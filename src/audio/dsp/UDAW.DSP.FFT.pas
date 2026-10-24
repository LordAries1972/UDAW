unit UDAW.DSP.FFT;
{$I udaw.inc}
{$POINTERMATH ON}

{ Phase 3 - internal radix-2 FFT. No third-party code.

  TFFT is created for a fixed power-of-two size and precomputes its bit-reversal
  permutation and twiddle factors, so a transform is allocation-free and can run
  on a worker thread repeatedly (spectrum analyser, convolution, pitch, true-peak
  oversampling). Complex data is held as separate real/imag Double arrays.

    ForwardInPlace / InverseInPlace  - full complex transform, size N
    RealForward                      - N real samples -> N/2+1 complex bins
    RealInverse                      - N/2+1 bins -> N real samples
    MagnitudeSpectrum / PowerSpectrumDb / PhaseSpectrum - analysis helpers

  InverseInPlace is normalised by 1/N so Forward then Inverse is the identity. }

interface

uses
  SysUtils, Math,
  UDAW.Errors, UDAW.DSP.Math;

type
  TFFT = class
  private
    FSize: Integer;
    FLogN: Integer;
    FBitRev: array of Integer;
    FCosT: array of Double;   // twiddle cos, length FSize div 2
    FSinT: array of Double;
    procedure Transform(var ARe, AIm: array of Double; AInverse: Boolean);
  public
    constructor Create(ASize: Integer);
    { In-place complex transform. Both arrays must be at least Size long. }
    procedure ForwardInPlace(var ARe, AIm: array of Double);
    procedure InverseInPlace(var ARe, AIm: array of Double);

    { ATime: Size real samples. AOutRe/AOutIm: at least Size div 2 + 1. }
    procedure RealForward(const ATime: array of Single;
      var AOutRe, AOutIm: array of Double);
    { Inverse of RealForward. AInRe/AInIm length Size div 2 + 1; AOutTime Size. }
    procedure RealInverse(const AInRe, AInIm: array of Double;
      var AOutTime: array of Single);

    { |X[k]| for k in 0..Size div 2, from a RealForward result. }
    procedure MagnitudeSpectrum(const ARe, AIm: array of Double;
      var AMag: array of Double);
    { 20*log10(|X[k]| / (Size/2)) with a floor, i.e. dBFS per bin. }
    procedure PowerSpectrumDb(const ARe, AIm: array of Double;
      var ADb: array of Double; AFloorDb: Double = -180.0);
    procedure PhaseSpectrum(const ARe, AIm: array of Double;
      var APhase: array of Double);

    { Convenience: window ATime, RealForward, return dBFS magnitude corrected for
      the window's coherent gain. AWork buffers are resized as needed. }
    procedure AnalyzeDb(const ATime: array of Single; AWindow: TWindowKind;
      var ADb: array of Double);

    function BinToHz(ABin: Integer; ASampleRate: Double): Double;
    function HzToBin(AHz, ASampleRate: Double): Integer;

    property Size: Integer read FSize;
    { number of one-sided spectrum bins produced by RealForward (Size div 2 + 1) }
    function SpectrumBins: Integer;
  end;

implementation


uses
  UDAW.DSP.MathTables;

constructor TFFT.Create(ASize: Integer);
var
  i, j, rev, bit: Integer;
  ang: Double;
begin
  inherited Create;
  if not IsPow2(ASize) or (ASize < 2) then
    RaiseUDAWFmt(errInvalidArgument, DSP_SUBSYS,
      'TFFT: size %d is not a power of two >= 2', [ASize]);
  FSize := ASize;
  FLogN := IntLog2(ASize);

  SetLength(FBitRev, FSize);
  for i := 0 to FSize - 1 do
  begin
    rev := 0;
    j := i;
    for bit := 0 to FLogN - 1 do
    begin
      rev := (rev shl 1) or (j and 1);
      j := j shr 1;
    end;
    FBitRev[i] := rev;
  end;

  SetLength(FCosT, FSize shr 1);
  SetLength(FSinT, FSize shr 1);
  for i := 0 to (FSize shr 1) - 1 do
  begin
    ang := -DSP_TWO_PI * i / FSize;   // forward sign
    FCosT[i] := Cos(ang);
    FSinT[i] := Sin(ang);
  end;
end;

procedure TFFT.Transform(var ARe, AIm: array of Double; AInverse: Boolean);
var
  i, j, k, len, half, step, tw, n: Integer;
  ur, ui, tr, ti, sgn, invn: Double;
  pr, pim, qr, qi: PDouble;      // butterfly top/bottom row pointers
  br: PInteger;
  cosT, sinT: PDouble;
begin
  if (Length(ARe) < FSize) or (Length(AIm) < FSize) then
    RaiseUDAW(errInvalidArgument, DSP_SUBSYS, 'TFFT.Transform: array shorter than Size');

  n := FSize;
  br := @FBitRev[0];

  { bit-reversal permutation }
  for i := 0 to n - 1 do
  begin
    j := br[i];
    if j > i then
    begin
      tr := ARe[i]; ARe[i] := ARe[j]; ARe[j] := tr;
      ti := AIm[i]; AIm[i] := AIm[j]; AIm[j] := ti;
    end;
  end;

  if AInverse then sgn := -1.0 else sgn := 1.0;
  cosT := @FCosT[0];
  sinT := @FSinT[0];

  { stage len=2: twiddle is exactly 1, so no multiplies }
  pr := @ARe[0];
  pim := @AIm[0];
  i := 0;
  while i < n do
  begin
    tr := pr[1];
    ti := pim[1];
    pr[1] := pr[0] - tr;
    pim[1] := pim[0] - ti;
    pr[0] := pr[0] + tr;
    pim[0] := pim[0] + ti;
    Inc(pr, 2);
    Inc(pim, 2);
    Inc(i, 2);
  end;

  len := 4;
  while len <= n do
  begin
    half := len shr 1;        // len is a power of two
    step := n div len;
    i := 0;
    while i < n do
    begin
      pr := @ARe[i];
      pim := @AIm[i];
      qr := pr + half;
      qi := pim + half;
      tw := 0;
      for k := 0 to half - 1 do
      begin
        ur := cosT[tw];
        ui := sgn * sinT[tw];
        tr := ur * qr[k] - ui * qi[k];
        ti := ur * qi[k] + ui * qr[k];
        qr[k] := pr[k] - tr;
        qi[k] := pim[k] - ti;
        pr[k] := pr[k] + tr;
        pim[k] := pim[k] + ti;
        Inc(tw, step);
      end;
      Inc(i, len);
    end;
    len := len shl 1;
  end;

  if AInverse then
  begin
    invn := 1.0 / n;
    pr := @ARe[0];
    pim := @AIm[0];
    for i := 0 to n - 1 do
    begin
      pr[i] := pr[i] * invn;
      pim[i] := pim[i] * invn;
    end;
  end;
end;

procedure TFFT.ForwardInPlace(var ARe, AIm: array of Double);
begin
  Transform(ARe, AIm, False);
end;

procedure TFFT.InverseInPlace(var ARe, AIm: array of Double);
begin
  Transform(ARe, AIm, True);
end;

procedure TFFT.RealForward(const ATime: array of Single;
  var AOutRe, AOutIm: array of Double);
var
  re, im: array of Double;
  i, nb: Integer;
begin
  if Length(ATime) < FSize then
    RaiseUDAW(errInvalidArgument, DSP_SUBSYS, 'TFFT.RealForward: time array shorter than Size');
  nb := (FSize shr 1) + 1;
  if (Length(AOutRe) < nb) or (Length(AOutIm) < nb) then
    RaiseUDAW(errInvalidArgument, DSP_SUBSYS, 'TFFT.RealForward: output arrays too small');

  SetLength(re, FSize);
  SetLength(im, FSize);
  for i := 0 to FSize - 1 do
  begin
    re[i] := ATime[i];
    im[i] := 0;
  end;
  Transform(re, im, False);
  for i := 0 to nb - 1 do
  begin
    AOutRe[i] := re[i];
    AOutIm[i] := im[i];
  end;
end;

procedure TFFT.RealInverse(const AInRe, AInIm: array of Double;
  var AOutTime: array of Single);
var
  re, im: array of Double;
  i, nb: Integer;
begin
  nb := (FSize shr 1) + 1;
  if (Length(AInRe) < nb) or (Length(AInIm) < nb) then
    RaiseUDAW(errInvalidArgument, DSP_SUBSYS, 'TFFT.RealInverse: input arrays too small');
  if Length(AOutTime) < FSize then
    RaiseUDAW(errInvalidArgument, DSP_SUBSYS, 'TFFT.RealInverse: output shorter than Size');

  SetLength(re, FSize);
  SetLength(im, FSize);
  { rebuild the conjugate-symmetric upper half }
  for i := 0 to nb - 1 do
  begin
    re[i] := AInRe[i];
    im[i] := AInIm[i];
  end;
  for i := nb to FSize - 1 do
  begin
    re[i] := AInRe[FSize - i];
    im[i] := -AInIm[FSize - i];
  end;
  Transform(re, im, True);
  for i := 0 to FSize - 1 do
    AOutTime[i] := re[i];
end;

procedure TFFT.MagnitudeSpectrum(const ARe, AIm: array of Double;
  var AMag: array of Double);
var
  i, nb: Integer;
begin
  nb := (FSize shr 1) + 1;
  for i := 0 to nb - 1 do
    AMag[i] := Sqrt(ARe[i] * ARe[i] + AIm[i] * AIm[i]);
end;

procedure TFFT.PowerSpectrumDb(const ARe, AIm: array of Double;
  var ADb: array of Double; AFloorDb: Double);
var
  i, nb: Integer;
  m, ref: Double;
begin
  nb := (FSize shr 1) + 1;
  ref := FSize * 0.5;
  for i := 0 to nb - 1 do
  begin
    m := Sqrt(ARe[i] * ARe[i] + AIm[i] * AIm[i]) / ref;
    if m <= 0 then
      ADb[i] := AFloorDb
    else
    begin
      ADb[i] := 20.0 * FastLog10(m);
      if ADb[i] < AFloorDb then ADb[i] := AFloorDb;
    end;
  end;
end;

procedure TFFT.PhaseSpectrum(const ARe, AIm: array of Double;
  var APhase: array of Double);
var
  i, nb: Integer;
begin
  nb := (FSize shr 1) + 1;
  for i := 0 to nb - 1 do
    APhase[i] := FastArcTan2(AIm[i], ARe[i]);
end;

procedure TFFT.AnalyzeDb(const ATime: array of Single; AWindow: TWindowKind;
  var ADb: array of Double);
var
  wnd, re, im: array of Double;
  windowed: array of Single;
  i, nb: Integer;
  cg, m, ref: Double;
begin
  nb := (FSize shr 1) + 1;
  if Length(ADb) < nb then
    RaiseUDAW(errInvalidArgument, DSP_SUBSYS, 'TFFT.AnalyzeDb: output too small');
  SetLength(windowed, FSize);
  SetLength(wnd, FSize);
  cg := 0;
  for i := 0 to FSize - 1 do
  begin
    wnd[i] := WindowValue(AWindow, i, FSize);
    cg := cg + wnd[i];
  end;
  cg := cg / FSize;   // coherent gain
  if cg <= 0 then cg := 1;
  for i := 0 to FSize - 1 do
    windowed[i] := ATime[i] * wnd[i];

  SetLength(re, nb);
  SetLength(im, nb);
  RealForward(windowed, re, im);

  ref := (FSize * 0.5) * cg;
  for i := 0 to nb - 1 do
  begin
    m := Sqrt(re[i] * re[i] + im[i] * im[i]) / ref;
    if m <= 1.0E-12 then
      ADb[i] := -240.0
    else
      ADb[i] := 20.0 * FastLog10(m);
  end;
end;

function TFFT.BinToHz(ABin: Integer; ASampleRate: Double): Double;
begin
  Result := ABin * ASampleRate / FSize;
end;

function TFFT.HzToBin(AHz, ASampleRate: Double): Integer;
begin
  Result := Round(AHz * FSize / ASampleRate);
  if Result < 0 then Result := 0;
  if Result > (FSize shr 1) then Result := FSize shr 1;
end;

function TFFT.SpectrumBins: Integer;
begin
  Result := (FSize shr 1) + 1;
end;

end.
