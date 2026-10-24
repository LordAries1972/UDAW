unit UDAW.Codec.WAV;
{$I udaw.inc}
{$POINTERMATH ON}

{ Phase 6 - PCM / WAV engine (plan section 17).

  A complete, self-contained WAV implementation - no third-party loaders, no OS
  multimedia API. It reads and writes:

    * RIFF/WAVE and RF64/BW64 (EBU Tech 3306) for files past the 4 GiB RIFF limit
    * PCM 8-bit (unsigned), 16 / 24 / 32-bit (signed, little-endian)
    * IEEE float 32-bit and 64-bit
    * mono, stereo and arbitrary multichannel (WAVE_FORMAT_EXTENSIBLE)

  All multi-byte integers are assembled/emitted byte-by-byte in little-endian
  order, so the codec is correct on any host endianness. The canonical
  in-memory representation is the engine-wide planar Float32 layout
  (TAudioPlanar, Data[channel][frame]).

  The reader never trusts the file extension: TWavReader / ReadWavInfo parse the
  actual RIFF structure and DataLooksLikeWav / FileLooksLikeWav sniff the header
  signature (plan section 20). A malformed or unsupported file raises
  EUDAWError (errConfig / errIO) - it never loads with data silently missing. }

interface

uses
  UDAW.Media.Progress, SysUtils, Classes, Math, StrUtils, UDAW.Media.Attribution,
  UDAW.Errors, UDAW.Audio.Types, UDAW.Audio.Buffer, UDAW.Audio.Source;

const
  CODEC_SUBSYS = 'Codec.WAV';

  WAVE_FORMAT_PCM        = $0001;
  WAVE_FORMAT_IEEE_FLOAT = $0003;
  WAVE_FORMAT_EXTENSIBLE = $FFFE;

type
  TWavSampleFormat = (
    wsfUnknown,
    wsfPCM8,     // unsigned 8-bit
    wsfPCM16,    // signed 16-bit  little-endian
    wsfPCM24,    // signed 24-bit  little-endian, 3 bytes packed
    wsfPCM32,    // signed 32-bit  little-endian
    wsfFloat32,  // IEEE 754 single
    wsfFloat64   // IEEE 754 double
  );

  TWavInfo = record
    SampleFormat: TWavSampleFormat;
    Channels: Integer;
    SampleRate: Integer;
    FrameCount: Int64;      // sample frames (per channel)
    BitsPerSample: Integer;
    ChannelMask: LongWord;
    IsRF64: Boolean;
    IsExtensible: Boolean;
    DataOffset: Int64;      // byte offset of the first PCM data byte
    DataSize: Int64;        // bytes of PCM data
    function BytesPerSample: Integer;
    function BytesPerFrame: Integer;
    function DurationSeconds: Double;
    function Describe: string;
  end;

function WavSampleFormatName(AFmt: TWavSampleFormat): string;
function WavSampleFormatBytes(AFmt: TWavSampleFormat): Integer;
function WavSampleFormatBits(AFmt: TWavSampleFormat): Integer;

{ Header-signature detection - does NOT look at the file name. }
function DataLooksLikeWav(const AData; ALength: Integer): Boolean;
function FileLooksLikeWav(const AFileName: string): Boolean;

{ Parse only the header of a file. Raises EUDAWError on a malformed WAV. }
function ReadWavInfo(const AFileName: string): TWavInfo;

type
  { Streaming reader. Owns its stream when constructed from a file name. }
  TWavReader = class
  private
    FStream: TStream;
    FOwnsStream: Boolean;
    FInfo: TWavInfo;
    FCurrentFrame: Int64;
    procedure ParseHeader;
  public
    constructor Create(const AFileName: string); overload;
    constructor Create(AStream: TStream; AOwnsStream: Boolean); overload;
    destructor Destroy; override;

    procedure SeekFrame(AFrame: Int64);
    { Reads up to AMaxFrames sample frames into ADst (grown as needed), starting
      at ADst column 0. Returns the number of frames actually read (0 at EOF). }
    function ReadFrames(var ADst: TAudioPlanar; AMaxFrames: Integer): Integer;
    { Reads every remaining frame into a fresh planar buffer. }
    function ReadAll(out AChannels, ASampleRate: Integer): TAudioPlanar;

    property Info: TWavInfo read FInfo;
    property CurrentFrame: Int64 read FCurrentFrame;
  end;

  { Streaming writer. Writes a JUNK placeholder sized exactly like a ds64 chunk
    so that, if the file turns out to exceed the 32-bit RIFF limit, Finalize can
    promote RIFF->RF64 in place without moving the audio data. Pass AForceRF64
    to emit an RF64 file unconditionally (used by the test-suite; also correct
    for a stream whose final size is not known up front). }
  TWavWriter = class
  private
    FStream: TStream;
    FOwnsStream: Boolean;
    FFormat: TWavSampleFormat;
    FChannels: Integer;
    FSampleRate: Integer;
    FForceRF64: Boolean;
    FFinalized: Boolean;
    FFramesWritten: Int64;
    FDataStart: Int64;
    FRiffSizePos: Int64;
    FJunkTagPos: Int64;
    FDataSizePos: Int64;
    FFactValuePos: Int64;   // 0 when there is no fact chunk
    FArtist: string;        // written to the LIST/INFO IART chunk when non-empty
    procedure WriteHeader;
  public
    constructor Create(const AFileName: string; AFormat: TWavSampleFormat;
      AChannels, ASampleRate: Integer; AForceRF64: Boolean = False;
      const AArtist: string = ''); overload;
    constructor Create(AStream: TStream; AOwnsStream: Boolean;
      AFormat: TWavSampleFormat; AChannels, ASampleRate: Integer;
      AForceRF64: Boolean = False; const AArtist: string = ''); overload;
    destructor Destroy; override;

    procedure WriteFrames(const ASrc: TAudioPlanar; AFrameCount: Integer);
    procedure Finalize;

    property FramesWritten: Int64 read FFramesWritten;
    property SampleFormat: TWavSampleFormat read FFormat;
  end;

