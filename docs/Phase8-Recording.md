# Phase 8 - Recording

Status: **implemented and passing** (177/177 acceptance tests: 157 from
Phases 1-7 + 20 Phase 8, Delphi 12 / Win64). The Windows executable builds
with the recording units linked and gains a live **Recording** tab.
`UDAW_PHASE` is bumped to 8.

Phase 8 delivers the plan's complete recording architecture (section 22):
mono / stereo / multichannel capture, punch-in / punch-out, loop recording,
takes, comping, input monitoring, pre-roll, count-in, latency compensation,
**disk-streaming with bounded RAM**, and **crash recovery** of an unfinished
recording. No third-party code - the recoverable chunk container, the capture
state machine and the take/comp model are all written from scratch on top of
the Phase 2 ring, Phase 6 WAV codec and Phase 7 timeline.

## Layout

```
src/recording/
  UDAW.Recording.Types.pas       Value types only. TRecordSettings (rate,
                                  channel mode, take format, pre-roll,
                                  count-in + tempo, punch mode + window,
                                  loop range, input/output latency frames,
                                  monitoring) with sample-domain accessors
                                  (CountInSamples / PreRollSamples /
                                  TotalLatencyFrames) and Validate.
                                  TRecordedTake describes one finished pass
                                  on disk.

  UDAW.Recording.ChunkFile.pas   The recoverable, disk-streaming take
                                  container. A take is a directory holding
                                  take.meta (key=value header), audio.pcm
                                  (raw interleaved Float32, appended as it
                                  arrives), audio.idx (append-only flush
                                  journal: framesTotal + wall-clock ms per
                                  record) and take.inprogress (marker, dropped
                                  only by a clean Finalize).
                                  TRecordingChunkWriter buffers at most
                                  REC_WRITER_FLUSH_FRAMES (32768) frames
                                  before forcing them to disk + journalling +
                                  FlushFileBuffers, so a multi-hour take never
                                  grows the process RSS.
                                  TRecordingChunkReader.RebuildIndex
                                  reconstructs the usable frame count straight
                                  from the bytes that survived: audio.pcm size
                                  floored to a whole frame (torn tail write
                                  discarded), capped to the last fully
                                  journalled count when the journal is intact,
                                  authoritative meta count when finalised.
                                  FinalizeToWav streams the container into a
                                  real .wav via the Phase 6 TWavWriter in any
                                  supported bit depth.

  UDAW.Recording.Engine.pas      The capture orchestrator. ProcessCaptureBlock
                                  advances an internal transport sample
                                  counter by exactly the frames it is handed
                                  and, frame-accurately:
                                    - skips pre-roll + count-in (rolled over,
                                      not written)
                                    - opens a take only inside the punch
                                      window (pmOff / pmPunchIn / pmPunchInOut)
                                    - on loop recording, closes the take and
                                      opens the next each time the transport
                                      wraps the loop range -> stacked takes,
                                      one per pass
                                    - pulls each take's timeline position
                                      earlier by InputLatencyFrames +
                                      OutputLatencyFrames so it lines up with
                                      what was played against it
                                  It never buffers audio itself - each run of
                                  in-gate frames goes straight to a
                                  TRecordingChunkWriter. On FinishTake the
                                  container is finalised and encoded to
                                  take.wav. ApplyMonitorMix folds the live
                                  input into an output block at the monitor
                                  gain. GUI-free and clock-free, so the same
                                  code drives the live ring and the offline
                                  tests.

  UDAW.Recording.Writer.pas      TRecordingWriterThread - the plan's
                                  dedicated Recording Writer Thread. The
                                  real-time capture callback only does
                                  TAudioRing.WriteFrames; this thread blocks
                                  on a signal, drains the ring in
                                  REC_DRAIN_CHUNK_FRAMES chunks and feeds
                                  ProcessCaptureBlock. Stop() drains whatever
                                  is left before exiting so the tail of a take
                                  is never lost; disk errors are caught,
                                  counted and exposed, never crash the audio
                                  path.

  UDAW.Recording.Takes.pas       Takes + comping. TTakeLane collects the
                                  takes of one recording effort (a pass, or
                                  stacked loop / punch passes over the same
                                  stretch). TTakeComp describes which take is
                                  heard at each point as an ordered gap-free
                                  segment list; the default plays take 0 for
                                  the whole lane, SetActiveTake splits at a
                                  boundary and reassigns, touching same-take
                                  segments coalesce. FlattenToClipSpecs turns
                                  the comp into one non-destructive clip
                                  placement per segment.

  UDAW.Recording.Recovery.pas    TRecordingRecovery scans the recording root
                                  for take containers that still carry the
                                  in-progress marker - the debris of a session
                                  that crashed mid-record - rebuilds each
                                  one's index from disk and encodes it to a
                                  real .wav offered on the next launch.
                                  DiscardSession removes one the user rejects.

  UDAW.Recording.Commands.pas    TCommitTakeCommand - a Phase 5 TDAWCommand
                                  that drops a take / comp (its
                                  TRecordedClipSpec list) onto the project
                                  timeline in one undoable step: registers
                                  each recorded .wav as a TMediaSource,
                                  adds one non-destructive clip per spec, and
                                  creates the target audio track when
                                  ATrackId = 0. Undo removes exactly those
                                  clips (and the track it created).
```

