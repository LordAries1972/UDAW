unit UDAW.UI.VideoForm;
{$I udaw.inc}

{ The pop-out video window: the Timeline's video playing at its own size in a window of its
  own. It holds nothing but the picture (pnlVideo, a UDAW OpenGL 3.3 panel the renderer draws
  into) and the window's close button - no minimise / maximise, no controls. The main form
  moves the video player's host to pnlVideo while this window is open (see
  TfrmMain.TlVideoPopOut) and back when it closes. }

interface

uses
  SysUtils, Classes, Graphics, Controls, Forms, UDAW.GL.Widgets;

type
  TfrmVideoPlayer = class(TForm)
    pnlVideo: TGLPanel;
    procedure FormClose(Sender: TObject; var Action: TCloseAction);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure pnlVideoResize(Sender: TObject);
  private
    FOnVideoResized: TNotifyEvent;
    FOnClosed: TNotifyEvent;
  public
    { the picture area changed size: the renderer must re-fit }
    property OnVideoResized: TNotifyEvent read FOnVideoResized write FOnVideoResized;
    { the window was closed: the main form puts the video back in its own pane }
    property OnClosed: TNotifyEvent read FOnClosed write FOnClosed;
    { sizes the window so the picture area is AWidth x AHeight, kept inside the screen }
    procedure FitToVideo(AWidth, AHeight: Integer);
  end;

implementation

{$R *.dfm}

procedure TfrmVideoPlayer.FormClose(Sender: TObject; var Action: TCloseAction);
begin
  Action := caHide;
  if Assigned(FOnClosed) then FOnClosed(Self);
end;

procedure TfrmVideoPlayer.FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if Key = 27 then Close;   // Esc, like the close button
end;

procedure TfrmVideoPlayer.pnlVideoResize(Sender: TObject);
begin
  if Assigned(FOnVideoResized) then FOnVideoResized(Self);
end;

procedure TfrmVideoPlayer.FitToVideo(AWidth, AHeight: Integer);
var
  maxW, maxH: Integer;
  k: Double;
begin
  if (AWidth <= 0) or (AHeight <= 0) then Exit;
  maxW := Monitor.WorkareaRect.Width - (Width - ClientWidth) - 40;
  maxH := Monitor.WorkareaRect.Height - (Height - ClientHeight) - 40;
  k := 1.0;
  if AWidth > maxW then k := maxW / AWidth;
  if AHeight * k > maxH then k := maxH / AHeight;
  ClientWidth := Round(AWidth * k);
  ClientHeight := Round(AHeight * k);
end;

end.
