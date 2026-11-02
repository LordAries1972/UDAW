unit UDAW.Types;
{$I udaw.inc}

{ Core shared types and product constants used across every UDAW layer.
  This unit must not depend on any other UDAW unit. }

interface

uses
  SysUtils;

const
  UDAW_PRODUCT_NAME    = 'Ultimanium Digital Audio Workstation (UDAW)';
  UDAW_SHORT_NAME      = 'UDAW';
  UDAW_VENDOR_NAME     = 'Ultimanium';
  UDAW_AUTHOR_LINE     = #$00A9 + ' Daniel J. Hobson of Australia, 2026';   // (c) sign
  { The product version is "1.0.<build>.<dd/mm/yyyy>" - see UDAW.Version
    (UDAWDisplayVersionString) for the full scheme. UDAW_VERSION_MAJOR/MINOR
    are the fixed 1.0 prefix; the build number and date are read from the
    compiled executable's own resource/PE header at runtime, not stored as
    compile-time constants here, since they change on every build. }
  UDAW_VERSION_MAJOR   = 1;
  UDAW_VERSION_MINOR   = 0;
  UDAW_VERSION_PATCH   = 0;   // unused by the 1.0.<build>.<date> scheme; kept for source compat

  { The desktop client's own web help centre. The server only serves this
    page to a caller sending Referer: UDAW/1.0 exactly (see
    F:\Projects\Web\EffectualDesigns\index.php, case "about-udaw", and
    library.php's CheckReferer) - anyone else, browsers included, gets 403. }
  UDAW_WEB_DOMAIN      = 'https://ultimanium.com';
  UDAW_HELP_URL        = UDAW_WEB_DOMAIN + '/index.php?action=about-udaw';
  UDAW_HELP_REFERER    = 'UDAW/1.0';

type
  { Result of an operation that can fail without necessarily raising. }
  TUDAWResult = record
    Success: Boolean;
    Code: Integer;
    Message: string;
    class function Ok: TUDAWResult; static;
    class function Fail(ACode: Integer; const AMessage: string): TUDAWResult; static;
  end;

  { A monotonic identifier handed out by subsystems (jobs, log sinks, ...). }
  TUDAWId = Int64;

function UDAWVersionString: string;
function UDAWFullVersionString: string;

implementation

class function TUDAWResult.Ok: TUDAWResult;
begin
  Result.Success := True;
  Result.Code := 0;
  Result.Message := '';
end;

class function TUDAWResult.Fail(ACode: Integer; const AMessage: string): TUDAWResult;
begin
  Result.Success := False;
  Result.Code := ACode;
  Result.Message := AMessage;
end;

function UDAWVersionString: string;
begin
  Result := Format('%d.%d.%d', [UDAW_VERSION_MAJOR, UDAW_VERSION_MINOR, UDAW_VERSION_PATCH]);
end;

function UDAWFullVersionString: string;
begin
  Result := Format('%s %s', [UDAW_SHORT_NAME, UDAWVersionString]);
end;

end.
