unit UDAW.Audio.Source;
{$I udaw.inc}

{ Phase 2 - audio sources feeding the device engine's render callback.

  IAudioSource.Render fills a TAudioBuffer's live frames. Implementations here
  are real signal generators (used for reliable-playback acceptance, latency
  measurement, and golden render tests) plus a mixer that sums child sources.
  Nothing here is a placeholder tone: the oscillators use a proper phase
  accumulator and the noise sources use a documented PRNG. }

interface

uses
  SysUtils, Math,
  UDAW.Errors, UDAW.Audio.Types, UDAW.Audio.Buffer;

type
  IAudioSource = interface
    ['{7E1C2A40-6B4E-4E2A-9F2E-1B7C0A9D3E11}']
    { Fill ABuffer[0..FrameCount) for playback at ABuffer.SampleRate.
      Called on the real-time thread: no allocation, no locks, no IO. }
    procedure Render(ABuffer: TAudioBuffer);
    procedure Prepare(ASampleRate, AMaxFrames, AChannels: Integer);
    procedure Reset;
    function Name: string;
  end;

  TOscShape = (osSine, osTriangle, osSaw, osSquare, osWhiteNoise, osPinkNoise);

  { Test / utility tone generator. Deterministic given the same construction
    parameters and Reset(). Stereo output is coherent (same phase both sides)
    unless APhaseSpreadRad is set. }
  TToneSource = class(TInterfacedObject, IAudioSource)
  private
    FShape: TOscShape;
    FFreq: Double;
    FAmp: Single;
    FSampleRate: Integer;
    FPhase: Double;          // 0..1
    FPhaseInc: Double;
    FPhaseSpread: Double;    // radians, applied to channel 1..n
    { pink noise state (Paul Kellet economy filter) }
    FPink: array[0..6] of Double;
    FRandState: UInt32;
    function NextWhite: Single;
    function NextPink: Single;
    procedure Recalc;
  public
    constructor Create(AShape: TOscShape; AFreqHz: Double; AAmplitude: Single = 0.5;
      APhaseSpreadRad: Double = 0.0);
    procedure Render(ABuffer: TAudioBuffer);
    procedure Prepare(ASampleRate, AMaxFrames, AChannels: Integer);
    procedure Reset;
    function Name: string;
    property Frequency: Double read FFreq write FFreq;
    property Amplitude: Single read FAmp write FAmp;
  end;

  { Linear or exponential frequency sweep - the standard stimulus for latency
    and frequency-response checks. }
  TSweepSource = class(TInterfacedObject, IAudioSource)
  private
    FF0, FF1: Double;
    FDurationS: Double;
    FAmp: Single;
    FExp: Boolean;
    FSampleRate: Integer;
    FT: Double;              // seconds elapsed
    FPhase: Double;          // radians
  public
    constructor Create(AStartHz, AEndHz, ADurationSeconds: Double;
      AAmplitude: Single = 0.5; AExponential: Boolean = True);
    procedure Render(ABuffer: TAudioBuffer);
    procedure Prepare(ASampleRate, AMaxFrames, AChannels: Integer);
    procedure Reset;
    function Name: string;
  end;

  TSilenceSource = class(TInterfacedObject, IAudioSource)
  public
    procedure Render(ABuffer: TAudioBuffer);
    procedure Prepare(ASampleRate, AMaxFrames, AChannels: Integer);
    procedure Reset;
    function Name: string;
  end;

  { Sums any number of child sources through a scratch buffer. Owns nothing:
    children are reference-counted interfaces. Real-time safe once Prepare has
    sized the scratch buffer. }
  TSourceMixer = class(TInterfacedObject, IAudioSource)
  private
    FChildren: array of IAudioSource;
    FGains: array of Single;
    FScratch: TAudioBuffer;
    FMasterGain: Single;
  public
    constructor Create(AMasterGain: Single = 1.0);
    destructor Destroy; override;
    procedure Add(ASource: IAudioSource; AGain: Single = 1.0);
    procedure Render(ABuffer: TAudioBuffer);
    procedure Prepare(ASampleRate, AMaxFrames, AChannels: Integer);
    procedure Reset;
    function Name: string;
    property MasterGain: Single read FMasterGain write FMasterGain;
  end;

implementation

const
  TWO_PI = 2.0 * Pi;

{ ---------------- TToneSource ---------------- }

