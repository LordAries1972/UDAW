# Phase 4 - Audio Graph

Status: **implemented and passing** (97/97 acceptance tests: 21 Phase 1 + 26
Phase 2 + 31 Phase 3 + 19 Phase 4, Delphi 12 / Win64). The Windows executable
builds with the graph units linked and gains a live **Graph** tab.

Phase 4 delivers the master node-based audio processing graph the plan's
section 6 calls for: a set of processing nodes built entirely on the Phase 3
DSP primitives, arbitrary DAG routing with summed fan-in, a validated
topological compile, an immutable render plan published to the real-time
thread with a single atomic store, a versioned human-readable serializer, and
the adapter that lets the Phase 2 device engine play a graph.

## Layout

```
src/audio/graph/
  UDAW.Audio.Graph.Nodes.pas       TAudioNode base + the concrete nodes, the
                                   node/biquad/oscillator id<->enum maps, and
                                   the "key=value;..." parameter reader. Every
                                   node is real processing: TGainNode ramps a
                                   one-pole (click-free), TPanNode is
                                   constant-power, TBiquadNode / TFilterChainNode
                                   / TDCBlockNode are the Phase 3 RBJ /
                                   Butterworth / DC-blocker designs, TDelayNode
                                   is a real feedback delay line with denormal
                                   flushing, TChannelMapNode does swap / mono-sum
                                   / M-S widen, TMeterNode runs the Phase 3
                                   peak / RMS / true-peak / BS.1770 chain as a
                                   unity-gain tap.
  UDAW.Audio.Graph.pas             TAudioGraph (nodes + connections + edit API +
                                   validation + compile + RT render), the
                                   immutable TCompiledGraph (topo-ordered steps
                                   + preallocated scratch buffers), and
                                   TGraphSource (IAudioSource adapter).
  UDAW.Audio.Graph.Serializer.pas  GraphToString / GraphFromString (+ file
                                   variants): a versioned, line-oriented,
                                   field-by-field text format. Never
                                   deserialises raw memory; rejects unknown
                                   versions and node kinds.
tests/Tests.Phase4.pas             the 19 acceptance tests
src/ui/UDAW.UI.MainForm.*          new "Graph" tab: pick a preset, Build +
                                   analyze (deterministic 1 s offline render
                                   with the Phase 3 meters) or Play graph
                                   (routes the compiled graph to the device
                                   engine). The paint box draws the actual
                                   compiled topology and colours meter taps by
                                   live level. Design-time controls only.
```

## Node model

A node has exactly **one logical audio input** - a summing point: the executor
sums every inbound connection into it - and **one output**. `nkInput` and
`nkSource` take no input. This keeps routing a clean DAG while still expressing
buses, sends and returns (a send is an output fanning to more than one
destination; a return is a `nkBus` that sums them).

| kind | plan node type(s) | processing |
|------|-------------------|------------|
| `nkInput` | AudioInputNode | passes the graph's external-input buffer (capture / offline feed) |
| `nkSource` | Generator/Synth/Sample (audio) | wraps an `IAudioSource` tone/sweep/noise generator |
| `nkGain` | GainNode | dB gain, ~15 ms one-pole glide, `BlockScaleRamp` |
| `nkPan` | PanNode | constant-power stereo pan / balance, glided |
| `nkBiquad` | EQNode / FilterNode | one RBJ biquad (LP/HP/BP/notch/allpass/peaking/shelf) |
| `nkFilterChain` | FilterNode | Butterworth LP/HP, order `2*pairs` |
| `nkDCBlock` | (utility) | `y = x - x1 + R*y1` DC blocker |
| `nkDelay` | DelayNode | feedback delay line, wet/dry, denormal-flushed |
| `nkChannelMap` | ChannelMapperNode | swap L/R, mono sum, mid/side widen |
| `nkMeter` | MeterNode / AnalyzerNode | unity tap: peak / RMS / true-peak / momentary+integrated LUFS |
| `nkBus` | BusNode / ReturnNode | explicit summing / routing point (unity) |
| `nkOutput` | MasterNode / AudioOutputNode | graph result + master trim; exactly one |

Processors that are whole later phases are **deliberately not** in Phase 4:
compressor / limiter / gate / reverb / chorus / distortion (Phase 10 / 19),
recorder (Phase 8), automation node (Phase 5 / 26), MIDI / synth / tracker
nodes (Phases 11-17). They slot in as new `TNodeKind`s with no change to the
graph engine.

## Node operations (plan section 6)

Connect / Disconnect (`Connect` / `Disconnect`), Insert / Remove (`AddNode` /
`RemoveNode`), Bypass / Mute (per-node flags honoured by the executor),
Reorder (implicit - the compile re-topo-sorts), Serialize / Restore
(`UDAW.Audio.Graph.Serializer`). Solo and Clone are UI-level conveniences
deferred to the mixer / editor phases.

## Validation

`Validate` mutates nothing and rejects, with a specific message:

* channel count out of range;
* not exactly one `nkOutput` node;
* **channel mismatch** - a node that cannot run at the graph's channel count
  (`SupportsChannels`), e.g. a swap/mono/widen channel map in a mono graph;
* a connection into a generator/input node (also rejected eagerly by
  `Connect`);