{ One-shot helpers. }
function LoadWavFile(const AFileName: string;
  out AChannels, ASampleRate: Integer): TAudioPlanar;
procedure SaveWavFile(const AFileName: string; const ASrc: TAudioPlanar;
  AChannels, ASampleRate, AFrameCount: Integer;
  AFormat: TWavSampleFormat = wsfFloat32; AForceRF64: Boolean = False);

type
  { Plays a WAV file through the device engine / offline renderer. The whole
    file is decoded to memory on construction; playback linear-interpolates from
    the file's sample rate to whatever rate Render is asked for, so a 44.1 kHz
    file plays correctly on a 48 kHz device. }
  TWavPlayerSource = class(TInterfacedObject, IAudioSource)
  private
    FName: string;
    FData: TAudioPlanar;
    FSrcFrames: Integer;
    FSrcChannels: Integer;
    FSrcRate: Integer;
    FLoop: Boolean;
    FPos: Double;          // fractional read position in source frames
    FAtEnd: Boolean;
  public
    constructor Create(const AFileName: string; ALoop: Boolean = False);
    procedure Render(ABuffer: TAudioBuffer);
    procedure Prepare(ASampleRate, AMaxFrames, AChannels: Integer);
    procedure Reset;
    function Name: string;
    property AtEnd: Boolean read FAtEnd;
    property SourceFrames: Integer read FSrcFrames;
    property SourceChannels: Integer read FSrcChannels;
    property SourceRate: Integer read FSrcRate;
  end;

implementation

const
  DS64_BODY_SIZE = 28;   // riffSize u64 + dataSize u64 + sampleCount u64 + tableLen u32

{ ============================ little-endian stream IO ====================== }

procedure WrBytes(S: TStream; const B: array of Byte);
begin
  if Length(B) > 0 then
    S.WriteBuffer(B[0], Length(B));
end;

procedure WrTag(S: TStream; const T: string);
var
  a: array[0..3] of Byte;
  i: Integer;
begin
  if Length(T) <> 4 then
    RaiseUDAW(errInvalidState, CODEC_SUBSYS, 'internal: chunk tag must be 4 chars');
  for i := 0 to 3 do
    a[i] := Byte(Ord(T[i + 1]));
  S.WriteBuffer(a[0], 4);
end;

procedure WrU16(S: TStream; V: Word);
var
  a: array[0..1] of Byte;
begin
  a[0] := Byte(V and $FF);
  a[1] := Byte((V shr 8) and $FF);
  S.WriteBuffer(a[0], 2);
end;

procedure WrU32(S: TStream; V: LongWord);
var
  a: array[0..3] of Byte;
begin
  a[0] := Byte(V and $FF);
  a[1] := Byte((V shr 8) and $FF);
  a[2] := Byte((V shr 16) and $FF);
  a[3] := Byte((V shr 24) and $FF);
  S.WriteBuffer(a[0], 4);
end;

procedure WrU64(S: TStream; V: UInt64);
var
  a: array[0..7] of Byte;
  i: Integer;
begin
  for i := 0 to 7 do
    a[i] := Byte((V shr (8 * i)) and $FF);
  S.WriteBuffer(a[0], 8);
end;

function RdExact(S: TStream; var Buf; Count: Integer): Boolean;
begin
  Result := (Count >= 0) and (S.Read(Buf, Count) = Count);
end;

function RdTag(S: TStream; out T: string): Boolean;
var
  a: array[0..3] of Byte;
begin
  Result := RdExact(S, a[0], 4);
  if Result then
    T := Chr(a[0]) + Chr(a[1]) + Chr(a[2]) + Chr(a[3])
  else
    T := '';
end;

function RdU16(S: TStream; out V: Word): Boolean;
var
  a: array[0..1] of Byte;
begin
  Result := RdExact(S, a[0], 2);
  if Result then
    V := a[0] or (a[1] shl 8)
  else
    V := 0;
end;

function RdU32(S: TStream; out V: LongWord): Boolean;
var
  a: array[0..3] of Byte;
begin
  Result := RdExact(S, a[0], 4);
  if Result then
    V := LongWord(a[0]) or (LongWord(a[1]) shl 8) or
         (LongWord(a[2]) shl 16) or (LongWord(a[3]) shl 24)
  else
    V := 0;
end;

function RdU64(S: TStream; out V: UInt64): Boolean;
var
  a: array[0..7] of Byte;
  i: Integer;
begin
  Result := RdExact(S, a[0], 8);
  V := 0;
  if Result then
    for i := 0 to 7 do
      V := V or (UInt64(a[i]) shl (8 * i));
end;

{ ============================ format descriptors ========================== }

function WavSampleFormatName(AFmt: TWavSampleFormat): string;
begin
  case AFmt of
    wsfPCM8:    Result := 'PCM 8-bit';
    wsfPCM16:   Result := 'PCM 16-bit';
    wsfPCM24:   Result := 'PCM 24-bit';
    wsfPCM32:   Result := 'PCM 32-bit';
    wsfFloat32: Result := 'IEEE float 32-bit';
    wsfFloat64: Result := 'IEEE float 64-bit';
  else
    Result := 'unknown';
  end;
