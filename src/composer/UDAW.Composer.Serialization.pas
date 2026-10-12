unit UDAW.Composer.Serialization;
{$I udaw.inc}

{ AI Composition, Phase 1 - the project-embedded Song Specification section
  (docs/AIPlan.md section 14 "Project Storage"). Mirrors the exact pattern
  UDAW.MIDI.Serialization / UDAW.Timeline.Serialization use: a versioned,
  line-oriented text codec the Phase 5 project serializer embeds between
  AISPEC-BEGIN / AISPEC-END, additive to the project format - an older
  project with no AISPEC-BEGIN block loads fine (SongSpecFromString on an
  empty string yields an empty TSongSpec/TLyricDocument pair).

  Format (v1):

    UDAWAISPEC 1
    REQUEST "Create a four-minute dark cyberpunk techno song..."
    PROVIDER "openai" "gpt-4o"
    SEED 1234567890
    META "Neon Resistance" INSTR 0 TEMPO 128 KEY "D" SCALE "minor" TSIG 4 4 DURBARS 128
    SECTION "intro" "Intro" 1 8 0.30
    TRACK "drums_1" "Main Drums" MIDI "drums" TAGS "hard-techno,electronic,punchy" PREFINST "instrument_0105" FALLBACK "Electronic Drum Kit" CHAN 10
    CHORDS "verse_1" 1 "Dm,Bb,C,Dm"
    LYRICLANG "English"
    LYRICSECTION "verse_1"
    LYRICLINE 9 2 "Running through the circuits underneath the neon sky"
    ENDLYRICSECTION

  v2 adds an optional trailing "LOCKED 0|1" token to SECTION and TRACK lines
  (AIPlan.md section 17 PHASE 8 "Preserve locked content" -
  UDAW.Composer.SongSpec.TSongSection/TSongTrackSpec.Locked). A v1 line has
  no such token; the reader treats a missing token as LOCKED 0, so a v1
  payload still round-trips unchanged. }

interface

uses
  SysUtils, Classes,
  UDAW.Errors,
  UDAW.Composer.SongSpec, UDAW.Composer.Lyrics;

const
  AISPEC_MAGIC   = 'UDAWAISPEC';
  AISPEC_VERSION = 2;
  AISPEC_SUBSYS  = 'Composer.Serialization';

{ Serializes ASpec and ALyrics together into one AISPEC-BEGIN/END payload. }
function SongSpecToString(ASpec: TSongSpec; ALyrics: TLyricDocument): string;
{ Parses a payload produced by SongSpecToString. Always returns non-nil
  objects (an empty AText yields an empty spec/lyrics pair) - the caller
  owns both results and must Free them. }
procedure SongSpecFromString(const AText: string; out ASpec: TSongSpec; out ALyrics: TLyricDocument);

implementation

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
    RaiseUDAW(errConfig, AISPEC_SUBSYS, 'AISPEC parse: expected a quoted value');
  closeAt := 0;
  for i := 2 to Length(S) do
    if S[i] = '"' then begin closeAt := i; Break; end;
  if closeAt = 0 then
    RaiseUDAW(errConfig, AISPEC_SUBSYS, 'AISPEC parse: unterminated quoted value');
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

function I32(const S: string): Integer;
begin
  if not TryStrToInt(Trim(S), Result) then
    RaiseUDAWFmt(errConfig, AISPEC_SUBSYS, 'AISPEC parse: "%s" is not an integer', [S]);
end;

function I64(const S: string): Int64;
begin
  if not TryStrToInt64(Trim(S), Result) then
    RaiseUDAWFmt(errConfig, AISPEC_SUBSYS, 'AISPEC parse: "%s" is not an integer', [S]);
end;

function F64(const S: string): Double;
var
  fs: TFormatSettings;
begin
  fs := TFormatSettings.Invariant;
  if not TryStrToFloat(Trim(S), Result, fs) then
    RaiseUDAWFmt(errConfig, AISPEC_SUBSYS, 'AISPEC parse: "%s" is not a number', [S]);
end;

function JoinCSV(const AItems: TArray<string>): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(AItems) do
  begin
    if i > 0 then Result := Result + ',';
    Result := Result + AItems[i];
  end;
end;

function SplitCSV(const AText: string): TArray<string>;
begin
  if Trim(AText) = '' then Exit(nil);
  Result := AText.Split([','], TStringSplitOptions.ExcludeEmpty);
end;

function SongSpecToString(ASpec: TSongSpec; ALyrics: TLyricDocument): string;
var
  sb: TStringBuilder;
  i, j: Integer;
  fs: TFormatSettings;
  sec: TSongSection;
  trk: TSongTrackSpec;
  chord: TChordProgressionEntry;
  lsec: TLyricSection;
  line: TLyricLine;
