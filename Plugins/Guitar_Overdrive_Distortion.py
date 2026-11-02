"""Guitar Overdrive & Distortion  -  a complete UDAW Python plug-in.

Written by Daniel J. Hobson, Australia.

Why this file exists
--------------------
It shows, in one realistic plug-in, everything the UDAW Python system offers:

  * parameters of every kind (float / logarithmic / integer / bool / choice) that are automatable and
    saved with the project;
  * real-time audio processing, per sample, with state kept per channel;
  * a window built from UDAW's own controls: tabs, groups, knobs, a combo box, check boxes,
    level meters, a memo and a custom-drawn canvas;
  * live feedback from the audio thread to the window (meters, the transfer curve);
  * a preset list that moves several parameters at once;
  * extra state saved in the project besides the parameter values.

Why a *scripted* amp stage?  A recording of a clean DI guitar is the classic case: you want to re-amp it
after the fact, try six different drive characters against the mix, automate the drive for a solo, and
ship the project to someone who does not own any amp-sim plug-in.  Because the whole effect lives in this
one text file (the project points at it when you add it to a lane), the sound is reproducible,
tweakable and free.

Signal flow:  noise gate -> tight (pre high-pass) -> drive -> waveshaper (6 voicings, 1-3 cascaded
stages, optional 2x anti-alias) -> tone (low-pass) -> bass / mid / presence EQ -> cabinet filter ->
DC block -> dry/wet mix -> output level -> output limiter.
"""

import math

import udaw_plugin as up

_tanh = math.tanh
_exp = math.exp
_sqrt = math.sqrt


# ---- the six waveshapers (input already scaled by the drive gain) ------------------------------

def _clean_boost(x):
    return _tanh(x)


def _overdrive(x):
    # a little bias gives the even harmonics of a pushed tube stage; -0.1489 re-centres it
    return _tanh(x + 0.15) - 0.1489


def _crunch(x):
    # exponential soft clip, a different knee for each half-wave (class-A feel)
    if x >= 0.0:
        return 1.0 - _exp(-x)
    return -0.85 * (1.0 - _exp(1.15 * x))


def _distortion(x):
    # generalised soft clip with a hard knee: x / (1 + x^4)^(1/4)
    x2 = x * x
    return x / _sqrt(_sqrt(1.0 + x2 * x2))


def _fuzz(x):
    return _tanh(3.0 * x + 0.25) - 0.2449


def _metal(x):
    # an almost square-wave clipper: x / (1 + x^8)^(1/8), the knee is razor sharp
    x2 = x * x
    x4 = x2 * x2
    return x / _sqrt(_sqrt(_sqrt(1.0 + x4 * x4)))


SHAPERS = (_clean_boost, _overdrive, _crunch, _distortion, _fuzz, _metal)
MODES = ["Clean Boost", "Overdrive", "Crunch", "Distortion", "Fuzz", "Metal"]
#: how hard each voicing is driven for the same Drive setting
DRIVE_SCALE = (0.55, 0.8, 1.0, 1.25, 1.4, 1.6)
#: dB of gain per Drive step: Drive 10 on the Metal voicing is about 100 dB into the clipper
DRIVE_DB_PER_STEP = 6.5
#: gain between cascaded stages (each stage clips what the previous one already clipped)
STAGE_GAIN = 3.0

#: name -> (mode, drive, tight, tone, bass, mid, presence, gate_db, cab, oversample, mix, level, stages)
PRESETS = {
    "Clean Boost":          (0, 3.0, 60, 9000, 0, 0, 1, -70, False, False, 100, -3, 1),
    "Blues Overdrive":      (1, 4.5, 120, 5200, 1, 2, 0, -65, True, False, 100, -6, 1),
    "Classic Crunch":       (2, 6.0, 150, 5800, 2, -1, 2, -60, True, False, 100, -7, 1),
    "Hard Rock":            (3, 7.5, 180, 6400, 1, -2, 3, -55, True, True, 100, -9, 2),
    "Heavy Metal":          (5, 9.0, 260, 7000, 3, -5, 4, -48, True, True, 100, -12, 2),
    "Fuzz Face":            (4, 8.0, 90, 4200, 4, 1, -2, -62, False, True, 100, -10, 2),
    "Maximum Destruction":  (5, 10.0, 300, 8000, 4, -6, 5, -40, True, True, 100, -15, 3),
}
PRESET_ORDER = list(PRESETS)


