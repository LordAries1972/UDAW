unit Tests.Phase18;
{$IFDEF FPC}{$MODE DELPHI}{$MODESWITCH ADVANCEDRECORDS}{$H+}{$ENDIF}
{$POINTERMATH ON}

{ Phase 18 acceptance tests - advanced visualization primitives. Verified in
  memory with synthetic signals only, no reference media:

    * TSpectrumAnalyzer locates a synthetic 1 kHz full-scale tone's energy in
      the correct bin, close to 0 dBFS, after the smoothed spectrum settles;
    * TSpectrogramBuffer accumulates history rows with the expected bin count
      and GetRow does not raise for any valid index;
    * TGoniometer's correlation reads near +1 for in-phase L=R and near -1 for
      out-of-phase L=-R, and its point history respects the configured cap;
    * TOscilloscopeCapture in triggered mode captures exactly the configured
      length once a rising edge crosses the trigger level;
    * TBallisticMeter settles near -18 dBFS on a steady -18 dBFS tone for the
      digital-peak and VU presets, and every TMeterBallistics value round
      -trips through MeterBallisticsId / MeterBallisticsFromId.

  Requires src/audio/dsp on the search path. }

interface

procedure RegisterPhase18Tests;

implementation

uses
  UDAW.Testing,
  UDAW.DSP.Visualization,
  UDAW.DSP.Math,
  Math, SysUtils;

const
  GRP = 'phase18.visualization';

{ ---------------- helpers ---------------- }

procedure MakeSine(var ABuf: array of Single; AFreqHz, ASampleRate: Double;
  AAmplitude: Double; APhaseStart: Integer);
var
  i: Integer;
begin
  for i := 0 to High(ABuf) do
    ABuf[i] := Single(AAmplitude * Sin(2.0 * Pi * AFreqHz * (i + APhaseStart) / ASampleRate));
end;

{ ---------------- TSpectrumAnalyzer ---------------- }

procedure Test_SpectrumAnalyzer_LocatesTone;
var
  an: TSpectrumAnalyzer;
  buf: array[0..511] of Single;
  db: array of Double;
  i, bestBin, expectBin, block: Integer;
  bestDb: Double;
const
  SR = 48000;
  FREQ = 1000.0;