begin
  fs := TFormatSettings.Invariant;
  sb := TStringBuilder.Create;
  try
    sb.Append(AISPEC_MAGIC).Append(' ').Append(AISPEC_VERSION).AppendLine;
    if ASpec = nil then Exit(sb.ToString);

    sb.Append('REQUEST ').Append(Q(ASpec.OriginalRequest)).AppendLine;
    sb.Append('PROVIDER ').Append(Q(ASpec.ProviderId)).Append(' ').Append(Q(ASpec.ModelId)).AppendLine;
    sb.Append('SEED ').Append(ASpec.GenerationSeed).AppendLine;

    sb.Append('META ').Append(Q(ASpec.Meta.Title))
      .Append(' INSTR ').Append(Ord(ASpec.Meta.Instrumental))
      .Append(' TEMPO ').Append(FloatToStr(ASpec.Meta.Tempo, fs))
      .Append(' KEY ').Append(Q(ASpec.Meta.Key))
      .Append(' SCALE ').Append(Q(ASpec.Meta.Scale))
      .Append(' TSIG ').Append(ASpec.Meta.TimeSigNum).Append(' ').Append(ASpec.Meta.TimeSigDen)
      .Append(' DURBARS ').Append(ASpec.Meta.DurationBars).AppendLine;

    for i := 0 to ASpec.Sections.Count - 1 do
    begin
      sec := ASpec.Sections[i];
      sb.Append('SECTION ').Append(Q(sec.Id)).Append(' ').Append(Q(sec.Name))
        .Append(' ').Append(sec.StartBar).Append(' ').Append(sec.LengthBars)
        .Append(' ').Append(FloatToStr(sec.Energy, fs))
        .Append(' LOCKED ').Append(Ord(sec.Locked)).AppendLine;
    end;

    for i := 0 to ASpec.Tracks.Count - 1 do
    begin
      trk := ASpec.Tracks[i];
      sb.Append('TRACK ').Append(Q(trk.Id)).Append(' ').Append(Q(trk.Name)).Append(' ');
      case trk.Kind of
        stkMidi: sb.Append('MIDI');
        stkAudio: sb.Append('AUDIO');
        stkBus: sb.Append('BUS');
      end;
      sb.Append(' ').Append(Q(trk.Role))
        .Append(' TAGS ').Append(Q(JoinCSV(trk.RequestedTags)))
        .Append(' PREFINST ').Append(Q(trk.PreferredInstrumentId))
        .Append(' FALLBACK ').Append(Q(trk.FallbackCategory))
        .Append(' CHAN ').Append(trk.MidiChannel)
        .Append(' LOCKED ').Append(Ord(trk.Locked))
        .Append(' REQMIDI ').Append(Ord(trk.RequireMidi)).AppendLine;
    end;

    for i := 0 to ASpec.Harmony.Count - 1 do
    begin
      chord := ASpec.Harmony[i];
      sb.Append('CHORDS ').Append(Q(chord.SectionId)).Append(' ').Append(chord.BarsPerChord)
        .Append(' ').Append(Q(JoinCSV(chord.Chords))).AppendLine;
    end;

    if ALyrics <> nil then
    begin
      sb.Append('LYRICLANG ').Append(Q(ALyrics.Language)).AppendLine;
      for i := 0 to ALyrics.Sections.Count - 1 do
      begin
        lsec := ALyrics.Sections[i];
        sb.Append('LYRICSECTION ').Append(Q(lsec.SectionId)).AppendLine;
        for j := 0 to lsec.Lines.Count - 1 do
        begin
          line := lsec.Lines[j];
          sb.Append('LYRICLINE ').Append(line.StartBar).Append(' ').Append(line.DurationBars)
            .Append(' ').Append(Q(line.Text)).AppendLine;
        end;
        sb.Append('ENDLYRICSECTION').AppendLine;
      end;
    end;

    Result := sb.ToString;
  finally
    sb.Free;
  end;
end;

procedure SongSpecFromString(const AText: string; out ASpec: TSongSpec; out ALyrics: TLyricDocument);
var
  lines: TStringList;
  li, ver: Integer;
  raw, line, t: string;
  spec: TSongSpec;
  lyrics: TLyricDocument;
  haveHeader: Boolean;
  sec: TSongSection;
  trk: TSongTrackSpec;
  chord: TChordProgressionEntry;
  lsec: TLyricSection;
  kindTok: string;
