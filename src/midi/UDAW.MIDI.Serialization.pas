unit UDAW.MIDI.Serialization;
{$I udaw.inc}

{ Phase 17 - MIDI: the project-embedded MIDI section (plan section 27 -
  "versioned serialization", MIDI listed as a first-class project part).

  A UDAW project can hold any number of MIDI *clips*, each a full
  TMidiSequence (its own PPQ, tempo / time-signature map and tracks).
  TMidiProject is that owning container; MidiProjectToString / FromString are
  the versioned text codec the Phase 5 project serializer embeds between
  MIDI-BEGIN / MIDI-END, exactly the way GRAPH / TIMELINE / MIXER / TRACKER
  sections already work.

  Format (v1):

    UDAWMIDI 1
    CLIPS 1
    CLIP 0 "Lead" PPQ 480
    TEMPO 0 500000
    TIMESIG 0 4 2
    TRACK 0 "Track 1" CHAN 0 PROG 0
    NOTE 0 480 0 60 100 64
    CC 240 0 7 100
    AUXCH 0 c0 05
    AUXSX 100 f0 43 12 00 f7
    AUXMETA 0 06 4d61726b6572
    ENDTRACK
    ENDCLIP

  An older project with no MIDI-BEGIN block loads fine: the deserializer
  synthesises an empty TMidiProject. }

interface

uses
  SysUtils, Classes,
  UDAW.Errors,
  UDAW.MIDI.Types, UDAW.MIDI.Sequence;

const
  MIDI_PROJECT_MAGIC   = 'UDAWMIDI';
  MIDI_PROJECT_VERSION  = 2;
  MIDI_SER_SUBSYS = 'MIDI.Serialization';

type
  TMidiProject = class
  private
    FClips: TArray<TMidiSequence>;
    FNames: TArray<string>;
    { Stable per-clip ids (Phase 38), independent of array position: a clip
      keeps its Id across every other clip's insert/remove, so a
      TTimelineClip can reference one (see UDAW.Timeline.Model's negative-
      SourceId MIDI-clip convention) without the link breaking whenever an
      earlier clip in the project is deleted or reordered. Persisted as the
      "index" slot of the CLIP line from format v2 on; a v1 file (no stable
      ids) gets ids synthesised 1..N in file order on load. }
    FIds: TArray<Integer>;
    FNextId: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Clear;
    function AddClip(const AName: string; ASeq: TMidiSequence): Integer; // adopts ASeq; returns index
    function NewClip(const AName: string; APPQ: Integer = MIDI_DEFAULT_PPQ): TMidiSequence;
    procedure RemoveClip(AIndex: Integer);
    function ClipCount: Integer;
    function Clip(AIndex: Integer): TMidiSequence;
    function ClipName(AIndex: Integer): string;
    procedure SetClipName(AIndex: Integer; const AName: string);
    function TotalNoteCount: Integer;
    function Clone: TMidiProject;
    function Describe: string;

    { ---- stable-id layer (Phase 38 - Timeline MIDI clip linkage) ---- }
    function IdOfIndex(AIndex: Integer): Integer;
    function IndexOfId(AId: Integer): Integer;              // -1 if not found
    function ClipById(AId: Integer): TMidiSequence;          // nil if not found
    function NameById(AId: Integer): string;
    procedure RemoveClipById(AId: Integer);
    { swaps the sequence of clip AId for ASeq (adopted), keeping its id and name -
      the clips a Timeline references stay valid. False (ASeq freed) if AId is unknown. }
    function ReplaceClipById(AId: Integer; ASeq: TMidiSequence): Boolean;
    { Adds ASeq (adopts it) and returns its new stable Id, not its index -
      the form TCommitMidiTakeCommand and the arrangement engine's Timeline
      linkage want. }
    function AddClipStable(const AName: string; ASeq: TMidiSequence): Integer;
    { Deserializer-only: forces the most-recently-added clip's stable id to
      match what a v2+ file recorded, instead of the auto-assigned counter
      value, so a Timeline clip's stored reference (see UDAW.Timeline.Model's
      negative-SourceId convention) still resolves after a reload. Also
      bumps the auto-id counter past AId so newly created clips in the same
      session never collide with a restored one. }
    procedure ForceLastId(AId: Integer);
  end;

