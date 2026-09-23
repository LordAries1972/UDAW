unit UDAW.DSP.TransientShaper;
{$I udaw.inc}
{$POINTERMATH ON}

{ Phase 34 - classic transient designer: a fast envelope follower and a slow
  one both track the same signal; where the fast envelope sits above the slow
  one the signal is "attacking" (a transient), otherwise it is "sustaining".
  AttackDb/SustainDb apply extra gain (or attenuation) proportional to how
  strongly the current sample falls into each category, smoothed by a short
  AR follower so the applied gain itself does not click. Built on the Phase 3
  TEnvelopeFollower / TAREnvelope. }

interface

uses
  SysUtils, Math,
  UDAW.Audio.Types, UDAW.DSP.Math, UDAW.DSP.Envelope;

type
  TTransientShaper = class
  private
    FSampleRate: Integer;
    FChannels: Integer;
    FAttackDb: Double;     // -20..+20, gain applied to transient portions
    FSustainDb: Double;    // -20..+20, gain applied to sustain portions
    FFast: array of TEnvelopeFollower;
    FSlow: array of TEnvelopeFollower;
    FGainSmooth: array of TAREnvelope;
  public
    constructor Create;
    procedure Configure(ASampleRate, AChannels: Integer);
    procedure Reset;
    procedure SetParams(AAttackDb, ASustainDb: Double);
    procedure ProcessBlock(const AIn, AOut: array of PSingle; AFrames: Integer);
  end;

implementation

constructor TTransientShaper.Create;
begin
  inherited Create;
  FSampleRate := UDAW_DEFAULT_SAMPLE_RATE;
  FChannels := 2;
  FAttackDb := 6.0;
  FSustainDb := 0.0;
end;

procedure TTransientShaper.Configure(ASampleRate, AChannels: Integer);
var
  ch: Integer;
begin
  if ASampleRate > 0 then FSampleRate := ASampleRate;
  if AChannels > 0 then FChannels := AChannels;
  SetLength(FFast, FChannels);
  SetLength(FSlow, FChannels);
  SetLength(FGainSmooth, FChannels);
  for ch := 0 to FChannels - 1 do
  begin
    FFast[ch].Init(FSampleRate);
    FFast[ch].SetTimes(0.3, 8.0);
    FSlow[ch].Init(FSampleRate);
    FSlow[ch].SetTimes(25.0, 400.0);
    FGainSmooth[ch].Init(FSampleRate, 0.5, 5.0);
    FGainSmooth[ch].SetImmediate(1.0);
  end;
  Reset;
end;

procedure TTransientShaper.Reset;
var
  ch: Integer;
begin
  for ch := 0 to High(FFast) do
  begin
    FFast[ch].Reset;
    FSlow[ch].Reset;
    FGainSmooth[ch].SetImmediate(1.0);
  end;
end;

procedure TTransientShaper.SetParams(AAttackDb, ASustainDb: Double);
begin
  if AAttackDb < -20.0 then AAttackDb := -20.0 else if AAttackDb > 20.0 then AAttackDb := 20.0;
  if ASustainDb < -20.0 then ASustainDb := -20.0 else if ASustainDb > 20.0 then ASustainDb := 20.0;
  FAttackDb := AAttackDb;
  FSustainDb := ASustainDb;
end;

procedure TTransientShaper.ProcessBlock(const AIn, AOut: array of PSingle; AFrames: Integer);
var
  i, ch, nc: Integer;
  x, fastEnv, slowEnv, ratio, targetGainDb, g: Double;
begin
  nc := Length(AIn);
  for ch := 0 to nc - 1 do
  begin
    if ch >= Length(FFast) then Break;
    for i := 0 to AFrames - 1 do
    begin
      x := AIn[ch][i];
      fastEnv := FFast[ch].Process(Single(x));
      slowEnv := FSlow[ch].Process(Single(x));
      if slowEnv < 1.0E-6 then slowEnv := 1.0E-6;
      ratio := (fastEnv - slowEnv) / slowEnv;
      if ratio > 0 then
      begin
        if ratio > 1.0 then ratio := 1.0;
        targetGainDb := FAttackDb * ratio;
      end
      else
      begin
        ratio := -ratio;
        if ratio > 1.0 then ratio := 1.0;
        targetGainDb := FSustainDb * ratio;
      end;
      FGainSmooth[ch].SetTarget(DbToLinear(targetGainDb));
      g := FGainSmooth[ch].Process;
      AOut[ch][i] := Single(FlushDenorm(Single(x * g)));
    end;
  end;
end;

end.