constructor TToneSource.Create(AShape: TOscShape; AFreqHz: Double;
  AAmplitude: Single; APhaseSpreadRad: Double);
begin
  inherited Create;
  FShape := AShape;
  FFreq := AFreqHz;
  FAmp := AAmplitude;
  FPhaseSpread := APhaseSpreadRad;
  FSampleRate := UDAW_DEFAULT_SAMPLE_RATE;
  FRandState := 22050;
  Recalc;
end;

procedure TToneSource.Recalc;
begin
  if FSampleRate > 0 then
    FPhaseInc := FFreq / FSampleRate
  else
    FPhaseInc := 0;
end;

procedure TToneSource.Prepare(ASampleRate, AMaxFrames, AChannels: Integer);
begin
  if ASampleRate > 0 then
    FSampleRate := ASampleRate;
  Recalc;
end;

procedure TToneSource.Reset;
begin
  FPhase := 0;
  FillChar(FPink, SizeOf(FPink), 0);
  FRandState := 22050;
end;

function TToneSource.NextWhite: Single;
begin
  { xorshift32 - deterministic, fast, good enough for test noise }
  FRandState := FRandState xor (FRandState shl 13);
  FRandState := FRandState xor (FRandState shr 17);
  FRandState := FRandState xor (FRandState shl 5);
  Result := (Int64(FRandState) / 2147483648.0) - 1.0;
end;

function TToneSource.NextPink: Single;
var
  w: Double;
begin
  w := NextWhite;
  FPink[0] := 0.99886 * FPink[0] + w * 0.0555179;
  FPink[1] := 0.99332 * FPink[1] + w * 0.0750759;
  FPink[2] := 0.96900 * FPink[2] + w * 0.1538520;
  FPink[3] := 0.86650 * FPink[3] + w * 0.3104856;
  FPink[4] := 0.55000 * FPink[4] + w * 0.5329522;
  FPink[5] := -0.7616 * FPink[5] - w * 0.0168980;
  Result := (FPink[0] + FPink[1] + FPink[2] + FPink[3] + FPink[4] + FPink[5]
             + FPink[6] + w * 0.5362) * 0.11;
  FPink[6] := w * 0.115926;
end;

procedure TToneSource.Render(ABuffer: TAudioBuffer);
var
  i, ch, n: Integer;
  ph, v, frac: Double;
  d: PAudioSample;
begin
  if ABuffer.SampleRate <> FSampleRate then
  begin
    FSampleRate := ABuffer.SampleRate;
    Recalc;
  end;
  n := ABuffer.FrameCount;

  for i := 0 to n - 1 do
  begin
    ph := FPhase;
    case FShape of
      osSine:     v := Sin(ph * TWO_PI);
      osTriangle:
        begin
          frac := ph - Floor(ph);
          if frac < 0.5 then v := 4.0 * frac - 1.0
          else v := 3.0 - 4.0 * frac;
        end;
      osSaw:
        begin
          frac := ph - Floor(ph);
          v := 2.0 * frac - 1.0;
        end;
      osSquare:
        begin
          frac := ph - Floor(ph);
          if frac < 0.5 then v := 1.0 else v := -1.0;
        end;
      osWhiteNoise: v := NextWhite;
      osPinkNoise:  v := NextPink;
    else
      v := 0;
    end;

    for ch := 0 to ABuffer.ChannelCount - 1 do
    begin
      d := ABuffer.ChannelPtr(ch);
      Inc(d, i);
      if (ch = 0) or (FPhaseSpread = 0) or (FShape in [osWhiteNoise, osPinkNoise]) then
        d^ := FAmp * Single(v)
      else
        d^ := FAmp * Single(Sin((ph * TWO_PI) + FPhaseSpread * ch));
    end;

    FPhase := FPhase + FPhaseInc;
    if FPhase >= 1.0 then
      FPhase := FPhase - Floor(FPhase);
  end;
end;

function TToneSource.Name: string;
const
  N: array[TOscShape] of string =
    ('sine', 'triangle', 'saw', 'square', 'white-noise', 'pink-noise');
begin
  Result := Format('tone(%s %.1f Hz)', [N[FShape], FFreq]);
end;

{ ---------------- TSweepSource ---------------- }

constructor TSweepSource.Create(AStartHz, AEndHz, ADurationSeconds: Double;
  AAmplitude: Single; AExponential: Boolean);
