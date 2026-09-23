# Phase 13 - XM Support

Status: **implemented and passing** (295/295 acceptance tests: 271 from
Phases 1-12 + **13 Phase 13** + 11 Phase 14, Delphi 12 / Win64; run
`scripts/test-windows.ps1`). The Windows executable builds with the XM codec
linked, boots clean (log shows
`phase 14`, `Startup complete`, no exceptions) and the **Tracker** tab gains
**Import .xm** / **Export .xm**. The project file format is **unchanged**
(still v4) - an imported XM is a `TTrackerModule` and serialises through the
existing `TRACKER` section.

Phase 13 delivers the plan's XM support (section 14 + phase line 13):
FastTracker 2 Extended Module **import, play, edit and export**, built from
scratch (the plan forbids OpenMPT). An XM is parsed onto the Phase 11 tracker
engine - a first-class module / pattern model with real tracker replay -
**not** flattened into ordinary audio clips.

## Layout

```
src/codecs/tracker/
  UDAW.Codec.XM.pas          The whole codec:

   DataLooksLikeXm / FileLooksLikeXm / XmKindFromData
        Header sniffing that never looks at the file extension (plan
        section 20). Requires the 17-byte "Extended Module: " magic and the
        mandatory 0x1A after the 20-char module name.

   XmToModule(bytes [, out TXmImportInfo]) : TTrackerModule
        The reader. Handles the v1.02 / v1.03 / v1.04 layouts; up to 32
        channels, 256 patterns, 128 instruments. Parses the fixed + variable
        header (header-size field bounds-checked), the FT2 packed pattern
        format (bit-7 mask bytes + literal rows), per-instrument sample
        keymap, volume / panning envelopes with sustain + loop points,
        volume fade-out, and per-sample volume / finetune / relative note /
        panning / forward + ping-pong loops / 8-bit and 16-bit delta PCM.
        Every offset is bounds-checked; a short file yields the patterns it
        can and is flagged `Truncated`, never read out of range. File size
        is capped at 32 MB, a sample at 8 MB, rows at 256.

   ModuleToXm(module) : TBytes   /   SaveXmFile
        The writer. Emits a v1.04 module: linear frequency table, one sample
        per instrument, patterns written **unpacked** (literal note bytes -
        always valid), notes -> XM note values (C-0 = 1 = internal C-0),
        effects -> the FT2 effect column, Float32 PCM -> 8-bit signed delta,
        forward / ping-pong loops -> loop start / length, relative note from
        the instrument root. Always best-effort; anything the module cannot
        express is clamped, and

   XmExportIssues(module) : TArray<string>
        lists it first (too many instruments / channels / patterns, a
        pattern over 256 rows, notes above B-7, effects with no XM
        equivalent). The Tracker tab shows these in a confirm dialog before
        writing.

   XmSampleRate(relativeNote, finetune) : Integer
        Exposed for the tests: 8363 * 2^(rel/12 + ft/(128*12)).
```

`UDAW.Tracker.Commands` gains **`TImportXmCommand`** - a structural (snapshot)
undo command that replaces the project's tracker module with one parsed from
XM bytes; undo restores the previous module.

## Pitch model

Relative note + finetune are baked into each instrument, so a plain
equal-tempered cell note reproduces FT2 pitch:

- `RootNote = 49` (C-4). `SampleRate = 8363 * 2^((relnote + finetune/128)/12)`.
  Playback rate for a cell note *N* is then `SampleRate * 2^((N - 49)/12)` =
  `8363 * 2^((N + relnote - 49 + finetune/128)/12)`, which is FT2's linear
  model. XM note value 1 = C-0 maps straight onto the internal note scheme
  (also C-0 = 1); XM key-off (97) -> `TRK_NOTE_OFF`.
- Only the linear frequency table is modelled (a few cents from the Amiga
  table, as with the Phase 12 MOD importer).

## Effect + volume columns

FT2's effect column (incl. the `Exy` extended set) and the FT2 **volume
column** both map onto UDAW's internal effect set (`UDAW.Tracker.Types`):

| XM | internal | XM | internal |
|----|----------|----|----------|
| `0xy` arpeggio | `tfxArpeggio` | `A` volume slide | `tfxVolSlide` |
| `1` / `2` porta up/down | `tfxPortaUp` / `tfxPortaDown` | `B` position jump | `tfxPositionJump` |
| `3` tone porta | `tfxTonePorta` | `C` set volume | `tfxSetVolume` |
| `4` vibrato | `tfxVibrato` | `D` pattern break | `tfxPatternBreak` (BCD -> row) |
| `5` / `6` porta/vib + volslide | `tfxTonePorta` / `tfxVibrato` (slide dropped) | `E1/E2` fine porta | `tfxPortaUp/Down` |
| `7` tremolo | `tfxTremolo` | `E9` retrigger | `tfxRetrigger` |
| `8` set panning | `tfxSetPanning` | `EA/EB` fine volume | `tfxFineVolUp/Down` |
| `9` sample offset | `tfxSampleOffset` | `EC` / `ED` note cut / delay | `tfxNoteCut` / `tfxNoteDelay` |
| `F` speed / tempo | `tfxSetSpeed` (<`20` speed, >=`20` BPM) | `P` panning slide | `tfxPanSlide` (nibbles swapped) |
| `R` multi-retrig | `tfxRetrigger` | `X1/X2` extra-fine porta | `tfxPortaUp/Down` |

