unit UDAW.Version;
{$I udaw.inc}

{ Runtime build identity.

  The product's version scheme is "1.0.<build>.<ddmmyyyy>" - a build number
  that auto-increments on every successful compile (scripts\build-windows.ps1
  bumps resources\UDAW.rc and UDAW_FALLBACK_BUILD_NUMBER below together (scripts\build.ps1),
  before compiling, and only keeps the bump if dcc64 actually succeeds),
  followed by the date that build was actually produced. That is NOT a shape
  the Win32
  FILEVERSION resource can hold directly (it's four plain 16-bit numbers,
  no date), so the approach here is:

    1. resources/UDAW.rc carries the numeric Major.Minor.Release.Build quad
       (the build component is bumped on every compile), which is embedded by the Windows build script.
    2. At runtime, UDAWBuildNumber reads that quad back out of the running
       .exe's own version resource (GetFileVersionInfo/VerQueryValue) and
       UDAWBuildDate reads the .exe's PE header link timestamp (the actual
       date THIS build was produced, not "today", which would just be
       whatever date someone happens to run it).
    3. UDAWDisplayVersionString combines both into the string the splash
       screen, About dialog and startup log line all show.

  Deliberately its own unit, not folded into UDAW.Types: UDAW.Types must
  stay platform-agnostic (its own header says so, and the Lazarus/FPC build
  leg needs it dependency-free), while reading a PE header and a Win32
  version resource is inherently Windows API surface - this unit degrades
  to a build number of 0 / the current date on non-Windows so the FPC leg
  still compiles, per this project's "Windows first" priority. }

interface

uses
  SysUtils, Classes, DateUtils
  {$IFDEF UDAW_WINDOWS}
  , Winapi.Windows
  {$ENDIF}
  ;

{ The Build component of the running executable's own Win32 version
  resource. 0 if the resource can't be read (non-Windows, or an
  unbuilt/unversioned executable). }
function UDAWBuildNumber: Cardinal;

{ The PE header's link timestamp of the running executable - the date THIS
  build was actually produced. Falls back to Now on non-Windows or if the
  header can't be read. }
function UDAWBuildDate: TDateTime;

{ "1.0.<build>.<ddmmyyyy>" - the product's full display version. }
function UDAWDisplayVersionString: string;

{ "Version <display version>" for the splash and Welcome screens; a DEBUG build
  appends " (DEBUG)" so a development build can't be mistaken for a release. }
function UDAWVersionBannerText: string;

{ "Major.Minor.0.<build>" - the purely numeric quad UDAW.Update compares
  against the online manifest's version (same shape as the .rc FILEVERSION). }
function UDAWNumericVersion: string;

implementation

uses
  UDAW.Types;

const
  { Mirrors resources\UDAW.rc's current FILEVERSION build component -
    scripts\build-windows.ps1 keeps the two in lockstep on every successful
    compile. Used only as a fallback when the running binary has no readable
    version resource yet (e.g. a quick FPC/debug build without a compiled-in
    .res), so the splash screen never shows "build 0". }
  UDAW_FALLBACK_BUILD_NUMBER = 682;

{$IFDEF UDAW_WINDOWS}

function UDAWBuildNumber: Cardinal;
var
  exeName: string;
  infoSize, handle: DWORD;
  buf: TBytes;
  fixedInfo: Pointer;
  fixedLen: UINT;
begin
  Result := 0;
  exeName := ParamStr(0);
  infoSize := GetFileVersionInfoSize(PChar(exeName), handle);
  if infoSize = 0 then Exit;
  SetLength(buf, infoSize);
  if not GetFileVersionInfo(PChar(exeName), handle, infoSize, @buf[0]) then Exit;
  if not VerQueryValue(@buf[0], '\', fixedInfo, fixedLen) then Exit;
  if (fixedInfo = nil) or (fixedLen < SizeOf(TVSFixedFileInfo)) then Exit;
  Result := LoWord(PVSFixedFileInfo(fixedInfo)^.dwFileVersionLS);
end;

function UDAWBuildDate: TDateTime;
const
  { 1970-01-01 expressed as a Delphi TDateTime (days since 1899-12-30). }
  UNIX_EPOCH_DELPHI: TDateTime = 25569.0;
var
  exeName: string;
  fs: TFileStream;
  dosHeader: TImageDosHeader;
  peSignature: DWORD;
  fileHeader: TImageFileHeader;
begin
  Result := 0;
  exeName := ParamStr(0);
  try
    fs := TFileStream.Create(exeName, fmOpenRead or fmShareDenyNone);
    try
      fs.ReadBuffer(dosHeader, SizeOf(dosHeader));
      if dosHeader.e_magic <> IMAGE_DOS_SIGNATURE then Exit;
      fs.Position := dosHeader._lfanew;
      fs.ReadBuffer(peSignature, SizeOf(peSignature));
      if peSignature <> IMAGE_NT_SIGNATURE then Exit;
      fs.ReadBuffer(fileHeader, SizeOf(fileHeader));
      if fileHeader.TimeDateStamp = 0 then Exit;
      { the stamp is UTC; the displayed date is the local day the build was made }
      Result := TTimeZone.Local.ToLocalTime(UNIX_EPOCH_DELPHI + (fileHeader.TimeDateStamp / 86400.0));
    finally
      fs.Free;
    end;
  except
    Result := 0;
  end;
end;

{$ELSE}

function UDAWBuildNumber: Cardinal;
begin
  Result := 0;
end;

function UDAWBuildDate: TDateTime;
begin
  Result := 0;
end;

{$ENDIF}

function UDAWDisplayVersionString: string;
var
  build: Cardinal;
  bdate: TDateTime;
begin
  build := UDAWBuildNumber;
  if build = 0 then build := UDAW_FALLBACK_BUILD_NUMBER;
  bdate := UDAWBuildDate;
  if bdate <= 0 then bdate := Now;
  Result := Format('%d.%d.%d.%s',
    [UDAW_VERSION_MAJOR, UDAW_VERSION_MINOR, build, FormatDateTime('ddmmyyyy', bdate)]);
end;

function UDAWVersionBannerText: string;
begin
  Result := 'Version ' + UDAWDisplayVersionString;
  {$IFDEF DEBUG}
  Result := Result + ' (DEBUG)';
  {$ENDIF}
end;

function UDAWNumericVersion: string;
var
  build: Cardinal;
begin
  build := UDAWBuildNumber;
  if build = 0 then build := UDAW_FALLBACK_BUILD_NUMBER;
  Result := Format('%d.%d.0.%d', [UDAW_VERSION_MAJOR, UDAW_VERSION_MINOR, build]);
end;

end.
