unit UDAW.MIDI.Sequence;
{$I udaw.inc}

{ Phase 17 - MIDI: the musical model.

  TMidiSequence is the editable representation the piano roll and the playback
  engine work on: a pulses-per-quarter grid, a set of tracks, and a tempo /
  time-signature map.  Each track carries

    * Notes     - paired note-on / note-off with start tick, length, channel,
                  key number, on/off velocity and a stable Id (so the undo
                  commands and the UI can refer to a note across edits);
    * Controllers - a flat time-ordered list of CC changes (for the controller
                  lanes);
    * Aux       - every other channel / SysEx event (program change, pitch
                  bend, aftertouch, ...) kept verbatim so a load -> edit -> save
                  round-trips.

  BuildFromSMF / ToSMF bridge to UDAW.MIDI.SMF; TickToSeconds / SecondsToTick
  integrate the tempo map so the engine and timeline can place MIDI in real
  time. }

interface

uses
  SysUtils, Classes, Math,
  UDAW.Errors, UDAW.MIDI.Types, UDAW.MIDI.SMF;

type
  TMidiNote = record
    Id: Integer;
    StartTick: Int64;
    LengthTick: Int64;
    Channel: Integer;      // 0..15
    Note: Integer;         // 0..127
    Velocity: Integer;     // 1..127
    OffVelocity: Integer;  // 0..127
    Selected: Boolean;
    function EndTick: Int64;
  end;
  TMidiNoteArray = TArray<TMidiNote>;

  TMidiCC = record
    Tick: Int64;
    Channel: Integer;
    Controller: Integer;
    Value: Integer;
  end;
  TMidiCCArray = TArray<TMidiCC>;

  TTempoPoint = record
    Tick: Int64;
    MicrosPerQuarter: Cardinal;
  end;
  TTimeSigPoint = record
    Tick: Int64;
    Num: Integer;
    DenPow2: Integer;      // denominator = 1 shl DenPow2
  end;

  TMidiTrackSeq = class
  private
    FName: string;
    FNotes: TMidiNoteArray;
    FNoteCount: Integer;
    FCC: TMidiCCArray;
    FCCCount: Integer;
    FAux: TMidiEventArray;
    FAuxCount: Integer;
    FChannelHint: Integer;
    FProgramHint: Integer;
  public
    constructor Create(const AName: string = '');
    procedure Clear;
    function AddNote(const ANote: TMidiNote): Integer;   // returns array index; assigns Id if 0
    procedure RemoveNoteAt(AIndex: Integer);
    function IndexOfNoteId(AId: Integer): Integer;
    { in-place edit accessors (FNotes/FCC are private to this unit) }
    procedure UpdateNote(AIndex: Integer; const ANote: TMidiNote);
    procedure SetNoteSelected(AIndex: Integer; AValue: Boolean);
    procedure UpdateCC(AIndex: Integer; const ACC: TMidiCC);
    procedure SortNotes;
    procedure AddCC(const ACC: TMidiCC);
    procedure SortCC;
    procedure AddAux(const AEvent: TMidiEvent);
    function LastTick: Int64;
    function Clone: TMidiTrackSeq;
    property Name: string read FName write FName;
    property Notes: TMidiNoteArray read FNotes;
    property NoteCount: Integer read FNoteCount;
    property Controllers: TMidiCCArray read FCC;
    property CCCount: Integer read FCCCount;
    property Aux: TMidiEventArray read FAux;
    property AuxCount: Integer read FAuxCount;
    property ChannelHint: Integer read FChannelHint write FChannelHint;
    property ProgramHint: Integer read FProgramHint write FProgramHint;
  end;

  TMidiSequence = class
  private
    FPPQ: Integer;
    FTracks: TArray<TMidiTrackSeq>;
    FTempo: TArray<TTempoPoint>;
    FTimeSig: TArray<TTimeSigPoint>;
    FNextNoteId: Integer;
    procedure EnsureTempoAtZero;
  public
    constructor Create(APPQ: Integer = MIDI_DEFAULT_PPQ);
    destructor Destroy; override;
    procedure Clear;
    procedure InitDefault;

    function AddTrack(const AName: string = ''): TMidiTrackSeq;
    procedure RemoveTrack(AIndex: Integer);
    function TrackCount: Integer;
    function GetTrack(AIndex: Integer): TMidiTrackSeq;
    function NewNoteId: Integer;

    { tempo map }
    procedure ClearTempoMap;
    procedure SetTempoAt(ATick: Int64; ABPM: Double);
    function TempoAt(ATick: Int64): Cardinal;          // us / quarter
    function InitialBPM: Double;
    procedure SetInitialBPM(ABPM: Double);
    function TempoPointCount: Integer;
    function GetTempoPoint(AIndex: Integer): TTempoPoint;

    { time-signature map }
    procedure SetTimeSigAt(ATick: Int64; ANum, ADenom: Integer);
    function TimeSigAt(ATick: Int64; out ANum, ADenPow2: Integer): Boolean;
    function TimeSigPointCount: Integer;
    function GetTimeSigPoint(AIndex: Integer): TTimeSigPoint;

    { conversions }
    function TickToSeconds(ATick: Int64): Double;
    function SecondsToTick(ASeconds: Double): Int64;
    function DurationTicks: Int64;
    function DurationSeconds: Double;
    function TicksPerBar(ATick: Int64): Int64;

    { SMF bridge }
    procedure BuildFromSMF(ASmf: TSmfFile);
    function ToSMF(AFormat: Integer = 1): TSmfFile;

    function Clone: TMidiSequence;
    function Describe: string;

    property PPQ: Integer read FPPQ write FPPQ;
  end;

