# Phase 15 - MP3

Complete MP3 support for the plan's section 18: **import, decode to DAW
buffers, accurate seek index, waveform-ready planar output, direct play,
render/export, and ID3 metadata read + write** - all from scratch, no LAME and
no third-party audio code.  `UDAW_PHASE` is bumped to **15**.  The project file
format is **unchanged** (still v4): MP3 is an import/export codec, not a
persisted document type.

## Units (`src/codecs/mp3/`)

| Unit | Role |
|---|---|
| `UDAW.Codec.MP3.Frame` | MSB-first bit reader; MPEG-1/2/2.5 frame-header decode (every version / layer / bitrate / sample-rate combination and every rejection path); frame-length arithmetic; Xing / Info / LAME and VBRI VBR headers; ID3v2 syncsafe envelope; whole-stream scan producing a byte-offset -> first-sample seek index; CBR/VBR classification; resync-over-garbage; signature sniffing. |
| `UDAW.Codec.MP3.Tables` | ISO/IEC 11172-3 constant data: Layer III Huffman code tables (canonical codewords assigned from FFmpeg's length/symbol lists, Kraft-equality self-checked), scalefactor-band widths, requantisation power tables, IMDCT windows + cosine basis, alias-reduction coefficients, and the 512-tap polyphase window `D[]`. |
| `UDAW.Codec.MP3.Decoder` | MPEG-1 Layer III audio decoder: bit-reservoir main-data assembly, side-info parse, scalefactor decode (long / short / mixed, scfsi sharing), Huffman decode of the three big-value regions + count1 quads, requantisation, MS / (partial) intensity stereo, alias reduction, the 18-point / 3x12-point IMDCT with overlap-add, frequency inversion, and the 32-band polyphase synthesis filterbank.  Output is engine-planar Float32.  Honours the LAME/Xing encoder delay + padding when asked.  MPEG-2/2.5 (LSF) frames are detected and reported (`SkippedLsfFrames`). |
| `UDAW.Codec.MP3.Encoder` | From-scratch MPEG-1 Layer III **encoder** - the mirror image of the decoder.  32-band polyphase analysis filterbank, forward long-block MDCT (transposed decoder basis), a global-gain bit-allocation inner loop per granule/channel, region split + Huffman table selection, count1 table pick, side-info + no-reservoir main-data assembly with fractional-slot CBR padding, and a leading Xing/"Info" header frame with a LAME-style delay tag.  CBR and (per-frame-rate) VBR.  Documented simplifications: long blocks only (no window switching), plain stereo (no MS/intensity on encode), scalefactors all zero (one quantiser step per granule), no psychoacoustic model, no bit reservoir. |
| `UDAW.Codec.MP3.Metadata` | Self-contained ID3 reader/writer: ID3v2.2/2.3/2.4 parse (syncsafe size, unsynchronisation, common text frames + COMM, Latin-1 / UTF-16 / UTF-8), ID3v1/v1.1 fallback, and a writer that emits a fresh ID3v2.3 tag + 128-byte ID3v1 trailer and splices them around the audio. |
| `UDAW.Codec.MP3` | The single facade, mirroring `UDAW.Codec.WAV`: `Mp3Sniff* / Mp3Probe* / Mp3Decode* / Mp3Encode* / Mp3ReadMetadata* / Mp3WriteMetadataFile`, re-exporting the record types so callers `uses` only this unit. |

## UI

The main window gains a design-time **MP3** tab (`tabMP3` in both
`UDAW.UI.MainForm.dfm` and `.lfm`): Import MP3 (decode + stream readout), Read
tags (ID3 v2/v1 dump), Export test tone (encode a generated stereo tone at the
chosen CBR bitrate), and Encode/decode verify (in-memory round-trip reporting
the recovered dominant frequency per channel).  All controls are placed in the
designer per the project's forms rule.

## Wiring

`UDAW_PHASE` -> 15 (`src/common/UDAW.Types.pas`).  All six MP3 units are added
to `UDAW.dpr`, `udaw.lpr`, `UDAW.dproj`, `udaw.lpi` and to both test runners
(`tests/UDAW.Tests.dpr`, `tests/udaw_tests.lpr`, `tests/udaw_tests.lpi`).

## Tests (`tests/Tests.Phase15.pas`)

The frame-layer tests (header decode across every combination, bit reader,
ID3v2 syncsafe size, Xing/Info/LAME + VBRI, whole-stream CBR/VBR scan,
resync-over-garbage, sniffing, Huffman table self-check + spot decode) are
unchanged and build their streams byte-by-byte in memory.

Added:

* **decoder conformance** (needs the ffmpeg golden fixtures in
  `tests/fixtures/`): `Test_Decode_ToneCbr` requires best-lag SNR >= 12 dB vs
  `tone_cbr128.f32` (measured **95 dB**, corr 1.000); `Test_Decode_RealExcerpt`
  requires >= 10 dB vs `real_excerpt.f32` (measured **17.6 dB**, corr 0.982);
  `Test_Decode_ToneVbr` is a spectral (dominant-frequency) check.  The former
  debug globals (`MP3DecDiag`, `MP3DbgImdct`, `MP3DbgNo*`) and the diagnostic
  sweeps have been removed from both the decoder and this test.
* **`Test_Metadata_RoundTrip`** - build an ID3v2 + ID3v1 tag, wrap a frame,
  read it back, assert the text fields survive.
* **`Test_Encode_ProducesValidStream`** - CBR encode a 1 s tone, confirm the
  output sniffs as MP3, scans, classifies as CBR at the requested rate, and
  carries an Info header frame.
* **`Test_Encode_VbrClassifies`** - VBR mode encodes and scans.
* **`Test_Encode_DecodeRoundTrip`** - encode a two-tone stereo signal, decode
  it back in memory, assert the dominant frequency per channel is recovered.

## Huffman table build (why the decoder was broken before this phase closed)

`UDAW.Codec.MP3.Tables` builds `MP3Huff[0..33]` from FFmpeg's `mpa_hufflens` /
`mpa_huffsymbols` (ISO Table B.7 lengths + symbols).  Two defects made it
decode garbage for every table past the first few:

1. `TMP3HuffTable.Codes` was `array of Word`, silently truncating the 17-19 bit
   codewords in tables 13 and 16-23.  Now `array of Cardinal`.
2. The fast decode used a canonical `FirstCode[len] + offset` index that only
   works when codewords of a given length are numerically consecutive.
   FFmpeg's canonical assignment over the ISO symbol order (roughly longest
   first, but not strictly monotonic for the big tables) does **not** produce
   consecutive-per-length codes, so the index mapped bit patterns to the wrong
   symbols.  Replaced with a plain binary decode tree (`Tree: array of
   Integer`, two ints per node, negative = packed leaf symbol) built from the
   same FFmpeg `(code, len)` pairs.  `HuffmanTablesSelfCheck` still verifies
   Kraft equality per table.

