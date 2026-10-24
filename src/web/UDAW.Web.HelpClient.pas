unit UDAW.Web.HelpClient;

{ Loads the UDAW Help Centre page from disk - the help is no longer fetched from
  the web server (it is offline), so the page ships with the application:

    1. about-udaw.dat next to the executable, or two folders up (build\bin ->
       the project root, the development layout);
    2. otherwise the copy embedded in the executable (UDAW_HELP in
       resources\UDAW.rc), so the Help Centre still opens when the loose file
       was not deployed.

  The loose file is preferred so an edited help page shows up without a
  rebuild. Windows/Delphi only. }

interface

uses
  SysUtils, Classes;

const
  UDAW_HELP_FILE = 'about-udaw.dat';

{ Returns True and the page body in AHtml on success; returns False and a
  human-readable failure reason in AErrorMsg otherwise. The name is kept from
  the days the page came over HTTPS. }
function FetchUDAWHelpPage(out AHtml: string; out AErrorMsg: string): Boolean;

implementation

uses
  Winapi.Windows, System.IOUtils;

function FindHelpFile: string;
var
  exeDir: string;
begin
  exeDir := ExtractFilePath(ParamStr(0));
  Result := exeDir + UDAW_HELP_FILE;
  if FileExists(Result) then Exit;
  Result := ExpandFileName(exeDir + '..\..\' + UDAW_HELP_FILE);
  if FileExists(Result) then Exit;
  Result := '';
end;

function FetchUDAWHelpPage(out AHtml: string; out AErrorMsg: string): Boolean;
var
  path: string;
  res: TResourceStream;
  bytes: TBytes;
begin
  Result := False;
  AHtml := '';
  AErrorMsg := '';
  path := FindHelpFile;
  if path <> '' then
  begin
    try
      AHtml := TFile.ReadAllText(path, TEncoding.UTF8);
      Exit(True);
    except
      on E: Exception do
        AErrorMsg := 'Could not read ' + path + ': ' + E.Message;
    end;
  end;
  { fall back to the page embedded in the executable }
  try
    res := TResourceStream.Create(HInstance, 'UDAW_HELP', RT_RCDATA);
    try
      SetLength(bytes, res.Size);
      if res.Size > 0 then res.ReadBuffer(bytes[0], res.Size);
    finally
      res.Free;
    end;
    AHtml := TEncoding.UTF8.GetString(bytes);
    Result := AHtml <> '';
    if Result then AErrorMsg := '';
  except
    on E: Exception do
      if AErrorMsg = '' then
        AErrorMsg := UDAW_HELP_FILE + ' was not found next to UDAW.exe and no help page is embedded.';
  end;
end;

end.
