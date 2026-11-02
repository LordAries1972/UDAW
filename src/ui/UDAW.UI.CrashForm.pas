unit UDAW.UI.CrashForm;

{ The crash window: UDAW's own exception hook (UDAW.CrashTrace) shows every exception that reaches
  it here. The report - what was raised, the message, and the call stack as "UDAW.exe+offset" lines
  - sits in a scrollable box, with Copy (to the clipboard), Save (to a text file) and Exit (closes
  UDAW). The window is the only way out: it has no close box, and closing it any other way is exit
  as well, because the state after an unexpected error cannot be trusted.

  Every control is placed at design time in the .dfm, per the project's forms rule. This unit
  registers itself with UDAW.CrashTrace when it is initialised. }

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.IOUtils, Vcl.Controls, Vcl.Forms,
  Vcl.Clipbrd, UDAW.GL.Widgets, UDAW.UI.FileDialog;

type
  TfrmCrash = class(TForm)
    lblHeadline: TGLLabel;
    lblNote: TGLLabel;
    memTrace: TGLMemo;
    btnCopy: TGLButton;
    btnSave: TGLButton;
    btnExit: TGLButton;
    lblStatus: TGLLabel;
    dlgSave: TGLSaveDialog;
    procedure FormClose(Sender: TObject; var Action: TCloseAction);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure btnCopyClick(Sender: TObject);
    procedure btnSaveClick(Sender: TObject);
    procedure btnExitClick(Sender: TObject);
  private
    FReport: string;
  public
    procedure Prepare(const AReport, ASavedPath: string);
  end;

{ shows the report and does not return: Exit ends the process }
procedure ShowCrashWindow(const AReport, ASavedPath: string);

implementation

{$R *.dfm}

uses
  UDAW.CrashTrace;

procedure TfrmCrash.Prepare(const AReport, ASavedPath: string);
begin
  FReport := AReport;
  memTrace.Text := AReport;
  if ASavedPath <> '' then
    lblNote.Caption := 'The report below says what happened and where. Copy it or save it before you exit, ' +
      'and send it with your problem report. A copy was saved automatically to ' + ASavedPath
  else
    lblNote.Caption := 'The report below says what happened and where. Copy it or save it before you exit, ' +
      'and send it with your problem report.';
end;

procedure TfrmCrash.btnCopyClick(Sender: TObject);
begin
  try
    Clipboard.AsText := FReport;
    lblStatus.Caption := 'Copied to the clipboard.';
  except
    on E: Exception do lblStatus.Caption := 'Could not copy: ' + E.Message;
  end;
end;

procedure TfrmCrash.btnSaveClick(Sender: TObject);
begin
  dlgSave.FileName := 'UDAW-crash-' + FormatDateTime('yyyymmdd-hhnnss', Now) + '.txt';
  if not dlgSave.Execute then Exit;
  try
    TFile.WriteAllText(dlgSave.FileName, FReport, TEncoding.UTF8);
    lblStatus.Caption := 'Saved to ' + ExtractFileName(dlgSave.FileName);
  except
    on E: Exception do lblStatus.Caption := 'Could not save: ' + E.Message;
  end;
end;

procedure TfrmCrash.btnExitClick(Sender: TObject);
begin
  ModalResult := mrAbort;
end;

procedure TfrmCrash.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  CanClose := True;
end;

procedure TfrmCrash.FormClose(Sender: TObject; var Action: TCloseAction);
begin
  Action := caHide;
end;

procedure ShowCrashWindow(const AReport, ASavedPath: string);
var
  frm: TfrmCrash;
begin
  frm := TfrmCrash.Create(nil);
  try
    frm.Prepare(AReport, ASavedPath);
    frm.ShowModal;
  finally
    frm.Free;
  end;
  { Exit (or any other way of closing the window): leave at once - UDAW's state after an
    unexpected error is not safe to carry on from or to run shut-down code in }
  ExitProcess(1);
end;

initialization
  SetCrashDisplay(ShowCrashWindow);

end.