Volume column: `0x10..0x50` -> set volume 0..64; `0x60..0x9F` -> volume
slides; `0xA0..0xBF` -> vibrato speed / depth; `0xC0..0xCF` -> set panning;
`0xD0..0xEF` -> pan slides; `0xF0..0xFF` -> tone portamento. The effect
column wins when both are present.

`E3` glissando, `E4/E7` waveforms, `E5` finetune (baked in), `E6` pattern
loop, `EE` pattern delay, `G/H` global volume, `L` set envelope position,
`T` tremor, `Y` panbrello and the volume-slide half of `5`/`6` have no
single-command internal equivalent: they are dropped and **counted** in
`TXmImportInfo.LostEffectCells` (surfaced in the import report), never
guessed at.

## Tracker tab (design-time)

Four buttons added to `pnlTrkTop` at design time in
`UDAW.UI.MainForm.dfm` / `.lfm` plus `dlgOpenXm` / `dlgSaveXm` (and the
Phase 14 `.mptm` pair) - `pnlTrkTop` grew to 140 px, `pbTracker` shifted
down (project rule 23):

- **Import .xm** - `TOpenDialog`, `FileLooksLikeXm` guard, parses once for
  the report, then imports via `TImportXmCommand` (undoable). The readout
  memo shows `TXmImportInfo.Summary`.
- **Export .xm** - runs `XmExportIssues` first; if non-empty, a Yes/No
  dialog lists every issue before `SaveXmFile` writes the file.

The existing pattern grid, cell editor, transport, play and undo/redo all
operate on the imported module unchanged.

## Tests

`tests/Tests.Phase13.pas` (13 tests), building `.xm` byte buffers in memory:

- **xm.sniff** - a generated buffer sniffs as an XM; an all-zero buffer does
  not.
- **xm.import** - 6-channel structure (channels, patterns, order length,
  instrument slot, title, sample length + forward loop, C-4 note value 49);
  the effect column incl. BCD pattern break, `F` speed, `EC`/`EA` extended
  commands, `P` nibble swap and a dropped `G` counted in the report; a
  hand-built volume-column set-volume; garbage raises `errConfig`; a
  truncated file still yields a usable module.
- **xm.rate** - `XmSampleRate` for relnote 0 / +12 / finetune +128.
- **xm.play** - an imported XM renders a finite tone at ~441 Hz through
  `TTrackerPlayer`; one octave lower halves the measured frequency.
- **xm.export** - byte-level round trip (channels, pattern / order counts,
  cell notes + instruments, set-volume and pattern-break effects incl. the
  BCD trip, sample length); the representability report fires for a note
  above B-7 and is empty for a clean module.
- **xm.cmd** - `TImportXmCommand` undo restores the previous module and redo
  re-imports; an imported module round-trips inside a saved project.

## Build wiring touched

`UDAW.Codec.XM` added to: `UDAW.dpr`, `UDAW.dproj` (`DCCReference`),
`udaw.lpr`, `udaw.lpi` (unit entry), `tests/UDAW.Tests.dpr`,
`tests/udaw_tests.lpr`, `tests/udaw_tests.lpi`. `src/codecs/tracker` was
already on every search path (Phase 12), so the build scripts were not
touched. `Tests.Phase13` registered in both test runners. `UDAW_PHASE` -> 14
(shared with Phase 14).

## Verified

Windows / Delphi 12 only: `scripts/test-windows.ps1` -> **295/295 pass**
(271 + 13 Phase 13 + 11 Phase 14); `scripts/build-windows.ps1` -> `UDAW.exe`
builds and boots clean (`phase 14`, `Startup complete`, no exceptions). The
FPC leg's source wiring is kept in parity but unrun (no FPC; Linux/macOS
builds deliberately not run).

## Deferred (deliberately)

- **Multi-sample instrument keymaps** - the Phase 11 instrument model is one
  mono sample per slot; the importer picks the sample the C-4 key maps to.
  Full keymap playback is the same later step noted in Phase 11.
- **Amiga (non-linear) frequency table**, FT2 auto-vibrato, envelope loop
  playback (the replay core has sustain but not env loop), and the
  volume-slide continuation of `5xy`/`6xy`.
- **Packed pattern output** - the writer emits valid unpacked patterns;
  RLE-style packing is a size optimisation, not correctness.
- **Routing the tracker player through the mixer / a timeline track** - the
  same open integration step noted in Phase 11.
