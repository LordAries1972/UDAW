unit UDAW.UI.SplashForm;
{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}

{ Startup splash screen: shown from the .dpr/.lpr entry point for the
  duration of TUDAWApp.Initialize, so the user sees the app name, version
  (UDAW.Version.UDAWDisplayVersionString), author credit and a real,
  determinate progress bar tracking each module TUDAWApp actually brings up
  (see TUDAWApp.OnProgress) - not a generic spinner. Every control is placed
  at design time (see the .dfm for Delphi/VCL and the .lfm for Lazarus/LCL),
  per this project's forms rule; this unit only wires the logo image and the
  progress callback, it never creates controls at run time.

  ShowSplash/CloseSplash bracket the whole startup sequence: the caller shows
  the splash, assigns its OnAppProgress method to TUDAWApp.OnProgress, runs
  Initialize, then closes/frees the splash before creating the main form -
  exactly the same "show, drive from a real callback, tear down" shape as
  UDAW.UI.HelpForm's embedded browser window uses for its own async load. }

interface

uses
  {$IFDEF FPC}
  LCLIntf,
  {$ELSE}
  Winapi.Windows, Vcl.Imaging.pngimage,   // registers .png with TPicture (see ShowSplash's LoadFromFile)
  {$ENDIF}
  SysUtils, Classes, Graphics, Controls, Forms, StdCtrls, ExtCtrls, ComCtrls;

type
  TfrmSplash = class(TForm)
    pnlMain: TPanel;
    imgLogo: TImage;
    lblAppName: TLabel;
    lblVersion: TLabel;
    lblAuthor: TLabel;
    lblStatus: TLabel;
    prgLoad: TProgressBar;
    pnlActivity: TPanel;
  private
    FActivityThread: TThread;
  public
    destructor Destroy; override;
    { Matches UDAW.App.TUDAWProgressEvent's signature exactly, so the caller
      can assign this method straight onto TUDAWApp.OnProgress. Pumps the
      message queue after each update (Application.Run hasn't started yet
      at this point in startup, so nothing else does) so the bar and status
      text actually repaint between synchronous Initialize steps instead of
      only flashing once at the end. }
    procedure OnAppProgress(const AStep: string; ADone, ATotal: Integer);
  end;

{ Creates and shows the splash (non-modal, on top, centred), loading the
  logo image from ALogoPngPath (pass '' to skip the image, e.g. if the file
  isn't found - a missing splash graphic is never fatal to startup). Caller
  owns the returned form and must free it (CloseSplash does that). }
function ShowSplash(const ALogoPngPath, AAppName, AVersionText, AAuthorText: string): TfrmSplash;
procedure CloseSplash(var ASplash: TfrmSplash);

implementation

uses Math, UDAW.UI.Theme
  {$IFNDEF FPC}, Vcl.Themes{$ENDIF};

{$IFDEF FPC}
{$R *.lfm}
{$ELSE}
{$R *.dfm}
{$ENDIF}

{$IFNDEF FPC}
type
  { Only raw GDI calls on this worker: no VCL access, synchronization or
    message-loop dependency. Startup audio keeps its original COM thread. }
  TSplashActivityThread = class(TThread)
  private
    FTarget: HWND;
    FWidth, FHeight: Integer;
    FBackground, FForeground: COLORREF;
  protected
    procedure Execute; override;
  public
    constructor Create(ATarget: HWND; AWidth, AHeight: Integer; ABackground, AForeground: TColor);
  end;

constructor TSplashActivityThread.Create(ATarget: HWND; AWidth, AHeight: Integer;
  ABackground, AForeground: TColor);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FTarget := ATarget; FWidth := AWidth; FHeight := AHeight;
  FBackground := ColorToRGB(ABackground); FForeground := ColorToRGB(AForeground);
end;

procedure TSplashActivityThread.Execute;
var dc, buffer: HDC; bitmap, oldBitmap: HGDIOBJ; brush, oldBrush, oldPen: HGDIOBJ;
  rect: TRect; i, phase, weight, x, y, radius, dot: Integer;
  angle: Double; color: COLORREF;
begin
  dc := GetDC(FTarget);
  if dc = 0 then Exit;
  buffer := CreateCompatibleDC(dc);
  bitmap := CreateCompatibleBitmap(dc, FWidth, FHeight);
  oldBitmap := SelectObject(buffer, bitmap);
  oldPen := SelectObject(buffer, GetStockObject(NULL_PEN));
  try
    rect.Left := 0; rect.Top := 0; rect.Right := FWidth; rect.Bottom := FHeight;
    radius := Max(4, Min(FWidth, FHeight) div 2 - 5);
    dot := Max(2, Min(FWidth, FHeight) div 14);
    while not Terminated do
    begin
      brush := CreateSolidBrush(FBackground);
      Winapi.Windows.FillRect(buffer, rect, brush); DeleteObject(brush);
      phase := (TThread.GetTickCount64 div 75) mod 12;
      for i := 0 to 11 do
      begin
        weight := 35 + ((i + 12 - phase) mod 12) * 20;
        color := RGB(
          (GetRValue(FForeground) * weight + GetRValue(FBackground) * (255 - weight)) div 255,
          (GetGValue(FForeground) * weight + GetGValue(FBackground) * (255 - weight)) div 255,
          (GetBValue(FForeground) * weight + GetBValue(FBackground) * (255 - weight)) div 255);
        angle := i * Pi / 6;
        x := FWidth div 2 + Round(Cos(angle) * radius);
        y := FHeight div 2 + Round(Sin(angle) * radius);
        brush := CreateSolidBrush(color); oldBrush := SelectObject(buffer, brush);
        Ellipse(buffer, x - dot, y - dot, x + dot + 1, y + dot + 1);
        SelectObject(buffer, oldBrush); DeleteObject(brush);
      end;
      BitBlt(dc, 0, 0, FWidth, FHeight, buffer, 0, 0, SRCCOPY);
      Sleep(33);
    end;
  finally
    SelectObject(buffer, oldPen); SelectObject(buffer, oldBitmap);
    DeleteObject(bitmap); DeleteDC(buffer); ReleaseDC(FTarget, dc);
  end;
end;
{$ENDIF}

destructor TfrmSplash.Destroy;
begin
  if FActivityThread <> nil then
  begin
    FActivityThread.Terminate;
    FActivityThread.WaitFor;
    FreeAndNil(FActivityThread);
  end;
  inherited Destroy;
end;

function ShowSplash(const ALogoPngPath, AAppName, AVersionText, AAuthorText: string): TfrmSplash;
begin
  ThemeInitForStartup;
  Result := TfrmSplash.Create(nil);
  try
    Result.lblAppName.Caption := AAppName;
    Result.lblVersion.Caption := AVersionText;
    Result.lblAuthor.Caption := AAuthorText;
    Result.lblStatus.Caption := 'Starting...';
    Result.prgLoad.Position := 0;
    if (ALogoPngPath <> '') and FileExists(ALogoPngPath) then
    begin
      try
        Result.imgLogo.Picture.LoadFromFile(ALogoPngPath);
      except
        { a broken/unreadable logo file must never block startup }
        Result.imgLogo.Picture := nil;
      end;
    end;
    Result.Show;
    Result.Update;
    {$IFNDEF FPC}
    Result.FActivityThread := TSplashActivityThread.Create(Result.pnlActivity.Handle,
      Result.pnlActivity.ClientWidth, Result.pnlActivity.ClientHeight,
      StyleServices.GetSystemColor(clBtnFace), StyleServices.GetSystemColor(clHighlight));
    Result.FActivityThread.Start;
    {$ENDIF}
  except
    Result.Free;
    raise;
  end;
end;

procedure CloseSplash(var ASplash: TfrmSplash);
begin
  if ASplash = nil then Exit;
  ASplash.Close;
  ASplash.Free;
  ASplash := nil;
end;

procedure TfrmSplash.OnAppProgress(const AStep: string; ADone, ATotal: Integer);
begin
  lblStatus.Caption := AStep;
  if ATotal > 0 then
  begin
    prgLoad.Max := ATotal;
    prgLoad.Position := ADone;
  end;
  Update;
  Application.ProcessMessages;
end;

end.
