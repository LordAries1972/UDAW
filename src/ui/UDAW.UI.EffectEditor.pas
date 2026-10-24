unit UDAW.UI.EffectEditor;
{$I udaw.inc}

{ The effect editor window: an effect's settings as knobs and check boxes on the GL widget set,
  with the effect's response drawn beside them. Opened by a double-click on an effect region of
  the Timeline (and by Edit Effect), and by the instrument editor before it applies an effect.

  An effect's settings are a plain "key=value;key=value" string with no declared ranges, so the
  window reads the string it is given: each numeric setting gets a knob (the range comes from
  a table of the known keys, widened to take the value it was opened with), each 0/1 switch a
  check box, and anything else stays as text in the "Other settings" field. The knobs, check
  boxes and the field are all on the form at design time; only their captions and ranges are
  set here. }

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.Math, Vcl.Controls, Vcl.Forms,
  Vcl.Graphics, Vcl.ExtCtrls, UDAW.Audio.Types, UDAW.GL.Canvas, UDAW.GL.Widgets;

const
  EFFECT_EDITOR_KNOBS = 12;
  EFFECT_EDITOR_CHECKS = 4;

type
  { audition the effect with these settings; the editor stays open }
  TEffectPreviewEvent = procedure(const AParams: string) of object;

  { what a graph beside the knobs shows. egCurve is the effect's calculated response; the
    others are measured from the audio before and after the effect was rendered. }
  TEffectGraph = (egNone, egCurve, egSpectrum, egEnvelope, egStereo);

  TfrmEffectEditor = class(TForm)
    lblTitle: TGLLabel;
    lblSub: TGLLabel;
    knob1: TGLKnob;
    knob2: TGLKnob;
    knob3: TGLKnob;
    knob4: TGLKnob;
    knob5: TGLKnob;
    knob6: TGLKnob;
    knob7: TGLKnob;
    knob8: TGLKnob;
    knob9: TGLKnob;
    knob10: TGLKnob;
    knob11: TGLKnob;
    knob12: TGLKnob;
    chk1: TGLCheck;
    chk2: TGLCheck;
    chk3: TGLCheck;
    chk4: TGLCheck;
    lblNone: TGLLabel;
    lblText: TGLLabel;
    edtText: TGLEdit;
    pbCurve: TGLView;
    pbGraph2: TGLView;
    pbScope: TGLView;
    tmrRender: TTimer;
    cboPreset: TGLCombo;
    btnLoadPreset: TGLButton;
    btnSavePreset: TGLButton;
    btnDeletePreset: TGLButton;
    lblNote: TGLLabel;
    btnReset: TGLButton;
    btnPreview: TGLButton;
    btnOK: TGLButton;
    btnCancel: TGLButton;
    procedure FormCreate(Sender: TObject);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure ControlChanged(Sender: TObject);
    procedure pbCurvePaint(Sender: TObject);
    procedure pbGraph2Paint(Sender: TObject);
    procedure pbScopePaint(Sender: TObject);
    procedure pbScopeMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    procedure pbScopeMouseLeave(Sender: TObject);
    procedure pbScopeDblClick(Sender: TObject);
    procedure pbScopeMouseWheel(Sender: TObject; Shift: TShiftState; WheelDelta: Integer;
      MousePos: TPoint; var Handled: Boolean);
    procedure tmrRenderTimer(Sender: TObject);
    procedure cboPresetChange(Sender: TObject);
    procedure btnLoadPresetClick(Sender: TObject);
    procedure btnSavePresetClick(Sender: TObject);
    procedure btnDeletePresetClick(Sender: TObject);
    procedure btnResetClick(Sender: TObject);
    procedure btnPreviewClick(Sender: TObject);
    procedure btnOKClick(Sender: TObject);
    procedure btnCancelClick(Sender: TObject);
  private
    FKnobs: array[0..EFFECT_EDITOR_KNOBS - 1] of TGLKnob;
    FChecks: array[0..EFFECT_EDITOR_CHECKS - 1] of TGLCheck;
    FKnobKey: array[0..EFFECT_EDITOR_KNOBS - 1] of string;
    FCheckKey: array[0..EFFECT_EDITOR_CHECKS - 1] of string;
    FKnobCount, FCheckCount: Integer;
    FKeys, FValues: TArray<string>;   // every setting, in the order it was given
    FKind: string;
    FName: string;
    FPresetKind: string;              // '' = no presets (the timeline's own effects); else the preset section
    FDeleteArmed: Boolean;
    FStartText: string;
    FBusy: Boolean;
    FOnPreview: TEffectPreviewEvent;
    { the marked region as it is now (plus a silent tail so reverb / echo tails show) and as
      the effect with the current settings would leave it }
    FSrc, FProc: TAudioPlanar;
    FRate, FRegionFrames, FTotalFrames: Integer;
    FRenderErr: string;
    FFullFrames: Integer;               // length of the whole region (only the first part is drawn)
    FViewStart, FViewLen, FHoverX: Integer;   // the zoom window of the scope, and the cursor in it
    FPeakB, FRmsB, FPeakA, FRmsA: Double;
    { measured from FSrc / FProc after each render }
    FGraphs: array[0..1] of TEffectGraph;
    FSpecB, FSpecA: TArray<Single>;      // dB per log-spaced band
    FEnvB, FEnvA: TArray<Single>;        // dB per 10 ms
    procedure ChooseGraphs;
    procedure Analyse;
    procedure SpectrumOf(const AData: TAudioPlanar; out ABands: TArray<Single>);
    procedure EnvelopeOf(const AData: TAudioPlanar; out AEnv: TArray<Single>);
    procedure DrawGraph(AView: TGLView; ASlot: Integer);
    procedure ResetScopeView;
    function ScopeFrameAt(AX: Integer): Integer;
    procedure ScopeZoom(AFactor: Double; ACenterFrame: Integer);
    procedure SetRegion(const AData: TAudioPlanar; ARate: Integer);
    procedure ScheduleRender;
    procedure RenderPreview;
    procedure Measure(const AData: TAudioPlanar; AFrames: Integer; out APeak, ARms: Double);
    procedure Setup(const AName, AKind, AParams: string);
    procedure RefreshPresets;
    function PresetsIni: string;
    class var FPresetsFolder: string;
    function CurrentParams: string;
    function TextValueOf(const AMap: TStringList; const AKey, ADefault: string): string;
  public
    { Opens the editor for one effect. AResult is the edited settings string when the user
      pressed OK. APreview, when given, adds an Audition button. ARegion is the audio of the
      marked region (planar, ARegionRate Hz): the window draws it before and after the effect,
      redone as the settings change. }
    class function Edit(AOwner: TComponent; const AName, AKind, AParams: string;
      out AResult: string; APreview: TEffectPreviewEvent = nil;
      const ARegion: TAudioPlanar = nil; ARegionRate: Integer = 0;
      const APresetKind: string = ''): Boolean;
    { True when the effect has anything to adjust (a knob, a switch or a text setting) }
    class function HasSettings(const AKind, AParams: string): Boolean;
    { the Settings > Presets folder; every preset is saved to and loaded from it (empty = the data folder) }
    class property PresetsFolder: string read FPresetsFolder write FPresetsFolder;
  end;

