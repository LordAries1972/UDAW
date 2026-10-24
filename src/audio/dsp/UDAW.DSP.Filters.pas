unit UDAW.DSP.Filters;
{$I udaw.inc}
{$POINTERMATH ON}

{ Phase 3 - filter building blocks.

  * TBiquad          - RBJ "audio EQ cookbook" biquad (LP/HP/BP/notch/allpass/
                       peaking/low-shelf/high-shelf), transposed direct form II,
                       with an analytic MagnitudeDb for drawing response curves
  * TBiquadChain     - a cascade of biquads (e.g. 4th-order Linkwitz-Riley = two
                       Butterworth biquads, or a graphic-EQ bank)
  * TOnePole         - first-order LP / HP; the cheapest smoother / tone control
  * TDCBlocker       - the standard y = x - x1 + R*y1 high-pass at ~5-20 Hz
  * TStateVariableFilter - Zavalishin TPT SVF, giving LP/HP/BP/notch outputs
                       simultaneously and remaining stable while modulated

  All processing is Float32 with denormal flushing. Coefficient calculation uses
  Double. Nothing here allocates after configuration. }

interface

uses
  SysUtils, Math,
  UDAW.Errors, UDAW.Audio.Types, UDAW.DSP.Math, UDAW.DSP.MathTables;

type
  TBiquadKind = (
    bqLowpass, bqHighpass,
    bqBandpassSkirt,    // constant skirt gain, peak gain = Q
    bqBandpassPeak,     // constant 0 dB peak gain
    bqNotch, bqAllpass,
    bqPeaking, bqLowShelf, bqHighShelf
  );

  TBiquad = record
  private
    Fb0, Fb1, Fb2, Fa1, Fa2: Double;   // a0-normalised
    Fz1, Fz2: Double;                  // TDF-II state
    FSampleRate: Double;
  public
    procedure Init(ASampleRate: Double);
    procedure Reset;
    { Configure from a filter kind. AGainDb is used only by peaking/shelf kinds. }
    procedure SetParams(AKind: TBiquadKind; AFreqHz, AQ: Double; AGainDb: Double = 0.0);
    { Set already-computed transfer-function coefficients (a0-normalised or not). }
    procedure SetCoeffs(Ab0, Ab1, Ab2, Aa0, Aa1, Aa2: Double);
    function ProcessSample(AX: Single): Single; inline;
    procedure ProcessBlock(ABuf: PSingle; AFrames: Integer);
    procedure ProcessBlockTo(ASrc, ADst: PSingle; AFrames: Integer);
    { |H(f)| in dB - for EQ curve drawing, not on the audio path. }
    function MagnitudeDb(AFreqHz: Double): Double;
    function PhaseDeg(AFreqHz: Double): Double;
    property SampleRate: Double read FSampleRate;
  end;
  PBiquad = ^TBiquad;

  TBiquadChain = class
  private
    FStages: array of TBiquad;
    FSampleRate: Double;
  public
    constructor Create(ASampleRate: Double; AStages: Integer);
    procedure SetStageCount(AStages: Integer);
    procedure Reset;
    function Stage(AIndex: Integer): PBiquad;
    { Butterworth lowpass/highpass of order 2*StageCount (each stage 2nd order). }
    procedure SetButterworthLowpass(AFreqHz: Double);
    procedure SetButterworthHighpass(AFreqHz: Double);
    function ProcessSample(AX: Single): Single;
    procedure ProcessBlock(ABuf: PSingle; AFrames: Integer);
    function MagnitudeDb(AFreqHz: Double): Double;
    function StageCount: Integer;
    property SampleRate: Double read FSampleRate;
  end;

  TOnePoleKind = (opLowpass, opHighpass);

  TOnePole = record
  private
    FA0, FB1: Double;
    FZ: Double;
    FHP: Boolean;
    FSampleRate: Double;
  public
    procedure Init(ASampleRate: Double);
    procedure Reset;
    procedure SetCutoff(AKind: TOnePoleKind; AFreqHz: Double);
    function ProcessSample(AX: Single): Single; inline;
    procedure ProcessBlock(ABuf: PSingle; AFrames: Integer);
  end;

  TDCBlocker = record
  private
    FR: Double;
    FX1, FY1: Double;
  public
    procedure Init(ASampleRate: Double; ACornerHz: Double = 20.0);
    procedure Reset;
    function ProcessSample(AX: Single): Single; inline;
    procedure ProcessBlock(ABuf: PSingle; AFrames: Integer);
  end;

  TSVFOutputs = record
    LP, HP, BP, Notch: Single;
  end;

  TStateVariableFilter = record
  private
    Fg, Fk, Fa1, Fa2, Fa3: Double;   // TPT coefficients
    Fic1eq, Fic2eq: Double;          // integrator states
    FSampleRate: Double;
  public
    procedure Init(ASampleRate: Double);
    procedure Reset;
    procedure SetParams(AFreqHz, AQ: Double);
    function ProcessSample(AX: Single): TSVFOutputs; inline;
    function ProcessLowpass(AX: Single): Single; inline;
    procedure ProcessBlockLowpass(ABuf: PSingle; AFrames: Integer);
  end;

