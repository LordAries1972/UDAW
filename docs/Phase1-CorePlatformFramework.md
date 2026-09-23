# Phase 1 - Core Platform Framework

Status: **implemented and passing** (21/21 acceptance tests, Delphi 12 / Win64).

Phase 1 delivers the foundation every later subsystem builds on: application
startup, configuration, logging, error handling, platform detection, filesystem
paths, threading primitives, the background job system, and OS secure storage -
all fully functional, with tests. No stubs.

## Layout

```
src/common/          shared, toolchain-neutral units (compile on Delphi 12 + FPC/Lazarus)
  udaw.inc             common compiler switches
  UDAW.Types.pas       product constants, TUDAWResult, TUDAWId
  UDAW.Errors.pas      TUDAWErrorCode, EUDAWError, RaiseUDAW helpers
  UDAW.Platform.pas    compile-time + run-time OS/arch/CPU/host detection
  UDAW.Paths.pas       per-platform config/data/cache/logs/temp dirs (+ EnsureDirs)
  UDAW.Threading.pas   atomics, full barrier, TUDAWLock, TUDAWSignal, TSPSCByteBuffer
  UDAW.Logging.pas     async logger: console + rolling-file + in-memory sinks
  UDAW.Config.pas      INI-backed settings with atomic (crash-safe) save
  UDAW.Jobs.pas        TJob / TJobManager worker pool, progress + cooperative cancel
  UDAW.SecureStorage.pas  ISecureStore: DPAPI / Keychain / libsecret
src/application/
  UDAW.App.pas         TUDAWApp bootstrap - wires the above in a defined order
src/ui/
  UDAW.UI.MainForm.*   design-time diagnostics window (.dfm for VCL, .lfm for LCL)
tests/
  UDAW.Testing.pas     tiny dependency-free assertion + runner
  Tests.Phase1.pas     the acceptance tests
  UDAW.Tests.dpr       Delphi console runner
  udaw_tests.lpr/.lpi  FPC/Lazarus console runner
UDAW.dpr / UDAW.dproj  Windows executable (Delphi 12, VCL)
udaw.lpr / udaw.lpi    macOS + Linux executable (Lazarus, LCL)
scripts/               build-*/test-* for windows (PowerShell), linux, macos
resources/UDAW.rc      Windows version resource
```

## Toolchain neutrality

Every shared unit compiles unchanged under **Delphi 12** and **FPC 3.2+ /
Lazarus** because:

- unscoped RTL unit names (`SysUtils`, `Classes`, `SyncObjs`, ...) are used
  everywhere - Delphi resolves them through its default unit scopes, FPC uses
  them directly;
- `udaw.inc` sets `{$MODE DELPHI}` and the needed mode switches for FPC;
- compiler/OS/CPU differences are isolated with `{$IFDEF UDAW_WINDOWS/…}`
  (derived once, in `udaw.inc`) and small `{$IFDEF FPC}` shims
  (atomics, `NameThreadForDebugging`, temp-dir lookup, base64, process launch).

## Bootstrap order (`TUDAWApp.Initialize`)

1. `CurrentPlatform` - detect OS, architecture, CPU count, host/user.
2. `UDAW.Paths.EnsureDirs` - create config/data/cache/logs/temp.
3. `TConfig.Create` - load `udaw.ini`, writing it with defaults on first run.
4. `StartLogging` - console + rolling-file + in-memory sinks, at the configured
   level and rotation size.
5. Log the startup banner; handle the first-run flag.
6. `SecureStore` - probe the OS provider, log whether it is available (a missing
   provider is a warning, never fatal).
7. `TJobManager.Create` - worker pool (`CPUs-1`, clamped 2..8).

`Shutdown` reverses it: cancel + drain jobs, save config if dirty, flush the
logger, drop the app's sinks.

## Key design points

- **Logger never blocks the caller.** Entries are copied into a bounded queue
  (65 536) and a single background thread dispatches them to sinks. A full queue
  drops the *oldest* entry and bumps `DroppedCount`. A failing sink cannot take
  down the logger. `Flush` drains synchronously for shutdown.
- **`TSPSCByteBuffer`** is a wait-free single-producer/single-consumer ring
  (power-of-two capacity, free-running head/tail counters, full-barrier between
  payload and index publication). It is the basis for the real-time-safe
  diagnostic path that Phase 2 will feed from the audio callback.
- **Config saves are atomic:** serialize to `udaw.ini.tmp`, move the current
  file to `udaw.ini.bak`, rename the temp into place. A crash mid-save leaves
  either the old file or the `.bak`.
- **Secrets never touch plaintext or project files.** Windows uses DPAPI
  (`CryptProtectData`, per-user, per-key entropy) with base64 blobs in
  `credentials.dpapi`; macOS shells out to `/usr/bin/security` (login Keychain);
  Linux uses `secret-tool` (libsecret). If the Linux tool is absent the provider
  reports `IsAvailable = False` and raises a clear, actionable error - there is
  no weak fallback.
- **Jobs:** `OnProgress` / `OnComplete` fire on a worker thread; GUI code must
  marshal. `ThrowIfCancelled` gives cooperative cancellation. `AOwnsJob` decides
  whether the manager frees the job after completion.
- **Forms are design-time only.** `UDAW.UI.MainForm` places every control in the
  `.dfm` / `.lfm`; nothing builds ordinary UI controls at run time.

## Acceptance tests (`tests/Tests.Phase1.pas`)

21 tests covering: version/result types; platform detection; path creation;
atomics single-threaded and under 4-thread contention; recursive lock; ring
buffer basic / overfill / 200k-item threaded SPSC ordering; `EUDAWError` code
propagation; config value roundtrip and atomic-save `.bak`; logger level
filtering, dispatch, memory-ring eviction, and file persistence; job
success+progress, failure capture, cooperative cancel, and manager-owned
free; secure-storage secret set/get/has/delete roundtrip (skipped with a notice
if no provider is available).

Run them:

```
powershell -ExecutionPolicy Bypass -File scripts\test-windows.ps1     # Delphi 12
./scripts/test-linux.sh          # or test-macos.sh   (FPC)
```

## Not in Phase 1 (deliberately)

Audio, DSP, project format, real-time-thread logging bridge, macOS/Linux
*runtime* verification (units are toolchain-neutral but have only been executed
on Windows/Delphi so far - Phase 2 CI adds the FPC leg).
