unit UDAW.DSP.Delay;
{$I udaw.inc}
{$POINTERMATH ON}

{ Tempo-syncable stereo delay / echo with feedback, true ping-pong cross-feed
  and a feedback low-pass (tape-style darkening). Time is free (ms) or a note
  fraction of the project BPM. }

interface

uses
  SysUtils, Math,
  UDAW.Audio.Types, UDAW.DSP.Math;

type
  TDelay = class
  private
    FSampleRate: Integer;
    FChannels: Integer;
    FBuf: array of array of Single;
    FLen: Integer;
    FPos: Integer;
    FLP: array of Single;
    FTimeMs: Double;
    FFeedback: Double;
    FMix: Double;
    FPingPong: Boolean;
    FDampHz: Double;
    FDampA: Double;
    procedure UpdateDamp;
  public
    constructor Create;
    procedure Configure(ASampleRate, AChannels: Integer);
    procedure Reset;
    procedure SetParams(ATimeMs, AFeedback, AMix, ADampHz: Double; APingPong: Boolean);
    { ABeats: 1 = quarter note, 0.5 = eighth, 1.5 = dotted quarter ... }
    procedure SetSyncedTime(ABpm, ABeats: Double);
    procedure ProcessBlock(const AIn, AOut: array of PSingle; AFrames: Integer);
  end;

implementation

const
  MAX_DELAY_SEC = 4;

constructor TDelay.Create;
begin
  inherited Create;
  FSampleRate := UDAW_DEFAULT_SAMPLE_RATE;
  FChannels := 2;
  FTimeMs := 375.0;
  FFeedback := 0.4;
  FMix := 0.3;
  FDampHz := 6000.0;
end;

procedure TDelay.UpdateDamp;
begin
  FDampA := 1.0 - Exp(-2.0 * Pi * FDampHz / FSampleRate);
end;

procedure TDelay.Configure(ASampleRate, AChannels: Integer);
var
  ch: Integer;
begin
  if ASampleRate > 0 then FSampleRate := ASampleRate;
  if AChannels > 0 then FChannels := AChannels;
  FLen := FSampleRate * MAX_DELAY_SEC + 1;
  SetLength(FBuf, FChannels);
  for ch := 0 to FChannels - 1 do
    SetLength(FBuf[ch], FLen);
  SetLength(FLP, FChannels);
  UpdateDamp;
  Reset;
end;

procedure TDelay.Reset;
var
  ch: Integer;
begin
  FPos := 0;
  for ch := 0 to High(FBuf) do
  begin
    FillChar(FBuf[ch][0], Length(FBuf[ch]) * SizeOf(Single), 0);
    FLP[ch] := 0;
  end;
end;

procedure TDelay.SetParams(ATimeMs, AFeedback, AMix, ADampHz: Double; APingPong: Boolean);
begin
  FTimeMs := EnsureRange(ATimeMs, 1.0, MAX_DELAY_SEC * 1000.0 - 1);
  FFeedback := EnsureRange(AFeedback, 0.0, 0.95);
  FMix := EnsureRange(AMix, 0.0, 1.0);
  FDampHz := EnsureRange(ADampHz, 200.0, FSampleRate * 0.45);
  FPingPong := APingPong;
  UpdateDamp;
end;

procedure TDelay.SetSyncedTime(ABpm, ABeats: Double);
begin
  if ABpm < 20.0 then ABpm := 20.0;
  FTimeMs := EnsureRange(60000.0 / ABpm * ABeats, 1.0, MAX_DELAY_SEC * 1000.0 - 1);
end;

procedure TDelay.ProcessBlock(const AIn, AOut: array of PSingle; AFrames: Integer);
var
  i, ch, nc, rp, d, src: Integer;
  x, mono: Double;
  wet: array[0..1] of Double;
begin
  nc := Min(Min(Length(AIn), Length(AOut)), Length(FBuf));
  if nc = 0 then Exit;
  d := Round(FTimeMs * 0.001 * FSampleRate);
  if d >= FLen then d := FLen - 1;
  if d < 1 then d := 1;
  for i := 0 to AFrames - 1 do
  begin
    rp := FPos - d;
    if rp < 0 then Inc(rp, FLen);
    { damp the wet tap per channel }
    for ch := 0 to nc - 1 do
      FLP[ch] := FLP[ch] + FDampA * (FBuf[ch][rp] - FLP[ch]);
    if FPingPong and (nc = 2) then
    begin
      { mono in -> L line; each line's echo feeds the opposite line }
      mono := (AIn[0][i] + AIn[1][i]) * 0.5;
      FBuf[0][FPos] := Single(FlushDenorm(Single(mono + FFeedback * FLP[1])));
      FBuf[1][FPos] := Single(FlushDenorm(Single(FFeedback * FLP[0])));
    end
    else
      for ch := 0 to nc - 1 do
        FBuf[ch][FPos] := Single(FlushDenorm(Single(AIn[ch][i] + FFeedback * FLP[ch])));
    for ch := 0 to nc - 1 do
    begin
      x := AIn[ch][i];
      src := ch;
      AOut[ch][i] := Single(x * (1.0 - FMix * 0.5) + FLP[src] * FMix);
    end;
    Inc(FPos);
    if FPos >= FLen then FPos := 0;
  end;
  if wet[0] = 0 then; { silence unused-variable hint }
end;

end.
