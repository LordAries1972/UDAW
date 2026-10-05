unit Tests.Phase7;
{$IFDEF FPC}{$MODE DELPHI}{$MODESWITCH ADVANCEDRECORDS}{$H+}{$ENDIF}
{$POINTERMATH ON}

{ Phase 7 acceptance tests: the timeline.

  Covers the time domain (seconds <-> samples <-> bars/beats, grid spacing,
  nearest / directional snap, formatting); the multiresolution waveform peak
  cache (exact min/max bounds, level pyramid, display-column aggregation,
  binary round-trip, streaming build from a real WAV); the non-destructive
  arrangement model (tracks, clips, split / trim / slip / move / duplicate,
  lock guard, markers, regions, deep Clone); the versioned text serializer
  (standalone round-trip, embedded-in-project round-trip, version / unknown-
  line rejection, forward compatibility with a timeline-less v1 project); the
  viewport (zoom clamp + anchored zoom, scroll clamp, snap delegation); and
  the undo/redo commands built on the Phase 5 command manager.

  Requires src/common, src/audio, src/audio/dsp, src/codecs/pcm, src/timeline
  and src/project on the search path. }

interface

procedure RegisterPhase7Tests;

implementation

uses
  SysUtils, Classes, Math,
  UDAW.Testing,
  UDAW.Errors,
  UDAW.Paths,
  UDAW.Audio.Types,
  UDAW.Audio.Buffer,
  UDAW.Codec.WAV,
  UDAW.Timeline.Time,
  UDAW.Timeline.Waveform,
  UDAW.Timeline.Model,
  UDAW.Timeline.Serialization,
  UDAW.Timeline.View,
  UDAW.Timeline.Commands,
  UDAW.Timeline.Playback,
  UDAW.Project.Document,
  UDAW.Project.Serialization,
  UDAW.Project.Commands;

function ScratchDir: string;
begin
  Result := IncludeTrailingPathDelimiter(Paths.Temp) + 'phase7-tests' + PathDelim;
  ForceDirectories(Result);
end;

procedure WipeFile(const AFileName: string);
begin
  if FileExists(AFileName) then
    DeleteFile(AFileName);
end;

function Ctx120: TGridContext;
begin
  Result := TGridContext.Make(120.0, 4, 4, 48000);
end;

{ ================= time domain ================= }

procedure Test_Time_SamplesRoundTrip;
begin
  CheckEqualInt(48000, SecondsToSamples(1.0, 48000), 'one second at 48k');
  CheckEqualInt(22050, SecondsToSamples(0.5, 44100), 'half a second at 44.1k');
  CheckNear(2.0, SamplesToSeconds(96000, 48000), 1e-12, 'samples back to seconds');
end;

procedure Test_Time_BeatsAndBars;
var
  c: TGridContext;
begin
  c := Ctx120;
  CheckNear(0.5, c.SecondsPerBeat, 1e-12, '120 BPM -> 0.5 s / beat');
  CheckNear(2.0, c.SecondsPerBar, 1e-12, '4/4 @ 120 -> 2 s / bar');
  CheckNear(4.0, SecondsToBeats(c, 2.0), 1e-12, '2 s is 4 beats');
  CheckNear(3.0, BeatsToSeconds(c, 6.0), 1e-12, '6 beats is 3 s');
  CheckNear(1.5, SecondsToBars(c, 3.0), 1e-12, '3 s is 1.5 bars');

  { 6/8 @ 120: a beat is an eighth note = 0.25 s, 6 per bar = 1.5 s }
  c := TGridContext.Make(120, 6, 8, 48000);
  CheckNear(0.25, c.SecondsPerBeat, 1e-12, '6/8 @ 120 -> 0.25 s / beat');
  CheckNear(1.5, c.SecondsPerBar, 1e-12, '6/8 @ 120 -> 1.5 s / bar');
end;

procedure Test_Time_GridSpacingAndSnap;
var
  c: TGridContext;
begin
  c := Ctx120;
  CheckNear(2.0, GridSpacingSeconds(c, smBar), 1e-12, 'bar spacing');
  CheckNear(0.5, GridSpacingSeconds(c, smBeat), 1e-12, 'beat spacing');
  CheckNear(0.125, GridSpacingSeconds(c, smDiv4), 1e-12, '1/4-beat spacing');
  CheckNear(1.0 / 48000, GridSpacingSeconds(c, smSample), 1e-15, 'sample spacing');

  CheckNear(0.5, SnapSeconds(c, 0.62, smBeat), 1e-12, 'nearest beat rounds down');
  CheckNear(1.0, SnapSeconds(c, 0.80, smBeat), 1e-12, 'nearest beat rounds up');
  CheckNear(0.0, SnapSeconds(c, 0.80, smBar), 1e-12, 'nearest bar');
  CheckNear(2.0, SnapSeconds(c, 1.20, smBar), 1e-12, 'nearest bar up');

  CheckNear(0.5, SnapSecondsDir(c, 0.99, smBeat, -1), 1e-12, 'floor snap');
  CheckNear(1.0, SnapSecondsDir(c, 0.51, smBeat, +1), 1e-12, 'ceil snap');
  CheckNear(0.62, SnapSeconds(c, 0.62, smOff), 1e-12, 'snap off is identity');
  CheckNear(0.0, SnapSeconds(c, -3.0, smBeat), 1e-12, 'snap never goes negative');
end;

procedure Test_Time_Formatting;
var
  c: TGridContext;
begin
  c := Ctx120;
  CheckEqualStr('1.1.000', FormatBarsBeats(c, 0.0), 'bar/beat at zero');
  CheckEqualStr('2.1.000', FormatBarsBeats(c, 2.0), 'bar/beat at one bar');
  CheckEqualStr('1.3.000', FormatBarsBeats(c, 1.0), 'bar/beat mid bar');
  CheckEqualStr('00:01.500', FormatTimecode(1.5), 'timecode sub-minute');
  CheckEqualStr('01:05.500', FormatTimecode(65.5), 'timecode over a minute');
  CheckEqualStr('1:00:00.000', FormatTimecode(3600.0), 'timecode over an hour');
end;

{ ================= waveform cache ================= }

function BruteMin(const A: TAudioSampleArray; AFrom, ATo: Integer): Single;
var i: Integer;
begin
  Result := A[AFrom];
  for i := AFrom + 1 to ATo - 1 do
    if A[i] < Result then Result := A[i];
end;

function BruteMax(const A: TAudioSampleArray; AFrom, ATo: Integer): Single;
var i: Integer;
begin
  Result := A[AFrom];
  for i := AFrom + 1 to ATo - 1 do
    if A[i] > Result then Result := A[i];
end;

procedure Test_Waveform_ExactBoundsAndPyramid;
const
  N = 1000;
var
  planar: TAudioPlanar;
  i: Integer;
  cache: TWaveformCache;
  pk: TWavePeak;
