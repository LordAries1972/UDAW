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
  public
    constructor Create;
    procedure Configure(ASampleRate, AChannels: Integer);
    procedure Reset;
    procedure SetParams(AFreqHz, ADrive, AMix: Double);
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
end;

procedure TExciter.Configure(ASampleRate, AChannels: Integer);
var
  ch: Integer;
begin
  if ASampleRate > 0 then FSampleRate := ASampleRate;
  if AChannels > 0 then FChannels := AChannels;
  SetLength(FHP, FChannels);
  for ch := 0 to FChannels - 1 do
    FHP[ch].Init(FSampleRate);
  SetParams(FFreqHz, FDrive, FMix);
  Reset;
end;

procedure TExciter.Reset;
var
  ch: Integer;
begin
  for ch := 0 to High(FHP) do
    FHP[ch].Reset;
end;

procedure TExciter.SetParams(AFreqHz, ADrive, AMix: Double);
var
  ch: Integer;
begin
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
      sh := Tanh(hi * FDrive);
      AOut[ch][i] := Single(FlushDenorm(Single(x + FMix * sh)));
    end;
  end;
end;

end.
