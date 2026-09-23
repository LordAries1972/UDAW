---
name: phase4-status
description: Phase 4 audio graph — done & tested on Delphi 12 (97/97); node engine, plan swap, serializer, Graph UI tab
metadata:
  type: project
---

Phase 4 (Audio Graph) is **implemented and passing** on Delphi 12 / Win64:
97/97 acceptance tests (21 P1 + 26 P2 + 31 P3 + 19 P4). Windows `.exe` builds
and launches with a new **Graph** tab.

New units under `src/audio/graph/`:
- `UDAW.Audio.Graph.Nodes.pas` — `TAudioNode` base + concrete nodes
  (`nkInput/nkSource/nkGain/nkPan/nkBiquad/nkFilterChain/nkDCBlock/nkDelay/
  nkChannelMap/nkMeter/nkBus/nkOutput`), all built on Phase 3 DSP. id<->enum
  maps; `key=value;...` param reader.
- `UDAW.Audio.Graph.pas` — `TAudioGraph` (edit API, `Validate`, `Compile`,
  `Prepare`, `Process`), immutable `TCompiledGraph` (topo steps + preallocated
  buffers), `TGraphSource` (IAudioSource adapter). Double-buffered plans with
  an atomic active index; `Compile` publishes then waits 20 ms before freeing
  the old plan / retired nodes. Edits serialised by `FEditLock`, off the RT
  thread.
- `UDAW.Audio.Graph.Serializer.pas` — versioned line text format
  (`UDAWGRAPH 1`), field-by-field parse, rejects unknown version/kind.

Model: one summing input + one output per node; fan-in auto-sums. Validation
catches: no/duplicate Output, cycle (Kahn), connect-into-generator, Output
with no upstream (missing source), channel mismatch (`SupportsChannels`).

Wired into `UDAW.dpr`, `udaw.lpr`, `tests/UDAW.Tests.dpr`, `tests/udaw_tests.lpr`,
`udaw.lpi` + `tests/udaw_tests.lpi` search paths, and all build/test scripts
(`src/audio/graph`). Tests in `tests/Tests.Phase4.pas` (`RegisterPhase4Tests`).
Doc: `docs/Phase4-AudioGraph.md`.

UI: `src/ui/UDAW.UI.MainForm.*` **Graph** tab — preset combo, Build+analyze
(deterministic 1 s offline render + Phase 3 meters), Play graph (routes
`graph.AsSource` to the engine), Live checkbox, and a read-only paint-box
visualiser of the compiled topology coloured by meter-tap level. All controls
design-time in both `.dfm` and `.lfm`.

Deferred (by design): DSP processor nodes (compressor/reverb/etc → Phase 10/19),
recorder/automation/MIDI/synth nodes, the interactive drag-connect node editor
(current visualiser is read-only), per-node latency/PDC. FPC leg written but
unrun (no FPC on this machine). Phase 5 (project system) is next.

Also this session: added plan section 79 (MCP support) to
`docs/UDAW-Original-Plan.txt` — MCP client + optional UDAW-as-MCP-server inside
the AI/tool layer only, phases 20/26, no engine impact.