function BiquadKindName(AKind: TBiquadKind): string;

implementation

function BiquadKindName(AKind: TBiquadKind): string;
begin
  case AKind of
    bqLowpass:        Result := 'lowpass';
    bqHighpass:       Result := 'highpass';
    bqBandpassSkirt:  Result := 'bandpass(skirt)';
    bqBandpassPeak:   Result := 'bandpass(peak)';
    bqNotch:          Result := 'notch';
    bqAllpass:        Result := 'allpass';
    bqPeaking:        Result := 'peaking';
    bqLowShelf:       Result := 'lowshelf';
    bqHighShelf:      Result := 'highshelf';
  else
    Result := '?';
  end;
end;

{ ---------------- TBiquad ---------------- }

procedure TBiquad.Init(ASampleRate: Double);
begin
  if ASampleRate <= 0 then ASampleRate := UDAW_DEFAULT_SAMPLE_RATE;
  FSampleRate := ASampleRate;
  Fb0 := 1; Fb1 := 0; Fb2 := 0; Fa1 := 0; Fa2 := 0;
  Fz1 := 0; Fz2 := 0;
end;

procedure TBiquad.Reset;
begin
  Fz1 := 0;
  Fz2 := 0;
end;

procedure TBiquad.SetCoeffs(Ab0, Ab1, Ab2, Aa0, Aa1, Aa2: Double);
begin
  if Aa0 = 0 then
    RaiseUDAW(errInvalidArgument, DSP_SUBSYS, 'TBiquad.SetCoeffs: a0 = 0');
  Fb0 := Ab0 / Aa0;
  Fb1 := Ab1 / Aa0;
  Fb2 := Ab2 / Aa0;
  Fa1 := Aa1 / Aa0;
  Fa2 := Aa2 / Aa0;
end;

procedure TBiquad.SetParams(AKind: TBiquadKind; AFreqHz, AQ: Double; AGainDb: Double);
var
  w0, cw, sw, alpha, A, beta: Double;
  b0, b1, b2, a0, a1, a2: Double;
begin
  if FSampleRate <= 0 then FSampleRate := UDAW_DEFAULT_SAMPLE_RATE;
  if AFreqHz < 1.0 then AFreqHz := 1.0;
  if AFreqHz > FSampleRate * 0.49 then AFreqHz := FSampleRate * 0.49;
  if AQ < 1.0E-4 then AQ := 1.0E-4;

  w0 := DSP_TWO_PI * AFreqHz / FSampleRate;
  cw := Cos(w0);
  sw := Sin(w0);
  alpha := sw / (2.0 * AQ);
  A := Power(10.0, AGainDb / 40.0);

  case AKind of
    bqLowpass:
      begin
        b0 := (1 - cw) / 2; b1 := 1 - cw; b2 := (1 - cw) / 2;
        a0 := 1 + alpha;    a1 := -2 * cw; a2 := 1 - alpha;
      end;
    bqHighpass:
      begin
        b0 := (1 + cw) / 2; b1 := -(1 + cw); b2 := (1 + cw) / 2;
        a0 := 1 + alpha;    a1 := -2 * cw;   a2 := 1 - alpha;
      end;
    bqBandpassSkirt:
      begin
        b0 := AQ * alpha; b1 := 0; b2 := -AQ * alpha;
        a0 := 1 + alpha;  a1 := -2 * cw; a2 := 1 - alpha;
      end;
    bqBandpassPeak:
      begin
        b0 := alpha;      b1 := 0; b2 := -alpha;
        a0 := 1 + alpha;  a1 := -2 * cw; a2 := 1 - alpha;
      end;
    bqNotch:
      begin
        b0 := 1;          b1 := -2 * cw; b2 := 1;
        a0 := 1 + alpha;  a1 := -2 * cw; a2 := 1 - alpha;
      end;
    bqAllpass:
      begin
        b0 := 1 - alpha;  b1 := -2 * cw; b2 := 1 + alpha;
        a0 := 1 + alpha;  a1 := -2 * cw; a2 := 1 - alpha;
      end;
    bqPeaking:
      begin
        b0 := 1 + alpha * A;   b1 := -2 * cw;        b2 := 1 - alpha * A;
        a0 := 1 + alpha / A;   a1 := -2 * cw;        a2 := 1 - alpha / A;
      end;
    bqLowShelf:
      begin
        beta := 2.0 * Sqrt(A) * alpha;
        b0 :=      A * ((A + 1) - (A - 1) * cw + beta);
        b1 :=  2 * A * ((A - 1) - (A + 1) * cw);
        b2 :=      A * ((A + 1) - (A - 1) * cw - beta);
        a0 :=          (A + 1) + (A - 1) * cw + beta;
        a1 :=     -2 * ((A - 1) + (A + 1) * cw);
        a2 :=          (A + 1) + (A - 1) * cw - beta;
      end;
    bqHighShelf:
      begin
        beta := 2.0 * Sqrt(A) * alpha;
        b0 :=      A * ((A + 1) + (A - 1) * cw + beta);
        b1 := -2 * A * ((A - 1) + (A + 1) * cw);
        b2 :=      A * ((A + 1) + (A - 1) * cw - beta);
        a0 :=          (A + 1) - (A - 1) * cw + beta;
        a1 :=      2 * ((A - 1) - (A + 1) * cw);
        a2 :=          (A + 1) - (A - 1) * cw - beta;
      end;
  else
    b0 := 1; b1 := 0; b2 := 0; a0 := 1; a1 := 0; a2 := 0;
  end;

  SetCoeffs(b0, b1, b2, a0, a1, a2);
