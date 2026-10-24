unit UDAW.DSP.MathTables;
{$I udaw.inc}

{ Precalculated mathematics. Every transcendental the runtime needs on a hot
  path (sin/cos, 2^x, log2, dB<->linear, pow, atan2, tan, MIDI/semitone ratios)
  is answered from tables generated once, at startup (the splash step
  "Generating Precalculated Maths"), instead of being recomputed per sample,
  per pixel or per bin.

  Accuracy (all far below the 24-bit noise floor of -144 dBFS):
    FastSin / FastCos        |err| <= 2.0E-8   (16384-point table, linear interp)
    FastExp2 / FastExp       rel err <= 1.0E-9 (8192-point table, linear interp)
    FastLog2 / Ln / Log10    abs err <= 3.0E-9 (8192-point mantissa table)
    FastArcTan2              abs err <= 5.0E-9 rad (4096-point table)
    SemitoneRatioInt, MidiKeyHz   exact (generated with the RTL)

  Square roots are intentionally NOT tabulated: SQRTSD is a single hardware
  instruction and beats any table lookup.

  Tables are read-only after generation, so every function is thread-safe
  (audio thread, UI thread, worker threads). Functions self-initialise if the
  tables were not generated explicitly (tests, tools), so the unit can never
  be used uninitialised. Other units can add their own tables to the startup
  step with RegisterPrecalcBuilder (call it from the unit's initialization). }

interface

uses
  SysUtils, SyncObjs, Math;

const
  MT_SIN_BITS  = 14;
  MT_SIN_SIZE  = 1 shl MT_SIN_BITS;      // 16384
  MT_SIN_MASK  = MT_SIN_SIZE - 1;
  MT_EXP_BITS  = 13;
  MT_EXP_SIZE  = 1 shl MT_EXP_BITS;      // 8192
  MT_LOG_BITS  = 13;
  MT_LOG_SIZE  = 1 shl MT_LOG_BITS;      // 8192
  MT_ATAN_BITS = 12;
  MT_ATAN_SIZE = 1 shl MT_ATAN_BITS;     // 4096

  MT_STATUS_TEXT = 'Generating Precalculated Maths';

  MT_SEMI_MIN  = -240;                   // +-20 octaves of exact semitone ratios
  MT_SEMI_MAX  = 240;

  MT_TWO_PI     = 6.28318530717958647693;
  MT_INV_TWO_PI = 0.15915494309189533577;
  MT_HALF_PI    = 1.57079632679489661923;
  MT_PI         = 3.14159265358979323846;
  MT_LN2        = 0.69314718055994530942;
  MT_LOG2E      = 1.44269504088896340736;
  MT_LOG10_2    = 0.30102999566398119521;
  MT_DB_PER_LOG2 = 6.02059991327962390427;          // 20*log10(2)
  MT_LOG2_PER_DB = 0.16609640474436811739;          // log2(10)/20

type
  TMathTablesProgress = procedure(const AStep: string; ADone, ATotal: Integer) of object;
  TPrecalcBuilder = procedure;

var
  { Public so the inline functions below can reach them. Treat as read-only. }
  MT_Ready: Boolean = False;
  MT_Sin:  array[0..MT_SIN_SIZE] of Double;      // sin(2*pi*i/N), [N]=[0]
  MT_Exp2: array[0..MT_EXP_SIZE] of Double;      // 2^(i/N)
  MT_Log2: array[0..MT_LOG_SIZE] of Double;      // log2(1+i/N)
  MT_Atan: array[0..MT_ATAN_SIZE] of Double;     // atan(i/N), i/N in 0..1
  MT_Semi: array[MT_SEMI_MIN..MT_SEMI_MAX] of Double;   // 2^(n/12)
  MT_MidiHz: array[0..127] of Double;            // 440*2^((k-69)/12)

{ Generates every table (idempotent) and runs the registered extra builders.
  AProgress (optional) is called once per table group so the splash bar and
  status text move. Safe to call from any thread, once. }
procedure GeneratePrecalcMathTables(AProgress: TMathTablesProgress = nil);

{ Extra tables owned by other units; the builder runs inside
  GeneratePrecalcMathTables (or immediately if generation already happened). }
procedure RegisterPrecalcBuilder(const AName: string; ABuilder: TPrecalcBuilder);

function PrecalcMathReady: Boolean;

{ ---- trigonometry ---- }
function FastSinTurns(APhase: Double): Double;       // sin(2*pi*APhase), any real APhase
function FastCosTurns(APhase: Double): Double;
function FastSin(ARad: Double): Double;
function FastCos(ARad: Double): Double;
function FastTan(ARad: Double): Double;
function FastArcTan2(AY, AX: Double): Double;
function FastArcTan(AX: Double): Double;

{ ---- exponentials / logarithms ---- }
function FastExp2(AX: Double): Double;
function FastExp(AX: Double): Double;
function FastExp10(AX: Double): Double;              // 10^AX
function FastLog2(AX: Double): Double;               // AX <= 0 clamps to a very small positive
function FastLn(AX: Double): Double;
function FastLog10(AX: Double): Double;
function FastPow(ABase, AExp: Double): Double;       // ABase <= 0 -> 0 (1 when AExp = 0)

{ ---- decibels ---- }
function FastDbToLin(ADb: Double): Double;           // 10^(dB/20)
function FastLinToDb(ALin: Double): Double;          // 20*log10(lin)
function FastPowerToDb(APower: Double): Double;      // 10*log10(power)
function FastDbToPower(ADb: Double): Double;         // 10^(dB/10)

{ ---- pitch ---- }
function SemitoneRatio(ASemis: Double): Double;      // 2^(semis/12)
function SemitoneRatioInt(ASemis: Integer): Double;  // exact table
function CentsRatio(ACents: Double): Double;         // 2^(cents/1200)
function MidiKeyHz(AKey: Integer): Double;           // exact table, 0..127 (clamped)
function MidiNoteToHz(ANote: Double): Double;        // fractional note numbers

implementation

type
  TBuilderRec = record
    Name: string;
    Proc: TPrecalcBuilder;
  end;

var
  GBuilders: array of TBuilderRec;
  GGenerated: Boolean = False;
  GGenerating: Boolean = False;
  GLock: TCriticalSection;

procedure BuildCoreTables(AProgress: TMathTablesProgress; AExtra: Integer);
const
  STEPS = 6;
var
  i, total: Integer;
begin
  total := STEPS + AExtra;

  if Assigned(AProgress) then AProgress(MT_STATUS_TEXT, 0, total);
  for i := 0 to MT_SIN_SIZE - 1 do
    MT_Sin[i] := System.Sin(MT_TWO_PI * i / MT_SIN_SIZE);
  MT_Sin[MT_SIN_SIZE] := MT_Sin[0];
  { exact landmarks so quadrant values (0, 1, 0, -1) are exact }
  MT_Sin[0] := 0.0;
  MT_Sin[MT_SIN_SIZE div 4] := 1.0;
  MT_Sin[MT_SIN_SIZE div 2] := 0.0;
  MT_Sin[(MT_SIN_SIZE div 4) * 3] := -1.0;
  MT_Sin[MT_SIN_SIZE] := 0.0;

  if Assigned(AProgress) then AProgress(MT_STATUS_TEXT, 1, total);
  for i := 0 to MT_EXP_SIZE - 1 do
    MT_Exp2[i] := System.Exp(MT_LN2 * i / MT_EXP_SIZE);
  MT_Exp2[0] := 1.0;
  MT_Exp2[MT_EXP_SIZE] := 2.0;

  if Assigned(AProgress) then AProgress(MT_STATUS_TEXT, 2, total);
  for i := 0 to MT_LOG_SIZE - 1 do
    MT_Log2[i] := System.Ln(1.0 + i / MT_LOG_SIZE) * MT_LOG2E;
  MT_Log2[0] := 0.0;
  MT_Log2[MT_LOG_SIZE] := 1.0;

  if Assigned(AProgress) then AProgress(MT_STATUS_TEXT, 3, total);
  for i := 0 to MT_ATAN_SIZE do
    MT_Atan[i] := System.ArcTan(i / MT_ATAN_SIZE);
  MT_Atan[0] := 0.0;
  MT_Atan[MT_ATAN_SIZE] := MT_PI / 4.0;

  if Assigned(AProgress) then AProgress(MT_STATUS_TEXT, 4, total);
  for i := MT_SEMI_MIN to MT_SEMI_MAX do
    MT_Semi[i] := Power(2.0, i / 12.0);
  MT_Semi[0] := 1.0;

  if Assigned(AProgress) then AProgress(MT_STATUS_TEXT, 5, total);
  for i := 0 to 127 do
    MT_MidiHz[i] := 440.0 * Power(2.0, (i - 69) / 12.0);
  MT_MidiHz[69] := 440.0;

  MT_Ready := True;
end;

procedure GeneratePrecalcMathTables(AProgress: TMathTablesProgress);
var
  i, n: Integer;
begin
  GLock.Enter;
  try
    if GGenerated or GGenerating then Exit;
    GGenerating := True;
    try
      n := Length(GBuilders);
      BuildCoreTables(AProgress, n);
      for i := 0 to n - 1 do
      begin
        if Assigned(AProgress) then
          AProgress(MT_STATUS_TEXT, 6 + i, 6 + n);
        GBuilders[i].Proc();
      end;
      if Assigned(AProgress) then
        AProgress(MT_STATUS_TEXT, 6 + n, 6 + n);
      GGenerated := True;
    finally
      GGenerating := False;
    end;
  finally
    GLock.Leave;
  end;
end;

procedure RegisterPrecalcBuilder(const AName: string; ABuilder: TPrecalcBuilder);
var
  n: Integer;
begin
  GLock.Enter;
  try
    n := Length(GBuilders);
    SetLength(GBuilders, n + 1);
    GBuilders[n].Name := AName;
    GBuilders[n].Proc := ABuilder;
    if GGenerated then ABuilder();   // late registration: build straight away
  finally
    GLock.Leave;
  end;
end;

procedure EnsureTables;
begin
  if not MT_Ready then GeneratePrecalcMathTables(nil);
end;

function PrecalcMathReady: Boolean;
begin
  Result := MT_Ready;
end;

{ ---------------- trigonometry ---------------- }

function FastSinTurns(APhase: Double): Double;
var
  x, f: Double;
  i: Int64;
  k: Integer;
begin
  if not MT_Ready then EnsureTables;
  x := APhase * MT_SIN_SIZE;
  i := Trunc(x);
  f := x - i;
  if f < 0.0 then
  begin
    f := f + 1.0;
    Dec(i);
  end;
  k := Integer(i and MT_SIN_MASK);
  Result := MT_Sin[k] + (MT_Sin[k + 1] - MT_Sin[k]) * f;
end;

function FastCosTurns(APhase: Double): Double;
begin
  Result := FastSinTurns(APhase + 0.25);
end;

function FastSin(ARad: Double): Double;
begin
  Result := FastSinTurns(ARad * MT_INV_TWO_PI);
end;

function FastCos(ARad: Double): Double;
begin
  Result := FastSinTurns(ARad * MT_INV_TWO_PI + 0.25);
end;

function FastTan(ARad: Double): Double;
var
  s, c: Double;
begin
  s := FastSinTurns(ARad * MT_INV_TWO_PI);
  c := FastSinTurns(ARad * MT_INV_TWO_PI + 0.25);
  if Abs(c) < 1.0E-300 then
    c := 1.0E-300;
  Result := s / c;
end;

function AtanUnit(AT: Double): Double;   // atan(AT), AT in 0..1
var
  x, f: Double;
  k: Integer;
begin
  x := AT * MT_ATAN_SIZE;
  k := Trunc(x);
  if k >= MT_ATAN_SIZE then Exit(MT_Atan[MT_ATAN_SIZE]);
  f := x - k;
  Result := MT_Atan[k] + (MT_Atan[k + 1] - MT_Atan[k]) * f;
end;

function FastArcTan2(AY, AX: Double): Double;
var
  ax_, ay_, a: Double;
begin
  if not MT_Ready then EnsureTables;
  ax_ := Abs(AX);
  ay_ := Abs(AY);
  if (ax_ = 0.0) and (ay_ = 0.0) then Exit(0.0);
  if ay_ <= ax_ then
    a := AtanUnit(ay_ / ax_)
  else
    a := MT_HALF_PI - AtanUnit(ax_ / ay_);
  if AX < 0.0 then a := MT_PI - a;
  if AY < 0.0 then a := -a;
  Result := a;
end;

function FastArcTan(AX: Double): Double;
begin
  Result := FastArcTan2(AX, 1.0);
end;

{ ---------------- exponentials / logarithms ---------------- }

function FastExp2(AX: Double): Double;
var
  fl: Int64;
  f, fi, r: Double;
  i: Integer;
  bits: Int64;
begin
  if not MT_Ready then EnsureTables;
  if AX < -1022.0 then AX := -1022.0
  else if AX > 1023.0 then AX := 1023.0;
  fl := Trunc(AX);
  f := AX - fl;
  if f < 0.0 then
  begin
    f := f + 1.0;
    Dec(fl);
  end;
  fi := f * MT_EXP_SIZE;
  i := Trunc(fi);
  if i >= MT_EXP_SIZE then i := MT_EXP_SIZE - 1;
  r := MT_Exp2[i] + (MT_Exp2[i + 1] - MT_Exp2[i]) * (fi - i);
  bits := (fl + 1023) shl 52;               // 2^fl built directly in the exponent field
  Result := r * PDouble(@bits)^;
end;

function FastExp(AX: Double): Double;
begin
  Result := FastExp2(AX * MT_LOG2E);
end;

function FastExp10(AX: Double): Double;
begin
  Result := FastExp2(AX * 3.32192809488736234787);
end;

function FastLog2(AX: Double): Double;
var
  bits: Int64;
  e: Integer;
  m, f: Double;
  idx: Integer;
begin
  if not MT_Ready then EnsureTables;
  if AX < 1.0E-300 then AX := 1.0E-300;
  bits := PInt64(@AX)^;
  e := Integer((bits shr 52) and $7FF) - 1023;
  idx := Integer((bits shr (52 - MT_LOG_BITS)) and (MT_LOG_SIZE - 1));
  f := (bits and ((Int64(1) shl (52 - MT_LOG_BITS)) - 1)) / (Int64(1) shl (52 - MT_LOG_BITS));
  m := MT_Log2[idx] + (MT_Log2[idx + 1] - MT_Log2[idx]) * f;
  Result := e + m;
end;

function FastLn(AX: Double): Double;
begin
  Result := FastLog2(AX) * MT_LN2;
end;

function FastLog10(AX: Double): Double;
begin
  Result := FastLog2(AX) * MT_LOG10_2;
end;

function FastPow(ABase, AExp: Double): Double;
begin
  if ABase <= 0.0 then
  begin
    if AExp = 0.0 then Result := 1.0 else Result := 0.0;
    Exit;
  end;
  Result := FastExp2(AExp * FastLog2(ABase));
end;

{ ---------------- decibels ---------------- }

function FastDbToLin(ADb: Double): Double;
begin
  Result := FastExp2(ADb * MT_LOG2_PER_DB);
end;

function FastLinToDb(ALin: Double): Double;
begin
  Result := FastLog2(ALin) * MT_DB_PER_LOG2;
end;

function FastPowerToDb(APower: Double): Double;
begin
  Result := FastLog2(APower) * (MT_DB_PER_LOG2 * 0.5);
end;

function FastDbToPower(ADb: Double): Double;
begin
  Result := FastExp2(ADb * (MT_LOG2_PER_DB * 2.0));
end;

{ ---------------- pitch ---------------- }

function SemitoneRatio(ASemis: Double): Double;
var
  i: Integer;
begin
  if not MT_Ready then EnsureTables;
  if (ASemis >= MT_SEMI_MIN) and (ASemis <= MT_SEMI_MAX) then
  begin
    i := Trunc(ASemis);
    if i = ASemis then Exit(MT_Semi[i]);   // whole semitones are exact
  end;
  Result := FastExp2(ASemis * (1.0 / 12.0));
end;

function SemitoneRatioInt(ASemis: Integer): Double;
begin
  if not MT_Ready then EnsureTables;
  if (ASemis >= MT_SEMI_MIN) and (ASemis <= MT_SEMI_MAX) then
    Result := MT_Semi[ASemis]
  else
    Result := FastExp2(ASemis * (1.0 / 12.0));
end;

function CentsRatio(ACents: Double): Double;
begin
  Result := FastExp2(ACents * (1.0 / 1200.0));
end;

function MidiKeyHz(AKey: Integer): Double;
begin
  if not MT_Ready then EnsureTables;
  if AKey < 0 then AKey := 0 else if AKey > 127 then AKey := 127;
  Result := MT_MidiHz[AKey];
end;

function MidiNoteToHz(ANote: Double): Double;
begin
  Result := 440.0 * SemitoneRatio(ANote - 69.0);
end;

initialization
  GLock := TCriticalSection.Create;

finalization
  FreeAndNil(GLock);

end.
