unit UDAW.Timeline.Waveform;
{$I udaw.inc}

{ Phase 7 - Timeline: the waveform system (plan section 8).

  Waveforms are NEVER fake image representations. On import the audio is decoded
  and reduced to a multiresolution peak cache:

    * per channel, per resolution level: min sample, max sample and RMS of every
      block of samples
    * level 0 blocks are TIMELINE_WAVE_BASE_BIN samples wide (64 by default -
      the plan's example), each higher level aggregates
      TIMELINE_WAVE_FACTOR (4) level-below blocks

  The cache is built by streaming the source (TWaveformBuilder.AddSamples, then
  Finish) so a multi-gigabyte file never has to be held in memory, and it is
  stored separately from the source media (SaveToStream / LoadFromStream, a
  small versioned binary format keyed by a source signature so a stale cache is
  rejected rather than shown against the wrong audio).

  Querying is display-oriented: GetColumns picks the finest level whose block is
  no wider than the requested samples-per-pixel and aggregates from there, so a
  zoomed-out overview is O(pixels) rather than O(samples). }

interface

uses
  UDAW.Media.Progress, SysUtils, Classes, Math,
  UDAW.Errors, UDAW.Audio.Types, UDAW.Codec.WAV,
  UDAW.Codec.MP3, UDAW.Codec.MP4, UDAW.Codec.FLAC, UDAW.Timeline.TrackerSource;

const
  WAVEFORM_SUBSYS = 'Timeline.Waveform';

  TIMELINE_WAVE_BASE_BIN = 64;    // level-0 samples per block (plan example)
  TIMELINE_WAVE_FACTOR   = 4;     // aggregation ratio between levels
  TIMELINE_WAVE_MAX_LEVELS = 12;

  WAVE_CACHE_MAGIC   = $57415643; // 'CVAW' little-endian -> "WAVC"
  WAVE_CACHE_VERSION = 1;

type
  { One reduced block: the exact min and max sample it spans and the RMS. }
  TWavePeak = packed record
    MinV: Single;
    MaxV: Single;
    Rms: Single;
  end;
  TWavePeakArray = array of TWavePeak;

  { Identifies the audio a cache was built from; a mismatch means "rebuild". }
  TWaveSourceSignature = packed record
    SampleRate: Integer;
    Channels: Integer;
    FrameCount: Int64;
    function Equals(const AOther: TWaveSourceSignature): Boolean;
  end;

  TWaveformCache = class
  private
    FChannels: Integer;
    FSampleRate: Integer;
    FBaseBin: Integer;
    FFactor: Integer;
    FFrameCount: Int64;
    { FLevels[level][channel] -> array of TWavePeak }
    FLevels: array of array of TWavePeakArray;
    function AggregateLevel(AChannel, ALevel: Integer;
      AFirstBin, ABinCount: Integer): TWavePeak;
  public
    constructor Create(AChannels, ASampleRate, ABaseBin, AFactor: Integer);
    destructor Destroy; override;

    property Channels: Integer read FChannels;
    property SampleRate: Integer read FSampleRate;
    property FrameCount: Int64 read FFrameCount;
    property BaseBin: Integer read FBaseBin;

    function LevelCount: Integer;
    function BinSamples(ALevel: Integer): Int64;
    function BinCount(ALevel: Integer): Integer;
    function Signature: TWaveSourceSignature;

    { Exact min/max/RMS over the raw sample range [AStartSample, AEndSample)
      of one channel, computed from level 0. Clamped to the available data. }
    function QueryRange(AChannel: Integer; AStartSample, AEndSample: Int64): TWavePeak;

    { Fill ACols[0..ACount-1] with one peak per display column, the first
      column starting at AStartSample and each spanning ASamplesPerColumn
      source samples. Columns past the end of the data are zeroed. }
    procedure GetColumns(AChannel: Integer; AStartSample: Int64;
      ASamplesPerColumn: Double; ACount: Integer; var ACols: TWavePeakArray);

    procedure SaveToStream(AStream: TStream);
    procedure SaveToFile(const AFileName: string);
    class function LoadFromStream(AStream: TStream): TWaveformCache;
    class function LoadFromFile(const AFileName: string): TWaveformCache;

    function Describe: string;
  end;

  { Streaming builder. Feed planar Float32 blocks in order, then call Finish. }
  TWaveformBuilder = class
  private
    type
      TRunning = record
        Count: Integer;
        MinV, MaxV: Double;
        SumSq: Double;
      end;
    var
    FCache: TWaveformCache;
    FRun: array of TRunning;      // one per channel, current level-0 block
    FL0: array of TWavePeakArray; // level 0 accumulating, one per channel - capacity, see FL0Count
    FL0Count: array of Integer;   // live length of FL0[ch] (<= Length(FL0[ch]))
    FFrames: Int64;
    FFinished: Boolean;
    procedure FlushBlock(AChannel: Integer);
  public
    constructor Create(AChannels, ASampleRate: Integer;
      ABaseBin: Integer = TIMELINE_WAVE_BASE_BIN;
      AFactor: Integer = TIMELINE_WAVE_FACTOR);
    destructor Destroy; override;
    procedure AddSamples(const ABlock: TAudioPlanar; AFrameCount: Integer);
    { Completes the pyramid and hands ownership of the cache to the caller.
      The builder must not be used afterwards. }
    function Finish: TWaveformCache;
  end;

{ AFraction is 0..1. Same cross-thread contract as TOfflineProgressEvent. }
type
  {$IFDEF FPC}
  TWaveformProgressEvent = procedure(AFraction: Double) of object;
  {$ELSE}
  TWaveformProgressEvent = reference to procedure(AFraction: Double);
  {$ENDIF}

{ One-shot: stream a WAV file into a fresh cache (no full-file buffering).
  AOnProgress, when given, is reported incrementally as the file streams in -
  WAV is the only source format this unit decodes a chunk at a time, so it is
  the only one that can report real incremental progress; see
  BuildWaveformCacheFromFile's comment for the MP3/MP4 case. }
function BuildWaveformCacheFromWav(const AFileName: string;
  ABaseBin: Integer = TIMELINE_WAVE_BASE_BIN;
  AFactor: Integer = TIMELINE_WAVE_FACTOR;
  AOnProgress: TWaveformProgressEvent = nil): TWaveformCache;

{ One-shot: reduce an in-memory planar buffer. }
function BuildWaveformCacheFromPlanar(const APlanar: TAudioPlanar;
  AChannels, AFrameCount, ASampleRate: Integer;
  ABaseBin: Integer = TIMELINE_WAVE_BASE_BIN;
  AFactor: Integer = TIMELINE_WAVE_FACTOR): TWaveformCache;

{ One-shot: sniff AFileName's REAL format (magic bytes, not the extension) and
  decode it through the matching codec - MP3 via Mp3DecodeFile, MP4/M4A via
  Mp4DecodeAudioFile (PCM-in-MP4 and MP3-in-MP4 both already work; AAC-in-MP4
  raises errNotImplemented from inside Mp4DecodeAudioFile, same as playback),
  falling back to the WAV path for everything else - before reducing to a
  cache via BuildWaveformCacheFromPlanar. This is what lets MP3/MP4 timeline
  clips get real waveform peaks instead of the flat placeholder line. Raises
  like BuildWaveformCacheFromWav does; TMediaSource.EnsureWaveform is the
  caller that turns a failure into "no cache" rather than a crash. }
function BuildWaveformCacheFromFile(const AFileName: string;
  ABaseBin: Integer = TIMELINE_WAVE_BASE_BIN;
  AFactor: Integer = TIMELINE_WAVE_FACTOR;
  AOnProgress: TWaveformProgressEvent = nil): TWaveformCache;

implementation

{ ================= signature ================= }

function TWaveSourceSignature.Equals(const AOther: TWaveSourceSignature): Boolean;
begin
  Result := (SampleRate = AOther.SampleRate) and (Channels = AOther.Channels) and
    (FrameCount = AOther.FrameCount);
end;

{ ================= TWaveformCache ================= }

constructor TWaveformCache.Create(AChannels, ASampleRate, ABaseBin, AFactor: Integer);
begin
  inherited Create;
  if AChannels <= 0 then
    RaiseUDAW(errInvalidArgument, WAVEFORM_SUBSYS, 'channel count must be > 0');
  if ASampleRate <= 0 then
    RaiseUDAW(errInvalidArgument, WAVEFORM_SUBSYS, 'sample rate must be > 0');
  if ABaseBin < 2 then ABaseBin := TIMELINE_WAVE_BASE_BIN;
  if AFactor < 2 then AFactor := TIMELINE_WAVE_FACTOR;
  FChannels := AChannels;
  FSampleRate := ASampleRate;
  FBaseBin := ABaseBin;
  FFactor := AFactor;
end;

destructor TWaveformCache.Destroy;
begin
  SetLength(FLevels, 0);
  inherited Destroy;
end;

function TWaveformCache.LevelCount: Integer;
begin
  Result := Length(FLevels);
end;

function TWaveformCache.BinSamples(ALevel: Integer): Int64;
var
  i: Integer;
begin
  Result := FBaseBin;
  for i := 1 to ALevel do
    Result := Result * FFactor;
end;

function TWaveformCache.BinCount(ALevel: Integer): Integer;
begin
  if (ALevel < 0) or (ALevel >= Length(FLevels)) then
    Exit(0);
  Result := Length(FLevels[ALevel][0]);
end;

function TWaveformCache.Signature: TWaveSourceSignature;
begin
  Result.SampleRate := FSampleRate;
  Result.Channels := FChannels;
  Result.FrameCount := FFrameCount;
end;

function TWaveformCache.AggregateLevel(AChannel, ALevel: Integer;
  AFirstBin, ABinCount: Integer): TWavePeak;
var
  i, n, last: Integer;
  bins: TWavePeakArray;
  sumSq: Double;
  cnt: Integer;
begin
  Result.MinV := 0;
  Result.MaxV := 0;
  Result.Rms := 0;
  if (ALevel < 0) or (ALevel >= Length(FLevels)) then Exit;
  bins := FLevels[ALevel][AChannel];
  n := Length(bins);
  if n = 0 then Exit;
  if AFirstBin < 0 then AFirstBin := 0;
  last := AFirstBin + ABinCount - 1;
  if last >= n then last := n - 1;
  if last < AFirstBin then Exit;

  Result.MinV := bins[AFirstBin].MinV;
  Result.MaxV := bins[AFirstBin].MaxV;
  sumSq := 0;
  cnt := 0;
  for i := AFirstBin to last do
  begin
    if bins[i].MinV < Result.MinV then Result.MinV := bins[i].MinV;
    if bins[i].MaxV > Result.MaxV then Result.MaxV := bins[i].MaxV;
    sumSq := sumSq + Double(bins[i].Rms) * Double(bins[i].Rms);
    Inc(cnt);
  end;
  if cnt > 0 then
    Result.Rms := Sqrt(sumSq / cnt);
end;

function TWaveformCache.QueryRange(AChannel: Integer;
  AStartSample, AEndSample: Int64): TWavePeak;
var
  bins: TWavePeakArray;
  firstBin, lastBin, i: Integer;
  sumSq: Double;
  cnt: Integer;
begin
  Result.MinV := 0; Result.MaxV := 0; Result.Rms := 0;
  if (AChannel < 0) or (AChannel >= FChannels) then Exit;
  if Length(FLevels) = 0 then Exit;
  if AStartSample < 0 then AStartSample := 0;
  if AEndSample > FFrameCount then AEndSample := FFrameCount;
  if AEndSample <= AStartSample then Exit;

  bins := FLevels[0][AChannel];
  if Length(bins) = 0 then Exit;
  firstBin := AStartSample div FBaseBin;
  lastBin := (AEndSample - 1) div FBaseBin;
  if lastBin >= Length(bins) then lastBin := High(bins);
  if firstBin > lastBin then Exit;

  Result.MinV := bins[firstBin].MinV;
  Result.MaxV := bins[firstBin].MaxV;
  sumSq := 0; cnt := 0;
  for i := firstBin to lastBin do
  begin
    if bins[i].MinV < Result.MinV then Result.MinV := bins[i].MinV;
    if bins[i].MaxV > Result.MaxV then Result.MaxV := bins[i].MaxV;
    sumSq := sumSq + Double(bins[i].Rms) * Double(bins[i].Rms);
    Inc(cnt);
  end;
  if cnt > 0 then
    Result.Rms := Sqrt(sumSq / cnt);
end;

procedure TWaveformCache.GetColumns(AChannel: Integer; AStartSample: Int64;
  ASamplesPerColumn: Double; ACount: Integer; var ACols: TWavePeakArray);
var
  level: Integer;
  binWidth: Int64;
  c: Integer;
  colStart, colEnd: Double;
  firstBin, lastBin: Int64;
  zero: TWavePeak;
begin
  zero.MinV := 0; zero.MaxV := 0; zero.Rms := 0;
  if ACount < 0 then ACount := 0;
  SetLength(ACols, ACount);
  if (AChannel < 0) or (AChannel >= FChannels) or (Length(FLevels) = 0) or (ACount = 0) then
  begin
    for c := 0 to ACount - 1 do ACols[c] := zero;
    Exit;
  end;
  if ASamplesPerColumn < 1 then ASamplesPerColumn := 1;

  { pick the finest level whose block is <= samples-per-column }
  level := 0;
  while (level + 1 < Length(FLevels)) and (BinSamples(level + 1) <= ASamplesPerColumn) do
    Inc(level);
  binWidth := BinSamples(level);

  for c := 0 to ACount - 1 do
  begin
    colStart := AStartSample + c * ASamplesPerColumn;
    colEnd := colStart + ASamplesPerColumn;
    if colStart >= FFrameCount then
    begin
      ACols[c] := zero;
      Continue;
    end;
    if colEnd > FFrameCount then colEnd := FFrameCount;
    if colStart < 0 then colStart := 0;
    firstBin := Trunc(colStart / binWidth);
    lastBin := Trunc((colEnd - 1) / binWidth);
    if lastBin < firstBin then lastBin := firstBin;
    ACols[c] := AggregateLevel(AChannel, level, Integer(firstBin),
      Integer(lastBin - firstBin + 1));
  end;
end;

procedure TWaveformCache.SaveToStream(AStream: TStream);
var
  magic, ver, i, ch, n, cnt: Integer;
  sig: TWaveSourceSignature;
begin
  magic := WAVE_CACHE_MAGIC;
  ver := WAVE_CACHE_VERSION;
  AStream.WriteBuffer(magic, 4);
  AStream.WriteBuffer(ver, 4);
  AStream.WriteBuffer(FChannels, 4);
  AStream.WriteBuffer(FSampleRate, 4);
  AStream.WriteBuffer(FBaseBin, 4);
  AStream.WriteBuffer(FFactor, 4);
  AStream.WriteBuffer(FFrameCount, 8);
  sig := Signature;  // reserved / self-check
  AStream.WriteBuffer(sig, SizeOf(sig));

  n := Length(FLevels);
  AStream.WriteBuffer(n, 4);
  for i := 0 to n - 1 do
    for ch := 0 to FChannels - 1 do
    begin
      cnt := Length(FLevels[i][ch]);
      AStream.WriteBuffer(cnt, 4);
      if cnt > 0 then
        AStream.WriteBuffer(FLevels[i][ch][0], cnt * SizeOf(TWavePeak));
    end;
end;

procedure TWaveformCache.SaveToFile(const AFileName: string);
var
  fs: TFileStream;
begin
  fs := TFileStream.Create(AFileName, fmCreate);
  try
    SaveToStream(fs);
  finally
    fs.Free;
  end;
end;

class function TWaveformCache.LoadFromStream(AStream: TStream): TWaveformCache;
var
  magic, ver, chans, sr, baseBin, factor, nLevels, i, ch, cnt: Integer;
  frameCount: Int64;
  sig: TWaveSourceSignature;
  cache: TWaveformCache;
begin
  AStream.ReadBuffer(magic, 4);
  if magic <> WAVE_CACHE_MAGIC then
    RaiseUDAW(errConfig, WAVEFORM_SUBSYS, 'not a UDAW waveform cache (bad magic)');
  AStream.ReadBuffer(ver, 4);
  if (ver <= 0) or (ver > WAVE_CACHE_VERSION) then
    RaiseUDAWFmt(errConfig, WAVEFORM_SUBSYS,
      'unsupported waveform cache version %d', [ver]);
  AStream.ReadBuffer(chans, 4);
  AStream.ReadBuffer(sr, 4);
  AStream.ReadBuffer(baseBin, 4);
  AStream.ReadBuffer(factor, 4);
  AStream.ReadBuffer(frameCount, 8);
  AStream.ReadBuffer(sig, SizeOf(sig));

  cache := TWaveformCache.Create(chans, sr, baseBin, factor);
  try
    cache.FFrameCount := frameCount;
    AStream.ReadBuffer(nLevels, 4);
    if (nLevels < 0) or (nLevels > TIMELINE_WAVE_MAX_LEVELS + 4) then
      RaiseUDAW(errConfig, WAVEFORM_SUBSYS, 'waveform cache: implausible level count');
    SetLength(cache.FLevels, nLevels);
    for i := 0 to nLevels - 1 do
    begin
      SetLength(cache.FLevels[i], chans);
      for ch := 0 to chans - 1 do
      begin
        AStream.ReadBuffer(cnt, 4);
        if (cnt < 0) or (cnt > 200 * 1000 * 1000) then
          RaiseUDAW(errConfig, WAVEFORM_SUBSYS, 'waveform cache: implausible bin count');
        SetLength(cache.FLevels[i][ch], cnt);
        if cnt > 0 then
          AStream.ReadBuffer(cache.FLevels[i][ch][0], cnt * SizeOf(TWavePeak));
      end;
    end;
  except
    cache.Free;
    raise;
  end;
  Result := cache;
end;

class function TWaveformCache.LoadFromFile(const AFileName: string): TWaveformCache;
var
  fs: TFileStream;
begin
  if not FileExists(AFileName) then
    RaiseUDAWFmt(errFileNotFound, WAVEFORM_SUBSYS, 'waveform cache not found: %s', [AFileName]);
  fs := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
  try
    Result := LoadFromStream(fs);
  finally
    fs.Free;
  end;
end;

function TWaveformCache.Describe: string;
var
  i: Integer;
begin
  Result := Format('waveform cache: %d ch, %d Hz, %d frames, base bin %d, %d levels',
    [FChannels, FSampleRate, FFrameCount, FBaseBin, Length(FLevels)]);
  for i := 0 to High(FLevels) do
    Result := Result + sLineBreak +
      Format('  level %d: %d samples/bin, %d bins',
        [i, BinSamples(i), Length(FLevels[i][0])]);
end;

{ ================= TWaveformBuilder ================= }

constructor TWaveformBuilder.Create(AChannels, ASampleRate, ABaseBin, AFactor: Integer);
var
  ch: Integer;
begin
  inherited Create;
  FCache := TWaveformCache.Create(AChannels, ASampleRate, ABaseBin, AFactor);
  SetLength(FRun, FCache.FChannels);
  SetLength(FL0, FCache.FChannels);
  SetLength(FL0Count, FCache.FChannels);
  for ch := 0 to FCache.FChannels - 1 do
  begin
    FRun[ch].Count := 0;
    FRun[ch].MinV := 0;
    FRun[ch].MaxV := 0;
    FRun[ch].SumSq := 0;
    FL0Count[ch] := 0;
  end;
end;

destructor TWaveformBuilder.Destroy;
begin
  FCache.Free;   // nil once Finish handed it away
  inherited Destroy;
end;

procedure TWaveformBuilder.FlushBlock(AChannel: Integer);
var
  n, idx, cap, newCap: Integer;
  pk: TWavePeak;
begin
  n := FRun[AChannel].Count;
  if n = 0 then Exit;
  pk.MinV := FRun[AChannel].MinV;
  pk.MaxV := FRun[AChannel].MaxV;
  pk.Rms := Sqrt(FRun[AChannel].SumSq / n);

  { Growing FL0[AChannel] by exactly one element per call (once per
    FBaseBin=64 source samples) used to SetLength the array to idx+1 every
    time - a real Delphi dynamic-array SetLength reallocates and copies the
    WHOLE array on every call rather than over-allocating, so that was
    O(total blocks) reallocations of an array averaging half that size: O(n^2)
    overall. For a several-minute real song (hundreds of thousands of
    64-sample blocks per channel) that is the difference between an
    imperceptible waveform build and the whole app appearing to hang for
    minutes - exactly what made adding a real .wav clip look frozen. Instead,
    grow capacity by doubling (amortized O(1) per append) and track the live
    count in FL0Count separately; Finish trims each array down to its real
    length before handing the cache to the caller. }
  idx := FL0Count[AChannel];
  cap := Length(FL0[AChannel]);
  if idx >= cap then
  begin
    if cap < 4 then newCap := 4 else newCap := cap * 2;
    SetLength(FL0[AChannel], newCap);
  end;
  FL0[AChannel][idx] := pk;
  FL0Count[AChannel] := idx + 1;

  FRun[AChannel].Count := 0;
  FRun[AChannel].MinV := 0;
  FRun[AChannel].MaxV := 0;
  FRun[AChannel].SumSq := 0;
end;

procedure TWaveformBuilder.AddSamples(const ABlock: TAudioPlanar; AFrameCount: Integer);
var
  ch, i: Integer;
  v: Double;
begin
  if FFinished then
    RaiseUDAW(errInvalidState, WAVEFORM_SUBSYS, 'AddSamples after Finish');
  if AFrameCount <= 0 then Exit;
  if Length(ABlock) < FCache.FChannels then
    RaiseUDAW(errInvalidArgument, WAVEFORM_SUBSYS, 'AddSamples: block has too few channels');

  for ch := 0 to FCache.FChannels - 1 do
  begin
    for i := 0 to AFrameCount - 1 do
    begin
      v := ABlock[ch][i];
      if FRun[ch].Count = 0 then
      begin
        FRun[ch].MinV := v;
        FRun[ch].MaxV := v;
      end
      else
      begin
        if v < FRun[ch].MinV then FRun[ch].MinV := v;
        if v > FRun[ch].MaxV then FRun[ch].MaxV := v;
      end;
      FRun[ch].SumSq := FRun[ch].SumSq + v * v;
      Inc(FRun[ch].Count);
      if FRun[ch].Count >= FCache.FBaseBin then
        FlushBlock(ch);
    end;
  end;
  FFrames := FFrames + AFrameCount;
end;

function TWaveformBuilder.Finish: TWaveformCache;
var
  ch, lvl, i, parentCount, childIdx, k: Integer;
  factor: Integer;
  prev, cur: TWavePeakArray;
  sumSq: Double;
  cnt: Integer;
  mn, mx: Single;
begin
  if FFinished then
    RaiseUDAW(errInvalidState, WAVEFORM_SUBSYS, 'Finish called twice');
  FFinished := True;

  for ch := 0 to FCache.FChannels - 1 do
    FlushBlock(ch);

  factor := FCache.FFactor;
  FCache.FFrameCount := FFrames;

  { level 0 - trim each channel's over-allocated capacity (see FlushBlock's
    comment) down to its real length before installing it. }
  SetLength(FCache.FLevels, 1);
  SetLength(FCache.FLevels[0], FCache.FChannels);
  for ch := 0 to FCache.FChannels - 1 do
  begin
    SetLength(FL0[ch], FL0Count[ch]);
    FCache.FLevels[0][ch] := FL0[ch];
  end;

  { higher levels, until a level would have <= 1 bin }
  lvl := 0;
  while (Length(FCache.FLevels[lvl][0]) > 1) and (lvl + 1 < TIMELINE_WAVE_MAX_LEVELS) do
  begin
    SetLength(FCache.FLevels, lvl + 2);
    SetLength(FCache.FLevels[lvl + 1], FCache.FChannels);
    for ch := 0 to FCache.FChannels - 1 do
    begin
      prev := FCache.FLevels[lvl][ch];
      parentCount := (Length(prev) + factor - 1) div factor;
      SetLength(cur, parentCount);
      for i := 0 to parentCount - 1 do
      begin
        childIdx := i * factor;
        mn := prev[childIdx].MinV;
        mx := prev[childIdx].MaxV;
        sumSq := 0;
        cnt := 0;
        for k := 0 to factor - 1 do
        begin
          if childIdx + k >= Length(prev) then Break;
          if prev[childIdx + k].MinV < mn then mn := prev[childIdx + k].MinV;
          if prev[childIdx + k].MaxV > mx then mx := prev[childIdx + k].MaxV;
          sumSq := sumSq + Double(prev[childIdx + k].Rms) * Double(prev[childIdx + k].Rms);
          Inc(cnt);
        end;
        cur[i].MinV := mn;
        cur[i].MaxV := mx;
        if cnt > 0 then cur[i].Rms := Sqrt(sumSq / cnt) else cur[i].Rms := 0;
      end;
      FCache.FLevels[lvl + 1][ch] := cur;
      cur := nil;
    end;
    Inc(lvl);
  end;

  Result := FCache;
  FCache := nil;
end;

{ ================= one-shot helpers ================= }

function BuildWaveformCacheFromWav(const AFileName: string;
  ABaseBin, AFactor: Integer; AOnProgress: TWaveformProgressEvent): TWaveformCache;
const
  CHUNK = 65536;
var
  reader: TWavReader;
  builder: TWaveformBuilder;
  block: TAudioPlanar;
  got, done, lastPct, pct: Integer;
  totalFrames: Int64;
begin
  reader := TWavReader.Create(AFileName);
  try
    builder := TWaveformBuilder.Create(reader.Info.Channels, reader.Info.SampleRate,
      ABaseBin, AFactor);
    try
      totalFrames := reader.Info.FrameCount;
      done := 0;
      lastPct := -1;
      if Assigned(AOnProgress) then AOnProgress(0);
      repeat
        got := reader.ReadFrames(block, CHUNK);
        if got > 0 then
        begin
          builder.AddSamples(block, got);
          Inc(done, got);
          if Assigned(AOnProgress) and (totalFrames > 0) then
          begin
            pct := Round(100 * (done / totalFrames));
            if pct <> lastPct then
            begin
              lastPct := pct;
              AOnProgress(done / totalFrames);
            end;
          end;
        end;
      until got = 0;
      Result := builder.Finish;
      if Assigned(AOnProgress) then AOnProgress(1);
    finally
      builder.Free;
    end;
  finally
    reader.Free;
  end;
end;

function BuildWaveformCacheFromPlanar(const APlanar: TAudioPlanar;
  AChannels, AFrameCount, ASampleRate: Integer;
  ABaseBin, AFactor: Integer): TWaveformCache;
var
  builder: TWaveformBuilder;
  chunk: TAudioPlanar;
  done, n, ch: Integer;
begin
  builder := TWaveformBuilder.Create(AChannels, ASampleRate, ABaseBin, AFactor);
  try
    EnsurePlanar(chunk, AChannels, 65536);
    done := 0;
    while done < AFrameCount do
    begin
      n := Min(65536, AFrameCount - done);
      for ch := 0 to AChannels - 1 do
        Move(APlanar[ch][done], chunk[ch][0], n * SizeOf(Single));
      builder.AddSamples(chunk, n);
      Inc(done, n);
      ReportMediaProgress('Building waveform', done, AFrameCount);
    end;
    Result := builder.Finish;
  finally
    builder.Free;
  end;
end;

function BuildWaveformCacheFromFile(const AFileName: string;
  ABaseBin, AFactor: Integer; AOnProgress: TWaveformProgressEvent): TWaveformCache;
var
  mp3Res: TMP3DecodeResult;
  mp4Res: TMP4DecodeResult;
  flacRes: TFLACDecodeResult;
  trkPcm: TAudioPlanar;
  trkFrames: Integer;
  trkBpm: Double;
begin
  { Codec loops report real decode progress through the scoped media reporter. }
  if Mp3SniffFile(AFileName) then
  begin
    if Assigned(AOnProgress) then AOnProgress(0);
    if not Mp3DecodeFile(AFileName, mp3Res) then
      RaiseUDAWFmt(errInvalidState, WAVEFORM_SUBSYS, 'MP3 decode failed: %s', [AFileName]);
    Result := BuildWaveformCacheFromPlanar(mp3Res.Pcm, mp3Res.Channels,
      Integer(mp3Res.Frames), mp3Res.SampleRate, ABaseBin, AFactor);
    if Assigned(AOnProgress) then AOnProgress(1);
    Exit;
  end;

  if Mp4SniffFile(AFileName) then
  begin
    if Assigned(AOnProgress) then AOnProgress(0);
    if not Mp4DecodeAudioFile(AFileName, mp4Res) then
      RaiseUDAWFmt(errInvalidState, WAVEFORM_SUBSYS, 'MP4 decode failed: %s', [AFileName]);
    Result := BuildWaveformCacheFromPlanar(mp4Res.Data, mp4Res.Channels,
      mp4Res.Frames, mp4Res.SampleRate, ABaseBin, AFactor);
    if Assigned(AOnProgress) then AOnProgress(1);
    Exit;
  end;

  if FlacSniffFile(AFileName) then
  begin
    if Assigned(AOnProgress) then AOnProgress(0);
    if not FlacDecodeFile(AFileName, flacRes) then
      RaiseUDAWFmt(errInvalidState, WAVEFORM_SUBSYS, 'FLAC decode failed: %s', [AFileName]);
    Result := BuildWaveformCacheFromPlanar(flacRes.Pcm, flacRes.Channels,
      Integer(flacRes.TotalFrames), flacRes.SampleRate, ABaseBin, AFactor);
    if Assigned(AOnProgress) then AOnProgress(1);
    Exit;
  end;

  if TrackerSniffFile(AFileName) then
  begin
    if Assigned(AOnProgress) then AOnProgress(0);
    if not TrackerRenderFile(AFileName, trkPcm, trkFrames, trkBpm) then
      RaiseUDAWFmt(errInvalidState, WAVEFORM_SUBSYS, 'Tracker module render failed: %s', [AFileName]);
    Result := BuildWaveformCacheFromPlanar(trkPcm, Length(trkPcm), trkFrames,
      TRACKER_SOURCE_RATE, ABaseBin, AFactor);
    if Assigned(AOnProgress) then AOnProgress(1);
    Exit;
  end;

  { neither MP3, MP4 nor FLAC magic - treat as WAV, same as before this
    dispatcher existed; TWavReader itself raises a precise error for
    anything else. }
  Result := BuildWaveformCacheFromWav(AFileName, ABaseBin, AFactor, AOnProgress);
end;

end.
