"""Vocoder  -  a channel vocoder with its own synthesiser, for UDAW.

Written by Daniel J. Hobson, Australia.

What it does
------------
Put it on a vocal (or any voice, or a drum loop, or a guitar) and the voice "plays" a synthesiser: the
plug-in measures how much energy the incoming sound has in each frequency band, many times a second, and
shapes the built-in carrier (a sawtooth / pulse / detuned-choir / noise synthesiser tuned to the note and
chord you choose) to have exactly the same spectral shape.  The result is the classic talking-synth robot
voice, choir pads that speak, or whispering noise.

How it works (for people reading the code)
------------------------------------------
Short-time Fourier transform, 1024-sample frames every 256 samples (75% overlap, Hann windows):

  1. the voice frame is transformed and its power is summed into N log-spaced bands -> band levels;
  2. the carrier frame is transformed and measured the same way;
  3. each band's gain = voice level / carrier level (so the carrier's own shape does not matter), smoothed
     with an attack and a release, optionally shifted in frequency (formant shift) and tilted (brightness);
  4. the gains are interpolated across the carrier's bins, applied, transformed back and overlap-added.

A little band-limited noise (the "Sibilance" knob) is added to the carrier above 3.5 kHz so "s", "t" and "f"
sounds stay intelligible.

Needs numpy (installed with `pip install numpy`): the transforms are vectorised, which keeps the plug-in at a
few percent of the real-time budget.  Without numpy the plug-in passes audio through and says so in its log.
Latency is about 21 ms (the frame length) - nudge the lane earlier if you need it tight.
"""

import math

import udaw_plugin as up

try:
    import numpy as np
except Exception:                                   # numpy missing: the plug-in explains itself
    np = None

FRAME = 1024
HOP = 256
NOTES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
CARRIERS = ["Sawtooth", "Pulse", "Choir (detuned saws)", "Noise (whisper)"]
CHORDS = {
    "Single note": [0],
    "Octaves": [-12, 0, 12],
    "Power (root + 5th)": [0, 7, 12],
    "Major": [0, 4, 7, 12],
    "Minor": [0, 3, 7, 12],
    "Minor 7th": [0, 3, 7, 10],
    "Suspended": [0, 5, 7, 12],
}
CHORD_NAMES = list(CHORDS)
PRESETS = {
    #            carrier note oct chord bands attack release formant bright sib   voice level
    "Classic Robot":   (0, 9, 3, 0, 20, 4.0, 45.0, 0.0, 3.0, 35, 0, 0.0),
    "Choir Pad":       (2, 0, 3, 3, 24, 12.0, 120.0, 0.0, 2.0, 25, 0, 0.0),
    "Deep Giant":      (0, 4, 2, 2, 16, 6.0, 80.0, -5.0, 0.0, 30, 0, 0.0),
    "Whisper":         (3, 9, 3, 0, 28, 3.0, 40.0, 0.0, 4.0, 60, 0, 3.0),
    "Cyborg Lead":     (1, 9, 4, 4, 22, 3.0, 35.0, 3.0, 5.0, 40, 10, -1.0),
    "Talking Strings": (2, 7, 3, 1, 32, 8.0, 70.0, 2.0, 1.0, 20, 0, 0.0),
}
PRESET_ORDER = list(PRESETS)