implementation

const
  SEQ_SUBSYS = 'MIDI.Sequence';

{ ============================ TMidiNote =========================== }

function TMidiNote.EndTick: Int64;
begin
  Result := StartTick + LengthTick;
end;

{ ============================ TMidiTrackSeq ======================= }

constructor TMidiTrackSeq.Create(const AName: string);
begin
  inherited Create;
  FName := AName;
  FChannelHint := 0;
  FProgramHint := 0;
end;

procedure TMidiTrackSeq.Clear;
begin
  SetLength(FNotes, 0); FNoteCount := 0;
  SetLength(FCC, 0); FCCCount := 0;
  SetLength(FAux, 0); FAuxCount := 0;
end;

function TMidiTrackSeq.AddNote(const ANote: TMidiNote): Integer;
begin
  if FNoteCount >= Length(FNotes) then
    SetLength(FNotes, IfThen(Length(FNotes) = 0, 64, Length(FNotes) * 2));
  FNotes[FNoteCount] := ANote;
  if FNotes[FNoteCount].Velocity <= 0 then FNotes[FNoteCount].Velocity := 1;
  Result := FNoteCount;
  Inc(FNoteCount);
end;

procedure TMidiTrackSeq.RemoveNoteAt(AIndex: Integer);
var
  i: Integer;
begin
  if (AIndex < 0) or (AIndex >= FNoteCount) then Exit;
  for i := AIndex to FNoteCount - 2 do
    FNotes[i] := FNotes[i + 1];
  Dec(FNoteCount);
end;

function TMidiTrackSeq.IndexOfNoteId(AId: Integer): Integer;
var
  i: Integer;
begin
  Result := -1;
  for i := 0 to FNoteCount - 1 do
    if FNotes[i].Id = AId then Exit(i);
end;

procedure TMidiTrackSeq.UpdateNote(AIndex: Integer; const ANote: TMidiNote);
begin
  if (AIndex >= 0) and (AIndex < FNoteCount) then
    FNotes[AIndex] := ANote;
end;

procedure TMidiTrackSeq.SetNoteSelected(AIndex: Integer; AValue: Boolean);
begin
  if (AIndex >= 0) and (AIndex < FNoteCount) then
    FNotes[AIndex].Selected := AValue;