end;

function WavSampleFormatBytes(AFmt: TWavSampleFormat): Integer;
begin
  case AFmt of
    wsfPCM8:    Result := 1;
    wsfPCM16:   Result := 2;
    wsfPCM24:   Result := 3;
    wsfPCM32:   Result := 4;
    wsfFloat32: Result := 4;
    wsfFloat64: Result := 8;
  else
    Result := 0;
  end;
end;

function WavSampleFormatBits(AFmt: TWavSampleFormat): Integer;
begin
  Result := WavSampleFormatBytes(AFmt) * 8;
end;

function WavIsFloat(AFmt: TWavSampleFormat): Boolean;
begin
  Result := AFmt in [wsfFloat32, wsfFloat64];
end;

function MapWavFormat(ATag: Word; ABits: Integer): TWavSampleFormat;
begin
  Result := wsfUnknown;
  if ATag = WAVE_FORMAT_PCM then
    case ABits of
      8:  Result := wsfPCM8;
      16: Result := wsfPCM16;
      24: Result := wsfPCM24;
      32: Result := wsfPCM32;
    end
  else if ATag = WAVE_FORMAT_IEEE_FLOAT then
    case ABits of
      32: Result := wsfFloat32;
      64: Result := wsfFloat64;
    end;
end;

function DefaultChannelMask(AChannels: Integer): LongWord;
begin
  case AChannels of
    1: Result := $00000004;                        // FRONT_CENTER
    2: Result := $00000003;                        // FL | FR
    3: Result := $00000007;                        // FL | FR | FC
    4: Result := $00000033;                        // FL FR BL BR
    6: Result := $0000003F;                        // 5.1
    8: Result := $000000FF;                        // 7.1
  else
    Result := 0;
  end;
end;

{ ============================ TWavInfo =================================== }

function TWavInfo.BytesPerSample: Integer;
begin
  Result := WavSampleFormatBytes(SampleFormat);
end;

function TWavInfo.BytesPerFrame: Integer;
begin
  Result := WavSampleFormatBytes(SampleFormat) * Channels;
end;

function TWavInfo.DurationSeconds: Double;
begin
  if SampleRate > 0 then
    Result := FrameCount / SampleRate
  else
    Result := 0;
end;

function TWavInfo.Describe: string;
begin
  Result := Format('%s, %d ch, %d Hz, %d frames (%.3f s), %s%s, data %d bytes @ %d',
    [WavSampleFormatName(SampleFormat), Channels, SampleRate, FrameCount,
     DurationSeconds,
     IfThen(IsRF64, 'RF64', 'RIFF'),
     IfThen(IsExtensible, '/EXTENSIBLE', ''),
     DataSize, DataOffset]);
end;

{ ============================ signature sniffing ========================= }

function DataLooksLikeWav(const AData; ALength: Integer): Boolean;
var
  p: PByte;
  riff, wave: string;
  i: Integer;
begin
  Result := False;
  if ALength < 12 then Exit;
  p := @AData;
  riff := '';
  for i := 0 to 3 do riff := riff + Chr(p[i]);
  wave := '';
  for i := 8 to 11 do wave := wave + Chr(p[i]);
  Result := ((riff = 'RIFF') or (riff = 'RF64') or (riff = 'BW64')) and (wave = 'WAVE');
end;

function FileLooksLikeWav(const AFileName: string): Boolean;
var
  fs: TFileStream;
  buf: array[0..11] of Byte;
  n: Integer;
begin
  Result := False;
  if not FileExists(AFileName) then Exit;
  try
    fs := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
    try
      n := fs.Read(buf[0], SizeOf(buf));
      Result := DataLooksLikeWav(buf[0], n);
    finally
      fs.Free;
    end;
  except
    Result := False;
  end;
end;

{ ============================ block conversion ========================== }

function ClampUnit(V: Single): Single;
begin
  if V > 1.0 then Result := 1.0
  else if V < -1.0 then Result := -1.0
  else if V <> V then Result := 0.0   // NaN
  else Result := V;
end;

procedure DecodeWavBlock(const ARaw: TBytes; AFmt: TWavSampleFormat;
  AChannels, AFrames, ADstOffset: Integer; var ADst: TAudioPlanar);
var
  idx, frame, ch, k: Integer;
  v: Integer;
  u32: LongWord;
  u64: UInt64;
begin
  idx := 0;
  for frame := 0 to AFrames - 1 do
    for ch := 0 to AChannels - 1 do
    begin
      case AFmt of
        wsfPCM8:
          begin
            ADst[ch][ADstOffset + frame] := (Integer(ARaw[idx]) - 128) / 128.0;
            Inc(idx);
          end;
        wsfPCM16:
          begin
            v := SmallInt(ARaw[idx] or (ARaw[idx + 1] shl 8));
            ADst[ch][ADstOffset + frame] := v / 32768.0;
            Inc(idx, 2);
          end;
        wsfPCM24:
          begin
            v := ARaw[idx] or (ARaw[idx + 1] shl 8) or (ARaw[idx + 2] shl 16);
            if (v and $800000) <> 0 then
              v := v or Integer($FF000000);
            ADst[ch][ADstOffset + frame] := v / 8388608.0;
            Inc(idx, 3);
          end;
        wsfPCM32:
          begin
            u32 := LongWord(ARaw[idx]) or (LongWord(ARaw[idx + 1]) shl 8) or
                   (LongWord(ARaw[idx + 2]) shl 16) or (LongWord(ARaw[idx + 3]) shl 24);
            ADst[ch][ADstOffset + frame] := Integer(u32) / 2147483648.0;
            Inc(idx, 4);
          end;
        wsfFloat32:
          begin
            u32 := LongWord(ARaw[idx]) or (LongWord(ARaw[idx + 1]) shl 8) or
                   (LongWord(ARaw[idx + 2]) shl 16) or (LongWord(ARaw[idx + 3]) shl 24);
            ADst[ch][ADstOffset + frame] := PSingle(@u32)^;
            Inc(idx, 4);
          end;
        wsfFloat64:
          begin
            u64 := 0;
            for k := 0 to 7 do
              u64 := u64 or (UInt64(ARaw[idx + k]) shl (8 * k));
            ADst[ch][ADstOffset + frame] := PDouble(@u64)^;
            Inc(idx, 8);
          end;
      else
        RaiseUDAW(errConfig, CODEC_SUBSYS, 'decode: unsupported sample format');
      end;
    end;
