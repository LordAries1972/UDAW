unit UDAW.Composer.Lyrics;
{$I udaw.inc}

{ AI Composition, Phase 1 - Internal Data Model (docs/AIPlan.md section 17
  Phase 1, and section F "LyricEngine" / section 7 "Lyrics and Vocal
  Timeline"). Nothing in the codebase covers lyrics before this unit.

  TLyricDocument stores lyrics in a structured, always-editable form
  (section F: "The LyricEngine should not assume that generated lyrics are
  final. Every line must remain editable.") divided into sections, lines
  and an estimated syllable count per line (section 7 step 3: "Analyze line
  length and syllable count"). It intentionally does NOT store timeline
  placement in seconds or generate MIDI - a later phase's guide-vocal
  generator converts StartBar/DurationBars into real timeline content via
  the project's Grid context (UDAW.Timeline.Time), the same way every other
  bar-based structure in this project (TSongSection) does. }

interface

uses
  SysUtils, Generics.Collections;

type
  { AIPlan.md section 5: lyrics.sections[].lines[] }
  TLyricLine = class
  private
    FText: string;
    FStartBar: Integer;
    FDurationBars: Integer;
    function EstimateSyllables: Integer;
  public
    constructor Create(const AText: string = ''; AStartBar: Integer = 1;
      ADurationBars: Integer = 1);
    function Clone: TLyricLine;
    { Simple vowel-group heuristic (count of vowel runs, min 1 per word) -
      no external NLP/dictionary library, matching the project's no-
      third-party-lib policy. Good enough to flag "too many syllables for
      this many bars", not meant to be phonetically precise. }
    property Text: string read FText write FText;
    property StartBar: Integer read FStartBar write FStartBar;
    property DurationBars: Integer read FDurationBars write FDurationBars;
    property SyllableCount: Integer read EstimateSyllables;
    function EndBarExclusive: Integer;
    { AIPlan.md section 7 step 3 "Analyze line length and syllable count" /
      step 5 "Generate phrase start and end positions" - phrase (word) level
      breakdown of the same heuristic EstimateSyllables already uses. }
    function Words: TArray<string>;
    function SyllablesPerWord: TArray<Integer>;
    { Distributes DurationBars across every syllable in the line,
      proportionally by word (AIPlan.md section 7 step 4 "Assign each line
      to measures" / the vocal-guide generator's per-syllable placement).
      Both output arrays have SyllableCount entries (at least 1, even for an
      empty line, so a placeholder/instrumental-pause line still times). }
    procedure ComputeSyllableTimings(out AStartBars, ADurationBars: TArray<Double>);
  end;

  { A flattened, timeline-ready view of one lyric line (AIPlan.md section 7
    step 6 "Create lyric regions on the timeline"). Lyrics carry no timeline
    dependency of their own - StartBar/DurationBars are already absolute
    song bars, the same convention TSongSection uses, so a region converts
    to seconds via the project's own UDAW.Timeline.Time.BarsToSeconds
    exactly like a section marker does; this unit only provides the flat,
    sorted list. }
  TLyricRegion = record
    SectionId: string;
    Text: string;
    StartBar: Integer;
    DurationBars: Integer;
    SyllableCount: Integer;
  end;

  TLyricSection = class
  private
    FSectionId: string;
    FLines: TObjectList<TLyricLine>;
  public
    constructor Create(const ASectionId: string = '');
    destructor Destroy; override;
    function Clone: TLyricSection;
    function AddLine(ALine: TLyricLine): TLyricLine; // takes ownership
    property SectionId: string read FSectionId write FSectionId;
    property Lines: TObjectList<TLyricLine> read FLines;
  end;

  { AIPlan.md section 5: lyrics.language + lyrics.sections[]. A section with
    no TLyricSection entry is implicitly instrumental (section 7: "When
    Instrumental is enabled: Do not request lyrics... Replace vocal
    sections with melodic or instrumental development"). }
  TLyricDocument = class
  private
    FLanguage: string;
    FSections: TObjectList<TLyricSection>;
  public
    constructor Create;
    destructor Destroy; override;
    function Clone: TLyricDocument;
    procedure Clear;
    function AddSection(ASection: TLyricSection): TLyricSection; // takes ownership
    function SectionById(const ASectionId: string): TLyricSection;
    function IsInstrumentalSection(const ASectionId: string): Boolean;
    { Every line across every section, flattened and sorted by StartBar -
      the data a Lyrics/Timeline UI needs to paint lyric regions (AIPlan.md
      section 7 step 6). }
    function AllRegions: TArray<TLyricRegion>;
    property Language: string read FLanguage write FLanguage;
    property Sections: TObjectList<TLyricSection> read FSections;
  end;

implementation

{ TLyricLine }

constructor TLyricLine.Create(const AText: string; AStartBar, ADurationBars: Integer);
begin
  inherited Create;
  FText := AText;
  FStartBar := AStartBar;
  FDurationBars := ADurationBars;
end;

function TLyricLine.Clone: TLyricLine;
begin
  Result := TLyricLine.Create(FText, FStartBar, FDurationBars);
end;

function TLyricLine.EndBarExclusive: Integer;
begin
  Result := FStartBar + FDurationBars;
end;

function TLyricLine.EstimateSyllables: Integer;
var
  i: Integer;
  ch: Char;
  inVowelRun: Boolean;
  word: Integer;
  wordHasVowel: Boolean;
  total: Integer;

  function IsVowel(C: Char): Boolean;
  begin
    Result := CharInSet(C, ['a', 'e', 'i', 'o', 'u', 'y',
      'A', 'E', 'I', 'O', 'U', 'Y']);
  end;

begin
  total := 0;
  inVowelRun := False;
  wordHasVowel := False;
  word := 0;
  for i := 1 to Length(FText) do
  begin
    ch := FText[i];
    if CharInSet(ch, [' ', #9, ',', '.', '!', '?', ';', ':', '-']) then
    begin
      if (word > 0) and not wordHasVowel then Inc(total); // word with no vowel still counts once
      inVowelRun := False;
      wordHasVowel := False;
      word := 0;
      Continue;
    end;
    Inc(word);
    if IsVowel(ch) then
    begin
      if not inVowelRun then
      begin
        Inc(total);
        wordHasVowel := True;
      end;
      inVowelRun := True;
    end
    else
      inVowelRun := False;
  end;
  if (word > 0) and not wordHasVowel then Inc(total);
  Result := total;
end;

function TLyricLine.Words: TArray<string>;
begin
  Result := FText.Split([' ', #9, ',', '.', '!', '?', ';', ':', '-'],
    TStringSplitOptions.ExcludeEmpty);
end;

function TLyricLine.SyllablesPerWord: TArray<Integer>;
var
  words: TArray<string>;
  i: Integer;

  function CountWordSyllables(const AWord: string): Integer;
  var
    j: Integer;
    ch: Char;
    inRun, hasVowel: Boolean;
  begin
    Result := 0;
    inRun := False;
    hasVowel := False;
    for j := 1 to Length(AWord) do
    begin
      ch := AWord[j];
      if CharInSet(ch, ['a', 'e', 'i', 'o', 'u', 'y', 'A', 'E', 'I', 'O', 'U', 'Y']) then
      begin
        if not inRun then
        begin
          Inc(Result);
          hasVowel := True;
        end;
        inRun := True;
      end
      else
        inRun := False;
    end;
    if not hasVowel then Result := 1; // a word with no vowel still counts once
  end;

begin
  words := Words;
  SetLength(Result, Length(words));
  for i := 0 to High(words) do
    Result[i] := CountWordSyllables(words[i]);
end;

procedure TLyricLine.ComputeSyllableTimings(out AStartBars, ADurationBars: TArray<Double>);
var
  counts: TArray<Integer>;
  total, i, k, idx: Integer;
  perSyllableBars, cursor: Double;
begin
  counts := SyllablesPerWord;
  if Length(counts) = 0 then counts := [1]; // empty/instrumental-pause line: one placeholder slot
  total := 0;
  for i := 0 to High(counts) do Inc(total, counts[i]);
  if total <= 0 then total := 1;

  SetLength(AStartBars, total);
  SetLength(ADurationBars, total);
  perSyllableBars := FDurationBars / total;
  cursor := FStartBar;
  idx := 0;
  for i := 0 to High(counts) do
    for k := 0 to counts[i] - 1 do
    begin
      AStartBars[idx] := cursor;
      ADurationBars[idx] := perSyllableBars;
      cursor := cursor + perSyllableBars;
      Inc(idx);
    end;
end;

{ TLyricSection }

constructor TLyricSection.Create(const ASectionId: string);
begin
  inherited Create;
  FSectionId := ASectionId;
  FLines := TObjectList<TLyricLine>.Create(True);
end;

destructor TLyricSection.Destroy;
begin
  FLines.Free;
  inherited Destroy;
end;

function TLyricSection.Clone: TLyricSection;
var
  i: Integer;
begin
  Result := TLyricSection.Create(FSectionId);
  for i := 0 to FLines.Count - 1 do
    Result.FLines.Add(FLines[i].Clone);
end;

function TLyricSection.AddLine(ALine: TLyricLine): TLyricLine;
begin
  FLines.Add(ALine);
  Result := ALine;
end;

{ TLyricDocument }

constructor TLyricDocument.Create;
begin
  inherited Create;
  FLanguage := 'English';
  FSections := TObjectList<TLyricSection>.Create(True);
end;

destructor TLyricDocument.Destroy;
begin
  FSections.Free;
  inherited Destroy;
end;

function TLyricDocument.Clone: TLyricDocument;
var
  i: Integer;
begin
  Result := TLyricDocument.Create;
  Result.FLanguage := FLanguage;
  for i := 0 to FSections.Count - 1 do
    Result.FSections.Add(FSections[i].Clone);
end;

procedure TLyricDocument.Clear;
begin
  FSections.Clear;
end;

function TLyricDocument.AddSection(ASection: TLyricSection): TLyricSection;
begin
  FSections.Add(ASection);
  Result := ASection;
end;

function TLyricDocument.SectionById(const ASectionId: string): TLyricSection;
var
  i: Integer;
begin
  Result := nil;
  for i := 0 to FSections.Count - 1 do
    if SameText(FSections[i].SectionId, ASectionId) then Exit(FSections[i]);
end;

function TLyricDocument.IsInstrumentalSection(const ASectionId: string): Boolean;
begin
  Result := SectionById(ASectionId) = nil;
end;

function TLyricDocument.AllRegions: TArray<TLyricRegion>;
var
  i, j, n: Integer;
  lsec: TLyricSection;
  line: TLyricLine;
  tmp: TLyricRegion;
begin
  SetLength(Result, 0);
  n := 0;
  for i := 0 to FSections.Count - 1 do
  begin
    lsec := FSections[i];
    for j := 0 to lsec.Lines.Count - 1 do
    begin
      line := lsec.Lines[j];
      SetLength(Result, n + 1);
      Result[n].SectionId := lsec.SectionId;
      Result[n].Text := line.Text;
      Result[n].StartBar := line.StartBar;
      Result[n].DurationBars := line.DurationBars;
      Result[n].SyllableCount := line.SyllableCount;
      Inc(n);
    end;
  end;
  { insertion sort by StartBar - region counts per song are small }
  for i := 1 to High(Result) do
  begin
    j := i;
    while (j > 0) and (Result[j - 1].StartBar > Result[j].StartBar) do
    begin
      tmp := Result[j - 1];
      Result[j - 1] := Result[j];
      Result[j] := tmp;
      Dec(j);
    end;
  end;
end;

end.