end;

function TBiquad.ProcessSample(AX: Single): Single;
var
  x, y: Double;
begin
  x := AX;
  y := Fb0 * x + Fz1;
  Fz1 := Fb1 * x - Fa1 * y + Fz2;
  Fz2 := Fb2 * x - Fa2 * y;
  if Abs(Fz1) < DSP_DENORMAL_FLOOR then Fz1 := 0;
  if Abs(Fz2) < DSP_DENORMAL_FLOOR then Fz2 := 0;
  Result := y;
end;

procedure TBiquad.ProcessBlock(ABuf: PSingle; AFrames: Integer);
begin
  ProcessBlockTo(ABuf, ABuf, AFrames);
end;

procedure TBiquad.ProcessBlockTo(ASrc, ADst: PSingle; AFrames: Integer);
var
  i: Integer;
  x, y, z1, z2, b0, b1, b2, a1, a2: Double;
begin
  { coefficients and state live in locals for the whole block }
  b0 := Fb0; b1 := Fb1; b2 := Fb2; a1 := Fa1; a2 := Fa2;
  z1 := Fz1; z2 := Fz2;
  for i := 0 to AFrames - 1 do
  begin
    x := ASrc[i];
    y := b0 * x + z1;
    z1 := b1 * x - a1 * y + z2;
    z2 := b2 * x - a2 * y;
    if Abs(z1) < DSP_DENORMAL_FLOOR then z1 := 0;
    if Abs(z2) < DSP_DENORMAL_FLOOR then z2 := 0;
    ADst[i] := y;
  end;
  Fz1 := z1; Fz2 := z2;
end;

function TBiquad.MagnitudeDb(AFreqHz: Double): Double;
var
  w, cw, sw, c2, s2: Double;
  nr, ni, dr, di, num, den: Double;
begin
  w := DSP_TWO_PI * AFreqHz / FSampleRate;
  cw := FastCos(w);   sw := FastSin(w);
  c2 := FastCos(2 * w); s2 := FastSin(2 * w);
  { z^-1 = e^-jw => real = cos, imag = -sin }
  nr := Fb0 + Fb1 * cw + Fb2 * c2;
  ni :=     - Fb1 * sw - Fb2 * s2;
  dr := 1.0 + Fa1 * cw + Fa2 * c2;
  di :=     - Fa1 * sw - Fa2 * s2;
  num := Sqrt(nr * nr + ni * ni);
  den := Sqrt(dr * dr + di * di);
  if den < 1.0E-30 then den := 1.0E-30;
  Result := FastLinToDb(num / den);
end;

function TBiquad.PhaseDeg(AFreqHz: Double): Double;
var
  w, cw, sw, c2, s2: Double;
  nr, ni, dr, di, pr, pi_: Double;
