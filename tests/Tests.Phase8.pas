unit Tests.Phase8;
{$IFDEF FPC}{$MODE DELPHI}{$MODESWITCH ADVANCEDRECORDS}{$H+}{$ENDIF}

{ Phase 8 acceptance tests: the recording architecture.

  Covers the disk-streaming recoverable take container (bounded RAM, torn-tail /
  torn-journal index rebuild, WAV finalisation), the capture engine
  (pre-roll, count-in, punch in/out, loop recording -> stacked takes, sample-
  accurate latency compensation, block-straddling, input monitoring, mono /
  stereo / multichannel), the dedicated writer thread draining a wait-free ring,
  takes + comping, crash recovery scanning, and committing a take to the
  timeline as one undoable command.

  Requires src/common, src/audio, src/audio/dsp, src/codecs/pcm, src/timeline,
  src/project and src/recording on the search path. }

interface

procedure RegisterPhase8Tests;

implementation

uses
  SysUtils, Classes, Math,
  UDAW.Testing,
  UDAW.Errors,
  UDAW.Paths,
  UDAW.Audio.Types,
  UDAW.Audio.Ring,
  UDAW.Codec.WAV,
  UDAW.Timeline.Model,
  UDAW.Project.Document, UDAW.Project.Commands,
  UDAW.Recording.Types,
  UDAW.Recording.ChunkFile,
  UDAW.Recording.Engine,
  UDAW.Recording.Writer,
  UDAW.Recording.Takes,
  UDAW.Recording.Recovery,
  UDAW.Recording.Commands;

const
  SR = 48000;

var
  GScratchCounter: Integer = 0;

function FreshDir(const AWhat: string): string;
begin
  Inc(GScratchCounter);
  Result := IncludeTrailingPathDelimiter(Paths.Temp) + 'phase8-tests' + PathDelim +
    Format('%s-%d', [AWhat, GScratchCounter]) + PathDelim;
  ForceDirectories(Result);
end;

function FileSize2(const AFileName: string): Int64;
var
  sr: TSearchRec;
begin
  if FindFirst(AFileName, faAnyFile, sr) = 0 then
  begin
    Result := sr.Size;
    FindClose(sr);
  end
  else
    Result := -1;
end;

function SlicePlanar(const ASrc: TAudioPlanar; AStart, ACount: Integer): TAudioPlanar;
var
  ch, i: Integer;
begin
  SetLength(Result, Length(ASrc));
  for ch := 0 to High(ASrc) do
  begin
    SetLength(Result[ch], ACount);
    for i := 0 to ACount - 1 do
      Result[ch][i] := ASrc[ch][AStart + i];
  end;
end;

{ deterministic per-channel ramp/tone, interleaved Float32 }
function MakeInterleaved(AChannels, AFrames: Integer): TAudioSampleArray;
var
  frame, ch, k: Integer;
begin
  SetLength(Result, Int64(AFrames) * AChannels);
  k := 0;
  for frame := 0 to AFrames - 1 do
    for ch := 0 to AChannels - 1 do
    begin
      Result[k] := Single(0.5 * Sin(2 * Pi * (100.0 + 50.0 * ch) * frame / SR));
      Inc(k);
    end;
end;

function MakePlanar(AChannels, AFrames: Integer): TAudioPlanar;
var
  ch, i: Integer;
begin
  SetLength(Result, AChannels);
  for ch := 0 to AChannels - 1 do
  begin
    SetLength(Result[ch], AFrames);
    for i := 0 to AFrames - 1 do
      Result[ch][i] := Single(0.5 * Sin(2 * Pi * (100.0 + 50.0 * ch) * i / SR));
  end;
end;

function MaxAbsDiffPlanar(const A, B: TAudioPlanar; AChannels, AFrames: Integer): Double;
var
  ch, i: Integer;
  d: Double;
begin
  Result := 0;
  for ch := 0 to AChannels - 1 do
    for i := 0 to AFrames - 1 do
    begin
      d := Abs(Double(A[ch][i]) - Double(B[ch][i]));
      if d > Result then Result := d;
    end;
end;

procedure TruncateFileBy(const AFileName: string; ABytes: Int64);
var
  fs: TFileStream;
begin
  fs := TFileStream.Create(AFileName, fmOpenReadWrite or fmShareExclusive);
  try
    if fs.Size > ABytes then
      fs.Size := fs.Size - ABytes
    else
      fs.Size := 0;
  finally
    fs.Free;
  end;
end;

{ ================= settings ================= }

procedure Test_Settings_Defaults_And_Validate;
var
  s: TRecordSettings;