end;

procedure TMidiTrackSeq.UpdateCC(AIndex: Integer; const ACC: TMidiCC);
begin
  if (AIndex >= 0) and (AIndex < FCCCount) then
    FCC[AIndex] := ACC;
end;

procedure TMidiTrackSeq.SortNotes;
var
  i, j: Integer;
  key: TMidiNote;
begin
  for i := 1 to FNoteCount - 1 do
  begin
    key := FNotes[i];
    j := i - 1;
    while (j >= 0) and ((FNotes[j].StartTick > key.StartTick) or
          ((FNotes[j].StartTick = key.StartTick) and (FNotes[j].Note > key.Note))) do
    begin
      FNotes[j + 1] := FNotes[j];
      Dec(j);
    end;
    FNotes[j + 1] := key;
  end;
end;

procedure TMidiTrackSeq.AddCC(const ACC: TMidiCC);
begin
  if FCCCount >= Length(FCC) then
    SetLength(FCC, IfThen(Length(FCC) = 0, 64, Length(FCC) * 2));
  FCC[FCCCount] := ACC;
  Inc(FCCCount);
end;

procedure TMidiTrackSeq.SortCC;
var
  i, j: Integer;
  key: TMidiCC;
begin
  for i := 1 to FCCCount - 1 do
  begin
    key := FCC[i];
    j := i - 1;
    while (j >= 0) and (FCC[j].Tick > key.Tick) do
    begin
      FCC[j + 1] := FCC[j];
      Dec(j);
    end;
    FCC[j + 1] := key;
  end;
end;

procedure TMidiTrackSeq.AddAux(const AEvent: TMidiEvent);
begin
  if FAuxCount >= Length(FAux) then
    SetLength(FAux, IfThen(Length(FAux) = 0, 32, Length(FAux) * 2));
  FAux[FAuxCount] := AEvent;
  Inc(FAuxCount);
end;

function TMidiTrackSeq.LastTick: Int64;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to FNoteCount - 1 do
    Result := Max(Result, FNotes[i].EndTick);
  for i := 0 to FCCCount - 1 do
    Result := Max(Result, FCC[i].Tick);
  for i := 0 to FAuxCount - 1 do
    Result := Max(Result, FAux[i].Tick);
end;

function TMidiTrackSeq.Clone: TMidiTrackSeq;
var
  i: Integer;
begin
  Result := TMidiTrackSeq.Create(FName);
  Result.FChannelHint := FChannelHint;
  Result.FProgramHint := FProgramHint;
  SetLength(Result.FNotes, FNoteCount);
  for i := 0 to FNoteCount - 1 do Result.FNotes[i] := FNotes[i];
  Result.FNoteCount := FNoteCount;
  SetLength(Result.FCC, FCCCount);
  for i := 0 to FCCCount - 1 do Result.FCC[i] := FCC[i];
  Result.FCCCount := FCCCount;
  SetLength(Result.FAux, FAuxCount);
  for i := 0 to FAuxCount - 1 do Result.FAux[i] := FAux[i];
  Result.FAuxCount := FAuxCount;
end;

{ ============================ TMidiSequence ====================== }

constructor TMidiSequence.Create(APPQ: Integer);
begin
  inherited Create;
  if APPQ <= 0 then APPQ := MIDI_DEFAULT_PPQ;
  FPPQ := APPQ;
  FNextNoteId := 1;
  EnsureTempoAtZero;
end;

destructor TMidiSequence.Destroy;
begin
  Clear;
  inherited Destroy;
end;

procedure TMidiSequence.Clear;
var
  i: Integer;
begin
  for i := 0 to High(FTracks) do
    FTracks[i].Free;
  SetLength(FTracks, 0);
  SetLength(FTempo, 0);
  SetLength(FTimeSig, 0);
end;

