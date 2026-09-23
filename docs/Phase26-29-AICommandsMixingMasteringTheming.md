# Phases 26-29 - AI Tool Commands, AI Mixing, AI Mastering, Theming

Plan reference: `docs/UDAW-Original-Plan.txt` lines 3776-3798 (phases 26-29),
detailed in sections 35 (AI Command System), 40 (Local Audio Analysis for
AI), 41 (AI Mixing Assistant), 42 (AI Mastering Assistant) and 47 (Theming
System). Four self-contained pieces, all written for Delphi 12; **unbuilt -
checkpoint for the user to compile.**

## Phase 26 - AI Tool Commands (`src/ai/UDAW.AI.ToolCommands.pas`)

The AI is never allowed to touch project memory directly (plan: "AI MUST
NEVER directly manipulate internal memory"). Instead an assistant reply can
carry a fenced block:

```tool
{"command":"SetGain","track":"drums","delta_db":-2}
```

`ParseAIToolCalls` extracts every such block (using the existing hand-written
`UDAW.AI.JSON` reader - no new JSON dependency), `AIToolKindFromId` resolves
both the canonical name (`SetGain`) and the plan's own worked-example
spelling (`set_track_gain`), `ValidateToolCall` range-checks the result
(pan -1..1, tempo 20..400 bpm, gain -120..24 dB, required fields present),
and `TAIToolDispatcher.Execute` performs the *normal* DAW command for it -
`SetGain`/`SetPan`/`SetMute`/`SetSolo` become `TSetMixStripFloatCommand`/
`TSetMixStripFlagCommand`, `AddTrack` a `TAddTimelineTrackCommand`,
`SetTempo` a `TSetTempoCommand`, `AddMarker` a `TAddTimelineMarkerCommand`,
`MoveClip` a `TMoveTimelineClipCommand` - every one run through the caller's
`TCommandManager.Perform`, so AI edits are ordinary undo/redo entries. `Get*`
tools (`GetProjectInfo`, `GetTracks`, `GetTrackInfo`, `GetMixerState`) return
a small JSON snapshot instead. `IsDestructiveTool` flags `AddTrack`,
`MoveClip`, `SetTempo`, `ExportProject`, `GenerateMusic` for the confirmation
the plan requires ("destructive commands must require appropriate
confirmation").

Wired into `TfrmMain.SendAiChatPrompt` (`UDAW.UI.MainForm.pas`): the first
message of a chat session is now `AIToolSystemPrompt` (the tool vocabulary +
protocol), and every assistant reply is scanned for tool blocks after it
arrives - validated ones execute (via `MessageDlg` confirmation for
destructive ones), and the result is logged to `memAiLog` as `[tool] ...`.

`CreateAutomation` is honest about a real limitation: there is no
automation-curve-authoring API yet anywhere in the codebase, so it puts the
target mixer strip into `amWrite` mode and says so, rather than pretending to
draw a curve that doesn't exist.

## Phase 27 - AI Mixing Assistant

### `src/audio/dsp/UDAW.DSP.Analysis.pas` - local audio analysis

Plan section 40: "never send huge PCM buffers to an LLM unnecessarily."
`AnalyzeStereoBuffer(L, R, SampleRate)` reduces a full stereo buffer to a
`TAudioAnalysisResult` - integrated/short-term LUFS and true peak (Phase 3's
`TLoudnessMeter`/`TTruePeakMeter`), sample peak/RMS/crest factor, a 1-second-
block dynamic-range spread, clipping-sample count, silence percentage,
stereo correlation, low/mid/high spectral band energy, spectral
centroid/rolloff (a Hann-windowed `TFFT` pass with spectral-flux onset
detection), a rough autocorrelation-based detected pitch, an onset-interval
BPM estimate, and transient density. `AnalysisResultToJSON`/
`...JSONString` serialize it with the exact field names from the plan's own
worked example (`integrated_lufs`, `true_peak`, `low_band_energy`,
`stereo_correlation`, `clipping_samples`, plus the rest). No pitch/BPM
detector existed anywhere in the codebase before this - both are new,
intentionally simple (autocorrelation / spectral-flux clustering), matching
this project's "clean-room, from spec" convention for DSP.

### `src/ai/UDAW.AI.Mixing.pas` - suggestions + Preview/Compare/Apply/Reject

`SuggestMixHeuristic` is a deterministic, fully offline pass (plan rule 26:
"the complete DAW must function without Internet") reproducing the plan's own
example almost verbatim: heavy low-band energy plus a strip whose name
contains "bass"/"sub" yields a -2.5 dB / 82 Hz / Q 1.3 corrective EQ
suggestion; other heuristics cover true-peak/clipping headroom, loudness vs.
a -14 LUFS target, and near-mono stereo correlation. `TAIMixingSession` never
makes an irreversible change automatically: `Preview` performs every
suggestion as a real `TSetMixStripFloatCommand`/`TAddMixInsertCommand`
through the project's `TCommandManager` (so it's heard immediately and is
already undo-safe), `CompareToggle` undoes/redoes the whole batch to A/B
against the untouched original, `Apply` just stops tracking it (the edits
already live on the normal undo stack), and `Reject` undoes them.

## Phase 28 - AI Mastering Assistant (`src/ai/UDAW.AI.Mastering.pas`)

`SuggestMasteringChain` runs the plan's stages (identify target -> determine
headroom -> analyze spectrum/dynamics -> suggest chain) against a
`TAudioAnalysisResult` and proposes: a -1 dBTP ceiling / -14 LUFS target /
a correlation-driven width factor for the Phase 19 `TMasteringChain`
(hosted as an `nkMastering` insert), an optional corrective EQ
(`nkBiquad`/peaking) for a heavy low end or a thin top end, and optional
gentle 2:1 glue compression (`nkCompressor`) only when the mix is genuinely
dynamic (crest factor > 14 dB) - an already-squashed mix gets no further
compression. `TAIMasteringSession.Preview` adds (or, on a second run,
updates in place via the new `TSetMixInsertParamsCommand`) up to three
inserts on the project's master strip; `CompareToggle`/`Apply`/`Reject` work
exactly like the mixing session, always offering "Original" vs. "AI
Recommendation" per the plan's closing line.