end;

procedure EncodeWavBlock(const ASrc: TAudioPlanar; ASrcOffset, AChannels,
  AFrames: Integer; AFmt: TWavSampleFormat; out ARaw: TBytes);
var
  idx, frame, ch, k, iv: Integer;
  fs: Single;
  d: Double;
  u32: LongWord;
  u64: UInt64;
begin
  SetLength(ARaw, Int64(AFrames) * AChannels * WavSampleFormatBytes(AFmt));
  idx := 0;
  for frame := 0 to AFrames - 1 do
    for ch := 0 to AChannels - 1 do
    begin
      fs := ASrc[ch][ASrcOffset + frame];
      case AFmt of
        wsfPCM8:
          begin
            iv := Round(ClampUnit(fs) * 127.0) + 128;
            if iv < 0 then iv := 0 else if iv > 255 then iv := 255;
            ARaw[idx] := Byte(iv);
            Inc(idx);
          end;
        wsfPCM16:
          begin
            iv := Round(ClampUnit(fs) * 32767.0);
            if iv > 32767 then iv := 32767 else if iv < -32768 then iv := -32768;
            ARaw[idx]     := Byte(iv and $FF);
            ARaw[idx + 1] := Byte((iv shr 8) and $FF);
            Inc(idx, 2);
          end;
        wsfPCM24:
          begin
            iv := Round(ClampUnit(fs) * 8388607.0);
            if iv > 8388607 then iv := 8388607
            else if iv < -8388608 then iv := -8388608;
            ARaw[idx]     := Byte(iv and $FF);
            ARaw[idx + 1] := Byte((iv shr 8) and $FF);
            ARaw[idx + 2] := Byte((iv shr 16) and $FF);
            Inc(idx, 3);
          end;
        wsfPCM32:
          begin
            d := ClampUnit(fs) * 2147483647.0;
            if d >= 2147483647.0 then u32 := $7FFFFFFF
            else if d <= -2147483648.0 then u32 := $80000000
            else u32 := LongWord(Round(d));
            ARaw[idx]     := Byte(u32 and $FF);
            ARaw[idx + 1] := Byte((u32 shr 8) and $FF);
            ARaw[idx + 2] := Byte((u32 shr 16) and $FF);
            ARaw[idx + 3] := Byte((u32 shr 24) and $FF);
            Inc(idx, 4);
          end;
        wsfFloat32:
          begin
            u32 := PLongWord(@fs)^;
            ARaw[idx]     := Byte(u32 and $FF);
            ARaw[idx + 1] := Byte((u32 shr 8) and $FF);
            ARaw[idx + 2] := Byte((u32 shr 16) and $FF);
            ARaw[idx + 3] := Byte((u32 shr 24) and $FF);
            Inc(idx, 4);
          end;
        wsfFloat64:
          begin
            d := fs;
            u64 := PUInt64(@d)^;
            for k := 0 to 7 do
              ARaw[idx + k] := Byte((u64 shr (8 * k)) and $FF);
            Inc(idx, 8);
          end;
      else
        RaiseUDAW(errConfig, CODEC_SUBSYS, 'encode: unsupported sample format');
      end;
    end;
end;

{ ============================ TWavReader =============================== }

constructor TWavReader.Create(const AFileName: string);
begin
  inherited Create;
  if not FileExists(AFileName) then
    RaiseUDAWFmt(errFileNotFound, CODEC_SUBSYS, 'WAV file not found: %s', [AFileName]);
  FStream := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
  FOwnsStream := True;
  try
    ParseHeader;
  except
    FStream.Free;
    FStream := nil;
    raise;
  end;
end;

constructor TWavReader.Create(AStream: TStream; AOwnsStream: Boolean);
begin
  inherited Create;
  if AStream = nil then
    RaiseUDAW(errInvalidArgument, CODEC_SUBSYS, 'TWavReader: nil stream');
  FStream := AStream;
  FOwnsStream := AOwnsStream;
  ParseHeader;
end;

destructor TWavReader.Destroy;
begin
  if FOwnsStream then
    FStream.Free;
  inherited Destroy;
end;

procedure TWavReader.ParseHeader;
var
  tag, sub: string;
  riffSize, chunkSize, factU: LongWord;
  fmtTag, wBits, cbSize, subTag, wChans: Word;
  wSampleRate, wAvgBytes: LongWord;
  wBlockAlign: Word;
  ds64RiffSize, ds64DataSize, ds64SampleCount: UInt64;
  ds64TableLen: LongWord;
  haveFmt, haveData: Boolean;
  consumed: Integer;
  skip: Int64;
  raw14: array[0..13] of Byte;
