# FL Studio Project (.flp) import

A clean-room, from-scratch reader for FL Studio's `.flp` binary project
format, scoped to one thing: turning a Playlist's placed **audio-sample**
blocks into non-destructive timeline clips. No third-party FLP library is
linked or transliterated - Image-Line has never published a specification,
so this was built the same way this project's MOD/XM/IT-MPTM tracker codecs
were: against the community reverse-engineering of the format, implemented
from the documented field meanings, not from anyone else's code.

## Sources consulted (field meanings only - nothing transliterated)

* The archived **"FL Studio FLP file format (v11)"** community write-up and
  the **fileformats.archiveteam.org/wiki/Raw_FL_Studio_Project** page, for
  the overall `FLhd` / `FLdt` chunk shape and the event-ID range scheme
  (0-63 byte, 64-127 word, 128-191 dword, 192-255 variable-length).
* **PyFLP** (`github.com/demberto/PyFLP`, GPL-3 - read for the *meaning* of
  specific fields and event IDs only; no code was copied or transliterated,
  matching this project's standing rule against lifting GPL source):
  - `pyflp/_events.py` - confirms the varint used for 192-255 events is a
    **protobuf-style base-128 varint**: 7 payload bits per byte, high bit =
    "more bytes follow", and the **first** byte holds the **least**
    significant 7 bits (this is the opposite bit order from a MIDI
    variable-length quantity, which is worth calling out since it is easy to
    get backwards). Confirmed against `construct.VarInt`'s own implementation.
  - `pyflp/_events.py` (`StrEventBase`) - text events are ASCII when the
    project's `FLVersion < 11.5.0`, else null-terminated UTF-16LE.
  - `pyflp/project.py` - `ProjectID.Tempo = DWORD+28` (id 156), dword value
    is **BPM * 1000**; older files instead carry `ProjectID._TempoCoarse =
    WORD+2` (id 66, integer BPM) and optionally `ProjectID._TempoFine =
    WORD+29` (id 93, thousandths to add). `ProjectID.FLVersion = TEXT+7`
    (id 199) is **always ASCII**, `"major.minor.build.revision"`, even in a
    file that otherwise stores every other string as UTF-16 - this is the
    field this importer parses to decide which encoding the rest of the
    file's text events use.
  - `pyflp/channel.py` - `ChannelID.New = WORD` (id 64) starts a channel's
    event scope and its word value is that channel's `iid`; `ChannelID.Type`
    is byte id 21 (`0` = Sampler, `2` = Native/audio clip, `3` = Layer,
    `4` = Instrument, `5` = Automation); `ChannelID._Name = TEXT` (id 192)
    is the channel's display name; `ChannelID.SamplePath = TEXT+4` (id 196)
    is the referenced sample file's path.
  - `pyflp/arrangement.py` - `ArrangementID.Playlist = DATA+25` (id 233) is
    a packed array of fixed-size records, **32 bytes** in older files or
    **60 bytes** from FL Studio 21 on (PyFLP detects which by checking
    whether the payload length is an exact multiple of 60 - this importer
    does the same). Record layout (offsets in bytes):

    | Offset | Field | Type | Meaning |
    |---|---|---|---|
    | 0 | position | UInt32LE | start, in ticks |
    | 4 | pattern_base | UInt16LE | observed constant, `20480` |
    | 6 | item_index | UInt16LE | channel `iid` if `<= pattern_base`, else `pattern_base + pattern number` |
    | 8 | length | UInt32LE | length, in ticks |
    | 12 | track_rvidx | UInt16LE | reversed playlist-track index (track 1 is the *highest* number seen) |
    | 14 | group | UInt16LE | clip group, unused by this importer |
    | 16..31 (..59) | - | - | reserved / start-offset / end-offset / FL21+ tail, unused by this importer |

## Tick -> seconds conversion

`secondsPerTick = 60 / (Tempo * PPQ)`, where `Tempo` is the resolved project
BPM and `PPQ` (pulses/ticks per quarter note) comes straight from the
`FLhd` header (`format:Int16LE`, `channels:Int16LE`, `PPQ:Int16LE`, in that
order, at a fixed 6-byte offset after the chunk's own header). Every clip's
`StartSeconds`/`LengthSeconds` is its tick value times `secondsPerTick`.

## What is imported

Only **Playlist blocks that reference an audio-sample channel** - a channel
whose `ChannelID.SamplePath` (id 196) is present, non-empty, and resolves to
a real, decodable file. Each such block becomes one `TTimelineClip`:

* One `TTimelineTrack` per distinct FL Studio playlist track that carried at
  least one importable clip. FLP gives no reliable, stable *name* for a
  playlist track in the data this importer reads, so tracks are numbered
  `FL Track 1`, `FL Track 2`, ... in FL's own top-to-bottom order (derived
  from `track_rvidx`, descending).
* One de-duplicated `TMediaSource` per distinct resolved sample file path
  (clips that reference the same file share one source, exactly like the
  WAV/MP3/FLAC importers).
* The clip's display name is the channel's own display name
  (`ChannelID._Name`, id 192) when present, else the sample file's base
  name.

The whole playlist lands as **one undo step** (`TImportFlpProjectCommand`):
Undo removes every clip/source/track this one import added; a track the
user has since put other clips on is left alone.

### Sample-format support

`UDAW.Codec.FLStudio` (the pure parser) only resolves a *file path* - it has
no audio-decoding code of its own. `UDAW.Codec.FLStudio.Timeline` (the
import command) probes each resolved file with this project's own decoders,
in order: **WAV**, then **MP3**, then **FLAC**. A resolved sample in a
format none of those three decode (OGG being the common case in FL Studio
projects - this project has no OGG decoder) is **skipped with a warning**,
never imported with fabricated `SampleRate`/`Channels`/`FrameCount` values.

### Sample-path resolution order

FL Studio records a sample's path as it was on the *authoring* machine,
which is frequently either absolute (and wrong on any other machine) or
relative to FL's shared `Data\Packs` install tree. This importer tries, in
order, and uses the first that resolves to an existing file:

1. the path exactly as stored in the project;
2. the same file name in the same folder as the `.flp` file itself;
3. the same file name under a `Samples\` or `Audio\` subfolder next to the
   `.flp` file.

If none of the three resolve, that one clip is skipped with a per-clip
warning - the rest of the import proceeds normally.

## What is explicitly NOT imported (out of scope for this pass)

* **Pattern / piano-roll content.** A Playlist block whose `item_index` is
  greater than `pattern_base` plays back a *pattern* (FL's internal
  step-sequenced / piano-roll note data), not an audio file - there is no
  audio to place on the timeline without actually rendering FL's synth
  engine, which this importer does not attempt. These blocks are counted
  and reported as a single warning: `"N pattern/instrument blocks were not
  imported (MIDI/pattern import not yet supported)"`. The same bucket also
  catches playlist blocks that reference a channel with no resolvable
  sample path (a synth/plugin instrument channel, an automation channel,
  etc.) - anything that is not a plain audio-sample channel.
* **Mixer routing** (FL's mixer tracks, inserts, sends) - not read at all.
* **Automation** (automation clips/channels, envelopes) - not read.
* **Plugin state** (VST/native plugin chunk data on instrument channels) -
  not read; a plugin-backed channel is simply not an audio-sample channel,
  so it falls into the pattern/instrument bucket above.
* Per-clip `start_offset` / `end_offset` (a fine playlist trim FL stores in
  the 32/60-byte record) is parsed as part of the record layout above but
  not currently applied to the resulting clip - every imported clip spans
  its full recorded tick length. A future pass could fold this into the
  clip's `SourceOffsetSeconds`/`LengthSeconds`.

## Units

* `src/codecs/flstudio/UDAW.Codec.FLStudio.pas` - the pure parser. No
  project/timeline/UI dependency. `FlpSniffFile` / `FlpSniffData` (magic
  check, never the extension), `FlpParseFile` / `FlpParseData` ->
  `TFlpProject` (`Tempo`, `PPQ`, `Clips: TArray<TFlpAudioClip>`) plus a
  human-readable `TArray<string>` of warnings, and `ResolveFlpSamplePath`
  (exposed standalone for testing).
* `src/codecs/flstudio/UDAW.Codec.FLStudio.Timeline.pas` -
  `TImportFlpProjectCommand : TDAWCommand`, the undoable whole-playlist
  import step described above. Probes resolved sample files with
  `UDAW.Codec.WAV` / `UDAW.Codec.MP3` / `UDAW.Codec.FLAC`.

## UI

MainForm's **Import to Timeline** submenu (`pmTlImport`) gains **"FL Studio
Project (.flp)..."** (`pmTlImportFlp` / `mnuTlImportFlpClick`), following the
exact same shape as the WAV/MP3/MOD entries: open a file dialog filtered to
`*.flp`, sniff, parse, perform `TImportFlpProjectCommand` on success, and log
every warning line (pattern/instrument counts, unresolved samples,
unsupported sample formats, etc.) to the Timeline tab's log (`memTimeline`).

## Tests

`tests/Tests.DAWImportFLStudio.pas`: `FlpSniffFile`/`FlpSniffData` magic
detection, a hand-built minimal `.flp` byte stream (header + one `NewChan`
sampler channel with a name and sample path + a tempo event + one
32-byte-record Playlist event) parsing into the expected
track/clip/tempo/PPQ structure, and a clip whose sample path cannot be
resolved producing a warning instead of failing the whole parse.

## Status

Written for Delphi 12 / Lazarus-FPC. **UNBUILT** - this has not been
compiled or run; treat it as a checkpoint for the next build, not as
verified-working.
