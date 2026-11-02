unit UDAW.UI.SystemSounds;
{$I udaw.inc}

{ Windows' warning / error / information / question sounds, played through UDAW's audio engine so
  they come out of the Output device chosen in Settings instead of the Windows default one.

  How it fits together.  A VCL message dialog (MessageDlg) normally becomes a Windows task dialog,
  and Windows plays its sound itself, on the default device.  InstallSystemSoundRouting turns that
  off (the dialog is drawn by the VCL instead, which makes no sound) and watches for the dialog
  appearing; PlaySystemSound then plays the sound the user has set up in Windows' Sound settings
  for that kind of dialog - a "No Sounds" scheme stays silent.  The sound is mixed into the engine
  like the Foley pads are.  If the engine is not open, the ordinary Windows beep is used so a
  warning is never silent for the wrong reason. }

interface

type
  TSystemSound = (ssDefault, ssWarning, ssError, ssInformation, ssQuestion);

{ plays one of the Windows sounds through the engine's output (Windows' own beep when the engine is closed) }
procedure PlaySystemSound(AKind: TSystemSound);

{ message dialogs made by the VCL play their sound through PlaySystemSound from now on }
procedure InstallSystemSoundRouting;

implementation

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.Win.Registry, Vcl.Forms, Vcl.Dialogs,
  Vcl.Consts, UDAW.Audio.Source, UDAW.Audio.Engine, UDAW.Drum.Machine, UDAW.App;

const
  EVENT_NAMES: array[TSystemSound] of string =
    ('.Default', 'SystemExclamation', 'SystemHand', 'SystemAsterisk', 'SystemQuestion');
  BEEP_TYPES: array[TSystemSound] of UINT =
    (MB_OK, MB_ICONEXCLAMATION, MB_ICONHAND, MB_ICONASTERISK, MB_ICONQUESTION);
  OVERLAY_SLOT = 1;   // the engine's slot for system sounds (0 is the Foley pads)

type
  TSystemSoundRouter = class
  private
    FPrevious: TNotifyEvent;
    FLastForm: TForm;
  public
    procedure ActiveFormChanged(Sender: TObject);
  end;

var
  GRouter: TSystemSoundRouter;
  GDrum: TDrumMachine;                    // one pad per sound kind
  GDrumRef: IAudioSource;
  GTried: array[TSystemSound] of Boolean; // the file has been looked up (and loaded, if it could be)
  GLoaded: array[TSystemSound] of Boolean;

{ the file Windows' Sound settings assign to this event; '' when the scheme has no sound for it }
function SoundFileFor(AKind: TSystemSound): string;
var
  reg: TRegistry;
  expanded: string;
begin
  Result := '';
  reg := TRegistry.Create(KEY_READ);
  try
    reg.RootKey := HKEY_CURRENT_USER;
    if reg.OpenKeyReadOnly('AppEvents\Schemes\Apps\.Default\' + EVENT_NAMES[AKind] + '\.Current') then
    begin
      Result := Trim(reg.ReadString(''));
      reg.CloseKey;
    end;
  except
    Result := '';
  end;
  reg.Free;
  if Result <> '' then
  begin
    expanded := Result;
    SetLength(Result, ExpandEnvironmentStrings(PChar(expanded), nil, 0));
    ExpandEnvironmentStrings(PChar(expanded), PChar(Result), Length(Result) + 1);
    Result := Trim(string(PChar(Result)));   // drops the terminating zero the API counts
  end;
end;

function EngineReady: Boolean;
begin
  Result := (App <> nil) and (App.Audio <> nil) and (App.Audio.State in [aesOpen, aesRunning]);
end;

procedure PlaySystemSound(AKind: TSystemSound);
var
  path, err: string;
begin
  if not EngineReady then
  begin
    MessageBeep(BEEP_TYPES[AKind]);
    Exit;
  end;
  if GDrum = nil then
  begin
    GDrum := TDrumMachine.Create;
    GDrumRef := GDrum;
  end;
  if not GTried[AKind] then
  begin
    GTried[AKind] := True;
    path := SoundFileFor(AKind);
    if path = '' then Exit;   // the user's sound scheme has no sound for this: stay silent
    GLoaded[AKind] := FileExists(path) and GDrum.LoadPad(Ord(AKind), path, err);
    if not GLoaded[AKind] then
    begin
      MessageBeep(BEEP_TYPES[AKind]);   // not a WAV we can read: Windows' own beep is better than nothing
      Exit;
    end;
  end;
  if not GLoaded[AKind] then Exit;
  App.Audio.SetOverlay(GDrumRef, OVERLAY_SLOT);   // idempotent; also re-attaches after the engine was reopened
  GDrum.Hit(Ord(AKind), 127);
end;

{ which sound a VCL message dialog stands for, from its caption (MessageDlg titles it by type) }
function SoundOfDialog(const ACaption: string): TSystemSound;
begin
  if SameText(ACaption, SMsgDlgWarning) then Result := ssWarning
  else if SameText(ACaption, SMsgDlgError) then Result := ssError
  else if SameText(ACaption, SMsgDlgInformation) then Result := ssInformation
  else if SameText(ACaption, SMsgDlgConfirm) then Result := ssQuestion
  else Result := ssDefault;
end;

procedure TSystemSoundRouter.ActiveFormChanged(Sender: TObject);
var
  f: TForm;
begin
  if Assigned(FPrevious) then FPrevious(Sender);
  f := Screen.ActiveForm;
  if (f = nil) or (f.ClassName <> 'TMessageForm') then Exit;
  if f = FLastForm then Exit;   // the same dialog being activated again
  FLastForm := f;
  PlaySystemSound(SoundOfDialog(f.Caption));
end;

procedure InstallSystemSoundRouting;
begin
  if GRouter <> nil then Exit;
  UseLatestCommonDialogs := False;   // VCL-drawn dialogs: Windows' task dialog would sound on the default device
  GRouter := TSystemSoundRouter.Create;
  GRouter.FPrevious := Screen.OnActiveFormChange;
  Screen.OnActiveFormChange := GRouter.ActiveFormChanged;
end;

initialization

finalization
  GDrum := nil;
  GDrumRef := nil;
  FreeAndNil(GRouter);

end.