begin
  FillChar(FInfo, SizeOf(FInfo), 0);
  FInfo.SampleFormat := wsfUnknown;
  FStream.Position := 0;

  if not RdTag(FStream, tag) then
    RaiseUDAW(errConfig, CODEC_SUBSYS, 'not a WAV file (truncated header)');
  if (tag <> 'RIFF') and (tag <> 'RF64') and (tag <> 'BW64') then
    RaiseUDAWFmt(errConfig, CODEC_SUBSYS, 'not a RIFF/RF64 container (tag "%s")', [tag]);
  FInfo.IsRF64 := (tag = 'RF64') or (tag = 'BW64');

  if not RdU32(FStream, riffSize) then
    RaiseUDAW(errConfig, CODEC_SUBSYS, 'truncated RIFF size');
  if not RdTag(FStream, sub) then
    RaiseUDAW(errConfig, CODEC_SUBSYS, 'truncated WAVE tag');
  if sub <> 'WAVE' then
    RaiseUDAWFmt(errConfig, CODEC_SUBSYS, 'RIFF form is "%s", not "WAVE"', [sub]);

  ds64DataSize := 0;
  ds64SampleCount := 0;
  ds64RiffSize := 0;

  if FInfo.IsRF64 then
  begin
    if not RdTag(FStream, tag) then
      RaiseUDAW(errConfig, CODEC_SUBSYS, 'RF64: missing ds64 chunk');
    if tag <> 'ds64' then
      RaiseUDAWFmt(errConfig, CODEC_SUBSYS, 'RF64: first chunk is "%s", expected "ds64"', [tag]);
    if not RdU32(FStream, chunkSize) then
      RaiseUDAW(errConfig, CODEC_SUBSYS, 'RF64: truncated ds64 size');
    if chunkSize < DS64_BODY_SIZE then
      RaiseUDAW(errConfig, CODEC_SUBSYS, 'RF64: ds64 chunk too small');
    if not (RdU64(FStream, ds64RiffSize) and RdU64(FStream, ds64DataSize) and
            RdU64(FStream, ds64SampleCount) and RdU32(FStream, ds64TableLen)) then
      RaiseUDAW(errConfig, CODEC_SUBSYS, 'RF64: truncated ds64 body');
    skip := Int64(chunkSize) - DS64_BODY_SIZE;
    if (chunkSize and 1) <> 0 then Inc(skip);   // pad
    if skip > 0 then
      FStream.Position := FStream.Position + skip;
  end;

  haveFmt := False;
  haveData := False;
  FillChar(raw14, SizeOf(raw14), 0);

  while (not haveFmt) or (not haveData) do
  begin
    if not RdTag(FStream, tag) then
      Break;
    if not RdU32(FStream, chunkSize) then
      Break;

    if tag = 'fmt ' then
    begin
      if chunkSize < 16 then
        RaiseUDAW(errConfig, CODEC_SUBSYS, '"fmt " chunk shorter than 16 bytes');
      RdU16(FStream, fmtTag);
      RdU16(FStream, wChans);
      RdU32(FStream, wSampleRate);
      RdU32(FStream, wAvgBytes);
      RdU16(FStream, wBlockAlign);
      RdU16(FStream, wBits);
      consumed := 16;
      FInfo.IsExtensible := (fmtTag = WAVE_FORMAT_EXTENSIBLE);
      if chunkSize >= 18 then
      begin
        RdU16(FStream, cbSize);
        Inc(consumed, 2);
        if FInfo.IsExtensible and (cbSize >= 22) and (chunkSize >= 40) then
        begin
          RdU16(FStream, subTag);            // valid bits per sample
          RdU32(FStream, FInfo.ChannelMask);
          RdU16(FStream, subTag);            // SubFormat tag (real format)
          RdExact(FStream, raw14[0], 14);    // fixed GUID suffix, ignored
          Inc(consumed, 22);
          fmtTag := subTag;
        end;
      end;
      skip := Int64(chunkSize) - consumed;
      if (chunkSize and 1) <> 0 then Inc(skip);
      if skip > 0 then
        FStream.Position := FStream.Position + skip;

      FInfo.Channels := wChans;
      FInfo.SampleRate := Integer(wSampleRate);
      FInfo.BitsPerSample := wBits;
      FInfo.SampleFormat := MapWavFormat(fmtTag, wBits);
      if FInfo.SampleFormat = wsfUnknown then
        RaiseUDAWFmt(errConfig, CODEC_SUBSYS,
          'unsupported WAV sample format (tag $%x, %d bits)', [fmtTag, wBits]);
      if (FInfo.Channels < 1) or (FInfo.Channels > UDAW_MAX_CHANNELS) then
        RaiseUDAWFmt(errConfig, CODEC_SUBSYS, 'WAV channel count %d out of range',
          [FInfo.Channels]);
      if FInfo.SampleRate <= 0 then
        RaiseUDAW(errConfig, CODEC_SUBSYS, 'WAV sample rate is zero');
      haveFmt := True;
    end
    else if tag = 'data' then
    begin
      FInfo.DataOffset := FStream.Position;
      if FInfo.IsRF64 and (chunkSize = $FFFFFFFF) then
        FInfo.DataSize := Int64(ds64DataSize)
      else
        FInfo.DataSize := Int64(chunkSize);
      if FInfo.DataOffset + FInfo.DataSize > FStream.Size then
        FInfo.DataSize := FStream.Size - FInfo.DataOffset;   // tolerate truncation
      if FInfo.DataSize < 0 then
        FInfo.DataSize := 0;
      haveData := True;
      skip := FInfo.DataSize;
      if (FInfo.DataSize and 1) <> 0 then Inc(skip);
      FStream.Position := FInfo.DataOffset + skip;
    end
    else if tag = 'fact' then
    begin
      RdU32(FStream, factU);
      skip := Int64(chunkSize) - 4;
      if (chunkSize and 1) <> 0 then Inc(skip);
      if skip > 0 then
        FStream.Position := FStream.Position + skip;
    end
    else
    begin
      skip := Int64(chunkSize);
      if (chunkSize and 1) <> 0 then Inc(skip);
      if FStream.Position + skip > FStream.Size then
        Break;
      FStream.Position := FStream.Position + skip;
    end;
  end;

  if not haveFmt then
    RaiseUDAW(errConfig, CODEC_SUBSYS, 'WAV has no "fmt " chunk');
  if not haveData then
    RaiseUDAW(errConfig, CODEC_SUBSYS, 'WAV has no "data" chunk');

  FInfo.FrameCount := FInfo.DataSize div FInfo.BytesPerFrame;
  if FInfo.IsRF64 and (ds64SampleCount > 0) and
     (Int64(ds64SampleCount) < FInfo.FrameCount) then
    FInfo.FrameCount := Int64(ds64SampleCount);

  FStream.Position := FInfo.DataOffset;
  FCurrentFrame := 0;