implementation

uses UDAW.DSP.MathTables,
  System.IniFiles, UDAW.Paths, System.Generics.Collections, System.StrUtils, Vcl.Themes, UDAW.UI.CurvePaint, UDAW.DSP.CurveMath,
  UDAW.Timeline.OfflineFx;

{$R *.dfm}

type
  TParamSpec = record
    Caption: string;
    Lo, Hi: Double;
    Decimals: Integer;
    Step: Double;
    Log: Boolean;
  end;

var
  GSpecs: TDictionary<string, TParamSpec>;

const
  SWITCH_KEYS = ',pingpong,fixphase,fixbalance,keepbass,out,';

procedure AddSpec(const AKey, ACaption: string; ALo, AHi: Double; ADecimals: Integer = 1;
  AStep: Double = 0; ALog: Boolean = False);
var
  s: TParamSpec;
begin
  s.Caption := ACaption;
  s.Lo := ALo;
  s.Hi := AHi;
  s.Decimals := ADecimals;
  s.Step := AStep;
  s.Log := ALog;
  GSpecs.AddOrSetValue(AKey, s);
end;

procedure BuildSpecs;
begin
  GSpecs := TDictionary<string, TParamSpec>.Create;
  AddSpec('db', 'Gain (dB)', -36, 36);
  AddSpec('gaindb', 'Gain (dB)', -24, 24);
  AddSpec('pos', 'Position', -1, 1, 2);
  AddSpec('semitones', 'Semitones', -24, 24);
  AddSpec('reduce', 'Reduction (dB)', 0, 48);
  AddSpec('freq', 'Frequency (Hz)', 20, 20000, 0, 0, True);
  AddSpec('hz', 'Frequency (Hz)', 20, 20000, 0, 0, True);
  AddSpec('q', 'Q', 0.1, 20, 2, 0, True);
  AddSpec('ms', 'Time (ms)', 1, 2000, 0, 0, True);
  AddSpec('fb', 'Feedback', 0, 0.95, 2);
  AddSpec('mix', 'Mix', 0, 1, 2);
  AddSpec('size', 'Size', 0, 1, 2);
  AddSpec('damp', 'Damping', 0, 1, 2);
  AddSpec('width', 'Width', 0, 2, 2);
  AddSpec('predelay', 'Pre-delay (ms)', 0, 200, 0);
  AddSpec('bits', 'Bits', 1, 16, 0, 1);
  AddSpec('down', 'Downsample', 1, 32, 0, 1);
  AddSpec('drive', 'Drive', 0, 40);
  AddSpec('trim', 'Trim (dB)', -24, 24);
  AddSpec('thresh', 'Threshold (dB)', -80, 0);
  AddSpec('ratio', 'Ratio', 1, 20);
  AddSpec('knee', 'Knee (dB)', 0, 24);
  AddSpec('attack', 'Attack', 0, 200);
  AddSpec('sustain', 'Sustain', -24, 24);
  AddSpec('release', 'Release (ms)', 1, 1000, 0, 0, True);
  AddSpec('makeup', 'Makeup (dB)', 0, 24);
  AddSpec('hold', 'Hold (ms)', 0, 500, 0);
  AddSpec('range', 'Range (dB)', -80, 80);
  AddSpec('ceiling', 'Ceiling (dB)', -12, 0);
  AddSpec('look', 'Lookahead (ms)', 0, 20);
  AddSpec('lookahead', 'Lookahead (ms)', 0, 20);
  AddSpec('rate', 'Rate (Hz)', 0.05, 20, 2, 0, True);
  AddSpec('depth', 'Depth', 0, 1, 2);
  AddSpec('stereo', 'Stereo (deg)', 0, 180, 0);
  AddSpec('stages', 'Stages', 2, 12, 0, 1);
  AddSpec('amt', 'Amount', 0, 1, 2);
  AddSpec('sens', 'Sensitivity', 0, 10);
  AddSpec('duty', 'Duty', 0, 1, 2);
  AddSpec('peak', 'Peak (dB)', -24, 0);
  AddSpec('bands', 'Bands', 4, 32, 0, 1);
  AddSpec('pitch', 'Pitch (Hz)', 40, 400, 0, 0, True);
  AddSpec('vowel', 'Vowel', 0, 4, 0, 1);
  AddSpec('tilt', 'Tilt (dB)', -12, 12);
  AddSpec('target', 'Target (dB)', -40, -6);
  AddSpec('gate', 'Gate (dB)', -80, -20);
  AddSpec('shape', 'Curve', 1, 4, 0, 1);
  AddSpec('strength', 'Strength', 0, 1, 2);
  AddSpec('mid', 'Mid (dB)', -24, 24);
  AddSpec('side', 'Side (dB)', -24, 24);
  AddSpec('lufs', 'Loudness (LUFS)', -40, -6);
  AddSpec('rep', 'Repeats', 1, 16, 0, 1);
  AddSpec('sidechain', 'Sidechain strip', 0, 64, 0, 1);
end;

function InvFmt: TFormatSettings;
begin
  Result := TFormatSettings.Invariant;
end;

{ ---- colours come from the active visual theme, like the rest of the GL widgets ---- }

type
  TPalette = record
    Bg, Head, Grid, Ink, Muted, Before, After, Tail: TColor;
  end;

function ThemeCol(AColor: TColor): TColor;
begin
  Result := ColorToRGB(StyleServices.GetSystemColor(AColor));
end;

function MixCol(A, B: TColor; T: Double): TColor;
var
  ca, cb: LongInt;
begin
  ca := ColorToRGB(A);
  cb := ColorToRGB(B);
  Result := TColor(
    Byte(Round((ca and $FF) + ((cb and $FF) - (ca and $FF)) * T)) or
    (Byte(Round(((ca shr 8) and $FF) + (((cb shr 8) and $FF) - ((ca shr 8) and $FF)) * T)) shl 8) or
    (Byte(Round(((ca shr 16) and $FF) + (((cb shr 16) and $FF) - ((ca shr 16) and $FF)) * T)) shl 16));
end;

