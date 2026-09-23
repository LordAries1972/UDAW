# Phase 12 - MOD Support

Status: **implemented and passing** (271/271 acceptance tests: 257 from
Phases 1-11 + 14 Phase 12, Delphi 12 / Win64). The Windows executable builds
with the MOD codec linked, boots clean (log shows "phase 12", "Startup
complete", no exceptions) and the **Tracker** tab gains **Import .mod** /
**Export .mod**. `UDAW_PHASE` is bumped to 12. The project file format is
**unchanged** (still v4) - an imported MOD is a `TTrackerModule` and
serialises through the existing `TRACKER` section.

Phase 12 delivers the plan's MOD support (section 15 + phase line 12):
ProTracker / Soundtracker `.mod` **import, play, edit and export**, built
from scratch (the plan forbids OpenMPT). A MOD is parsed onto the Phase 11
tracker engine - a first-class module/pattern model with real tracker replay
- **not** flattened into ordinary audio clips.

## Layout

```
src/codecs/tracker/
  UDAW.Codec.ProTracker.pas   The whole codec (named ProTracker, not "MOD",
                              because MOD is a Delphi keyword):

   ModKindFromData / DataLooksLikeMod / FileLooksLikeMod
        Header sniffing that never looks at the file extension (plan
        section 20). A recognised 4-char tag at offset 1080 -> 31-sample;
        otherwise a sanity-checked song-length + order table at offset 470
        -> 15-sample (Soundtracker); else "not a MOD".

   ModToModule(bytes [, out TModImportInfo]) : TTrackerModule
        The reader. Handles the 15-sample (no tag) and 31-sample layouts;
        tags M.K. M!K! M&K! FLT4 FLT8 4CHN 6CHN 8CHN OCTA OKTA CD81 and the
        generic "nnCH" / "nCHN" (1..32 channels). Parses the 20-char title,
        22-char sample names, sample headers (length, signed-nibble
        finetune, volume, loop start / length - all big-endian word
        counts), 8-bit signed PCM, forward loops, the order table and the
        restart position. Pattern count is taken from the order table.
        Every offset is bounds-checked; a short file is zero-padded and
        flagged, never allowed to read out of range; file size is capped at
        32 MB, channels at 32, patterns at 128, a sample at 128 KB.

   ModuleToMod(module) : TBytes   /   SaveModFile
        The writer. Emits a 31-sample module: M.K. for 4 channels, "nCHN" /
        "nnCH" otherwise. Notes -> Amiga periods, effects -> the MOD effect
        column, Float32 PCM -> 8-bit signed, forward loops -> loop
        start/length words, order table + restart byte. Always best-effort:
        anything the module cannot express is clamped, and

   ModExportIssues(module) : TArray<string>
        lists it first (too many instruments / channels / patterns, a
        non-64-row pattern, notes outside C-3..B-5, effects with no MOD
        equivalent, an over-long sample). The Tracker tab shows these in a
        confirm dialog before writing.
```

`UDAW.Tracker.Commands` gains **`TImportModCommand`** - a structural
(snapshot) undo command that replaces the project's tracker module with one
parsed from MOD bytes; undo restores the previous module.

## Pitch model

Notes resolve through an Amiga period table rather than a fixed frequency
map, so the Phase 11 player reproduces Amiga playback:

- `MOD_C3_RATE = 8363 Hz` is the rate a finetune-0 sample streams at for the
  reference note (ProTracker period ~428). One finetune step is 1/8
  semitone.
- `ModNoteFreq(i, ft) = 8363 * 2^((i - 12)/12 + ft/96)` over the 36-note
  range (3 octaves, periods ~856..113); `ModNotePeriod = 7093789.2 / (2*f)`
  (PAL colour clock).
- On import each MOD sample becomes one `TTrackerInstrument` (slot *n* =
  MOD sample *n*, so cell instrument numbers line up 1:1) with
  `RootNote = C-4` and `SampleRate = 8363 * 2^(finetune/96)` - the finetune
  is baked into the sample rate, so a plain equal-tempered cell note plays
  the right Amiga pitch. MOD note index 0 -> UDAW note value 37 (C-3).
- `ModPeriodToNoteIndex` picks the nearest table entry, so odd periods and
  out-of-range values degrade gracefully instead of raising.

## Effect column

MOD's command column (incl. the `Exy` extended set) maps onto UDAW's
internal effect set (`UDAW.Tracker.Types`):

| MOD | internal | MOD | internal |
|-----|----------|-----|----------|
| `0xy` arpeggio | `tfxArpeggio` | `A` volume slide | `tfxVolSlide` |
| `1` porta up | `tfxPortaUp` | `B` position jump | `tfxPositionJump` |
| `2` porta down | `tfxPortaDown` | `C` set volume | `tfxSetVolume` |
| `3` tone porta | `tfxTonePorta` | `D` pattern break | `tfxPatternBreak` (BCD -> row) |
| `4` vibrato | `tfxVibrato` | `E1/E2` fine porta | `tfxPortaUp/Down` |
| `5` toneporta+volslide | `tfxTonePorta` (slide dropped) | `E8` pan | `tfxSetPanning` |
| `6` vibrato+volslide | `tfxVibrato` (slide dropped) | `E9` retrigger | `tfxRetrigger` |
| `7` tremolo | `tfxTremolo` | `EA/EB` fine volume | `tfxFineVolUp/Down` |
| `8` set pan | `tfxSetPanning` | `EC` note cut | `tfxNoteCut` |
| `9` sample offset | `tfxSampleOffset` | `ED` note delay | `tfxNoteDelay` |
| `F` speed / tempo | `tfxSetSpeed` (<`20` speed, >=`20` BPM - same as MOD) | | |

`E0` filter, `E3` glissando, `E4/E7` waveforms, `E5` finetune (baked in),
`E6` pattern loop, `EE` pattern delay, `EF` invert loop and the volume-slide
half of `5`/`6` have no single-command internal equivalent: they are dropped
and **counted** in `TModImportInfo.LostEffectCells` (surfaced in the import
report), never guessed at. The writer's reverse map also emits `tfxSetBPM`
as `Fxx` (tempo range) and drops `tfxPanSlide` (no MOD equivalent).

## Tracker tab (design-time)

Two buttons added to `pnlTrkTop` at design time in `UDAW.UI.MainForm.dfm` /
`.lfm` plus `dlgOpenMod` / `dlgSaveMod` (project rule 23):

- **Import .mod** - `TOpenDialog`, `FileLooksLikeMod` guard, parses once for
  the report, then imports via `TImportModCommand` (undoable). The readout
  memo shows `TModImportInfo.Summary` (kind, tag, title, channels, samples
  used, patterns, orders, cell/note/effect counts, dropped-effect count,
  truncation note).
- **Export .mod** - runs `ModExportIssues` first; if non-empty, a
  Yes/No dialog lists every issue before `SaveModFile` writes the file.

The existing pattern grid, cell editor, transport, play and undo/redo all
operate on the imported module unchanged.

## Tests

`tests/Tests.Phase12.pas` (14 tests), building `.mod` byte buffers in memory:

- **mod.sniff** - a generated buffer sniffs as a 31-sample MOD; an all-zero
  buffer does not.
- **mod.import** - 31-sample structure (6-channel `6CHN` layout: channels,
  patterns from the order table, order length, 31 instrument slots, title,
  sample length + whole-sample forward loop, reference note -> C-4, sample
  reference); 15-sample Soundtracker layout (no tag, always 4 channels, 15
  slots); the full effect column incl. BCD pattern break, `F` speed vs
  tempo, `EC`/`EA` extended commands and a dropped `E3x` counted in the
  report; garbage raises `errConfig`; a truncated file still yields a
  usable module.
- **mod.period** - reference period ~428, an octave halves the period,
  period -> note-index round-trips, positive finetune shortens the period.
- **mod.play** - an imported MOD renders a finite tone at ~441 Hz through
  `TTrackerPlayer`; one octave lower halves the measured frequency.
- **mod.export** - byte-level round trip (channels, pattern / order counts,
  instrument slots, cell notes + instruments, set-volume and pattern-break
  effects incl. the BCD trip, sample length in whole words, sample volume);
  PCM survives export within 8-bit quantisation (<= 1 LSB); the
  representability report fires for >31 instruments, a 32-row pattern and a
  `tfxPanSlide`, and is empty for a clean 4-channel / 64-row module.
- **mod.cmd** - `TImportModCommand` undo restores the previous module and
  redo re-imports; an imported module round-trips inside a saved project.

## Build wiring touched

`src/codecs/tracker` added to every search path: `UDAW.dpr`, `UDAW.dproj`
(path + `DCCReference`), `udaw.lpr`, `udaw.lpi` (x2 + unit entry),
`tests/UDAW.Tests.dpr`, `tests/udaw_tests.lpr`, `tests/udaw_tests.lpi`, and
`scripts/{build,test}-windows.ps1` / `scripts/test-{linux,macos}.sh`.
`Tests.Phase12` registered in both test runners. `UDAW_PHASE` -> 12.

## Verified

Windows / Delphi 12 only: `scripts/test-windows.ps1` -> **271/271 pass**;
`scripts/build-windows.ps1` -> `UDAW.exe` builds and boots clean ("phase
12", "Startup complete", no exceptions). The FPC leg's source wiring is kept
in parity but unrun (no FPC; Linux/macOS builds deliberately not run).

## Deferred (deliberately, per the plan's phase order)

- **XM / MPTM import + export** - Phases 13-14, onto the same module model
  and effect set.
- **Faithful ProTracker E6 pattern-loop / EE pattern-delay playback** - the
  Phase 11 replay core has no pattern-loop or row-delay state; these MOD
  commands are dropped on import and reported.
- **Exact ProTracker period table + Amiga hardware quirks** (Paula
  resampling, blep, the classic period-table rounding) - Phase 12 uses an
  equal-tempered period model with the finetune baked into the sample rate,
  which is within a few cents and is what linear-frequency importers do.
- **Routing the tracker player through the mixer / a timeline track** - the
  same open integration step noted in Phase 11.
