unit UDAW.UI.InstrumentEditor;
{$I udaw.inc}

{ The instrument editor / audio file editor: opened by a double-click on a drum pad's instrument
  panel (the pad's sound), or - EditFile - by a double-click on a Timeline clip (the clip's WAV). The pad's
  sound is shown large on the GL canvas; drag across it to mark a region (drag the region's
  edges to trim it), then trim, cut, silence, reverse, normalise, fade, change the level,
  add silence after it, stretch it or apply any effect to it - the effect opens the effect
  editor, which shows the region before and after the effect while its knobs are turned.

  The work happens on a copy of the sound. Audition plays the copy through the pad itself;
  OK writes it to a new WAV in the folder the caller gives (the original file is never
  touched) and leaves the pad holding it; Cancel puts the original sound back. Every edit can
  be undone. }

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.Math, System.Types,
  System.Generics.Collections, System.StrUtils, Vcl.Controls, Vcl.Forms, Vcl.Graphics,
  Winapi.MMSystem, UDAW.Audio.Types, UDAW.Drum.Machine, UDAW.GL.Canvas, UDAW.GL.Controls, UDAW.GL.Widgets,
  UDAW.Timeline.FxPresets, UDAW.UI.FileDialog;

type
  TfrmInstrumentEditor = class(TForm)
    lblTitle: TGLLabel;
    lblInfo: TGLLabel;
    pbWave: TGLView;
    sbWave: TGLScrollBar;
    lblSel: TGLLabel;
    ibTransport: TGLIconBar;   // play, stop, undo
    ibView: TGLIconBar;        // select all, zoom in, zoom out, zoom to region, fit
    ibEdit: TGLIconBar;        // trim, cut, silence, reverse, normalise, fade in, fade out
    ibEffects: TGLIconBar;     // edit and apply the chosen effect
    ibFile: TGLIconBar;        // save the audio to disk; loop on the Timeline (clip editing only)
    dlgSaveWav: TGLSaveDialog;
    grpRegion: TGLGroup;
    knobGain: TGLKnob;
    ibGain: TGLIconBar;
    knobExtend: TGLKnob;
    ibExtend: TGLIconBar;
    knobStretch: TGLKnob;
    ibStretch: TGLIconBar;
    grpFx: TGLGroup;
    edtFilter: TGLEdit;
    lstFx: TGLList;
    lblHint: TGLLabel;
    ibDialog: TGLIconBar;      // OK, cancel
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure pbWavePaint(Sender: TObject);
    procedure pbWaveMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure pbWaveMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    procedure pbWaveMouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure pbWaveDblClick(Sender: TObject);
    procedure pbWaveMouseWheel(Sender: TObject; Shift: TShiftState; WheelDelta: Integer;
      MousePos: TPoint; var Handled: Boolean);
    procedure sbWaveChange(Sender: TObject);
    procedure ToolClick(Sender: TObject; AIndex: Integer; const AId: string);
    procedure DialogClick(Sender: TObject; AIndex: Integer; const AId: string);
    procedure FileToolClick(Sender: TObject; AIndex: Integer; const AId: string);
    procedure btnPlayClick(Sender: TObject);
    procedure btnStopClick(Sender: TObject);
    procedure btnUndoClick(Sender: TObject);
    procedure btnSelAllClick(Sender: TObject);
    procedure btnZoomInClick(Sender: TObject);
    procedure btnZoomOutClick(Sender: TObject);
    procedure btnZoomSelClick(Sender: TObject);
    procedure btnFitClick(Sender: TObject);
    procedure btnTrimClick(Sender: TObject);
    procedure btnCutClick(Sender: TObject);
    procedure btnSilenceClick(Sender: TObject);
    procedure btnReverseClick(Sender: TObject);
    procedure btnNormalizeClick(Sender: TObject);
    procedure btnFadeInClick(Sender: TObject);
    procedure btnFadeOutClick(Sender: TObject);
    procedure btnGainClick(Sender: TObject);
    procedure btnExtendClick(Sender: TObject);
    procedure btnStretchClick(Sender: TObject);
    procedure edtFilterChange(Sender: TObject);
    procedure lstFxDblClick(Sender: TObject);
    procedure btnFxClick(Sender: TObject);
    procedure btnOKClick(Sender: TObject);
    procedure btnCancelClick(Sender: TObject);
  private
    const
      RULER_H = 20;
      EDGE_PX = 6;
      UNDO_LIMIT = 30;
    var
    FMachine: TDrumMachine;
    FFileMode: Boolean;        // editing a WAV file (a Timeline clip), not a drum pad
    FLoop: Boolean;            // the clip repeats on the Timeline until the last segment
    FShowLoop: Boolean;
    FAuditionPath: string;     // file mode: where the region being heard is written
    FFileTitle: string;
    FNote: Integer;
    FWaveColor: TColor;
    FData: TAudioPlanar;       // the sound being edited
    FOrig: TAudioPlanar;       // the sound the pad held when the window opened
    FOrigPath: string;
    FRate: Integer;
    FUndo: TList<TAudioPlanar>;
    FModified: Boolean;
    FSelA, FSelB: Integer;     // marked region in frames, -1 = none; A < B when set
    FViewStart, FViewLen: Integer;
    FDrag: Integer;            // 0 none, 1 moving edge A, 2 moving edge B, 3 marking
    FAnchor: Integer;
    FFx: TArray<TFxPresetInfo>;
    FShown: TArray<Integer>;   // list row -> FFx index
    FPreviewKind: string;
    FPreviewA, FPreviewB: Integer;
    function Frames: Integer;
    function Channels: Integer;
    function HasSel: Boolean;
    function EditRange(out AFrom, ATo: Integer): Boolean;
    function RequireSel(out AFrom, ATo: Integer): Boolean;
    function XToFrame(AX: Integer): Integer;
    function FrameToX(AFrame: Integer): Integer;
    function Slice(AFrom, ATo: Integer): TAudioPlanar;
    procedure PushUndo;
    procedure Changed(AKeepView: Boolean = True);
    procedure UpdateView;
    procedure UpdateReadout;
    procedure SetView(AStart, ALen: Integer);
    procedure ZoomBy(AFactor: Double; ACenterFrame: Integer);
    procedure Note(const AMsg: string);
    procedure FillEffectList;
    procedure Audition(const AData: TAudioPlanar);
    procedure FxAudition(const AParams: string);
    procedure ApplyEffect(const AName, AKind, AParams: string; AFrom, ATo: Integer);
    function SaveEdited(const AOutDir: string; out APath: string): Boolean;
    procedure StopAudition;
    procedure RestoreOriginal;
    procedure SaveToDisk;
    procedure UpdateFileBar;
    class function EditFileCore(AOwner: TComponent; const ATitle, AWavPath: string; AColor: TColor;
      const AOutDir: string; AShowLoop: Boolean; var ALoop: Boolean; out ALoopChanged: Boolean;
      out ANewPath: string): Boolean;
  public
    { Opens the editor for the sound on pad ANote of AMachine. Returns True when the sound was
      changed and the user pressed OK: the pad then holds the edited sound, which has been
      written to AOutDir as ANewPath. Otherwise the pad is exactly as it was. }
    class function Edit(AOwner: TComponent; AMachine: TDrumMachine; ANote: Integer;
      AColor: TColor; const AOutDir: string; out ANewPath: string): Boolean;
    { Opens the editor on the WAV file AWavPath (a Timeline clip's audio). Heard through the
      system audio output. Returns True when the audio was changed and the user pressed OK: the
      edited audio has been written to AOutDir as ANewPath (the original file is never touched).
      Cancel, or OK with no edit, returns False. }
    class function EditFile(AOwner: TComponent; const ATitle, AWavPath: string; AColor: TColor;
      const AOutDir: string; out ANewPath: string): Boolean;
    { As EditFile for a Timeline clip, with the Loop icon shown: ALoop is whether the clip repeats
      until the last segment of the Timeline. Returns True when the audio was edited (ANewPath is
      then the new WAV) or ALoop was changed (ANewPath is '' when only the loop flag changed). }
    class function EditFileLoop(AOwner: TComponent; const ATitle, AWavPath: string; AColor: TColor;
      const AOutDir: string; var ALoop: Boolean; out ANewPath: string): Boolean;
  end;

implementation

uses UDAW.DSP.MathTables,
  UDAW.Codec.WAV, UDAW.DSP.TimeStretch, UDAW.UI.EffectEditor, UDAW.Timeline.OfflineFx;

{$R *.dfm}

function CopyPlanar(const AData: TAudioPlanar): TAudioPlanar;
var
  c: Integer;
begin
  SetLength(Result, Length(AData));
  for c := 0 to High(AData) do Result[c] := Copy(AData[c]);
end;

function SafeFileName(const AText: string): string;
var
  i: Integer;
begin
  Result := Trim(AText);
  for i := 1 to Length(Result) do
    if CharInSet(Result[i], ['\', '/', ':', '*', '?', '"', '<', '>', '|', ' ']) then Result[i] := '_';
  if Result = '' then Result := 'sound';
end;

{ TfrmInstrumentEditor }

class function TfrmInstrumentEditor.Edit(AOwner: TComponent; AMachine: TDrumMachine;
  ANote: Integer; AColor: TColor; const AOutDir: string; out ANewPath: string): Boolean;
var
  frm: TfrmInstrumentEditor;
  smp: TDrumSample;
begin
  Result := False;
  ANewPath := '';
  if (AMachine = nil) or not AMachine.HasSample(ANote) then Exit;
  smp := AMachine.Pads[ANote].Sample;
  frm := TfrmInstrumentEditor.Create(AOwner);
  try
    frm.FMachine := AMachine;
    frm.FNote := ANote;
    frm.FWaveColor := AColor;
    frm.FRate := smp.Rate;
    frm.FOrigPath := smp.Path;
    frm.FOrig := CopyPlanar(smp.Data);
    SetLength(frm.FOrig, smp.Channels);
    frm.FData := CopyPlanar(frm.FOrig);
    frm.FSelA := -1;
    frm.FSelB := -1;
    frm.FFx := FxExtraPresets + FxPresetList;
    frm.FillEffectList;
    frm.Caption := Format('Instrument editor - %s  %s', [DrumNoteName(ANote), AMachine.Pads[ANote].Name]);
    frm.lblTitle.Caption := Format('%s   MIDI %d   %s', [DrumNoteName(ANote), ANote,
      AMachine.Pads[ANote].Name]);
    frm.UpdateView;
    frm.SetView(0, frm.Frames);
    if frm.ShowModal = mrOk then
    begin
      if frm.FModified then
        Result := frm.SaveEdited(AOutDir, ANewPath);
      if not Result then frm.RestoreOriginal;
    end
    else
      frm.RestoreOriginal;
    AMachine.StopPad(ANote);
  finally
    frm.FUndo.Free;
    frm.Free;
  end;
end;

class function TfrmInstrumentEditor.EditFile(AOwner: TComponent; const ATitle, AWavPath: string;
  AColor: TColor; const AOutDir: string; out ANewPath: string): Boolean;
var
  loopFlag, loopChanged: Boolean;
begin
  loopFlag := False;
  Result := EditFileCore(AOwner, ATitle, AWavPath, AColor, AOutDir, False, loopFlag, loopChanged, ANewPath);
end;

class function TfrmInstrumentEditor.EditFileLoop(AOwner: TComponent; const ATitle, AWavPath: string;
  AColor: TColor; const AOutDir: string; var ALoop: Boolean; out ANewPath: string): Boolean;
var
  loopChanged: Boolean;
begin
  Result := EditFileCore(AOwner, ATitle, AWavPath, AColor, AOutDir, True, ALoop, loopChanged, ANewPath);
  if loopChanged then Result := True;
end;

class function TfrmInstrumentEditor.EditFileCore(AOwner: TComponent; const ATitle, AWavPath: string;
  AColor: TColor; const AOutDir: string; AShowLoop: Boolean; var ALoop: Boolean;
  out ALoopChanged: Boolean; out ANewPath: string): Boolean;
var
  frm: TfrmInstrumentEditor;
  ch, sr: Integer;
begin
  Result := False;
  ALoopChanged := False;
  ANewPath := '';
  if not FileExists(AWavPath) then Exit;
  frm := TfrmInstrumentEditor.Create(AOwner);
  try
    frm.FFileMode := True;
    frm.FShowLoop := AShowLoop;
    frm.FLoop := ALoop;
    frm.FFileTitle := ATitle;
    frm.FWaveColor := AColor;
    frm.FOrigPath := AWavPath;
    frm.FOrig := LoadWavFile(AWavPath, ch, sr);
    frm.FRate := sr;
    if (Length(frm.FOrig) = 0) or (Length(frm.FOrig[0]) < 2) or (sr <= 0) then Exit;
    frm.FData := CopyPlanar(frm.FOrig);
    frm.FAuditionPath := IncludeTrailingPathDelimiter(AOutDir) + 'audition.wav';
    ForceDirectories(ExtractFilePath(frm.FAuditionPath));
    frm.FSelA := -1;
    frm.FSelB := -1;
    frm.FFx := FxExtraPresets + FxPresetList;
    frm.FillEffectList;
    frm.Caption := 'Audio file editor - ' + ATitle;
    frm.lblTitle.Caption := ATitle;
    frm.UpdateView;
    frm.SetView(0, frm.Frames);
    frm.UpdateFileBar;
    if frm.ShowModal = mrOk then
    begin
      if frm.FLoop <> ALoop then
      begin
        ALoop := frm.FLoop;
        ALoopChanged := True;
      end;
      if frm.FModified then Result := frm.SaveEdited(AOutDir, ANewPath);
    end;
    frm.StopAudition;
    DeleteFile(frm.FAuditionPath);
  finally
    frm.FUndo.Free;
    frm.Free;
  end;
end;

procedure TfrmInstrumentEditor.FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if ActiveControl is TGLEdit then Exit;
  case Key of
    VK_ESCAPE: btnCancelClick(nil);
    VK_RETURN: btnOKClick(nil);
    VK_DELETE: btnCutClick(nil);
    VK_SPACE: btnPlayClick(nil);
    Ord('Z'):
      if ssCtrl in Shift then btnUndoClick(nil);
    Ord('A'):
      if ssCtrl in Shift then btnSelAllClick(nil);
  else
    Exit;
  end;
  Key := 0;
end;

function TfrmInstrumentEditor.Frames: Integer;
begin
  if Length(FData) > 0 then Result := Length(FData[0]) else Result := 0;
end;

function TfrmInstrumentEditor.Channels: Integer;
begin
  Result := Length(FData);
end;

function TfrmInstrumentEditor.HasSel: Boolean;
begin
  Result := (FSelA >= 0) and (FSelB > FSelA);
end;

{ the marked region, or the whole sound when nothing is marked }
function TfrmInstrumentEditor.EditRange(out AFrom, ATo: Integer): Boolean;
begin
  if HasSel then
  begin
    AFrom := FSelA;
    ATo := Min(FSelB, Frames);
  end
  else
  begin
    AFrom := 0;
    ATo := Frames;
  end;
  Result := ATo - AFrom >= 2;
end;

function TfrmInstrumentEditor.RequireSel(out AFrom, ATo: Integer): Boolean;
begin
  AFrom := 0;
  ATo := 0;
  Result := HasSel;
  if Result then
  begin
    AFrom := FSelA;
    ATo := Min(FSelB, Frames);
  end
  else
    Note('Drag across the waveform to mark a region first.');
end;

function TfrmInstrumentEditor.Slice(AFrom, ATo: Integer): TAudioPlanar;
var
  c: Integer;
begin
  SetLength(Result, Channels);
  for c := 0 to Channels - 1 do Result[c] := Copy(FData[c], AFrom, ATo - AFrom);
end;

procedure TfrmInstrumentEditor.Note(const AMsg: string);
begin
  lblHint.Caption := AMsg;
end;

procedure TfrmInstrumentEditor.PushUndo;
begin
  if FUndo = nil then FUndo := TList<TAudioPlanar>.Create;
  FUndo.Add(CopyPlanar(FData));
  if FUndo.Count > UNDO_LIMIT then FUndo.Delete(0);
  ibTransport.SetButtonEnabled(2, True);
end;

{ call after the sound was edited }
procedure TfrmInstrumentEditor.Changed(AKeepView: Boolean);
begin
  FModified := True;
  if FSelB > Frames then FSelB := Frames;
  if FSelA >= FSelB then
  begin
    FSelA := -1;
    FSelB := -1;
  end;
  UpdateView;
  if not AKeepView then SetView(0, Frames);
  UpdateReadout;
  pbWave.Invalidate;
end;

procedure TfrmInstrumentEditor.UpdateView;
begin
  if FViewLen < 16 then FViewLen := Max(16, Frames);
  FViewLen := EnsureRange(FViewLen, Min(16, Max(1, Frames)), Max(1, Frames));
  FViewStart := EnsureRange(FViewStart, 0, Max(0, Frames - FViewLen));
  sbWave.PageSize := FViewLen;
  sbWave.SetParams(FViewStart, 0, Max(1, Frames));
  ibTransport.SetButtonEnabled(2, (FUndo <> nil) and (FUndo.Count > 0));
end;

procedure TfrmInstrumentEditor.SetView(AStart, ALen: Integer);
begin
  FViewLen := ALen;
  FViewStart := AStart;
  UpdateView;
  pbWave.Invalidate;
end;

procedure TfrmInstrumentEditor.ZoomBy(AFactor: Double; ACenterFrame: Integer);
var
  newLen, newStart: Integer;
  rel: Double;
begin
  if Frames < 2 then Exit;
  newLen := EnsureRange(Round(FViewLen * AFactor), Min(16, Frames), Frames);
  if FViewLen > 0 then rel := (ACenterFrame - FViewStart) / FViewLen else rel := 0.5;
  newStart := ACenterFrame - Round(rel * newLen);
  SetView(newStart, newLen);
end;

procedure TfrmInstrumentEditor.UpdateReadout;
var
  dur: string;
begin
  lblInfo.Caption := Format('%.0f ms   %d Hz   %s   %d frames%s', [Frames / FRate * 1000, FRate,
    IfThen(Channels > 1, 'stereo', 'mono'), Frames, IfThen(FModified, '   (edited)', '')]);
  if HasSel then
  begin
    dur := Format('%.1f ms', [(FSelB - FSelA) / FRate * 1000]);
    lblSel.Caption := Format('Marked: %.1f ms to %.1f ms   (%s)   - effects and edits apply to this region',
      [FSelA / FRate * 1000, FSelB / FRate * 1000, dur]);
  end
  else
    lblSel.Caption := 'Nothing marked - edits apply to the whole sound. Drag on the waveform to mark a region; double-click marks all.';
end;

function TfrmInstrumentEditor.XToFrame(AX: Integer): Integer;
begin
  Result := EnsureRange(FViewStart + Round(AX / Max(1, pbWave.Width) * FViewLen), 0, Frames);
end;

function TfrmInstrumentEditor.FrameToX(AFrame: Integer): Integer;
begin
  Result := Round((AFrame - FViewStart) / Max(1, FViewLen) * pbWave.Width);
end;

{ ---- drawing ---- }

procedure TfrmInstrumentEditor.pbWavePaint(Sender: TObject);
const
  STEPS_MS: array[0..13] of Integer = (1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 30000);
var
  cv: TGLCanvas;
  w, h, x, lanes, lane, laneH, mid, c, f0, f1, f, stp, stepMs, i, x1, x2: Integer;
  lo, hi, v, t, pxMs: Double;
begin
  cv := pbWave.GL;
  w := pbWave.Width;
  h := pbWave.Height;
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
  cv.Brush.Color := $181818;
  cv.FillRect(Rect(0, 0, w, h));
  cv.Font.Size := 8;
  if (Frames < 2) or (FViewLen < 1) then Exit;
  { marked region behind the waveform }
  if HasSel then
  begin
    x1 := Max(0, FrameToX(FSelA));
    x2 := Min(w, FrameToX(FSelB));
    if x2 > x1 then
    begin
      cv.Brush.Color := $4A3820;
      cv.FillRect(Rect(x1, RULER_H, x2, h));
    end;
  end;
  { time ruler }
  cv.Brush.Color := $262626;
  cv.FillRect(Rect(0, 0, w, RULER_H));
  pxMs := w / Max(1.0, FViewLen / FRate * 1000);
  stepMs := STEPS_MS[High(STEPS_MS)];
  for i := 0 to High(STEPS_MS) do
    if STEPS_MS[i] * pxMs >= 70 then
    begin
      stepMs := STEPS_MS[i];
      Break;
    end;
  t := Ceil(FViewStart / FRate * 1000 / stepMs) * stepMs;
  while t <= (FViewStart + FViewLen) / FRate * 1000 do
  begin
    x := FrameToX(Round(t / 1000 * FRate));
    cv.Brush.Color := $505050;
    cv.FillRect(Rect(x, RULER_H - 6, x + 1, h));
    cv.Brush.Style := bsClear;
    cv.Font.Color := clSilver;
    if stepMs >= 1000 then cv.TextOut(x + 3, 3, Format('%.1f s', [t / 1000]))
    else cv.TextOut(x + 3, 3, Format('%.0f ms', [t]));
    cv.Brush.Style := bsSolid;
    t := t + stepMs;
  end;
  { waveform, one lane per channel }
  lanes := Max(1, Channels);
  laneH := (h - RULER_H) div lanes;
  stp := Max(1, (FViewLen div Max(1, w)) div 48);
  for lane := 0 to lanes - 1 do
  begin
    mid := RULER_H + lane * laneH + laneH div 2;
    cv.Brush.Color := $404040;
    cv.FillRect(Rect(0, mid, w, mid + 1));
    cv.Pen.Style := psSolid;
    cv.Pen.Color := FWaveColor;
    c := Min(lane, Channels - 1);
    for x := 0 to w - 1 do
    begin
      f0 := FViewStart + Trunc(x / w * FViewLen);
      f1 := Min(Frames, Max(f0 + 1, FViewStart + Trunc((x + 1) / w * FViewLen)));
      lo := 0;
      hi := 0;
      f := f0;
      while f < f1 do
      begin
        v := FData[c][f];
        if v < lo then lo := v;
        if v > hi then hi := v;
        Inc(f, stp);
      end;
      cv.MoveTo(x, mid - Round(Min(1, hi) * (laneH div 2 - 3)));
      cv.LineTo(x, mid - Round(Max(-1, lo) * (laneH div 2 - 3)) + 1);
    end;
    cv.Pen.Style := psClear;
  end;
  { region edges }
  if HasSel then
    for i := 0 to 1 do
    begin
      x := FrameToX(IfThen(i = 0, FSelA, FSelB));
      if (x >= 0) and (x < w) then
      begin
        cv.Brush.Color := clWhite;
        cv.FillRect(Rect(x, RULER_H, x + 2, h));
        cv.FillRect(Rect(x - 3, RULER_H, x + 5, RULER_H + 5));
      end;
    end;
end;

{ ---- marking a region ---- }

procedure TfrmInstrumentEditor.pbWaveMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  if (Button <> mbLeft) or (Frames < 2) then Exit;
  FDrag := 0;
  if HasSel and (Abs(X - FrameToX(FSelA)) <= EDGE_PX) then FDrag := 1
  else if HasSel and (Abs(X - FrameToX(FSelB)) <= EDGE_PX) then FDrag := 2
  else
  begin
    FDrag := 3;
    FAnchor := XToFrame(X);
    FSelA := -1;
    FSelB := -1;
  end;
  pbWave.Invalidate;
end;

procedure TfrmInstrumentEditor.pbWaveMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
var
  f: Integer;
begin
  if (FDrag = 0) then
  begin
    if HasSel and ((Abs(X - FrameToX(FSelA)) <= EDGE_PX) or (Abs(X - FrameToX(FSelB)) <= EDGE_PX)) then
      pbWave.Cursor := crSizeWE
    else
      pbWave.Cursor := crCross;
    Exit;
  end;
  f := XToFrame(X);
  case FDrag of
    1: FSelA := Min(f, FSelB - 1);
    2: FSelB := Max(f, FSelA + 1);
    3:
      begin
        FSelA := Min(FAnchor, f);
        FSelB := Max(FAnchor, f);
      end;
  end;
  UpdateReadout;
  pbWave.Invalidate;
end;

procedure TfrmInstrumentEditor.pbWaveMouseUp(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  if FDrag = 0 then Exit;
  FDrag := 0;
  if (FSelB - FSelA) < 2 then
  begin
    FSelA := -1;
    FSelB := -1;
  end;
  UpdateReadout;
  pbWave.Invalidate;
end;

procedure TfrmInstrumentEditor.pbWaveDblClick(Sender: TObject);
begin
  btnSelAllClick(nil);
end;

procedure TfrmInstrumentEditor.pbWaveMouseWheel(Sender: TObject; Shift: TShiftState;
  WheelDelta: Integer; MousePos: TPoint; var Handled: Boolean);
var
  p: TPoint;
begin
  Handled := True;
  p := pbWave.ScreenToClient(Mouse.CursorPos);
  if ssShift in Shift then
    SetView(FViewStart - Sign(WheelDelta) * Max(1, FViewLen div 10), FViewLen)
  else if WheelDelta > 0 then
    ZoomBy(0.8, XToFrame(p.X))
  else
    ZoomBy(1.25, XToFrame(p.X));
end;

procedure TfrmInstrumentEditor.sbWaveChange(Sender: TObject);
begin
  FViewStart := sbWave.Position;
  pbWave.Invalidate;
end;

{ ---- view buttons ---- }

procedure TfrmInstrumentEditor.btnSelAllClick(Sender: TObject);
begin
  if Frames < 2 then Exit;
  FSelA := 0;
  FSelB := Frames;
  UpdateReadout;
  pbWave.Invalidate;
end;

procedure TfrmInstrumentEditor.btnZoomInClick(Sender: TObject);
begin
  ZoomBy(0.5, FViewStart + FViewLen div 2);
end;

procedure TfrmInstrumentEditor.btnZoomOutClick(Sender: TObject);
begin
  ZoomBy(2, FViewStart + FViewLen div 2);
end;

procedure TfrmInstrumentEditor.btnZoomSelClick(Sender: TObject);
begin
  if HasSel then SetView(FSelA, FSelB - FSelA)
  else Note('Mark a region to zoom to it.');
end;

procedure TfrmInstrumentEditor.btnFitClick(Sender: TObject);
begin
  SetView(0, Frames);
end;

{ ---- editing ---- }

procedure TfrmInstrumentEditor.btnUndoClick(Sender: TObject);
begin
  if (FUndo = nil) or (FUndo.Count = 0) then Exit;
  FData := FUndo[FUndo.Count - 1];
  FUndo.Delete(FUndo.Count - 1);
  Changed;
  Note('Undone.');
end;

procedure TfrmInstrumentEditor.btnTrimClick(Sender: TObject);
var
  a, b: Integer;
begin
  if not RequireSel(a, b) then Exit;
  if b - a < 2 then Exit;
  PushUndo;
  FData := Slice(a, b);
  FSelA := -1;
  FSelB := -1;
  Changed(False);
  Note('Trimmed to the marked region.');
end;

procedure TfrmInstrumentEditor.btnCutClick(Sender: TObject);
var
  a, b, c: Integer;
  nd: TAudioPlanar;
begin
  if not RequireSel(a, b) then Exit;
  if Frames - (b - a) < 2 then
  begin
    Note('That would leave nothing - use Silence instead.');
    Exit;
  end;
  PushUndo;
  SetLength(nd, Channels);
  for c := 0 to Channels - 1 do
  begin
    SetLength(nd[c], Frames - (b - a));
    Move(FData[c][0], nd[c][0], a * SizeOf(Single));
    Move(FData[c][b], nd[c][a], (Frames - b) * SizeOf(Single));
  end;
  FData := nd;
  FSelA := -1;
  FSelB := -1;
  Changed;
  Note('Cut the marked region out.');
end;

procedure TfrmInstrumentEditor.btnSilenceClick(Sender: TObject);
var
  a, b, c: Integer;
begin
  if not RequireSel(a, b) then Exit;
  PushUndo;
  for c := 0 to Channels - 1 do FillChar(FData[c][a], (b - a) * SizeOf(Single), 0);
  Changed;
  Note('Silenced the marked region.');
end;

procedure TfrmInstrumentEditor.btnReverseClick(Sender: TObject);
var
  a, b, c, i: Integer;
  t: Single;
begin
  if not EditRange(a, b) then Exit;
  PushUndo;
  for c := 0 to Channels - 1 do
    for i := 0 to (b - a) div 2 - 1 do
    begin
      t := FData[c][a + i];
      FData[c][a + i] := FData[c][b - 1 - i];
      FData[c][b - 1 - i] := t;
    end;
  Changed;
  Note('Reversed.');
end;

procedure TfrmInstrumentEditor.btnNormalizeClick(Sender: TObject);
var
  a, b, c, i: Integer;
  pk, g: Single;
begin
  if not EditRange(a, b) then Exit;
  pk := 0;
  for c := 0 to Channels - 1 do
    for i := a to b - 1 do
      if Abs(FData[c][i]) > pk then pk := Abs(FData[c][i]);
  if pk < 0.000001 then
  begin
    Note('The region is silent - nothing to normalise.');
    Exit;
  end;
  g := 0.98 / pk;
  PushUndo;
  for c := 0 to Channels - 1 do
    for i := a to b - 1 do FData[c][i] := FData[c][i] * g;
  Changed;
  Note(Format('Normalised: raised by %.1f dB.', [20 * FastLog10(g)]));
end;

procedure TfrmInstrumentEditor.ApplyEffect(const AName, AKind, AParams: string; AFrom, ATo: Integer);
var
  err: string;
begin
  PushUndo;
  if ApplyEffectOffline(AKind, AParams, FData, Channels, FRate, AFrom, ATo - AFrom, err) then
  begin
    Changed;
    Note(AName + ' applied.');
  end
  else
  begin
    FUndo.Delete(FUndo.Count - 1);
    UpdateView;
    Note(AName + ' failed: ' + err);
  end;
end;

procedure TfrmInstrumentEditor.btnFadeInClick(Sender: TObject);
var
  a, b: Integer;
begin
  if EditRange(a, b) then ApplyEffect('Fade in', '@fadein', '', a, b);
end;

procedure TfrmInstrumentEditor.btnFadeOutClick(Sender: TObject);
var
  a, b: Integer;
begin
  if EditRange(a, b) then ApplyEffect('Fade out', '@fadeout', '', a, b);
end;

procedure TfrmInstrumentEditor.btnGainClick(Sender: TObject);
var
  a, b, c, i: Integer;
  g: Single;
begin
  if not EditRange(a, b) then Exit;
  g := FastExp10(knobGain.Position / 20);
  PushUndo;
  for c := 0 to Channels - 1 do
    for i := a to b - 1 do FData[c][i] := FData[c][i] * g;
  Changed;
  Note(Format('Level changed by %+.1f dB.', [knobGain.Position]));
end;

{ adds silence after the marked region (or at the end): room for a reverb or echo tail }
procedure TfrmInstrumentEditor.btnExtendClick(Sender: TObject);
var
  at, n, c: Integer;
  nd: TAudioPlanar;
begin
  n := Round(knobExtend.Position / 1000 * FRate);
  if n < 1 then Exit;
  if HasSel then at := Min(FSelB, Frames) else at := Frames;
  PushUndo;
  SetLength(nd, Channels);
  for c := 0 to Channels - 1 do
  begin
    SetLength(nd[c], Frames + n);
    FillChar(nd[c][0], (Frames + n) * SizeOf(Single), 0);
    Move(FData[c][0], nd[c][0], at * SizeOf(Single));
    Move(FData[c][at], nd[c][at + n], (Frames - at) * SizeOf(Single));
  end;
  FData := nd;
  Changed;
  Note(Format('Added %.0f ms of silence.', [knobExtend.Position]));
end;

{ lengthens or shortens the region (or the whole sound) keeping its pitch }
procedure TfrmInstrumentEditor.btnStretchClick(Sender: TObject);
var
  a, b, c, i, n, newN: Integer;
  factor: Double;
  stretcher: TPhaseVocoderStretch;
  src: TAudioSampleArray;
  outp: TArray<Single>;
  nd: TAudioPlanar;
begin
  if not EditRange(a, b) then Exit;
  factor := knobStretch.Position / 100;
  if Abs(factor - 1) < 0.005 then Exit;
  n := b - a;
  newN := Max(2, Round(n * factor));
  PushUndo;
  SetLength(nd, Channels);
  stretcher := TPhaseVocoderStretch.Create(2048);
  try
    for c := 0 to Channels - 1 do
    begin
      src := Copy(FData[c], a, n);
      if n < 2048 then
      begin
        { too short for the vocoder frame: plain interpolation }
        SetLength(outp, newN);
        for i := 0 to newN - 1 do
          outp[i] := src[Min(n - 1, Trunc(i / factor))];
      end
      else
        stretcher.Process(src, factor, outp);
      SetLength(nd[c], Frames - n + Length(outp));
      Move(FData[c][0], nd[c][0], a * SizeOf(Single));
      Move(outp[0], nd[c][a], Length(outp) * SizeOf(Single));
      Move(FData[c][b], nd[c][a + Length(outp)], (Frames - b) * SizeOf(Single));
    end;
  finally
    stretcher.Free;
  end;
  FData := nd;
  FSelA := -1;
  FSelB := -1;
  Changed;
  Note(Format('Stretched to %.0f%% of its length.', [knobStretch.Position]));
end;

{ ---- effects ---- }

procedure TfrmInstrumentEditor.FillEffectList;
var
  i: Integer;
  flt: string;
begin
  flt := LowerCase(Trim(edtFilter.Text));
  lstFx.Items.BeginUpdate;
  try
    lstFx.Items.Clear;
    SetLength(FShown, 0);
    for i := 0 to High(FFx) do
      if (flt = '') or (Pos(flt, LowerCase(FFx[i].Name)) > 0) then
      begin
        lstFx.Items.Add(FFx[i].Name);
        SetLength(FShown, Length(FShown) + 1);
        FShown[High(FShown)] := i;
      end;
  finally
    lstFx.Items.EndUpdate;
  end;
  if lstFx.Items.Count > 0 then lstFx.ItemIndex := 0;
end;

procedure TfrmInstrumentEditor.edtFilterChange(Sender: TObject);
begin
  FillEffectList;
end;

procedure TfrmInstrumentEditor.lstFxDblClick(Sender: TObject);
begin
  btnFxClick(nil);
end;

procedure TfrmInstrumentEditor.btnFxClick(Sender: TObject);
var
  a, b, idx: Integer;
  fx: TFxPresetInfo;
  res: string;
  region: TAudioPlanar;
begin
  if (lstFx.ItemIndex < 0) or (lstFx.ItemIndex > High(FShown)) then
  begin
    Note('Pick an effect from the list first.');
    Exit;
  end;
  if not EditRange(a, b) then Exit;
  idx := FShown[lstFx.ItemIndex];
  fx := FFx[idx];
  region := Slice(a, b);
  FPreviewKind := fx.Kind;
  FPreviewA := a;
  FPreviewB := b;
  if TfrmEffectEditor.Edit(Self, fx.Name, fx.Kind, fx.Params, res, FxAudition, region, FRate) then
    ApplyEffect(fx.Name, fx.Kind, res, a, b);
  { the audition may have left a processed copy on the pad }
  if FMachine <> nil then
    FMachine.SetPadData(FNote, FData, FRate, FOrigPath);
end;

procedure TfrmInstrumentEditor.StopAudition;
begin
  if FMachine <> nil then FMachine.StopPad(FNote)
  else if FFileMode then PlaySound(nil, 0, 0);
end;

{ ---- hearing the work ---- }

procedure TfrmInstrumentEditor.Audition(const AData: TAudioPlanar);
begin
  if FFileMode then
  begin
    { the region is written beside the output and played through the system audio output }
    if (Length(AData) < 1) or (Length(AData[0]) < 2) then Exit;
    PlaySound(nil, 0, 0);
    try
      SaveWavFile(FAuditionPath, AData, Length(AData), FRate, Length(AData[0]), wsfPCM16);
      PlaySound(PChar(FAuditionPath), 0, SND_FILENAME or SND_ASYNC or SND_NODEFAULT);
    except
      on E: Exception do Note('Audition failed: ' + E.Message);
    end;
    Exit;
  end;
  if (FMachine = nil) or (Length(AData) < 1) or (Length(AData[0]) < 2) then Exit;
  FMachine.StopPad(FNote);
  if FMachine.SetPadData(FNote, AData, FRate, FOrigPath) then FMachine.Hit(FNote, 110);
end;

procedure TfrmInstrumentEditor.btnPlayClick(Sender: TObject);
var
  a, b: Integer;
begin
  if not EditRange(a, b) then Exit;
  Audition(Slice(a, b));
end;

procedure TfrmInstrumentEditor.btnStopClick(Sender: TObject);
begin
  StopAudition;
end;

{ the region with the effect as set in the effect editor, played through the pad }
procedure TfrmInstrumentEditor.FxAudition(const AParams: string);
var
  part: TAudioPlanar;
  err: string;
begin
  part := Slice(FPreviewA, FPreviewB);
  if ApplyEffectOffline(FPreviewKind, AParams, part, Length(part), FRate, 0, Length(part[0]), err) then
    Audition(part)
  else
    Note('Audition failed: ' + err);
end;

{ ---- leaving ---- }

function TfrmInstrumentEditor.SaveEdited(const AOutDir: string; out APath: string): Boolean;
var
  dir: string;
begin
  APath := '';
  try
    dir := IncludeTrailingPathDelimiter(AOutDir);
    ForceDirectories(dir);
    if FFileMode then
    begin
      APath := dir + Format('edit-%s-%s.wav', [SafeFileName(ChangeFileExt(ExtractFileName(FOrigPath), '')),
        FormatDateTime('yyyymmdd-hhnnsszzz', Now)]);
      SaveWavFile(APath, FData, Channels, FRate, Frames, wsfPCM24);
      Result := True;
      Exit;
    end;
    APath := dir + Format('drum-%d-%s-%s.wav', [FNote, SafeFileName(FMachine.Pads[FNote].Name),
      FormatDateTime('yyyymmdd-hhnnsszzz', Now)]);
    SaveWavFile(APath, FData, Channels, FRate, Frames, wsfPCM24);
    Result := FMachine.SetPadData(FNote, FData, FRate, APath);
  except
    on E: Exception do
    begin
      MessageBox(Handle, PChar('Could not save the edited sound:' + sLineBreak + E.Message),
        'Instrument editor', MB_OK or MB_ICONWARNING);
      Result := False;
    end;
  end;
end;

procedure TfrmInstrumentEditor.RestoreOriginal;
begin
  if FMachine = nil then Exit;
  FMachine.SetPadData(FNote, FOrig, FRate, FOrigPath);
end;

{ every tool is an icon: the icon's id says what it does }
procedure TfrmInstrumentEditor.ToolClick(Sender: TObject; AIndex: Integer; const AId: string);
begin
  if AId = 'play' then btnPlayClick(nil)
  else if AId = 'stop' then btnStopClick(nil)
  else if AId = 'undo' then btnUndoClick(nil)
  else if AId = 'selall' then btnSelAllClick(nil)
  else if AId = 'zoomin' then btnZoomInClick(nil)
  else if AId = 'zoomout' then btnZoomOutClick(nil)
  else if AId = 'zoomsel' then btnZoomSelClick(nil)
  else if AId = 'fit' then btnFitClick(nil)
  else if AId = 'trim' then btnTrimClick(nil)
  else if AId = 'cut' then btnCutClick(nil)
  else if AId = 'silence' then btnSilenceClick(nil)
  else if AId = 'reverse' then btnReverseClick(nil)
  else if AId = 'normalize' then btnNormalizeClick(nil)
  else if AId = 'fadein' then btnFadeInClick(nil)
  else if AId = 'fadeout' then btnFadeOutClick(nil)
  else if AId = 'gain' then btnGainClick(nil)
  else if AId = 'extend' then btnExtendClick(nil)
  else if AId = 'stretch' then btnStretchClick(nil)
  else if AId = 'tools' then btnFxClick(nil);
end;

{ the file icons: Save writes the audio as it is now (all of it) to a WAV the user names; Loop toggles
  whether the clip repeats on the Timeline until the last segment }
procedure TfrmInstrumentEditor.UpdateFileBar;
begin
  if FShowLoop then ibFile.Buttons := 'save;loop' else ibFile.Buttons := 'save';
  ibFile.Width := 4 + ibFile.CellWidth * Length(ibFile.Buttons.Split([';']));
  if FLoop then ibFile.LitMask := 2 else ibFile.LitMask := 0;
end;

procedure TfrmInstrumentEditor.SaveToDisk;
var
  fn: string;
begin
  if Frames = 0 then Exit;
  dlgSaveWav.FileName := SafeFileName(ChangeFileExt(ExtractFileName(FOrigPath), '')) + '.wav';
  if not dlgSaveWav.Execute then Exit;
  fn := dlgSaveWav.FileName;
  if ExtractFileExt(fn) = '' then fn := fn + '.wav';
  try
    SaveWavFile(fn, FData, Channels, FRate, Frames, wsfPCM24);
    Note('Saved ' + ExtractFileName(fn));
  except
    on E: Exception do
      MessageBox(Handle, PChar('Could not save the audio:' + sLineBreak + E.Message),
        'Audio file editor', MB_OK or MB_ICONWARNING);
  end;
end;

procedure TfrmInstrumentEditor.FileToolClick(Sender: TObject; AIndex: Integer; const AId: string);
begin
  if AId = 'save' then SaveToDisk
  else if AId = 'loop' then
  begin
    FLoop := not FLoop;
    UpdateFileBar;
    if FLoop then Note('Loop on: the clip repeats on the Timeline until the last segment')
    else Note('Loop off: the clip plays once');
  end;
end;

procedure TfrmInstrumentEditor.DialogClick(Sender: TObject; AIndex: Integer; const AId: string);
begin
  if AId = 'ok' then btnOKClick(nil) else btnCancelClick(nil);
end;

procedure TfrmInstrumentEditor.btnOKClick(Sender: TObject);
begin
  ModalResult := mrOk;
end;

procedure TfrmInstrumentEditor.btnCancelClick(Sender: TObject);
begin
  if FModified and
     (MessageBox(Handle, 'Discard the changes made to this sound?', 'Instrument editor',
       MB_YESNO or MB_ICONQUESTION) <> IDYES) then Exit;
  ModalResult := mrCancel;
end;

end.