end;

procedure TWavReader.SeekFrame(AFrame: Int64);
begin
  if AFrame < 0 then AFrame := 0;
  if AFrame > FInfo.FrameCount then AFrame := FInfo.FrameCount;
  FStream.Position := FInfo.DataOffset + AFrame * FInfo.BytesPerFrame;
  FCurrentFrame := AFrame;
end;

function TWavReader.ReadFrames(var ADst: TAudioPlanar; AMaxFrames: Integer): Integer;
var
  n, bpf, got: Integer;
  raw: TBytes;
begin
  Result := 0;
  if AMaxFrames <= 0 then Exit;
  n := AMaxFrames;
  if FCurrentFrame + n > FInfo.FrameCount then
    n := Integer(FInfo.FrameCount - FCurrentFrame);
  if n <= 0 then Exit;

  bpf := FInfo.BytesPerFrame;
  SetLength(raw, Int64(n) * bpf);
  got := FStream.Read(raw[0], Length(raw));
  if got < Length(raw) then
  begin
    n := got div bpf;               // partial tail read
    if n <= 0 then Exit;
    SetLength(raw, n * bpf);
  end;

  EnsurePlanar(ADst, FInfo.Channels, n);
  DecodeWavBlock(raw, FInfo.SampleFormat, FInfo.Channels, n, 0, ADst);
  Inc(FCurrentFrame, n);
  ReportMediaProgress('Reading WAV', FCurrentFrame, FInfo.FrameCount, FInfo.SampleRate);
  Result := n;
end;

function TWavReader.ReadAll(out AChannels, ASampleRate: Integer): TAudioPlanar;
const
  BLOCK = 65536;
var
  total, done, n, ch, i: Integer;
  scratch: TAudioPlanar;
begin
  AChannels := FInfo.Channels;
  ASampleRate := FInfo.SampleRate;
  total := Integer(FInfo.FrameCount - FCurrentFrame);
  if total < 0 then total := 0;

  SetLength(Result, FInfo.Channels);
  for ch := 0 to FInfo.Channels - 1 do
    SetLength(Result[ch], total);

  done := 0;
  while done < total do
  begin
    n := ReadFrames(scratch, Min(BLOCK, total - done));
    if n <= 0 then Break;
    for ch := 0 to FInfo.Channels - 1 do
      for i := 0 to n - 1 do
        Result[ch][done + i] := scratch[ch][i];
    Inc(done, n);
  end;

  if done <> total then
    for ch := 0 to FInfo.Channels - 1 do
      SetLength(Result[ch], done);
end;

{ ============================ TWavWriter =============================== }

constructor TWavWriter.Create(const AFileName: string; AFormat: TWavSampleFormat;
  AChannels, ASampleRate: Integer; AForceRF64: Boolean; const AArtist: string);
var
  dir: string;
  fs: TFileStream;
begin
  dir := ExtractFilePath(AFileName);
  if dir <> '' then
    ForceDirectories(dir);
  fs := TFileStream.Create(AFileName, fmCreate);
  Create(fs, True, AFormat, AChannels, ASampleRate, AForceRF64, AArtist);
end;

constructor TWavWriter.Create(AStream: TStream; AOwnsStream: Boolean;
  AFormat: TWavSampleFormat; AChannels, ASampleRate: Integer; AForceRF64: Boolean;
  const AArtist: string);
begin
  inherited Create;
  if AStream = nil then
    RaiseUDAW(errInvalidArgument, CODEC_SUBSYS, 'TWavWriter: nil stream');
  if WavSampleFormatBytes(AFormat) = 0 then
    RaiseUDAW(errInvalidArgument, CODEC_SUBSYS, 'TWavWriter: unknown sample format');
  if (AChannels < 1) or (AChannels > UDAW_MAX_CHANNELS) then
    RaiseUDAWFmt(errInvalidArgument, CODEC_SUBSYS, 'TWavWriter: channel count %d out of range', [AChannels]);
  if ASampleRate <= 0 then
    RaiseUDAW(errInvalidArgument, CODEC_SUBSYS, 'TWavWriter: sample rate must be positive');

  FStream := AStream;
  FOwnsStream := AOwnsStream;
  FFormat := AFormat;
  FChannels := AChannels;
  FSampleRate := ASampleRate;
  FForceRF64 := AForceRF64;
  FArtist := Trim(AArtist);
  WriteHeader;
