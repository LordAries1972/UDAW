unit UDAW.MIDI.SMF;
{$I udaw.inc}
{$POINTERMATH ON}

{ Phase 17 - MIDI (plan section 25): Standard MIDI File parsing and writing,
  from scratch.

    * SMF Type 0 (one track) and Type 1 (many parallel tracks); Type 2
      (sequential independent patterns) is parsed but flagged.
    * variable-length quantities; running status; every channel-voice message;
      all meta events (tempo, time/key signature, track/instrument names,
      markers, channel prefix/port, SMPTE offset, sequencer-specific) kept
      verbatim; SysEx (F0 .. F7) and escaped (F7 ..) blobs preserved byte for
      byte.
    * a matching writer that re-emits a byte-accurate MThd + MTrk stream with
      running-status compression and a guaranteed End-of-Track per track.

  Every length read from the file is bounds-checked before it is used; a
  truncated or hostile file raises EUDAWError(errIO / errConfig), never a bad
  read or a runaway allocation. }

interface

uses
  SysUtils, Classes, Math,
  UDAW.Errors, UDAW.MIDI.Types;

const
  SMF_MAX_FILE_BYTES = Int64(256) * 1024 * 1024;
  SMF_MAX_TRACKS     = 4096;
  SMF_MAX_EVENTS_PER_TRACK = 8 * 1024 * 1024;

type
  TSmfDivisionKind = (sdkPPQ, sdkSMPTE);

  TSmfTrack = class
  private
    FEvents: TMidiEventArray;
    FCount: Integer;
    FName: string;
    procedure Grow;
  public
    procedure Clear;
    procedure Add(const AEvent: TMidiEvent);
    procedure SortByTick;               // stable, keeps insertion order per tick
    function LastTick: Int64;
    property Events: TMidiEventArray read FEvents;
    property Count: Integer read FCount;
    property Name: string read FName write FName;
  end;

  TSmfFile = class
  private
    FFormat: Integer;                   // 0 / 1 / 2
    FDivisionKind: TSmfDivisionKind;
    FTicksPerQuarter: Integer;          // when sdkPPQ
    FSmpteFps: Integer;                 // 24/25/29/30 when sdkSMPTE
    FSmpteTicksPerFrame: Integer;
    FTracks: TArray<TSmfTrack>;
    procedure ParseHeader(const AData: TBytes; var APos: Int64);
    procedure ParseTrack(const AData: TBytes; var APos: Int64);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Clear;

    procedure LoadFromBytes(const AData: TBytes);
    procedure LoadFromFile(const AFileName: string);
    function SaveToBytes: TBytes;
    procedure SaveToFile(const AFileName: string);

    function AddTrack(const AName: string = ''): TSmfTrack;
    function TrackCount: Integer;
    function GetTrack(AIndex: Integer): TSmfTrack;

    { convenience: overall length in ticks across all tracks }
    function DurationTicks: Int64;
    function Describe: string;

    property FileFormat: Integer read FFormat write FFormat;   // 0 / 1 / 2
    property DivisionKind: TSmfDivisionKind read FDivisionKind;
    property TicksPerQuarter: Integer read FTicksPerQuarter write FTicksPerQuarter;
    property SmpteFps: Integer read FSmpteFps;
    property SmpteTicksPerFrame: Integer read FSmpteTicksPerFrame;
  end;

{ ---- VLQ helpers (exposed: the serializer for the project format reuses them) ---- }
function SmfReadVLQ(const AData: TBytes; var APos: Int64): Cardinal;
procedure SmfWriteVLQ(AStream: TStream; AValue: Cardinal);

implementation

const
  SMF_SUBSYS = 'MIDI.SMF';

function BE32(const B: TBytes; AOfs: Int64): Cardinal;
begin
  if AOfs + 4 > Length(B) then
    RaiseUDAW(errIO, SMF_SUBSYS, 'SMF: read past end (u32)');
  Result := (Cardinal(B[AOfs]) shl 24) or (Cardinal(B[AOfs + 1]) shl 16) or
            (Cardinal(B[AOfs + 2]) shl 8) or Cardinal(B[AOfs + 3]);
end;

function BE16(const B: TBytes; AOfs: Int64): Word;
begin
  if AOfs + 2 > Length(B) then
    RaiseUDAW(errIO, SMF_SUBSYS, 'SMF: read past end (u16)');
  Result := (Word(B[AOfs]) shl 8) or Word(B[AOfs + 1]);
end;

function SmfReadVLQ(const AData: TBytes; var APos: Int64): Cardinal;
var
  b: Byte;
  guard: Integer;
