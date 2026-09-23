# Phase 7 - Timeline

Status: **implemented and passing** (157/157 acceptance tests: 21 Phase 1 +
26 Phase 2 + 31 Phase 3 + 19 Phase 4 + 18 Phase 5 + 19 Phase 6 + 23 Phase 7,
Delphi 12 / Win64). The Windows executable builds with the timeline units
linked and gains a live **Timeline** tab. `UDAW_PHASE` is bumped to 7.

Phase 7 delivers the plan's main DAW timeline (section 7) and the waveform
system (section 8): tracks, clips, non-destructive editing, zoom, scrolling,
snapping and **real** multiresolution waveform rendering. No third-party
code - the peak cache, the musical grid math and the text serializer are all
written from scratch.

## Layout

```
src/timeline/
  UDAW.Timeline.Time.pas          The time domain. TGridContext (tempo +
                                   time signature + sample rate) and free
                                   functions converting seconds <-> samples
                                   <-> beats/bars, grid spacing, nearest and
                                   directional snap (TSnapMode: Off / Bar /
                                   Beat / 1-2 / 1-3 / 1-4 / 1-6 / 1-8 / 1-16 /
                                   Seconds / Sample), and bar.beat.tick +
                                   h:mm:ss.mmm formatting. No state, fully
                                   unit-tested.

  UDAW.Timeline.Waveform.pas      The waveform system (plan section 8).
                                   TWavePeak (exact min, exact max, RMS per
                                   block). TWaveformBuilder streams planar
                                   Float32 blocks (AddSamples / Finish) so a
                                   multi-GB file is never buffered whole;
                                   level 0 = 64 samples/block, each higher
                                   level aggregates x4 up to a single bin.
                                   TWaveformCache.GetColumns picks the finest
                                   level no wider than the requested
                                   samples-per-pixel, so an overview is
                                   O(pixels). SaveToStream / LoadFromStream:
                                   a small versioned binary format, keyed by
                                   a source signature, stored separately from
                                   the media. BuildWaveformCacheFromWav /
                                   ...FromPlanar one-shots.

  UDAW.Timeline.Model.pas         The arrangement. TTimeline owns tracks,
                                   a media-source registry (deduped by path),
                                   markers, regions, loop range and playhead.
                                   TTimelineTrack (kinds: Audio / MIDI /
                                   Instrument / Tracker / Bus / Aux / Folder /
                                   Master) keeps its clips sorted. TTimelineClip
                                   is a NON-DESTRUCTIVE window into a source:
                                   StartSeconds, SourceOffsetSeconds,
                                   LengthSeconds, GainDb, fade in/out + shape,
                                   Reversed, Muted, Locked, Loop. Operations:
                                   add / remove / move (incl. across tracks) /
                                   split / trim start|end / slip / duplicate,
                                   plus per-clip gain / fades / reverse / mute /
                                   lock. Split, trim and slip only move the
                                   window - source audio is never touched. A
                                   locked clip rejects mutating edits with
                                   EUDAWError(errInvalidState). Deep Clone for
                                   the recovery manager.

  UDAW.Timeline.Serialization.pas Versioned, human-readable text serializer
                                   (UDAWTIMELINE 1). Round-trips every field.
                                   Used standalone (.udawtl) and embedded
                                   verbatim inside the project file between
                                   TIMELINE-BEGIN / TIMELINE-END. Unknown line
                                   or future version -> EUDAWError(errConfig);
                                   it never loads with data silently missing.

  UDAW.Timeline.View.pas          The editor viewport - GUI-free so it is
                                   unit-tested. Pixels-per-second (zoom, clamped
                                   1 .. 40000), horizontal scroll (clamped to
                                   content + run-out), header/ruler insets.
                                   SecondsToX / XToSeconds, anchored ZoomBy
                                   (keeps the second under a pixel fixed),
                                   Snap delegating to the musical grid.

  UDAW.Timeline.Commands.pas      Undo/redo as Phase 5 TDAWCommand descendants
                                   operating on TProjectDocument.Timeline, so
                                   timeline edits share the one project-wide
                                   undo stack: add/remove track, add/remove
                                   clip, move clip (AbsorbNext merge for a
                                   drag), trim (merge), split (undo = re-join,
                                   redo reuses the same right-hand clip id),
                                   set clip gain (merge), add marker.
```

`TProjectDocument` now owns a `TTimeline` alongside its audio graph, exposes
`GridContext`, deep-copies the timeline in `Clone`, and the project
serializer's version is bumped to **2** (a v1 project with no `TIMELINE`
block still loads, with an empty timeline).