begin
  w := DSP_TWO_PI * AFreqHz / FSampleRate;
  cw := FastCos(w);   sw := FastSin(w);
  c2 := FastCos(2 * w); s2 := FastSin(2 * w);
  nr := Fb0 + Fb1 * cw + Fb2 * c2;
  ni :=     - Fb1 * sw - Fb2 * s2;
  dr := 1.0 + Fa1 * cw + Fa2 * c2;
  di :=     - Fa1 * sw - Fa2 * s2;
  { (nr+jni)/(dr+jdi) }
  pr := (nr * dr + ni * di) / (dr * dr + di * di);
  pi_ := (ni * dr - nr * di) / (dr * dr + di * di);
  Result := FastArcTan2(pi_, pr) * 180.0 / DSP_PI;
end;

{ ---------------- TBiquadChain ---------------- }

constructor TBiquadChain.Create(ASampleRate: Double; AStages: Integer);
begin
  inherited Create;
  if ASampleRate <= 0 then ASampleRate := UDAW_DEFAULT_SAMPLE_RATE;
  FSampleRate := ASampleRate;
  SetStageCount(AStages);
end;

procedure TBiquadChain.SetStageCount(AStages: Integer);
var
  i, old: Integer;
begin
  if AStages < 1 then AStages := 1;
  old := Length(FStages);
  SetLength(FStages, AStages);
  for i := old to AStages - 1 do
  begin
    FStages[i].Init(FSampleRate);
    FStages[i].Reset;
  end;
end;

procedure TBiquadChain.Reset;
var
  i: Integer;
begin
  for i := 0 to High(FStages) do
    FStages[i].Reset;
end;

function TBiquadChain.Stage(AIndex: Integer): PBiquad;
begin
  if (AIndex < 0) or (AIndex > High(FStages)) then
    RaiseUDAWFmt(errInvalidArgument, DSP_SUBSYS, 'TBiquadChain.Stage: %d out of range', [AIndex]);
  Result := @FStages[AIndex];
end;

procedure TBiquadChain.SetButterworthLowpass(AFreqHz: Double);
var
  n, k: Integer;
  q: Double;
begin
  n := Length(FStages) * 2;   // overall order
  for k := 0 to High(FStages) do
  begin
    { Butterworth pole-pair Q values: 1 / (2 sin( (2k+1)pi / 2n )) }
    q := 1.0 / (2.0 * Sin((2.0 * k + 1.0) * DSP_PI / (2.0 * n)));
    FStages[k].SetParams(bqLowpass, AFreqHz, q);
  end;
end;

procedure TBiquadChain.SetButterworthHighpass(AFreqHz: Double);
var
  n, k: Integer;
  q: Double;
begin
  n := Length(FStages) * 2;
  for k := 0 to High(FStages) do
  begin
    q := 1.0 / (2.0 * Sin((2.0 * k + 1.0) * DSP_PI / (2.0 * n)));
    FStages[k].SetParams(bqHighpass, AFreqHz, q);
  end;
end;

function TBiquadChain.ProcessSample(AX: Single): Single;
var
  i: Integer;
  y: Single;
begin
  y := AX;
  for i := 0 to High(FStages) do
    y := FStages[i].ProcessSample(y);
  Result := y;
end;

procedure TBiquadChain.ProcessBlock(ABuf: PSingle; AFrames: Integer);
var
  i: Integer;
begin
  for i := 0 to High(FStages) do
    FStages[i].ProcessBlock(ABuf, AFrames);
end;

function TBiquadChain.MagnitudeDb(AFreqHz: Double): Double;
var
  i: Integer;
  acc: Double;
begin
  acc := 0;
  for i := 0 to High(FStages) do
    acc := acc + FStages[i].MagnitudeDb(AFreqHz);
  Result := acc;
end;

function TBiquadChain.StageCount: Integer;
begin
  Result := Length(FStages);
end;

{ ---------------- TOnePole ---------------- }

procedure TOnePole.Init(ASampleRate: Double);
begin
  if ASampleRate <= 0 then ASampleRate := UDAW_DEFAULT_SAMPLE_RATE;
  FSampleRate := ASampleRate;
  FA0 := 1; FB1 := 0; FZ := 0; FHP := False;
end;

procedure TOnePole.Reset;
begin
  FZ := 0;
end;

procedure TOnePole.SetCutoff(AKind: TOnePoleKind; AFreqHz: Double);
begin
  if AFreqHz < 0.1 then AFreqHz := 0.1;
  if AFreqHz > FSampleRate * 0.49 then AFreqHz := FSampleRate * 0.49;
  FB1 := Exp(-DSP_TWO_PI * AFreqHz / FSampleRate);
  FA0 := 1.0 - FB1;
  FHP := AKind = opHighpass;
