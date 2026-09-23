unit Tests.Phase29;
{$IFDEF FPC}{$MODE DELPHI}{$MODESWITCH ADVANCEDRECORDS}{$H+}{$ENDIF}

{ Phase 29 acceptance tests - the theming system (UDAW.UI.ThemeColors): the
  five built-in themes exist and are visually distinct, ThemeColorsGet falls
  back sensibly, and Save/Export/Import/Reset round-trip through a real (but
  cleaned-up-afterwards) file under <data>/themes. }

interface

procedure RegisterPhase29Tests;

implementation

uses
  SysUtils,
  UDAW.Testing,
  UDAW.UI.ThemeColors,
  UDAW.Paths;

const
  GRP = 'phase29.theming';
  TEST_THEME_NAME = 'UDAWTestTheme_Phase29';

procedure Test_FiveBuiltInThemesExist;
var
  names: TArray<string>;
begin
  names := ThemeColorsBuiltInNames;
  CheckEqualInt(5, Length(names), 'exactly the five themes the plan names');
  Check(Length(ThemeColorsAvailable) >= 5, 'available list includes at least the five built-ins');
end;

procedure Test_BuiltInThemesAreDistinct;
var
  a, b: TUDAWTheme;
begin
  a := ThemeColorsBuiltIn('Studio Dark');
  b := ThemeColorsBuiltIn('Studio Light');
  Check(a.Background <> b.Background, 'Dark and Light have different backgrounds');
  a := ThemeColorsBuiltIn('Midnight');
  b := ThemeColorsBuiltIn('Graphite');
  Check(a.Accent <> b.Accent, 'Midnight and Graphite have different accents');
end;

procedure Test_ThemeColorsGet_FallsBackForUnknownName;
var
  t: TUDAWTheme;
begin
  t := ThemeColorsGet('Not A Real Theme Name');
  CheckEqualStr(THEME_COLORS_DEFAULT, t.Name, 'unknown name resolves to the default theme');
end;

procedure Test_ThemeColorsApply_ChangesCurrent;
var
  before: TUDAWTheme;
begin
  before := ThemeColorsCurrent;
  try
    ThemeColorsApply('High Contrast');
    CheckEqualStr('High Contrast', ThemeColorsCurrent.Name, 'apply switches the in-memory current theme');
    CheckEqualStr('High Contrast', CurrentTheme.Name, 'CurrentTheme is the same alias');
  finally
    ThemeColorsApply(before.Name);
  end;
end;

procedure Test_SaveExportImportReset_RoundTrip;
var
  edited: TUDAWTheme;
  loaded: TUDAWTheme;
  exportPath: string;
begin
  { Save: an edited copy of a built-in, under a private test name so it
    can't collide with (or be mistaken for) a real user theme. }
  edited := ThemeColorsBuiltIn('Studio Dark');
  edited.Name := TEST_THEME_NAME;
  edited.Accent := $00123456;
  ColorSwatchSet(edited, csClipEffectsBackground, $00234567);
  ColorSwatchSet(edited, csFadeInBackground, $00345678);
  ColorSwatchSet(edited, csFadeOutBackground, $00456789);
  try
    Check(ThemeColorsSave(edited), 'save succeeds');
    loaded := ThemeColorsGet(TEST_THEME_NAME);
    CheckEqualInt(Integer($00123456), Integer(loaded.Accent), 'the saved edit is what comes back');

    { Export / Import round trip through a temp file. }
    exportPath := Paths.Temp + PathDelim + TEST_THEME_NAME + '.udawtheme';
    Check(ThemeColorsExport(loaded, exportPath), 'export succeeds');
    Check(ThemeColorsImport(exportPath, loaded), 'import succeeds and re-saves it as selectable');
    CheckEqualInt(Integer($00123456), Integer(loaded.Accent), 'imported theme keeps its colours');
    CheckEqualInt($00234567, ColorSwatchGet(loaded, csClipEffectsBackground), 'effects background persists');
    CheckEqualInt($00345678, loaded.FadeInBackground, 'fade-in colour persists');
    CheckEqualInt($00456789, loaded.FadeOutBackground, 'fade-out colour persists');
    if FileExists(exportPath) then DeleteFile(exportPath);

    { Reset removes the saved edit, reverting the name to its built-in
      colours (Studio Dark's own accent, not our custom one) - but our test
      name isn't a built-in, so Reset should report nothing to revert to and
      simply remove the saved file. }
    Check(ThemeColorsReset(TEST_THEME_NAME), 'reset removes the saved custom theme file');
    CheckFalse(ThemeColorsReset(TEST_THEME_NAME), 'a second reset finds nothing left to remove');
  finally
    { belt-and-braces cleanup even if an assertion above failed }
    ThemeColorsReset(TEST_THEME_NAME);
  end;
end;

procedure RegisterPhase29Tests;
begin
  RegisterTest(GRP, 'Five built-in themes exist', Test_FiveBuiltInThemesExist);
  RegisterTest(GRP, 'Built-in themes are visually distinct', Test_BuiltInThemesAreDistinct);
  RegisterTest(GRP, 'ThemeColorsGet falls back for an unknown name', Test_ThemeColorsGet_FallsBackForUnknownName);
  RegisterTest(GRP, 'ThemeColorsApply changes the current theme', Test_ThemeColorsApply_ChangesCurrent);
  RegisterTest(GRP, 'Save/Export/Import/Reset round-trip', Test_SaveExportImportReset_RoundTrip);
end;

end.