procedure TMidiSequence.EnsureTempoAtZero;
begin
  if Length(FTempo) = 0 then
  begin
    SetLength(FTempo, 1);
    FTempo[0].Tick := 0;
    FTempo[0].MicrosPerQuarter := MIDI_DEFAULT_TEMPO_US;
  end
  else if FTempo[0].Tick <> 0 then
  begin
    SetLength(FTempo, Length(FTempo) + 1);
    Move(FTempo[0], FTempo[1], (Length(FTempo) - 1) * SizeOf(TTempoPoint));
    FTempo[0].Tick := 0;
    FTempo[0].MicrosPerQuarter := FTempo[1].MicrosPerQuarter;
  end;
end;

procedure TMidiSequence.InitDefault;
begin
  Clear;
  EnsureTempoAtZero;
  SetLength(FTimeSig, 1);
  FTimeSig[0].Tick := 0;
  FTimeSig[0].Num := 4;
  FTimeSig[0].DenPow2 := 2;
  AddTrack('Track 1');
end;

function TMidiSequence.AddTrack(const AName: string): TMidiTrackSeq;
var
  n: Integer;
begin
  n := Length(FTracks);
  SetLength(FTracks, n + 1);
  FTracks[n] := TMidiTrackSeq.Create(AName);
  Result := FTracks[n];
end;

procedure TMidiSequence.RemoveTrack(AIndex: Integer);
var
  i: Integer;
begin
  if (AIndex < 0) or (AIndex > High(FTracks)) then Exit;
  FTracks[AIndex].Free;
  for i := AIndex to High(FTracks) - 1 do
    FTracks[i] := FTracks[i + 1];
  SetLength(FTracks, Length(FTracks) - 1);
end;

function TMidiSequence.TrackCount: Integer;
begin
  Result := Length(FTracks);
end;

function TMidiSequence.GetTrack(AIndex: Integer): TMidiTrackSeq;
begin
  if (AIndex < 0) or (AIndex > High(FTracks)) then Result := nil
  else Result := FTracks[AIndex];
end;

function TMidiSequence.NewNoteId: Integer;
begin
  Result := FNextNoteId;
  Inc(FNextNoteId);
end;

{ ---- tempo map ---- }

procedure TMidiSequence.ClearTempoMap;
begin
  SetLength(FTempo, 0);
  EnsureTempoAtZero;
end;

procedure TMidiSequence.SetTempoAt(ATick: Int64; ABPM: Double);
var
  i, ins: Integer;
  us: Cardinal;
begin
  if ATick < 0 then ATick := 0;
  us := BPMToTempo(ABPM);
  for i := 0 to High(FTempo) do
    if FTempo[i].Tick = ATick then
    begin
      FTempo[i].MicrosPerQuarter := us;
      Exit;
    end;
  ins := Length(FTempo);
  for i := 0 to High(FTempo) do
    if FTempo[i].Tick > ATick then begin ins := i; Break; end;
  SetLength(FTempo, Length(FTempo) + 1);
  for i := High(FTempo) downto ins + 1 do
    FTempo[i] := FTempo[i - 1];
  FTempo[ins].Tick := ATick;
  FTempo[ins].MicrosPerQuarter := us;
end;

function TMidiSequence.TempoAt(ATick: Int64): Cardinal;
var
  i: Integer;
begin
  Result := MIDI_DEFAULT_TEMPO_US;
  for i := 0 to High(FTempo) do
    if FTempo[i].Tick <= ATick then
      Result := FTempo[i].MicrosPerQuarter
    else
      Break;
end;

function TMidiSequence.InitialBPM: Double;
begin
  EnsureTempoAtZero;
  Result := TempoToBPM(FTempo[0].MicrosPerQuarter);
end;

procedure TMidiSequence.SetInitialBPM(ABPM: Double);
begin
  EnsureTempoAtZero;
  FTempo[0].MicrosPerQuarter := BPMToTempo(ABPM);
end;

function TMidiSequence.TempoPointCount: Integer;
begin
  Result := Length(FTempo);
end;

