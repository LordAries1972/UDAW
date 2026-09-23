# Phase 16 - MP4

Plan section 19 ("Treat MP4 correctly as a CONTAINER").  This phase delivers
the **MP4 container subsystem** and the **supported audio workflows** that can
be done from scratch with no third-party code: PCM-in-MP4 (read + write) and
MP3-in-MP4 (read, via the Phase 15 Layer III decoder).  `UDAW_PHASE` is bumped
to **17** (Phases 16 and 17 land together).  The project file format moves to
**v5** for Phase 17's MIDI section; MP4 is an import/export codec and persists
nothing.

## Units (`src/codecs/mp4/`)

| Unit | Role |
|---|---|
| `UDAW.Codec.MP4.Atoms` | The ISO Base Media File Format (ISO/IEC 14496-12) **box layer**, codec-agnostic. Bounds-checked big-endian scalar readers (`BE_U8..BE_U64`, 16.16 / 8.8 fixed point, FourCC); `TMP4Atom` - one parsed box (type, byte range, 64-bit `largesize`, `uuid` extended type, `Truncated` flag) with `Find` / `FindAll` / `Path`; `TMP4AtomTree` parses a whole buffer, recursing only the known container boxes (`moov trak mdia minf stbl edts dinf ...`, with the `meta` / `stsd` prologues handled explicitly) and never trusting a size field - an over-long box is clamped and flagged. `TMP4BoxWriter` is the mirror: an append-only builder emitting correctly sized 32-bit boxes with `BeginBox` / `BeginFullBox` / `CloseBox` back-patching. |
| `UDAW.Codec.MP4.Container` | `TMP4SampleTable` folds `stts / ctts / stsc / stsz\|stz2 / stco\|co64 / stss` into a flat per-sample list (file offset, byte size, decode + composition timestamp, sync flag, `sample_description_index`). `TMP4Track` carries identity + media timescale/duration + language, and for a sound track the **detected audio codec**: the `stsd` sample-entry FourCC plus, for `mp4a`, a walk of the `esds` `ES_Descriptor` -> `DecoderConfigDescriptor` (object-type indication, max/avg bitrate) -> `DecoderSpecificInfo` (= `AudioSpecificConfig`), from which `ParseAudioSpecificConfig` reads the audio object type, sample rate (incl. the 24-bit explicit-rate escape) and channel config. PCM entries (`sowt twos in24 in32 fl32 fl64 raw lpcm`, and ISO `ipcm` + `pcmC`) map straight to a `TMP4CodecKind`. `TMP4Reader` parses `ftyp` (major + compatible brands), detects fragmentation (`moof` / `mvex`), builds the track list, and prints a report that **names the container and the codec separately** ("Container: MP4 ... \| Audio codec: AAC LC, 44100 Hz, 2 ch"). `TMP4Writer` assembles a minimal standards-valid file from scratch - `ftyp + moov(mvhd, trak(tkhd, mdia(mdhd, hdlr, minf(smhd, dinf/dref, stbl(stsd, stts, stsc, stsz, stco))))) + mdat` - for `mp4a` + `esds` (raw AAC access units) or `sowt` / `in24` / `fl32` PCM, back-patching the single `stco` chunk offset onto its own output. |
| `UDAW.Codec.MP4` | The facade, mirroring `UDAW.Codec.WAV` / `UDAW.Codec.MP3`. `Mp4Sniff*` looks for a real ISOBMFF top-level box, never the extension. `Mp4Probe*` fills `TMP4ProbeInfo` (container brand + compatible brands + fragmented; and, for the sound track, sample-entry FourCC, codec kind + name, OTI, AAC object type, rate, channels, bit depth, sample count, duration, avg bitrate, and a `Decodable` flag). `Mp4DecodeAudio*` turns a PCM-in-MP4 file into engine-planar Float32 exactly (all endian / bit-depth variants, gathering the sample payloads into one blob and de-interleaving), routes an MP3-in-MP4 payload to the Phase 15 decoder, and for AAC / ALAC / AC-3 raises a precise `EUDAWError(errNotImplemented)` that names the detected codec (the container, identity, rate/channels and ASC are all still available via `Mp4Probe`). `Mp4EncodeAudio*` writes a tone or any planar buffer into an MP4 as PCM 16 / 24-bit / Float32 via `TMP4Writer`. |