begin
  s := TRecordSettings.Default;
  CheckEqualInt(48000, s.SampleRate, 'default sample rate');
  CheckEqualInt(2, s.Channels, 'default stereo');
  s.Validate;

  s.PunchMode := pmPunchInOut;
  s.PunchInSeconds := 2.0;
  s.PunchOutSeconds := 1.0;
  try
    s.Validate;
    Fail('punch-out before punch-in must be rejected');
  except
    on E: EUDAWError do
      CheckEqualInt(Ord(errInvalidArgument), Ord(E.Code), 'bad punch window -> errInvalidArgument');
  end;
end;

procedure Test_Settings_LeadIn_Sample_Math;
var
  s: TRecordSettings;
begin
  s := TRecordSettings.Default;
  s.TempoBPM := 120;
  s.CountInBeats := 2;                 // 2 beats @ 120 BPM = 1.0 s
  CheckEqualInt(SR, s.CountInSamples, 'count-in = 1 s of samples');
  s.PreRollSeconds := 0.25;
  CheckEqualInt(SR div 4, s.PreRollSamples, 'pre-roll = 0.25 s of samples');
  s.InputLatencyFrames := 100;
  s.OutputLatencyFrames := 380;
  CheckEqualInt(480, s.TotalLatencyFrames, 'round-trip latency frames');
end;

{ ================= chunk container ================= }

procedure Test_Chunk_RoundTrip_Planar;
const
  FR = 5000;
var
  dir: string;
  w: TRecordingChunkWriter;
  r: TRecordingChunkReader;
  src, back: TAudioPlanar;
begin
  dir := FreshDir('chunk-rt') + 'take';
  src := MakePlanar(2, FR);
  w := TRecordingChunkWriter.Create(dir, SR, 2, 'rt', 0.0);
  try
    w.WritePlanar(src, FR);
    w.Finalize;
    CheckEqualInt(FR, w.FramesWritten, 'frames written');
  finally
    w.Free;
  end;

  CheckFalse(FileExists(ChunkMarkerPath(dir)), 'clean finalize drops the in-progress marker');

  r := TRecordingChunkReader.Create(dir);
  try
    CheckEqualInt(FR, r.UsableFrames, 'reader recovers every frame');
    CheckEqualInt(Ord(tsFinalized), Ord(r.Status), 'status is finalized');
    back := r.ReadAllPlanar;
    CheckNear(0, MaxAbsDiffPlanar(src, back, 2, FR), 1e-9, 'samples are bit-exact (float32 store)');
  finally
    r.Free;
  end;
end;

procedure Test_Chunk_BoundedMemory_ManyFlushes;
const
  FR = REC_WRITER_FLUSH_FRAMES * 3 + 777;   // forces multiple auto-flushes
var
  dir: string;
  w: TRecordingChunkWriter;
  r: TRecordingChunkReader;
  blk: TAudioSampleArray;
  pushed, take: Integer;
begin
  dir := FreshDir('chunk-big') + 'take';
  blk := MakeInterleaved(1, 4096);
  w := TRecordingChunkWriter.Create(dir, SR, 1, 'big', 0.0);
  try
    pushed := 0;
    while pushed < FR do
    begin
      take := Min(4096, FR - pushed);
      w.WriteInterleaved(blk[0], take);
      Inc(pushed, take);
    end;
    w.Finalize;
  finally
    w.Free;
  end;

  r := TRecordingChunkReader.Create(dir);
  try
    CheckEqualInt(FR, r.UsableFrames, 'every frame survived across many flushes');
    CheckEqualInt(Int64(FR) * SizeOf(Single), Int64(FileSize2(ChunkAudioPath(dir))),
      'pcm file is exactly frames*bytesPerFrame - nothing buffered whole in RAM');
  finally
    r.Free;
  end;
end;

procedure Test_Chunk_Recover_TornTail;
const
  FR = 20000;
var
  dir: string;
  w: TRecordingChunkWriter;
  r: TRecordingChunkReader;
begin
  dir := FreshDir('chunk-torn') + 'take';
  w := TRecordingChunkWriter.Create(dir, SR, 2, 'torn', 0.0);
  try
    w.WritePlanar(MakePlanar(2, FR), FR);
    w.Flush;            // everything on disk + journalled
    { simulate a crash: writer object dies without Finalize }
  finally
    w.Free;
  end;

  Check(FileExists(ChunkMarkerPath(dir)), 'a crashed take keeps its in-progress marker');

  { now corrupt the tail of the raw audio: 10 bytes = 1.25 float frames }
  TruncateFileBy(ChunkAudioPath(dir), 10);

  r := TRecordingChunkReader.Create(dir);   // ctor rebuilds the index
  try
    Check(r.IsInProgress, 'reader still sees the container as in-progress');
    Check(r.UsableFrames <= FR, 'rebuilt frame count never exceeds what was written');
    Check(r.UsableFrames >= FR - 2, 'rebuilt frame count keeps all fully written frames');
    Check(Int64(r.UsableFrames) * 2 * SizeOf(Single) <= FileSize2(ChunkAudioPath(dir)),
      'usable frames fit inside the surviving pcm bytes');
  finally
    r.Free;
  end;