function MidiProjectToString(AProject: TMidiProject): string;
function MidiProjectFromString(const AText: string): TMidiProject;   // caller owns result

implementation

{ ============================ TMidiProject ======================= }

constructor TMidiProject.Create;
begin
  inherited Create;
  FNextId := 1;
end;

destructor TMidiProject.Destroy;
begin
  Clear;
  inherited Destroy;
end;

procedure TMidiProject.Clear;
var
  i: Integer;
begin
  for i := 0 to High(FClips) do
    FClips[i].Free;
  SetLength(FClips, 0);
  SetLength(FNames, 0);
  SetLength(FIds, 0);
end;

function TMidiProject.AddClip(const AName: string; ASeq: TMidiSequence): Integer;
begin
  Result := Length(FClips);
  SetLength(FClips, Result + 1);
  SetLength(FNames, Result + 1);
  SetLength(FIds, Result + 1);
  FClips[Result] := ASeq;
  FNames[Result] := AName;
  FIds[Result] := FNextId;
  Inc(FNextId);
end;

function TMidiProject.AddClipStable(const AName: string; ASeq: TMidiSequence): Integer;
var
  idx: Integer;
begin
  idx := AddClip(AName, ASeq);
  Result := FIds[idx];
end;

function TMidiProject.NewClip(const AName: string; APPQ: Integer): TMidiSequence;
begin
  Result := TMidiSequence.Create(APPQ);
  Result.InitDefault;
  AddClip(AName, Result);
end;

procedure TMidiProject.RemoveClip(AIndex: Integer);
var
  i: Integer;
begin
  if (AIndex < 0) or (AIndex > High(FClips)) then Exit;
  FClips[AIndex].Free;
  for i := AIndex to High(FClips) - 1 do
  begin
    FClips[i] := FClips[i + 1];
    FNames[i] := FNames[i + 1];
    FIds[i] := FIds[i + 1];
  end;
  SetLength(FClips, Length(FClips) - 1);
  SetLength(FNames, Length(FNames) - 1);
  SetLength(FIds, Length(FIds) - 1);
end;

function TMidiProject.IdOfIndex(AIndex: Integer): Integer;
begin
  if (AIndex < 0) or (AIndex > High(FIds)) then Result := 0
  else Result := FIds[AIndex];
end;

function TMidiProject.IndexOfId(AId: Integer): Integer;
var
  i: Integer;
begin
  for i := 0 to High(FIds) do
    if FIds[i] = AId then Exit(i);
  Result := -1;
end;

function TMidiProject.ClipById(AId: Integer): TMidiSequence;
var
  idx: Integer;
begin
  idx := IndexOfId(AId);
  if idx < 0 then Result := nil else Result := FClips[idx];
end;

function TMidiProject.NameById(AId: Integer): string;
var
  idx: Integer;
begin
  idx := IndexOfId(AId);
  if idx < 0 then Result := '' else Result := FNames[idx];
end;

function TMidiProject.ReplaceClipById(AId: Integer; ASeq: TMidiSequence): Boolean;
var
  idx: Integer;
begin
  idx := IndexOfId(AId);
  Result := idx >= 0;
  if not Result then
  begin
    ASeq.Free;
    Exit;
  end;
  if ASeq <> FClips[idx] then
  begin
    FClips[idx].Free;
    FClips[idx] := ASeq;
  end;
end;

procedure TMidiProject.RemoveClipById(AId: Integer);
begin
  RemoveClip(IndexOfId(AId));
end;