function TMidiSequence.GetTempoPoint(AIndex: Integer): TTempoPoint;
begin
  if (AIndex < 0) or (AIndex > High(FTempo)) then
    FillChar(Result, SizeOf(Result), 0)
  else
    Result := FTempo[AIndex];
end;

{ ---- time signature map ---- }

procedure TMidiSequence.SetTimeSigAt(ATick: Int64; ANum, ADenom: Integer);
var
  i, ins, denPow2: Integer;
begin
  if ATick < 0 then ATick := 0;
  if ANum < 1 then ANum := 1;
  denPow2 := 0;
  while (1 shl denPow2) < ADenom do Inc(denPow2);
  for i := 0 to High(FTimeSig) do
    if FTimeSig[i].Tick = ATick then
    begin
      FTimeSig[i].Num := ANum;
      FTimeSig[i].DenPow2 := denPow2;
      Exit;
    end;
  ins := Length(FTimeSig);
  for i := 0 to High(FTimeSig) do
    if FTimeSig[i].Tick > ATick then begin ins := i; Break; end;
  SetLength(FTimeSig, Length(FTimeSig) + 1);
  for i := High(FTimeSig) downto ins + 1 do
    FTimeSig[i] := FTimeSig[i - 1];
  FTimeSig[ins].Tick := ATick;
  FTimeSig[ins].Num := ANum;
  FTimeSig[ins].DenPow2 := denPow2;
end;

function TMidiSequence.TimeSigAt(ATick: Int64; out ANum, ADenPow2: Integer): Boolean;
var
  i: Integer;
begin
  ANum := 4; ADenPow2 := 2;
  Result := False;
  for i := 0 to High(FTimeSig) do
    if FTimeSig[i].Tick <= ATick then
    begin
      ANum := FTimeSig[i].Num;
      ADenPow2 := FTimeSig[i].DenPow2;
      Result := True;
    end
    else
      Break;
end;

function TMidiSequence.TimeSigPointCount: Integer;
begin
  Result := Length(FTimeSig);
end;

function TMidiSequence.GetTimeSigPoint(AIndex: Integer): TTimeSigPoint;
begin
  if (AIndex < 0) or (AIndex > High(FTimeSig)) then
    FillChar(Result, SizeOf(Result), 0)
  else
    Result := FTimeSig[AIndex];
end;

function TMidiSequence.TicksPerBar(ATick: Int64): Int64;
var
  num, denPow2: Integer;
begin
  TimeSigAt(ATick, num, denPow2);
  { ticks per whole note = 4 * PPQ ; per bar = num * (4*PPQ / 2^denPow2) }
  Result := Int64(num) * ((4 * Int64(FPPQ)) shr denPow2);
  if Result <= 0 then Result := 4 * FPPQ;
end;

{ ---- conversions ---- }

function TMidiSequence.TickToSeconds(ATick: Int64): Double;
var
  i: Integer;
  segStart, segEnd: Int64;
  us: Cardinal;
  acc: Double;
begin
  EnsureTempoAtZero;
  if ATick <= 0 then Exit(0);
  acc := 0;
  for i := 0 to High(FTempo) do
  begin
    segStart := FTempo[i].Tick;
    if i < High(FTempo) then segEnd := FTempo[i + 1].Tick else segEnd := ATick;
    if segEnd > ATick then segEnd := ATick;
    if segEnd <= segStart then
    begin
      if segStart >= ATick then Break else Continue;
    end;
    us := FTempo[i].MicrosPerQuarter;
    acc := acc + ((segEnd - segStart) / FPPQ) * (us / 1000000.0);
    if segEnd >= ATick then Break;
  end;
  Result := acc;
end;

function TMidiSequence.SecondsToTick(ASeconds: Double): Int64;
var
  i: Integer;
  segStart, segEnd: Int64;
  us: Cardinal;
  segSeconds, acc: Double;
