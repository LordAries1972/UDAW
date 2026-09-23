# Phase 34 - AI Composition: AI Provider Layer + Basic Arrangement Generation

Plan reference: `docs/AIPlan.md` section 17, **PHASE 3 - AI PROVIDER LAYER**
and **PHASE 4 - BASIC ARRANGEMENT GENERATION**. (That plan's own 1-9 phase
numbering is independent of `UDAW_PHASE`; this doc's title uses the
project's own phase counter, 34.) Builds directly on Phase 32/33
(`docs/Phase32-33-AIComposerDataModel.md`), which left both of these
explicitly unimplemented ("No AI provider is wired to it... no arrangement
engine turns a spec into real timeline/MIDI/mixer content yet").

## Phase 3 - AI Provider Layer (`src/ai/UDAW.AI.Composer.pas`)

`ICompositionProvider` / `TCompositionProvider` sit **above** the existing
chat-shaped `IAIProvider` (`UDAW.AI.Types`, Phase 20) rather than adding
AIPlan.md section 2A's composition methods to it in place: `IAIProvider`
already has three concrete, tested implementations (OpenAI/Claude/DeepSeek,
Phases 21-23) that only implement the five chat-oriented methods, and
changing that interface's shape would break all three. Wrapping any one of
them behind `TCompositionProvider` gets every Phase 3 requirement without
touching the provider units:

| AIPlan.md Phase 3 item | Implementation |
|---|---|
| Define IAIProvider (composition-shaped) | `ICompositionProvider`: `Initialize`, `Authenticate`, `SubmitCompositionRequest`, `SubmitRevisionRequest`, `GenerateLyrics`, `AnalyzeLyrics`, `AnalyzeArrangement`, `CancelRequest`, `GetRequestStatus`, `GetLastError` |
| Secure credentials | Reused as-is: `UDAW.AI.Credentials` (OS-backed `ISecureStore`); `CreateCompositionProvider(providerId)` reads the stored key and builds the inner provider via the existing `UDAW.AI.Providers.CreateAIProvider` factory |
| Request and cancellation handling | A monotonic `Int64` request id per call + a `TAICancelToken` (`UDAW.AI.HTTP`), tracked in a lock-guarded dictionary so `CancelRequest`/`GetRequestStatus` work from a different thread than the one running the call |
| Require structured responses | Every `Submit*`/`GenerateLyrics` call instructs the provider to reply with one JSON object matching AIPlan.md section 5's shape, parses it with `UDAW.AI.JSON`, and runs `TSongSpecValidator` on the result; a parse or validation failure is fed back to the AI as a corrective follow-up prompt and retried |
| Retry and error reporting | `CallWithRetry` retries a transport failure (`errNetwork`/`errTimeout`/other `EUDAWError`) with a linear backoff, up to `AMaxRetries` (default 2); `GetLastError` exposes the final failure reason |
| Log usage without exposing private content | No new logging - every HTTP call already goes through `UDAW.AI.HTTP`, which logs via `UDAW.AI.SecureLog` (method + URL + body length only) |

`SubmitCompositionRequest` also sends the caller's `TInstrumentCatalogue`
(via `SafeDescriptionsJSON`, Phase 33) so the AI only ever sees safe
id/name/category/tags/roles/presets/available data, never a file path.
`AnalyzeLyrics`/`AnalyzeArrangement` are plain-text critique calls (no
structured-response requirement - they inform, they don't mutate anything).

## Phase 4 - Basic Arrangement Generation (`src/composer/UDAW.Composer.Arrangement.pas`)

`TArrangementEngine.Apply` turns a validated `TSongSpec` into real project
content, in AIPlan.md section 8's order, as **one** undo step:

1. Re-validates the spec (`TSongSpecValidator`) and rejects (no project
   change, no command pushed) on any `vsError` issue - AIPlan.md section 1's
   "the AI must not directly manipulate the DAW timeline from unvalidated
   text."
2. Sets tempo/time signature, adds one `TTimeline` marker per `TSongSection`.
3. For each `TSongTrackSpec`: a linked `TTimelineTrack` + `TMixStrip` for
   `stkMidi`/`stkAudio` (`InputSourceId` wired to the new track), or a
   bus-only `TMixStrip` for `stkBus`.
4. Instrument resolution against the Phase 33 `TInstrumentCatalogue`: exact
   `PreferredInstrumentId` match first, else a suitability score (category
   20, per matching role 15, per matching tag 5 - AIPlan.md section 6's
   matching order, simplified to the fields available at this phase).
   Never drops a track for being unresolved; the result carries up to 3
   suggested alternative catalogue ids per unresolved track.
5. Simple chords/bass/drums: any track whose `Role` names a drum/percussion,
   bass or harmony/chords/pad/keys/rhythm/guitar part gets real MIDI content
   -  a small hand-written chord-symbol parser (`ParseChordSymbol`: major/
   minor/7/maj7/m7/dim/aug/sus2/sus4, defaulting to a major triad on an
   unrecognised suffix) walks each section's `TChordProgressionEntry` one
   bar at a time via `TPianoRoll.AddNote`; a section with no progression
   falls back to a static triad on the song's key/scale. Drums get a fixed
   kick/snare/hat pattern scaled by the section's `Energy`. Any other role
   (melody, vocal, fx, ...) gets an empty, ready-to-edit MIDI clip/track -
   real melodic/performance generation is AIPlan.md's later PHASE 6.
6. Preview/Undo: everything above runs inside `TApplyArrangementCommand`
   (`UDAW.Project.Commands.TDAWCommand`), which clones Timeline/Mixer/Midi/
   SongSpec/Lyrics/tempo/time-signature before touching anything and
   restores them on Undo (and from a second `After*` snapshot on Redo,
   cheaper than regenerating) - "Apply" is always exactly one undo step,
   AIPlan.md section 12's "keep a complete Undo transaction."

`TArrangementResult` (`Warnings`, `Resolutions`, `UnresolvedCount`) is
returned either way, so a caller can show AIPlan.md section 13's pre-apply
summary ("Tracks to be created... Missing instruments... Suggested
substitutions") even though the actual pre-build **preview mode** (running
the engine into a scratch document instead of the live one) is left for the
UI-wiring pass, same as the AI Composer workspace UI itself (section 15).

## Not in this pass

- No UI: no AI Composer workspace/tab, no "Generate"/"Preview"/"Apply"
  buttons (AIPlan.md section 15). Both new units are backend-only, callable
  from tests or a future UI pass - matching how Phases 21-23's providers
  shipped before Phase 22 wired a chat tab.
- No melody/lead generation, drum fills, variations, automation or
  side-chaining - AIPlan.md PHASE 6.
- No mixing-assistant hookup for the arrangement's initial gain staging -
  PHASE 7 (`UDAW.AI.Mixing` already exists from Phase 26-29 but is not
  invoked here).
- `SubmitRevisionRequest` asks the AI to return the **complete** updated
  spec rather than a minimal diff/change-set; full conversational,
  partial-only revision is AIPlan.md PHASE 8, layered on the existing
  targeted `UDAW.Composer.Commands` (`TUpdateSongSectionCommand` etc.) that
  Phase 32 already provides for exactly that purpose.
- FPC/Lazarus: `UDAW.AI.Composer.pas` is wired into `UDAW.dpr`/`UDAW.dproj`
  only, matching every other `src/ai/*` unit - the AI subsystem is not yet
  part of the `udaw.lpi` (FPC) build at all. `UDAW.Composer.Arrangement.pas`
  *is* added to `udaw.lpi` alongside the rest of `src/composer/`, since that
  folder already builds on both legs.
- No new automated tests. Both units are new, non-trivial, and unbuilt -
  **unbuilt checkpoint**, per the standing no-build-during-credits rule: none
  of this has been compiled this session. Before relying on it, build
  `UDAW.dproj` and add/run a `Tests.Phase34` covering at minimum:
  `TCompositionProvider` JSON parse/retry behaviour against a fake
  `IAIProvider`, and `TArrangementEngine.Apply` end-to-end against a
  hand-built `TSongSpec` (track/marker/mixer-strip creation, instrument
  resolution scoring, chord-symbol parsing, and Undo restoring the project
  exactly).