class Plugin(up.Plugin):
    name = "Guitar Overdrive & Distortion"
    vendor = "UDAW examples"
    author = "Daniel J. Hobson, Australia"
    version = "1.1"
    description = "Six amp-style drive voicings, up to three cascaded clipping stages, gate, tight, tone stack and cabinet filter."

    # ---- parameters ------------------------------------------------------------------------
    def setup(self):
        self.add_choice("mode", "Voicing", MODES, default=1, group="Amp")
        self.add_param("drive", "Drive", min=0, max=10, default=5, decimals=1, group="Amp")
        self.add_param("stages", "Stages", min=1, max=3, default=1, kind="int", group="Amp")
        self.add_param("tight", "Tight", min=20, max=400, default=120, unit="Hz", log=True, decimals=0,
                       group="Amp")
        self.add_param("tone", "Tone", min=800, max=12000, default=5500, unit="Hz", log=True, decimals=0,
                       group="Amp")
        self.add_param("bass", "Bass", min=-12, max=12, default=0, unit="dB", decimals=1, group="EQ")
        self.add_param("mid", "Mid", min=-12, max=12, default=0, unit="dB", decimals=1, group="EQ")
        self.add_param("presence", "Presence", min=-12, max=12, default=0, unit="dB", decimals=1, group="EQ")
        self.add_param("gate", "Gate", min=-80, max=-20, default=-65, unit="dB", decimals=0, group="Input")
        self.add_bool("cab", "Cabinet", default=True, group="Output")
        self.add_bool("oversample", "2x anti-alias", default=False, group="Amp")
        self.add_bool("protect", "Output limiter", default=True, group="Output")
        self.add_param("mix", "Mix", min=0, max=100, default=100, unit="%", decimals=0, group="Output")
        self.add_param("level", "Level", min=-40, max=12, default=-6, unit="dB", decimals=1, group="Output")
        self._preset = 0

    # ---- window ---------------------------------------------------------------------------------
    def ui(self, ui):
        ui.window(820, 430, "Guitar Overdrive & Distortion", color="#16181d")
        ui.label("title", "OVERDRIVE / DISTORTION", 16, 10, 320, 22, font_size=15, bold=True)
        ui.label("sub", "for guitar recordings", 16, 32, 200, 16, font_color="#8a93a3")
        ui.combo("preset", ["Presets..."] + PRESET_ORDER, 580, 12, 224, 26, value=self._preset,
                 hint="Load a ready-made sound")

        ui.tabs("tabs", ["Tone", "About"], 8, 56, 804, 366)
        # ---- Tone page: every control sits on its frame, so it takes the frame's background ----
        ui.group("g_in", "INPUT", 8, 8, 100, 190, parent="tabs#0")
        ui.knob("k_gate", 14, 28, 72, 104, param="gate", label="Gate", parent="tabs#0")
        ui.meter("m_in", 40, 142, 20, 48, vertical=True, parent="tabs#0", hint="Input level")

        ui.group("g_amp", "AMP", 116, 8, 400, 190, parent="tabs#0")
        ui.combo("c_mode", MODES, 126, 30, 150, 26, param="mode", parent="tabs#0")
        ui.check("x_os", "2x anti-alias", 286, 32, 140, 22, param="oversample", parent="tabs#0",
                 hint="Runs the waveshaper at twice the sample rate to tame aliasing")
        ui.knob("k_drive", 130, 62, 96, 128, param="drive", label="Drive", parent="tabs#0",
                hint="Gain into the clipper (Drive 10 on Metal is about 100 dB)")
        ui.knob("k_tight", 236, 66, 80, 112, param="tight", label="Tight", parent="tabs#0",
                hint="High-pass before the clipper: higher = tighter low end")
        ui.knob("k_tone", 332, 66, 80, 112, param="tone", label="Tone", parent="tabs#0",
                hint="Low-pass after the clipper")
        ui.knob("k_stages", 428, 66, 80, 112, param="stages", label="Stages", parent="tabs#0",
                hint="Cascaded clipping stages: each one clips what the last already clipped")

        ui.group("g_eq", "EQ", 524, 8, 240, 190, parent="tabs#0")
        ui.knob("k_bass", 530, 28, 72, 104, param="bass", label="Bass", parent="tabs#0")
        ui.knob("k_mid", 604, 28, 72, 104, param="mid", label="Mid", parent="tabs#0")
        ui.knob("k_pres", 678, 28, 72, 104, param="presence", label="Presence", parent="tabs#0")
        ui.check("x_cab", "Cabinet filter", 536, 148, 200, 22, param="cab", parent="tabs#0",
                 hint="Roll off the harsh fizz above ~5 kHz and the rumble below 80 Hz")

        ui.group("g_out", "OUTPUT", 8, 204, 756, 124, parent="tabs#0")
        ui.knob("k_mix", 18, 220, 72, 104, param="mix", label="Mix", parent="tabs#0")
        ui.knob("k_lvl", 96, 220, 72, 104, param="level", label="Level", parent="tabs#0")
        ui.meter("m_out", 176, 224, 20, 96, vertical=True, parent="tabs#0", hint="Output level")
        ui.check("x_prot", "Output limiter", 208, 226, 150, 22, param="protect", parent="tabs#0",
                 hint="Soft limiter on the output so heavy drive can never go over 0 dBFS")
        ui.canvas("scope", 208, 252, 548, 68, parent="tabs#0", fps=20, mouse=False)
        # ---- About page ---------------------------------------------------------------------
        ui.memo("about", self.about_text(), 12, 12, 780, 290, parent="tabs#1", read_only=True)

    def about_text(self):
        return (
            "Overdrive & Distortion for guitar\n"
            "Version %s  -  written by %s\n\n" % (self.version, self.author) +
            "Pick a sound from the Preset list, then shape it.\n\n"
            "Gate - silences the noise between notes; raise it for high-gain sounds.\n"
            "Tight - high-pass before the clipper; stops the low strings turning to mud.\n"
            "Drive - how hard the clipper is pushed (up to about 100 dB on the Metal voicing).\n"
            "Voicing - Clean Boost (soft tanh), Overdrive (biased tube stage), Crunch (asymmetric knee),\n"
            "  Distortion (hard knee), Fuzz (heavy and uneven), Metal (almost a square wave).\n"
            "Stages - 1 to 3 clippers in series; every extra stage clips the previous one again for a\n"
            "  denser, more compressed, more distorted sound.\n"
            "Tone - low-pass after the clipper.   Bass / Mid / Presence - tone stack.\n"
            "Cabinet filter - a quick speaker-cabinet roll-off.\n"
            "2x anti-alias - less harsh aliasing on heavy settings, costs more CPU.\n"
            "Output limiter - a soft ceiling so a heavy setting never goes over 0 dBFS.\n"
            "Mix - blend with the dry guitar (parallel drive keeps the pick attack).\n\n"
            "Tip: automate Drive from the Mixer for a solo that gets dirtier as it climbs."
        )

    # ---- audio ----------------------------------------------------------------------------------
    def prepare(self, sample_rate, channels, max_frames):
        sr = float(sample_rate)
        self._sr = sr
        # per-channel state, plain floats so the per-sample loop stays fast
        self._st = [dict(hp=0.0, lp=0.0, gate_env=0.0, gate_g=0.0, prev=0.0, dc_x=0.0, dc_y=0.0)
                    for _ in range(channels)]
        self._eq = [(up.Biquad("lowshelf", sr, 120, 0.7071, 0.0),
                     up.Biquad("peak", sr, 700, 0.9, 0.0),
                     up.Biquad("highshelf", sr, 3500, 0.7071, 0.0)) for _ in range(channels)]
        self._dc_r = 1.0 - 2.0 * math.pi * 12.0 / sr
        self._in_meter = 0.0
        self._out_meter = 0.0
        self._wave = [0.0] * 96
        self._last_peak_in = 0.0
        self._cab = [(up.Biquad("highpass", sr, 80, 0.7071), up.Biquad("lowpass", sr, 5200, 0.8))
                     for _ in range(channels)]
        self._apply_eq()

    def reset(self):
        for st in self._st:
            for k in st:
                st[k] = 0.0
        for chain in self._eq + self._cab:
            for f in chain:
                f.reset()

    def _apply_eq(self):
        for chain in self._eq:
            chain[0].set(120, 0.7071, self.p.bass)
            chain[1].set(700, 0.9, self.p.mid)
            chain[2].set(3500, 0.7071, self.p.presence)

    def on_param(self, pid, value):
        if pid in ("bass", "mid", "presence"):
            self._apply_eq()
        elif pid in ("mode", "drive", "stages"):
            self.repaint("scope")

    def _drive_gain(self):
        p = self.p
        return up.db_to_lin(p.drive * DRIVE_DB_PER_STEP * DRIVE_SCALE[p.mode])

    def _amp(self, shape, v, stages):
        """The clipping stages in series (used by the 2x path and the transfer-curve display)."""
        y = shape(v)
        if stages > 1:
            y = shape(y * STAGE_GAIN)
            if stages > 2:
                y = shape(y * STAGE_GAIN)
        return y

    def process(self, block):
        p = self.p
        n, sr = block.frames, self._sr
        shape = SHAPERS[p.mode]
        stages = p.stages
        g_target = self._drive_gain()
        lvl_target = up.db_to_lin(p.level)
        mix = p.mix * 0.01
        oversample = p.oversample
        use_cab = p.cab
        protect = p.protect
        gate_on = p.gate > -79.5
        gate_thr = up.db_to_lin(p.gate)
        # one-pole coefficients
        a_hp = 1.0 - math.exp(-2.0 * math.pi * p.tight / sr)       # pre high-pass ("tight")
        a_lp = 1.0 - math.exp(-2.0 * math.pi * min(p.tone, sr * 0.45) / sr)
        a_att = 1.0 - math.exp(-1.0 / (0.001 * sr))                 # gate: 1 ms open
        a_rel = 1.0 - math.exp(-1.0 / (0.080 * sr))                 # gate: 80 ms close
        a_env = 1.0 - math.exp(-1.0 / (0.010 * sr))
        dc_r = self._dc_r
        eq_active = abs(p.bass) > 0.05 or abs(p.mid) > 0.05 or abs(p.presence) > 0.05
        g0 = getattr(self, "_g_now", g_target)
        l0 = getattr(self, "_lvl_now", lvl_target)
        dg = (g_target - g0) / n          # ramp over the block: no zipper noise on automation
        dl = (lvl_target - l0) / n
        sg = STAGE_GAIN
        amp = self._amp
        pk_in = pk_out = 0.0

        for ch in range(block.channels):
            src, dst = block.inp[ch], block.out[ch]
            st = self._st[ch]
            hp, lp = st["hp"], st["lp"]
            genv, ggain = st["gate_env"], st["gate_g"]
            prev, dcx, dcy = st["prev"], st["dc_x"], st["dc_y"]
            eqs = self._eq[ch]
            cabs = self._cab[ch]
            g, lvl = g0, l0
            for i in range(n):
                x = src[i]
                ax = x if x >= 0.0 else -x
                if ax > pk_in:
                    pk_in = ax
                dry = x
                # -- noise gate (envelope + smoothed gain) --
                if gate_on:
                    genv += a_env * (ax - genv)
                    target = 1.0 if genv > gate_thr else 0.0
                    ggain += (a_att if target > ggain else a_rel) * (target - ggain)
                    x *= ggain
                # -- tight: remove lows before the clipper --
                hp += a_hp * (x - hp)
                x -= hp
                # -- drive + the clipping stages (optionally at 2x the rate) --
                g += dg
                if oversample:
                    y = 0.5 * (amp(shape, 0.5 * (prev + x) * g, stages) + amp(shape, x * g, stages))
                    prev = x
                else:
                    y = shape(x * g)
                    if stages > 1:
                        y = shape(y * sg)
                        if stages > 2:
                            y = shape(y * sg)
                # -- tone low-pass --
                lp += a_lp * (y - lp)
                y = lp
                # -- tone stack and cabinet --
                if eq_active:
                    y = eqs[0].tick(y)
                    y = eqs[1].tick(y)
                    y = eqs[2].tick(y)
                if use_cab:
                    y = cabs[0].tick(y)
                    y = cabs[1].tick(y)
                # -- DC block (the asymmetric shapers add offset) --
                out = y - dcx + dc_r * dcy
                dcx, dcy = y, out
                # -- mix + level --
                lvl += dl
                out = (dry + (out - dry) * mix) * lvl
                # -- output limiter: transparent below 0.8, a soft ceiling at 1.0 --
                if protect:
                    if out > 0.8:
                        out = 0.8 + 0.2 * _tanh((out - 0.8) * 5.0)
                    elif out < -0.8:
                        out = -0.8 - 0.2 * _tanh((-out - 0.8) * 5.0)
                if out != out:                   # NaN guard: never let a bad sample escape
                    out = 0.0
                dst[i] = out
                ao = out if out >= 0.0 else -out
                if ao > pk_out:
                    pk_out = ao
            st["hp"], st["lp"] = hp, lp
            st["gate_env"], st["gate_g"] = genv, ggain
            st["prev"], st["dc_x"], st["dc_y"] = prev, dcx, dcy
            if ch == 0:
                step = max(1, n // len(self._wave))
                self._wave = [dst[min(n - 1, k * step)] for k in range(len(self._wave))]

        self._g_now, self._lvl_now = g_target, lvl_target
        # -- meters: instant attack, smooth fall --
        self._in_meter = max(pk_in, self._in_meter * 0.82)
        self._out_meter = max(pk_out, self._out_meter * 0.82)
        self._last_peak_in = pk_in
        self.ui_set("m_in", value=min(1.0, self._in_meter))
        self.ui_set("m_out", value=min(1.0, self._out_meter))
        self.repaint("scope")

    # ---- custom drawing -------------------------------------------------------------------------
    def paint_scope(self, cv):
        """Left: the transfer curve for the current voicing; right: the last output block."""
        w, h = cv.width, cv.height
        cv.gradient(0, 0, w, h, "#1d2027", "#12141a")
        half = w // 3
        cv.grid(6, 6, half - 12, h - 12, 4, 4, "#262b35")
        cv.line(6 + (half - 12) / 2, 6, 6 + (half - 12) / 2, h - 6, "#3a4150")
        cv.line(6, h / 2, half - 6, h / 2, "#3a4150")
        shape = SHAPERS[self.p.mode]
        stages = self.p.stages
        g = self._drive_gain()
        scale = (h / 2 - 8) * 0.8
        pts = []
        for i in range(61):
            x = -1.0 + 2.0 * i / 60
            y = max(-1.2, min(1.2, self._amp(shape, x * g * 0.35, stages)))
            pts.append((6 + (half - 12) * i / 60, h / 2 - y * scale))
        cv.polyline(pts, "#ffb347", 2)
        peak = min(1.0, getattr(self, "_last_peak_in", 0.0))
        dot = max(-1.2, min(1.2, self._amp(shape, peak * g * 0.35, stages)))
        cv.circle(6 + (half - 12) * (0.5 + 0.5 * peak), h / 2 - dot * scale, 3, fill="#ffffff")
        cv.text(8, 7, "TRANSFER", "#8a93a3", 10, True)
        # waveform of the last block
        x0 = half + 4
        cv.rect(x0, 4, w - x0 - 6, h - 8, "#262b35")
        cv.line(x0, h / 2, w - 6, h / 2, "#303644")
        cv.plot(self._wave, x0, 6, w - x0 - 6, h - 12, -1.0, 1.0, "#6fe0a0", 1)
        cv.text(x0 + 4, 7, "OUTPUT", "#8a93a3", 10, True)

    # ---- presets and saved state ---------------------------------------------------------------
    def on_preset(self, event, value):
        try:
            idx = int(value)
            if idx <= 0:
                return
            name = PRESET_ORDER[idx - 1]
        except (TypeError, ValueError, IndexError):
            return
        mode, drive, tight, tone, bass, mid, pres, gate, cab, os_, mix, level, stages = PRESETS[name]
        for pid, v in (("mode", mode), ("drive", drive), ("stages", stages), ("tight", tight),
                       ("tone", tone), ("bass", bass), ("mid", mid), ("presence", pres), ("gate", gate),
                       ("cab", 1 if cab else 0), ("oversample", 1 if os_ else 0),
                       ("mix", mix), ("level", level)):
            self.set_param(pid, v)
        self._preset = idx
        self.log("preset: " + name)

    def get_state(self):
        return {"preset": self._preset}

    def set_state(self, state):
        if isinstance(state, dict):
            self._preset = int(state.get("preset", 0))
            self.ui_set("preset", value=self._preset)
