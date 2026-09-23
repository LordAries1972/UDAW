# Phase 2 - Audio Device Engine

Status: **implemented and passing** (47/47 acceptance tests: 21 Phase 1 + 26
Phase 2, Delphi 12 / Win64). The Windows executable boots and opens a real
WASAPI shared-mode stream (48 kHz / stereo / Float32) on this machine.

Phase 2 delivers the audio device layer every later subsystem plays through:
device enumeration, format/rate/buffer negotiation, an event-driven real-time
render/capture callback, a planar Float32 buffer with full mixing maths, a
wait-free frame ring for the RT<->disk boundary, real signal generators, an
offline (faster-than-real-time) render path, and automatic device-loss
recovery. No stubs: the WASAPI backend is a complete native implementation and
the portable software backend is a real timed backend, not a mock.

## Layout

```
src/audio/
  UDAW.Audio.Types.pas             sample formats, rates, channel layouts, dB;
                                   interleaved<->planar conversion (int16/24/32,
                                   float32/64) - the "format negotiation" edge
  UDAW.Audio.Buffer.pas            TAudioBuffer (planar Float32: Clear/Copy/Mix/
                                   Add/ApplyGain/Peak/RMS/HasNonFinite,
                                   Load/StoreInterleaved) + TAudioBufferPool
  UDAW.Audio.Ring.pas              TAudioRing - wait-free SPSC ring of interleaved
                                   frames; over/underrun counters, zero-pad reads
  UDAW.Audio.Source.pas            IAudioSource; TToneSource (sine/tri/saw/square/
                                   white+pink noise, phase-accurate), TSweepSource
                                   (lin/exp), TSilenceSource, TSourceMixer
  UDAW.Audio.Device.pas            IAudioBackend / IAudioStream contracts,
                                   TAudioDeviceInfo, TAudioStreamRequest/Granted,
                                   TAudioStreamStats, event kinds
  UDAW.Audio.Offline.pas           RenderSourceOffline + RMS / peak / frequency /
                                   clip-count analysis for golden tests
  UDAW.Audio.Backend.Factory.pas   platform backend selection (+ override by
                                   config/env), AvailableBackendIds
  UDAW.Audio.Engine.pas            TAudioEngine - app-facing: open/negotiate,
                                   drive one source, metering, device-loss
                                   recovery with backoff, config persistence
  src/audio/backend/
    UDAW.Audio.Backend.Software.pas  portable timed backend: QPC-paced worker,
                                     duplex loopback, injectable virtual mic,
                                     missed-deadline xrun accounting,
                                     SimulateDeviceLoss
    UDAW.Audio.Backend.WASAPI.pas    native Windows backend (COM interfaces
                                     declared inline): IMMDeviceEnumerator,
                                     IAudioClient shared+exclusive, event-driven
                                     IAudioRenderClient / IAudioCaptureClient,
                                     IMMNotificationClient device-change,
                                     AUDCLNT_E_DEVICE_INVALIDATED -> aseDeviceLost
tests/Tests.Phase2.pas             the 26 acceptance tests
src/ui/UDAW.UI.MainForm.*          new "Audio" tab: live engine state, output
                                   L/R peak meters, Start/Stop/Test-tone/
                                   Reset-device/Re-open (design-time controls)
src/application/UDAW.App.pas       TUDAWApp creates + owns the TAudioEngine
```

## Canonical audio representation

* IEEE **Float32**, **planar** (one contiguous array per channel).
* Standard rates advertised: 22050/32000/44100/48000/88200/96000/176400/192000;
  custom rates accepted when hardware reports support.
* Device edge converts to/from interleaved int16, int24 (packed 3-byte), int32,
  float32 and float64 with clamping - `DecodeInterleaved` / `EncodeInterleaved`.

## Real-time discipline