end;

procedure Test_Chunk_Recover_TornJournal;
const
  FR = 15000;
var
  dir: string;
  w: TRecordingChunkWriter;
  r: TRecordingChunkReader;
begin
  dir := FreshDir('chunk-tornidx') + 'take';
  w := TRecordingChunkWriter.Create(dir, SR, 1, 'tornidx', 0.0);
  try
    w.WritePlanar(MakePlanar(1, FR), FR);
    w.Flush;
  finally
    w.Free;
  end;

  { half-write the last journal record }
  TruncateFileBy(ChunkIndexPath(dir), 7);

  r := TRecordingChunkReader.Create(dir);
  try
    CheckEqualInt(FR, r.UsableFrames,
      'a torn journal record is ignored; pcm bytes still yield every frame');
  finally
    r.Free;
  end;
end;

procedure Test_Chunk_FinalizeToWav;
const
  FR = 8000;
var
  dir, wav: string;
  w: TRecordingChunkWriter;
  r: TRecordingChunkReader;
  src, back: TAudioPlanar;
  info: TWavInfo;
  ch2, sr2: Integer;
begin
  dir := FreshDir('chunk-wav') + 'take';
  wav := FreshDir('chunk-wav-out') + 'take.wav';
  src := MakePlanar(2, FR);
  w := TRecordingChunkWriter.Create(dir, SR, 2, 'wav', 0.0);
  try
    w.WritePlanar(src, FR);
    w.Finalize;
  finally
    w.Free;
  end;

  r := TRecordingChunkReader.Create(dir);
  try
    r.FinalizeToWav(wav, wsfPCM24);
  finally
    r.Free;
  end;

  Check(FileLooksLikeWav(wav), 'finalised take is a real WAV file');
  info := ReadWavInfo(wav);
  CheckEqualInt(FR, info.FrameCount, 'WAV frame count matches the take');
  CheckEqualInt(2, info.Channels, 'WAV channel count');
  CheckEqualInt(SR, info.SampleRate, 'WAV sample rate');
  back := LoadWavFile(wav, ch2, sr2);
  CheckNear(0, MaxAbsDiffPlanar(src, back, 2, FR), 1.0 / 4000000, 'PCM24 encode round-trips');
end;

{ ================= engine ================= }

function NewEngine(const AWhat: string; const ASettings: TRecordSettings): TRecordingEngine;
begin
  Result := TRecordingEngine.Create(FreshDir(AWhat));
  Result.Configure(ASettings);
end;

procedure Test_Engine_SimplePass;
const
  FR = SR;   // 1 second
var
  eng: TRecordingEngine;
  s: TRecordSettings;
  src, back: TAudioPlanar;
  tk: TRecordedTake;
  ch2, sr2: Integer;
begin
  s := TRecordSettings.Default;
  eng := NewEngine('eng-simple', s);
  try
    src := MakePlanar(2, FR);
    eng.Arm;
    eng.Start(0.0);
    eng.ProcessCapturePlanar(src, FR);
    eng.Stop;

    CheckEqualInt(1, eng.TakeCount, 'one take from one pass');
    tk := eng.LastTake;
    CheckEqualInt(FR, tk.FrameCount, 'take captured every frame (no lead-in)');
    CheckNear(0, tk.TimelineStartSeconds, 1e-9, 'take sits at the playhead');
    Check(FileExists(tk.WavFile), 'take was finalised to a WAV');
    back := LoadWavFile(tk.WavFile, ch2, sr2);
    CheckNear(0, MaxAbsDiffPlanar(src, back, 2, FR), 1e-6, 'recorded audio matches the input');
  finally
    eng.Free;
  end;
end;

procedure Test_Engine_PreRoll_NotRecorded;
var
  eng: TRecordingEngine;
  s: TRecordSettings;
begin
  s := TRecordSettings.Default;
  s.PreRollSeconds := 0.5;              // 24000 frames of lead-in
  eng := NewEngine('eng-preroll', s);
  try
    eng.Arm;
    eng.Start(0.0);
    eng.ProcessCapturePlanar(MakePlanar(2, SR), SR);   // feed 1 s
    eng.Stop;
    CheckEqualInt(SR - SR div 2, eng.LastTake.FrameCount,
      'pre-roll frames are rolled over, not written');
  finally
    eng.Free;
  end;
