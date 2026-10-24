unit UDAW.DSP.Exciter;
{$I udaw.inc}
{$POINTERMATH ON}

{ Phase 34 - harmonic exciter / enhancer: split off the band above FreqHz
  with the Phase 3 RBJ highpass, saturate that band with the Phase 10 tanh
  shaper (drive), then blend the generated harmonics back in at Mix. The full
  (unfiltered) dry signal always passes through unaltered underneath. }

interface

uses
  SysUtils, Math,
  UDAW.Audio.Types, UDAW.DSP.Math, UDAW.DSP.Filters;

type
  TExciter = class
  private
    FSampleRate: Integer;
    FChannels: Integer;
    FFreqHz: Double;
    FDrive: Double;
    FMix: Double;
    FHP: array of TBiquad;
    FOs: Integer;                                   // 1 = off, 2 / 4 / 8 oversampled shaping
    FUp, FDn: array of array[0..1] of TBiquad;      // [channel] anti-image / anti-alias
    procedure BuildOsFilters;
    function ShapeBand(ACh: Integer; AX: Double): Double;
  public
    constructor Create;
    procedure Configure(ASampleRate, AChannels: Integer);
    procedure Reset;
    procedure SetParams(AFreqHz, ADrive, AMix: Double; AOversample: Integer = 2);
    procedure ProcessBlock(const AIn, AOut: array of PSingle; AFrames: Integer);
  end;

implementation

constructor TExciter.Create;
begin
  inherited Create;
  FSampleRate := UDAW_DEFAULT_SAMPLE_RATE;
  FChannels := 2;
  FFreqHz := 3000.0;
  FDrive := 4.0;
  FMix := 0.25;
  FOs := 2;
end;

procedure TExciter.Configure(ASampleRate, AChannels: Integer);
var
  ch: Integer;
begin
  if ASampleRate > 0 then FSampleRate := ASampleRate;
  if AChannels > 0 then FChannels := AChannels;
  SetLength(FHP, FChannels);
  SetLength(FUp, FChannels);
  SetLength(FDn, FChannels);
  for ch := 0 to FChannels - 1 do
    FHP[ch].Init(FSampleRate);
  BuildOsFilters;
  SetParams(FFreqHz, FDrive, FMix, FOs);
  Reset;
end;

procedure TExciter.BuildOsFilters;
var
  ch, k: Integer;
begin
  if FOs < 2 then Exit;
  for ch := 0 to High(FUp) do
    for k := 0 to 1 do
    begin
      FUp[ch][k].Init(FSampleRate * FOs);
      FDn[ch][k].Init(FSampleRate * FOs);
      { 4th-order Butterworth = two sections, Q 0.5412 and 1.3066 }
      FUp[ch][k].SetParams(bqLowpass, FSampleRate * 0.45, IfThen(k = 0, 0.5412, 1.3066));
      FDn[ch][k].SetParams(bqLowpass, FSampleRate * 0.45, IfThen(k = 0, 0.5412, 1.3066));
    end;
end;

{ the saturator, run at FOs times the sample rate so the harmonics it makes
  above Nyquist are filtered away instead of folding back as aliasing }
function TExciter.ShapeBand(ACh: Integer; AX: Double): Double;
var
  j: Integer;
  u: Double;
begin
  if FOs < 2 then Exit(Tanh(AX * FDrive));
  Result := 0.0;
  for j := 0 to FOs - 1 do
  begin
    if j = 0 then u := FOs * AX else u := 0.0;
    u := FUp[ACh][1].ProcessSample(FUp[ACh][0].ProcessSample(Single(u)));
    Result := FDn[ACh][1].ProcessSample(FDn[ACh][0].ProcessSample(Single(Tanh(u * FDrive))));
  end;
end;

procedure TExciter.Reset;
var
  ch, k: Integer;
begin
  for ch := 0 to High(FHP) do
    FHP[ch].Reset;
  for ch := 0 to High(FUp) do
    for k := 0 to 1 do
    begin
      FUp[ch][k].Reset;
      FDn[ch][k].Reset;
    end;
end;

procedure TExciter.SetParams(AFreqHz, ADrive, AMix: Double; AOversample: Integer);
var
  ch: Integer;
begin
  if AOversample >= 8 then AOversample := 8
  else if AOversample >= 4 then AOversample := 4
  else if AOversample >= 2 then AOversample := 2
  else AOversample := 1;
  if (AOversample <> FOs) and (Length(FUp) > 0) then
  begin
    FOs := AOversample;
    BuildOsFilters;
    Reset;
  end
  else
    FOs := AOversample;
  if AFreqHz < 500.0 then AFreqHz := 500.0;
  if ADrive < 1.0 then ADrive := 1.0;
  if AMix < 0 then AMix := 0 else if AMix > 1.0 then AMix := 1.0;
  FFreqHz := AFreqHz;
  FDrive := ADrive;
  FMix := AMix;
  for ch := 0 to High(FHP) do
    FHP[ch].SetParams(bqHighpass, FFreqHz, 0.7071);
end;

procedure TExciter.ProcessBlock(const AIn, AOut: array of PSingle; AFrames: Integer);
var
  i, ch, nc: Integer;
  x, hi, sh: Double;
begin
  nc := Length(AIn);
  for ch := 0 to nc - 1 do
  begin
    if ch >= Length(FHP) then Break;
    for i := 0 to AFrames - 1 do
    begin
      x := AIn[ch][i];
      hi := FHP[ch].ProcessSample(Single(x));
      sh := ShapeBand(ch, hi);
      AOut[ch][i] := Single(FlushDenorm(Single(x + FMix * sh)));
    end;
  end;
end;

end.
