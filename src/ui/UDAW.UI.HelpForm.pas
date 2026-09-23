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
  Dialogs, OleCtrls, SHDocVw, IOUtils, ExtCtrls, StdCtrls, UITypes,
  UDAW.Paths, UDAW.Web.HelpClient;

type
  TfrmHelp = class(TForm)
    wb: TWebBrowser;
    pnlToolbar: TPanel;
    btnRefresh: TButton;
    procedure FormClose(Sender: TObject; var Action: TCloseAction);
    procedure FormDestroy(Sender: TObject);
    procedure btnRefreshClick(Sender: TObject);
  private
    FTempFile: string;
  public
    procedure ShowHtml(const AHtml: string);
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

procedure TfrmHelp.ShowHtml(const AHtml: string);
var
  url: string;
begin
  if FTempFile = '' then
    begin
      ForceDirectories(Paths.Temp);
      FTempFile := TPath.Combine(Paths.Temp, 'udaw-help.html');
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