end;

procedure Test_Engine_CountIn_NotRecorded;
var
  eng: TRecordingEngine;
  s: TRecordSettings;
begin
  s := TRecordSettings.Default;
  s.TempoBPM := 120;
  s.CountInBeats := 2;                  // 1.0 s
  eng := NewEngine('eng-countin', s);
  try
    eng.Arm;
    eng.Start(0.0);
    eng.ProcessCapturePlanar(MakePlanar(2, 2 * SR), 2 * SR);   // 2 s
    eng.Stop;
    CheckEqualInt(SR, eng.LastTake.FrameCount, 'count-in delays the record gate by exactly its length');
  finally
    eng.Free;
  end;
end;

procedure Test_Engine_PunchInOut_Window;
var
  eng: TRecordingEngine;
  s: TRecordSettings;
  tk: TRecordedTake;
begin
  s := TRecordSettings.Default;
  s.PunchMode := pmPunchInOut;
  s.PunchInSeconds := 1.0;
  s.PunchOutSeconds := 2.0;
  eng := NewEngine('eng-punch', s);
  try
    eng.Arm;
    eng.Start(0.0);
    eng.ProcessCapturePlanar(MakePlanar(2, 3 * SR), 3 * SR);   // 3 s
    eng.Stop;
    CheckEqualInt(1, eng.TakeCount, 'punch produced one take');
    tk := eng.LastTake;
    CheckEqualInt(SR, tk.FrameCount, 'take covers exactly the 1 s punch window');
    CheckNear(1.0, tk.TimelineStartSeconds, 1e-6, 'take starts at the punch-in point');
  finally
    eng.Free;
  end;
end;

procedure Test_Engine_Punch_BlockStraddle;
var
  eng: TRecordingEngine;
  s: TRecordSettings;
  planar: TAudioPlanar;
  pushed, take: Integer;
begin
  s := TRecordSettings.Default;
  s.PunchMode := pmPunchInOut;
  s.PunchInSeconds := 0.5;
  s.PunchOutSeconds := 1.5;
  eng := NewEngine('eng-straddle', s);
  try
    eng.Arm;
    eng.Start(0.0);
    planar := MakePlanar(2, 2 * SR);
    { feed in ragged 777-frame blocks so both punch edges land mid-block }
    pushed := 0;
    while pushed < 2 * SR do
    begin
      take := Min(777, 2 * SR - pushed);
      { shift the planar window }
      eng.ProcessCapturePlanar(SlicePlanar(planar, pushed, take), take);
      Inc(pushed, take);
    end;
    eng.Stop;
    CheckEqualInt(SR, eng.LastTake.FrameCount,
      'punch window is sample-accurate even when edges fall mid-block');
  finally
    eng.Free;
  end;
end;

procedure Test_Engine_LatencyCompensation;
var
  eng: TRecordingEngine;
  s: TRecordSettings;
begin
  s := TRecordSettings.Default;
  s.PunchMode := pmPunchIn;
  s.PunchInSeconds := 1.0;
  s.InputLatencyFrames := 240;
  s.OutputLatencyFrames := 240;        // 480 total -> 10 ms @ 48k
  eng := NewEngine('eng-latency', s);
  try
    eng.Arm;
    eng.Start(0.0);
    eng.ProcessCapturePlanar(MakePlanar(2, 2 * SR), 2 * SR);
    eng.Stop;
    CheckNear(1.0 - 480.0 / SR, eng.LastTake.TimelineStartSeconds, 1e-6,
      'take is pulled earlier by the round-trip latency');
  finally
    eng.Free;
  end;
end;

procedure Test_Engine_LoopRecording_StacksTakes;
var
  eng: TRecordingEngine;
  s: TRecordSettings;
begin
  s := TRecordSettings.Default;
  s.LoopRecord := True;
  s.LoopStartSeconds := 0.0;
  s.LoopEndSeconds := 1.0;
  eng := NewEngine('eng-loop', s);
  try
    eng.Arm;
    eng.Start(0.0);
    eng.ProcessCapturePlanar(MakePlanar(2, Round(2.5 * SR)), Round(2.5 * SR));
    eng.Stop;
    CheckEqualInt(3, eng.TakeCount, 'two full loops + a partial third = 3 takes');
    CheckEqualInt(SR, eng.GetTake(0).FrameCount, 'pass 1 is a full loop');
    CheckEqualInt(SR, eng.GetTake(1).FrameCount, 'pass 2 is a full loop');
    CheckEqualInt(SR div 2, eng.GetTake(2).FrameCount, 'pass 3 is the half-loop tail');
    CheckEqualInt(0, eng.GetTake(0).PassIndex, 'pass index 0');
    CheckEqualInt(2, eng.GetTake(2).PassIndex, 'pass index 2');
    CheckNear(0, eng.GetTake(1).TimelineStartSeconds, 1e-6, 'every pass stacks at the loop start');
  finally
    eng.Free;
  end;
