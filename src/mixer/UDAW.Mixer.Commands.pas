unit UDAW.Mixer.Commands;
{$I udaw.inc}

{ Phase 9 - Mixer: undo/redo commands (plan section 28) for TMixerModel,
  built on the Phase 5 TDAWCommand / TCommandManager.

  Two families:

    * structural commands (add / remove strip, route output, add / remove /
      move an insert, add / remove a send, assign a VCA group) capture the
      whole mixer as text before and after the edit and restore it through the
      Phase 9 text serializer - no raw class memory is ever snapshotted, and
      routing that a mutation would make invalid is rejected before the command
      is kept; and

    * fine-grained parameter commands (fader, pan, trim, width, mute, solo,
      polarity, record-arm, send gain) that mutate a single field and merge a
      burst of moves into one undo step exactly as the plan's fader example
      calls for. }

interface

uses
  SysUtils,
  UDAW.Errors,
  UDAW.Project.Document, UDAW.Project.Commands,
  UDAW.Mixer.Model, UDAW.Mixer.Serialization, UDAW.Mixer.Automation,
  UDAW.Timeline.Model;

{ The Timeline track a mixer strip backs (strip.InputSourceId), or nil for
  buses/aux/VCA/master. }
function TrackForMixStrip(ADoc: TProjectDocument; AStripId: Integer): TTimelineTrack;

