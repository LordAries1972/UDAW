unit UDAW.Audio.Device;
{$I udaw.inc}

{ Phase 2 - device / stream abstraction shared by every audio backend
  (WASAPI, Core Audio, ALSA/PipeWire, software). Higher layers depend only on
  these interfaces; the concrete backend is chosen by UDAW.Audio.Backend.Factory.

  Threading contract:
    * TAudioStreamCallback runs on the backend's real-time thread. It must not
      allocate, lock, touch disk/network, or raise. Fill AOutput; read AInput.
    * OnStreamEvent (device lost / recovered / xrun burst) fires on a backend
      helper thread - never the RT thread. Consumers marshal to the UI.
    * Enumerate / Open / Start / Stop / Close are called from a normal thread. }

interface

uses
  SysUtils, Classes,
  UDAW.Types, UDAW.Errors, UDAW.Audio.Types, UDAW.Audio.Buffer;

type
  TAudioBackendId = (abNull, abSoftware, abWASAPI, abCoreAudio, abALSA, abPipeWire);

  TAudioDeviceInfo = record
    BackendId: TAudioBackendId;
    Id: string;               // backend-stable identifier
    Name: string;             // human readable
    Direction: TAudioDirection;   // adRender or adCapture (never adDuplex here)
    IsDefault: Boolean;
    MinChannels: Integer;
    MaxChannels: Integer;
    DefaultSampleRate: Integer;
    SupportedSampleRates: TArray<Integer>;   // may be empty => "flexible"
    DefaultBufferFrames: Integer;
    MinBufferFrames: Integer;
    MaxBufferFrames: Integer;
    function SupportsRate(ARate: Integer): Boolean;
    function Describe: string;
  end;

  TAudioDeviceList = TArray<TAudioDeviceInfo>;

  TAudioShareMode = (asmShared, asmExclusive);

  { What the caller asks for. The backend negotiates and returns the granted
    values in TAudioStream.ActualConfig - which may differ (rate, buffer, fmt). }
  TAudioStreamRequest = record
    Direction: TAudioDirection;      // adRender / adCapture / adDuplex
    RenderDeviceId: string;          // '' => backend default render device
    CaptureDeviceId: string;         // '' => backend default capture device
    SampleRate: Integer;             // 0 => device default
    RenderChannels: Integer;         // 0 => device default (usually 2)
    CaptureChannels: Integer;
    BufferFrames: Integer;           // 0 => device default; hint only
    ShareMode: TAudioShareMode;
    class function Defaults: TAudioStreamRequest; static;
  end;

  TAudioStreamGranted = record
    Direction: TAudioDirection;
    RenderDeviceId: string;
    RenderDeviceName: string;
    CaptureDeviceId: string;
    CaptureDeviceName: string;
    SampleRate: Integer;
    RenderChannels: Integer;
    CaptureChannels: Integer;
    BufferFrames: Integer;
    ShareMode: TAudioShareMode;
    RenderFormat: TAudioDeviceFormat;
    CaptureFormat: TAudioDeviceFormat;
    InputLatencyFrames: Integer;
    OutputLatencyFrames: Integer;
    function Describe: string;
  end;

  TAudioStreamState = (assClosed, assStopped, assRunning, assLost);

  TAudioStreamStats = record
    CallbackCount: Int64;
    FramesProcessed: Int64;
    XRunCount: Int64;            // output underruns + input overruns
    LastBlockFrames: Integer;
    { fraction of one callback period spent inside the user callback,
      exponentially smoothed; 1.0 == at the edge of dropping out }
    CpuLoad: Double;
    PeakCpuLoad: Double;
    SampleRate: Integer;
    BufferFrames: Integer;
  end;

  { Input/output can arrive independently, including duplex WASAPI streams:
    capture calls with AOutput=nil, render calls with AInput=nil on separate
    workers. Consumers must keep input and output scratch/state independent. }
  TAudioStreamCallback = procedure(AInput, AOutput: TAudioBuffer;
    const ATime: TAudioStreamTime) of object;

  TAudioStreamEventKind = (aseDeviceChanged, aseDeviceLost, aseRecovered,
    aseXRunBurst, aseFormatChanged);

  TAudioStreamEvent = procedure(AKind: TAudioStreamEventKind;
    const AMessage: string) of object;

  IAudioStream = interface
    ['{2C0A9E51-4F7B-4A1D-8C6A-9A2E1D7B4C33}']
    procedure Start;
    procedure Stop;
    procedure Close;
    function State: TAudioStreamState;
    function Granted: TAudioStreamGranted;
    function Stats: TAudioStreamStats;
    procedure ResetStats;
    procedure SetEventHandler(AHandler: TAudioStreamEvent);
    function BackendName: string;
  end;

  IAudioBackend = interface
    ['{5B7D3C62-1E8A-4B9C-A0D4-6F3E2C1A9B44}']
    function Id: TAudioBackendId;
    function Name: string;
    function IsAvailable: Boolean;
    { Fresh enumeration each call (hardware may have changed). }
    function EnumerateDevices(ADirection: TAudioDirection): TAudioDeviceList;
    function DefaultDeviceId(ADirection: TAudioDirection): string;
    { Negotiates and returns a stopped stream. Raises EUDAWError on failure. }
    function OpenStream(const ARequest: TAudioStreamRequest;
      ACallback: TAudioStreamCallback): IAudioStream;
    { Fires (on a helper thread) when the OS reports a device add/remove/default
      change so the app can refresh pickers / trigger recovery. }
    procedure SetDeviceChangeHandler(AHandler: TAudioStreamEvent);
  end;