`TSetMixInsertParamsCommand` (new, in `src/mixer/UDAW.Mixer.Commands.pas`)
fills a real gap: `UDAW.Mixer.Commands` had add/remove/move-insert commands
but nothing to retune an insert already sitting in a strip's chain without a
remove-and-re-add round trip. Mergeable like the other fine-grained mixer
commands.

## Phase 29 - Theming (`src/ui/UDAW.UI.ThemeColors.pas`)

`UDAW.UI.Theme` (Settings-tab work, still unbuilt at the time of writing)
only ever swapped whole native-control skins via VCL `.vsf` styles - Windows
-only in practice, with no concept of per-role colour. This unit adds the
plan's actual theme model: `TUDAWTheme` (background, panel, text, secondary
text, border, accent, selection, waveform, grid, meter, clipping,
automation, MIDI-note colours), five built-in themes (Studio Dark/Light,
Midnight, Graphite, High Contrast), and `ThemeColorsSave`/`Export`/`Import`/
`Reset` - an edited or imported theme is stored as one small text file under
`<data>/themes/<name>.udawtheme` and shadows the built-in of the same name.
Deliberately never touches `Vcl.Themes`/`TStyleManager`, so it works
identically under FPC/Lazarus.

Wired into the Settings tab as a second, independent theme control
(`grpColorTheme`: `cboColorTheme` + Save copy/Reset/Export/Import buttons,
alongside the existing VCL-style picker) and into two of `UDAW.UI.MainForm`'s
custom-drawn `TPaintBox` routines (the Scope tab's oscilloscope/spectrum/
goniometer/meters view, and the DSP tab's spectrum analyser) via a
`CurrentTheme` alias, replacing their hardcoded `clBlack`/`clLime`/`clGray`/
`clSilver`/`clYellow` constants. The tracker/piano-roll/timeline paint
routines were left as-is: several of those hardcode genuine semantic
constants (black/white piano keys) rather than "background/text" theme
roles, and re-theming them without being able to visually verify the result
this session risked a worse outcome than leaving them alone - a scope
boundary, not an oversight, and a reasonable next step for a follow-up pass.

## Wiring

New units added to `UDAW.dpr`, `UDAW.dproj`, `udaw.lpr`:
`UDAW.AI.ToolCommands`, `UDAW.DSP.Analysis`, `UDAW.AI.Mixing`,
`UDAW.AI.Mastering`, `UDAW.UI.ThemeColors`. `UDAW.Mixer.Commands.pas` gained
`TSetMixInsertParamsCommand`. `UDAW.UI.MainForm.pas`/`.dfm` gained a Mixing
Assistant and Mastering Assistant submenu (under the AI tab's popup menu,
matching this file's existing hidden-menu-as-command-surface convention) and
the Settings-tab colour-theme group. `UDAW_PHASE` -> **29**.

## Tests

`tests/Tests.Phase26.pas` - fenced-block parsing (single/multiple/malformed),
name/alias resolution, destructive-tool classification, validation range
checks, and dispatcher execution against a real in-memory
`TProjectDocument`/`TCommandManager` (including the undo-stack round trip
and a clean failure path for an unknown track).

`tests/Tests.Phase27.pas` - `AnalyzeStereoBuffer` against synthetic buffers
with known-exact answers (silence, a clipped square wave, a clean 220 Hz
sine), the JSON field names from the plan's example, the bass-masking
heuristic, and the mixing session's Preview/Reject/Apply lifecycle.

`tests/Tests.Phase28.pas` - the mastering heuristic's three branches (hot
peak, heavy low end, very dynamic mix) and the mastering session's
Preview/Compare/Reject lifecycle against a real master strip's insert count.

`tests/Tests.Phase29.pas` - the five built-in themes exist and are visually
distinct, unknown-name fallback, `ThemeColorsApply`, and a full
Save/Export/Import/Reset round trip through a private test-only theme name
that cleans up after itself.

Registered in both `tests/UDAW.Tests.dpr` and `tests/udaw_tests.lpr`.
