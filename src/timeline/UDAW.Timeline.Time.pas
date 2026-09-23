unit UDAW.Timeline.Time;
{$I udaw.inc}

{ Phase 7 - Timeline: the time domain.

  Everything on the timeline is stored in SECONDS (a double). This unit is the
  single place that converts between the three views of a timeline position the
  rest of the DAW needs:

    * seconds      - the canonical storage / DSP unit
    * samples      - integer frame index at a given sample rate
    * bars/beats   - musical position, given tempo + time signature

  and the grid/snap logic the editor uses to quantise edits. There is no state
  here beyond a small immutable TGridContext value record, so it is trivially
  testable and shared by the model, the serializer and the view.

  A single constant tempo / time signature is assumed (the project has exactly
  one of each until the tempo-map phase). The API is shaped so a future
  TTempoMap can replace the free functions without touching call sites. }

interface

uses
  SysUtils, Math,
  UDAW.Errors;

const
  TIMELINE_SUBSYS = 'Timeline';

  { Pulses-per-quarter-note used when a musical position is expressed as
    bar.beat.tick (matches the common MIDI/DAW default). }
  TIMELINE_PPQ = 960;

type
  { What the grid snaps to. The Div* values are fractions of a *beat*
    (a quarter note in 4/4), so smDiv4 is a sixteenth note in 4/4. }
  TSnapMode = (
    smOff,
    smBar,
    smBeat,
    smDiv2,     // 1/2 beat
    smDiv3,     // triplet
    smDiv4,     // 1/4 beat
    smDiv6,
    smDiv8,
    smDiv16,
    smSecond,   // whole seconds
    smSample    // sample-accurate (no sub-sample positions)
  );

  { Immutable musical/sample context for every conversion below. }
  TGridContext = record
    Tempo: Double;        // BPM, quarter notes per minute
    TSigNum: Integer;     // beats per bar
    TSigDen: Integer;     // note value that gets one beat (1,2,4,8,16,32,64)
    SampleRate: Integer;  // Hz
    class function Make(ATempo: Double; ATSigNum, ATSigDen, ASampleRate: Integer): TGridContext; static;
    function SecondsPerBeat: Double;
    function SecondsPerBar: Double;
    function BeatsPerBar: Double;
    function IsValid: Boolean;
  end;

function SnapModeId(AMode: TSnapMode): string;
function SnapModeFromId(const AId: string; out AMode: TSnapMode): Boolean;
function SnapModeDisplay(AMode: TSnapMode): string;

{ ---- seconds <-> samples ---- }
function SecondsToSamples(ASeconds: Double; ASampleRate: Integer): Int64;
function SamplesToSeconds(ASamples: Int64; ASampleRate: Integer): Double;

{ ---- seconds <-> beats / bars ---- }
function SecondsToBeats(const ACtx: TGridContext; ASeconds: Double): Double;
function BeatsToSeconds(const ACtx: TGridContext; ABeats: Double): Double;
function SecondsToBars(const ACtx: TGridContext; ASeconds: Double): Double;
function BarsToSeconds(const ACtx: TGridContext; ABars: Double): Double;

{ Spacing, in seconds, between two adjacent lines of the given grid. Returns 0
  for smOff (no grid). For smSample the spacing is one sample. }
function GridSpacingSeconds(const ACtx: TGridContext; AMode: TSnapMode): Double;

{ Nearest grid line at or around ASeconds (round to nearest). }
function SnapSeconds(const ACtx: TGridContext; ASeconds: Double; AMode: TSnapMode): Double;
{ Directional snap: ADir < 0 rounds down (floor), ADir > 0 rounds up (ceil),
  ADir = 0 rounds to nearest. Never returns a negative time. }
function SnapSecondsDir(const ACtx: TGridContext; ASeconds: Double; AMode: TSnapMode;
  ADir: Integer): Double;

{ The k-th grid line (k may be negative only in theory; times are clamped >= 0). }
function GridLineSeconds(const ACtx: TGridContext; AMode: TSnapMode; AIndex: Integer): Double;

{ ---- formatting ---- }
{ "bar.beat.tick", 1-based bar and beat, tick 0..PPQ-1 scaled to the beat. }
function FormatBarsBeats(const ACtx: TGridContext; ASeconds: Double): string;
{ "h:mm:ss.mmm" (hours omitted when zero -> "mm:ss.mmm"). }
function FormatTimecode(ASeconds: Double): string;

