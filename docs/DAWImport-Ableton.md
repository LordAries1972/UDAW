# Ableton Live Set (.als) import

A from-scratch **Ableton Live Set importer**: audio tracks and their
arrangement audio clips land on the DAW timeline as one undoable step,
mirroring how MP3/FLAC/MP4 import onto a single track - except an `.als`
project can create *several* tracks at once, so this is a whole-project
import command, not a single-clip one. No third-party XML or archive
library is used anywhere: gzip decompression goes through the compiler's
own RTL binding (`System.ZLib` on Delphi, `zstream`'s `TGZFileStream` on
FPC - see "Decompression" below for why that is not the third-party-library
line this project avoids), and the XML itself is walked with a small
hand-rolled DOM, the same clean-room approach `UDAW.AI.JSON` uses for JSON.

**Import-only.** There is no `.als` writer/exporter - out of scope per the
task brief, and Ableton's own format is complex enough (warp markers,
device-chain serialization, per-version schema drift) that a faithful
writer would be a separate, much larger undertaking. MIDI/instrument
tracks are recognised and reported but never imported (see "Explicitly
out of scope" below). The project file format is **unchanged**: Ableton
import is a timeline operation, not a persisted document type.

## Units (`src/codecs/ableton/`)

| Unit | Role |
|---|---|
| `UDAW.Codec.Ableton` | Pure parser, no project/timeline dependency. `AlsSniffFile` (2-byte GZIP magic `1F 8B`, content only, never the `.als` extension); `AlsGunzipToBytes` (RTL zlib decompression, see below); a small hand-rolled recursive-descent XML tokenizer/DOM (`TXmlNode`: elements, attributes, nested children, comments, CDATA, the five standard entities + numeric character references - not a general XML parser, no namespaces/DTD/external entities, because Ableton's own writer never emits any of that); and the Ableton-specific extraction that walks the parsed tree into `TAbletonProject`/`TAbletonTrack`/`TAbletonClip`. `AlsParseFile` is the single entry point. |
| `UDAW.Codec.Ableton.Timeline` | `TImportAlsProjectCommand`, an undoable "import a whole Live Set" step on the shared project undo/redo stack. One `Execute` parses the file, adds one `TTimelineTrack` per parsed `AudioTrack`, and for each of its clips content-sniffs the resolved sample file against WAV/MP3/FLAC/MP4 (Ableton predominantly stores WAV, but nothing stops a project referencing any format this DAW already decodes) to get the `TMediaSource` facts, then adds a non-destructive `TTimelineClip`. `Undo` removes exactly the tracks/clips/sources this command created; `Redo` recreates them with the same ids. |

## Wiring

MainForm gains **Import to Timeline > Ableton Live Set (.als)...** in both
the main "Timeline" menu and the Timeline tab's right-click popup menu
(`mnuTlImportAls` / `pmTlImportAls`, both calling `mnuTlImportAlsClick`),
alongside the existing WAV/MP3/MP4/FLAC/tracker entries. The handler opens
`dlgOpenAls` (filter `*.als`), sniffs the file, runs `TImportAlsProjectCommand`
through the shared `TCommandManager`, and logs every warning the parse or
import produced to the Timeline tab's log (`memTimeline`) - nothing is
silently dropped. Long imports show progress in the status bar per the
project's standing requirement for long-running operations.

## Decompression

An `.als` file is a single-member GZIP stream (RFC 1952) wrapping a UTF-8
XML document. This project's "no third-party libraries" rule targets
third-party **audio/JSON/XML/UI** libraries (see `UDAW.AI.JSON`'s header
for the same point made about JSON) - it does not extend to the compiler's
own RTL, so gzip inflate goes through:

* **Delphi**: `System.ZLib.TZDecompressionStream.Create(AStream, 15 + 16)`.
  The `+ 16` is the documented zlib convention (see `deflateInit2`'s
  comment in `System.ZLib.pas`) for "read/write a gzip header+trailer
  instead of a zlib wrapper"; `15` is the max window size. Verified against
  the Delphi 12 (`23.0`) RTL source on this machine.
* **FPC/Lazarus**: `zstream.TGZFileStream.Create(APath, gzopenread)`. Unlike
  Delphi's `TZDecompressionStream`, FPC's `zstream.TDecompressionStream`
  only understands the plain zlib wrapper, not gzip - but `TGZFileStream`
  reads an actual on-disk `.gz` file directly, and an unpacked `.als` file
  *is* exactly that, so no manual gzip-header parsing is needed on either
  leg. **This leg is written but unrun this session** - see the checkpoint
  note at the bottom of this document.

Both legs decompress into an in-memory byte buffer, which is then decoded
as UTF-8 (`.als` always declares `encoding="UTF-8"`) and handed to the XML
parser.

## XML paths read

Cross-checked against the real, community-documented Live 9.7-12 schema
(no code copied - this project's clean-room rule - but the *paths*
themselves are simply what Ableton's own writer emits, so they necessarily
agree with any correct reader):

```
<Ableton Creator="Ableton Live 11.0.12" ...>      Creator -> SourceVersion (informational)
  <LiveSet>
    <MasterTrack>
      .../Tempo/Manual                            @Value -> project tempo, BPM
    <Tracks>
      <AudioTrack Id="...">
        <Name><UserName Value="..."/></Name>       track name (tried first)
        <Name><EffectiveName Value="..."/></Name>  track name (fallback)
        <DeviceChain>
          <MainSequencer>
            <Sample>                               any depth beneath here:
              ...<AudioClip Time="...">             every descendant AudioClip
                <Name Value="..."/>                 clip name
                <CurrentStart Value=".../>           beat position (absolute)
                <CurrentEnd Value="..."/>            beat position (absolute)
                <Loop><LoopStart/><LoopEnd/></Loop>  fallback span if Current* absent
                <FadeInLength Value="..."/>          best-effort, beats
                <FadeOutLength Value="..."/>         best-effort, beats
                <SampleRef>
                  <FileRef>
                    <Path Value="..."/>              absolute path (Live 11+)
                    <RelativePath Value="..."/>       relative path (Live 11+)
      <MidiTrack Id="...">                           recognised, never imported
      <ReturnTrack/><GroupTrack/>...                 recognised, never imported
```

Tempo falls back from `LiveSet/MasterTrack/.../Tempo/Manual` to a
top-level `LiveSet/Tempo/Manual` (older layouts), and finally to **120
BPM with a warning** if neither is present - matching the task brief's
"if a nested element is simply absent, treat it as absent, don't fail the
import" rule.

`CurrentStart`/`CurrentEnd` are read as the clip's absolute beat position
and end in the arrangement (confirmed against the well-documented
`abletoolz` Python parser's `Transport.furthest_bar`, which reads raw
`CurrentEnd` values as absolute bar positions the same way). When a clip
carries neither, its own `Time` attribute plus a `Loop/LoopStart`..`LoopEnd`
span is used as a fallback; if even that is absent, the clip has no
determinable length and is skipped with a warning rather than guessed at.

`Sample`, not `ClipSlotList`, is the scope root for clip discovery - this
deliberately walks only **arrangement** clips (the ones with a fixed
timeline position), not session-view clip slots, which have no timeline
position to import onto in the first place.

## Sample path resolution

For each clip's `SampleRef/FileRef`, only the **Live 11+ plain-string
shape** (`Path`/`RelativePath` as string-valued attributes) is read. Older
sets (pre-11) hex-encode the absolute path inside a `<Data>` element
instead - recognised (so it never crashes the parser) and reported per-clip
as "pre-Live-11 (hex-encoded) sample reference format is not supported",
never guessed at.

Resolution order, exactly as specified in the task brief:

1. `RelativePath` joined onto the **`.als` file's own directory**.
2. `RelativePath` joined onto the **`.als` file's parent directory** (the
   common Ableton "Project" layout: `<Project>\<SetName>.als` next to
   `<Project>\Samples\Imported\...`, where the relative path is stored
   relative to `<Project>`, one level up from the set itself).
3. The absolute `Path` the set itself recorded.
4. If none of the three exist on disk, the clip is **skipped** with a
   warning naming both paths that were tried - the whole import is never
   failed for one unresolvable sample.

Once a sample path resolves, `TImportAlsProjectCommand` content-sniffs
*that file* (never trusting its extension) against WAV, then MP3, then
FLAC, then MP4/M4A - whichever one accepts it supplies the sample rate /
channel count / frame count `TMediaSource` needs. A resolved file in some
other/undecodable format produces a per-clip warning instead of failing
the track.

## What is mapped

* Track name, one `TTimelineTrack` (kind `tkAudio`) per parsed `AudioTrack`.
* Clip name, start position and length (`CurrentStart`/`CurrentEnd`
  converted beats -> seconds via the project tempo).
* Fade-in/fade-out length, when a clip carries a simple
  `FadeInLength`/`FadeOutLength` value (mapped onto
  `TTimelineClip.FadeInSeconds`/`FadeOutSeconds` - see
  `src/timeline/UDAW.Timeline.Model.pas`).
* The underlying audio file itself, resolved and probed as above.

## Explicitly out of scope

* **MIDI/instrument tracks.** Recognised (`MidiTrack`), counted, and
  reported in one summary warning (`"N MIDI track(s) skipped"`) - never
  imported, never crash the parse. A MIDI import pass would need this
  DAW's own MIDI/piano-roll model (`src/midi/`) as the target and is a
  separate undertaking.
* **Return/group/other track types** - recognised, counted, skipped the
  same way.
* **Warp markers / time-stretch fidelity.** Ableton's warp-marker model
  has no equivalent in this DAW's non-destructive clip model (which is
  fixed-ratio, not multi-anchor time-warped); only the clip's plain
  position/length survive.
