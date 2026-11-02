unit UDAW.Input.KeyHooks;
{$I udaw.inc}

{ Global (system-wide) keyboard hooks, independent of the app-focused
  shortcuts handled inline by TfrmMain.FormKeyDown (Undo/Redo/Delete clip -
  those only ever fire while UDAW has focus, so they stay exactly where they
  were). The hooks managed here (video capture start/stop, emergency
  stop-and-save, stop recording) must work even when another window has
  focus, which is what Win32 RegisterHotKey is for.

  Every hook has a stable Action identity and a user-configurable key
  combination, persisted under the [KeyHooks] config section. Registration
  can fail (another app already owns that combination) - TryRegister/
  TrySetKeys never raise for that; they record the OS error text on the hook
  itself so the Settings > Key Hooks tab can show it per-row and the user can
  reassign or restore that one hook without losing the others. }

interface

uses
  SysUtils, Classes,
  {$IFDEF MSWINDOWS}
  Winapi.Windows,
  {$ENDIF}
  UDAW.Config;

type
  TKeyHookAction = (
    khaEmergencyStop,
    khaStopRecording,
    khaTogglePlayback,
    khaPanicStopAudio,
    khaToggleMasterMute
  );

  TKeyHookDef = record
    Id: Integer;                 // stable RegisterHotKey id (also the config row key)
    Action: TKeyHookAction;
    DisplayName: string;
    Modifiers: Word;             // MOD_CONTROL etc. (0 = none)
    VirtualKey: Word;
    DefaultModifiers: Word;
    DefaultVirtualKey: Word;
    Enabled: Boolean;
    Registered: Boolean;         // true iff currently applied with the OS
    LastError: string;           // '' when Registered, else why it failed
  end;

const
  CFG_SEC_KEYHOOKS = 'KeyHooks';

function KeyHookActionName(AAction: TKeyHookAction): string;
{ what the hook does and when, for the Key Hooks list }
function KeyHookDescription(AAction: TKeyHookAction): string;

type
  TKeyHookManager = class
  private
    FWnd: {$IFDEF MSWINDOWS}HWND{$ELSE}NativeUInt{$ENDIF};
    FHooks: array of TKeyHookDef;
    function IndexOfId(AId: Integer): Integer;
    function KeyName(AVirtualKey: Word): string;
    function TryApply(var AHook: TKeyHookDef): Boolean;
    procedure Unapply(var AHook: TKeyHookDef);
  public
    constructor Create(AWnd: {$IFDEF MSWINDOWS}HWND{$ELSE}NativeUInt{$ENDIF});
    destructor Destroy; override;

    procedure LoadFromConfig(ACfg: TConfig);
    procedure SaveToConfig(ACfg: TConfig);
    procedure RestoreDefaults(ACfg: TConfig);

    { Registers every enabled hook with the OS. Never raises; returns the
      number of hooks that failed to register (0 = all good). Call again
      after TrySetKeys/RestoreDefaults change anything. }
    function ApplyAll: Integer;
    procedure UnregisterAll;

    function Count: Integer;
    function GetHook(AIndex: Integer): TKeyHookDef;
    function IndexOfAction(AAction: TKeyHookAction): Integer;

    { Attempts to rebind hook AIndex to the given combination. On failure the
      hook keeps its previous (working) binding and AError explains why. }
    function TrySetKeys(AIndex: Integer; AModifiers, AVirtualKey: Word;
      out AError: string): Boolean;

    { Lets the user "get rid of" a hook that keeps failing (or just doesn't
      want it) without touching the others; re-enabling re-applies it. }
    procedure SetEnabled(AIndex: Integer; AEnabled: Boolean);

    { Resolves a WM_HOTKEY wParam back to the action that fired, or False if
      it wasn't one of ours (shouldn't happen, but WM_HOTKEY ids are shared
      window-wide). }
    function ActionForHotkeyId(AId: Integer; out AAction: TKeyHookAction): Boolean;

    function KeysToString(AModifiers, AVirtualKey: Word): string;
    function HasErrors: Boolean;
  end;

implementation

