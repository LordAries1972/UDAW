unit UDAW.Mixer.PluginMidi;
{$I udaw.inc}

{ The MIDI hub for hosted VST2 / VST3 plug-ins (UDAW.Mixer.PluginHost).

  A plug-in insert that takes MIDI (an instrument, or an effect with an event input) registers
  itself here as a LISTENER, with the Timeline lane its mixer strip is fed from.  MIDI reaches
  it from three places:

    * LANE MIDI   - the Timeline player plays a MIDI / Instrument lane's clips and, when that
                    lane's mixer strip holds a plug-in instrument, posts the notes here instead
                    of (not as well as) the built-in synth: Post(lane, ...)
    * LIVE MIDI   - the MIDI keyboard / controller chosen in Settings: PostLive(...) reaches
                    every listener that has live input switched on
    * RENDER MIDI - a range render (UDAW.Mixer.PluginRender) gives its private listener the
                    notes of the highlighted MIDI clips: Post(virtual lane, ...)

  The hub also carries the project transport (tempo, beat position, play state) so tempo-synced
  plug-ins see it, and collects the MIDI that plug-ins send out for the MIDI output device.

  Everything here is safe to call from the audio thread, the UI thread and the MIDI thread. }

interface

uses
  Windows, SysUtils, Classes, SyncObjs, Generics.Collections, UDAW.Mixer.PluginHost;

type
  TPluginListener = class
  public
    Key: Pointer;                 // the node
    LaneId: Integer;              // Timeline lane this plug-in's strip is fed from (0 = none)
    Live: Boolean;                // receives live MIDI
    Instrument: Boolean;          // replaces the built-in synth for its lane
    Queue: TList<TPluginMidi>;
    constructor Create;
    destructor Destroy; override;
  end;

  TPluginMidiHub = class
  private
    FLock: TCriticalSection;
    FListeners: TObjectList<TPluginListener>;
    FOut: TList<TPluginMidi>;
    FTransport: TPluginTransport;
    FStamp: UInt64;
    function Find(AKey: Pointer): TPluginListener;
  public
    constructor Create;
    destructor Destroy; override;

    { adds or updates the listener for AKey }
    procedure Register(AKey: Pointer; ALaneId: Integer; ALive, AInstrument: Boolean);
    procedure Unregister(AKey: Pointer);
    procedure SetLane(AKey: Pointer; ALaneId: Integer);

    { MIDI for the plug-ins of one lane; ADeltaFrames is the position inside the block being rendered }
    procedure Post(ALaneId: Integer; AStatus, AData1, AData2: Byte; ADeltaFrames: Integer = 0);
    { all-notes-off on every plug-in of the lane (clip ended, seek, stop) }
    procedure PostAllNotesOff(ALaneId: Integer);
    procedure PostLive(AStatus, AData1, AData2: Byte);
    { moves the queued messages of AKey into ADest, oldest first; returns the count }
    function Take(AKey: Pointer; var ADest: array of TPluginMidi): Integer;
    { True when a plug-in instrument is fed from ALaneId: the built-in synth stays silent }
    function LaneHasInstrument(ALaneId: Integer): Boolean;

    { MIDI sent by plug-ins, for the MIDI output device }
    procedure PostOut(AStatus, AData1, AData2: Byte);
    function TakeOut(var ADest: array of TPluginMidi): Integer;

    procedure SetTransport(const ATransport: TPluginTransport);
    function Transport: TPluginTransport;
  end;

function PluginMidi: TPluginMidiHub;

implementation

var
  GHub: TPluginMidiHub;

function PluginMidi: TPluginMidiHub;
begin
  if GHub = nil then GHub := TPluginMidiHub.Create;
  Result := GHub;
end;

const
  MAX_QUEUE = 4096;       // per listener: the oldest messages are dropped beyond this
  MAX_OUT = 4096;

constructor TPluginListener.Create;
begin
  inherited Create;
  Queue := TList<TPluginMidi>.Create;
end;

destructor TPluginListener.Destroy;
begin
  Queue.Free;
  inherited Destroy;
end;

constructor TPluginMidiHub.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FListeners := TObjectList<TPluginListener>.Create(True);
  FOut := TList<TPluginMidi>.Create;
  FTransport := TPluginTransport.Make(False, 120, 0);
end;

destructor TPluginMidiHub.Destroy;
begin
  FOut.Free;
  FListeners.Free;
  FLock.Free;
  inherited Destroy;
end;

function TPluginMidiHub.Find(AKey: Pointer): TPluginListener;
var
  i: Integer;
begin
  for i := 0 to FListeners.Count - 1 do
    if FListeners[i].Key = AKey then Exit(FListeners[i]);
  Result := nil;
end;

procedure TPluginMidiHub.Register(AKey: Pointer; ALaneId: Integer; ALive, AInstrument: Boolean);
var
  l: TPluginListener;
begin
  FLock.Enter;
  try
    l := Find(AKey);
    if l = nil then
    begin
      l := TPluginListener.Create;
      l.Key := AKey;
      FListeners.Add(l);
    end;
    l.LaneId := ALaneId;
    l.Live := ALive;
    l.Instrument := AInstrument;
  finally
    FLock.Leave;
  end;
