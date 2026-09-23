unit UDAW.DSP.ParametricEQ;
{$I udaw.inc}
{$POINTERMATH ON}

{ Phase 34 - fully parametric multi-band equaliser: PEQ_BAND_COUNT bands, each
  independently switchable between peaking / low-shelf / high-shelf / low-cut
  (highpass) / high-cut (lowpass), with per-band freq/gain/Q. Built entirely
  on the Phase 3 RBJ biquad (UDAW.DSP.Filters) - one cascaded biquad per band
  per channel, same structure as TGraphicEQ. Allocated once in Configure. }

interface

uses
  SysUtils, Math,
  UDAW.Audio.Types, UDAW.DSP.Math, UDAW.DSP.Filters;

const
  PEQ_BAND_COUNT = 6;
  PEQ_MIN_GAIN_DB = -24.0;
  PEQ_MAX_GAIN_DB = 24.0;

type
  TPEQBandType = (peqPeaking, peqLowShelf, peqHighShelf, peqLowCut, peqHighCut);

  TPEQBand = record
    BandType: TPEQBandType;
    Freq: Double;
    GainDb: Double;
    Q: Double;
  end;

  TParametricEQ = class
  private
    FSampleRate: Integer;
    FChannels: Integer;
    FBands: array[0..PEQ_BAND_COUNT - 1] of TPEQBand;
    FBiq: array of array[0..PEQ_BAND_COUNT - 1] of TBiquad;   // [channel][band]
    procedure RecalcBand(ABand: Integer);
  public
    constructor Create;
    procedure Configure(ASampleRate, AChannels: Integer);
    procedure Reset;
    procedure SetBand(AIndex: Integer; AType: TPEQBandType; AFreqHz, AGainDb, AQ: Double);
    function Band(AIndex: Integer): TPEQBand;
    procedure ProcessBlock(const AIn, AOut: array of PSingle; AFrames: Integer);
  end;

function PEQBandTypeId(AType: TPEQBandType): string;
function PEQBandTypeFromId(const AId: string; out AType: TPEQBandType): Boolean;

implementation

function PEQBandTypeId(AType: TPEQBandType): string;
begin
  case AType of
    peqLowShelf:  Result := 'lowshelf';
    peqHighShelf: Result := 'highshelf';
    peqLowCut:    Result := 'lowcut';
    peqHighCut:   Result := 'highcut';
  else
    Result := 'peaking';
  end;
end;

function PEQBandTypeFromId(const AId: string; out AType: TPEQBandType): Boolean;
var
  t: TPEQBandType;
begin
  for t := Low(TPEQBandType) to High(TPEQBandType) do
    if SameText(AId, PEQBandTypeId(t)) then
    begin
      AType := t;
      Exit(True);
    end;
  Result := False;
end;

constructor TParametricEQ.Create;
var
  i: Integer;
const
  DefaultFreqs: array[0..PEQ_BAND_COUNT - 1] of Double =
    (80, 250, 1000, 3000, 6000, 12000);
begin
  inherited Create;
  FSampleRate := UDAW_DEFAULT_SAMPLE_RATE;
  FChannels := 2;
  for i := 0 to PEQ_BAND_COUNT - 1 do
  begin
    FBands[i].BandType := peqPeaking;
    FBands[i].Freq := DefaultFreqs[i];
    FBands[i].GainDb := 0.0;
    FBands[i].Q := 0.7071;
  end;
  FBands[0].BandType := peqLowShelf;
  FBands[PEQ_BAND_COUNT - 1].BandType := peqHighShelf;
end;

procedure TParametricEQ.Configure(ASampleRate, AChannels: Integer);
var
  ch, b: Integer;
begin
  if ASampleRate > 0 then FSampleRate := ASampleRate;
  if AChannels > 0 then FChannels := AChannels;
  SetLength(FBiq, FChannels);
  for ch := 0 to FChannels - 1 do
    for b := 0 to PEQ_BAND_COUNT - 1 do
      FBiq[ch][b].Init(FSampleRate);
  for b := 0 to PEQ_BAND_COUNT - 1 do
    RecalcBand(b);
  Reset;
end;

procedure TParametricEQ.Reset;
var
  ch, b: Integer;
begin
  for ch := 0 to High(FBiq) do
    for b := 0 to PEQ_BAND_COUNT - 1 do
      FBiq[ch][b].Reset;
end;

procedure TParametricEQ.RecalcBand(ABand: Integer);
var
  ch: Integer;
  bqk: TBiquadKind;
  f, q, g: Double;
begin
  if (ABand < 0) or (ABand > High(FBands)) then Exit;
  f := FBands[ABand].Freq;
  if f > FSampleRate * 0.45 then f := FSampleRate * 0.45;
  q := FBands[ABand].Q;
  g := FBands[ABand].GainDb;
  case FBands[ABand].BandType of
    peqLowShelf:  bqk := bqLowShelf;
    peqHighShelf: bqk := bqHighShelf;
    peqLowCut:    bqk := bqHighpass;
    peqHighCut:   bqk := bqLowpass;
  else
    bqk := bqPeaking;
  end;
  for ch := 0 to High(FBiq) do
    FBiq[ch][ABand].SetParams(bqk, f, q, g);
end;

procedure TParametricEQ.SetBand(AIndex: Integer; AType: TPEQBandType; AFreqHz, AGainDb, AQ: Double);
begin
  if (AIndex < 0) or (AIndex > High(FBands)) then Exit;
  if AFreqHz < 10.0 then AFreqHz := 10.0;
  if AGainDb < PEQ_MIN_GAIN_DB then AGainDb := PEQ_MIN_GAIN_DB
  else if AGainDb > PEQ_MAX_GAIN_DB then AGainDb := PEQ_MAX_GAIN_DB;
  if AQ < 0.05 then AQ := 0.05 else if AQ > 24.0 then AQ := 24.0;
  FBands[AIndex].BandType := AType;
  FBands[AIndex].Freq := AFreqHz;
  FBands[AIndex].GainDb := AGainDb;
  FBands[AIndex].Q := AQ;
  RecalcBand(AIndex);
end;

function TParametricEQ.Band(AIndex: Integer): TPEQBand;
begin
  if (AIndex >= 0) and (AIndex <= High(FBands)) then
    Result := FBands[AIndex]
  else
    FillChar(Result, SizeOf(Result), 0);
end;

procedure TParametricEQ.ProcessBlock(const AIn, AOut: array of PSingle; AFrames: Integer);
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
      for b := 0 to PEQ_BAND_COUNT - 1 do
        s := FBiq[ch][b].ProcessSample(Single(s));
      AOut[ch][i] := Single(s);
    end;
  end;
end;

end.
