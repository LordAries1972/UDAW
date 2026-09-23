# Phase 25 - Voice Commands

Plan reference: `docs/UDAW-Original-Plan.txt` line 3770 ("Complete voice
pipeline."). Three focused, independently testable units, wired together by
one UI handler:

## `src/voice/UDAW.Voice.Capture.pas` - listen

`CaptureVoiceToWavFile(AEngine: TAudioEngine; AWavPath: string;
ADurationSeconds: Double): Boolean` drains `AEngine`'s live input to a 16-bit
PCM WAV file. It reuses `TAudioEngine.SetCaptureRing` - a Phase 2 hook that,
until this unit, had no caller (Phase 8's recording engine has its own
`ProcessCapturePlanar`/`ProcessCaptureBlock` feed instead) - polling a
`TAudioRing` in ~50ms slices until `ADurationSeconds` of audio has arrived or
a generous safety deadline passes, then writes it with the Phase 6
`SaveWavFile`. Uses `AEngine.Granted.CaptureChannels` / `.SampleRate`, so it
needs a full-duplex (or capture-capable) stream already open.

## `src/voice/UDAW.Voice.Recognition.pas` - transcribe

`TranscribeWavFile(AWavPath: string; out AText: string): Boolean`, Windows
-only for now. Shells out to a short generated PowerShell script that drives
.NET's `System.Speech.Recognition` (`SetInputToWaveFile` + a free-dictation
`DictationGrammar` + `Recognize()`) - part of the OS/.NET, not a third-party
library, the same way `UDAW.AI.HTTP` reuses the RTL's HTTP client instead of
vendoring one. Only text crosses the process boundary (the script writes its
result to a temp file; no pipes, no stdout parsing).

A raw-COM SAPI implementation (mirroring `UDAW.Audio.Backend.WASAPI`'s
from-scratch COM interfaces) was considered and rejected: SAPI recognition
events need either a hand-implemented `IConnectionPoint` event sink or
several dozen vtable-order-sensitive method declarations on
`ISpRecoContext`/`ISpRecoGrammar`/`ISpRecoResult` that cannot be verified
without a live Windows COM run - a wrong vtable slot order fails silently at
runtime, not at compile time. `VoiceRecognitionAvailable` reports `False` (and
`TranscribeWavFile` fails with a clear message) on non-Windows platforms.

## `src/voice/UDAW.Voice.Command.pas` - act

`ParseVoiceCommand(AText: string): TVoiceAction` matches a normalised (lower
-cased, trimmed, punctuation-stripped) transcript against a small fixed
vocabulary - `play`, `stop`/`pause`, `record`, `undo`, `redo`, `save`/`save
project`, `new track`/`add audio track`, `clear chat` - returning `vaNone` on
anything else. Deliberately has no audio/COM/process dependency, so it is
fully unit-tested without hardware or a real Windows box.

## Pipeline (`TfrmMain.RunVoicePipeline`, `UDAW.UI.MainForm.pas`)

Capture 4s -> transcribe -> `ParseVoiceCommand`. A recognised action calls the
matching existing handler directly (`btnAudioStartClick` for `vaPlay`,
`btnUndoClick` for `vaUndo`, `btnTlAddTrackClick` for `vaNewAudioTrack`, ...).
`vaNone` forwards the transcript into `SendAiChatPrompt` - the same chat path
`btnAiSendClick` uses - so an utterance that isn't one of the fixed commands
is never silently dropped, it just becomes a normal AI prompt.

`SendAiChatPrompt` is `btnAiSendClick`'s old body factored out to a
parameterised procedure so both the text box and the voice pipeline share
one code path.

## UI

New controls on the AI tab (`pnlAiVoice`, below the Suno panel): a hint label
and `btnVoiceRecord`. Everything else (the log, the resulting chat turn or
action) reuses the AI tab's existing `memAiLog` and chat history.

## Wiring

`UDAW.Voice.Command`, `UDAW.Voice.Capture`, `UDAW.Voice.Recognition` added to
`UDAW.dpr`, `udaw.lpr`, `UDAW.dproj`, and (Command only, since Capture/
Recognition need real hardware/OS to exercise) `tests/UDAW.Tests.dpr` +
`tests/udaw_tests.lpr`. `Tests.Phase25` registered in both. `UDAW_PHASE` ->
**25**.

## Tests (`tests/Tests.Phase25.pas`)

Capture and Recognition need a real device / real OS speech stack, left to
manual/interactive testing. Verified here without either: exact-match
command recognition, case/punctuation/whitespace normalisation, and the
"unrecognised text falls through to `vaNone`" behaviour the pipeline relies
on to decide "run a command" vs. "just chat".