* The render/capture callback runs on the backend's RT thread. It never
  allocates, never takes a blocking lock (the engine swaps its source under
  `TryEnter` and keeps the previous source if it can't get in), never logs,
  never touches disk or the network.
* `TAudioBuffer` grows storage only off the RT path; reused buffers never
  reallocate once at working size.
* `TAudioRing` is the RT<->non-RT bridge: power-of-two capacity, free-running
  head/tail counters, a full barrier between payload and index publication,
  every counter difference taken in Int64 and clamped.
* The engine's callback also hard-clips to +/-1.0, scrubs NaN/Inf, and counts
  clipped samples for the meter.

## Backend selection

`CreateAudioBackend`:

| Platform | Preference |
|----------|------------|
| Windows  | WASAPI -> software |
| macOS    | software (native Core Audio backend is the remaining Phase 2 item) |
| Linux    | software (native PipeWire/ALSA backend is the remaining Phase 2 item) |

Force one with `[audio] backend = software|wasapi|auto` or the
`UDAW_AUDIO_BACKEND` environment variable. An unavailable forced backend falls
back to software with a logged warning - audio never blocks startup.

## Configuration - `[audio]` section

```
backend         = auto        ; auto | wasapi | software
output_device   =             ; '' => backend default
input_device    =
sample_rate     = 0           ; 0 => device default
buffer_frames   = 480
output_channels = 2
input_channels  = 2
exclusive       = 0
enable_input    = 0           ; 1 => open a duplex stream
autostart       = 1
```

The engine writes the negotiated values back after a successful open.

## Device-loss recovery

`aseDeviceLost` (from WASAPI's `AUDCLNT_E_DEVICE_INVALIDATED`, from the software
backend's `SimulateDeviceLoss`, or from `TAudioEngine.NotifyDeviceLost`) drops
the engine to `aesRecovering` and starts a background thread that re-opens the
configured device with exponential backoff (250 ms .. 4 s, up to 20 attempts).
On success it re-primes the source and fires `aseRecovered`; on exhaustion it
settles at `aesFailed` and the DAW keeps running silently.

## Acceptance tests (`tests/Tests.Phase2.pas`)

26 tests: format sizes + interleave/deinterleave round-trips (int16/int24/
float32) and out-of-range clamping; `TAudioBuffer` mix/gain, no-realloc reuse,
sine RMS; `TAudioRing` basic, underrun zero-pad, and a 40 000-frame threaded
SPSC ordering check; offline sine amplitude+frequency at 48 k and 44.1 k, an
exponential sweep whose measured frequency rises, an over-range square that
clips every sample, and a mixer that sums coherent sources; software backend
enumeration, QPC-paced block delivery + timing + zero xruns, duplex loopback
capture, injected virtual-microphone capture, and device loss + reopen; the
factory forced-software and auto-selection paths; and the `TAudioEngine`
open/start/stop/close lifecycle, recovery after a forced device loss, and a
compressed "soak" (3 s of continuous 5 ms-block rendering with a monotonic
callback count, bounded xruns and zero clipping).

Run them:

```
powershell -ExecutionPolicy Bypass -File scripts\test-windows.ps1     # Delphi 12
./scripts/test-linux.sh          # or test-macos.sh   (FPC)
```

## Manual / hardware check

`build\bin\UDAW.exe` -> **Audio** tab -> **Test tone 440 Hz** plays a real sine
through the negotiated WASAPI (or software) device; the L/R meters and the
callback / xrun / CPU-load readout update live. **Reset device** exercises the
recovery path against the real backend.

## Not in Phase 2 (deliberately, or still open)

* Native **macOS Core Audio** and **Linux PipeWire/ALSA** backends. The engine,
  factory, interfaces and tests are backend-agnostic and the portable software
  backend is a working stand-in on those platforms today; wiring the two native
  HAL backends is the remaining Phase 2 task (tracked like Phase 1's FPC leg).
* WASAPI **exclusive-mode** and **duplex** paths are implemented but have only
  been exercised against shared-mode render hardware so far.
* The FPC/Lazarus build of the audio units is written (unscoped RTL names,
  `{$IFDEF UDAW_WINDOWS}` around the WASAPI unit) but not yet executed - no FPC
  on the current machine.
* Multi-resolution metering, the graph, resampling and DSP are Phase 3+.