type
  TMixFloatField = (mffFader, mffPan, mffTrim, mffWidth);
  TMixFlagField  = (mfgMute, mfgSolo, mfgPolarity, mfgArm);

  { ---- base ---- }

  TMixerCommand = class abstract(TDAWCommand)
  protected
    FDoc: TProjectDocument;
    { True when the command edits the Tracker mixer (set before it is performed); it keeps working
      on that mixer however the Mixer view is switched afterwards }
    FTrackerSide: Boolean;
    function M: TMixerModel;
    procedure ReplaceM(AModel: TMixerModel);
    procedure RequireValidRouting;
  public
    constructor Create(ADoc: TProjectDocument);
    property TrackerSide: Boolean read FTrackerSide write FTrackerSide;
  end;

  { ---- structural (text snapshot before/after) ---- }

  TMixerStructuralCommand = class abstract(TMixerCommand)
  private
    FBefore: string;
    FAfter: string;
  protected
    { Perform the edit on M. Return False for "nothing to do". May raise
      EUDAWError to reject the edit (the manager then discards the command and
      the model is left as Mutate found it - so a rejecting Mutate must undo
      any partial change itself before raising). }
    function Mutate: Boolean; virtual; abstract;
  public
    function Execute: Boolean; override;
    procedure Undo; override;
    function Redo: Boolean; override;
  end;

  TAddMixStripCommand = class(TMixerStructuralCommand)
  private
    FKind: TMixStripKind;
    FName: string;
    FCreatedId: Integer;
  protected
    function Mutate: Boolean; override;
  public
    constructor Create(ADoc: TProjectDocument; AKind: TMixStripKind; const AName: string);
    function Description: string; override;
    property CreatedId: Integer read FCreatedId;
  end;

  TRemoveMixStripCommand = class(TMixerStructuralCommand)
  private
    FStripId: Integer;
    FName: string;
  protected
    function Mutate: Boolean; override;
  public
    constructor Create(ADoc: TProjectDocument; AStripId: Integer);
    function Description: string; override;
  end;

  TSetMixStripRouteCommand = class(TMixerStructuralCommand)
  private
    FStripId: Integer;
    FNewTargetId: Integer;
  protected
    function Mutate: Boolean; override;
  public
    constructor Create(ADoc: TProjectDocument; AStripId, ANewTargetId: Integer);
    function Description: string; override;
  end;

  { Links (or unlinks, with ATrackId = 0) an skAudioTrack strip to a Timeline
    track's id (TMixStrip.InputSourceId) - see UDAW.Timeline.Playback's
    AttachMixer/RefreshLinkedTracks, which is what actually makes a linked
    strip's fader/pan/inserts/sends reach the output instead of the track
    playing through its own direct gain/pan. Rejects a track id already
    claimed by another strip so two strips never fight over the same track's
    audio. }
  TSetMixStripInputCommand = class(TMixerStructuralCommand)
  private
    FStripId: Integer;
    FNewTrackId: Integer;
  protected
    function Mutate: Boolean; override;
  public
    constructor Create(ADoc: TProjectDocument; AStripId, ANewTrackId: Integer);
    function Description: string; override;
  end;

  { Reorders a strip in the mixer's strip list (drag-and-drop in the Mixer
    tab). Purely cosmetic/ordering - it does not touch routing - so it never
    fails ValidateRouting and needs no rollback branch. }
  TMoveMixStripCommand = class(TMixerStructuralCommand)
  private
    FStripId, FNewIndex: Integer;
  protected
    function Mutate: Boolean; override;
  public
    constructor Create(ADoc: TProjectDocument; AStripId, ANewIndex: Integer);
    function Description: string; override;
  end;

  TSetMixStripVCACommand = class(TMixerStructuralCommand)
  private
    FStripId: Integer;
    FVCAId: Integer;
  protected
    function Mutate: Boolean; override;
  public
    constructor Create(ADoc: TProjectDocument; AStripId, AVCAId: Integer);
    function Description: string; override;
  end;

  TAddMixSendCommand = class(TMixerStructuralCommand)
  private
    FStripId, FTargetId: Integer;
    FGainDb: Double;
    FMode: TMixSendMode;
  protected
    function Mutate: Boolean; override;
  public
    constructor Create(ADoc: TProjectDocument; AStripId, ATargetId: Integer;
      AGainDb: Double; AMode: TMixSendMode);
    function Description: string; override;
  end;

  TRemoveMixSendCommand = class(TMixerStructuralCommand)
  private
    FStripId, FTargetId: Integer;
  protected
    function Mutate: Boolean; override;
  public
    constructor Create(ADoc: TProjectDocument; AStripId, ATargetId: Integer);
    function Description: string; override;
  end;

  TAddMixInsertCommand = class(TMixerStructuralCommand)
  private
    FStripId: Integer;
    FKind, FParams: string;
    FIndex: Integer;   // -1 => append
    { the caller appends the effect's name to the backing track's title right
      after Perform; snapshot it so Undo takes the name back out }
    FTitleTrackId: Integer;
    FOldTitle, FRedoTitle, FEffectName: string;
    FHaveRedoTitle: Boolean;
  protected
    function Mutate: Boolean; override;
  public
    { AEffectName is the label appended to the backing track's title (done here
      so every caller - UI, AI mixing, AI mastering - is titled and undone the
      same way); '' falls back to the insert kind id. }
    constructor Create(ADoc: TProjectDocument; AStripId: Integer;
      const AKind, AParams: string; AIndex: Integer = -1;
      const AEffectName: string = '');
    function Execute: Boolean; override;
    procedure Undo; override;
    function Redo: Boolean; override;
    function Description: string; override;
  end;

  TRemoveMixInsertCommand = class(TMixerStructuralCommand)
  private
    FStripId, FIndex: Integer;
  protected
    function Mutate: Boolean; override;
  public
    constructor Create(ADoc: TProjectDocument; AStripId, AIndex: Integer);
    function Description: string; override;
  end;

  TMoveMixInsertCommand = class(TMixerStructuralCommand)
  private
    FStripId, FFromIndex, FToIndex: Integer;
  protected
    function Mutate: Boolean; override;
  public
    constructor Create(ADoc: TProjectDocument; AStripId, AFromIndex, AToIndex: Integer);
    function Description: string; override;
  end;

  { Changes an existing insert's parameter string in place (the insert's kind
    and position are unchanged). Used by the Phase 27/28 AI mixing/mastering
    assistants to tune an insert they (or the user) already added, without a
    remove+re-add round trip. Mergeable like TSetMixStripFloatCommand so a
    knob dragged through many intermediate values collapses into one step. }
  TSetMixInsertParamsCommand = class(TMixerCommand)
  private
    FStripId, FIndex: Integer;
    FOld, FNew: string;
  public
    constructor Create(ADoc: TProjectDocument; AStripId, AIndex: Integer;
      const ANewParams: string);
    function Execute: Boolean; override;
    procedure Undo; override;
    function Description: string; override;
    function AbsorbNext(ANext: TDAWCommand): Boolean; override;
  end;

  { Changes an existing insert's external-sidechain key source (TMixInsert.
    SidechainStripId; 0 = none / self-keyed). Mirrors TSetMixInsertParamsCommand
    but for this one non-Params field, so a dynamics insert can be keyed off
    another strip from the UI without a remove+re-add round trip. }
  TSetMixInsertSidechainCommand = class(TMixerCommand)
  private
    FStripId, FIndex: Integer;
    FOld, FNew: Integer;
  public
    constructor Create(ADoc: TProjectDocument; AStripId, AIndex,
      ANewSidechainStripId: Integer);
    function Execute: Boolean; override;
    procedure Undo; override;
    function Description: string; override;
  end;

  { ---- automation breakpoint edits (structural: whole-mixer text snapshot,
    same as the other structural commands - AddPoint mutates a TList in place
    so there is no cheap per-field undo to capture) ---- }

  TAddAutomationPointCommand = class(TMixerStructuralCommand)
  private
    FStripId: Integer;
    FParam: TAutomationParam;
    FTargetIndex, FSubIndex: Integer;
    FTimeSeconds, FValue: Double;
  protected
    function Mutate: Boolean; override;
  public
    constructor Create(ADoc: TProjectDocument; AStripId: Integer; AParam: TAutomationParam;
      ATimeSeconds, AValue: Double; ATargetIndex: Integer = 0;
      ASubIndex: Integer = 0);
    function Description: string; override;
    function AbsorbNext(ANext: TDAWCommand): Boolean; override;
  end;

  TRemoveAutomationPointCommand = class(TMixerStructuralCommand)
  private
    FStripId: Integer;
    FParam: TAutomationParam;
    FTargetIndex, FSubIndex: Integer;
    FTimeSeconds, FToleranceSeconds: Double;
  protected
    function Mutate: Boolean; override;
  public
    constructor Create(ADoc: TProjectDocument; AStripId: Integer; AParam: TAutomationParam;
      ATimeSeconds, AToleranceSeconds: Double; ATargetIndex: Integer = 0;
      ASubIndex: Integer = 0);
    function Description: string; override;
  end;

  TClearAutomationLaneCommand = class(TMixerStructuralCommand)
  private
    FStripId: Integer;
    FParam: TAutomationParam;
    FTargetIndex, FSubIndex: Integer;
  protected
    function Mutate: Boolean; override;
  public
    constructor Create(ADoc: TProjectDocument; AStripId: Integer; AParam: TAutomationParam;
      ATargetIndex: Integer = 0; ASubIndex: Integer = 0);
    function Description: string; override;
  end;

  { ---- fine-grained parameter commands (mergeable) ---- }

  TSetMixStripFloatCommand = class(TMixerCommand)
  private
    FStripId: Integer;
    FField: TMixFloatField;
    FOld, FNew: Double;
    procedure Apply(AValue: Double);
    function Current: Double;
  public
    constructor Create(ADoc: TProjectDocument; AStripId: Integer;
      AField: TMixFloatField; ANewValue: Double);
    function Execute: Boolean; override;
    procedure Undo; override;
    function Description: string; override;
    function AbsorbNext(ANext: TDAWCommand): Boolean; override;
  end;

  TSetMixStripFlagCommand = class(TMixerCommand)
  private
    FStripId: Integer;
    FField: TMixFlagField;
    FOld, FNew: Boolean;
    procedure Apply(AValue: Boolean);
    function Current: Boolean;
  public
    constructor Create(ADoc: TProjectDocument; AStripId: Integer;
      AField: TMixFlagField; ANewValue: Boolean);
    function Execute: Boolean; override;
    procedure Undo; override;
    function Description: string; override;
  end;

  { Mixer automation read-write mode (amOff/amRead/amTouch/amLatch/
    amWrite - see UDAW.Mixer.Model.TMixAutomationMode and
    UDAW.Mixer.Automation). Not mergeable - it is a discrete mode switch, not
    a dragged value. }
  TSetMixStripAutoModeCommand = class(TMixerCommand)
  private
    FStripId: Integer;
    FOld, FNew: TMixAutomationMode;
  public
    constructor Create(ADoc: TProjectDocument; AStripId: Integer; ANewMode: TMixAutomationMode);
    function Execute: Boolean; override;
    procedure Undo; override;
    function Description: string; override;
  end;

  TSetMixSendGainCommand = class(TMixerCommand)
  private
    FStripId, FTargetId: Integer;
    FOld, FNew: Double;
  public
    constructor Create(ADoc: TProjectDocument; AStripId, ATargetId: Integer;
      ANewGainDb: Double);
    function Execute: Boolean; override;
    procedure Undo; override;
    function Description: string; override;
    function AbsorbNext(ANext: TDAWCommand): Boolean; override;
  end;

  TSetMixMeterConfigCommand = class(TMixerCommand)
  private
    FOldHoldMs, FOldDecayDb, FNewHoldMs, FNewDecayDb: Double;
  public
    constructor Create(ADoc: TProjectDocument; AHoldMs, ADecayDbPerSec: Double);
    function Execute: Boolean; override;
    procedure Undo; override;
    function Description: string; override;
  end;