class Plugin(up.Plugin):
    name = "Vocoder"
    vendor = "UDAW examples"
    author = "Daniel J. Hobson, Australia"
    version = "1.0"
    description = "Channel vocoder with a built-in synthesiser carrier: make a voice talk through a sawtooth, a choir or noise."
    use_numpy = True

    # ---- parameters -------------------------------------------------------------------------------
    def setup(self):
        self.add_choice("carrier", "Carrier", CARRIERS, default=0, group="Carrier")
        self.add_choice("note", "Note", NOTES, default=9, group="Carrier")
        self.add_param("octave", "Octave", min=1, max=5, default=3, kind="int", group="Carrier")
        self.add_choice("chord", "Chord", CHORD_NAMES, default=0, group="Carrier")
        self.add_param("detune", "Detune", min=0, max=50, default=12, unit="cents", decimals=0, group="Carrier")
        self.add_param("bands", "Bands", min=8, max=32, default=20, kind="int", group="Vocoder")
        self.add_param("attack", "Attack", min=1, max=100, default=4, unit="ms", log=True, decimals=1, group="Vocoder")
        self.add_param("release", "Release", min=5, max=500, default=45, unit="ms", log=True, decimals=0, group="Vocoder")
        self.add_param("formant", "Formant", min=-12, max=12, default=0, unit="st", decimals=1, group="Vocoder")
        self.add_param("bright", "Brightness", min=-12, max=12, default=3, unit="dB", decimals=1, group="Vocoder")
        self.add_param("sibilance", "Sibilance", min=0, max=100, default=35, unit="%", decimals=0, group="Vocoder")
        self.add_param("gate", "Gate", min=-80, max=-30, default=-62, unit="dB", decimals=0, group="Output")
        self.add_param("voice", "Voice", min=0, max=100, default=0, unit="%", decimals=0, group="Output")
        self.add_param("level", "Level", min=-24, max=18, default=0, unit="dB", decimals=1, group="Output")
        self._preset = 0
        self._dirty_voices = True

    # ---- window -----------------------------------------------------------------------------------
    def ui(self, ui):
        ui.window(820, 440, "Vocoder", color="#16181d")
        ui.label("title", "VOCODER", 16, 10, 200, 22, font_size=15, bold=True)
        ui.label("sub", "make a voice talk through a synthesiser", 16, 32, 320, 16, font_color="#8a93a3")
        ui.combo("preset", ["Presets..."] + PRESET_ORDER, 580, 12, 224, 26, value=self._preset,
                 hint="Load a ready-made sound")

        ui.tabs("tabs", ["Vocoder", "About"], 8, 56, 804, 376)
        ui.group("g_car", "CARRIER (the synthesiser)", 8, 8, 304, 196, parent="tabs#0")
        ui.combo("c_car", CARRIERS, 18, 30, 170, 26, param="carrier", parent="tabs#0")
        ui.combo("c_chord", CHORD_NAMES, 196, 30, 108, 26, param="chord", parent="tabs#0")
        ui.knob("k_note", 18, 64, 72, 104, param="note", label="Note", parent="tabs#0",
                hint="The root note the synthesiser plays")
        ui.knob("k_oct", 98, 64, 72, 104, param="octave", label="Octave", parent="tabs#0")
        ui.knob("k_det", 178, 64, 72, 104, param="detune", label="Detune", parent="tabs#0",
                hint="Spreads the voices for a thicker, choir-like sound")
        ui.recess("r_note", 18, 174, 286, 22, parent="tabs#0")
        ui.label("l_note", "Playing: A3", 26, 176, 200, 16, parent="tabs#0")

        ui.group("g_voc", "VOCODER", 320, 8, 444, 196, parent="tabs#0")
        ui.knob("k_bands", 326, 28, 68, 104, param="bands", label="Bands", parent="tabs#0",
                hint="More bands: clearer words. Fewer: a rougher, more robotic sound")
        ui.knob("k_att", 396, 28, 68, 104, param="attack", label="Attack", parent="tabs#0")
        ui.knob("k_rel", 466, 28, 68, 104, param="release", label="Release", parent="tabs#0",
                hint="Longer release smears the words; shorter is crisper")
        ui.knob("k_form", 536, 28, 68, 104, param="formant", label="Formant", parent="tabs#0",
                hint="Shifts the voice's character up (smaller head) or down (a giant)")
        ui.knob("k_bri", 606, 28, 68, 104, param="bright", label="Brightness", parent="tabs#0",
                hint="Tilts the balance toward the highs for clearer consonants")
        ui.knob("k_sib", 676, 28, 68, 104, param="sibilance", label="Sibilance", parent="tabs#0",
                hint="Adds noise above 3.5 kHz so s, t and f sounds come through")
        ui.canvas("bands", 328, 138, 428, 58, parent="tabs#0", fps=24, mouse=False)

        ui.group("g_out", "OUTPUT", 8, 212, 756, 124, parent="tabs#0")
        ui.knob("k_gate", 18, 228, 72, 104, param="gate", label="Gate", parent="tabs#0",
                hint="Silences the vocoder when the voice is quieter than this")
        ui.knob("k_voice", 98, 228, 72, 104, param="voice", label="Voice", parent="tabs#0",
                hint="Mixes some of the original, unprocessed voice back in")
        ui.knob("k_lvl", 178, 228, 72, 104, param="level", label="Level", parent="tabs#0")
        ui.meter("m_in", 268, 232, 20, 96, vertical=True, parent="tabs#0", hint="Voice level")
        ui.meter("m_out", 296, 232, 20, 96, vertical=True, parent="tabs#0", hint="Output level")
        ui.memo("hint", self.hint_text(), 332, 232, 424, 96, parent="tabs#0", read_only=True)
        ui.memo("about", self.about_text(), 12, 12, 780, 320, parent="tabs#1", read_only=True)

    def hint_text(self):
        return ("Put this on a vocal.  Speak or sing; the synthesiser takes on the voice.\n"
                "Pick a carrier and a note, then choose a chord for a pad.  More bands = clearer words.\n"
                "Raise Sibilance if s and t sounds go missing.  Latency is about 21 ms.")

    def about_text(self):
        return (
            "Vocoder\nVersion %s  -  written by %s\n\n" % (self.version, self.author) +
            "A channel vocoder with its own synthesiser, so it works on any single lane: it needs no side-chain.\n\n"
            "Carrier - Sawtooth (bright, classic), Pulse (hollow), Choir (several detuned saws), Noise (whisper).\n"
            "Note / Octave / Chord - what the synthesiser plays.  A chord turns the voice into a talking pad.\n"
            "Bands - how many frequency bands the voice is measured in (8 to 32).\n"
            "Attack / Release - how fast each band follows the voice; short = crisp, long = smeared.\n"
            "Formant - shifts the voice's spectral character without changing the note.\n"
            "Brightness - tilts the highs for intelligibility.  Sibilance - noise for s, t and f.\n"
            "Gate - quiet passages are silenced.  Voice - blend in the original voice.\n\n"
            "Latency is about 21 ms (one analysis frame).  Needs numpy: pip install numpy."
        )

    # ---- audio ------------------------------------------------------------------------------------
    def prepare(self, sample_rate, channels, max_frames):
        self._sr = float(sample_rate)
        self._ok = np is not None
        if not self._ok:
            self.log("The Vocoder needs numpy (pip install numpy); until then the audio passes through unchanged.")
            return
        self._win = np.hanning(FRAME + 1)[:FRAME]                   # periodic Hann
        self._norm = 1.0 / np.sum(self._win[::HOP] ** 2)            # overlap-add gain
        self._freqs = np.fft.rfftfreq(FRAME, 1.0 / self._sr)
        self._rng = np.random.default_rng(20241031)
        self._build_bands()
        self._reset_state()

    def _reset_state(self):
        self._inbuf = np.zeros(0)
        self._outbuf = np.zeros(HOP)                # one hop of silence of latency head-room
        self._mh = np.zeros(FRAME)
        self._ch = np.zeros(FRAME)
        self._ola = np.zeros(FRAME)
        self._env = np.zeros(self._nb)
        self._gain_smooth = 0.0
        self._ph = None
        self._voices = None
        self._in_meter = self._out_meter = 0.0

    def reset(self):
        if self._ok:
            self._reset_state()

    def _build_bands(self):
        nb = int(self.p.bands)
        self._nb = nb
        fmax = min(12000.0, self._sr * 0.45)
        edges_hz = np.geomspace(80.0, fmax, nb + 1)
        idx = np.round(edges_hz * FRAME / self._sr).astype(int)
        idx[0] = max(idx[0], 1)
        for i in range(1, len(idx)):
            if idx[i] <= idx[i - 1]:
                idx[i] = idx[i - 1] + 1
        idx = np.minimum(idx, FRAME // 2)
        self._edges = idx
        self._counts = np.maximum(np.diff(idx), 1)
        self._centers = np.sqrt(edges_hz[:-1] * edges_hz[1:])
        self._logc = np.log(self._centers)
        self._binlog = np.log(np.maximum(self._freqs, 1.0))

    def on_param(self, pid, value):
        if not getattr(self, "_ok", False):
            return
        if pid == "bands":
            self._build_bands()
            self._env = np.zeros(self._nb)
        elif pid in ("carrier", "note", "octave", "chord", "detune"):
            self._voices = None
            self.ui_set("l_note", caption="Playing: %s%d  %s" % (NOTES[self.p.note], self.p.octave,
                                                                  CHORD_NAMES[self.p.chord]))

    def _voice_freqs(self):
        p = self.p
        midi = 12 * (p.octave + 1) + p.note
        out = []
        det = p.detune
        for iv in CHORDS[CHORD_NAMES[p.chord]]:
            base = midi + iv
            if p.carrier == 2:                      # choir: three detuned saws per chord note
                for c in (-det, 0.0, det):
                    out.append(440.0 * 2.0 ** ((base + c / 100.0 - 69.0) / 12.0))
            elif det > 0 and len(CHORDS[CHORD_NAMES[p.chord]]) == 1:
                for c in (-det * 0.5, det * 0.5):
                    out.append(440.0 * 2.0 ** ((base + c / 100.0 - 69.0) / 12.0))
            else:
                out.append(440.0 * 2.0 ** ((base - 69.0) / 12.0))
        return np.array(out)

    def _carrier_hop(self):
        """HOP samples of the carrier."""
        if self.p.carrier == 3:
            return self._rng.standard_normal(HOP) * 0.5
        if self._voices is None:
            self._voices = self._voice_freqs() / self._sr
            self._ph = self._rng.random(len(self._voices))
        t = np.arange(1, HOP + 1)
        ph = (self._ph[:, None] + self._voices[:, None] * t[None, :]) % 1.0
        self._ph = ph[:, -1]
        if self.p.carrier == 1:
            wave = np.where(ph < 0.5, 1.0, -1.0)
        else:
            wave = 2.0 * ph - 1.0
        return wave.sum(axis=0) / math.sqrt(len(self._voices))

    def _hop(self, mod_hop):
        p = self.p
        sr = self._sr
        win, edges, counts = self._win, self._edges, self._counts
        self._mh = np.concatenate((self._mh[HOP:], mod_hop))
        self._ch = np.concatenate((self._ch[HOP:], self._carrier_hop()))
        X = np.fft.rfft(self._mh * win)
        C = np.fft.rfft(self._ch * win)
        # sibilance: band-limited noise (above 3.5 kHz) added to the carrier
        sib = p.sibilance * 0.01
        if sib > 0.0:
            noise = np.fft.rfft(self._rng.standard_normal(FRAME) * win)
            mask = np.clip((self._freqs - 3000.0) / 1500.0, 0.0, 1.0)
            C = C + noise * mask * (sib * 0.9)
        # band levels of the voice and of the carrier
        pm = (X.real ** 2 + X.imag ** 2)
        pc = (C.real ** 2 + C.imag ** 2)
        em = np.sqrt(np.add.reduceat(pm, edges[:-1])[:self._nb] / counts)
        ec = np.sqrt(np.add.reduceat(pc, edges[:-1])[:self._nb] / counts) + 1e-9
        # smoothing: separate attack and release, per hop
        a_att = 1.0 - math.exp(-HOP / (max(p.attack, 0.5) * 0.001 * sr))
        a_rel = 1.0 - math.exp(-HOP / (max(p.release, 1.0) * 0.001 * sr))
        coef = np.where(em > self._env, a_att, a_rel)
        self._env = self._env + coef * (em - self._env)
        env = self._env
        # formant shift: read the voice's band levels from a different frequency
        if abs(p.formant) > 0.05:
            env = np.interp(self._logc - p.formant * math.log(2.0) / 12.0, self._logc, env)
        # brightness tilt: about +/-bright dB at the two ends of the spectrum
        if abs(p.bright) > 0.05:
            env = env * 10.0 ** ((p.bright * np.log2(self._centers / 1000.0) / 3.3) / 20.0)
        # gate on the voice's overall level
        total = math.sqrt(float(np.sum(self._env ** 2))) / math.sqrt(FRAME)
        target = 1.0 if total > up.db_to_lin(p.gate) * 4.0 else 0.0
        self._gain_smooth += (0.35 if target > self._gain_smooth else 0.15) * (target - self._gain_smooth)
        gains = env / ec * self._gain_smooth
        # gains across the carrier's bins (log-frequency interpolation, nothing outside the bands)
        g_bins = np.interp(self._binlog, self._logc, gains, left=0.0, right=0.0)
        g_bins[self._freqs < 80.0] = 0.0
        y = np.fft.irfft(C * g_bins, FRAME) * win
        self._ola += y
        out = self._ola[:HOP] * self._norm
        self._ola = np.concatenate((self._ola[HOP:], np.zeros(HOP)))
        dry = self._mh[:HOP]
        return out, dry

    def process(self, block):
        if not self._ok:
            block.copy_through()
            return
        p = self.p
        n = block.frames
        if block.channels > 1:
            mod = 0.5 * (block.inp[0].astype(np.float64) + block.inp[1].astype(np.float64))
        else:
            mod = block.inp[0].astype(np.float64)
        self._inbuf = np.concatenate((self._inbuf, mod))
        outs, drys = [], []
        pos = 0
        while len(self._inbuf) - pos >= HOP:
            o, d = self._hop(self._inbuf[pos:pos + HOP])
            outs.append(o)
            drys.append(d)
            pos += HOP
        self._inbuf = self._inbuf[pos:]
        wet = np.concatenate([self._outbuf] + outs) if outs else self._outbuf
        dry_hist = np.concatenate(drys) if drys else np.zeros(0)
        # the voice signal that matches the vocoded output in time
        if not hasattr(self, "_dryq") or self._dryq is None:
            self._dryq = np.zeros(HOP)
        dryq = np.concatenate([self._dryq] + ([dry_hist] if len(dry_hist) else []))
        if len(wet) < n:                                  # should not happen: head-room covers it
            wet = np.concatenate((np.zeros(n - len(wet)), wet))
            dryq = np.concatenate((np.zeros(max(0, n - len(dryq))), dryq))
        res = wet[:n]
        self._outbuf = wet[n:]
        dres = dryq[:n] if len(dryq) >= n else np.concatenate((dryq, np.zeros(n - len(dryq))))
        self._dryq = dryq[n:] if len(dryq) > n else np.zeros(0)
        lvl = up.db_to_lin(p.level)
        vm = p.voice * 0.01
        mixed = (res * (1.0 - 0.5 * vm) + dres * vm) * lvl * 2.2
        np.clip(mixed, -1.0, 1.0, out=mixed)
        m32 = mixed.astype(np.float32)
        for ch in range(block.channels):
            block.out[ch][:] = m32
        pin = float(np.max(np.abs(mod))) if n else 0.0
        pout = float(np.max(np.abs(m32))) if n else 0.0
        self._in_meter = max(pin, self._in_meter * 0.85)
        self._out_meter = max(pout, self._out_meter * 0.85)
        self.ui_set("m_in", value=min(1.0, self._in_meter))
        self.ui_set("m_out", value=min(1.0, self._out_meter))
        self.repaint("bands")

    # ---- the band display -----------------------------------------------------------------------
    def paint_bands(self, cv):
        w, h = cv.width, cv.height
        cv.gradient(0, 0, w, h, "#1d2027", "#12141a")
        if not getattr(self, "_ok", False) or self._env is None:
            cv.text(10, h // 2 - 7, "numpy is not installed - the vocoder is bypassed", "#e08a6f", 11)
            return
        env = self._env
        peak = max(float(np.max(env)), 1e-6)
        nb = len(env)
        bw = (w - 12) / nb
        for i in range(nb):
            v = min(1.0, float(env[i]) / peak) ** 0.6
            bh = max(1, int((h - 14) * v))
            x = 6 + i * bw
            cv.fill_rect(x + 1, h - 6 - bh, max(1, bw - 2), bh, up.rgb(60 + 170 * v, 210 - 70 * v, 160))
        cv.text(8, 4, "VOICE BANDS", "#8a93a3", 10, True)

    # ---- presets and saved state -----------------------------------------------------------------
    def on_preset(self, event, value):
        try:
            idx = int(value)
            if idx <= 0:
                return
            name = PRESET_ORDER[idx - 1]
        except (TypeError, ValueError, IndexError):
            return
        car, note, octv, chord, bands, att, rel, form, bri, sib, voice, level = PRESETS[name]
        for pid, v in (("carrier", car), ("note", note), ("octave", octv), ("chord", chord), ("bands", bands),
                       ("attack", att), ("release", rel), ("formant", form), ("bright", bri),
                       ("sibilance", sib), ("voice", voice), ("level", level)):
            self.set_param(pid, v)
        self._preset = idx
        self.log("preset: " + name)

    def get_state(self):
        return {"preset": self._preset}

    def set_state(self, state):
        if isinstance(state, dict):
            self._preset = int(state.get("preset", 0))
            self.ui_set("preset", value=self._preset)