begin
  inherited Create;
  FF0 := AStartHz;
  FF1 := AEndHz;
  FDurationS := Max(ADurationSeconds, 0.001);
  FAmp := AAmplitude;
  FExp := AExponential;
  FSampleRate := UDAW_DEFAULT_SAMPLE_RATE;
end;

procedure TSweepSource.Prepare(ASampleRate, AMaxFrames, AChannels: Integer);
begin
  if ASampleRate > 0 then FSampleRate := ASampleRate;
end;

procedure TSweepSource.Reset;
begin
  FT := 0;
  FPhase := 0;
end;

procedure TSweepSource.Render(ABuffer: TAudioBuffer);
var
  i, ch, n: Integer;
  dt, f, prog, v: Double;
  d: PAudioSample;
begin
  if ABuffer.SampleRate > 0 then FSampleRate := ABuffer.SampleRate;
  n := ABuffer.FrameCount;
  dt := 1.0 / FSampleRate;
  for i := 0 to n - 1 do
  begin
    prog := FT / FDurationS;
    if prog > 1.0 then prog := 1.0;
    if FExp and (FF0 > 0) and (FF1 > 0) then
      f := FF0 * Power(FF1 / FF0, prog)
    else
      f := FF0 + (FF1 - FF0) * prog;
    v := FAmp * Sin(FPhase);
    for ch := 0 to ABuffer.ChannelCount - 1 do
    begin
      d := ABuffer.ChannelPtr(ch);
      Inc(d, i);
      d^ := Single(v);
    end;
    FPhase := FPhase + TWO_PI * f * dt;
    if FPhase >= TWO_PI then FPhase := FPhase - TWO_PI;
    FT := FT + dt;
  end;
end;

function TSweepSource.Name: string;
begin
  Result := Format('sweep(%.0f->%.0f Hz / %.2fs)', [FF0, FF1, FDurationS]);
end;

{ ---------------- TSilenceSource ---------------- }

procedure TSilenceSource.Render(ABuffer: TAudioBuffer);
begin
  ABuffer.Clear;
end;

procedure TSilenceSource.Prepare(ASampleRate, AMaxFrames, AChannels: Integer);
begin
end;

procedure TSilenceSource.Reset;
begin
end;

function TSilenceSource.Name: string;
begin
  Result := 'silence';
end;

{ ---------------- TSourceMixer ---------------- }

constructor TSourceMixer.Create(AMasterGain: Single);
begin
  inherited Create;
  FMasterGain := AMasterGain;
  FScratch := TAudioBuffer.Create(2, UDAW_DEFAULT_BUFFER_FRAMES, UDAW_DEFAULT_SAMPLE_RATE);
end;

destructor TSourceMixer.Destroy;
var
  i: Integer;
begin
  for i := 0 to High(FChildren) do
    FChildren[i] := nil;
  FScratch.Free;
  inherited Destroy;
end;

procedure TSourceMixer.Add(ASource: IAudioSource; AGain: Single);
var
  n: Integer;
begin
  if ASource = nil then Exit;
  n := Length(FChildren);
  SetLength(FChildren, n + 1);
  SetLength(FGains, n + 1);
  FChildren[n] := ASource;
  FGains[n] := AGain;
end;

procedure TSourceMixer.Prepare(ASampleRate, AMaxFrames, AChannels: Integer);
var
  i: Integer;
begin
  FScratch.Configure(AChannels, AMaxFrames, ASampleRate);
  for i := 0 to High(FChildren) do
    FChildren[i].Prepare(ASampleRate, AMaxFrames, AChannels);
end;

procedure TSourceMixer.Reset;
var
  i: Integer;
begin
  for i := 0 to High(FChildren) do
    FChildren[i].Reset;
end;

procedure TSourceMixer.Render(ABuffer: TAudioBuffer);
var
  i: Integer;
begin
  ABuffer.Clear;
  if Length(FChildren) = 0 then Exit;
  FScratch.Configure(ABuffer.ChannelCount, ABuffer.FrameCount, ABuffer.SampleRate);
  for i := 0 to High(FChildren) do
  begin
    FScratch.SetActiveFrames(ABuffer.FrameCount);
    FScratch.Clear;
    FChildren[i].Render(FScratch);
    ABuffer.MixFrom(FScratch, FGains[i]);
  end;
  if FMasterGain <> 1.0 then
    ABuffer.ApplyGain(FMasterGain);
end;

function TSourceMixer.Name: string;
begin
  Result := Format('mixer(%d sources)', [Length(FChildren)]);
end;

end.
