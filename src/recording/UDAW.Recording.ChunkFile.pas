unit UDAW.Recording.ChunkFile;
{$I udaw.inc}

{ Phase 8 - Recording: the recoverable, disk-streaming take container
  (plan section 22 "Recording must use disk streaming" + "RECOVERY: record to
  recoverable temporary chunks ... rebuild header/index ... offer recovery").

  A take lives in its own directory:

     <sessionDir>/
        take.meta          key=value header (rate, channels, name, status, ...)
        audio.pcm          raw interleaved Float32 samples, appended as they arrive
        audio.idx          append-only journal: one 16-byte record per flush,
                           (framesTotal:Int64, wallClockMs:Int64), little-endian
        take.inprogress    marker file, deleted only by a clean Finalize

  TRecordingChunkWriter buffers at most REC_WRITER_FLUSH_FRAMES frames before
  forcing them to disk, so a multi-hour take never grows the process RSS. Every
  flush also appends a journal record and (best effort) FlushFileBuffers, so a
  hard crash loses at most one un-journalled flush.

  TRecordingChunkReader reads a container back. RebuildIndex reconstructs the
  usable frame count purely from what survived on disk:
    * the audio.pcm size floored to a whole frame  (torn tail write discarded)
    * capped to the last fully-journalled frame count when the journal is intact
  so a container left behind by a crashed session still yields every fully
  written sample and nothing past the last good one.

  The PCM store is always canonical Float32; the requested TWavSampleFormat is
  applied only when FinalizeToWav encodes the real .wav. }

interface

uses
  {$IFDEF UDAW_WINDOWS}Windows,{$ENDIF}
  SysUtils, Classes, Math,
  UDAW.Errors, UDAW.Audio.Types,
  UDAW.Codec.WAV,
  UDAW.Recording.Types;

type
  TRecordingChunkWriter = class
  private
    FSessionDir: string;
    FSampleRate: Integer;
    FChannels: Integer;
    FName: string;
    FTimelineStartSeconds: Double;
    FSourceOffsetSeconds: Double;
    FPassIndex: Integer;
    FStartedUTC: TDateTime;

    FPcm: TFileStream;
    FIdx: TFileStream;
    FBuf: TAudioSampleArray;   // interleaved Float32 staging
    FBufFrames: Integer;
    FFramesWritten: Int64;
    FFramesOnDisk: Int64;
    FFinalized: Boolean;
    FBytesPerFrame: Integer;

    procedure WriteMeta(AStatus: TTakeStatus);
    procedure AppendIndexRecord;
  public
    constructor Create(const ASessionDir: string; ASampleRate, AChannels: Integer;
      const AName: string; ATimelineStartSeconds: Double;
      APassIndex: Integer = 0; ASourceOffsetSeconds: Double = 0);
    destructor Destroy; override;

    { Append AFrames interleaved Float32 frames. Buffered; a full staging buffer
      is flushed automatically. }
    procedure WriteInterleaved(const ASrc; AFrames: Integer);
    { Append AFrames from a planar Float32 buffer (column 0..AFrames-1). }
    procedure WritePlanar(const ASrc: TAudioPlanar; AFrames: Integer);
    { Force the staging buffer to disk and append a journal record. }
    procedure Flush;
    { Flush, journal the final count, mark the container finalized and drop the
      in-progress marker. Idempotent. }
    procedure Finalize(AKeepRecoveryMarker: Boolean = False);
    { Abort: flush what we have but LEAVE the marker so recovery can offer it. }
    procedure Abandon;

    property SessionDir: string read FSessionDir;
    property FramesWritten: Int64 read FFramesWritten;
    property SampleRate: Integer read FSampleRate;
    property Channels: Integer read FChannels;
    property Name: string read FName write FName;
    property TimelineStartSeconds: Double read FTimelineStartSeconds write FTimelineStartSeconds;
    property SourceOffsetSeconds: Double read FSourceOffsetSeconds;
    property PassIndex: Integer read FPassIndex;
  end;

  TRecordingChunkReader = class
  private
    FSessionDir: string;
    FSampleRate: Integer;
    FChannels: Integer;
    FName: string;
    FStatus: TTakeStatus;
    FTimelineStartSeconds: Double;
    FSourceOffsetSeconds: Double;
    FPassIndex: Integer;
    FStartedUTC: TDateTime;
    FMetaFrameCount: Int64;     // frame count recorded in the meta (0 if unknown)
    FUsableFrames: Int64;       // set by RebuildIndex
    FBytesPerFrame: Integer;
    procedure ParseMeta;
  public
    constructor Create(const ASessionDir: string);

    { Reconstruct the usable frame count from what is on disk. Safe to call on a
      container from a crashed session. Sets UsableFrames and returns it. }
    function RebuildIndex: Int64;

    { Stream the usable audio into a fresh planar buffer. }
    function ReadAllPlanar: TAudioPlanar;
    { Encode the usable audio into a real .wav at APath using AFormat. Returns
      the frame count written. }
    function FinalizeToWav(const AWavPath: string;
      AFormat: TWavSampleFormat = wsfFloat32): Int64;

    function IsInProgress: Boolean;
    function ToRecordedTake: TRecordedTake;

    property SessionDir: string read FSessionDir;
    property SampleRate: Integer read FSampleRate;
    property Channels: Integer read FChannels;
    property Name: string read FName;
    property Status: TTakeStatus read FStatus;
    property UsableFrames: Int64 read FUsableFrames;
    property TimelineStartSeconds: Double read FTimelineStartSeconds;
    property SourceOffsetSeconds: Double read FSourceOffsetSeconds;
    property PassIndex: Integer read FPassIndex;
    property StartedUTC: TDateTime read FStartedUTC;
  end;

function ChunkMetaPath(const ASessionDir: string): string;
function ChunkAudioPath(const ASessionDir: string): string;
function ChunkIndexPath(const ASessionDir: string): string;
function ChunkMarkerPath(const ASessionDir: string): string;
function IsRecordingSessionDir(const ASessionDir: string): Boolean;

implementation

const
  IDX_RECORD_BYTES = 16;   // Int64 framesTotal + Int64 wallClockMs

{ ---- path helpers ---- }

function ChunkMetaPath(const ASessionDir: string): string;
begin
  Result := IncludeTrailingPathDelimiter(ASessionDir) + REC_META_NAME;
end;

function ChunkAudioPath(const ASessionDir: string): string;
begin
  Result := IncludeTrailingPathDelimiter(ASessionDir) + REC_AUDIO_NAME;
end;

function ChunkIndexPath(const ASessionDir: string): string;
begin
  Result := IncludeTrailingPathDelimiter(ASessionDir) + REC_INDEX_NAME;
end;

function ChunkMarkerPath(const ASessionDir: string): string;
begin
  Result := IncludeTrailingPathDelimiter(ASessionDir) + REC_MARKER_NAME;
end;

function IsRecordingSessionDir(const ASessionDir: string): Boolean;
begin
  Result := FileExists(ChunkMetaPath(ASessionDir)) and
            FileExists(ChunkAudioPath(ASessionDir));
end;

{ ---- little-endian Int64 IO (host-endian-independent) ---- }

procedure PutI64(var B: array of Byte; AOffset: Integer; V: Int64);
var
  i: Integer;
  u: UInt64;
begin
  u := UInt64(V);
  for i := 0 to 7 do
    B[AOffset + i] := Byte((u shr (8 * i)) and $FF);
end;

function GetI64(const B: array of Byte; AOffset: Integer): Int64;
var
  i: Integer;
  u: UInt64;
begin
  u := 0;
  for i := 0 to 7 do
    u := u or (UInt64(B[AOffset + i]) shl (8 * i));
  Result := Int64(u);
end;

function NowMs: Int64;
begin
  Result := Round(Now * 24.0 * 60.0 * 60.0 * 1000.0);
end;

{ ================= TRecordingChunkWriter ================= }

constructor TRecordingChunkWriter.Create(const ASessionDir: string;
  ASampleRate, AChannels: Integer; const AName: string;
  ATimelineStartSeconds: Double; APassIndex: Integer; ASourceOffsetSeconds: Double);
begin
  inherited Create;
  if ASampleRate <= 0 then
    RaiseUDAW(errInvalidArgument, RECORDING_SUBSYS, 'chunk writer: bad sample rate');
  if AChannels < 1 then
    RaiseUDAW(errInvalidArgument, RECORDING_SUBSYS, 'chunk writer: bad channel count');

  FSessionDir := ExcludeTrailingPathDelimiter(ASessionDir);
  FSampleRate := ASampleRate;
  FChannels := AChannels;
  FName := AName;
  FTimelineStartSeconds := ATimelineStartSeconds;
  FSourceOffsetSeconds := ASourceOffsetSeconds;
  FPassIndex := APassIndex;
  FStartedUTC := Now;
  FBytesPerFrame := FChannels * SizeOf(Single);

  if not ForceDirectories(FSessionDir) then
    RaiseUDAWFmt(errIO, RECORDING_SUBSYS,
      'cannot create take directory "%s"', [FSessionDir]);

  { marker first: if the process dies right here recovery still finds an empty
    but well-formed container and simply discards it }
  with TFileStream.Create(ChunkMarkerPath(FSessionDir), fmCreate) do
  try
  finally
    Free;
  end;

  FPcm := TFileStream.Create(ChunkAudioPath(FSessionDir), fmCreate);
  FIdx := TFileStream.Create(ChunkIndexPath(FSessionDir), fmCreate);
  SetLength(FBuf, Int64(REC_WRITER_FLUSH_FRAMES) * FChannels);
  FBufFrames := 0;

  WriteMeta(tsRecording);
end;

destructor TRecordingChunkWriter.Destroy;
begin
  { a writer freed without Finalize is treated as a crash: keep the marker }
  if not FFinalized then
  begin
    try
      Abandon;
    except
      { destructor must not raise }
    end;
  end;
  FPcm.Free;
  FIdx.Free;
  inherited Destroy;
end;

procedure TRecordingChunkWriter.WriteMeta(AStatus: TTakeStatus);
var
  sl: TStringList;
begin
  sl := TStringList.Create;
  try
    sl.Add('version=' + IntToStr(REC_META_VERSION));
    sl.Add('name=' + FName);
    sl.Add('sample_rate=' + IntToStr(FSampleRate));
    sl.Add('channels=' + IntToStr(FChannels));
    sl.Add('pcm_format=float32');
    sl.Add('status=' + TakeStatusId(AStatus));
    sl.Add('pass_index=' + IntToStr(FPassIndex));
    sl.Add('frames=' + IntToStr(FFramesWritten));
    sl.Add(Format('timeline_start=%.9f', [FTimelineStartSeconds]));
    sl.Add(Format('source_offset=%.9f', [FSourceOffsetSeconds]));
    sl.Add('started_utc=' + FormatDateTime('yyyy-mm-dd"T"hh:nn:ss', FStartedUTC));
    sl.SaveToFile(ChunkMetaPath(FSessionDir));
  finally
    sl.Free;
  end;
end;

procedure TRecordingChunkWriter.AppendIndexRecord;
var
  rec: array[0 .. IDX_RECORD_BYTES - 1] of Byte;
begin
  PutI64(rec, 0, FFramesOnDisk);
  PutI64(rec, 8, NowMs);
  FIdx.WriteBuffer(rec[0], IDX_RECORD_BYTES);
end;

procedure TRecordingChunkWriter.WriteInterleaved(const ASrc; AFrames: Integer);
var
  src: PSingle;
  take, i: Integer;
  dstBase: Integer;
begin
  if FFinalized then
    RaiseUDAW(errInvalidState, RECORDING_SUBSYS, 'chunk writer already finalized');
  if AFrames <= 0 then Exit;

  src := PSingle(@ASrc);
  while AFrames > 0 do
  begin
    take := REC_WRITER_FLUSH_FRAMES - FBufFrames;
    if take > AFrames then take := AFrames;

    dstBase := FBufFrames * FChannels;
    for i := 0 to take * FChannels - 1 do
    begin
      FBuf[dstBase + i] := src^;
      Inc(src);
    end;
    Inc(FBufFrames, take);
    Inc(FFramesWritten, take);
    Dec(AFrames, take);

    if FBufFrames >= REC_WRITER_FLUSH_FRAMES then
      Flush;
  end;
end;

procedure TRecordingChunkWriter.WritePlanar(const ASrc: TAudioPlanar; AFrames: Integer);
var
  scratch: TAudioSampleArray;
  frame, ch, k: Integer;
begin
  if FFinalized then
    RaiseUDAW(errInvalidState, RECORDING_SUBSYS, 'chunk writer already finalized');
  if AFrames <= 0 then Exit;
  if Length(ASrc) < FChannels then
    RaiseUDAWFmt(errInvalidArgument, RECORDING_SUBSYS,
      'WritePlanar: source has %d channels, need %d', [Length(ASrc), FChannels]);

  SetLength(scratch, Int64(AFrames) * FChannels);
  k := 0;
  for frame := 0 to AFrames - 1 do
    for ch := 0 to FChannels - 1 do
    begin
      scratch[k] := ASrc[ch][frame];
      Inc(k);
    end;
  WriteInterleaved(scratch[0], AFrames);
end;

procedure TRecordingChunkWriter.Flush;
begin
  if FBufFrames > 0 then
  begin
    FPcm.WriteBuffer(FBuf[0], Int64(FBufFrames) * FBytesPerFrame);
    Inc(FFramesOnDisk, FBufFrames);
    FBufFrames := 0;
  end;
  AppendIndexRecord;
  {$IFDEF UDAW_WINDOWS}
  try
    FlushFileBuffers(FPcm.Handle);
    FlushFileBuffers(FIdx.Handle);
  except
  end;
  {$ENDIF}
end;

procedure TRecordingChunkWriter.Finalize(AKeepRecoveryMarker: Boolean);
begin
  if FFinalized then Exit;
  Flush;
  WriteMeta(tsFinalized);
  FFinalized := True;
  if (not AKeepRecoveryMarker) and FileExists(ChunkMarkerPath(FSessionDir)) then
    DeleteFile(ChunkMarkerPath(FSessionDir));
end;

procedure TRecordingChunkWriter.Abandon;
begin
  if FFinalized then Exit;
  Flush;
  WriteMeta(tsRecording);   // keep status=recording + marker present
end;

{ ================= TRecordingChunkReader ================= }

constructor TRecordingChunkReader.Create(const ASessionDir: string);
begin
  inherited Create;
  FSessionDir := ExcludeTrailingPathDelimiter(ASessionDir);
  if not FileExists(ChunkMetaPath(FSessionDir)) then
    RaiseUDAWFmt(errFileNotFound, RECORDING_SUBSYS,
      'no take meta in "%s"', [FSessionDir]);
  ParseMeta;
  FBytesPerFrame := FChannels * SizeOf(Single);
  RebuildIndex;
end;

procedure TRecordingChunkReader.ParseMeta;
var
  sl: TStringList;
  i, eq: Integer;
  line, key, val: string;
  st: TTakeStatus;
  fs: TFormatSettings;
begin
  fs := FormatSettings;
  fs.DecimalSeparator := '.';
  fs.ThousandSeparator := #0;

  FStatus := tsRecording;
  FPassIndex := 0;
  FMetaFrameCount := 0;

  sl := TStringList.Create;
  try
    sl.LoadFromFile(ChunkMetaPath(FSessionDir));
    for i := 0 to sl.Count - 1 do
    begin
      line := sl[i];
      eq := Pos('=', line);
      if eq <= 0 then Continue;
      key := Trim(Copy(line, 1, eq - 1));
      val := Copy(line, eq + 1, MaxInt);
      if key = 'name' then FName := val
      else if key = 'sample_rate' then FSampleRate := StrToIntDef(val, 0)
      else if key = 'channels' then FChannels := StrToIntDef(val, 0)
      else if key = 'pass_index' then FPassIndex := StrToIntDef(val, 0)
      else if key = 'frames' then FMetaFrameCount := StrToInt64Def(val, 0)
      else if key = 'timeline_start' then FTimelineStartSeconds := StrToFloatDef(val, 0, fs)
      else if key = 'source_offset' then FSourceOffsetSeconds := StrToFloatDef(val, 0, fs)
      else if key = 'status' then
      begin
        if TakeStatusFromId(Trim(val), st) then FStatus := st;
      end
      else if key = 'started_utc' then
        FStartedUTC := StrToDateTimeDef(StringReplace(val, 'T', ' ', []), Now);
    end;
  finally
    sl.Free;
  end;

  if (FSampleRate <= 0) or (FChannels <= 0) then
    RaiseUDAWFmt(errConfig, RECORDING_SUBSYS,
      'take meta in "%s" is missing rate/channels', [FSessionDir]);
end;

function TRecordingChunkReader.RebuildIndex: Int64;
var
  pcmBytes, framesFromPcm, framesFromIdx: Int64;
  idxBytes: Int64;
  fs: TFileStream;
  rec: array[0 .. IDX_RECORD_BYTES - 1] of Byte;
begin
  framesFromPcm := 0;
  if FileExists(ChunkAudioPath(FSessionDir)) then
  begin
    fs := TFileStream.Create(ChunkAudioPath(FSessionDir), fmOpenRead or fmShareDenyWrite);
    try
      pcmBytes := fs.Size;
    finally
      fs.Free;
    end;
    framesFromPcm := pcmBytes div FBytesPerFrame;   // torn tail write dropped
  end;

  { the last fully-journalled frame count, if the journal survived }
  framesFromIdx := -1;
  if FileExists(ChunkIndexPath(FSessionDir)) then
  begin
    fs := TFileStream.Create(ChunkIndexPath(FSessionDir), fmOpenRead or fmShareDenyWrite);
    try
      idxBytes := fs.Size;
      idxBytes := (idxBytes div IDX_RECORD_BYTES) * IDX_RECORD_BYTES;  // ignore torn record
      if idxBytes >= IDX_RECORD_BYTES then
      begin
        fs.Position := idxBytes - IDX_RECORD_BYTES;
        fs.ReadBuffer(rec[0], IDX_RECORD_BYTES);
        framesFromIdx := GetI64(rec, 0);
      end;
    finally
      fs.Free;
    end;
  end;

  Result := framesFromPcm;
  { trust the journal when it is intact and not ahead of the bytes we actually
    have - it marks the last flush that completed before the crash }
  if (framesFromIdx >= 0) and (framesFromIdx <= framesFromPcm) then
    Result := framesFromIdx;
  { a cleanly finalised meta is authoritative when it agrees with the bytes }
  if (FStatus = tsFinalized) and (FMetaFrameCount > 0) and
     (FMetaFrameCount <= framesFromPcm) then
    Result := FMetaFrameCount;

  if Result < 0 then Result := 0;
  FUsableFrames := Result;
end;

function TRecordingChunkReader.ReadAllPlanar: TAudioPlanar;
const
  BLOCK = 1 shl 16;
var
  fs: TFileStream;
  remaining, n, frame, ch, k: Int64;
  raw: TAudioSampleArray;
  done: Int64;
begin
  SetLength(Result, FChannels);
  for ch := 0 to FChannels - 1 do
    SetLength(Result[ch], FUsableFrames);
  if FUsableFrames <= 0 then Exit;

  fs := TFileStream.Create(ChunkAudioPath(FSessionDir), fmOpenRead or fmShareDenyWrite);
  try
    SetLength(raw, BLOCK * FChannels);
    done := 0;
    remaining := FUsableFrames;
    while remaining > 0 do
    begin
      n := remaining;
      if n > BLOCK then n := BLOCK;
      fs.ReadBuffer(raw[0], n * FBytesPerFrame);
      k := 0;
      for frame := 0 to n - 1 do
        for ch := 0 to FChannels - 1 do
        begin
          Result[ch][done + frame] := raw[k];
          Inc(k);
        end;
      Inc(done, n);
      Dec(remaining, n);
    end;
  finally
    fs.Free;
  end;
end;

function TRecordingChunkReader.FinalizeToWav(const AWavPath: string;
  AFormat: TWavSampleFormat): Int64;
const
  RD_BLOCK = 1 shl 16;
var
  fs: TFileStream;
  w: TWavWriter;
  raw: TAudioSampleArray;
  planar: TAudioPlanar;
  remaining: Int64;
  n, frame, ch, k: Integer;
begin
  ForceDirectories(ExtractFilePath(AWavPath));
  fs := nil;
  w := TWavWriter.Create(AWavPath, AFormat, FChannels, FSampleRate);
  try
    if FUsableFrames > 0 then
    begin
      fs := TFileStream.Create(ChunkAudioPath(FSessionDir), fmOpenRead or fmShareDenyWrite);
      SetLength(raw, RD_BLOCK * FChannels);
      SetLength(planar, FChannels);
      for ch := 0 to FChannels - 1 do
        SetLength(planar[ch], RD_BLOCK);
      remaining := FUsableFrames;
      while remaining > 0 do
      begin
        if remaining > RD_BLOCK then n := RD_BLOCK else n := Integer(remaining);
        fs.ReadBuffer(raw[0], Int64(n) * FBytesPerFrame);
        k := 0;
        for frame := 0 to n - 1 do
          for ch := 0 to FChannels - 1 do
          begin
            planar[ch][frame] := raw[k];
            Inc(k);
          end;
        w.WriteFrames(planar, n);
        Dec(remaining, n);
      end;
    end;
    w.Finalize;
  finally
    fs.Free;
    w.Free;
  end;
  Result := FUsableFrames;
end;

function TRecordingChunkReader.IsInProgress: Boolean;
begin
  Result := FileExists(ChunkMarkerPath(FSessionDir));
end;

function TRecordingChunkReader.ToRecordedTake: TRecordedTake;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Id := ExtractFileName(FSessionDir);
  Result.SessionDir := FSessionDir;
  Result.WavFile := '';
  Result.Name := FName;
  Result.SampleRate := FSampleRate;
  Result.Channels := FChannels;
  Result.FrameCount := FUsableFrames;
  Result.Status := FStatus;
  Result.TimelineStartSeconds := FTimelineStartSeconds;
  Result.SourceOffsetSeconds := FSourceOffsetSeconds;
  Result.PassIndex := FPassIndex;
  Result.StartedUTC := FStartedUTC;
end;

end.