const
  { First RegisterHotKey id UDAW claims; kept well clear of ids any other
    in-process code might use for its own accelerators. }
  FIRST_HOTKEY_ID = $B000;

  ACTION_NAMES: array[TKeyHookAction] of string = (
    'Emergency stop && save',
    'Stop recording',
    'Toggle timeline playback',
    'Panic (stop all audio)',
    'Toggle master output mute'
  );

  ACTION_CFG_KEYS: array[TKeyHookAction] of string = (
    'EmergencyStop',
    'StopRecording',
    'TogglePlayback',
    'PanicStopAudio',
    'ToggleMasterMute'
  );

function KeyHookActionName(AAction: TKeyHookAction): string;
begin
  Result := ACTION_NAMES[AAction];
end;

function KeyHookDescription(AAction: TKeyHookAction): string;
begin
  case AAction of
    khaEmergencyStop: Result := 'Stops everything at once and saves the project to a recovery file. Use it when something has gone wrong and you do not want to lose work; works from any program.';
    khaStopRecording: Result := 'Ends a recording that is running and keeps the take, so you can stop while another window has the focus (a plug-in editor, say).';
    khaTogglePlayback: Result := 'Starts or stops Timeline playback from anywhere, for example while you play an instrument in another window.';
    khaPanicStopAudio: Result := 'Silences every sound that is playing (stuck notes, runaway effects) without touching the project.';
    khaToggleMasterMute: Result := 'Switches the master output off and on again, a quick way to take a break from the sound.';
  else
    Result := '';
  end;
end;

{$IFDEF MSWINDOWS}
const
  DEFAULT_MODS: array[TKeyHookAction] of Word = (
    MOD_CONTROL,              // Ctrl+Pause     - emergency stop & save
    MOD_CONTROL,              // Ctrl+Space     - stop recording
    MOD_CONTROL,              // Ctrl+F2        - toggle timeline playback
    MOD_CONTROL,              // Ctrl+F3        - panic: stop all audio
    MOD_CONTROL               // Ctrl+F4        - toggle master output mute
  );
  DEFAULT_VKS: array[TKeyHookAction] of Word = (
    VK_PAUSE,
    VK_SPACE,
    VK_F2,
    VK_F3,
    VK_F4
  );
{$ELSE}
const
  DEFAULT_MODS: array[TKeyHookAction] of Word = (2, 2, 2, 2, 2); // MOD_CONTROL value, unused off-Windows
  DEFAULT_VKS: array[TKeyHookAction] of Word = (0, 0, 0, 0, 0);
{$ENDIF}

constructor TKeyHookManager.Create(AWnd: {$IFDEF MSWINDOWS}HWND{$ELSE}NativeUInt{$ENDIF});
var
  a: TKeyHookAction;
  n: Integer;
begin
  inherited Create;
  FWnd := AWnd;
  SetLength(FHooks, Ord(High(TKeyHookAction)) + 1);
  n := 0;
  for a := Low(TKeyHookAction) to High(TKeyHookAction) do
  begin
    FHooks[n].Id := FIRST_HOTKEY_ID + n;
    FHooks[n].Action := a;
    FHooks[n].DisplayName := ACTION_NAMES[a];
    FHooks[n].Modifiers := DEFAULT_MODS[a];
    FHooks[n].VirtualKey := DEFAULT_VKS[a];
    FHooks[n].DefaultModifiers := DEFAULT_MODS[a];
    FHooks[n].DefaultVirtualKey := DEFAULT_VKS[a];
    FHooks[n].Enabled := True;
    FHooks[n].Registered := False;
    FHooks[n].LastError := '';
    Inc(n);
  end;
end;

destructor TKeyHookManager.Destroy;
begin
  UnregisterAll;
  inherited Destroy;
end;

function TKeyHookManager.IndexOfId(AId: Integer): Integer;
var
  i: Integer;
begin
  for i := 0 to High(FHooks) do
    if FHooks[i].Id = AId then Exit(i);
  Result := -1;
end;

function TKeyHookManager.IndexOfAction(AAction: TKeyHookAction): Integer;
var
  i: Integer;
begin
  for i := 0 to High(FHooks) do
    if FHooks[i].Action = AAction then Exit(i);
  Result := -1;
end;

