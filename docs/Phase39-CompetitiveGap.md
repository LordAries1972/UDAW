# Phase 39 - Competitive-gap features

Closes the gap with FL Studio / Ableton Live / Bitwig / Reaper / Cubase on the features users most often leave for. All built from scratch, offline, no third-party audio code. **Unbuilt at time of writing - compile and run `Tests.Phase39` before trusting.**

| Feature | Unit(s) | UI |
|---|---|---|
| Tempo-sync / ping-pong delay | `UDAW.DSP.Delay` | (existing Delay node already in the mixer) |
| TPDF dither on export | `UDAW.DSP.Dither`, `UDAW.Timeline.Export` | automatic |
| Noise reduction, Auto-Tune, convolution reverb, stem split | `UDAW.DSP.Spectral`, `UDAW.Timeline.SpectralFx` | Timeline > Effects |
| Step sequencer, arpeggiator, metronome events | `UDAW.Sequencer.Patterns` | metronome checkbox (live click in `TTimelinePlayer.SetMetronome`) |
| Subtractive synth + sampler | `UDAW.Synth.Instruments` | engine only (not yet on the UI) |
| Audio to MIDI (mono YIN, poly peak-picking) | `UDAW.DSP.AudioToMidi` | Timeline > Effects > Audio to MIDI |
| Warp markers (manual, snap, auto-detect, bake) | `UDAW.Timeline.Warp` | clip menu "Warp: ..." |
| Swipe comping | `UDAW.Recording.Takes` (existing model) | Recording tab |
| Modulator system (LFO/random/steps/follower/macro) | `UDAW.Mixer.Modulation`, `Mixer.Model/Serialization/Engine` | Mixer > Modulation |
| CLAP hosting | `UDAW.Mixer.CLAP` | Add VST... accepts .clap |
| VST3 hosting | `UDAW.Mixer.VST3` | Add VST... accepts .vst3 |

## Known limits
- Stem separation is classical DSP (HPSS + crossover + centre mask), not a neural model.
- CLAP/VST3 have no editor window or parameter automation yet, and no instrument support; VST3 exposes no parameter list (needs the edit controller). Neither host has been run against a real plug-in.
- Warp markers are session-only until applied; Apply bakes them into a new file via the undoable source swap and preserves clip length.
- Modulators are edited through prompts (no graphical editor) and their changes are not on the undo stack.
- Synth/sampler and step sequencer/arpeggiator have no UI yet.
- Mixer tab top panel re-laid out into four rows (no behaviour change).