begin
  Result := 0;
  guard := 0;
  repeat
    if APos >= Length(AData) then
      RaiseUDAW(errIO, SMF_SUBSYS, 'SMF: truncated variable-length quantity');
    b := AData[APos];
    Inc(APos);
    Result := (Result shl 7) or (b and $7F);
    Inc(guard);
    if guard > 5 then
      RaiseUDAW(errConfig, SMF_SUBSYS, 'SMF: over-long variable-length quantity');
  until (b and $80) = 0;
end;

procedure SmfWriteVLQ(AStream: TStream; AValue: Cardinal);
var
  buf: array[0..4] of Byte;
  n: Integer;
begin
  buf[0] := AValue and $7F;
  n := 1;
  AValue := AValue shr 7;
  while AValue > 0 do
  begin
    buf[n] := (AValue and $7F) or $80;
    Inc(n);
    AValue := AValue shr 7;
  end;
  { emitted most-significant group first }
  while n > 0 do
  begin
    Dec(n);
    AStream.WriteBuffer(buf[n], 1);
  end;
end;

{ ============================ TSmfTrack =========================== }

procedure TSmfTrack.Grow;
begin
  if FCount >= Length(FEvents) then
  begin
    if Length(FEvents) = 0 then
      SetLength(FEvents, 256)
    else
      SetLength(FEvents, Length(FEvents) * 2);
  end;
end;

procedure TSmfTrack.Clear;
begin
  SetLength(FEvents, 0);
  FCount := 0;
  FName := '';
end;

procedure TSmfTrack.Add(const AEvent: TMidiEvent);
begin
  if FCount >= SMF_MAX_EVENTS_PER_TRACK then
    RaiseUDAW(errConfig, SMF_SUBSYS, 'SMF: track event count limit exceeded');
  Grow;
  FEvents[FCount] := AEvent;
  Inc(FCount);
  if (AEvent.Kind = mekMeta) and (AEvent.MetaType = META_TRACK_NAME) then
    FName := AEvent.AsText;
end;

procedure TSmfTrack.SortByTick;
var
  i, j: Integer;
  key: TMidiEvent;
begin
  { insertion sort - stable, and SMF tracks are already tick-ordered so this is
    O(n) in practice; only re-sorts after programmatic edits }
  for i := 1 to FCount - 1 do
  begin
    key := FEvents[i];
    j := i - 1;
    while (j >= 0) and (FEvents[j].Tick > key.Tick) do
    begin
      FEvents[j + 1] := FEvents[j];
      Dec(j);
    end;
    FEvents[j + 1] := key;
  end;
end;

function TSmfTrack.LastTick: Int64;
begin
  if FCount = 0 then Result := 0
  else Result := FEvents[FCount - 1].Tick;
end;

{ ============================ TSmfFile ============================ }

constructor TSmfFile.Create;
begin
  inherited Create;
  FFormat := 1;
  FDivisionKind := sdkPPQ;
  FTicksPerQuarter := MIDI_DEFAULT_PPQ;
end;

destructor TSmfFile.Destroy;
begin
  Clear;
  inherited Destroy;
end;

procedure TSmfFile.Clear;
var
  i: Integer;
begin
  for i := 0 to High(FTracks) do
    FTracks[i].Free;
  SetLength(FTracks, 0);
end;

function TSmfFile.AddTrack(const AName: string): TSmfTrack;
var
  n: Integer;
  ev: TMidiEvent;
begin
  n := Length(FTracks);
  SetLength(FTracks, n + 1);
  FTracks[n] := TSmfTrack.Create;
  Result := FTracks[n];
  if AName <> '' then
  begin
    FillChar(ev, SizeOf(ev), 0);
    ev.Tick := 0;
    ev.Kind := mekMeta;
    ev.MetaType := META_TRACK_NAME;
    ev.Bytes := TEncoding.ANSI.GetBytes(AName);
    Result.Add(ev);
  end;
end;

function TSmfFile.TrackCount: Integer;
begin
  Result := Length(FTracks);
end;

function TSmfFile.GetTrack(AIndex: Integer): TSmfTrack;
begin
  if (AIndex < 0) or (AIndex > High(FTracks)) then Result := nil
  else Result := FTracks[AIndex];
end;

procedure TSmfFile.ParseHeader(const AData: TBytes; var APos: Int64);
var
  chunkLen: Cardinal;
  division: Word;
