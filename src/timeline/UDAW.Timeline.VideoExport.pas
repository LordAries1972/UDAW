unit UDAW.Timeline.VideoExport;
{$I udaw.inc}
{$POINTERMATH ON}

{ Renders the Timeline's video channels, together with the already-mixed audio,
  into an MP4 file (H.264 video + AAC audio).

  For every output frame the topmost un-muted video clip under that time is
  decoded (clips on a higher track in the list win), fitted into the output
  picture with black bars, and handed to the encoder; where no clip covers the
  time the frame is black.  Frame size and rate follow the video clips used
  (largest size, first clip's rate; 30 fps when a file does not say).

  Decoding and encoding use Windows Media Foundation (Source Reader and Sink
  Writer): the codecs Windows already ships, no extra libraries.  Delphi 12 has
  no Media Foundation headers, so the small part used is declared below and the
  DLLs are bound lazily - a Windows edition without the Media Feature Pack gets
  a clear error instead of a failed start-up.

  The audio arrives as a raw 16-bit little-endian stereo PCM file (what the
  export job's mixer render writes) and is interleaved with the pictures. }

interface

uses
  {$IFDEF FPC}UDAW.Compat,{$ENDIF}
  SysUtils, Classes, UDAW.Timeline.Model;

{ True when any un-muted video clip with a usable source touches
  [AStart, AStart + ADuration). }
function TimelineHasVideoInRange(ATl: TTimeline; AStart, ADuration: Double): Boolean;

{ ARawPcm16: interleaved stereo SmallInt PCM at ASampleRate covering
  ADuration seconds (the file may be shorter - the rest is silence).
  AStretchBPM is the Timeline tempo that clips carrying a SourceBPM are
  conformed to (0 = none); reversed clips play backwards. AProgress receives
  0..1 and may raise to cancel. }
procedure ExportTimelineVideoMp4(ATl: TTimeline; const ARawPcm16, AOutMp4: string;
  ASampleRate: Integer; AStart, ADuration, AStretchBPM: Double; AProgress: TProc<Double>;
  AMaxWidth: Integer = 0; ABitrateKbps: Integer = 0; AAudioKbps: Integer = 0);

{ Renders the Timeline's picture alone (effects and transitions applied) from
  AStart for ADuration seconds into AOutMp4, tuned for speed - see the
  implementation. The picture is at most AMaxWidth wide. AProgress receives
  0..1 and may raise EAbort to cancel (the partial file is left to the caller). }
procedure RenderTimelineVideoPreview(ATl: TTimeline; const AOutMp4: string;
  AStart, ADuration, AStretchBPM: Double; AMaxWidth: Integer; AProgress: TProc<Double>;
  AAllowHardware: Boolean = True);

{ The video effect / transition region (UDAW.Video.Effects) active at ASeconds
  on an un-muted video track, or nil. Shared by the export and the on-screen
  preview so both pick the same region. }
function VideoFxRegionAt(ATl: TTimeline; ASeconds: Double): TVideoEffectRegion;
{ 0..1 across the region. }
function VideoFxProgressAt(ARegion: TVideoEffectRegion; ASeconds: Double): Double;
{ The two clips a transition region joins: the outgoing one (ends at the pivot)
  and the incoming one (starts at the pivot); either may be nil. }
procedure VideoFxTransitionClips(ATl: TTimeline; ARegion: TVideoEffectRegion;
  out AOutgoing, AIncoming: TTimelineClip);

{ Decodes the picture shown ASeconds into a video file and saves it as a
  24-bit BMP (top-down as seen). Returns False and sets AError when the file
  cannot be decoded. Used to preview / check a video file. }
function SaveVideoFrameBmp(const AVideo: string; ASeconds: Double; const ABmp: string;
  out AError: string): Boolean;

implementation

uses
  Math, Generics.Collections,
  Winapi.Windows, Winapi.ActiveX,
  UDAW.Errors, UDAW.Media.DirectShow, UDAW.Video.Effects;

const
  SUBSYS = 'Timeline.VideoExport';

{ ====================== Media Foundation subset ======================== }

type
  IMFAttributes = interface(IUnknown)
    ['{2CD2D921-C447-44A7-A13C-4ADABFC247E3}']
    function GetItem(const guidKey: TGUID; pValue: Pointer): HRESULT; stdcall;
    function GetItemType(const guidKey: TGUID; out pType: Integer): HRESULT; stdcall;
    function CompareItem(const guidKey: TGUID; Value: Pointer; out pbResult: BOOL): HRESULT; stdcall;
    function Compare(pTheirs: IUnknown; MatchType: Integer; out pbResult: BOOL): HRESULT; stdcall;
    function GetUINT32(const guidKey: TGUID; out punValue: UINT): HRESULT; stdcall;
    function GetUINT64(const guidKey: TGUID; out punValue: UInt64): HRESULT; stdcall;
    function GetDouble(const guidKey: TGUID; out pfValue: Double): HRESULT; stdcall;
    function GetGUID(const guidKey: TGUID; out pguidValue: TGUID): HRESULT; stdcall;
    function GetStringLength(const guidKey: TGUID; out pcchLength: UINT): HRESULT; stdcall;
    function GetString(const guidKey: TGUID; pwszValue: PWideChar; cchBufSize: UINT;
      pcchLength: PUINT): HRESULT; stdcall;
    function GetAllocatedString(const guidKey: TGUID; out ppwszValue: PWideChar;
      out pcchLength: UINT): HRESULT; stdcall;
    function GetBlobSize(const guidKey: TGUID; out pcbBlobSize: UINT): HRESULT; stdcall;
    function GetBlob(const guidKey: TGUID; pBuf: PByte; cbBufSize: UINT;
      pcbBlobSize: PUINT): HRESULT; stdcall;
    function GetAllocatedBlob(const guidKey: TGUID; out ppBuf: PByte;
      out pcbSize: UINT): HRESULT; stdcall;
    function GetUnknown(const guidKey: TGUID; const riid: TGUID; out ppv): HRESULT; stdcall;
    function SetItem(const guidKey: TGUID; Value: Pointer): HRESULT; stdcall;
    function DeleteItem(const guidKey: TGUID): HRESULT; stdcall;
    function DeleteAllItems: HRESULT; stdcall;
    function SetUINT32(const guidKey: TGUID; unValue: UINT): HRESULT; stdcall;
    function SetUINT64(const guidKey: TGUID; unValue: UInt64): HRESULT; stdcall;
    function SetDouble(const guidKey: TGUID; fValue: Double): HRESULT; stdcall;
    function SetGUID(const guidKey: TGUID; const guidValue: TGUID): HRESULT; stdcall;
    function SetString(const guidKey: TGUID; wszValue: PWideChar): HRESULT; stdcall;
    function SetBlob(const guidKey: TGUID; pBuf: PByte; cbBufSize: UINT): HRESULT; stdcall;
    function SetUnknown(const guidKey: TGUID; pUnknown: IUnknown): HRESULT; stdcall;
    function LockStore: HRESULT; stdcall;
    function UnlockStore: HRESULT; stdcall;
    function GetCount(out pcItems: UINT): HRESULT; stdcall;
    function GetItemByIndex(unIndex: UINT; out pguidKey: TGUID; pValue: Pointer): HRESULT; stdcall;
    function CopyAllItems(pDest: IUnknown): HRESULT; stdcall;
  end;

  IMFMediaType = interface(IMFAttributes)
    ['{44AE0FA8-EA31-4109-8D2E-4CAE4997C555}']
    function GetMajorType(out pguidMajorType: TGUID): HRESULT; stdcall;
    function IsCompressedFormat(out pfCompressed: BOOL): HRESULT; stdcall;
    function IsEqual(pIMediaType: IMFMediaType; out pdwFlags: DWORD): HRESULT; stdcall;
    function GetRepresentation(guidRepresentation: TGUID; out ppvRepresentation: Pointer): HRESULT; stdcall;
    function FreeRepresentation(guidRepresentation: TGUID; pvRepresentation: Pointer): HRESULT; stdcall;
  end;

  IMFMediaBuffer = interface(IUnknown)
    ['{045FA593-8799-42B8-BC8D-8968C6453507}']
    function Lock(out ppbBuffer: PByte; pcbMaxLength, pcbCurrentLength: PDWORD): HRESULT; stdcall;
    function Unlock: HRESULT; stdcall;
    function GetCurrentLength(out pcbCurrentLength: DWORD): HRESULT; stdcall;
    function SetCurrentLength(cbCurrentLength: DWORD): HRESULT; stdcall;
    function GetMaxLength(out pcbMaxLength: DWORD): HRESULT; stdcall;
  end;

  IMFSample = interface(IMFAttributes)
    ['{C40A00F2-B93A-4D80-AE8C-5A1C634F58E4}']
    function GetSampleFlags(out pdwSampleFlags: DWORD): HRESULT; stdcall;
    function SetSampleFlags(dwSampleFlags: DWORD): HRESULT; stdcall;
    function GetSampleTime(out phnsSampleTime: Int64): HRESULT; stdcall;
    function SetSampleTime(hnsSampleTime: Int64): HRESULT; stdcall;
    function GetSampleDuration(out phnsSampleDuration: Int64): HRESULT; stdcall;
    function SetSampleDuration(hnsSampleDuration: Int64): HRESULT; stdcall;
    function GetBufferCount(out pdwBufferCount: DWORD): HRESULT; stdcall;
    function GetBufferByIndex(dwIndex: DWORD; out ppBuffer: IMFMediaBuffer): HRESULT; stdcall;
    function ConvertToContiguousBuffer(out ppBuffer: IMFMediaBuffer): HRESULT; stdcall;
    function AddBuffer(pBuffer: IMFMediaBuffer): HRESULT; stdcall;
    function RemoveBufferByIndex(dwIndex: DWORD): HRESULT; stdcall;
    function RemoveAllBuffers: HRESULT; stdcall;
    function GetTotalLength(out pcbTotalLength: DWORD): HRESULT; stdcall;
    function CopyToBuffer(pBuffer: IMFMediaBuffer): HRESULT; stdcall;
  end;

  { PROPVARIANT, 24 bytes on Win64 - only the VT_I8 (100 ns time) case is used. }
  TMfPropVarI8 = record
    vt: Word;
    wReserved1, wReserved2, wReserved3: Word;
    hVal: Int64;
    pad: Int64;
  end;

  IMFSourceReader = interface(IUnknown)
    ['{70AE66F2-C809-4E4F-8915-BDCB406B7993}']
    function GetStreamSelection(dwStreamIndex: DWORD; out pfSelected: BOOL): HRESULT; stdcall;
    function SetStreamSelection(dwStreamIndex: DWORD; fSelected: BOOL): HRESULT; stdcall;
    function GetNativeMediaType(dwStreamIndex, dwMediaTypeIndex: DWORD;
      out ppMediaType: IMFMediaType): HRESULT; stdcall;
    function GetCurrentMediaType(dwStreamIndex: DWORD; out ppMediaType: IMFMediaType): HRESULT; stdcall;
    function SetCurrentMediaType(dwStreamIndex: DWORD; pdwReserved: PDWORD;
      pMediaType: IMFMediaType): HRESULT; stdcall;
    function SetCurrentPosition(const guidTimeFormat: TGUID; varPosition: TMfPropVarI8): HRESULT; stdcall;
    function ReadSample(dwStreamIndex, dwControlFlags: DWORD; out pdwActualStreamIndex,
      pdwStreamFlags: DWORD; out pllTimestamp: Int64; out ppSample: IMFSample): HRESULT; stdcall;
    function Flush(dwStreamIndex: DWORD): HRESULT; stdcall;
    function GetServiceForStream(dwStreamIndex: DWORD; const guidService, riid: TGUID;
      out ppvObject): HRESULT; stdcall;
    function GetPresentationAttribute(dwStreamIndex: DWORD; const guidAttribute: TGUID;
      pvarAttribute: Pointer): HRESULT; stdcall;
  end;

  IMFSinkWriter = interface(IUnknown)
    ['{3137F1CD-FE5E-4805-A5D8-FB477448CB3A}']
    function AddStream(pTargetMediaType: IMFMediaType; out pdwStreamIndex: DWORD): HRESULT; stdcall;
    function SetInputMediaType(dwStreamIndex: DWORD; pInputMediaType: IMFMediaType;
      pEncodingParameters: IMFAttributes): HRESULT; stdcall;
    function BeginWriting: HRESULT; stdcall;
    function WriteSample(dwStreamIndex: DWORD; pSample: IMFSample): HRESULT; stdcall;
    function SendStreamTick(dwStreamIndex: DWORD; llTimestamp: Int64): HRESULT; stdcall;
    function PlaceMarker(dwStreamIndex: DWORD; pvContext: Pointer): HRESULT; stdcall;
    function NotifyEndOfSegment(dwStreamIndex: DWORD): HRESULT; stdcall;
    function Flush(dwStreamIndex: DWORD): HRESULT; stdcall;
    function DoFinalize: HRESULT; stdcall;     // IMFSinkWriter::Finalize
    function GetServiceForStream(dwStreamIndex: DWORD; const guidService, riid: TGUID;
      out ppvObject): HRESULT; stdcall;
    function GetStatistics(dwStreamIndex: DWORD; pStats: Pointer): HRESULT; stdcall;
  end;

const
  MF_VERSION = $00020070;
  MFSTARTUP_FULL = 0;
  MF_SOURCE_READER_FIRST_VIDEO_STREAM = DWORD($FFFFFFFC);
  MF_SOURCE_READER_ALL_STREAMS = DWORD($FFFFFFFE);
  MF_SOURCE_READERF_ENDOFSTREAM = $2;
  MF_SOURCE_READERF_ERROR = $1;
  VT_I8_TYPE = 20;
  HNS_PER_SECOND = 10000000;

  MF_MT_MAJOR_TYPE: TGUID = '{48EBA18E-F8C9-4687-BF11-0A74C9F96A8F}';
  MF_MT_SUBTYPE: TGUID = '{F7E34C9A-42E8-4714-B74B-CB29D72C35E5}';
  MF_MT_FRAME_SIZE: TGUID = '{1652C33D-D6B2-4012-B834-72030849A37D}';
  MF_MT_FRAME_RATE: TGUID = '{C459A2E8-3D2C-4E44-B132-FEE5156C7BB0}';
  MF_MT_PIXEL_ASPECT_RATIO: TGUID = '{C6376A1E-8D0A-4027-BE45-6D9A0AD39BB6}';
  MF_MT_INTERLACE_MODE: TGUID = '{E2724BB8-E676-4806-B4B2-A8D6EFB44CCD}';
  MF_MT_AVG_BITRATE: TGUID = '{20332624-FB0D-4D9E-BD0D-CBF6786C102E}';
  MF_MT_DEFAULT_STRIDE: TGUID = '{644B4E48-1E02-4516-B0EB-C01CA9D49AC6}';
  MF_MT_MPEG2_PROFILE: TGUID = '{AD76A80B-2D5C-4E0B-B375-64E520137036}';
  MF_MT_MAX_KEYFRAME_SPACING: TGUID = '{C16EB52B-73A1-476F-8D62-839D6A020652}';
  MF_MT_AUDIO_NUM_CHANNELS: TGUID = '{37E48BF5-645E-4C5B-89DE-ADA9E29B696A}';
  MF_MT_AUDIO_SAMPLES_PER_SECOND: TGUID = '{5FAEEAE7-0290-4C31-9E8A-C534F68D9DBA}';
  MF_MT_AUDIO_BITS_PER_SAMPLE: TGUID = '{F2DEB57F-40FA-4764-AA33-ED4F2D1FF669}';
  MF_MT_AUDIO_AVG_BYTES_PER_SECOND: TGUID = '{1AAB75C8-CFEF-451C-AB95-AC034B8E1731}';
  MF_MT_AUDIO_BLOCK_ALIGNMENT: TGUID = '{322DE230-9EEB-43BD-AB7A-FF412251541D}';
  MF_MT_AAC_PAYLOAD_TYPE: TGUID = '{BFBABE79-7434-4D1C-94F0-72A3B9E17188}';
  MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING: TGUID = '{FB394F3D-CCF1-42EE-BBB3-F9B845D5681D}';
  MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS: TGUID = '{A634A91C-822B-41B9-A494-4DE4643612B0}';
  MF_SINK_WRITER_DISABLE_THROTTLING: TGUID = '{08B845D8-2B74-4AFE-9D53-BE16D2D5AE4F}';
  MFMediaType_Video: TGUID = '{73646976-0000-0010-8000-00AA00389B71}';
  MFMediaType_Audio: TGUID = '{73647561-0000-0010-8000-00AA00389B71}';
  MFVideoFormat_H264: TGUID = '{34363248-0000-0010-8000-00AA00389B71}';
  MFVideoFormat_RGB32: TGUID = '{00000016-0000-0010-8000-00AA00389B71}';
  MFAudioFormat_PCM: TGUID = '{00000001-0000-0010-8000-00AA00389B71}';
  MFAudioFormat_AAC: TGUID = '{00001610-0000-0010-8000-00AA00389B71}';
  { Encoder property: pictures between key/reference pictures. 0 keeps picture
    and decode order identical, so the file starts at time 0 in step with the sound. }
  CODECAPI_AVEncMPVDefaultBPictureCount: TGUID = '{8D390AAC-DC5C-4200-B57F-814D04BABAB2}';
  GUID_NULL_FORMAT: TGUID = '{00000000-0000-0000-0000-000000000000}';

{$WARN SYMBOL_PLATFORM OFF}
function MFStartup(Version: ULONG; dwFlags: DWORD): HRESULT; stdcall;
  external 'mfplat.dll' name 'MFStartup' delayed;
function MFShutdown: HRESULT; stdcall; external 'mfplat.dll' name 'MFShutdown' delayed;
function MFCreateAttributes(out ppMFAttributes: IMFAttributes; cInitialSize: UINT): HRESULT; stdcall;
  external 'mfplat.dll' name 'MFCreateAttributes' delayed;
function MFCreateMediaType(out ppMFType: IMFMediaType): HRESULT; stdcall;
  external 'mfplat.dll' name 'MFCreateMediaType' delayed;
function MFCreateSample(out ppIMFSample: IMFSample): HRESULT; stdcall;
  external 'mfplat.dll' name 'MFCreateSample' delayed;
function MFCreateMemoryBuffer(cbMaxLength: DWORD; out ppBuffer: IMFMediaBuffer): HRESULT; stdcall;
  external 'mfplat.dll' name 'MFCreateMemoryBuffer' delayed;
function MFCreateSourceReaderFromURL(pwszURL: PWideChar; pAttributes: IMFAttributes;
  out ppSourceReader: IMFSourceReader): HRESULT; stdcall;
  external 'mfreadwrite.dll' name 'MFCreateSourceReaderFromURL' delayed;
function MFCreateSinkWriterFromURL(pwszOutputURL: PWideChar; pByteStream: IUnknown;
  pAttributes: IMFAttributes; out ppSinkWriter: IMFSinkWriter): HRESULT; stdcall;
  external 'mfreadwrite.dll' name 'MFCreateSinkWriterFromURL' delayed;

{$WARN SYMBOL_PLATFORM ON}

procedure Check(AHr: HRESULT; const AWhat: string);
begin
  if AHr < 0 then
    RaiseUDAW(errIO, SUBSYS, Format('%s failed (0x%.8x).', [AWhat, Cardinal(AHr)]));
end;

function Pack32(AHi, ALo: Cardinal): UInt64;
begin
  Result := (UInt64(AHi) shl 32) or ALo;
end;

{ ============================ video source ============================= }

type
  TCachedFrame = record
    Time: Int64;
    Pixels: TBytes;
  end;

  { One video file decoded to 32-bit BGRX pictures, top row first.
    FrameAt reads forward (cheap while the time keeps advancing, seeks on a big
    jump); FrameAtBackward serves reversed clips from a short cache of decoded
    pictures that it refills window by window. }
  TMfVideoSource = class
  private
    FReader: IMFSourceReader;
    FDs: TDsVideoReader;              // the DirectShow reader, when Media Foundation cannot open the file
    FWidth, FHeight: Integer;
    FStride: Integer;                 // signed, as Media Foundation reports it
    FFpsNum, FFpsDen: Cardinal;
    FCur, FNext: TBytes;
    FCurT, FNextT: Int64;
    FHaveCur, FHaveNext, FEos, FStarted, FNeedSeek: Boolean;
    FOut: PByte;                      // the picture the last call chose
    FCache: TArray<TCachedFrame>;
    FCacheCount: Integer;
    FCacheCap: Integer;
    function ReadInto(var ADest: TBytes; out ATime: Int64): Boolean;
    procedure SeekTo(AHns: Int64);
    procedure OpenWithMf(const APath: string);
    procedure OpenWithDs(const APath: string);
  public
    constructor Create(const APath: string);
    destructor Destroy; override;
    { Makes Pixels the picture shown at ASeconds of the file. False when the
      file has no picture there at all. }
    function FrameAt(ASeconds: Double): Boolean;
    { Same, for a transport running backwards through the file. }
    function FrameAtBackward(ASeconds: Double): Boolean;
    function Pixels: PByte;
    property Width: Integer read FWidth;
    property Height: Integer read FHeight;
    property FpsNum: Cardinal read FFpsNum;
    property FpsDen: Cardinal read FFpsDen;
  end;

{ The picture is decoded the way MPC-HC does it for formats Windows' own
  Media Foundation cannot open or decode (MKV, HEVC, ...): by the DirectShow
  splitter and decoder registered on the machine. }
constructor TMfVideoSource.Create(const APath: string);
var
  mfError: string;
  probeTime: Int64;
begin
  inherited Create;
  try
    OpenWithMf(APath);
    { Opening proves little (a demuxer can exist without the decoder): only a
      decoded picture does. }
    SetLength(FCur, FWidth * FHeight * 4);
    if not ReadInto(FCur, probeTime) then
      RaiseUDAW(errIO, SUBSYS, 'Windows decoded no picture from ' + ExtractFileName(APath));
    SeekTo(0);
  except
    on E: Exception do
    begin
      mfError := E.Message;
      FReader := nil;
      FEos := False;
      FHaveCur := False;
      FHaveNext := False;
      try
        OpenWithDs(APath);
      except
        on E2: Exception do
          RaiseUDAW(errIO, SUBSYS, mfError + ' (' + E2.Message + ')');
      end;
    end;
  end;
  SetLength(FCur, FWidth * FHeight * 4);
  SetLength(FNext, FWidth * FHeight * 4);
  FOut := @FCur[0];
  { Reverse cache: about 160 MB of pictures, at least 8, at most 90. }
  FCacheCap := Max(8, Min(90, Int64(160) * 1024 * 1024 div (Int64(FWidth) * FHeight * 4)));
end;

destructor TMfVideoSource.Destroy;
begin
  FDs.Free;
  inherited;
end;

procedure TMfVideoSource.OpenWithDs(const APath: string);
begin
  FDs := TDsVideoReader.Create(APath);
  FWidth := FDs.Width;
  FHeight := FDs.Height;
  FFpsNum := FDs.FpsNum;
  FFpsDen := FDs.FpsDen;
end;

procedure TMfVideoSource.OpenWithMf(const APath: string);
var
  attrs: IMFAttributes;
  native, want, cur: IMFMediaType;
  v: UInt64;
  u: UINT;
begin
  Check(MFCreateAttributes(attrs, 1), 'Create reader attributes');
  attrs.SetUINT32(MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, 1);   // YUV -> RGB inside the reader
  Check(MFCreateSourceReaderFromURL(PWideChar(APath), attrs, FReader),
    'Open video file ' + ExtractFileName(APath));
  FReader.SetStreamSelection(MF_SOURCE_READER_ALL_STREAMS, False);
  Check(FReader.SetStreamSelection(MF_SOURCE_READER_FIRST_VIDEO_STREAM, True),
    'Select video stream of ' + ExtractFileName(APath));
  FFpsNum := 0;
  FFpsDen := 1;
  if Succeeded(FReader.GetNativeMediaType(MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, native)) and
     Succeeded(native.GetUINT64(MF_MT_FRAME_RATE, v)) then
  begin
    FFpsNum := Cardinal(v shr 32);
    FFpsDen := Cardinal(v and $FFFFFFFF);
  end;
  Check(MFCreateMediaType(want), 'Create media type');
  want.SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  want.SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
  Check(FReader.SetCurrentMediaType(MF_SOURCE_READER_FIRST_VIDEO_STREAM, nil, want),
    'Decode ' + ExtractFileName(APath) + ' to pictures (is the codec installed?)');
  Check(FReader.GetCurrentMediaType(MF_SOURCE_READER_FIRST_VIDEO_STREAM, cur), 'Read picture format');
  Check(cur.GetUINT64(MF_MT_FRAME_SIZE, v), 'Read picture size');
  FWidth := Integer(v shr 32);
  FHeight := Integer(v and $FFFFFFFF);
  if (FWidth <= 0) or (FHeight <= 0) or (FWidth > 8192) or (FHeight > 8192) then
    RaiseUDAW(errIO, SUBSYS, Format('%s has an unsupported picture size (%d x %d).',
      [ExtractFileName(APath), FWidth, FHeight]));
  if Succeeded(cur.GetUINT32(MF_MT_DEFAULT_STRIDE, u)) then FStride := Integer(u)
  else FStride := -FWidth * 4;        // RGB defaults to bottom-up
  if Abs(FStride) < FWidth * 4 then FStride := -FWidth * 4;
end;

function TMfVideoSource.Pixels: PByte;
begin
  Result := FOut;
end;

function TMfVideoSource.ReadInto(var ADest: TBytes; out ATime: Int64): Boolean;
var
  tries: Integer;
  actual, flags: DWORD;
  ts: Int64;
  sample: IMFSample;
  buf: IMFMediaBuffer;
  p: PByte;
  cur: DWORD;
  rowBytes, y, srcRow: Integer;
begin
  Result := False;
  if FDs <> nil then
  begin
    Result := FDs.ReadFrame(ADest, ATime);
    if not Result then FEos := True;
    Exit;
  end;
  for tries := 1 to 200 do
  begin
    sample := nil;
    Check(FReader.ReadSample(MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, actual, flags, ts, sample),
      'Decode video');
    if flags and MF_SOURCE_READERF_ERROR <> 0 then
      RaiseUDAW(errIO, SUBSYS, 'The video decoder reported an error.');
    if flags and MF_SOURCE_READERF_ENDOFSTREAM <> 0 then
    begin
      FEos := True;
      Exit;
    end;
    if sample = nil then Continue;            // a gap / stream tick - keep reading
    if (Succeeded(sample.ConvertToContiguousBuffer(buf))) and (Succeeded(buf.Lock(p, nil, @cur))) then
    try
      rowBytes := FWidth * 4;
      if Int64(cur) >= Int64(Abs(FStride)) * (FHeight - 1) + rowBytes then
      begin
        for y := 0 to FHeight - 1 do
        begin
          if FStride < 0 then srcRow := FHeight - 1 - y else srcRow := y;
          Move(p[Int64(srcRow) * Abs(FStride)], ADest[y * rowBytes], rowBytes);
        end;
        ATime := ts;
        Exit(True);
      end;
    finally
      buf.Unlock;
    end;
  end;
end;

procedure TMfVideoSource.SeekTo(AHns: Int64);
var
  pv: TMfPropVarI8;
begin
  if FDs <> nil then
    FDs.SeekTo(AHns)
  else
  begin
    FillChar(pv, SizeOf(pv), 0);
    pv.vt := VT_I8_TYPE;
    pv.hVal := Max(0, AHns);
    Check(FReader.SetCurrentPosition(GUID_NULL_FORMAT, pv), 'Seek in video');
  end;
  FHaveCur := False;
  FHaveNext := False;
  FEos := False;
  FNeedSeek := False;
end;

function TMfVideoSource.FrameAt(ASeconds: Double): Boolean;
const
  JUMP_HNS = 2 * HNS_PER_SECOND;      // further ahead than this: seek instead of decoding through
var
  t: Int64;
  tmp: TBytes;
begin
  t := Round(Max(0.0, ASeconds) * HNS_PER_SECOND);
  if not FStarted then
  begin
    FStarted := True;
    if t > HNS_PER_SECOND div 2 then SeekTo(t);
  end
  else if FNeedSeek then
    SeekTo(t)                                    // came here from a backward run
  else if FHaveCur and (t < FCurT - HNS_PER_SECOND div 2) then
    SeekTo(t)                                    // jumped back
  else if FHaveNext and (t > FNextT + JUMP_HNS) then
    SeekTo(t);                                   // jumped far ahead
  if (not FHaveNext) and (not FEos) then
    FHaveNext := ReadInto(FNext, FNextT);
  while FHaveNext and (FNextT <= t) do
  begin
    tmp := FCur; FCur := FNext; FNext := tmp;
    FCurT := FNextT;
    FHaveCur := True;
    FHaveNext := False;
    if not FEos then FHaveNext := ReadInto(FNext, FNextT);
  end;
  if (not FHaveCur) and FHaveNext then
  begin
    { The request is before the first picture: show that first picture. }
    tmp := FCur; FCur := FNext; FNext := tmp;
    FCurT := FNextT;
    FHaveCur := True;
    FHaveNext := False;
  end;
  FOut := @FCur[0];
  Result := FHaveCur;
end;

function TMfVideoSource.FrameAtBackward(ASeconds: Double): Boolean;
var
  t, startT, frameT: Int64;
  fpsHns: Double;
  i: Integer;
  tmp, spare: TBytes;
begin
  Result := False;
  t := Round(Max(0.0, ASeconds) * HNS_PER_SECOND);
  FStarted := True;
  if (FCacheCount = 0) or (t < FCache[0].Time) or
     (t > FCache[FCacheCount - 1].Time + 2 * HNS_PER_SECOND) then
  begin
    { Refill: decode forward from a window before t, keeping the last pictures. }
    if FFpsNum > 0 then fpsHns := HNS_PER_SECOND * FFpsDen / FFpsNum else fpsHns := HNS_PER_SECOND / 30;
    startT := Max(0, t - Round(fpsHns * (FCacheCap - 1)));
    SeekTo(startT);
    FNeedSeek := True;                           // a later forward request must re-seek
    FCacheCount := 0;
    if Length(FCache) < FCacheCap then SetLength(FCache, FCacheCap);
    SetLength(tmp, FWidth * FHeight * 4);
    while ReadInto(tmp, frameT) do
    begin
      if frameT > t then
      begin
        if FCacheCount = 0 then          // nothing at or before t: keep this first picture
        begin
          if Length(FCache[0].Pixels) <> Length(tmp) then SetLength(FCache[0].Pixels, Length(tmp));
          Move(tmp[0], FCache[0].Pixels[0], Length(tmp));
          FCache[0].Time := frameT;
          FCacheCount := 1;
        end;
        Break;
      end;
      if frameT < startT - Round(fpsHns) then Continue;   // before the window
      if FCacheCount = FCacheCap then
      begin                                // full: drop the oldest, reuse its buffer
        spare := FCache[0].Pixels;
        for i := 1 to FCacheCap - 1 do FCache[i - 1] := FCache[i];
        FCache[FCacheCap - 1].Pixels := spare;
        Dec(FCacheCount);
      end;
      FCache[FCacheCount].Time := frameT;
      if Length(FCache[FCacheCount].Pixels) <> Length(tmp) then
        SetLength(FCache[FCacheCount].Pixels, Length(tmp));
      Move(tmp[0], FCache[FCacheCount].Pixels[0], Length(tmp));
      Inc(FCacheCount);
    end;
    if FCacheCount = 0 then Exit;
    FHaveCur := False;
    FHaveNext := False;
  end;
  i := FCacheCount - 1;
  while (i > 0) and (FCache[i].Time > t) do Dec(i);
  FOut := @FCache[i].Pixels[0];
  Result := True;
end;

{ ======================== picture composition ========================== }

{ Draws ASrc (SW x SH, BGRX) into ADst (DW x DH) scaled to fit, centred, with
  black bars - bilinear. }
procedure DrawFitted(ASrc: PByte; SW, SH: Integer; ADst: PByte; DW, DH: Integer);
var
  scale: Double;
  tw, th, x0, y0, x, y, sx0, sx1, sy0, sy1, fx, fy, c: Integer;
  xi0, xi1, xf: TArray<Integer>;
  fxs: Double;
  r0, r1, d: PByte;
  a, b, e, f: Cardinal;
begin
  FillChar(ADst^, Int64(DW) * DH * 4, 0);
  if (SW <= 0) or (SH <= 0) then Exit;
  if (SW = DW) and (SH = DH) then
  begin
    Move(ASrc^, ADst^, Int64(DW) * DH * 4);
    Exit;
  end;
  scale := Min(DW / SW, DH / SH);
  tw := Max(1, Min(DW, Round(SW * scale)));
  th := Max(1, Min(DH, Round(SH * scale)));
  x0 := (DW - tw) div 2;
  y0 := (DH - th) div 2;
  SetLength(xi0, tw); SetLength(xi1, tw); SetLength(xf, tw);
  for x := 0 to tw - 1 do
  begin
    fxs := (x + 0.5) * SW / tw - 0.5;
    if fxs < 0 then fxs := 0;
    sx0 := Min(SW - 1, Trunc(fxs));
    xi0[x] := sx0 * 4;
    xi1[x] := Min(SW - 1, sx0 + 1) * 4;
    xf[x] := Round((fxs - sx0) * 256);
    if xf[x] > 256 then xf[x] := 256;
  end;
  for y := 0 to th - 1 do
  begin
    fxs := (y + 0.5) * SH / th - 0.5;
    if fxs < 0 then fxs := 0;
    sy0 := Min(SH - 1, Trunc(fxs));
    sy1 := Min(SH - 1, sy0 + 1);
    fy := Min(256, Round((fxs - sy0) * 256));
    r0 := ASrc + Int64(sy0) * SW * 4;
    r1 := ASrc + Int64(sy1) * SW * 4;
    d := ADst + (Int64(y0 + y) * DW + x0) * 4;
    for x := 0 to tw - 1 do
    begin
      fx := xf[x];
      sx0 := xi0[x];
      sx1 := xi1[x];
      for c := 0 to 2 do
      begin
        a := r0[sx0 + c] * Cardinal(256 - fx) + r0[sx1 + c] * Cardinal(fx);
        b := r1[sx0 + c] * Cardinal(256 - fx) + r1[sx1 + c] * Cardinal(fx);
        e := a * Cardinal(256 - fy) + b * Cardinal(fy);
        f := e shr 16;
        d[c] := Byte(f);
      end;
      d[3] := 0;
      Inc(d, 4);
    end;
  end;
end;

{ ======================= timeline clip lookup ========================== }

function VideoClipAt(ATl: TTimeline; ASeconds: Double; out ASrc: TMediaSource): TTimelineClip;
var
  i: Integer;
  trk: TTimelineTrack;
  clip: TTimelineClip;
  src: TMediaSource;
begin
  Result := nil;
  ASrc := nil;
  for i := 0 to ATl.TrackCount - 1 do
  begin
    trk := ATl.GetTrack(i);
    if (trk.Kind <> tkVideo) or trk.Muted then Continue;
    clip := trk.ClipAtSeconds(ASeconds);
    if (clip = nil) or clip.Muted or clip.IsMidiClip then Continue;
    src := ATl.SourceById(clip.SourceId);
    if (src = nil) or (src.Kind <> mkVideoFile) then Continue;
    ASrc := src;
    Exit(clip);
  end;
end;

function VideoFxRegionAt(ATl: TTimeline; ASeconds: Double): TVideoEffectRegion;
var
  i: Integer;
  r: TVideoEffectRegion;
  trk: TTimelineTrack;
begin
  Result := nil;
  if ATl = nil then Exit;
  for i := 0 to ATl.VideoEffectCount - 1 do
  begin
    r := ATl.GetVideoEffect(i);
    if (ASeconds < r.StartSeconds) or (ASeconds >= r.EndSeconds) or (r.LengthSeconds <= 0) then Continue;
    trk := ATl.TrackById(r.TrackId);
    if (trk = nil) or (trk.Kind <> tkVideo) or trk.Muted then Continue;
    Exit(r);
  end;
end;

function VideoFxProgressAt(ARegion: TVideoEffectRegion; ASeconds: Double): Double;
begin
  if (ARegion = nil) or (ARegion.LengthSeconds <= 0) then Exit(0);
  Result := Min(1, Max(0, (ASeconds - ARegion.StartSeconds) / ARegion.LengthSeconds));
end;

procedure VideoFxTransitionClips(ATl: TTimeline; ARegion: TVideoEffectRegion;
  out AOutgoing, AIncoming: TTimelineClip);
const
  TOL = 0.05;
var
  trk: TTimelineTrack;
  i: Integer;
  c: TTimelineClip;
  bestEnd, bestStart: Double;
begin
  AOutgoing := nil;
  AIncoming := nil;
  trk := ATl.TrackById(ARegion.TrackId);
  if trk = nil then Exit;
  bestEnd := -1;
  bestStart := 1E30;
  for i := 0 to trk.ClipCount - 1 do
  begin
    c := trk.GetClip(i);
    if c.Muted or c.IsMidiClip then Continue;
    if (c.StartSeconds < ARegion.PivotSeconds - TOL) and (c.EndSeconds <= ARegion.PivotSeconds + TOL) and
       (c.EndSeconds > bestEnd) then
    begin
      AOutgoing := c;
      bestEnd := c.EndSeconds;
    end;
    if (c.StartSeconds >= ARegion.PivotSeconds - TOL) and (c.StartSeconds < bestStart) then
    begin
      AIncoming := c;
      bestStart := c.StartSeconds;
    end;
  end;
  { a pivot inside one clip (no cut): that clip is both sides }
  if (AOutgoing = nil) and (AIncoming = nil) then
  begin
    c := trk.ClipAtSeconds(ARegion.PivotSeconds);
    AOutgoing := c;
    AIncoming := c;
  end;
end;

function TimelineHasVideoInRange(ATl: TTimeline; AStart, ADuration: Double): Boolean;
var
  i, j: Integer;
  trk: TTimelineTrack;
  clip: TTimelineClip;
  src: TMediaSource;
begin
  Result := False;
  if ATl = nil then Exit;
  for i := 0 to ATl.TrackCount - 1 do
  begin
    trk := ATl.GetTrack(i);
    if (trk.Kind <> tkVideo) or trk.Muted then Continue;
    for j := 0 to trk.ClipCount - 1 do
    begin
      clip := trk.GetClip(j);
      if clip.Muted or clip.IsMidiClip then Continue;
      src := ATl.SourceById(clip.SourceId);
      if (src = nil) or (src.Kind <> mkVideoFile) then Continue;
      if (ADuration > 0) and ((clip.EndSeconds <= AStart) or (clip.StartSeconds >= AStart + ADuration)) then
        Continue;
      Exit(True);
    end;
  end;
end;

{ ========================= single-picture preview ====================== }

function SaveVideoFrameBmp(const AVideo: string; ASeconds: Double; const ABmp: string;
  out AError: string): Boolean;
var
  comInit: HRESULT;
  mfUp: Boolean;
  vs: TMfVideoSource;
  fs: TFileStream;
  hdr: array[0..53] of Byte;
  w, h, y, x, rowBytes, padBytes: Integer;
  row: TBytes;
  p: PByte;
  fileSize: Cardinal;
begin
  Result := False;
  AError := '';
  comInit := CoInitializeEx(nil, COINIT_MULTITHREADED);
  mfUp := False;
  vs := nil;
  try
    try
      Check(MFStartup(MF_VERSION, MFSTARTUP_FULL), 'Start Media Foundation');
      mfUp := True;
      vs := TMfVideoSource.Create(AVideo);
      if not vs.FrameAt(ASeconds) then
      begin
        AError := 'No picture at that time.';
        Exit;
      end;
      w := vs.Width;
      h := vs.Height;
      rowBytes := w * 3;
      padBytes := (4 - rowBytes and 3) and 3;
      SetLength(row, rowBytes + padBytes);
      FillChar(row[0], Length(row), 0);
      fileSize := 54 + Cardinal(Length(row)) * Cardinal(h);
      FillChar(hdr, SizeOf(hdr), 0);
      hdr[0] := Ord('B'); hdr[1] := Ord('M');
      PCardinal(@hdr[2])^ := fileSize;
      PCardinal(@hdr[10])^ := 54;
      PCardinal(@hdr[14])^ := 40;
      PInteger(@hdr[18])^ := w;
      PInteger(@hdr[22])^ := h;            // positive height: rows stored bottom-up
      PWord(@hdr[26])^ := 1;
      PWord(@hdr[28])^ := 24;
      fs := TFileStream.Create(ABmp, fmCreate);
      try
        fs.WriteBuffer(hdr[0], 54);
        for y := h - 1 downto 0 do        // bottom row first
        begin
          p := vs.Pixels + Int64(y) * w * 4;
          for x := 0 to w - 1 do
          begin
            row[x * 3] := p[x * 4];
            row[x * 3 + 1] := p[x * 4 + 1];
            row[x * 3 + 2] := p[x * 4 + 2];
          end;
          fs.WriteBuffer(row[0], Length(row));
        end;
      finally
        fs.Free;
      end;
      Result := True;
    except
      on E: Exception do AError := E.Message;
    end;
  finally
    vs.Free;
    if mfUp then MFShutdown;
    if comInit in [S_OK, S_FALSE] then CoUninitialize;
  end;
end;

{ ============================== the export ============================= }

const
  HW_MIN_PIXELS = 640 * 360;

type
  { How the shared renderer treats its output: the export wants full quality
    with sound; the playback pre-render wants speed (see RenderTimelineVideoPreview). }
  TVideoRenderOpts = record
    { Hardware means "allowed": the hardware encoder costs about 0.6 s to start,
      so it is used only for pictures of HW_MIN_PIXELS or more, where its speed
      pays that back (measured: small pictures encode faster in software). }
    VideoOnly: Boolean;          // no sound stream at all
    Hardware: Boolean;           // let Windows use a hardware H.264 encoder when there is one
    MaxWidth: Integer;           // 0 = keep the largest source size
    MaxFps: Integer;             // 0 = keep the first clip's rate
    KeyframeSeconds: Double;     // longest gap between key pictures (short = fast seeking)
    BitsPerPixel: Double;        // encoder budget
    AudioKbps: Integer;          // > 0 picks the AAC rate (snapped to what the encoder offers)
    BitrateKbps: Integer;        // > 0 overrides the BitsPerPixel budget with a fixed bitrate
  end;

procedure RenderVideoCore(ATl: TTimeline; const ARawPcm16, AOutMp4: string;
  ASampleRate: Integer; AStart, ADuration, AStretchBPM: Double; const AOpts: TVideoRenderOpts;
  AProgress: TProc<Double>);
const
  AUDIO_BYTES_PER_SEC = 24000;          // AAC-LC stereo, 192 kbit/s
var
  comInit: HRESULT;
  mfUp: Boolean;
  sources: TObjectDictionary<string, TMfVideoSource>;
  sink: IMFSinkWriter;
  pcm: TFileStream;
  canvas: TBytes;
  outW, outH, i, j: Integer;
  fpsNum, fpsDen: Cardinal;
  vStream, aStream: DWORD;
  totalFrames, k: Int64;
  audioTotal, audioDone, audioDue: Int64;
  audioChunk: TBytes;
  clip: TTimelineClip;
  src: TMediaSource;
  vs: TMfVideoSource;
  trk: TTimelineTrack;
  t: Double;
  bitrate: Int64;
  haveRate: Boolean;
  lib: HMODULE;
  srcT: Double;
  picOk: Boolean;
  fxReg: TVideoEffectRegion;
  fxOutClip, fxInClip: TTimelineClip;
  fxA, fxB, fxO: TBytes;
  fxAId, fxBId: Integer;
  fxAMs, fxBMs: Int64;

  procedure NeedLib(const AName: string);
  begin
    lib := LoadLibrary(PChar(AName));
    if lib = 0 then
      RaiseUDAW(errConfig, SUBSYS, 'Video export needs Windows Media Foundation (' + AName +
        '), which this Windows edition does not provide (install the Media Feature Pack).');
    FreeLibrary(lib);
  end;

  function SourceFor(ASource: TMediaSource): TMfVideoSource;
  begin
    if not sources.TryGetValue(ASource.Path, Result) then
    begin
      if not FileExists(ASource.Path) then
        RaiseUDAW(errIO, SUBSYS, 'The video file is missing: ' + ASource.Path);
      Result := TMfVideoSource.Create(ASource.Path);
      sources.Add(ASource.Path, Result);
    end;
  end;

  { The picture of AClip at timeline time AT fitted into ADst. Outside the
    clip it holds the first / last picture (a transition's frozen side); such a
    held picture is decoded once and kept in ADst (AKeyId/AKeyMs name it). }
  procedure ClipPicture(AClip: TTimelineClip; AT: Double; var ADst: TBytes;
    var AKeyId: Integer; var AKeyMs: Int64);
  var
    s: TMediaSource;
    v: TMfVideoSource;
    tt, lastT: Double;
    frozen, ok: Boolean;
    ms: Int64;
  begin
    s := nil;
    if AClip <> nil then s := ATl.SourceById(AClip.SourceId);
    if (AClip = nil) or (s = nil) or (s.Kind <> mkVideoFile) then
    begin
      FillChar(ADst[0], Length(ADst), 0);
      AKeyId := -1;
      Exit;
    end;
    lastT := Max(AClip.StartSeconds, AClip.EndSeconds - fpsDen / fpsNum);
    frozen := (AT < AClip.StartSeconds) or (AT > lastT);
    tt := Min(Max(AT, AClip.StartSeconds), lastT);
    ms := Round(tt * 1000);
    if frozen and (AKeyId = AClip.Id) and (AKeyMs = ms) then Exit;
    v := SourceFor(s);
    srcT := AClip.VideoSourceSecondsAt(tt, AStretchBPM);
    if AClip.Reversed then ok := v.FrameAtBackward(srcT) else ok := v.FrameAt(srcT);
    if ok then DrawFitted(v.Pixels, v.Width, v.Height, @ADst[0], outW, outH)
    else FillChar(ADst[0], Length(ADst), 0);
    if frozen then
    begin
      AKeyId := AClip.Id;
      AKeyMs := ms;
    end
    else
      AKeyId := -1;
  end;

  function VideoType(AEncoded: Boolean): IMFMediaType;
  begin
    Check(MFCreateMediaType(Result), 'Create video type');
    Result.SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    if AEncoded then
    begin
      Result.SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
      Result.SetUINT32(MF_MT_AVG_BITRATE, UINT(bitrate));
      Result.SetUINT32(MF_MT_MPEG2_PROFILE, 77);        // H.264 Main
      Result.SetUINT32(MF_MT_MAX_KEYFRAME_SPACING, UINT(Max(1, Round(fpsNum / fpsDen * AOpts.KeyframeSeconds))));
    end
    else
      Result.SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
    Result.SetUINT32(MF_MT_INTERLACE_MODE, 2);          // progressive
    Result.SetUINT64(MF_MT_FRAME_SIZE, Pack32(outW, outH));
    Result.SetUINT64(MF_MT_FRAME_RATE, Pack32(fpsNum, fpsDen));
    Result.SetUINT64(MF_MT_PIXEL_ASPECT_RATIO, Pack32(1, 1));
  end;

  { The Windows AAC encoder only accepts 96 / 128 / 160 / 192 kbit/s stereo. }
  function AacBytesPerSec(AKbps: Integer): UINT;
  begin
    if AKbps <= 0 then Exit(AUDIO_BYTES_PER_SEC);
    if AKbps >= 176 then Exit(24000);
    if AKbps >= 144 then Exit(20000);
    if AKbps >= 112 then Exit(16000);
    Result := 12000;
  end;

  function AudioType(AEncoded: Boolean): IMFMediaType;
  begin
    Check(MFCreateMediaType(Result), 'Create audio type');
    Result.SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
    Result.SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, 2);
    Result.SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, UINT(ASampleRate));
    Result.SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
    if AEncoded then
    begin
      Result.SetGUID(MF_MT_SUBTYPE, MFAudioFormat_AAC);
      Result.SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, AacBytesPerSec(AOpts.AudioKbps));
      Result.SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, 1);
      Result.SetUINT32(MF_MT_AAC_PAYLOAD_TYPE, 0);      // raw access units (MP4)
    end
    else
    begin
      Result.SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
      Result.SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, UINT(ASampleRate * 4));
      Result.SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, 4);
    end;
  end;

  { Appends the PCM frames [audioDone, AUpTo) to the file as one sample. }
  procedure WriteAudioUpTo(AUpTo: Int64);
  var
    n: Int64;
    bytes: DWORD;
    buf: IMFMediaBuffer;
    smp: IMFSample;
    p: PByte;
    got: Integer;
  begin
    AUpTo := Min(AUpTo, audioTotal);
    n := AUpTo - audioDone;
    if n <= 0 then Exit;
    bytes := DWORD(n * 4);
    if Length(audioChunk) < Integer(bytes) then SetLength(audioChunk, bytes);
    pcm.Position := audioDone * 4;
    got := pcm.Read(audioChunk[0], bytes);
    if got < Integer(bytes) then FillChar(audioChunk[got], Integer(bytes) - got, 0);
    Check(MFCreateMemoryBuffer(bytes, buf), 'Allocate audio buffer');
    Check(buf.Lock(p, nil, nil), 'Lock audio buffer');
    Move(audioChunk[0], p^, bytes);
    buf.Unlock;
    buf.SetCurrentLength(bytes);
    Check(MFCreateSample(smp), 'Create audio sample');
    smp.AddBuffer(buf);
    smp.SetSampleTime(audioDone * HNS_PER_SECOND div ASampleRate);
    smp.SetSampleDuration(n * HNS_PER_SECOND div ASampleRate);
    Check(sink.WriteSample(aStream, smp), 'Write audio');
    audioDone := AUpTo;
  end;

  procedure WriteVideoFrame(AIndex: Int64);
  var
    bytes: DWORD;
    buf: IMFMediaBuffer;
    smp: IMFSample;
    p: PByte;
    y, rowBytes: Integer;
    t0, t1: Int64;
  begin
    rowBytes := outW * 4;
    bytes := DWORD(rowBytes * outH);
    Check(MFCreateMemoryBuffer(bytes, buf), 'Allocate picture buffer');
    Check(buf.Lock(p, nil, nil), 'Lock picture buffer');
    { Media Foundation RGB32 is bottom-up in memory: last picture row first. }
    for y := 0 to outH - 1 do
      Move(canvas[(outH - 1 - y) * rowBytes], p[y * rowBytes], rowBytes);
    buf.Unlock;
    buf.SetCurrentLength(bytes);
    Check(MFCreateSample(smp), 'Create picture sample');
    smp.AddBuffer(buf);
    t0 := Round(AIndex * HNS_PER_SECOND * fpsDen / fpsNum);
    t1 := Round((AIndex + 1) * HNS_PER_SECOND * fpsDen / fpsNum);
    smp.SetSampleTime(t0);
    smp.SetSampleDuration(t1 - t0);
    Check(sink.WriteSample(vStream, smp), 'Write picture');
  end;

