unit UDAW.UI.HelpForm;

{ A dedicated window that renders the UDAW Help Centre page fetched by
  UDAW.UI.MainForm's Help menu (see btnHelpAboutClick), using the VCL's
  built-in TWebBrowser (MSHTML) control - the same embedded-browser target
  the page's own CSS/JS already designs around (its "embedded MSHTML
  browser" fallbacks for dark scrollbars and sticky navigation).

  Mirrors CyberRealm's frmHelpCentreU: this form owns its own temp file
  (computed here via TPath, not passed in by the caller) and writes the
  fetched HTML to it itself - the caller only ever hands over the HTML
  string via ShowHtml, never a file path, so there is no path for a caller
  to get wrong or leave empty.

  Windows/Delphi only. There is no Lazarus/LCL equivalent of TWebBrowser
  available in this project, so the FPC build does not use this unit at
  all - it opens the same locally-saved file in the OS default browser
  instead (see the FPC-only branch in btnHelpAboutClick). }

interface

uses
  Windows, Messages, SysUtils, Variants, Classes, Graphics, Controls, Forms,
  Dialogs, OleCtrls, SHDocVw, IOUtils, ExtCtrls, StdCtrls, UITypes, ShellAPI,
  UDAW.Paths, UDAW.Web.HelpClient;

type
  TfrmHelp = class(TForm)
    wb: TWebBrowser;
    pnlToolbar: TPanel;
    btnRefresh: TButton;
    btnTranslate: TButton;
    procedure FormClose(Sender: TObject; var Action: TCloseAction);
    procedure FormDestroy(Sender: TObject);
    procedure btnRefreshClick(Sender: TObject);
    procedure btnTranslateClick(Sender: TObject);
  private
    FTempFile, FBrowserFile: string;
    FTempName: string;
  public
    procedure ShowHtml(const AHtml: string);
    procedure ShowLicense(const AHtml: string);
  end;

implementation

{$R *.dfm}

const
  { "Mark of the Web" - tells MSHTML to treat the local temp file as
    Internet-zone content so the page's inline <script> runs without the
    Local Machine Zone lockdown prompt. }
  CMotw = '<!-- saved from url=(0016)http://localhost -->' + sLineBreak;

procedure TfrmHelp.FormClose(Sender: TObject; var Action: TCloseAction);
begin
  Action := caFree;
end;

procedure TfrmHelp.FormDestroy(Sender: TObject);
begin
  if (FBrowserFile <> '') and TFile.Exists(FBrowserFile) then
    try
      TFile.Delete(FBrowserFile);
    except
      // the browser may still have it open
    end;
  if (FTempFile <> '') and TFile.Exists(FTempFile) then
    try
      TFile.Delete(FTempFile);
    except
      // a browser still holding the file open is not worth surfacing
    end;
end;

procedure TfrmHelp.btnRefreshClick(Sender: TObject);
var
  html, errMsg: string;
begin
  btnRefresh.Enabled := False;
  Screen.Cursor := crHourGlass;
  try
    if not FetchUDAWHelpPage(html, errMsg) then
      begin
        MessageDlg('Could not refresh the UDAW Help Centre:' + sLineBreak + errMsg,
          mtError, [mbOK], 0);
        Exit;
      end;
  finally
    Screen.Cursor := crDefault;
    btnRefresh.Enabled := True;
  end;

  ShowHtml(html);
end;

{ The help page carries a Google Translate box in its header bar. The embedded viewer is too old to run
  that widget, so this opens the same page in the default browser, where the language box works. }
procedure TfrmHelp.btnTranslateClick(Sender: TObject);
begin
  if (FTempFile = '') or not TFile.Exists(FTempFile) then Exit;
  FBrowserFile := TPath.Combine(ExtractFilePath(FTempFile), 'udaw-help-translate.html');
  try
    TFile.Copy(FTempFile, FBrowserFile, True);
  except
    on E: Exception do
    begin
      MessageDlg('Could not prepare the help page for your browser:' + sLineBreak + E.Message, mtError, [mbOK], 0);
      Exit;
    end;
  end;
  ShellExecute(0, 'open', PChar(FBrowserFile), nil, nil, SW_SHOWNORMAL);
end;

{ The License / EULA page: its own temp file and caption, and no Refresh/Translate buttons
  (those reload or translate the Help Centre). }
procedure TfrmHelp.ShowLicense(const AHtml: string);
begin
  Caption := 'UDAW License and EULA';
  FTempName := 'udaw-license.html';
  btnRefresh.Visible := False;
  btnTranslate.Visible := False;
  ShowHtml(AHtml);
end;

procedure TfrmHelp.ShowHtml(const AHtml: string);
var
  url: string;
begin
  { wide enough for the page's two columns, but never larger than the screen }
  if not Visible then
  begin
    if Width > Screen.WorkAreaWidth - 20 then Width := Screen.WorkAreaWidth - 20;
    if Height > Screen.WorkAreaHeight - 20 then Height := Screen.WorkAreaHeight - 20;
    Left := Screen.WorkAreaLeft + (Screen.WorkAreaWidth - Width) div 2;
    Top := Screen.WorkAreaTop + (Screen.WorkAreaHeight - Height) div 2;
  end;
  if FTempFile = '' then
    begin
      ForceDirectories(Paths.Temp);
      if FTempName = '' then FTempName := 'udaw-help.html';
      FTempFile := TPath.Combine(Paths.Temp, FTempName);
    end;

  TFile.WriteAllText(FTempFile, CMotw + AHtml, TEncoding.UTF8);

  { The embedded ActiveX control is only created (and its IWebBrowser2
    interface pointer valid) once the control has a real window handle -
    force that now rather than relying on Show doing it later, or Navigate
    silently targets nothing. }
  wb.HandleNeeded;
  url := 'file:///' + StringReplace(FTempFile, '\', '/', [rfReplaceAll]);
  wb.Navigate(url);
end;

end.