implementation

uses
  Math;

function TrackForMixStrip(ADoc: TProjectDocument; AStripId: Integer): TTimelineTrack;
var
  s: TMixStrip;
begin
  Result := nil;
  if ADoc = nil then Exit;
  s := ADoc.Mixer.StripById(AStripId);
  { only the strip's real input link - never guess by id, or the master/bus
    strips could title an unrelated track that happens to share their id }
  if (s <> nil) and (s.InputSourceId > 0) then
    Result := ADoc.Timeline.TrackById(s.InputSourceId);
end;

{ ================= TMixerCommand ================= }

constructor TMixerCommand.Create(ADoc: TProjectDocument);
begin
  inherited Create;
  FDoc := ADoc;
  FTrackerSide := False;
end;

function TMixerCommand.M: TMixerModel;
begin
  if FTrackerSide then Result := FDoc.TrackerMixer else Result := FDoc.Mixer;
end;

procedure TMixerCommand.ReplaceM(AModel: TMixerModel);
begin
  if FTrackerSide then FDoc.ReplaceTrackerMixer(AModel) else FDoc.ReplaceMixer(AModel);
end;

procedure TMixerCommand.RequireValidRouting;
var
  err: string;
begin
  if not M.ValidateRouting(err) then
    RaiseUDAWFmt(errInvalidState, MIXER_SUBSYS, 'edit rejected: %s', [err]);
end;

{ ================= TMixerStructuralCommand ================= }

function TMixerStructuralCommand.Execute: Boolean;
begin
  FBefore := MixerToString(M);
  if not Mutate then
  begin
    { Mutate may have restored the model itself; make sure. }
    if MixerToString(M) <> FBefore then
      ReplaceM(MixerFromString(FBefore));
    Exit(False);
  end;
  FAfter := MixerToString(M);
  if FAfter = FBefore then Exit(False);
  FDoc.Touch;
  Result := True;
end;

procedure TMixerStructuralCommand.Undo;
begin
  ReplaceM(MixerFromString(FBefore));
  FDoc.Touch;
end;

function TMixerStructuralCommand.Redo: Boolean;
begin
  ReplaceM(MixerFromString(FAfter));
  FDoc.Touch;
  Result := True;
end;

{ ================= TAddMixStripCommand ================= }

constructor TAddMixStripCommand.Create(ADoc: TProjectDocument;
  AKind: TMixStripKind; const AName: string);
begin
  inherited Create(ADoc);
  FKind := AKind;
  FName := AName;
  FCreatedId := -1;
end;

function TAddMixStripCommand.Mutate: Boolean;
var
  s: TMixStrip;
begin
  if FKind = skMaster then
    RaiseUDAW(errInvalidState, MIXER_SUBSYS, 'a project has exactly one master strip');
  s := M.AddStrip(FKind, FName);
  FCreatedId := s.Id;
  FName := s.Name;
  Result := True;
end;

function TAddMixStripCommand.Description: string;
begin
  Result := Format('Add %s strip "%s"', [MixStripKindDisplay(FKind), FName]);
end;

{ ================= TRemoveMixStripCommand ================= }

constructor TRemoveMixStripCommand.Create(ADoc: TProjectDocument; AStripId: Integer);
begin
  inherited Create(ADoc);
  FStripId := AStripId;
end;

function TRemoveMixStripCommand.Mutate: Boolean;
var
  s: TMixStrip;
begin
  s := M.StripById(FStripId);
  if s = nil then Exit(False);
  if s.Kind = skMaster then
    RaiseUDAW(errInvalidState, MIXER_SUBSYS, 'the master strip cannot be removed');
  FName := s.Name;
  M.RemoveStrip(FStripId);
  Result := True;