begin
  if (Length(AData) < 14) or
     (AData[0] <> Ord('M')) or (AData[1] <> Ord('T')) or
     (AData[2] <> Ord('h')) or (AData[3] <> Ord('d')) then
    RaiseUDAW(errConfig, SMF_SUBSYS, 'not a Standard MIDI File (missing MThd)');
  chunkLen := BE32(AData, 4);
  if chunkLen < 6 then
    RaiseUDAW(errConfig, SMF_SUBSYS, 'SMF: MThd chunk too short');
  FFormat := BE16(AData, 8);
  { number of tracks at offset 10 is advisory; we read what the file contains }
  division := BE16(AData, 12);
  if (division and $8000) <> 0 then
  begin
    FDivisionKind := sdkSMPTE;
    FSmpteFps := 256 - (division shr 8);   // stored as negative fps
    FSmpteTicksPerFrame := division and $FF;
    FTicksPerQuarter := Max(1, FSmpteFps * FSmpteTicksPerFrame);
  end
  else
  begin
    FDivisionKind := sdkPPQ;
    FTicksPerQuarter := division;
    if FTicksPerQuarter <= 0 then FTicksPerQuarter := MIDI_DEFAULT_PPQ;
  end;
  APos := Int64(8) + chunkLen;
end;

procedure TSmfFile.ParseTrack(const AData: TBytes; var APos: Int64);
var
  chunkLen: Cardinal;
  trackEnd: Int64;
  trk: TSmfTrack;
  absTick: Int64;
  runningStatus: Byte;
  delta: Cardinal;
  status, d1, d2, metaType: Byte;
  len: Cardinal;
  ev: TMidiEvent;
  i: Integer;
  sawEndOfTrack: Boolean;
begin
  if (APos + 8 > Length(AData)) or
     (AData[APos] <> Ord('M')) or (AData[APos + 1] <> Ord('T')) or
     (AData[APos + 2] <> Ord('r')) or (AData[APos + 3] <> Ord('k')) then
    RaiseUDAWFmt(errConfig, SMF_SUBSYS, 'SMF: expected MTrk at offset %d', [APos]);
  chunkLen := BE32(AData, APos + 4);
  APos := APos + 8;
  trackEnd := APos + chunkLen;
  if trackEnd > Length(AData) then
    trackEnd := Length(AData);              // tolerate a truncated final track

  if Length(FTracks) >= SMF_MAX_TRACKS then
    RaiseUDAW(errConfig, SMF_SUBSYS, 'SMF: track count limit exceeded');

  trk := TSmfTrack.Create;
  SetLength(FTracks, Length(FTracks) + 1);
  FTracks[High(FTracks)] := trk;

  absTick := 0;
  runningStatus := 0;
  sawEndOfTrack := False;

  while (APos < trackEnd) and (not sawEndOfTrack) do
  begin
    delta := SmfReadVLQ(AData, APos);
    absTick := absTick + Int64(delta);
    if APos >= trackEnd then Break;

    status := AData[APos];
    if status < $80 then
    begin
      { running status: reuse the last channel status byte }
      if runningStatus < $80 then
        RaiseUDAW(errConfig, SMF_SUBSYS, 'SMF: data byte with no running status');
      status := runningStatus;
    end
    else
      Inc(APos);

    FillChar(ev, SizeOf(ev), 0);
    ev.Tick := absTick;

    if status = $FF then
    begin
      { meta event }
      if APos >= trackEnd then Break;
      metaType := AData[APos]; Inc(APos);
      len := SmfReadVLQ(AData, APos);
      if APos + Int64(len) > Length(AData) then
        len := Cardinal(Max(Int64(0), Int64(Length(AData)) - APos));
      ev.Kind := mekMeta;
      ev.MetaType := metaType;
      SetLength(ev.Bytes, len);
      for i := 0 to Integer(len) - 1 do
        ev.Bytes[i] := AData[APos + i];
      APos := APos + Int64(len);
      trk.Add(ev);
      if metaType = META_END_OF_TRACK then
        sawEndOfTrack := True;
      runningStatus := 0;    // sysex + meta cancel running status
    end
    else if (status = $F0) or (status = $F7) then
    begin
      { SysEx (F0) or escaped raw (F7) }
      len := SmfReadVLQ(AData, APos);
      if APos + Int64(len) > Length(AData) then
        len := Cardinal(Max(Int64(0), Int64(Length(AData)) - APos));
      ev.Kind := mekSysEx;
      if status = $F0 then
      begin
        SetLength(ev.Bytes, len + 1);
        ev.Bytes[0] := $F0;
        for i := 0 to Integer(len) - 1 do
          ev.Bytes[i + 1] := AData[APos + i];
      end
      else
      begin
        SetLength(ev.Bytes, len);
        for i := 0 to Integer(len) - 1 do
          ev.Bytes[i] := AData[APos + i];
      end;
      APos := APos + Int64(len);
      trk.Add(ev);
      runningStatus := 0;
    end
    else
    begin
      { channel-voice message }
      runningStatus := status;
      d1 := 0; d2 := 0;
      case status and $F0 of
        MIDI_PROGRAM_CHANGE, MIDI_CHAN_AFTERTOUCH:
          begin
            if APos < trackEnd then begin d1 := AData[APos] and $7F; Inc(APos); end;
          end;
      else
        begin
          if APos < trackEnd then begin d1 := AData[APos] and $7F; Inc(APos); end;
          if APos < trackEnd then begin d2 := AData[APos] and $7F; Inc(APos); end;
        end;
      end;
      ev.Kind := mekChannel;
      ev.Msg.Status := status;
      ev.Msg.Data1 := d1;
      ev.Msg.Data2 := d2;
      trk.Add(ev);
    end;
  end;

  { make sure there is an End-of-Track even if the file omitted it }
  if not sawEndOfTrack then
  begin
    FillChar(ev, SizeOf(ev), 0);
    ev.Tick := absTick;
    ev.Kind := mekMeta;
    ev.MetaType := META_END_OF_TRACK;
    SetLength(ev.Bytes, 0);
    trk.Add(ev);
  end;

  APos := trackEnd;
