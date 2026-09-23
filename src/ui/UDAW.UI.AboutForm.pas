unit UDAW.UI.AboutForm;
{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}

{ A small, static "About" dialog: application name, publisher, author credit
  and a clickable website link. Every control is placed at design time (see
  the .dfm for the Delphi/VCL build and the .lfm for the Lazarus/LCL build),
  per the project's forms rule - this unit only wires OnClick handlers, it
  never creates controls at run time. }

interface

uses
  {$IFDEF FPC}
  LCLIntf,
  {$ELSE}
  Winapi.Windows, Winapi.ShellAPI,
  {$ENDIF}
  SysUtils, Classes, Graphics, Controls, Forms, StdCtrls, ExtCtrls,
  UDAW.Version;

type
  TfrmAbout = class(TForm)
    pnlMain: TPanel;
    lblAppName: TLabel;
    lblPublisher: TLabel;
    lblAuthor: TLabel;
    lblVersion: TLabel;
    lblWebsiteCaption: TLabel;
    lblWebsite: TLabel;
    btnClose: TButton;
    procedure lblWebsiteClick(Sender: TObject);
    procedure btnCloseClick(Sender: TObject);
  end;

procedure ShowAboutDialog;

implementation

{$IFDEF FPC}
{$R *.lfm}
{$ELSE}
{$R *.dfm}
{$ENDIF}

const
  UDAW_ABOUT_URL = 'https://ultimanium.com/';

procedure ShowAboutDialog;
var
  frm: TfrmAbout;
begin
  frm := TfrmAbout.Create(nil);
  try
    frm.lblVersion.Caption := 'Version ' + UDAWDisplayVersionString;
    frm.ShowModal;
  finally
    frm.Free;
  end;
end;

procedure TfrmAbout.lblWebsiteClick(Sender: TObject);
begin
  {$IFDEF FPC}
  OpenURL(UDAW_ABOUT_URL);
  {$ELSE}
  ShellExecute(0, 'open', PChar(UDAW_ABOUT_URL), nil, nil, SW_SHOWNORMAL);
  {$ENDIF}
end;

procedure TfrmAbout.btnCloseClick(Sender: TObject);
begin
  ModalResult := mrOk;
end;

end.