## Disk streaming and bounded RAM

A recording's entire in-memory footprint is one `REC_WRITER_FLUSH_FRAMES`
staging buffer in the chunk writer plus one `REC_DRAIN_CHUNK_FRAMES` drain
buffer on the writer thread - constant regardless of take length. Nothing
between the capture callback and the platter ever holds the whole recording
(plan 22: "Never accumulate an unlimited recording entirely in RAM").

## Recovery

Every take container is created with its `take.inprogress` marker **before**
the first sample is written and keeps it until `Finalize`. On the next launch
`TRecordingRecovery.ScanUnfinished` lists every container that still has the
marker; `RebuildIndex` derives the usable frame count from the surviving
bytes (a torn final `audio.pcm` write is floored away, a half-written journal
record is ignored); `RecoverSession` / `RecoverAll` encodes each to a `.wav`.
Tested against deliberately truncated `audio.pcm` and `audio.idx` files.

## Latency compensation

Recorded audio arrives `InputLatencyFrames + OutputLatencyFrames` late
relative to the transport it was played against, so a take's
`TimelineStartSeconds` is set to the in-gate timeline sample **minus** that
round-trip, clamped at 0. The Recording tab reads the two frame counts
straight from whatever the device engine negotiated
(`TAudioStreamGranted.Input/OutputLatencyFrames`).

## Recording tab (design-time)

All controls are placed at design time in `UDAW.UI.MainForm.dfm` / `.lfm`
(project rule 23): channel mode, take format, simulated-input length,
pre-roll, count-in, punch mode + in/out points, loop-record + range, input
monitoring, **Arm + simulate record** (feeds a deterministic generated tone
through the engine in ragged blocks, so it works with no capture hardware),
**Commit last take(s) to timeline** (one undoable `TCommitTakeCommand` on the
shared project stack), **Scan for recovery**, a readout memo and a
`TPaintBox` that draws each take as a bar on a seconds ruler.

## Tests

`tests/Tests.Phase8.pas` (20 tests):

- **recording.settings** - defaults + Validate rejects a reversed punch
  window; count-in / pre-roll / round-trip-latency sample math.
- **recording.chunk** - planar round-trip is bit-exact; > 3 flush buffers of
  audio stream to disk with the pcm file sized exactly frames x bytesPerFrame;
  a crashed writer keeps its marker and RebuildIndex recovers every fully
  written frame after the tail is truncated; a torn journal record is
  ignored; FinalizeToWav yields a valid PCM24 WAV that round-trips.
- **recording.engine** - simple pass captures every frame and finalises a
  WAV matching the input; pre-roll and count-in frames are rolled over, not
  written; a punch in/out window is exactly one second and starts at the
  punch-in point; the window stays sample-accurate when fed in ragged
  311-frame blocks; a 480-frame round-trip latency pulls the take earlier by
  10 ms; loop recording over a 1 s range for 2.5 s produces three stacked
  takes (48000 / 48000 / 24000 frames, pass indices 0/1/2); mono and
  4-channel passes round-trip; unity and -6 dB input-monitor mixes sum into
  the output bus.
- **recording.writer** - the writer thread drains a wait-free ring of a full
  second of stereo audio with zero overruns / errors and the take holds every
  frame.
- **recording.takes** - the default comp is one segment of take 0; punching
  take 1 into the middle splits it into three segments with the right read
  offsets; the comp flattens to three clip specs pointing at the right wavs.
- **recording.recovery** - two crashed take containers are detected (a cleanly
  finalised one is not), both recover to valid WAVs, and discard removes them.
- **recording.commit** - `TCommitTakeCommand` with `ATrackId = 0` adds a
  track + clip + media source; undo removes the clip and the track it
  created; redo restores both.

## Build wiring touched

`src/recording` added to every search path: `UDAW.dpr`, `UDAW.dproj` (path +
`DCCReference`s), `udaw.lpr`, `udaw.lpi` (x2), `tests/UDAW.Tests.dpr`,
`tests/udaw_tests.lpr`, `tests/udaw_tests.lpi`, and
`scripts/{build,test}-windows.ps1` / `test-{linux,macos}.sh`.

## Verified

Windows / Delphi 12 only: `scripts/test-windows.ps1` -> **177/177 pass**;
`scripts/build-windows.ps1` -> `UDAW.exe` builds and boots clean (log shows
"phase 8", no exceptions). The FPC leg is written but unrun on this machine
(no FPC), same caveat as Phases 3-7.

## Deferred (deliberately, per the plan's phase order)

Routing recorded / monitored audio through the live device output as part of
transport playback (the mixer's job, Phase 9); a metronome click for the
count-in (the engine reserves the beats, the click tone is a Phase 9 mixer
asset); real capture-device selection in the Recording tab (the engine already
consumes a `TAudioRing` the duplex device engine can fill - only the UI wiring
is pending); comp cross-fades at segment edges (segments are hard cuts today).