end;

procedure TPluginMidiHub.Unregister(AKey: Pointer);
var
  l: TPluginListener;
begin
  FLock.Enter;
  try
    l := Find(AKey);
    if l <> nil then FListeners.Remove(l);
  finally
    FLock.Leave;
  end;
end;

procedure TPluginMidiHub.SetLane(AKey: Pointer; ALaneId: Integer);
var
  l: TPluginListener;
begin
  FLock.Enter;
  try
    l := Find(AKey);
    if l <> nil then l.LaneId := ALaneId;
  finally
    FLock.Leave;
  end;
end;

procedure TPluginMidiHub.Post(ALaneId: Integer; AStatus, AData1, AData2: Byte; ADeltaFrames: Integer);
var
  i: Integer;
  m: TPluginMidi;
begin
  if ALaneId = 0 then Exit;
  m.Status := AStatus;
  m.Data1 := AData1;
  m.Data2 := AData2;
  m.DeltaFrames := ADeltaFrames;
  FLock.Enter;
  try
    for i := 0 to FListeners.Count - 1 do
      if FListeners[i].LaneId = ALaneId then
      begin
        if FListeners[i].Queue.Count >= MAX_QUEUE then FListeners[i].Queue.Delete(0);
        FListeners[i].Queue.Add(m);
      end;
  finally
    FLock.Leave;
  end;
end;

procedure TPluginMidiHub.PostAllNotesOff(ALaneId: Integer);
var
  ch: Integer;
begin
  for ch := 0 to 15 do
  begin
    Post(ALaneId, $B0 or ch, 123, 0, 0);
    Post(ALaneId, $B0 or ch, 120, 0, 0);
  end;
end;

procedure TPluginMidiHub.PostLive(AStatus, AData1, AData2: Byte);
var
  i: Integer;
  m: TPluginMidi;
begin
  m.Status := AStatus;
  m.Data1 := AData1;
  m.Data2 := AData2;
  m.DeltaFrames := 0;
  FLock.Enter;
  try
    for i := 0 to FListeners.Count - 1 do
      if FListeners[i].Live then
      begin
        if FListeners[i].Queue.Count >= MAX_QUEUE then FListeners[i].Queue.Delete(0);
        FListeners[i].Queue.Add(m);
      end;
  finally
    FLock.Leave;
  end;
end;

function TPluginMidiHub.Take(AKey: Pointer; var ADest: array of TPluginMidi): Integer;
var
  l: TPluginListener;
  n, i: Integer;
begin
  Result := 0;
  FLock.Enter;
  try
    l := Find(AKey);
    if l = nil then Exit;
    n := l.Queue.Count;
    if n > Length(ADest) then n := Length(ADest);
    for i := 0 to n - 1 do ADest[i] := l.Queue[i];
    if n > 0 then l.Queue.DeleteRange(0, n);
    Result := n;
  finally
    FLock.Leave;
  end;
end;

function TPluginMidiHub.LaneHasInstrument(ALaneId: Integer): Boolean;
var
  i: Integer;
begin
  Result := False;
  if ALaneId = 0 then Exit;
  FLock.Enter;
  try
    for i := 0 to FListeners.Count - 1 do
      if (FListeners[i].LaneId = ALaneId) and FListeners[i].Instrument then
      begin
        Result := True;
        Exit;
      end;
  finally
    FLock.Leave;
  end;
end;

procedure TPluginMidiHub.PostOut(AStatus, AData1, AData2: Byte);
var
  m: TPluginMidi;
begin
  m.Status := AStatus;
  m.Data1 := AData1;
  m.Data2 := AData2;
  m.DeltaFrames := 0;
  FLock.Enter;
  try
    if FOut.Count >= MAX_OUT then FOut.Delete(0);
    FOut.Add(m);
  finally
    FLock.Leave;
  end;
end;

function TPluginMidiHub.TakeOut(var ADest: array of TPluginMidi): Integer;
var
  n, i: Integer;
begin
  FLock.Enter;
  try
    n := FOut.Count;
    if n > Length(ADest) then n := Length(ADest);
    for i := 0 to n - 1 do ADest[i] := FOut[i];
    if n > 0 then FOut.DeleteRange(0, n);
    Result := n;
  finally
    FLock.Leave;
  end;
end;

procedure TPluginMidiHub.SetTransport(const ATransport: TPluginTransport);
begin
  FLock.Enter;
  try
    FTransport := ATransport;
    FStamp := GetTickCount64;
  finally
    FLock.Leave;
  end;
end;

function TPluginMidiHub.Transport: TPluginTransport;
begin
  FLock.Enter;
  try
    Result := FTransport;
    { the player republishes every block; when it stops doing so, playback has stopped }
    if Result.Playing and (GetTickCount64 - FStamp > 250) then Result.Playing := False;
  finally
    FLock.Leave;
  end;
end;

initialization

finalization
  FreeAndNil(GHub);

end.
