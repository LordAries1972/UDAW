unit UDAW.Threading;
{$I udaw.inc}

{ Threading primitives shared by every UDAW subsystem:
    - portable 32-bit atomics and a full memory barrier
    - TUDAWLock       : named recursive mutex (thin TCriticalSection wrapper)
    - TUDAWSignal     : manual/auto reset event with millisecond wait
    - TSPSCByteBuffer : wait-free single-producer / single-consumer ring buffer,
                        the basis for the real-time-safe diagnostic queue. }

interface

uses
  SysUtils, Classes, SyncObjs;

{ ---- atomics ---------------------------------------------------------------- }

function AtomicInc32(var Target: Integer): Integer;
function AtomicDec32(var Target: Integer): Integer;
function AtomicRead32(var Target: Integer): Integer;
function AtomicSet32(var Target: Integer; Value: Integer): Integer;   // returns previous
function AtomicCAS32(var Target: Integer; NewValue, Comparand: Integer): Boolean;
procedure FullBarrier;

{ ---- lock ---------------------------------------------------------------- }

type
  TUDAWLock = class
  private
    FCS: TCriticalSection;
    FName: string;
  public
    constructor Create(const AName: string = '');
    destructor Destroy; override;
    procedure Enter;
    procedure Leave;
    function TryEnter: Boolean;
    property Name: string read FName;
  end;

  { RAII helper: Lock := TUDAWScopeLock.Create(FLock); }
  TUDAWScopeLock = class(TInterfacedObject)
  private
    FLock: TUDAWLock;
  public
    constructor Create(ALock: TUDAWLock);
    destructor Destroy; override;
  end;

{ ---- signal ---------------------------------------------------------------- }

  TUDAWSignal = class
  private
    FEvent: TEvent;
  public
    constructor Create(AManualReset: Boolean = False; AInitiallySet: Boolean = False);
    destructor Destroy; override;
    procedure Signal;
    procedure Reset;
    { Returns True if signalled, False on timeout. INFINITE = $FFFFFFFF. }
    function Wait(ATimeoutMs: Cardinal): Boolean;
  end;

{ ---- SPSC ring buffer ---------------------------------------------------------------- }

  { Wait-free for exactly one producer thread and one consumer thread.
    Capacity is rounded up to the next power of two (min 2). }
  TSPSCByteBuffer = class
  private
    FData: TBytes;
    FMask: Cardinal;
    FCapacity: Cardinal;
    FHead: Integer;   // producer write counter (free running)
    FTail: Integer;   // consumer read counter  (free running)
  public
    constructor Create(ACapacityBytes: Cardinal);
    { Producer side. Returns the number of bytes actually written (0..ACount). }
    function Write(const ABuffer; ACount: Cardinal): Cardinal;
    function WriteString(const S: RawByteString): Boolean;   // all-or-nothing
    { Consumer side. Returns the number of bytes actually read (0..ACount). }
    function Read(var ABuffer; ACount: Cardinal): Cardinal;
    function BytesAvailable: Cardinal;
    function BytesFree: Cardinal;
    property Capacity: Cardinal read FCapacity;
  end;

implementation

uses
  UDAW.Errors;

{ ---- atomics ---------------------------------------------------------------- }

function AtomicInc32(var Target: Integer): Integer;
begin
  {$IFDEF FPC}
  Result := InterLockedIncrement(Target);
  {$ELSE}
  Result := AtomicIncrement(Target);
  {$ENDIF}
end;

function AtomicDec32(var Target: Integer): Integer;
begin
  {$IFDEF FPC}
  Result := InterLockedDecrement(Target);
  {$ELSE}
  Result := AtomicDecrement(Target);
  {$ENDIF}
end;

function AtomicRead32(var Target: Integer): Integer;
begin
  {$IFDEF FPC}
  Result := InterLockedCompareExchange(Target, 0, 0);
  {$ELSE}
  Result := AtomicCmpExchange(Target, 0, 0);
  {$ENDIF}
end;

function AtomicSet32(var Target: Integer; Value: Integer): Integer;
begin
  {$IFDEF FPC}
  Result := InterLockedExchange(Target, Value);
  {$ELSE}
  Result := AtomicExchange(Target, Value);
  {$ENDIF}
end;

function AtomicCAS32(var Target: Integer; NewValue, Comparand: Integer): Boolean;
begin
  {$IFDEF FPC}
  Result := InterLockedCompareExchange(Target, NewValue, Comparand) = Comparand;
  {$ELSE}
  Result := AtomicCmpExchange(Target, NewValue, Comparand) = Comparand;
  {$ENDIF}
end;

var
  GBarrierSlot: Integer = 0;

