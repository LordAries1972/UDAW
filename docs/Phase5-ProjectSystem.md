# Phase 5 - Project System

Status: **implemented and passing** (115/115 acceptance tests: 21 Phase 1 +
26 Phase 2 + 31 Phase 3 + 19 Phase 4 + 18 Phase 5, Delphi 12 / Win64). The
Windows executable builds with the project units linked and gains a live
**Project** tab.

Phase 5 delivers the plan's project system (section 67, Phase 5; sections 27
and 28): project creation, save, open, autosave, recovery, undo, redo - built
directly on the Phase 4 audio graph rather than a placeholder.

## Layout

```
src/project/
  UDAW.Project.Document.pas       TProjectDocument: identity (UUID), tempo /
                                   time signature / sample rate / channels,
                                   validated property setters that stamp
                                   ModifiedUTC and mark the document dirty,
                                   and the master TAudioGraph (starts with
                                   just the Master output node). Clone() makes
                                   a fully independent deep copy for autosave.
  UDAW.Project.Serialization.pas  ProjectToString / ProjectFromString (+ file
                                   variants): a versioned, sectioned, human-
                                   readable text format. The routing section
                                   is the Phase 4 graph text verbatim (reuses
                                   GraphToString/GraphFromString - routing is
                                   never re-derived). SaveProjectToFile is
                                   atomic (temp file + rename, mirrors
                                   UDAW.Config.Save).
  UDAW.Project.Commands.pas       TDAWCommand / TCommandManager (Command
                                   Pattern undo/redo, plan section 28), plus
                                   concrete commands for project metadata
                                   (name/tempo/time signature) and for the
                                   Phase 4 graph edit API (add/remove node,
                                   connect/disconnect, set a node's
                                   parameters). Commands can absorb a rapid
                                   follow-up edit of the same kind so a burst
                                   of fader/tempo nudges collapses into one
                                   undo step.
  UDAW.Project.Recovery.pas       TProjectRecoveryManager: rotating autosave
                                   backups (*.autosave.1/2/3, primary file
                                   never touched by autosave) and an "open
                                   marker" file that reveals an unclean
                                   shutdown the next time the same project
                                   path is opened.
tests/Tests.Phase5.pas            the 18 acceptance tests
src/ui/UDAW.UI.MainForm.*         new "Project" tab: name/tempo/time-sig/
                                   sample-rate/channels fields, New/Open/Save/
                                   Save As, Undo/Redo (captioned with the
                                   command description), two demo buttons
                                   that add/remove a graph node through the
                                   command manager, an autosave-interval
                                   picker + manual Autosave + Recover, and a
                                   read-only status memo. Design-time controls
                                   only.
```

## Document model

`TProjectDocument` is the root object every later phase's own section hangs
off. Right now it owns:

* identity - `UUID` (a stable `TGUID` minted once, survives renames/moves)
  and `FileName` (empty until the first Save);
* transport metadata - `Name`, `TempoBPM` (20-999), `TimeSigNum` (1-64),
  `TimeSigDen` (a power of two, 1-64), `SampleRate` (8000-384000 Hz),
  `Channels` (1-32) - every setter validates and raises `EUDAWError` on a bad
  value, so a corrupt or hostile value can never enter the document silently;
* `CreatedUTC` / `ModifiedUTC` and a `Dirty` flag, kept in lock-step: every
  setter that actually changes something calls `Touch`, so autosave and a
  "you have unsaved changes" prompt never need separate bookkeeping;
* `Graph: TAudioGraph` - the Phase 4 master routing graph. `CreateNew` seeds
  it with just the persistent `Master` (`nkOutput`) node, matching the plan's
  "no production feature is represented by a stub": a brand-new project has
  nothing routed yet, exactly like a fresh DAW session.

`Clone` produces a fully independent document (its own `TAudioGraph`, node
for node, connection for connection) so the recovery manager can snapshot a
live, possibly-still-being-edited document from a background job without
racing the UI thread.

## Serializer (plan section 27)

