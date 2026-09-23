# Phase 3 - Internal DSP Foundation

Status: **implemented and passing** (78/78 acceptance tests: 21 Phase 1 + 26
Phase 2 + 31 Phase 3, Delphi 12 / Win64). The Windows executable builds with the
DSP units linked and gains a live **DSP** analyser tab.

Phase 3 delivers the from-scratch signal-processing primitives every later
subsystem (graph, mixer, effects, analysis, visualisation, mastering) is built
on: block/mix math, fractional interpolation, arbitrary-ratio resampling, a
radix-2 FFT, the RBJ filter family, envelope generation/detection, and a full
meter suite up to ITU-R BS.1770 loudness. No third-party code - every algorithm
is elementary numerics implemented here.

## Layout

```
src/audio/dsp/
  UDAW.DSP.Math.pas           denormal/finite guards; block ops on planar
                              Float32 (copy/add/scale/ramp, click-free mix
                              ramp); SumSquares/BlockPeak/BlockRms; pan laws
                              (linear / constant-power / -4.5 dB) and
                              equal-power crossfade; TParamSmoother (one-pole
                              parameter ramp); Hann/Hamming/Blackman/
                              Blackman-Harris windows + coherent gain;
                              NextPow2/IsPow2/IntLog2; normalised sinc
  UDAW.DSP.Interpolation.pas  ikDrop / ikLinear / ikHermite (4-point Catmull-
                              Rom) / ikLagrange3 kernels; ReadFractional with
                              edge clamping
  UDAW.DSP.Filters.pas        TBiquad - RBJ cookbook (LP/HP/BP-skirt/BP-peak/
                              notch/allpass/peaking/low-shelf/high-shelf),
                              transposed DF-II, analytic MagnitudeDb/PhaseDeg;
                              TBiquadChain (Butterworth LP/HP of order 2N);
                              TOnePole; TDCBlocker; TStateVariableFilter (TPT/
                              Zavalishin, simultaneous LP/HP/BP/notch, stable
                              under modulation)
  UDAW.DSP.FFT.pas            TFFT - radix-2 iterative, precomputed bit-reversal
                              + twiddles, allocation-free transform; complex
                              ForwardInPlace/InverseInPlace (1/N normalised),
                              RealForward/RealInverse, Magnitude/Power(dB)/Phase
                              spectra, AnalyzeDb (window + coherent-gain
                              corrected dBFS), Bin<->Hz
  UDAW.DSP.Resampler.pas      TResampler - streaming arbitrary ratio; rqLinear /
                              rqCubic (Hermite) / rqSinc (Blackman-windowed
                              polyphase sinc, cutoff tracks the ratio so it
                              anti-aliases on downsampling); retains unconsumed
                              input, reports Latency; ResamplePlanar one-shot
  UDAW.DSP.Envelope.pas       TADSR (analog-style exponential segments, gate/
                              retrigger, stage introspection); TEnvelopeFollower
                              (peak or mean-square, attack/release); TAREnvelope
                              (attack/release gain ramp)
  UDAW.DSP.Meter.pas          TPeakMeter (instant attack, dB/s release, decaying
                              peak-hold); TRmsMeter (true sliding window);
                              TTruePeakMeter (4x polyphase-sinc oversampled
                              inter-sample peak, dBTP); TLoudnessMeter (BS.1770-4
                              K-weighting, 400 ms momentary / 3 s short-term /
                              gated integrated LUFS, max M/S); TCorrelationMeter
                              (sliding L/R correlation)
tests/Tests.Phase3.pas       the 31 acceptance tests
src/ui/UDAW.UI.MainForm.*    new "DSP" tab: choose a signal + filter + FFT
                             window, render 1 s offline through the chain and
                             show the internal-FFT spectrum plus RMS / true-peak
                             / integrated + momentary LUFS / correlation and the
                             filter's |H| at 100 Hz / 1 kHz / 10 kHz
                             (design-time controls; only the analyser pixels are
                             painted at run time)
```

## Conventions

* Sample data stays canonical: IEEE **Float32**, **planar**. Coefficient math is
  done in `Double`; state variables that feed back (IIR, integrators, meter
  ballistics) are `Double` and flushed below `DSP_DENORMAL_FLOOR` (1e-20) every
  sample so the RT thread never stalls on subnormals.