* dangling or self connections;
* **missing source** - the `nkOutput` node has no upstream;
* **illegal feedback** - any cycle (Kahn's algorithm; names a node on the
  cycle).

`Compile` runs `Validate`, then a Kahn topological sort, then builds a
`TCompiledGraph`. On any failure the previously compiled plan keeps running and
`LastError` is set.

## Real-time model

* `TCompiledGraph` is immutable once built: an array of steps in topological
  order, one preallocated output `TAudioBuffer` per step, plus one shared
  fan-in scratch buffer. `Render` walks the steps - clear scratch, sum the
  source buffers, then `Clear` (mute) / `CopyFrom` (bypass) / `Node.Process`
  into the step buffer - and copies the Output step's buffer to the callback
  buffer. No allocation, no locks, no IO.
* Plans are **double-buffered** (`FPlans[0..1]`) with an atomic active index.
  `Compile` builds the new plan into the inactive slot, publishes it with one
  `AtomicSet32`, then - after a 20 ms wait so any in-flight audio block on the
  old plan has finished - frees the old plan and any nodes retired by
  `RemoveNode`. `Process` reads the index once and renders that plan; if none
  is compiled yet it outputs silence.
* Structural edits (`AddNode` / `RemoveNode` / `Connect` / `Disconnect`) and
  `Compile` / `Prepare` are serialised by `FEditLock` and must run off the
  audio thread. A `RemoveNode` retires the node object (moved to `FRetired`)
  rather than freeing it, because the still-active plan may reference it until
  the next `Compile`.
* The engine plays a graph via `graph.AsSource` (a cached `TGraphSource`
  `IAudioSource`); `RenderSourceOffline(graph.AsSource, ...)` renders it
  deterministically for tests and, later, export.

## Serializer

```
UDAWGRAPH 1
CHANNELS 2
NODE 1 source "Osc"  shape=saw;freq=220;amp=0.4
NODE 2 biquad "Tone" type=lowpass;freq=1200;q=0.7;gaindb=0
NODE 3 gain   "Trim" db=-4.5
NODE 4 output "Master" db=0
CONN 1 2
CONN 2 3
CONN 3 4
```

Line-oriented, `#` comments allowed. The header version is checked
(`errConfig` on anything newer than the reader supports); the node kind is
validated against the enum; node ids are checked for uniqueness before any
`CONN` is resolved. The two boolean flags `bypass` / `mute` travel inside the
parameter field. Round-trips exactly (tested by rendering both graphs and
comparing RMS).

## Acceptance tests (`tests/Tests.Phase4.pas`)

19 tests:

* **graph.build** - build + compile a 3-node graph, step count, topo order
  (source before output); introspection (`NodeById`, `Describe`).
* **graph.validate** - no Output; two Outputs; illegal feedback cycle;
  connecting into a generator raises `EUDAWError`; Output with no upstream is a
  missing source; a stereo-only channel map in a mono graph is a channel
  mismatch.
* **graph.render** - a -6 dB gain node (peak 0.25, RMS peak/sqrt2, frequency
  preserved); summed fan-in of two sources; a muted node = silence and a
  bypassed node passes through; a biquad lowpass kills a tone an octave-plus
  above cutoff and passes one below; a 100 %-wet delay is silent until the
  delay time elapses then keeps the source RMS; a meter tap passes audio
  unchanged and reads peak / RMS / LUFS in the right ranges.
* **graph.serialize** - full round-trip (structure + a parameter + identical
  render); a future file version is rejected with `errConfig`; an unknown node
  kind is rejected.
* **graph.engine** - the `IAudioSource` adapter plays a graph through
  `RenderSourceOffline` and is cached; 25 rounds of parameter change +
  `Compile` + add/remove node + `Compile` while calling `Process`, asserting
  the output stays finite (exercises the plan-swap and node-retire paths).

Run them:

```
powershell -ExecutionPolicy Bypass -File scripts\test-windows.ps1     # Delphi 12
./scripts/test-linux.sh          # or test-macos.sh   (FPC - unverified leg)
```

## Manual check

`build\bin\UDAW.exe` -> **Graph** tab -> pick a preset (e.g. *Saw 220 Hz ->
Lowpass 1.2 kHz -> Meter -> Output*) and press **Build + analyze**: the paint
box draws the compiled node chain, the readout shows the compiled plan plus a
deterministic 1 s offline render (peak / RMS / true peak / integrated LUFS from
the Phase 3 meters). Press **Play graph** to route the same compiled graph to
the WASAPI output; the meter-tap boxes then colour by live level and the
readout switches to live meter values. **Live** re-runs the analysis each UI
tick.

## Not in Phase 4 (deliberately)

* The professional drag-and-connect node editor (minimap, automatic layout,
  selection groups, route highlighting) - the Phase 4 visualiser is read-only:
  it renders the real compiled topology and live tap levels. Interactive
  editing is UI work for a later phase.
* MIDI / AI routing visualisation - there is no MIDI or AI graph yet.
* Per-node latency reporting and automatic delay compensation (plan section
  55) - Phase 8 / 9.
* The FPC/Lazarus build of the graph units is written (unscoped RTL names,
  `udaw.inc`, wired into `udaw.lpr` / `udaw_tests.lpr`, the `.lpi` search
  paths and the `.sh` scripts) but not executed here - no FPC on this machine
  (same caveat as Phases 1-3).
```
