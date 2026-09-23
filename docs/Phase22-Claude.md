# Phase 22 - Claude

Plan reference: `docs/UDAW-Original-Plan.txt` line 3750 ("Fully integrate
provider"). The second concrete `IAIProvider` (Phase 20 abstraction, Phase 21
shipped OpenAI) - a from-scratch client for Anthropic's Messages REST
endpoint, no Anthropic SDK.

## Unit (`src/ai/UDAW.AI.Claude.pas`)

`TClaudeProvider` implements `IAIProvider` on `UDAW.AI.HTTP` + `UDAW.AI.JSON`,
same shape as Phase 21's `TOpenAIProvider` but matched to the Messages API's
differences:

* `ProviderId` -> `'claude'`, `DisplayName` -> `'Claude'`.
* Auth is `x-api-key: <key>` + `anthropic-version: 2023-06-01`, not a Bearer
  token.
* The Messages API has no `system` role inside the `messages` array: every
  `arSystem` message in the request is concatenated (newline-joined) into a
  top-level `"system"` string instead. `arTool` has no first-class mapping
  yet (arrives with Phase 26's structured tool bridge) - folded into a
  `"user"` turn prefixed `[tool]: ` so a round-trip never silently drops
  content. `max_tokens` is required by the API; defaults to 1024 when the
  caller's `TAIRequest.MaxTokens` is `<= 0`.
* `SendMessage` parses the reply's `content` array, concatenating every
  block whose `"type"` is `"text"` (Claude can return other block types;
  those are skipped, not concatenated) into `TAIResponse.Content`, plus
  `stop_reason` and `usage.input_tokens` / `usage.output_tokens`.
* `StreamMessage` sets `stream:true` and reads Claude's SSE stream through
  `TAIHttpClient.PostStreaming`'s per-line callback: `event: ...` framing
  lines are skipped, `data: {...}` lines are parsed and any `delta.text`
  field (present on `content_block_delta` events) is accumulated and
  forwarded. Same Phase-20-documented non-incremental `PostStreaming` caveat
  as Phase 21.
* Default model `claude-sonnet-5` (constructor `AModel` parameter overrides
  it). Like `TOpenAIProvider`, `TAIRequest.Model` is not read.

`UDAW.AI.Providers.CreateAIProvider` now dispatches `'claude'` to
`TClaudeProvider` alongside Phase 21's `'openai'`; `'deepseek'`/`'suno'`/
unknown ids still return `nil`.

## UI

No new controls - Phase 21's chat panel and Test button are provider-agnostic
(`cboAiProvider` selects the id, `CreateAIProvider` returns whichever concrete
provider matches). Selecting "Claude", saving a key and using Test / Send now
talks to Anthropic instead of OpenAI with no other change.

## Wiring

`UDAW.AI.Claude` added to `UDAW.dpr`, `udaw.lpr`, `UDAW.dproj` and both test
runners. `Tests.Phase22` registered in both. `UDAW_PHASE` -> **22**.

## Tests (`tests/Tests.Phase22.pas`)

Same rationale as Phase 21: `SendMessage`/`StreamMessage` need a real key and
endpoint, left to manual testing. Verified here without network access:
provider identity and `CreateAIProvider('claude', ...)` dispatch.