end;

function TRemoveMixStripCommand.Description: string;
begin
  Result := Format('Remove strip "%s"', [FName]);
end;

{ ================= TSetMixStripRouteCommand ================= }

constructor TSetMixStripRouteCommand.Create(ADoc: TProjectDocument;
  AStripId, ANewTargetId: Integer);
begin
  inherited Create(ADoc);
  FStripId := AStripId;
  FNewTargetId := ANewTargetId;
end;

function TSetMixStripRouteCommand.Mutate: Boolean;
var
  s: TMixStrip;
  old: Integer;
  err: string;
begin
  s := M.StripById(FStripId);
  if s = nil then Exit(False);
  if s.Kind = skMaster then
    RaiseUDAW(errInvalidState, MIXER_SUBSYS, 'the master strip has no output target');
  old := s.OutputTargetId;
  if old = FNewTargetId then Exit(False);
  s.OutputTargetId := FNewTargetId;
  if not M.ValidateRouting(err) then
  begin
    s.OutputTargetId := old;
    RaiseUDAWFmt(errInvalidState, MIXER_SUBSYS, 'route rejected: %s', [err]);
  end;
  Result := True;
end;

function TSetMixStripRouteCommand.Description: string;
begin
  Result := Format('Route strip %d -> %d', [FStripId, FNewTargetId]);
end;

{ ================= TSetMixStripInputCommand ================= }

constructor TSetMixStripInputCommand.Create(ADoc: TProjectDocument;
  AStripId, ANewTrackId: Integer);
begin
  inherited Create(ADoc);
  FStripId := AStripId;
  FNewTrackId := ANewTrackId;
end;

function TSetMixStripInputCommand.Mutate: Boolean;
var
  s, other: TMixStrip;
  i: Integer;
begin
  s := M.StripById(FStripId);
  if s = nil then Exit(False);
  if s.Kind <> skAudioTrack then
    RaiseUDAW(errInvalidState, MIXER_SUBSYS, 'only an audio-track strip can be linked to a Timeline track');
  if s.InputSourceId = FNewTrackId then Exit(False);
  if FNewTrackId <> 0 then
    for i := 0 to M.StripCount - 1 do
    begin
      other := M.GetStrip(i);
      if (other.Id <> FStripId) and (other.InputSourceId = FNewTrackId) then
        RaiseUDAWFmt(errInvalidState, MIXER_SUBSYS,
          'track %d is already linked to strip "%s"', [FNewTrackId, other.Name]);
    end;
  s.InputSourceId := FNewTrackId;
  Result := True;
end;

function TSetMixStripInputCommand.Description: string;
begin
  Result := Format('Link strip %d to track %d', [FStripId, FNewTrackId]);
end;

{ ================= TMoveMixStripCommand ================= }

constructor TMoveMixStripCommand.Create(ADoc: TProjectDocument; AStripId, ANewIndex: Integer);
begin
  inherited Create(ADoc);
  FStripId := AStripId;
  FNewIndex := ANewIndex;
end;

function TMoveMixStripCommand.Mutate: Boolean;
begin
  if M.StripById(FStripId) = nil then Exit(False);
  M.MoveStrip(FStripId, FNewIndex);
  Result := True;
end;

function TMoveMixStripCommand.Description: string;
begin
  Result := Format('Reorder strip %d', [FStripId]);
end;

{ ================= TSetMixStripVCACommand ================= }

constructor TSetMixStripVCACommand.Create(ADoc: TProjectDocument; AStripId, AVCAId: Integer);
begin
  inherited Create(ADoc);
  FStripId := AStripId;
  FVCAId := AVCAId;
end;

function TSetMixStripVCACommand.Mutate: Boolean;
var
  s: TMixStrip;
  old: Integer;
  err: string;
begin
  s := M.StripById(FStripId);
  if s = nil then Exit(False);
  old := s.VCAGroupId;
  if old = FVCAId then Exit(False);
  s.VCAGroupId := FVCAId;
  if not M.ValidateRouting(err) then
  begin
    s.VCAGroupId := old;
    RaiseUDAWFmt(errInvalidState, MIXER_SUBSYS, 'VCA assignment rejected: %s', [err]);
  end;
  Result := True;
end;

function TSetMixStripVCACommand.Description: string;
begin
  Result := Format('Assign strip %d to VCA %d', [FStripId, FVCAId]);
end;

{ ================= TAddMixSendCommand ================= }

constructor TAddMixSendCommand.Create(ADoc: TProjectDocument; AStripId, ATargetId: Integer;
  AGainDb: Double; AMode: TMixSendMode);
begin
  inherited Create(ADoc);
  FStripId := AStripId;
  FTargetId := ATargetId;
  FGainDb := AGainDb;
  FMode := AMode;
end;

function TAddMixSendCommand.Mutate: Boolean;
var
  s, tgt: TMixStrip;
  err: string;
begin
  s := M.StripById(FStripId);
  tgt := M.StripById(FTargetId);
  if (s = nil) or (tgt = nil) then Exit(False);
  s.AddSend(FTargetId, FGainDb, FMode);
  if not M.ValidateRouting(err) then
  begin
    s.RemoveSend(FTargetId);
    RaiseUDAWFmt(errInvalidState, MIXER_SUBSYS, 'send rejected: %s', [err]);
  end;
  Result := True;
end;

function TAddMixSendCommand.Description: string;
begin
  Result := Format('Add send %d -> %d', [FStripId, FTargetId]);
end;

{ ================= TRemoveMixSendCommand ================= }

