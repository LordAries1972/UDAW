unit UDAW.Audio.Offline;
{$I udaw.inc}
{$POINTERMATH ON}

{ Phase 2 - deterministic, faster-than-real-time rendering of an IAudioSource
  into memory. Used by the golden-render acceptance tests and, later, by the
  export subsystem. It runs the exact same Render path the device engine uses,
  block by block, with no pacing and no hardware. }

interface

uses
  SysUtils, Math,
  UDAW.Audio.Types, UDAW.Audio.Buffer, UDAW.Audio.Source;

type
  TOfflineResult = record
    Planar: TAudioPlanar;    // [channel][frame]
    Channels: Integer;
    Frames: Integer;
    SampleRate: Integer;
  end;

  { AFraction is 0..1. Called from whatever thread RenderSourceOffline runs
    on - a UI-thread caller must marshal to the UI thread itself, same
    contract as TTrackerProgressEvent. }
  {$IFDEF FPC}
  TOfflineProgressEvent = procedure(AFraction: Double) of object;
  {$ELSE}
  TOfflineProgressEvent = reference to procedure(AFraction: Double);
  {$ENDIF}

function RenderSourceOffline(ASource: IAudioSource;
  ASampleRate, AChannels, ATotalFrames: Integer;
  ABlockFrames: Integer = UDAW_DEFAULT_BUFFER_FRAMES;
  AOnProgress: TOfflineProgressEvent = nil): TOfflineResult;

{ RMS of one channel over the whole result. }
function ChannelRms(const AResult: TOfflineResult; AChannel: Integer): Double;
{ Peak magnitude of one channel. }
function ChannelPeak(const AResult: TOfflineResult; AChannel: Integer): Double;
{ Fundamental frequency estimate from positive-going zero crossings. Accurate
  for clean periodic signals (sine / sweep midpoint), which is all the tests
  need it for. Returns 0 if fewer than two crossings. }
function EstimateFrequency(const AResult: TOfflineResult; AChannel: Integer): Double;
{ Count of samples whose magnitude reaches or exceeds AThreshold (clipping). }
function CountAtOrAbove(const AResult: TOfflineResult; AChannel: Integer;
  AThreshold: Single): Integer;

implementation

function RenderSourceOffline(ASource: IAudioSource;
  ASampleRate, AChannels, ATotalFrames: Integer;
  ABlockFrames: Integer; AOnProgress: TOfflineProgressEvent): TOfflineResult;
var
  buf: TAudioBuffer;
  done, n, ch, i: Integer;
  lastPct: Integer;
begin
  if ASampleRate <= 0 then ASampleRate := UDAW_DEFAULT_SAMPLE_RATE;
  if AChannels <= 0 then AChannels := 2;
  if ATotalFrames < 0 then ATotalFrames := 0;
  ABlockFrames := ClampBufferFrames(ABlockFrames);

  Result.Channels := AChannels;
  Result.Frames := ATotalFrames;
  Result.SampleRate := ASampleRate;
  SetLength(Result.Planar, AChannels);
  for ch := 0 to AChannels - 1 do
    SetLength(Result.Planar[ch], ATotalFrames);

  buf := TAudioBuffer.Create(AChannels, ABlockFrames, ASampleRate);
  try
    if ASource <> nil then
    begin
      ASource.Prepare(ASampleRate, ABlockFrames, AChannels);
      ASource.Reset;
    end;
    done := 0;
    lastPct := -1;
    if Assigned(AOnProgress) then AOnProgress(0);
    while done < ATotalFrames do
    begin
      n := ATotalFrames - done;
      if n > ABlockFrames then n := ABlockFrames;
      buf.SetActiveFrames(n);
      buf.Clear;
      buf.StreamPosition := done;
      if ASource <> nil then
        ASource.Render(buf);
      for ch := 0 to AChannels - 1 do
        for i := 0 to n - 1 do
          Result.Planar[ch][done + i] := buf.ChannelPtr(ch)[i];
      Inc(done, n);
      { Throttled to whole-percent steps so a large render doesn't pay for a
        callback (often Application.ProcessMessages) every single block. }
      if Assigned(AOnProgress) and (ATotalFrames > 0) then
      begin
        i := (done * 100) div ATotalFrames;
        if i <> lastPct then
        begin
          lastPct := i;
          AOnProgress(done / ATotalFrames);
        end;
      end;
    end;
    if Assigned(AOnProgress) then AOnProgress(1);
  finally
    buf.Free;
  end;
end;

function ChannelRms(const AResult: TOfflineResult; AChannel: Integer): Double;
var
  i: Integer;
  acc: Double;
begin
  Result := 0;
  if (AChannel < 0) or (AChannel >= AResult.Channels) or (AResult.Frames = 0) then Exit;
  acc := 0;
  for i := 0 to AResult.Frames - 1 do
    acc := acc + Sqr(Double(AResult.Planar[AChannel][i]));
  Result := Sqrt(acc / AResult.Frames);
end;

function ChannelPeak(const AResult: TOfflineResult; AChannel: Integer): Double;
var
  i: Integer;
  m, a: Double;
begin
  Result := 0;
  if (AChannel < 0) or (AChannel >= AResult.Channels) then Exit;
  m := 0;
  for i := 0 to AResult.Frames - 1 do
  begin
    a := Abs(Double(AResult.Planar[AChannel][i]));
    if a > m then m := a;
  end;
  Result := m;
end;

function EstimateFrequency(const AResult: TOfflineResult; AChannel: Integer): Double;
var
  i, firstX, lastX, crossings: Integer;
  prev, cur: Single;
  spanFrames: Double;
begin
  Result := 0;
  if (AChannel < 0) or (AChannel >= AResult.Channels) or (AResult.Frames < 4) then Exit;
  firstX := -1;
  lastX := -1;
  crossings := 0;
  prev := AResult.Planar[AChannel][0];
  for i := 1 to AResult.Frames - 1 do
  begin
    cur := AResult.Planar[AChannel][i];
    if (prev <= 0) and (cur > 0) then
    begin
      if firstX < 0 then firstX := i;
      lastX := i;
      Inc(crossings);
    end;
    prev := cur;
  end;
  if crossings < 2 then Exit;
  spanFrames := lastX - firstX;
  if spanFrames <= 0 then Exit;
  Result := (crossings - 1) * AResult.SampleRate / spanFrames;
end;

function CountAtOrAbove(const AResult: TOfflineResult; AChannel: Integer;
  AThreshold: Single): Integer;
var
  i, c: Integer;
begin
  c := 0;
  if (AChannel >= 0) and (AChannel < AResult.Channels) then
    for i := 0 to AResult.Frames - 1 do
      if Abs(AResult.Planar[AChannel][i]) >= AThreshold then
        Inc(c);
  Result := c;
end;

end.
