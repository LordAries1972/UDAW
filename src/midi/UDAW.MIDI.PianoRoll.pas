unit UDAW.MIDI.PianoRoll;
{$I udaw.inc}

{ Phase 17 - MIDI: the piano roll model (plan section 25: "draw notes, resize,
  move, velocity, controller lanes, quantization, humanization, scale
  highlighting, chord highlighting").

  TPianoRoll is a thin, non-owning editor over one TMidiTrackSeq of a
  TMidiSequence.  It never draws anything - it is the model the design-time
  Piano Roll tab and the undo commands drive:

    * note edit : add / delete / move / resize / set-velocity, addressed by the
      note's stable Id so an edit is stable across a re-sort;
    * quantize  : grid + strength + swing, start (and optionally length);
    * humanize  : deterministic (seeded) timing + velocity jitter;
    * controller lanes : read / write a CC lane;
    * selection : rectangle select, select-all / none, per-note toggle;
    * musical helpers : scale membership + snap, and a small triad/7th chord
      namer for the "highlight" features.  These are pure functions so the UI
      and tests can call them directly. }

interface

uses
  SysUtils, Math,
  UDAW.Errors, UDAW.MIDI.Types, UDAW.MIDI.Sequence;

type
  TScaleKind = (
    skChromatic, skMajor, skNaturalMinor, skHarmonicMinor, skMelodicMinor,
    skDorian, skPhrygian, skLydian, skMixolydian, skLocrian,
    skMajorPentatonic, skMinorPentatonic, skBlues, skWholeTone);

  TPianoRoll = class
  private
    FSeq: TMidiSequence;
    FTrackIndex: Integer;
    function Trk: TMidiTrackSeq;
    function Rnd(var AState: Cardinal): Double;   // xorshift32 -> [0,1)
  public
    constructor Create(ASeq: TMidiSequence; ATrackIndex: Integer);
    procedure Bind(ASeq: TMidiSequence; ATrackIndex: Integer);

    { ---- note edits (return the note Id, or False/-1 on miss) ---- }
    function AddNote(AStartTick, ALengthTick: Int64; ANote, AVelocity: Integer;
      AChannel: Integer = 0): Integer;
    function DeleteNote(AId: Integer): Boolean;
    function MoveNote(AId: Integer; ADeltaTick: Int64; ADeltaNote: Integer): Boolean;
    function ResizeNote(AId: Integer; ADeltaLenTick: Int64; AFromStart: Boolean = False): Boolean;
    function SetVelocity(AId: Integer; AVelocity: Integer): Boolean;
    function GetNote(AId: Integer; out ANote: TMidiNote): Boolean;

    { ---- bulk ---- }
    procedure Quantize(const AIds: array of Integer; AGridTicks: Int64;
      AStrength: Double; ASwing: Double = 0.0; AAlsoLength: Boolean = False);
    procedure Humanize(const AIds: array of Integer; ATimingTicks: Int64;
      AVelocityAmount: Integer; ASeed: Cardinal = 1);
    procedure Legato(const AIds: array of Integer);
    procedure TransposeSelection(const AIds: array of Integer; ASemitones: Integer);

    { ---- controller lanes ---- }
    procedure SetController(AChannel, AController: Integer; ATick: Int64; AValue: Integer);
    function ControllerLane(AChannel, AController: Integer): TMidiCCArray;
    function ControllerValueAt(AChannel, AController: Integer; ATick: Int64): Integer;

    { ---- selection ---- }
    procedure SelectNone;
    procedure SelectAll;
    procedure SelectRect(ATick0, ATick1: Int64; ANote0, ANote1: Integer;
      AAdditive: Boolean = False);
    procedure ToggleSelect(AId: Integer);
    function SelectedIds: TArray<Integer>;

    property Sequence: TMidiSequence read FSeq;
    property TrackIndex: Integer read FTrackIndex;
  end;

{ ---- grid ---- }
function GridTicks(ASeq: TMidiSequence; ADivisionDenom: Integer): Int64; // 16 -> a 1/16 note
function QuantizeTick(ATick, AGridTicks: Int64; AStrength, ASwing: Double): Int64;

{ ---- musical helpers (pure) ---- }
function ScaleIntervals(AKind: TScaleKind): TArray<Integer>;
function ScaleKindName(AKind: TScaleKind): string;
function ScaleContains(ANote, ARootPitchClass: Integer; AKind: TScaleKind): Boolean;
function SnapNoteToScale(ANote, ARootPitchClass: Integer; AKind: TScaleKind): Integer;
{ name a set of sounding pitch classes as a chord, best effort ('' if unclear) }
function DetectChordName(const APitchClasses: array of Integer): string;

implementation

const
  PR_SUBSYS = 'MIDI.PianoRoll';

{ ============================ grid =============================== }

function GridTicks(ASeq: TMidiSequence; ADivisionDenom: Integer): Int64;
begin
  if (ASeq = nil) or (ADivisionDenom <= 0) then Exit(MIDI_DEFAULT_PPQ);
  { a quarter note is PPQ ticks; a 1/ADivisionDenom note is 4*PPQ/ADivisionDenom }
  Result := Max(Int64(1), (4 * Int64(ASeq.PPQ)) div ADivisionDenom);
end;

function QuantizeTick(ATick, AGridTicks: Int64; AStrength, ASwing: Double): Int64;
var
  slot, target, rem: Int64;
  isOffbeat: Boolean;
begin
  if AGridTicks <= 0 then Exit(ATick);
  if AStrength < 0 then AStrength := 0 else if AStrength > 1 then AStrength := 1;
  if ASwing < 0 then ASwing := 0 else if ASwing > 0.75 then ASwing := 0.75;

  slot := Round(ATick / AGridTicks);
  target := slot * AGridTicks;
  { swing: push every other grid slot later by up to 0.75 * grid }
  isOffbeat := Odd(slot);
  if isOffbeat and (ASwing > 0) then
    target := target + Round(ASwing * AGridTicks);

  rem := ATick - target;
  Result := ATick - Round(rem * AStrength);
  if Result < 0 then Result := 0;
end;

{ ============================ TPianoRoll ======================== }

constructor TPianoRoll.Create(ASeq: TMidiSequence; ATrackIndex: Integer);
begin
  inherited Create;
  Bind(ASeq, ATrackIndex);
end;

procedure TPianoRoll.Bind(ASeq: TMidiSequence; ATrackIndex: Integer);
begin
  FSeq := ASeq;
  FTrackIndex := ATrackIndex;
end;

function TPianoRoll.Trk: TMidiTrackSeq;
begin
  if FSeq = nil then
    RaiseUDAW(errInvalidState, PR_SUBSYS, 'piano roll not bound to a sequence');
  Result := FSeq.GetTrack(FTrackIndex);
  if Result = nil then
    RaiseUDAWFmt(errInvalidArgument, PR_SUBSYS, 'piano roll: no track %d', [FTrackIndex]);
end;

function TPianoRoll.Rnd(var AState: Cardinal): Double;
begin
  AState := AState xor (AState shl 13);
  AState := AState xor (AState shr 17);
  AState := AState xor (AState shl 5);
  if AState = 0 then AState := $1D872B41;
  Result := AState / 4294967296.0;
end;

function TPianoRoll.AddNote(AStartTick, ALengthTick: Int64; ANote, AVelocity: Integer;
  AChannel: Integer): Integer;
var
  n: TMidiNote;
begin
  if AStartTick < 0 then AStartTick := 0;
  if ALengthTick < 1 then ALengthTick := 1;
  if ANote < 0 then ANote := 0 else if ANote > 127 then ANote := 127;
  if AVelocity < 1 then AVelocity := 1 else if AVelocity > 127 then AVelocity := 127;
  FillChar(n, SizeOf(n), 0);
  n.Id := FSeq.NewNoteId;
  n.StartTick := AStartTick;
  n.LengthTick := ALengthTick;
  n.Channel := AChannel and $0F;
  n.Note := ANote;
  n.Velocity := AVelocity;
  n.OffVelocity := 64;
  Trk.AddNote(n);
  Trk.SortNotes;
  Result := n.Id;
end;

function TPianoRoll.DeleteNote(AId: Integer): Boolean;
var
  idx: Integer;
begin
  idx := Trk.IndexOfNoteId(AId);
  Result := idx >= 0;
  if Result then Trk.RemoveNoteAt(idx);
end;

function TPianoRoll.MoveNote(AId: Integer; ADeltaTick: Int64; ADeltaNote: Integer): Boolean;
var
  idx: Integer;
  t: TMidiTrackSeq;
  n: TMidiNote;
begin
  t := Trk;
  idx := t.IndexOfNoteId(AId);
  Result := idx >= 0;
  if not Result then Exit;
  n := t.Notes[idx];
  n.StartTick := n.StartTick + ADeltaTick;
  if n.StartTick < 0 then n.StartTick := 0;
  n.Note := n.Note + ADeltaNote;
  if n.Note < 0 then n.Note := 0 else if n.Note > 127 then n.Note := 127;
  t.UpdateNote(idx, n);
  t.SortNotes;
end;

function TPianoRoll.ResizeNote(AId: Integer; ADeltaLenTick: Int64; AFromStart: Boolean): Boolean;
var
  idx: Integer;
  t: TMidiTrackSeq;
  n: TMidiNote;
begin
  t := Trk;
  idx := t.IndexOfNoteId(AId);
  Result := idx >= 0;
  if not Result then Exit;
  n := t.Notes[idx];
  if AFromStart then
  begin
    n.StartTick := n.StartTick - ADeltaLenTick;
    n.LengthTick := n.LengthTick + ADeltaLenTick;
    if n.StartTick < 0 then
    begin
      n.LengthTick := n.LengthTick + n.StartTick;   // keep the end fixed
      n.StartTick := 0;
    end;
    if n.LengthTick < 1 then n.LengthTick := 1;
    t.UpdateNote(idx, n);
    t.SortNotes;
  end
  else
  begin
    n.LengthTick := n.LengthTick + ADeltaLenTick;
    if n.LengthTick < 1 then n.LengthTick := 1;
    t.UpdateNote(idx, n);
  end;
end;

function TPianoRoll.SetVelocity(AId: Integer; AVelocity: Integer): Boolean;
var
  idx: Integer;
  t: TMidiTrackSeq;
  n: TMidiNote;
begin
  if AVelocity < 1 then AVelocity := 1 else if AVelocity > 127 then AVelocity := 127;
  t := Trk;
  idx := t.IndexOfNoteId(AId);
  Result := idx >= 0;
  if Result then
  begin
    n := t.Notes[idx];
    n.Velocity := AVelocity;
    t.UpdateNote(idx, n);
  end;
end;

function TPianoRoll.GetNote(AId: Integer; out ANote: TMidiNote): Boolean;
var
  idx: Integer;
begin
  FillChar(ANote, SizeOf(ANote), 0);
  idx := Trk.IndexOfNoteId(AId);
  Result := idx >= 0;
  if Result then ANote := Trk.Notes[idx];
end;

procedure TPianoRoll.Quantize(const AIds: array of Integer; AGridTicks: Int64;
  AStrength, ASwing: Double; AAlsoLength: Boolean);
var
  k, idx: Integer;
  t: TMidiTrackSeq;
  n: TMidiNote;
  oldStart, newStart, newEnd: Int64;
begin
  t := Trk;
  for k := 0 to High(AIds) do
  begin
    idx := t.IndexOfNoteId(AIds[k]);
    if idx < 0 then Continue;
    n := t.Notes[idx];
    oldStart := n.StartTick;
    newStart := QuantizeTick(oldStart, AGridTicks, AStrength, ASwing);
    n.StartTick := newStart;
    if AAlsoLength then
    begin
      newEnd := QuantizeTick(oldStart + n.LengthTick, AGridTicks, AStrength, 0.0);
      if newEnd <= newStart then newEnd := newStart + AGridTicks;
      n.LengthTick := newEnd - newStart;
    end;
    t.UpdateNote(idx, n);
  end;
  t.SortNotes;
end;

procedure TPianoRoll.Humanize(const AIds: array of Integer; ATimingTicks: Int64;
  AVelocityAmount: Integer; ASeed: Cardinal);
var
  k, idx, v: Integer;
  t: TMidiTrackSeq;
  n: TMidiNote;
  st: Cardinal;
  jitter: Int64;
begin
  t := Trk;
  st := ASeed;
  if st = 0 then st := 1;
  for k := 0 to High(AIds) do
  begin
    idx := t.IndexOfNoteId(AIds[k]);
    if idx < 0 then Continue;
    n := t.Notes[idx];
    if ATimingTicks > 0 then
    begin
      jitter := Round((Rnd(st) * 2.0 - 1.0) * ATimingTicks);
      n.StartTick := Max(Int64(0), n.StartTick + jitter);
    end;
    if AVelocityAmount > 0 then
    begin
      v := n.Velocity + Round((Rnd(st) * 2.0 - 1.0) * AVelocityAmount);
      if v < 1 then v := 1 else if v > 127 then v := 127;
      n.Velocity := v;
    end;
    t.UpdateNote(idx, n);
  end;
  t.SortNotes;
end;

procedure TPianoRoll.Legato(const AIds: array of Integer);
var
  k, idx, nextIdx, bestIdx: Integer;
  t: TMidiTrackSeq;
  cur: TMidiNote;
  bestStart: Int64;
begin
  t := Trk;
  t.SortNotes;
  for k := 0 to High(AIds) do
  begin
    idx := t.IndexOfNoteId(AIds[k]);
    if idx < 0 then Continue;
    cur := t.Notes[idx];
    { find the nearest later note on the same channel }
    bestIdx := -1;
    bestStart := High(Int64);
    for nextIdx := 0 to t.NoteCount - 1 do
      if (nextIdx <> idx) and (t.Notes[nextIdx].Channel = cur.Channel) and
         (t.Notes[nextIdx].StartTick > cur.StartTick) and
         (t.Notes[nextIdx].StartTick < bestStart) then
      begin
        bestStart := t.Notes[nextIdx].StartTick;
        bestIdx := nextIdx;
      end;
    if bestIdx >= 0 then
    begin
      cur.LengthTick := Max(Int64(1), bestStart - cur.StartTick);
      t.UpdateNote(idx, cur);
    end;
  end;
end;

procedure TPianoRoll.TransposeSelection(const AIds: array of Integer; ASemitones: Integer);
var
  k, idx, nn: Integer;
  t: TMidiTrackSeq;
  n: TMidiNote;
begin
  t := Trk;
  for k := 0 to High(AIds) do
  begin
    idx := t.IndexOfNoteId(AIds[k]);
    if idx < 0 then Continue;
    n := t.Notes[idx];
    nn := n.Note + ASemitones;
    if nn < 0 then nn := 0 else if nn > 127 then nn := 127;
    n.Note := nn;
    t.UpdateNote(idx, n);
  end;
  t.SortNotes;
end;

procedure TPianoRoll.SetController(AChannel, AController: Integer; ATick: Int64;
  AValue: Integer);
var
  t: TMidiTrackSeq;
  i: Integer;
  cc: TMidiCC;
begin
  t := Trk;
  if AValue < 0 then AValue := 0 else if AValue > 127 then AValue := 127;
  { replace a point at the exact same tick+cc+channel }
  for i := 0 to t.CCCount - 1 do
    if (t.Controllers[i].Tick = ATick) and (t.Controllers[i].Channel = (AChannel and $0F)) and
       (t.Controllers[i].Controller = AController) then
    begin
      cc := t.Controllers[i];
      cc.Value := AValue;
      t.UpdateCC(i, cc);
      Exit;
    end;
  cc.Tick := ATick;
  cc.Channel := AChannel and $0F;
  cc.Controller := AController;
  cc.Value := AValue;
  t.AddCC(cc);
  t.SortCC;
end;

function TPianoRoll.ControllerLane(AChannel, AController: Integer): TMidiCCArray;
var
  t: TMidiTrackSeq;
  i, n: Integer;
begin
  t := Trk;
  SetLength(Result, 0);
  n := 0;
  for i := 0 to t.CCCount - 1 do
    if (t.Controllers[i].Channel = (AChannel and $0F)) and
       (t.Controllers[i].Controller = AController) then
    begin
      SetLength(Result, n + 1);
      Result[n] := t.Controllers[i];
      Inc(n);
    end;
end;

function TPianoRoll.ControllerValueAt(AChannel, AController: Integer; ATick: Int64): Integer;
var
  lane: TMidiCCArray;
  i: Integer;
begin
  Result := -1;
  lane := ControllerLane(AChannel, AController);
  for i := 0 to High(lane) do
    if lane[i].Tick <= ATick then Result := lane[i].Value
    else Break;
end;

procedure TPianoRoll.SelectNone;
var
  t: TMidiTrackSeq;
  i: Integer;
begin
  t := Trk;
  for i := 0 to t.NoteCount - 1 do t.SetNoteSelected(i, False);
end;

procedure TPianoRoll.SelectAll;
var
  t: TMidiTrackSeq;
  i: Integer;
begin
  t := Trk;
  for i := 0 to t.NoteCount - 1 do t.SetNoteSelected(i, True);
end;

procedure TPianoRoll.SelectRect(ATick0, ATick1: Int64; ANote0, ANote1: Integer;
  AAdditive: Boolean);
var
  t: TMidiTrackSeq;
  i: Integer;
  lo, hi: Int64;
  nlo, nhi: Integer;
begin
  t := Trk;
  lo := Min(ATick0, ATick1); hi := Max(ATick0, ATick1);
  nlo := Min(ANote0, ANote1); nhi := Max(ANote0, ANote1);
  if not AAdditive then SelectNone;
  for i := 0 to t.NoteCount - 1 do
    if (t.Notes[i].Note >= nlo) and (t.Notes[i].Note <= nhi) and
       (t.Notes[i].StartTick < hi) and (t.Notes[i].EndTick > lo) then
      t.SetNoteSelected(i, True);
end;

procedure TPianoRoll.ToggleSelect(AId: Integer);
var
  idx: Integer;
begin
  idx := Trk.IndexOfNoteId(AId);
  if idx >= 0 then
    Trk.SetNoteSelected(idx, not Trk.Notes[idx].Selected);
end;

function TPianoRoll.SelectedIds: TArray<Integer>;
var
  t: TMidiTrackSeq;
  i, n: Integer;
begin
  t := Trk;
  SetLength(Result, 0);
  n := 0;
  for i := 0 to t.NoteCount - 1 do
    if t.Notes[i].Selected then
    begin
      SetLength(Result, n + 1);
      Result[n] := t.Notes[i].Id;
      Inc(n);
    end;
end;

{ ============================ musical helpers ================== }

function ScaleKindName(AKind: TScaleKind): string;
begin
  case AKind of
    skChromatic:       Result := 'Chromatic';
    skMajor:           Result := 'Major (Ionian)';
    skNaturalMinor:    Result := 'Natural Minor (Aeolian)';
    skHarmonicMinor:   Result := 'Harmonic Minor';
    skMelodicMinor:    Result := 'Melodic Minor';
    skDorian:          Result := 'Dorian';
    skPhrygian:        Result := 'Phrygian';
    skLydian:          Result := 'Lydian';
    skMixolydian:      Result := 'Mixolydian';
    skLocrian:         Result := 'Locrian';
    skMajorPentatonic: Result := 'Major Pentatonic';
    skMinorPentatonic: Result := 'Minor Pentatonic';
    skBlues:           Result := 'Blues';
    skWholeTone:       Result := 'Whole Tone';
  else
    Result := '?';
  end;
end;

function ScaleIntervals(AKind: TScaleKind): TArray<Integer>;
begin
  case AKind of
    skChromatic:       Result := [0,1,2,3,4,5,6,7,8,9,10,11];
    skMajor:           Result := [0,2,4,5,7,9,11];
    skNaturalMinor:    Result := [0,2,3,5,7,8,10];
    skHarmonicMinor:   Result := [0,2,3,5,7,8,11];
    skMelodicMinor:    Result := [0,2,3,5,7,9,11];
    skDorian:          Result := [0,2,3,5,7,9,10];
    skPhrygian:        Result := [0,1,3,5,7,8,10];
    skLydian:          Result := [0,2,4,6,7,9,11];
    skMixolydian:      Result := [0,2,4,5,7,9,10];
    skLocrian:         Result := [0,1,3,5,6,8,10];
    skMajorPentatonic: Result := [0,2,4,7,9];
    skMinorPentatonic: Result := [0,3,5,7,10];
    skBlues:           Result := [0,3,5,6,7,10];
    skWholeTone:       Result := [0,2,4,6,8,10];
  else
    Result := [0,1,2,3,4,5,6,7,8,9,10,11];
  end;
end;

function ScaleContains(ANote, ARootPitchClass: Integer; AKind: TScaleKind): Boolean;
var
  ints: TArray<Integer>;
  pc, i: Integer;
begin
  ints := ScaleIntervals(AKind);
  pc := (((ANote - ARootPitchClass) mod 12) + 12) mod 12;
  Result := False;
  for i := 0 to High(ints) do
    if ints[i] = pc then Exit(True);
end;

function SnapNoteToScale(ANote, ARootPitchClass: Integer; AKind: TScaleKind): Integer;
var
  d: Integer;
begin
  if ScaleContains(ANote, ARootPitchClass, AKind) then Exit(ANote);
  for d := 1 to 6 do
  begin
    if (ANote - d >= 0) and ScaleContains(ANote - d, ARootPitchClass, AKind) then
      Exit(ANote - d);
    if (ANote + d <= 127) and ScaleContains(ANote + d, ARootPitchClass, AKind) then
      Exit(ANote + d);
  end;
  Result := ANote;
end;

function DetectChordName(const APitchClasses: array of Integer): string;
const
  NOTE_NAMES: array[0..11] of string = ('C','C#','D','D#','E','F','F#','G','G#','A','A#','B');
var
  present: array[0..11] of Boolean;
  i, root, k: Integer;
  best: string;

  function Has(APc: Integer): Boolean;
  begin
    Result := present[((APc mod 12) + 12) mod 12];
  end;

  function IntervalsFrom(ARoot: Integer): string;
  var
    hasMin3, hasMaj3, hasP5, hasDim5, hasAug5, hasMin7, hasMaj7, hasMaj6: Boolean;
  begin
    Result := '';
    hasMin3 := Has(ARoot + 3);  hasMaj3 := Has(ARoot + 4);
    hasDim5 := Has(ARoot + 6);  hasP5 := Has(ARoot + 7);  hasAug5 := Has(ARoot + 8);
    hasMaj6 := Has(ARoot + 9);
    hasMin7 := Has(ARoot + 10); hasMaj7 := Has(ARoot + 11);
    if hasMaj3 and hasP5 then
    begin
      if hasMaj7 then Result := 'maj7'
      else if hasMin7 then Result := '7'
      else if hasMaj6 then Result := '6'
      else Result := '';
      Exit;
    end;
    if hasMin3 and hasP5 then
    begin
      if hasMin7 then Result := 'm7'
      else if hasMaj7 then Result := 'm(maj7)'
      else Result := 'm';
      Exit;
    end;
    if hasMin3 and hasDim5 then
    begin
      if hasMin7 then Result := 'm7b5' else Result := 'dim';
      Exit;
    end;
    if hasMaj3 and hasAug5 then begin Result := 'aug'; Exit; end;
    Result := '?';
  end;

begin
  Result := '';
  FillChar(present, SizeOf(present), 0);
  for i := 0 to High(APitchClasses) do
    present[((APitchClasses[i] mod 12) + 12) mod 12] := True;

  k := 0;
  for i := 0 to 11 do if present[i] then Inc(k);
  if k < 3 then Exit;

  for root := 0 to 11 do
    if present[root] then
    begin
      best := IntervalsFrom(root);
      if (best <> '?') then
        Exit(NOTE_NAMES[root] + best);
    end;
end;

end.