## What is *not* in this phase

A from-scratch **AAC-LC decoder / encoder**.  The ~1,240 spectral Huffman
codebook constants from ISO/IEC 14496-3 (plus the scalefactor codebook and SWB
offset tables) have no reference copy in this repo, and transcribing them blind
into a decoder that cannot be compiled or tested here would ship subtly wrong.
The container half is complete and the codec is fully **identified and
reported** (`Mp4Probe` gives the AAC object type, rate, channels and the raw
`AudioSpecificConfig`); `Mp4DecodeAudio` fails loudly on it.  Wiring in the
codebook data and the decoder/encoder/filterbank is the one Phase 16 follow-up.

## UI

The main window gains a design-time **MP4** tab (`tabMP4` in both `.dfm` and
`.lfm`): Probe MP4 (container + codec report), Import PCM/MP3 MP4 (decode +
readout), Export test tone (PCM 16 / 24 / float), and a PCM encode/decode
verify round-trip.  Every control is placed in the designer per the project's
forms rule.

## Wiring

`UDAW_PHASE` -> 17 (`src/common/UDAW.Types.pas`).  The three MP4 units are added
to `UDAW.dpr`, `udaw.lpr`, `UDAW.dproj`, `udaw.lpi` and to both test runners.

## Tests (`tests/Tests.Phase16.pas`)

All in memory, no reference media: `TMP4BoxWriter` <-> `TMP4AtomTree` round-trip
(nested boxes, the `stsd`/`meta` prologues, a truncated box); big-endian reads +
their bounds checks; `AudioSpecificConfig` build <-> parse and the sample-rate
index table; PCM-in-MP4 encode -> decode at 16 / 24-bit / float32 with a
dominant-frequency and amplitude-fidelity check and a container/codec report
assertion; `TMP4Writer.BuildAAC` -> `TMP4Reader` identifies "AAC LC" + the
embedded ASC (and `Mp4Probe` marks it not-decodable-yet); hostile / truncated
input degrades without an unhandled fault.

## Follow-up: playback + timeline import

Two new units mirror the Phase 15 MP3 follow-up exactly:

* `UDAW.Codec.MP4.Source` - `TMP4StreamSource`, a real `IAudioSource`: decodes
  the whole file via `Mp4DecodeAudio`/`Mp4DecodeAudioFile` up front (off the
  real-time thread), then `Render` is allocation/lock/IO-free and rate-adapts
  to the engine's sample rate, with `SeekSeconds`/`SeekFrames`/`Loop`.
* `UDAW.Codec.MP4.Timeline` - `TImportMp4Command`, an undoable "import onto the
  timeline" step. `ResolveFile` uses `Mp4ProbeFile` (no full decode) and
  refuses (raising `errNotImplemented`/`errConfig`) any track this build
  can't turn into PCM yet - i.e. it checks `TMP4ProbeInfo.Decodable` - before
  registering a `TMediaSource` and adding a clip.
* `UDAW.Timeline.Playback.TTimelinePlayer.DecodeSource` now also recognises
  MP4 (`Mp4SniffFile`/`Mp4DecodeAudioFile`) alongside WAV/MP3, so an MP4/M4A
  clip already on the timeline plays back like any other source.
* MainForm's MP4 tab gains three more actions (menu + popup, mirroring MP3's):
  *Import to timeline...*, *Play through engine*, *Stop*.

As with import/probe, only PCM-in-MP4 and MP3-in-MP4 payloads actually decode
today; AAC-LC/HE-AAC `.m4a` files are correctly identified but raise
`EUDAWError(errNotImplemented)` until Phase 16b's codebook tables land, and
`TImportMp4Command` reports that clearly rather than adding an unplayable clip.

`UDAW.Codec.MP4.Source` and `UDAW.Codec.MP4.Timeline` are added to `UDAW.dpr`,
`udaw.lpr`, `UDAW.dproj`, `udaw.lpi`.
