# Phase 15 - MP3 Decoder (bring-up note)

Status: **decoder conformance bug found and fixed by source review on
2026-09-10; not yet built/verified.** This note records the analysis so it is
not lost. The full Phase 15 doc (`docs/Phase15-MP3.md`) will be written when the
phase is complete (encoder + facade + UI still outstanding).

## The bug: broken scfsi scalefactor sharing

`UDAW.Codec.MP3.Decoder` decodes each frame as four granule/channel units
(gr0ch0, gr0ch1, gr1ch0, gr1ch1). For **granule 1, long blocks**, MPEG-1
Layer III lets the encoder signal (via the 4 `scfsi` bits per channel) that a
group of scalefactor bands is **shared from granule 0** - those bands carry no
bits in granule 1 and the decoder must reuse granule 0's values.

`DecodeGranuleChannel` implemented this by seeding the working buffer:

```pascal
if AGr = 1 then sf := ASfPrev else FillChar(sf, SizeOf(sf), 0);
sfBits := ReadScalefactors(..., sf);
```

but `ReadScalefactors` opened with:

```pascal
FillChar(ASF, SizeOf(ASF), 0);   // <-- wiped the granule-0 seed
```

and then, for each shared band group:

```pascal
Continue;   // "shared: keep granule 0's value (caller preserves)"
```

Because the seed had just been zeroed, every scfsi-shared band in granule 1
was left at **scalefactor 0** instead of granule 0's value. A wrong scalefactor
scales the requantised spectrum of that band by `2^(sfMul * sf)` too much, so
granule 1's audio had the wrong gain in those bands - a discontinuity at every
576-sample granule boundary.

### Why the symptoms matched

| Observation | Explanation |
|---|---|
| Tone: best-lag xcorr ~0.89, SNR ~3 dB | LAME sets scfsi aggressively when gr0 == gr1 (steady signal), so granule 1 was wrong in *every* frame -> a periodic seam every 576 samples -> broadband-ish error, fundamental still intact. |
| Real music: xcorr ~0.47 | scfsi used less uniformly and across more bands -> larger, less periodic error. |
| Antialias / freq-inv / reorder toggles inert | The defect is in requantisation input, upstream of all three. |
| Disabling MS stereo made music *worse* | MS was already correct; removing it only removed a correct step. |
| IMDCT / requant / Huffman spot-checks passed | They were checked with correct inputs; the scalefactor for a *shared* band in granule 1 was never in the spot sample. |

## The fix (2 edits, `UDAW.Codec.MP3.Decoder.pas`)

1. **`ReadScalefactors`** - removed the opening `FillChar(ASF, SizeOf(ASF), 0)`.
   The function now only ever *writes* the bands it reads and *preserves*
   everything else, which is exactly what the scfsi `Continue` path needs. A
   comment records why it must not clear.

2. **`DecodeGranuleChannel`** - made the seed explicit and total on both paths:

   ```pascal
   FillChar(sf, SizeOf(sf), 0);
   if AGr = 1 then sf := ASfPrev;
   ```

   Granule 0 starts from zero; granule 1 starts from granule 0's scalefactors.
   Non-shared bands are overwritten with freshly read values inside
   `ReadScalefactors`; shared bands keep the granule-0 value. Safe for the
   granule-1 short-block path too: `ASF.S[w,12]` and the unused `ASF.L[]`
   entries are only ever read after `Requantize`, and granule 0 never writes
   them, so they are guaranteed 0.

## Rest of the pipeline - re-verified this pass

Re-checked line-by-line against **pdmp3** (technosaurus/PDMP3) *and* raw
**ISO/IEC 11172-3**, all bit-faithful, no other defect found by inspection:

- reservoir main-data assembly (`main_data_begin` back-pointer, per-granule
  `part2_3` bit accumulation, `endBit` alignment);
- side info parse; scalefactor `slen1/slen2` table (ISO Table B.4) and the
  0-5 / 6-10 / 11-15 / 16-20 scfsi band groups;
- Huffman big-values (region boundaries in `is[]` units, `linbits` then sign
  order) and count1 quads (tables 32/33, `vwxy` bit unpack);
- requantise: `2^(0.25*(global_gain-210))`, `sfMul` 0.5 / 1.0 by
  `scalefac_scale`, `preflag*PRETAB`, `|is|^(4/3)`, per-subblock gain for
  shorts;
- antialias butterfly (`ALIAS_CS/CA`, 8 taps per subband boundary);
- IMDCT: `cos(pi/72 * (2k+1+18) * (2i+1))`, all four windows (normal / start /
  short / stop), 3x12 path for `block_type = 2`, no `2/N` normalisation
  (folded into `D[]`, same as pdmp3);
- overlap-add (first 18 + carry, save last 18); frequency inversion (negate
  odd `i` of odd subbands);
- polyphase synthesis: `N[i,k] = cos((16+i)(2k+1)pi/64)`, V ring-buffer
  emulation of the 1024-tap shift, U-vector fold `V[i*128+j]` /
  `V[i*128+96+j]`, `D[j+32i]` window (peak `1.144989014` at `D[256]`), 16-tap
  sum. Output is engine-planar Float32.

## Verify

Build and run `Tests.Phase15`:

- `Test_Decode_ToneCbr` requires best-lag SNR **>= 12 dB** vs the ffmpeg
  golden `tone_cbr128.f32`;
- `Test_Decode_RealExcerpt` requires **>= 10 dB** vs `real_excerpt.f32`.

If conformance still fails after this fix, the next suspects (both timing, not
spectral - would move the xcorr lag, not lower the correlation) are:

- the first audio frame's audio is dropped when `main_data_begin > 0` and the
  reservoir is empty, because `ScanMp3Stream` skips the Xing/Info header frame
  without feeding its main-data slots into the reservoir;
- the `+528` decoder-latency term added to the LAME encoder delay in the trim
  path.