implementation

const
  SNAP_IDS: array[TSnapMode] of string = (
    'off', 'bar', 'beat', '1/2', '1/3', '1/4', '1/6', '1/8', '1/16',
    'sec', 'sample');
  { Display labels only - SNAP_IDS above is the persisted/serialized token
    and must not change. smSample reads as "Realtime" here: it snaps to the
    nearest single audio sample, the finest grid the timeline has, so
    editing effectively tracks the exact position in real time. }
  SNAP_DISPLAY: array[TSnapMode] of string = (
    'Off', 'Bar', 'Beat', '1/2 beat', 'Triplet', '1/4 beat', '1/6 beat',
    '1/8 beat', '1/16 beat', 'Seconds', 'Realtime');

function SnapModeId(AMode: TSnapMode): string;
begin
  Result := SNAP_IDS[AMode];
end;

function SnapModeFromId(const AId: string; out AMode: TSnapMode): Boolean;
var
  m: TSnapMode;
begin
  for m := Low(TSnapMode) to High(TSnapMode) do
    if SameText(AId, SNAP_IDS[m]) then
    begin
      AMode := m;
      Exit(True);
    end;
  Result := False;
end;

function SnapModeDisplay(AMode: TSnapMode): string;
begin
  Result := SNAP_DISPLAY[AMode];
end;

{ ================= TGridContext ================= }

class function TGridContext.Make(ATempo: Double; ATSigNum, ATSigDen, ASampleRate: Integer): TGridContext;
begin
  Result.Tempo := ATempo;
  Result.TSigNum := ATSigNum;
  Result.TSigDen := ATSigDen;
  Result.SampleRate := ASampleRate;
end;

function TGridContext.SecondsPerBeat: Double;
begin
  { A "beat" here is the notated beat of the time signature: in 6/8 a beat is an
    eighth note, so it is (4/den) quarter notes long. }
  if Tempo <= 0 then
    RaiseUDAW(errInvalidArgument, TIMELINE_SUBSYS, 'tempo must be > 0');
  if TSigDen <= 0 then
    RaiseUDAW(errInvalidArgument, TIMELINE_SUBSYS, 'time-signature denominator must be > 0');
  Result := (60.0 / Tempo) * (4.0 / TSigDen);
end;

function TGridContext.BeatsPerBar: Double;
begin
  if TSigNum <= 0 then
    RaiseUDAW(errInvalidArgument, TIMELINE_SUBSYS, 'time-signature numerator must be > 0');
  Result := TSigNum;
end;

function TGridContext.SecondsPerBar: Double;
begin
  Result := SecondsPerBeat * BeatsPerBar;
end;

function TGridContext.IsValid: Boolean;
begin
  Result := (Tempo > 0) and (TSigNum > 0) and (TSigDen > 0) and (SampleRate > 0);
end;

{ ================= seconds <-> samples ================= }

function SecondsToSamples(ASeconds: Double; ASampleRate: Integer): Int64;
begin
  if ASampleRate <= 0 then
    RaiseUDAW(errInvalidArgument, TIMELINE_SUBSYS, 'sample rate must be > 0');
  Result := Round(ASeconds * ASampleRate);
end;

function SamplesToSeconds(ASamples: Int64; ASampleRate: Integer): Double;
begin
  if ASampleRate <= 0 then
    RaiseUDAW(errInvalidArgument, TIMELINE_SUBSYS, 'sample rate must be > 0');
  Result := ASamples / ASampleRate;
end;

{ ================= seconds <-> beats / bars ================= }

function SecondsToBeats(const ACtx: TGridContext; ASeconds: Double): Double;
begin
  Result := ASeconds / ACtx.SecondsPerBeat;
end;

function BeatsToSeconds(const ACtx: TGridContext; ABeats: Double): Double;
begin
  Result := ABeats * ACtx.SecondsPerBeat;
end;

function SecondsToBars(const ACtx: TGridContext; ASeconds: Double): Double;
begin
  Result := ASeconds / ACtx.SecondsPerBar;
end;

function BarsToSeconds(const ACtx: TGridContext; ABars: Double): Double;
begin
  Result := ABars * ACtx.SecondsPerBar;
