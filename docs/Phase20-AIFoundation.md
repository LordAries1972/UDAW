# Phase 20 - AI Foundation

Plan reference: `docs/UDAW-Original-Plan.txt` lines 3722-3741 (provider
abstraction / credentials / networking / JSON / streaming / cancellation /
rate handling / secure logging) and section 79 (lines 4460-4551, MCP
support). This phase delivers the plumbing every concrete AI integration
(OpenAI in Phase 21, Claude in Phase 22, DeepSeek in Phase 23, Suno later)
will sit on top of - no provider is wired up yet. `UDAW_PHASE` moves to
**20**.

## Units (`src/ai/`)

| Unit | Role |
|---|---|
| `UDAW.AI.JSON` | A from-scratch JSON value / recursive-descent parser / compact writer (no platform JSON library, matching how this project wrote its own MP3/MP4/tracker codecs). `TJSONValue` (`jkNull/jkBool/jkNumber/jkString/jkArray/jkObject`) owns its children; `Parse` raises `EUDAWError(errParse)` on malformed input; `ToJSONString` / `JSONStringify` serialize back to compact text. Foundational - every other Phase 20 unit and the Phase 21-23 provider bodies build request/response JSON on it. |
| `UDAW.AI.Credentials` | A thin AI-specific key-naming layer over `UDAW.SecureStorage.SecureStore` - no new storage mechanism. `AI_KNOWN_PROVIDERS`, `AICredentialKey` (`'<id>.api_key'`), `AIProviderDisplayName`, `IsKnownAIProvider`, and `Set/Get/Has/DeleteAIApiKey` delegating straight to `SecureStore`. |
| `UDAW.AI.RateLimiter` | `TAIRateLimiter` - a thread-safe token-bucket limiter (independent request and token buckets, continuous wall-clock refill) guarded by a `TCriticalSection` since AI calls may run on a background thread while the UI reads remaining budget. `Configure`, `TryAcquire` (returns a suggested wait when refused), `RecordActualUsage`, `Reset`, `RequestsRemaining` / `TokensRemaining`. |
| `UDAW.AI.SecureLog` | `TAISecureLog` - a redacting wrapper around `UDAW.Logging.Logger` so API keys/tokens never reach a log file. `RegisterSecret` remembers exact literals to scrub; `Redact` also defensively masks `Bearer <token>` and 20+-char runs after `sk-` / `key=` / `api_key=` / `Authorization:` even when unregistered. `Info/Warn/Error/Debug` redact then forward to `Logger`. Process-wide `AISecureLog` accessor, matching the `Logger` singleton pattern. |
| `UDAW.AI.HTTP` | `TAIHttpClient` - synchronous HTTP on the RTL's own client (`System.Net.HttpClient` / FPC `fphttpclient`, not a third-party library). `Post` / `Get` raise `EUDAWError(errNetwork)` on failure and `errCancelled` if the call's `TAICancelToken` is already cancelled. `PostStreaming` invokes a `TAIStreamLineProc` once per line of an SSE-shaped response (documented fallback: performs the request to completion then replays line-by-line; true incremental delivery is a Phase 21+ hardening item once a concrete provider stream exists to test against). All requests are logged through `UDAW.AI.SecureLog` at method+URL+length only - headers/body content are never logged verbatim. |
| `UDAW.AI.Types` | Shared chat-style vocabulary: `TAIRole` (+`AIRoleId`/`AIRoleFromId`), `TAIMessage`, `TAIRequest`, `TAIResponse`, `TAIStreamDeltaProc`, and the `IAIProvider` interface. Abstraction only - Phases 21-23 supply concrete providers. |
| `UDAW.AI.MCP` | Plan section 79's Phase-20 scope: `IMCPTransport` with `TMCPStdioTransport` (newline-delimited JSON-RPC 2.0 over a child process's stdin/stdout - real MCP stdio framing, not Content-Length framing; Win32 `CreateProcess`+pipes or FPC `TProcess`, a background reader thread, `SendRequest` polls for the matching `id` with an `errTimeout` timeout) and `TMCPHttpTransport` (JSON-RPC over `UDAW.AI.HTTP`; full SSE server push is a later hardening item); `IMCPClient`/`TMCPClient` (`ListTools`, `CallTool`, built on `UDAW.AI.JSON`); `TMCPServerRegistry`, an in-memory (no persistence yet) named list of `TMCPServerConfig`. Does **not** implement `TMCPToolBridge` - that arrives once a concrete AI provider exists. |

## Project format

Unchanged.

## UI

Integration (outside this phase's scope) is expected to add a new **AI**
tab (`tabAI`) to the main form: a provider dropdown (OpenAI / Claude /
DeepSeek / Suno), a masked API-key entry field with Save / Test / Delete
buttons wired to `UDAW.AI.Credentials`, an MCP servers list (add/remove,
stdio or HTTP) wired to `TMCPServerRegistry`, and a log memo showing
redacted `AISecureLog` output. No concrete AI provider is wired up yet -
the dropdown will have nothing to actually call until Phases 21-23 land.
This phase is foundation plumbing only.

## Wiring

7 AI-foundation units added to `UDAW.dpr`, `udaw.lpr`, `UDAW.dproj`,
`udaw.lpi` and both test runners, under a new `src/ai/` directory.
`Tests.Phase20` registered in both test runners.

## Tests (`tests/Tests.Phase20.pas`)

`UDAW.AI.JSON`: a nested document (object containing a string, a number, a
bool, a null and an array of objects) parses correctly with every field
verified via `ByName`/`Items`; `ToJSONString` followed by re-`Parse` is
stable; malformed JSON raises `EUDAWError` with `Code = errParse`.
`UDAW.AI.Credentials`: `IsKnownAIProvider` for all four known ids plus a
negative case, `AICredentialKey` naming, and `AIProviderDisplayName`
mapping - deliberately **not** testing actual secret storage round-trips,
since that exercises the OS credential vault and belongs to
interactive/manual testing. `UDAW.AI.RateLimiter`: a first acquire
succeeds with no wait, hammering far beyond the configured budget
eventually fails with a positive suggested wait, and `Reset` restores full
budget. `UDAW.AI.SecureLog`: a registered secret is scrubbed from a log
line, and a `Bearer <token>` shaped string is masked even without explicit
registration. `UDAW.AI.Types`: every `TAIRole` round-trips through
`AIRoleId`/`AIRoleFromId`. Two extra checks that need neither real network
I/O nor a real child process are included: `TAICancelToken.Cancel`/
`IsCancelled` in isolation, and `TMCPServerRegistry.Add`/`Remove`/
`FindByName` against its in-memory list. `UDAW.AI.HTTP`'s actual
`Post`/`Get`/`PostStreaming` calls and `UDAW.AI.MCP`'s stdio/HTTP
transports are intentionally left untested here - they need a real network
endpoint or a real child process to exercise meaningfully, which becomes
possible once a concrete AI provider or MCP server exists to test against
in Phase 21+.