var
  attrs, encParams: IMFAttributes;
  g: Cardinal;
begin
  if (ATl = nil) or (ADuration <= 0) or (ASampleRate <= 0) then
    RaiseUDAW(errInvalidArgument, SUBSYS, 'There is nothing to export.');
  NeedLib('mfplat.dll');
  NeedLib('mfreadwrite.dll');
  comInit := CoInitializeEx(nil, COINIT_MULTITHREADED);
  mfUp := False;
  sources := TObjectDictionary<string, TMfVideoSource>.Create([doOwnsValues]);
  pcm := nil;
  try
    Check(MFStartup(MF_VERSION, MFSTARTUP_FULL), 'Start Media Foundation');
    mfUp := True;

    { ---- inspect the video clips that take part: picture size and rate ---- }
    outW := 0; outH := 0; fpsNum := 0; fpsDen := 1; haveRate := False;
    for i := 0 to ATl.TrackCount - 1 do
    begin
      trk := ATl.GetTrack(i);
      if (trk.Kind <> tkVideo) or trk.Muted then Continue;
      for j := 0 to trk.ClipCount - 1 do
      begin
        clip := trk.GetClip(j);
        if clip.Muted or clip.IsMidiClip then Continue;
        if (clip.EndSeconds <= AStart) or (clip.StartSeconds >= AStart + ADuration) then Continue;
        src := ATl.SourceById(clip.SourceId);
        if (src = nil) or (src.Kind <> mkVideoFile) then Continue;
        vs := SourceFor(src);
        if vs.Width * vs.Height > outW * outH then
        begin
          outW := vs.Width;
          outH := vs.Height;
        end;
        if (not haveRate) and (vs.FpsNum > 0) and (vs.FpsDen > 0) and
           (vs.FpsNum / vs.FpsDen >= 1) and (vs.FpsNum / vs.FpsDen <= 120) then
        begin
          fpsNum := vs.FpsNum;
          fpsDen := vs.FpsDen;
          haveRate := True;
        end;
      end;
    end;
    if outW = 0 then
      RaiseUDAW(errInvalidArgument, SUBSYS, 'There is no video clip in the exported range.');
    if not haveRate then begin fpsNum := 30; fpsDen := 1; end;
    { The H.264 encoder needs even sizes; keep within a sane ceiling. }
    while (outW > 3840) or (outH > 3840) do
    begin
      outW := outW div 2;
      outH := outH div 2;
    end;
    { pre-render: fewer pixels and pictures = proportionally less work }
    if (AOpts.MaxWidth > 0) and (outW > AOpts.MaxWidth) then
    begin
      outH := Round(outH * AOpts.MaxWidth / outW);
      outW := AOpts.MaxWidth;
    end;
    if (AOpts.MaxFps > 0) and (fpsDen > 0) and (fpsNum / fpsDen > AOpts.MaxFps) then
    begin
      fpsNum := Cardinal(AOpts.MaxFps);
      fpsDen := 1;
    end;
    outW := Max(16, outW and not 1);
    outH := Max(16, outH and not 1);
    g := fpsNum;                                    // reduce the rate fraction
    i := fpsDen;
    while i <> 0 do begin j := Integer(g mod Cardinal(i)); g := Cardinal(i); i := j; end;
    if g > 1 then begin fpsNum := fpsNum div g; fpsDen := fpsDen div g; end;

    if AOpts.BitrateKbps > 0 then
      bitrate := AOpts.BitrateKbps * 1000
    else
    begin
      bitrate := Round(outW * outH * (fpsNum / fpsDen) * AOpts.BitsPerPixel);
      bitrate := Max(1000000, Min(50000000, bitrate));
    end;
    totalFrames := Ceil(ADuration * fpsNum / fpsDen);
    SetLength(canvas, outW * outH * 4);
    SetLength(fxA, outW * outH * 4);
    SetLength(fxB, outW * outH * 4);
    SetLength(fxO, outW * outH * 4);
    fxAId := -1;
    fxBId := -1;
    fxAMs := 0;
    fxBMs := 0;

    { ---- sink writer ---- }
    SysUtils.DeleteFile(AOutMp4);
    Check(MFCreateAttributes(attrs, 2), 'Create writer attributes');
    attrs.SetUINT32(MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, Ord(AOpts.Hardware and (outW * outH >= HW_MIN_PIXELS)));   // export: deterministic software encode
    attrs.SetUINT32(MF_SINK_WRITER_DISABLE_THROTTLING, 1);
    Check(MFCreateSinkWriterFromURL(PWideChar(AOutMp4), nil, attrs, sink), 'Create MP4 writer');
    Check(sink.AddStream(VideoType(True), vStream), 'Add H.264 stream');
    Check(MFCreateAttributes(encParams, 1), 'Create encoder settings');
    encParams.SetUINT32(CODECAPI_AVEncMPVDefaultBPictureCount, 0);
    Check(sink.SetInputMediaType(vStream, VideoType(False), encParams),
      'Set picture input (the Windows H.264 encoder is unavailable?)');
    if not AOpts.VideoOnly then
    begin
      Check(sink.AddStream(AudioType(True), aStream), 'Add AAC stream');
      Check(sink.SetInputMediaType(aStream, AudioType(False), nil),
        'Set audio input (the Windows AAC encoder is unavailable?)');
    end;
    Check(sink.BeginWriting, 'Begin writing');

    audioDone := 0;
    audioTotal := 0;
    if not AOpts.VideoOnly then
    begin
      pcm := TFileStream.Create(ARawPcm16, fmOpenRead or fmShareDenyNone);
      audioTotal := Min(pcm.Size div 4, Round(ADuration * ASampleRate));
    end;

    { ---- frame loop: one picture, then the audio up to its end ---- }
    for k := 0 to totalFrames - 1 do
    begin
      t := AStart + k * fpsDen / fpsNum;
      fxReg := VideoFxRegionAt(ATl, t);
      if (fxReg <> nil) and VideoFxIsTransition(fxReg.Kind) then
      begin
        { transition: outgoing and incoming pictures of the cut, mixed }
        VideoFxTransitionClips(ATl, fxReg, fxOutClip, fxInClip);
        ClipPicture(fxOutClip, t, fxA, fxAId, fxAMs);
        ClipPicture(fxInClip, t, fxB, fxBId, fxBMs);
        VideoFxRenderTransition(fxReg.Kind, fxReg.Params, VideoFxProgressAt(fxReg, t),
          @fxA[0], @fxB[0], @canvas[0], outW, outH, Integer(k));
      end
      else
      begin
        clip := VideoClipAt(ATl, t, src);
        if clip = nil then
          FillChar(canvas[0], Length(canvas), 0)
        else
        begin
          vs := SourceFor(src);
          srcT := clip.VideoSourceSecondsAt(t, AStretchBPM);
          if clip.Reversed then picOk := vs.FrameAtBackward(srcT)
          else picOk := vs.FrameAt(srcT);
          if picOk then
            DrawFitted(vs.Pixels, vs.Width, vs.Height, @canvas[0], outW, outH)
          else
            FillChar(canvas[0], Length(canvas), 0);
        end;
        if fxReg <> nil then
        begin
          VideoFxRenderFilter(fxReg.Kind, fxReg.Params, VideoFxProgressAt(fxReg, t),
            @canvas[0], @fxO[0], outW, outH, Integer(k));
          Move(fxO[0], canvas[0], Length(canvas));
        end;
      end;
      WriteVideoFrame(k);
      if k = totalFrames - 1 then audioDue := audioTotal
      else audioDue := Round((k + 1) * ASampleRate * fpsDen / fpsNum);
      WriteAudioUpTo(audioDue);
      if Assigned(AProgress) and ((k and 7) = 0) then AProgress(k / totalFrames);
    end;
    Check(sink.DoFinalize, 'Finish MP4 file');
    sink := nil;
    if Assigned(AProgress) then AProgress(1.0);
  finally
    pcm.Free;
    sink := nil;
    sources.Free;
    if mfUp then MFShutdown;
    if comInit in [S_OK, S_FALSE] then CoUninitialize;
  end;
