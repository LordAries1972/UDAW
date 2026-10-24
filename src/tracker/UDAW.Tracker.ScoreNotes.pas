unit UDAW.Tracker.ScoreNotes;
{$I udaw.inc}

{ Reads the notes out of a tracker module for the Score: where each one starts and
  ends in seconds (following the module's own speed / tempo / jump / break commands),
  its pitch as a MIDI key, and the channel and instrument that play it, so the Score
  can filter by channel or by instrument. A note ends at the next note, a key-off or a
  note cut on its channel, or at the end of the song. }

interface

uses
  SysUtils, Math,
  UDAW.Tracker.Types, UDAW.Tracker.Pattern;

type
  TTrkScoreNote = record
    StartSec, LenSec: Double;
    Pitch: Integer;        // MIDI key (tracker C-4 = 60)
    Channel: Integer;      // 0-based
    Instrument: Integer;   // 1-based slot, 0 = none
  end;

{ AChanOn / AInstrOn: a flag per channel (0-based) / instrument slot (1-based, index 0
  unused); nil or a short array lets everything through. }
function TrackerScoreNotes(AModule: TTrackerModule; const AChanOn, AInstrOn: TArray<Boolean>): TArray<TTrkScoreNote>;

{ Seconds the module plays for (0 for an empty one). }
function TrackerSongSeconds(AModule: TTrackerModule): Double;

implementation

const
  MAX_ROWS_WALKED = 400000;   // a safety stop for modules that jump around forever

type
  TRowEvent = procedure(ARow, AOrder: Integer; ATimeSec: Double) of object;

function Passes(const AFlags: TArray<Boolean>; AIndex: Integer): Boolean;
begin
  Result := (AIndex < 0) or (AIndex >= Length(AFlags)) or AFlags[AIndex];
end;

function TrackerScoreNotes(AModule: TTrackerModule; const AChanOn, AInstrOn: TArray<Boolean>): TArray<TTrkScoreNote>;
var
  openIdx: array of Integer;     // per channel: index into Result of the sounding note, or -1
  lastInstr: array of Integer;
  visited: array of Boolean;     // (order, row) pairs already walked - a repeat means the song loops
  rowBase: array of Integer;
  speed, bpm, ord_, row, ci, n, walked, jumpOrd, breakRow, totalRows, k: Integer;
  t: Double;
  pat: TTrackerPattern;
  cell: TTrackerCell;
  nextOrd, nextRow, delayRows: Integer;

  procedure CloseNote(ACh: Integer; AAt: Double);
  begin
    if openIdx[ACh] >= 0 then
    begin
      Result[openIdx[ACh]].LenSec := Max(0.02, AAt - Result[openIdx[ACh]].StartSec);
      openIdx[ACh] := -1;
    end;
  end;

begin
  SetLength(Result, 0);
  if (AModule = nil) or (AModule.OrderLength = 0) then Exit;

  n := AModule.Channels;
  SetLength(openIdx, n);
  SetLength(lastInstr, n);
  for ci := 0 to n - 1 do
  begin
    openIdx[ci] := -1;
    lastInstr[ci] := 0;
  end;

  { one visited flag per (order, row) }
  SetLength(rowBase, AModule.OrderLength + 1);
  totalRows := 0;
  for ord_ := 0 to AModule.OrderLength - 1 do
  begin
    rowBase[ord_] := totalRows;
    pat := AModule.GetPattern(AModule.GetOrder(ord_));
    if pat <> nil then Inc(totalRows, pat.Rows);
  end;
  rowBase[AModule.OrderLength] := totalRows;
  SetLength(visited, totalRows);

  speed := Max(1, AModule.InitialSpeed);
  bpm := Max(32, AModule.InitialBPM);
  t := 0;
  ord_ := 0;
  row := 0;
  walked := 0;

  while (ord_ < AModule.OrderLength) and (walked < MAX_ROWS_WALKED) do
  begin
    pat := AModule.GetPattern(AModule.GetOrder(ord_));
    if (pat = nil) or (row >= pat.Rows) then
    begin
      Inc(ord_);
      row := 0;
      Continue;
    end;
    if visited[rowBase[ord_] + row] then Break;   // the song has come round again
    visited[rowBase[ord_] + row] := True;
    Inc(walked);

    jumpOrd := -1;
    breakRow := -1;
    delayRows := 0;
    for ci := 0 to Min(n, pat.Channels) - 1 do
    begin
      cell := pat.GetCell(row, ci);
      if cell.Instrument <> TRK_INSTR_NONE then lastInstr[ci] := cell.Instrument;

      case cell.Effect of
        tfxSetSpeed:
          if cell.Param > 0 then
            if cell.Param < $20 then speed := cell.Param else bpm := Max(32, cell.Param);
        tfxSetBPM:
          if cell.Param > 0 then bpm := Max(32, cell.Param);
        tfxPositionJump: jumpOrd := cell.Param;
        tfxPatternBreak: breakRow := cell.Param;
        tfxPatternDelay: delayRows := Max(delayRows, cell.Param and $0F);
      end;
    end;

    for ci := 0 to Min(n, pat.Channels) - 1 do
    begin
      cell := pat.GetCell(row, ci);
      case cell.Note of
        TRK_NOTE_NONE: ;
        TRK_NOTE_OFF, TRK_NOTE_CUT: CloseNote(ci, t);
      else
        if (cell.Note >= TRK_NOTE_MIN) and (cell.Note <= TRK_NOTE_MAX) and
           not (cell.Effect in [tfxTonePorta, tfxTonePortaVolSlide]) then
        begin
          CloseNote(ci, t);
          if Passes(AChanOn, ci) and Passes(AInstrOn, lastInstr[ci]) then
          begin
            k := Length(Result);
            SetLength(Result, k + 1);
            Result[k].StartSec := t;
            Result[k].LenSec := 0.25;
            Result[k].Pitch := cell.Note + 11;
            Result[k].Channel := ci;
            Result[k].Instrument := lastInstr[ci];
            openIdx[ci] := k;
          end;
        end;
      end;
    end;

    t := t + (speed * (1 + delayRows)) * 2.5 / bpm;

    if jumpOrd >= 0 then
    begin
      nextOrd := jumpOrd;
      nextRow := Max(0, breakRow);
    end
    else if breakRow >= 0 then
    begin
      nextOrd := ord_ + 1;
      nextRow := breakRow;
    end
    else
    begin
      nextOrd := ord_;
      nextRow := row + 1;
    end;
    ord_ := nextOrd;
    row := nextRow;
  end;

  for ci := 0 to n - 1 do CloseNote(ci, t);
end;

function TrackerSongSeconds(AModule: TTrackerModule): Double;
var
  notes: TArray<TTrkScoreNote>;
  i: Integer;
begin
  Result := 0;
  notes := TrackerScoreNotes(AModule, nil, nil);
  for i := 0 to High(notes) do
    Result := Max(Result, notes[i].StartSec + notes[i].LenSec);
end;

end.
