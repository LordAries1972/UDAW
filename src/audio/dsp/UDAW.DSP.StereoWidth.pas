unit UDAW.DSP.StereoWidth;
{$I udaw.inc}
{$POINTERMATH ON}

{ Phase 34 - stereo widener/imager insert: mid/side encode, scale the side
  channel by Width (0 = mono .. 1 = unchanged .. 2 = extra wide), decode back
  to L/R. Same M/S math as TMasteringChain's internal width stage, exposed
  here as a standalone general-purpose insert effect. Mono input (single
  channel) passes through unchanged - there is nothing to widen. }

interface

uses
  SysUtils, Math,
  UDAW.Audio.Types, UDAW.DSP.Math;

type
  TStereoWidthProcessor = class
  private
    FSampleRate: Integer;
    FChannels: Integer;
    FWidth: Double;       // 0..2, 1 = unity
  public
    constructor Create;
    procedure Configure(ASampleRate, AChannels: Integer);
    procedure Reset;
    procedure SetParams(AWidth: Double);
    procedure ProcessBlock(const AIn, AOut: array of PSingle; AFrames: Integer);
    property Width: Double read FWidth;
  end;

implementation

constructor TStereoWidthProcessor.Create;
begin
  inherited Create;
  FSampleRate := UDAW_DEFAULT_SAMPLE_RATE;
  FChannels := 2;
  FWidth := 1.0;
end;

procedure TStereoWidthProcessor.Configure(ASampleRate, AChannels: Integer);
begin
  if ASampleRate > 0 then FSampleRate := ASampleRate;
  if AChannels > 0 then FChannels := AChannels;
  Reset;
end;

procedure TStereoWidthProcessor.Reset;
begin
  { stateless per-sample M/S scale: nothing to clear }
end;

procedure TStereoWidthProcessor.SetParams(AWidth: Double);
begin
  if AWidth < 0 then AWidth := 0 else if AWidth > 2.0 then AWidth := 2.0;
  FWidth := AWidth;
end;

procedure TStereoWidthProcessor.ProcessBlock(const AIn, AOut: array of PSingle; AFrames: Integer);
var
  i: Integer;
  l, r, mid, side: Double;
  pl, pr, ol, orr: PSingle;
begin
  if (Length(AIn) < 2) or (Length(AOut) < 2) then
  begin
    if (Length(AIn) >= 1) and (Length(AOut) >= 1) then
      BlockCopy(AOut[0], AIn[0], AFrames);
    Exit;
  end;
  pl := AIn[0]; pr := AIn[1];
  ol := AOut[0]; orr := AOut[1];
  for i := 0 to AFrames - 1 do
  begin
    l := pl[i]; r := pr[i];
    mid := 0.5 * (l + r);
    side := 0.5 * (l - r) * FWidth;
    ol[i] := Single(FlushDenorm(Single(mid + side)));
    orr[i] := Single(FlushDenorm(Single(mid - side)));
  end;
end;

end.
