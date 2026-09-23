# Luma (video/image) provider

Client: `src/ai/UDAW.AI.Luma.pas`. Base `https://api.lumalabs.ai/dream-machine/v1`, Bearer key.
POST `/generations/video|image` -> poll GET `/generations/{id}` (queued/dreaming/completed/failed) -> download `assets.video|image`. GET `/credits` (USD cents).
Luma has no music / lyrics / instrumental / sheet-music API: `LumaCapabilities` reports them False and the AI tab hides those controls.
Generate runs as `TLumaGenerationJob` (UDAW.Jobs), output saved to `<Recordings>\Luma`. Timeline video import deferred to the video phase.
Not implemented: "add audio to a generation" (contract unconfirmed). Tests: `tests/Tests.Luma.pas` (offline).
