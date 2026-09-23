# Phase 16b — AAC-LC decoder

Follows Phase 16 (the MP4 *container* subsystem). Adds a from-scratch AAC-LC
decoder and the ADTS transport walk, and wires them into the MP4 facade so an
`mp4a` (AAC) sound track decodes to engine planar Float32.

Written for Delphi 12. **Unbuilt** when committed (batched under the
no-build-during-credits rule).

## Units (`src/codecs/aac/`)

| unit | contents |
|---|---|
| `UDAW.Codec.AAC.Types` | `TAacBitReader` (MSB-first), AOT / sample-rate-index tables, `TAacAudioConfig` + `ParseAudioSpecificConfig` / `BuildAudioSpecificConfig` (5/6-bit escaped AOT, frame-length flag, explicit backward-compatible SBR (AOT 5) + PS (AOT 29) and the trailing `0x2b7` sync-extension signalling) |
| `UDAW.Codec.AAC.Tables` | SWB (scalefactor window band) offset tables for 1024 & 128, keyed by sample-rate index; TNS limits; `x^(4/3)` and `2^(0.25·x)` lookups; KBD & sine analysis windows (runtime); the 12 Huffman codebooks as explicit `(length → canonical codeword)` binary trees; `HuffBooksSelfCheck` (per-book Kraft + count) |
| `UDAW.Codec.AAC.Tables` include `UDAW.Codec.AAC.HuffData.inc` | the codebook **data** — see "Huffman tables" below |
| `UDAW.Codec.AAC.Decoder` | `TAACDecoder`: `raw_data_block` → SCE/CPE/LFE/DSE/PCE/FIL (CCE parsed-and-skipped) → ICS (`global_gain`, `ics_info`, `section_data`, `scale_factor_data`, `pulse_data`, `tns_data`, `spectral_data` with escape) → inverse quant → PNS fill → TNS synthesis lattice → M/S → intensity → filterbank (O(N²) IMDCT 2048/8×256, KBD/sine window with the previous frame's shape on the left half, overlap-add) |
| `UDAW.Codec.AAC` | facade: `AacSniff*` (true ADTS syncword), `AacProbe*`, `AacDecodeAdts*`, `AacDecodeRaw(asc, accessUnits)` (the shape `UDAW.Codec.MP4` hands over), `AacTablesReady` |

`UDAW.Codec.MP4.Mp4DecodeAudio` now routes `mckAAC_LC / mckHE_AAC / mckHE_AACv2`
tracks to `AacDecodeRaw` with the track's `AudioSpecificConfig` + access units.
Other AAC profiles (Main/SSR/LD/ELD) and ALAC/AC-3 still return a precise
`errNotImplemented`.

## Huffman tables — populated

`UDAW.Codec.AAC.HuffData.inc` now carries the real ISO/IEC 14496-3:2009
Tables 4.A.1..4.A.12 data, transcribed programmatically (not retyped by hand -
the failure mode that sank the first Phase-16b attempt) from FFmpeg
`libavcodec/aactab.c`: `ff_aac_scalefactor_bits`/`ff_aac_scalefactor_code`
(book 0) and `bits1..bits11`/`codes1..codes11` (books 1-11). Both the length
and codeword columns are pasted verbatim (`AacApplyBookCodes` overwrites the
canonically-derived codes with the exact reference column for every book, not
just the non-canonical ones), so the bitstream codeword assignment matches a
real encoder bit-for-bit rather than relying on canonical re-derivation being
correct.

Two things were verified before trusting this data:
* every book's Kraft sum (`sum(2^-length)` over all codewords) equals exactly
  1.0, and the codeword count matches the ISO table size (81/81/81/81/81/81/
  64/64/169/169/289, plus 121 for the scalefactor book) - both checked by the
  extraction script *and* by `HuffBooksSelfCheck` at runtime;
* the natural nested-tuple enumeration order the length/codeword index `i`
  is assumed to follow (`i = ((w*M+x)*M+y)*M+z` for a 4-coefficient book,
  `i = y*M+z` for a 2-coefficient book) was cross-checked against FFmpeg's
  companion literal-value tables: `codebook_vector0` (book 1, 4-dim signed)
  lists entry 0 = (-1,-1,-1,-1), entry 1 = (-1,-1,-1,0), ... - the same nested
  loop, last coefficient fastest; `codebook_vector2` (book 3, 4-dim unsigned)
  lists entry 0 = (0,0,0,0), entry 1 = (0,0,0,1), entry 2 = (0,0,0,2) -
  confirming an **unsigned** book's per-axis range is magnitudes `0..LavMax`
  (`LavMax+1` values), not the symmetric `2*LavMax+1` a **signed** book uses.

That last point corrected a real bug in `AAC_HCB_META`: `ModVal` for the seven
unsigned books (3, 4, 7, 8, 9, 10, 11) had been set to `2*LavMax+1` (the signed
formula) instead of `LavMax+1`, which would have made `UnpackTuple`'s
`r mod ModVal` decompose every unsigned tuple wrong even with correct
Huffman codes. It's now `LavMax+1` for those seven books; the four signed
books (1, 2, 5, 6) were already correct.

`HuffBooksSelfCheck` now passes for all twelve books, `AacTablesReady` returns
`True`, and `AacDecodeRaw` / `Mp4DecodeAudio` no longer refuse AAC-LC content -
PCM-in-MP4, MP3-in-MP4 and AAC-LC-in-MP4 (typical `.m4a`) all decode. HE-AAC
(SBR/PS) is unaffected by this change - only the LC core reconstructs, per the
"Approximations" section below.

## Approximations (correct once tables are in, refine later)

* IMDCT is O(N²) (exact, slow) — a split-radix FFT path is a follow-up.
* `LONG_START` / `LONG_STOP` are windowed as plain long windows (correct energy,
  a small transient smear at the switch) — dedicated start/stop windows pending.
* HE-AAC: only the LC core is reconstructed; SBR/PS is the next checkpoint.
  `TAACDecodeResult.HadSBR` flags core-bandwidth-only output.
* CCE (coupling) elements end the block early rather than being applied.

## Tests — `tests/Tests.Phase16b.pas`

All pass now (they assert the stub refuses); they keep passing once the tables
are populated (the "refuses" assertions become no-ops):

* `TAacBitReader` MSB-first read / peek / byte-align / overrun;
* `AudioSpecificConfig` build↔parse + explicit SBR signalling;
* SWB tables monotonic, terminate at 1024 / 128, counts agree;
* KBD / sine windows: length, bounds, Princen–Bradley identity `w[i]² +
  w[i+N/2]² = 1` for the sine window;
* Huffman self-check reports the stub; `AacDecodeRaw` refuses with a message
  naming `HuffData.inc`;
* ADTS: a hand-built 3-frame stream is sniffed, probed (rate/channels/frame
  count) and walked.