function TKeyHookManager.KeyName(AVirtualKey: Word): string;
begin
  {$IFDEF MSWINDOWS}
  case AVirtualKey of
    VK_F1: Result := 'F1'; VK_F2: Result := 'F2'; VK_F3: Result := 'F3';
    VK_F4: Result := 'F4'; VK_F5: Result := 'F5'; VK_F6: Result := 'F6';
    VK_F7: Result := 'F7'; VK_F8: Result := 'F8'; VK_F9: Result := 'F9';
    VK_F10: Result := 'F10'; VK_F11: Result := 'F11'; VK_F12: Result := 'F12';
    VK_ESCAPE: Result := 'Esc';
    VK_SPACE: Result := 'Space';
    VK_PAUSE: Result := 'Pause/Break';
    VK_TAB: Result := 'Tab';
    VK_RETURN: Result := 'Enter';
    VK_DELETE: Result := 'Delete';
    VK_INSERT: Result := 'Insert';
    VK_HOME: Result := 'Home';
    VK_END: Result := 'End';
  else
    if (AVirtualKey >= Ord('A')) and (AVirtualKey <= Ord('Z')) then
      Result := Chr(AVirtualKey)
    else if (AVirtualKey >= Ord('0')) and (AVirtualKey <= Ord('9')) then
      Result := Chr(AVirtualKey)
    else
      Result := Format('VK_%.2X', [AVirtualKey]);
  end;
  {$ELSE}
  Result := Format('VK_%.2X', [AVirtualKey]);
  {$ENDIF}
end;

function TKeyHookManager.KeysToString(AModifiers, AVirtualKey: Word): string;
var
  parts: string;
begin
  parts := '';
  {$IFDEF MSWINDOWS}
  if (AModifiers and MOD_CONTROL) <> 0 then parts := parts + 'Ctrl+';
  if (AModifiers and MOD_ALT) <> 0 then parts := parts + 'Alt+';
  if (AModifiers and MOD_SHIFT) <> 0 then parts := parts + 'Shift+';
  if (AModifiers and MOD_WIN) <> 0 then parts := parts + 'Win+';
  {$ENDIF}
  Result := parts + KeyName(AVirtualKey);
end;

function TKeyHookManager.TryApply(var AHook: TKeyHookDef): Boolean;
{$IFDEF MSWINDOWS}
var
  err: Cardinal;
{$ENDIF}
begin
  {$IFDEF MSWINDOWS}
  UnregisterHotKey(FWnd, AHook.Id);   // defensive: never leave a stale binding for this id
  if not AHook.Enabled then
  begin
    AHook.Registered := False;
    AHook.LastError := '';
    Exit(True);
  end;
  if RegisterHotKey(FWnd, AHook.Id, AHook.Modifiers or MOD_NOREPEAT, AHook.VirtualKey) then
  begin
    AHook.Registered := True;
    AHook.LastError := '';
    Result := True;
  end
  else
  begin
    err := GetLastError;
    AHook.Registered := False;
    AHook.LastError := Format('Could not bind %s (%s already claimed by another '
      + 'application, code %d)', [KeysToString(AHook.Modifiers, AHook.VirtualKey),
      KeysToString(AHook.Modifiers, AHook.VirtualKey), err]);
    Result := False;
  end;
  {$ELSE}
  AHook.Registered := False;
  AHook.LastError := 'Global key hooks are only implemented on Windows in this build.';
  Result := False;
  {$ENDIF}
end;

procedure TKeyHookManager.Unapply(var AHook: TKeyHookDef);
begin
  {$IFDEF MSWINDOWS}
  if AHook.Registered then
    UnregisterHotKey(FWnd, AHook.Id);
  {$ENDIF}
  AHook.Registered := False;
end;

function TKeyHookManager.ApplyAll: Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(FHooks) do
    if not TryApply(FHooks[i]) and FHooks[i].Enabled then
      Inc(Result);
end;

procedure TKeyHookManager.UnregisterAll;
var
  i: Integer;
begin
  for i := 0 to High(FHooks) do
    Unapply(FHooks[i]);
end;

function TKeyHookManager.Count: Integer;
begin
  Result := Length(FHooks);
end;

function TKeyHookManager.GetHook(AIndex: Integer): TKeyHookDef;
begin
  Result := FHooks[AIndex];
