# Phase 14 - MPTM Support

Status: **implemented and passing** (295/295 acceptance tests as originally
shipped; +4 more added for IT2.14/IT2.15 sample decompression, see below,
Delphi 12 / Win64 - not yet rebuilt/reverified after that addition). The
Windows executable builds with the MPTM codec linked, boots clean (log shows
`phase 14`, `Startup complete`, no exceptions) and the **Tracker** tab gains
**Import .mptm** / **Export .mptm**. The project file format is **unchanged**
(still v4) - an imported MPTM is a `TTrackerModule` and serialises through the
existing `TRACKER` section.

Phase 14 delivers the plan's MPTM support (section 16 + phase line 14):
**"a supported MPTM compatibility layer with exhaustive validation / testing"**,
built from scratch (the plan forbids OpenMPT). Per the plan, this is
deliberately a *supported subset*, not a claim of full OpenMPT
feature-parity - the emphasis is on **safety and validation**.

## What MPTM actually is

On disk, an `.mptm` file is the **Impulse Tracker container** (`IMPM`
signature) extended with trailing OpenMPT extension chunks. Every MPTM file
therefore carries a complete IT core; this unit implements a strict,
bounds-checked reader / writer over that IT core and **recognises but does
not interpret** the trailing OpenMPT chunks - they can never steer an
allocation or a read. Plain `.it` files load through the same path.

## Layout

```
src/codecs/tracker/
  UDAW.Codec.MPTM.pas        The whole codec. The plan names TMPTMReader /
                             TMPTMWriter / TMPTMModule / TMPTMPattern /
                             TMPTMInstrument / TMPTMSample; the parsed views
                             (TMPTMSample / TMPTMInstrument / TMPTMEnvelope /
                             TMPTMImportInfo) are records over the Phase 11
                             engine, and the reader / writer are:

   DataLooksLikeMptm / FileLooksLikeMptm / MptmKindFromData
        Header sniffing that never looks at the file extension (plan
        section 20). Requires the `IMPM` magic and sane OrdNum / InsNum /
        SmpNum / PatNum counts whose offset tables fit inside the file.

   MptmToModule(bytes [, out TMPTMImportInfo]) : TTrackerModule   (TMPTMReader)
        Parses the 192-byte IT header, the order table, and the
        instrument / sample / pattern dword offset tables (every table
        bounds-checked against Int64 file length). Handles:
          * "instrument mode" (flag bit 2) -> one TTrackerInstrument per IT
            instrument, backed by the sample its middle-C key maps to, with
            volume / panning envelopes (sustain + loop points) and volume
            fade-out;
          * "sample mode" -> one TTrackerInstrument per IT sample;
          * the IT packed pattern format with per-channel mask / last-value
            memory (note, instrument, volume, command, param), every byte
            read guarded against the packed length;
          * uncompressed 8-bit and 16-bit samples, signed or unsigned,
            optional delta encoding, big-endian 16-bit, forward / ping-pong
            loops; **IT2.14 / IT2.15-compressed samples are decoded**
            (`CompressedSamples` still counts them) via a from-scratch,
            bounds-checked implementation of the IT variable-width delta
            bitstream - single delta (`cwtv < $215`) or double delta
            (`cwtv >= $215`);
          * the IT effect column (A..Z incl. the `Sxy` special set) and the
            IT volume column.
        Caps (allocation limits, plan section 16): file 64 MB, channels 64,
        orders / instruments / samples / patterns 240-256, rows 1024, a
        sample 16 M frames. A short / hostile file is clamped and flagged
        `Truncated`, or rejected with `errConfig` - never a crash, never OOM,
        never an out-of-range read.

   ModuleToMptm(module) : TBytes   /   SaveMptmFile   (TMPTMWriter)
        Emits a plain IT-compatible core (sample mode, `cmwt` 2.14): 192-byte
        header, order table, sample + pattern offset tables, 80-byte `IMPS`
        sample headers, IT-packed patterns (one fresh mask byte per cell -
        always valid), 8-bit signed PCM. Notes -> IT note values
        (C-5 = 60 = internal 61), effects -> the IT command column,
        set-volume carried through the volume column. No OpenMPT extension
        chunks, no plugins, no tempo swing.

   MptmExportIssues(module) : TArray<string>
        Lists limits exceeded, effects with no IT equivalent, and always
        notes that export writes a plain IT core. Shown in a confirm dialog.
```

