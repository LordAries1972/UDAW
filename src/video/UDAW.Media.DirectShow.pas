unit UDAW.Media.DirectShow;
{$I udaw.inc}
{$POINTERMATH ON}

{ The system media pipeline, used the way MPC-HC uses it: a DirectShow graph in
  which whatever splitter and decoder the machine has registered (LAV Splitter /
  LAV Audio where installed - they read MP4, MKV, WebM and decode AAC incl.
  HE-AAC, Opus, Vorbis, AC-3, DTS, FLAC ...) turn a file into PCM.

  Registered into UDAW.Codec.MP4 (Mp4SystemProbe / Mp4SystemDecode), so every
  caller that already opens MP4 files - the Timeline import, playback, the
  waveform - opens MKV and the codecs the built-in decoders do not cover without
  a second code path.  The built-in decoders keep the formats they decode
  exactly (verified sample for sample against a reference decoder); this
  pipeline is only the fallback for the rest.

  The audio is pulled through the stock Sample Grabber filter with the graph's
  clock removed, so decoding runs as fast as the decoder can go. }

interface

uses
  SysUtils, Classes, SyncObjs, Winapi.Windows, Winapi.ActiveX, Winapi.DirectShow9,
  UDAW.Codec.MP4;

{ Container, first audio stream and first video stream of any file DirectShow
  can open. }
function DsProbeFile(const AFileName: string; out AInfo: TMP4ProbeInfo): Boolean;

