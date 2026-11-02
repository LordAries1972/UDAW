# UDAW – Ultimanium Digital Audio Workstation

**A free, open-source digital audio workstation that brings a timeline DAW, a tracker, a MIDI sequencer and an AI music assistant into one project file.**

> **Platforms:** Windows today. **A Linux version is coming soon**, and macOS is planned after it. See [Platform support](#platform-support).
>
> **Status:** active development. UDAW is usable today, but it is not finished – see [What still needs work](#what-still-needs-work) for an honest list.

---

## Just want to use UDAW? Download a release, not the repository

> **If you only want to run the program, do not download or clone this repository.** The repository is the source code for people who want to build or change UDAW, and it contains no ready-to-run program.
>
> 1. Open the **[Releases page](https://github.com/LordAries1972/UDAW/releases)**.
> 2. Download the release file for your platform (today that is the **Windows** `.zip`).
> 3. Unzip it to a folder you can write to and run `UDAW.exe`.
>
> See [Installing and getting started](#installing-and-getting-started) for first-run steps. Only continue to [Contributing](#contributing--building-udaw-from-source) if you want to work on the code.

---

## Contents

1. [What UDAW is](#what-udaw-is)
2. [Community, support and bug reports](#community-support-and-bug-reports)
3. [What UDAW can do today](#what-udaw-can-do-today)
4. [What still needs work](#what-still-needs-work)
5. [Platform support](#platform-support)
6. [System Requirements](#system-requirements)
7. [Installing and getting started](#installing-and-getting-started)
8. [Help system](#help-system)
9. [Contributing – building UDAW from source](#contributing--building-udaw-from-source)
10. [License, EULA and your responsibilities](#license-eula-and-your-responsibilities)

---

## What UDAW is

UDAW combines four ways of making music in a single project, and you can mix them freely in the same song:

| Workflow | Use it for |
| --- | --- |
| **Timeline** (linear multitrack) | Recording and arranging audio, comping takes, mixing a song from start to finish |
| **Tracker** | Pattern-based, chiptune and classic tracker composition, with MOD / XM / IT-style effects |
| **MIDI / Piano Roll** | Drawing and editing notes, playing them through the built-in synth or your plug-ins |
| **AI Assistant** | Asking questions about your project, getting mixing and mastering help, and generating music, lyrics and arrangements through the AI services you connect |

Codecs, DSP, mixer, tracker engine, MIDI engine and file-format readers/writers are built into UDAW itself, so a project opens, plays and renders without needing outside codec packs. A project is a single `.udawproj` file that carries the timeline, mixer, tracker module and MIDI together.

---

## Community, support and bug reports

UDAW is free software and support is community-driven.

> ### 💬 Discord
> **Join our Discord channel to report problems, ask questions and share your music:**
>
> **`DISCORD INVITE LINK GOES HERE`**
>
> *(The maintainers must replace the line above with the real invite link before publishing this file – the License and the in-app help point users to this README for the link.)*

When you report a problem please include:

1. Your UDAW version (shown at the top of the Help Centre page and in **Help → About**).
2. Your version of Windows.
3. Exactly what you did, step by step.
4. What you expected to happen, and what happened instead (copy any error text word for word).
5. If UDAW showed its **crash window**, press **Copy** and paste the report.

No one is obliged to provide support (see the [License](LICENSE.md)), but reports are how UDAW gets better, and they are very welcome.

---

## What UDAW can do today

### Timeline (linear multitrack)

- Unlimited audio, MIDI and tracker tracks on a zoomable, scrollable timeline with snap-to-grid, markers, regions, loop range, chord lane, and a tempo map with multiple tempo changes and time signatures.
- Non-destructive editing: move, trim, split, duplicate, fade in/out, crossfade, ripple and range selection, with cut / copy / paste of ranges that keep their effects, titles, markers and regions.
- Unlimited undo / redo across the whole project, autosave and crash recovery.
- Per-clip tempo-stretch and warp markers, stem splitting, audio-to-MIDI, and metronome.
- Clip Stage (clip launcher) for performing with scenes.
- Per-track colours, mute / solo / record-arm, track titles and renaming, and range-based effects (noise reduction, auto-tune, convolution reverb and more).
- Editing modes on one screen: **Arrange, Piano, Score, Instrument, Pattern, Mix, Tracker, Record, AI and Foley**.
- Video on the timeline: import video files, play them in sync with the playhead, apply video effects and transitions, and export with the effects rendered.

### Recording

- Record from any input device with a per-device picker.
- Multiple takes with take selection and swipe-comping.
- Foley sampler for quickly capturing and triggering sounds.

### Mixer and routing

- Channel strips with faders, pan, mute / solo, metering, sends and busses; drag to reorder.
- Automation lanes and modulators.
- Plug-in hosting for **VST2, VST3 and CLAP**, with a plug-in scanner and crash isolation so a faulty plug-in does not take your project down.
- Python scripts and Python plug-ins to write your own effects and automate UDAW.

### DSP and effects

- A large built-in suite of audio effects (EQ, dynamics, delay, reverb, convolution, modulation, distortion, pitch, spectral and Fairlight-style effects including a vocoder) and a large library of video effects.
- Real-time visualisation: spectrum, scope and level meters.
- A node-based audio graph for custom signal routing.
- Dithered export at several bit depths.

### Tracker

- A full pattern editor with an order list, instruments with multi-sample key-maps, volume / pan envelopes, and a per-channel mixer with effects.
- Import and export of **MOD, XM and MPTM / IT** modules, including compressed IT samples.
- Import of S3M, STM, 669, OKT, MTM, ULT, AMF, PTM, FAR and DSM modules.
- MIDI-keyboard recording into patterns.
- Tracker modules can be placed on the Timeline and rendered with the rest of your song.

### MIDI, Piano Roll, Score and drums

- Piano roll with velocity lane, quantise and chord detection.
- Import and export Standard MIDI Files; record from real MIDI devices.
- Built-in polyphonic synthesiser and a 128-pad drum machine with per-pad editors, kits that are saved with your project, and a pattern editor.
- Score view with staves, clefs, chord symbols and a guitar-tab toggle.

### File formats

- **Audio:** WAV / RF64, FLAC, MP3, AAC / M4A.
- **Video / containers:** MP4, and other common video files through the system's media framework (audio streams are decoded into your project).
- **Music:** MIDI, MOD, XM, IT / MPTM and the legacy tracker formats above.
- Export of your mix, stems and tracker modules.

### AI Assistant and voice

- Connect your own accounts / API keys for **OpenAI, Anthropic (Claude), DeepSeek, Suno and Luma**. UDAW only connects to those services on your behalf; they are independent engines (see the [License](LICENSE.md)).
- Chat about your project, with tool commands that can make changes you can preview, compare and undo.
- Mixing and mastering assistants.
- AI composition: song specification, lyrics and arrangement, preferring your samples and loops before synthesised MIDI.
- Music generation through Suno, and the "up-match" workflow for bringing a UDAW mix to Suno.
- Video and image generation through Luma.
- Voice commands.
- **Model Context Protocol (MCP)** support so UDAW can use, and optionally expose, tools to other AI applications.
- Secure storage for your keys.

### Application

- Themeable interface with many visual styles and a colour editor.
- Built-in Help Centre and a built-in License / EULA viewer.
- Automatic update checks and a separate updater.
- Per-project window layout.

---

## What still needs work

UDAW is a large, fast-moving project. Being upfront about its limits:

**Platform and release**
- **Linux and macOS** – not yet released. **Linux is coming soon**; macOS follows. Windows is the only fully tested platform today.
- Installer and packaging polish.

**Testing and stability**
- Some recent features have had limited real-world testing, especially on unusual hardware, audio interfaces and large projects. Expect rough edges and report them.
- Hosted plug-ins (especially **CLAP and VST3**) have been tested against a limited set of plug-ins. Plug-in editor windows and parameter support are incomplete for some plug-ins.
- The AI features depend on third-party services whose behaviour, pricing and output change. Interoperability with every MCP client has not been verified.

**Missing or incomplete features**
- Music **transcription to printed notation / tablature and PDF export** – planned, not started.
- A local **usage-learning** feature (so UDAW can learn which instruments and effects you use) – planned, with a privacy-first design, not started.
- Score view: no ties or beams yet.
- Piano-roll velocity lane is display-only for editing in some modes.
- Some tracker formats (for example DMF and several rare module types) are not yet supported, and a few tracker effects follow other trackers only approximately.
- Neural stem separation and some advanced mastering tools are still basic.
- Synth / sampler / arpeggiator engines exist, but their full editing interfaces are still being built.
- Some pages of the AI tab still need layout clean-up.
- Not every user-interface surface has had a full accessibility and high-DPI pass.

**Documentation**
- The Help Centre is comprehensive but is kept in step with a fast-changing program; if you find something that no longer matches, please tell us on Discord.

---

## Platform support

| Platform | Status |
| --- | --- |
| **Windows 10 / 11 (64-bit)** | Supported and tested |
| **Linux** | **Coming soon** |
| macOS | Planned after Linux |

---

## System Requirements

> Only the Windows build is released today. The Linux and macOS requirements below are the **targets** for those versions and may change before release.

### Windows (64-bit) – available now

| | Minimum | Recommended |
| --- | --- | --- |
| **Operating system** | Windows 10 (64-bit), version 1809 or later | Windows 11 (64-bit), fully updated |
| **Processor** | Dual-core, 2.0 GHz, 64-bit (x64) | Quad-core or better, 3.0 GHz+ |
| **Memory** | 4 GB RAM | 8 GB RAM or more (16 GB for large projects and video) |
| **Graphics** | Graphics adapter with a current driver that supports hardware-accelerated OpenGL | Dedicated GPU with an up-to-date driver |
| **Display** | 1366 × 768 | 1920 × 1080 or higher |
| **Storage** | 500 MB for the program, plus space for your projects and recordings | SSD with several GB free |
| **Audio** | Any Windows audio device | A low-latency audio interface for recording |
| **Internet** | Optional | Needed for the AI services, update checks and Help downloads |

### Linux (64-bit) – coming soon

| | Target |
| --- | --- |
| **Operating system** | A current 64-bit desktop distribution (for example Ubuntu 22.04 LTS or newer, Fedora, Debian 12) |
| **Processor / memory** | Same as Windows |
| **Graphics** | Hardware-accelerated OpenGL with a current driver |
| **Audio** | PipeWire or PulseAudio (ALSA supported) |
| **Display server** | X11 or Wayland |

### macOS – planned after Linux

| | Target |
| --- | --- |
| **Operating system** | A current, supported macOS release |
| **Processor** | Apple silicon or Intel (64-bit) |
| **Memory** | Same as Windows |
| **Audio** | Core Audio devices |

### Optional extras (all platforms)

- **Plug-ins:** VST2, VST3 and CLAP plug-ins you install yourself. Use the 64-bit plug-ins for the 64-bit program.
- **MIDI:** any class-compliant MIDI keyboard or controller.
- **AI features:** your own accounts / API keys for the services you want to use, and an internet connection.
- **Python plug-ins:** Python 3.14 or newer on your machine, if you want to run or write Python plug-ins. See [Installing Python](#installing-python) below.

### Installing Python

Python is only needed for Python plug-ins and scripting. **UDAW requires Python 3.14 or newer.** Install a 64-bit release of that version (or later) for your platform, then restart UDAW so it can find it.

**Windows**

1. Go to [python.org/downloads](https://www.python.org/downloads/) and download the latest **Windows installer (64-bit)**.
2. Run the installer and tick **Add python.exe to PATH** on the first page, then choose **Install Now**.
3. Open a new Command Prompt and check it with `python --version`.

Alternatively, from a Command Prompt: `winget install Python.Python.3.14`

**Linux**

Many distributions ship an older Python 3, so check with `python3 --version`. If it is older than 3.14, install a newer one with your package manager (or from [python.org/downloads/source](https://www.python.org/downloads/source/) or a tool such as `pyenv` if your distribution does not package 3.14 yet):

- Debian / Ubuntu: `sudo apt update && sudo apt install python3.14` (may need the deadsnakes PPA on Ubuntu)
- Fedora: `sudo dnf install python3.14`
- Arch: `sudo pacman -S python`

**macOS**

1. Go to [python.org/downloads/macos](https://www.python.org/downloads/macos/) and download the latest **macOS 64-bit universal2 installer**, then open the `.pkg` and follow the prompts.
2. Check it in Terminal with `python3 --version`.

Alternatively, with [Homebrew](https://brew.sh/): `brew install python@3.14`

---

## Installing and getting started

1. Download the latest release and unzip it to a folder you can write to.
2. Run `UDAW.exe`.
3. On first run, choose your audio output (and input) device in **Settings → General**, then start a new project or import some audio.
4. Open **Help → UDAW Help Centre** for step-by-step guides to every part of UDAW.

> **Turn your volume down before you press Play for the first time**, and always use a safe listening level – see the [License](LICENSE.md).

---

## Help system

Everything is built into the **Help** menu:

- **UDAW Help Centre** – full user guide.
- **License and EULA (Read the Agreement)** – the full license text, shown in the same style as the Help Centre.
- **About Ultimanium UDAW** – version information.

---

## Contributing – building UDAW from source

Contributions are welcome. This section lists everything you need to get the code compiling, running and tested. Read it top to bottom the first time; the [checklist](#quick-start-checklist) at the end is the short version.

Before you start, read the [License](LICENSE.md). It restricts commercial distribution of UDAW and of anything derived from it, and by contributing you agree your work is covered by it.

### What you can build today

| Target | Toolchain | Status |
| --- | --- | --- |
| **Windows 64-bit** (`UDAW.exe`, `UDAWUpdater.exe`) | Embarcadero Delphi 12 | **The supported, tested build. Use this.** |
| Linux / macOS | Lazarus + Free Pascal (`udaw.lpi`, `scripts/build-linux.sh`, `scripts/build-macos.sh`) | Project files exist, but these ports are **not released and not kept in step** with the Windows build. Expect them not to compile yet. Do not rely on them, and please ask on Discord before investing time here. |

All contributor instructions below are for the Windows build.

### 1. Required software

| Requirement | Details |
| --- | --- |
| **Windows** | Windows 10 or 11, 64-bit. The program and its tests only run on Windows. |
| **Delphi 12** | Embarcadero **RAD Studio / Delphi 12 Athens (Studio 23.0)**. The Community Edition is enough to compile, but check Embarcadero's current Community licence terms for your use. Older Delphi versions will not work; the code relies on Delphi 12 language and library features. |
| **Delphi components** | The **Windows 64-bit** compiler and platform. The **VCL** and its **Windows VCL styles** (the app ships 35 `.vsf` themes). The **Indy** components (`IndySystem`, `IndyProtocols`, `IndyCore`), which install with Delphi. Resource compiler (`brcc32`), included with Delphi. |
| **Git** | To clone, branch and submit changes. |
| **PowerShell** | Windows PowerShell 5.1 (already on Windows) or PowerShell 7 to run the build and test scripts. |
| **Python 3.14 or newer** (optional) | Only if you work on Python plug-ins or run the helper scripts in `scripts/` that are written in Python. See [Installing Python](#installing-python). |
| **A working audio output device** | Needed to run the program and to hear what you are changing. The tests do not need one. |

You do **not** need any third-party audio, DSP, codec or GUI package, and you must not add one (see [Coding rules](#4-coding-rules-the-short-version)). Everything UDAW needs, apart from the items under "Bundled third-party code" below, is in this repository or ships with Delphi.

### 2. Getting the source and what is in it

```
git clone <the repository URL>
cd UDAW
```

| Folder / file | Purpose |
| --- | --- |
| `UDAW.dpr`, `UDAW.dproj` | The main application project (Delphi) |
| `UDAWUpdater.dpr` | The small helper program that applies downloaded updates |
| `src/` | All application source, split by subsystem: `common`, `audio`, `codecs`, `midi`, `timeline`, `project`, `recording`, `mixer`, `tracker`, `sequencer`, `synth`, `composer`, `ai`, `voice`, `video`, `browser`, `input`, `web`, `application`, `ui` |
| `tests/` | The regression test suite (`UDAW.Tests.dpr` and the `Tests.*.pas` units) |
| `scripts/` | Build, clean, test and packaging scripts |
| `resources/` | The version resource (`UDAW.rc`) and the VCL style files |
| `Plugins/` | Example and bundled Python plug-ins |
| `ThirdParty/` | Bundled third-party code (see below) |
| `docs/` | Design notes per subsystem, and the **[coding rules](docs/CodingRules.md)** |
| `about-udaw.dat` | The built-in Help Centre page |

**Bundled third-party code.** These are already in `ThirdParty/`; you do not install them:

| Folder | What it is | Why it is there |
| --- | --- | --- |
| `ThirdParty/TaurusTLS` | The TaurusTLS TLS layer for Indy | Secure connections for the AI services and update checks |
| `ThirdParty/OpenSSL/Win64` | The 64-bit OpenSSL runtime DLLs (`libssl`, `libcrypto`) | Loaded at run time by TaurusTLS. They must sit beside `UDAW.exe` |
| `ThirdParty/dglOpenGL` | An OpenGL header translation | Used by the hardware-accelerated interface controls |

Each carries its own licence file; keep those intact.

### 3. Building

Run everything from the repository root. **Use the scripts rather than the IDE for your first build**, because they define the search paths, conditionals and output folders exactly as the project expects.

```powershell
# Everyday debug build (recommended for contributors)
powershell -ExecutionPolicy Bypass -File scripts\build.ps1 -Config Debug

# Full clean rebuild: use this if a change does not seem to "take"
powershell -ExecutionPolicy Bypass -File scripts\build.ps1 -Config Debug -Clean

# List every option and use case
powershell -ExecutionPolicy Bypass -File scripts\build.ps1 -Help
```

**What the script does:**

1. Finds Delphi 12 using the `BDS` environment variable, else the default `Program Files\Embarcadero\Studio\23.0` location. If you installed Delphi somewhere else, set it first:
   `$env:BDS = 'D:\Embarcadero\Studio\23.0'`
2. Raises the build number in `resources\UDAW.rc` and `src\common\UDAW.Version.pas`. If the compile fails it puts both files back, so a failed build does not change your working tree. **If the build succeeds, those two files show up as modified in `git status`. Do not include that build-number change in your pull request** (see [Submitting changes](#7-submitting-changes)).
3. Compiles the version resource, then `UDAW.exe` and `UDAWUpdater.exe` with the 64-bit compiler (`dcc64`).
4. Copies the VCL styles, the icon, the licence files and the Help page into the output folder.

**Output** goes to `build\bin` (compiled units to `build\dcu`). Both are git-ignored.

**Important points:**

- **Always build Debug unless a maintainer has asked for a Release build.** The Release configuration additionally packages an over-the-air update and writes it to a maintainer-only location; it is not intended for contributor machines and will fail or do nothing useful without that set-up. A Debug build is unoptimised and has `DEBUG` defined, which is what you want for development.
- **OpenSSL DLLs.** The IDE project copies `ThirdParty\OpenSSL\Win64\*.dll` beside the executable after a build. If you build with the script into your own `-OutputDir`, or the DLLs are missing, copy them there by hand. Without them the AI features, online licence checks and update checks cannot make secure connections, but the rest of UDAW still runs.
- **Runtime files.** The scripts point UDAW's configuration, logs, cache and scratch files at `.udaw-home` inside the repository (git-ignored) by setting `UDAW_HOME`, so test runs do not touch your real UDAW settings. Set `UDAW_HOME` yourself to move it elsewhere.
- **Stale builds.** The compiler caches compiled units. If you change a shared include or a unit's interface and see odd link or access violations, run with `-Clean` or `scripts\clean.ps1` before assuming your code is wrong.

**Building in the IDE.** Open `UDAW.dproj`, choose **Win64** and the **Debug** configuration, then **Project → Build**. The project is a VCL application. The main window and all panels are real design-time forms (`.dfm`), so you can open and edit them in the Form Designer. If the IDE reports missing units, check **Tools → Options → Language → Delphi → Library** is not overriding the project's own search path (the project already lists every `src\` subfolder and the `ThirdParty` folders). Do not install the TaurusTLS design-time packages from the bundled copy; the project compiles the source directly.

**Command-line compiler settings**, for anyone driving the build from another tool: 64-bit target (`dcc64`), unit scopes `System;System.Win;Winapi;Vcl;Vcl.Imaging`, conditional `DEBUG` or `RELEASE`, include path `src\common`, resource path `src\ui`, and every `src\` subfolder plus `ThirdParty\TaurusTLS\Source` and `ThirdParty\dglOpenGL` on the unit path. `scripts\build.ps1` is the reference.

**Windows-only parts of the code.** The Windows build uses native Windows interfaces for audio (WASAPI and DirectSound), video and media playback (including DirectShow), the VCL, and secure storage. None needs a separate SDK: the declarations are in the repository or in Delphi's own `Winapi.*` units.

### 4. Coding rules (the short version)

The full list is **[docs/CodingRules.md](docs/CodingRules.md)**; read it before writing code. The points that most often cause a change to be rejected:

1. **No UI code touches audio processing,** and **nothing on the real-time audio thread** may allocate unboundedly, do file or network I/O, or wait on a lock held by UI or AI code.
2. **No third-party audio, DSP, codec or GUI libraries.** Native operating-system APIs are fine; new package dependencies are not.
3. **Design-time forms only.** New windows and panels must be real forms or frames with controls placed in the designer. Do not build static interfaces by calling `TControl.Create` at run time. Dynamic creation is acceptable only for genuinely data-driven repeaters, such as one strip per mixer channel.
4. **No placeholders.** No `TODO` implementations, empty event handlers, fake progress bars, fake meters or unimplemented menu items. If a feature is not finished, it is not in the menu.
5. **All project changes go through the command interfaces,** so that they take part in undo and redo.
6. **Validate everything read from disk or the network** before allocating memory from it; never trust sizes from a file. Project files are versioned; never read raw object memory from disk.
7. **Secrets** are kept only in OS secure storage. Never put keys, tokens or passwords in source, project files, logs or issue reports.
8. **Raise `EUDAWError`** with a `TUDAWErrorCode` for expected failures instead of a bare `Exception.Create`, and never silently swallow errors.
9. **Long operations** go through the job system, must honour cancellation, and must show **real** progress in the status bar. Never fake it.
10. **Platform-specific code** stays behind the platform abstraction units. Shared units in `src\common` should stay free of Windows-only calls where practical.
11. **Zero warnings and zero hints.** The build must be clean. Fix the ones your change introduces, and fix ones you touch in files you are already editing.
12. **Keep the three copies of a GL control in step.** Where a user-interface change involves the hardware-accelerated controls, mirror it everywhere the control is defined (see the existing units for the pattern) rather than changing one place.

### 5. Testing

Every file-format reader or writer, engine feature and bug fix needs a regression test. Tests live in `tests\`, one `Tests.<Subject>.pas` unit per area, and are registered in `tests\UDAW.Tests.dpr`.

```powershell
# Builds tests\UDAW.Tests.dpr and runs the whole suite.
# Exit code is 0 only if every test passes.
powershell -ExecutionPolicy Bypass -File scripts\test-windows.ps1
powershell -ExecutionPolicy Bypass -File scripts\test-windows.ps1 -Clean
```

- The test build turns range checking, overflow checking and warnings **on** (`$R+ $Q+ $W+`) and optimisation off, so it catches problems the normal build hides. Run it before every pull request.
- The suite is a console program and needs no audio device. It copies the OpenSSL DLLs next to the test executable itself.
- Tests may create temporary files; they do so under `UDAW_HOME` (`.udaw-home`), never in system folders.
- If you add a new test unit, add it to the `uses` list of `tests\UDAW.Tests.dpr` and give the tests deterministic input. Do not depend on your own music files, network access or an API key.
- A change is not finished until the **full suite passes**, not just the tests for the area you touched.

### 6. Common problems

| Symptom | Likely cause and fix |
| --- | --- |
| "Delphi 12 (Studio 23.0) not found" | Delphi is not installed in the default place. Set `$env:BDS` to the install root (the folder that contains `bin\dcc64.exe`). |
| `dcc64` cannot find a unit named `UDAW.something` or `IdSomething` | You are compiling outside the script, so the search paths are missing. Use `scripts\build.ps1`, or the IDE with `UDAW.dproj`. A missing `Id…` unit means the Indy components were not installed with Delphi. |
| "File not found: dglOpenGL" or TaurusTLS units | The `ThirdParty` folder is incomplete. Re-clone, or restore it. These are tracked in the repository. |
| Build succeeds but AI, update or licence features fail to connect | The OpenSSL DLLs are not beside `UDAW.exe`. Copy `ThirdParty\OpenSSL\Win64\*.dll` there. |
| Strange crashes or behaviour after changing a shared unit | A stale compiled unit. Rebuild with `-Clean`. |
| Python plug-ins report that Python was not found | Install Python 3.14 or newer and tick **Add python.exe to PATH**, then restart UDAW. See [Installing Python](#installing-python). |
| Release build fails near the end (packaging) | Expected on a contributor machine. Use `-Config Debug`. |
| Your settings or recent projects are different from normal | The scripts use `.udaw-home`. Unset `UDAW_HOME` to use your normal profile. |

### 7. Submitting changes

1. **Talk first for anything large.** Open the topic on [Discord](#community-support-and-bug-reports) before starting a new subsystem, a new file format, a new third-party dependency or a big refactor, so effort is not wasted.
2. Create a branch from `main`. Keep each pull request to one purpose.
3. Match the surrounding code: naming, layout, comment density and idiom. Do not reformat files you are not changing.
4. Build with **zero warnings and zero hints**, and run the **whole test suite**.
5. Add or update tests for what you changed.
6. **Update the documentation that users read.** A user-visible change must also be reflected in the built-in Help Centre page (`about-udaw.dat`) and, if it adds a feature, in the "What UDAW can do today" list above. Keep these pages free of implementation detail: describe what a feature does for the user, not how it is built.
7. **Do not commit build output or generated files:** `build\`, `.udaw-home\`, `*.dcu`, `*.exe`, `*.zip`, the IDE's `.identcache` and local settings files, or the version bump the build script makes to `resources\UDAW.rc` and `src\common\UDAW.Version.pas`. Run `git status` before committing and `git restore` those two files if the build changed them.
8. **Never commit secrets,** such as API keys, tokens, signing keys, passwords or private certificates, even test ones.
9. In the pull request, explain what changed and why, how you tested it, and anything you could not test (for example hardware you do not have).

Reviewers check against the [coding rules](docs/CodingRules.md). A change is complete when it has: working implementation, user interface where needed, saving and loading where needed, error handling, cancellation for long work, tests, documentation, and a clean build.

### Quick-start checklist

- [ ] Windows 10/11 64-bit with **Delphi 12 (Studio 23.0)** installed, including the Win64 compiler and VCL.
- [ ] Repository cloned with the `ThirdParty` folder intact.
- [ ] `scripts\build.ps1 -Config Debug` completes with no warnings or hints.
- [ ] `ThirdParty\OpenSSL\Win64\*.dll` sit beside `UDAW.exe` in `build\bin`.
- [ ] `scripts\test-windows.ps1` finishes with exit code 0.
- [ ] (Optional) Python 3.14 or newer installed, for Python plug-in work.
- [ ] You have read [docs/CodingRules.md](docs/CodingRules.md).

---

## License, EULA and your responsibilities

UDAW is **Free and Open Source Software**, free to use, study and share. **UDAW, modified versions of it, and any Python plug-ins made with or for it may not be sold or distributed for commercial gain** (the music and other work you make with UDAW is yours to sell). It is provided **as is**, with **no warranty**, and **the developer(s) are not responsible for what it does to your system or your data at any time**.

**You are responsible for the material you use and create.** Third-party engines such as **Suno** and others are independent services with their own terms and rights; what you import, generate, publish or sell with UDAW – audio, video, lyrics or anything else – is your responsibility, including copyright. The developer(s) cannot be held liable for copyright breaches or any other liability arising from it.

Please read the full text in **[LICENSE.md](LICENSE.md)**. It is also available inside UDAW from **Help → License and EULA**.

By installing or using UDAW you agree to that license.
