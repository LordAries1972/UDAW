unit UDAW.DSP.Reverb;
{$I udaw.inc}
{$POINTERMATH ON}

{ Phase 10 - internal algorithmic reverb (plan section 11): early reflections,
  a bank of damped comb filters, a series of all-pass diffusers, room-size and
  damping controls, stereo decorrelation and a wet/dry mix.

  Structure (a Schroeder / Freeverb-family design, implemented from the
  well-known topology - no third-party code):

    input -> pre-delay -> [ early-reflection tapped delay ]  --.
                       -> 8 parallel LP-damped comb filters --+-> 4 series
                          (right channel lengths offset for       all-pass
                           stereo decorrelation)                   diffusers -> wet

  Comb / all-pass lengths are the classic Freeverb tunings scaled from 44.1 kHz
  to the running sample rate. Delay buffers are allocated once in Configure. }

interface

uses
  SysUtils, Math,
  UDAW.Audio.Types, UDAW.DSP.Math;

const
  REV_NUM_COMBS   = 8;
  REV_NUM_ALLPASS = 4;
  REV_STEREO_SPREAD = 23;      // samples @ 44.1k, added to the right channel
  REV_MAX_PREDELAY_MS = 200.0;

type
  TReverbComb = record
    Buf: array of Single;
    Len: Integer;
    Pos: Integer;
    FilterStore: Double;       // one-pole LP in the feedback path (damping)
    Feedback: Double;
    Damp1: Double;
    Damp2: Double;
    procedure SetSize(ALen: Integer);
    procedure Reset;
    function Process(AInput: Single): Single; {$IFDEF FPC}inline;{$ENDIF}
  end;

  TReverbAllpass = record
    Buf: array of Single;
    Len: Integer;
    Pos: Integer;
    Feedback: Double;
    procedure SetSize(ALen: Integer);
    procedure Reset;
    function Process(AInput: Single): Single; {$IFDEF FPC}inline;{$ENDIF}
  end;

  TAlgoReverb = class
  private
    FSampleRate: Integer;
    FSize: Double;            // 0..1 -> comb feedback
    FDamp: Double;            // 0..1
    FWidth: Double;           // 0..1 stereo spread of the wet signal
    FMix: Double;             // 0..1 wet
    FPreDelayMs: Double;
    FEarlyLevel: Double;
    FTailLevel: Double;
    FCombL, FCombR: array[0..REV_NUM_COMBS - 1] of TReverbComb;
    FApL, FApR: array[0..REV_NUM_ALLPASS - 1] of TReverbAllpass;
    FPre: array of Single;    // pre-delay line (mono feed)
    FPreLen, FPrePos: Integer;
    FErTaps: array[0..5] of Integer;
    FErGains: array[0..5] of Double;
    procedure Recalc;
  public
    constructor Create;
    procedure Configure(ASampleRate: Integer);
    procedure Reset;
    procedure SetParams(ASize, ADamp, AWidth, AMix, APreDelayMs,
      AEarlyLevel, ATailLevel: Double);
    { Stereo in place. Mono input is duplicated; a mono call passes ch 0 only. }
    procedure ProcessBlock(const AIn, AOut: array of PSingle; AFrames: Integer);
  end;

implementation

const
  COMB_TUNING: array[0..REV_NUM_COMBS - 1] of Integer =
    (1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617);
  ALLPASS_TUNING: array[0..REV_NUM_ALLPASS - 1] of Integer =
    (556, 441, 341, 225);
  REF_SR = 44100.0;

{ ---------------- TReverbComb ---------------- }

procedure TReverbComb.SetSize(ALen: Integer);
begin
  if ALen < 1 then ALen := 1;
  if Len <> ALen then
  begin
    Len := ALen;
    SetLength(Buf, Len);
  end;
  Reset;
end;

procedure TReverbComb.Reset;
begin
  if Length(Buf) > 0 then
    FillChar(Buf[0], Length(Buf) * SizeOf(Single), 0);
  Pos := 0;
  FilterStore := 0;
end;

function TReverbComb.Process(AInput: Single): Single;
var
  outp: Double;
