# Phase 23 - DeepSeek

Plan reference: `docs/UDAW-Original-Plan.txt` line 3756 ("Fully integrate
provider"). The third concrete `IAIProvider` (Phase 20 abstraction; Phase 21
shipped OpenAI, Phase 22 shipped Claude) - a from-scratch client for
DeepSeek's REST endpoint, no DeepSeek SDK.

## Unit (`src/ai/UDAW.AI.DeepSeek.pas`)

`TDeepSeekProvider` implements `IAIProvider` on `UDAW.AI.HTTP` +
`UDAW.AI.JSON`. DeepSeek's API is Chat-Completions-compatible - the same
request/response shape OpenAI uses - so this is structurally identical to
Phase 21's `TOpenAIProvider`, just pointed at a different endpoint/model:

* `ProviderId` -> `'deepseek'`, `DisplayName` -> `'DeepSeek'`.
* Endpoint `https://api.deepseek.com/chat/completions`, `Authorization:
  Bearer <key>`.
* Default model `deepseek-chat` (constructor `AModel` parameter overrides
  it, e.g. to `deepseek-reasoner`).
* Request body: `model` / `messages` (role + content, via the shared
  `AIRoleId` mapping) / `temperature` / optional `max_tokens` / `stream`.
* `SendMessage` parses `choices[0].message.content`, `finish_reason` and
  `usage.prompt_tokens` / `usage.completion_tokens`, raising on an `error`
  object or an empty `choices` array.
* `StreamMessage` sets `stream:true` and reads the SSE stream through
  `TAIHttpClient.PostStreaming`: `data: [DONE]` ends the stream, other
  `data: {...}` lines are parsed and `choices[0].delta.content` is
  accumulated and forwarded. Same Phase-20-documented non-incremental
  `PostStreaming` caveat as Phases 21-22.

`UDAW.AI.Providers.CreateAIProvider` now dispatches `'deepseek'` to
`TDeepSeekProvider` alongside `'openai'`/`'claude'`; `'suno'`/unknown ids
still return `nil` (Suno is a generation client, not a chat provider - see
Phase 24).

## UI

No new controls - the AI tab's provider combo, key store, Test button and
chat panel are all provider-agnostic (`cboAiProvider` selects the id,
`CreateAIProvider` returns whichever concrete provider matches). Selecting
"DeepSeek", saving a key and using Test / Send now talks to DeepSeek with no
other change.

## Wiring

`UDAW.AI.DeepSeek` added to `UDAW.dpr`, `udaw.lpr`, `UDAW.dproj` and both
test runners. `Tests.Phase23` registered in both. `UDAW_PHASE` -> **25**
(bumped once, covering Phases 23-25 together).

## Tests (`tests/Tests.Phase23.pas`)

Same rationale as Phases 21-22: `SendMessage`/`StreamMessage` need a real key
and endpoint, left to manual testing. Verified here without network access:
provider identity and `CreateAIProvider('deepseek', ...)` dispatch
(case-insensitive).