end;

{ ================= grid ================= }

function GridSpacingSeconds(const ACtx: TGridContext; AMode: TSnapMode): Double;
begin
  case AMode of
    smOff:    Result := 0.0;
    smBar:    Result := ACtx.SecondsPerBar;
    smBeat:   Result := ACtx.SecondsPerBeat;
    smDiv2:   Result := ACtx.SecondsPerBeat / 2.0;
    smDiv3:   Result := ACtx.SecondsPerBeat / 3.0;
    smDiv4:   Result := ACtx.SecondsPerBeat / 4.0;
    smDiv6:   Result := ACtx.SecondsPerBeat / 6.0;
    smDiv8:   Result := ACtx.SecondsPerBeat / 8.0;
    smDiv16:  Result := ACtx.SecondsPerBeat / 16.0;
    smSecond: Result := 1.0;
    smSample:
      begin
        if ACtx.SampleRate <= 0 then
          RaiseUDAW(errInvalidArgument, TIMELINE_SUBSYS, 'sample rate must be > 0');
        Result := 1.0 / ACtx.SampleRate;
      end;
  else
    Result := 0.0;
  end;
end;

function SnapSecondsDir(const ACtx: TGridContext; ASeconds: Double; AMode: TSnapMode;
  ADir: Integer): Double;
var
  step, q: Double;
begin
  if AMode = smOff then
    Exit(Max(0.0, ASeconds));

  step := GridSpacingSeconds(ACtx, AMode);
  if step <= 0 then
    Exit(Max(0.0, ASeconds));

  q := ASeconds / step;
  if ADir < 0 then
    q := Floor(q + 1e-9)
  else if ADir > 0 then
    q := Ceil(q - 1e-9)
  else
    q := Floor(q + 0.5);

  Result := q * step;
  if Result < 0 then
    Result := 0;
end;

function SnapSeconds(const ACtx: TGridContext; ASeconds: Double; AMode: TSnapMode): Double;
begin
  Result := SnapSecondsDir(ACtx, ASeconds, AMode, 0);
end;

function GridLineSeconds(const ACtx: TGridContext; AMode: TSnapMode; AIndex: Integer): Double;
var
  step: Double;
begin
  step := GridSpacingSeconds(ACtx, AMode);
  if step <= 0 then
    Exit(0.0);
  Result := AIndex * step;
  if Result < 0 then
    Result := 0;
end;

{ ================= formatting ================= }

function FormatBarsBeats(const ACtx: TGridContext; ASeconds: Double): string;
var
  spb, totalBeats, beatsPerBar: Double;
  bar, beat, tick: Integer;
  fracBeat: Double;
begin
  if not ACtx.IsValid then
    Exit(FormatTimecode(ASeconds));
  spb := ACtx.SecondsPerBeat;
  beatsPerBar := ACtx.BeatsPerBar;
  if ASeconds < 0 then ASeconds := 0;
  totalBeats := ASeconds / spb;

  bar := Floor(totalBeats / beatsPerBar);
  beat := Floor(totalBeats - bar * beatsPerBar);
  fracBeat := (totalBeats - bar * beatsPerBar) - beat;
  tick := Round(fracBeat * TIMELINE_PPQ);
  if tick >= TIMELINE_PPQ then
  begin
    tick := 0;
    Inc(beat);
    if beat >= Round(beatsPerBar) then
    begin
      beat := 0;
      Inc(bar);
    end;
  end;

  Result := Format('%d.%d.%.3d', [bar + 1, beat + 1, tick]);
end;

function FormatTimecode(ASeconds: Double): string;
var
  neg: Boolean;
  total, h, m, s, ms: Int64;
begin
  neg := ASeconds < 0;
  if neg then ASeconds := -ASeconds;
  total := Round(ASeconds * 1000.0);
  ms := total mod 1000;
  total := total div 1000;
  s := total mod 60;
  total := total div 60;
  m := total mod 60;
  h := total div 60;
  if h > 0 then
    Result := Format('%d:%.2d:%.2d.%.3d', [h, m, s, ms])
  else
    Result := Format('%.2d:%.2d.%.3d', [m, s, ms]);
  if neg then
    Result := '-' + Result;
end;

end.