end;

procedure Test_Engine_Mono_And_Multichannel;
var
  eng: TRecordingEngine;
  s: TRecordSettings;
  tk: TRecordedTake;
  back: TAudioPlanar;
  ch2, sr2: Integer;
begin
  { mono }
  s := TRecordSettings.Default;
  s.ChannelMode := rcmMono;
  s.Channels := 1;
  eng := NewEngine('eng-mono', s);
  try
    eng.Arm; eng.Start(0.0);
    eng.ProcessCapturePlanar(MakePlanar(1, SR), SR);
    eng.Stop;
    tk := eng.LastTake;
    CheckEqualInt(1, tk.Channels, 'mono take has one channel');
    CheckEqualInt(SR, tk.FrameCount, 'mono frame count');
  finally
    eng.Free;
  end;

  { 4-channel }
  s := TRecordSettings.Default;
  s.ChannelMode := rcmMultichannel;
  s.Channels := 4;
  eng := NewEngine('eng-multi', s);
  try
    eng.Arm; eng.Start(0.0);
    eng.ProcessCapturePlanar(MakePlanar(4, 2000), 2000);
    eng.Stop;
    tk := eng.LastTake;
    CheckEqualInt(4, tk.Channels, '4-channel take');
    back := LoadWavFile(tk.WavFile, ch2, sr2);
    CheckEqualInt(4, ch2, 'finalised WAV keeps 4 channels');
    CheckNear(0, MaxAbsDiffPlanar(MakePlanar(4, 2000), back, 4, 2000), 1e-6,
      '4-channel audio round-trips through the take');
  finally
    eng.Free;
  end;
end;

procedure Test_Engine_InputMonitoring_Mix;
var
  eng: TRecordingEngine;
  s: TRecordSettings;
  cap, dst: TAudioSampleArray;
  i: Integer;
begin
  s := TRecordSettings.Default;
  s.InputMonitoring := True;
  s.MonitorGainDb := 0;
  eng := NewEngine('eng-monitor', s);
  try
    SetLength(cap, 8 * 2);
    SetLength(dst, 8 * 2);
    for i := 0 to High(cap) do begin cap[i] := 0.25; dst[i] := 0; end;
    eng.ApplyMonitorMix(cap[0], 8, 2, dst[0], 2);
    for i := 0 to High(dst) do
      CheckNear(0.25, dst[i], 1e-6, 'unity monitor mix copies the input into the output bus');

    { -6 dB roughly halves it, and it SUMS into whatever is already there }
    s.MonitorGainDb := -6.0206;
    eng.Configure(s);
    for i := 0 to High(dst) do dst[i] := 0.1;
    eng.ApplyMonitorMix(cap[0], 8, 2, dst[0], 2);
    for i := 0 to High(dst) do
      CheckNear(0.1 + 0.125, dst[i], 1e-3, '-6 dB monitor sums a half-level copy');
  finally
    eng.Free;
  end;
end;

{ ================= writer thread ================= }

procedure Test_WriterThread_DrainsRing;
const
  TOTAL = SR + 137;           // ragged final block
  BLK = 512;
var
  eng: TRecordingEngine;
  s: TRecordSettings;
  ring: TAudioRing;
  wt: TRecordingWriterThread;
  block: TAudioSampleArray;
  pushed, n: Integer;
begin
  s := TRecordSettings.Default;
  eng := NewEngine('eng-thread', s);
  ring := TAudioRing.Create(2, 1 shl 14);
  try
    eng.Arm;
    eng.Start(0.0);
    wt := TRecordingWriterThread.Create(eng, ring);
    try
      block := MakeInterleaved(2, BLK);
      pushed := 0;
      while pushed < TOTAL do
      begin
        n := Min(BLK, TOTAL - pushed);
        while ring.FramesFree < n do
        begin
          wt.Nudge;
          Sleep(1);          // let the consumer make room before we push
        end;
        ring.WriteFrames(block[0], n);
        wt.Nudge;
        Inc(pushed, n);
      end;
      wt.Stop;
      CheckEqualInt(0, wt.RingOverruns, 'no ring overruns - the writer thread kept up');
      CheckEqualInt(0, wt.ErrorCount, 'no disk errors on the writer thread');
      CheckEqualInt(TOTAL, wt.FramesConsumed, 'writer thread consumed every frame from the ring');
      CheckEqualInt(TOTAL, eng.LastTake.FrameCount, 'Stop finalized every frame including the queued tail');
      CheckEqualInt(TOTAL, ReadWavInfo(eng.LastTake.WavFile).FrameCount, 'final WAV contains the full tail');
    finally
      wt.Free;
    end;
    eng.Stop;
    CheckEqualInt(TOTAL, eng.LastTake.FrameCount, 'the take holds everything that went through the ring');
  finally
    ring.Free;
    eng.Free;
  end;