end;

procedure TSmfFile.LoadFromBytes(const AData: TBytes);
var
  pos: Int64;
  skipLen: Cardinal;
begin
  Clear;
  if Length(AData) > SMF_MAX_FILE_BYTES then
    RaiseUDAW(errInvalidArgument, SMF_SUBSYS, 'SMF: file too large');
  pos := 0;
  ParseHeader(AData, pos);
  while (pos + 8 <= Length(AData)) do
  begin
    if (AData[pos] = Ord('M')) and (AData[pos + 1] = Ord('T')) and
       (AData[pos + 2] = Ord('r')) and (AData[pos + 3] = Ord('k')) then
      ParseTrack(AData, pos)
    else
    begin
      { skip an unknown chunk }
      skipLen := BE32(AData, pos + 4);
      pos := pos + 8 + Int64(skipLen);
    end;
  end;
  if Length(FTracks) = 0 then
    RaiseUDAW(errConfig, SMF_SUBSYS, 'SMF: no MTrk chunks');
end;

procedure TSmfFile.LoadFromFile(const AFileName: string);
var
  fs: TFileStream;
  buf: TBytes;
begin
  if not FileExists(AFileName) then
    RaiseUDAWFmt(errFileNotFound, SMF_SUBSYS, 'MIDI file not found: %s', [AFileName]);
  fs := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(buf, fs.Size);
    if Length(buf) > 0 then fs.ReadBuffer(buf[0], Length(buf));
  finally
    fs.Free;
  end;
  LoadFromBytes(buf);
end;

function TSmfFile.SaveToBytes: TBytes;
var
  ms: TMemoryStream;
  ti, ei: Integer;
  trk: TSmfTrack;
  trackMs: TMemoryStream;
  prevTick: Int64;
  runningStatus: Byte;
  ev: TMidiEvent;
  b: Byte;
  hdrDivision: Word;

  procedure W8(S: TStream; V: Byte);
  begin
    S.WriteBuffer(V, 1);
  end;
  procedure W16(S: TStream; V: Word);
  begin
    b := (V shr 8) and $FF; S.WriteBuffer(b, 1);
    b := V and $FF; S.WriteBuffer(b, 1);
  end;
  procedure W32(S: TStream; V: Cardinal);
  begin
    b := (V shr 24) and $FF; S.WriteBuffer(b, 1);
    b := (V shr 16) and $FF; S.WriteBuffer(b, 1);
    b := (V shr 8) and $FF; S.WriteBuffer(b, 1);
    b := V and $FF; S.WriteBuffer(b, 1);
  end;

