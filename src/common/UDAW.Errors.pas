unit UDAW.Errors;
{$I udaw.inc}

{ Central error taxonomy and exception type for UDAW.
  Every subsystem raises EUDAWError with a stable TUDAWErrorCode so the
  diagnostics layer and tests can reason about failures without string matching. }

interface

uses
  SysUtils;

type
  TUDAWErrorCode = (
    errNone,
    errUnknown,
    errNotImplemented,
    errInvalidArgument,
    errInvalidState,
    errIO,
    errFileNotFound,
    errAccessDenied,
    errConfig,
    errPlatform,
    errSecureStorage,
    errCancelled,
    errTimeout,
    errJobFailed,
    errNetwork,
    errParse
  );

  EUDAWError = class(Exception)
  private
    FCode: TUDAWErrorCode;
    FSubsystem: string;
  public
    constructor CreateCode(ACode: TUDAWErrorCode; const ASubsystem, AMessage: string);
    constructor CreateCodeFmt(ACode: TUDAWErrorCode; const ASubsystem, AFormat: string;
      const AArgs: array of const);
    property Code: TUDAWErrorCode read FCode;
    property Subsystem: string read FSubsystem;
  end;

function ErrorCodeName(ACode: TUDAWErrorCode): string;

{ Raise helpers - keep call sites terse. }
procedure RaiseUDAW(ACode: TUDAWErrorCode; const ASubsystem, AMessage: string);
procedure RaiseUDAWFmt(ACode: TUDAWErrorCode; const ASubsystem, AFormat: string;
  const AArgs: array of const);

implementation

const
  CODE_NAMES: array[TUDAWErrorCode] of string = (
    'None', 'Unknown', 'NotImplemented', 'InvalidArgument', 'InvalidState',
    'IO', 'FileNotFound', 'AccessDenied', 'Config', 'Platform',
    'SecureStorage', 'Cancelled', 'Timeout', 'JobFailed', 'Network', 'Parse'
  );

function ErrorCodeName(ACode: TUDAWErrorCode): string;
begin
  Result := CODE_NAMES[ACode];
end;

constructor EUDAWError.CreateCode(ACode: TUDAWErrorCode; const ASubsystem, AMessage: string);
begin
  inherited Create(AMessage);
  FCode := ACode;
  FSubsystem := ASubsystem;
end;

constructor EUDAWError.CreateCodeFmt(ACode: TUDAWErrorCode; const ASubsystem, AFormat: string;
  const AArgs: array of const);
begin
  inherited Create(Format(AFormat, AArgs));
  FCode := ACode;
  FSubsystem := ASubsystem;
end;

procedure RaiseUDAW(ACode: TUDAWErrorCode; const ASubsystem, AMessage: string);
begin
  raise EUDAWError.CreateCode(ACode, ASubsystem, AMessage);
end;

procedure RaiseUDAWFmt(ACode: TUDAWErrorCode; const ASubsystem, AFormat: string;
  const AArgs: array of const);
begin
  raise EUDAWError.CreateCodeFmt(ACode, ASubsystem, AFormat, AArgs);
end;

end.
