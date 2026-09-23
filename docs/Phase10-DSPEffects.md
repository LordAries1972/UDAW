# Phase 10 - DSP Effects

Status: **implemented and passing** (228/228 acceptance tests: 203 from
Phases 1-9 + 25 Phase 10, Delphi 12 / Win64). The Windows executable builds
with the new DSP units linked and boots clean (log shows "phase 10"). The
Mixer tab gains an insert palette. `UDAW_PHASE` is bumped to 10.

Phase 10 delivers the plan's core built-in DSP effect suite (section 11): the
processors that were missing after Phases 3-4 (which already provided gain,
pan, RBJ biquads = parametric / shelving EQ + LP/HP/BP/notch filters,
Butterworth filter chains, DC removal, delay/echo and a stereo widener). New
this phase: **dynamics** (compressor, limiter, downward expander, noise gate,
de-esser), **modulation** (chorus, flanger, phaser, tremolo, auto-pan),
**distortion** (saturation, hard-clip, wave-folder, bit-crusher), an
**algorithmic reverb**, and a **graphic EQ**. Each is a from-scratch
processor built only on the Phase 3 primitives (`TEnvelopeFollower`,
`TBiquad`, `TParamSmoother`, denormal flushing), wrapped as an audio-graph
node, and hostable as a mixer insert - including **external sidechain**
routing for the compressor.

## New units (`src/audio/dsp/`)

```
UDAW.DSP.Dynamics.pas    TDynamicsProcessor - one stereo-linked processor with
                         modes dynCompressor / dynLimiter / dynExpander /
                         dynGate / dynDeEsser. Detector: TEnvelopeFollower over
                         a mono key (channel-summed input, an external
                         sidechain buffer, or - for the de-esser - a
                         high-passed copy). A standard quadratic soft-knee
                         static curve turns the detector level into a target
                         gain in dB; the follower's attack/release give the
                         ballistics; a hold counter keeps the gate open; makeup
                         gain follows. CurrentGainReductionDb for metering.
                         Nothing allocates after Configure.

UDAW.DSP.Modulation.pas  TModulationProcessor - modChorus / modFlanger (feedback
                         + shorter base delay) as a linear-interpolated
                         modulated delay line per channel; modPhaser as a
                         swept first-order all-pass cascade with feedback;
                         modTremolo as in-phase amplitude modulation; modAutoPan
                         as a constant-power pan position swept in anti-phase.
                         A stereo LFO phase offset widens chorus / flanger /
                         auto-pan. Delay lines sized once (MOD_MAX_DELAY_MS).

UDAW.DSP.Distortion.pas  TDistortionProcessor - distSaturation (tanh),
                         distHardClip, distFoldback (wave-folder), distBitCrush
                         (2^bits mid-rise quantiser + sample-and-hold
                         downsampling). drive pre-gain, trim post-gain, mix
                         for parallel processing.

UDAW.DSP.Reverb.pas      TAlgoReverb - a Schroeder/Freeverb-family topology
                         (implemented from the well-known structure, no
                         third-party code): pre-delay -> tapped early
                         reflections -> 8 parallel LP-damped comb filters
                         (right-channel lengths offset by REV_STEREO_SPREAD for
                         decorrelation) -> 4 series all-pass diffusers -> a
                         width matrix -> wet/dry mix. Comb / all-pass tunings
                         are the classic 44.1 kHz values scaled to the running
                         rate. size, damp, width, mix, predelay, early / tail
                         levels.

UDAW.DSP.GraphicEQ.pas   TGraphicEQ - a bank of fixed-frequency peaking TBiquads
                         (10 ISO octave centres by default, up to 31 bands on a
                         geometric grid), one per band, cascaded per channel,
                         each band's gain settable -18..+18 dB.
```

## Graph-node wrappers (`UDAW.Audio.Graph.Nodes`)

Five new `TNodeKind`s - `nkCompressor`, `nkModulation`, `nkDistortion`,
`nkReverb`, `nkGraphicEQ` - each a `TEffectNodeBase` subclass that gathers the
buffer channel pointers once (no RT allocation), drives its processor, and
round-trips its parameters through the same `key=value;...` string the graph
serializer and the Mixer tab already use. `TAudioNode` gains a virtual
`SetSidechain(TAudioBuffer)` (no-op by default; `TCompressorNode` overrides it
to key its detector off an external buffer). `CreateNode`, `NodeKindId`,
`NodeKindDisplay` and the graph text serializer pick the new kinds up with no
other change, so a project graph can now contain a reverb or a compressor and
round-trip it.

## Mixer integration + external sidechain