constructor TRemoveMixSendCommand.Create(ADoc: TProjectDocument; AStripId, ATargetId: Integer);
begin
  inherited Create(ADoc);
  FStripId := AStripId;
  FTargetId := ATargetId;
end;

function TRemoveMixSendCommand.Mutate: Boolean;
var
  s: TMixStrip;
begin
  s := M.StripById(FStripId);
  if (s = nil) or (s.SendToStrip(FTargetId) = nil) then Exit(False);
  s.RemoveSend(FTargetId);
  M.Automation.RemoveSend(FStripId, FTargetId);
  Result := True;
end;

function TRemoveMixSendCommand.Description: string;
begin
  Result := Format('Remove send %d -> %d', [FStripId, FTargetId]);
end;

{ ================= TAddMixInsertCommand ================= }

constructor TAddMixInsertCommand.Create(ADoc: TProjectDocument; AStripId: Integer;
  const AKind, AParams: string; AIndex: Integer; const AEffectName: string);
begin
  inherited Create(ADoc);
  FEffectName := AEffectName;
  FStripId := AStripId;
  FKind := AKind;
  FParams := AParams;
  FIndex := AIndex;
end;

function TAddMixInsertCommand.Mutate: Boolean;
var
  s: TMixStrip;
  actualIndex: Integer;
begin
  s := M.StripById(FStripId);
  if s = nil then Exit(False);
  if FIndex < 0 then
    s.AddInsert(TMixInsert.Make(FKind, FParams))
  else
  begin
    actualIndex := FIndex;
    if actualIndex < 0 then actualIndex := 0;
    if actualIndex > s.InsertCount then actualIndex := s.InsertCount;
    M.Automation.InsertInsert(FStripId, actualIndex);
    s.InsertInsertAt(FIndex, TMixInsert.Make(FKind, FParams));
  end;
  Result := True;
end;

function TAddMixInsertCommand.Execute: Boolean;
var
  t: TTimelineTrack;
  lbl: string;
begin
  if FTrackerSide then t := nil else t := TrackForMixStrip(FDoc, FStripId);
  if t <> nil then
  begin
    FTitleTrackId := t.Id;
    FOldTitle := t.Title;
  end
  else
    FTitleTrackId := -1;
  Result := inherited Execute;
  if Result and (t <> nil) then
  begin
    if FEffectName <> '' then lbl := FEffectName else lbl := FKind;
    if t.Title = '' then t.Title := lbl else t.Title := t.Title + ', ' + lbl;
  end;
end;

procedure TAddMixInsertCommand.Undo;
var
  t: TTimelineTrack;
begin
  inherited Undo;
  if FTitleTrackId < 0 then Exit;
  t := FDoc.Timeline.TrackById(FTitleTrackId);
  if t = nil then Exit;
  FRedoTitle := t.Title;
  FHaveRedoTitle := True;
  t.Title := FOldTitle;
end;

function TAddMixInsertCommand.Redo: Boolean;
var
  t: TTimelineTrack;
begin
  Result := inherited Redo;
  if (FTitleTrackId < 0) or not FHaveRedoTitle then Exit;
  t := FDoc.Timeline.TrackById(FTitleTrackId);
  if t <> nil then t.Title := FRedoTitle;
end;

function TAddMixInsertCommand.Description: string;
begin
  Result := Format('Add %s insert to strip %d', [FKind, FStripId]);
end;

{ ================= TRemoveMixInsertCommand ================= }

constructor TRemoveMixInsertCommand.Create(ADoc: TProjectDocument; AStripId, AIndex: Integer);
begin
  inherited Create(ADoc);
  FStripId := AStripId;
  FIndex := AIndex;
end;

function TRemoveMixInsertCommand.Mutate: Boolean;
var
  s: TMixStrip;
begin
  s := M.StripById(FStripId);
  if s = nil then Exit(False);
  if (FIndex < 0) or (FIndex >= s.InsertCount) then Exit(False);
  s.DeleteInsert(FIndex);
  M.Automation.RemoveInsert(FStripId, FIndex);
  Result := True;
end;

function TRemoveMixInsertCommand.Description: string;
begin
  Result := Format('Remove insert %d from strip %d', [FIndex, FStripId]);
end;

{ ================= TMoveMixInsertCommand ================= }

constructor TMoveMixInsertCommand.Create(ADoc: TProjectDocument;
  AStripId, AFromIndex, AToIndex: Integer);
begin
  inherited Create(ADoc);
  FStripId := AStripId;
  FFromIndex := AFromIndex;
  FToIndex := AToIndex;
end;

function TMoveMixInsertCommand.Mutate: Boolean;
var
  s: TMixStrip;
begin
  s := M.StripById(FStripId);
  if s = nil then Exit(False);
  if (FFromIndex < 0) or (FFromIndex >= s.InsertCount) then Exit(False);
  if FFromIndex = FToIndex then Exit(False);
  if FToIndex < 0 then FToIndex := 0;
  if FToIndex >= s.InsertCount then FToIndex := s.InsertCount - 1;
  s.MoveInsert(FFromIndex, FToIndex);
  M.Automation.MoveInsert(FStripId, FFromIndex, FToIndex);
  Result := True;
end;

function TMoveMixInsertCommand.Description: string;
begin
  Result := Format('Reorder insert %d -> %d on strip %d', [FFromIndex, FToIndex, FStripId]);
end;

{ ================= TSetMixInsertParamsCommand ================= }

constructor TSetMixInsertParamsCommand.Create(ADoc: TProjectDocument;
  AStripId, AIndex: Integer; const ANewParams: string);
begin
  inherited Create(ADoc);
  FStripId := AStripId;
  FIndex := AIndex;
  FNew := ANewParams;
end;

