# Phase 38 - MIDI Device I/O

Redoes the MIDI subsystem's device story on top of Phase 17's file/model/
synth foundation: real hardware input/output, live recording from a
controller straight onto the Timeline, device selection in Settings, and -
the biggest gap Phase 17 left open - MIDI clips actually being heard when
the Timeline transport plays, not just from the Piano Roll's own isolated
Play/Stop.

## What Phase 17 already had (unchanged)

`UDAW.MIDI.Types` / `.SMF` / `.Sequence` / `.PianoRoll` / `.Engine` / `.PianoRoll`
- musical model, SMF import/export, the internal `TMidiSynth` poly synth, and
  `TMidiPlaybackEngine` (a `TMidiSequence` as an `IAudioSource`). All still
  exactly as they were; Phase 38 only extends `UDAW.MIDI.Serialization` (see
  below) and reuses `TMidiPlaybackEngine`/`TMidiSynth` rather than
  replacing them.

## What was missing (confirmed by an exhaustive repo-wide grep before this
phase started): zero Windows MIDI hardware API usage anywhere, no device
enumeration, no live-recording-from-a-controller pathway, and - a separate,
structural gap - `TTrackKind.tkMidi` already existed on `TTimelineTrack` but
`UDAW.Timeline.Playback.TTimelinePlayer.RenderBlock` never rendered it: a
MIDI track placed on the Timeline was completely silent during Timeline
playback, audible only through the Piano Roll tab's own separate
`TMidiPlaybackEngine`/Play button.

## Units (src/midi)

| Unit | Adds |
|---|---|
| `UDAW.MIDI.Hardware.pas` | `TMidiInputDevice`/`TMidiOutputDevice` (winmm `midiIn*`/`midiOut*`), `EnumerateMidiInputs`/`EnumerateMidiOutputs`, `FindMidiInputByName`/`FindMidiOutputByName`. Windows-only implementation guarded by `{$IFDEF UDAW_WINDOWS}`; a non-Windows build gets stub bodies (empty device lists, every `Open` returns `False`) so the unit compiles unconditionally and callers degrade gracefully instead of needing their own platform guards. |
| `UDAW.MIDI.Capture.pas` | `TMidiCaptureEngine` - pairs live NoteOn/NoteOff into `TMidiNote`s at a fixed tempo/PPQ, records CC/program/pitch-bend/aftertouch verbatim, closes any note still held at `Stop`, optional `Monitor: TMidiSynth` for real-time audible feedback while recording. |
| `UDAW.MIDI.Serialization.pas` | `TMidiProject` clips now carry a stable `Id` independent of array position (`IdOfIndex`/`IndexOfId`/`ClipById`/`NameById`/`RemoveClipById`/`AddClipStable`), so a Timeline reference to one survives another clip being deleted or reordered. Format bumped to `UDAWMIDI 2` (the `CLIP` line's positional-index slot now holds the stable id); a `UDAWMIDI 1` file still loads, with ids synthesised 1..N in file order. |
| `UDAW.MIDI.Commands.pas` | `TCommitMidiTakeCommand` - commits a captured `TMidiSequence` to the Timeline as one undoable step, mirroring `UDAW.Recording.Commands.TCommitTakeCommand`'s shape exactly: registers the sequence as a stable-id `TMidiProject` clip (adopting it), drops a non-destructive `TTimelineClip` referencing it onto a `tkMidi` track (creating one when `ATrackId = 0`). Undo removes only the Timeline clip (and the track, if this command created it) - the MIDI-project clip itself is left in place, the same way `TCommitTakeCommand` leaves its `TMediaSource` registrations, so Redo re-attaches the same captured performance instead of losing it. |

## Timeline clip linkage: the negative-SourceId convention

`TTimelineClip.SourceId` already skips its "does this source exist"
validation whenever the id is negative (`UDAW.Timeline.Model.AddClipWithId`:
`if (ASourceId >= 0) and (SourceById(ASourceId) = nil) then raise...`) - a
convention already there for the taking. Phase 38 uses it directly: a MIDI
clip's `SourceId` is `-MidiProjectClipId` (`EncodeMidiSourceId`/
`DecodeMidiSourceId`; `TTimelineClip.IsMidiClip`/`MidiClipId`). This needed
**zero** schema or serializer changes - `SourceId` was already a plain
signed integer column in the Timeline's own text format.

## Timeline playback: rendering MIDI tracks

`UDAW.Timeline.Playback.TTimelinePlayer` gained:

- `AttachMidi(AMidi: TMidiProject)` - not owned; lets `RenderBlock` resolve
  a `tkMidi`/`tkInstrument` track's active clip to its `TMidiSequence`.
