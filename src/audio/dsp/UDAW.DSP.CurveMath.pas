unit UDAW.DSP.CurveMath;
{$I udaw.inc}

{ Curve data for the effect editors: the frequency response of the EQ / filter
  inserts and the input-to-output transfer curve of the dynamics inserts, both
  computed from the same "key=value;key=value" parameter strings the DSP nodes
  use, so what the editor draws is what the node does.  UI-free. }

interface

type
  TCurveKind = (ckNone, ckFrequency, ckTransfer);

{ Which display (if any) an insert kind has. }
function CurveKindFor(const AKind: string): TCurveKind;

{ Magnitude response in dB at AFreqHz (frequency curves). }
function EqResponseDb(const AKind, AParams: string; AFreqHz: Double;
  ASampleRate: Integer = 48000): Double;

{ Output level in dB for an input level of AInDb (transfer curves). }
function TransferOutDb(const AKind, AParams: string; AInDb: Double): Double;

implementation

uses
  SysUtils, Math, UDAW.DSP.Dynamics, UDAW.DSP.MathTables;

function KV(const AParams, AKey: string; ADef: Double): Double;
var
  part: string;
  p: Integer;
begin
  Result := ADef;
  for part in AParams.Split([';']) do
  begin
    p := Pos('=', part);
    if (p > 0) and SameText(Trim(Copy(part, 1, p - 1)), AKey) then
      Exit(StrToFloatDef(Trim(Copy(part, p + 1, MaxInt)), ADef, TFormatSettings.Invariant));
  end;
end;

function KVS(const AParams, AKey, ADef: string): string;
var
  part: string;
  p: Integer;
begin
  Result := ADef;
  for part in AParams.Split([';']) do
  begin
    p := Pos('=', part);
    if (p > 0) and SameText(Trim(Copy(part, 1, p - 1)), AKey) then
      Exit(Trim(Copy(part, p + 1, MaxInt)));
  end;
end;

function CurveKindFor(const AKind: string): TCurveKind;
begin
  if SameText(AKind, 'biquad') or SameText(AKind, 'parametriceq') or
     SameText(AKind, 'graphiceq') or SameText(AKind, 'dcblock') then
    Result := ckFrequency
  else if SameText(AKind, 'compressor') or SameText(AKind, 'lookaheadlimiter') then
    Result := ckTransfer
  else
    Result := ckNone;
end;

{ RBJ cookbook biquad magnitude (dB) of one section.  AType: lowpass, highpass,
  bandpass, notch, allpass, peaking, lowshelf, highshelf. }
function SectionDb(const AType: string; AFs, AFreq, AQ, AGainDb, AAt: Double): Double;
var
  w0, cs, sn, alpha, a, sq, b0, b1, b2, a0, a1, a2, w, num, den, c1, c2: Double;
begin
  if AFreq > AFs * 0.45 then AFreq := AFs * 0.45;
  if AFreq < 1 then AFreq := 1;
  if AQ < 0.05 then AQ := 0.05;
  w0 := 2 * Pi * AFreq / AFs;
  cs := FastCos(w0);
  sn := FastSin(w0);
  alpha := sn / (2 * AQ);
  a := FastExp10(AGainDb / 40);
  if SameText(AType, 'highpass') then
  begin
    b0 := (1 + cs) / 2; b1 := -(1 + cs); b2 := (1 + cs) / 2;
    a0 := 1 + alpha; a1 := -2 * cs; a2 := 1 - alpha;
  end
  else if SameText(AType, 'bpskirt') or SameText(AType, 'bppeak') or SameText(AType, 'bandpass') then
  begin
    b0 := alpha; b1 := 0; b2 := -alpha;
    a0 := 1 + alpha; a1 := -2 * cs; a2 := 1 - alpha;
  end
  else if SameText(AType, 'notch') then
  begin
    b0 := 1; b1 := -2 * cs; b2 := 1;
    a0 := 1 + alpha; a1 := -2 * cs; a2 := 1 - alpha;
  end
  else if SameText(AType, 'allpass') then
  begin
    b0 := 1 - alpha; b1 := -2 * cs; b2 := 1 + alpha;
    a0 := 1 + alpha; a1 := -2 * cs; a2 := 1 - alpha;
  end
  else if SameText(AType, 'peaking') then
  begin
    b0 := 1 + alpha * a; b1 := -2 * cs; b2 := 1 - alpha * a;
    a0 := 1 + alpha / a; a1 := -2 * cs; a2 := 1 - alpha / a;
  end
  else if SameText(AType, 'lowshelf') then
  begin
    sq := 2 * Sqrt(a) * alpha;
    b0 := a * ((a + 1) - (a - 1) * cs + sq);
    b1 := 2 * a * ((a - 1) - (a + 1) * cs);
    b2 := a * ((a + 1) - (a - 1) * cs - sq);
    a0 := (a + 1) + (a - 1) * cs + sq;
    a1 := -2 * ((a - 1) + (a + 1) * cs);
    a2 := (a + 1) + (a - 1) * cs - sq;
  end
  else if SameText(AType, 'highshelf') then
  begin
    sq := 2 * Sqrt(a) * alpha;
    b0 := a * ((a + 1) + (a - 1) * cs + sq);
    b1 := -2 * a * ((a - 1) + (a + 1) * cs);
    b2 := a * ((a + 1) + (a - 1) * cs - sq);
    a0 := (a + 1) - (a - 1) * cs + sq;
    a1 := 2 * ((a - 1) - (a + 1) * cs);
    a2 := (a + 1) - (a - 1) * cs - sq;
  end
  else
  begin
    { lowpass }
    b0 := (1 - cs) / 2; b1 := 1 - cs; b2 := (1 - cs) / 2;
    a0 := 1 + alpha; a1 := -2 * cs; a2 := 1 - alpha;
  end;
  b0 := b0 / a0; b1 := b1 / a0; b2 := b2 / a0;
  a1 := a1 / a0; a2 := a2 / a0;
  w := 2 * Pi * AAt / AFs;
  c1 := FastCos(w);
  c2 := FastCos(2 * w);
  num := b0 * b0 + b1 * b1 + b2 * b2 + 2 * (b0 * b1 + b1 * b2) * c1 + 2 * b0 * b2 * c2;
  den := 1 + a1 * a1 + a2 * a2 + 2 * (a1 + a1 * a2) * c1 + 2 * a2 * c2;
  if (num <= 1E-30) or (den <= 1E-30) then Exit(-120);
  Result := 10 * FastLog10(num / den);
