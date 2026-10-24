unit UDAW.UI.Display;

{ How UDAW's window sits on the screen: in an ordinary window, as a borderless window that covers a
  monitor, or in exclusive full screen - the monitor itself is switched to the resolution and refresh
  rate you choose, and Windows puts it back by itself when UDAW ends (the mode is applied with
  CDS_FULLSCREEN, never written to the registry).

  ListMonitors / ListDisplayModes enumerate what the machine offers, so the Settings page only ever
  shows modes that exist. TDisplayController applies a choice to a form and undoes it. }

interface

uses
  Winapi.Windows, Winapi.MultiMon, System.SysUtils, System.Classes, System.Types,
  System.Generics.Collections, Vcl.Forms, Vcl.Controls;

type
  TScreenMode = (smWindowed, smBorderless, smExclusive);

  TDisplayMode = record
    Width, Height, Frequency, Bits: Integer;
  end;

  TMonitorEntry = record
    Device: string;      // \\.\DISPLAY1
    Caption: string;     // "1 - 2560 x 1440 (primary)"
    Rect: TRect;
    Primary: Boolean;
  end;

function ListMonitors: TArray<TMonitorEntry>;
{ the distinct modes of one display device (32-bit colour), widest and fastest first }
function ListDisplayModes(const ADevice: string): TArray<TDisplayMode>;
function CurrentDisplayMode(const ADevice: string; out AMode: TDisplayMode): Boolean;
function DisplayModeText(const AMode: TDisplayMode): string;
function SameDisplayMode(const A, B: TDisplayMode): Boolean;
function ScreenModeName(AMode: TScreenMode): string;