end;

destructor TWavWriter.Destroy;
begin
  try
    if not FFinalized then
      Finalize;
  finally
    if FOwnsStream then
      FStream.Free;
  end;
  inherited Destroy;
end;

procedure TWavWriter.WriteHeader;
var
  useExt: Boolean;
  blockAlign, fmtSize: Integer;
  effTag: Word;
  stamp, artistStamp: AnsiString;
  zero: Byte;
begin
  useExt := FChannels > 2;
  if WavIsFloat(FFormat) then
    effTag := WAVE_FORMAT_IEEE_FLOAT
  else
    effTag := WAVE_FORMAT_PCM;
  blockAlign := FChannels * WavSampleFormatBytes(FFormat);

  FStream.Position := 0;
  if FForceRF64 then
    WrTag(FStream, 'RF64')
  else
    WrTag(FStream, 'RIFF');
  FRiffSizePos := FStream.Position;
  if FForceRF64 then WrU32(FStream, $FFFFFFFF) else WrU32(FStream, 0);
  WrTag(FStream, 'WAVE');

  { ds64 placeholder (as JUNK unless we are already committed to RF64) so the
    audio data never has to move if the file grows past 4 GiB. }
  FJunkTagPos := FStream.Position;
  if FForceRF64 then WrTag(FStream, 'ds64') else WrTag(FStream, 'JUNK');
  WrU32(FStream, DS64_BODY_SIZE);
  WrU64(FStream, 0);   // riffSize
  WrU64(FStream, 0);   // dataSize
  WrU64(FStream, 0);   // sampleCount
  WrU32(FStream, 0);   // table length

  { fmt }
  if useExt then fmtSize := 40 else fmtSize := 16;
  WrTag(FStream, 'fmt ');
  WrU32(FStream, LongWord(fmtSize));
  if useExt then
    WrU16(FStream, WAVE_FORMAT_EXTENSIBLE)
  else
    WrU16(FStream, effTag);
  WrU16(FStream, Word(FChannels));
  WrU32(FStream, LongWord(FSampleRate));
  WrU32(FStream, LongWord(FSampleRate * blockAlign));
  WrU16(FStream, Word(blockAlign));
  WrU16(FStream, Word(WavSampleFormatBits(FFormat)));
  if useExt then
  begin
    WrU16(FStream, 22);                                  // cbSize
    WrU16(FStream, Word(WavSampleFormatBits(FFormat)));  // valid bits
    WrU32(FStream, DefaultChannelMask(FChannels));
    WrU16(FStream, effTag);                              // SubFormat data1 low
    WrBytes(FStream, [$00, $00, $00, $00, $10, $00, $80, $00,
                      $00, $AA, $00, $38, $9B, $71]);    // fixed GUID suffix
  end;

  { fact - required for non-PCM; also written for EXTENSIBLE }
  if WavIsFloat(FFormat) or useExt then
  begin
    WrTag(FStream, 'fact');
    WrU32(FStream, 4);
    FFactValuePos := FStream.Position;
    WrU32(FStream, 0);
  end
  else
    FFactValuePos := 0;

  stamp := AnsiString(UDAW_MEDIA_COPYRIGHT) + #0;
  artistStamp := UTF8Encode(FArtist);
  if artistStamp <> '' then artistStamp := artistStamp + #0;
  zero := 0;
  WrTag(FStream, 'LIST');
  WrU32(FStream, 12 + Length(stamp) + (Length(stamp) and 1) +
    IfThen(artistStamp <> '', 8 + Length(artistStamp) + (Length(artistStamp) and 1), 0));
  WrTag(FStream, 'INFO');
  if artistStamp <> '' then
  begin
    WrTag(FStream, 'IART');
    WrU32(FStream, Length(artistStamp));
    FStream.WriteBuffer(artistStamp[1], Length(artistStamp));
    if Odd(Length(artistStamp)) then FStream.WriteBuffer(zero, 1);
  end;
  WrTag(FStream, 'ICOP');
  WrU32(FStream, Length(stamp));
  FStream.WriteBuffer(stamp[1], Length(stamp));
  if Odd(Length(stamp)) then FStream.WriteBuffer(zero, 1);
  { data }
  WrTag(FStream, 'data');
  FDataSizePos := FStream.Position;
  if FForceRF64 then WrU32(FStream, $FFFFFFFF) else WrU32(FStream, 0);
  FDataStart := FStream.Position;
end;

procedure TWavWriter.WriteFrames(const ASrc: TAudioPlanar; AFrameCount: Integer);
var
  raw: TBytes;
begin
  if FFinalized then
    RaiseUDAW(errInvalidState, CODEC_SUBSYS, 'TWavWriter: already finalized');
  if AFrameCount <= 0 then Exit;
  if Length(ASrc) < FChannels then
    RaiseUDAWFmt(errInvalidArgument, CODEC_SUBSYS,
      'WriteFrames: source has %d channels, writer needs %d', [Length(ASrc), FChannels]);
  EncodeWavBlock(ASrc, 0, FChannels, AFrameCount, FFormat, raw);
  FStream.WriteBuffer(raw[0], Length(raw));
  Inc(FFramesWritten, AFrameCount);
end;

procedure TWavWriter.Finalize;
var
  dataBytes, riffSize, fileEnd: Int64;
  needRF64: Boolean;
  pad: Byte;