"Do not save the entire project in one fragile binary structure" is met with
a sectioned, versioned, line-oriented text format - the same philosophy as
the Phase 4 graph serializer, one level up:

```
UDAWPROJECT 1
UUID {B78E2A5E-1234-4B11-9ABC-0123456789AB}
NAME "My Song"
CREATED 2026-09-09 12:00:00
MODIFIED 2026-09-09 12:05:30
TEMPO 128.000000
TIMESIG 4 4
SAMPLERATE 48000
CHANNELS 2
GRAPH-BEGIN
UDAWGRAPH 1
CHANNELS 2
NODE 1 output "Master" -
GRAPH-END
```

The `GRAPH-BEGIN`/`GRAPH-END` block is the *unmodified* Phase 4 graph text -
`ProjectFromString` collects the lines between the markers and hands them to
`GraphFromString` as-is, so routing round-trips byte-for-byte through code
that is already independently tested. The outer header version is checked
first (`errConfig` on anything newer than the reader supports, before a
document object even exists); every field is parsed and validated
individually (`TryStrToInt`/`TryStrToFloat`/`StringToGUID`, never a raw
memory cast); an unrecognised line at the top level is a hard parse error,
not a silently-skipped one. `SaveProjectToFile` writes to `<file>.tmp` then
deletes-and-renames into place, so a crash or power loss mid-write can never
corrupt the previous good copy.

## Undo / redo (plan section 28)

`TDAWCommand` is `Execute` / `Undo` / `Redo` (default: re-`Execute`) /
`Description`, plus `AbsorbNext` for merging. `TCommandManager.Perform`
always consumes the command it is given - executed-and-kept on the undo
stack, absorbed-and-freed into the command already on top, or freed on
failure/exception - so call sites never manage command lifetime themselves.
A successful `Perform` clears the redo stack, exactly like every other
editor's undo model.

Shipped concrete commands:

* `TSetProjectNameCommand`, `TSetTempoCommand`, `TSetTimeSignatureCommand` -
  project metadata, each with a `AbsorbNext` that merges edits arriving
  within an 800 ms window (`COMMAND_MERGE_WINDOW_MS`) into the command
  already on top of the undo stack - a burst of "nudge the tempo four times"
  becomes one undo step, exactly the plan's "100 tiny fader movements ->
  one undo operation" example.
* `TAddGraphNodeCommand` / `TRemoveGraphNodeCommand` - wrap the Phase 4
  `TAudioGraph.AddNode`/`AddNodeWithId`/`RemoveNode`. Redo re-adds a node
  with the *same id* it originally got (`AddNodeWithId`), so any command
  that references that id later in the stack (a connect, a parameter change)
  keeps working after an undo/redo round trip. Removing a node snapshots its
  kind, name, parameters, bypass/mute flags and every connection touching it,
  so Undo restores it exactly, connections included.
* `TConnectNodesCommand` / `TDisconnectNodesCommand` - thin wraps of
  `Connect`/`Disconnect`, inverse of each other.
* `TSetNodeParamsCommand` - generic: works for *any* node type via the
  `SerializeParams`/`DeserializeParams` pair every `TAudioNode` already
  implements (Phase 4), so a gain fader, an EQ knob or a delay time all reuse
  one command class and the same rapid-edit merge behaviour.

Later phases (tracks, clips, tracker patterns, mixer) add their own
`TDAWCommand` descendants against this same `TCommandManager` - nothing here
changes.

## Autosave + crash recovery (plan sections 56/57)

`TProjectRecoveryManager` rotates up to `AMaxBackups` (default 3) numbered
backups next to the project file - `MySong.udawproj.autosave.1` (newest) up
to `.autosave.3` (oldest kept) - and **never writes the primary project
file**; only an explicit Save does that. Each `AutosaveNow` clones the live
document (so it never races an in-flight edit) and serializes the clone
through the same atomic `SaveProjectToFile` a manual save uses. `Tick` is the
UI-thread convenience: it autosaves only when the configured interval (Off /
1 / 2 / 5 / 10 minutes / Custom) has elapsed *and* the document is actually
`Dirty` - an untouched project is never rewritten.

