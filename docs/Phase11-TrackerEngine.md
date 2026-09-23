# Phase 11 - Tracker Engine

Status: **implemented and passing** (257/257 acceptance tests: 228 from
Phases 1-10 + 29 Phase 11, Delphi 12 / Win64). The Windows executable builds
with the tracker units linked, boots clean (log shows "phase 11") and gains a
live **Tracker** tab. `UDAW_PHASE` is bumped to 11. The project file format is
bumped to **v4** (embedded `TRACKER` section).

Phase 11 delivers the plan's native tracker player / editor (section 13 +
phase line 11): a first-class pattern/module model, a from-scratch replay
core with real tracker effect semantics, versioned self-contained
persistence, undoable editing and a design-time pattern-grid editor. The
MOD / XM / MPTM importers of Phases 12-14 map their commands onto this
engine - they do not replace it.

## Layout

```
src/tracker/
  UDAW.Tracker.Types.pas        Value types. TTrackerCell (Note / Instrument /
                                Volume / Effect / EffectParam), the
                                TTrackerEffect set with a documented single-
                                letter map (EFFECT_LETTERS), note-value <-> name
                                helpers (1 = C-0 .. 120 = B-9; "===" key-off,
                                "^^^" cut) and NoteToHz (A-4 = value 58 = 440
                                Hz, equal temperament).

  UDAW.Tracker.Instrument.pas   TTrackerInstrument - one mono Float32 sample,
                                root note, forward / ping-pong loop, per-
                                instrument volume / pan, a per-tick fade-out
                                after key-off, and TTrackerEnvelope volume /
                                panning envelopes (linear-interpolated points,
                                sustain point, loop). MakeSine builds a
                                deterministic looped sine for the tests and the
                                "fill demo" UI action.

  UDAW.Tracker.Pattern.pas      TTrackerPattern (rows x channels TTrackerCell
                                grid, resize / channel-resize keep existing
                                data) and TTrackerModule - the whole song:
                                name, channel count, initial speed / BPM,
                                global volume, a 1-based instrument list, a
                                pattern list, and the order table (pattern
                                indices + restart position). RemovePattern
                                renumbers / drops order references so the model
                                is never left dangling. Deep Clone.

  UDAW.Tracker.Player.pas       TTrackerPlayer - the replay core. Walks the
                                order / patterns at FSpeed ticks per row and
                                FBPM (2.5/BPM s per tick), keeps per-channel
                                voice state (fractional sample position + pitch
                                as a fractional note, volume, pan, envelope
                                positions, fade-out, per-effect memory) and
                                renders Float32 blocks with linear interpolation
                                and forward / ping-pong looping. Implements
                                arpeggio, pitch slides + tone portamento,
                                vibrato, tremolo, volume / pan slides, set
                                volume / panning, sample offset, position jump,
                                pattern break, set speed / BPM, note delay /
                                cut, retrigger and fine volume slides.
                                RenderBlock is a pure function of state -
                                AsSource plugs it into the device engine and
                                the offline render the tests / "play" action
                                use.

  UDAW.Tracker.Serialization.pas UDAWTRACKER 1 - a versioned, line-oriented,
                                human-readable text format (STRIP / INSTR /
                                VOLENV / SAMPLE / PATTERN / R-rows), embedded in
                                the project file as TRACKER-BEGIN / TRACKER-END.
                                Sample PCM is carried as hex (Float32 LE) so a
                                module is fully self-contained - persistence is
                                complete, not a reference. Version-checked;
                                note / effect tokens go through the validated
                                Types parsers; the order table is buffered and
                                applied after the patterns exist so nothing is
                                clamped away.

  UDAW.Tracker.Commands.pas     Undo/redo on the Phase 5 stack. Fine-grained:
                                set / clear one cell (stores the previous
                                cell), set speed / BPM (mergeable). Structural
                                (text snapshot before/after, restored through
                                the serializer): add / remove pattern, resize a
                                pattern, order-table edits, add / remove
                                instrument (with an optional sine fill).
```

## Effect set

`.` none, `J` arpeggio, `F`/`E` pitch slide up/down, `G` tone portamento,
`H` vibrato, `R` tremolo, `D` volume slide, `C` set volume, `O` sample
offset, `B` position jump, `K` pattern break, `A` set speed/BPM, `T` set
BPM, `W` note delay, `X` note cut, `Q` retrigger, `P` set panning,
`Y` pan slide, `U`/`V` fine volume up/down. Parameters are two hex digits
(the classic `C-4 01 40 A06` layout). The lettering is UDAW's own documented
set - close to the XM/ProTracker tradition, not tied to one tracker.