function TSetMixInsertParamsCommand.Execute: Boolean;
var
  s: TMixStrip;
  ins: TMixInsert;
begin
  s := M.StripById(FStripId);
  if s = nil then Exit(False);
  if (FIndex < 0) or (FIndex >= s.InsertCount) then Exit(False);
  ins := s.GetInsert(FIndex);
  FOld := ins.Params;
  if FOld = FNew then Exit(False);
  ins.Params := FNew;
  s.SetInsert(FIndex, ins);
  FDoc.Touch;
  Result := True;
end;

procedure TSetMixInsertParamsCommand.Undo;
var
  s: TMixStrip;
  ins: TMixInsert;
begin
  s := M.StripById(FStripId);
  if (s = nil) or (FIndex < 0) or (FIndex >= s.InsertCount) then Exit;
  ins := s.GetInsert(FIndex);
  ins.Params := FOld;
  s.SetInsert(FIndex, ins);
  FDoc.Touch;
end;

function TSetMixInsertParamsCommand.Description: string;
begin
  Result := Format('Change insert %d parameters on strip %d', [FIndex, FStripId]);
end;

function TSetMixInsertParamsCommand.AbsorbNext(ANext: TDAWCommand): Boolean;
var
  nx: TSetMixInsertParamsCommand;
  s: TMixStrip;
  ins: TMixInsert;
begin
  Result := (ANext is TSetMixInsertParamsCommand);
  if not Result then Exit;
  nx := TSetMixInsertParamsCommand(ANext);
  Result := (nx.FDoc = FDoc) and (nx.TrackerSide = TrackerSide) and (nx.FStripId = FStripId) and (nx.FIndex = FIndex)
    and (MsSinceStamp <= COMMAND_MERGE_WINDOW_MS);
  if Result then
  begin
    FNew := nx.FNew;
    s := M.StripById(FStripId);
    if (s <> nil) and (FIndex < s.InsertCount) then
    begin
      ins := s.GetInsert(FIndex);
      ins.Params := FNew;
      s.SetInsert(FIndex, ins);
    end;
    FDoc.Touch;
    Restamp;
  end;
end;

{ ================= TSetMixInsertSidechainCommand ================= }

constructor TSetMixInsertSidechainCommand.Create(ADoc: TProjectDocument;
  AStripId, AIndex, ANewSidechainStripId: Integer);
begin
  inherited Create(ADoc);
  FStripId := AStripId;
  FIndex := AIndex;
  FNew := ANewSidechainStripId;
end;

function TSetMixInsertSidechainCommand.Execute: Boolean;
var
  s: TMixStrip;
  ins: TMixInsert;
begin
  s := M.StripById(FStripId);
  if s = nil then Exit(False);
  if (FIndex < 0) or (FIndex >= s.InsertCount) then Exit(False);
  ins := s.GetInsert(FIndex);
  FOld := ins.SidechainStripId;
  if FOld = FNew then Exit(False);
  ins.SidechainStripId := FNew;
  s.SetInsert(FIndex, ins);
  FDoc.Touch;
  Result := True;
end;

procedure TSetMixInsertSidechainCommand.Undo;
var
  s: TMixStrip;
  ins: TMixInsert;
begin
  s := M.StripById(FStripId);
  if (s = nil) or (FIndex < 0) or (FIndex >= s.InsertCount) then Exit;
  ins := s.GetInsert(FIndex);
  ins.SidechainStripId := FOld;
  s.SetInsert(FIndex, ins);
  FDoc.Touch;
end;

function TSetMixInsertSidechainCommand.Description: string;
begin
  Result := Format('Change insert %d sidechain source on strip %d', [FIndex, FStripId]);
end;

{ ================= TAddAutomationPointCommand ================= }

constructor TAddAutomationPointCommand.Create(ADoc: TProjectDocument; AStripId: Integer;
  AParam: TAutomationParam; ATimeSeconds, AValue: Double; ATargetIndex,
  ASubIndex: Integer);
begin
  inherited Create(ADoc);
  FStripId := AStripId;
  FParam := AParam;
  FTargetIndex := ATargetIndex;
  FSubIndex := ASubIndex;
  FTimeSeconds := ATimeSeconds;
  FValue := AValue;
end;

function TAddAutomationPointCommand.Mutate: Boolean;
begin
  if M.StripById(FStripId) = nil then Exit(False);
  M.Automation.LaneFor(FStripId, FParam, True, FTargetIndex, FSubIndex)
    .AddPoint(FTimeSeconds, FValue);
  Result := True;
end;

function TAddAutomationPointCommand.Description: string;
begin
  Result := Format('Add %s automation point on strip %d', [AutomationParamId(FParam), FStripId]);
end;

function TAddAutomationPointCommand.AbsorbNext(ANext: TDAWCommand): Boolean;
var
  nx: TAddAutomationPointCommand;