begin
  EnsureTempoAtZero;
  if ASeconds <= 0 then Exit(0);
  acc := 0;
  for i := 0 to High(FTempo) do
  begin
    segStart := FTempo[i].Tick;
    if i < High(FTempo) then segEnd := FTempo[i + 1].Tick else segEnd := High(Int64) div 4;
    us := FTempo[i].MicrosPerQuarter;
    segSeconds := ((segEnd - segStart) / FPPQ) * (us / 1000000.0);
    if acc + segSeconds >= ASeconds then
    begin
      Result := segStart + Round(((ASeconds - acc) / (us / 1000000.0)) * FPPQ);
      Exit;
    end;
    acc := acc + segSeconds;
  end;
  Result := 0;
end;

function TMidiSequence.DurationTicks: Int64;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(FTracks) do
    Result := Max(Result, FTracks[i].LastTick);
end;

function TMidiSequence.DurationSeconds: Double;
begin
  Result := TickToSeconds(DurationTicks);
end;

{ ---- SMF bridge ---- }

procedure TMidiSequence.BuildFromSMF(ASmf: TSmfFile);
type
  TPending = record Active: Boolean; StartTick: Int64; Velocity: Integer; end;
var
  ti, ei: Integer;
  smfTrk: TSmfTrack;
  seqTrk: TMidiTrackSeq;
  ev: TMidiEvent;
  pending: array[0..15, 0..127] of TPending;
  note: TMidiNote;
  cc: TMidiCC;
  ch, key, tsN, tsD, tsC, tsS: Integer;
begin
  Clear;
  FPPQ := ASmf.TicksPerQuarter;
  if FPPQ <= 0 then FPPQ := MIDI_DEFAULT_PPQ;
  EnsureTempoAtZero;
  SetLength(FTempo, 0);
  SetLength(FTimeSig, 0);

  for ti := 0 to ASmf.TrackCount - 1 do
  begin
    smfTrk := ASmf.GetTrack(ti);
    seqTrk := AddTrack(smfTrk.Name);
    FillChar(pending, SizeOf(pending), 0);

    for ei := 0 to smfTrk.Count - 1 do
    begin
      ev := smfTrk.Events[ei];
      case ev.Kind of
        mekMeta:
          begin
            case ev.MetaType of
              META_SET_TEMPO:
                SetTempoAt(ev.Tick, TempoToBPM(ev.TempoMicros));
              META_TIME_SIG:
                begin
                  ev.TimeSigParts(tsN, tsD, tsC, tsS);
                  SetTimeSigAt(ev.Tick, tsN, 1 shl tsD);
                end;
              META_TRACK_NAME:
                seqTrk.Name := ev.AsText;
            else
              seqTrk.AddAux(ev);   // keep markers, key sig, text, SMPTE, etc.
            end;
          end;
        mekSysEx:
          seqTrk.AddAux(ev);
        mekChannel:
          begin
            ch := ev.Msg.Channel;
            if ev.Msg.IsNoteOn then
            begin
              key := ev.Msg.NoteNumber;
              { a second note-on for a sounding key: close the first at this tick }
              if pending[ch][key].Active then
              begin
                FillChar(note, SizeOf(note), 0);
                note.Id := NewNoteId;
                note.StartTick := pending[ch][key].StartTick;
                note.LengthTick := Max(Int64(1), ev.Tick - pending[ch][key].StartTick);
                note.Channel := ch;
                note.Note := key;
                note.Velocity := pending[ch][key].Velocity;
                note.OffVelocity := 64;
                seqTrk.AddNote(note);
              end;
              pending[ch][key].Active := True;
              pending[ch][key].StartTick := ev.Tick;
              pending[ch][key].Velocity := ev.Msg.Velocity;
              if seqTrk.ChannelHint = 0 then seqTrk.ChannelHint := ch;
            end
            else if ev.Msg.IsNoteOff then
            begin
              key := ev.Msg.NoteNumber;
              if pending[ch][key].Active then
              begin
                FillChar(note, SizeOf(note), 0);
                note.Id := NewNoteId;
                note.StartTick := pending[ch][key].StartTick;
                note.LengthTick := Max(Int64(1), ev.Tick - pending[ch][key].StartTick);
                note.Channel := ch;
                note.Note := key;
                note.Velocity := pending[ch][key].Velocity;
                note.OffVelocity := ev.Msg.Velocity;
                seqTrk.AddNote(note);
                pending[ch][key].Active := False;
              end;
            end
            else if ev.Msg.StatusHi = MIDI_CONTROL_CHANGE then
            begin
              cc.Tick := ev.Tick;
              cc.Channel := ch;
              cc.Controller := ev.Msg.Data1;
              cc.Value := ev.Msg.Data2;
              seqTrk.AddCC(cc);
            end
            else
            begin
              if ev.Msg.StatusHi = MIDI_PROGRAM_CHANGE then
                seqTrk.ProgramHint := ev.Msg.Data1;
              seqTrk.AddAux(ev);
            end;
          end;
      end;
    end;

    { close any still-sounding notes at the track end }
    for ch := 0 to 15 do
      for key := 0 to 127 do
        if pending[ch][key].Active then
        begin
          FillChar(note, SizeOf(note), 0);
          note.Id := NewNoteId;
          note.StartTick := pending[ch][key].StartTick;
          note.LengthTick := Max(Int64(1), smfTrk.LastTick - pending[ch][key].StartTick);
          note.Channel := ch;
          note.Note := key;
          note.Velocity := pending[ch][key].Velocity;
          note.OffVelocity := 64;
          seqTrk.AddNote(note);
        end;

    seqTrk.SortNotes;
    seqTrk.SortCC;
  end;

  EnsureTempoAtZero;
  if Length(FTimeSig) = 0 then
  begin
    SetLength(FTimeSig, 1);
    FTimeSig[0].Tick := 0; FTimeSig[0].Num := 4; FTimeSig[0].DenPow2 := 2;
  end;
