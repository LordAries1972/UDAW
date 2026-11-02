unit UDAW.UI.ShellMenu;
{$I udaw.inc}

{ The Windows Explorer context menu for a file or folder, shown in the application's own graphical
  (GL) menu style. The entries come from the shell's IContextMenu for that item - Open, Open with,
  Send to, Copy, Cut, Delete, Rename, Properties and whatever the installed shell extensions add -
  and are mirrored into a TPopupMenu (sub-menus, separators, disabled and ticked entries included)
  that GLShowPopup draws. Choosing an entry has the shell carry the command out, exactly as
  Explorer would. Holding Shift while right-clicking adds the extended verbs. }

interface

uses
  SysUtils;

{ Shows the menu for APath at a screen point. Returns True when the menu was shown; False when it
  could not be built (ShellMenuLastError says why). AOnInvoked runs after the shell has run a
  command, so the caller can refresh what it lists. }
function ShowShellContextMenu(AOwnerWnd: NativeUInt; const APath: string;
  AScreenX, AScreenY: Integer; AOnInvoked: TProc = nil): Boolean;

function ShellMenuLastError: string;

implementation

{$IFDEF MSWINDOWS}

uses
  Windows, Messages, Classes, Menus, ActiveX, ShlObj,
  UDAW.GL.Menus;

const
  ID_FIRST = 1;
  ID_LAST = $7FFF;

function ShBindToParentRaw(pidl: Pointer; const riid: TGUID; out ppv: Pointer;
  ppidlLast: PPointer): HRESULT; stdcall; external 'shell32.dll' name 'SHBindToParent';

type
  { one open menu: keeps the shell objects alive while the GL menu is up (the commands run when
    an entry is clicked, long after the build) }
  TShellMenuSession = class
  private
    FOwnerWnd: HWND;
    FCm: IContextMenu;
    FCm2: IContextMenu2;
    FCm3: IContextMenu3;
    FHMenu: HMENU;
    FPopup: TPopupMenu;
    FOnInvoked: TProc;
    procedure InitSub(ASub: HMENU; AIndex: Integer);
    procedure FillFrom(AHMenu: HMENU; AParent: TMenuItem);
    procedure ItemClick(Sender: TObject);
    function VerbOf(AId: UINT): string;
    procedure Tidy(AParent: TMenuItem);
  public
    constructor Create(AOwnerWnd: HWND; ACm: IContextMenu; AHMenu: HMENU; AOnInvoked: TProc);
    destructor Destroy; override;
    procedure Build;
    property Popup: TPopupMenu read FPopup;
  end;

var
  GSession: TShellMenuSession;
  GLastError: string;

constructor TShellMenuSession.Create(AOwnerWnd: HWND; ACm: IContextMenu; AHMenu: HMENU;
  AOnInvoked: TProc);
begin
  inherited Create;
  FOwnerWnd := AOwnerWnd;
  FCm := ACm;
  FHMenu := AHMenu;
  FOnInvoked := AOnInvoked;
  if Failed(FCm.QueryInterface(IContextMenu3, FCm3)) then
    FCm.QueryInterface(IContextMenu2, FCm2);
  FPopup := TPopupMenu.Create(nil);
end;

destructor TShellMenuSession.Destroy;
begin
  FPopup.Free;
  FCm3 := nil;
  FCm2 := nil;
  FCm := nil;
  if FHMenu <> 0 then DestroyMenu(FHMenu);
  inherited Destroy;
end;

{ sub-menus such as Send to and Open with are filled in by the handler when the shell announces
  them (WM_INITMENUPOPUP), so announce each one before reading it }
procedure TShellMenuSession.InitSub(ASub: HMENU; AIndex: Integer);
var
  res: LRESULT;
begin
  res := 0;
  if FCm3 <> nil then
    FCm3.HandleMenuMsg2(WM_INITMENUPOPUP, WPARAM(ASub), MakeLParam(AIndex, 0), res)
  else if FCm2 <> nil then
    FCm2.HandleMenuMsg(WM_INITMENUPOPUP, WPARAM(ASub), MakeLParam(AIndex, 0));
end;

