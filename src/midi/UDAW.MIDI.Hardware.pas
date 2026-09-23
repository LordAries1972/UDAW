unit UDAW.MIDI.Hardware;
{$I udaw.inc}

{ Phase 38 - MIDI: real Windows MIDI hardware I/O (plan section 25's MIDI
  engine, extended to actual external devices - controllers/keyboards for
  input, external synths/modules for output).

  TMidiInputDevice opens one winmm MIDI-in device and queues every incoming
  channel-voice message with its driver timestamp on a small thread-safe
  ring; the driver's callback thread only ever pushes onto that ring (a
  critical section + array write - one of the few things Microsoft's own
  docs allow a MIDI callback to do), never touching VCL or any Object Pascal
  machinery beyond that. The engine/UI thread drains it with Poll at whatever
  cadence it likes (a UI timer, an audio callback tick, ...); nothing is lost
  between polls short of the ring actually filling up, which only happens
  under a sustained flood no real performance produces.

  TMidiOutputDevice opens one winmm MIDI-out device and sends short channel-
  voice messages - the plain "external synth/controller" output path used
  for hardware monitoring during recording and for routing a track's
  performance out to real gear.

  Windows-only. On any other platform every device list is empty and every
  Open call returns False, so callers (UDAW.MIDI.Capture, the Settings tab)
  work unchanged - they just never see a device to pick. }

interface

uses
  SysUtils, Classes,
  {$IFDEF UDAW_WINDOWS}
  Winapi.Windows, Winapi.MMSystem,
  {$ENDIF}
  UDAW.Errors, UDAW.Threading,
  UDAW.MIDI.Types;

const
  MIDI_HW_SUBSYS = 'MIDI.Hardware';
  MIDI_HW_QUEUE_CAPACITY = 2048;

  { Settings tab / TConfig persistence - device NAME, not driver index (a
    driver index is not stable across replug/reboot; see FindMidiInputByName/
    FindMidiOutputByName, which is how a saved name is resolved back to
    today's index whenever the app opens the device). }
  CFG_SEC_MIDI       = 'midi';
  CFG_MIDI_IN_DEVICE  = 'input_device';
  CFG_MIDI_OUT_DEVICE = 'output_device';

type
  TMidiDeviceInfo = record
    Id: Integer;      // driver device index - NOT stable across replug/reboot
    Name: string;      // human readable - the stable key persisted in config
  end;
  TMidiDeviceList = TArray<TMidiDeviceInfo>;

  TMidiQueuedEvent = record
    Msg: TMidiMessage;
    TimestampMs: Cardinal;   // ms since this device's midiInStart
  end;

  TMidiInputEvent = procedure(Sender: TObject; const AMsg: TMidiMessage;
    ATimestampMs: Cardinal) of object;

  { One opened physical MIDI input device. }
  TMidiInputDevice = class
  private
    {$IFDEF UDAW_WINDOWS}
    FHandle: HMIDIIN;
    {$ENDIF}
    FDeviceId: Integer;
    FDeviceName: string;
    FOpen: Boolean;
    FLock: TUDAWLock;
    FQueue: array[0..MIDI_HW_QUEUE_CAPACITY - 1] of TMidiQueuedEvent;
    FQHead, FQCount: Integer;
    FDropCount: Int64;
    FOpenTickCount64: UInt64;
    procedure Push(const AMsg: TMidiMessage; ATimestampMs: Cardinal);
  public
    constructor Create;
    destructor Destroy; override;
    { Opens by driver device index (see EnumerateMidiInputs). Closes any
      previously open device first. }
    function Open(ADeviceId: Integer; const ADeviceName: string): Boolean;
    { GetTickCount64 at the moment this device's internal clock (what every
      TMidiQueuedEvent/Poll TimestampMs counts from) started - lets a caller
      translate "now" (GetTickCount64) into the same clock domain as an
      incoming event's timestamp: DeviceNowMs = GetTickCount64 - OpenTickCount64.
      See TfrmMain.mnuMidiRecordClick/HandleLiveMidiInput for why this
      matters: the device's own clock never resets between recordings (it
      only resets on Open), so a capture's own "elapsed since Start" has to
      be computed in that same domain, not wall-clock GetTickCount64. }
    property OpenTickCount64: UInt64 read FOpenTickCount64;
    procedure Close;
    { Caller-thread: drain every event queued since the last Poll, invoking
      AProc for each in arrival order. Safe to call from any thread/cadence;
      never allocates, never blocks longer than a short critical section. }
    procedure Poll(AProc: TMidiInputEvent; ASender: TObject);
    { Events dropped because the ring was full (sustained flood with nobody
      polling) - zero in the normal case. }
    property DropCount: Int64 read FDropCount;
    property IsOpen: Boolean read FOpen;
    property DeviceId: Integer read FDeviceId;
    property DeviceName: string read FDeviceName;
  end;

  { One opened physical MIDI output device. }
  TMidiOutputDevice = class
  private
    {$IFDEF UDAW_WINDOWS}
    FHandle: HMIDIOUT;
    {$ENDIF}
    FDeviceId: Integer;
    FDeviceName: string;
    FOpen: Boolean;
  public
    destructor Destroy; override;
    function Open(ADeviceId: Integer; const ADeviceName: string): Boolean;
    procedure Close;
    procedure SendMessage(const AMsg: TMidiMessage);
    { Silences every note on every channel - the "MIDI panic" button. }
    procedure AllNotesOffAllChannels;
    property IsOpen: Boolean read FOpen;
    property DeviceId: Integer read FDeviceId;
    property DeviceName: string read FDeviceName;
  end;