## Persistence (project file v4)

`ProjectToString` writes a `TRACKER-BEGIN ... TRACKER-END` block after the
mixer block; `PROJECT_FILE_VERSION` is 4. An older file (no `TRACKER`
section) still loads - the deserializer synthesises a default one-pattern
module. `TProjectDocument` owns the module (`Tracker` property,
`ReplaceTracker` for the deserializer, deep-copied by `Clone`). `CreateNew`
seeds a 64-row / 4-channel / speed-6 / 125-BPM module.

## Tracker tab (design-time)

All controls placed at design time in `UDAW.UI.MainForm.dfm` / `.lfm`
(project rule 23): a pattern selector, speed / BPM edits + **Apply**,
**Add pattern** / **Remove pattern**, cell edits (Note / Ins / Vol / Fx
letter / Param hex) with **Set cell** / **Clear cell**, **Fill demo (sine
arpeggio)** (adds a sine instrument and a C-E-G-C arpeggio down channel 0 -
each step an undoable command), **Play (render 2 s)** (renders the module
through `TTrackerPlayer` offline and reports peak / RMS / loop count),
**Undo / Redo**, a `Describe` + preview readout memo, and a `TPaintBox`
pattern grid (hex row numbers, `C-4 01 40 A06` cells, every-4th-row
shading, click-to-select a cell).

## Tests

`tests/Tests.Phase11.pas` (29 tests):

- **tracker.types** - note name <-> value <-> Hz (A-4 = 440, octaves
  double / halve); every effect letter round-trips.
- **tracker.model** - pattern resize keeps existing rows; the order table
  stays valid after a pattern is removed (references dropped / renumbered);
  1-based instrument slots; deep clone is independent.
- **tracker.instr** - envelope linear interpolation + clamp; MakeSine length,
  loop and root note.
- **tracker.player** - an empty module renders silence; a note plays a tone
  at the right frequency; one octave above the root doubles the pitch;
  arpeggio raises the sounding note by +x / +y on successive ticks;
  portamento up raises pitch over ticks; tone portamento glides toward the
  target without overshooting; `D02` slides volume down; `A03` / `T96` set
  speed / BPM; `B01` jumps order position; `W03` defers a note trigger; the
  song loops to the restart position (and ends when looping is off); a
  ping-pong loop stays finite and keeps sounding.
- **tracker.serialize** - a rich module (multi-channel, instrument with
  sample + envelope + fade, varied cells, multi-entry order) round-trips
  (`Describe` identical, cell fields, **sample PCM bit-exact**); an
  unsupported version and a bad effect letter raise `errConfig`; the module
  round-trips inside a project at file v4; a pre-v4 project gains a default
  module.
- **tracker.commands** - set-cell undo/redo; add/remove pattern undo/redo;
  three fast speed changes merge into one undo step; add-instrument-with-sine
  undo removes it.

## Build wiring touched

`src/tracker` added to every search path: `UDAW.dpr`, `UDAW.dproj` (path +
`DCCReference`s), `udaw.lpr`, `udaw.lpi` (x2), `tests/UDAW.Tests.dpr`,
`tests/udaw_tests.lpr`, `tests/udaw_tests.lpi`, and
`scripts/{build,test}-windows.ps1`. `Tests.Phase11` registered in both test
runners.

## Verified

Windows / Delphi 12 only: `scripts/test-windows.ps1` -> **257/257 pass**;
`scripts/build-windows.ps1` -> `UDAW.exe` builds and boots clean ("phase 11",
"Startup complete", no exceptions). The FPC leg's source wiring is kept in
parity but unrun (no FPC; Linux/macOS builds deliberately not run).

## Deferred (deliberately, per the plan's phase order)

- **MOD / XM / MPTM import + export** - Phases 12-14. They read/write their
  formats onto this module model and effect set; the pattern player is done.
- **Multisample instruments + WAV import into instruments** - plan section
  12; the instrument model is shaped for it (one sample now, layers later).
- **Routing tracker output through the mixer / a timeline tracker track** -
  the player already exposes `IAudioSource`; wiring it to a `tkTracker`
  timeline track and the Phase 9 mixer is a later integration step.
- **Sample editor** (plan section 23) - a later phase; the instrument sample
  data is fully addressable now.
- **Pattern-grid keyboard entry / cursor navigation** - the tab edits cells
  through the field row + click-select; a full keyboard tracker cursor is a
  later UI pass.