## Non-destructive editing

Every clip edit changes only the window onto the source:

| Operation   | StartSeconds | LengthSeconds | SourceOffsetSeconds |
|-------------|--------------|---------------|---------------------|
| Move        | changes      | -             | -                   |
| Trim start  | changes      | changes       | changes (stays put) |
| Trim end    | -            | changes       | -                   |
| Slip        | -            | -             | changes             |
| Split       | left: -, right: at cut | both halves sum to the original | right continues seamlessly |

Split gives the left half the fade-in and the right half the fade-out; the
new inner edges get no fade. Reversed clips adjust the offset arithmetic so
the same guarantees hold.

## Waveform rendering

The Timeline tab draws the real peak cache: for each visible clip it builds
(lazily, once) the source's `TWaveformCache` and, per screen column, draws a
vertical line from the exact max to the exact min sample that column covers,
picking the pyramid level that matches the zoom. A source with no readable
file draws a flat centre line - never a synthetic waveform.

## Timeline tab (design-time)

All controls are placed at design time in `UDAW.UI.MainForm.dfm` / `.lfm`
(project rule 23). Build demo arrangement (writes three short real WAVs to
the cache dir and lays down a 4-bar drum / bass / lead arrangement with
markers, a region and clip fades), Add audio track, Add clip from WAV...,
Split at playhead, Delete clip, zoom +/-, a snap picker, Undo/Redo (the
shared project stack), a horizontal scrollbar, and a `TPaintBox` that paints
the bar grid, ruler, markers, track headers, clips with real waveforms,
fades and the playhead. Click the ruler to move the (snapped) playhead;
click a clip to select it; drag a selected unlocked clip to move it (snapped,
merged into one undo step).

## Tests

`tests/Tests.Phase7.pas` (23 tests):

- **timeline.time** - seconds/samples round-trip; beats & bars (incl. 6/8);
  grid spacing + nearest / floor / ceil snap; bar.beat.tick + timecode.
- **timeline.waveform** - level-0 bin min/max are exact vs a brute-force
  scan; pyramid depth & bin counts; full-scale ramp; display-column
  aggregation + past-EOF zeroing; binary cache round-trip; streaming build
  from a real WAV file.
- **timeline.model** - add/query; split preserves total length, keeps the
  source contiguous and leaves the media untouched; trim start/end + slip
  are non-destructive under a fixed time; move across tracks + duplicate +
  remove; lock guard; markers / regions / deep Clone independence.
- **timeline.serial** - standalone round-trip (stable across a second
  encode); embedded-in-project round-trip; a hand-written v1 project still
  loads; future version and unknown line are rejected with errConfig.
- **timeline.view** - x<->seconds inverse; zoom clamp; anchored zoom pins
  the anchor; scroll clamp; snap on/off.
- **timeline.cmd** - add/remove track undo/redo with stable ids; clip move
  gesture merges to one undo step; remove/undo restores position; split
  undo re-joins and redo reuses the right-hand id; clip-gain ride merges.

## Build wiring touched

`src/timeline` added to every search path: `UDAW.dpr`, `UDAW.dproj` (path +
`DCCReference`s), `udaw.lpr`, `udaw.lpi`, `tests/UDAW.Tests.dpr`,
`tests/udaw_tests.lpr`, `tests/udaw_tests.lpi`, and
`scripts/{build,test}-windows.ps1` / `test-{linux,macos}.sh`
(`build-{linux,macos}.sh` use `lazbuild` + the `.lpi`, unchanged).

## Verified

Windows / Delphi 12 only: `scripts/test-windows.ps1` -> **157/157 pass**;
`scripts/build-windows.ps1` -> `UDAW.exe` builds and boots clean (log shows
"phase 7", no exceptions). The FPC leg is written but unrun on this machine
(no FPC), same caveat as Phases 3-6.

## Deferred (deliberately, per the plan's phase order)

Recording into clips (Phase 8), the mixer / bus routing that Bus/Aux/Folder
tracks will drive (Phase 9), MIDI and tracker clip *content* (Phases 11, 17),
automation-lane editing (curves exist only as clip fades so far), and
audio-thread playback of the arrangement (the timeline is model + editor;
routing a compiled timeline through the device engine belongs with the mixer
phase). Waveform-cache building currently runs on the UI thread on first
paint of a clip - moving it to a background job is a Phase 74 performance
task.

## Final mix export and live import status

See [Timeline export](Timeline-export.md) for the export menu, supported formats,
attribution, cancellation, decoder progress and fitted labels.