begin
  an := TSpectrumAnalyzer.Create;
  try
    an.Configure(SR, 2048);
    { feed several seconds' worth of blocks so the smoothed spectrum settles }
    for block := 0 to 199 do
    begin
      MakeSine(buf, FREQ, SR, 0.99, block * Length(buf));
      an.PushBlock(@buf[0], Length(buf));
    end;

    SetLength(db, an.SpectrumBins);
    an.GetSpectrumDb(db);

    bestBin := 0;
    bestDb := db[0];
    for i := 1 to High(db) do
      if db[i] > bestDb then
      begin
        bestDb := db[i];
        bestBin := i;
      end;

    expectBin := an.HzToBin(FREQ);
    Check(Abs(bestBin - expectBin) <= 1, Format('peak bin %d within 1 of expected %d', [bestBin, expectBin]));
    Check(bestDb > -6.0, Format('peak level %.2f dB close to 0 dBFS', [bestDb]));
  finally
    an.Free;
  end;
end;

{ ---------------- TSpectrogramBuffer ---------------- }

procedure Test_Spectrogram_AccumulatesRows;
var
  sg: TSpectrogramBuffer;
  buf: array[0..1023] of Single;
  row: array of Double;
  block: Integer;
const
  SR = 48000;
begin
  sg := TSpectrogramBuffer.Create;
  try
    sg.Configure(SR, 512, 64);
    Check(sg.BinCount = 257, 'bin count matches FFT size 512 -> 257 bins');
    CheckEqualInt(0, sg.RowCount, 'no rows before any samples pushed');

    for block := 0 to 9 do
    begin
      MakeSine(buf, 440.0, SR, 0.5, block * Length(buf));
      sg.PushBlock(@buf[0], Length(buf));
    end;

    Check(sg.RowCount > 0, 'at least one row appended');
    SetLength(row, sg.BinCount);
    sg.GetRow(0, row);
    sg.GetRow(sg.RowCount - 1, row);
  finally
    sg.Free;
  end;
end;

{ ---------------- TGoniometer ---------------- }

procedure Test_Goniometer_Correlation_InPhase;
var
  g: TGoniometer;
  l, r: array[0..2047] of Single;
  i: Integer;
begin
  g := TGoniometer.Create;
  try
    g.Configure(48000, 512);
    for i := 0 to High(l) do
    begin
      l[i] := Single(0.7 * Sin(2 * Pi * 300.0 * i / 48000));
      r[i] := l[i];
    end;
    g.PushBlock(@l[0], @r[0], Length(l));
    Check(g.Correlation > 0.95, Format('in-phase correlation near +1 (got %.4f)', [g.Correlation]));
    Check(g.PointCount = 512, 'point history capped at configured size');
  finally
    g.Free;
  end;
end;

procedure Test_Goniometer_Correlation_OutOfPhase;
var
  g: TGoniometer;
  l, r: array[0..1023] of Single;
  i: Integer;
begin
  g := TGoniometer.Create;
  try
    g.Configure(48000, 4096);
    for i := 0 to High(l) do
    begin
      l[i] := Single(0.7 * Sin(2 * Pi * 300.0 * i / 48000));
      r[i] := -l[i];
    end;
    g.PushBlock(@l[0], @r[0], Length(l));
    Check(g.Correlation < -0.95, Format('out-of-phase correlation near -1 (got %.4f)', [g.Correlation]));
    CheckEqualInt(Length(l), g.PointCount, 'point count grows with pushed samples below the cap');
  finally
    g.Free;
  end;
end;

{ ---------------- TOscilloscopeCapture ---------------- }

procedure Test_Oscilloscope_Triggered_Capture;
var
  osc: TOscilloscopeCapture;
  buf: array[0..3999] of Single;
  snap: array of Single;
  i, got: Integer;
begin
  osc := TOscilloscopeCapture.Create;
  try
    osc.Configure(48000, 1024);
    osc.TriggerLevel := 0.0;
    osc.SetTriggerMode(True);
    CheckFalse(osc.HasSnapshot, 'no snapshot before any rising edge');

    { a slow sine guarantees at least one clean upward zero-crossing }
    for i := 0 to High(buf) do
      buf[i] := Single(0.8 * Sin(2 * Pi * 50.0 * i / 48000));
    osc.PushBlock(@buf[0], Length(buf));

    Check(osc.HasSnapshot, 'triggered snapshot captured after a rising edge');
    SetLength(snap, 1024);
    got := osc.GetSnapshot(snap);
    CheckEqualInt(1024, got, 'snapshot returns exactly the configured capture length');
  finally
    osc.Free;
  end;
end;

{ ---------------- TBallisticMeter ---------------- }

procedure Test_BallisticMeter_SettlesNear18dBFS;
var
  bm: TBallisticMeter;
  buf: array[0..47999] of Single;
  i: Integer;
const
  SR = 48000;
begin
  { -18 dBFS = amplitude 10^(-18/20) }
  for i := 0 to High(buf) do
    buf[i] := Single(Power(10.0, -18.0 / 20.0) * Sin(2 * Pi * 1000.0 * i / SR));

  bm.Configure(SR, mbDigitalPeak);
  bm.PushBlock(@buf[0], Length(buf));
  Check(Abs(bm.ReadingDb - (-18.0)) < 3.0, Format('digital peak near -18 dBFS (got %.2f)', [bm.ReadingDb]));

  bm.Configure(SR, mbVU);
  bm.PushBlock(@buf[0], Length(buf));
  { RMS of a sine is peak - 3.01 dB, so a -18 dBFS-peak tone reads ~-21 dBFS RMS. }
  Check(Abs(bm.ReadingDb - (-21.0)) < 1.0, Format('VU RMS near -21 dBFS (got %.2f)', [bm.ReadingDb]));
end;

procedure Test_MeterBallistics_IdRoundTrip;
var
  b, back: TMeterBallistics;
begin
  for b := Low(TMeterBallistics) to High(TMeterBallistics) do
  begin
    Check(MeterBallisticsFromId(MeterBallisticsId(b), back), 'id parses back: ' + MeterBallisticsId(b));
    Check(back = b, 'round-tripped ballistics preset matches: ' + MeterBallisticsId(b));
  end;
  Check(not MeterBallisticsFromId('nonsense', back), 'unknown id is rejected');
end;

procedure RegisterPhase18Tests;
begin
  RegisterTest(GRP, 'spectrum analyzer locates a 1 kHz tone near 0 dBFS', Test_SpectrumAnalyzer_LocatesTone);
  RegisterTest(GRP, 'spectrogram buffer accumulates rows with the right bin count', Test_Spectrogram_AccumulatesRows);
  RegisterTest(GRP, 'goniometer correlation near +1 for in-phase L=R', Test_Goniometer_Correlation_InPhase);
  RegisterTest(GRP, 'goniometer correlation near -1 for out-of-phase L=-R', Test_Goniometer_Correlation_OutOfPhase);
  RegisterTest(GRP, 'triggered oscilloscope captures exactly the configured length', Test_Oscilloscope_Triggered_Capture);
  RegisterTest(GRP, 'ballistic meter settles near -18 dBFS (peak + VU)', Test_BallisticMeter_SettlesNear18dBFS);
  RegisterTest(GRP, 'meter ballistics id round-trip', Test_MeterBallistics_IdRoundTrip);
end;

end.