- `AttachLiveMidiMonitor(ASynth: TMidiSynth)` - not owned; every event fed to
  this synth (typically the same synth `TMidiCaptureEngine.Monitor` drives,
  or a plain live-Thru path with nothing being recorded) is mixed into the
  very next block, so a connected controller is audible through whatever the
  Timeline is already playing.
- `InvalidateAllMidi` - drops every cached per-clip `TMidiPlaybackEngine`;
  call after any edit to a MIDI clip that might currently be playing (note
  edit, undo/redo, a freshly committed take).

Each block, for every unmuted/audible `tkMidi`/`tkInstrument` track:
resolve the clip under the playhead (block-rate granularity, like the
existing per-block mute/solo check), get-or-create a `TMidiPlaybackEngine`
for that Timeline clip id (not the MIDI-project clip id, so two Timeline
clips referencing the same performance keep independent playback heads),
seek it when the block just switched onto that clip (or drifted, e.g. a
loop/scrub jump), render one block, apply clip gain + track gain/pan, sum
into the block alongside the existing direct/mixer-linked audio-track path.
Loop/Reverse/fades are **not** applied to MIDI clips in this phase (a
documented limitation, not an oversight - see "Known limitations" below).

## Live MIDI recording

`TfrmMain.mnuMidiRecordClick` (Piano Roll tab menu: Transport > "Record from
MIDI device", toggle) is the whole UI: arm starts Timeline playback if it
isn't already running (so the live monitor synth is actually audible),
starts `TMidiCaptureEngine.Start` at the current playhead/tempo; stop closes
any still-held note, and - if anything was actually captured - commits it
via `TCommitMidiTakeCommand` onto the currently selected `tkMidi` Timeline
track (or a new one). `TfrmMain.HandleLiveMidiInput`, polled every UI tick
from `TMidiInputDevice.Poll` (never the driver callback thread itself),
echoes every event to the MIDI output device (hardware Thru, when one is
open) and feeds it to the capture engine while recording or straight to the
monitor synth otherwise.

Device clock note: a `TMidiInputDevice`'s event timestamps count from its
own `midiInOpen`/`midiInStart` call, which happens once at app startup (or
whenever the Settings picker reopens it) - not once per recording. A
capture's own "seconds since Start" is computed by translating both the
recording-start moment and every incoming timestamp into that same
device-clock domain via `TMidiInputDevice.OpenTickCount64`, not by comparing
wall-clock `GetTickCount64` directly against the device's raw timestamp.

## Settings tab: MIDI Devices group

New group box on Settings > General (`RefreshMidiDeviceCombos`,
`OpenMidiDevicesFromConfig`) with Input/Output device combos, a Refresh
button (device lists are enumerated once at load; a controller plugged in
afterward needs Refresh), and a MIDI Panic button (`AllNotesOffAllChannels`
on the output device plus `TMidiSynth.AllSoundOff` on the monitor synth).
Persisted in `[midi]` by device **name**, not driver index - a driver index
is not stable across replug/reboot, matching how this project already
treats it for `UDAW.MIDI.Hardware`'s API but *unlike* the existing audio
input-device combo (which persists a backend-stable device id string,
available for audio because `UDAW.Audio.Device.TAudioDeviceInfo.Id` already
is one; winmm has no equivalent stable id, only a volatile index).

## Known limitations (deliberately out of scope for this pass)

- MIDI Timeline clips do not support Loop, Reverse, or fades (audio clips
  do). Mute and gain do work.
- No per-track MIDI output routing to external hardware - only one global
  live-Thru path (the Settings-selected output device) plus the internal
  monitor synth.
- No overdub/punch-in/punch-out for MIDI recording (Phase 8's audio
  recording has both) - one continuous capture per take.
- No live note-by-note visual feedback on the Piano Roll grid while
  recording (the notes appear once committed).
- `UDAW.MIDI.Hardware`'s real implementation is Windows-only (matches this
  project's current "Windows first" focus); other platforms get a
  functionally-empty stub, not a crash.

## Tests

`tests/Tests.Phase38.pas`: stable-id survival across removal/reorder, the
v1/v2 text-format round trip, the negative-SourceId MIDI-clip encoding,
`TCommitMidiTakeCommand` execute/undo/redo (including that undo leaves the
MIDI-project clip itself intact), and `TMidiCaptureEngine`'s NoteOn/NoteOff
pairing - including a still-held note being closed at `Stop` and an empty
capture returning `nil`. Real hardware I/O is not exercised (no MIDI device
on a CI/test machine); `UDAW.MIDI.Hardware`'s degrade-to-empty-list behavior
with no device is covered by inspection, the same way Phase 37 covers VST2
crash isolation.

## Wiring

`UDAW.dpr`, `UDAW.dproj`, `udaw.lpr`, `UDAW.lpi`, `tests/UDAW.Tests.dpr` all
gained `UDAW.MIDI.Hardware` and `UDAW.MIDI.Capture`; `UDAW_PHASE` -> 38.