end;

function TKeyHookManager.TrySetKeys(AIndex: Integer; AModifiers, AVirtualKey: Word;
  out AError: string): Boolean;
var
  prevMods, prevVk: Word;
  prevEnabled: Boolean;
begin
  AError := '';
  if (AIndex < 0) or (AIndex > High(FHooks)) then
  begin
    AError := 'No such key hook.';
    Exit(False);
  end;
  prevMods := FHooks[AIndex].Modifiers;
  prevVk := FHooks[AIndex].VirtualKey;
  prevEnabled := FHooks[AIndex].Enabled;

  Unapply(FHooks[AIndex]);
  FHooks[AIndex].Modifiers := AModifiers;
  FHooks[AIndex].VirtualKey := AVirtualKey;
  FHooks[AIndex].Enabled := True;

  if TryApply(FHooks[AIndex]) then
    Exit(True);

  { roll back to the previous, working binding so the user never ends up
    with a silently-dead hook }
  AError := FHooks[AIndex].LastError;
  FHooks[AIndex].Modifiers := prevMods;
  FHooks[AIndex].VirtualKey := prevVk;
  FHooks[AIndex].Enabled := prevEnabled;
  TryApply(FHooks[AIndex]);
  Result := False;
end;

procedure TKeyHookManager.SetEnabled(AIndex: Integer; AEnabled: Boolean);
begin
  if (AIndex < 0) or (AIndex > High(FHooks)) then Exit;
  if FHooks[AIndex].Enabled = AEnabled then Exit;
  FHooks[AIndex].Enabled := AEnabled;
  TryApply(FHooks[AIndex]);
end;

function TKeyHookManager.ActionForHotkeyId(AId: Integer; out AAction: TKeyHookAction): Boolean;
var
  idx: Integer;
begin
  idx := IndexOfId(AId);
  Result := idx >= 0;
  if Result then AAction := FHooks[idx].Action;
end;

function TKeyHookManager.HasErrors: Boolean;
var
  i: Integer;
begin
  for i := 0 to High(FHooks) do
    if FHooks[i].Enabled and not FHooks[i].Registered then Exit(True);
  Result := False;
end;

procedure TKeyHookManager.LoadFromConfig(ACfg: TConfig);
var
  i: Integer;
  key: string;
begin
  if ACfg = nil then Exit;
  for i := 0 to High(FHooks) do
  begin
    key := ACTION_CFG_KEYS[FHooks[i].Action];
    FHooks[i].Modifiers := Word(ACfg.GetInt(CFG_SEC_KEYHOOKS, key + '.Mod', FHooks[i].DefaultModifiers));
    FHooks[i].VirtualKey := Word(ACfg.GetInt(CFG_SEC_KEYHOOKS, key + '.VK', FHooks[i].DefaultVirtualKey));
    FHooks[i].Enabled := ACfg.GetBool(CFG_SEC_KEYHOOKS, key + '.Enabled', True);
  end;
end;

procedure TKeyHookManager.SaveToConfig(ACfg: TConfig);
var
  i: Integer;
  key: string;
begin
  if ACfg = nil then Exit;
  for i := 0 to High(FHooks) do
  begin
    key := ACTION_CFG_KEYS[FHooks[i].Action];
    ACfg.SetInt(CFG_SEC_KEYHOOKS, key + '.Mod', FHooks[i].Modifiers);
    ACfg.SetInt(CFG_SEC_KEYHOOKS, key + '.VK', FHooks[i].VirtualKey);
    ACfg.SetBool(CFG_SEC_KEYHOOKS, key + '.Enabled', FHooks[i].Enabled);
  end;
  ACfg.Save;
end;

procedure TKeyHookManager.RestoreDefaults(ACfg: TConfig);
var
  i: Integer;
begin
  UnregisterAll;
  for i := 0 to High(FHooks) do
  begin
    FHooks[i].Modifiers := FHooks[i].DefaultModifiers;
    FHooks[i].VirtualKey := FHooks[i].DefaultVirtualKey;
    FHooks[i].Enabled := True;
    FHooks[i].LastError := '';
  end;
  ApplyAll;
  if ACfg <> nil then SaveToConfig(ACfg);
end;

end.
