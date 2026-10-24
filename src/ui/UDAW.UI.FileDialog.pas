unit UDAW.UI.FileDialog;

{ File open / save and folder pick dialogs built from the GL widgets, with the
  same properties and Execute call as TOpenDialog / TSaveDialog, so the existing
  code only changes the component types:

    TGLOpenDialog   DefaultExt, FileName, Filter ('Name|*.wav;*.mp3|Name|*.*'),
                    FilterIndex, InitialDir, Options (ofAllowMultiSelect,
                    ofFileMustExist, ofOverwritePrompt), Title; Files after Execute.
    TGLSaveDialog   the same, defaulting to a save dialog.
    GLSelectDirectory   folder picker (replaces SelectDirectory).

  The dialog window itself is the designed form in UDAW.UI.FileDialog.dfm. }

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Classes, System.Types,
  System.UITypes, System.Masks, System.Generics.Collections, System.Generics.Defaults, Vcl.Controls,
  Vcl.Forms, Vcl.Dialogs, UDAW.GL.Widgets, UDAW.GL.Controls;

type
  TGLFileDialogMode = (fdOpen, fdSave, fdFolder);

  { the project's memory of where each dialog was last used: the application sets these; a dialog
    asks for its key's path when it has no folder of its own and reports the path chosen }
  TGLDialogRecallFn = reference to function(const AKey: string): string;
  TGLDialogRememberProc = reference to procedure(const AKey, APath: string);

var
  GLDialogRecall: TGLDialogRecallFn;
  GLDialogRemember: TGLDialogRememberProc;

type

  TGLOpenDialog = class(TComponent)
  private
    FDefaultExt: string;
    FFileName: string;
    FFilter: string;
    FFilterIndex: Integer;
    FInitialDir: string;
    FOptions: TOpenOptions;
    FTitle: string;
    FFiles: TStrings;
    procedure SetFiles(AValue: TStrings);
  protected
    function Mode: TGLFileDialogMode; virtual;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    function Execute: Boolean; virtual;
    property Files: TStrings read FFiles write SetFiles;
  published
    property DefaultExt: string read FDefaultExt write FDefaultExt;
    property FileName: string read FFileName write FFileName;
    property Filter: string read FFilter write FFilter;
    property FilterIndex: Integer read FFilterIndex write FFilterIndex default 1;
    property InitialDir: string read FInitialDir write FInitialDir;
    property Options: TOpenOptions read FOptions write FOptions default [ofHideReadOnly, ofEnableSizing];
    property Title: string read FTitle write FTitle;
  end;

  TGLSaveDialog = class(TGLOpenDialog)
  protected
    function Mode: TGLFileDialogMode; override;
  end;

  TfrmGLFileDialog = class(TForm)
    lblLook: TGLLabel;
    cboPlaces: TGLCombo;
    ibNav: TGLIconBar;
    edPath: TGLEdit;
    lvFiles: TGLListView;
    lblName: TGLLabel;
    edName: TGLEdit;
    lblType: TGLLabel;
    cboFilter: TGLCombo;
    btnOK: TGLButton;
    btnCancel: TGLButton;
    procedure FormCreate(Sender: TObject);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure cboPlacesChange(Sender: TObject);
    procedure cboFilterChange(Sender: TObject);
    procedure ibNavClick(Sender: TObject; AIndex: Integer; const AId: string);
    procedure btnOKClick(Sender: TObject);
    procedure btnCancelClick(Sender: TObject);
    procedure edPathKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure lvFilesClick(Sender: TObject);
    procedure lvFilesDblClick(Sender: TObject);
  private
    FMode: TGLFileDialogMode;
    FDir: string;
    FPlacePaths: TStringList;
    FMasks: TArray<string>;
    FFilterMasks: TStringList;
    FMulti: Boolean;
    FMustExist: Boolean;
    FOverwrite: Boolean;
    FDefaultExt: string;
    FResultFile: string;
    FResultFiles: TStringList;
    procedure BuildPlaces;
    procedure ApplyFilter;
    procedure LoadDir(const ADir: string);
    function Matches(const AName: string): Boolean;
    function FormatSize(ASize: Int64): string;
    procedure Accept;
    procedure GoUp;
    procedure NewFolder;
  public
    destructor Destroy; override;
    procedure Setup(const ATitle, AInitialDir, AFileName, AFilter: string; AFilterIndex: Integer;
      AMode: TGLFileDialogMode; AMulti, AMustExist, AOverwrite: Boolean; const ADefaultExt: string);
    property ResultFile: string read FResultFile;
    property ResultFiles: TStringList read FResultFiles;
    property Dir: string read FDir;
  end;

{ folder picker: ADir is the start folder on entry and the chosen folder on exit }
function GLSelectDirectory(const ACaption: string; var ADir: string): Boolean;

implementation

{$R *.dfm}

uses
  Winapi.ShlObj, Winapi.KnownFolders, Winapi.ActiveX, System.IOUtils, System.Math, System.StrUtils;

type
  TEntry = record
    Name: string;
    IsDir: Boolean;
    Size: Int64;
    Time: TDateTime;
  end;

var
  GLastDir: string;

function KnownFolder(const AId: TGUID): string;
var
  p: PWideChar;
begin
  Result := '';
  p := nil;
  if Succeeded(SHGetKnownFolderPath(AId, 0, 0, p)) then
  try
    Result := p;
  finally
    CoTaskMemFree(p);
  end;
end;

{ ---- TGLOpenDialog ---- }

constructor TGLOpenDialog.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FFiles := TStringList.Create;
  FFilterIndex := 1;
  FOptions := [ofHideReadOnly, ofEnableSizing];
end;

destructor TGLOpenDialog.Destroy;
begin
  FFiles.Free;
  inherited Destroy;
end;

procedure TGLOpenDialog.SetFiles(AValue: TStrings);
begin
  FFiles.Assign(AValue);
end;

function TGLOpenDialog.Mode: TGLFileDialogMode;
begin
  Result := fdOpen;
end;

function TGLOpenDialog.Execute: Boolean;
var
  frm: TfrmGLFileDialog;
  start, key, recalled: string;
begin
  start := FInitialDir;
  if (start = '') and (FFileName <> '') then start := ExtractFilePath(FFileName);
  key := IfThen(Name <> '', Name, Title);
  if (start = '') and (key <> '') and Assigned(GLDialogRecall) then
  begin
    recalled := GLDialogRecall(key);
    if recalled <> '' then
    begin
      if DirectoryExists(recalled) then start := recalled
      else if DirectoryExists(ExtractFilePath(recalled)) then start := ExtractFilePath(recalled);
    end;
  end;
  frm := TfrmGLFileDialog.Create(Application);
  try
    frm.Setup(FTitle, start, ExtractFileName(FFileName), FFilter, FFilterIndex, Mode,
      ofAllowMultiSelect in FOptions, ofFileMustExist in FOptions, ofOverwritePrompt in FOptions, FDefaultExt);
    Result := frm.ShowModal = mrOk;
    if Result then
    begin
      FFileName := frm.ResultFile;
      FFiles.Assign(frm.ResultFiles);
      FFilterIndex := frm.cboFilter.ItemIndex + 1;
      GLastDir := frm.Dir;
      if (key <> '') and Assigned(GLDialogRemember) then GLDialogRemember(key, FFileName);
    end;
  finally
    frm.Free;
  end;
end;

function TGLSaveDialog.Mode: TGLFileDialogMode;
begin
  Result := fdSave;
end;

{ ---- folder picker ---- }

function GLSelectDirectory(const ACaption: string; var ADir: string): Boolean;
var
  frm: TfrmGLFileDialog;
  key, recalled: string;
begin
  key := 'folder:' + ACaption;
  if (Trim(ADir) = '') and Assigned(GLDialogRecall) then
  begin
    recalled := GLDialogRecall(key);
    if (recalled <> '') and DirectoryExists(recalled) then ADir := recalled;
  end;
  frm := TfrmGLFileDialog.Create(Application);
  try
    frm.Setup(ACaption, ADir, '', '', 1, fdFolder, False, False, False, '');
    Result := frm.ShowModal = mrOk;
    if Result then
    begin
      ADir := ExcludeTrailingPathDelimiter(frm.ResultFile);
      GLastDir := frm.Dir;
      if Assigned(GLDialogRemember) then GLDialogRemember(key, ADir);
    end;
  finally
    frm.Free;
  end;
end;

{ ---- TfrmGLFileDialog ---- }

procedure TfrmGLFileDialog.FormCreate(Sender: TObject);
begin
  FPlacePaths := TStringList.Create;
  FFilterMasks := TStringList.Create;
  FResultFiles := TStringList.Create;
end;

destructor TfrmGLFileDialog.Destroy;
begin
  FResultFiles.Free;
  FFilterMasks.Free;
  FPlacePaths.Free;
  inherited Destroy;
end;

procedure TfrmGLFileDialog.BuildPlaces;
var
  d: Char;
  p: string;
  procedure Add(const ACaption, APath: string);
  begin
    if (APath <> '') and DirectoryExists(APath) then
    begin
      cboPlaces.Items.Add(ACaption);
      FPlacePaths.Add(IncludeTrailingPathDelimiter(APath));
    end;
  end;
begin
  cboPlaces.Items.Clear;
  FPlacePaths.Clear;
  Add('Desktop', KnownFolder(FOLDERID_Desktop));
  Add('Documents', KnownFolder(FOLDERID_Documents));
  Add('Music', KnownFolder(FOLDERID_Music));
  Add('Downloads', KnownFolder(FOLDERID_Downloads));
  for d := 'A' to 'Z' do
  begin
    p := d + ':\';
    if GetDriveType(PChar(p)) > DRIVE_NO_ROOT_DIR then Add('Drive ' + d + ':', p);
  end;
end;

procedure TfrmGLFileDialog.Setup(const ATitle, AInitialDir, AFileName, AFilter: string;
  AFilterIndex: Integer; AMode: TGLFileDialogMode; AMulti, AMustExist, AOverwrite: Boolean;
  const ADefaultExt: string);
var
  parts: TArray<string>;
  i: Integer;
  start: string;
begin
  FMode := AMode;
  FMulti := AMulti and (AMode = fdOpen);
  FMustExist := AMustExist;
  FOverwrite := AOverwrite;
  FDefaultExt := ADefaultExt;
  if ATitle <> '' then Caption := ATitle
  else case AMode of
    fdOpen: Caption := 'Open';
    fdSave: Caption := 'Save As';
    fdFolder: Caption := 'Select Folder';
  end;
  lvFiles.MultiSelect := FMulti;
  case AMode of
    fdOpen: btnOK.Caption := 'Open';
    fdSave: btnOK.Caption := 'Save';
    fdFolder: btnOK.Caption := 'Select';
  end;
  if AMode = fdFolder then
  begin
    lblName.Caption := 'Folder:';
    lblType.Visible := False;
    cboFilter.Visible := False;
  end
  else
  begin
    lblName.Caption := 'File name:';
    edName.Text := AFileName;
  end;
  { Filter = 'Description|mask;mask|Description|mask' }
  cboFilter.Items.Clear;
  FFilterMasks.Clear;
  parts := AFilter.Split(['|']);
  i := 0;
  while i + 1 < Length(parts) do
  begin
    cboFilter.Items.Add(parts[i]);
    FFilterMasks.Add(parts[i + 1]);
    Inc(i, 2);
  end;
  if cboFilter.Items.Count = 0 then
  begin
    cboFilter.Items.Add('All files (*.*)');
    FFilterMasks.Add('*.*');
  end;
  cboFilter.ItemIndex := EnsureRange(AFilterIndex - 1, 0, cboFilter.Items.Count - 1);
  ApplyFilter;
  BuildPlaces;
  start := AInitialDir;
  if (start = '') or not DirectoryExists(start) then start := GLastDir;
  if (start = '') or not DirectoryExists(start) then start := KnownFolder(FOLDERID_Documents);
  LoadDir(start);
end;

procedure TfrmGLFileDialog.ApplyFilter;
var
  m: string;
begin
  m := FFilterMasks[EnsureRange(cboFilter.ItemIndex, 0, FFilterMasks.Count - 1)];
  FMasks := m.Split([';']);
end;

function TfrmGLFileDialog.Matches(const AName: string): Boolean;
var
  m: string;
begin
  Result := False;
  for m in FMasks do
    if MatchesMask(AName, Trim(m)) then Exit(True);
end;

function TfrmGLFileDialog.FormatSize(ASize: Int64): string;
begin
  Result := Format('%s KB', [FormatFloat('#,##0', (ASize + 1023) div 1024)]);
end;

procedure TfrmGLFileDialog.LoadDir(const ADir: string);
var
  dir: string;
  sr: TSearchRec;
  entries: TList<TEntry>;
  e: TEntry;
  it: TGLListItem;
  i: Integer;
begin
  dir := IncludeTrailingPathDelimiter(StringReplace(Trim(ADir), '/', '\', [rfReplaceAll]));
  if not DirectoryExists(dir) then Exit;
  FDir := dir;
  edPath.Text := dir;
  entries := TList<TEntry>.Create;
  try
    if FindFirst(dir + '*', faAnyFile, sr) = 0 then
    try
      repeat
        if (sr.Name = '.') or (sr.Name = '..') then Continue;
        if sr.Attr and (FILE_ATTRIBUTE_HIDDEN or FILE_ATTRIBUTE_SYSTEM) <> 0 then Continue;
        e.Name := sr.Name;
        e.IsDir := sr.Attr and faDirectory <> 0;
        e.Size := sr.Size;
        e.Time := sr.TimeStamp;
        if e.IsDir then entries.Add(e)
        else if (FMode <> fdFolder) and Matches(sr.Name) then entries.Add(e);
      until FindNext(sr) <> 0;
    finally
      FindClose(sr);
    end;
    entries.Sort(TComparer<TEntry>.Construct(
      function(const A, B: TEntry): Integer
      begin
        if A.IsDir <> B.IsDir then Exit(IfThen(A.IsDir, -1, 1));
        Result := CompareText(A.Name, B.Name);
      end));
    lvFiles.Items.BeginUpdate;
    try
      lvFiles.Items.Clear;
      for i := 0 to entries.Count - 1 do
      begin
        e := entries[i];
        it := lvFiles.Items.Add;
        it.Caption := e.Name;
        if e.IsDir then
        begin
          it.SubItems.Add('');
          it.Data := Pointer(1);
        end
        else it.SubItems.Add(FormatSize(e.Size));
        it.SubItems.Add(FormatDateTime('yyyy-mm-dd hh:nn', e.Time));
      end;
    finally
      lvFiles.Items.EndUpdate;
    end;
  finally
    entries.Free;
  end;
  lvFiles.ItemIndex := -1;
end;

procedure TfrmGLFileDialog.cboPlacesChange(Sender: TObject);
begin
  if (cboPlaces.ItemIndex >= 0) and (cboPlaces.ItemIndex < FPlacePaths.Count) then
    LoadDir(FPlacePaths[cboPlaces.ItemIndex]);
end;

procedure TfrmGLFileDialog.cboFilterChange(Sender: TObject);
begin
  ApplyFilter;
  LoadDir(FDir);
end;

{ The folder one level above APath, or '' when there is none (a drive root, or the top of a network
  share). The path is read as text and its last folder is cut off - separators are normalised first so
  a path typed with '/' or with several trailing '\' is handled, and a parent that no longer exists is
  skipped for the next one up rather than falling back to the drive root. }
function ParentFolder(const APath: string): string;
var
  p: string;
  i: Integer;
begin
  Result := '';
  p := StringReplace(Trim(APath), '/', '\', [rfReplaceAll]);
  p := StringReplace(p, '"', '', [rfReplaceAll]);
  while (Length(p) > 3) and (p[Length(p)] = '\') do SetLength(p, Length(p) - 1);
  if p = '' then Exit;
  { a drive root such as "C:\" has nothing above it }
  if (Length(p) <= 3) and (Length(p) >= 2) and (p[2] = ':') then Exit;
  i := LastDelimiter('\', p);
  if i <= 1 then Exit;
  Result := Copy(p, 1, i - 1);
  if (Length(Result) = 2) and (Result[2] = ':') then Result := Result + '\';
  { "\\server" or "\\server\share" is the top of a network location }
  if (Copy(Result, 1, 2) = '\\') and (Pos('\', Copy(Result, 3, MaxInt)) = 0) then Exit('');
  if not DirectoryExists(Result) then Result := ParentFolder(Result);
end;

procedure TfrmGLFileDialog.GoUp;
var
  cur, parent: string;
begin
  { read the path first: what is in the path box if it is a real folder, else the folder shown }
  cur := Trim(edPath.Text);
  if (cur = '') or not DirectoryExists(cur) then cur := FDir;
  parent := ParentFolder(cur);
  if (parent = '') or SameText(IncludeTrailingPathDelimiter(parent), IncludeTrailingPathDelimiter(cur)) then Exit;
  LoadDir(parent);
end;

procedure TfrmGLFileDialog.NewFolder;
var
  name: string;
  i: Integer;
begin
  name := Trim(edName.Text);
  if (name = '') or (Pos('.', name) > 0) or (Pos('"', name) > 0) then name := 'New folder';
  if CreateDir(FDir + name) then
  begin
    LoadDir(FDir);
    edName.Text := '';
    { select the new folder so the highlight glides to it }
    for i := 0 to lvFiles.Items.Count - 1 do
      if (lvFiles.Items[i].Data <> nil) and SameText(lvFiles.Items[i].Caption, name) then
      begin
        lvFiles.ItemIndex := i;
        Break;
      end;
  end
  else MessageDlg('Could not create the folder "' + name + '".', mtError, [mbOK], 0);
end;

procedure TfrmGLFileDialog.ibNavClick(Sender: TObject; AIndex: Integer; const AId: string);
begin
  if AId = 'up' then GoUp
  else if AId = 'newfolder' then NewFolder;
end;

procedure TfrmGLFileDialog.edPathKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if Key = VK_RETURN then
  begin
    LoadDir(edPath.Text);
    Key := 0;
  end;
end;

procedure TfrmGLFileDialog.FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if Key = VK_ESCAPE then
  begin
    ModalResult := mrCancel;
    Key := 0;
  end
  else if (Key = VK_UP) and (ssAlt in Shift) then
  begin
    GoUp;
    Key := 0;
  end;
end;

{ one click on a file puts its name in the box (several quoted names when many are picked) }
procedure TfrmGLFileDialog.lvFilesClick(Sender: TObject);
var
  i, n: Integer;
  names: string;
begin
  n := 0;
  names := '';
  for i := 0 to lvFiles.Items.Count - 1 do
    if lvFiles.IsSelected(i) and ((lvFiles.Items[i].Data = nil) or (FMode = fdFolder)) then
    begin
      Inc(n);
      if names <> '' then names := names + ' ';
      names := names + '"' + lvFiles.Items[i].Caption + '"';
    end;
  if n = 1 then names := StringReplace(names, '"', '', [rfReplaceAll]);
  if n > 0 then edName.Text := names;
end;

procedure TfrmGLFileDialog.lvFilesDblClick(Sender: TObject);
var
  it: TGLListItem;
begin
  it := lvFiles.Selected;
  if it = nil then Exit;
  if it.Data <> nil then LoadDir(FDir + it.Caption)
  else if FMode <> fdFolder then Accept;
end;

procedure TfrmGLFileDialog.btnOKClick(Sender: TObject);
begin
  Accept;
end;

procedure TfrmGLFileDialog.btnCancelClick(Sender: TObject);
begin
  ModalResult := mrCancel;
end;

procedure TfrmGLFileDialog.Accept;
var
  txt, nm, full: string;
  names: TStringList;
  i, q: Integer;
  inQ: Boolean;
  buf: string;
begin
  FResultFiles.Clear;
  txt := Trim(edName.Text);
  if FMode = fdFolder then
  begin
    full := FDir;
    if (txt <> '') and DirectoryExists(FDir + txt) then full := FDir + txt;
    FResultFile := IncludeTrailingPathDelimiter(full);
    FResultFiles.Add(ExcludeTrailingPathDelimiter(FResultFile));
    ModalResult := mrOk;
    Exit;
  end;
  if txt = '' then Exit;
  { names: either one name, or several "quoted" names }
  names := TStringList.Create;
  try
    inQ := False;
    buf := '';
    for q := 1 to Length(txt) do
    begin
      if txt[q] = '"' then
      begin
        if inQ and (buf <> '') then names.Add(buf);
        buf := '';
        inQ := not inQ;
      end
      else if inQ or (names.Count = 0) then buf := buf + txt[q];
    end;
    if (names.Count = 0) and (buf <> '') then names.Add(buf);
    if names.Count = 0 then Exit;
    { wildcards narrow the list instead of choosing a file }
    if (names.Count = 1) and ((Pos('*', names[0]) > 0) or (Pos('?', names[0]) > 0)) then
    begin
      FMasks := names[0].Split([';']);
      LoadDir(FDir);
      Exit;
    end;
    for i := 0 to names.Count - 1 do
    begin
      nm := names[i];
      if (Pos(':', nm) > 0) or (Copy(nm, 1, 2) = '\\') then full := nm else full := FDir + nm;
      if (names.Count = 1) and DirectoryExists(full) then
      begin
        LoadDir(full);
        edName.Text := '';
        Exit;
      end;
      if (FMode = fdSave) and (ExtractFileExt(full) = '') and (FDefaultExt <> '') then
        full := full + '.' + FDefaultExt;
      if (FMode = fdOpen) and FMustExist and not FileExists(full) then
      begin
        MessageDlg('"' + ExtractFileName(full) + '" was not found.' + sLineBreak +
          'Check the file name and try again.', mtWarning, [mbOK], 0);
        Exit;
      end;
      if (FMode = fdSave) and FOverwrite and FileExists(full) then
        if MessageDlg('"' + ExtractFileName(full) + '" already exists.' + sLineBreak +
          'Do you want to replace it?', mtConfirmation, [mbYes, mbNo], 0) <> mrYes then Exit;
      FResultFiles.Add(full);
    end;
  finally
    names.Free;
  end;
  FResultFile := FResultFiles[0];
  ModalResult := mrOk;
end;

initialization
  RegisterClasses([TGLOpenDialog, TGLSaveDialog]);

end.