end;

{ ================= takes / comping ================= }

function FakeTake(const AName, AWav: string; AStart, ALen: Double; APass: Integer): TRecordedTake;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Id := AName;
  Result.Name := AName;
  Result.WavFile := AWav;
  Result.SampleRate := SR;
  Result.Channels := 2;
  Result.FrameCount := Round(ALen * SR);
  Result.Status := tsFinalized;
  Result.TimelineStartSeconds := AStart;
  Result.SourceOffsetSeconds := 0;
  Result.PassIndex := APass;
  Result.StartedUTC := Now;
end;

procedure Test_Comp_Default_And_Split;
var
  lane: TTakeLane;
  comp: TTakeComp;
  specs: TRecordedClipSpecArray;
  s0, s1, s2: TCompSegment;
begin
  lane := TTakeLane.Create('vox');
  comp := nil;
  try
    lane.AddTake(FakeTake('t0', 'a.wav', 4.0, 2.0, 0));
    lane.AddTake(FakeTake('t1', 'b.wav', 4.0, 2.0, 1));
    comp := TTakeComp.Create(lane);

    CheckEqualInt(1, comp.SegmentCount, 'default comp is a single segment');
    CheckEqualInt(0, comp.ActiveTakeAt(5.0), 'default comp plays take 0');
    specs := comp.FlattenToClipSpecs;
    CheckEqualInt(1, Length(specs), 'default comp flattens to one clip');
    CheckNear(4.0, specs[0].TimelineStartSeconds, 1e-9, 'clip at lane start');
    CheckNear(2.0, specs[0].LengthSeconds, 1e-9, 'clip spans the lane');

    { punch take 1 into the middle second: [4.5 .. 5.5] }
    comp.SetActiveTake(4.5, 5.5, 1);
    CheckEqualInt(3, comp.SegmentCount, 'comp now has 3 segments (t0 / t1 / t0)');
    s0 := comp.GetSegment(0);
    s1 := comp.GetSegment(1);
    s2 := comp.GetSegment(2);
    CheckEqualInt(0, s0.TakeIndex, 'first segment is take 0');
    CheckEqualInt(1, s1.TakeIndex, 'middle segment is take 1');
    CheckEqualInt(0, s2.TakeIndex, 'last segment is take 0');
    CheckNear(1.0, s1.LengthSeconds, 1e-6, 'middle segment spans the 1 s punch window');
    CheckNear(0.5, s1.TakeReadOffsetSeconds, 1e-6, 'take 1 is read from 0.5 s in');
    CheckNear(0.5, s0.LengthSeconds, 1e-6, 'lead segment is the first half-second');
    CheckEqualInt(1, comp.ActiveTakeAt(5.0), 'take 1 active in the punched region');

    specs := comp.FlattenToClipSpecs;
    CheckEqualInt(3, Length(specs), 'comped performance flattens to 3 clips');
    CheckEqualStr('b.wav', specs[1].SourceWavFile, 'middle clip points at take 1''s wav');
  finally
    comp.Free;
    lane.Free;
  end;
end;

{ ================= recovery ================= }

procedure MakeCrashedTake(const ADir: string; AFrames: Integer);
var
  w: TRecordingChunkWriter;
begin
  w := TRecordingChunkWriter.Create(ADir, SR, 2, ExtractFileName(ADir), 0.0);
  try
    w.WritePlanar(MakePlanar(2, AFrames), AFrames);
    w.Flush;   // on disk, journalled, NOT finalised
  finally
    w.Free;    // dies without Finalize -> marker stays
  end;
end;

procedure Test_Recovery_ScanAndFinalize;
var
  root, outDir: string;
  rec: TRecordingRecovery;
  pending, recovered: TRecordedTakeArray;
  info: TWavInfo;
