# Phase 30 - FLAC (decoder)

A complete, from-scratch **FLAC decoder** - metadata parsing, full subframe
decode, stereo decorrelation, CRC checking, a facade, an `IAudioSource`, and a
timeline-import command - wired in exactly the way MP3 (Phase 15) was wired
in.  `UDAW_PHASE` is bumped to **30**.  The project file format is
**unchanged** (still v5): FLAC is an import/playback codec, not a persisted
document type.

**Decode-only.** There is no FLAC encoder/writer - out of scope per the task
brief. Every unit name, comment and doc section below reflects that.

## Units (`src/codecs/flac/`)

| Unit | Role |
|---|---|
| `UDAW.Codec.FLAC.Frame` | MSB-first bit reader (`TFlacBitReader`, mirrors `UDAW.Codec.MP3.Frame.TBitReader`, plus `ReadUnary`/`ReadSigned` for Rice coding); metadata-block header + STREAMINFO parse; the frame-header decode (blocking strategy, block size incl. both fixed-table and 8/16-bit escapes, sample rate incl. every "from STREAMINFO" and "N more bits follow" case, channel assignment incl. left/side, right/side, mid/side, bits-per-sample incl. "from STREAMINFO"); the UTF-8-style variable-length frame/sample-number code (genuinely unusual - not text UTF-8, the same bit-pattern scheme reused for numbers up to 36 bits, via a 7-byte extension beyond standard UTF-8's 6-byte cap); the frame header's CRC-8; and CRC-8/CRC-16 routines. `DataLooksLikeFlac`/`FileLooksLikeFlac` sniff the literal 4-byte `fLaC` magic (tolerating a leading ID3v2 tag some taggers mistakenly prepend), never the file extension. |
| `UDAW.Codec.FLAC.Decoder` | The audio pipeline: subframe decode for CONSTANT, VERBATIM, FIXED predictors (orders 0-4) and LPC (arbitrary order up to 32, quantised coefficients + shift via a correct arithmetic-right-shift helper, since Delphi/FPC's `shr` on a signed type is a *logical* shift); partitioned-Rice residual decoding (both 4-bit and 5-bit parameter variants, with the raw-bits escape code); wasted-bits-per-sample handling; all three stereo-decorrelation modes (left/side, right/side, mid/side) with reconstruction back to independent channels; and the frame footer's CRC-16 check. FLAC carries no explicit frame length in its header, so frames are found by fully decoding each one in turn - the bit position right after a frame's CRC-16 is exactly where the next frame begins. Output is the engine-wide planar Float32 layout (`TFLACDecodeResult`). |
| `UDAW.Codec.FLAC` | The single facade, mirroring `UDAW.Codec.MP3`: `FlacSniffData/FlacSniffFile`, `FlacProbe/FlacProbeFile` (STREAMINFO only, fast, no audio decode), `FlacDecode/FlacDecodeFile`, re-exporting `TFLACStreamInfo`/`TFLACDecodeResult` so callers `uses` only this unit. |
| `UDAW.Codec.FLAC.Source` | `TFLACStreamSource`, a real `IAudioSource` for playback, mirroring `TMP3StreamSource`'s constructor/`Reset`/`Render`/`Prepare` shape exactly. Unlike MP3, FLAC has no bit-reservoir / IMDCT-overlap state a seek needs to pre-roll through - each frame decodes independently - so there is no incremental, seek-aware pull decoder to reuse; the whole file is decoded once in the constructor and served from an in-memory planar buffer (a legitimate, documented tradeoff, not a stub - see the unit's header comment). |
| `UDAW.Codec.FLAC.Timeline` | `TImportFlacCommand`, a structural mirror of `TImportMp3Command`: same fields, same `Execute`/`Redo`/`Undo`/`Description`/`ResolveFile`/`DoApply` shape, same property names (`CreatedClipId`, `SourceId`, `ImportedSampleRate`, `ImportedChannels`, `ImportedLengthSeconds`), `IMP_SUBSYS = 'Codec.FLAC.Import'`. |

## Public facade API (for menu-wiring integration)

```pascal
function FlacSniffData(const AData: TBytes): Boolean;
function FlacSniffFile(const AFileName: string): Boolean;
function FlacProbe(const AData: TBytes; out AInfo: TFLACStreamInfo): Boolean;
function FlacProbeFile(const AFileName: string; out AInfo: TFLACStreamInfo): Boolean;
function FlacDecode(const AData: TBytes; out ARes: TFLACDecodeResult): Boolean;
function FlacDecodeFile(const AFileName: string; out ARes: TFLACDecodeResult): Boolean;

TFLACStreamInfo = record  // = UDAW.Codec.FLAC.Frame.TFlacStreamInfo
  SampleRate, Channels, BitsPerSample: Integer;
  TotalSamples: Int64;
  function DurationSeconds: Double;
  ...
end;

TFLACDecodeResult = record  // = UDAW.Codec.FLAC.Decoder.TFLACDecodeResult
  Channels, SampleRate, BitsPerSample: Integer;
  TotalFrames: Int64;
  Pcm: TAudioPlanar;
  ...
end;

TFLACStreamSource = class(TInterfacedObject, IAudioSource)
  constructor CreateFromData(const AData: TBytes; ALoop: Boolean = False);
  constructor CreateFromFile(const AFileName: string; ALoop: Boolean = False);
  ...
end;

TImportFlacCommand = class(TDAWCommand)
  constructor Create(ADoc: TProjectDocument; ATrackId: Integer;
    const AFilePath: string; AStartSeconds: Double; AMaxLenSeconds: Double = 0);
  ...
end;
```

## Wiring

`UDAW_PHASE` -> 30 (`src/common/UDAW.Types.pas`). All five FLAC units are
added to `UDAW.dproj` (DCCReference + unit search path) and `udaw.lpi` (Units
+ OtherUnitFiles, both build modes). `tests/Tests.PhaseFLAC.pas` is added to
both test runners (`tests/UDAW.Tests.dpr`, `tests/udaw_tests.lpr`,
`tests/udaw_tests.lpi`) and `RegisterPhaseFLACTests` is called alongside
`RegisterPhase15Tests`. (There is no `tests/UDAW.Tests.dproj` - the Delphi
test runner builds directly from the `.dpr` via `dcc64`, per its own header
comment.)

## Tests (`tests/Tests.PhaseFLAC.pas`)

Every test stream is hand-built in memory with a small MSB-first `TBitWriter`
local to the test unit (mirroring `Tests.Phase15`'s byte-by-byte header
builders) - no reference audio files, no external tools:

* **Sniffing**: rejects garbage/too-short/nil buffers; accepts the `fLaC`
  magic; and explicitly proves the sniffer ignores a `.flac` file name on a
  file with no real magic (never trust the extension).
* **Probe**: STREAMINFO fields (sample rate, channels, bits-per-sample, total
  samples, duration) read back exactly as encoded, with no audio decode.
* **Lossless round-trip** (the single most important property for a lossless
  codec): mono CONSTANT, mono FIXED order-1, independent stereo (two FIXED
  order-0 subframes), and a VERBATIM subframe all decode to the exact integer
  values that were encoded, checked against the known values within only the
  int-to-float quantisation step.
* **Stereo decorrelation**: left/side, right/side and mid/side frames each
  reconstruct the correct left/right samples from hand-picked source values
  (including the mid/side LSB-recovery step).
* **CRC handling doesn't crash**: a corrupted frame-footer CRC-16 and a
  corrupted frame-header CRC-8 are each logged (`CrcMismatches` /
  `HeaderCrcMismatches`) but do not fail the decode or corrupt the still-valid
  audio data; trailing junk after the last real frame stops the scan cleanly
  instead of raising.
* **Frame-header unit tests**: a bad sync code is rejected; a well-formed
  header (built via the 8-bit block-size escape, an explicit channel/bps code,
  and sample rate resolved from STREAMINFO) parses every field correctly and
  its CRC-8 checks out.

## Known limitations / intentionally out of scope

* **No encoder/writer.** This phase is decode-only, as scoped by the task.
* **No Ogg-FLAC container.** Only native/"raw" FLAC (magic `fLaC` + metadata
  blocks + frames) is supported, matching every other codec in this codebase
  (no third-party demuxer, and Ogg-FLAC is rare in the wild compared to native
  FLAC or FLAC-in-a-native-container).
* **32-bit-per-sample streams are read structurally** (STREAMINFO/frame-header
  parsing has no arbitrary ceiling) but are not exercised by the test suite,
  which sticks to the common 8/12/16/20/24-bit depths every real encoder
  actually emits; the integer pipeline uses `Int64` throughout so 32-bit (and
  the +1 bit a side channel needs on top of it) never overflows the sample
  type, but extreme LPC orders at 32-bit depth could in principle overflow the
  `Int64` predictor accumulator - a real-world non-issue no encoder triggers.
* **LPC shift field**: the FLAC bitstream format declares the quantised
  predictor's shift as a signed 5-bit field, but no known real encoder ever
  emits a negative shift. The decoder parses it as signed per spec and falls
  back to a shift of 0 if it is ever negative, rather than guessing a
  "correct" interpretation of an encoder bug that has never been observed.
* **Seeking** in `TFLACStreamSource` is O(1) memory-resident scrub (the whole
  file is decoded up front), not a disk-streaming design - see that unit's
  header comment for why that is a legitimate tradeoff here (FLAC frames have
  no MP3-style reservoir/overlap state to pre-roll through, so there is no
  incremental decoder worth building for this phase).
* **Vorbis comments / pictures / seek tables / cuesheets** in the metadata
  area are recognised (by block type) and skipped by length, not parsed - they
  carry no information the decoder or the timeline import needs.
