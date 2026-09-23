# Phase 19 - Advanced DSP

Plan section (docs/UDAW-Original-Plan.txt lines 3706-3719, "Advanced DSP").
Four new internal DSP units add multiband dynamics, a lookahead/brick-wall
compressor, a full stereo mastering chain, and an offline phase-vocoder
time-stretch / pitch-shift pair, all built from the existing Phase 3/10
primitives (`TBiquad`, `TDynamicsProcessor`, `TTruePeakMeter`,
`TLoudnessMeter`, `TFFT`, `TResampler`) with no third-party code. `UDAW_PHASE`
moves to **19**.

## Units (`src/audio/dsp/`)

| Unit | Role |
|---|---|
| `UDAW.DSP.MultibandComp` | `TMultibandCompressor` - a fixed 3-band (low/mid/high) compressor/limiter. Each channel is split into bands by a cascaded 4th-order Linkwitz-Riley crossover (two cascaded `TBiquad` Butterworth sections per crossover point, at settable `LowMidHz` / `MidHighHz`), each band runs through its own fully-parameterizable `TDynamicsProcessor`, and the three processed bands are summed back to the channel. Also `TAdvancedCompressor` - a lookahead-capable compressor/limiter: it reuses `TDynamicsProcessor` for the whole detector/curve/ballistics chain and adds a per-channel circular delay line so the *audio* path lags the *detector* path by `LookaheadMs` (0-20 ms), letting gain reduction react to a transient before it reaches the output. |
| `UDAW.DSP.Mastering` | `TMasteringChain` - a stereo (2-channel) mastering processor combining, in order: an internal `TMultibandCompressor` for glue/tone shaping; a mid/side stereo-width control (`WidthAmount`); a brick-wall true-peak-safe limiter stage built on an internal `TTruePeakMeter` per channel plus a short lookahead delay and a fast-attack/slow-release gain follower, backstopped by a final per-sample hard ceiling clamp so `CeilingDb` is a hard guarantee, not just a target; and a loudness-normalize stage built on an internal `TLoudnessMeter`, implemented as a slow-adapting AGC that nudges a running gain toward `TargetLufs` using the meter's `ShortTerm` reading every block (documented in-unit as the reason it needs no separate priming pass). |
| `UDAW.DSP.TimeStretch` | `TPhaseVocoderStretch` - an OFFLINE (not real-time-safe) classic STFT phase vocoder built on `TFFT`: Hann-windowed analysis frames at hop `Ha = FFTSize/4`, per-bin phase-difference unwrapping against the expected on-bin phase advance to recover true instantaneous frequency, phase accumulation scaled by the synthesis hop `Hs = Round(Ha*Stretch)` instead of `Ha`, and windowed overlap-add normalised by the accumulated window-square sum. `Process` stretches a buffer by an arbitrary factor in 0.25..4.0; `EstimateOutputLength` predicts the result length. |
| `UDAW.DSP.PitchShift` | `TPitchShifter` - pitch-shift without changing duration, built as the classic pairing of `TPhaseVocoderStretch` (stretch by `2^(semitones/12)`) followed by resampling the stretched buffer back down by the inverse ratio using `UDAW.DSP.Resampler`'s `ResamplePlanar` one-shot helper, trimmed/padded to the original input length. |

## Project format

Unchanged.

## UI

`TMultibandCompressor` and `TMasteringChain` are real-time audio-graph node
kinds (`nkMultibandComp`, `nkMastering`) available from the Mixer's insert
palette (`UDAW.Mixer.Engine.InsertKindAllowed`; "Multiband Compressor" /
"Mastering Chain" in `cboMixInsertKind`), alongside the existing dynamics/
modulation/distortion/reverb/EQ nodes from Phase 10. `TPhaseVocoderStretch`
and `TPitchShifter` are offline buffer-processing tools rather than
real-time nodes; the Advanced DSP tab's "Project Mix (Timeline)" signal
choice runs them (and the Scope tab's analysis) against the actual project
timeline mix instead of only a synthetic tone/sweep/noise signal, though
that is the whole timeline's rendered output rather than a single selected
clip/take buffer.

## Wiring

4 advanced-DSP units added to `UDAW.dpr`, `udaw.lpr`, `UDAW.dproj`, `udaw.lpi`
and both test runners. `Tests.Phase19` registered in both test runners. Two
new `TNodeKind` values (`nkMultibandComp`, `nkMastering`) added to the audio
graph.

## Tests (`tests/Tests.Phase19.pas`)

`TMultibandCompressor`: with every band set transparent (0 dB threshold, 1:1
ratio) a full-scale sine's 3-band-summed output stays within a few dB of the
input RMS (checks the LR4 crossover sums back to roughly flat); with the low
band's threshold dropped and ratio raised, a low-frequency tone produces
nonzero `BandGainReductionDb(0)` while a high-frequency-only tone leaves it
near zero. `TAdvancedCompressor`: a 5 ms lookahead is configured without
crashing and `CurrentGainReductionDb` is nonzero after a silence-to-full-
scale step. `TMasteringChain`: a full-scale sine through a -3 dB ceiling
never peaks above that ceiling (linear peak scan with a small epsilon).
`TPhaseVocoderStretch`: a 440 Hz sine stretched by 2.0 comes back roughly
twice as long, and an FFT peak-bin check on a window from the middle of the
output confirms the dominant frequency is still close to 440 Hz.
`TPitchShifter`: a 440 Hz sine shifted up 12 semitones keeps its length close
to the original and its dominant frequency close to 880 Hz. Tolerances are
generous throughout - these check for gross breakage, not exact DSP values.