begin
  { A drag while writing automation (see the Mixer tab's record-mode capture)
    lands many points close together in time - collapse a burst into the
    single most recent point rather than leaving a point per mouse-move. }
  Result := (ANext is TAddAutomationPointCommand);
  if not Result then Exit;
  nx := TAddAutomationPointCommand(ANext);
  Result := (nx.FDoc = FDoc) and (nx.TrackerSide = TrackerSide) and (nx.FStripId = FStripId) and (nx.FParam = FParam)
    and (nx.FTargetIndex = FTargetIndex) and (nx.FSubIndex = FSubIndex)
    and (Abs(nx.FTimeSeconds - FTimeSeconds) < 0.25) and (MsSinceStamp <= COMMAND_MERGE_WINDOW_MS);
  if Result then
  begin
    FTimeSeconds := nx.FTimeSeconds;
    FValue := nx.FValue;
    M.Automation.LaneFor(FStripId, FParam, True, FTargetIndex, FSubIndex)
      .AddPoint(FTimeSeconds, FValue);
    FDoc.Touch;
    Restamp;
  end;
end;

{ ================= TRemoveAutomationPointCommand ================= }

constructor TRemoveAutomationPointCommand.Create(ADoc: TProjectDocument; AStripId: Integer;
  AParam: TAutomationParam; ATimeSeconds, AToleranceSeconds: Double;
  ATargetIndex, ASubIndex: Integer);
begin
  inherited Create(ADoc);
  FStripId := AStripId;
  FParam := AParam;
  FTargetIndex := ATargetIndex;
  FSubIndex := ASubIndex;
  FTimeSeconds := ATimeSeconds;
  FToleranceSeconds := AToleranceSeconds;
end;

function TRemoveAutomationPointCommand.Mutate: Boolean;
var
  lane: TAutomationLane;
  oldCount: Integer;
begin
  lane := M.Automation.LaneFor(FStripId, FParam, False, FTargetIndex, FSubIndex);
  if (lane = nil) or (lane.PointCount = 0) then Exit(False);
  oldCount := lane.PointCount;
  lane.RemoveNear(FTimeSeconds, FToleranceSeconds);
  Result := lane.PointCount <> oldCount;
end;

function TRemoveAutomationPointCommand.Description: string;
begin
  Result := Format('Remove %s automation point on strip %d', [AutomationParamId(FParam), FStripId]);
end;

{ ================= TClearAutomationLaneCommand ================= }

constructor TClearAutomationLaneCommand.Create(ADoc: TProjectDocument; AStripId: Integer;
  AParam: TAutomationParam; ATargetIndex, ASubIndex: Integer);
begin
  inherited Create(ADoc);
  FStripId := AStripId;
  FParam := AParam;
  FTargetIndex := ATargetIndex;
  FSubIndex := ASubIndex;
end;

function TClearAutomationLaneCommand.Mutate: Boolean;
var
  lane: TAutomationLane;
begin
  lane := M.Automation.LaneFor(FStripId, FParam, False, FTargetIndex, FSubIndex);
  if (lane = nil) or (lane.PointCount = 0) then Exit(False);
  lane.Clear;
  Result := True;
end;

function TClearAutomationLaneCommand.Description: string;
begin
  Result := Format('Clear %s automation on strip %d', [AutomationParamId(FParam), FStripId]);
end;

{ ================= TSetMixStripFloatCommand ================= }

constructor TSetMixStripFloatCommand.Create(ADoc: TProjectDocument; AStripId: Integer;
  AField: TMixFloatField; ANewValue: Double);
begin
  inherited Create(ADoc);
  FStripId := AStripId;
  FField := AField;
  FNew := ANewValue;
end;

function TSetMixStripFloatCommand.Current: Double;
var
  s: TMixStrip;
begin
  Result := 0;
  s := M.StripById(FStripId);
  if s = nil then Exit;
  case FField of
    mffFader: Result := s.FaderDb;
    mffPan:   Result := s.Pan;
    mffTrim:  Result := s.TrimGainDb;
    mffWidth: Result := s.StereoWidth;
  end;
end;

procedure TSetMixStripFloatCommand.Apply(AValue: Double);
var
  s: TMixStrip;
begin
  s := M.StripById(FStripId);
  if s = nil then Exit;
  case FField of
    mffFader: s.FaderDb := AValue;
    mffPan:   s.Pan := AValue;
    mffTrim:  s.TrimGainDb := AValue;
    mffWidth: s.StereoWidth := AValue;
  end;
end;

function TSetMixStripFloatCommand.Execute: Boolean;
begin
  if M.StripById(FStripId) = nil then Exit(False);
  FOld := Current;
  Apply(FNew);
  if SameValue(Current, FOld, 1.0E-12) then Exit(False);
  FDoc.Touch;
  Result := True;
end;

procedure TSetMixStripFloatCommand.Undo;
begin
  Apply(FOld);
  FDoc.Touch;
end;

function TSetMixStripFloatCommand.Description: string;
const
  N: array[TMixFloatField] of string = ('fader', 'pan', 'trim', 'width');
begin
  Result := Format('Set strip %d %s', [FStripId, N[FField]]);
end;

function TSetMixStripFloatCommand.AbsorbNext(ANext: TDAWCommand): Boolean;
var
  nx: TSetMixStripFloatCommand;
begin
  Result := (ANext is TSetMixStripFloatCommand);
  if not Result then Exit;
  nx := TSetMixStripFloatCommand(ANext);
  Result := (nx.FDoc = FDoc) and (nx.TrackerSide = TrackerSide) and (nx.FStripId = FStripId) and (nx.FField = FField)
    and (MsSinceStamp <= COMMAND_MERGE_WINDOW_MS);
  if Result then
  begin
    FNew := nx.FNew;
    Apply(FNew);
    FDoc.Touch;
    Restamp;
  end;
end;

{ ================= TSetMixStripFlagCommand ================= }

constructor TSetMixStripFlagCommand.Create(ADoc: TProjectDocument; AStripId: Integer;
  AField: TMixFlagField; ANewValue: Boolean);
begin
  inherited Create(ADoc);
  FStripId := AStripId;
  FField := AField;
  FNew := ANewValue;
end;

function TSetMixStripFlagCommand.Current: Boolean;
var
  s: TMixStrip;
begin
  Result := False;
  s := M.StripById(FStripId);
  if s = nil then Exit;
  case FField of
    mfgMute:      Result := s.Muted;
    mfgSolo:      Result := s.Soloed;
    mfgPolarity:  Result := s.PolarityInvert;
    mfgArm:       Result := s.RecordArmed;
  end;
end;

procedure TSetMixStripFlagCommand.Apply(AValue: Boolean);
var
  s: TMixStrip;
begin
  s := M.StripById(FStripId);
  if s = nil then Exit;
  case FField of
    mfgMute:      s.Muted := AValue;
    mfgSolo:      s.Soloed := AValue;
    mfgPolarity:  s.PolarityInvert := AValue;
    mfgArm:       s.RecordArmed := AValue;
  end;
end;

function TSetMixStripFlagCommand.Execute: Boolean;
begin
  if M.StripById(FStripId) = nil then Exit(False);
  FOld := Current;
  if FOld = FNew then Exit(False);
  Apply(FNew);
  FDoc.Touch;
  Result := True;
end;

procedure TSetMixStripFlagCommand.Undo;
begin
  Apply(FOld);
  FDoc.Touch;
end;

function TSetMixStripFlagCommand.Description: string;
const
  N: array[TMixFlagField] of string = ('mute', 'solo', 'polarity', 'record-arm');
begin
  Result := Format('Toggle strip %d %s', [FStripId, N[FField]]);
end;

{ ================= TSetMixStripAutoModeCommand ================= }

constructor TSetMixStripAutoModeCommand.Create(ADoc: TProjectDocument; AStripId: Integer;
  ANewMode: TMixAutomationMode);
begin
  inherited Create(ADoc);
  FStripId := AStripId;
  FNew := ANewMode;
end;

function TSetMixStripAutoModeCommand.Execute: Boolean;
var
  s: TMixStrip;
begin
  s := M.StripById(FStripId);
  if s = nil then Exit(False);
  FOld := s.AutomationMode;
  if FOld = FNew then Exit(False);
  s.AutomationMode := FNew;
  FDoc.Touch;
  Result := True;
end;

procedure TSetMixStripAutoModeCommand.Undo;
var
  s: TMixStrip;
begin
  s := M.StripById(FStripId);
  if s = nil then Exit;
  s.AutomationMode := FOld;
  FDoc.Touch;
end;

function TSetMixStripAutoModeCommand.Description: string;
begin
  Result := Format('Set strip %d automation mode', [FStripId]);
end;

{ ================= TSetMixSendGainCommand ================= }

constructor TSetMixSendGainCommand.Create(ADoc: TProjectDocument; AStripId, ATargetId: Integer;
  ANewGainDb: Double);
begin
  inherited Create(ADoc);
  FStripId := AStripId;
  FTargetId := ATargetId;
  FNew := ANewGainDb;
end;

function TSetMixSendGainCommand.Execute: Boolean;
var
  s: TMixStrip;
  snd: TMixSend;
begin
  s := M.StripById(FStripId);
  if s = nil then Exit(False);
  snd := s.SendToStrip(FTargetId);
  if snd = nil then Exit(False);
  FOld := snd.GainDb;
  if SameValue(FOld, FNew, 1.0E-12) then Exit(False);
  snd.GainDb := FNew;
  FDoc.Touch;
  Result := True;
end;

procedure TSetMixSendGainCommand.Undo;
var
  s: TMixStrip;
  snd: TMixSend;
begin
  s := M.StripById(FStripId);
  if s = nil then Exit;
  snd := s.SendToStrip(FTargetId);
  if snd <> nil then
  begin
    snd.GainDb := FOld;
    FDoc.Touch;
  end;
end;

function TSetMixSendGainCommand.Description: string;
begin
  Result := Format('Set send %d -> %d gain', [FStripId, FTargetId]);
end;

function TSetMixSendGainCommand.AbsorbNext(ANext: TDAWCommand): Boolean;
var
  nx: TSetMixSendGainCommand;
  s: TMixStrip;
  snd: TMixSend;
begin
  Result := (ANext is TSetMixSendGainCommand);
  if not Result then Exit;
  nx := TSetMixSendGainCommand(ANext);
  Result := (nx.FDoc = FDoc) and (nx.TrackerSide = TrackerSide) and (nx.FStripId = FStripId) and (nx.FTargetId = FTargetId)
    and (MsSinceStamp <= COMMAND_MERGE_WINDOW_MS);
  if Result then
  begin
    FNew := nx.FNew;
    s := M.StripById(FStripId);
    if s <> nil then
    begin
      snd := s.SendToStrip(FTargetId);
      if snd <> nil then snd.GainDb := FNew;
    end;
    FDoc.Touch;
    Restamp;
  end;
end;

{ ================= TSetMixMeterConfigCommand ================= }

constructor TSetMixMeterConfigCommand.Create(ADoc: TProjectDocument;
  AHoldMs, ADecayDbPerSec: Double);
begin
  inherited Create(ADoc);
  FNewHoldMs := AHoldMs;
  FNewDecayDb := ADecayDbPerSec;
end;

function TSetMixMeterConfigCommand.Execute: Boolean;
begin
  FOldHoldMs := M.MeterHoldMs;
  FOldDecayDb := M.MeterHoldDecayDbPerSec;
  M.MeterHoldMs := FNewHoldMs;
  M.MeterHoldDecayDbPerSec := FNewDecayDb;
  Result := (not SameValue(FOldHoldMs, M.MeterHoldMs, 1.0E-12)) or
    (not SameValue(FOldDecayDb, M.MeterHoldDecayDbPerSec, 1.0E-12));
  if Result then FDoc.Touch;
end;

procedure TSetMixMeterConfigCommand.Undo;
begin
  M.MeterHoldMs := FOldHoldMs;
  M.MeterHoldDecayDbPerSec := FOldDecayDb;
  FDoc.Touch;
end;

function TSetMixMeterConfigCommand.Description: string;
begin
  Result := 'Set mixer peak-hold timing';
end;

end.
