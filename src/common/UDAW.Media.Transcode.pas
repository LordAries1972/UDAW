unit UDAW.Media.Transcode;
{$I udaw.inc}
interface
uses {$IFDEF FPC}UDAW.Compat,{$ENDIF} SysUtils;
{ ABpm > 0 stamps the project tempo into the encoded file: ID3v2 TBPM for
  MP3, iTunes-style 'tmpo' atom (moov/udta/meta/ilst) for MP4/M4A, so other
  software reads the same tempo the timeline was rendered at. A non-empty
  AArtist stamps the project's Author name: ID3v2 TPE1 for MP3, iTunes-style
  (c)ART atom for MP4/M4A; it is also the Copyright field (the UDAW default
  notice is used only when it is empty). Every export also carries a
  "Created by ..." field (TENC / (c)too) and a "Version" field (TXXX /
  freeform atom) holding the UDAW build version. }
procedure EncodeCompressedFile(const AWav, AOutput, AFormat: string; AProgress: TProc<Double>;
  ABpm: Double = 0; const AArtist: string = '');
implementation
uses Classes, Math, UDAW.Errors, UDAW.Threading, UDAW.Media.Attribution, UDAW.Version,
  UDAW.Codec.MP3.Metadata, UDAW.Codec.MP4.Atoms
  {$IFDEF UDAW_WINDOWS}
  , Winapi.Windows, Winapi.WinRT, Winapi.Foundation, Winapi.Storage,
  Winapi.Media, Winapi.Media.MediaProperties, Winapi.ActiveX, ComObj,
  Winapi.CommonTypes
  {$ENDIF};

{$IFDEF UDAW_WINDOWS}
type
  IAgileObject = interface(IUnknown)
    ['{94EA2B94-E9CC-49E0-C0FF-EE64CA8F5B90}']
  end;
  TAacProgress = class(TInterfacedObject, AsyncActionProgressHandler_1__Double, IAgileObject)
  public
    Percent: Integer;
    procedure Invoke(asyncInfo: IAsyncActionWithProgress_1__Double; progressInfo: Double); safecall;
  end;

function InitializeWinRT(AType: Cardinal): HRESULT; stdcall; external 'combase.dll' name 'RoInitialize';

procedure TAacProgress.Invoke(asyncInfo: IAsyncActionWithProgress_1__Double; progressInfo: Double);
begin
  AtomicSet32(Percent, Round(progressInfo * 100));
end;

procedure StampMp4(const AFile: string; ABpm: Double; const AArtist: string);

  procedure TextAtom(AWriter: TMP4BoxWriter; const AType, AText: string);
  begin
    AWriter.BeginBox(AType);
    AWriter.BeginFullBox('data', 0, 1);   // 1 = UTF-8 text
    AWriter.U32(0);                       // locale
    AWriter.RawBytes(TEncoding.UTF8.GetBytes(AText));
    AWriter.CloseBox;
    AWriter.CloseBox;
  end;

  procedure FreeformAtom(AWriter: TMP4BoxWriter; const AName, AText: string);
  begin
    AWriter.BeginBox('----');
    AWriter.BeginFullBox('mean', 0, 0);
    AWriter.RawBytes(TEncoding.UTF8.GetBytes('com.apple.iTunes'));
    AWriter.CloseBox;
    AWriter.BeginFullBox('name', 0, 0);
    AWriter.RawBytes(TEncoding.UTF8.GetBytes(AName));
    AWriter.CloseBox;
    AWriter.BeginFullBox('data', 0, 1);
    AWriter.U32(0);
    AWriter.RawBytes(TEncoding.UTF8.GetBytes(AText));
    AWriter.CloseBox;
    AWriter.CloseBox;
  end;

var
  copyrightText: string;
  f: TFileStream;
  header, moov, tag: TBytes;
  pos, size: Int64;
  child, childSize, insertAt, oldLen, addLen: Integer;
  writer: TMP4BoxWriter;
  freeTag: AnsiString;
