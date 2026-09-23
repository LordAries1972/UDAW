# Suno integration (Windows)

The integration supports two explicit API contracts, selected in the AI tab:

| API type | Base URL | Submit | Poll | Connection test |
|---|---|---|---|---|
| Self-hosted gcui-art/suno-api | `http://localhost:3000` or your deployment | `/api/generate`, or `/api/custom_generate` for custom lyrics/style | `/api/get?ids=...` | `/api/get_limit` |
| Managed SunoAPI.org | `https://apibox.erweima.ai` or the URL in your provider dashboard | `/api/v1/generate` | `/api/v1/generate/record-info?taskId=...` | `/api/v1/generate/credit` |

These are third-party contracts, not interchangeable Suno website endpoints.

**Default UX (auto-configured):** the Suno panel now defaults to the managed
SunoAPI.org contract with API type, base URL (`UDAW.AI.Suno.SUNO_MANAGED_BASE_URL`),
model (`SUNO_MANAGED_DEFAULT_MODEL`, `V6`) and callback URL
(`SUNO_MANAGED_PLACEHOLDER_CALLBACK`, an inert `https://example.com/...` URL on the
RFC 2606 reserved domain - UDAW polls for results and never actually receives a
callback) all pre-filled and disabled in the UI. The only field the user must supply
is their own API key on the Provider row. The `chkSunoAdvanced` checkbox
("Advanced (self-hosted)", off by default, persisted as `ai.suno_advanced`)
re-enables the API type/base URL/model/callback fields for a self-hosted proxy or a
non-default managed account, restoring the previous manual-configuration behavior.
`ApplySunoAutoConfig`/`chkSunoAdvancedClick` in `UDAW.UI.MainForm.pas` implement the
toggle; `cboSunoApiChange` only enables Model/Callback when both Managed is selected
and Advanced is checked.

Configure the self-hosted service and its Suno session independently. Its UDAW
API key may be blank if the proxy does not require one. Managed access requires
the provider's own key (AI Provider row: Suno); in Advanced mode it also requires a
model and a public HTTPS callback URL you control (the auto-configured default
satisfies this requirement without one). UDAW polls results; it does not host a
webhook. Provider selection, base URL, model, callback and the Advanced flag persist
when testing, generating, or toggling Advanced. Keys stay in OS secure storage.

**Model:** `edtSunoModel` was replaced with `cboSunoModel`, a `csDropDownList`
populated from the real, documented SunoAPI.org model enum (checked 2026-09-18
against https://docs.sunoapi.org/suno-api/generate-music): `V6`, `V6_WILD`,
`V6_MINI` (current tier, `V6` is the provider's own default and UDAW's default
selection), then `V5_5`, `V5`, `V4_5PLUS`, `V4_5ALL`, `V4_5`, `V4` labelled
"(deprecated)" in the UI. `TfrmMain.CurrentSunoModel`/`SetSunoModel` map the
combo's `ItemIndex` to/from the canonical `SUNO_MODEL_IDS` id (stripping the
"(deprecated)" display suffix) for the request body and for
`App.Config`/`suno_model` persistence.

**Retries:** the paid `/api/v1/generate` (or self-hosted `/api/generate`)
submission is sent exactly once and is never automatically retried - a failed
submit never risks a duplicate charge; the user must check provider history
before resubmitting. Separately, `TSunoClient.GetWithRetry` gives only the
idempotent GET calls (status poll, quota check) one automatic retry
(`SUNO_MAX_RETRIES = 1`) on a transport-level failure (timeout/DNS/connection
reset) - never on a response actually received from the provider. This is
scoped to a single dropped packet mid-poll during the up-to-ten-minute wait; it
does not resubmit generation and is not a general-purpose retry policy.

Ordinary mode interprets Prompt as a description. Custom mode interprets it as
lyrics and additionally requires Style and Title. Instrumental omits vocals.
Requests use each provider's actual field names. HTTP failures and API errors
inside HTTP 200 envelopes fail explicitly. Test validates a quota response, not
merely reachability. Polling preserves managed task IDs separately from
returned clip IDs, encodes query values, and waits for explicit completion of
all requested results. Streaming audio URLs and FIRST_SUCCESS are not
completion.

Generation, polling, download and MP3 decoding run in a cancellable UDAW job.
The status bar and Jobs tab report provider state and per-take download/decode
stages; no provider percentage is invented. Polling times out after ten minutes.
Cancel is checked during poll waits and between network/codec calls; an in-flight
HTTP request may take up to its 30-second transport timeout. Local cancellation
does not cancel or refund the remote task. Check provider history before resubmitting
after cancellation, timeout or a connection failure.

Finished MP3 takes are decoded into cached WAV files with locally generated safe
filenames. Timeline insertion uses undoable commands on the UI thread. The first
take uses the audio track selected at submission and the snapped playhead position;
alternatives use separate lanes at that position. If that track was deleted, a new
lane is used. Changing projects cancels/detaches the old job so results cannot land
in a different project. Downloaded WAVs remain in the Suno cache if import fails.

BPM/style text is a generation hint, not a guaranteed tempo grid. This change does
not add automatic silence trimming, warping, WAV-conversion API calls, extension,
or stem-separation jobs. In gcui-art's API, `/api/concat` joins extensions; it is not
stem separation. The supported retrieval path is finished full-mix MP3 to local WAV.

Contract regression tests cover both payloads, managed lifecycle, streaming state,
error envelopes, missing IDs, response wrappers and URL encoding. A paid live
generation still requires the user's configured provider and credentials.

Primary references checked 2026-09-16:
- https://github.com/gcui-art/suno-api#api-reference
- https://docs.sunoapi.org/suno-api/generate-music
- https://docs.sunoapi.org/suno-api/get-music-generation-details
- https://docs.sunoapi.org/suno-api/get-remaining-credits
