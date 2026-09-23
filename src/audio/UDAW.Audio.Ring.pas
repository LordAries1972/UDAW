unit UDAW.Audio.Ring;
{$I udaw.inc}

{ Phase 2 - TAudioRing: a wait-free single-producer / single-consumer ring of
  interleaved Float32 frames. It bridges the real-time audio callback and a
  non-real-time thread (disk streaming, recording writer, offline consumer)
  without locks or allocation on either side.

  Same discipline as UDAW.Threading.TSPSCByteBuffer: power-of-two capacity,
  free-running head/tail counters, a full barrier between the payload writes and
  the index publication. Counts are in FRAMES; each frame is Channels samples.
  Loop counters are plain Integers and every counter difference is taken in
  Int64 then clamped, so range/overflow checking never trips. }

interface

uses
  SysUtils,
  UDAW.Errors, UDAW.Threading, UDAW.Audio.Types;

type
  TAudioRing = class
  private
    FData: TAudioSampleArray;   // FCapacityFrames * FChannels samples
    FChannels: Integer;
    FCapacityFrames: Integer;   // power of two
    FMask: Integer;
    FHead: Integer;             // producer frame counter (free running)
    FTail: Integer;             // consumer frame counter (free running)
    FOverruns: Integer;         // producer could not fit all frames (atomic)
    FUnderruns: Integer;        // consumer asked for more than available (atomic)
  public
    constructor Create(AChannels, ACapacityFrames: Integer);

    { Producer. Copies min(AFrames, FramesFree) interleaved frames from ASrc.
      Returns frames actually written. A short write bumps Overruns. }
    function WriteFrames(const ASrc; AFrames: Integer): Integer;
    { Consumer. Copies min(AFrames, FramesAvailable) frames into ADst and, when
      AZeroPad is set, fills the remainder of ADst with silence. Returns frames
      actually read; a short read bumps Underruns. }
    function ReadFrames(var ADst; AFrames: Integer; AZeroPad: Boolean = True): Integer;
    { Consumer. Advance past AFrames without copying (min with available). }
    function SkipFrames(AFrames: Integer): Integer;

    procedure Reset;   // call only while both sides are stopped

    function FramesAvailable: Integer;
    function FramesFree: Integer;
    function Overruns: Integer;
    function Underruns: Integer;
    procedure ResetCounters;

    property Channels: Integer read FChannels;
    property CapacityFrames: Integer read FCapacityFrames;
  end;

implementation

function NextPow2(V: Integer): Integer;
begin
  Result := 2;
  while Result < V do
    Result := Result shl 1;
end;

constructor TAudioRing.Create(AChannels, ACapacityFrames: Integer);
begin
  inherited Create;
  if AChannels < 1 then
    RaiseUDAW(errInvalidArgument, AUDIO_SUBSYS, 'TAudioRing: channels < 1');
  if ACapacityFrames < 2 then
    ACapacityFrames := 2;
  FChannels := AChannels;
  FCapacityFrames := NextPow2(ACapacityFrames);
  FMask := FCapacityFrames - 1;
  SetLength(FData, Int64(FCapacityFrames) * FChannels);
  FHead := 0;
  FTail := 0;
end;

function TAudioRing.FramesAvailable: Integer;
var
  diff: Int64;
begin
  diff := Int64(AtomicRead32(FHead)) - Int64(AtomicRead32(FTail));
  if diff < 0 then diff := 0
  else if diff > FCapacityFrames then diff := FCapacityFrames;
  Result := Integer(diff);
end;

function TAudioRing.FramesFree: Integer;
begin
  Result := FCapacityFrames - FramesAvailable;
  if Result < 0 then Result := 0;
end;

function TAudioRing.WriteFrames(const ASrc; AFrames: Integer): Integer;
var
  src: PAudioSample;
  head, slot, i, ch, freeFrames: Integer;
begin
  if AFrames <= 0 then Exit(0);
  freeFrames := FramesFree;
  if AFrames > freeFrames then
  begin
    AtomicInc32(FOverruns);
    AFrames := freeFrames;
  end;
  if AFrames <= 0 then Exit(0);

  src := PAudioSample(@ASrc);
  head := AtomicRead32(FHead);
  for i := 0 to AFrames - 1 do
  begin
    slot := ((head + i) and FMask) * FChannels;
    for ch := 0 to FChannels - 1 do
    begin
      FData[slot + ch] := src^;
      Inc(src);
    end;
  end;
  FullBarrier;
  AtomicSet32(FHead, head + AFrames);
  Result := AFrames;
end;

function TAudioRing.ReadFrames(var ADst; AFrames: Integer; AZeroPad: Boolean): Integer;
var
  dst: PAudioSample;
  tail, slot, i, ch, avail, got: Integer;
begin
  if AFrames <= 0 then Exit(0);
  dst := PAudioSample(@ADst);
  avail := FramesAvailable;
  got := AFrames;
  if got > avail then
  begin
    AtomicInc32(FUnderruns);
    got := avail;
  end;
  if got < 0 then got := 0;

  tail := AtomicRead32(FTail);
  for i := 0 to got - 1 do
  begin
    slot := ((tail + i) and FMask) * FChannels;
    for ch := 0 to FChannels - 1 do
    begin
      dst^ := FData[slot + ch];
      Inc(dst);
    end;
  end;
  if got > 0 then
  begin
    FullBarrier;
    AtomicSet32(FTail, tail + got);
  end;

  if AZeroPad and (got < AFrames) then
    FillChar(dst^, (AFrames - got) * FChannels * SizeOf(TAudioSample), 0);
  Result := got;
end;

function TAudioRing.SkipFrames(AFrames: Integer): Integer;
var
  avail, tail: Integer;
begin
  if AFrames <= 0 then Exit(0);
  avail := FramesAvailable;
  if AFrames > avail then AFrames := avail;
  if AFrames <= 0 then Exit(0);
  tail := AtomicRead32(FTail);
  FullBarrier;
  AtomicSet32(FTail, tail + AFrames);
  Result := AFrames;
end;

procedure TAudioRing.Reset;
begin
  AtomicSet32(FHead, 0);
  AtomicSet32(FTail, 0);
end;

function TAudioRing.Overruns: Integer;
begin
  Result := AtomicRead32(FOverruns);
end;

function TAudioRing.Underruns: Integer;
begin
  Result := AtomicRead32(FUnderruns);
end;

procedure TAudioRing.ResetCounters;
begin
  AtomicSet32(FOverruns, 0);
  AtomicSet32(FUnderruns, 0);
end;

end.
