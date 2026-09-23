unit UDAW.Composer.Validation;
{$I udaw.inc}

{ AI Composition, Phase 1 - Internal Data Model (docs/AIPlan.md section 17
  Phase 1's "Implement validation", and sections D "SongSpecificationParser"
  / G "MusicalValidationEngine").

  TSongSpecValidator is the safety gate between whatever a (later-phase) AI
  provider returns and anything ever touching the real timeline (AIPlan.md
  section 1's core rule: "The AI must not directly manipulate the DAW
  timeline from unvalidated text"). It only checks the SCHEMA-LEVEL
  concerns available at this phase (required fields, ranges, internal
  consistency of sections/harmony/lyrics); note-range / key-membership /
  instrument-range checks that need actual generated MIDI or a resolved
  instrument (section G's "Detect MIDI notes outside an instrument's usable
  range") are deferred to the arrangement-engine phase, once notes and
  resolved instruments exist to check.

  ApplyDefaults mutates ASpec in place for missing optional values (section
  D: "Apply safe defaults") - it never invents section/track content, only
  fills genuinely optional numeric/string fields. }

interface

uses
  SysUtils, Generics.Collections,
  UDAW.Composer.SongSpec, UDAW.Composer.Lyrics;

type
  TValidationSeverity = (vsInfo, vsWarning, vsError);

  TValidationIssue = record
    Severity: TValidationSeverity;
    Message: string;
    SectionId: string;   // '' if not section-specific
    TrackId: string;      // '' if not track-specific
    constructor Create(ASeverity: TValidationSeverity; const AMessage: string;
      const ASectionId: string = ''; const ATrackId: string = '');
  end;
  TValidationIssues = TArray<TValidationIssue>;

  TSongSpecValidator = class
  public
    { Fills in safe defaults for missing/degenerate optional fields
      (tempo <= 0, time signature 0/0, chord bars-per-chord <= 0, and so
      on). Never touches required identity fields (section/track Id). }
    class procedure ApplyDefaults(ASpec: TSongSpec);
    { Schema + internal-consistency validation. Returns an empty array when
      the spec is clean. Does not raise - callers decide whether any
      vsError issue blocks proceeding. }
    class function Validate(ASpec: TSongSpec; ALyrics: TLyricDocument = nil): TValidationIssues;
    class function HasErrors(const AIssues: TValidationIssues): Boolean;
  end;

implementation

const
  SUBSYS = 'Composer.Validation';

constructor TValidationIssue.Create(ASeverity: TValidationSeverity; const AMessage: string;
  const ASectionId, ATrackId: string);
begin
  Severity := ASeverity;
  Message := AMessage;
  SectionId := ASectionId;
  TrackId := ATrackId;
end;

type
  TIssueList = TList<TValidationIssue>;

procedure AddIssue(AList: TIssueList; ASeverity: TValidationSeverity; const AMessage: string;
  const ASectionId: string = ''; const ATrackId: string = '');
begin
  AList.Add(TValidationIssue.Create(ASeverity, AMessage, ASectionId, ATrackId));
end;

class procedure TSongSpecValidator.ApplyDefaults(ASpec: TSongSpec);
var
  i: Integer;
  t: TSongTrackSpec;
  c: TChordProgressionEntry;
begin
  if ASpec = nil then Exit;
  if Trim(ASpec.Meta.Title) = '' then ASpec.Meta.Title := 'Untitled Song';
  if (ASpec.Meta.Tempo <= 0) then ASpec.Meta.Tempo := 120.0;
  if Trim(ASpec.Meta.Key) = '' then ASpec.Meta.Key := 'C';
  if Trim(ASpec.Meta.Scale) = '' then ASpec.Meta.Scale := 'major';
  if (ASpec.Meta.TimeSigNum <= 0) then ASpec.Meta.TimeSigNum := 4;
  if not (ASpec.Meta.TimeSigDen in [1, 2, 4, 8, 16, 32, 64]) then ASpec.Meta.TimeSigDen := 4;
  if (ASpec.Meta.DurationBars <= 0) then ASpec.Meta.DurationBars := 32;

  for i := 0 to ASpec.Tracks.Count - 1 do
  begin
    t := ASpec.Tracks[i];
    if Trim(t.Role) = '' then t.Role := 'other';
    if Trim(t.FallbackCategory) = '' then t.FallbackCategory := 'General';
  end;

  for i := 0 to ASpec.Harmony.Count - 1 do
  begin
    c := ASpec.Harmony[i];
    if c.BarsPerChord <= 0 then c.BarsPerChord := 1;
  end;
end;

class function TSongSpecValidator.Validate(ASpec: TSongSpec; ALyrics: TLyricDocument): TValidationIssues;
var
  issues: TIssueList;
  i, j: Integer;
  sec: TSongSection;
  trk: TSongTrackSpec;
  chord: TChordProgressionEntry;
  lyricSec: TLyricSection;
  line: TLyricLine;
  hasVocalTrack: Boolean;
begin
  issues := TIssueList.Create;
  try
    if ASpec = nil then
    begin
      AddIssue(issues, vsError, 'song specification is nil');
      Exit(issues.ToArray);
    end;

    { --- project meta --- }
    if Trim(ASpec.Meta.Title) = '' then
      AddIssue(issues, vsError, 'project.title is required');
    if (ASpec.Meta.Tempo < 20) or (ASpec.Meta.Tempo > 999) then
      AddIssue(issues, vsError, Format('project.tempo %.1f is out of range [20, 999]', [ASpec.Meta.Tempo]));
    if not (ASpec.Meta.TimeSigDen in [1, 2, 4, 8, 16, 32, 64]) then
      AddIssue(issues, vsError, Format('project.timeSignature denominator %d must be a power of two', [ASpec.Meta.TimeSigDen]));
    if ASpec.Meta.TimeSigNum <= 0 then
      AddIssue(issues, vsError, 'project.timeSignature numerator must be positive');
    if ASpec.Meta.DurationBars <= 0 then
      AddIssue(issues, vsError, 'project.durationBars must be positive');

    { --- sections: required, distinct ids, inside song duration --- }
    if ASpec.Sections.Count = 0 then
      AddIssue(issues, vsWarning, 'song specification has no sections');

    for i := 0 to ASpec.Sections.Count - 1 do
    begin
      sec := ASpec.Sections[i];
      if Trim(sec.Id) = '' then
        AddIssue(issues, vsError, Format('section "%s" has no id', [sec.Name]));
      if sec.LengthBars <= 0 then
        AddIssue(issues, vsError, 'section length must be positive', sec.Id);
      if sec.StartBar < 1 then
        AddIssue(issues, vsError, 'section startBar must be >= 1', sec.Id);
      if (ASpec.Meta.DurationBars > 0) and (sec.EndBarExclusive - 1 > ASpec.Meta.DurationBars) then
        AddIssue(issues, vsError, Format(
          'section "%s" (bars %d..%d) extends past the song''s durationBars (%d)',
          [sec.Id, sec.StartBar, sec.EndBarExclusive - 1, ASpec.Meta.DurationBars]), sec.Id);
      if (sec.Energy < 0) or (sec.Energy > 1) then
        AddIssue(issues, vsWarning, 'section energy should be in [0.0, 1.0]', sec.Id);
      for j := i + 1 to ASpec.Sections.Count - 1 do
        if SameText(sec.Id, ASpec.Sections[j].Id) and (Trim(sec.Id) <> '') then
          AddIssue(issues, vsError, Format('duplicate section id "%s"', [sec.Id]), sec.Id);
    end;

    { --- tracks: required fields, role/tag presence, instrumental-vs-vocal consistency --- }
    hasVocalTrack := False;
    for i := 0 to ASpec.Tracks.Count - 1 do
    begin
      trk := ASpec.Tracks[i];
      if Trim(trk.Id) = '' then
        AddIssue(issues, vsError, Format('track "%s" has no id', [trk.Name]));
      if Trim(trk.Role) = '' then
        AddIssue(issues, vsWarning, 'track has no role assigned', '', trk.Id);
      if SameText(trk.Role, 'vocal') or SameText(trk.Role, 'lead-vocal') or
         SameText(trk.Role, 'vocals') then
        hasVocalTrack := True;
      for j := i + 1 to ASpec.Tracks.Count - 1 do
        if SameText(trk.Id, ASpec.Tracks[j].Id) and (Trim(trk.Id) <> '') then
          AddIssue(issues, vsError, Format('duplicate track id "%s"', [trk.Id]), '', trk.Id);
    end;

    if ASpec.Meta.Instrumental and hasVocalTrack then
      AddIssue(issues, vsError, 'project.instrumental is true but a vocal-role track is present (AIPlan.md section 7)');
    if (not ASpec.Meta.Instrumental) and (not hasVocalTrack) and (ASpec.Tracks.Count > 0) then
      AddIssue(issues, vsWarning, 'project.instrumental is false but no vocal-role track was found');

    { --- harmony: sectionId references exist, progression covers its section --- }
    for i := 0 to ASpec.Harmony.Count - 1 do
    begin
      chord := ASpec.Harmony[i];
      if Length(chord.Chords) = 0 then
        AddIssue(issues, vsWarning, 'chord progression has no chords', chord.SectionId);
      if chord.BarsPerChord <= 0 then
        AddIssue(issues, vsError, 'chord progression barsPerChord must be positive', chord.SectionId);
      sec := ASpec.SectionById(chord.SectionId);
      if sec = nil then
        AddIssue(issues, vsError, Format('chord progression references unknown section "%s"', [chord.SectionId]), chord.SectionId)
      else if (chord.BarsPerChord > 0) and (chord.TotalBars <> sec.LengthBars) then
        AddIssue(issues, vsWarning, Format(
          'chord progression for section "%s" covers %d bar(s) but the section is %d bar(s) long',
          [chord.SectionId, chord.TotalBars, sec.LengthBars]), chord.SectionId);
    end;

    { --- lyrics: only meaningful for a non-instrumental spec --- }
    if ALyrics <> nil then
    begin
      if ASpec.Meta.Instrumental and (ALyrics.Sections.Count > 0) then
        AddIssue(issues, vsError, 'project.instrumental is true but lyrics were supplied (AIPlan.md section 7)');
      for i := 0 to ALyrics.Sections.Count - 1 do
      begin
        lyricSec := ALyrics.Sections[i];
        sec := ASpec.SectionById(lyricSec.SectionId);
        if sec = nil then
        begin
          AddIssue(issues, vsError, Format('lyrics reference unknown section "%s"', [lyricSec.SectionId]), lyricSec.SectionId);
          Continue;
        end;
        for j := 0 to lyricSec.Lines.Count - 1 do
        begin
          line := lyricSec.Lines[j];
          if (line.StartBar < sec.StartBar) or (line.EndBarExclusive - 1 > sec.EndBarExclusive - 1) then
            AddIssue(issues, vsError, Format(
              'lyric line "%s" (bars %d..%d) falls outside section "%s" (bars %d..%d)',
              [line.Text, line.StartBar, line.EndBarExclusive - 1, sec.Id, sec.StartBar, sec.EndBarExclusive - 1]),
              lyricSec.SectionId);
        end;
      end;
    end;

    Result := issues.ToArray;
  finally
    issues.Free;
  end;
end;

class function TSongSpecValidator.HasErrors(const AIssues: TValidationIssues): Boolean;
var
  i: Integer;
begin
  Result := False;
  for i := 0 to High(AIssues) do
    if AIssues[i].Severity = vsError then Exit(True);
end;

end.
