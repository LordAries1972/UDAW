# Phase 18 - Advanced Visualization

Plan section (`docs/UDAW-Original-Plan.txt` lines 3688-3703), "Advanced
Visualization". A from-scratch analysis layer built entirely on the Phase 3
DSP foundation (`TFFT`, `TPeakMeter`, `TRmsMeter`, `TCorrelationMeter`): a
real-time spectrum analyzer, a scrolling spectrogram history, a stereo
goniometer / correlation tracker, a triggered oscilloscope capture, and a set
of classic level-meter ballistics presets (VU, PPM types 1/2, K-System
12/14/20, digital peak). `UDAW_PHASE` moves to **18**.

## Units (`src/audio/dsp/`)

| Unit | Role |
|---|---|
| `UDAW.DSP.Visualization` | `TSpectrumAnalyzer` - windowed (Hann), 75%-overlap FFT spectrum over a configurable FFT size (default 2048), with an exponential attack/release-smoothed dB spectrum plus an independent per-bin peak-hold (built on `TPeakMeter`). `TSpectrogramBuffer` - owns a `TSpectrumAnalyzer` and appends its spectrum to a fixed-depth circular row history for a scrolling spectrogram view. `TGoniometer` - a Lissajous/vectorscope point-history ring (mid/side-rotated L/R pairs) plus a `TCorrelationMeter`-backed correlation reading and a simple width estimate. `TOscilloscopeCapture` - a free-run rolling snapshot or a rising-edge-triggered fixed-length waveform capture. `TMeterBallistics` / `TBallisticMeter` - VU, PPM (two release-time variants), K-System (K-12/14/20) and digital-peak metering presets built on `TRmsMeter` / `TPeakMeter`, each with a `ReadingDb` (plain dBFS) and a `ReadingScale01` (0..1 bar position per that preset's display convention). |

## Project format

Unchanged.

## UI

Integration is expected to add a new **Scope** tab (`tabScope`) to the main
form: a mode selector (Spectrum / Spectrogram / Goniometer / Oscilloscope /
Meters) alongside a `TPaintBox` that renders whichever view is selected,
refreshed on a timer while that tab is the active one. The paint box reads
straight from a `TSpectrumAnalyzer` / `TSpectrogramBuffer` / `TGoniometer` /
`TOscilloscopeCapture` / `TBallisticMeter` fed by the live monitor tap, with
no allocation on the paint or audio-callback paths.

## Wiring

1 visualization unit added to `UDAW.dpr`, `udaw.lpr`, `UDAW.dproj`, `udaw.lpi`
and both test runners. `Tests.Phase18` registered in both test runners.

## Tests (`tests/Tests.Phase18.pas`)

Synthetic-signal-only, no reference media: `TSpectrumAnalyzer` locates a
full-scale 1 kHz tone's energy within one bin of the expected FFT bin and
close to 0 dBFS once the smoothed spectrum settles; `TSpectrogramBuffer`
accumulates history rows with the FFT-size-derived bin count and `GetRow`
does not raise for any valid row index; `TGoniometer` reads correlation near
+1 for in-phase L=R input and near -1 for out-of-phase L=-R input, and its
point history is capped at the configured size; `TOscilloscopeCapture` in
triggered mode captures exactly the configured length once a rising edge
crosses the trigger level; `TBallisticMeter` settles within a few dB of a
steady -18 dBFS tone for both the digital-peak and VU presets; and every
`TMeterBallistics` value round-trips through `MeterBallisticsId` /
`MeterBallisticsFromId`.
