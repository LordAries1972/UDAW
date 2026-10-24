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
  UDAW.UI.CapsuleProgress,                // the OpenGL 3.3 capsule progress bar
  {$ENDIF}
  SysUtils, Classes, Graphics, Controls, Forms, StdCtrls, ExtCtrls, ComCtrls,
  UDAW.GL.Widgets;

type
  TfrmSplash = class(TForm)
    pnlMain: TPanel;
    imgLogo: TImage;
    {$IFDEF FPC}
    lblAppName: TGLLabel;
    {$ELSE}
    pnlTitle: TPanel;               // the animated title is drawn straight onto this by TSplashTitleThread
    {$ENDIF}
    lblVersion: TGLLabel;
    lblAuthor: TGLLabel;
    lblStatus: TGLLabel;
    {$IFDEF FPC}
    prgLoad: TProgressBar;
    {$ELSE}
    prgLoad: TGLCapsuleProgress;    // UDAW's own OpenGL 3.3 progress bar, the one the status bar uses
    {$ENDIF}
    pnlActivity: TPanel;
  private
    FActivityThread: TThread;
    FTitleThread: TThread;
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

type
  TTitleRGB = array[0..2] of Double;

  { Draws the application title with colours that scroll from right to left and pulse, straight onto
    the title panel. Same rules as the activity thread: raw GDI only, no VCL access. The lettering is
    rasterised once into a coverage mask; every frame colours the mask column by column (a travelling
    sine palette, a breathing brightness and a white glint sweeping leftwards) in a 32-bit DIB and
    blits it in one go, so it is smooth and flicker-free. }
  TSplashTitleThread = class(TThread)
  private
    FTarget: HWND;
    FWidth, FHeight: Integer;
    FBackground: COLORREF;
    FText: string;
  protected
    procedure Execute; override;
  public
    constructor Create(ATarget: HWND; AWidth, AHeight: Integer; ABackground: TColor; const AText: string);
  end;

constructor TSplashTitleThread.Create(ATarget: HWND; AWidth, AHeight: Integer;
  ABackground: TColor; const AText: string);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FTarget := ATarget; FWidth := AWidth; FHeight := AHeight;
  FBackground := ColorToRGB(ABackground);
  FText := AText;
end;

procedure TSplashTitleThread.Execute;
var
  dc, mem: HDC;
  bmi: TBitmapInfo;
  maskBmp, outBmp, oldBmp, font, oldFont: HGDIOBJ;
  maskBits, outBits: Pointer;
  cov: TArray<Byte>;
  cols: TArray<TTitleRGB>;
  sz: TSize;
  fs, x, y, c, px: Integer;
  t, a, pulse, m, glint, pos, d, r, g, b, bgR, bgG, bgB: Double;
  row: PCardinal;
  bg: Cardinal;
