# UDAW coding rules

Extracted from the master plan. These are enforced by review; several are also
checked by tests.

## Non-negotiable

1. Audio processing is never performed by UI code.
2. AI / network activity never runs on the real-time audio thread.
3. File IO never runs on the real-time audio thread.
4. No unbounded allocation in the real-time callback.
5. All project changes go through controlled command interfaces.
6. AI commands are validated before execution; AI changes participate in undo.
7. Project files are versioned; never deserialize raw class memory from disk.
8. Imported files are validated before allocation; external sizes are never trusted.
9. API credentials are stored only in OS secure storage - never plaintext, never
   in project files, never in logs/diagnostics.
10. Cloud uploads require explicit user authorization.
11. Audio-graph changes are thread-safe; background jobs are cancellable.
12. Every visible operation reports genuine progress when it is measurable.
13. Every file-format implementation gets regression tests.
14. No third-party audio/DSP/codec/GUI framework is introduced (native OS APIs
    are fine). See the plan's section 69 for the explicit ban list.
15. Platform-specific code stays behind abstraction units.
16. Windows stays Delphi 12 native; macOS/Linux stay Lazarus/FPC; Apple Silicon
    is first-class.
17. The DAW is fully usable offline with every AI provider disabled.

## Zero placeholder policy

Nothing is "implemented" until real production functionality exists **and is
tested**. Forbidden: TODO implementations, placeholder buttons, empty event
handlers, fake progress, fake waveforms/meters/AI responses, unimplemented menu
commands, unfinished persistence, mocked project loading, silent error
swallowing, and **runtime-created interface controls where a design-time control
is appropriate**.

## Forms

- Every window and panel is a real design-time form/frame: a `.dfm` for the
  Delphi/VCL build and a `.lfm` for the Lazarus/LCL build, with all controls
  placed in the designer.
- Do not `TControl.Create` static UI at run time. Dynamic construction is only
  acceptable for genuinely data-driven repeaters (e.g. one strip per mixer
  channel) and then via frames.
- Reusable professional components are frames or custom controls, not
  hand-assembled control trees.

## Pascal / portability

- Shared units live in `src/common` and must compile on Delphi 12 and FPC.
  Use unscoped RTL unit names; guard toolchain differences with `{$IFDEF FPC}`
  and OS differences with the `UDAW_WINDOWS` / `UDAW_MACOS` / `UDAW_POSIX`
  defines from `udaw.inc`.
- No platform `{$IFDEF}` in core DSP/engine code - push it into the platform
  abstraction units.
- Every subsystem raises `EUDAWError` with a `TUDAWErrorCode`; no bare
  `Exception.Create` for expected failure modes.
- Long-running work goes through `UDAW.Jobs`; it must honour `ThrowIfCancelled`.

## Definition of "phase complete"

Implementation + UI where required + persistence where required + error handling
+ cancellation where relevant + tests + docs + edge cases tested + memory
ownership verified + thread behaviour verified + release build passes.