begin
  root := FreshDir('recov-root');
  MakeCrashedTake(root + 'sess-a', 6000);
  MakeCrashedTake(root + 'sess-b', 9000);
  { a cleanly finalised take must NOT be offered for recovery }
  with TRecordingChunkWriter.Create(root + 'sess-clean', SR, 2, 'clean', 0.0) do
  try
    WritePlanar(MakePlanar(2, 1000), 1000);
    Finalize;
  finally
    Free;
  end;

  rec := TRecordingRecovery.Create(root);
  try
    Check(rec.HasUnfinishedTakes, 'recovery detects the crashed takes');
    pending := rec.ScanUnfinished;
    CheckEqualInt(2, Length(pending), 'exactly the two crashed takes are pending (clean one excluded)');

    outDir := FreshDir('recov-out');
    recovered := rec.RecoverAll(outDir);
    CheckEqualInt(2, Length(recovered), 'both crashed takes were recovered');
    Check(FileExists(recovered[0].WavFile), 'recovered take 0 has a WAV');
    Check(FileExists(recovered[1].WavFile), 'recovered take 1 has a WAV');
    CheckEqualInt(Ord(tsRecovered), Ord(recovered[0].Status), 'status marked recovered');
    info := ReadWavInfo(recovered[0].WavFile);
    Check((info.FrameCount = 6000) or (info.FrameCount = 9000), 'recovered frame count is one of the crashed takes');

    rec.DiscardAllUnfinished;
    CheckFalse(rec.HasUnfinishedTakes, 'discard removes the crashed containers');
  finally
    rec.Free;
  end;
end;

{ ================= commit to timeline ================= }

procedure Test_Commit_Take_To_Timeline_Undo_Redo;
var
  doc: TProjectDocument;
  mgr: TCommandManager;
  eng: TRecordingEngine;
  s: TRecordSettings;
  specs: TRecordedClipSpecArray;
  cmd: TCommitTakeCommand;
  tk: TRecordedTake;
begin
  s := TRecordSettings.Default;
  eng := NewEngine('eng-commit', s);
  doc := TProjectDocument.CreateNew('rec');
  mgr := TCommandManager.Create;
  try
    eng.Arm;
    eng.Start(2.0);
    eng.ProcessCapturePlanar(MakePlanar(2, SR), SR);
    eng.Stop;
    tk := eng.LastTake;

    SetLength(specs, 1);
    specs[0].SourceWavFile := tk.WavFile;
    specs[0].SampleRate := tk.SampleRate;
    specs[0].Channels := tk.Channels;
    specs[0].SourceFrameCount := tk.FrameCount;
    specs[0].Name := tk.Name;
    specs[0].TimelineStartSeconds := tk.TimelineStartSeconds;
    specs[0].SourceOffsetSeconds := 0;
    specs[0].LengthSeconds := tk.LengthSeconds;

    cmd := TCommitTakeCommand.Create(doc, 0, specs, 'Vocals');
    Check(mgr.Perform(cmd), 'commit command executes');
    CheckEqualInt(1, doc.Timeline.TrackCount, 'a track was created for the take');
    CheckEqualInt(1, doc.Timeline.ClipCountTotal, 'the take landed as one clip');
    CheckEqualInt(1, doc.Timeline.SourceCount, 'the take wav is registered as a media source');

    mgr.Undo;
    CheckEqualInt(0, doc.Timeline.ClipCountTotal, 'undo removes the committed clip');
    CheckEqualInt(0, doc.Timeline.TrackCount, 'undo removes the track this command created');

    mgr.Redo;
    CheckEqualInt(1, doc.Timeline.ClipCountTotal, 'redo puts the clip back');
    CheckEqualInt(1, doc.Timeline.TrackCount, 'redo puts the track back');
  finally
    mgr.Free;
    doc.Free;
    eng.Free;
  end;
end;

procedure Test_FullLength_SelectedTrack;
const
  RATE = 8000;
  TOTAL = RATE * 65 + 137;
var
  eng: TRecordingEngine;
  settings: TRecordSettings;
  block: TAudioSampleArray;
  take: TRecordedTake;
  doc: TProjectDocument;
  mgr: TCommandManager;
  target: TTimelineTrack;
  specs: TRecordedClipSpecArray;
  cmd: TCommitTakeCommand;
  clip: TTimelineClip;
  pos, n: Integer;
