unit UDAW.DSP.Visualization;
{$I udaw.inc}
{$POINTERMATH ON}

{ Phase 18 - advanced visualization primitives (plan section, "Advanced
  Visualization"): a spectrum analyzer, a scrolling spectrogram history, a
  stereo goniometer / correlation tracker, a triggered oscilloscope capture,
  and a set of classic level-meter ballistics presets.

  Everything here is analysis-only (no signal is altered); all spectral work
  goes through the Phase 3 TFFT and all peak / RMS / correlation math reuses
  the Phase 3 TPeakMeter / TRmsMeter / TCorrelationMeter records so the
  numbers agree with the rest of the DAW. Nothing allocates once Configure has
  run - PushBlock / Push paths are plain array and record writes. }

interface

uses
  SysUtils, Math,
  UDAW.Audio.Types, UDAW.DSP.Math, UDAW.DSP.FFT, UDAW.DSP.Meter;

type
  { ---------------- spectrum analyzer ---------------- }

  TSpectrumAnalyzer = class
  private
    FFFT: TFFT;
    FSampleRate: Integer;
    FFFTSize: Integer;
    FHop: Integer;
    FBins: Integer;
    FRing: array of Single;        // circular input buffer, length FFTSize
    FRingHead: Integer;            // next write slot; also the oldest sample
    FSamplesTotal: Int64;
    FHopCounter: Integer;
    FAnalysisBuf: array of Single; // scratch, linear oldest->newest order
    FRawDb: array of Double;
    FSmoothDb: array of Double;
    FPeakMeters: array of TPeakMeter;
    FAttackMs, FReleaseMs: Double;
    FAttackCoef, FReleaseCoef: Double;
    procedure RecalcBallistics;
    procedure DoAnalysis;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Configure(ASampleRate, AFFTSize: Integer);
    procedure SetBallistics(AAttackMs, AReleaseMs: Double);
    procedure PushBlock(ABuf: PSingle; AFrames: Integer);
    procedure GetSpectrumDb(var ADb: array of Double);
    procedure GetPeakDb(var ADb: array of Double);
    function BinToHz(ABin: Integer): Double;
    function HzToBin(AHz: Double): Integer;
    procedure Reset;
    property SpectrumBins: Integer read FBins;
  end;

  { ---------------- spectrogram history ---------------- }

  TSpectrogramBuffer = class
  private
    FAnalyzer: TSpectrumAnalyzer;
    FRows: array of array of Single;   // [row][bin], circular by FHead
    FTempRow: array of Double;
    FDepth: Integer;
    FBins: Integer;
    FHopSize: Integer;
    FSampleCounter: Integer;
    FHead: Integer;   // next row to write
    FCount: Integer;  // valid rows, <= FDepth
    procedure AppendRow;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Configure(ASampleRate, AFFTSize: Integer; AHistoryRows: Integer = 256);
    procedure PushBlock(ABuf: PSingle; AFrames: Integer);
    procedure GetRow(AIndex: Integer; var ADb: array of Double);
    procedure Clear;
    property RowCount: Integer read FCount;
    property BinCount: Integer read FBins;
  end;

  { ---------------- goniometer / correlation ---------------- }

  TGoniometer = class
  private
    FCorr: TCorrelationMeter;
    FPointsX, FPointsY: array of Single;
    FCapacity: Integer;
    FHead: Integer;
    FCount: Integer;
  public
    procedure Configure(ASampleRate: Integer; AHistoryPoints: Integer = 2048);
    procedure PushBlock(AL, AR: PSingle; AFrames: Integer);
    procedure GetPoint(AIndex: Integer; out AX, AY: Single);
    procedure Reset;
    function Correlation: Double;
    { crude width proxy, not a physical measurement - see comment in body }
    function WidthEstimate: Double;
    property PointCount: Integer read FCount;
  end;

  { ---------------- triggered oscilloscope ---------------- }

  TOscilloscopeCapture = class
  private
    FSampleRate: Integer;
    FCaptureLen: Integer;
    FTriggerMode: Boolean;
    FTriggerLevel: Single;
    FSnapshot: array of Single;
    FHasSnapshot: Boolean;
    FCaptureBuf: array of Single;
    FCapturePos: Integer;    // -1 = not mid-capture
    FArmed: Boolean;
    FPrevSample: Single;
    FFreeRunRing: array of Single;
    FFreeRunHead: Integer;
    FFreeRunTotal: Int64;
    procedure ResetCaptureState;
  public
    procedure Configure(ASampleRate: Integer; ACaptureLenSamples: Integer = 2048);
    procedure SetTriggerMode(AEnabled: Boolean);
    procedure PushBlock(ABuf: PSingle; AFrames: Integer);
    function GetSnapshot(var ABuf: array of Single): Integer;
    procedure Rearm;
    procedure Reset;
    function HasSnapshot: Boolean;
    property TriggerLevel: Single read FTriggerLevel write FTriggerLevel;
  end;

  { ---------------- ballistics-preset level meter ---------------- }

  TMeterBallistics = (mbVU, mbPpmType1, mbPpmType2, mbK12, mbK14, mbK20, mbDigitalPeak);

  TBallisticMeter = record
  private
    FSampleRate: Double;
    FPreset: TMeterBallistics;
    FRms: TRmsMeter;
    FPeak: TPeakMeter;
    function UsesRms: Boolean;
  public
    procedure Configure(ASampleRate: Double; APreset: TMeterBallistics);
    procedure Push(AX: Single); {$IFDEF FPC}inline;{$ENDIF}
    procedure PushBlock(ABuf: PSingle; AFrames: Integer);
    procedure Reset;
    function ReadingDb: Double;       // plain dBFS, independent of the preset's scale
    function ReadingScale01: Double;  // 0..1 bar position per the preset's display convention
    property Preset: TMeterBallistics read FPreset;
  end;

function MeterBallisticsId(ABallistics: TMeterBallistics): string;
function MeterBallisticsFromId(const AId: string; out ABallistics: TMeterBallistics): Boolean;

implementation

function MeterBallisticsId(ABallistics: TMeterBallistics): string;
begin
  case ABallistics of
    mbPpmType1:   Result := 'ppm1';
    mbPpmType2:   Result := 'ppm2';
    mbK12:        Result := 'k12';
    mbK14:        Result := 'k14';
    mbK20:        Result := 'k20';
    mbDigitalPeak: Result := 'peak';
  else
    Result := 'vu';
  end;
end;

function MeterBallisticsFromId(const AId: string; out ABallistics: TMeterBallistics): Boolean;
var
  b: TMeterBallistics;
begin
  for b := Low(TMeterBallistics) to High(TMeterBallistics) do
    if SameText(AId, MeterBallisticsId(b)) then
    begin
      ABallistics := b;
      Exit(True);
    end;
  Result := False;
end;

{ ================= TSpectrumAnalyzer ================= }

constructor TSpectrumAnalyzer.Create;
begin
  inherited Create;
  FFFT := nil;
  Configure(UDAW_DEFAULT_SAMPLE_RATE, 2048);
end;

destructor TSpectrumAnalyzer.Destroy;
begin
  FreeAndNil(FFFT);
  inherited Destroy;
end;

procedure TSpectrumAnalyzer.Configure(ASampleRate, AFFTSize: Integer);
var
  i: Integer;
  hopRate: Double;
begin
  if ASampleRate <= 0 then ASampleRate := UDAW_DEFAULT_SAMPLE_RATE;
  if not IsPow2(AFFTSize) or (AFFTSize < 64) then AFFTSize := NextPow2(Max(64, AFFTSize));

  FreeAndNil(FFFT);
  FFFT := TFFT.Create(AFFTSize);
  FSampleRate := ASampleRate;
  FFFTSize := AFFTSize;
  FHop := Max(1, AFFTSize div 4);
  FBins := FFFT.SpectrumBins;

  SetLength(FRing, FFFTSize);
  SetLength(FAnalysisBuf, FFFTSize);
  SetLength(FRawDb, FBins);
  SetLength(FSmoothDb, FBins);
  SetLength(FPeakMeters, FBins);

  { the per-bin peak-hold ticks once per hop, so give it a "sample rate" of
    the hop rate rather than the audio sample rate - its dB/s ballistics
    then decay in real seconds regardless of FFT size / overlap. }
  hopRate := FSampleRate / FHop;
  for i := 0 to FBins - 1 do
    FPeakMeters[i].Init(hopRate, 20.0, 1500.0, 10.0);

  if (FAttackMs <= 0) and (FReleaseMs <= 0) then
  begin
    FAttackMs := 10.0;
    FReleaseMs := 200.0;
  end;
  SetBallistics(FAttackMs, FReleaseMs);
  Reset;
end;

procedure TSpectrumAnalyzer.RecalcBallistics;
var
  hopRate: Double;
begin
  hopRate := FSampleRate / FHop;
  if FAttackMs <= 0 then
    FAttackCoef := 0
  else
    FAttackCoef := Exp(-1.0 / (FAttackMs * 0.001 * hopRate));
  if FReleaseMs <= 0 then
    FReleaseCoef := 0
  else
    FReleaseCoef := Exp(-1.0 / (FReleaseMs * 0.001 * hopRate));
end;

procedure TSpectrumAnalyzer.SetBallistics(AAttackMs, AReleaseMs: Double);
begin
  FAttackMs := Max(0.0, AAttackMs);
  FReleaseMs := Max(0.0, AReleaseMs);
  RecalcBallistics;
end;

procedure TSpectrumAnalyzer.Reset;
var
  i: Integer;
begin
  for i := 0 to High(FRing) do FRing[i] := 0;
  FRingHead := 0;
  FSamplesTotal := 0;
  FHopCounter := 0;
  for i := 0 to FBins - 1 do
  begin
    FRawDb[i] := -240.0;
    FSmoothDb[i] := -240.0;
    FPeakMeters[i].Reset;
  end;
end;

procedure TSpectrumAnalyzer.DoAnalysis;
var
  i, idx: Integer;
begin
  for i := 0 to FFFTSize - 1 do
  begin
    idx := (FRingHead + i) mod FFFTSize;
    FAnalysisBuf[i] := FRing[idx];
  end;

  FFFT.AnalyzeDb(FAnalysisBuf, wkHann, FRawDb);

  for i := 0 to FBins - 1 do
  begin
    if FRawDb[i] > FSmoothDb[i] then
      FSmoothDb[i] := FRawDb[i] + (FSmoothDb[i] - FRawDb[i]) * FAttackCoef
    else
      FSmoothDb[i] := FRawDb[i] + (FSmoothDb[i] - FRawDb[i]) * FReleaseCoef;
    FPeakMeters[i].Push(Single(DbToLinear(FRawDb[i])));
  end;
end;

procedure TSpectrumAnalyzer.PushBlock(ABuf: PSingle; AFrames: Integer);
var
  i: Integer;
begin
  for i := 0 to AFrames - 1 do
  begin
    FRing[FRingHead] := ABuf[i];
    FRingHead := (FRingHead + 1) mod FFFTSize;
    Inc(FSamplesTotal);
    Inc(FHopCounter);
    if FHopCounter >= FHop then
    begin
      FHopCounter := 0;
      if FSamplesTotal >= FFFTSize then
        DoAnalysis;
    end;
  end;
end;

procedure TSpectrumAnalyzer.GetSpectrumDb(var ADb: array of Double);
var
  i, n: Integer;
begin
  n := Min(Length(ADb), FBins);
  for i := 0 to n - 1 do
    ADb[i] := FSmoothDb[i];
end;

procedure TSpectrumAnalyzer.GetPeakDb(var ADb: array of Double);
var
  i, n: Integer;
begin
  n := Min(Length(ADb), FBins);
  for i := 0 to n - 1 do
    ADb[i] := FPeakMeters[i].HoldDb;
end;

function TSpectrumAnalyzer.BinToHz(ABin: Integer): Double;
begin
  Result := FFFT.BinToHz(ABin, FSampleRate);
end;

function TSpectrumAnalyzer.HzToBin(AHz: Double): Integer;
begin
  Result := FFFT.HzToBin(AHz, FSampleRate);
end;

{ ================= TSpectrogramBuffer ================= }

constructor TSpectrogramBuffer.Create;
begin
  inherited Create;
  FAnalyzer := TSpectrumAnalyzer.Create;
  Configure(UDAW_DEFAULT_SAMPLE_RATE, 2048, 256);
end;

destructor TSpectrogramBuffer.Destroy;
begin
  FreeAndNil(FAnalyzer);
  inherited Destroy;
end;

procedure TSpectrogramBuffer.Configure(ASampleRate, AFFTSize: Integer; AHistoryRows: Integer);
var
  r: Integer;
begin
  FAnalyzer.Configure(ASampleRate, AFFTSize);
  FBins := FAnalyzer.SpectrumBins;
  FDepth := Max(1, AHistoryRows);
  FHopSize := Max(1, AFFTSize div 4);

  SetLength(FRows, FDepth);
  for r := 0 to FDepth - 1 do
    SetLength(FRows[r], FBins);
  SetLength(FTempRow, FBins);

  Clear;
end;

procedure TSpectrogramBuffer.AppendRow;
var
  b: Integer;
begin
  FAnalyzer.GetSpectrumDb(FTempRow);
  for b := 0 to FBins - 1 do
    FRows[FHead][b] := Single(FTempRow[b]);
  FHead := (FHead + 1) mod FDepth;
  if FCount < FDepth then Inc(FCount);
end;

procedure TSpectrogramBuffer.PushBlock(ABuf: PSingle; AFrames: Integer);
var
  i: Integer;
begin
  for i := 0 to AFrames - 1 do
  begin
    FAnalyzer.PushBlock(@ABuf[i], 1);
    Inc(FSampleCounter);
    if FSampleCounter >= FHopSize then
    begin
      FSampleCounter := 0;
      AppendRow;
    end;
  end;
end;

procedure TSpectrogramBuffer.GetRow(AIndex: Integer; var ADb: array of Double);
var
  oldest, physical, b, n: Integer;
begin
  if (FCount = 0) or (AIndex < 0) or (AIndex >= FCount) then
  begin
    for b := 0 to High(ADb) do ADb[b] := -240.0;
    Exit;
  end;
  if FCount < FDepth then
    oldest := 0
  else
    oldest := FHead;
  physical := (oldest + AIndex) mod FDepth;
  n := Min(Length(ADb), FBins);
  for b := 0 to n - 1 do
    ADb[b] := FRows[physical][b];
end;

procedure TSpectrogramBuffer.Clear;
begin
  FHead := 0;
  FCount := 0;
  FSampleCounter := 0;
  FAnalyzer.Reset;
end;

{ ================= TGoniometer ================= }

procedure TGoniometer.Configure(ASampleRate: Integer; AHistoryPoints: Integer);
begin
  FCorr.Init(ASampleRate);
  FCapacity := Max(1, AHistoryPoints);
  SetLength(FPointsX, FCapacity);
  SetLength(FPointsY, FCapacity);
  Reset;
end;

procedure TGoniometer.PushBlock(AL, AR: PSingle; AFrames: Integer);
var
  i: Integer;
  l, r: Single;
const
  ROT = 0.70710678; // 1/sqrt(2), the standard mid/side goniometer rotation
begin
  FCorr.PushBlock(AL, AR, AFrames);
  for i := 0 to AFrames - 1 do
  begin
    l := AL[i];
    r := AR[i];
    FPointsX[FHead] := (l - r) * ROT;
    FPointsY[FHead] := (l + r) * ROT;
    FHead := (FHead + 1) mod FCapacity;
    if FCount < FCapacity then Inc(FCount);
  end;
end;

procedure TGoniometer.GetPoint(AIndex: Integer; out AX, AY: Single);
var
  oldest, physical: Integer;
begin
  AX := 0; AY := 0;
  if (FCount = 0) or (AIndex < 0) or (AIndex >= FCount) then Exit;
  if FCount < FCapacity then
    oldest := 0
  else
    oldest := FHead;
  physical := (oldest + AIndex) mod FCapacity;
  AX := FPointsX[physical];
  AY := FPointsY[physical];
end;

procedure TGoniometer.Reset;
begin
  FHead := 0;
  FCount := 0;
  FCorr.Reset;
end;

function TGoniometer.Correlation: Double;
begin
  Result := FCorr.Value;
end;

function TGoniometer.WidthEstimate: Double;
begin
  { crude UI proxy, not a physical stereo-width measurement: fully correlated
    (mono, +1) -> 0 width, fully anti-correlated (-1) -> 1 width. }
  Result := (1.0 - Correlation) * 0.5;
  if Result < 0 then Result := 0 else if Result > 1 then Result := 1;
end;

{ ================= TOscilloscopeCapture ================= }

procedure TOscilloscopeCapture.Configure(ASampleRate: Integer; ACaptureLenSamples: Integer);
begin
  if ASampleRate <= 0 then ASampleRate := UDAW_DEFAULT_SAMPLE_RATE;
  FSampleRate := ASampleRate;
  FCaptureLen := Max(1, ACaptureLenSamples);
  SetLength(FSnapshot, FCaptureLen);
  SetLength(FCaptureBuf, FCaptureLen);
  SetLength(FFreeRunRing, FCaptureLen);
  FTriggerLevel := 0.0;
  FTriggerMode := False;
  Reset;
end;

procedure TOscilloscopeCapture.ResetCaptureState;
begin
  FCapturePos := -1;
  FArmed := True;
  FHasSnapshot := False;
  FPrevSample := 0;
end;

procedure TOscilloscopeCapture.SetTriggerMode(AEnabled: Boolean);
begin
  FTriggerMode := AEnabled;
  ResetCaptureState;
end;

procedure TOscilloscopeCapture.Reset;
var
  i: Integer;
begin
  for i := 0 to High(FSnapshot) do FSnapshot[i] := 0;
  for i := 0 to High(FCaptureBuf) do FCaptureBuf[i] := 0;
  for i := 0 to High(FFreeRunRing) do FFreeRunRing[i] := 0;
  FFreeRunHead := 0;
  FFreeRunTotal := 0;
  ResetCaptureState;
end;

procedure TOscilloscopeCapture.Rearm;
begin
  FCapturePos := -1;
  FArmed := True;
end;

procedure TOscilloscopeCapture.PushBlock(ABuf: PSingle; AFrames: Integer);
var
  i: Integer;
  cur: Single;
begin
  if not FTriggerMode then
  begin
    for i := 0 to AFrames - 1 do
    begin
      FFreeRunRing[FFreeRunHead] := ABuf[i];
      FFreeRunHead := (FFreeRunHead + 1) mod FCaptureLen;
      if FFreeRunTotal < FCaptureLen then Inc(FFreeRunTotal);
    end;
    Exit;
  end;

  for i := 0 to AFrames - 1 do
  begin
    cur := ABuf[i];
    if (FCapturePos < 0) and FArmed and (FPrevSample < FTriggerLevel) and (cur >= FTriggerLevel) then
      FCapturePos := 0;   // rising edge found: start (or, if CaptureLen=1, finish) the capture

    if FCapturePos >= 0 then
    begin
      FCaptureBuf[FCapturePos] := cur;
      Inc(FCapturePos);
      if FCapturePos >= FCaptureLen then
      begin
        Move(FCaptureBuf[0], FSnapshot[0], FCaptureLen * SizeOf(Single));
        FHasSnapshot := True;
        FCapturePos := -1;
        FArmed := False;
      end;
    end;
    FPrevSample := cur;
  end;
end;

function TOscilloscopeCapture.GetSnapshot(var ABuf: array of Single): Integer;
var
  i, n, idx: Integer;
begin
  n := Min(Length(ABuf), FCaptureLen);
  if not FTriggerMode then
  begin
    for i := 0 to n - 1 do
    begin
      idx := ((FFreeRunHead - n + i) mod FCaptureLen + FCaptureLen) mod FCaptureLen;
      ABuf[i] := FFreeRunRing[idx];
    end;
    Result := n;
    Exit;
  end;

  if not FHasSnapshot then Exit(0);
  Move(FSnapshot[0], ABuf[0], n * SizeOf(Single));
  Result := n;
end;

function TOscilloscopeCapture.HasSnapshot: Boolean;
begin
  if FTriggerMode then
    Result := FHasSnapshot
  else
    Result := True;   // free-run: a rolling snapshot is always available
end;

{ ================= TBallisticMeter ================= }

function TBallisticMeter.UsesRms: Boolean;
begin
  Result := FPreset in [mbVU, mbK12, mbK14, mbK20];
end;

procedure TBallisticMeter.Configure(ASampleRate: Double; APreset: TMeterBallistics);
begin
  FSampleRate := ASampleRate;
  FPreset := APreset;
  case APreset of
    mbVU:
      FRms.Init(ASampleRate, 300.0);
    mbK12, mbK14, mbK20:
      FRms.Init(ASampleRate, 300.0);
    mbPpmType1:
      FPeak.Init(ASampleRate, 24.0, 1500.0, 10.0);   // BBC-ish PPM: ~24 dB/s fall
    mbPpmType2:
      FPeak.Init(ASampleRate, 20.0, 1500.0, 10.0);   // slightly slower fall
  else
    FPeak.Init(ASampleRate, 20.0, 1500.0, 10.0);      // mbDigitalPeak: plain peak
  end;
  Reset;
end;

procedure TBallisticMeter.Reset;
begin
  FRms.Reset;
  FPeak.Reset;
end;

procedure TBallisticMeter.Push(AX: Single);
begin
  if UsesRms then
    FRms.Push(AX)
  else
    FPeak.Push(AX);
end;

procedure TBallisticMeter.PushBlock(ABuf: PSingle; AFrames: Integer);
begin
  if UsesRms then
    FRms.PushBlock(ABuf, AFrames)
  else
    FPeak.PushBlock(ABuf, AFrames);
end;

function TBallisticMeter.ReadingDb: Double;
begin
  if UsesRms then
    Result := FRms.ValueDb
  else
    Result := FPeak.ValueDb;
end;

function TBallisticMeter.ReadingScale01: Double;
var
  db, rel: Double;
begin
  db := ReadingDb;
  case FPreset of
    mbVU:
      begin
        { 0 VU = -18 dBFS; display span -20..+3 VU }
        rel := db - (-18.0);
        Result := (rel - (-20.0)) / (3.0 - (-20.0));
      end;
    mbPpmType1, mbPpmType2:
      begin
        { 0 dB mark = -18 dBFS; display span -40..+6 dB relative to that mark }
        rel := db - (-18.0);
        Result := (rel - (-40.0)) / (6.0 - (-40.0));
      end;
    mbK12:
      begin
        rel := db - (-12.0);
        Result := (rel - (-40.0)) / (0.0 - (-40.0));
      end;
    mbK14:
      begin
        rel := db - (-14.0);
        Result := (rel - (-40.0)) / (0.0 - (-40.0));
      end;
    mbK20:
      begin
        rel := db - (-20.0);
        Result := (rel - (-40.0)) / (0.0 - (-40.0));
      end;
  else
    { mbDigitalPeak: plain dBFS, display span -60..0 }
    Result := (db - (-60.0)) / (0.0 - (-60.0));
  end;
  if Result < 0 then Result := 0 else if Result > 1 then Result := 1;
end;

end.