* **Automation envelopes and device chains** (effects, sends, instrument
  chains). Counted per track (`WarpMarker`/`FloatEvent`/
  `AutomationEnvelope` element counts) into a single
  `"N automation/warp feature(s) not imported"` warning per track, per the
  task brief - not interpreted or preserved.
* **Session-view clips** (`ClipSlotList`). Deliberately never walked -
  they have no fixed arrangement position, so there is nothing meaningful
  to place on a linear timeline.
* **Pre-Live-11 hex-encoded `FileRef`** sample paths - reported per clip,
  not guessed at (see "Sample path resolution" above).
* **Writing/exporting `.als`.** Import-only.

## Tests (`tests/Tests.DAWImportAbleton.pas`)

Every fixture is a real temporary file on disk, gzip-compressed through the
same RTL zlib path `AlsGunzipToBytes` decompresses with (never an
in-memory-only shortcut), mirroring how `Tests.PhaseFLAC` writes a real
temp file to prove its sniffer never trusts an extension:

* gzip sniff accepts a real gzip file, rejects plain text saved with an
  `.als` extension, and rejects a missing path.
* A minimal hand-built fixture (one `AudioTrack` with two `AudioClip`s -
  one resolvable, one not - plus one `MidiTrack`) round-trips tempo, track
  name/kind, clip name, and the beats-to-seconds conversion of
  `CurrentStart`/`CurrentEnd`, and confirms only the resolvable clip
  survives.
* A clip whose sample cannot be resolved anywhere produces a
  `"sample not found"` warning and is dropped, rather than failing the
  parse.
* A gzip file whose XML root isn't `<Ableton>` raises, rather than
  silently producing an empty project.

## UNBUILT - checkpoint before trusting

This entire feature (both codec units, the MainForm wiring, the FPC/zstream
decompression leg, and the tests) was written this session under the
project's "no build/test while credits are being consumed" rule and has
**not been compiled or run** on either the Delphi 12 or the Lazarus/FPC
leg. In particular: the exact FPC `TGZFileStream` constructor signature
(`gzopenread`/`gzopenwrite`) was written from documented FPC RTL behaviour,
not verified against a local FPC installation (none is present on this
machine) - compile it first before trusting the FPC leg.