begin
  SetLength(planar, 1);
  SetLength(planar[0], N);
  for i := 0 to N - 1 do
    planar[0][i] := 0.9 * Sin(2 * Pi * 7.0 * i / N) + 0.05 * Sin(2 * Pi * 51.0 * i / N);

  cache := BuildWaveformCacheFromPlanar(planar, 1, N, 48000, 64, 4);
  try
    CheckEqualInt(1, cache.Channels, 'channel count');
    CheckEqualInt(N, cache.FrameCount, 'frame count');
    CheckEqualInt(64, cache.BinSamples(0), 'level 0 bin width');
    CheckEqualInt(256, cache.BinSamples(1), 'level 1 bin width');
    { 1000/64 -> 16 level-0 bins; -> 4 level-1; -> 1 level-2; stop }
    CheckEqualInt(3, cache.LevelCount, 'pyramid depth');
    CheckEqualInt(16, cache.BinCount(0), 'level 0 bin count');
    CheckEqualInt(4, cache.BinCount(1), 'level 1 bin count');

    pk := cache.QueryRange(0, 0, 64);
    CheckNear(BruteMin(planar[0], 0, 64), pk.MinV, 1e-6, 'first bin min is exact');
    CheckNear(BruteMax(planar[0], 0, 64), pk.MaxV, 1e-6, 'first bin max is exact');

    pk := cache.QueryRange(0, 0, N);
    CheckNear(BruteMin(planar[0], 0, N), pk.MinV, 1e-6, 'global min is exact');
    CheckNear(BruteMax(planar[0], 0, N), pk.MaxV, 1e-6, 'global max is exact');
  finally
    cache.Free;
  end;
end;

procedure Test_Waveform_RampAndColumns;
const
  N = 2048;
var
  planar: TAudioPlanar;
  i: Integer;
  cache: TWaveformCache;
  cols: TWavePeakArray;
begin
  SetLength(planar, 1);
  SetLength(planar[0], N);
  for i := 0 to N - 1 do
    planar[0][i] := (i / (N - 1)) * 2.0 - 1.0;      // -1 .. +1 ramp

  cache := BuildWaveformCacheFromPlanar(planar, 1, N, 48000, 64, 4);
  try
    cache.GetColumns(0, 0, 256, 8, cols);
    CheckEqualInt(8, Length(cols), 'column count');
    { first column spans samples 0..255 -> min about -1, rising }
    CheckNear(-1.0, cols[0].MinV, 1e-3, 'ramp starts at -1');
    Check(cols[7].MaxV > cols[0].MaxV, 'later column has a higher max than the first');
    CheckNear(1.0, cols[7].MaxV, 1e-3, 'ramp ends near +1');
    { a column past the end is zeroed }
    cache.GetColumns(0, N, 256, 3, cols);
    CheckNear(0.0, cols[0].MinV, 1e-12, 'past-EOF column is zero (min)');
    CheckNear(0.0, cols[0].MaxV, 1e-12, 'past-EOF column is zero (max)');
  finally
    cache.Free;
  end;
end;

procedure Test_Waveform_BinaryRoundTrip;
const
  N = 4096;
var
  planar: TAudioPlanar;
  i: Integer;
  cache, back: TWaveformCache;
  ms: TMemoryStream;
  a, b: TWavePeak;
begin
  SetLength(planar, 2);
  SetLength(planar[0], N);
  SetLength(planar[1], N);
  for i := 0 to N - 1 do
  begin
    planar[0][i] := 0.7 * Sin(2 * Pi * 3.0 * i / N);
    planar[1][i] := 0.4 * Sin(2 * Pi * 9.0 * i / N);
  end;

  cache := BuildWaveformCacheFromPlanar(planar, 2, N, 44100, 64, 4);
  ms := TMemoryStream.Create;
  try
    cache.SaveToStream(ms);
    ms.Position := 0;
    back := TWaveformCache.LoadFromStream(ms);
    try
      CheckEqualInt(cache.Channels, back.Channels, 'channels survive');
      CheckEqualInt(cache.FrameCount, back.FrameCount, 'frame count survives');
      CheckEqualInt(cache.LevelCount, back.LevelCount, 'level count survives');
      CheckEqualInt(cache.BinCount(0), back.BinCount(0), 'level 0 bin count survives');
      a := cache.QueryRange(1, 100, 900);
      b := back.QueryRange(1, 100, 900);
      CheckNear(a.MinV, b.MinV, 1e-9, 'peak data survives (min)');
      CheckNear(a.MaxV, b.MaxV, 1e-9, 'peak data survives (max)');
      CheckNear(a.Rms, b.Rms, 1e-9, 'peak data survives (rms)');
    finally
      back.Free;
    end;
  finally
    ms.Free;
    cache.Free;
  end;
end;

procedure Test_Waveform_StreamFromWav;
const
  SR = 48000;
  N  = 12000;
var
  fn: string;
  tone: TAudioPlanar;
  i: Integer;
  cache: TWaveformCache;
  pk: TWavePeak;
begin
  fn := ScratchDir + 'wave_src.wav';
  WipeFile(fn);
  SetLength(tone, 2);
  SetLength(tone[0], N);
  SetLength(tone[1], N);
  for i := 0 to N - 1 do
  begin
    tone[0][i] := 0.5 * Sin(2 * Pi * 220.0 * i / SR);
    tone[1][i] := 0.5 * Sin(2 * Pi * 330.0 * i / SR);
  end;
  try
    SaveWavFile(fn, tone, 2, SR, N, wsfFloat32);
    cache := BuildWaveformCacheFromWav(fn);
    try
      CheckEqualInt(2, cache.Channels, 'stereo cache from WAV');
      CheckEqualInt(N, cache.FrameCount, 'frame count matches the file');
      pk := cache.QueryRange(0, 0, N);
      CheckNear(0.5, pk.MaxV, 0.02, 'peak reflects the 0.5 amplitude tone');
      CheckNear(-0.5, pk.MinV, 0.02, 'trough reflects the 0.5 amplitude tone');
    finally
      cache.Free;
    end;
  finally
    WipeFile(fn);
  end;
end;

{ ================= model ================= }

function MakeTimelineWithClip(out ATrackId, AClipId, ASourceId: Integer): TTimeline;
var
  tl: TTimeline;
  src: TMediaSource;
  trk: TTimelineTrack;
  c: TTimelineClip;
begin
  tl := TTimeline.Create;
  src := tl.AddSource('C:\loops\a.wav', 48000, 2, 480000);   // 10 s of source
  trk := tl.AddTrack(tkAudio, 'Audio 1');
  c := tl.AddClip(trk.Id, src.Id, 'Clip A', 4.0, 1.0, 3.0);  // start 4, off 1, len 3
  ATrackId := trk.Id;
  AClipId := c.Id;
  ASourceId := src.Id;
  Result := tl;
end;

procedure Test_Model_AddAndQuery;
var
  tl: TTimeline;
  tId, cId, sId: Integer;
  c: TTimelineClip;
begin
  tl := MakeTimelineWithClip(tId, cId, sId);
  try
    CheckEqualInt(1, tl.TrackCount, 'one track');
    CheckEqualInt(1, tl.ClipCountTotal, 'one clip');
    c := tl.ClipById(cId);
    Check(c <> nil, 'clip looked up by id');
    CheckNear(7.0, c.EndSeconds, 1e-12, 'end = start + length');
    Check(tl.GetTrack(0).ClipAtSeconds(5.0) = c, 'ClipAtSeconds finds the clip');
    Check(tl.GetTrack(0).ClipAtSeconds(9.0) = nil, 'ClipAtSeconds past the clip is nil');
    CheckNear(7.0, tl.TotalDurationSeconds, 1e-12, 'total duration is the clip end');
  finally
    tl.Free;
  end;
end;

procedure Test_Model_SplitIsNonDestructive;
var
  tl: TTimeline;
  tId, cId, sId: Integer;
  left, right: TTimelineClip;
  srcFramesBefore: Int64;
