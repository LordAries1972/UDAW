# Phase 9 - Mixer

Status: **implemented and passing** (203/203 acceptance tests: 177 from
Phases 1-8 + 26 Phase 9, Delphi 12 / Win64). The Windows executable builds
with the mixer units linked, boots clean (log shows "phase 9") and gains a
live **Mixer** tab. `UDAW_PHASE` is bumped to 9. The project file format is
bumped to **v3** (embedded `MIXER` section).

Phase 9 delivers the plan's complete mixer, sends, buses and master
(section 10 + phase line 9): a professional channel strip (input selector,
trim gain, polarity invert, an ordered insert chain, pre/post-fader sends,
constant-power pan / unity balance, stereo width, fader, mute, solo,
record-arm, automation-mode flag, output selector), summing **buses** and
effects-return **aux** strips, a single **master**, and **VCA control
groups**. No third-party code - the model, the RT summing/routing processor,
the versioned serializer and the undo commands are written from scratch on
top of the Phase 3 DSP primitives and the Phase 4 graph nodes (reused
verbatim as insert processors).

## Layout

```
src/mixer/
  UDAW.Mixer.Model.pas          The in-memory model. TMixStrip carries every
                                channel-strip control plus live meter scalars
                                the engine writes and the UI reads. TMixerModel
                                owns the ordered strip list, always has exactly
                                one skMaster, and enforces routing sanity:
                                ValidateRouting rejects a missing / duplicate
                                master, an OutputTargetId or send that does not
                                resolve to a bus/aux/master, a self-route, and
                                any cycle in either the output graph or the
                                send graph (plan section 6: illegal feedback /
                                circular dependency / invalid bus routing).
                                AnySolo / GateGain implement solo-in-place;
                                VCATrimDb walks the (depth-limited) VCA chain.
                                RemoveStrip rewrites every dangling
                                OutputTargetId / VCAGroupId / send so the model
                                is never left inconsistent. Clone is a deep,
                                independent copy.

  UDAW.Mixer.Engine.pas         TMixerProcessor - the real-time mix processor.
                                Prepare (off the audio thread) validates the
                                routing, topologically orders the strips so
                                every producer runs before its consumer, and
                                preallocates every buffer, insert processor and
                                meter. ProcessBlock is RT-safe: no allocation,
                                no lock, no disk. Per strip, in order:
                                  input source (IMixInputProvider, for input /
                                    audio-track strips) + inbound bus feeds and
                                    sends left by earlier strips
                                  -> trim gain (click-free glide)
                                  -> polarity invert
                                  -> insert chain (hosted graph nodes in
                                     series, bypass-aware, ping-pong buffers)
                                  -> pre-fader sends
                                  -> stereo width (M/S) then placement
                                     (constant-power PAN for a mono-ish source,
                                     unity-at-centre BALANCE for a bus / aux /
                                     master so sub-mixes stay transparent)
                                  -> fader x VCA-group trim x mute/solo gate
                                     (click-free glide)
                                  -> peak L/R + RMS + BS.1770 momentary LUFS,
                                     written back onto the model strip
                                  -> post-fader sends
                                  -> summed into its output-target bus (or, for
                                     the master, into the mix output).
                                RenderToPlanar is an offline block loop for
                                tests / bounce.

  UDAW.Mixer.Serialization.pas  MixerToString / MixerFromString - a versioned
                                (UDAWMIXER 1), line-oriented, human-readable
                                text format (STRIP / INSERT / SEND records). It
                                never deserializes raw class memory: the
                                version is checked, unknown strip kinds and
                                send modes are rejected, strip ids are unique-
                                validated. Embedded in the project file as the
                                MIXER-BEGIN / MIXER-END section.

  UDAW.Mixer.Commands.pas       Undo/redo on the Phase 5 TDAWCommand /
                                TCommandManager. Structural edits (add / remove
                                strip, route output, add / remove / move an
                                insert, add / remove a send, assign a VCA
                                group) snapshot the whole mixer as text before
                                and after and restore through the serializer -
                                and reject a mutation that would make the
                                routing invalid before the command is kept.
                                Fine-grained parameter commands (fader, pan,
                                trim, width, mute, solo, polarity, record-arm,
                                send gain) mutate one field and merge a burst
                                of moves into one undo step (plan section 28:
                                "100 tiny fader movements -> one undo").
```

## Routing model

- Every audio strip flows to its `OutputTargetId` (a bus / aux / master), or
  straight to the master when that is 0. Buses and auxes may chain into
  further buses; the master is the sink.
- **Sends** are independent taps into any bus/aux/master, each pre- or
  post-fader, each with its own gain and enable. Pre-fader sends are taken
  after the inserts and before pan/fader (monitor-mix / parallel-processing
  semantics); post-fader sends follow the fader.
- **VCA** strips carry no audio - `VCATrimDb` folds their fader (and their
  mute/solo state) into every member strip's fader gain. VCA groups can nest.
- **Solo** is solo-in-place: while any audio strip is soloed, every
  non-soloed non-master audio strip is gain-gated to zero; mute always wins.

## Persistence (project file v3)

`ProjectToString` now writes a `MIXER-BEGIN ... MIXER-END` block after the
timeline block; `PROJECT_FILE_VERSION` is 3. A v1/v2 file (no `MIXER`
section) still loads - the deserializer synthesises a bare master strip so
`Document.Mixer` is always valid. `TProjectDocument` owns the model
(`Mixer` property, `ReplaceMixer` for the deserializer, deep-copied by
`Clone`). `CreateNew` seeds one master strip alongside the graph's Master
node.