begin
  outp := Buf[Pos];
  FilterStore := outp * Damp2 + FilterStore * Damp1;
  FilterStore := FlushDenorm(Single(FilterStore));
  Buf[Pos] := Single(FlushDenorm(Single(AInput + FilterStore * Feedback)));
  Inc(Pos);
  if Pos >= Len then Pos := 0;
  Result := Single(outp);
end;

{ ---------------- TReverbAllpass ---------------- }

procedure TReverbAllpass.SetSize(ALen: Integer);
begin
  if ALen < 1 then ALen := 1;
  if Len <> ALen then
  begin
    Len := ALen;
    SetLength(Buf, Len);
  end;
  Reset;
end;

procedure TReverbAllpass.Reset;
begin
  if Length(Buf) > 0 then
    FillChar(Buf[0], Length(Buf) * SizeOf(Single), 0);
  Pos := 0;
end;

function TReverbAllpass.Process(AInput: Single): Single;
var
  bufout, outp: Double;
begin
  bufout := Buf[Pos];
  outp := -AInput + bufout;
  Buf[Pos] := Single(FlushDenorm(Single(AInput + bufout * Feedback)));
  Inc(Pos);
  if Pos >= Len then Pos := 0;
  Result := Single(outp);
end;

{ ---------------- TAlgoReverb ---------------- }

constructor TAlgoReverb.Create;
begin
  inherited Create;
  FSampleRate := UDAW_DEFAULT_SAMPLE_RATE;
  FSize := 0.7;
  FDamp := 0.4;
  FWidth := 1.0;
  FMix := 0.3;
  FPreDelayMs := 15.0;
  FEarlyLevel := 0.5;
  FTailLevel := 0.9;
end;

procedure TAlgoReverb.Configure(ASampleRate: Integer);
var
  i, scaledLen, spread: Integer;
  scale: Double;
begin
  if ASampleRate > 0 then FSampleRate := ASampleRate;
  scale := FSampleRate / REF_SR;
  spread := Round(REV_STEREO_SPREAD * scale);

  for i := 0 to REV_NUM_COMBS - 1 do
  begin
    scaledLen := Round(COMB_TUNING[i] * scale);
    FCombL[i].SetSize(scaledLen);
    FCombR[i].SetSize(scaledLen + spread);
  end;
  for i := 0 to REV_NUM_ALLPASS - 1 do
  begin
    scaledLen := Round(ALLPASS_TUNING[i] * scale);
    FApL[i].SetSize(scaledLen);
    FApR[i].SetSize(scaledLen + spread);
    FApL[i].Feedback := 0.5;
    FApR[i].Feedback := 0.5;
  end;

  FPreLen := Round(REV_MAX_PREDELAY_MS * 0.001 * FSampleRate) + 4;
  SetLength(FPre, FPreLen);

  { early-reflection pattern (ms -> samples) }
  FErTaps[0] := Round(0.0043 * FSampleRate);  FErGains[0] := 0.841;
  FErTaps[1] := Round(0.0215 * FSampleRate);  FErGains[1] := 0.504;
  FErTaps[2] := Round(0.0225 * FSampleRate);  FErGains[2] := 0.491;
  FErTaps[3] := Round(0.0268 * FSampleRate);  FErGains[3] := 0.379;
  FErTaps[4] := Round(0.0298 * FSampleRate);  FErGains[4] := 0.380;
  FErTaps[5] := Round(0.0450 * FSampleRate);  FErGains[5] := 0.346;

  Recalc;
  Reset;
end;

procedure TAlgoReverb.Recalc;
var
  i: Integer;
  fb, d1: Double;
begin
  if FSize < 0 then FSize := 0 else if FSize > 1 then FSize := 1;
  if FDamp < 0 then FDamp := 0 else if FDamp > 1 then FDamp := 1;
  if FWidth < 0 then FWidth := 0 else if FWidth > 1 then FWidth := 1;
  if FMix < 0 then FMix := 0 else if FMix > 1 then FMix := 1;
  fb := 0.7 + 0.28 * FSize;      // 0.70 .. 0.98
  d1 := FDamp * 0.4;
  for i := 0 to REV_NUM_COMBS - 1 do
  begin
    FCombL[i].Feedback := fb;
    FCombR[i].Feedback := fb;
    FCombL[i].Damp1 := d1;  FCombL[i].Damp2 := 1.0 - d1;
    FCombR[i].Damp1 := d1;  FCombR[i].Damp2 := 1.0 - d1;
  end;
