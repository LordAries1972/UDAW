unit UDAW.DSP.GraphicEQ;
{$I udaw.inc}
{$POINTERMATH ON}

{ Phase 10 - graphic equaliser (plan section 11): a bank of fixed-frequency
  peaking biquads (ISO octave centres), one per band, cascaded per channel.
  Each band's gain is set in dB (-15..+15). Built entirely on the Phase 3
  TBiquad. Allocated once in Configure. }

interface

uses
  SysUtils, Math,
  UDAW.Audio.Types, UDAW.DSP.Math, UDAW.DSP.Filters;

const
  GEQ_MAX_BANDS = 31;
  GEQ_BAND_Q = 4.318;                 { ~1/3-oct-ish for a 10-band octave EQ }
  GEQ_MIN_GAIN_DB = -18.0;
  GEQ_MAX_GAIN_DB =  18.0;

type
  TGraphicEQ = class
  private
    FSampleRate: Integer;
    FChannels: Integer;
    FBandCount: Integer;
    FFreqs: array[0..GEQ_MAX_BANDS - 1] of Double;
    FGains: array[0..GEQ_MAX_BANDS - 1] of Double;
    FBiq: array of array of TBiquad;   // [channel][band]
    procedure BuildFreqs;
    procedure RecalcBand(ABand: Integer);
  public
    constructor Create;
    procedure Configure(ASampleRate, AChannels: Integer);
    procedure Reset;
    procedure SetBandCount(ACount: Integer);
    procedure SetBandGain(ABand: Integer; AGainDb: Double);
    procedure SetAllGains(const AGainsDb: array of Double);
    function BandFreq(ABand: Integer): Double;
    function BandGain(ABand: Integer): Double;
    function BandCount: Integer;
    procedure ProcessBlock(const AIn, AOut: array of PSingle; AFrames: Integer);
  end;

implementation

const
  { 10 ISO octave centres (Hz) - the default; more bands interpolate on 1/3-oct }
  ISO_10: array[0..9] of Double =
    (31.25, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 16000);

constructor TGraphicEQ.Create;
begin
  inherited Create;
  FSampleRate := UDAW_DEFAULT_SAMPLE_RATE;
  FChannels := 2;
  FBandCount := 10;
end;

procedure TGraphicEQ.BuildFreqs;
var
  i: Integer;
  fLo, fHi, r: Double;
begin
  if FBandCount = 10 then
  begin
    for i := 0 to 9 do FFreqs[i] := ISO_10[i];
    Exit;
  end;
  { geometric spread 25 Hz .. 16 kHz for an arbitrary band count }
  fLo := 25.0;
  fHi := 16000.0;
  if FBandCount <= 1 then
  begin
    FFreqs[0] := 1000.0;
    Exit;
  end;
  r := Power(fHi / fLo, 1.0 / (FBandCount - 1));
  for i := 0 to FBandCount - 1 do
    FFreqs[i] := fLo * Power(r, i);
end;

procedure TGraphicEQ.Configure(ASampleRate, AChannels: Integer);
var
  ch, b: Integer;
begin
  if ASampleRate > 0 then FSampleRate := ASampleRate;
  if AChannels > 0 then FChannels := AChannels;
  BuildFreqs;
  SetLength(FBiq, FChannels);
  for ch := 0 to FChannels - 1 do
  begin
    SetLength(FBiq[ch], FBandCount);
    for b := 0 to FBandCount - 1 do
      FBiq[ch][b].Init(FSampleRate);
  end;
  for b := 0 to FBandCount - 1 do
    RecalcBand(b);
  Reset;
end;

procedure TGraphicEQ.Reset;
var
  ch, b: Integer;
begin
  for ch := 0 to High(FBiq) do
    for b := 0 to High(FBiq[ch]) do
      FBiq[ch][b].Reset;
end;

procedure TGraphicEQ.SetBandCount(ACount: Integer);
begin
  if ACount < 1 then ACount := 1 else if ACount > GEQ_MAX_BANDS then ACount := GEQ_MAX_BANDS;
  FBandCount := ACount;
end;

procedure TGraphicEQ.RecalcBand(ABand: Integer);
var
  ch: Integer;
  f: Double;
begin
  if (ABand < 0) or (ABand >= FBandCount) then Exit;
  f := FFreqs[ABand];
  if f > FSampleRate * 0.45 then f := FSampleRate * 0.45;
  for ch := 0 to High(FBiq) do
    if ABand < Length(FBiq[ch]) then
      FBiq[ch][ABand].SetParams(bqPeaking, f, GEQ_BAND_Q, FGains[ABand]);
end;

procedure TGraphicEQ.SetBandGain(ABand: Integer; AGainDb: Double);
begin
  if (ABand < 0) or (ABand >= FBandCount) then Exit;
  if AGainDb < GEQ_MIN_GAIN_DB then AGainDb := GEQ_MIN_GAIN_DB
  else if AGainDb > GEQ_MAX_GAIN_DB then AGainDb := GEQ_MAX_GAIN_DB;
  FGains[ABand] := AGainDb;
  RecalcBand(ABand);
end;

procedure TGraphicEQ.SetAllGains(const AGainsDb: array of Double);
var
  i, n: Integer;
begin
  n := Length(AGainsDb);
  if n > FBandCount then n := FBandCount;
  for i := 0 to n - 1 do
    SetBandGain(i, AGainsDb[i]);
end;

function TGraphicEQ.BandFreq(ABand: Integer): Double;
begin
  if (ABand >= 0) and (ABand < FBandCount) then Result := FFreqs[ABand] else Result := 0;
end;

function TGraphicEQ.BandGain(ABand: Integer): Double;
begin
  if (ABand >= 0) and (ABand < FBandCount) then Result := FGains[ABand] else Result := 0;
end;

function TGraphicEQ.BandCount: Integer;
begin
  Result := FBandCount;
end;

procedure TGraphicEQ.ProcessBlock(const AIn, AOut: array of PSingle; AFrames: Integer);
var
  i, ch, b, nc: Integer;
  s: Double;
begin
  nc := Length(AIn);
  for ch := 0 to nc - 1 do
  begin
    if ch >= Length(FBiq) then Break;
    for i := 0 to AFrames - 1 do
    begin
      s := AIn[ch][i];
      for b := 0 to High(FBiq[ch]) do
        s := FBiq[ch][b].ProcessSample(Single(s));
      AOut[ch][i] := Single(s);
    end;
  end;
end;

end.
