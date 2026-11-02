unit UDAW.UI.ThemeColors;
{$I udaw.inc}

{ Phase 29 - Theming System (plan section 47, lines 2738-2801).

  UDAW.UI.Theme (Phase "Settings tab + VCL themes") only ever skinned native
  controls via whole .vsf VCL styles - Windows-only in practice, and it had
  no concept of the per-role semantic colours the plan actually asks for
  ("background, panels, text, secondary text, borders, accent, selection,
  waveform, grid, meters, clipping, automation, MIDI notes"). This unit adds
  that: TUDAWTheme is a plain colour record, platform-independent (it never
  touches Vcl.Themes/TStyleManager), five built-in themes ship, and the
  custom-drawn surfaces in UDAW.UI.MainForm (waveform, meters, piano-roll /
  tracker grids) read CurrentTheme.* instead of hardcoded clXxx constants -
  "never scatter hardcoded colours throughout UI code".

  A user can save an edited copy of any theme (Theme Editor -> Save Theme),
  export/import it as a small text file, or reset a built-in name back to its
  shipped colours. Edited themes are stored one-per-file under
  <data>/themes/<name>.udawtheme and shadow the built-in of the same name;
  ThemeColorsReset removes the shadow file. }

interface

uses
  SysUtils, Classes, Graphics,
  UDAW.Config, UDAW.Paths;

const
  CFG_SEC_UI_COLOR     = 'ui';
  CFG_UI_COLOR_THEME   = 'colortheme';
  THEME_COLORS_DEFAULT = 'Studio Dark';

type
  { A colour for an effect that has no dedicated TUDAWTheme field: every other
    audio effect and every video effect. Key is the effect name ('Echo') or
    'video:<id>'. Effects with no entry get a stable generated colour. }
  TNamedColor = record
    Key: string;
    Color: TColor;
  end;

  TFadeDisplayMode = (fdmColours, fdmCurves, fdmColoursAndCurves);
  TUDAWTheme = record
    Name: string;
    Background: TColor;
    PanelBackground: TColor;
    ClipEffectsBackground: TColor;
    FadeInBackground, FadeOutBackground: TColor;
    LockColor: TColor;               // the padlock on locked clips, markers, scenes and chords
    ControlSelection: TColor;        // selected rows, ticked boxes and the gliding selection pill of lists and trees
    ControlSelectionText: TColor;    // text on a selected row
    ControlHover: TColor;            // the glow that follows the mouse over a list or tree row
    ControlFocus: TColor;            // the outline of the control that has the keyboard focus
    Text: TColor;
    SecondaryText: TColor;
    Border: TColor;
    Accent: TColor;
    Selection: TColor;
    Waveform: TColor;
    Grid: TColor;
    Meter: TColor;
    MeterClip: TColor;
    Automation: TColor;
    MidiNote: TColor;
    LogTrace: TColor;
    LogDebug: TColor;
    LogInfo: TColor;
    LogWarn: TColor;
    LogError: TColor;
    LogCritical: TColor;
    { one swatch per Timeline "Effects" menu entry (UDAW.UI.MainForm's
      TlFxMenuClick Tag values 1..11) - not yet read by any renderer, but
      lets each effect be told apart at a glance wherever a future UI wants
      to colour-code by effect. }
    FxCompressor, FxReverb, FxChorus, FxFlanger, FxPhaser, FxTremolo,
    FxAutoPan, FxSaturation, FxBitCrusher, FxBrightenEQ, FxSilence: TColor;
    FxAmplify, FxDeEsser, FxDelay, FxExpander, FxFoldback, FxGate, FxHardClip,
    FxLimiter, FxPingPongDelay,
    FxBalance, FxBassEnhance, FxDCOffsetRemover, FxExciter, FxHighPassFilter, FxLowPassFilter, FxMakeMono, FxMultibandCompressor, FxNotchFilter, FxPitchShift, FxPresenceBoost, FxStereoWidener, FxTransientShaper, FxTrebleBoost: TColor;
    ExtraFx: TArray<TNamedColor>;   // see TNamedColor
    Trk: array[0..29] of TColor;     // tracker colours, indexed by TTrkColorRole
    Score: array[0..9] of TColor;    // Score / guitar-tab colours, indexed by TScoreColorRole
  end;

  { the Score tab's colour roles: staff notation and guitar tablature }
  TScoreColorRole = (
    scrPage, scrInk, scrStaff, scrLedger, scrTabString, scrTabNumber, scrTabOutline,
    scrPlayhead, scrChord, scrBarNumber);

  { the tracker's colour roles (pattern grid, channel headers, LEDs, sequence strip) }
  TTrkColorRole = (
    tcGridTop, tcGridBottom, tcBeatRow, tcBarRow, tcLines, tcGutter, tcRowNumber, tcHeader, tcHeaderText, tcNote, tcInstrument, tcVolume, tcEffect, tcParam, tcEmpty, tcNoteOff, tcNoteCut, tcCursor, tcCursorField, tcHover, tcPlaying, tcLedIdle, tcLedNormal, tcLedHot, tcLedPeak, tcMuted, tcFxActive, tcSeqStep, tcSeqCurrent, tcSeqPlaying);

  { One editable colour role, for a data-driven "Colors" settings page - each
    entry is a (display name, getter, setter) triple over TUDAWTheme so the
    UI can list/edit every swatch without one designed control per colour. }
  TColorSwatch = (
    csBackground, csPanelBackground, csText, csSecondaryText, csBorder,
    csAccent, csSelection, csWaveform, csGrid, csMeter, csMeterClip,
    csAutomation, csMidiNote,
    csLogTrace, csLogDebug, csLogInfo, csLogWarn, csLogError, csLogCritical,
    csClipEffectsBackground, csFadeInBackground, csFadeOutBackground, csTimelineLock,
    csControlSelection, csControlSelectionText, csControlHover, csControlFocus,
    csFxCompressor, csFxReverb, csFxChorus, csFxFlanger, csFxPhaser,
    csFxTremolo, csFxAutoPan, csFxSaturation, csFxBitCrusher, csFxBrightenEQ,
    csFxSilence, csFxAmplify, csFxDeEsser, csFxDelay, csFxExpander, csFxFoldback,
    csFxGate, csFxHardClip, csFxLimiter, csFxPingPongDelay,
    csFxBalance, csFxBassEnhance, csFxDCOffsetRemover, csFxExciter, csFxHighPassFilter, csFxLowPassFilter, csFxMakeMono, csFxMultibandCompressor, csFxNotchFilter, csFxPitchShift, csFxPresenceBoost, csFxStereoWidener, csFxTransientShaper, csFxTrebleBoost,
    csTrkGridTop, csTrkGridBottom, csTrkBeatRow, csTrkBarRow, csTrkLines, csTrkGutter, csTrkRowNumber, csTrkHeader, csTrkHeaderText, csTrkNote, csTrkInstrument, csTrkVolume, csTrkEffect, csTrkParam, csTrkEmpty, csTrkNoteOff, csTrkNoteCut, csTrkCursor, csTrkCursorField, csTrkHover, csTrkPlaying, csTrkLedIdle, csTrkLedNormal, csTrkLedHot, csTrkLedPeak, csTrkMuted, csTrkFxActive, csTrkSeqStep, csTrkSeqCurrent, csTrkSeqPlaying,
    csScorePage, csScoreInk, csScoreStaff, csScoreLedger, csScoreTabString, csScoreTabNumber,
    csScoreTabOutline, csScorePlayhead, csScoreChord, csScoreBarNumber);

{ Colour of an effect without a dedicated field (see TNamedColor): the
  theme's saved colour for AKey, else a stable colour generated from the name
  so every effect is distinguishable out of the box. }
function ThemeExtraFxGet(const ATheme: TUDAWTheme; const AKey: string): TColor;
procedure ThemeExtraFxSet(var ATheme: TUDAWTheme; const AKey: string; AColor: TColor);

{ All built-in theme names, in a fixed display order. }
function ThemeColorsBuiltInNames: TArray<string>;
{ Built-in + any saved custom/edited themes, alphabetical, built-ins first in
  their fixed order followed by any custom name that isn't a built-in name. }
function ThemeColorsAvailable: TArray<string>;

{ The built-in defaults for AName (ignores any saved edit). Raises if AName
  is not a built-in name. }
function ThemeColorsBuiltIn(const AName: string): TUDAWTheme;
{ The theme actually in effect for AName: a saved edit if one exists under
  <data>/themes, otherwise the built-in. Falls back to the default built-in
  if AName matches nothing at all. }
function ThemeColorsGet(const AName: string): TUDAWTheme;

{ The theme currently applied (kept in memory; not re-read from disk on
  every access). }
function ThemeColorsCurrent: TUDAWTheme;
{ Short alias for ThemeColorsCurrent, for terse use at custom-draw call
  sites (CurrentTheme.Waveform, CurrentTheme.Grid, ...). }
function CurrentTheme: TUDAWTheme;
{ One tracker colour of the current theme }
function TrkColor(ARole: TTrkColorRole): TColor;
{ One Score / guitar-tab colour of the current theme }
function ScoreColor(ARole: TScoreColorRole): TColor;
{ Switches the in-memory current theme. Always succeeds - an unknown name
  resolves to THEME_COLORS_DEFAULT. }
procedure ThemeColorsApply(const AName: string);
{ Replaces the in-memory current theme outright, e.g. after a per-swatch
  edit on the Colors settings page - unlike ThemeColorsApply, this does not
  look anything up by name; the caller already has the record it wants live. }
procedure ThemeColorsSetCurrent(const ATheme: TUDAWTheme);

{ Display name for one colour role, in a fixed, stable order for a swatch
  list UI. }
function ColorSwatchName(ASwatch: TColorSwatch): string;
function ColorSwatchGet(const ATheme: TUDAWTheme; ASwatch: TColorSwatch): TColor;
procedure ColorSwatchSet(var ATheme: TUDAWTheme; ASwatch: TColorSwatch; AColor: TColor);

{ Theme Editor support: persist an edited copy under <data>/themes so it
  shadows the built-in (or extends the list, for a new custom name) from now
  on. If ATheme.Name is the theme currently applied, the in-memory current
  theme is updated too. }
function ThemeColorsSave(const ATheme: TUDAWTheme): Boolean;
{ Removes any saved edit for AName, reverting it to its shipped built-in
  colours (a no-op, returning False, for a name that isn't built-in and has
  no saved file - there would be nothing to reset to). }
function ThemeColorsReset(const AName: string): Boolean;

function ThemeColorsExport(const ATheme: TUDAWTheme; const AFilePath: string): Boolean;
function ThemeColorsImport(const AFilePath: string; out ATheme: TUDAWTheme): Boolean;

procedure ThemeColorsInitFromConfig(ACfg: TConfig);
function CurrentFadeDisplay: TFadeDisplayMode;
procedure SetFadeDisplay(AMode: TFadeDisplayMode; ACfg: TConfig);
procedure ThemeColorsSaveToConfig(ACfg: TConfig; const AName: string);

implementation

uses
  UDAW.Errors;

const
  THEME_SUBSYS = 'UI.ThemeColors';

var
  GCurrent: TUDAWTheme;
  GHaveCurrent: Boolean = False;
  GFadeDisplay: TFadeDisplayMode = fdmColours;

{ Builds a TColor directly from its byte layout ($00BBGGRR) instead of
  relying on a platform RGB() helper (Winapi.Windows on Delphi vs. the LCL
  Graphics unit on FPC declare it differently / not at all here). }
function RGB(ARed, AGreen, ABlue: Byte): TColor;
begin
  Result := TColor(ARed or (AGreen shl 8) or (ABlue shl 16));
end;

const
  { default tracker colours, TColor $00BBGGRR, parallel to TTrkColorRole }
  TRK_COLOR_DEFAULTS: array[0..29] of TColor = (
    $002E221E, $0018100E, $008C5A46, $00BE826E, $00120C0A, $00342622, $00A08278, $004E3A34, $00EBDAD2, $00F0E0B0, $0060D8F0, $0060E060, $00E070F0, $00C0A0F0, $00504A44, $0040B0F0, $005050F0, $00E6783C, $005AD6FF, $00FFFFFF, $0078DC3C, $00183018, $0050E040, $0000D0F0, $00403CF0, $004040C8, $0078C846, $003C2C28, $00E6783C, $0078DC3C);

procedure ApplyTrkDefaults(var ATheme: TUDAWTheme);
var
  i: Integer;
begin
  for i := 0 to High(TRK_COLOR_DEFAULTS) do ATheme.Trk[i] := TRK_COLOR_DEFAULTS[i];
end;

{ default Score colours follow the theme's own text / page colours until the user picks others }
procedure ApplyScoreDefaults(var ATheme: TUDAWTheme);

  function Mix(A, B: TColor; T: Double): TColor;
  var
    ca, cb: Integer;
  begin
    ca := ColorToRGB(A);
    cb := ColorToRGB(B);
    Result := RGB(
      Round((ca and $FF) + ((cb and $FF) - (ca and $FF)) * T),
      Round(((ca shr 8) and $FF) + (((cb shr 8) and $FF) - ((ca shr 8) and $FF)) * T),
      Round(((ca shr 16) and $FF) + (((cb shr 16) and $FF) - ((ca shr 16) and $FF)) * T));
  end;

begin
  ATheme.Score[Ord(scrPage)] := ATheme.Background;
  ATheme.Score[Ord(scrInk)] := ATheme.Text;
  ATheme.Score[Ord(scrStaff)] := Mix(ATheme.Background, ATheme.Text, 0.65);
  ATheme.Score[Ord(scrLedger)] := Mix(ATheme.Background, ATheme.Text, 0.9);
  ATheme.Score[Ord(scrTabString)] := Mix(ATheme.Background, ATheme.Text, 0.65);
  ATheme.Score[Ord(scrTabNumber)] := ATheme.Text;
  ATheme.Score[Ord(scrTabOutline)] := ATheme.Background;
  ATheme.Score[Ord(scrPlayhead)] := TColor($0030A0F0);
  ATheme.Score[Ord(scrChord)] := Mix(ATheme.Text, TColor($0070C0F0), 0.6);
  ATheme.Score[Ord(scrBarNumber)] := ATheme.SecondaryText;
end;

function MakeTheme(const AName: string; ABackground, APanelBackground, AText,
  ASecondaryText, ABorder, AAccent, ASelection, AWaveform, AGrid, AMeter,
  AMeterClip, AAutomation, AMidiNote,
  ALogTrace, ALogDebug, ALogInfo, ALogWarn, ALogError, ALogCritical: TColor): TUDAWTheme;
begin
  Result.Name := AName;
  Result.Background := ABackground;
  Result.PanelBackground := APanelBackground;
  Result.ClipEffectsBackground := RGB(74, 69, 115);
  Result.FadeInBackground := RGB(38, 92, 74);
  Result.FadeOutBackground := RGB(104, 69, 43);
  Result.LockColor := RGB(240, 176, 48);
  Result.ControlSelection := RGB(44, 176, 176);
  Result.ControlSelectionText := RGB(255, 255, 255);
  Result.ControlHover := RGB(205, 210, 220);
  Result.ControlFocus := RGB(60, 190, 200);
  { fixed default per-effect palette, same rationale as the clip/fade
    backgrounds above: a colour every built-in theme starts with, that the
    user can then re-pick per swatch on the Colors settings page. }
  Result.FxCompressor := RGB(224, 80, 80);
  Result.FxReverb := RGB(80, 160, 224);
  Result.FxChorus := RGB(120, 200, 120);
  Result.FxFlanger := RGB(200, 160, 80);
  Result.FxPhaser := RGB(180, 100, 220);
  Result.FxTremolo := RGB(220, 200, 80);
  Result.FxAutoPan := RGB(80, 200, 200);
  Result.FxSaturation := RGB(220, 120, 60);
  Result.FxBitCrusher := RGB(140, 140, 140);
  Result.FxBrightenEQ := RGB(240, 220, 140);
  Result.FxSilence := RGB(90, 90, 110);
  Result.FxAmplify := RGB(255, 140, 60);
  Result.FxDeEsser := RGB(120, 200, 190);
  Result.FxDelay := RGB(90, 150, 230);
  Result.FxExpander := RGB(170, 120, 200);
  Result.FxFoldback := RGB(210, 90, 150);
  Result.FxGate := RGB(110, 170, 110);
  Result.FxHardClip := RGB(200, 70, 70);
  Result.FxLimiter := RGB(230, 190, 60);
  Result.FxPingPongDelay := RGB(60, 190, 230);
  Result.FxBalance := RGB(200, 160, 90);
  Result.FxBassEnhance := RGB(190, 80, 60);
  Result.FxDCOffsetRemover := RGB(130, 130, 160);
  Result.FxExciter := RGB(250, 120, 200);
  Result.FxHighPassFilter := RGB(100, 120, 200);
  Result.FxLowPassFilter := RGB(80, 110, 160);
  Result.FxMakeMono := RGB(150, 150, 120);
  Result.FxMultibandCompressor := RGB(220, 150, 90);
  Result.FxNotchFilter := RGB(160, 100, 100);
  Result.FxPitchShift := RGB(120, 90, 220);
  Result.FxPresenceBoost := RGB(230, 210, 90);
  Result.FxStereoWidener := RGB(90, 200, 140);
  Result.FxTransientShaper := RGB(240, 110, 80);
  Result.FxTrebleBoost := RGB(180, 220, 240);
  if (ColorToRGB(AText) and $FF) < 128 then
  begin
    Result.ClipEffectsBackground := RGB(204, 194, 230);
    Result.FadeInBackground := RGB(159, 221, 190);
    Result.FadeOutBackground := RGB(236, 198, 155);
    Result.LockColor := RGB(188, 108, 0);
    Result.ControlSelection := RGB(0, 128, 136);
    Result.ControlHover := RGB(60, 70, 90);
    Result.ControlFocus := RGB(0, 120, 150);
  end;
  Result.Text := AText;
  Result.SecondaryText := ASecondaryText;
  Result.Border := ABorder;
  Result.Accent := AAccent;
  Result.Selection := ASelection;
  Result.Waveform := AWaveform;
  Result.Grid := AGrid;
  Result.Meter := AMeter;
  Result.MeterClip := AMeterClip;
  Result.Automation := AAutomation;
  Result.MidiNote := AMidiNote;
  Result.LogTrace := ALogTrace;
  Result.LogDebug := ALogDebug;
  Result.LogInfo := ALogInfo;
  Result.LogWarn := ALogWarn;
  Result.LogError := ALogError;
  Result.LogCritical := ALogCritical;
  ApplyTrkDefaults(Result);
  ApplyScoreDefaults(Result);
end;

function ThemeColorsBuiltInNames: TArray<string>;
begin
  Result := ['Studio Dark', 'Studio Light', 'Midnight', 'Graphite', 'High Contrast'];
end;

function ThemeColorsBuiltIn(const AName: string): TUDAWTheme;
begin
  { colours built with RGB(r,g,b) rather than TColor's $00BBGGRR hex literal
    order, so the numbers below read as ordinary RGB and can't be transposed
    by mistake. }
  if SameText(AName, 'Studio Dark') then
    Exit(MakeTheme('Studio Dark',
      RGB($25,$25,$25), RGB($30,$30,$30), RGB($E6,$E6,$E6), RGB($A0,$A0,$A0),
      RGB($46,$46,$46), RGB($E0,$80,$30), RGB($80,$5C,$3C), RGB($00,$C8,$FF),
      RGB($40,$40,$40), RGB($40,$D0,$60), RGB($FF,$40,$40), RGB($C8,$90,$20),
      RGB($60,$C8,$FF),
      RGB($70,$70,$70), RGB($A0,$A0,$A0), RGB($E6,$E6,$E6), RGB($E8,$C0,$40),
      RGB($FF,$60,$60), RGB($FF,$40,$FF)))
  else if SameText(AName, 'Studio Light') then
    Exit(MakeTheme('Studio Light',
      RGB($F2,$F2,$F2), RGB($FF,$FF,$FF), RGB($20,$20,$20), RGB($70,$70,$70),
      RGB($C8,$C8,$C8), RGB($E0,$76,$2A), RGB($C8,$A0,$80), RGB($1A,$6E,$BE),
      RGB($C0,$C0,$C0), RGB($20,$A0,$50), RGB($E0,$20,$20), RGB($B8,$78,$18),
      RGB($1E,$7A,$D2),
      RGB($90,$90,$90), RGB($60,$60,$60), RGB($20,$20,$20), RGB($A0,$70,$00),
      RGB($C8,$20,$20), RGB($A0,$20,$A0)))
  else if SameText(AName, 'Midnight') then
    Exit(MakeTheme('Midnight',
      RGB($14,$0F,$0A), RGB($1E,$18,$12), RGB($D8,$D8,$E8), RGB($88,$88,$98),
      RGB($30,$2A,$24), RGB($C0,$60,$FF), RGB($58,$3C,$78), RGB($8C,$6C,$FF),
      RGB($28,$20,$20), RGB($40,$C0,$FF), RGB($FF,$30,$60), RGB($90,$60,$E0),
      RGB($A0,$80,$FF),
      RGB($70,$68,$78), RGB($88,$88,$98), RGB($D8,$D8,$E8), RGB($E0,$B0,$40),
      RGB($FF,$50,$70), RGB($FF,$50,$FF)))
  else if SameText(AName, 'Graphite') then
    Exit(MakeTheme('Graphite',
      RGB($3A,$3A,$3A), RGB($46,$46,$46), RGB($DC,$DC,$DC), RGB($96,$96,$96),
      RGB($58,$58,$58), RGB($90,$90,$90), RGB($68,$68,$68), RGB($B4,$B4,$B4),
      RGB($50,$50,$50), RGB($78,$C8,$78), RGB($E0,$50,$50), RGB($A0,$A0,$A0),
      RGB($C8,$C8,$C8),
      RGB($80,$80,$80), RGB($96,$96,$96), RGB($DC,$DC,$DC), RGB($D8,$B0,$50),
      RGB($E0,$60,$60), RGB($D8,$80,$D8)))
  else if SameText(AName, 'High Contrast') then
    Exit(MakeTheme('High Contrast',
      RGB($00,$00,$00), RGB($00,$00,$00), RGB($FF,$FF,$FF), RGB($FF,$FF,$00),
      RGB($FF,$FF,$FF), RGB($00,$FF,$FF), RGB($00,$00,$FF), RGB($00,$FF,$00),
      RGB($FF,$FF,$FF), RGB($00,$FF,$00), RGB($00,$00,$FF), RGB($FF,$00,$FF),
      RGB($00,$FF,$FF),
      RGB($C0,$C0,$C0), RGB($FF,$FF,$FF), RGB($00,$FF,$FF), RGB($FF,$FF,$00),
      RGB($FF,$00,$00), RGB($FF,$00,$FF)))
  else
    RaiseUDAWFmt(errInvalidArgument, THEME_SUBSYS, '"%s" is not a built-in theme', [AName]);
end;

function ThemeFileFor(const AName: string): string;
begin
  Result := DataFile('themes' + PathDelim + LowerCase(AName) + '.udawtheme');
end;

function LoadThemeFile(const APath: string; out ATheme: TUDAWTheme): Boolean;
var
  lines: TStringList;
  n, v: Integer;

  function Field(const AKey, ADefault: string): string;
  var
    v: string;
  begin
    v := lines.Values[AKey];
    if v = '' then Result := ADefault else Result := v;
  end;

  function ColorField(const AKey: string; ADefault: TColor): TColor;
  var
    n: Integer;
  begin
    if TryStrToInt(lines.Values[AKey], n) then Result := TColor(n) else Result := ADefault;
  end;

begin
  Result := False;
  if not FileExists(APath) then Exit;
  lines := TStringList.Create;
  try
    try
      lines.LoadFromFile(APath);
    except
      Exit(False);
    end;
    ATheme.Name := Field('name', ExtractFileName(APath));
    ATheme.Background := ColorField('background', clBlack);
    ATheme.PanelBackground := ColorField('panelbackground', clBlack);
    ATheme.ClipEffectsBackground := ColorField('clipeffectsbackground', RGB(74, 69, 115));
    ATheme.FadeInBackground := ColorField('fadeinbackground', RGB(38, 92, 74));
    ATheme.FadeOutBackground := ColorField('fadeoutbackground', RGB(104, 69, 43));
    ATheme.LockColor := ColorField('timelinelock', RGB(240, 176, 48));
    ATheme.ControlSelection := ColorField('controlselection', RGB(44, 176, 176));
    ATheme.ControlSelectionText := ColorField('controlselectiontext', RGB(255, 255, 255));
    ATheme.ControlHover := ColorField('controlhover', RGB(205, 210, 220));
    ATheme.ControlFocus := ColorField('controlfocus', RGB(60, 190, 200));
    ATheme.Text := ColorField('text', clWhite);
    ATheme.SecondaryText := ColorField('secondarytext', clSilver);
    ATheme.Border := ColorField('border', clGray);
    ATheme.Accent := ColorField('accent', clYellow);
    ATheme.Selection := ColorField('selection', clNavy);
    ATheme.Waveform := ColorField('waveform', clLime);
    ATheme.Grid := ColorField('grid', clGray);
    ATheme.Meter := ColorField('meter', clLime);
    ATheme.MeterClip := ColorField('meterclip', clRed);
    ATheme.Automation := ColorField('automation', clYellow);
    ATheme.MidiNote := ColorField('midinote', clAqua);
    { added after the first shipped theme-file format; a file saved before
      these existed just falls back to sensible defaults instead of failing
      to load. }
    ATheme.LogTrace := ColorField('logtrace', clGray);
    ATheme.LogDebug := ColorField('logdebug', clSilver);
    ATheme.LogInfo := ColorField('loginfo', ATheme.Text);
    ATheme.LogWarn := ColorField('logwarn', clYellow);
    ATheme.LogError := ColorField('logerror', clRed);
    ATheme.LogCritical := ColorField('logcritical', clFuchsia);
    { added after the first shipped theme-file format, same reasoning as the
      log-level colours above - fall back to the fixed built-in defaults. }
    ATheme.FxCompressor := ColorField('fxcompressor', RGB(224, 80, 80));
    ATheme.FxReverb := ColorField('fxreverb', RGB(80, 160, 224));
    ATheme.FxChorus := ColorField('fxchorus', RGB(120, 200, 120));
    ATheme.FxFlanger := ColorField('fxflanger', RGB(200, 160, 80));
    ATheme.FxPhaser := ColorField('fxphaser', RGB(180, 100, 220));
    ATheme.FxTremolo := ColorField('fxtremolo', RGB(220, 200, 80));
    ATheme.FxAutoPan := ColorField('fxautopan', RGB(80, 200, 200));
    ATheme.FxSaturation := ColorField('fxsaturation', RGB(220, 120, 60));
    ATheme.FxBitCrusher := ColorField('fxbitcrusher', RGB(140, 140, 140));
    ApplyTrkDefaults(ATheme);
    for n := 0 to High(ATheme.Trk) do
      ATheme.Trk[n] := ColorField('trk' + IntToStr(n), ATheme.Trk[n]);
    ApplyScoreDefaults(ATheme);
    for n := 0 to High(ATheme.Score) do
      ATheme.Score[n] := ColorField('score' + IntToStr(n), ATheme.Score[n]);
    ATheme.FxBrightenEQ := ColorField('fxbrighteneq', RGB(240, 220, 140));
    ATheme.FxSilence := ColorField('fxsilence', RGB(90, 90, 110));
    ATheme.FxAmplify := ColorField('fxamplify', RGB(255, 140, 60));
    ATheme.FxDeEsser := ColorField('fxdeesser', RGB(120, 200, 190));
    ATheme.FxDelay := ColorField('fxdelay', RGB(90, 150, 230));
    ATheme.FxExpander := ColorField('fxexpander', RGB(170, 120, 200));
    ATheme.FxFoldback := ColorField('fxfoldback', RGB(210, 90, 150));
    ATheme.FxGate := ColorField('fxgate', RGB(110, 170, 110));
    ATheme.FxHardClip := ColorField('fxhardclip', RGB(200, 70, 70));
    ATheme.FxLimiter := ColorField('fxlimiter', RGB(230, 190, 60));
    ATheme.FxPingPongDelay := ColorField('fxpingpongdelay', RGB(60, 190, 230));
    ATheme.FxBalance := ColorField('fxbalance', RGB(200, 160, 90));
    ATheme.FxBassEnhance := ColorField('fxbassenhance', RGB(190, 80, 60));
    ATheme.FxDCOffsetRemover := ColorField('fxdcoffsetremover', RGB(130, 130, 160));
    ATheme.FxExciter := ColorField('fxexciter', RGB(250, 120, 200));
    ATheme.FxHighPassFilter := ColorField('fxhighpassfilter', RGB(100, 120, 200));
    ATheme.FxLowPassFilter := ColorField('fxlowpassfilter', RGB(80, 110, 160));
    ATheme.FxMakeMono := ColorField('fxmakemono', RGB(150, 150, 120));
    ATheme.FxMultibandCompressor := ColorField('fxmultibandcompressor', RGB(220, 150, 90));
    ATheme.FxNotchFilter := ColorField('fxnotchfilter', RGB(160, 100, 100));
    ATheme.FxPitchShift := ColorField('fxpitchshift', RGB(120, 90, 220));
    ATheme.FxPresenceBoost := ColorField('fxpresenceboost', RGB(230, 210, 90));
    ATheme.FxStereoWidener := ColorField('fxstereowidener', RGB(90, 200, 140));
    ATheme.FxTransientShaper := ColorField('fxtransientshaper', RGB(240, 110, 80));
    ATheme.FxTrebleBoost := ColorField('fxtrebleboost', RGB(180, 220, 240));
    SetLength(ATheme.ExtraFx, 0);
    for n := 0 to lines.Count - 1 do
      if (Copy(lines.Names[n], 1, 4) = 'xfx.') and TryStrToInt(lines.ValueFromIndex[n], v) then
        ThemeExtraFxSet(ATheme, Copy(lines.Names[n], 5, MaxInt), TColor(v));
    Result := True;
  finally
    lines.Free;
  end;
end;

function SaveThemeFile(const ATheme: TUDAWTheme; const APath: string): Boolean;
var
  lines: TStringList;
  n: Integer;
begin
  ForceDirectories(ExtractFilePath(APath));
  lines := TStringList.Create;
  try
    lines.Values['name'] := ATheme.Name;
    lines.Values['background'] := IntToStr(Integer(ATheme.Background));
    lines.Values['panelbackground'] := IntToStr(Integer(ATheme.PanelBackground));
    lines.Values['clipeffectsbackground'] := IntToStr(Integer(ATheme.ClipEffectsBackground));
    lines.Values['fadeinbackground'] := IntToStr(Integer(ATheme.FadeInBackground));
    lines.Values['fadeoutbackground'] := IntToStr(Integer(ATheme.FadeOutBackground));
    lines.Values['timelinelock'] := IntToStr(Integer(ATheme.LockColor));
    lines.Values['controlselection'] := IntToStr(Integer(ATheme.ControlSelection));
    lines.Values['controlselectiontext'] := IntToStr(Integer(ATheme.ControlSelectionText));
    lines.Values['controlhover'] := IntToStr(Integer(ATheme.ControlHover));
    lines.Values['controlfocus'] := IntToStr(Integer(ATheme.ControlFocus));
    lines.Values['text'] := IntToStr(Integer(ATheme.Text));
    lines.Values['secondarytext'] := IntToStr(Integer(ATheme.SecondaryText));
    lines.Values['border'] := IntToStr(Integer(ATheme.Border));
    lines.Values['accent'] := IntToStr(Integer(ATheme.Accent));
    lines.Values['selection'] := IntToStr(Integer(ATheme.Selection));
    lines.Values['waveform'] := IntToStr(Integer(ATheme.Waveform));
    lines.Values['grid'] := IntToStr(Integer(ATheme.Grid));
    lines.Values['meter'] := IntToStr(Integer(ATheme.Meter));
    lines.Values['meterclip'] := IntToStr(Integer(ATheme.MeterClip));
    lines.Values['automation'] := IntToStr(Integer(ATheme.Automation));
    lines.Values['midinote'] := IntToStr(Integer(ATheme.MidiNote));
    lines.Values['logtrace'] := IntToStr(Integer(ATheme.LogTrace));
    lines.Values['logdebug'] := IntToStr(Integer(ATheme.LogDebug));
    lines.Values['loginfo'] := IntToStr(Integer(ATheme.LogInfo));
    lines.Values['logwarn'] := IntToStr(Integer(ATheme.LogWarn));
    lines.Values['logerror'] := IntToStr(Integer(ATheme.LogError));
    lines.Values['logcritical'] := IntToStr(Integer(ATheme.LogCritical));
    lines.Values['fxcompressor'] := IntToStr(Integer(ATheme.FxCompressor));
    lines.Values['fxreverb'] := IntToStr(Integer(ATheme.FxReverb));
    lines.Values['fxchorus'] := IntToStr(Integer(ATheme.FxChorus));
    lines.Values['fxflanger'] := IntToStr(Integer(ATheme.FxFlanger));
    lines.Values['fxphaser'] := IntToStr(Integer(ATheme.FxPhaser));
    lines.Values['fxtremolo'] := IntToStr(Integer(ATheme.FxTremolo));
    lines.Values['fxautopan'] := IntToStr(Integer(ATheme.FxAutoPan));
    lines.Values['fxsaturation'] := IntToStr(Integer(ATheme.FxSaturation));
    lines.Values['fxbitcrusher'] := IntToStr(Integer(ATheme.FxBitCrusher));
    for n := 0 to High(ATheme.Trk) do
      lines.Values['trk' + IntToStr(n)] := IntToStr(Integer(ATheme.Trk[n]));
    for n := 0 to High(ATheme.Score) do
      lines.Values['score' + IntToStr(n)] := IntToStr(Integer(ATheme.Score[n]));
    lines.Values['fxbrighteneq'] := IntToStr(Integer(ATheme.FxBrightenEQ));
    lines.Values['fxsilence'] := IntToStr(Integer(ATheme.FxSilence));
    lines.Values['fxamplify'] := IntToStr(Integer(ATheme.FxAmplify));
    lines.Values['fxdeesser'] := IntToStr(Integer(ATheme.FxDeEsser));
    lines.Values['fxdelay'] := IntToStr(Integer(ATheme.FxDelay));
    lines.Values['fxexpander'] := IntToStr(Integer(ATheme.FxExpander));
    lines.Values['fxfoldback'] := IntToStr(Integer(ATheme.FxFoldback));
    lines.Values['fxgate'] := IntToStr(Integer(ATheme.FxGate));
    lines.Values['fxhardclip'] := IntToStr(Integer(ATheme.FxHardClip));
    lines.Values['fxlimiter'] := IntToStr(Integer(ATheme.FxLimiter));
    lines.Values['fxpingpongdelay'] := IntToStr(Integer(ATheme.FxPingPongDelay));
    lines.Values['fxbalance'] := IntToStr(Integer(ATheme.FxBalance));
    lines.Values['fxbassenhance'] := IntToStr(Integer(ATheme.FxBassEnhance));
    lines.Values['fxdcoffsetremover'] := IntToStr(Integer(ATheme.FxDCOffsetRemover));
    lines.Values['fxexciter'] := IntToStr(Integer(ATheme.FxExciter));
    lines.Values['fxhighpassfilter'] := IntToStr(Integer(ATheme.FxHighPassFilter));
    lines.Values['fxlowpassfilter'] := IntToStr(Integer(ATheme.FxLowPassFilter));
    lines.Values['fxmakemono'] := IntToStr(Integer(ATheme.FxMakeMono));
    lines.Values['fxmultibandcompressor'] := IntToStr(Integer(ATheme.FxMultibandCompressor));
    lines.Values['fxnotchfilter'] := IntToStr(Integer(ATheme.FxNotchFilter));
    lines.Values['fxpitchshift'] := IntToStr(Integer(ATheme.FxPitchShift));
    lines.Values['fxpresenceboost'] := IntToStr(Integer(ATheme.FxPresenceBoost));
    lines.Values['fxstereowidener'] := IntToStr(Integer(ATheme.FxStereoWidener));
    lines.Values['fxtransientshaper'] := IntToStr(Integer(ATheme.FxTransientShaper));
    lines.Values['fxtrebleboost'] := IntToStr(Integer(ATheme.FxTrebleBoost));
    for n := 0 to High(ATheme.ExtraFx) do
      lines.Values['xfx.' + LowerCase(ATheme.ExtraFx[n].Key)] := IntToStr(Integer(ATheme.ExtraFx[n].Color));
    try
      lines.SaveToFile(APath);
      Result := True;
    except
      Result := False;
    end;
  finally
    lines.Free;
  end;
end;

function IsBuiltInName(const AName: string): Boolean;
var
  n: string;
begin
  for n in ThemeColorsBuiltInNames do
    if SameText(n, AName) then Exit(True);
  Result := False;
end;

function ThemeColorsAvailable: TArray<string>;
var
  names: TStringList;
  dir: string;
  n: string;
  loaded: TUDAWTheme;
  sr: TSearchRec;
  found: Integer;
begin
  names := TStringList.Create;
  try
    names.Duplicates := dupIgnore;
    names.CaseSensitive := False;
    for n in ThemeColorsBuiltInNames do names.Add(n);
    dir := DataFile('themes');
    if DirectoryExists(dir) then
    begin
      found := FindFirst(IncludeTrailingPathDelimiter(dir) + '*.udawtheme', faAnyFile, sr);
      try
        while found = 0 do
        begin
          if LoadThemeFile(IncludeTrailingPathDelimiter(dir) + sr.Name, loaded) then
            names.Add(loaded.Name);
          found := FindNext(sr);
        end;
      finally
        FindClose(sr);
      end;
    end;
    Result := [];
    for n in names do
      Result := Result + [n];
  finally
    names.Free;
  end;
end;

function ThemeColorsGet(const AName: string): TUDAWTheme;
var
  saved: TUDAWTheme;
begin
  if LoadThemeFile(ThemeFileFor(AName), saved) then
    Exit(saved);
  if IsBuiltInName(AName) then
    Exit(ThemeColorsBuiltIn(AName));
  Result := ThemeColorsBuiltIn(THEME_COLORS_DEFAULT);
end;

function ThemeColorsCurrent: TUDAWTheme;
begin
  if not GHaveCurrent then
  begin
    GCurrent := ThemeColorsGet(THEME_COLORS_DEFAULT);
    GHaveCurrent := True;
  end;
  Result := GCurrent;
end;

procedure ThemeColorsApply(const AName: string);
begin
  GCurrent := ThemeColorsGet(AName);
  GHaveCurrent := True;
end;

function CurrentTheme: TUDAWTheme;
begin
  Result := ThemeColorsCurrent;
end;

procedure ThemeColorsSetCurrent(const ATheme: TUDAWTheme);
begin
  GCurrent := ATheme;
  GHaveCurrent := True;
end;

const
  { parallel to TColorSwatch - keep in the same declared order }
  COLOR_SWATCH_NAMES: array[TColorSwatch] of string = (
    'Background', 'Panel Background', 'Text', 'Secondary Text', 'Border',
    'Accent', 'Selection', 'Waveform', 'Grid Lines', 'Meter',
    'Meter Clip', 'Automation', 'MIDI Note',
    'Log: Trace', 'Log: Debug', 'Log: Info', 'Log: Warn', 'Log: Error',
    'Log: Critical', 'Clip with effects: Background', 'Fade in: Background', 'Fade out: Background', 'Timeline: Lock',
    'Control: Selection', 'Control: Selection text', 'Control: Hover glow', 'Control: Focus outline',
    'Effect: Compressor', 'Effect: Reverb', 'Effect: Chorus', 'Effect: Flanger',
    'Effect: Phaser', 'Effect: Tremolo', 'Effect: Auto-Pan', 'Effect: Saturation',
    'Effect: Bit Crusher', 'Effect: Brighten (EQ)', 'Effect: Silence',
    'Effect: Amplify', 'Effect: De-Esser', 'Effect: Delay', 'Effect: Expander',
    'Effect: Foldback', 'Effect: Gate', 'Effect: Hard Clip', 'Effect: Limiter',
    'Effect: Ping-Pong Delay',
    'Effect: Balance', 'Effect: Bass Enhance', 'Effect: DC Offset Remover', 'Effect: Exciter', 'Effect: High-Pass Filter', 'Effect: Low-Pass Filter', 'Effect: Make Mono', 'Effect: Multiband Compressor', 'Effect: Notch Filter', 'Effect: Pitch Shift', 'Effect: Presence Boost', 'Effect: Stereo Widener', 'Effect: Transient Shaper', 'Effect: Treble Boost',
    'Tracker: Grid background (top)', 'Tracker: Grid background (bottom)', 'Tracker: Beat row (every 4)', 'Tracker: Bar row (every 16)', 'Tracker: Grid lines', 'Tracker: Row number gutter', 'Tracker: Row numbers', 'Tracker: Channel header', 'Tracker: Channel header text', 'Tracker: Note', 'Tracker: Instrument', 'Tracker: Volume', 'Tracker: Effect command', 'Tracker: Effect parameter', 'Tracker: Empty cell', 'Tracker: Note off', 'Tracker: Note cut', 'Tracker: Cell cursor', 'Tracker: Cursor field', 'Tracker: Mouse hover', 'Tracker: Playing row', 'Tracker: Channel LED (silent)', 'Tracker: Channel LED (playing)', 'Tracker: Channel LED (loud)', 'Tracker: Channel LED (peak)', 'Tracker: Muted channel', 'Tracker: Channel with effect', 'Tracker: Sequence step', 'Tracker: Sequence step shown', 'Tracker: Sequence step playing',
    'Score: Page background', 'Score: Notes, clefs and rests', 'Score: Staff lines', 'Score: Ledger lines',
    'Tab: String lines', 'Tab: Fret numbers', 'Tab: Fret number outline', 'Score: Playhead',
    'Score: Chord symbols', 'Score: Bar numbers');

function ThemeExtraFxDefault(const AKey: string): TColor;
var
  h: Cardinal;
  i: Integer;
  hue, s, l, q, p: Double;
  key: string;

  function Chan(t: Double): Integer;
  begin
    if t < 0 then t := t + 1;
    if t > 1 then t := t - 1;
    if t < 1 / 6 then Result := Round(255 * (p + (q - p) * 6 * t))
    else if t < 1 / 2 then Result := Round(255 * q)
    else if t < 2 / 3 then Result := Round(255 * (p + (q - p) * (2 / 3 - t) * 6))
    else Result := Round(255 * p);
  end;

begin
  key := LowerCase(AKey);
  h := 2166136261;                       // FNV-1a over the lower-cased key
  for i := 1 to Length(key) do
    h := (h xor Cardinal(Ord(key[i]))) * 16777619;
  hue := (h mod 360) / 360;
  s := 0.55;
  l := 0.62;
  q := l + s - l * s;
  p := 2 * l - q;
  Result := RGB(Chan(hue + 1 / 3), Chan(hue), Chan(hue - 1 / 3));
end;

function ThemeExtraFxGet(const ATheme: TUDAWTheme; const AKey: string): TColor;
var
  i: Integer;
begin
  for i := 0 to High(ATheme.ExtraFx) do
    if SameText(ATheme.ExtraFx[i].Key, AKey) then Exit(ATheme.ExtraFx[i].Color);
  Result := ThemeExtraFxDefault(AKey);
end;

procedure ThemeExtraFxSet(var ATheme: TUDAWTheme; const AKey: string; AColor: TColor);
var
  i: Integer;
begin
  { copy first: records are copied by value but a dynamic array is shared, and
    an edit must not leak into the theme this one was copied from }
  ATheme.ExtraFx := Copy(ATheme.ExtraFx);
  for i := 0 to High(ATheme.ExtraFx) do
    if SameText(ATheme.ExtraFx[i].Key, AKey) then
    begin
      ATheme.ExtraFx[i].Color := AColor;
      Exit;
    end;
  SetLength(ATheme.ExtraFx, Length(ATheme.ExtraFx) + 1);
  ATheme.ExtraFx[High(ATheme.ExtraFx)].Key := AKey;
  ATheme.ExtraFx[High(ATheme.ExtraFx)].Color := AColor;
end;

function TrkColor(ARole: TTrkColorRole): TColor;
begin
  Result := CurrentTheme.Trk[Ord(ARole)];
end;

function ScoreColor(ARole: TScoreColorRole): TColor;
begin
  Result := CurrentTheme.Score[Ord(ARole)];
end;

function ColorSwatchName(ASwatch: TColorSwatch): string;
begin
  Result := COLOR_SWATCH_NAMES[ASwatch];
end;

function ColorSwatchGet(const ATheme: TUDAWTheme; ASwatch: TColorSwatch): TColor;
begin
  case ASwatch of
    csBackground:      Result := ATheme.Background;
    csPanelBackground: Result := ATheme.PanelBackground;
    csClipEffectsBackground: Result := ATheme.ClipEffectsBackground;
    csFadeInBackground: Result := ATheme.FadeInBackground;
    csFadeOutBackground: Result := ATheme.FadeOutBackground;
    csTimelineLock: Result := ATheme.LockColor;
    csControlSelection: Result := ATheme.ControlSelection;
    csControlSelectionText: Result := ATheme.ControlSelectionText;
    csControlHover: Result := ATheme.ControlHover;
    csControlFocus: Result := ATheme.ControlFocus;
    csText:            Result := ATheme.Text;
    csSecondaryText:   Result := ATheme.SecondaryText;
    csBorder:          Result := ATheme.Border;
    csAccent:          Result := ATheme.Accent;
    csSelection:       Result := ATheme.Selection;
    csWaveform:        Result := ATheme.Waveform;
    csGrid:            Result := ATheme.Grid;
    csMeter:           Result := ATheme.Meter;
    csMeterClip:       Result := ATheme.MeterClip;
    csAutomation:      Result := ATheme.Automation;
    csMidiNote:        Result := ATheme.MidiNote;
    csLogTrace:        Result := ATheme.LogTrace;
    csLogDebug:        Result := ATheme.LogDebug;
    csLogInfo:         Result := ATheme.LogInfo;
    csLogWarn:         Result := ATheme.LogWarn;
    csLogError:        Result := ATheme.LogError;
    csLogCritical:     Result := ATheme.LogCritical;
    csFxCompressor:    Result := ATheme.FxCompressor;
    csFxReverb:        Result := ATheme.FxReverb;
    csFxChorus:        Result := ATheme.FxChorus;
    csFxFlanger:       Result := ATheme.FxFlanger;
    csFxPhaser:        Result := ATheme.FxPhaser;
    csFxTremolo:       Result := ATheme.FxTremolo;
    csFxAutoPan:       Result := ATheme.FxAutoPan;
    csFxSaturation:    Result := ATheme.FxSaturation;
    csFxBitCrusher:    Result := ATheme.FxBitCrusher;
    csFxBrightenEQ:    Result := ATheme.FxBrightenEQ;
    csFxSilence:       Result := ATheme.FxSilence;
    csFxAmplify:       Result := ATheme.FxAmplify;
    csFxDeEsser:       Result := ATheme.FxDeEsser;
    csFxDelay:         Result := ATheme.FxDelay;
    csFxExpander:      Result := ATheme.FxExpander;
    csFxFoldback:      Result := ATheme.FxFoldback;
    csFxGate:          Result := ATheme.FxGate;
    csFxHardClip:      Result := ATheme.FxHardClip;
    csFxLimiter:       Result := ATheme.FxLimiter;
    csFxPingPongDelay: Result := ATheme.FxPingPongDelay;
    csFxBalance: Result := ATheme.FxBalance;
    csFxBassEnhance: Result := ATheme.FxBassEnhance;
    csFxDCOffsetRemover: Result := ATheme.FxDCOffsetRemover;
    csFxExciter: Result := ATheme.FxExciter;
    csFxHighPassFilter: Result := ATheme.FxHighPassFilter;
    csFxLowPassFilter: Result := ATheme.FxLowPassFilter;
    csFxMakeMono: Result := ATheme.FxMakeMono;
    csFxMultibandCompressor: Result := ATheme.FxMultibandCompressor;
    csFxNotchFilter: Result := ATheme.FxNotchFilter;
    csFxPitchShift: Result := ATheme.FxPitchShift;
    csFxPresenceBoost: Result := ATheme.FxPresenceBoost;
    csFxStereoWidener: Result := ATheme.FxStereoWidener;
    csFxTransientShaper: Result := ATheme.FxTransientShaper;
    csFxTrebleBoost: Result := ATheme.FxTrebleBoost;
  else
    if ASwatch >= csScorePage then Result := ATheme.Score[Ord(ASwatch) - Ord(csScorePage)]
    else if ASwatch >= csTrkGridTop then Result := ATheme.Trk[Ord(ASwatch) - Ord(csTrkGridTop)]
    else Result := clBlack;
  end;
end;

procedure ColorSwatchSet(var ATheme: TUDAWTheme; ASwatch: TColorSwatch; AColor: TColor);
begin
  case ASwatch of
    csBackground:      ATheme.Background := AColor;
    csPanelBackground: ATheme.PanelBackground := AColor;
    csClipEffectsBackground: ATheme.ClipEffectsBackground := AColor;
    csFadeInBackground: ATheme.FadeInBackground := AColor;
    csFadeOutBackground: ATheme.FadeOutBackground := AColor;
    csTimelineLock: ATheme.LockColor := AColor;
    csControlSelection: ATheme.ControlSelection := AColor;
    csControlSelectionText: ATheme.ControlSelectionText := AColor;
    csControlHover: ATheme.ControlHover := AColor;
    csControlFocus: ATheme.ControlFocus := AColor;
    csText:            ATheme.Text := AColor;
    csSecondaryText:   ATheme.SecondaryText := AColor;
    csBorder:          ATheme.Border := AColor;
    csAccent:          ATheme.Accent := AColor;
    csSelection:       ATheme.Selection := AColor;
    csWaveform:        ATheme.Waveform := AColor;
    csGrid:            ATheme.Grid := AColor;
    csMeter:           ATheme.Meter := AColor;
    csMeterClip:       ATheme.MeterClip := AColor;
    csAutomation:      ATheme.Automation := AColor;
    csMidiNote:        ATheme.MidiNote := AColor;
    csLogTrace:        ATheme.LogTrace := AColor;
    csLogDebug:        ATheme.LogDebug := AColor;
    csLogInfo:         ATheme.LogInfo := AColor;
    csLogWarn:         ATheme.LogWarn := AColor;
    csLogError:        ATheme.LogError := AColor;
    csLogCritical:     ATheme.LogCritical := AColor;
    csFxCompressor:    ATheme.FxCompressor := AColor;
    csFxReverb:        ATheme.FxReverb := AColor;
    csFxChorus:        ATheme.FxChorus := AColor;
    csFxFlanger:       ATheme.FxFlanger := AColor;
    csFxPhaser:        ATheme.FxPhaser := AColor;
    csFxTremolo:       ATheme.FxTremolo := AColor;
    csFxAutoPan:       ATheme.FxAutoPan := AColor;
    csFxSaturation:    ATheme.FxSaturation := AColor;
    csFxBitCrusher:    ATheme.FxBitCrusher := AColor;
    csFxBrightenEQ:    ATheme.FxBrightenEQ := AColor;
    csFxSilence:       ATheme.FxSilence := AColor;
    csFxAmplify:       ATheme.FxAmplify := AColor;
    csFxDeEsser:       ATheme.FxDeEsser := AColor;
    csFxDelay:         ATheme.FxDelay := AColor;
    csFxExpander:      ATheme.FxExpander := AColor;
    csFxFoldback:      ATheme.FxFoldback := AColor;
    csFxGate:          ATheme.FxGate := AColor;
    csFxHardClip:      ATheme.FxHardClip := AColor;
    csFxLimiter:       ATheme.FxLimiter := AColor;
    csFxPingPongDelay: ATheme.FxPingPongDelay := AColor;
    csFxBalance: ATheme.FxBalance := AColor;
    csFxBassEnhance: ATheme.FxBassEnhance := AColor;
    csFxDCOffsetRemover: ATheme.FxDCOffsetRemover := AColor;
    csFxExciter: ATheme.FxExciter := AColor;
    csFxHighPassFilter: ATheme.FxHighPassFilter := AColor;
    csFxLowPassFilter: ATheme.FxLowPassFilter := AColor;
    csFxMakeMono: ATheme.FxMakeMono := AColor;
    csFxMultibandCompressor: ATheme.FxMultibandCompressor := AColor;
    csFxNotchFilter: ATheme.FxNotchFilter := AColor;
    csFxPitchShift: ATheme.FxPitchShift := AColor;
    csFxPresenceBoost: ATheme.FxPresenceBoost := AColor;
    csFxStereoWidener: ATheme.FxStereoWidener := AColor;
    csFxTransientShaper: ATheme.FxTransientShaper := AColor;
    csFxTrebleBoost: ATheme.FxTrebleBoost := AColor;
  else
    if ASwatch >= csScorePage then ATheme.Score[Ord(ASwatch) - Ord(csScorePage)] := AColor
    else if ASwatch >= csTrkGridTop then ATheme.Trk[Ord(ASwatch) - Ord(csTrkGridTop)] := AColor;
  end;
end;

function ThemeColorsSave(const ATheme: TUDAWTheme): Boolean;
begin
  Result := SaveThemeFile(ATheme, ThemeFileFor(ATheme.Name));
  if Result and GHaveCurrent and SameText(GCurrent.Name, ATheme.Name) then
    GCurrent := ATheme;
end;

function ThemeColorsReset(const AName: string): Boolean;
var
  path: string;
begin
  path := ThemeFileFor(AName);
  Result := FileExists(path);
  if Result then
  begin
    DeleteFile(path);
    if GHaveCurrent and SameText(GCurrent.Name, AName) and IsBuiltInName(AName) then
      GCurrent := ThemeColorsBuiltIn(AName);
  end;
end;

function ThemeColorsExport(const ATheme: TUDAWTheme; const AFilePath: string): Boolean;
begin
  Result := SaveThemeFile(ATheme, AFilePath);
end;

function ThemeColorsImport(const AFilePath: string; out ATheme: TUDAWTheme): Boolean;
begin
  Result := LoadThemeFile(AFilePath, ATheme);
  if Result then
    ThemeColorsSave(ATheme);   // imported themes are immediately available/selectable
end;

function CurrentFadeDisplay: TFadeDisplayMode;
begin
  Result := GFadeDisplay;
end;

procedure SetFadeDisplay(AMode: TFadeDisplayMode; ACfg: TConfig);
begin
  GFadeDisplay := AMode;
  if ACfg <> nil then ACfg.SetInt('ui', 'fade_display', Ord(AMode));
end;

procedure ThemeColorsInitFromConfig(ACfg: TConfig);
var
  want: string;
  display: Integer;
begin
  if ACfg = nil then
  begin
    ThemeColorsApply(THEME_COLORS_DEFAULT);
    Exit;
  end;
  want := ACfg.GetString(CFG_SEC_UI_COLOR, CFG_UI_COLOR_THEME, THEME_COLORS_DEFAULT);
  display := ACfg.GetInt('ui', 'fade_display', 0);
  if (display < 0) or (display > Ord(High(TFadeDisplayMode))) then display := 0;
  GFadeDisplay := TFadeDisplayMode(display);
  ThemeColorsApply(want);
end;

procedure ThemeColorsSaveToConfig(ACfg: TConfig; const AName: string);
begin
  if ACfg = nil then Exit;
  ACfg.SetString(CFG_SEC_UI_COLOR, CFG_UI_COLOR_THEME, AName);
end;

end.