## Insert host

An insert is `{kind, params, bypass}` where `kind` is a
`UDAW.Audio.Graph.Nodes` node id. Phase 9 accepts the self-contained
per-channel processors that already exist - `gain`, `pan`, `biquad`
(parametric EQ), `filterchain` (Butterworth HP/LP), `dcblock`, `delay`,
`channelmap` (widen / mono-sum / swap), `meter`. Phase 10's compressor /
limiter / gate / saturation / modulation effects register into the same
seam with no engine change; sidechain detector routing plugs into the same
`ProcessStrip` step.

## Mixer tab (design-time)

All controls are placed at design time in `UDAW.UI.MainForm.dfm` / `.lfm`
(project rule 23): a strip selector, **Track / Bus / Aux / VCA / Remove**
(each an undoable command on the shared project stack), fader-dB / pan
edits, mute / solo, an output-route selector, **Apply strip** (issues the
float / flag / route commands), **Add EQ insert**, **Undo / Redo**, a
**Render preview mix** button (builds a `TMixerProcessor` over the project
mixer, feeds a distinct tone to each audio strip, renders 0.5 s offline and
reports master peak / RMS / meter LUFS), a `Describe` + preview readout
memo, and a `TPaintBox` that draws each strip as a fader line + post-preview
meter bar.

## Tests

`tests/Tests.Phase9.pas` (26 tests):

- **mixer.model** - default has one master + valid routing; track->bus->master
  plus an aux send validates; an A<->B output cycle is rejected; routing a
  track into a track is rejected; removing a bus falls its members back to the
  master and drops sends to it while the model stays valid; solo gates the
  non-soloed strip to 0 and never the master, mute beats solo; a single and a
  nested VCA fader sum into `VCATrimDb`; a clone keeps its own fader + inserts
  when the original is mutated.
- **mixer.serialize** - a model exercising every strip kind, inserts (incl.
  bypass), sends (pre + post, incl. disabled), VCA assignment and all flags
  round-trips (`Describe` identical); an unsupported version and an unknown
  strip kind both raise `errConfig`; a project round-trips its mixer at file
  v3; a synthesised `UDAWPROJECT 2` file with the `MIXER` section removed
  loads with one master strip.
- **mixer.engine** - only-master renders exact silence; a 0.25 DC track lands
  on the master at 0.25 x cos(pi/4) per channel (constant-power centre pan);
  a -6.02 dB fader halves the level; muting one of two equal tracks halves the
  mix and soloing the other matches it exactly; a bus sums two tracks then
  applies its own -6 dB fader; a pre-fader send still feeds an aux when the
  source strip is muted while a post-fader send goes silent; a -6 dB `gain`
  insert halves the strip and a bypassed insert is transparent; a
  polarity-inverted duplicate cancels the original to <1e-4; a -6 dB VCA
  halves its member.
- **mixer.commands** - add-strip undo removes it and redo restores the same
  id; three fast fader moves collapse to one undo step that returns to the
  pre-drag value; a route command that would create a cycle raises and leaves
  the model unchanged; removing a bus by command and undoing restores the
  member's route back into that bus (structural undo works in id space -
  strip object refs do not survive a snapshot restore).

## Build wiring touched

`src/mixer` added to every search path: `UDAW.dpr`, `UDAW.dproj` (path +
`DCCReference`s), `udaw.lpr`, `udaw.lpi` (x2), `tests/UDAW.Tests.dpr`,
`tests/udaw_tests.lpr`, `tests/udaw_tests.lpi`, and
`scripts/{build,test}-windows.ps1`. `Tests.Phase9` registered in both test
runners.

## Verified

Windows / Delphi 12 only (per the project's Windows-first focus):
`scripts/test-windows.ps1` -> **203/203 pass**; `scripts/build-windows.ps1`
-> `UDAW.exe` builds and boots clean (log shows "phase 9", "Startup
complete", no exceptions). The FPC leg's source wiring (`udaw.lpr` / `.lpi`,
`.lfm`) is kept in parity but unrun on this machine (no FPC; Linux/macOS
builds are deliberately deferred).

## Deferred

- **Live device playback of individual mixer strips** - the mixer processor
  has a real `IMixInputProvider` seam, but the current Timeline player still
  exposes only its final mixed output rather than one source per timeline
  track. Mixer automation is applied by `TMixerProcessor`; routing the Timeline
  transport through it needs a per-track Timeline provider split.
- **Mixer views (compact / standard / expanded / mastering)** - a UI
  presentation concern; the model carries everything the views need.

## Mixer expansion checkpoint (unbuilt)

The Windows mixer now also contains:

- a real VST2 audio-effect host (`UDAW.Mixer.VST2`) with DLL validation,
  replacing-process audio, parameter access, native or generic editors, and
  chunk/parameter state persistence; VST3, instruments, MIDI events, and
  multi-bus plugin routing are deliberately outside this host's scope;
- version 3 `UDAWMIXER` automation lanes for fader, pan, mute, send gain, and
  VST parameter indices, with undoable breakpoint editing and read/write UI;
- undoable strip and insert reordering, adjustable strip width, popup-state
  synchronization, and timer repaint protection while popup menus are open;
- per-strip peak hold, RMS, momentary/integrated LUFS and latching clip LEDs,
  plus persisted peak-hold/decay configuration and a master loudness readout.

These additions are source-complete but have not yet been compiled or run in
Delphi 12. The earlier 203/203 verification statement above applies to the
original Phase 9 baseline, not this expansion checkpoint.