`UDAW.Mixer.Engine.InsertKindAllowed` now accepts the five new kinds, so any
strip's insert chain can host them. `TMixInsert` gains `SidechainStripId`
(0 = internal / program-dependent key). When an insert names a sidechain
source:

- `BuildOrder` adds a producer->consumer edge (key strip before the strip
  that keys off it); a sidechain that would close a loop is rejected at
  `Prepare` alongside output / send feedback.
- The key strip publishes its **post-insert, pre-fader** signal into a
  per-strip `FScTap` buffer each block (pre-fader, so the key can be faded
  right down in the mix and still drive the detector).
- Just before the consumer strip runs its inserts, the engine calls
  `SetSidechain(keyRT.FScTap)` on each sidechain insert.

## Mixer tab (design-time)

The single "Add EQ insert" button is replaced by an **insert palette**: a
`cboMixInsertKind` combo (Trim gain / Parametric EQ / Graphic EQ / Compressor
/ Limiter / Noise gate / Chorus / Saturation / Reverb / Delay), **Add insert**
and **Remove insert** buttons - all issuing the Phase 9 undoable
`TAddMixInsertCommand` / `TRemoveMixInsertCommand` on the shared project
stack. The existing **Render preview mix** button now exercises the full
insert chain (inserts hosting the new processors) through `TMixerProcessor`.

## Tests

`tests/Tests.Phase10.pas` (25 tests):

- **dsp.dynamics** - compressor squashes a loud sine above threshold and
  passes a quiet one untouched (and reports gain reduction); limiter holds a
  0.95 sine near its -6 dB ceiling; gate stays open on the loud half and
  attenuates the -50 dB tail; expander pulls a below-threshold tone down far
  more than an above-threshold one; de-esser ducks a loud 8 kHz tone but not
  an equally loud 200 Hz one; +6 dB makeup doubles the output.
- **dsp.modulation** - full-depth tremolo dips a DC signal near silence and
  back; auto-pan sweeps the image fully left and right in anti-phase; chorus
  colours a 440 Hz tone (changes it) while keeping the level in the same
  ballpark and staying finite; a heavy-feedback phaser stays finite and
  bounded.
- **dsp.distortion** - tanh saturation cannot exceed full scale and is not a
  linear gain; hard-clip pins peaks at +/-1 for a large fraction of samples;
  3-bit crush yields a handful of output levels; downsampling holds each value
  for the factor; mix=0 is a clean bypass.
- **dsp.reverb** - a mono impulse leaves a tail that is still present at ~100
  ms and has decayed by ~475 ms; the L and R tails of a mono impulse are
  decorrelated; mix=0 is a clean bypass; 2 s of dense input stays finite and
  bounded.
- **dsp.graphiceq** - a +12 dB boost on the 1 kHz band lifts a 1 kHz tone and
  barely touches an 8 kHz tone; a flat EQ is transparent; band count / centre
  accessors are correct.
- **dsp.nodes** - the five effect nodes round-trip their parameter strings; a
  `nkCompressor` node reduces the settled peak of a loud source through a
  compiled `TAudioGraph`; the graph text serializer preserves a distortion +
  reverb node.
- **dsp.mixer** - a distortion insert audibly changes a strip's output; a loud
  external-sidechain key strip ducks a compressed strip (and stops ducking
  when the key goes silent).

## Build wiring touched

The five DSP units live in `src/audio/dsp` (already on every search path);
they are added to the `uses` lists of `UDAW.dpr`, `UDAW.dproj`
(`DCCReference`s), `udaw.lpr`, `tests/UDAW.Tests.dpr`, `tests/udaw_tests.lpr`,
before `UDAW.Audio.Graph.Nodes` (which now depends on them). `Tests.Phase10`
registered in both test runners.

## Verified

Windows / Delphi 12 only: `scripts/test-windows.ps1` -> **228/228 pass**;
`scripts/build-windows.ps1` -> `UDAW.exe` builds and boots clean ("phase 10",
"Startup complete", no exceptions). The FPC leg's source wiring is kept in
parity but unrun (no FPC; Linux/macOS builds deliberately not run).

## Deferred (deliberately, per the plan's phase order)

- **Mastering processors** - multiband compressor / limiter, dynamic EQ,
  stereo imager, loudness maximizer, true-peak limiter, mid-side processor -
  are **Phase 19** (Advanced DSP), together with time-stretch / pitch-shift.
- **Effect parameter automation** - Phase 26 (the automation engine reads /
  writes the curves; the node parameters are already fully addressable).
- **Per-effect editor UI** - the Mixer tab adds effects with sane preset
  parameters and the graph text is fully editable; dedicated knob panels are a
  later UI pass.