end;

procedure ExportTimelineVideoMp4(ATl: TTimeline; const ARawPcm16, AOutMp4: string;
  ASampleRate: Integer; AStart, ADuration, AStretchBPM: Double; AProgress: TProc<Double>;
  AMaxWidth: Integer; ABitrateKbps: Integer; AAudioKbps: Integer);
var
  o: TVideoRenderOpts;
begin
  o.VideoOnly := False;
  o.Hardware := False;           // deterministic software encode
  o.MaxWidth := AMaxWidth;       // Settings > Export (0 = source size)
  o.MaxFps := 0;
  o.KeyframeSeconds := 2;
  o.BitsPerPixel := 0.10;
  o.BitrateKbps := ABitrateKbps; // Settings > Export (0 = automatic)
  o.AudioKbps := AAudioKbps;
  RenderVideoCore(ATl, ARawPcm16, AOutMp4, ASampleRate, AStart, ADuration, AStretchBPM, o, AProgress);
end;

{ Speed first: no sound, at most AMaxWidth pixels wide, at most 30 pictures a
  second, a key picture every second (so playback can seek quickly) and a lean
  bitrate. The hardware H.264 encoder is tried first - several times faster -
  and the software one takes over if Windows has none or it refuses the job. }
procedure RenderTimelineVideoPreview(ATl: TTimeline; const AOutMp4: string;
  AStart, ADuration, AStretchBPM: Double; AMaxWidth: Integer; AProgress: TProc<Double>;
  AAllowHardware: Boolean);
var
  o: TVideoRenderOpts;
begin
  o.VideoOnly := True;
  o.Hardware := AAllowHardware;
  o.MaxWidth := AMaxWidth;
  o.MaxFps := 30;
  o.KeyframeSeconds := 1;
  o.BitsPerPixel := 0.07;
  o.BitrateKbps := 0;
  o.AudioKbps := 0;
  try
    RenderVideoCore(ATl, '', AOutMp4, 48000, AStart, ADuration, AStretchBPM, o, AProgress);
  except
    on EAbort do raise;
    on Exception do
    begin
      o.Hardware := False;
      RenderVideoCore(ATl, '', AOutMp4, 48000, AStart, ADuration, AStretchBPM, o, AProgress);
    end;
  end;
end;

end.