end;

function EqResponseDb(const AKind, AParams: string; AFreqHz: Double; ASampleRate: Integer): Double;
const
  ISO: array[0..9] of Double = (31.25, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 16000);
  PEQ_DEF: array[0..5] of Double = (80, 250, 1000, 3000, 6000, 12000);
var
  fs: Double;
  i, n: Integer;
  t, gains: string;
  parts: TArray<string>;
  g, fc: Double;
begin
  fs := ASampleRate;
  Result := 0;
  if SameText(AKind, 'biquad') then
    Result := SectionDb(KVS(AParams, 'type', 'lowpass'), fs, KV(AParams, 'freq', 1000),
      KV(AParams, 'q', 0.707), KV(AParams, 'gaindb', 0), AFreqHz)
  else if SameText(AKind, 'dcblock') then
    Result := SectionDb('highpass', fs, KV(AParams, 'hz', 20), 0.5, 0, AFreqHz)
  else if SameText(AKind, 'parametriceq') then
  begin
    for i := 0 to 5 do
    begin
      if i = 0 then t := 'lowshelf' else if i = 5 then t := 'highshelf' else t := 'peaking';
      t := KVS(AParams, Format('b%dtype', [i]), t);
      if SameText(t, 'lowcut') then t := 'highpass'
      else if SameText(t, 'highcut') then t := 'lowpass';
      Result := Result + SectionDb(t, fs, KV(AParams, Format('b%dfreq', [i]), PEQ_DEF[i]),
        KV(AParams, Format('b%dq', [i]), 0.707), KV(AParams, Format('b%dgain', [i]), 0), AFreqHz);
    end;
  end
  else if SameText(AKind, 'graphiceq') then
  begin
    n := Round(KV(AParams, 'bands', 10));
    gains := KVS(AParams, 'gains', '');
    parts := gains.Split([',']);
    for i := 0 to High(parts) do
    begin
      g := StrToFloatDef(Trim(parts[i]), 0, TFormatSettings.Invariant);
      if g = 0 then Continue;
      if n = 10 then fc := ISO[Min(i, 9)]
      else fc := 25 * FastPow(16000 / 25, i / Max(1, n - 1));
      Result := Result + SectionDb('peaking', fs, fc, 1.4, g, AFreqHz);
    end;
  end;
end;

function TransferOutDb(const AKind, AParams: string; AInDb: Double): Double;
var
  proc: TDynamicsProcessor;
  mode: TDynamicsMode;
begin
  if SameText(AKind, 'lookaheadlimiter') then
    Exit(Min(AInDb, KV(AParams, 'ceiling', -0.3)));
  if not DynamicsModeFromId(KVS(AParams, 'type', 'compressor'), mode) then mode := dynCompressor;
  proc := TDynamicsProcessor.Create;
  try
    proc.Configure(48000, 2);
    proc.SetParams(mode, KV(AParams, 'thresh', -18), KV(AParams, 'ratio', 3), KV(AParams, 'knee', 6),
      KV(AParams, 'attack', 10), KV(AParams, 'release', 120), KV(AParams, 'makeup', 0));
    proc.SetGateParams(KV(AParams, 'hold', 20), KV(AParams, 'range', -60));
    Result := proc.StaticTransferDb(AInDb);
  finally
    proc.Free;
  end;
end;

end.
