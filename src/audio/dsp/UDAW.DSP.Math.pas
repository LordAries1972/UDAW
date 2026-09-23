unit UDAW.DSP.Math;
{$I udaw.inc}
{$POINTERMATH ON}

{ Phase 3 - Internal DSP Foundation: scalar and block math shared by every DSP
  unit. No third-party code: everything here is elementary numerics.

  * denormal flushing (the RT audio path must never stall on subnormals)
  * click-free block operations on planar Float32 (copy / add / scale / ramp)
  * energy helpers (sum-of-squares, block peak)
  * pan / crossfade laws (linear and constant-power)
  * TParamSmoother - a one-pole parameter ramp so gain / cutoff / pan changes
    never step-discontinuity the signal
  * analysis windows (Hann / Hamming / Blackman / Blackman-Harris) and the
    power-of-two helpers the FFT needs

  This unit depends only on the RTL and UDAW.Audio.Types (for TAudioSample and
  the dB helpers already defined there). }

interface

uses
  SysUtils, Math,
  UDAW.Audio.Types;

const
  DSP_SUBSYS = 'DSP';

  { Anything below this magnitude is treated as silence and flushed to zero so
    IIR state cannot decay into the subnormal range. -300 dBFS-ish. }
  DSP_DENORMAL_FLOOR = 1.0E-20;

  DSP_PI     = 3.14159265358979323846;
  DSP_TWO_PI = 6.28318530717958647693;

type
  TWindowKind = (wkRect, wkHann, wkHamming, wkBlackman, wkBlackmanHarris);

  TPanLaw = (plLinear, plConstantPower, plCompromise45);

  { One-pole smoother. Target changes are approached exponentially with a
    configurable time constant; SetImmediate jumps with no ramp. Value semantics
    - copy it freely, it holds no heap state. }
  TParamSmoother = record
  private
    FCurrent: Double;
    FTarget: Double;
    FCoeff: Double;        // per-sample pole; 0 => no smoothing (instant)
    FSampleRate: Double;
    FTimeMs: Double;
  public
    procedure Init(ASampleRate: Double; ATimeMs: Double; AInitial: Double = 0.0);
    procedure SetTimeMs(ATimeMs: Double);
    procedure SetTarget(AValue: Double);       {$IFDEF FPC}inline;{$ENDIF}
    procedure SetImmediate(AValue: Double);    {$IFDEF FPC}inline;{$ENDIF}
    function  Process: Double;                  {$IFDEF FPC}inline;{$ENDIF}
    function  Settled(AEps: Double = 1.0E-6): Boolean;
    property  Current: Double read FCurrent;
    property  Target: Double read FTarget;
  end;

{ ---- denormal / finite guards ---- }

function FlushDenorm(AValue: Single): Single; {$IFDEF FPC}inline;{$ENDIF}
function IsFiniteSample(AValue: Single): Boolean; {$IFDEF FPC}inline;{$ENDIF}
function SanitizeSample(AValue: Single): Single; {$IFDEF FPC}inline;{$ENDIF}

{ ---- block operations (length = AFrames Singles) ---- }

procedure BlockClear(ADst: PSingle; AFrames: Integer);
procedure BlockCopy(ADst, ASrc: PSingle; AFrames: Integer);
procedure BlockScale(ADst: PSingle; AGain: Single; AFrames: Integer);
procedure BlockAdd(ADst, ASrc: PSingle; AFrames: Integer);
procedure BlockAddScaled(ADst, ASrc: PSingle; AGain: Single; AFrames: Integer);
{ dst := dst*(1-t) + src*t with t moving linearly AStartMix..AEndMix - the
  click-free crossfade primitive used by the mixer and by parameter ramps. }
procedure BlockMixRamp(ADst, ASrc: PSingle; AStartMix, AEndMix: Single; AFrames: Integer);
{ dst *= gain, gain moving linearly AStartGain..AEndGain over the block. }
procedure BlockScaleRamp(ADst: PSingle; AStartGain, AEndGain: Single; AFrames: Integer);
procedure BlockFlushDenorm(ADst: PSingle; AFrames: Integer);

function SumSquares(ASrc: PSingle; AFrames: Integer): Double;
function BlockPeak(ASrc: PSingle; AFrames: Integer): Single;
function BlockRms(ASrc: PSingle; AFrames: Integer): Double;

{ ---- pan / crossfade ---- }

{ APos in -1..+1 (left..right). Returns linear channel gains. }
procedure PanGains(APos: Single; ALaw: TPanLaw; out ALeft, ARight: Single);
{ Equal-power crossfade weights for APos in 0..1 (A..B). }
procedure XfadeGains(APos: Single; out AGainA, AGainB: Single);

{ ---- windows ---- }

function WindowValue(AKind: TWindowKind; AIndex, ALength: Integer): Double;
procedure FillWindow(AKind: TWindowKind; var ADst: array of Single);
{ Coherent gain (mean of the window) - divide a windowed sum by this to keep
  amplitude calibration; also the 1/sum(w) FFT normalisation. }