begin
  tl := MakeTimelineWithClip(tId, cId, sId);
  try
    srcFramesBefore := tl.SourceById(sId).FrameCount;
    right := tl.SplitClip(cId, 5.5);        // 1.5 s into a 3 s clip
    left := tl.ClipById(cId);

    CheckEqualInt(2, tl.ClipCountTotal, 'split produced a second clip');
    CheckNear(1.5, left.LengthSeconds, 1e-9, 'left half length');
    CheckNear(1.5, right.LengthSeconds, 1e-9, 'right half length');
    CheckNear(left.LengthSeconds + right.LengthSeconds, 3.0, 1e-9, 'total length preserved');
    CheckNear(5.5, right.StartSeconds, 1e-9, 'right half starts at the cut');
    CheckNear(7.0, right.EndSeconds, 1e-9, 'right half ends where the original did');
    { source windows are contiguous: left [1..2.5], right [2.5..4] }
    CheckNear(1.0, left.SourceOffsetSeconds, 1e-9, 'left keeps the original source offset');
    CheckNear(2.5, right.SourceOffsetSeconds, 1e-9, 'right continues seamlessly into the source');
    CheckNear(left.SourceSecondsAt(5.5), right.SourceSecondsAt(5.5), 1e-9,
      'no source discontinuity at the cut');
    CheckEqualInt(srcFramesBefore, tl.SourceById(sId).FrameCount,
      'the source media is untouched by the split');
  finally
    tl.Free;
  end;
end;

procedure Test_Model_TrimAndSlip;
var
  tl: TTimeline;
  tId, cId, sId: Integer;
  c: TTimelineClip;
  readAt5Before, readAt5After: Double;
begin
  tl := MakeTimelineWithClip(tId, cId, sId);
  try
    c := tl.ClipById(cId);
    readAt5Before := c.SourceSecondsAt(5.0);

    tl.TrimClip(cId, ceStart, 4.5);           // pull the head in by 0.5 s
    CheckNear(4.5, c.StartSeconds, 1e-9, 'start moved');
    CheckNear(2.5, c.LengthSeconds, 1e-9, 'length shrank by the trim amount');
    CheckNear(1.5, c.SourceOffsetSeconds, 1e-9, 'offset advanced so the content stays put');
    readAt5After := c.SourceSecondsAt(5.0);
    CheckNear(readAt5Before, readAt5After, 1e-9, 'trim-start is non-destructive under a fixed time');

    tl.TrimClip(cId, ceEnd, 6.0);             // crop the tail
    CheckNear(1.5, c.LengthSeconds, 1e-9, 'end trim sets length only');
    CheckNear(1.5, c.SourceOffsetSeconds, 1e-9, 'end trim leaves the offset alone');

    tl.SlipClip(cId, 0.25);
    CheckNear(1.75, c.SourceOffsetSeconds, 1e-9, 'slip shifts the content under the window');
    CheckNear(4.5, c.StartSeconds, 1e-9, 'slip does not move the clip');
    CheckNear(1.5, c.LengthSeconds, 1e-9, 'slip does not resize the clip');
  finally
    tl.Free;
  end;
end;

procedure Test_Model_MoveDuplicateRemove;
var
  tl: TTimeline;
  tId, cId, sId: Integer;
  t2: TTimelineTrack;
  dup: TTimelineClip;
  trk: TTimelineTrack;
begin
  tl := MakeTimelineWithClip(tId, cId, sId);
  try
    t2 := tl.AddTrack(tkAudio, 'Audio 2');
    tl.MoveClip(cId, 8.0, t2.Id);
    Check(tl.GetTrack(0).ClipCount = 0, 'clip left the first track');
    Check(t2.ClipCount = 1, 'clip landed on the second track');
    CheckNear(8.0, tl.ClipById(cId).StartSeconds, 1e-9, 'clip moved to the new start');

    dup := tl.DuplicateClip(cId);
    Check(dup.Id <> cId, 'duplicate has a fresh id');
    CheckNear(11.0, dup.StartSeconds, 1e-9, 'duplicate sits right after the original');
    CheckEqualInt(2, t2.ClipCount, 'duplicate added to the same track');

    tl.RemoveClip(cId);
    Check(tl.ClipById(cId, trk) = nil, 'removed clip is gone');
    CheckEqualInt(1, tl.ClipCountTotal, 'only the duplicate remains');
  finally
    tl.Free;
  end;
end;

procedure Test_Model_LockGuard;
var
  tl: TTimeline;
  tId, cId, sId: Integer;
  raised: Boolean;
begin
  tl := MakeTimelineWithClip(tId, cId, sId);
  try
    tl.SetClipLocked(cId, True);
    raised := False;
    try
      tl.MoveClip(cId, 1.0);
    except
      on E: EUDAWError do
        raised := (E.Code = errInvalidState);
    end;
    Check(raised, 'moving a locked clip is rejected');

    raised := False;
    try
      tl.SplitClip(cId, 5.0);
    except
      on E: EUDAWError do raised := True;
    end;
    Check(raised, 'splitting a locked clip is rejected');

    tl.SetClipLocked(cId, False);
    tl.MoveClip(cId, 1.0);   // now allowed
    CheckNear(1.0, tl.ClipById(cId).StartSeconds, 1e-9, 'unlocked clip moves again');
  finally
    tl.Free;
  end;
end;

procedure Test_Model_MarkersRegionsAndClone;
var
  tl, cl: TTimeline;
  tId, cId, sId, mId: Integer;
begin
  tl := MakeTimelineWithClip(tId, cId, sId);
  try
    mId := tl.AddMarker('Verse', 8.0).Id;
    tl.AddRegion('Chorus', 16.0, 8.0);
    CheckEqualInt(1, tl.MarkerCount, 'marker added');
    CheckEqualInt(1, tl.RegionCount, 'region added');
    CheckNear(24.0, tl.TotalDurationSeconds, 1e-9, 'region end extends the duration');

    cl := tl.Clone;
    try
      CheckEqualInt(tl.TrackCount, cl.TrackCount, 'clone track count');
      CheckEqualInt(tl.ClipCountTotal, cl.ClipCountTotal, 'clone clip count');
      CheckEqualInt(tl.MarkerCount, cl.MarkerCount, 'clone marker count');
      { mutate the original; the clone must not follow }
      tl.MoveClip(cId, 0.0);
      tl.RemoveMarker(mId);
      CheckNear(4.0, cl.ClipById(cId).StartSeconds, 1e-9, 'clone clip position is independent');
      CheckEqualInt(1, cl.MarkerCount, 'clone markers are independent');
    finally
      cl.Free;
    end;
  finally
    tl.Free;
  end;
end;

{ ================= serialization ================= }

function BuildRichTimeline: TTimeline;
var
  tl: TTimeline;
  s1, s2: TMediaSource;
  t1, t2: TTimelineTrack;
  c: TTimelineClip;
begin
  tl := TTimeline.Create;
  s1 := tl.AddSource('C:\media\drums.wav', 44100, 2, 441000);
  s2 := tl.AddSource('C:\media\bass.wav', 48000, 1, 240000);
  t1 := tl.AddTrack(tkAudio, 'Drums');
  t1.GainDb := -2.5;
  t1.Muted := True;
  t2 := tl.AddTrack(tkAudio, 'Bass line');
  c := tl.AddClip(t1.Id, s1.Id, 'Groove 1', 0.0, 0.0, 4.0);
  c.GainDb := -3.0;
  c.FadeInSeconds := 0.02;
  c.FadeOutSeconds := 0.15;
  c.FadeOutShape := fsLinear;
  tl.AddClip(t1.Id, s1.Id, 'Groove 2', 4.0, 0.0, 4.0);
  c := tl.AddClip(t2.Id, s2.Id, 'Bass A', 2.0, 0.5, 6.0);
  c.Reversed := True;
  c.Locked := True;
  tl.AddMarker('Intro', 0.0);
  tl.AddMarker('Verse', 8.0);
  tl.AddRegion('Bridge', 16.0, 4.0);
  tl.PlayheadSeconds := 3.25;
  tl.LoopEnabled := True;
  tl.LoopStartSeconds := 4.0;
  tl.LoopLengthSeconds := 4.0;
  Result := tl;