procedure FullBarrier;
begin
  { A full interlocked CAS is a full memory fence on every CPU UDAW targets
    (LOCK-prefixed on x86/x64, DMB ISH on AArch64). This avoids depending on a
    platform-specific barrier intrinsic. }
  AtomicCAS32(GBarrierSlot, 0, 0);
end;

{ ---- TUDAWLock ---------------------------------------------------------------- }

constructor TUDAWLock.Create(const AName: string);
begin
  inherited Create;
  FName := AName;
  FCS := TCriticalSection.Create;
end;

destructor TUDAWLock.Destroy;
begin
  FCS.Free;
  inherited Destroy;
end;

procedure TUDAWLock.Enter;
begin
  FCS.Enter;
end;

procedure TUDAWLock.Leave;
begin
  FCS.Leave;
end;

function TUDAWLock.TryEnter: Boolean;
begin
  Result := FCS.TryEnter;
end;

{ ---- TUDAWScopeLock ---------------------------------------------------------------- }

constructor TUDAWScopeLock.Create(ALock: TUDAWLock);
begin
  inherited Create;
  FLock := ALock;
  FLock.Enter;
end;

destructor TUDAWScopeLock.Destroy;
begin
  FLock.Leave;
  inherited Destroy;
end;

{ ---- TUDAWSignal ---------------------------------------------------------------- }

constructor TUDAWSignal.Create(AManualReset: Boolean; AInitiallySet: Boolean);
begin
  inherited Create;
  FEvent := TEvent.Create(nil, AManualReset, AInitiallySet, '');
end;

destructor TUDAWSignal.Destroy;
begin
  FEvent.Free;
  inherited Destroy;
end;

procedure TUDAWSignal.Signal;
begin
  FEvent.SetEvent;
end;

procedure TUDAWSignal.Reset;
begin
  FEvent.ResetEvent;
end;

function TUDAWSignal.Wait(ATimeoutMs: Cardinal): Boolean;
begin
  Result := FEvent.WaitFor(ATimeoutMs) = wrSignaled;
end;

{ ---- TSPSCByteBuffer ---------------------------------------------------------------- }

function NextPow2(V: Cardinal): Cardinal;
begin
  Result := 2;
  while Result < V do
    Result := Result shl 1;
end;

constructor TSPSCByteBuffer.Create(ACapacityBytes: Cardinal);
begin
  inherited Create;
  if ACapacityBytes < 2 then
    ACapacityBytes := 2;
  FCapacity := NextPow2(ACapacityBytes);
  FMask := FCapacity - 1;
  SetLength(FData, FCapacity);
  FHead := 0;
  FTail := 0;
end;

function TSPSCByteBuffer.BytesAvailable: Cardinal;
begin
  Result := Cardinal(AtomicRead32(FHead) - AtomicRead32(FTail));
end;

function TSPSCByteBuffer.BytesFree: Cardinal;
begin
  { one slot kept free is unnecessary here because head/tail are free-running
    counters, not wrapped indices; full == Capacity. }
  Result := FCapacity - BytesAvailable;
end;

function TSPSCByteBuffer.Write(const ABuffer; ACount: Cardinal): Cardinal;
var
  src: PByte;
  head, idx, i: Cardinal;
  free: Cardinal;
begin
  free := BytesFree;
  if ACount > free then
    ACount := free;
  if ACount = 0 then
    Exit(0);
  src := @ABuffer;
  head := Cardinal(AtomicRead32(FHead));
  for i := 0 to ACount - 1 do
  begin
    idx := (head + i) and FMask;
    FData[idx] := src[i];
  end;
  FullBarrier;
  AtomicSet32(FHead, Integer(head + ACount));
  Result := ACount;
end;

function TSPSCByteBuffer.WriteString(const S: RawByteString): Boolean;
begin
  if Length(S) = 0 then
    Exit(True);
  if Cardinal(Length(S)) > BytesFree then
    Exit(False);
  Result := Write(S[1], Cardinal(Length(S))) = Cardinal(Length(S));
end;

function TSPSCByteBuffer.Read(var ABuffer; ACount: Cardinal): Cardinal;
var
  dst: PByte;
  tail, idx, i: Cardinal;
  avail: Cardinal;
begin
  avail := BytesAvailable;
  if ACount > avail then
    ACount := avail;
  if ACount = 0 then
    Exit(0);
  dst := @ABuffer;
  tail := Cardinal(AtomicRead32(FTail));
  for i := 0 to ACount - 1 do
  begin
    idx := (tail + i) and FMask;
    dst[i] := FData[idx];
  end;
  FullBarrier;
  AtomicSet32(FTail, Integer(tail + ACount));
  Result := ACount;
end;

end.