`UDAW.Tracker.Commands` gains **`TImportMptmCommand`** - a structural
(snapshot) undo command that replaces the project's tracker module with one
parsed from MPTM/IT bytes; undo restores the previous module.

## Pitch model

Each IT sample's `C5Speed` is its playback rate for note C-5, baked into the
instrument: `RootNote = 61` (internal C-5), `SampleRate = C5Speed`. IT
pattern note *n* (0..119, middle C = 60) maps to internal note *n + 1*; IT
255 -> `TRK_NOTE_OFF`, 254 -> `TRK_NOTE_CUT`, 253 -> `TRK_NOTE_OFF`. The
linear model is used throughout.

## Effect + volume columns

The IT command column (index 1..26 = `A`..`Z`) and the IT volume column both
map onto UDAW's internal effect set:

| IT | internal | IT | internal |
|----|----------|----|----------|
| `A` set speed | `tfxSetSpeed` | `O` sample offset | `tfxSampleOffset` |
| `B` position jump | `tfxPositionJump` | `P` panning slide | `tfxPanSlide` |
| `C` pattern break | `tfxPatternBreak` (**plain**, not BCD) | `Q` retrigger | `tfxRetrigger` |
| `D` volume slide | `tfxVolSlide` | `R` tremolo | `tfxTremolo` |
| `E` / `F` porta down/up | `tfxPortaDown` / `tfxPortaUp` | `S8x` pan / `SCx` cut / `SDx` delay | `tfxSetPanning` / `tfxNoteCut` / `tfxNoteDelay` |
| `G` tone porta | `tfxTonePorta` | `T` tempo (>=`20`) | `tfxSetBPM` |
| `H` / `U` vibrato | `tfxVibrato` | `X` set panning | `tfxSetPanning` |
| `J` arpeggio | `tfxArpeggio` | `K` / `L` vib/porta + volslide | `tfxVibrato` / `tfxTonePorta` (slide dropped) |

Volume column: `0..64` -> set volume; `128..192` -> set panning;
`65..104` -> fine / normal volume slides; `193..212` -> tone porta / vibrato.

`I` tremor, `M/N` channel volume, `V/W` global volume, `Y` panbrello,
`Z` MIDI macro, the `S` sub-commands other than `8/C/D`, and IT tempo
slides have no internal equivalent: dropped and **counted** in
`TMPTMImportInfo.LostEffectCells`.

## Tracker tab (design-time)

Two buttons added to `pnlTrkTop` at design time in `UDAW.UI.MainForm.dfm` /
`.lfm` plus `dlgOpenMptm` / `dlgSaveMptm` (project rule 23), next to the
Phase 13 `.xm` pair:

- **Import .mptm** - `TOpenDialog` (`*.mptm;*.it`), `FileLooksLikeMptm`
  guard, parses once for the report, then imports via `TImportMptmCommand`
  (undoable). The readout memo shows `TMPTMImportInfo.Summary` (mode,
  channels, patterns, instruments, samples used, compressed skipped, orders,
  cell / note / effect counts, dropped-effect count, trailing-extension byte
  count, truncation note).
- **Export .mptm** - runs `MptmExportIssues` first; a Yes/No dialog lists
  every note before `SaveMptmFile` writes the file.

## Tests

`tests/Tests.Phase14.pas` (11 tests), building sample-mode IT/MPTM byte
buffers in memory:

- **mptm.sniff** - a generated buffer sniffs as `IMPM`; an all-zero buffer
  does not.