function EnumerateMidiInputs: TMidiDeviceList;
function EnumerateMidiOutputs: TMidiDeviceList;
{ -1 when no device with that exact name is currently present - the caller
  (Settings tab / capture engine) then falls back to "no device" rather than
  guessing, since a driver index is not stable across replug. }
function FindMidiInputByName(const AName: string): Integer;
function FindMidiOutputByName(const AName: string): Integer;

implementation

{$IFDEF UDAW_WINDOWS}

{ ============================ device enumeration =================== }

function EnumerateMidiInputs: TMidiDeviceList;
var
  n, i: Cardinal;
  caps: MIDIINCAPS;
begin
  SetLength(Result, 0);
  n := midiInGetNumDevs;
  if n = 0 then Exit;
  SetLength(Result, n);
  for i := 0 to n - 1 do
  begin
    Result[i].Id := Integer(i);
    if midiInGetDevCaps(i, @caps, SizeOf(caps)) = MMSYSERR_NOERROR then
      Result[i].Name := string(PAnsiChar(@caps.szPname[0]))
    else
      Result[i].Name := Format('MIDI In %d', [i]);
  end;
end;

function EnumerateMidiOutputs: TMidiDeviceList;
var
  n, i: Cardinal;
  caps: MIDIOUTCAPS;
begin
  SetLength(Result, 0);
  n := midiOutGetNumDevs;
  if n = 0 then Exit;
  SetLength(Result, n);
  for i := 0 to n - 1 do
  begin
    Result[i].Id := Integer(i);
    if midiOutGetDevCaps(i, @caps, SizeOf(caps)) = MMSYSERR_NOERROR then
      Result[i].Name := string(PAnsiChar(@caps.szPname[0]))
    else
      Result[i].Name := Format('MIDI Out %d', [i]);
  end;
end;

function FindMidiInputByName(const AName: string): Integer;
var
  list: TMidiDeviceList;
  d: TMidiDeviceInfo;
begin
  Result := -1;
  if Trim(AName) = '' then Exit;
  list := EnumerateMidiInputs;
  for d in list do
    if SameText(d.Name, AName) then Exit(d.Id);
end;

function FindMidiOutputByName(const AName: string): Integer;
var
  list: TMidiDeviceList;
  d: TMidiDeviceInfo;