begin
  spec := TSongSpec.Create;
  lyrics := TLyricDocument.Create;
  lsec := nil;
  lines := TStringList.Create;
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
        if not SameText(t, AISPEC_MAGIC) then
          RaiseUDAW(errConfig, AISPEC_SUBSYS, 'not a UDAWAISPEC section');
        ver := I32(line);
        if (ver <= 0) or (ver > AISPEC_VERSION) then
          RaiseUDAWFmt(errConfig, AISPEC_SUBSYS,
            'unsupported UDAWAISPEC version %d (reader supports up to %d)', [ver, AISPEC_VERSION]);
        haveHeader := True;
        Continue;
      end;

      if SameText(t, 'REQUEST') then
        spec.OriginalRequest := TakeQuoted(line)
      else if SameText(t, 'PROVIDER') then
      begin
        spec.ProviderId := TakeQuoted(line);
        spec.ModelId := TakeQuoted(line);
      end
      else if SameText(t, 'SEED') then
        spec.GenerationSeed := I64(line)
      else if SameText(t, 'META') then
      begin
        spec.Meta.Title := TakeQuoted(line);
        Tok(line); // 'INSTR'
        spec.Meta.Instrumental := I32(Tok(line)) <> 0;
        Tok(line); // 'TEMPO'
        spec.Meta.Tempo := F64(Tok(line));
        Tok(line); // 'KEY'
        spec.Meta.Key := TakeQuoted(line);
        Tok(line); // 'SCALE'
        spec.Meta.Scale := TakeQuoted(line);
        Tok(line); // 'TSIG'
        spec.Meta.TimeSigNum := I32(Tok(line));
        spec.Meta.TimeSigDen := I32(Tok(line));
        Tok(line); // 'DURBARS'
        spec.Meta.DurationBars := I32(line);
      end
      else if SameText(t, 'SECTION') then
      begin
        sec := TSongSection.Create;
        sec.Id := TakeQuoted(line);
        sec.Name := TakeQuoted(line);
        sec.StartBar := I32(Tok(line));
        sec.LengthBars := I32(Tok(line));
        sec.Energy := F64(Tok(line));
        if SameText(Tok(line), 'LOCKED') then
          sec.Locked := I32(line) <> 0;
        spec.AddSection(sec);
      end
      else if SameText(t, 'TRACK') then
      begin
        trk := TSongTrackSpec.Create;
        trk.Id := TakeQuoted(line);
        trk.Name := TakeQuoted(line);
        kindTok := Tok(line);
        if SameText(kindTok, 'MIDI') then trk.Kind := stkMidi
        else if SameText(kindTok, 'AUDIO') then trk.Kind := stkAudio
        else trk.Kind := stkBus;
        trk.Role := TakeQuoted(line);
        Tok(line); // 'TAGS'
        trk.RequestedTags := SplitCSV(TakeQuoted(line));
        Tok(line); // 'PREFINST'
        trk.PreferredInstrumentId := TakeQuoted(line);
        Tok(line); // 'FALLBACK'
        trk.FallbackCategory := TakeQuoted(line);
        Tok(line); // 'CHAN'
        trk.MidiChannel := I32(Tok(line));
        if SameText(Tok(line), 'LOCKED') then
          trk.Locked := I32(Tok(line)) <> 0;
        if SameText(Tok(line), 'REQMIDI') then
          trk.RequireMidi := I32(line) <> 0;
        spec.AddTrack(trk);
      end
      else if SameText(t, 'CHORDS') then
      begin
        chord := TChordProgressionEntry.Create;
        chord.SectionId := TakeQuoted(line);
        chord.BarsPerChord := I32(Tok(line));
        chord.Chords := SplitCSV(TakeQuoted(line));
        spec.AddChordProgression(chord);
      end
      else if SameText(t, 'LYRICLANG') then
        lyrics.Language := TakeQuoted(line)
      else if SameText(t, 'LYRICSECTION') then
      begin
        lsec := TLyricSection.Create(TakeQuoted(line));
        lyrics.AddSection(lsec);
      end
      else if SameText(t, 'LYRICLINE') then
      begin
        if lsec = nil then
          RaiseUDAW(errConfig, AISPEC_SUBSYS, 'LYRICLINE outside a LYRICSECTION');
        lsec.AddLine(TLyricLine.Create('', I32(Tok(line)), I32(Tok(line))));
        lsec.Lines[lsec.Lines.Count - 1].Text := TakeQuoted(line);
      end
      else if SameText(t, 'ENDLYRICSECTION') then
        lsec := nil
      else
        RaiseUDAWFmt(errConfig, AISPEC_SUBSYS, 'AISPEC parse: unexpected line "%s"', [raw]);
    end;

    ASpec := spec;
    ALyrics := lyrics;
    spec := nil;
    lyrics := nil;
  finally
    spec.Free;
    lyrics.Free;
    lines.Free;
  end;
end;

end.
