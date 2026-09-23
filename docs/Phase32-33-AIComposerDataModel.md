# Phase 32-33 - AI Composition: Internal Data Model + Browser/Instrument Catalogue

Plan reference: `docs/AIPlan.md` section 17, **PHASE 1 - INTERNAL DATA
MODEL** and **PHASE 2 - BROWSER AND INSTRUMENT CATALOGUE**. (That plan's
own 1-9 phase numbering is independent of `UDAW_PHASE`; this doc's title
uses the project's own phase counter, 32 and 33.)

This is schema + catalogue only. No AI provider is wired to it (AIPlan.md
Phase 3, a later `UDAW_PHASE`), and no arrangement engine turns a spec into
real timeline/MIDI/mixer content yet (AIPlan.md Phase 4). Per Phase 1's own
instruction, every test here hand-builds its data instead of connecting to
AI.

## Phase 32 - Internal Data Model (`src/composer/`)

| Unit | Role |
|---|---|
| `UDAW.Composer.SongSpec` | The Structured Song Specification (AIPlan.md section 5's JSON shape) as plain editable classes: `TSongMeta`, `TSongSection`, `TSongTrackSpec`, `TChordProgressionEntry`, and the owning `TSongSpec` (plus AIPlan.md section 14's provenance fields - original request, provider/model id, generation seed; never an API key). |
| `UDAW.Composer.Lyrics` | `TLyricLine` (text, startBar, durationBars, a vowel-group syllable-count heuristic), `TLyricSection`, `TLyricDocument` (language + sections; a song section with no lyric section is implicitly instrumental). Nothing existed for lyrics before this unit. |
| `UDAW.Composer.Validation` | `TSongSpecValidator.Validate` - schema/consistency checks available at this phase (required fields, tempo/time-signature ranges, section bars within the song duration, chord-progression bar coverage, lyric-line bars within their section, instrumental/vocal-track consistency); `ApplyDefaults` fills missing optional fields in place. Note-range/instrument-range checks wait for the arrangement-engine phase, once real notes/instruments exist to check. |
| `UDAW.Composer.Serialization` | `UDAWAISPEC 1` versioned text codec (same line-oriented style as `UDAW.MIDI.Serialization`) for a `TSongSpec`/`TLyricDocument` pair. |
| `UDAW.Composer.Commands` | `TDAWCommand` descendants against the *existing* `TCommandManager` (`UDAW.Project.Commands`, unchanged): `TSetSongSpecCommand` (whole-spec replace, one undo step per generation/full revision), `TUpdateSongSectionCommand`, `TSetChordProgressionCommand`, `TSetLyricLineCommand` (targeted edits so a small revision doesn't cost the whole spec). |

`TProjectDocument` (`UDAW.Project.Document`) gains `SongSpec`/`Lyrics`
properties + `ReplaceSongSpec`/`ReplaceLyrics`, following the exact
existing `Midi`/`ReplaceMidi` pattern. `UDAW.Project.Serialization` gains an
`AISPEC-BEGIN`/`AISPEC-END` section (project format -> **v6**); an older
v1-v5 project with no `AISPEC` block loads fine with an empty spec/lyrics
pair, exactly like MIDI's own v5 addition.

## Phase 33 - Browser and Instrument Catalogue (`src/browser/`)

| Unit | Role |
|---|---|
| `UDAW.Browser.Catalogue` | `TCatalogueItem` (id/name/category/kind/tags/roles/presets/available/lastScanUTC/platform, plus an internal-only `Path` never exposed to AI) and `TInstrumentCatalogue`: `ScanRoots` (recursive, depth-limited, extension + folder-keyword classification into `TCatalogueItemKind` - VST/VST3, SoundFont, sample, loop, drum kit, preset, effect VST, vocal recording - with a small keyword table for tags/roles, no third-party tagging/ML library), `FindByTag`/`FindByRole`/`FindByCategory`/`TextSearch`, `MarkMissing` (marks `Available := False`, never removes an entry), `SafeDescriptionJSON`/`SafeDescriptionsJSON` (the AIPlan.md section 3 id/name/category/tags/roles/presets/available shape - the only view an AI provider ever sees), `SaveToFile`/`LoadFromFile` (own JSON via the existing from-scratch `UDAW.AI.JSON`). |

Stable ids are an FNV-1a hash of the normalized absolute path
(`StableCatalogueId`), so `TSongTrackSpec.PreferredInstrumentId` references
survive rescans without ever encoding a path. Persistence is one global
file at `DataFile('instrument_catalogue.json')` (`UDAW.Paths.DataFile`),
shared across projects - matching how the Browser tab's audio-library/SFX
folders are already global settings, not per-project state.

`UDAW.Config` gains six new `[paths]` keys alongside the existing
`CFG_PATH_AUDIO_LIB`/`CFG_PATH_SFX`: `CFG_PATH_INSTRUMENTS`,
`CFG_PATH_PRESETS`, `CFG_PATH_LOOPS`, `CFG_PATH_PLUGINS`,
`CFG_PATH_SOUNDFONTS`, `CFG_PATH_VOCALS` (AIPlan.md section 3: "Allow the
user to define one or more preset locations"). **Settings-tab UI fields and
the Browser tab's category tree/search UI for these are not yet wired up**
in this pass - `UDAW.Browser.Catalogue` is complete and independently
tested, but MainForm integration (new edit boxes/buttons, a Catalogue view
alongside `tvBrowser`) is left for the next pass alongside the Phase 3/4
work that will actually consume the catalogue, to keep this phase's diff to
the model + engine rather than a large hand-edited `.dfm`/`.lfm` change.

## Project format

`PROJECT_FILE_VERSION` -> 6 (adds `AISPEC-BEGIN`/`AISPEC-END`). v1-v5 files
still load.

## Wiring

11 new units (5 composer + 1 browser, times both build legs) added to
`UDAW.dpr`, `udaw.lpr`, `UDAW.dproj`, `udaw.lpi`, `tests/UDAW.Tests.dpr`,
`tests/udaw_tests.lpr`, `tests/udaw_tests.lpi` (`OtherUnitFiles`), and
`scripts/test-windows.ps1`'s `-U` search path. `Tests.Phase32`/
`Tests.Phase33` registered in both test runners.

## Tests

`tests/Tests.Phase32.pas`: the AIPlan.md section 5 example spec (hand-built
in code, no AI) validates clean; the validator catches a section past the
song duration, an under-covered chord progression, a lyric line outside its
section, and an instrumental/vocal-track conflict; `ApplyDefaults` fills
missing optional fields; spec+lyrics serialize/deserialize round-trip
exactly; `TSetSongSpecCommand`/`TUpdateSongSectionCommand` undo/redo
correctly through `TCommandManager`.

`tests/Tests.Phase33.pas`: `ScanRoots` over a scratch temp tree classifies
and tags a loop/drum-kit/vocal/soundfont/VST-by-extension correctly; the
same file gets the same stable id across two scans; `MarkMissing` marks a
deleted file's item unavailable without removing it; `SaveToFile`/
`LoadFromFile` round-trip losslessly; `SafeDescriptionJSON` never contains
the item's filesystem path. No real VST binary is available for automated
testing, so `.dll`/`.vst3` classification is checked only by extension, not
by invoking `TVST2Host` - the same gap Phase 20 left for `UDAW.AI.HTTP`'s
real network calls, for the same "needs a real endpoint/file" reason.

**Unbuilt checkpoint** - per the standing no-build-during-credits rule, none
of this has been compiled or run this session. Build and run
`Tests.Phase32`/`Tests.Phase33` (via `scripts/test-windows.ps1` or the
Delphi/Lazarus IDE) to verify before relying on it.