begin
  Result := -1;
  if Trim(AName) = '' then Exit;
  list := EnumerateMidiOutputs;
  for d in list do
    if SameText(d.Name, AName) then Exit(d.Id);
end;

{ ============================ TMidiInputDevice ====================== }

{ The winmm MIDI-in callback runs on an internal driver thread. Per Microsoft's
  own docs it may only touch a short, fixed list of API functions - none of
  which include allocating, VCL, or arbitrary Object Pascal virtual calls -
  so this global procedure does the absolute minimum: decode the packed short
  message and push it onto the owning device's lock-protected ring. dwInstance
  carries the TMidiInputDevice instance across, set at midiInOpen time. }
procedure MidiInCallbackProc(hMidiIn: HMIDIIN; wMsg: UINT;
  dwInstance, dwParam1, dwParam2: DWORD_PTR); stdcall;
var
  dev: TMidiInputDevice;
  packed_: Cardinal;
  msg: TMidiMessage;
begin
  if wMsg <> MIM_DATA then Exit;
  if dwInstance = 0 then Exit;
  dev := TMidiInputDevice(Pointer(dwInstance));
  packed_ := Cardinal(dwParam1);
  msg.Status := Byte(packed_ and $FF);
  msg.Data1 := Byte((packed_ shr 8) and $FF);
  msg.Data2 := Byte((packed_ shr 16) and $FF);
  dev.Push(msg, Cardinal(dwParam2));
end;

constructor TMidiInputDevice.Create;
begin
  inherited Create;
  FLock := TUDAWLock.Create('MidiInputDevice');
  FDeviceId := -1;
end;

destructor TMidiInputDevice.Destroy;
begin
  Close;
  FLock.Free;
  inherited Destroy;
end;

procedure TMidiInputDevice.Push(const AMsg: TMidiMessage; ATimestampMs: Cardinal);
begin
  FLock.Enter;
  try
    if FQCount >= MIDI_HW_QUEUE_CAPACITY then
    begin
      { ring full: drop the oldest event rather than block the driver thread }
      FQHead := (FQHead + 1) mod MIDI_HW_QUEUE_CAPACITY;
      Dec(FQCount);
      Inc(FDropCount);
    end;
    FQueue[(FQHead + FQCount) mod MIDI_HW_QUEUE_CAPACITY].Msg := AMsg;
    FQueue[(FQHead + FQCount) mod MIDI_HW_QUEUE_CAPACITY].TimestampMs := ATimestampMs;
    Inc(FQCount);
  finally
    FLock.Leave;
  end;
end;

function TMidiInputDevice.Open(ADeviceId: Integer; const ADeviceName: string): Boolean;
var
  rc: MMRESULT;
begin
  Close;
  if ADeviceId < 0 then Exit(False);
  rc := midiInOpen(@FHandle, Cardinal(ADeviceId), DWORD_PTR(@MidiInCallbackProc),
    DWORD_PTR(Self), CALLBACK_FUNCTION);
  if rc <> MMSYSERR_NOERROR then
  begin
    FHandle := 0;
    Exit(False);
  end;
  FQHead := 0;
  FQCount := 0;
  FDropCount := 0;
  FOpenTickCount64 := GetTickCount64;
  midiInStart(FHandle);
  FDeviceId := ADeviceId;
  FDeviceName := ADeviceName;
  FOpen := True;
  Result := True;
end;

procedure TMidiInputDevice.Close;
begin
  if not FOpen then Exit;
  midiInStop(FHandle);
  midiInReset(FHandle);
  midiInClose(FHandle);
  FHandle := 0;
  FOpen := False;
  FDeviceId := -1;
  FDeviceName := '';
end;

procedure TMidiInputDevice.Poll(AProc: TMidiInputEvent; ASender: TObject);
var
  drained: array of TMidiQueuedEvent;
  n, i: Integer;