begin
  settings := TRecordSettings.Default;
  settings.SampleRate := RATE;
  eng := NewEngine('full-length-selected', settings);
  doc := TProjectDocument.CreateNew('full recording');
  mgr := TCommandManager.Create;
  try
    target := doc.Timeline.AddTrack(tkAudio, 'Selected destination');
    eng.Arm;
    eng.Start(12.375);
    block := MakeInterleaved(2, 311);
    pos := 0;
    while pos < TOTAL do
    begin
      n := Min(311, TOTAL - pos);
      eng.ProcessCaptureBlock(block[0], n);
      Inc(pos, n);
    end;
    eng.Stop;
    take := eng.LastTake;
    CheckEqualInt(TOTAL, take.FrameCount, 'capture is not capped at 60 seconds');
    CheckEqualInt(TOTAL, ReadWavInfo(take.WavFile).FrameCount, 'saved WAV has every frame');
    SetLength(specs, 1);
    specs[0].SourceWavFile := take.WavFile;
    specs[0].Name := take.Name;
    specs[0].SampleRate := RATE;
    specs[0].Channels := 2;
    specs[0].SourceFrameCount := take.FrameCount;
    specs[0].TimelineStartSeconds := take.TimelineStartSeconds;
    specs[0].SourceOffsetSeconds := 0;
    specs[0].LengthSeconds := take.LengthSeconds;
    cmd := TCommitTakeCommand.Create(doc, target.Id, specs);
    Check(mgr.Perform(cmd), 'selected-track commit succeeds');
    CheckEqualInt(1, doc.Timeline.TrackCount, 'selected track reused');
    clip := target.GetClip(0);
    CheckNear(12.375, clip.StartSeconds, 1e-9, 'insertion point retained');
    CheckNear(TOTAL / RATE, clip.LengthSeconds, 1e-9, 'full take duration retained');
    mgr.Undo;
    CheckEqualInt(1, doc.Timeline.TrackCount, 'undo preserves existing track');
    CheckEqualInt(0, target.ClipCount, 'undo removes take');
    mgr.Redo;
    CheckEqualInt(1, target.ClipCount, 'redo restores full take');
    eng.ClearTakes;
    eng.Start(0);
    eng.ProcessCaptureBlock(block[0], 137);
    eng.Stop;
    CheckNear(0, eng.LastTake.TimelineStartSeconds, 0, 'unset insertion starts at zero');
    Check(take.SessionDir <> eng.LastTake.SessionDir, 'rapid takes have unique containers');
  finally
    mgr.Free;
    doc.Free;
    eng.Free;
  end;
end;

{ ---------------- registration ---------------- }

procedure RegisterPhase8Tests;
begin
  RegisterTest('recording.commit', 'full length on selected track and zero origin', @Test_FullLength_SelectedTrack);
  RegisterTest('recording.settings', 'defaults + validate',        @Test_Settings_Defaults_And_Validate);
  RegisterTest('recording.settings', 'lead-in sample math',        @Test_Settings_LeadIn_Sample_Math);

  RegisterTest('recording.chunk', 'planar round-trip',             @Test_Chunk_RoundTrip_Planar);
  RegisterTest('recording.chunk', 'bounded memory / many flushes', @Test_Chunk_BoundedMemory_ManyFlushes);
  RegisterTest('recording.chunk', 'recover torn audio tail',       @Test_Chunk_Recover_TornTail);
  RegisterTest('recording.chunk', 'recover torn journal record',   @Test_Chunk_Recover_TornJournal);
  RegisterTest('recording.chunk', 'finalize to WAV',               @Test_Chunk_FinalizeToWav);

  RegisterTest('recording.engine', 'simple pass',                  @Test_Engine_SimplePass);
  RegisterTest('recording.engine', 'pre-roll not recorded',        @Test_Engine_PreRoll_NotRecorded);
  RegisterTest('recording.engine', 'count-in not recorded',        @Test_Engine_CountIn_NotRecorded);
  RegisterTest('recording.engine', 'punch in/out window',          @Test_Engine_PunchInOut_Window);
  RegisterTest('recording.engine', 'punch edges mid-block',        @Test_Engine_Punch_BlockStraddle);
  RegisterTest('recording.engine', 'latency compensation',         @Test_Engine_LatencyCompensation);
  RegisterTest('recording.engine', 'loop recording stacks takes',  @Test_Engine_LoopRecording_StacksTakes);
  RegisterTest('recording.engine', 'mono + multichannel',          @Test_Engine_Mono_And_Multichannel);
  RegisterTest('recording.engine', 'input monitoring mix',         @Test_Engine_InputMonitoring_Mix);

  RegisterTest('recording.writer', 'writer thread drains ring',    @Test_WriterThread_DrainsRing);

  RegisterTest('recording.takes', 'comp default + split',          @Test_Comp_Default_And_Split);

  RegisterTest('recording.recovery', 'scan + finalize crashed takes', @Test_Recovery_ScanAndFinalize);

  RegisterTest('recording.commit', 'commit take -> timeline undo/redo', @Test_Commit_Take_To_Timeline_Undo_Redo);
end;

end.