* Nothing in the processing path allocates once configured. `TFFT`,
  `TBiquadChain`, `TLoudnessMeter` are classes created up front; the small
  filters, envelopes, meters and the parameter smoother are value-type records
  with an `Init` - copy them freely, they own no heap state.
* Every filter/meter takes an explicit sample rate; the BS.1770 pre-filters are
  bilinear-transformed from the spec's analog prototype so they are correct at
  any rate, not just 48 kHz.
* Parameter changes go through `TParamSmoother` / `BlockScaleRamp` /
  `BlockMixRamp` so gain, pan and cutoff moves are click-free.

## Acceptance tests (`tests/Tests.Phase3.pas`)

31 tests:

* **dsp.math** - denormal + NaN/Inf guards; block add-scaled / scale / mix-ramp;
  sum-of-squares / RMS / peak on a sine; linear & constant-power pan (unit
  energy, hard-left) and equal-power crossfade; window endpoints + Hann coherent
  gain; pow2 helpers; the parameter smoother converging and jumping on
  SetImmediate.
* **dsp.interp** - linear midpoint, Hermite passing through its nodes,
  Lagrange-3 exact on a cubic, ReadFractional clamping both edges.
* **dsp.filter** - biquad LP/HP/peaking magnitude response (-3 dB at cutoff,
  +6 dB peak, roll-off); a sine below cutoff passing while one above is killed;
  one-pole DC-unity and the DC blocker removing an offset; the SVF attenuating
  12 kHz and staying finite through 200 000 samples of high-Q modulation;
  4th-order Butterworth chain (-3 dB at cutoff, ~24 dB/oct).
* **dsp.fft** - forward/inverse identity to 1e-9 on random data; a 64-cycle sine
  landing in bin 64 at the right amplitude; a full-scale sine reading ~0 dBFS
  through `AnalyzeDb` with Hann coherent-gain correction.
* **dsp.resampler** - 24k->48k up and 48k->24k down preserving frequency and
  amplitude with the right length ratio; unity-ratio sinc resample sample-exact
  after its delay; linear-mode length ratio + pitch.
* **dsp.envelope** - ADSR reaching sustain then decaying to zero with correct
  stage transitions; peak follower tracking amplitude then releasing on silence;
  RMS-mode follower reading amp/sqrt(2).
* **dsp.meter** - peak-meter instant attack + ~2 dB/100 ms release + hold;
  sliding RMS reading -3.01 dBFS for a full-scale sine; true-peak ~0 dBTP for a
  full-scale sine and >= the sample peak for an under-sampled crest; BS.1770
  loudness: +6 dB in => +6 LU integrated, steady tone momentary ~ integrated,
  the value in a sane absolute range, and silence gating to <= -70 LUFS; stereo
  correlation reading +1 for mono and -1 for anti-phase.

Run them:

```
powershell -ExecutionPolicy Bypass -File scripts\test-windows.ps1     # Delphi 12
./scripts/test-linux.sh          # or test-macos.sh   (FPC - unverified leg)
```

## Manual check

`build\bin\UDAW.exe` -> **DSP** tab -> pick e.g. *White noise* + *Lowpass 1 kHz*
+ *Hann* and press **Analyze** (or tick **Live**): the spectrum plot is drawn
from the internal `TFFT`, the roll-off matches the printed `|H|` values, and the
RMS / true-peak / LUFS / correlation readouts come from the Phase 3 meters.

## Not in Phase 3 (deliberately)

* Effects *processors* (compressor, EQ UI, reverb, delay, saturation) - those
  are Phase 10 / 19 and are built from these primitives.
* The audio graph and the mixer engine (Phase 4 / 9).
* FIR convolution / partitioned convolution reverb, and the phase-vocoder
  time-stretch - Phase 19.
* The FPC/Lazarus build of the DSP units is written (unscoped RTL names,
  `udaw.inc`) and wired into `udaw.lpr` / `udaw_tests.lpr` and the `.sh`
  scripts, but not executed here - no FPC on this machine (same caveat as
  Phases 1-2).