end;

function TOnePole.ProcessSample(AX: Single): Single;
var
  lp: Double;
begin
  FZ := FA0 * AX + FB1 * FZ;
  if Abs(FZ) < DSP_DENORMAL_FLOOR then FZ := 0;
  lp := FZ;
  if FHP then
    Result := AX - lp
  else
    Result := lp;
end;

procedure TOnePole.ProcessBlock(ABuf: PSingle; AFrames: Integer);
var
  i: Integer;
begin
  for i := 0 to AFrames - 1 do
    ABuf[i] := ProcessSample(ABuf[i]);
end;

{ ---------------- TDCBlocker ---------------- }

procedure TDCBlocker.Init(ASampleRate, ACornerHz: Double);
begin
  if ASampleRate <= 0 then ASampleRate := UDAW_DEFAULT_SAMPLE_RATE;
  if ACornerHz < 0.1 then ACornerHz := 0.1;
  { R ~ 1 - (2*pi*fc/Fs) for small fc }
  FR := 1.0 - (DSP_TWO_PI * ACornerHz / ASampleRate);
  if FR < 0 then FR := 0;
  if FR > 0.99999 then FR := 0.99999;
  FX1 := 0; FY1 := 0;
end;

procedure TDCBlocker.Reset;
begin
  FX1 := 0; FY1 := 0;
end;

function TDCBlocker.ProcessSample(AX: Single): Single;
var
  y: Double;
begin
  y := AX - FX1 + FR * FY1;
  FX1 := AX;
  if Abs(y) < DSP_DENORMAL_FLOOR then y := 0;
  FY1 := y;
  Result := y;
end;

procedure TDCBlocker.ProcessBlock(ABuf: PSingle; AFrames: Integer);
var
  i: Integer;
begin
  for i := 0 to AFrames - 1 do
    ABuf[i] := ProcessSample(ABuf[i]);
end;

{ ---------------- TStateVariableFilter (TPT / Zavalishin) ---------------- }

procedure TStateVariableFilter.Init(ASampleRate: Double);
begin
  if ASampleRate <= 0 then ASampleRate := UDAW_DEFAULT_SAMPLE_RATE;
  FSampleRate := ASampleRate;
  Reset;
  SetParams(1000.0, 0.7071);
end;

procedure TStateVariableFilter.Reset;
begin
  Fic1eq := 0;
  Fic2eq := 0;
end;

procedure TStateVariableFilter.SetParams(AFreqHz, AQ: Double);
begin
  if AFreqHz < 1.0 then AFreqHz := 1.0;
  if AFreqHz > FSampleRate * 0.49 then AFreqHz := FSampleRate * 0.49;
  if AQ < 1.0E-3 then AQ := 1.0E-3;
  Fg := Tan(DSP_PI * AFreqHz / FSampleRate);
  Fk := 1.0 / AQ;
  Fa1 := 1.0 / (1.0 + Fg * (Fg + Fk));
  Fa2 := Fg * Fa1;
  Fa3 := Fg * Fa2;
end;

function TStateVariableFilter.ProcessSample(AX: Single): TSVFOutputs;
var
  v0, v1, v2, v3: Double;
begin
  v0 := AX;
  v3 := v0 - Fic2eq;
  v1 := Fa1 * Fic1eq + Fa2 * v3;
  v2 := Fic2eq + Fa2 * Fic1eq + Fa3 * v3;
  Fic1eq := 2.0 * v1 - Fic1eq;
  Fic2eq := 2.0 * v2 - Fic2eq;
  if Abs(Fic1eq) < DSP_DENORMAL_FLOOR then Fic1eq := 0;
  if Abs(Fic2eq) < DSP_DENORMAL_FLOOR then Fic2eq := 0;
  Result.LP := v2;
  Result.BP := v1;
  Result.HP := v0 - Fk * v1 - v2;
  Result.Notch := v0 - Fk * v1;
end;

function TStateVariableFilter.ProcessLowpass(AX: Single): Single;
begin
  Result := ProcessSample(AX).LP;
end;

procedure TStateVariableFilter.ProcessBlockLowpass(ABuf: PSingle; AFrames: Integer);
var
  i: Integer;
begin
  for i := 0 to AFrames - 1 do
    ABuf[i] := ProcessSample(ABuf[i]).LP;
end;

end.