After the fix the decoder clears the conformance floors by a wide margin (see
Tests) and the from-scratch encoder's encode -> decode round-trip recovers the
input tones.

## Phase 15 follow-up (streaming source + timeline import)

Two items listed as "still open" after the codec landed are now done:

* **`TMP3StreamDecoder`** (`UDAW.Codec.MP3.Decoder`) - the per-frame pipeline is
  factored into an incremental decoder: `Open(bytes)` scans the stream,
  `DecodeNext(planar, out produced)` returns one MPEG frame of PCM at a time
  (<= 1152 samples/ch), and `SeekToSample(n)` rewinds `MP3_SEEK_PREROLL_FRAMES`
  (12) frames and decode-discards forward so the bit reservoir, IMDCT overlap
  and the synthesis V-buffers are warm at the target.  The whole-file
  `DecodeMp3` is now a thin loop over it, so both share one copy of the
  algorithm and the existing conformance tests still cover it.  A test asserts
  the incremental output is sample-identical to the whole-file path, and that a
  post-seek block reconverges to the reference (SNR).

* **`TMP3StreamSource`** (`UDAW.Codec.MP3.Source`) - a real `IAudioSource` for
  MP3.  Decodes the file through `TMP3StreamDecoder` in `Prepare` /
  construction (off the RT thread, like `TWavPlayerSource`), then serves frames
  from memory: `Render` is allocation-, lock- and IO-free, adapts the file rate
  to the buffer rate with linear interpolation, and honours `SeekSeconds` /
  `SeekFrames` issued from any thread (picked up on the next `Render` via a
  lock-free flag).  A future low-memory variant can drive `TMP3StreamDecoder`
  from a feeder thread into a `TAudioRing`.

* **`TImportMp3Command`** (`UDAW.Codec.MP3.Timeline`) - an undoable
  "import an MP3 onto the timeline" step on the shared project undo/redo stack.
  Execute probes the file (header sniff, never the extension), registers a
  de-duplicated `TMediaSource`, and adds one non-destructive clip.  Undo
  removes the clip and any source the import brought in that nothing else uses;
  Redo re-creates both with their original ids.

* MainForm **MP3** tab gains two design-time buttons: *Import to timeline...*
  (runs `TImportMp3Command`) and *Play through engine* (auditions via
  `TMP3StreamSource`).

## Known limits / follow-ups

* Encoder audio quality is bit-budget driven only (no masking model); the
  forward-MDCT level constant `MDCT_ENC_SCALE = 1/9` was confirmed by the
  round-trip test.
* Encoder: long blocks only, plain stereo, no bit reservoir - all bitstream
  fields are still valid and any compliant decoder plays the output.  A full
  psychoacoustic rebuild (ISO Model-2 masking, block switching, M/S decision,
  bit reservoir, rate-distortion loops) is a separate follow-up checkpoint.
* Decoder intensity stereo uses the conservative "mirror the zero region"
  rule; full IS position tables remain a documented deferral.
* MPEG-2/2.5 LSF decode/encode is out of scope for Phase 15 (32/44.1/48 kHz).
