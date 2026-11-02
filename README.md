# UDAW – Ultimanium Digital Audio Workstation

**A free, open-source digital audio workstation that brings a timeline DAW, a tracker, a MIDI sequencer and an AI music assistant into one project file.**

> **Platforms:** Windows today. **A Linux version is coming soon**, and macOS is planned after it. See [Platform support](#platform-support).
>
> **Status:** active development. UDAW is usable today, but it is not finished – see [What still needs work](#what-still-needs-work) for an honest list.

---

## Contents

1. [What UDAW is](#what-udaw-is)
2. [Community, support and bug reports](#community-support-and-bug-reports)
3. [What UDAW can do today](#what-udaw-can-do-today)
4. [What still needs work](#what-still-needs-work)
5. [Platform support](#platform-support)
6. [Installing and getting started](#installing-and-getting-started)
7. [Help system](#help-system)
8. [License, EULA and your responsibilities](#license-eula-and-your-responsibilities)

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

## License, EULA and your responsibilities

UDAW is **Free and Open Source Software**, free to use, study and share. **UDAW, modified versions of it, and any Python plug-ins made with or for it may not be sold or distributed for commercial gain** (the music and other work you make with UDAW is yours to sell). It is provided **as is**, with **no warranty**, and **the developer(s) are not responsible for what it does to your system or your data at any time**.

**You are responsible for the material you use and create.** Third-party engines such as **Suno** and others are independent services with their own terms and rights; what you import, generate, publish or sell with UDAW – audio, video, lyrics or anything else – is your responsibility, including copyright. The developer(s) cannot be held liable for copyright breaches or any other liability arising from it.

Please read the full text in **[LICENSE.md](LICENSE.md)**. It is also available inside UDAW from **Help → License and EULA**.

By installing or using UDAW you agree to that license.