end;

function TMidiSequence.ToSMF(AFormat: Integer): TSmfFile;
var
  smf: TSmfFile;
  metaTrk, mtrk: TSmfTrack;
  ti, ni, ci, ai, i: Integer;
  seqTrk: TMidiTrackSeq;

  procedure AddMeta(T: TSmfTrack; ATick: Int64; AType: Byte; const ABytes: TBytes);
  var
    e: TMidiEvent;
  begin
    FillChar(e, SizeOf(e), 0);
    e.Tick := ATick;
    e.Kind := mekMeta;
    e.MetaType := AType;
    e.Bytes := Copy(ABytes);
    T.Add(e);
  end;

  procedure AddChan(T: TSmfTrack; ATick: Int64; const M: TMidiMessage);
  var
    e: TMidiEvent;
  begin
    FillChar(e, SizeOf(e), 0);
    e.Tick := ATick;
    e.Kind := mekChannel;
    e.Msg := M;
    T.Add(e);
  end;

  function TempoBytes(AUs: Cardinal): TBytes;
  begin
    SetLength(Result, 3);
    Result[0] := (AUs shr 16) and $FF;
    Result[1] := (AUs shr 8) and $FF;
    Result[2] := AUs and $FF;
  end;

  function TimeSigBytes(ANum, ADenPow2: Integer): TBytes;
  begin
    SetLength(Result, 4);
    Result[0] := ANum and $FF;
    Result[1] := ADenPow2 and $FF;
    Result[2] := 24;
    Result[3] := 8;
  end;