begin
  f := TFileStream.Create(AFile, fmOpenReadWrite or fmShareExclusive);
  try
    SetLength(header, 8);
    pos := 0;
    while pos + 8 <= f.Size do
    begin
      f.Position := pos;
      f.ReadBuffer(header[0], 8);
      size := BE_U32(header, 0);
      if (size < 8) or (size > f.Size - pos) then
        RaiseUDAW(errIO, 'Media.Transcode', 'Invalid encoded MP4 box.');
      if (header[4] = Ord('m')) and (header[5] = Ord('o')) and
         (header[6] = Ord('o')) and (header[7] = Ord('v')) then
      begin
        if size > 64 * 1024 * 1024 then
          RaiseUDAW(errIO, 'Media.Transcode', 'MP4 metadata exceeds supported size.');
        SetLength(moov, size);
        f.Position := pos;
        f.ReadBuffer(moov[0], Length(moov));
        if AArtist <> '' then copyrightText := AArtist else copyrightText := UDAW_MEDIA_COPYRIGHT;
        writer := TMP4BoxWriter.Create;
        try
          writer.BeginBox('udta');
          writer.BeginFullBox('cprt', 0, 0);
          writer.U16($15C7);
          writer.RawBytes(TEncoding.UTF8.GetBytes(copyrightText + #0));
          writer.CloseBox;
          begin   // always: 'Created by' and 'Version' are on every export
            writer.BeginFullBox('meta', 0, 0);
            writer.BeginFullBox('hdlr', 0, 0);
            writer.U32(0);
            writer.FourCCStr('mdir');
            writer.Zeros(12);
            writer.U8(0);
            writer.CloseBox;
            writer.BeginBox('ilst');
            if ABpm > 0 then
            begin
              writer.BeginBox('tmpo');
              writer.BeginFullBox('data', 0, 21);   // 21 = big-endian integer
              writer.U32(0);                        // locale
              writer.U16(EnsureRange(Round(ABpm), 1, 65535));
              writer.CloseBox;
              writer.CloseBox;
            end;
            if AArtist <> '' then TextAtom(writer, #$A9 + 'ART', AArtist);
            TextAtom(writer, #$A9 + 'too', UDAW_MEDIA_CREATED_BY);
            FreeformAtom(writer, 'Version', UDAWDisplayVersionString);
            FreeformAtom(writer, 'Website', UDAW_MEDIA_WEBSITE);
            writer.CloseBox;
            writer.CloseBox;
          end;
          writer.CloseBox;
          tag := writer.ToBytes;
        finally writer.Free; end;
        child := 8;
        while child + 8 <= Length(moov) do
        begin
          childSize := BE_U32(moov, child);
          if (childSize < 8) or (childSize > Length(moov) - child) then Break;
          if (moov[child + 4] = Ord('u')) and (moov[child + 5] = Ord('d')) and
             (moov[child + 6] = Ord('t')) and (moov[child + 7] = Ord('a')) then
          begin
            tag := Copy(tag, 8, Length(tag) - 8);
            addLen := Length(tag);
            oldLen := Length(moov);
            insertAt := child + childSize;
            SetLength(moov, oldLen + addLen);
            if oldLen > insertAt then
              Move(moov[insertAt], moov[insertAt + addLen], oldLen - insertAt);
            Move(tag[0], moov[insertAt], addLen);
            Inc(childSize, addLen);
            moov[child] := (childSize shr 24) and $FF;
            moov[child + 1] := (childSize shr 16) and $FF;
            moov[child + 2] := (childSize shr 8) and $FF;
            moov[child + 3] := childSize and $FF;
            tag := nil;
            Break;
          end;
          Inc(child, childSize);
        end;
        size := Length(moov) + Length(tag);
        moov[0] := (size shr 24) and $FF;
        moov[1] := (size shr 16) and $FF;
        moov[2] := (size shr 8) and $FF;
        moov[3] := size and $FF;
        // Relocate only moov; media offsets remain unchanged.
        f.Position := f.Size;
        f.WriteBuffer(moov[0], Length(moov));
        if Length(tag) > 0 then f.WriteBuffer(tag[0], Length(tag));
        f.Position := pos + 4;
        freeTag := 'free';
        f.WriteBuffer(freeTag[1], 4);
        Exit;
      end;
      Inc(pos, size);
    end;
    RaiseUDAW(errIO, 'Media.Transcode', 'Encoded MP4 contains no movie metadata.');
  finally f.Free; end;
end;

// Actual rate of the rendered WAV (canonical fmt chunk at byte 24); the encoder
// profile must match it or the output plays at the wrong speed.
function WavSampleRate(const AWav: string): Cardinal;
var
  f: TFileStream;
  tag: array[0..3] of AnsiChar;
  size, rate: Cardinal;
  fmt: array[0..7] of Byte;
  pos: Int64;
begin
  Result := 48000;
  f := TFileStream.Create(AWav, fmOpenRead or fmShareDenyNone);
  try
    { TWavWriter emits a JUNK/ds64 placeholder before 'fmt ', so the rate is not
      at a fixed offset - walk the chunks. }
    pos := 12;
    while pos + 8 <= f.Size do
    begin
      f.Position := pos;
      f.ReadBuffer(tag, 4);
      f.ReadBuffer(size, 4);
      if (tag = 'fmt ') and (size >= 8) then
      begin
        f.ReadBuffer(fmt, 8);
        rate := fmt[4] or (fmt[5] shl 8) or (fmt[6] shl 16) or (Cardinal(fmt[7]) shl 24);
        if rate <> 0 then Result := rate;
        Exit;
      end;
      Inc(pos, 8 + Int64(size) + (size and 1));
    end;
  finally f.Free; end;
end;

procedure StampMp3(const Name: string; ABpm: Double; const AArtist: string);
var
  input, output: TFileStream;
  meta: TMP3Metadata;
  tag: TBytes;
  bpmText: string;

  { ISO-8859-1 text frame; ADesc <> '' makes it a TXXX (description, value) frame }
  procedure AddOther(const AId, ADesc, AText: string);
  var
    d: TBytes;
    j, n: Integer;
    full: string;
  begin
    if ADesc <> '' then full := ADesc + #0 + AText else full := AText;
    SetLength(d, Length(full) + 1);
    d[0] := 0;
    if AId = 'WXXX' then full := ADesc + #0 + AText;   // URL text itself is always Latin-1
    for j := 1 to Length(full) do d[j] := Byte(Ord(full[j]) and $FF);
    n := Length(meta.Other);
    SetLength(meta.Other, n + 1);
    meta.Other[n].Id := AId;
    meta.Other[n].Data := d;
  end;

begin
  meta.Clear;
  if AArtist <> '' then meta.Copyright := AArtist else meta.Copyright := UDAW_MEDIA_COPYRIGHT;
  meta.Artist := AArtist;
  if ABpm > 0 then
  begin
    bpmText := IntToStr(Round(ABpm));
    AddOther('TBPM', '', bpmText);
  end;
  AddOther('TENC', '', UDAW_MEDIA_CREATED_BY);
  AddOther('TXXX', 'Version', UDAWDisplayVersionString);
  AddOther('WXXX', 'Website', UDAW_MEDIA_WEBSITE);
  tag := BuildId3v2Tag(meta);
  input := TFileStream.Create(Name, fmOpenRead or fmShareDenyWrite);
  try
    output := TFileStream.Create(Name + '.tagged', fmCreate);
    try
      output.WriteBuffer(tag[0], Length(tag));
      output.CopyFrom(input, 0);
    finally output.Free; end;
  finally input.Free; end;
  if not SysUtils.DeleteFile(Name) or not RenameFile(Name + '.tagged', Name) then
    RaiseUDAW(errIO, 'Media.Transcode', 'Cannot stamp MP3 output.');
end;

procedure EncodeCompressedFile(const AWav, AOutput, AFormat: string; AProgress: TProc<Double>;
  ABpm: Double; const AArtist: string);
var
  source, dest: IStorageFile;
  load: IAsyncOperation_1__IStorageFile;
  prepare: IAsyncOperation_1__Transcoding_IPrepareTranscodeResult;
  prepared: Transcoding_IPrepareTranscodeResult;
  transcoder: Transcoding_IMediaTranscoder;
  profile: IMediaEncodingProfile;
  action: IAsyncActionWithProgress_1__Double;
  progress: TAacProgress;
  handler: AsyncActionProgressHandler_1__Double;
  h: HSTRING;
  fs: TFileStream;
  stage: string;

  procedure Wait(const Operation: IInterface);
  var info: IAsyncInfo;
  begin
    info := Operation as IAsyncInfo;
    try
      while info.Status = AsyncStatus.Started do
      begin
        if Assigned(AProgress) then AProgress(AtomicRead32(progress.Percent) / 10000);
        TThread.Sleep(50);
      end;
    except
      info.Cancel;
      while info.Status = AsyncStatus.Started do TThread.Sleep(10);
      raise;
    end;
  end;

  function OpenFile(const Name: string): IStorageFile;
  begin
    OleCheck(WindowsCreateString(PWideChar(Name), Length(Name), h));
    try load := TStorageFile.GetFileFromPathAsync(h);
    finally WindowsDeleteString(h); end;
    Wait(load);
    Result := load.GetResults;
  end;

begin
  OleCheck(InitializeWinRT(1));
  stage := 'initializing';
  try
  try
    progress := TAacProgress.Create;
    handler := progress;
    fs := TFileStream.Create(AOutput, fmCreate);
    fs.Free;
    stage := 'opening source';
    source := OpenFile(AWav);
    stage := 'opening output';
    dest := OpenFile(AOutput);
    stage := 'creating encoder';
    transcoder := TTranscoding_MediaTranscoder.Create;
    if AFormat = '.mp3' then profile := TMediaEncodingProfile.CreateMp3(AudioEncodingQuality.High)
    else profile := TMediaEncodingProfile.CreateM4a(AudioEncodingQuality.High);
    profile.Audio.SampleRate := WavSampleRate(AWav);
    profile.Audio.ChannelCount := 2;
    if AFormat = '.mp3' then profile.Audio.Bitrate := 320000
    else profile.Audio.Bitrate := 320000;
    stage := 'preparing encoder';
    prepare := transcoder.PrepareFileTranscodeAsync(source, dest, profile);
    Wait(prepare);
    prepared := prepare.GetResults;
    if not prepared.CanTranscode then
      RaiseUDAWFmt(errIO, 'Media.Transcode', 'Windows audio encoder unavailable (reason %d).', [Ord(prepared.FailureReason)]);
    stage := 'transcoding';
    action := prepared.TranscodeAsync;
    action.Progress := handler;
    Wait(action);
    action.GetResults;
    action := nil; prepared := nil; prepare := nil; transcoder := nil;
    source := nil; dest := nil; load := nil;
    if AFormat = '.mp3' then StampMp3(AOutput, ABpm, AArtist) else StampMp4(AOutput, ABpm, AArtist);
    if Assigned(AProgress) then AProgress(1);
  except
    on E: EAbort do raise;
    on E: Exception do RaiseUDAW(errIO, 'Media.Transcode', stage + ': ' + E.Message);
  end;
  finally
    action := nil; prepared := nil; prepare := nil; transcoder := nil;
    source := nil; dest := nil; load := nil; handler := nil;
    profile := nil;
    RoUninitialize;
  end;
end;
{$ELSE}
procedure EncodeCompressedFile(const AWav, AOutput, AFormat: string; AProgress: TProc<Double>;
  ABpm: Double; const AArtist: string);
begin
  RaiseUDAW(errNotImplemented, 'Media.Transcode', 'AAC export requires Windows.');
end;
{$ENDIF}
end.