begin
  ms := TMemoryStream.Create;
  try
    { ---- MThd ---- }
    ms.WriteBuffer(AnsiString('MThd')[1], 4);
    W32(ms, 6);
    if Length(FTracks) <= 1 then
      W16(ms, 0)
    else
      W16(ms, Word(FFormat));
    W16(ms, Word(Length(FTracks)));          // ntrks
    if FDivisionKind = sdkSMPTE then
      hdrDivision := Word((256 - FSmpteFps) shl 8) or Word(FSmpteTicksPerFrame and $FF)
    else
      hdrDivision := Word(FTicksPerQuarter and $7FFF);
    W16(ms, hdrDivision);

    { ---- each MTrk ---- }
    for ti := 0 to High(FTracks) do
    begin
      trk := FTracks[ti];
      trk.SortByTick;
      trackMs := TMemoryStream.Create;
      try
        prevTick := 0;
        runningStatus := 0;
        for ei := 0 to trk.Count - 1 do
        begin
          ev := trk.Events[ei];
          if ev.Tick < prevTick then ev.Tick := prevTick;   // never negative delta
          SmfWriteVLQ(trackMs, Cardinal(ev.Tick - prevTick));
          prevTick := ev.Tick;

          case ev.Kind of
            mekChannel:
              begin
                if ev.Msg.Status <> runningStatus then
                begin
                  W8(trackMs, ev.Msg.Status);
                  runningStatus := ev.Msg.Status;
                end;
                case ev.Msg.Status and $F0 of
                  MIDI_PROGRAM_CHANGE, MIDI_CHAN_AFTERTOUCH:
                    W8(trackMs, ev.Msg.Data1 and $7F);
                else
                  begin
                    W8(trackMs, ev.Msg.Data1 and $7F);
                    W8(trackMs, ev.Msg.Data2 and $7F);
                  end;
                end;
              end;
            mekMeta:
              begin
                W8(trackMs, $FF);
                W8(trackMs, ev.MetaType);
                SmfWriteVLQ(trackMs, Cardinal(Length(ev.Bytes)));
                if Length(ev.Bytes) > 0 then
                  trackMs.WriteBuffer(ev.Bytes[0], Length(ev.Bytes));
                runningStatus := 0;
              end;
            mekSysEx:
              begin
                if (Length(ev.Bytes) > 0) and (ev.Bytes[0] = $F0) then
                begin
                  W8(trackMs, $F0);
                  SmfWriteVLQ(trackMs, Cardinal(Length(ev.Bytes) - 1));
                  if Length(ev.Bytes) > 1 then
                    trackMs.WriteBuffer(ev.Bytes[1], Length(ev.Bytes) - 1);
                end
                else
                begin
                  W8(trackMs, $F7);
                  SmfWriteVLQ(trackMs, Cardinal(Length(ev.Bytes)));
                  if Length(ev.Bytes) > 0 then
                    trackMs.WriteBuffer(ev.Bytes[0], Length(ev.Bytes));
                end;
                runningStatus := 0;
              end;
          end;
        end;

        { guarantee a trailing End-of-Track }
        if (trk.Count = 0) or (trk.Events[trk.Count - 1].Kind <> mekMeta) or
           (trk.Events[trk.Count - 1].MetaType <> META_END_OF_TRACK) then
        begin
          SmfWriteVLQ(trackMs, 0);
          W8(trackMs, $FF); W8(trackMs, META_END_OF_TRACK); W8(trackMs, 0);
        end;

        ms.WriteBuffer(AnsiString('MTrk')[1], 4);
        W32(ms, Cardinal(trackMs.Size));
        trackMs.Position := 0;
        ms.CopyFrom(trackMs, trackMs.Size);
      finally
        trackMs.Free;
      end;
    end;

    SetLength(Result, ms.Size);
    if ms.Size > 0 then
      Move(ms.Memory^, Result[0], ms.Size);
  finally
    ms.Free;
  end;
end;

procedure TSmfFile.SaveToFile(const AFileName: string);
var
  bytes: TBytes;
  fs: TFileStream;
begin
  bytes := SaveToBytes;
  fs := TFileStream.Create(AFileName, fmCreate);
  try
    if Length(bytes) > 0 then fs.WriteBuffer(bytes[0], Length(bytes));
  finally
    fs.Free;
  end;
end;

function TSmfFile.DurationTicks: Int64;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(FTracks) do
    Result := Max(Result, FTracks[i].LastTick);
end;

function TSmfFile.Describe: string;
var
  i: Integer;
  sb: TStringBuilder;
begin
  sb := TStringBuilder.Create;
  try
    sb.Append(Format('SMF format %d, %d track(s), ', [FFormat, Length(FTracks)]));
    if FDivisionKind = sdkPPQ then
      sb.Append(Format('%d ticks/quarter', [FTicksPerQuarter]))
    else
      sb.Append(Format('SMPTE %d fps x %d ticks/frame', [FSmpteFps, FSmpteTicksPerFrame]));
    sb.AppendLine;
    for i := 0 to High(FTracks) do
      sb.Append(Format('  track %d: %d events, "%s", last tick %d',
        [i, FTracks[i].Count, FTracks[i].Name, FTracks[i].LastTick])).AppendLine;
    Result := sb.ToString;
  finally
    sb.Free;
  end;
end;

end.