end;

procedure CheckTimelinesEqual(A, B: TTimeline; const AWhat: string);
var
  i, j: Integer;
  ta, tb: TTimelineTrack;
  ca, cb: TTimelineClip;
begin
  CheckEqualInt(A.TrackCount, B.TrackCount, AWhat + ': track count');
  CheckEqualInt(A.SourceCount, B.SourceCount, AWhat + ': source count');
  CheckEqualInt(A.MarkerCount, B.MarkerCount, AWhat + ': marker count');
  CheckEqualInt(A.RegionCount, B.RegionCount, AWhat + ': region count');
  CheckEqualBool(A.LoopEnabled, B.LoopEnabled, AWhat + ': loop flag');
  CheckNear(A.PlayheadSeconds, B.PlayheadSeconds, 1e-6, AWhat + ': playhead');
  CheckNear(A.LoopStartSeconds, B.LoopStartSeconds, 1e-6, AWhat + ': loop start');
  CheckNear(A.LoopLengthSeconds, B.LoopLengthSeconds, 1e-6, AWhat + ': loop length');
  for i := 0 to A.TrackCount - 1 do
  begin
    ta := A.GetTrack(i);
    tb := B.GetTrack(i);
    CheckEqualInt(ta.Id, tb.Id, AWhat + ': track id');
    CheckEqualStr(ta.Name, tb.Name, AWhat + ': track name');
    CheckEqualInt(Ord(ta.Kind), Ord(tb.Kind), AWhat + ': track kind');
    CheckEqualBool(ta.Muted, tb.Muted, AWhat + ': track mute');
    CheckNear(ta.GainDb, tb.GainDb, 1e-6, AWhat + ': track gain');
    CheckEqualInt(ta.ClipCount, tb.ClipCount, AWhat + ': clip count');
    for j := 0 to ta.ClipCount - 1 do
    begin
      ca := ta.GetClip(j);
      cb := tb.GetClip(j);
      CheckEqualInt(ca.Id, cb.Id, AWhat + ': clip id');
      CheckEqualStr(ca.Name, cb.Name, AWhat + ': clip name');
      CheckEqualInt(ca.SourceId, cb.SourceId, AWhat + ': clip source');
      CheckNear(ca.StartSeconds, cb.StartSeconds, 1e-6, AWhat + ': clip start');
      CheckNear(ca.SourceOffsetSeconds, cb.SourceOffsetSeconds, 1e-6, AWhat + ': clip offset');
      CheckNear(ca.LengthSeconds, cb.LengthSeconds, 1e-6, AWhat + ': clip length');
      CheckNear(ca.GainDb, cb.GainDb, 1e-6, AWhat + ': clip gain');
      CheckNear(ca.FadeInSeconds, cb.FadeInSeconds, 1e-6, AWhat + ': fade in');
      CheckNear(ca.FadeOutSeconds, cb.FadeOutSeconds, 1e-6, AWhat + ': fade out');
      CheckEqualInt(Ord(ca.FadeOutShape), Ord(cb.FadeOutShape), AWhat + ': fade out shape');
      CheckEqualBool(ca.Reversed, cb.Reversed, AWhat + ': reversed');
      CheckEqualBool(ca.Locked, cb.Locked, AWhat + ': locked');
    end;
  end;
end;

procedure Test_Serial_StandaloneRoundTrip;
var
  tl, back: TTimeline;
  text: string;
begin
  tl := BuildRichTimeline;
  try
    text := TimelineToString(tl);
    back := TimelineFromString(text);
    try
      CheckTimelinesEqual(tl, back, 'standalone');
      CheckEqualStr(text, TimelineToString(back), 'serialization is stable across a round-trip');
    finally
      back.Free;
    end;
  finally
    tl.Free;
  end;
end;

procedure Test_Serial_EmbeddedInProjectRoundTrip;
var
  doc, back: TProjectDocument;
  rich: TTimeline;
  text: string;
begin
  doc := TProjectDocument.CreateNew('Timeline Song');
  rich := BuildRichTimeline;
  try
    doc.ReplaceTimeline(rich);
    rich := nil;
    doc.TempoBPM := 132.0;
    text := ProjectToString(doc);
    Check(Pos('TIMELINE-BEGIN', text) > 0, 'project stream carries the embedded timeline');

    back := ProjectFromString(text);
    try
      CheckNear(132.0, back.TempoBPM, 1e-9, 'project metadata still round-trips');
      CheckTimelinesEqual(doc.Timeline, back.Timeline, 'embedded');
    finally
      back.Free;
    end;
  finally
    rich.Free;
    doc.Free;
  end;
end;

procedure Test_Serial_ForwardCompatV1Project;
var
  v1: string;
  doc: TProjectDocument;
begin
  { a hand-written v1 project (no TIMELINE section) must still load, with an
    empty timeline rather than an error }
  v1 :=
    'UDAWPROJECT 1'#13#10 +
    'UUID {00000000-0000-0000-0000-000000000000}'#13#10 +
    'NAME "Legacy"'#13#10 +
    'CREATED 2026-01-01 00:00:00'#13#10 +
    'MODIFIED 2026-01-01 00:00:00'#13#10 +
    'TEMPO 120'#13#10 +
    'TIMESIG 4 4'#13#10 +
    'SAMPLERATE 48000'#13#10 +
    'CHANNELS 2'#13#10 +
    'GRAPH-BEGIN'#13#10 +
    'UDAWGRAPH 1'#13#10 +
    'CHANNELS 2'#13#10 +
    'NODE 1 output "Master" -'#13#10 +
    'GRAPH-END'#13#10;
  doc := ProjectFromString(v1);
  try
    CheckEqualStr('Legacy', doc.Name, 'v1 project loads');
    CheckEqualInt(0, doc.Timeline.TrackCount, 'v1 project has an empty timeline');
  finally
    doc.Free;
  end;
end;

procedure Test_Serial_Rejections;
var
  raised: Boolean;