procedure TMidiProject.ForceLastId(AId: Integer);
begin
  if High(FIds) < 0 then Exit;
  if AId <= 0 then Exit;
  FIds[High(FIds)] := AId;
  if AId >= FNextId then FNextId := AId + 1;
end;

function TMidiProject.ClipCount: Integer;
begin
  Result := Length(FClips);
end;

function TMidiProject.Clip(AIndex: Integer): TMidiSequence;
begin
  if (AIndex < 0) or (AIndex > High(FClips)) then Result := nil
  else Result := FClips[AIndex];
end;

function TMidiProject.ClipName(AIndex: Integer): string;
begin
  if (AIndex < 0) or (AIndex > High(FNames)) then Result := ''
  else Result := FNames[AIndex];
end;

procedure TMidiProject.SetClipName(AIndex: Integer; const AName: string);
begin
  if (AIndex >= 0) and (AIndex <= High(FNames)) then
    FNames[AIndex] := AName;
end;

function TMidiProject.TotalNoteCount: Integer;
var
  i, t: Integer;
begin
  Result := 0;
  for i := 0 to High(FClips) do
    for t := 0 to FClips[i].TrackCount - 1 do
      Inc(Result, FClips[i].GetTrack(t).NoteCount);
end;

function TMidiProject.Clone: TMidiProject;
var
  i: Integer;
begin
  Result := TMidiProject.Create;
  SetLength(Result.FClips, Length(FClips));
  SetLength(Result.FNames, Length(FNames));
  SetLength(Result.FIds, Length(FIds));
  for i := 0 to High(FClips) do
  begin
    Result.FClips[i] := FClips[i].Clone;
    Result.FNames[i] := FNames[i];
    Result.FIds[i] := FIds[i];
  end;
  Result.FNextId := FNextId;
end;

function TMidiProject.Describe: string;
var
  i: Integer;
begin
  Result := Format('MIDI project: %d clip(s), %d note(s) total', [ClipCount, TotalNoteCount]);
  for i := 0 to High(FClips) do
    Result := Result + sLineBreak + Format('  clip %d "%s": %s',
      [i, FNames[i], FClips[i].Describe]);
end;

{ ============================ text codec ======================== }

function HexOf(const B: TBytes): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(B) do
  begin
    if i > 0 then Result := Result + ' ';
    Result := Result + IntToHex(B[i], 2);
  end;
end;

function BytesOfHex(const S: string): TBytes;
var
  parts: TArray<string>;
  i, n, v: Integer;