{ the command's verb name ("open", "delete" ...) - the only label an owner-drawn entry has }
function TShellMenuSession.VerbOf(AId: UINT): string;
var
  buf: array[0..127] of WideChar;
begin
  Result := '';
  FillChar(buf, SizeOf(buf), 0);
  if Succeeded(FCm.GetCommandString(AId - ID_FIRST, GCS_VERBW, nil, PAnsiChar(@buf[0]),
       Length(buf))) then
    Result := buf;
  if Result <> '' then
    Result := UpperCase(Copy(Result, 1, 1)) + Copy(Result, 2, MaxInt);
end;

procedure TShellMenuSession.FillFrom(AHMenu: HMENU; AParent: TMenuItem);
var
  i, n, len: Integer;
  mii: TMenuItemInfoW;
  buf: array of WideChar;
  item: TMenuItem;
  cap: string;
  p: Integer;
begin
  n := GetMenuItemCount(AHMenu);
  for i := 0 to n - 1 do
  begin
    FillChar(mii, SizeOf(mii), 0);
    mii.cbSize := SizeOf(mii);
    mii.fMask := MIIM_ID or MIIM_FTYPE or MIIM_STATE or MIIM_SUBMENU;
    if not GetMenuItemInfoW(AHMenu, i, True, mii) then Continue;
    if (mii.fType and MFT_SEPARATOR) <> 0 then
    begin
      item := TMenuItem.Create(FPopup);
      item.Caption := '-';
      AParent.Add(item);
      Continue;
    end;
    cap := '';
    if (mii.fType and MFT_OWNERDRAW) = 0 then
    begin
      { first call reports the text length, the second reads the text }
      FillChar(mii, SizeOf(mii), 0);
      mii.cbSize := SizeOf(mii);
      mii.fMask := MIIM_STRING;
      mii.dwTypeData := nil;
      if GetMenuItemInfoW(AHMenu, i, True, mii) and (mii.cch > 0) then
      begin
        len := Integer(mii.cch);
        SetLength(buf, len + 1);
        mii.dwTypeData := PWideChar(buf);
        mii.cch := UINT(len + 1);
        if GetMenuItemInfoW(AHMenu, i, True, mii) then cap := PWideChar(buf);
      end;
      FillChar(mii, SizeOf(mii), 0);
      mii.cbSize := SizeOf(mii);
      mii.fMask := MIIM_ID or MIIM_FTYPE or MIIM_STATE or MIIM_SUBMENU;
      GetMenuItemInfoW(AHMenu, i, True, mii);
    end
    else if mii.hSubMenu = 0 then
      cap := VerbOf(mii.wID);
    { "Open<TAB>Enter": keep the label, drop the shortcut text }
    p := Pos(#9, cap);
    if p > 0 then cap := Copy(cap, 1, p - 1);
    if cap = '' then Continue;
    item := TMenuItem.Create(FPopup);
    item.Caption := cap;
    item.Enabled := (mii.fState and (MFS_DISABLED or MFS_GRAYED)) = 0;
    item.Checked := (mii.fState and MFS_CHECKED) <> 0;
    item.Tag := Integer(mii.wID);
    if mii.hSubMenu <> 0 then
    begin
      InitSub(mii.hSubMenu, i);
      FillFrom(mii.hSubMenu, item);
      if item.Count = 0 then item.Free
      else AParent.Add(item);
    end
    else
    begin
      item.OnClick := ItemClick;
      AParent.Add(item);
    end;
  end;
end;

{ no leading, trailing or doubled separators }
procedure TShellMenuSession.Tidy(AParent: TMenuItem);
var
  i: Integer;
begin
  for i := AParent.Count - 1 downto 0 do
    if AParent[i].Count > 0 then Tidy(AParent[i]);
  while (AParent.Count > 0) and (AParent[0].Caption = '-') do AParent[0].Free;
  while (AParent.Count > 0) and (AParent[AParent.Count - 1].Caption = '-') do
    AParent[AParent.Count - 1].Free;
  for i := AParent.Count - 1 downto 1 do
    if (AParent[i].Caption = '-') and (AParent[i - 1].Caption = '-') then AParent[i].Free;
end;

procedure TShellMenuSession.Build;
begin
  FillFrom(FHMenu, FPopup.Items);
  Tidy(FPopup.Items);
end;

procedure TShellMenuSession.ItemClick(Sender: TObject);
var
  ici: TCMInvokeCommandInfo;
  id: UINT;
begin
  id := UINT(TMenuItem(Sender).Tag);
  FillChar(ici, SizeOf(ici), 0);
  ici.cbSize := SizeOf(ici);
  ici.hwnd := FOwnerWnd;
  ici.lpVerb := MakeIntResourceA(id - ID_FIRST);
  ici.nShow := SW_SHOWNORMAL;
  if Succeeded(FCm.InvokeCommand(ici)) and Assigned(FOnInvoked) then FOnInvoked();
end;

function ShowShellContextMenu(AOwnerWnd: NativeUInt; const APath: string;
  AScreenX, AScreenY: Integer; AOnInvoked: TProc): Boolean;
var
  pidl, childPidl: PItemIDList;
  parentObj, childRaw: Pointer;
  folder: IShellFolder;
  cm: IContextMenu;
  menu: HMENU;
  flags: UINT;
  attrs: ULONG;
  hr: HRESULT;
  sess: TShellMenuSession;
begin
  Result := False;
  GLastError := '';
  if (APath = '') or not (FileExists(APath) or DirectoryExists(APath)) then
  begin
    GLastError := 'the item no longer exists: ' + APath;
    Exit;
  end;
  pidl := nil;
  attrs := 0;
  hr := SHParseDisplayName(PChar(APath), nil, pidl, 0, attrs);
  if Failed(hr) or (pidl = nil) then
  begin
    GLastError := Format('the shell could not parse the path (0x%.8x)', [Cardinal(hr)]);
    Exit;
  end;
  try
    childRaw := nil;
    parentObj := nil;
    hr := ShBindToParentRaw(pidl, IShellFolder, parentObj, @childRaw);
    if Failed(hr) or (parentObj = nil) then
    begin
      GLastError := Format('the shell could not open the parent folder (0x%.8x)', [Cardinal(hr)]);
      Exit;
    end;
    Pointer(folder) := parentObj;   // owns the reference the call returned
    childPidl := PItemIDList(childRaw);
    hr := folder.GetUIObjectOf(AOwnerWnd, 1, childPidl, IContextMenu, nil, cm);
    if Failed(hr) or (cm = nil) then
    begin
      GLastError := Format('the shell has no context menu for this item (0x%.8x)', [Cardinal(hr)]);
      Exit;
    end;
    menu := CreatePopupMenu;
    if menu = 0 then
    begin
      GLastError := 'could not create the menu';
      Exit;
    end;
    flags := CMF_NORMAL or CMF_CANRENAME;
    if GetKeyState(VK_SHIFT) < 0 then flags := flags or CMF_EXTENDEDVERBS;
    hr := cm.QueryContextMenu(menu, 0, ID_FIRST, ID_LAST, flags);
    if Failed(hr) then
    begin
      DestroyMenu(menu);
      GLastError := Format('the shell would not list its commands (0x%.8x)', [Cardinal(hr)]);
      Exit;
    end;
    FreeAndNil(GSession);
    sess := TShellMenuSession.Create(AOwnerWnd, cm, menu, AOnInvoked);
    GSession := sess;
    sess.Build;
    if sess.Popup.Items.Count = 0 then
    begin
      FreeAndNil(GSession);
      GLastError := 'the shell offered no commands for this item';
      Exit;
    end;
    GLShowPopup(sess.Popup, AScreenX, AScreenY);
    Result := True;
  finally
    CoTaskMemFree(pidl);
  end;
end;

function ShellMenuLastError: string;
begin
  Result := GLastError;
end;

initialization

finalization
  FreeAndNil(GSession);

{$ELSE}

function ShowShellContextMenu(AOwnerWnd: NativeUInt; const APath: string;
  AScreenX, AScreenY: Integer; AOnInvoked: TProc): Boolean;
begin
  Result := False;   // the shell menu is a Windows feature
end;

function ShellMenuLastError: string;
begin
  Result := 'the shell menu is only available on Windows';
end;

{$ENDIF}

end.
