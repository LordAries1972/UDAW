# Phase 6 - PCM / WAV Engine

Status: **implemented and passing** (134/134 acceptance tests: 21 Phase 1 +
26 Phase 2 + 31 Phase 3 + 19 Phase 4 + 18 Phase 5 + 19 Phase 6, Delphi 12 /
Win64). The Windows executable builds with the codec unit linked and gains a
live **WAV** tab.

Phase 6 delivers the plan's PCM/WAV engine (section 67, Phase 6; section 17):
a complete, self-contained WAV reader and writer with **no third-party
loaders and no OS multimedia API** - all container parsing and sample
conversion is written from scratch.

## Layout

```
src/codecs/pcm/
  UDAW.Codec.WAV.pas   The whole engine:
                        - TWavSampleFormat / TWavInfo (format, channels, rate,
                          frame count, data offset/size, RF64 + EXTENSIBLE
                          flags, duration/bytes-per-frame helpers)
                        - DataLooksLikeWav / FileLooksLikeWav: header-signature
                          sniffing that never looks at the file extension
                          (plan section 20)
                        - ReadWavInfo: parse only the header
                        - TWavReader: streaming decode to planar Float32
                          (SeekFrame, ReadFrames, ReadAll); owns its stream
                          when built from a file name, or wraps any TStream
                        - TWavWriter: streaming encode from planar Float32;
                          writes a ds64-sized JUNK placeholder so a file that
                          outgrows the 32-bit RIFF limit is promoted
                          RIFF->RF64 in place at Finalize without moving audio
                        - LoadWavFile / SaveWavFile: one-shot helpers
                        - TWavPlayerSource: an IAudioSource that plays a WAV
                          file through the device engine / offline renderer,
                          linear-interpolating from the file's sample rate to
                          the engine's rate (so a 44.1 kHz file plays correctly
                          on a 48 kHz device), with optional looping
```

## Formats

| Container | Sample formats | Channels |
|-----------|----------------|----------|
| RIFF/WAVE, RF64/BW64 (EBU Tech 3306) | PCM 8-bit (unsigned), PCM 16 / 24 / 32-bit (signed LE), IEEE float 32 / 64-bit | mono, stereo, multichannel (WAVE_FORMAT_EXTENSIBLE written automatically for > 2 channels) |

All multi-byte integers are assembled and emitted byte-by-byte in
little-endian order, so the codec is correct regardless of host endianness.
The canonical in-memory representation is the engine-wide planar Float32
layout (`TAudioPlanar`, `Data[channel][frame]`).

Chunk parsing tolerates unknown chunks (`LIST`, `fact`, ...), a slightly
truncated final `data` chunk, and the RF64 `data`/`RIFF` size sentinels
(`0xFFFFFFFF` resolved from `ds64`). A file that is not a RIFF/RF64 container,
has no `fmt ` or `data` chunk, or declares an unsupported tag/bit-depth is
rejected with `EUDAWError` (`errConfig`) - it never loads with data silently
missing (plan rule: fail loudly, never deserialize raw class memory).

## UI

MainForm gains a design-time **WAV** tab (see the `.dfm`/`.lfm`):

- **Import WAV...** - signature-checks and header-probes a file, prints
  `TWavInfo.Describe`
- **Play / Stop** + **Loop** - routes the imported file through the device
  engine via `TWavPlayerSource` (rate-adapted)
- **Write format** picker (PCM 8/16/24/32, float 32/64)
- **Export test tone...** - writes a 2 s stereo 440 Hz / 660 Hz WAV in the
  chosen format
- **Round-trip verify** - encodes then decodes a 220 Hz test signal in the
  chosen format and reports the maximum absolute reconstruction error

## Tests

`tests/Tests.Phase6.pas` (19 tests, registered from `UDAW.Tests.dpr` /
`udaw_tests.lpr`):

- **roundtrip**: every sample format in mono / stereo / 6-ch / 8-ch, samples
  compared within format-appropriate tolerance
- **header**: `ReadWavInfo` field-by-field; EXTENSIBLE sub-format decode;
  RF64 round-trip (forced, `ds64` frame count + data verified)
- **io**: `SeekFrame` + partial reads + EOF clamping; 8-bit PCM stored as the
  unsigned midpoint `0x80`; round-trip through an in-memory `TStream`
- **reject**: text file not detected as WAV; non-RIFF blob rejected with
  `errConfig`; structurally valid header claiming 12-bit PCM rejected
- **play**: `TWavPlayerSource` reproduces 440 Hz at matching rate; a 44.1 kHz
  file resamples to a 48 kHz engine without pitch shift

## Build wiring

`src/codecs/pcm` added to the search path in `UDAW.dpr` / `UDAW.dproj`,
`udaw.lpr` / `udaw.lpi`, `tests/UDAW.Tests.dpr` / `tests/udaw_tests.lpr` /
`tests/udaw_tests.lpi`, and `scripts/{build,test}-windows.ps1` /
`scripts/test-{linux,macos}.sh`. `UDAW_PHASE` bumped to 6.

## Verified / deferred

**Verified on Windows / Delphi 12 only**: 134/134 tests pass; the GUI exe
builds and boots clean (log shows "phase 6", no exceptions). The FPC/Lazarus
leg is wired but not compiled here (no FPC on this machine).

**Deferred (deliberately, per the plan's phase order)**: metadata (`LIST`
`INFO`, `bext`) reading/writing, cue/loop chunks, and integration with the
project file / timeline clips - those belong to the import system (section
20) and later phases. MP3 (Phase 12+ / section 18) and MP4 (section 19) are
separate codecs and untouched here.