Crash detection is a tiny "open marker" file (`<project>.open`) written by
`BeginSession` and deleted by `EndSessionClean` (called on an explicit save,
a clean project close, or normal app shutdown). If the marker is still there
the next time the same path is opened, `HasUncleanShutdown` reports it, and
`ListRecoveryCandidates`/`RecoverNewest` find the newest of every autosave
backup plus the primary file itself (by modification time) to restore.

## Acceptance tests (`tests/Tests.Phase5.pas`)

18 tests across four groups:

* **project.document** - defaults and dirty-tracking (`CreateNew` starts
  clean with just the Master node); every validated setter rejects an
  out-of-range value with `EUDAWError`; `Clone` is a fully independent copy.
* **project.serialize** - full text round-trip (metadata + embedded graph +
  a graph node's parameters + a connection); file round-trip through the
  atomic save/load path; a future document version is rejected with
  `errConfig`; a missing header and a corrupt field are both rejected rather
  than silently defaulted.
* **project.commands** - tempo undo/redo; a burst of four rapid tempo edits
  collapsing into one undo step; name + time-signature undo/redo; add/undo/
  redo a graph node (same id preserved across redo); removing a connected
  node and undoing it restores both the node and its connection with its
  original parameters; a burst of node-parameter edits merging into one undo
  step; `Clear` frees both stacks.
* **project.recovery** - autosave rotation (four autosaves, exactly three
  kept, oldest replaced, primary file never written); unclean-shutdown
  marker written/detected/cleared; recovering the newest candidate after a
  simulated crash restores the latest autosaved content bound back to the
  primary path; `Tick` autosaves only once dirty *and* the interval has
  elapsed.

Run them:

```
powershell -ExecutionPolicy Bypass -File scripts\test-windows.ps1     # Delphi 12
./scripts/test-linux.sh          # or test-macos.sh   (FPC - unverified leg)
```

## Manual check

`build\bin\UDAW.exe` -> **Project** tab. **New** starts a fresh untitled
project (just the Master node); edit Name/Tempo/Time sig./Sample rate/
Channels and press **Apply metadata** to push them through the undo-tracked
commands (sample rate/channels are applied directly - project-format
settings rather than undoable edits, since there is no audio content yet for
their undo history to belong to). **Add gain node** / **Remove last node**
exercise the graph commands; **Undo**/**Redo** show the pending command's
description and walk the history either way. **Save As...** picks a
`.udawproj` file; **Save** re-saves it in place; **Open...** offers to
recover unsaved changes if the chosen file's previous session did not close
cleanly. The autosave interval picker and **Autosave now** exercise
`TProjectRecoveryManager` directly against the open project's backups; the
status memo reports the live document (`TProjectDocument.Describe`), the
undo/redo stack depth, and how many backups are on disk.

## Not in Phase 5 (deliberately)

* Tracks, clips, patterns, the mixer, MIDI, tracker data - those subsystems
  do not exist yet (Phases 7/9/11+), so the project document does not invent
  placeholder sections for them. The serializer's sectioned format is
  designed so later phases add their own `*-BEGIN`/`*-END` sections without
  touching what Phase 5 already writes.
* A visual undo history list / branching redo - the plan's linear undo/redo
  stack is what section 28 asks for; a history browser is UI polish for a
  later pass.
* Project templates, recent-files list, and the AI-history / media-pool
  sections of the plan's project package (section 27) - later phases own
  that data, so there is nothing yet for them to serialize.
* The FPC/Lazarus build of the project units is written (unscoped RTL names,
  `udaw.inc`, wired into `udaw.lpr` / `udaw_tests.lpr`, the `.lpi` search
  paths, the `.lfm` mirror of the Project tab, and the `.sh` scripts) but not
  executed here - no FPC on this machine (same caveat as Phases 1-4).