begin
  if FFinalized then Exit;
  FFinalized := True;

  dataBytes := FFramesWritten * FChannels * WavSampleFormatBytes(FFormat);

  { data chunk pad byte for odd length }
  if (dataBytes and 1) <> 0 then
  begin
    FStream.Position := FDataStart + dataBytes;
    pad := 0;
    FStream.WriteBuffer(pad, 1);
  end;

  fileEnd := FDataStart + dataBytes + Ord((dataBytes and 1) <> 0);
  riffSize := fileEnd - 8;
  needRF64 := FForceRF64 or (riffSize > $FFFFFFFF) or (dataBytes > $FFFFFFFF);

  if needRF64 then
  begin
    FStream.Position := 0;
    WrTag(FStream, 'RF64');
    FStream.Position := FRiffSizePos;
    WrU32(FStream, $FFFFFFFF);
    FStream.Position := FJunkTagPos;
    WrTag(FStream, 'ds64');
    FStream.Position := FJunkTagPos + 8;      // past tag + size
    WrU64(FStream, UInt64(riffSize));
    WrU64(FStream, UInt64(dataBytes));
    WrU64(FStream, UInt64(FFramesWritten));
    WrU32(FStream, 0);
    FStream.Position := FDataSizePos;
    WrU32(FStream, $FFFFFFFF);
  end
  else
  begin
    FStream.Position := FRiffSizePos;
    WrU32(FStream, LongWord(riffSize));
    FStream.Position := FDataSizePos;
    WrU32(FStream, LongWord(dataBytes));
  end;

  if FFactValuePos <> 0 then
  begin
    FStream.Position := FFactValuePos;
    WrU32(FStream, LongWord(FFramesWritten));
  end;

  FStream.Position := fileEnd;
end;

{ ============================ one-shot helpers ========================= }

function ReadWavInfo(const AFileName: string): TWavInfo;
var
  r: TWavReader;
begin
  r := TWavReader.Create(AFileName);
  try
    Result := r.Info;
  finally
    r.Free;
  end;
end;

function LoadWavFile(const AFileName: string;
  out AChannels, ASampleRate: Integer): TAudioPlanar;
var
  r: TWavReader;
begin
  r := TWavReader.Create(AFileName);
  try
    Result := r.ReadAll(AChannels, ASampleRate);
  finally
    r.Free;
  end;
end;

procedure SaveWavFile(const AFileName: string; const ASrc: TAudioPlanar;
  AChannels, ASampleRate, AFrameCount: Integer; AFormat: TWavSampleFormat;
  AForceRF64: Boolean);
var
  w: TWavWriter;
begin
  w := TWavWriter.Create(AFileName, AFormat, AChannels, ASampleRate, AForceRF64);
  try
    if AFrameCount > 0 then
      w.WriteFrames(ASrc, AFrameCount);
    w.Finalize;
  finally
    w.Free;
  end;
end;

{ ============================ TWavPlayerSource ======================== }

constructor TWavPlayerSource.Create(const AFileName: string; ALoop: Boolean);
var
  ch, sr: Integer;
begin
  inherited Create;
  FData := LoadWavFile(AFileName, ch, sr);
  FSrcChannels := ch;
  FSrcRate := sr;
  if Length(FData) > 0 then
    FSrcFrames := Length(FData[0])
  else
    FSrcFrames := 0;
  FLoop := ALoop;
  FName := Format('wav "%s" (%d Hz, %d ch, %d frames)',
    [ExtractFileName(AFileName), FSrcRate, FSrcChannels, FSrcFrames]);
  Reset;
end;

procedure TWavPlayerSource.Prepare(ASampleRate, AMaxFrames, AChannels: Integer);
begin
  { nothing to allocate - the file is already resident and Render adapts the
    rate to whatever ABuffer asks for }
end;

procedure TWavPlayerSource.Reset;
begin
  FPos := 0;
  FAtEnd := FSrcFrames = 0;
end;

function TWavPlayerSource.Name: string;
begin
  Result := FName;
end;

procedure TWavPlayerSource.Render(ABuffer: TAudioBuffer);
var
  i, ch, i0, i1, srcCh: Integer;
  ratio, frac, a, b: Double;
  d: PAudioSample;
begin
  ABuffer.Clear;
  if (FSrcFrames <= 0) or (FSrcChannels <= 0) then
  begin
    FAtEnd := True;
    Exit;
  end;
  if ABuffer.SampleRate > 0 then
    ratio := FSrcRate / ABuffer.SampleRate
  else
    ratio := 1.0;

  for i := 0 to ABuffer.FrameCount - 1 do
  begin
    if FPos >= FSrcFrames then
    begin
      if FLoop then
        FPos := FPos - FSrcFrames * Floor(FPos / FSrcFrames)
      else
      begin
        FAtEnd := True;
        Break;
      end;
    end;

    i0 := Floor(FPos);
    frac := FPos - i0;
    i1 := i0 + 1;
    if i1 >= FSrcFrames then
    begin
      if FLoop then i1 := 0 else i1 := FSrcFrames - 1;
    end;

    for ch := 0 to ABuffer.ChannelCount - 1 do
    begin
      if ch < FSrcChannels then srcCh := ch
      else srcCh := FSrcChannels - 1;          // duplicate last channel (mono->stereo)
      a := FData[srcCh][i0];
      b := FData[srcCh][i1];
      d := ABuffer.ChannelPtr(ch);
      Inc(d, i);
      d^ := Single(a + (b - a) * frac);
    end;

    FPos := FPos + ratio;
    if (not FLoop) and (FPos >= FSrcFrames) then
      FAtEnd := True;
  end;
end;

end.