begin
  parts := S.Trim.Split([' ', #9], TStringSplitOptions.ExcludeEmpty);
  SetLength(Result, Length(parts));
  n := 0;
  for i := 0 to High(parts) do
  begin
    if TryStrToInt('$' + parts[i], v) then
    begin
      Result[n] := Byte(v);
      Inc(n);
    end;
  end;
  SetLength(Result, n);
end;

function Q(const S: string): string;
begin
  Result := '"' + StringReplace(S, '"', '''', [rfReplaceAll]) + '"';
end;

function TakeQuoted(var S: string): string;
var
  i, closeAt: Integer;
begin
  S := TrimLeft(S);
  if (S = '') or (S[1] <> '"') then
    RaiseUDAW(errConfig, MIDI_SER_SUBSYS, 'MIDI parse: expected a quoted value');
  closeAt := 0;
  for i := 2 to Length(S) do
    if S[i] = '"' then begin closeAt := i; Break; end;
  if closeAt = 0 then
    RaiseUDAW(errConfig, MIDI_SER_SUBSYS, 'MIDI parse: unterminated quoted value');
  Result := Copy(S, 2, closeAt - 2);
  S := TrimLeft(Copy(S, closeAt + 1, MaxInt));
end;

function Tok(var S: string): string;
var
  sp: Integer;
begin
  S := TrimLeft(S);
  sp := Pos(' ', S);
  if sp = 0 then sp := Pos(#9, S);
  if sp = 0 then begin Result := S; S := ''; end
  else begin Result := Copy(S, 1, sp - 1); S := TrimLeft(Copy(S, sp + 1, MaxInt)); end;
end;

function I64(const S: string): Int64;
begin
  if not TryStrToInt64(Trim(S), Result) then
    RaiseUDAWFmt(errConfig, MIDI_SER_SUBSYS, 'MIDI parse: "%s" is not an integer', [S]);
end;

function I32(const S: string): Integer;
begin
  Result := Integer(I64(S));
end;

function MidiProjectToString(AProject: TMidiProject): string;
var
  sb: TStringBuilder;
  ci, ti, ni, cci, ai, i: Integer;
  seq: TMidiSequence;
  trk: TMidiTrackSeq;
  ev: TMidiEvent;
  raw: TBytes;
begin
  sb := TStringBuilder.Create;
  try
    sb.Append(MIDI_PROJECT_MAGIC).Append(' ').Append(MIDI_PROJECT_VERSION).AppendLine;
    sb.Append('CLIPS ').Append(AProject.ClipCount).AppendLine;

    for ci := 0 to AProject.ClipCount - 1 do
    begin
      seq := AProject.Clip(ci);
      { v2: the "index" slot of CLIP is the clip's stable Id (Phase 38), not
        its array position - IndexOfId/ClipById resolve it back on load. }
      sb.Append('CLIP ').Append(AProject.IdOfIndex(ci)).Append(' ').Append(Q(AProject.ClipName(ci)))
        .Append(' PPQ ').Append(seq.PPQ).AppendLine;

      for i := 0 to seq.TempoPointCount - 1 do
        sb.Append('TEMPO ').Append(seq.GetTempoPoint(i).Tick).Append(' ')
          .Append(seq.GetTempoPoint(i).MicrosPerQuarter).AppendLine;
      for i := 0 to seq.TimeSigPointCount - 1 do
        sb.Append('TIMESIG ').Append(seq.GetTimeSigPoint(i).Tick).Append(' ')
          .Append(seq.GetTimeSigPoint(i).Num).Append(' ')
          .Append(seq.GetTimeSigPoint(i).DenPow2).AppendLine;

      for ti := 0 to seq.TrackCount - 1 do
      begin
        trk := seq.GetTrack(ti);
        trk.SortNotes;
        sb.Append('TRACK ').Append(ti).Append(' ').Append(Q(trk.Name))
          .Append(' CHAN ').Append(trk.ChannelHint)
          .Append(' PROG ').Append(trk.ProgramHint).AppendLine;
        for ni := 0 to trk.NoteCount - 1 do
          sb.Append('NOTE ')
            .Append(trk.Notes[ni].StartTick).Append(' ')
            .Append(trk.Notes[ni].LengthTick).Append(' ')
            .Append(trk.Notes[ni].Channel).Append(' ')
            .Append(trk.Notes[ni].Note).Append(' ')
            .Append(trk.Notes[ni].Velocity).Append(' ')
            .Append(trk.Notes[ni].OffVelocity).AppendLine;
        for cci := 0 to trk.CCCount - 1 do
          sb.Append('CC ')
            .Append(trk.Controllers[cci].Tick).Append(' ')
            .Append(trk.Controllers[cci].Channel).Append(' ')
            .Append(trk.Controllers[cci].Controller).Append(' ')
            .Append(trk.Controllers[cci].Value).AppendLine;
        for ai := 0 to trk.AuxCount - 1 do
        begin
          ev := trk.Aux[ai];
          case ev.Kind of
            mekChannel:
              begin
                if ((ev.Msg.Status and $F0) = MIDI_PROGRAM_CHANGE) or
                   ((ev.Msg.Status and $F0) = MIDI_CHAN_AFTERTOUCH) then
                begin
                  SetLength(raw, 2);
                  raw[0] := ev.Msg.Status; raw[1] := ev.Msg.Data1;
                end
                else
                begin
                  SetLength(raw, 3);
                  raw[0] := ev.Msg.Status; raw[1] := ev.Msg.Data1; raw[2] := ev.Msg.Data2;
                end;
                sb.Append('AUXCH ').Append(ev.Tick).Append(' ').Append(HexOf(raw)).AppendLine;
              end;
            mekSysEx:
              sb.Append('AUXSX ').Append(ev.Tick).Append(' ').Append(HexOf(ev.Bytes)).AppendLine;
            mekMeta:
              sb.Append('AUXMETA ').Append(ev.Tick).Append(' ')
                .Append(IntToHex(ev.MetaType, 2)).Append(' ')
                .Append(HexOf(ev.Bytes)).AppendLine;
          end;
        end;
        sb.Append('ENDTRACK').AppendLine;
      end;
      sb.Append('ENDCLIP').AppendLine;
    end;
    Result := sb.ToString;
  finally
    sb.Free;
  end;
end;

function MidiProjectFromString(const AText: string): TMidiProject;
var
  lines: TStringList;
  li: Integer;
  raw, line, t: string;
  proj: TMidiProject;
  seq: TMidiSequence;
  trk: TMidiTrackSeq;
  haveHeader: Boolean;
  ver: Integer;
  note: TMidiNote;
  cc: TMidiCC;
  ev: TMidiEvent;
  blob: TBytes;
  nm: string;
  ppq, num, denPow2, mtv, clipIdTok: Integer;
  tkv: Int64;
  usv: Cardinal;
begin
  lines := TStringList.Create;
  proj := TMidiProject.Create;
  ver := 0;
  seq := nil;
  trk := nil;
  try
    lines.Text := AText;
    haveHeader := False;

    for li := 0 to lines.Count - 1 do
    begin
      raw := Trim(lines[li]);
      if (raw = '') or (raw[1] = '#') then Continue;
      line := raw;
      t := Tok(line);

      if not haveHeader then
      begin
        if not SameText(t, MIDI_PROJECT_MAGIC) then
          RaiseUDAW(errConfig, MIDI_SER_SUBSYS, 'not a UDAWMIDI section');
        ver := I32(line);
        if (ver <= 0) or (ver > MIDI_PROJECT_VERSION) then
          RaiseUDAWFmt(errConfig, MIDI_SER_SUBSYS,
            'unsupported UDAWMIDI version %d (reader supports up to %d)',
            [ver, MIDI_PROJECT_VERSION]);
        haveHeader := True;
        Continue;
      end;

      if SameText(t, 'CLIPS') then
      begin
        // advisory only; the clip list is rebuilt from the CLIP lines
      end
      else if SameText(t, 'CLIP') then
      begin
        clipIdTok := I32(Tok(line));  // v1: positional index, ignored; v2+: stable id
        nm := TakeQuoted(line);
        Tok(line);                    // 'PPQ'
        ppq := I32(line);
        seq := TMidiSequence.Create(ppq);
        seq.Clear;
        proj.AddClip(nm, seq);
        if ver >= 2 then proj.ForceLastId(clipIdTok);
        trk := nil;
      end
      else if SameText(t, 'TEMPO') then
      begin
        if seq = nil then RaiseUDAW(errConfig, MIDI_SER_SUBSYS, 'TEMPO outside a CLIP');
        tkv := I64(Tok(line));
        usv := Cardinal(I64(line));
        if usv = 0 then usv := 1;
        seq.SetTempoAt(tkv, 60000000.0 / usv);
      end
      else if SameText(t, 'TIMESIG') then
      begin
        if seq = nil then RaiseUDAW(errConfig, MIDI_SER_SUBSYS, 'TIMESIG outside a CLIP');
        tkv := I64(Tok(line));
        num := I32(Tok(line));
        denPow2 := I32(line);
        seq.SetTimeSigAt(tkv, num, 1 shl denPow2);
      end
      else if SameText(t, 'TRACK') then
      begin
        if seq = nil then RaiseUDAW(errConfig, MIDI_SER_SUBSYS, 'TRACK outside a CLIP');
        Tok(line);                    // index
        nm := TakeQuoted(line);
        trk := seq.AddTrack(nm);
        Tok(line);                    // 'CHAN'
        trk.ChannelHint := I32(Tok(line));
        Tok(line);                    // 'PROG'
        trk.ProgramHint := I32(line);
      end
      else if SameText(t, 'NOTE') then
      begin
        if trk = nil then RaiseUDAW(errConfig, MIDI_SER_SUBSYS, 'NOTE outside a TRACK');
        FillChar(note, SizeOf(note), 0);
        note.Id := seq.NewNoteId;
        note.StartTick := I64(Tok(line));
        note.LengthTick := I64(Tok(line));
        note.Channel := I32(Tok(line));
        note.Note := I32(Tok(line));
        note.Velocity := I32(Tok(line));
        note.OffVelocity := I32(line);
        trk.AddNote(note);
      end
      else if SameText(t, 'CC') then
      begin
        if trk = nil then RaiseUDAW(errConfig, MIDI_SER_SUBSYS, 'CC outside a TRACK');
        cc.Tick := I64(Tok(line));
        cc.Channel := I32(Tok(line));
        cc.Controller := I32(Tok(line));
        cc.Value := I32(line);
        trk.AddCC(cc);
      end
      else if SameText(t, 'AUXCH') then
      begin
        if trk = nil then RaiseUDAW(errConfig, MIDI_SER_SUBSYS, 'AUXCH outside a TRACK');
        FillChar(ev, SizeOf(ev), 0);
        ev.Tick := I64(Tok(line));
        blob := BytesOfHex(line);
        ev.Kind := mekChannel;
        if Length(blob) >= 1 then ev.Msg.Status := blob[0];
        if Length(blob) >= 2 then ev.Msg.Data1 := blob[1];
        if Length(blob) >= 3 then ev.Msg.Data2 := blob[2];
        trk.AddAux(ev);
      end
      else if SameText(t, 'AUXSX') then
      begin
        if trk = nil then RaiseUDAW(errConfig, MIDI_SER_SUBSYS, 'AUXSX outside a TRACK');
        FillChar(ev, SizeOf(ev), 0);
        ev.Tick := I64(Tok(line));
        ev.Kind := mekSysEx;
        ev.Bytes := BytesOfHex(line);
        trk.AddAux(ev);
      end
      else if SameText(t, 'AUXMETA') then
      begin
        if trk = nil then RaiseUDAW(errConfig, MIDI_SER_SUBSYS, 'AUXMETA outside a TRACK');
        FillChar(ev, SizeOf(ev), 0);
        ev.Tick := I64(Tok(line));
        ev.Kind := mekMeta;
        if not TryStrToInt('$' + Trim(Tok(line)), mtv) then mtv := 1;
        ev.MetaType := Byte(mtv);
        ev.Bytes := BytesOfHex(line);
        trk.AddAux(ev);
      end
      else if SameText(t, 'ENDTRACK') then
      begin
        if trk <> nil then begin trk.SortNotes; trk.SortCC; end;
        trk := nil;
      end
      else if SameText(t, 'ENDCLIP') then
      begin
        seq := nil;
        trk := nil;
      end
      else
        RaiseUDAWFmt(errConfig, MIDI_SER_SUBSYS, 'MIDI parse: unexpected line "%s"', [raw]);
    end;

    if not haveHeader then
      RaiseUDAW(errConfig, MIDI_SER_SUBSYS, 'empty or headerless UDAWMIDI section');

    Result := proj;
    proj := nil;
  finally
    proj.Free;
    lines.Free;
  end;
end;

end.