type
  TDisplayController = class
  private
    FForm: TForm;
    FMode: TScreenMode;
    FDevice: string;            // the monitor the full-screen window is on
    FChangedDevice: string;     // the device whose mode this object switched ('' = none)
    FSavedBounds: TRect;
    FSavedMax: Boolean;
    FSavedBorder: TFormBorderStyle;
    FHaveSaved: Boolean;
    procedure SaveWindowed;
    procedure RestoreDisplayMode;
    function MonitorRect(const ADevice: string): TRect;
  public
    constructor Create(AForm: TForm);
    destructor Destroy; override;
    { applies a screen mode; False with a reason in AError when the monitor refused the mode (the window
      then stays borderless at the monitor's current mode) }
    function Apply(AMode: TScreenMode; const ADevice: string; const AWant: TDisplayMode;
      out AError: string): Boolean;
    property Mode: TScreenMode read FMode;
    property Device: string read FDevice;
    property IsFullScreen: Boolean read FHaveSaved;
  end;

implementation

uses
  System.StrUtils, System.Math, Vcl.Graphics;

const
  ENUM_CURRENT_SETTINGS = DWORD(-1);

function ScreenModeName(AMode: TScreenMode): string;
begin
  case AMode of
    smWindowed: Result := 'Windowed';
    smBorderless: Result := 'Borderless full screen';
    smExclusive: Result := 'Exclusive full screen';
  else
    Result := '?';
  end;
end;

function DisplayModeText(const AMode: TDisplayMode): string;
begin
  Result := Format('%d x %d @ %d Hz', [AMode.Width, AMode.Height, AMode.Frequency]);
end;

function SameDisplayMode(const A, B: TDisplayMode): Boolean;
begin
  Result := (A.Width = B.Width) and (A.Height = B.Height) and (A.Frequency = B.Frequency);
end;

function MonitorProc(AMon: HMONITOR; ADC: HDC; ARect: PRect; AData: LPARAM): BOOL; stdcall;
var
  list: TList<TMonitorEntry>;
  mi: TMonitorInfoEx;
  e: TMonitorEntry;
begin
  Result := True;
  list := TList<TMonitorEntry>(AData);
  FillChar(mi, SizeOf(mi), 0);
  mi.cbSize := SizeOf(mi);
  if not GetMonitorInfo(AMon, @mi) then Exit;
  e.Device := string(mi.szDevice);
  e.Rect := mi.rcMonitor;
  e.Primary := (mi.dwFlags and MONITORINFOF_PRIMARY) <> 0;
  e.Caption := Format('%d - %d x %d%s', [list.Count + 1, mi.rcMonitor.Right - mi.rcMonitor.Left,
    mi.rcMonitor.Bottom - mi.rcMonitor.Top, IfThen(e.Primary, ' (primary)', '')]);
  list.Add(e);
end;

function ListMonitors: TArray<TMonitorEntry>;
var
  list: TList<TMonitorEntry>;
  i, p: Integer;
  tmp: TMonitorEntry;
begin
  list := TList<TMonitorEntry>.Create;
  try
    EnumDisplayMonitors(0, nil, @MonitorProc, LPARAM(list));
    Result := list.ToArray;
  finally
    list.Free;
  end;
  { the primary monitor first, the numbering follows that order }
  for i := 0 to High(Result) do
    if Result[i].Primary then
    begin
      p := i;
      if p > 0 then
      begin
        tmp := Result[0];
        Result[0] := Result[p];
        Result[p] := tmp;
      end;
      Break;
    end;
  for i := 0 to High(Result) do
    Result[i].Caption := Format('%d - %d x %d%s', [i + 1, Result[i].Rect.Right - Result[i].Rect.Left,
      Result[i].Rect.Bottom - Result[i].Rect.Top, IfThen(Result[i].Primary, ' (primary)', '')]);
end;

function CurrentDisplayMode(const ADevice: string; out AMode: TDisplayMode): Boolean;
var
  dm: TDevMode;
begin
  FillChar(dm, SizeOf(dm), 0);
  dm.dmSize := SizeOf(dm);
  Result := EnumDisplaySettings(PChar(ADevice), ENUM_CURRENT_SETTINGS, dm);
  if Result then
  begin
    AMode.Width := dm.dmPelsWidth;
    AMode.Height := dm.dmPelsHeight;
    AMode.Frequency := dm.dmDisplayFrequency;
    AMode.Bits := dm.dmBitsPerPel;
  end;
end;

function ListDisplayModes(const ADevice: string): TArray<TDisplayMode>;
var
  dm: TDevMode;
  i, j: Integer;
  m, t: TDisplayMode;
  list: TList<TDisplayMode>;
  dup: Boolean;
begin
  list := TList<TDisplayMode>.Create;
  try
    i := 0;
    FillChar(dm, SizeOf(dm), 0);
    dm.dmSize := SizeOf(dm);
    while EnumDisplaySettings(PChar(ADevice), i, dm) do
    begin
      if (dm.dmBitsPerPel = 32) and (dm.dmPelsWidth >= 640) then
      begin
        m.Width := dm.dmPelsWidth;
        m.Height := dm.dmPelsHeight;
        m.Frequency := dm.dmDisplayFrequency;
        m.Bits := 32;
        dup := False;
        for j := 0 to list.Count - 1 do
          if SameDisplayMode(list[j], m) then
          begin
            dup := True;
            Break;
          end;
        if not dup then list.Add(m);
      end;
      Inc(i);
      FillChar(dm, SizeOf(dm), 0);
      dm.dmSize := SizeOf(dm);
    end;
    Result := list.ToArray;
  finally
    list.Free;
  end;
  { widest, then tallest, then fastest first }
  for i := 0 to High(Result) - 1 do
    for j := i + 1 to High(Result) do
      if (Result[j].Width > Result[i].Width) or
         ((Result[j].Width = Result[i].Width) and (Result[j].Height > Result[i].Height)) or
         ((Result[j].Width = Result[i].Width) and (Result[j].Height = Result[i].Height) and
          (Result[j].Frequency > Result[i].Frequency)) then
      begin
        t := Result[i];
        Result[i] := Result[j];
        Result[j] := t;
      end;
end;

{ TDisplayController }

constructor TDisplayController.Create(AForm: TForm);
begin
  inherited Create;
  FForm := AForm;
  FMode := smWindowed;
end;

destructor TDisplayController.Destroy;
begin
  RestoreDisplayMode;
  inherited Destroy;
end;

function TDisplayController.MonitorRect(const ADevice: string): TRect;
var
  m: TArray<TMonitorEntry>;
  i: Integer;
begin
  m := ListMonitors;
  for i := 0 to High(m) do
    if SameText(m[i].Device, ADevice) then Exit(m[i].Rect);
  if Length(m) > 0 then Exit(m[0].Rect);
  Result := Rect(0, 0, GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN));
end;

procedure TDisplayController.SaveWindowed;
var
  wp: TWindowPlacement;
begin
  if FHaveSaved then Exit;
  FSavedMax := FForm.WindowState = wsMaximized;
  FSavedBorder := FForm.BorderStyle;
  wp.length := SizeOf(wp);
  if GetWindowPlacement(FForm.Handle, @wp) then FSavedBounds := wp.rcNormalPosition
  else FSavedBounds := FForm.BoundsRect;
  FHaveSaved := True;
end;

{ the monitor goes back to the mode it had before this object switched it }
procedure TDisplayController.RestoreDisplayMode;
begin
  if FChangedDevice <> '' then
  begin
    ChangeDisplaySettingsEx(PChar(FChangedDevice), nil, 0, 0, nil);
    FChangedDevice := '';
  end;
end;

function TDisplayController.Apply(AMode: TScreenMode; const ADevice: string; const AWant: TDisplayMode;
  out AError: string): Boolean;
var
  dm: TDevMode;
  r: Integer;
  rc: TRect;
begin
  AError := '';
  Result := True;
  FForm.DisableAlign;
  try
    case AMode of
      smWindowed:
        begin
          RestoreDisplayMode;
          if FHaveSaved then
          begin
            FForm.BorderStyle := FSavedBorder;
            FForm.WindowState := wsNormal;
            FForm.BoundsRect := FSavedBounds;
            if FSavedMax then FForm.WindowState := wsMaximized;
            FHaveSaved := False;
          end;
          FMode := smWindowed;
          FDevice := '';
        end;

      smBorderless, smExclusive:
        begin
          SaveWindowed;
          RestoreDisplayMode;
          FDevice := ADevice;
          if AMode = smExclusive then
          begin
            FillChar(dm, SizeOf(dm), 0);
            dm.dmSize := SizeOf(dm);
            dm.dmPelsWidth := AWant.Width;
            dm.dmPelsHeight := AWant.Height;
            dm.dmDisplayFrequency := AWant.Frequency;
            dm.dmBitsPerPel := 32;
            dm.dmFields := DM_PELSWIDTH or DM_PELSHEIGHT or DM_DISPLAYFREQUENCY or DM_BITSPERPEL;
            r := ChangeDisplaySettingsEx(PChar(ADevice), @dm, 0, CDS_FULLSCREEN, nil);
            if r = DISP_CHANGE_SUCCESSFUL then
              FChangedDevice := ADevice
            else
            begin
              case r of
                DISP_CHANGE_BADMODE: AError := 'the monitor does not support ' + DisplayModeText(AWant);
                DISP_CHANGE_RESTART: AError := 'Windows needs a restart for that mode';
                DISP_CHANGE_FAILED: AError := 'the display driver refused the mode';
              else
                AError := 'the mode could not be set (error ' + IntToStr(r) + ')';
              end;
              Result := False;   // falls through to borderless at the monitor's own mode
            end;
          end;
          FForm.WindowState := wsNormal;
          FForm.BorderStyle := bsNone;
          rc := MonitorRect(ADevice);
          FForm.BoundsRect := rc;
          if Result and (AMode = smExclusive) then FMode := smExclusive else FMode := smBorderless;
        end;
    end;
  finally
    FForm.EnableAlign;
  end;
end;

end.
