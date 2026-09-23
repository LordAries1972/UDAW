unit UDAW.AI.MCPTls;
{$I udaw.inc}

{ HTTPS (TLS 1.2+) listener for UDAW's MCP server, so a remote AI agent - one
  outside the local network, reaching this machine through a port forward, a
  reverse proxy or a tunnel - can connect over an encrypted channel. It is a
  thin transport: Indy's TIdHTTPServer + a TaurusTLS (OpenSSL) server IOHandler
  do the sockets and the TLS handshake, and every request is handed to a
  callback (TUDAWMcpServer.HandleHttpRequest) that applies the exact same
  bearer-token check and JSON-RPC dispatch the plain loopback listener uses.

  The certificate + private key are PEM files supplied by the user (e.g. a
  Let's Encrypt / Cloudflare Origin / self-signed cert). Delphi-only: TaurusTLS
  is not wired into the Lazarus build. }

interface

uses
  SysUtils, Classes;

type
  { Called on a listener worker thread. Returns the response body ('' = no body)
    and sets AStatus to the HTTP status code. }
  TMcpTlsRequestEvent = function(const AMethod, AAuthHeader, AOrigin, ABody: string;
    out AStatus: Integer): string of object;

  TMcpTlsListener = class
  private
    FPort: Integer;
    FBindAddress: string;
    FCertFile: string;
    FKeyFile: string;
    FKeyPassword: string;
    FOnRequest: TMcpTlsRequestEvent;
    FImpl: TObject;
    function GetIsRunning: Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    property Port: Integer read FPort write FPort;
    property BindAddress: string read FBindAddress write FBindAddress;
    property CertFile: string read FCertFile write FCertFile;
    property KeyFile: string read FKeyFile write FKeyFile;
    property KeyPassword: string read FKeyPassword write FKeyPassword;
    property OnRequest: TMcpTlsRequestEvent read FOnRequest write FOnRequest;
    property IsRunning: Boolean read GetIsRunning;
    { Raises EUDAWError if the certificate/key are missing or unreadable, or
      the port cannot be bound. }
    procedure Start;
    procedure Stop;
  end;

implementation

{$IFNDEF FPC}
uses
  IdHTTPServer, IdCustomHTTPServer, IdContext, IdSocketHandle, IdGlobal,
  TaurusTLS, UDAW.Errors, UDAW.AI.SecureLog;

const
  SUBSYS = 'AI.MCPTls';

type
  TMcpTlsImpl = class
  private
    FOwner: TMcpTlsListener;
    FServer: TIdHTTPServer;
    FIO: TTaurusTLSServerIOHandler;
    procedure DoGet(AContext: TIdContext; ARequestInfo: TIdHTTPRequestInfo;
      AResponseInfo: TIdHTTPResponseInfo);
    procedure DoParseAuth(AContext: TIdContext; const AAuthType, AAuthData: string;
      var VUsername, VPassword: string; var VHandled: Boolean);
    procedure DoQuerySSLPort(APort: TIdPort; var VUseSSL: Boolean);
    procedure DoPassword(ASender: TObject; var VPassword: string;
      const AIsWrite: Boolean; var VOk: Boolean);
  public
    constructor Create(AOwner: TMcpTlsListener);
    destructor Destroy; override;
  end;

constructor TMcpTlsImpl.Create(AOwner: TMcpTlsListener);
var
  b: TIdSocketHandle;
begin
  inherited Create;
  FOwner := AOwner;
  FIO := TTaurusTLSServerIOHandler.Create(nil);
  FIO.SSLOptions.MinTLSVersion := TLSv1_2;
  FIO.SSLOptions.Mode := sslmServer;
  FIO.DefaultCert.PublicKey := AOwner.CertFile;
  FIO.DefaultCert.PrivateKey := AOwner.KeyFile;
  FIO.OnGetPassword := DoPassword;

  FServer := TIdHTTPServer.Create(nil);
  FServer.IOHandler := FIO;
  FServer.Bindings.Clear;
  b := FServer.Bindings.Add;
  b.IP := AOwner.BindAddress;
  b.Port := AOwner.Port;
  FServer.OnQuerySSLPort := DoQuerySSLPort;
  FServer.OnParseAuthentication := DoParseAuth;
  FServer.OnCommandGet := DoGet;
  FServer.OnCommandOther := DoGet;
end;

destructor TMcpTlsImpl.Destroy;
begin
  if FServer <> nil then
  begin
    FServer.Active := False;
    FServer.IOHandler := nil;
  end;
  FServer.Free;
  FIO.Free;
  inherited Destroy;
end;

procedure TMcpTlsImpl.DoParseAuth(AContext: TIdContext; const AAuthType, AAuthData: string;
  var VUsername, VPassword: string; var VHandled: Boolean);
begin
  { Indy answers any Authorization scheme it does not know (Bearer) with its own
    401 before our handler runs. Claim it; the MCP layer validates the token. }
  VHandled := True;
end;

procedure TMcpTlsImpl.DoQuerySSLPort(APort: TIdPort; var VUseSSL: Boolean);
begin
  { Indy only switches a connection to TLS on port 443 unless told otherwise;
    every connection to this listener is TLS. }
  VUseSSL := True;
end;

procedure TMcpTlsImpl.DoPassword(ASender: TObject; var VPassword: string;
  const AIsWrite: Boolean; var VOk: Boolean);
begin
  VPassword := FOwner.KeyPassword;
  VOk := True;
end;

procedure TMcpTlsImpl.DoGet(AContext: TIdContext; ARequestInfo: TIdHTTPRequestInfo;
  AResponseInfo: TIdHTTPResponseInfo);
var
  body, resp: string;
  status: Integer;
  ms: TStringStream;
begin
  body := '';
  if ARequestInfo.PostStream <> nil then
  begin
    ms := TStringStream.Create('', TEncoding.UTF8);
    try
      ARequestInfo.PostStream.Position := 0;
      ms.CopyFrom(ARequestInfo.PostStream, 0);
      body := ms.DataString;
    finally
      ms.Free;
    end;
  end;
  status := 500;
  resp := '';
  try
    if Assigned(FOwner.OnRequest) then
      resp := FOwner.OnRequest(ARequestInfo.Command,
        ARequestInfo.RawHeaders.Values['Authorization'],
        ARequestInfo.RawHeaders.Values['Origin'], body, status);
  except
    on E: Exception do
    begin
      status := 500;
      resp := '{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"internal error"}}';
    end;
  end;
  AResponseInfo.ResponseNo := status;
  if status = 401 then
    AResponseInfo.CustomHeaders.Values['WWW-Authenticate'] := 'Bearer';
  if status = 405 then
    AResponseInfo.CustomHeaders.Values['Allow'] := 'POST';
  if resp <> '' then
  begin
    AResponseInfo.ContentType := 'application/json';
    AResponseInfo.CharSet := 'utf-8';
    AResponseInfo.ContentText := resp;
  end
  else
  begin
    AResponseInfo.ContentText := '';
    AResponseInfo.ContentLength := 0;
  end;
end;

{ ---------------- TMcpTlsListener ---------------- }

constructor TMcpTlsListener.Create;
begin
  inherited Create;
  FPort := 8766;
  FBindAddress := '0.0.0.0';
end;

destructor TMcpTlsListener.Destroy;
begin
  Stop;
  inherited Destroy;
end;

function TMcpTlsListener.GetIsRunning: Boolean;
begin
  Result := (FImpl <> nil) and TMcpTlsImpl(FImpl).FServer.Active;
end;

procedure TMcpTlsListener.Start;
begin
  if GetIsRunning then Exit;
  if not FileExists(FCertFile) then
    RaiseUDAWFmt(errInvalidArgument, SUBSYS, 'TLS certificate file not found: "%s"', [FCertFile]);
  if not FileExists(FKeyFile) then
    RaiseUDAWFmt(errInvalidArgument, SUBSYS, 'TLS private key file not found: "%s"', [FKeyFile]);
  FreeAndNil(FImpl);
  FImpl := TMcpTlsImpl.Create(Self);
  try
    TMcpTlsImpl(FImpl).FServer.Active := True;
  except
    on E: Exception do
    begin
      FreeAndNil(FImpl);
      RaiseUDAWFmt(errNetwork, SUBSYS, 'HTTPS listener failed to start on %s:%d - %s',
        [FBindAddress, FPort, E.Message]);
    end;
  end;
  AISecureLog.Info(SUBSYS, Format('MCP HTTPS listener on %s:%d', [FBindAddress, FPort]));
end;

procedure TMcpTlsListener.Stop;
begin
  if FImpl <> nil then
  begin
    FreeAndNil(FImpl);
    AISecureLog.Info(SUBSYS, 'MCP HTTPS listener stopped');
  end;
end;

{$ELSE}

uses
  UDAW.Errors;

constructor TMcpTlsListener.Create;
begin
  inherited Create;
end;

destructor TMcpTlsListener.Destroy;
begin
  inherited Destroy;
end;

function TMcpTlsListener.GetIsRunning: Boolean;
begin
  Result := False;
end;

procedure TMcpTlsListener.Start;
begin
  RaiseUDAW(errNotImplemented, 'AI.MCPTls', 'the HTTPS listener is only implemented on Delphi today');
end;

procedure TMcpTlsListener.Stop;
begin
end;

{$ENDIF}

end.