begin
  raised := False;
  try
    TimelineFromString(TIMELINE_FILE_MAGIC + ' ' +
      IntToStr(TIMELINE_FILE_VERSION + 1) + #13#10).Free;
  except
    on E: EUDAWError do raised := (E.Code = errConfig);
  end;
  Check(raised, 'a future timeline version is rejected');

  raised := False;
  try
    TimelineFromString('UDAWTIMELINE 1'#13#10 + 'WOBBLE 3'#13#10).Free;
  except
    on E: EUDAWError do raised := (E.Code = errConfig);
  end;
  Check(raised, 'an unknown timeline line is rejected, not ignored');
end;

{ ================= view ================= }

procedure Test_View_ZoomScrollSnap;
var
  v: TTimelineView;
  sAtAnchor: Double;
begin
  v := TTimelineView.Create;
  try
    v.SetGrid(Ctx120);
    v.SetHeaderWidth(100);
    v.SetViewportWidth(900);       // 800 px lane
    v.SetContentSeconds(60);
    v.SetZoom(100);                // 100 px/s -> 8 s visible

    { seconds<->x is an exact inverse }
    CheckNear(12.34, v.XToSeconds(v.SecondsToX(12.34)), 1e-9, 'x<->seconds inverse');

    { zoom clamps }
    v.SetZoom(1e9);
    Check(v.PixelsPerSecond <= TIMELINE_VIEW_MAX_PPS + 1, 'zoom clamped to max');
    v.SetZoom(1e-9);
    Check(v.PixelsPerSecond >= TIMELINE_VIEW_MIN_PPS - 1e-6, 'zoom clamped to min');

    { anchored zoom keeps the second under the anchor pixel fixed }
    v.SetZoom(100);
    v.ScrollToSeconds(10);
    sAtAnchor := v.XToSeconds(400);
    v.ZoomBy(2.0, 400);
    CheckNear(sAtAnchor, v.XToSeconds(400), 1e-6, 'anchored zoom pins the anchor position');

    { scroll never goes negative }
    v.ScrollToSeconds(-5);
    CheckNear(0.0, v.ScrollSeconds, 1e-12, 'scroll clamped at zero');

    { snap delegates to the grid }
    v.SnapMode := smBeat;
    CheckNear(0.5, v.Snap(0.62), 1e-9, 'view snap uses the musical grid');
    v.SnapMode := smOff;
    CheckFalse(v.SnapEnabled, 'snap can be turned off');
    CheckNear(0.62, v.Snap(0.62), 1e-9, 'snap off is identity');
  finally
    v.Free;
  end;
end;

{ ================= commands ================= }

procedure Test_Cmd_AddRemoveTrackUndo;
var
  doc: TProjectDocument;
  mgr: TCommandManager;
  addCmd: TAddTimelineTrackCommand;
  newId: Integer;
begin
  doc := TProjectDocument.CreateNew('c');
  mgr := TCommandManager.Create;
  try
    addCmd := TAddTimelineTrackCommand.Create(doc, tkAudio, 'T1');
    Check(mgr.Perform(addCmd), 'add-track command executed');
    newId := addCmd.CreatedId;
    CheckEqualInt(1, doc.Timeline.TrackCount, 'track present after add');
    Check(doc.Dirty, 'document marked dirty by the command');

    mgr.Undo;
    CheckEqualInt(0, doc.Timeline.TrackCount, 'undo removed the track');
    mgr.Redo;
    CheckEqualInt(1, doc.Timeline.TrackCount, 'redo re-added the track');
    CheckEqualInt(newId, doc.Timeline.GetTrack(0).Id, 'redo keeps the original track id');

    mgr.Perform(TRemoveTimelineTrackCommand.Create(doc, newId));
    CheckEqualInt(0, doc.Timeline.TrackCount, 'remove-track command executed');
    mgr.Undo;
    CheckEqualInt(1, doc.Timeline.TrackCount, 'undo restored the removed track');
  finally
    mgr.Free;
    doc.Free;
  end;
end;

procedure Test_Cmd_ClipMoveMergeAndRemove;
var
  doc: TProjectDocument;
  mgr: TCommandManager;
  trkCmd: TAddTimelineTrackCommand;
  clipCmd: TAddTimelineClipCommand;
  srcId, clipId: Integer;
begin
  doc := TProjectDocument.CreateNew('c');
  mgr := TCommandManager.Create;
  try
    srcId := doc.Timeline.AddSource('x.wav', 48000, 2, 480000).Id;
    trkCmd := TAddTimelineTrackCommand.Create(doc, tkAudio, 'T');
    mgr.Perform(trkCmd);
    clipCmd := TAddTimelineClipCommand.Create(doc, trkCmd.CreatedId, srcId, 'C', 1.0, 0.0, 2.0);
    mgr.Perform(clipCmd);
    clipId := clipCmd.CreatedId;
    CheckEqualInt(2, mgr.UndoCount, 'two commands on the stack');

    mgr.Perform(TMoveTimelineClipCommand.Create(doc, clipId, 3.0));
    mgr.Perform(TMoveTimelineClipCommand.Create(doc, clipId, 5.0));
    mgr.Perform(TMoveTimelineClipCommand.Create(doc, clipId, 6.5));
    CheckEqualInt(3, mgr.UndoCount, 'rapid moves collapsed into one undo step');
    CheckNear(6.5, doc.Timeline.ClipById(clipId).StartSeconds, 1e-9, 'clip at the final position');

    mgr.Undo;
    CheckNear(1.0, doc.Timeline.ClipById(clipId).StartSeconds, 1e-9,
      'one undo reverts the whole move gesture');

    mgr.Redo;
    CheckNear(6.5, doc.Timeline.ClipById(clipId).StartSeconds, 1e-9, 'redo re-applies the move');

    mgr.Perform(TRemoveTimelineClipCommand.Create(doc, clipId));
    Check(doc.Timeline.ClipById(clipId) = nil, 'clip removed');
    mgr.Undo;
    Check(doc.Timeline.ClipById(clipId) <> nil, 'undo restored the clip');
    CheckNear(6.5, doc.Timeline.ClipById(clipId).StartSeconds, 1e-9,
      'restored clip keeps its position');
  finally
    mgr.Free;
    doc.Free;
  end;
end;

procedure Test_Cmd_SplitUndoRedo;
var
  doc: TProjectDocument;
  mgr: TCommandManager;
  trkCmd: TAddTimelineTrackCommand;
  clipCmd: TAddTimelineClipCommand;
  splitCmd: TSplitTimelineClipCommand;
  srcId, clipId, rightId: Integer;
begin
  doc := TProjectDocument.CreateNew('c');
  mgr := TCommandManager.Create;
  try
    srcId := doc.Timeline.AddSource('x.wav', 48000, 2, 480000).Id;
    trkCmd := TAddTimelineTrackCommand.Create(doc, tkAudio, 'T');
    mgr.Perform(trkCmd);
    clipCmd := TAddTimelineClipCommand.Create(doc, trkCmd.CreatedId, srcId, 'C', 0.0, 0.0, 4.0);
    mgr.Perform(clipCmd);
    clipId := clipCmd.CreatedId;

    splitCmd := TSplitTimelineClipCommand.Create(doc, clipId, 2.5);
    mgr.Perform(splitCmd);
    rightId := splitCmd.RightClipId;
    CheckEqualInt(2, doc.Timeline.ClipCountTotal, 'split made two clips');
    CheckNear(2.5, doc.Timeline.ClipById(clipId).LengthSeconds, 1e-9, 'left half shrank');

    mgr.Undo;
    CheckEqualInt(1, doc.Timeline.ClipCountTotal, 'undo re-joined the clip');
    CheckNear(4.0, doc.Timeline.ClipById(clipId).LengthSeconds, 1e-9,
      'undo restored the original length');

    mgr.Redo;
    CheckEqualInt(2, doc.Timeline.ClipCountTotal, 'redo split again');
    CheckEqualInt(rightId, doc.Timeline.ClipById(splitCmd.RightClipId).Id,
      'redo reuses the same right-hand clip id');
  finally
    mgr.Free;
    doc.Free;
  end;
end;

procedure Test_Model_SplitPartitionsEffectRegions;
var
  tl: TTimeline;
  trk: TTimelineTrack;
  left, right: TTimelineClip;
  srcId: Integer;
begin
  tl := TTimeline.Create;
  try
    srcId := tl.AddSource('x.wav', 48000, 2, 480000).Id;
    trk := tl.AddTrack(tkAudio, 'T');
    left := tl.AddClip(trk.Id, srcId, 'C', 0.0, 0.0, 4.0);
    left.AddEffectRegion('Reverb', 1.0, 2.0, 1, 'reverb', 'p');
    left.AddEffectRegion('Chorus', 3.5, 0.0, 2);   // 0 = to the clip's end
    right := tl.SplitClip(left.Id, 2.0);
    CheckEqualInt(1, Length(left.EffectRegions), 'left keeps only the region inside it');
    CheckEqualStr('Reverb', left.EffectRegions[0].Name, 'left region is Reverb');
    CheckNear(1.0, left.EffectRegions[0].OffsetSeconds, 1e-9, 'left region offset');
    CheckNear(1.0, left.EffectRegions[0].LengthSeconds, 1e-9, 'left region clipped at the split');
    CheckEqualInt(2, Length(right.EffectRegions), 'right keeps both regions it overlaps');
    CheckNear(0.0, right.EffectRegions[0].OffsetSeconds, 1e-9, 'right Reverb rebased to its start');
    CheckNear(1.0, right.EffectRegions[0].LengthSeconds, 1e-9, 'right Reverb remaining length');
    CheckEqualStr('reverb', right.EffectRegions[0].Kind, 'region kind survives the split');
    CheckNear(1.5, right.EffectRegions[1].OffsetSeconds, 1e-9, 'right Chorus rebased');
    CheckNear(0.5, right.EffectRegions[1].LengthSeconds, 1e-9, 'right Chorus runs to the end');
  finally
    tl.Free;
  end;
end;

procedure Test_Model_TrimStartMovesEffectRegions;
var
  doc: TProjectDocument;
  mgr: TCommandManager;
  trkId, srcId, clipId: Integer;
  c: TTimelineClip;
begin
  doc := TProjectDocument.CreateNew('c');
  mgr := TCommandManager.Create;
  try
    srcId := doc.Timeline.AddSource('x.wav', 48000, 2, 480000).Id;
    trkId := doc.Timeline.AddTrack(tkAudio, 'T').Id;
    c := doc.Timeline.AddClip(trkId, srcId, 'C', 2.0, 2.0, 4.0);
    clipId := c.Id;
    c.AddEffectRegion('Reverb', 1.0, 2.0, 1);    // timeline 3..5
    c.AddEffectRegion('Chorus', 0.2, 0.5, 2);    // timeline 2.2..2.7

    { pull the head in past Chorus and into Reverb }
    doc.Timeline.TrimClip(clipId, ceStart, 3.5);
    CheckEqualInt(1, Length(c.EffectRegions), 'region cut off by the trim is dropped');
    CheckEqualStr('Reverb', c.EffectRegions[0].Name, 'Reverb kept');
    CheckNear(0.0, c.EffectRegions[0].OffsetSeconds, 1e-9, 'Reverb rebased to the new start');
    CheckNear(1.5, c.EffectRegions[0].LengthSeconds, 1e-9, 'Reverb keeps its end at 5.0');

    { pull the head back out: regions shift right, staying on the same audio }
    doc.Timeline.TrimClip(clipId, ceStart, 3.0);
    CheckNear(0.5, c.EffectRegions[0].OffsetSeconds, 1e-9, 'Reverb still starts at 3.5 on the timeline');
    CheckNear(1.5, c.EffectRegions[0].LengthSeconds, 1e-9, 'Reverb length unchanged');

    { a merged drag that goes in and comes back out loses nothing }
    c := doc.Timeline.AddClip(trkId, srcId, 'D', 10.0, 0.0, 4.0);
    clipId := c.Id;
    c.AddEffectRegion('Chorus', 0.2, 0.5, 2);
    mgr.Perform(TTrimTimelineClipCommand.Create(doc, clipId, ceStart, 11.0));
    CheckEqualInt(0, Length(doc.Timeline.ClipById(clipId).EffectRegions), 'drag in drops Chorus');
    mgr.Perform(TTrimTimelineClipCommand.Create(doc, clipId, ceStart, 10.0));
    c := doc.Timeline.ClipById(clipId);
    CheckEqualInt(1, Length(c.EffectRegions), 'dragging back out brings Chorus back');
    CheckNear(0.2, c.EffectRegions[0].OffsetSeconds, 1e-9, 'Chorus back at its original offset');
    mgr.Undo;
    CheckNear(10.0, doc.Timeline.ClipById(clipId).StartSeconds, 1e-9, 'undo restores the start');
    CheckEqualInt(1, Length(doc.Timeline.ClipById(clipId).EffectRegions), 'undo keeps the region');
  finally
    mgr.Free;
    doc.Free;
  end;
end;

procedure Test_Cmd_RangeClipboardKeepsEffects;
var
  doc: TProjectDocument;
  mgr: TCommandManager;
  trkId, srcId, clipId: Integer;
  c: TTimelineClip;
  st: TClipState;
  addCmd: TAddTimelineClipStateCommand;
  regCmd: TAddTimelineRegionCommand;
  markCmd: TAddTimelineMarkerCommand;
begin
  doc := TProjectDocument.CreateNew('c');
  mgr := TCommandManager.Create;
  try
    srcId := doc.Timeline.AddSource('x.wav', 48000, 2, 480000).Id;
    trkId := doc.Timeline.AddTrack(tkAudio, 'T').Id;
    c := doc.Timeline.AddClip(trkId, srcId, 'C', 0.0, 0.0, 4.0);
    clipId := c.Id;
    c.AddEffectRegion('Reverb', 1.0, 2.0, 1);
    c.AddEffectRegion('Chorus', 3.5, 0.0, 2);
    c.SourceBPM := 120;

    { remove + undo brings the clip back with its effects }
    mgr.Perform(TRemoveTimelineClipCommand.Create(doc, clipId));
    mgr.Undo;
    c := doc.Timeline.ClipById(clipId);
    CheckEqualInt(2, Length(c.EffectRegions), 'undo of remove restores effect regions');
    CheckNear(120, c.SourceBPM, 1e-9, 'undo of remove restores the clip tempo');

    { a range slice carries only the effects inside it, rebased }
    st := CaptureTimelineClipSlice(doc.Timeline, clipId, 1.5, 3.8);
    CheckNear(1.5, st.StartSeconds, 1e-9, 'slice starts at the range start');
    CheckNear(2.3, st.LengthSeconds, 1e-9, 'slice length');
    CheckNear(1.5, st.SourceOffsetSeconds, 1e-9, 'slice source offset');
    CheckEqualInt(2, Length(st.EffectRegions), 'slice holds both overlapping regions');
    CheckNear(0.0, st.EffectRegions[0].OffsetSeconds, 1e-9, 'Reverb rebased to slice');
    CheckNear(1.5, st.EffectRegions[0].LengthSeconds, 1e-9, 'Reverb clipped to slice');
    CheckNear(2.0, st.EffectRegions[1].OffsetSeconds, 1e-9, 'Chorus rebased to slice');
    CheckNear(0.3, st.EffectRegions[1].LengthSeconds, 1e-9, 'Chorus clipped to slice');
    CheckNear(4.0, doc.Timeline.ClipById(clipId).LengthSeconds, 1e-9, 'slicing leaves the clip alone');

    { paste it elsewhere: effects come along; undo takes it away again }
    st.StartSeconds := 10.0;
    addCmd := TAddTimelineClipStateCommand.Create(doc, st);
    mgr.Perform(addCmd);
    c := doc.Timeline.ClipById(addCmd.CreatedId);
    Check(c <> nil, 'pasted clip exists');
    CheckNear(10.0, c.StartSeconds, 1e-9, 'pasted at the new position');
    CheckEqualInt(2, Length(c.EffectRegions), 'pasted clip keeps its effect regions');
    CheckEqualStr('Chorus', c.EffectRegions[1].Name, 'pasted region names');
    mgr.Undo;
    Check(doc.Timeline.ClipById(addCmd.CreatedId) = nil, 'undo removes the pasted clip');
    mgr.Redo;
    CheckEqualInt(2, Length(doc.Timeline.ClipById(addCmd.CreatedId).EffectRegions),
      'redo restores the pasted clip with its effects');

    { markers, regions and titles are undoable too }
    markCmd := TAddTimelineMarkerCommand.Create(doc, 'Verse', 2.0);
    mgr.Perform(markCmd);
    mgr.Perform(TRemoveTimelineMarkerCommand.Create(doc, markCmd.CreatedId));
    CheckEqualInt(0, doc.Timeline.MarkerCount, 'marker removed');
    mgr.Undo;
    CheckEqualInt(1, doc.Timeline.MarkerCount, 'undo restores the marker');
    regCmd := TAddTimelineRegionCommand.Create(doc, 'Hook', 1.0, 2.0, 7);
    mgr.Perform(regCmd);
    CheckEqualInt(7, doc.Timeline.GetRegion(0).Color, 'region colour kept');
    mgr.Perform(TRemoveTimelineRegionCommand.Create(doc, regCmd.CreatedId));
    CheckEqualInt(0, doc.Timeline.RegionCount, 'region removed');
    mgr.Undo;
    CheckEqualInt(1, doc.Timeline.RegionCount, 'undo restores the region');
    CheckNear(2.0, doc.Timeline.GetRegion(0).LengthSeconds, 1e-9, 'restored region length');
    mgr.Perform(TSetTimelineTrackTitleCommand.Create(doc, trkId, 'Reverb, Chorus'));
    CheckEqualStr('Reverb, Chorus', doc.Timeline.TrackById(trkId).Title, 'title set');
    mgr.Undo;
    CheckEqualStr('', doc.Timeline.TrackById(trkId).Title, 'undo restores the old title');
  finally
    mgr.Free;
    doc.Free;
  end;
end;

procedure Test_Cmd_ClipGainMerge;
var
  doc: TProjectDocument;
  mgr: TCommandManager;
  trkCmd: TAddTimelineTrackCommand;
  clipCmd: TAddTimelineClipCommand;
  srcId, clipId: Integer;
begin
  doc := TProjectDocument.CreateNew('c');
  mgr := TCommandManager.Create;
  try
    srcId := doc.Timeline.AddSource('x.wav', 48000, 2, 480000).Id;
    trkCmd := TAddTimelineTrackCommand.Create(doc, tkAudio, 'T');
    mgr.Perform(trkCmd);
    clipCmd := TAddTimelineClipCommand.Create(doc, trkCmd.CreatedId, srcId, 'C', 0.0, 0.0, 4.0);
    mgr.Perform(clipCmd);
    clipId := clipCmd.CreatedId;

    mgr.Perform(TSetTimelineClipGainCommand.Create(doc, clipId, -2.0));
    mgr.Perform(TSetTimelineClipGainCommand.Create(doc, clipId, -4.0));
    mgr.Perform(TSetTimelineClipGainCommand.Create(doc, clipId, -6.0));
    CheckEqualInt(3, mgr.UndoCount, 'gain ride collapsed to one step');
    CheckNear(-6.0, doc.Timeline.ClipById(clipId).GainDb, 1e-9, 'final gain applied');

    mgr.Undo;
    CheckNear(0.0, doc.Timeline.ClipById(clipId).GainDb, 1e-9,
      'one undo returns to the pre-gesture gain');
  finally
    mgr.Free;
    doc.Free;
  end;
end;

{ ---------------- timeline playback ---------------- }

function MakeConstantDecoded(AChannels, ASampleRate, AFrameCount: Integer;
  AValue: Single): TDecodedSource;
var
  ch, i: Integer;
begin
  Result := TDecodedSource.Create;
  Result.Channels := AChannels;
  Result.SampleRate := ASampleRate;
  Result.FrameCount := AFrameCount;
  SetLength(Result.Data, AChannels);
  for ch := 0 to AChannels - 1 do
  begin
    SetLength(Result.Data[ch], AFrameCount);
    for i := 0 to AFrameCount - 1 do
      Result.Data[ch][i] := AValue;
  end;
end;

procedure Test_Playback_ClipAudibleAtGain;
var
  tl: TTimeline;
  src: TMediaSource;
  trk: TTimelineTrack;
  player: TTimelinePlayer;
  buf: TAudioBuffer;
begin
  tl := TTimeline.Create;
  player := nil;
  buf := nil;
  try
    src := tl.AddSource('fake.wav', 48000, 1, 48000);
    trk := tl.AddTrack(tkAudio, 'A');
    tl.AddClip(trk.Id, src.Id, 'Clip', 0.0, 0.0, 1.0);   // starts at t=0, 1s long

    player := TTimelinePlayer.Create(tl);
    player.InjectForTest(src.Id, MakeConstantDecoded(1, 48000, 48000, 0.5));
    player.Prepare(48000, 256, 2);

    buf := TAudioBuffer.Create(2, 256, 48000);
    buf.Configure(2, 256, 48000);
    player.RenderBlock(buf);

    { PanGains uses the constant-power law: center pan (0) attenuates each
      channel by 1/sqrt(2), not 1.0 - see UDAW.DSP.Math.PanGains. }
    CheckNear(0.5 * (1 / Sqrt(2)), buf.ChannelPtr(0)[0], 1e-4, 'clip at unity gain/center pan renders sample * center-pan gain');
    CheckNear(0.5 * (1 / Sqrt(2)), buf.ChannelPtr(1)[0], 1e-4, 'both channels carry the mono source equally at center pan');
  finally
    buf.Free;
    player.Free;
    tl.Free;
  end;
end;

procedure Test_Playback_MuteAndSolo;
var
  tl: TTimeline;
  srcA, srcB: TMediaSource;
  trkA, trkB: TTimelineTrack;
  player: TTimelinePlayer;
  buf: TAudioBuffer;
begin
  tl := TTimeline.Create;
  player := nil;
  buf := nil;
  try
    srcA := tl.AddSource('a.wav', 48000, 1, 48000);
    srcB := tl.AddSource('b.wav', 48000, 1, 48000);
    trkA := tl.AddTrack(tkAudio, 'A');
    trkB := tl.AddTrack(tkAudio, 'B');
    tl.AddClip(trkA.Id, srcA.Id, 'ClipA', 0.0, 0.0, 1.0);
    tl.AddClip(trkB.Id, srcB.Id, 'ClipB', 0.0, 0.0, 1.0);

    player := TTimelinePlayer.Create(tl);
    player.InjectForTest(srcA.Id, MakeConstantDecoded(1, 48000, 48000, 0.25));
    player.InjectForTest(srcB.Id, MakeConstantDecoded(1, 48000, 48000, 0.75));
    player.Prepare(48000, 256, 2);

    { mute track A: only B's 0.75 should sound }
    trkA.Muted := True;
    buf := TAudioBuffer.Create(2, 8, 48000);
    buf.Configure(2, 8, 48000);
    player.RenderBlock(buf);
    CheckNear(0.75 * (1 / Sqrt(2)), buf.ChannelPtr(0)[0], 1e-4, 'muted track A is silent, B still sounds');
    trkA.Muted := False;

    { solo track A: only A's 0.25 should sound, even though B is unmuted }
    tl.PlayheadSeconds := 0;
    trkA.Soloed := True;
    buf.Configure(2, 8, 48000);
    player.RenderBlock(buf);
    CheckNear(0.25 * (1 / Sqrt(2)), buf.ChannelPtr(0)[0], 1e-4, 'soloing A silences unsoloed B');
  finally
    buf.Free;
    player.Free;
    tl.Free;
  end;
end;

procedure Test_Playback_ClipGainDbAndTrackGainDb;
var
  tl: TTimeline;
  src: TMediaSource;
  trk: TTimelineTrack;
  clip: TTimelineClip;
  player: TTimelinePlayer;
  buf: TAudioBuffer;
begin
  tl := TTimeline.Create;
  player := nil;
  buf := nil;
  try
    src := tl.AddSource('a.wav', 48000, 1, 48000);
    trk := tl.AddTrack(tkAudio, 'A');
    clip := tl.AddClip(trk.Id, src.Id, 'Clip', 0.0, 0.0, 1.0);
    clip.GainDb := -6.0206;   // ~0.5x
    trk.GainDb := -6.0206;    // another ~0.5x -> combined ~0.25x

    player := TTimelinePlayer.Create(tl);
    player.InjectForTest(src.Id, MakeConstantDecoded(1, 48000, 48000, 1.0));
    player.Prepare(48000, 256, 2);

    buf := TAudioBuffer.Create(2, 8, 48000);
    buf.Configure(2, 8, 48000);
    player.RenderBlock(buf);
    CheckNear(0.25 * (1 / Sqrt(2)), buf.ChannelPtr(0)[0], 3e-3, 'clip dB gain and track dB gain both apply (multiplicatively)');
  finally
    buf.Free;
    player.Free;
    tl.Free;
  end;
end;

procedure Test_Playback_SilentBeforeAndAfterClip;
var
  tl: TTimeline;
  src: TMediaSource;
  trk: TTimelineTrack;
  player: TTimelinePlayer;
  buf: TAudioBuffer;
begin
  tl := TTimeline.Create;
  player := nil;
  buf := nil;
  try
    src := tl.AddSource('a.wav', 48000, 1, 48000);
    trk := tl.AddTrack(tkAudio, 'A');
    tl.AddClip(trk.Id, src.Id, 'Clip', 2.0, 0.0, 1.0);   // starts at t=2s

    player := TTimelinePlayer.Create(tl);
    player.InjectForTest(src.Id, MakeConstantDecoded(1, 48000, 48000, 0.9));
    player.Prepare(48000, 256, 2);

    tl.PlayheadSeconds := 0.0;   // before the clip starts
    buf := TAudioBuffer.Create(2, 8, 48000);
    buf.Configure(2, 8, 48000);
    player.RenderBlock(buf);
    CheckNear(0.0, buf.ChannelPtr(0)[0], 1e-6, 'silent before the clip starts');
  finally
    buf.Free;
    player.Free;
    tl.Free;
  end;
end;

procedure Test_Playback_AdvancesPlayhead;
var
  tl: TTimeline;
  player: TTimelinePlayer;
  buf: TAudioBuffer;
begin
  tl := TTimeline.Create;
  player := nil;
  buf := nil;
  try
    tl.AddTrack(tkAudio, 'A');
    player := TTimelinePlayer.Create(tl);
    player.Prepare(48000, 256, 2);
    tl.PlayheadSeconds := 1.0;
    buf := TAudioBuffer.Create(2, 480, 48000);
    buf.Configure(2, 480, 48000);
    player.RenderBlock(buf);
    CheckNear(1.01, tl.PlayheadSeconds, 1e-9, 'playhead advances by FrameCount/SampleRate each render');
  finally
    buf.Free;
    player.Free;
    tl.Free;
  end;
end;

{ ---------------- registration ---------------- }

procedure Test_ClipEffects;
var clip: TTimelineClip;
begin
  clip := TTimelineClip.Create(1);
  try
    CheckFalse(clip.HasEffects, 'new clip is dry');
    clip.FadeInSeconds := 0.2; Check(clip.HasEffects, 'fade in');
    clip.FadeInSeconds := 0; clip.FadeOutSeconds := 0.2; Check(clip.HasEffects, 'fade out');
    clip.FadeOutSeconds := 0; clip.GainDb := -3; Check(clip.HasEffects, 'clip gain');
    clip.GainDb := 0; clip.Reversed := True; Check(clip.HasEffects, 'reverse');
    clip.Reversed := False; CheckFalse(clip.HasEffects, 'removing effects restores dry state');
  finally clip.Free; end;
end;

procedure RegisterPhase7Tests;
begin
  RegisterTest('timeline.model', 'clip effects indication', Test_ClipEffects);
  RegisterTest('timeline.time', 'seconds <-> samples',        @Test_Time_SamplesRoundTrip);
  RegisterTest('timeline.time', 'beats and bars',             @Test_Time_BeatsAndBars);
  RegisterTest('timeline.time', 'grid spacing and snap',      @Test_Time_GridSpacingAndSnap);
  RegisterTest('timeline.time', 'bar/beat + timecode format', @Test_Time_Formatting);

  RegisterTest('timeline.waveform', 'exact bounds + pyramid', @Test_Waveform_ExactBoundsAndPyramid);
  RegisterTest('timeline.waveform', 'ramp + display columns', @Test_Waveform_RampAndColumns);
  RegisterTest('timeline.waveform', 'binary cache round-trip',@Test_Waveform_BinaryRoundTrip);
  RegisterTest('timeline.waveform', 'streaming build from WAV',@Test_Waveform_StreamFromWav);

  RegisterTest('timeline.model', 'add + query',               @Test_Model_AddAndQuery);
  RegisterTest('timeline.model', 'split is non-destructive',  @Test_Model_SplitIsNonDestructive);
  RegisterTest('timeline.model', 'split partitions effect regions', @Test_Model_SplitPartitionsEffectRegions);
  RegisterTest('timeline.model', 'trim start moves effect regions', @Test_Model_TrimStartMovesEffectRegions);
  RegisterTest('timeline.model', 'trim + slip',               @Test_Model_TrimAndSlip);
  RegisterTest('timeline.model', 'move + duplicate + remove', @Test_Model_MoveDuplicateRemove);
  RegisterTest('timeline.model', 'lock guard',                @Test_Model_LockGuard);
  RegisterTest('timeline.model', 'markers, regions, clone',   @Test_Model_MarkersRegionsAndClone);

  RegisterTest('timeline.serial', 'standalone round-trip',    @Test_Serial_StandaloneRoundTrip);
  RegisterTest('timeline.serial', 'embedded in project',      @Test_Serial_EmbeddedInProjectRoundTrip);
  RegisterTest('timeline.serial', 'v1 project still loads',   @Test_Serial_ForwardCompatV1Project);
  RegisterTest('timeline.serial', 'version / line rejection', @Test_Serial_Rejections);

  RegisterTest('timeline.view', 'zoom, scroll, snap',         @Test_View_ZoomScrollSnap);

  RegisterTest('timeline.cmd', 'add / remove track undo',     @Test_Cmd_AddRemoveTrackUndo);
  RegisterTest('timeline.cmd', 'clip move merge + remove',    @Test_Cmd_ClipMoveMergeAndRemove);
  RegisterTest('timeline.cmd', 'split undo / redo',           @Test_Cmd_SplitUndoRedo);
  RegisterTest('timeline.cmd', 'clip gain merge',             @Test_Cmd_ClipGainMerge);
  RegisterTest('timeline.cmd', 'range clipboard keeps effects', @Test_Cmd_RangeClipboardKeepsEffects);

  RegisterTest('timeline.playback', 'clip audible at gain/pan',    @Test_Playback_ClipAudibleAtGain);
  RegisterTest('timeline.playback', 'track mute + solo',           @Test_Playback_MuteAndSolo);
  RegisterTest('timeline.playback', 'clip + track dB gain combine',@Test_Playback_ClipGainDbAndTrackGainDb);
  RegisterTest('timeline.playback', 'silent outside clip range',   @Test_Playback_SilentBeforeAndAfterClip);
  RegisterTest('timeline.playback', 'playhead advances',           @Test_Playback_AdvancesPlayhead);
end;

end.