{ The first audio stream as engine planar float, at the stream's own rate. }
function DsDecodeAudioFile(const AFileName: string; AStream: Integer;
  out ARes: TMP4DecodeResult): Boolean;

{ Why the last call failed (empty after a success). }
function DsLastError: string;

type
  { The first video stream of a file as 32-bit BGRX pictures, top row first,
    read frame by frame - the picture-side twin of DsDecodeAudioFile, for files
    Media Foundation cannot open or decode (MKV, HEVC, ...).  A producer thread
    inside the graph fills a small queue; ReadFrame takes from it. }
  TDsVideoReader = class
  private
    FGraph: IGraphBuilder;
    FControl: IMediaControl;
    FSeeking: IMediaSeeking;
    FEvent: IMediaEvent;
    FCallback: TObject;                 // TVideoGrabCallback
    FCallbackIntf: IUnknown;
    FWidth, FHeight: Integer;
    FFpsNum, FFpsDen: Cardinal;
    FCompleted: Boolean;                // EC_COMPLETE seen for the current segment
    FComJoined: Boolean;
    procedure PollEvents;
    procedure Build(const APath: string);
  public
    constructor Create(const APath: string);
    destructor Destroy; override;
    { The next picture into ADest (Width * Height * 4 bytes) and its media
      time; False at the end of the stream. }
    function ReadFrame(var ADest: TBytes; out ATimeHns: Int64): Boolean;
    { Restart reading at AHns (pictures before it may still be delivered: the
      stream restarts at the previous key picture). }
    procedure SeekTo(AHns: Int64);
    property Width: Integer read FWidth;
    property Height: Integer read FHeight;
    property FpsNum: Cardinal read FFpsNum;
    property FpsDen: Cardinal read FFpsDen;
  end;

implementation

uses
  Math,
  UDAW.Errors, UDAW.Audio.Types, UDAW.Media.Progress;

const
  DS_SUBSYS = 'Media.DirectShow';
  AM_SEEKING_NO_POSITIONING = 0;
  AM_SEEKING_ABSOLUTE_POSITIONING = 1;

type
  { qedit.h - the stock Sample Grabber filter's interfaces (not in Delphi's unit) }
  ISampleGrabberCB = interface(IUnknown)
    ['{0579154A-2B53-4994-B0D0-E773148EFF85}']
    function SampleCB(SampleTime: Double; pSample: IMediaSample): HRESULT; stdcall;
    function BufferCB(SampleTime: Double; pBuffer: PByte; BufferLen: Integer): HRESULT; stdcall;
  end;

  ISampleGrabber = interface(IUnknown)
    ['{6B652FFF-11FE-4FCE-92AD-0266B5D7C78F}']
    function SetOneShot(OneShot: BOOL): HRESULT; stdcall;
    function SetMediaType(const pType: TAMMediaType): HRESULT; stdcall;
    function GetConnectedMediaType(out pType: TAMMediaType): HRESULT; stdcall;
    function SetBufferSamples(BufferThem: BOOL): HRESULT; stdcall;
    function GetCurrentBuffer(var pBufferSize: Integer; pBuffer: Pointer): HRESULT; stdcall;
    function GetCurrentSample(out ppSample: IMediaSample): HRESULT; stdcall;
    function SetCallback(pCallback: ISampleGrabberCB; WhichMethodToCallback: Integer): HRESULT; stdcall;
  end;

  { Collects the decoded bytes; runs on the graph's streaming thread. }
  TGrabCallback = class(TInterfacedObject, ISampleGrabberCB)
  private
    FData: TMemoryStream;
    FFirstTime: Double;
    FGotFirst: Boolean;
    FBytes: Int64;
  public
    constructor Create;
    destructor Destroy; override;
    function SampleCB(SampleTime: Double; pSample: IMediaSample): HRESULT; stdcall;
    function BufferCB(SampleTime: Double; pBuffer: PByte; BufferLen: Integer): HRESULT; stdcall;
    property Data: TMemoryStream read FData;
    property FirstTime: Double read FFirstTime;
    property Bytes: Int64 read FBytes;
  end;

  TStreamFormat = record
    Rate, Channels, Bits: Integer;
    IsFloat: Boolean;
    CodecName: string;
  end;

  TPcmKind = (pkFloat, pkInt);

var
  GLastError: string = '';

function DsLastError: string;
begin
  Result := GLastError;
end;

procedure FreeMediaType(var AMt: TAMMediaType);
begin
  if AMt.pbFormat <> nil then
  begin
    CoTaskMemFree(AMt.pbFormat);
    AMt.pbFormat := nil;
    AMt.cbFormat := 0;
  end;
  AMt.pUnk := nil;
end;

{ ============================ TGrabCallback =========================== }

constructor TGrabCallback.Create;
begin
  inherited Create;
  FData := TMemoryStream.Create;
end;

destructor TGrabCallback.Destroy;
begin
  FData.Free;
  inherited;
end;

function TGrabCallback.SampleCB(SampleTime: Double; pSample: IMediaSample): HRESULT;
begin
  Result := E_NOTIMPL;
end;

function TGrabCallback.BufferCB(SampleTime: Double; pBuffer: PByte; BufferLen: Integer): HRESULT;
begin
  if not FGotFirst then
  begin
    FGotFirst := True;
    FFirstTime := SampleTime;
  end;
  if BufferLen > 0 then
  begin
    FData.WriteBuffer(pBuffer^, BufferLen);
    Inc(FBytes, BufferLen);
  end;
  Result := S_OK;
end;

{ ============================ pin helpers ============================= }

type
  TPinKind = (pkAudioPin, pkVideoPin);

{ Name a stream from its media subtype: the first DWORD of the GUID is a
  WAVE format tag (audio) or a FourCC (video). }
function AudioTagName(ATag: Cardinal): string;
begin
  case ATag of
    $0001: Result := 'PCM';
    $0003: Result := 'PCM float';
    $0050, $0055: Result := 'MP3';
    $00FF, $1600, $1601, $1602, $4143, $4144, $4441, $706D, $A106: Result := 'AAC';
    $2000: Result := 'AC-3';
    $2001: Result := 'DTS';
    $566F: Result := 'Vorbis';
    $704F, $4F70: Result := 'Opus';
    $F1AC: Result := 'FLAC';
    $0161, $0162: Result := 'WMA';
  else
    Result := Format('audio 0x%.4x', [ATag]);
  end;
end;

function FourCCName(AFourCC: Cardinal): string;
var
  i: Integer;
  c: Byte;
begin
  Result := '';
  for i := 0 to 3 do
  begin
    c := (AFourCC shr (8 * i)) and $FF;
    if (c >= 32) and (c < 127) then Result := Result + Chr(c) else Result := Result + '?';
  end;
  case AFourCC of
    $34363248, $31637661, $34363268, $31435641: Result := 'H.264';       // H264 avc1 h264 AVC1
    $43564548, $31637668, $31766568, $35363248: Result := 'H.265';       // HEVC hvc1 hev1 H265
    $30395056: Result := 'VP9';
    $31305641: Result := 'AV1';
  end;
end;

{ The AIndex-th (0-based) output pin of that kind; ACount, when given, receives
  how many such pins the filter has (a splitter exposes one per stream). }
function FindOutputPins(const AFilter: IBaseFilter; AKind: TPinKind;
  out APin: IPin; out AMt: TAMMediaType; AIndex: Integer = 0;
  ACount: PInteger = nil): Boolean;
var
  seen: Integer;
  en: IEnumPins;
  pin: IPin;
  dir: TPinDirection;
  mtEn: IEnumMediaTypes;
  pmt: PAMMediaType;
  fetched: ULONG;
  wantMajor: TGUID;
begin
  Result := False;
  FillChar(AMt, SizeOf(AMt), 0);
  if AKind = pkAudioPin then wantMajor := MEDIATYPE_Audio else wantMajor := MEDIATYPE_Video;
  seen := 0;
  if ACount <> nil then ACount^ := 0;
  if AFilter.EnumPins(en) <> S_OK then Exit;
  while en.Next(1, pin, @fetched) = S_OK do
  begin
    if (pin.QueryDirection(dir) <> S_OK) or (dir <> PINDIR_OUTPUT) then Continue;
    if pin.EnumMediaTypes(mtEn) <> S_OK then Continue;
    while mtEn.Next(1, pmt, @fetched) = S_OK do
    begin
      if IsEqualGUID(pmt^.majortype, wantMajor) then
      begin
        if (seen = AIndex) and (not Result) then
        begin
          AMt := pmt^;
          { the format block now belongs to AMt; only the struct is released }
          CoTaskMemFree(pmt);
          APin := pin;
          Result := True;
          if ACount = nil then Exit;
        end
        else
        begin
          FreeMediaType(pmt^);
          CoTaskMemFree(pmt);
        end;
        Inc(seen);
        Break;                                  // one count per pin
      end;
      FreeMediaType(pmt^);
      CoTaskMemFree(pmt);
    end;
  end;
  if ACount <> nil then ACount^ := seen;
end;

function FirstPin(const AFilter: IBaseFilter; ADir: TPinDirection): IPin;
var
  en: IEnumPins;
  pin: IPin;
  d: TPinDirection;
  fetched: ULONG;
begin
  Result := nil;
  if AFilter.EnumPins(en) <> S_OK then Exit;
  while en.Next(1, pin, @fetched) = S_OK do
    if (pin.QueryDirection(d) = S_OK) and (d = ADir) then Exit(pin);
end;

function WaveFormatOf(const AMt: TAMMediaType; out AFmt: TStreamFormat): Boolean;
var
  p: PByte;
  tag: Word;
  sub: Cardinal;
begin
  FillChar(AFmt, SizeOf(AFmt), 0);
  Result := False;
  if (not IsEqualGUID(AMt.formattype, FORMAT_WaveFormatEx)) or (AMt.pbFormat = nil) or
     (AMt.cbFormat < 16) then Exit;
  p := AMt.pbFormat;
  tag := PWord(p)^;
  AFmt.Channels := PWord(p + 2)^;
  AFmt.Rate := PCardinal(p + 4)^;
  AFmt.Bits := PWord(p + 14)^;
  if (tag = $FFFE) and (AMt.cbFormat >= 40) then
    sub := PCardinal(p + 24)^                       // WAVEFORMATEXTENSIBLE.SubFormat.D1
  else
    sub := tag;
  AFmt.IsFloat := sub = 3;
  AFmt.CodecName := AudioTagName(sub);
  Result := (AFmt.Channels > 0) and (AFmt.Rate > 0);
end;

{ ============================ probe =================================== }

function DoProbe(const AFileName: string; out AInfo: TMP4ProbeInfo): Boolean;
var
  graph: IGraphBuilder;
  src: IBaseFilter;
  pin: IPin;
  mt: TAMMediaType;
  fmt: TStreamFormat;
  seek: IMediaSeeking;
  dur: Int64;
  hr: HRESULT;
  bih: PByte;
begin
  FillChar(AInfo, SizeOf(AInfo), 0);
  GLastError := '';
  Result := False;
  if not FileExists(AFileName) then
  begin
    GLastError := 'file not found';
    Exit;
  end;
  hr := CoCreateInstance(CLSID_FilterGraph, nil, CLSCTX_INPROC_SERVER, IID_IGraphBuilder, graph);
  if hr < 0 then
  begin
    GLastError := Format('could not create a DirectShow graph (0x%.8x)', [Cardinal(hr)]);
    Exit;
  end;
  hr := graph.AddSourceFilter(PWideChar(AFileName), 'Source', src);
  if hr < 0 then
  begin
    GLastError := Format('no DirectShow splitter can open this file (0x%.8x) - install a ' +
      'splitter/decoder pack such as LAV Filters (K-Lite Codec Pack)', [Cardinal(hr)]);
    Exit;
  end;

  AInfo.IsMP4 := True;                       // "a container the media layer understands"
  AInfo.MajorBrand := 'dshw';
  AInfo.UseSystemDecoder := True;
  dur := 0;

  if FindOutputPins(src, pkAudioPin, pin, mt, 0, @AInfo.AudioStreamCount) then
  begin
    if WaveFormatOf(mt, fmt) then
    begin
      AInfo.HasAudio := True;
      AInfo.SampleRate := fmt.Rate;
      AInfo.Channels := fmt.Channels;
      AInfo.BitsPerSample := fmt.Bits;
      AInfo.CodecName := fmt.CodecName;
      AInfo.Decodable := True;
      if Supports(pin, IMediaSeeking, seek) and (seek.GetDuration(dur) = S_OK) then
        AInfo.DurationSeconds := dur / 10000000.0;
    end;
    FreeMediaType(mt);
  end;

  if FindOutputPins(src, pkVideoPin, pin, mt) then
  begin
    AInfo.HasVideo := True;
    AInfo.VideoCodecName := FourCCName(mt.subtype.D1);
    if (mt.pbFormat <> nil) and (mt.cbFormat >= 48 + 12) then
    begin
      { VIDEOINFOHEADER (48 bytes) or VIDEOINFOHEADER2 / MPEG2VIDEOINFO (72 bytes)
        followed by the BITMAPINFOHEADER: biSize, biWidth, biHeight }
      if IsEqualGUID(mt.formattype, FORMAT_VideoInfo) then
        bih := PByte(mt.pbFormat) + 48
      else
        bih := PByte(mt.pbFormat) + 72;
      AInfo.VideoWidth := PInteger(bih + 4)^;
      AInfo.VideoHeight := Abs(PInteger(bih + 8)^);
    end;
    if (AInfo.DurationSeconds <= 0) and Supports(pin, IMediaSeeking, seek) and
       (seek.GetDuration(dur) = S_OK) then
      AInfo.VideoDurationSeconds := dur / 10000000.0
    else if Supports(pin, IMediaSeeking, seek) and (seek.GetDuration(dur) = S_OK) then
      AInfo.VideoDurationSeconds := dur / 10000000.0;
    if AInfo.VideoDurationSeconds <= 0 then AInfo.VideoDurationSeconds := AInfo.DurationSeconds;
    FreeMediaType(mt);
  end;

  if AInfo.HasAudio and (AInfo.SampleRate > 0) then
    AInfo.SampleCount := Round(AInfo.DurationSeconds * AInfo.SampleRate);
  Result := AInfo.HasAudio or AInfo.HasVideo;
  if not Result then GLastError := 'the file has no sound or picture stream DirectShow can read';
end;

{ DirectShow objects live on the calling thread's COM apartment: join one for the
  duration (all interfaces are released inside the inner call). }
function DsProbeFile(const AFileName: string; out AInfo: TMP4ProbeInfo): Boolean;
var
  hrInit: HRESULT;
begin
  hrInit := CoInitializeEx(nil, COINIT_MULTITHREADED);
  try
    Result := DoProbe(AFileName, AInfo);
  finally
    if hrInit >= 0 then CoUninitialize;
  end;
end;

{ ============================ decode ================================== }

{ Interleaved bytes of the connected format -> planar float. }
procedure ConvertToPlanar(const AData: TMemoryStream; const AFmt: TStreamFormat;
  ALeadFrames: Integer; out ARes: TMP4DecodeResult);
var
  bytesPer, frames, i, ch: Integer;
  p: PByte;
  v: Integer;
  d: Double;
begin
  bytesPer := Max(1, AFmt.Bits div 8);
  frames := AData.Size div (bytesPer * AFmt.Channels);
  EnsurePlanar(ARes.Data, AFmt.Channels, ALeadFrames + frames);
  for ch := 0 to AFmt.Channels - 1 do
    if ALeadFrames > 0 then FillChar(ARes.Data[ch][0], ALeadFrames * SizeOf(Single), 0);
  p := AData.Memory;
  for i := 0 to frames - 1 do
    for ch := 0 to AFmt.Channels - 1 do
    begin
      case bytesPer of
        1: ARes.Data[ch][ALeadFrames + i] := (Integer(p^) - 128) / 128.0;
        2: ARes.Data[ch][ALeadFrames + i] := PSmallInt(p)^ / 32768.0;
        3:
          begin
            v := p[0] or (p[1] shl 8) or (p[2] shl 16);
            if (v and $800000) <> 0 then v := v or Integer($FF000000);
            ARes.Data[ch][ALeadFrames + i] := v / 8388608.0;
          end;
        4:
          if AFmt.IsFloat then ARes.Data[ch][ALeadFrames + i] := PSingle(p)^
          else ARes.Data[ch][ALeadFrames + i] := PInteger(p)^ / 2147483648.0;
        8:
          begin
            d := PDouble(p)^;
            ARes.Data[ch][ALeadFrames + i] := d;
          end;
      end;
      Inc(p, bytesPer);
    end;
  ARes.Frames := ALeadFrames + frames;
  ARes.Channels := AFmt.Channels;
  ARes.SampleRate := AFmt.Rate;
end;

{ One attempt at decoding with the grabber asking for ASubtype. False with
  GLastError set when the graph cannot be built for that format. }
function DoTryDecode(const AFileName: string; const ASubtype: TGUID;
  AStream: Integer; out ARes: TMP4DecodeResult): Boolean;
var
  graph: IGraphBuilder;
  src, grabFilter, nullFilter: IBaseFilter;
  grabber: ISampleGrabber;
  cb: TGrabCallback;
  cbIntf: ISampleGrabberCB;
  audioPin, grabIn, grabOut, nullIn: IPin;
  mt, want: TAMMediaType;
  fmt: TStreamFormat;
  ctl: IMediaControl;
  ev: IMediaEvent;
  flt: IMediaFilter;
  seek: IMediaSeeking;
  hr: HRESULT;
  evCode: Longint;
  durHns: Int64;
  lead: Integer;
  totalFrames: Int64;
  what: string;
begin
  Result := False;
  evCode := 0;
  FillChar(ARes, SizeOf(ARes), 0);

  hr := CoCreateInstance(CLSID_FilterGraph, nil, CLSCTX_INPROC_SERVER, IID_IGraphBuilder, graph);
  if hr < 0 then
  begin
    GLastError := Format('could not create a DirectShow graph (0x%.8x)', [Cardinal(hr)]);
    Exit;
  end;
  hr := graph.AddSourceFilter(PWideChar(AFileName), 'Source', src);
  if hr < 0 then
  begin
    GLastError := Format('no DirectShow splitter can open this file (0x%.8x) - install a ' +
      'splitter/decoder pack such as LAV Filters (K-Lite Codec Pack)', [Cardinal(hr)]);
    Exit;
  end;
  if not FindOutputPins(src, pkAudioPin, audioPin, mt, AStream) then
  begin
    GLastError := Format('the file has no sound stream number %d', [AStream + 1]);
    Exit;
  end;
  FreeMediaType(mt);

  hr := CoCreateInstance(CLSID_SampleGrabber, nil, CLSCTX_INPROC_SERVER, IID_IBaseFilter, grabFilter);
  if hr < 0 then
  begin
    GLastError := 'the DirectShow Sample Grabber (qedit.dll) is not available';
    Exit;
  end;
  grabber := grabFilter as ISampleGrabber;
  FillChar(want, SizeOf(want), 0);
  want.majortype := MEDIATYPE_Audio;
  want.subtype := ASubtype;
  grabber.SetMediaType(want);
  grabber.SetBufferSamples(False);
  grabber.SetOneShot(False);
  cb := TGrabCallback.Create;
  cbIntf := cb;
  grabber.SetCallback(cbIntf, 1);                      // 1 = BufferCB
  graph.AddFilter(grabFilter, 'Grabber');

  hr := CoCreateInstance(CLSID_NullRenderer, nil, CLSCTX_INPROC_SERVER, IID_IBaseFilter, nullFilter);
  if hr < 0 then
  begin
    GLastError := 'the DirectShow Null Renderer (qedit.dll) is not available';
    Exit;
  end;
  graph.AddFilter(nullFilter, 'Null');

  grabIn := FirstPin(grabFilter, PINDIR_INPUT);
  grabOut := FirstPin(grabFilter, PINDIR_OUTPUT);
  nullIn := FirstPin(nullFilter, PINDIR_INPUT);
  { the graph builder inserts the registered decoder between the two }
  hr := graph.Connect(audioPin, grabIn);
  if hr < 0 then
  begin
    if IsEqualGUID(ASubtype, MEDIASUBTYPE_IEEE_FLOAT) then what := 'float' else what := 'PCM';
    GLastError := Format('no DirectShow decoder produces this audio as %s (0x%.8x)',
      [what, Cardinal(hr)]);
    Exit;
  end;
  graph.Connect(grabOut, nullIn);

  FillChar(mt, SizeOf(mt), 0);
  if (grabber.GetConnectedMediaType(mt) <> S_OK) or (not WaveFormatOf(mt, fmt)) then
  begin
    FreeMediaType(mt);
    GLastError := 'the decoder gave an audio format this build cannot read';
    Exit;
  end;
  FreeMediaType(mt);
  if not (fmt.Bits in [8, 16, 24, 32, 64]) then
  begin
    GLastError := Format('unsupported decoded sample size (%d bit)', [fmt.Bits]);
    Exit;
  end;
  { float arrives as tag 3 / extensible; a 32-bit integer must not be read as float }
  if IsEqualGUID(ASubtype, MEDIASUBTYPE_IEEE_FLOAT) then fmt.IsFloat := True;

  { no clock: every filter runs as fast as it can }
  if Supports(graph, IMediaFilter, flt) then flt.SetSyncSource(nil);

  durHns := 0;
  if Supports(audioPin, IMediaSeeking, seek) then seek.GetDuration(durHns);
  totalFrames := Round(durHns / 10000000.0 * fmt.Rate);

  ctl := graph as IMediaControl;
  ev := graph as IMediaEvent;
  hr := ctl.Run;
  if hr < 0 then
  begin
    GLastError := Format('the DirectShow graph would not start (0x%.8x)', [Cardinal(hr)]);
    Exit;
  end;
  try
    repeat
      hr := ev.WaitForCompletion(250, evCode);
      if hr = S_OK then Break;
      if hr <> HRESULT($80004004) then          // anything but E_ABORT (= still running)
      begin
        evCode := 0;
        Break;
      end;
      if (totalFrames > 0) then
        ReportMediaProgress('Decoding audio', cb.Bytes div (Max(1, fmt.Bits div 8) * fmt.Channels),
          totalFrames, fmt.Rate);
    until False;
  finally
    ctl.Stop;
  end;
  if evCode <> EC_COMPLETE then
  begin
    GLastError := 'the decoder stopped before the end of the file';
    if cb.Bytes = 0 then Exit;
  end
  else
    GLastError := '';

  if cb.Bytes = 0 then
  begin
    GLastError := 'the decoder produced no audio';
    Exit;
  end;
  { a stream that starts later than the picture keeps its place in time }
  lead := 0;
  if cb.FirstTime > 0.0005 then lead := Round(Min(cb.FirstTime, 3600) * fmt.Rate);
  ConvertToPlanar(cb.Data, fmt, lead, ARes);
  ARes.CodecName := fmt.CodecName;
  ARes.ContainerBrand := 'dshw';
  Result := ARes.Frames > 0;
end;

function TryDecode(const AFileName: string; const ASubtype: TGUID;
  AStream: Integer; out ARes: TMP4DecodeResult): Boolean;
var
  hrInit: HRESULT;
begin
  hrInit := CoInitializeEx(nil, COINIT_MULTITHREADED);
  try
    Result := DoTryDecode(AFileName, ASubtype, AStream, ARes);
  finally
    if hrInit >= 0 then CoUninitialize;
  end;
end;

function DsDecodeAudioFile(const AFileName: string; AStream: Integer;
  out ARes: TMP4DecodeResult): Boolean;
var
  firstError: string;
begin
  GLastError := '';
  Result := TryDecode(AFileName, MEDIASUBTYPE_IEEE_FLOAT, AStream, ARes);
  if not Result then
  begin
    firstError := GLastError;
    Result := TryDecode(AFileName, MEDIASUBTYPE_PCM, AStream, ARes);
    if not Result then
    begin
      if GLastError = '' then GLastError := firstError;
      RaiseUDAWFmt(errNotImplemented, DS_SUBSYS, 'cannot decode the audio of %s: %s',
        [ExtractFileName(AFileName), GLastError]);
    end;
  end;
end;


{ ======================== video reader (frame by frame) =============== }

type
  TQueuedFrame = record
    Time: Double;                        // seconds, stream time of the segment
    Pixels: TBytes;
  end;

  TVideoGrabCallback = class(TInterfacedObject, ISampleGrabberCB)
  private
    FLock: TCriticalSection;
    FSpace, FData: TEvent;
    FQueue: array[0..5] of TQueuedFrame;
    FHead, FCount: Integer;
    FAbort: Boolean;
    FFrameBytes: Integer;
    FWidth, FHeight: Integer;
    FBottomUp: Boolean;
  public
    constructor Create(AWidth, AHeight: Integer; ABottomUp: Boolean);
    destructor Destroy; override;
    function SampleCB(SampleTime: Double; pSample: IMediaSample): HRESULT; stdcall;
    function BufferCB(SampleTime: Double; pBuffer: PByte; BufferLen: Integer): HRESULT; stdcall;
    function Pop(var ADest: TBytes; out ATime: Double): Boolean;
    procedure Flush;
    procedure Abort;
    property DataEvent: TEvent read FData;
  end;

constructor TVideoGrabCallback.Create(AWidth, AHeight: Integer; ABottomUp: Boolean);
var
  i: Integer;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FSpace := TEvent.Create(nil, True, True, '');
  FData := TEvent.Create(nil, True, False, '');
  FWidth := AWidth;
  FHeight := AHeight;
  FBottomUp := ABottomUp;
  FFrameBytes := AWidth * AHeight * 4;
  for i := 0 to High(FQueue) do SetLength(FQueue[i].Pixels, FFrameBytes);
end;

destructor TVideoGrabCallback.Destroy;
begin
  FData.Free;
  FSpace.Free;
  FLock.Free;
  inherited;
end;

function TVideoGrabCallback.SampleCB(SampleTime: Double; pSample: IMediaSample): HRESULT;
begin
  Result := E_NOTIMPL;
end;

function TVideoGrabCallback.BufferCB(SampleTime: Double; pBuffer: PByte; BufferLen: Integer): HRESULT;
var
  slot, y, row: Integer;
begin
  Result := S_OK;
  if BufferLen < FFrameBytes then Exit;
  { backpressure: wait for room (the graph's own thread blocks here) }
  while True do
  begin
    FLock.Enter;
    try
      if FAbort then Exit;
      if FCount < Length(FQueue) then
      begin
        slot := (FHead + FCount) mod Length(FQueue);
        row := FWidth * 4;
        if FBottomUp then
          for y := 0 to FHeight - 1 do
            Move((pBuffer + Int64(FHeight - 1 - y) * row)^, FQueue[slot].Pixels[y * row], row)
        else
          Move(pBuffer^, FQueue[slot].Pixels[0], FFrameBytes);
        FQueue[slot].Time := SampleTime;
        Inc(FCount);
        FData.SetEvent;
        Exit;
      end;
      FSpace.ResetEvent;
    finally
      FLock.Leave;
    end;
    FSpace.WaitFor(40);
  end;
end;

function TVideoGrabCallback.Pop(var ADest: TBytes; out ATime: Double): Boolean;
var
  tmp: TBytes;
begin
  FLock.Enter;
  try
    Result := FCount > 0;
    if not Result then
    begin
      FData.ResetEvent;
      Exit;
    end;
    tmp := ADest;
    ADest := FQueue[FHead].Pixels;
    FQueue[FHead].Pixels := tmp;
    if Length(FQueue[FHead].Pixels) <> FFrameBytes then SetLength(FQueue[FHead].Pixels, FFrameBytes);
    ATime := FQueue[FHead].Time;
    FHead := (FHead + 1) mod Length(FQueue);
    Dec(FCount);
    FSpace.SetEvent;
  finally
    FLock.Leave;
  end;
end;

procedure TVideoGrabCallback.Abort;
begin
  FLock.Enter;
  try
    FAbort := True;
    FSpace.SetEvent;
  finally
    FLock.Leave;
  end;
end;

procedure TVideoGrabCallback.Flush;
begin
  FLock.Enter;
  try
    FCount := 0;
    FHead := 0;
    FAbort := False;
    FData.ResetEvent;
    FSpace.SetEvent;
  finally
    FLock.Leave;
  end;
end;

constructor TDsVideoReader.Create(const APath: string);
var
  hrInit: HRESULT;
begin
  inherited Create;
  FFpsDen := 1;
  hrInit := CoInitializeEx(nil, COINIT_MULTITHREADED);
  { the apartment is joined for the reader's whole life, left in Destroy }
  FComJoined := hrInit >= 0;
  try
    Build(APath);
  except
    FControl := nil;
    FGraph := nil;
    raise;
  end;
end;

procedure TDsVideoReader.Build(const APath: string);
var
  src, grabFilter, nullFilter: IBaseFilter;
  grabber: ISampleGrabber;
  videoPin, grabIn, grabOut, nullIn: IPin;
  mt, want: TAMMediaType;
  flt: IMediaFilter;
  hr: HRESULT;
  bih: PByte;
  avgTime: Int64;
  bottomUp: Boolean;
  a, b, t: Int64;
begin
  hr := CoCreateInstance(CLSID_FilterGraph, nil, CLSCTX_INPROC_SERVER, IID_IGraphBuilder, FGraph);
  if hr < 0 then RaiseUDAWFmt(errIO, DS_SUBSYS, 'could not create a DirectShow graph (0x%.8x)', [Cardinal(hr)]);
  hr := FGraph.AddSourceFilter(PWideChar(APath), 'Source', src);
  if hr < 0 then
    RaiseUDAWFmt(errIO, DS_SUBSYS, 'no DirectShow splitter can open %s (0x%.8x) - install a ' +
      'splitter/decoder pack such as LAV Filters (K-Lite Codec Pack)', [ExtractFileName(APath), Cardinal(hr)]);
  if not FindOutputPins(src, pkVideoPin, videoPin, mt) then
    RaiseUDAWFmt(errIO, DS_SUBSYS, '%s has no picture stream', [ExtractFileName(APath)]);
  FreeMediaType(mt);

  hr := CoCreateInstance(CLSID_SampleGrabber, nil, CLSCTX_INPROC_SERVER, IID_IBaseFilter, grabFilter);
  if hr < 0 then RaiseUDAW(errIO, DS_SUBSYS, 'the DirectShow Sample Grabber (qedit.dll) is not available');
  grabber := grabFilter as ISampleGrabber;
  FillChar(want, SizeOf(want), 0);
  want.majortype := MEDIATYPE_Video;
  want.subtype := MEDIASUBTYPE_RGB32;
  grabber.SetMediaType(want);
  FGraph.AddFilter(grabFilter, 'Grabber');
  hr := CoCreateInstance(CLSID_NullRenderer, nil, CLSCTX_INPROC_SERVER, IID_IBaseFilter, nullFilter);
  if hr < 0 then RaiseUDAW(errIO, DS_SUBSYS, 'the DirectShow Null Renderer (qedit.dll) is not available');
  FGraph.AddFilter(nullFilter, 'Null');
  grabIn := FirstPin(grabFilter, PINDIR_INPUT);
  grabOut := FirstPin(grabFilter, PINDIR_OUTPUT);
  nullIn := FirstPin(nullFilter, PINDIR_INPUT);
  hr := FGraph.Connect(videoPin, grabIn);
  if hr < 0 then
    RaiseUDAWFmt(errIO, DS_SUBSYS, 'no DirectShow decoder turns the picture of %s into RGB (0x%.8x)',
      [ExtractFileName(APath), Cardinal(hr)]);
  FGraph.Connect(grabOut, nullIn);

  FillChar(mt, SizeOf(mt), 0);
  if grabber.GetConnectedMediaType(mt) <> S_OK then
    RaiseUDAW(errIO, DS_SUBSYS, 'the picture format could not be read');
  try
    if (mt.pbFormat = nil) or (mt.cbFormat < 48 + 40) or
       not IsEqualGUID(mt.formattype, FORMAT_VideoInfo) then
      RaiseUDAW(errIO, DS_SUBSYS, 'the decoder gave an unexpected picture format');
    avgTime := PInt64(PByte(mt.pbFormat) + 40)^;            // VIDEOINFOHEADER.AvgTimePerFrame (after rects + bitrates)
    bih := PByte(mt.pbFormat) + 48;
    FWidth := PInteger(bih + 4)^;
    FHeight := PInteger(bih + 8)^;
    bottomUp := FHeight > 0;                                // positive biHeight = bottom-up DIB
    FHeight := Abs(FHeight);
  finally
    FreeMediaType(mt);
  end;
  if (FWidth <= 0) or (FHeight <= 0) or (FWidth > 8192) or (FHeight > 8192) then
    RaiseUDAWFmt(errIO, DS_SUBSYS, '%s has an unsupported picture size (%d x %d)',
      [ExtractFileName(APath), FWidth, FHeight]);
  if avgTime > 0 then
  begin
    { reduce 10_000_000 / avgTime }
    a := 10000000;
    b := avgTime;
    while b <> 0 do
    begin
      t := a mod b;
      a := b;
      b := t;
    end;
    FFpsNum := Cardinal(10000000 div a);
    FFpsDen := Cardinal(avgTime div a);
  end
  else
  begin
    FFpsNum := 30;
    FFpsDen := 1;
  end;

  FCallback := TVideoGrabCallback.Create(FWidth, FHeight, bottomUp);
  FCallbackIntf := TVideoGrabCallback(FCallback) as ISampleGrabberCB;
  grabber.SetBufferSamples(False);
  grabber.SetOneShot(False);
  grabber.SetCallback(FCallbackIntf as ISampleGrabberCB, 1);
  if Supports(FGraph, IMediaFilter, flt) then flt.SetSyncSource(nil);
  FControl := FGraph as IMediaControl;
  FSeeking := FGraph as IMediaSeeking;
  FEvent := FGraph as IMediaEvent;
  hr := FControl.Run;
  if hr < 0 then RaiseUDAWFmt(errIO, DS_SUBSYS, 'the DirectShow graph would not start (0x%.8x)', [Cardinal(hr)]);
end;

destructor TDsVideoReader.Destroy;
begin
  if FCallback <> nil then TVideoGrabCallback(FCallback).Abort;
  if FControl <> nil then FControl.Stop;
  FEvent := nil;
  FSeeking := nil;
  FControl := nil;
  FGraph := nil;
  FCallbackIntf := nil;
  FCallback := nil;
  if FComJoined then CoUninitialize;
  inherited;
end;

{ Notes the end of the stream (EC_COMPLETE) and drops every other event. }
procedure TDsVideoReader.PollEvents;
var
  code: Longint;
  p1, p2: LONG_PTR;
begin
  while FEvent.GetEvent(code, p1, p2, 0) = S_OK do
  begin
    FEvent.FreeEventParams(code, p1, p2);
    if code = EC_COMPLETE then FCompleted := True;
  end;
end;

function TDsVideoReader.ReadFrame(var ADest: TBytes; out ATimeHns: Int64): Boolean;
var
  cb: TVideoGrabCallback;
  t: Double;
  waited: Integer;
begin
  cb := TVideoGrabCallback(FCallback);
  waited := 0;
  while True do
  begin
    if cb.Pop(ADest, t) then
    begin
      ATimeHns := Round(t * 10000000.0);
      Exit(True);
    end;
    PollEvents;
    if FCompleted then
    begin
      { the stream has ended: whatever it delivered is in the queue by now }
      Result := cb.Pop(ADest, t);
      if Result then ATimeHns := Round(t * 10000000.0);
      Exit;
    end;
    if cb.DataEvent.WaitFor(40) <> wrSignaled then
    begin
      Inc(waited, 40);
      if waited > 20000 then
        RaiseUDAW(errIO, DS_SUBSYS, 'the video decoder stopped delivering pictures');
    end
    else
      waited := 0;
  end;
end;

procedure TDsVideoReader.SeekTo(AHns: Int64);
var
  cur, stop: Int64;
  cb: TVideoGrabCallback;
begin
  cb := TVideoGrabCallback(FCallback);
  cb.Abort;                                  // frees a picture the graph thread is waiting to queue
  cur := Max(0, AHns);
  stop := 0;
  FSeeking.SetPositions(cur, AM_SEEKING_ABSOLUTE_POSITIONING, stop, AM_SEEKING_NO_POSITIONING);
  cb.Flush;
  PollEvents;                                // anything raised before the seek is stale
  FCompleted := False;
end;

initialization
  { COM is initialised by the VCL for the main thread; worker threads that load
    media call CoInitializeEx themselves }
  Mp4SystemProbe := DsProbeFile;
  Mp4SystemDecode := DsDecodeAudioFile;

end.