function WindowCoherentGain(AKind: TWindowKind; ALength: Integer): Double;

{ ---- power-of-two helpers ---- }

function IsPow2(AValue: Integer): Boolean; {$IFDEF FPC}inline;{$ENDIF}
function NextPow2(AValue: Integer): Integer;
function IntLog2(AValue: Integer): Integer;

{ Normalised sinc: sin(pi x)/(pi x), sinc(0)=1. }
function SincNorm(AX: Double): Double; {$IFDEF FPC}inline;{$ENDIF}

implementation

{ ---------------- TParamSmoother ---------------- }

procedure TParamSmoother.Init(ASampleRate, ATimeMs, AInitial: Double);
begin
  if ASampleRate <= 0 then ASampleRate := UDAW_DEFAULT_SAMPLE_RATE;
  FSampleRate := ASampleRate;
  FCurrent := AInitial;
  FTarget := AInitial;
  SetTimeMs(ATimeMs);
end;

procedure TParamSmoother.SetTimeMs(ATimeMs: Double);
begin
  FTimeMs := ATimeMs;
  if ATimeMs <= 0 then
    FCoeff := 0.0
  else
    { one-pole so that after ATimeMs the step response reaches ~63% (1-1/e). }
    FCoeff := Exp(-1.0 / ((ATimeMs * 0.001) * FSampleRate));
end;

procedure TParamSmoother.SetTarget(AValue: Double);
begin
  FTarget := AValue;
end;

procedure TParamSmoother.SetImmediate(AValue: Double);
begin
  FTarget := AValue;
  FCurrent := AValue;
end;

function TParamSmoother.Process: Double;
begin
  if FCoeff <= 0.0 then
    FCurrent := FTarget
  else
  begin
    FCurrent := FTarget + (FCurrent - FTarget) * FCoeff;
    if Abs(FCurrent - FTarget) < DSP_DENORMAL_FLOOR then
      FCurrent := FTarget;
  end;
  Result := FCurrent;
end;

function TParamSmoother.Settled(AEps: Double): Boolean;
begin
  Result := Abs(FCurrent - FTarget) <= AEps;
end;

{ ---------------- denormal / finite ---------------- }

function FlushDenorm(AValue: Single): Single;
begin
  if Abs(AValue) < DSP_DENORMAL_FLOOR then
    Result := 0.0
  else
    Result := AValue;
end;

function IsFiniteSample(AValue: Single): Boolean;
begin
  Result := not (IsNan(AValue) or IsInfinite(AValue));
end;

function SanitizeSample(AValue: Single): Single;
begin
  if not IsFiniteSample(AValue) then
    Result := 0.0
  else if Abs(AValue) < DSP_DENORMAL_FLOOR then
    Result := 0.0
  else
    Result := AValue;
end;

{ ---------------- block ops ---------------- }

procedure BlockClear(ADst: PSingle; AFrames: Integer);
begin
  if (ADst <> nil) and (AFrames > 0) then
    FillChar(ADst^, AFrames * SizeOf(Single), 0);
end;

procedure BlockCopy(ADst, ASrc: PSingle; AFrames: Integer);
begin
  if (ADst <> nil) and (ASrc <> nil) and (AFrames > 0) then
    Move(ASrc^, ADst^, AFrames * SizeOf(Single));
end;

procedure BlockScale(ADst: PSingle; AGain: Single; AFrames: Integer);
var
  i: Integer;
begin
  for i := 0 to AFrames - 1 do
    ADst[i] := ADst[i] * AGain;
end;

procedure BlockAdd(ADst, ASrc: PSingle; AFrames: Integer);
var
  i: Integer;
begin
  for i := 0 to AFrames - 1 do
    ADst[i] := ADst[i] + ASrc[i];
end;

procedure BlockAddScaled(ADst, ASrc: PSingle; AGain: Single; AFrames: Integer);
var
  i: Integer;
begin
  for i := 0 to AFrames - 1 do
    ADst[i] := ADst[i] + ASrc[i] * AGain;
end;

procedure BlockMixRamp(ADst, ASrc: PSingle; AStartMix, AEndMix: Single; AFrames: Integer);
var
  i: Integer;
  t, step: Double;
begin
  if AFrames <= 0 then Exit;
  t := AStartMix;
  if AFrames = 1 then
    step := 0
  else
    step := (AEndMix - AStartMix) / AFrames;
  for i := 0 to AFrames - 1 do
  begin
    ADst[i] := ADst[i] * (1.0 - t) + ASrc[i] * t;
    t := t + step;
  end;
end;

procedure BlockScaleRamp(ADst: PSingle; AStartGain, AEndGain: Single; AFrames: Integer);
var
  i: Integer;
  g, step: Double;
begin
  if AFrames <= 0 then Exit;
  g := AStartGain;
  if AFrames = 1 then
    step := 0
  else
    step := (AEndGain - AStartGain) / AFrames;
  for i := 0 to AFrames - 1 do
  begin
    ADst[i] := ADst[i] * g;
    g := g + step;
  end;
