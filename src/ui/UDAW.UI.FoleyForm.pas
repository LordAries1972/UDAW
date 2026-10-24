unit UDAW.UI.FoleyForm;
{$I udaw.inc}

{ Foley Sampler: sixteen pads, each holding one sound effect (WAV or MP3).  Hit
  a pad - with the mouse or the 4 x 4 keyboard block 1234 / QWER / ASDF / ZXCV -
  to hear it.  While the Timeline plays, "Record hits" notes where the playhead
  was for every hit; "Add hits to Timeline" then lays them out as clips (one
  track per pad), so a sound performed live against the picture lands in time.
  "Place pad at playhead" drops one sound at the playhead without recording.

  Pad sounds are previewed through the system audio output (Windows MCI, so
  several pads can ring at once and they sound over Timeline playback); the
  clips that end up on the Timeline play through UDAW's own audio engine.  Pad
  assignments are remembered between sessions.  Every control is placed at
  design time. }

interface

uses
  Windows, Messages, SysUtils, Classes, Graphics, Controls, Forms, StdCtrls,
  Dialogs, ExtCtrls, MMSystem, UDAW.UI.FileDialog, UDAW.GL.Widgets;

type
  TFoleyHit = record
    PadIndex: Integer;
    SampleFile: string;
    Seconds: Double;
  end;

  TFoleyPlayheadFunc = function: Double of object;
  TFoleyPlayingFunc = function: Boolean of object;
  TFoleyCommitEvent = procedure(const AHits: TArray<TFoleyHit>) of object;
  TFoleyPlaceEvent = procedure(const AFile: string; ASeconds: Double) of object;

  TfrmFoley = class(TForm)
    btnPad1: TButton;
    btnPad2: TButton;
    btnPad3: TButton;
    btnPad4: TButton;
    btnPad5: TButton;
    btnPad6: TButton;
    btnPad7: TButton;
    btnPad8: TButton;
    btnPad9: TButton;
    btnPad10: TButton;
    btnPad11: TButton;
    btnPad12: TButton;
    btnPad13: TButton;
    btnPad14: TButton;
    btnPad15: TButton;
    btnPad16: TButton;
    lblSelected: TGLLabel;
    btnLoadPad: TButton;
    btnClearPad: TButton;
    btnPlace: TButton;
    chkRecord: TGLCheck;
    chkTimeline: TGLCheck;
    lblHits: TGLLabel;
    btnCommit: TButton;
    btnClearHits: TButton;
    dlgOpenSample: TGLOpenDialog;
    procedure PadClick(Sender: TObject);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure FormKeyUp(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure FormShow(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure btnLoadPadClick(Sender: TObject);
    procedure btnClearPadClick(Sender: TObject);
    procedure btnPlaceClick(Sender: TObject);
    procedure btnCommitClick(Sender: TObject);
    procedure btnClearHitsClick(Sender: TObject);
  private
    FFiles: array[0..15] of string;
    FOpened: array[0..15] of Boolean;
    FHeld: array[0..15] of Boolean;
    FSelected: Integer;
    FHits: TArray<TFoleyHit>;
    FOnPlayhead: TFoleyPlayheadFunc;
    FOnIsPlaying: TFoleyPlayingFunc;
    FOnCommit: TFoleyCommitEvent;
    FOnPlace: TFoleyPlaceEvent;
    FOnInsert: TFoleyPlaceEvent;
    function PadButton(AIndex: Integer): TButton;
    function PadForKey(AKey: Word): Integer;
    function IniPath: string;
    procedure LoadPads;
    procedure SavePads;
    procedure SelectPad(AIndex: Integer);
    procedure RefreshPadCaptions;
    procedure RefreshHitsLabel;
    procedure CloseSound(AIndex: Integer);
    procedure Mci(const ACommand: string);
    procedure Hit(AIndex: Integer; AFromKey: Boolean = False);
  public
    property OnPlayhead: TFoleyPlayheadFunc read FOnPlayhead write FOnPlayhead;
    property OnIsPlaying: TFoleyPlayingFunc read FOnIsPlaying write FOnIsPlaying;
    property OnCommit: TFoleyCommitEvent read FOnCommit write FOnCommit;
    property OnPlace: TFoleyPlaceEvent read FOnPlace write FOnPlace;
    { a pad KEY was pressed: put its sound on the Timeline at the playhead (splitting the clip
      the playhead is inside, so the sound lands between the two halves) }
    property OnInsert: TFoleyPlaceEvent read FOnInsert write FOnInsert;
  end;

implementation

uses
  IniFiles, UDAW.Paths;

{$R *.dfm}

const
  PAD_KEYS = '1234QWERASDFZXCV';

function TfrmFoley.IniPath: string;
begin
  Result := DataFile('FoleyPads.ini');
end;

function TfrmFoley.PadButton(AIndex: Integer): TButton;
begin
  Result := FindComponent('btnPad' + IntToStr(AIndex + 1)) as TButton;
end;

function TfrmFoley.PadForKey(AKey: Word): Integer;
var
  p: Integer;
begin
  Result := -1;
  if (AKey > 255) then Exit;
  p := Pos(UpCase(Chr(AKey)), PAD_KEYS);
  if p > 0 then Result := p - 1;
end;

procedure TfrmFoley.Mci(const ACommand: string);
begin
  mciSendString(PChar(ACommand), nil, 0, 0);
end;

procedure TfrmFoley.CloseSound(AIndex: Integer);
begin
  if FOpened[AIndex] then
  begin
    Mci('close udawfoley' + IntToStr(AIndex));
    FOpened[AIndex] := False;
  end;
end;

procedure TfrmFoley.LoadPads;
var
  ini: TMemIniFile;
  i: Integer;
begin
  ini := TMemIniFile.Create(IniPath);
  try
    for i := 0 to 15 do
    begin
      FFiles[i] := ini.ReadString('Pads', 'Pad' + IntToStr(i + 1), '');
      if (FFiles[i] <> '') and not FileExists(FFiles[i]) then FFiles[i] := '';
    end;
  finally
    ini.Free;
  end;
end;

procedure TfrmFoley.SavePads;
var
  ini: TMemIniFile;
  i: Integer;
begin
  ini := TMemIniFile.Create(IniPath);
  try
    for i := 0 to 15 do
      ini.WriteString('Pads', 'Pad' + IntToStr(i + 1), FFiles[i]);
    ini.UpdateFile;
  finally
    ini.Free;
  end;
end;

procedure TfrmFoley.RefreshPadCaptions;
var
  i: Integer;
  nm: string;
begin
  for i := 0 to 15 do
  begin
    if FFiles[i] = '' then nm := '(empty)'
    else nm := ChangeFileExt(ExtractFileName(FFiles[i]), '');
    if Length(nm) > 12 then nm := Copy(nm, 1, 11) + '...';
    PadButton(i).Caption := PAD_KEYS[i + 1] + '  ' + nm;
  end;
  if FFiles[FSelected] = '' then
    lblSelected.Caption := Format('Pad %s: empty - choose "Load into pad..."', [PAD_KEYS[FSelected + 1]])
  else
    lblSelected.Caption := Format('Pad %s: %s', [PAD_KEYS[FSelected + 1], ExtractFileName(FFiles[FSelected])]);
end;

procedure TfrmFoley.RefreshHitsLabel;
begin
  lblHits.Caption := Format('%d hit(s) recorded', [Length(FHits)]);
  btnCommit.Enabled := Length(FHits) > 0;
  btnClearHits.Enabled := Length(FHits) > 0;
end;

procedure TfrmFoley.SelectPad(AIndex: Integer);
begin
  FSelected := AIndex;
  RefreshPadCaptions;
end;

procedure TfrmFoley.FormShow(Sender: TObject);
begin
  LoadPads;
  FSelected := 0;
  RefreshPadCaptions;
  RefreshHitsLabel;
end;

procedure TfrmFoley.FormDestroy(Sender: TObject);
var
  i: Integer;
begin
  for i := 0 to 15 do CloseSound(i);
end;

procedure TfrmFoley.Hit(AIndex: Integer; AFromKey: Boolean);
var
  h: TFoleyHit;
  inserted: Boolean;
begin
  SelectPad(AIndex);
  if FFiles[AIndex] = '' then Exit;
  if not FOpened[AIndex] then
  begin
    Mci(Format('open "%s" alias udawfoley%d', [FFiles[AIndex], AIndex]));
    FOpened[AIndex] := True;
  end;
  Mci(Format('seek udawfoley%d to start', [AIndex]));
  Mci(Format('play udawfoley%d', [AIndex]));
  inserted := False;
  if AFromKey and chkTimeline.Checked and Assigned(FOnInsert) and Assigned(FOnPlayhead) then
  begin
    FOnInsert(FFiles[AIndex], FOnPlayhead());
    inserted := True;   { already on the Timeline: not also kept as a recorded hit }
  end;
  if (not inserted) and chkRecord.Checked and Assigned(FOnIsPlaying) and FOnIsPlaying() and Assigned(FOnPlayhead) then
  begin
    h.PadIndex := AIndex;
    h.SampleFile := FFiles[AIndex];
    h.Seconds := FOnPlayhead();
    SetLength(FHits, Length(FHits) + 1);
    FHits[High(FHits)] := h;
    RefreshHitsLabel;
  end;
end;

procedure TfrmFoley.PadClick(Sender: TObject);
begin
  Hit((Sender as TButton).Tag);
end;

procedure TfrmFoley.FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
var
  p: Integer;
begin
  if Shift * [ssCtrl, ssAlt] <> [] then Exit;
  p := PadForKey(Key);
  if (p >= 0) and not FHeld[p] then
  begin
    FHeld[p] := True;   // a held key must not retrigger on keyboard auto-repeat
    Hit(p, True);
    Key := 0;
  end;
end;

procedure TfrmFoley.FormKeyUp(Sender: TObject; var Key: Word; Shift: TShiftState);
var
  p: Integer;
begin
  p := PadForKey(Key);
  if p >= 0 then FHeld[p] := False;
end;

procedure TfrmFoley.btnLoadPadClick(Sender: TObject);
begin
  if not dlgOpenSample.Execute then Exit;
  CloseSound(FSelected);
  FFiles[FSelected] := dlgOpenSample.FileName;
  SavePads;
  RefreshPadCaptions;
end;

procedure TfrmFoley.btnClearPadClick(Sender: TObject);
begin
  CloseSound(FSelected);
  FFiles[FSelected] := '';
  SavePads;
  RefreshPadCaptions;
end;

procedure TfrmFoley.btnPlaceClick(Sender: TObject);
begin
  if (FFiles[FSelected] = '') or not Assigned(FOnPlace) or not Assigned(FOnPlayhead) then Exit;
  FOnPlace(FFiles[FSelected], FOnPlayhead());
end;

procedure TfrmFoley.btnCommitClick(Sender: TObject);
begin
  if (Length(FHits) = 0) or not Assigned(FOnCommit) then Exit;
  FOnCommit(FHits);
  FHits := nil;
  RefreshHitsLabel;
end;

procedure TfrmFoley.btnClearHitsClick(Sender: TObject);
begin
  FHits := nil;
  RefreshHitsLabel;
end;

end.
