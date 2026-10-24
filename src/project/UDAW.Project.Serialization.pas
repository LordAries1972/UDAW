unit UDAW.Project.Serialization;
{$I udaw.inc}

{ Phase 5 - Project System: a small, versioned, human-readable text
  serializer for TProjectDocument (plan section 27: "do not save the entire
  project in one fragile binary structure").

  The document is written as a sequence of tagged fields followed by an
  embedded GRAPH section that reuses the Phase 4 graph serializer verbatim -
  routing is never re-derived or re-encoded, it round-trips byte-for-byte
  through the same GraphToString / GraphFromString the Graph tab already
  exercises. Later phases (Timeline, Mixer, Tracker, ...) add their own
  BEGIN/END sections the same way, without breaking this reader: an unknown
  trailing section is rejected rather than silently ignored, so a partially
  understood file never loads with data quietly missing (plan rule: never
  deserialize raw class memory; a project file must fail loudly, not fail
  silently).

  Format:

    UDAWPROJECT 1
    UUID (a braced GUID literal)
    NAME "My Project"
    CREATED 2026-09-09 12:00:00
    MODIFIED 2026-09-09 12:05:30
    TEMPO 128.000000
    TIMESIG 4 4
    SAMPLERATE 48000
    CHANNELS 2
    GRAPH-BEGIN
    UDAWGRAPH 1
    CHANNELS 2
    NODE 1 output "Master" -
    GRAPH-END }

interface

uses
  SysUtils, Classes,
  UDAW.Errors,
  UDAW.Project.Document, UDAW.Timeline.Time,
  UDAW.Audio.Graph.Serializer,
  UDAW.Timeline.Model, UDAW.Timeline.Serialization,
  UDAW.Mixer.Model, UDAW.Mixer.Serialization,
  UDAW.Tracker.Pattern, UDAW.Tracker.Serialization, UDAW.Tracker.Player,
  UDAW.MIDI.Serialization, UDAW.Pattern.Model, UDAW.Drum.KitModel,
  UDAW.Composer.SongSpec, UDAW.Composer.Lyrics, UDAW.Composer.Serialization,
  UDAW.Project.WindowLayout, UDAW.Project.DialogPaths;

const
  PROJECT_FILE_MAGIC   = 'UDAWPROJECT';
  { v1: metadata + embedded graph.  v2: adds the embedded TIMELINE section.
    v3: adds the embedded MIXER section.  v4: adds the embedded TRACKER section.
    v5: adds the embedded MIDI section (an older file with no MIDI block loads -
    the deserializer leaves an empty TMidiProject).  v6: adds the embedded
    AISPEC section (docs/AIPlan.md Phase 1: Structured Song Specification +
    lyrics; an older file with no AISPEC block loads - the deserializer
    leaves an empty TSongSpec/TLyricDocument pair).  v7: adds the embedded
    WINDOWS section (per-project remembered window layout; an older file
    with no WINDOWS block loads - the deserializer leaves an empty
    TWindowLayout, i.e. no windows reopen).  Every older section that is
    absent is still synthesised, so v1..v7 all round-trip through this
    reader.  v9: adds the embedded PATTERNS section (the Pattern editor's
    rhythm patterns with the instruments they use; an older file with no
    PATTERNS block loads - the deserializer leaves an empty library).  v10: adds the
    embedded DRUMKIT section (the drum machine's pads - sample, level, pan, mute, solo,
    choke, mode and a waveform overview; an older file with no DRUMKIT block loads and
    leaves the player's current kit alone).  v11: adds the embedded DIALOGS section (the last
    path each file dialog was used with; an older file with no DIALOGS block loads with none).
    v12: adds the SCORESPREAD line (the Score's vertical line spacing; an older file without it
    loads with the normal spacing). }
  PROJECT_FILE_VERSION = 12;
  PROJECT_FILE_EXT     = '.udawproj';

function ProjectToString(ADoc: TProjectDocument): string;
{ Raises EUDAWError (errConfig) on a malformed or unsupported document.
  Caller owns the returned document. }
function ProjectFromString(const AText: string): TProjectDocument;

{ Atomic save: written to a temp file in the same directory then renamed into
  place, so a crash or power loss mid-write can never corrupt the previous
  good copy (mirrors UDAW.Config.Save). Marks ADoc clean and records
  AFileName on success. }
procedure SaveProjectToFile(ADoc: TProjectDocument; const AFileName: string);
{ Marks the loaded document clean and records AFileName. }
function LoadProjectFromFile(const AFileName: string): TProjectDocument;

implementation

{$IFDEF MSWINDOWS}
uses
  Windows;   // expands the inline RenameFile (H2443)
{$ENDIF}

function Iso(ADateTime: TDateTime): string;
var
  y, mo, d, h, mi, s, ms: Word;
begin
  DecodeDate(ADateTime, y, mo, d);
  DecodeTime(ADateTime, h, mi, s, ms);
  Result := Format('%.4d-%.2d-%.2d %.2d:%.2d:%.2d', [y, mo, d, h, mi, s]);
end;

function ParseIso(const AText: string; out ADateTime: TDateTime): Boolean;
var
  datePart, timePart: string;
  y, mo, d, h, mi, s: Integer;
  sp: Integer;
begin
  Result := False;
  sp := Pos(' ', AText);
  if sp = 0 then Exit;
  datePart := Copy(AText, 1, sp - 1);
  timePart := Copy(AText, sp + 1, MaxInt);
  if (Length(datePart) <> 10) or (Length(timePart) < 8) then Exit;
  if not TryStrToInt(Copy(datePart, 1, 4), y) then Exit;
  if not TryStrToInt(Copy(datePart, 6, 2), mo) then Exit;
  if not TryStrToInt(Copy(datePart, 9, 2), d) then Exit;
  if not TryStrToInt(Copy(timePart, 1, 2), h) then Exit;
  if not TryStrToInt(Copy(timePart, 4, 2), mi) then Exit;
  if not TryStrToInt(Copy(timePart, 7, 2), s) then Exit;
  try
    ADateTime := EncodeDate(y, mo, d) + EncodeTime(h, mi, s, 0);
    Result := True;
  except
    Result := False;
  end;
end;

function QuoteStr(const S: string): string;
begin
  Result := '"' + StringReplace(S, '"', '''', [rfReplaceAll]) + '"';
end;

function TakeQuoted(var S: string): string;
var
  i, closeAt: Integer;
begin
  S := TrimLeft(S);
  if (S = '') or (S[1] <> '"') then
    RaiseUDAW(errConfig, PROJECT_SUBSYS, 'project parse: expected a quoted value');
  closeAt := 0;
  for i := 2 to Length(S) do
    if S[i] = '"' then begin closeAt := i; Break; end;
  if closeAt = 0 then
    RaiseUDAW(errConfig, PROJECT_SUBSYS, 'project parse: unterminated quoted value');
  Result := Copy(S, 2, closeAt - 2);
  S := TrimLeft(Copy(S, closeAt + 1, MaxInt));
end;

function TakeToken(var S: string): string;
var
  sp: Integer;
begin
  S := TrimLeft(S);
  sp := Pos(' ', S);
  if sp = 0 then sp := Pos(#9, S);
  if sp = 0 then
  begin
    Result := S;
    S := '';
  end
  else
  begin
    Result := Copy(S, 1, sp - 1);
    S := TrimLeft(Copy(S, sp + 1, MaxInt));
  end;
end;

function ProjectToString(ADoc: TProjectDocument): string;
var
  sb: TStringBuilder;
  tp: TTempoPoint;
begin
  sb := TStringBuilder.Create;
  try
    sb.Append(PROJECT_FILE_MAGIC).Append(' ').Append(PROJECT_FILE_VERSION).AppendLine;
    sb.Append('UUID ').Append(GUIDToString(ADoc.UUID)).AppendLine;
    sb.Append('NAME ').Append(QuoteStr(ADoc.Name)).AppendLine;
    if ADoc.Author <> '' then
      sb.Append('AUTHOR ').Append(QuoteStr(ADoc.Author)).AppendLine;
    sb.Append('EXPORT ').Append(ADoc.ExportSettings.VideoBitrateKbps).Append(' ')
      .Append(ADoc.ExportSettings.MaxWidth).Append(' ')
      .Append(ADoc.ExportSettings.AudioBitrateKbps).AppendLine;
    sb.Append('SCORESPREAD ').Append(FloatToStr(ADoc.ScoreSpread, TFormatSettings.Invariant)).AppendLine;
    sb.Append('CREATED ').Append(Iso(ADoc.CreatedUTC)).AppendLine;
    sb.Append('MODIFIED ').Append(Iso(ADoc.ModifiedUTC)).AppendLine;
    sb.Append('TEMPO ').Append(FloatToStr(ADoc.TempoBPM, TFormatSettings.Invariant)).AppendLine;
    for tp in ADoc.TempoMap do
      sb.Append('TEMPOPT ').Append(FloatToStr(tp.Seconds, TFormatSettings.Invariant)).Append(' ')
        .Append(FloatToStr(tp.Bpm, TFormatSettings.Invariant)).AppendLine;
    sb.Append('TIMESIG ').Append(ADoc.TimeSigNum).Append(' ').Append(ADoc.TimeSigDen).AppendLine;
    sb.Append('SAMPLERATE ').Append(ADoc.SampleRate).AppendLine;
    sb.Append('CHANNELS ').Append(ADoc.Channels).AppendLine;
    sb.Append('GRAPH-BEGIN').AppendLine;
    sb.Append(GraphToString(ADoc.Graph));
    sb.Append('GRAPH-END').AppendLine;
    sb.Append('TIMELINE-BEGIN').AppendLine;
    sb.Append(TimelineToString(ADoc.Timeline));
    sb.Append('TIMELINE-END').AppendLine;
    sb.Append('MIXER-BEGIN').AppendLine;
    sb.Append(MixerToString(ADoc.Mixer));
    sb.Append('MIXER-END').AppendLine;
    sb.Append('TRKMIXER-BEGIN').AppendLine;
    sb.Append(MixerToString(ADoc.TrackerMixer));
    sb.Append('TRKMIXER-END').AppendLine;
    sb.Append('TRACKER-BEGIN').AppendLine;
    sb.Append(TrackerModuleToString(ADoc.Tracker));
    sb.Append('TRACKER-END').AppendLine;
    sb.Append('MIDI-BEGIN').AppendLine;
    sb.Append(MidiProjectToString(ADoc.Midi));
    sb.Append('MIDI-END').AppendLine;
    sb.Append('PATTERNS-BEGIN').AppendLine;
    sb.Append(PatternLibraryToString(ADoc.Patterns));
    sb.Append('PATTERNS-END').AppendLine;
    sb.Append('DRUMKIT-BEGIN').AppendLine;
    sb.Append(DrumKitToString(ADoc.DrumKit));
    sb.Append('DRUMKIT-END').AppendLine;
    sb.Append('AISPEC-BEGIN').AppendLine;
    sb.Append(SongSpecToString(ADoc.SongSpec, ADoc.Lyrics));
    sb.Append('AISPEC-END').AppendLine;
    sb.Append('WINDOWS-BEGIN').AppendLine;
    sb.Append(WindowLayoutToString(ADoc.Windows));
    sb.Append('WINDOWS-END').AppendLine;
    sb.Append('DIALOGS-BEGIN').AppendLine;
    sb.Append(DialogPathsToString(ADoc.DialogPaths));
    sb.Append('DIALOGS-END').AppendLine;
    Result := sb.ToString;
  finally
    sb.Free;
  end;
end;

function ProjectFromString(const AText: string): TProjectDocument;
var
  lines: TStringList;
  li, ver, num, den, sr, chans: Integer;
  num2: Double;
  tpt: TTempoPoint;
  raw, line, tok: string;
  doc: TProjectDocument;
  haveHeader: Boolean;
  inGraph: Boolean;
  inTimeline: Boolean;
  haveTimeline: Boolean;
  inMixer: Boolean;
  haveMixer: Boolean;
  inTrkMixer: Boolean;
  haveTrkMixer: Boolean;
  inTracker: Boolean;
  haveTracker: Boolean;
  inMidi: Boolean;
  haveMidi: Boolean;
  inPatterns: Boolean;
  havePatterns: Boolean;
  inDrumKit: Boolean;
  haveDrumKit: Boolean;
  inAISpec: Boolean;
  haveAISpec: Boolean;
  inWindows: Boolean;
  haveWindows: Boolean;
  inDialogs, haveDialogs: Boolean;
  dialogLines: TStringList;
  graphLines: TStringList;
  timelineLines: TStringList;
  mixerLines: TStringList;
  trackerLines: TStringList;
  trkMixerLines: TStringList;
  midiLines: TStringList;
  patternLines: TStringList;
  drumKitLines: TStringList;
  aiSpecLines: TStringList;
  windowsLines: TStringList;
  parsedSpec: TSongSpec;
  parsedLyrics: TLyricDocument;
  guid: TGUID;
  dt: TDateTime;
  fs: TFormatSettings;
  expSet: TExportSettings;
begin
  lines := TStringList.Create;
  graphLines := TStringList.Create;
  timelineLines := TStringList.Create;
  mixerLines := TStringList.Create;
  trackerLines := TStringList.Create;
  trkMixerLines := TStringList.Create;
  midiLines := TStringList.Create;
  patternLines := TStringList.Create;
  drumKitLines := TStringList.Create;
  aiSpecLines := TStringList.Create;
  windowsLines := TStringList.Create;
  dialogLines := TStringList.Create;
  doc := nil;
  try
    lines.Text := AText;
    haveHeader := False;
    inGraph := False;
    inTimeline := False;
    haveTimeline := False;
    inMixer := False;
    haveMixer := False;
    inTrkMixer := False;
    haveTrkMixer := False;
    inTracker := False;
    haveTracker := False;
    inMidi := False;
    haveMidi := False;
    inPatterns := False;
    havePatterns := False;
    inDrumKit := False;
    haveDrumKit := False;
    inAISpec := False;
    haveAISpec := False;
    inWindows := False;
    haveWindows := False;
    inDialogs := False;
    haveDialogs := False;
    fs := TFormatSettings.Invariant;

    for li := 0 to lines.Count - 1 do
    begin
      raw := lines[li];

      if inGraph then
      begin
        if SameText(Trim(raw), 'GRAPH-END') then
        begin
          inGraph := False;
          Continue;
        end;
        graphLines.Add(raw);
        Continue;
      end;

      if inTimeline then
      begin
        if SameText(Trim(raw), 'TIMELINE-END') then
        begin
          inTimeline := False;
          Continue;
        end;
        timelineLines.Add(raw);
        Continue;
      end;

      if inMixer then
      begin
        if SameText(Trim(raw), 'MIXER-END') then
        begin
          inMixer := False;
          Continue;
        end;
        mixerLines.Add(raw);
        Continue;
      end;

      if inTrkMixer then
      begin
        if SameText(Trim(raw), 'TRKMIXER-END') then
        begin
          inTrkMixer := False;
          Continue;
        end;
        trkMixerLines.Add(raw);
        Continue;
      end;

      if inTracker then
      begin
        if SameText(Trim(raw), 'TRACKER-END') then
        begin
          inTracker := False;
          Continue;
        end;
        trackerLines.Add(raw);
        Continue;
      end;

      if inMidi then
      begin
        if SameText(Trim(raw), 'MIDI-END') then
        begin
          inMidi := False;
          Continue;
        end;
        midiLines.Add(raw);
        Continue;
      end;

      if inPatterns then
      begin
        if SameText(Trim(raw), 'PATTERNS-END') then
        begin
          inPatterns := False;
          Continue;
        end;
        patternLines.Add(raw);
        Continue;
      end;

      if inDrumKit then
      begin
        if SameText(Trim(raw), 'DRUMKIT-END') then
        begin
          inDrumKit := False;
          Continue;
        end;
        drumKitLines.Add(raw);
        Continue;
      end;

      if inAISpec then
      begin
        if SameText(Trim(raw), 'AISPEC-END') then
        begin
          inAISpec := False;
          Continue;
        end;
        aiSpecLines.Add(raw);
        Continue;
      end;

      if inDialogs then
      begin
        if SameText(Trim(raw), 'DIALOGS-END') then
        begin
          inDialogs := False;
          Continue;
        end;
        dialogLines.Add(raw);
        Continue;
      end;

      if inWindows then
      begin
        if SameText(Trim(raw), 'WINDOWS-END') then
        begin
          inWindows := False;
          Continue;
        end;
        windowsLines.Add(raw);
        Continue;
      end;

      raw := Trim(raw);
      if (raw = '') or (raw[1] = '#') then Continue;

      if not haveHeader then
      begin
        line := raw;
        tok := TakeToken(line);
        if not SameText(tok, PROJECT_FILE_MAGIC) then
          RaiseUDAW(errConfig, PROJECT_SUBSYS,
            'not a UDAW project document (missing ' + PROJECT_FILE_MAGIC + ' header)');
        if not TryStrToInt(Trim(line), ver) then
          RaiseUDAW(errConfig, PROJECT_SUBSYS, 'project header: missing version number');
        if (ver <= 0) or (ver > PROJECT_FILE_VERSION) then
          RaiseUDAWFmt(errConfig, PROJECT_SUBSYS,
            'unsupported project document version %d (reader supports up to %d)',
            [ver, PROJECT_FILE_VERSION]);
        haveHeader := True;
        doc := TProjectDocument.Create;
        Continue;
      end;

      line := raw;
      tok := TakeToken(line);

      if SameText(tok, 'UUID') then
      begin
        try
          guid := StringToGUID(Trim(line));
        except
          RaiseUDAW(errConfig, PROJECT_SUBSYS, 'UUID: malformed GUID');
        end;
        doc.UUID := guid;
      end
      else if SameText(tok, 'NAME') then
        doc.Name := TakeQuoted(line)
      else if SameText(tok, 'AUTHOR') then
        doc.Author := TakeQuoted(line)
      else if SameText(tok, 'EXPORT') then
      begin
        tok := TakeToken(line);
        if not TryStrToInt(tok, num) then
          RaiseUDAW(errConfig, PROJECT_SUBSYS, 'EXPORT: bad video bitrate');
        tok := TakeToken(line);
        if not TryStrToInt(tok, den) then
          RaiseUDAW(errConfig, PROJECT_SUBSYS, 'EXPORT: bad maximum width');
        if (Trim(line) = '') then num2 := 0
        else if not TryStrToInt(Trim(line), sr) then
          RaiseUDAW(errConfig, PROJECT_SUBSYS, 'EXPORT: bad audio bitrate')
        else num2 := sr;
        expSet.VideoBitrateKbps := num;
        expSet.MaxWidth := den;
        expSet.AudioBitrateKbps := Round(num2);
        doc.ExportSettings := expSet;
      end
      else if SameText(tok, 'SCORESPREAD') then
      begin
        if not TryStrToFloat(Trim(line), num2, TFormatSettings.Invariant) then
          RaiseUDAW(errConfig, PROJECT_SUBSYS, 'SCORESPREAD: bad number');
        doc.ScoreSpread := num2;
      end
      else if SameText(tok, 'CREATED') then
      begin
        if not ParseIso(Trim(line), dt) then
          RaiseUDAW(errConfig, PROJECT_SUBSYS, 'CREATED: malformed timestamp');
        doc.CreatedUTC := dt;
      end
      else if SameText(tok, 'MODIFIED') then
      begin
        if not ParseIso(Trim(line), dt) then
          RaiseUDAW(errConfig, PROJECT_SUBSYS, 'MODIFIED: malformed timestamp');
        doc.ModifiedUTC := dt;
      end
      else if SameText(tok, 'TEMPO') then
      begin
        if not TryStrToFloat(Trim(line), num2, fs) then
          RaiseUDAW(errConfig, PROJECT_SUBSYS, 'TEMPO: not a number');
        doc.TempoBPM := num2;
      end
      else if SameText(tok, 'TEMPOPT') then
      begin
        { one tempo change after time 0: seconds, then BPM }
        tok := TakeToken(line);
        if not TryStrToFloat(tok, num2, fs) then
          RaiseUDAW(errConfig, PROJECT_SUBSYS, 'TEMPOPT: bad time');
        tpt.Seconds := num2;
        if not TryStrToFloat(Trim(line), num2, fs) then
          RaiseUDAW(errConfig, PROJECT_SUBSYS, 'TEMPOPT: bad tempo');
        tpt.Bpm := num2;
        doc.TempoMap := doc.TempoMap + [tpt];
      end
      else if SameText(tok, 'TIMESIG') then
      begin
        tok := TakeToken(line);
        if not TryStrToInt(tok, num) then
          RaiseUDAW(errConfig, PROJECT_SUBSYS, 'TIMESIG: bad numerator');
        if not TryStrToInt(Trim(line), den) then
          RaiseUDAW(errConfig, PROJECT_SUBSYS, 'TIMESIG: bad denominator');
        doc.TimeSigNum := num;
        doc.TimeSigDen := den;
      end
      else if SameText(tok, 'SAMPLERATE') then
      begin
        if not TryStrToInt(Trim(line), sr) then
          RaiseUDAW(errConfig, PROJECT_SUBSYS, 'SAMPLERATE: not an integer');
        doc.SampleRate := sr;
      end
      else if SameText(tok, 'CHANNELS') then
      begin
        if not TryStrToInt(Trim(line), chans) then
          RaiseUDAW(errConfig, PROJECT_SUBSYS, 'CHANNELS: not an integer');
        doc.Channels := chans;
      end
      else if SameText(tok, 'GRAPH-BEGIN') then
      begin
        inGraph := True;
        graphLines.Clear;
      end
      else if SameText(tok, 'TIMELINE-BEGIN') then
      begin
        inTimeline := True;
        haveTimeline := True;
        timelineLines.Clear;
      end
      else if SameText(tok, 'MIXER-BEGIN') then
      begin
        inMixer := True;
        haveMixer := True;
        mixerLines.Clear;
      end
      else if SameText(tok, 'TRKMIXER-BEGIN') then
      begin
        inTrkMixer := True;
        haveTrkMixer := True;
        trkMixerLines.Clear;
      end
      else if SameText(tok, 'TRACKER-BEGIN') then
      begin
        inTracker := True;
        haveTracker := True;
        trackerLines.Clear;
      end
      else if SameText(tok, 'MIDI-BEGIN') then
      begin
        inMidi := True;
        haveMidi := True;
        midiLines.Clear;
      end
      else if SameText(tok, 'PATTERNS-BEGIN') then
      begin
        inPatterns := True;
        havePatterns := True;
        patternLines.Clear;
      end
      else if SameText(tok, 'DRUMKIT-BEGIN') then
      begin
        inDrumKit := True;
        haveDrumKit := True;
        drumKitLines.Clear;
      end
      else if SameText(tok, 'AISPEC-BEGIN') then
      begin
        inAISpec := True;
        haveAISpec := True;
        aiSpecLines.Clear;
      end
      else if SameText(tok, 'DIALOGS-BEGIN') then
      begin
        inDialogs := True;
        haveDialogs := True;
        dialogLines.Clear;
      end
      else if SameText(tok, 'WINDOWS-BEGIN') then
      begin
        inWindows := True;
        haveWindows := True;
        windowsLines.Clear;
      end
      else
        RaiseUDAWFmt(errConfig, PROJECT_SUBSYS, 'project parse: unexpected line "%s"', [raw]);
    end;

    if not haveHeader then
      RaiseUDAW(errConfig, PROJECT_SUBSYS, 'empty or headerless project document');
    if inGraph then
      RaiseUDAW(errConfig, PROJECT_SUBSYS, 'GRAPH-BEGIN without a matching GRAPH-END');
    if inTimeline then
      RaiseUDAW(errConfig, PROJECT_SUBSYS, 'TIMELINE-BEGIN without a matching TIMELINE-END');
    if inMixer then
      RaiseUDAW(errConfig, PROJECT_SUBSYS, 'MIXER-BEGIN without a matching MIXER-END');
    if inTrkMixer then
      RaiseUDAW(errConfig, PROJECT_SUBSYS, 'TRKMIXER-BEGIN without a matching TRKMIXER-END');
    if inTracker then
      RaiseUDAW(errConfig, PROJECT_SUBSYS, 'TRACKER-BEGIN without a matching TRACKER-END');
    if inMidi then
      RaiseUDAW(errConfig, PROJECT_SUBSYS, 'MIDI-BEGIN without a matching MIDI-END');
    if inPatterns then
      RaiseUDAW(errConfig, PROJECT_SUBSYS, 'PATTERNS-BEGIN without a matching PATTERNS-END');
    if inDrumKit then
      RaiseUDAW(errConfig, PROJECT_SUBSYS, 'DRUMKIT-BEGIN without a matching DRUMKIT-END');
    if inAISpec then
      RaiseUDAW(errConfig, PROJECT_SUBSYS, 'AISPEC-BEGIN without a matching AISPEC-END');
    if inWindows then
      RaiseUDAW(errConfig, PROJECT_SUBSYS, 'WINDOWS-BEGIN without a matching WINDOWS-END');
    if inDialogs then
      RaiseUDAW(errConfig, PROJECT_SUBSYS, 'DIALOGS-BEGIN without a matching DIALOGS-END');

    doc.ReplaceGraph(GraphFromString(graphLines.Text));
    if haveTimeline then
    begin
      doc.ReplaceTimeline(TimelineFromString(timelineLines.Text));
      { A SOURCE entry with no CLIP referencing it is decoded media the
        project carries for no reason (leftover from an old edit, an
        interrupted import, etc.) - the same dead weight every import codec
        already sweeps via RemoveUnusedSources right after decoding (see
        UDAW.Codec.MP4/MP3/FLAC/Ableton/FLStudio.Timeline). A plain project
        load skipped that sweep, so an orphaned source could persist in the
        file forever even though nothing on the Timeline ever uses it. }
      doc.Timeline.RemoveUnusedSources;
    end;
    if haveMixer then
      doc.ReplaceMixer(MixerFromString(mixerLines.Text))
    else
      doc.Mixer.EnsureMaster;
    if haveTrkMixer then
      doc.ReplaceTrackerMixer(MixerFromString(trkMixerLines.Text))
    else
      doc.TrackerMixer.EnsureMaster;
    if haveTracker then
      doc.ReplaceTracker(TrackerModuleFromString(trackerLines.Text))
    else
      doc.Tracker.InitDefault;
    { the Tracker mixer always has its TRK-CHN strip per channel and the master EQ once loaded, with
      every saved fader / pan / insert / EQ band kept }
    EnsureTrackerMixerStrips(doc.TrackerMixer, doc.Tracker.Channels, doc.Tracker);
    if haveMidi then
      doc.ReplaceMidi(MidiProjectFromString(midiLines.Text));
    { else: the empty TMidiProject created in the constructor is kept }
    if havePatterns then
      doc.ReplacePatterns(PatternLibraryFromString(patternLines.Text));
    { else: the empty TPatternLibrary created in the constructor is kept }
    if haveDrumKit then
      doc.ReplaceDrumKit(DrumKitFromString(drumKitLines.Text));
    { else: the undefined, empty kit created in the constructor is kept }
    if haveAISpec then
    begin
      SongSpecFromString(aiSpecLines.Text, parsedSpec, parsedLyrics);
      doc.ReplaceSongSpec(parsedSpec);
      doc.ReplaceLyrics(parsedLyrics);
    end;
    { else: the empty TSongSpec/TLyricDocument created in the constructor are kept }
    if haveWindows then
      doc.ReplaceWindows(WindowLayoutFromString(windowsLines.Text));
    { else: the empty TWindowLayout created in the constructor is kept }
    if haveDialogs then
      doc.ReplaceDialogPaths(DialogPathsFromString(dialogLines.Text));
    { else: the empty list created in the constructor is kept }
    doc.ClearDirty;
    Result := doc;
    doc := nil;
  finally
    dialogLines.Free;
    windowsLines.Free;
    aiSpecLines.Free;
    patternLines.Free;
    drumKitLines.Free;
    midiLines.Free;
    trackerLines.Free;
    trkMixerLines.Free;
    mixerLines.Free;
    timelineLines.Free;
    graphLines.Free;
    lines.Free;
    doc.Free;   // only non-nil if we raised before handing ownership over
  end;
end;

procedure SaveProjectToFile(ADoc: TProjectDocument; const AFileName: string);
var
  tmp, dir: string;
  sl: TStringList;
begin
  dir := ExtractFilePath(AFileName);
  if dir <> '' then
    ForceDirectories(dir);
  tmp := AFileName + '.tmp';

  sl := TStringList.Create;
  try
    sl.Text := ProjectToString(ADoc);
    if FileExists(tmp) then
      SysUtils.DeleteFile(tmp);
    sl.SaveToFile(tmp);
  finally
    sl.Free;
  end;

  if not FileExists(tmp) then
    RaiseUDAWFmt(errIO, PROJECT_SUBSYS, 'save produced no file at "%s"', [tmp]);

  if FileExists(AFileName) then
    if not SysUtils.DeleteFile(AFileName) then
      RaiseUDAWFmt(errIO, PROJECT_SUBSYS, 'could not remove previous "%s"', [AFileName]);
  if not RenameFile(tmp, AFileName) then
    RaiseUDAWFmt(errIO, PROJECT_SUBSYS, 'could not move "%s" to "%s"', [tmp, AFileName]);

  ADoc.FileName := AFileName;
  ADoc.ClearDirty;
end;

function LoadProjectFromFile(const AFileName: string): TProjectDocument;
var
  sl: TStringList;
begin
  if not FileExists(AFileName) then
    RaiseUDAWFmt(errFileNotFound, PROJECT_SUBSYS, 'project file not found: %s', [AFileName]);
  sl := TStringList.Create;
  try
    sl.LoadFromFile(AFileName);
    Result := ProjectFromString(sl.Text);
  finally
    sl.Free;
  end;
  Result.FileName := AFileName;
  Result.ClearDirty;
end;

end.