end;

procedure BlockFlushDenorm(ADst: PSingle; AFrames: Integer);
var
  i: Integer;
begin
  for i := 0 to AFrames - 1 do
    if Abs(ADst[i]) < DSP_DENORMAL_FLOOR then
      ADst[i] := 0.0;
end;

function SumSquares(ASrc: PSingle; AFrames: Integer): Double;
var
  i: Integer;
  acc: Double;
begin
  acc := 0;
  for i := 0 to AFrames - 1 do
    acc := acc + Double(ASrc[i]) * Double(ASrc[i]);
  Result := acc;
end;

function BlockPeak(ASrc: PSingle; AFrames: Integer): Single;
var
  i: Integer;
  m, a: Single;
begin
  m := 0;
  for i := 0 to AFrames - 1 do
  begin
    a := Abs(ASrc[i]);
    if a > m then m := a;
  end;
  Result := m;
end;

function BlockRms(ASrc: PSingle; AFrames: Integer): Double;
begin
  if AFrames <= 0 then
    Result := 0
  else
    Result := Sqrt(SumSquares(ASrc, AFrames) / AFrames);
end;

{ ---------------- pan / crossfade ---------------- }

procedure PanGains(APos: Single; ALaw: TPanLaw; out ALeft, ARight: Single);
var
  x, ang: Double;
begin
  if APos < -1 then APos := -1 else if APos > 1 then APos := 1;
  x := (APos + 1.0) * 0.5;   // 0..1
  case ALaw of
    plLinear:
      begin
        ALeft := 1.0 - x;
        ARight := x;
      end;
    plConstantPower:
      begin
        ang := x * (DSP_PI * 0.5);
        ALeft := Cos(ang);
        ARight := Sin(ang);
      end;
    plCompromise45:
      begin
        { geometric mean of the linear and constant-power laws: -4.5 dB centre }
        ang := x * (DSP_PI * 0.5);
        ALeft := Sqrt((1.0 - x) * Cos(ang));
        ARight := Sqrt(x * Sin(ang));
      end;
  else
    ALeft := 1; ARight := 1;
  end;
end;

procedure XfadeGains(APos: Single; out AGainA, AGainB: Single);
var
  ang: Double;
begin
  if APos < 0 then APos := 0 else if APos > 1 then APos := 1;
  ang := APos * (DSP_PI * 0.5);
  AGainA := Cos(ang);
  AGainB := Sin(ang);
end;

{ ---------------- windows ---------------- }

function WindowValue(AKind: TWindowKind; AIndex, ALength: Integer): Double;
var
  n: Double;
begin
  if ALength <= 1 then Exit(1.0);
  if AIndex < 0 then AIndex := 0 else if AIndex > ALength - 1 then AIndex := ALength - 1;
  n := AIndex / (ALength - 1);   // 0..1
  case AKind of
    wkHann:
      Result := 0.5 - 0.5 * Cos(DSP_TWO_PI * n);
    wkHamming:
      Result := 0.54 - 0.46 * Cos(DSP_TWO_PI * n);
    wkBlackman:
      Result := 0.42 - 0.5 * Cos(DSP_TWO_PI * n) + 0.08 * Cos(2 * DSP_TWO_PI * n);
    wkBlackmanHarris:
      Result := 0.35875
              - 0.48829 * Cos(DSP_TWO_PI * n)
              + 0.14128 * Cos(2 * DSP_TWO_PI * n)
              - 0.01168 * Cos(3 * DSP_TWO_PI * n);
  else
    Result := 1.0;   // wkRect
  end;
end;

procedure FillWindow(AKind: TWindowKind; var ADst: array of Single);
var
  i, n: Integer;
begin
  n := Length(ADst);
  for i := 0 to n - 1 do
    ADst[i] := WindowValue(AKind, i, n);
end;

function WindowCoherentGain(AKind: TWindowKind; ALength: Integer): Double;
var
  i: Integer;
  acc: Double;
begin
  if ALength <= 0 then Exit(1.0);
  acc := 0;
  for i := 0 to ALength - 1 do
    acc := acc + WindowValue(AKind, i, ALength);
  Result := acc / ALength;
end;

{ ---------------- pow2 ---------------- }

function IsPow2(AValue: Integer): Boolean;
begin
  Result := (AValue > 0) and ((AValue and (AValue - 1)) = 0);
end;

function NextPow2(AValue: Integer): Integer;
begin
  if AValue <= 1 then Exit(1);
  Result := 1;
  while Result < AValue do
    Result := Result shl 1;
end;

function IntLog2(AValue: Integer): Integer;
begin
  Result := 0;
  while AValue > 1 do
  begin
    AValue := AValue shr 1;
    Inc(Result);
  end;
end;

function SincNorm(AX: Double): Double;
var
  px: Double;
begin
  if Abs(AX) < 1.0E-9 then
    Result := 1.0
  else
  begin
    px := DSP_PI * AX;
    Result := Sin(px) / px;
  end;
end;

end.