begin
  smf := TSmfFile.Create;
  smf.FileFormat := AFormat;
  smf.TicksPerQuarter := FPPQ;

  if AFormat = 1 then
  begin
    metaTrk := smf.AddTrack('Conductor');
    for i := 0 to High(FTempo) do
      AddMeta(metaTrk, FTempo[i].Tick, META_SET_TEMPO, TempoBytes(FTempo[i].MicrosPerQuarter));
    for i := 0 to High(FTimeSig) do
      AddMeta(metaTrk, FTimeSig[i].Tick, META_TIME_SIG,
        TimeSigBytes(FTimeSig[i].Num, FTimeSig[i].DenPow2));
    AddMeta(metaTrk, metaTrk.LastTick, META_END_OF_TRACK, nil);
  end;

  for ti := 0 to High(FTracks) do
  begin
    seqTrk := FTracks[ti];
    mtrk := smf.AddTrack(seqTrk.Name);

    if (AFormat = 0) and (ti = 0) then
    begin
      for i := 0 to High(FTempo) do
        AddMeta(mtrk, FTempo[i].Tick, META_SET_TEMPO, TempoBytes(FTempo[i].MicrosPerQuarter));
      for i := 0 to High(FTimeSig) do
        AddMeta(mtrk, FTimeSig[i].Tick, META_TIME_SIG,
          TimeSigBytes(FTimeSig[i].Num, FTimeSig[i].DenPow2));
    end;

    seqTrk.SortNotes;
    for ni := 0 to seqTrk.NoteCount - 1 do
    begin
      AddChan(mtrk, seqTrk.Notes[ni].StartTick,
        TMidiMessage.NoteOn(seqTrk.Notes[ni].Channel, seqTrk.Notes[ni].Note,
          seqTrk.Notes[ni].Velocity));
      AddChan(mtrk, seqTrk.Notes[ni].EndTick,
        TMidiMessage.NoteOff(seqTrk.Notes[ni].Channel, seqTrk.Notes[ni].Note,
          seqTrk.Notes[ni].OffVelocity));
    end;
    for ci := 0 to seqTrk.CCCount - 1 do
      AddChan(mtrk, seqTrk.Controllers[ci].Tick,
        TMidiMessage.ControlChange(seqTrk.Controllers[ci].Channel,
          seqTrk.Controllers[ci].Controller, seqTrk.Controllers[ci].Value));
    for ai := 0 to seqTrk.AuxCount - 1 do
      mtrk.Add(seqTrk.Aux[ai]);

    mtrk.SortByTick;
    AddMeta(mtrk, mtrk.LastTick, META_END_OF_TRACK, nil);
  end;

  Result := smf;
end;

function TMidiSequence.Clone: TMidiSequence;
var
  i: Integer;
begin
  Result := TMidiSequence.Create(FPPQ);
  Result.Clear;
  Result.FPPQ := FPPQ;
  Result.FNextNoteId := FNextNoteId;
  SetLength(Result.FTempo, Length(FTempo));
  for i := 0 to High(FTempo) do Result.FTempo[i] := FTempo[i];
  SetLength(Result.FTimeSig, Length(FTimeSig));
  for i := 0 to High(FTimeSig) do Result.FTimeSig[i] := FTimeSig[i];
  SetLength(Result.FTracks, Length(FTracks));
  for i := 0 to High(FTracks) do
    Result.FTracks[i] := FTracks[i].Clone;
  Result.EnsureTempoAtZero;
end;

function TMidiSequence.Describe: string;
var
  i, totalNotes: Integer;
  sb: TStringBuilder;
begin
  sb := TStringBuilder.Create;
  try
    totalNotes := 0;
    for i := 0 to High(FTracks) do Inc(totalNotes, FTracks[i].NoteCount);
    sb.Append(Format('MIDI sequence: PPQ %d, %d track(s), %d note(s), %.2f BPM, %.3f s',
      [FPPQ, Length(FTracks), totalNotes, InitialBPM, DurationSeconds])).AppendLine;
    for i := 0 to High(FTracks) do
      sb.Append(Format('  track %d "%s": %d notes, %d CC, ch hint %d, prog %d',
        [i, FTracks[i].Name, FTracks[i].NoteCount, FTracks[i].CCCount,
         FTracks[i].ChannelHint, FTracks[i].ProgramHint])).AppendLine;
    Result := sb.ToString;
  finally
    sb.Free;
  end;
end;

end.