begin
  if not Assigned(AProc) then Exit;
  FLock.Enter;
  try
    n := FQCount;
    if n = 0 then Exit;
    SetLength(drained, n);
    for i := 0 to n - 1 do
      drained[i] := FQueue[(FQHead + i) mod MIDI_HW_QUEUE_CAPACITY];
    FQHead := (FQHead + n) mod MIDI_HW_QUEUE_CAPACITY;
    FQCount := 0;
  finally
    FLock.Leave;
  end;
  for i := 0 to High(drained) do
    AProc(ASender, drained[i].Msg, drained[i].TimestampMs);
end;

{ ============================ TMidiOutputDevice ===================== }

destructor TMidiOutputDevice.Destroy;
begin
  Close;
  inherited Destroy;
end;

function TMidiOutputDevice.Open(ADeviceId: Integer; const ADeviceName: string): Boolean;
var
  rc: MMRESULT;
begin
  Close;
  if ADeviceId < 0 then Exit(False);
  rc := midiOutOpen(@FHandle, Cardinal(ADeviceId), 0, 0, CALLBACK_NULL);
  if rc <> MMSYSERR_NOERROR then
  begin
    FHandle := 0;
    Exit(False);
  end;
  FDeviceId := ADeviceId;
  FDeviceName := ADeviceName;
  FOpen := True;
  Result := True;
end;

procedure TMidiOutputDevice.Close;
begin
  if not FOpen then Exit;
  midiOutReset(FHandle);
  midiOutClose(FHandle);
  FHandle := 0;
  FOpen := False;
  FDeviceId := -1;
  FDeviceName := '';
end;

procedure TMidiOutputDevice.SendMessage(const AMsg: TMidiMessage);
var
  packed_: DWORD;
begin
  if not FOpen then Exit;
  packed_ := DWORD(AMsg.Status) or (DWORD(AMsg.Data1) shl 8) or (DWORD(AMsg.Data2) shl 16);
  midiOutShortMsg(FHandle, packed_);
end;

procedure TMidiOutputDevice.AllNotesOffAllChannels;
var
  ch: Integer;
begin
  if not FOpen then Exit;
  for ch := 0 to 15 do
  begin
    SendMessage(TMidiMessage.ControlChange(ch, MIDI_CC_ALL_SOUND_OFF, 0));
    SendMessage(TMidiMessage.ControlChange(ch, MIDI_CC_ALL_NOTES_OFF, 0));
  end;
end;

{$ELSE}

{ ============================ non-Windows stubs ===================== }

function EnumerateMidiInputs: TMidiDeviceList;
begin
  SetLength(Result, 0);
end;

function EnumerateMidiOutputs: TMidiDeviceList;
begin
  SetLength(Result, 0);
end;

function FindMidiInputByName(const AName: string): Integer;
begin
  Result := -1;
end;

function FindMidiOutputByName(const AName: string): Integer;
begin
  Result := -1;
end;

constructor TMidiInputDevice.Create;
begin
  inherited Create;
  FLock := TUDAWLock.Create('MidiInputDevice');
  FDeviceId := -1;
end;

destructor TMidiInputDevice.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure TMidiInputDevice.Push(const AMsg: TMidiMessage; ATimestampMs: Cardinal);
begin
  // no-op: never opened, never fed
end;

function TMidiInputDevice.Open(ADeviceId: Integer; const ADeviceName: string): Boolean;
begin
  Result := False;
end;

procedure TMidiInputDevice.Close;
begin
  FOpen := False;
end;

procedure TMidiInputDevice.Poll(AProc: TMidiInputEvent; ASender: TObject);
begin
  // nothing ever queued
end;

destructor TMidiOutputDevice.Destroy;
begin
  inherited Destroy;
end;

function TMidiOutputDevice.Open(ADeviceId: Integer; const ADeviceName: string): Boolean;
begin
  Result := False;
end;

procedure TMidiOutputDevice.Close;
begin
  FOpen := False;
end;

procedure TMidiOutputDevice.SendMessage(const AMsg: TMidiMessage);
begin
  // no device
end;

procedure TMidiOutputDevice.AllNotesOffAllChannels;
begin
  // no device
end;

{$ENDIF}

end.