end;

procedure TAlgoReverb.Reset;
var
  i: Integer;
begin
  for i := 0 to REV_NUM_COMBS - 1 do
  begin
    FCombL[i].Reset;
    FCombR[i].Reset;
  end;
  for i := 0 to REV_NUM_ALLPASS - 1 do
  begin
    FApL[i].Reset;
    FApR[i].Reset;
  end;
  if Length(FPre) > 0 then FillChar(FPre[0], Length(FPre) * SizeOf(Single), 0);
  FPrePos := 0;
end;

procedure TAlgoReverb.SetParams(ASize, ADamp, AWidth, AMix, APreDelayMs,
  AEarlyLevel, ATailLevel: Double);
begin
  FSize := ASize;
  FDamp := ADamp;
  FWidth := AWidth;
  FMix := AMix;
  FPreDelayMs := Min(REV_MAX_PREDELAY_MS, Max(0.0, APreDelayMs));
  FEarlyLevel := Max(0.0, AEarlyLevel);
  FTailLevel := Max(0.0, ATailLevel);
  Recalc;
end;

procedure TAlgoReverb.ProcessBlock(const AIn, AOut: array of PSingle; AFrames: Integer);
var
  i, k, nc, preSamp, rp, ep: Integer;
  monoIn, early, wl, wr, dry, wet: Double;
  inputComb: Double;
  combL, combR, apInL, apInR: Double;
  outL, outR, w1, w2: Double;
begin
  nc := Length(AIn);
  if nc = 0 then Exit;
  preSamp := Round(FPreDelayMs * 0.001 * FSampleRate);
  if preSamp < 0 then preSamp := 0;
  if preSamp > FPreLen - 1 then preSamp := FPreLen - 1;
  dry := 1.0 - FMix;
  wet := FMix;
  { equal-power-ish wet stereo matrix from width }
  w1 := FWidth * 0.5 + 0.5;
  w2 := (1.0 - FWidth) * 0.5;

  for i := 0 to AFrames - 1 do
  begin
    if nc >= 2 then
      monoIn := 0.5 * (AIn[0][i] + AIn[1][i])
    else
      monoIn := AIn[0][i];

    { pre-delay line }
    FPre[FPrePos] := Single(monoIn);
    rp := FPrePos - preSamp;
    if rp < 0 then rp := rp + FPreLen;
    inputComb := FPre[rp] * 0.015;   // input scaling into the comb bank

    { early reflections from the pre-delay line }
    early := 0;
    for k := 0 to 5 do
    begin
      ep := FPrePos - FErTaps[k];
      while ep < 0 do ep := ep + FPreLen;
      early := early + FPre[ep] * FErGains[k];
    end;
    early := early * FEarlyLevel * 0.5;

    Inc(FPrePos);
    if FPrePos >= FPreLen then FPrePos := 0;

    { parallel damped combs }
    combL := 0; combR := 0;
    for k := 0 to REV_NUM_COMBS - 1 do
    begin
      combL := combL + FCombL[k].Process(Single(inputComb));
      combR := combR + FCombR[k].Process(Single(inputComb));
    end;

    { series all-pass diffusers }
    apInL := combL;
    apInR := combR;
    for k := 0 to REV_NUM_ALLPASS - 1 do
    begin
      apInL := FApL[k].Process(Single(apInL));
      apInR := FApR[k].Process(Single(apInR));
    end;

    wl := (apInL * FTailLevel + early);
    wr := (apInR * FTailLevel + early);

    outL := wl * w1 + wr * w2;
    outR := wr * w1 + wl * w2;

    AOut[0][i] := Single(FlushDenorm(Single(dry * AIn[0][i] + wet * outL)));
    if nc >= 2 then
      AOut[1][i] := Single(FlushDenorm(Single(dry * AIn[1][i] + wet * outR)));
  end;
end;

end.
