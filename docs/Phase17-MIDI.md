# Phase 17 - MIDI

Plan section 25 ("Complete MIDI engine and piano roll").  A from-scratch MIDI
subsystem: Standard MIDI File read/write, an editable musical model with a
tempo map, the piano-roll edit operations, a real internal polyphonic synth
playback engine, project embedding at file version **5**, and undo/redo
commands.  `UDAW_PHASE` is **17**.

## Units (`src/midi/`)

| Unit | Role |
|---|---|
| `UDAW.MIDI.Types` | Channel-voice `TMidiMessage` (status/data1/data2 with `IsNoteOn/Off`, `PitchBend14`, constructors); one timestamped `TMidiEvent` (channel / meta / SysEx, with tempo / time-sig / key-sig accessors); all status + controller + meta constants; and the helper tables - `MidiNoteName` (60 = C4), `MidiNoteIsBlack`, `MidiFrequency` (A4 = 440, equal temperament), the full 128-entry General MIDI program-name table and the GM percussion map, `TempoToBPM` / `BPMToTempo`. |
| `UDAW.MIDI.SMF` | Standard MIDI File **parser + writer**, from scratch. Reads SMF Type 0 / 1 (Type 2 parsed + flagged); variable-length quantities; running status; every channel message; all meta events kept verbatim; SysEx (`F0..F7`) and escaped (`F7 ..`) blobs preserved byte for byte; a synthesised End-of-Track when the file omits one; SMPTE and PPQ divisions. The writer re-emits a byte-accurate `MThd` + `MTrk` stream with running-status compression, correct `ntrks`, and a guaranteed trailing EoT. Every length is bounds-checked - a truncated / hostile file raises `EUDAWError`, never a bad read. `SmfReadVLQ` / `SmfWriteVLQ` are exposed and reused by the project serializer. |
| `UDAW.MIDI.Sequence` | The editable model. `TMidiTrackSeq` holds paired **notes** (start tick, length, channel, key, on/off velocity, a stable `Id`, selection), a flat time-ordered **CC** list, and an **Aux** list preserving every other channel / SysEx event for lossless round-trip. `TMidiSequence` owns the PPQ grid, the tracks, a **tempo map** and a **time-signature map**, with `TickToSeconds` / `SecondsToTick` integrating the tempo segments, `TicksPerBar`, `DurationTicks/Seconds`. `BuildFromSMF` pairs note-on/off (a re-struck key closes the previous note; still-sounding keys close at track end) and lifts the tempo / time-sig / name meta out of the tracks; `ToSMF` rebuilds a conductor track + one MTrk per track. `Clone` is a deep copy. |
| `UDAW.MIDI.PianoRoll` | `TPianoRoll` - a non-owning editor over one track: add / delete / move / resize / set-velocity addressed by note `Id`; **Quantize** (grid + strength + swing, optional length); **Humanize** (deterministic seeded timing + velocity jitter); **Legato**; **Transpose**; controller-lane read/write; rectangle / all / none **selection**. Pure musical helpers: 14 scale kinds with interval sets, `ScaleContains` / `SnapNoteToScale`, and a triad / 7th **chord namer** (`DetectChordName([0,4,7]) = 'C'`). `GridTicks` / `QuantizeTick` are standalone. |
| `UDAW.MIDI.Engine` | `TMidiSynth` - a genuine polyphonic synth: up to 64 voices, a coarse GM-family -> oscillator-shape map, per-voice PolyBLEP oscillator (sine / triangle / saw / square / pulse) + one-pole tone filter + Phase 3 `TADSR`, plus a fixed noise-burst percussion voice on channel 10; per-channel volume (CC7), expression (CC11), pan (CC10, equal-power), sustain pedal (CC64), channel aftertouch and pitch bend with an RPN-0 settable range; voice stealing prefers idle, then released, then oldest. `TMidiPlaybackEngine` implements `IAudioSource`: it flattens every track to one tick-ordered event stream, advances a sample clock through the sequence tempo map (adjustable `TempoScale`, optional loop), dispatches due events to the synth and renders it into the callback buffer - no allocation or locks after `Prepare`. `RenderToPlanar` bounces the whole sequence + a tail offline. |
| `UDAW.MIDI.Serialization` | `TMidiProject` - the owning container of any number of MIDI **clips** (each a full `TMidiSequence`). `MidiProjectToString` / `FromString` is the versioned text codec (`UDAWMIDI 1`) the Phase 5 project serializer embeds between `MIDI-BEGIN` / `MIDI-END`, exactly like the GRAPH / TIMELINE / MIXER / TRACKER sections: PPQ, tempo + time-sig points, and per track the notes, CC points and hex-encoded Aux events. An older project with no MIDI block loads with an empty `TMidiProject`. |
| `UDAW.MIDI.Commands` | Undo/redo on `TProjectDocument.Midi`, built on `TDAWCommand` / `TCommandManager`. Fine-grained (clip + track + note `Id`): add / delete / move / resize / set-velocity, with move / resize / velocity **mergeable** so a drag is one undo step; add-note re-inserts with the same `Id` on redo. Structural (full-project text snapshot, restored through the serializer): add / remove clip, add / remove track, quantize, humanize, set-tempo. |

## Project format

`PROJECT_FILE_VERSION` 4 -> **5**.  `ProjectToString` appends a `MIDI-BEGIN
... MIDI-END` block; `ProjectFromString` reads it and, when it is absent (v1-v4
files), keeps the empty `TMidiProject` the document constructor makes.
`TProjectDocument` gains `Midi: TMidiProject`, `ReplaceMidi`, and deep-clones it
alongside the graph / timeline / mixer / tracker.

## UI

A design-time **Piano Roll** tab (`tabMIDI`): clip picker + add clip / add
track; add / delete note (note / start / len / vel fields); quantize / humanize
against a 1/4..1/32 grid; Play / Stop through the internal synth; Import /
Export `.mid`; Undo / Redo; a "fill demo phrase" button; and a `TPaintBox`
that draws the grid, bar lines and the current track's notes.

## Wiring

Seven MIDI units added to `UDAW.dpr`, `udaw.lpr`, `UDAW.dproj`, `udaw.lpi` and
both test runners.  `Tests.Phase16` and `Tests.Phase17` registered in both.

## Tests (`tests/Tests.Phase17.pas`)

VLQ round-trip across the boundary values; message helpers + note tables; SMF
write -> read round-trip (meta + SysEx, byte-accurate event recovery); tempo
map seconds <-> ticks with a mid-sequence tempo change; note-on/off pairing
from an SMF; sequence -> SMF -> sequence; the embedded MIDI section text
round-trip; a full project save/open at v5 carrying the MIDI clips, and an
older v4 project text with no MIDI block still loading; piano-roll edits
(add/move/resize/quantize/velocity-clamp); scale membership + chord namer;
undo commands (add execute/undo/redo, merged move); and the engine rendering
an audible tone whose dominant frequency matches the played note.