begin
  dc := GetDC(FTarget);
  if dc = 0 then Exit;
  mem := CreateCompatibleDC(dc);
  ZeroMemory(@bmi, SizeOf(bmi));
  bmi.bmiHeader.biSize := SizeOf(TBitmapInfoHeader);
  bmi.bmiHeader.biWidth := FWidth;
  bmi.bmiHeader.biHeight := -FHeight;          // top-down
  bmi.bmiHeader.biPlanes := 1;
  bmi.bmiHeader.biBitCount := 32;
  bmi.bmiHeader.biCompression := BI_RGB;
  maskBmp := CreateDIBSection(dc, bmi, DIB_RGB_COLORS, maskBits, 0, 0);
  outBmp := CreateDIBSection(dc, bmi, DIB_RGB_COLORS, outBits, 0, 0);
  oldBmp := SelectObject(mem, maskBmp);
  try
    if (maskBits = nil) or (outBits = nil) then Exit;
    ZeroMemory(maskBits, FWidth * FHeight * 4);
    { the biggest bold size that still fits the panel }
    fs := 19;
    repeat
      font := CreateFont(-fs, 0, 0, 0, FW_BOLD, 0, 0, 0, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
        CLIP_DEFAULT_PRECIS, ANTIALIASED_QUALITY, DEFAULT_PITCH, 'Segoe UI');
      oldFont := SelectObject(mem, font);
      GetTextExtentPoint32(mem, PChar(FText), Length(FText), sz);
      if (sz.cx <= FWidth - 12) or (fs <= 9) then Break;
      SelectObject(mem, oldFont); DeleteObject(font);
      Dec(fs);
    until False;
    SetBkMode(mem, TRANSPARENT);
    SetTextColor(mem, $FFFFFF);
    TextOut(mem, (FWidth - sz.cx) div 2, (FHeight - sz.cy) div 2, PChar(FText), Length(FText));
    GdiFlush;
    SetLength(cov, FWidth * FHeight);
    for c := 0 to FWidth * FHeight - 1 do
      cov[c] := PByte(NativeUInt(maskBits) + NativeUInt(c) * 4)^;   // white on black: any channel is the coverage
    SelectObject(mem, oldFont); DeleteObject(font);
    SelectObject(mem, outBmp);
    SetLength(cols, FWidth);
    bgR := GetRValue(FBackground); bgG := GetGValue(FBackground); bgB := GetBValue(FBackground);
    bg := (Cardinal(GetRValue(FBackground)) shl 16) or (Cardinal(GetGValue(FBackground)) shl 8) or GetBValue(FBackground);
    while not Terminated do
    begin
      t := TThread.GetTickCount64 / 1000.0;
      pos := FWidth + 90 - Frac(t * 0.42) * (FWidth + 180);    // the glint travels right to left
      for x := 0 to FWidth - 1 do
      begin
        a := x * 0.021 + t * 2.3;                             // phase grows with time: the colours move left
        r := 0.55 + 0.45 * Sin(a);
        g := 0.55 + 0.45 * Sin(a + 2.094);
        b := 0.55 + 0.45 * Sin(a + 4.188);
        pulse := 0.5 + 0.5 * Sin(x * 0.012 + t * 3.0);        // brightness ripples leftwards too
        m := 0.62 + 0.38 * pulse;
        d := (x - pos) / 26;
        glint := 0.65 * Exp(-d * d);
        r := r * m; g := g * m; b := b * m;
        r := r + (1 - r) * glint; g := g + (1 - g) * glint; b := b + (1 - b) * glint;
        cols[x][0] := r * 255; cols[x][1] := g * 255; cols[x][2] := b * 255;
      end;
      for y := 0 to FHeight - 1 do
      begin
        row := PCardinal(NativeUInt(outBits) + NativeUInt(y) * NativeUInt(FWidth) * 4);
        for x := 0 to FWidth - 1 do
        begin
          c := cov[y * FWidth + x];
          if c = 0 then row^ := bg
          else
          begin
            d := c / 255;
            px := (Round(bgR + (cols[x][0] - bgR) * d) shl 16) or
                  (Round(bgG + (cols[x][1] - bgG) * d) shl 8) or
                   Round(bgB + (cols[x][2] - bgB) * d);
            row^ := Cardinal(px);
          end;
          Inc(row);
        end;
      end;
      GdiFlush;
      BitBlt(dc, 0, 0, FWidth, FHeight, mem, 0, 0, SRCCOPY);
      Sleep(16);
    end;
  finally
    SelectObject(mem, oldBmp);
    DeleteObject(maskBmp); DeleteObject(outBmp);
    DeleteDC(mem); ReleaseDC(FTarget, dc);
  end;
end;
{$ENDIF}

destructor TfrmSplash.Destroy;
begin
  if FTitleThread <> nil then
  begin
    FTitleThread.Terminate;
    FTitleThread.WaitFor;
    FreeAndNil(FTitleThread);
  end;
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
    {$IFDEF FPC}
    Result.lblAppName.Caption := AAppName;
    {$ENDIF}
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
    {$IFNDEF FPC}
    { No loose file next to the exe (installed / relocated build): use the copy
      embedded in the executable (UDAW_SPLASH in resources/UDAW.rc). }
    if Result.imgLogo.Picture.Graphic = nil then
    try
      var res := TResourceStream.Create(HInstance, 'UDAW_SPLASH', RT_RCDATA);
      try
        var png := TPngImage.Create;
        try
          png.LoadFromStream(res);
          Result.imgLogo.Picture.Assign(png);
        finally
          png.Free;
        end;
      finally
        res.Free;
      end;
    except
      Result.imgLogo.Picture := nil;
    end;
    {$ENDIF}
    Result.Show;
    Result.Update;
    {$IFNDEF FPC}
    Result.FActivityThread := TSplashActivityThread.Create(Result.pnlActivity.Handle,
      Result.pnlActivity.ClientWidth, Result.pnlActivity.ClientHeight,
      StyleServices.GetSystemColor(clBtnFace), StyleServices.GetSystemColor(clHighlight));
    Result.FActivityThread.Start;
    Result.FTitleThread := TSplashTitleThread.Create(Result.pnlTitle.Handle,
      Result.pnlTitle.ClientWidth, Result.pnlTitle.ClientHeight,
      StyleServices.GetSystemColor(clBtnFace), AAppName);
    Result.FTitleThread.Start;
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

{$IFNDEF FPC}
initialization
  { the splash form is streamed before the main form's unit has registered anything }
  RegisterClass(TGLCapsuleProgress);
{$ENDIF}

end.