function Palette: TPalette;
begin
  Result.Bg := ThemeCol(clWindow);
  Result.Ink := ThemeCol(clWindowText);
  Result.Head := MixCol(Result.Bg, Result.Ink, 0.10);
  Result.Grid := MixCol(Result.Bg, Result.Ink, 0.18);
  Result.Muted := MixCol(Result.Bg, Result.Ink, 0.60);
  Result.Tail := MixCol(Result.Bg, Result.Ink, 0.07);
  Result.Before := MixCol(Result.Bg, Result.Ink, 0.62);   { the original: a neutral ink }
  Result.After := MixCol(ThemeCol(clHighlight), Result.Ink, 0.20);   { the result: the theme's accent }
end;

{ the range a knob needs for a setting: the table's, widened to take the opening value; an
  unknown setting gets a range around its value }
function SpecFor(const AKey: string; AValue: Double): TParamSpec;
begin
  if not GSpecs.TryGetValue(LowerCase(AKey), Result) then
  begin
    Result.Caption := AKey;
    Result.Decimals := 2;
    Result.Step := 0;
    Result.Log := False;
    if AValue >= 0 then
    begin
      Result.Lo := 0;
      Result.Hi := Max(1, Ceil(Abs(AValue) * 3));
    end
    else
    begin
      Result.Lo := Floor(AValue * 3);
      Result.Hi := Abs(Result.Lo);
    end;
  end;
  if AValue < Result.Lo then Result.Lo := AValue;
  if AValue > Result.Hi then Result.Hi := AValue;
  if Result.Log and (Result.Lo <= 0) then Result.Log := False;
  if Result.Hi <= Result.Lo then Result.Hi := Result.Lo + 1;
end;

{ splits "k=v;k=v" into keys and values; a part without "=" is ignored }
procedure SplitParams(const AParams: string; out AKeys, AValues: TArray<string>);
var
  part: string;
  p, n: Integer;
begin
  SetLength(AKeys, 0);
  SetLength(AValues, 0);
  n := 0;
  for part in AParams.Split([';']) do
  begin
    p := Pos('=', part);
    if p < 2 then Continue;
    SetLength(AKeys, n + 1);
    SetLength(AValues, n + 1);
    AKeys[n] := Trim(Copy(part, 1, p - 1));
    AValues[n] := Trim(Copy(part, p + 1, MaxInt));
    Inc(n);
  end;
end;

function IsSwitch(const AKey, AValue: string): Boolean;
begin
  Result := (Pos(',' + LowerCase(AKey) + ',', SWITCH_KEYS) > 0) and ((AValue = '0') or (AValue = '1'));
end;

{ TfrmEffectEditor }

class function TfrmEffectEditor.Edit(AOwner: TComponent; const AName, AKind, AParams: string;
  out AResult: string; APreview: TEffectPreviewEvent; const ARegion: TAudioPlanar;
  ARegionRate: Integer; const APresetKind: string): Boolean;
var
  frm: TfrmEffectEditor;
begin
  AResult := AParams;
  frm := TfrmEffectEditor.Create(AOwner);
  try
    frm.FOnPreview := APreview;
    frm.btnPreview.Visible := Assigned(APreview);
    frm.FPresetKind := APresetKind;
    frm.cboPreset.Visible := APresetKind <> '';
    frm.btnLoadPreset.Visible := APresetKind <> '';
    frm.btnSavePreset.Visible := APresetKind <> '';
    frm.btnDeletePreset.Visible := APresetKind <> '';
    frm.RefreshPresets;
    frm.SetRegion(ARegion, ARegionRate);
    frm.Setup(AName, AKind, AParams);
    { no audio to draw (a Mixer insert): the scope is not needed, the window is shorter }
    if frm.FTotalFrames < 1 then
    begin
      frm.pbScope.Visible := False;
      frm.ClientHeight := frm.pbScope.Top + 4 + (frm.ClientHeight - frm.btnOK.Top);
    end;
    Result := frm.ShowModal = mrOk;
    if Result then AResult := frm.CurrentParams;
  finally
    frm.Free;
  end;
end;

class function TfrmEffectEditor.HasSettings(const AKind, AParams: string): Boolean;
var
  k, v: TArray<string>;
begin
  SplitParams(AParams, k, v);
  Result := Length(k) > 0;
end;

procedure TfrmEffectEditor.FormCreate(Sender: TObject);
begin
  FKnobs[0] := knob1; FKnobs[1] := knob2; FKnobs[2] := knob3; FKnobs[3] := knob4;
  FKnobs[4] := knob5; FKnobs[5] := knob6; FKnobs[6] := knob7; FKnobs[7] := knob8;
  FKnobs[8] := knob9; FKnobs[9] := knob10; FKnobs[10] := knob11; FKnobs[11] := knob12;
  FChecks[0] := chk1; FChecks[1] := chk2; FChecks[2] := chk3; FChecks[3] := chk4;
end;

{ ---- presets (Mixer inserts): one INI, a section per effect kind, name = the full settings string ---- }

function TfrmEffectEditor.PresetsIni: string;
var
  legacy: string;
begin
  legacy := DataFile('MixerPresets.ini');
  if FPresetsFolder = '' then Exit(legacy);
  ForceDirectories(FPresetsFolder);
  Result := IncludeTrailingPathDelimiter(FPresetsFolder) + 'MixerPresets.ini';
  { presets saved before a folder was chosen come along the first time }
  if (not FileExists(Result)) and FileExists(legacy) then
    CopyFile(PChar(legacy), PChar(Result), True);
end;

procedure TfrmEffectEditor.RefreshPresets;
var
  ini: TMemIniFile;
begin
  if FPresetKind = '' then Exit;
  cboPreset.Items.Clear;
  ini := TMemIniFile.Create(PresetsIni);
  try
    ini.ReadSection(FPresetKind, cboPreset.Items);
  finally
    ini.Free;
  end;
end;

procedure TfrmEffectEditor.cboPresetChange(Sender: TObject);
begin
  if FDeleteArmed then
  begin
    FDeleteArmed := False;
    btnDeletePreset.Caption := 'Del';
  end;
  lblNote.Caption := '';
end;

procedure TfrmEffectEditor.btnLoadPresetClick(Sender: TObject);
var
  ini: TMemIniFile;
  raw: string;
begin
  if Trim(cboPreset.Text) = '' then Exit;
  ini := TMemIniFile.Create(PresetsIni);
  try
    raw := ini.ReadString(FPresetKind, Trim(cboPreset.Text), '');
  finally
    ini.Free;
  end;
  if raw = '' then
  begin
    lblNote.Caption := 'No preset with that name.';
    Exit;
  end;
  Setup(FName, FKind, raw);
  lblNote.Caption := 'Preset loaded.';
end;

procedure TfrmEffectEditor.btnSavePresetClick(Sender: TObject);
var
  ini: TMemIniFile;
  nm: string;
begin
  nm := Trim(cboPreset.Text);
  if nm = '' then
  begin
    lblNote.Caption := 'Type a preset name in the box first.';
    Exit;
  end;
  ini := TMemIniFile.Create(PresetsIni);
  try
    ini.WriteString(FPresetKind, nm, CurrentParams);
    ini.UpdateFile;
  finally
    ini.Free;
  end;
  RefreshPresets;
  cboPreset.ItemIndex := cboPreset.Items.IndexOf(nm);
  lblNote.Caption := 'Preset saved.';
end;

procedure TfrmEffectEditor.btnDeletePresetClick(Sender: TObject);
var
  ini: TMemIniFile;
begin
  if Trim(cboPreset.Text) = '' then Exit;
  if not FDeleteArmed then
  begin
    FDeleteArmed := True;
    btnDeletePreset.Caption := 'Sure?';
    lblNote.Caption := 'Click again to delete the preset.';
    Exit;
  end;
  FDeleteArmed := False;
  btnDeletePreset.Caption := 'Del';
  ini := TMemIniFile.Create(PresetsIni);
  try
    ini.DeleteKey(FPresetKind, Trim(cboPreset.Text));
    ini.UpdateFile;
  finally
    ini.Free;
  end;
  RefreshPresets;
  cboPreset.Text := '';
  lblNote.Caption := 'Preset deleted.';
end;

procedure TfrmEffectEditor.FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if Key = VK_ESCAPE then
  begin
    Key := 0;
    ModalResult := mrCancel;
  end;
end;

procedure TfrmEffectEditor.Setup(const AName, AKind, AParams: string);
var
  i, k: Integer;
  v: Double;
  spec: TParamSpec;
  textPairs: string;
begin
  FBusy := True;
  try
    FKind := AKind;
    FName := AName;
    FStartText := AParams;
    Caption := 'Effect - ' + AName;
    lblTitle.Caption := AName;
    lblSub.Caption := 'Drag a knob up or down; hold Shift for fine steps; double-click resets it.';
    SplitParams(AParams, FKeys, FValues);
    FKnobCount := 0;
    FCheckCount := 0;
    textPairs := '';
    for i := 0 to High(FKeys) do
    begin
      if IsSwitch(FKeys[i], FValues[i]) and (FCheckCount < EFFECT_EDITOR_CHECKS) then
      begin
        FCheckKey[FCheckCount] := FKeys[i];
        FChecks[FCheckCount].Caption := FKeys[i];
        FChecks[FCheckCount].Checked := FValues[i] = '1';
        Inc(FCheckCount);
      end
      else if TryStrToFloat(FValues[i], v, InvFmt) and (FKnobCount < EFFECT_EDITOR_KNOBS) and
              not (SameText(AKind, 'graphiceq') and SameText(FKeys[i], 'bands')) then
      begin
        k := FKnobCount;
        spec := SpecFor(FKeys[i], v);
        FKnobKey[k] := FKeys[i];
        with FKnobs[k] do
        begin
          Logarithmic := False;
          Step := 0;
          Min := spec.Lo;
          Max := spec.Hi;
          Decimals := spec.Decimals;
          Logarithmic := spec.Log;
          Step := spec.Step;
          Caption := spec.Caption;
          DefaultPosition := v;
          Position := v;
        end;
        Inc(FKnobCount);
      end
      else
      begin
        if textPairs <> '' then textPairs := textPairs + ';';
        textPairs := textPairs + FKeys[i] + '=' + FValues[i];
      end;
    end;
    for i := 0 to EFFECT_EDITOR_KNOBS - 1 do FKnobs[i].Visible := i < FKnobCount;
    for i := 0 to EFFECT_EDITOR_CHECKS - 1 do FChecks[i].Visible := i < FCheckCount;
    edtText.Text := textPairs;
    edtText.Visible := textPairs <> '';
    lblText.Visible := textPairs <> '';
    lblNone.Visible := (FKnobCount = 0) and (FCheckCount = 0) and (textPairs = '');
  finally
    FBusy := False;
  end;
  ChooseGraphs;
  pbCurve.Visible := FGraphs[0] <> egNone;
  pbGraph2.Visible := FGraphs[1] <> egNone;
  pbCurve.Invalidate;
  pbGraph2.Invalidate;
  ScheduleRender;
end;

const
  PREVIEW_MAX_SECONDS = 8.0;   // longest stretch of the region the window renders
  PREVIEW_TAIL_SECONDS = 1.5;  // silence after it, for reverb and echo tails

procedure TfrmEffectEditor.SetRegion(const AData: TAudioPlanar; ARate: Integer);
var
  c, ch, n: Integer;
begin
  FRegionFrames := 0;
  FTotalFrames := 0;
  FRate := ARate;
  if (Length(AData) < 1) or (ARate < 1) or (Length(AData[0]) < 2) then Exit;
  ch := Length(AData);
  FFullFrames := Length(AData[0]);
  FRegionFrames := Min(Length(AData[0]), Round(PREVIEW_MAX_SECONDS * ARate));
  FTotalFrames := FRegionFrames + Round(PREVIEW_TAIL_SECONDS * ARate);
  SetLength(FSrc, ch);
  for c := 0 to ch - 1 do
  begin
    SetLength(FSrc[c], FTotalFrames);
    n := Min(FRegionFrames, Length(AData[c]));
    Move(AData[c][0], FSrc[c][0], n * SizeOf(Single));
    FillChar(FSrc[c][n], (FTotalFrames - n) * SizeOf(Single), 0);
  end;
  Measure(FSrc, FRegionFrames, FPeakB, FRmsB);
  FHoverX := -1;
  ResetScopeView;
end;

procedure TfrmEffectEditor.Measure(const AData: TAudioPlanar; AFrames: Integer;
  out APeak, ARms: Double);
var
  c, f: Integer;
  v, sum: Double;
begin
  APeak := 0;
  sum := 0;
  for c := 0 to High(AData) do
    for f := 0 to Min(AFrames, Length(AData[c])) - 1 do
    begin
      v := AData[c][f];
      if Abs(v) > APeak then APeak := Abs(v);
      sum := sum + v * v;
    end;
  if (AFrames > 0) and (Length(AData) > 0) then ARms := Sqrt(sum / (AFrames * Length(AData)))
  else ARms := 0;
end;

procedure TfrmEffectEditor.ScheduleRender;
begin
  if FTotalFrames < 1 then Exit;
  tmrRender.Enabled := False;
  tmrRender.Enabled := True;   // renders once the knobs have been still for a moment
end;

procedure TfrmEffectEditor.tmrRenderTimer(Sender: TObject);
begin
  RenderPreview;
end;

procedure TfrmEffectEditor.RenderPreview;
var
  c, len: Integer;
  err: string;
  ok: Boolean;
begin
  tmrRender.Enabled := False;
  if (FTotalFrames < 1) or (FKind = '') then Exit;
  SetLength(FProc, Length(FSrc));
  for c := 0 to High(FSrc) do FProc[c] := Copy(FSrc[c], 0, FTotalFrames);
  if (FKind = '@fadein') or (FKind = '@fadeout') then len := FRegionFrames else len := FTotalFrames;
  FRenderErr := '';
  Screen.Cursor := crHourGlass;
  try
    ok := ApplyEffectOffline(FKind, CurrentParams, FProc, Length(FProc), FRate, 0, len, err);
  finally
    Screen.Cursor := crDefault;
  end;
  if not ok then
  begin
    FRenderErr := err;
    for c := 0 to High(FSrc) do FProc[c] := Copy(FSrc[c], 0, FTotalFrames);
  end;
  Measure(FProc, FRegionFrames, FPeakA, FRmsA);
  Analyse;
  pbScope.Invalidate;
  pbCurve.Invalidate;
  pbGraph2.Invalidate;
end;

{ ---- the graphs beside the knobs ---- }

const
  SPEC_BANDS = 160;       // log-spaced bands, 20 Hz .. 20 kHz
  SPEC_N = 4096;          // FFT size
  ENV_FLOOR = -80.0;      // dB shown at the bottom of the level graph

function KindHas(const AKind: string; const AWords: array of string): Boolean;
var
  w: string;
begin
  for w in AWords do
    if Pos(w, LowerCase(AKind)) > 0 then Exit(True);
  Result := False;
end;

{ Picks the two graphs that tell the most about this effect: the calculated response where the
  effect has one, the stereo picture for the effects that work on it, the level graph for the
  ones that act on level or time, the spectrum for the ones that act on tone. All but the
  calculated response are measured from the rendered audio. }
procedure TfrmEffectEditor.ChooseGraphs;
var
  ck: TCurveKind;
  haveAudio: Boolean;
begin
  haveAudio := FTotalFrames > 0;
  FGraphs[0] := egNone;
  FGraphs[1] := egNone;
  ck := CurveKindFor(FKind);
  if ck = ckFrequency then
  begin
    FGraphs[0] := egCurve;
    if haveAudio then FGraphs[1] := egSpectrum;
  end
  else if ck <> ckNone then
  begin
    FGraphs[0] := egCurve;
    if haveAudio then FGraphs[1] := egEnvelope;
  end
  else if not haveAudio then
    Exit
  else if KindHas(FKind, ['stereo', 'pan', 'midside', 'haas', 'swaplr', 'crossfeed', 'monobass',
      'vocalchannel', 'invertphase', 'ensemble', 'rotary']) then
  begin
    FGraphs[0] := egStereo;
    FGraphs[1] := egEnvelope;
  end
  else if KindHas(FKind, ['delay', 'echo', 'reverb', 'comb', 'multitap', 'stutter', 'convolve',
      'gater', 'tapestop', 'fade', 'rider', 'gain', 'loudnorm', 'peaknorm', 'limiter', 'tplimiter',
      'transient', 'comp', 'gate', 'expand']) then
  begin
    FGraphs[0] := egEnvelope;
    FGraphs[1] := egSpectrum;
  end
  else
  begin
    FGraphs[0] := egSpectrum;
    FGraphs[1] := egEnvelope;
  end;
end;

procedure Fft(var Re, Im: TArray<Double>);
var
  n, i, j, k, m, half: Integer;
  t, ang, wr, wi, ur, ui, vr, vi: Double;
begin
  n := Length(Re);
  j := 0;
  for i := 1 to n - 1 do
  begin
    m := n shr 1;
    while (j and m) <> 0 do
    begin
      j := j xor m;
      m := m shr 1;
    end;
    j := j xor m;
    if i < j then
    begin
      t := Re[i]; Re[i] := Re[j]; Re[j] := t;
      t := Im[i]; Im[i] := Im[j]; Im[j] := t;
    end;
  end;
  half := 1;
  while half < n do
  begin
    ang := -Pi / half;
    wr := FastCos(ang);
    wi := FastSin(ang);
    k := 0;
    while k < n do
    begin
      ur := 1;
      ui := 0;
      for i := 0 to half - 1 do
      begin
        vr := Re[k + i + half] * ur - Im[k + i + half] * ui;
        vi := Re[k + i + half] * ui + Im[k + i + half] * ur;
        Re[k + i + half] := Re[k + i] - vr;
        Im[k + i + half] := Im[k + i] - vi;
        Re[k + i] := Re[k + i] + vr;
        Im[k + i] := Im[k + i] + vi;
        t := ur * wr - ui * wi;
        ui := ur * wi + ui * wr;
        ur := t;
      end;
      Inc(k, half * 2);
    end;
    half := half * 2;
  end;
end;

{ average spectrum of the channels mixed to mono over the whole buffer (region and tail), Hann
  windowed, in dB per log-spaced band }
procedure TfrmEffectEditor.SpectrumOf(const AData: TAudioPlanar; out ABands: TArray<Single>);
var
  re, im, win, acc: TArray<Double>;
  cnt: TArray<Integer>;
  fr: TArray<Double>;
  pos, hop, i, c, k, b, frames, lastB: Integer;
  s, f, a: Double;
begin
  SetLength(ABands, SPEC_BANDS);
  for b := 0 to SPEC_BANDS - 1 do ABands[b] := -100;
  if (Length(AData) < 1) or (FTotalFrames < 1) or (FRate < 1) then Exit;
  SetLength(re, SPEC_N);
  SetLength(im, SPEC_N);
  SetLength(win, SPEC_N);
  SetLength(acc, SPEC_BANDS);
  SetLength(cnt, SPEC_BANDS);
  SetLength(fr, SPEC_BANDS);
  for i := 0 to SPEC_N - 1 do win[i] := 0.5 - 0.5 * FastCos(2 * Pi * i / (SPEC_N - 1));
  hop := Max(SPEC_N div 2, (FTotalFrames - SPEC_N) div 48);
  frames := 0;
  pos := 0;
  repeat
    for i := 0 to SPEC_N - 1 do
    begin
      s := 0;
      if pos + i < FTotalFrames then
        for c := 0 to High(AData) do s := s + AData[c][pos + i];
      re[i] := s / Length(AData) * win[i];
      im[i] := 0;
    end;
    Fft(re, im);
    for b := 0 to SPEC_BANDS - 1 do fr[b] := 0;
    for k := 1 to SPEC_N div 2 do
    begin
      f := k * FRate / SPEC_N;
      if (f < 20) or (f > 20000) then Continue;
      b := EnsureRange(Round(FastLn(f / 20) / FastLn(1000) * (SPEC_BANDS - 1)), 0, SPEC_BANDS - 1);
      a := 4 * Sqrt(re[k] * re[k] + im[k] * im[k]) / SPEC_N;   // amplitude of a sine at this bin
      if a > fr[b] then fr[b] := a;
    end;
    for b := 0 to SPEC_BANDS - 1 do
      if fr[b] > 0 then
      begin
        acc[b] := acc[b] + fr[b] * fr[b];
        Inc(cnt[b]);
      end;
    Inc(frames);
    Inc(pos, hop);
  until (pos + SPEC_N > FTotalFrames) or (frames >= 64);
  lastB := -1;
  for b := 0 to SPEC_BANDS - 1 do
    if cnt[b] > 0 then
    begin
      ABands[b] := 10 * FastLog10(Max(1e-14, acc[b] / cnt[b]));
      lastB := b;
    end
    else if lastB >= 0 then
      ABands[b] := ABands[lastB];   // below the first bin's reach: hold the neighbour
  { leading bands with no bin of their own take the first measured value }
  for b := 0 to SPEC_BANDS - 1 do
    if cnt[b] > 0 then
    begin
      for i := 0 to b - 1 do ABands[i] := ABands[b];
      Break;
    end;
end;

{ RMS level in dB per 10 ms, all channels }
procedure TfrmEffectEditor.EnvelopeOf(const AData: TAudioPlanar; out AEnv: TArray<Single>);
var
  win, n, i, c, f: Integer;
  sum, v: Double;
begin
  SetLength(AEnv, 0);
  if (Length(AData) < 1) or (FRate < 1) or (FTotalFrames < 1) then Exit;
  win := Max(1, FRate div 100);
  n := FTotalFrames div win;
  SetLength(AEnv, n);
  for i := 0 to n - 1 do
  begin
    sum := 0;
    for c := 0 to High(AData) do
      for f := i * win to i * win + win - 1 do
      begin
        v := AData[c][f];
        sum := sum + v * v;
      end;
    sum := sum / (win * Length(AData));
    if sum < 1e-12 then AEnv[i] := ENV_FLOOR else AEnv[i] := Max(ENV_FLOOR, 10 * FastLog10(sum));
  end;
end;

procedure TfrmEffectEditor.Analyse;
begin
  SpectrumOf(FSrc, FSpecB);
  SpectrumOf(FProc, FSpecA);
  EnvelopeOf(FSrc, FEnvB);
  EnvelopeOf(FProc, FEnvA);
end;

procedure TfrmEffectEditor.DrawGraph(AView: TGLView; ASlot: Integer);
var
  pal: TPalette;
  cv: TGLCanvas;
  w, h, i, x, y, x0, y0, n, c, step, endX: Integer;
  title, tag: string;
  fx: Double;
  lb, la, sb, sa, sx, sy, cb, ca: Double;

  procedure Label_(const AText: string; AX, AY: Integer; AColor: TColor);
  begin
    cv.Brush.Style := bsClear;
    cv.Font.Color := AColor;
    cv.TextOut(AX, AY, AText);
    cv.Brush.Style := bsSolid;
  end;

  procedure Series(const ASeries: TArray<Single>; AColor: TColor; AFloor, ATop: Double);
  var
    k, px, py, count: Integer;
  begin
    count := Length(ASeries);
    if count < 2 then Exit;
    cv.Pen.Style := psSolid;
    cv.Pen.Color := AColor;
    cv.Pen.Width := 1;
    for k := 0 to count - 1 do
    begin
      px := Round(k / (count - 1) * (w - 1));
      py := Round((ATop - EnsureRange(Double(ASeries[k]), AFloor, ATop)) / (ATop - AFloor) * (h - 20)) + 16;
      if k = 0 then cv.MoveTo(px, py) else cv.LineTo(px, py);
    end;
    cv.Pen.Style := psClear;
  end;

  procedure HLine(AY: Integer; const AText: string);
  begin
    cv.Pen.Style := psSolid;
    cv.Pen.Color := pal.Grid;
    cv.MoveTo(0, AY);
    cv.LineTo(w, AY);
    cv.Pen.Style := psClear;
    if AText <> '' then Label_(AText, 2, AY - 11, pal.Muted);
  end;

begin
  cv := AView.GL;
  w := AView.Width;
  h := AView.Height;
  pal := Palette;
  cv.Font.Size := 7;
  case FGraphs[ASlot] of
    egCurve:
      begin
        PaintEffectCurve(cv, w, h, FKind, CurrentParams);
        Label_('response (calculated)', 4, 2, pal.Muted);
      end;
    egSpectrum:
      begin
        cv.Brush.Style := bsSolid;
        cv.Pen.Style := psClear;
        cv.Brush.Color := pal.Bg;
        cv.FillRect(Rect(0, 0, w, h));
        for i := 0 to 4 do HLine(16 + Round(i / 4 * (h - 20)), Format('%d dB', [-i * 20]));
        for i := 0 to 2 do
        begin
          fx := FastLn(IfThen(i = 0, 100, IfThen(i = 1, 1000, 10000)) / 20) / FastLn(1000);
          x := Round(fx * (w - 1));
          cv.Pen.Style := psSolid;
          cv.Pen.Color := pal.Grid;
          cv.MoveTo(x, 16);
          cv.LineTo(x, h);
          cv.Pen.Style := psClear;
          Label_(IfThen(i = 0, '100', IfThen(i = 1, '1k', '10k')), x + 2, h - 11, pal.Muted);
        end;
        Series(FSpecB, pal.Before, -80, 0);
        Series(FSpecA, pal.After, -80, 0);
        Label_('spectrum (measured)', 4, 2, pal.Ink);
        Label_('before', w - 90, 2, pal.Before);
        Label_('after', w - 44, 2, pal.After);
      end;
    egEnvelope:
      begin
        cv.Brush.Style := bsSolid;
        cv.Pen.Style := psClear;
        cv.Brush.Color := pal.Bg;
        cv.FillRect(Rect(0, 0, w, h));
        for i := 0 to 4 do HLine(16 + Round(i / 4 * (h - 20)), Format('%d dB', [-i * 20]));
        n := Length(FEnvB);
        if n > 1 then
        begin
          endX := Round(FRegionFrames / FTotalFrames * (w - 1));
          cv.Brush.Color := pal.Tail;
          cv.FillRect(Rect(endX, 16, w, h));
        end;
        Series(FEnvB, pal.Before, ENV_FLOOR, 0);
        Series(FEnvA, pal.After, ENV_FLOOR, 0);
        Label_('level over time (measured)', 4, 2, pal.Ink);
        Label_('before', w - 90, 2, pal.Before);
        Label_('after', w - 44, 2, pal.After);
      end;
    egStereo:
      begin
        cv.Brush.Style := bsSolid;
        cv.Pen.Style := psClear;
        cv.Brush.Color := pal.Bg;
        cv.FillRect(Rect(0, 0, w, h));
        Label_('stereo picture (measured)', 4, 2, pal.Ink);
        if (Length(FSrc) < 2) or (FRegionFrames < 2) then
        begin
          Label_('mono audio - nothing to show', 8, h div 2, pal.Muted);
          Exit;
        end;
        x0 := w div 2;
        y0 := 16 + (h - 16) div 2;
        n := Min(x0 - 6, (h - 20) div 2);
        cv.Pen.Style := psSolid;
        cv.Pen.Color := pal.Grid;
        cv.MoveTo(x0 - n, y0);
        cv.LineTo(x0 + n, y0);
        cv.MoveTo(x0, y0 - n);
        cv.LineTo(x0, y0 + n);
        cv.MoveTo(x0 - n, y0 + n);
        cv.LineTo(x0 + n, y0 - n);
        cv.Pen.Style := psClear;
        Label_('L', x0 - n - 10, y0 - 5, pal.Muted);
        Label_('R', x0 + n + 3, y0 - 5, pal.Muted);
        step := Max(1, FRegionFrames div 1500);
        for c := 0 to 1 do
        begin
          { L on the horizontal, R on the vertical: a mono sound is the diagonal }
          if c = 0 then cv.Brush.Color := MixCol(pal.Bg, pal.Before, 0.6) else cv.Brush.Color := pal.After;
          i := 0;
          while i < FRegionFrames do
          begin
            if c = 0 then
            begin
              sx := FSrc[0][i];
              sy := FSrc[1][i];
            end
            else
            begin
              sx := FProc[0][i];
              sy := FProc[1][i];
            end;
            x := x0 + Round(EnsureRange(sx, -1, 1) * n);
            y := y0 - Round(EnsureRange(sy, -1, 1) * n);
            cv.FillRect(Rect(x, y, x + 2, y + 2));
            Inc(i, step);
          end;
        end;
        { correlation and width, before and after }
        sb := 0; sa := 0; lb := 0; la := 0; cb := 0; ca := 0;
        for i := 0 to FRegionFrames - 1 do
        begin
          sb := sb + FSrc[0][i] * FSrc[1][i];
          lb := lb + FSrc[0][i] * FSrc[0][i];
          cb := cb + FSrc[1][i] * FSrc[1][i];
          sa := sa + FProc[0][i] * FProc[1][i];
          la := la + FProc[0][i] * FProc[0][i];
          ca := ca + FProc[1][i] * FProc[1][i];
        end;
        if lb * cb > 0 then tag := Format('%.2f', [sb / Sqrt(lb * cb)]) else tag := '-';
        title := 'correlation before ' + tag;
        if la * ca > 0 then tag := Format('%.2f', [sa / Sqrt(la * ca)]) else tag := '-';
        Label_(title, 4, h - 24, pal.Before);
        Label_('after ' + tag + '   (1 = mono, 0 = wide, <0 = phase trouble)', 4, h - 12, pal.After);
      end;
  else
    ;
  end;
end;

procedure TfrmEffectEditor.pbGraph2Paint(Sender: TObject);
begin
  DrawGraph(pbGraph2, 1);
end;

function DbText(AValue: Double): string;
begin
  if AValue < 0.000001 then Result := '-inf dB' else Result := Format('%.1f dB', [20 * FastLog10(AValue)]);
end;

{ ---- the audio as it is ---- }

procedure TfrmEffectEditor.ResetScopeView;
begin
  FViewStart := 0;
  FViewLen := Max(1, FTotalFrames);
end;

function TfrmEffectEditor.ScopeFrameAt(AX: Integer): Integer;
begin
  Result := EnsureRange(FViewStart + Round(AX / Max(1, pbScope.Width) * FViewLen), 0,
    Max(0, FTotalFrames - 1));
end;

procedure TfrmEffectEditor.ScopeZoom(AFactor: Double; ACenterFrame: Integer);
var
  newLen: Integer;
  rel: Double;
begin
  if FTotalFrames < 2 then Exit;
  newLen := EnsureRange(Round(FViewLen * AFactor), Min(32, FTotalFrames), FTotalFrames);
  rel := (ACenterFrame - FViewStart) / Max(1, FViewLen);
  FViewStart := EnsureRange(ACenterFrame - Round(rel * newLen), 0, FTotalFrames - newLen);
  FViewLen := newLen;
  pbScope.Invalidate;
end;

procedure TfrmEffectEditor.pbScopeMouseWheel(Sender: TObject; Shift: TShiftState;
  WheelDelta: Integer; MousePos: TPoint; var Handled: Boolean);
var
  p: TPoint;
begin
  Handled := True;
  if FTotalFrames < 2 then Exit;
  p := pbScope.ScreenToClient(Mouse.CursorPos);
  if ssShift in Shift then
  begin
    FViewStart := EnsureRange(FViewStart - Sign(WheelDelta) * Max(1, FViewLen div 10), 0,
      FTotalFrames - FViewLen);
    pbScope.Invalidate;
  end
  else if WheelDelta > 0 then
    ScopeZoom(0.75, ScopeFrameAt(p.X))
  else
    ScopeZoom(1.33, ScopeFrameAt(p.X));
end;

procedure TfrmEffectEditor.pbScopeMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
begin
  FHoverX := X;
  pbScope.Invalidate;
end;

procedure TfrmEffectEditor.pbScopeMouseLeave(Sender: TObject);
begin
  FHoverX := -1;
  pbScope.Invalidate;
end;

procedure TfrmEffectEditor.pbScopeDblClick(Sender: TObject);
begin
  ResetScopeView;
  pbScope.Invalidate;
end;

{ The region's own samples before (top) and after (bottom) the effect, one lane per channel (the
  first two), on one scale so a level change is visible. Zoomed out, every pixel column shows the
  lowest and highest sample it covers; zoomed in far enough, the samples themselves are drawn
  and marked. The cursor reads out the exact value of every sample under it. The dimmed area to
  the right of the dashed line is the tail past the region's end: it shows an effect ringing on,
  but only the region itself is rewritten when the effect is applied. }