- **mptm.import** - 6-channel structure (channel count from the pattern
  scan, patterns, order length, instrument slot, title, sample length +
  forward loop, IT note 60 -> internal C-5, sample reference); sample-mode
  detected; the effect column incl. non-BCD pattern break, `S C4` note cut,
  `X` set panning, `V` dropped-and-counted, and the volume column
  (set-volume + set-panning).
- **mptm.import / rejects garbage** - a non-`IMPM` buffer raises `errConfig`.
- **mptm.import / malformed files stay safe** - a truncated file, a file
  with a `0x7FFFFFFF` declared sample length, and a header claiming 9999
  patterns all either build a clamped module or raise `EUDAWError` - never a
  crash or an unbounded allocation.
- **mptm.import / IT2.14 and IT2.15 compressed sample decode** - a hand-built
  single-block compressed sample (raw width-9 codes, so the bit-reader and
  delta accumulation are exercised directly) decodes to the exact expected
  PCM values for both the single-delta (`cwtv` `$0214`) and double-delta
  (`cwtv` `$0215`) schemes, including unsigned wraparound past 256 and a
  wrap to a negative sample.
- **mptm.import / truncated compressed sample stays safe** - a compressed
  block whose declared length runs past EOF is clamped and zero-padded, not
  a crash.
- **mptm.play** - an imported MPTM renders a finite tone at ~441 Hz through
  `TTrackerPlayer`; one octave lower halves the measured frequency.
- **mptm.export** - byte-level round trip (channels, pattern / order counts,
  cell notes + instruments, arpeggio and pattern-break effects, sample
  length).
- **mptm.export / representability report** - notes that export is a plain
  IT core.
- **mptm.cmd** - `TImportMptmCommand` undo restores the previous module and
  redo re-imports; an imported module round-trips inside a saved project.

## Build wiring touched

`UDAW.Codec.MPTM` added to: `UDAW.dpr`, `UDAW.dproj` (`DCCReference`),
`udaw.lpr`, `udaw.lpi` (unit entry), `tests/UDAW.Tests.dpr`,
`tests/udaw_tests.lpr`, `tests/udaw_tests.lpi`. `src/codecs/tracker` was
already on every search path, so the build scripts were not touched.
`Tests.Phase14` registered in both test runners. `UDAW_PHASE` -> 14.

## Verified

Windows / Delphi 12 only: `scripts/test-windows.ps1` -> **295/295 pass**;
`scripts/build-windows.ps1` -> `UDAW.exe` builds and boots clean
(`phase 14`, `Startup complete`, no exceptions). The FPC leg's source wiring
is kept in parity but unrun. **The IT2.14/IT2.15 decompression added after
that verification run has not yet been rebuilt/retested - checkpoint before
trusting it in the running app.**

## Deferred (deliberately, per the plan's "supported compatibility layer")

- **Stereo compressed samples** - like the existing uncompressed-PCM path,
  only the left/mono-equivalent channel stream is decoded; this mirrors a
  pre-existing simplification (`TTrackerInstrument` holds one channel of
  data) rather than a new gap introduced by decompression.
- **OpenMPT extension chunks** - tempo swing, per-channel / per-instrument
  plugins, extended pattern data, MIDI mapping, the > 64-channel MPTM
  extension, resampling / filter modes. Recognised as trailing bytes and
  reported (`ExtensionBytes`); never parsed.
- **IT NNA / duplicate-check / pitch envelopes / channel & track volume /
  the full `Sxy` set / MIDI macros** - the Phase 11 replay core has no state
  for these; the commands are dropped and counted.
- **Old (pre-2.00) IT instrument layout** - the new `IMPI` layout is parsed;
  every MPTM and virtually every IT2 file uses it.
- **Instrument-mode note translation table** - the importer uses the played
  note directly with the middle-C sample rather than the per-instrument
  note/transpose map.
- **Routing the tracker player through the mixer / a timeline track** - the
  same open integration step noted in Phase 11.
