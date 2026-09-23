# Phase 21 - OpenAI / ChatGPT

Plan reference: `docs/UDAW-Original-Plan.txt` line 3744 ("Fully integrate
provider and DAW assistant"). The first concrete `IAIProvider` (see
`UDAW.AI.Types`, Phase 20) - a from-scratch client for OpenAI's Chat
Completions REST endpoint, no OpenAI SDK.

## Unit (`src/ai/UDAW.AI.OpenAI.pas`)

`TOpenAIProvider` implements `IAIProvider` on top of `UDAW.AI.HTTP` (transport)
and `UDAW.AI.JSON` (request/response bodies):

* `ProviderId` -> `'openai'`, `DisplayName` -> `'OpenAI / ChatGPT'`.
* `SendMessage` builds a `{model, messages, temperature, max_tokens,
  stream:false}` body, `POST`s to `https://api.openai.com/v1/chat/completions`
  with `Authorization: Bearer <key>`, and parses
  `choices[0].message.content` / `finish_reason` / `usage.*` into
  `TAIResponse`. A non-200 status or an `"error"` object in the body raises
  `EUDAWError(errNetwork)` with the provider's own message.
* `StreamMessage` sets `stream:true` and uses `TAIHttpClient.PostStreaming`
  (per-line callback); each `data: {...}` SSE line is parsed for
  `choices[0].delta.content`, appended to an accumulator and forwarded to the
  caller's `TAIStreamDeltaProc`; a `data: [DONE]` line and any line that fails
  to parse as JSON are skipped. Inherits Phase 20's documented streaming
  caveat: `PostStreaming` itself performs the request to completion first,
  then replays lines - not yet byte-incremental.
* Default model `gpt-4o-mini` (constructor `AModel` parameter overrides it).
  `TAIRequest.Model` is not read - one model per provider instance, matching
  how the AI tab constructs a provider fresh per call.

## Factory (`src/ai/UDAW.AI.Providers.pas`)

`CreateAIProvider(const AProviderId, AApiKey: string): IAIProvider` turns a
`AI_KNOWN_PROVIDERS` id + stored key into a concrete provider - `'openai'` here,
`'claude'` in Phase 22 - and returns `nil` for `'deepseek'` / `'suno'` /
anything unrecognised (still no concrete implementation). The AI tab uses this
instead of instantiating `TOpenAIProvider` directly so a future DeepSeek
(Phase 23) is a one-line addition.

## UI

The Phase 20 **AI** tab (`tabAI`) gains a chat panel (`pnlAiChat`):
`edtAiPrompt` + **Send** (`btnAiSend`) + **Clear chat** (`btnAiClear`), with
`memAiLog` doubling as the transcript ("You: ..." / "OpenAI / ChatGPT: ...").
`btnAiSendClick` keeps the running turns in `TfrmMain.FAiHistory`
(`TArray<TAIMessage>`), looks up the stored key via `UDAW.AI.Credentials`,
creates a provider through `CreateAIProvider`, and calls `SendMessage`
synchronously (matching this codebase's existing synchronous-on-click style
for file/network operations elsewhere, e.g. MP3 import). `btnAiTestClick` now
actually calls `SendMessage` with a one-line prompt instead of only reporting
"a key is stored". Switching provider (`cboAiProviderChange`) clears
`FAiHistory` - conversations don't carry across providers.

Not added to `UDAW.UI.MainForm.lfm`: the Phase 20 AI tab itself was never
added to the Lazarus form (Delphi 12 is this project's only actively-verified
target - see `platform-focus-windows-first` project memory), so the Phase 21
chat controls follow the same gap rather than introducing a new one.

## Wiring

`UDAW.AI.OpenAI` and `UDAW.AI.Providers` added to `UDAW.dpr`, `udaw.lpr`,
`UDAW.dproj` and both test runners. `Tests.Phase21` registered in both.
`UDAW_PHASE` unchanged here (bumped to 22 in Phase 22, since the two ship in
the same pass).

## Tests (`tests/Tests.Phase21.pas`)

`TOpenAIProvider.SendMessage`/`StreamMessage` need a real endpoint and a real
key to exercise meaningfully (same rationale Phase 20 gave for leaving
`UDAW.AI.HTTP`'s live calls untested), so those are manual/interactive.
Verified here without network access: provider identity, and
`CreateAIProvider` dispatch (`'openai'` -> a working provider, case-
insensitive, `nil` for `'deepseek'`/unknown ids).