function BackendIdName(AId: TAudioBackendId): string;

implementation

function BackendIdName(AId: TAudioBackendId): string;
begin
  case AId of
    abNull:      Result := 'null';
    abSoftware:  Result := 'software';
    abWASAPI:    Result := 'wasapi';
    abCoreAudio: Result := 'coreaudio';
    abALSA:      Result := 'alsa';
    abPipeWire:  Result := 'pipewire';
  else
    Result := '?';
  end;
end;

{ TAudioDeviceInfo }

function TAudioDeviceInfo.SupportsRate(ARate: Integer): Boolean;
var
  r: Integer;
begin
  if Length(SupportedSampleRates) = 0 then
    Exit(ValidSampleRate(ARate));
  for r in SupportedSampleRates do
    if r = ARate then
      Exit(True);
  Result := False;
end;

function TAudioDeviceInfo.Describe: string;
var
  rates: string;
  r: Integer;
begin
  rates := '';
  for r in SupportedSampleRates do
  begin
    if rates <> '' then rates := rates + ',';
    rates := rates + IntToStr(r);
  end;
  if rates = '' then rates := 'flexible';
  Result := Format('[%s] %s "%s" %s ch=%d..%d rate=%d {%s} buf=%d..%d',
    [BackendIdName(BackendId), DirectionName(Direction), Name,
     BoolToStr(IsDefault, True), MinChannels, MaxChannels,
     DefaultSampleRate, rates, MinBufferFrames, MaxBufferFrames]);
end;

{ TAudioStreamRequest }

class function TAudioStreamRequest.Defaults: TAudioStreamRequest;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Direction := adRender;
  Result.SampleRate := 0;
  Result.RenderChannels := 0;
  Result.CaptureChannels := 0;
  Result.BufferFrames := 0;
  Result.ShareMode := asmShared;
end;

{ TAudioStreamGranted }

function TAudioStreamGranted.Describe: string;
var
  share: string;
begin
  if ShareMode = asmExclusive then share := 'exclusive' else share := 'shared';
  Result := Format('%s %d Hz  out=%dch/%s  in=%dch/%s  buf=%d  %s  lat in=%d out=%d',
    [DirectionName(Direction), SampleRate,
     RenderChannels, DeviceFormatName(RenderFormat),
     CaptureChannels, DeviceFormatName(CaptureFormat),
     BufferFrames, share,
     InputLatencyFrames, OutputLatencyFrames]);
end;

end.