procedure TfrmEffectEditor.pbScopePaint(Sender: TObject);
const
  HEAD = 16;
  FOOT = 16;
var
  cv: TGLCanvas;
  pal: TPalette;
  w, h, ph, pane, lane, lanes, laneH, mid, x, f, f0, f1, endX, px, py, prevX, prevY, hv, top, c: Integer;
  lo, hi, v, scale, spp: Double;
  data: TAudioPlanar;
  col: TColor;
  title, rd, chName: string;
begin
  cv := pbScope.GL;
  w := pbScope.Width;
  h := pbScope.Height;
  pal := Palette;
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psClear;
  cv.Brush.Color := pal.Bg;
  cv.FillRect(Rect(0, 0, w, h));
  cv.Font.Size := 8;
  if FTotalFrames < 1 then
  begin
    cv.Brush.Style := bsClear;
    cv.Font.Color := pal.Muted;
    cv.TextOut(10, h div 2 - 7, 'No audio region to show - the effect will be heard when it is applied.');
    Exit;
  end;
  lanes := Max(1, Min(2, Length(FSrc)));
  ph := (h - FOOT) div 2;
  laneH := (ph - HEAD) div lanes;
  scale := Max(1.0, Max(FPeakB, FPeakA));
  spp := FViewLen / Max(1, w);
  endX := Round((FRegionFrames - FViewStart) / FViewLen * w);
  hv := -1;
  if (FHoverX >= 0) and (FHoverX < w) then hv := ScopeFrameAt(FHoverX);

  for pane := 0 to 1 do
  begin
    top := pane * ph;
    if pane = 0 then
    begin
      data := FSrc;
      col := pal.Before;
      title := Format('Before - the audio as it is     peak %s     RMS %s', [DbText(FPeakB), DbText(FRmsB)]);
    end
    else
    begin
      data := FProc;
      col := pal.After;
      title := Format('After - with these settings     peak %s     RMS %s', [DbText(FPeakA), DbText(FRmsA)]);
    end;
    { pane header and the tail past the region }
    cv.Brush.Color := pal.Head;
    cv.FillRect(Rect(0, top, w, top + HEAD));
    if endX < w then
    begin
      cv.Brush.Color := pal.Tail;
      cv.FillRect(Rect(Max(0, endX), top + HEAD, w, top + ph));
    end;
    cv.Brush.Style := bsClear;
    cv.Font.Color := pal.Ink;
    cv.TextOut(6, top + 2, title);
    cv.Brush.Style := bsSolid;
    for lane := 0 to lanes - 1 do
    begin
      mid := top + HEAD + lane * laneH + laneH div 2;
      { centre line and the full-scale guides }
      cv.Brush.Color := pal.Grid;
      cv.FillRect(Rect(0, mid, w, mid + 1));
      cv.FillRect(Rect(0, mid - (laneH div 2 - 2), w, mid - (laneH div 2 - 2) + 1));
      cv.FillRect(Rect(0, mid + (laneH div 2 - 2), w, mid + (laneH div 2 - 2) + 1));
      if lanes > 1 then
      begin
        if lane = 0 then chName := 'L' else chName := 'R';
        cv.Brush.Style := bsClear;
        cv.Font.Color := pal.Muted;
        cv.TextOut(w - 12, mid - laneH div 2 + 2, chName);
        cv.Brush.Style := bsSolid;
      end;
      if (Length(data) <= lane) or (Length(data[lane]) < FTotalFrames) then Continue;
      cv.Pen.Style := psSolid;
      cv.Pen.Color := col;
      cv.Brush.Color := col;
      if spp > 1.5 then
      begin
        { zoomed out: the lowest and highest sample of every pixel column }
        for x := 0 to w - 1 do
        begin
          f0 := FViewStart + Trunc(x * spp);
          f1 := Min(FTotalFrames, FViewStart + Max(Trunc(x * spp) + 1, Trunc((x + 1) * spp)));
          if f0 >= FTotalFrames then Break;
          lo := data[lane][f0];
          hi := lo;
          for f := f0 + 1 to f1 - 1 do
          begin
            v := data[lane][f];
            if v < lo then lo := v;
            if v > hi then hi := v;
          end;
          cv.MoveTo(x, mid - Round(EnsureRange(hi / scale, -1, 1) * (laneH div 2 - 3)));
          cv.LineTo(x, mid - Round(EnsureRange(lo / scale, -1, 1) * (laneH div 2 - 3)) + 1);
        end;
      end
      else
      begin
        { zoomed in: every sample, joined by lines, and marked once they are far enough apart }
        prevX := -1;
        prevY := 0;
        for f := Max(0, FViewStart - 1) to Min(FTotalFrames - 1, FViewStart + FViewLen + 1) do
        begin
          px := Round((f - FViewStart + 0.5) / FViewLen * w);
          py := mid - Round(EnsureRange(data[lane][f] / scale, -1, 1) * (laneH div 2 - 3));
          if prevX >= 0 then
          begin
            cv.MoveTo(prevX, prevY);
            cv.LineTo(px, py);
          end;
          if w / FViewLen >= 5 then cv.FillRect(Rect(px - 2, py - 2, px + 3, py + 3));
          prevX := px;
          prevY := py;
        end;
      end;
      cv.Pen.Style := psClear;
    end;
  end;

  { the region's end }
  cv.Pen.Style := psDot;
  cv.Pen.Color := pal.Muted;
  if (endX > 0) and (endX < w) then
  begin
    cv.MoveTo(endX, 0);
    cv.LineTo(endX, h - FOOT);
  end;
  cv.Pen.Style := psClear;
  if FRenderErr <> '' then
  begin
    cv.Brush.Style := bsClear;
    cv.Font.Color := clRed;
    cv.TextOut(6, ph + HEAD + 4, 'Could not render: ' + FRenderErr);
    cv.Brush.Style := bsSolid;
  end;

  { the cursor and its readout, or a hint line }
  cv.Brush.Color := pal.Head;
  cv.FillRect(Rect(0, h - FOOT, w, h));
  cv.Brush.Style := bsClear;
  cv.Font.Color := pal.Ink;
  if hv >= 0 then
  begin
    cv.Pen.Style := psSolid;
    cv.Pen.Color := pal.Ink;
    cv.MoveTo(FHoverX, 0);
    cv.LineTo(FHoverX, h - FOOT);
    cv.Pen.Style := psClear;
    rd := Format('%.3f ms   sample %d   before', [hv / FRate * 1000, hv]);
    for c := 0 to lanes - 1 do
      if hv < Length(FSrc[c]) then rd := rd + Format('  %s %.5f', [IfThen(c = 0, 'L', 'R'), FSrc[c][hv]]);
    rd := rd + '   after';
    for c := 0 to Min(lanes, Length(FProc)) - 1 do
      if hv < Length(FProc[c]) then rd := rd + Format('  %s %.5f', [IfThen(c = 0, 'L', 'R'), FProc[c][hv]]);
    if hv >= FRegionFrames then rd := rd + '   (tail)';
    cv.TextOut(6, h - FOOT + 2, rd);
  end
  else
  begin
    rd := 'Wheel zooms, Shift+wheel scrolls, double-click shows it all.';
    if FFullFrames > FRegionFrames then
      rd := rd + Format('   Showing the first %.1f s of %.1f s - the whole region is processed on OK.',
        [FRegionFrames / FRate, FFullFrames / FRate]);
    cv.TextOut(6, h - FOOT + 2, rd);
  end;
  cv.Brush.Style := bsSolid;
end;
function TfrmEffectEditor.TextValueOf(const AMap: TStringList; const AKey, ADefault: string): string;
var
  i: Integer;
begin
  i := AMap.IndexOfName(AKey);
  if i >= 0 then Result := AMap.ValueFromIndex[i] else Result := ADefault;
end;

{ the settings string for what the controls show now, in the order the settings were given }
function TfrmEffectEditor.CurrentParams: string;
var
  map: TStringList;
  k, v: TArray<string>;
  i, j: Integer;
  used: TStringList;

  procedure Put(const AKey, AValue: string);
  begin
    if Result <> '' then Result := Result + ';';
    Result := Result + AKey + '=' + AValue;
  end;

  function KnobIndex(const AKey: string): Integer;
  var
    n: Integer;
  begin
    for n := 0 to FKnobCount - 1 do
      if SameText(FKnobKey[n], AKey) then Exit(n);
    Result := -1;
  end;

  function CheckIndex(const AKey: string): Integer;
  var
    n: Integer;
  begin
    for n := 0 to FCheckCount - 1 do
      if SameText(FCheckKey[n], AKey) then Exit(n);
    Result := -1;
  end;

begin
  Result := '';
  map := TStringList.Create;
  used := TStringList.Create;
  try
    map.NameValueSeparator := '=';
    SplitParams(edtText.Text, k, v);
    for i := 0 to High(k) do map.Add(k[i] + '=' + v[i]);
    for i := 0 to High(FKeys) do
    begin
      j := KnobIndex(FKeys[i]);
      if j >= 0 then
        Put(FKeys[i], FormatFloat('0.####', FKnobs[j].Position, InvFmt))
      else
      begin
        j := CheckIndex(FKeys[i]);
        if j >= 0 then
          Put(FKeys[i], IfThen(FChecks[j].Checked, '1', '0'))
        else
          Put(FKeys[i], TextValueOf(map, FKeys[i], FValues[i]));
      end;
      used.Add(FKeys[i]);
    end;
    { settings the user typed that the effect was not opened with }
    for i := 0 to High(k) do
      if used.IndexOf(k[i]) < 0 then Put(k[i], v[i]);
  finally
    used.Free;
    map.Free;
  end;
end;

procedure TfrmEffectEditor.ControlChanged(Sender: TObject);
begin
  if FBusy then Exit;
  pbCurve.Invalidate;
end;

procedure TfrmEffectEditor.pbCurvePaint(Sender: TObject);
begin
  DrawGraph(pbCurve, 0);
end;

procedure TfrmEffectEditor.btnResetClick(Sender: TObject);
begin
  { back to the settings the window was opened with }
  Setup(lblTitle.Caption, FKind, FStartText);
end;

procedure TfrmEffectEditor.btnPreviewClick(Sender: TObject);
begin
  if Assigned(FOnPreview) then FOnPreview(CurrentParams);
end;

procedure TfrmEffectEditor.btnOKClick(Sender: TObject);
begin
  ModalResult := mrOk;
end;

procedure TfrmEffectEditor.btnCancelClick(Sender: TObject);
begin
  ModalResult := mrCancel;
end;

initialization
  BuildSpecs;

finalization
  GSpecs.Free;

end.
