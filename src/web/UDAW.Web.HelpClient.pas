unit UDAW.Web.HelpClient;

{ Fetches the UDAW Help Centre page (UDAW_HELP_URL, see UDAW.Types) over
  HTTPS using Indy's TIdHTTP with a TaurusTLS IOHandler (OpenSSL-backed TLS
  1.2+), rather than System.Net.HttpClient/WinHTTP - TaurusTLS gives this
  request its own explicit, modern TLS stack independent of the OS's
  Schannel configuration.

  TaurusTLS lazy-loads libcrypto-4-x64.dll / libssl-4-x64.dll from the
  executable's own directory (or the user's PATH) the first time this is
  called - see ThirdParty\OpenSSL\Win64, which UDAW.dproj's AfterBuild
  target copies next to the exe on every build.

  The server only serves this exact URL to a caller sending the header
  Referer: UDAW/1.0 - anyone else (browsers included) gets HTTP 403. See
  F:\Projects\Web\EffectualDesigns\index.php ("about-udaw" case) and
  library.php's CheckReferer. Windows/Delphi only. }

interface

uses
  SysUtils, IdHTTP, TaurusTLS,
  UDAW.Types;

{ Returns True and the page body in AHtml on success; returns False and a
  human-readable failure reason in AErrorMsg otherwise (network failure,
  TLS failure, or a non-200 HTTP status). }
function FetchUDAWHelpPage(out AHtml: string; out AErrorMsg: string): Boolean;

implementation

function FetchUDAWHelpPage(out AHtml: string; out AErrorMsg: string): Boolean;
var
  http: TIdHTTP;
  ssl: TTaurusTLSIOHandlerSocket;
begin
  Result := False;
  AHtml := '';
  AErrorMsg := '';

  http := TIdHTTP.Create(nil);
  ssl := TTaurusTLSIOHandlerSocket.Create(nil);
  try
    ssl.SSLOptions.MinTLSVersion := TLSv1_2;
    ssl.SSLOptions.VerifyMode := [sslvrfPeer];
    ssl.SSLOptions.VerifyDepth := 9;
    http.IOHandler := ssl;
    http.HandleRedirects := True;
    http.RedirectMaximum := 5;
    http.Request.CustomHeaders.Clear;
    http.Request.CustomHeaders.Values['Referer'] := UDAW_HELP_REFERER;
    http.Request.UserAgent := UDAW_HELP_REFERER;

    try
      AHtml := http.Get(UDAW_HELP_URL);
      Result := True;
    except
      on E: EIdHTTPProtocolException do
        AErrorMsg := Format('HTTP %d: %s', [http.ResponseCode, E.Message]);
      on E: Exception do
        AErrorMsg := E.Message;
    end;
  finally
    http.IOHandler := nil;
    ssl.Free;
    http.Free;
  end;
end;

end.
