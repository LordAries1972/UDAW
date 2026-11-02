"""Reverberator & Chorus  -  a stereo chorus feeding an algorithmic reverb, for UDAW.

Written by Daniel J. Hobson, Australia.

What it does
------------
Two classic effects in one plug-in, in series:

  * CHORUS - one to four short, slowly modulated delays per channel are mixed with the dry signal.  Because the
    delay time wobbles, each copy is slightly detuned and drifts in time, which thickens a thin guitar, widens
    a synth pad or turns one vocal into a small ensemble.  The right channel's modulation is offset from the
    left's, so a mono source comes out wide.
  * REVERB - a Schroeder / Freeverb-style room: a pre-delay, eight parallel comb filters (the room's
    resonances, each with damping so high frequencies die faster, as in a real room), and four all-pass
    filters that blur the echoes into a smooth tail.  Size sets the room, Decay sets how long the tail takes
    to fall by 60 dB, Damping sets how dark it gets, Width sets the stereo spread.

Why use it on one lane?  A chorused electric piano pushed into a short plate behaves like a finished part;
a bus of backing vocals with the Cathedral setting sits behind the lead without further work.

How it is written
-----------------
All the maths is vectorised with numpy, one block at a time.  A comb filter's feedback reaches back at least
a few hundred samples, so a whole chunk of 256 samples can be computed in one go: no per-sample loop, a few
percent of the real-time budget.  Without numpy the plug-in passes audio through and says so in its log.
Changing Size rebuilds the room (the tail restarts); every other control is smooth.
"""

import math

import udaw_plugin as up

try:
    import numpy as np
except Exception:                                   # numpy missing: the plug-in explains itself
    np = None

CH = 256                                            # processing chunk: every delay below is longer than this
COMBS = (1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617)      # Freeverb lengths at 44.1 kHz
ALLPASS = (556, 441, 341, 225)
SPREAD = 23                                         # right channel is longer by this much (stereo)
TYPES = ["Room", "Hall", "Plate", "Cathedral", "Custom"]
#: type -> (size %, decay s, damping %, pre-delay ms, mix %)
TYPE_SETTINGS = {
    "Room": (35, 0.9, 55, 6, 20),
    "Hall": (62, 2.4, 45, 18, 28),
    "Plate": (50, 1.8, 20, 2, 30),
    "Cathedral": (95, 7.5, 60, 35, 40),
}
PRESETS = {
    #                  chorus: on rate depth delay voices mix   | reverb: on type size decay damp pre width mix | level
    "Lush Pad":        (True, 0.5, 60, 16, 4, 55,   True, 1, 70, 3.2, 45, 25, 100, 35, 0.0),
    "Electric Piano":  (True, 0.9, 40, 12, 2, 50,   True, 2, 45, 1.4, 20, 4, 90, 22, -1.0),
    "Vocal Ensemble":  (True, 0.7, 50, 18, 4, 40,   True, 1, 60, 2.2, 40, 20, 100, 25, 0.0),
    "Clean Guitar":    (True, 0.8, 35, 11, 2, 45,   True, 0, 30, 0.8, 55, 5, 80, 18, 0.0),
    "Big Cathedral":   (False, 0.8, 40, 12, 2, 0,   True, 3, 95, 7.5, 60, 35, 100, 45, -2.0),
    "Slow Shimmer":    (True, 0.2, 80, 22, 4, 70,   True, 1, 80, 4.5, 30, 30, 100, 40, -1.0),
}
PRESET_ORDER = list(PRESETS)


class Plugin(up.Plugin):
    name = "Reverberator & Chorus"
    vendor = "UDAW examples"
    author = "Daniel J. Hobson, Australia"
    version = "1.0"
    description = "A stereo chorus into an algorithmic reverb: rooms, halls, plates and cathedrals, with a lush ensemble in front."
    use_numpy = True

    # ---- parameters -------------------------------------------------------------------------------
    def setup(self):
        self.add_bool("c_on", "Chorus", default=True, group="Chorus")
        self.add_param("c_rate", "Rate", min=0.05, max=8, default=0.7, unit="Hz", log=True, decimals=2, group="Chorus")
        self.add_param("c_depth", "Depth", min=0, max=100, default=45, unit="%", decimals=0, group="Chorus")
        self.add_param("c_delay", "Delay", min=4, max=30, default=14, unit="ms", decimals=1, group="Chorus")
        self.add_param("c_voices", "Voices", min=1, max=4, default=3, kind="int", group="Chorus")
        self.add_param("c_mix", "Mix", min=0, max=100, default=45, unit="%", decimals=0, group="Chorus")
        self.add_bool("r_on", "Reverb", default=True, group="Reverb")
        self.add_choice("r_type", "Room type", TYPES, default=1, group="Reverb")
        self.add_param("r_size", "Size", min=0, max=100, default=62, unit="%", decimals=0, group="Reverb")
        self.add_param("r_decay", "Decay", min=0.2, max=12, default=2.4, unit="s", log=True, decimals=1, group="Reverb")
        self.add_param("r_damp", "Damping", min=0, max=100, default=45, unit="%", decimals=0, group="Reverb")
        self.add_param("r_pre", "Pre-delay", min=0, max=200, default=18, unit="ms", decimals=0, group="Reverb")
        self.add_param("r_width", "Width", min=0, max=100, default=100, unit="%", decimals=0, group="Reverb")
        self.add_param("r_mix", "Mix", min=0, max=100, default=28, unit="%", decimals=0, group="Reverb")
        self.add_param("level", "Level", min=-24, max=12, default=0, unit="dB", decimals=1, group="Output")
        self._preset = 0
        self._anim = 0.0
        self._applying = False      # a preset / room type is moving several controls: do not treat them as hand edits

    # ---- window -----------------------------------------------------------------------------------
    def ui(self, ui):
        ui.window(820, 440, "Reverberator & Chorus", color="#16181d")
        ui.label("title", "REVERB & CHORUS", 16, 10, 260, 22, font_size=15, bold=True)
        ui.label("sub", "ensemble in front, room behind", 16, 32, 260, 16, font_color="#8a93a3")
        ui.combo("preset", ["Presets..."] + PRESET_ORDER, 580, 12, 224, 26, value=self._preset,
                 hint="Load a ready-made sound")

        ui.tabs("tabs", ["Effects", "About"], 8, 56, 804, 376)
        ui.group("g_cho", "CHORUS", 8, 8, 372, 196, parent="tabs#0")
        ui.check("x_con", "Chorus on", 18, 28, 140, 22, param="c_on", parent="tabs#0")
        ui.knob("k_crate", 16, 54, 66, 98, param="c_rate", label="Rate", parent="tabs#0",
                hint="How fast the delay time wobbles")
        ui.knob("k_cdep", 86, 54, 66, 98, param="c_depth", label="Depth", parent="tabs#0",
                hint="How far the delay time swings: more depth, more detune")
        ui.knob("k_cdel", 156, 54, 66, 98, param="c_delay", label="Delay", parent="tabs#0",
                hint="The centre of the delay time; longer is more 'flange-free' and ensemble-like")
        ui.knob("k_cvox", 226, 54, 66, 98, param="c_voices", label="Voices", parent="tabs#0",
                hint="Number of modulated copies mixed together")
        ui.knob("k_cmix", 296, 54, 66, 98, param="c_mix", label="Mix", parent="tabs#0")
        ui.canvas("lfo", 16, 158, 356, 38, parent="tabs#0", fps=20, mouse=False)

        ui.group("g_rev", "REVERB", 388, 8, 376, 196, parent="tabs#0")
        ui.check("x_ron", "Reverb on", 398, 28, 110, 22, param="r_on", parent="tabs#0")
        ui.combo("c_type", TYPES, 516, 26, 136, 26, param="r_type", parent="tabs#0")
        ui.knob("k_size", 394, 54, 58, 92, param="r_size", label="Size", parent="tabs#0",
                hint="Room size (changing it restarts the tail)")
        ui.knob("k_dec", 454, 54, 58, 92, param="r_decay", label="Decay", parent="tabs#0",
                hint="Time for the tail to fall by 60 dB")
        ui.knob("k_dmp", 514, 54, 58, 92, param="r_damp", label="Damping", parent="tabs#0",
                hint="How quickly high frequencies die away: more damping, a darker tail")
        ui.knob("k_pre", 574, 54, 58, 92, param="r_pre", label="Pre-delay", parent="tabs#0",
                hint="Gap between the dry sound and the start of the reverb")
        ui.knob("k_wid", 634, 54, 58, 92, param="r_width", label="Width", parent="tabs#0")
        ui.knob("k_rmix", 694, 54, 58, 92, param="r_mix", label="Mix", parent="tabs#0")
        ui.canvas("tail", 396, 152, 360, 44, parent="tabs#0", fps=12, mouse=False)

        ui.group("g_out", "OUTPUT", 8, 212, 756, 124, parent="tabs#0")
        ui.knob("k_lvl", 18, 228, 72, 104, param="level", label="Level", parent="tabs#0")
        ui.meter("m_in", 108, 232, 20, 96, vertical=True, parent="tabs#0", hint="Input level")
        ui.meter("m_out", 136, 232, 20, 96, vertical=True, parent="tabs#0", hint="Output level")
        ui.memo("hint", self.hint_text(), 176, 232, 580, 96, parent="tabs#0", read_only=True)
        ui.memo("about", self.about_text(), 12, 12, 780, 320, parent="tabs#1", read_only=True)

    def hint_text(self):
        return ("Chorus first, then reverb.  Use the Room type list for a quick start (Room, Hall, Plate, Cathedral),\n"
                "then adjust Size, Decay and Damping.  A little Pre-delay keeps a vocal in front of its own reverb.\n"
                "Turn Chorus off (or its Mix to 0) for a pure reverb, or Reverb off for a pure chorus.")

    def about_text(self):
        return (
            "Reverberator & Chorus\nVersion %s  -  written by %s\n\n" % (self.version, self.author) +
            "CHORUS  Rate - speed of the modulation.  Depth - how far the delay swings (the detune).\n"
            "  Delay - centre delay time.  Voices - how many modulated copies.  Mix - amount.\n\n"
            "REVERB  Room type - Room, Hall, Plate, Cathedral set sensible starting values (Custom keeps yours).\n"
            "  Size - the room.  Decay - time for the tail to fall 60 dB.  Damping - how dark the tail gets.\n"
            "  Pre-delay - gap before the reverb starts.  Width - stereo spread of the tail.  Mix - amount.\n\n"
            "Needs numpy: pip install numpy."
        )

    # ---- audio ------------------------------------------------------------------------------------
    def prepare(self, sample_rate, channels, max_frames):
        self._sr = float(sample_rate)
        self._ok = np is not None
        if not self._ok:
            self.log("Reverberator & Chorus needs numpy (pip install numpy); until then the audio passes through unchanged.")
            return
        self._cL = 16384
        self._build_chorus()
        self._build_reverb()
        self._in_meter = self._out_meter = 0.0

    def _build_chorus(self):
        self._chist = [np.zeros(self._cL), np.zeros(self._cL)]
        self._cwp = [0, 0]
        self._cph = [0.0, 0.0]

    def _build_reverb(self):
        sr = self._sr
        scale = (sr / 44100.0) * (0.45 + self.p.r_size * 0.011)
        floor = CH + 16

        def mk(length):
            d = max(floor, int(length * scale))
            return {"D": d, "buf": np.zeros(d), "pos": 0, "last": 0.0}

        self._combs = [[mk(c + side * SPREAD) for c in COMBS] for side in (0, 1)]
        self._aps = [[mk(a + side * SPREAD) for a in ALLPASS] for side in (0, 1)]
        self._plen = int(0.2 * sr) + CH + 16
        self._pbuf = np.zeros(self._plen)
        self._ppos = 0

    def reset(self):
        if getattr(self, "_ok", False):
            self._build_chorus()
            self._build_reverb()

    def on_param(self, pid, value):
        if not getattr(self, "_ok", False):
            return
        if pid == "r_size":
            self._build_reverb()
        elif pid == "r_type":
            name = TYPES[int(value)]
            if name in TYPE_SETTINGS and not self._applying:
                size, decay, damp, pre, mix = TYPE_SETTINGS[name]
                self._applying = True
                try:
                    for k, v in (("r_size", size), ("r_decay", decay), ("r_damp", damp), ("r_pre", pre), ("r_mix", mix)):
                        self.set_param(k, v)
                finally:
                    self._applying = False
        elif pid in ("r_decay", "r_damp", "r_pre", "r_mix") and not self._applying:
            if self.p.r_type != 4:                  # hand-tuned: it is a Custom room now
                self._applying = True
                try:
                    self.set_param("r_type", 4)
                finally:
                    self._applying = False

    # -- chorus ----------------------------------------------------------------------------------
    def _chorus(self, c, x):
        p = self.p
        n = len(x)
        L = self._cL
        hist = self._chist[c]
        wp = self._cwp[c]
        t = np.arange(n)
        hist[(wp + t) % L] = x
        sr = self._sr
        d0 = p.c_delay * 0.001 * sr
        dep = p.c_depth * 0.01 * d0 * 0.85
        rate = p.c_rate
        voices = int(p.c_voices)
        acc = np.zeros(n)
        for v in range(voices):
            phase = self._cph[c] + v / voices + (0.25 if c == 1 else 0.0)
            lfo = np.sin(2.0 * math.pi * (phase + t * rate / sr))
            pos = (wp + t) - (d0 + dep * lfo)
            i0 = np.floor(pos).astype(np.int64)
            fr = pos - i0
            a = hist[i0 % L]
            b = hist[(i0 + 1) % L]
            acc += a + (b - a) * fr
        self._cph[c] = (self._cph[c] + n * rate / sr) % 1.0
        self._cwp[c] = (wp + n) % L
        mix = p.c_mix * 0.01
        return x * (1.0 - 0.5 * mix) + (acc / voices) * mix

    # -- reverb ----------------------------------------------------------------------------------
    @staticmethod
    def _comb(st, x, g, damp):
        m = len(x)
        D = st["D"]
        buf = st["buf"]
        idx = (st["pos"] + np.arange(m)) % D
        d = buf[idx]
        prev = np.empty(m)
        prev[0] = st["last"]
        prev[1:] = d[:-1]
        df = d * (1.0 - damp) + prev * damp
        st["last"] = d[-1]
        buf[idx] = x + g * df
        st["pos"] = (st["pos"] + m) % D
        return df

    @staticmethod
    def _allpass(st, x):
        m = len(x)
        D = st["D"]
        buf = st["buf"]
        idx = (st["pos"] + np.arange(m)) % D
        vd = buf[idx]
        buf[idx] = x + 0.5 * vd
        st["pos"] = (st["pos"] + m) % D
        return vd - x

    def _reverb(self, xl, xr):
        p = self.p
        n = len(xl)
        sr = self._sr
        outl = np.empty(n)
        outr = np.empty(n)
        pre = int(p.r_pre * 0.001 * sr)
        damp = min(0.9, p.r_damp * 0.009)
        decay = max(0.1, p.r_decay)
        width = p.r_width * 0.01
        for s in range(0, n, CH):
            e = min(n, s + CH)
            m = e - s
            mono = 0.5 * (xl[s:e] + xr[s:e])
            # pre-delay: write, then read pre samples back
            idx = (self._ppos + np.arange(m)) % self._plen
            self._pbuf[idx] = mono
            mono = self._pbuf[(self._ppos + np.arange(m) - pre) % self._plen]
            self._ppos = (self._ppos + m) % self._plen
            wet = []
            for side in (0, 1):
                acc = np.zeros(m)
                for st in self._combs[side]:
                    g = min(0.985, 10.0 ** (-3.0 * st["D"] / (sr * decay)))
                    acc += self._comb(st, mono * 0.03, g, damp)
                for st in self._aps[side]:
                    acc = self._allpass(st, acc)
                wet.append(acc)
            mid = 0.5 * (wet[0] + wet[1])
            side_sig = 0.5 * (wet[0] - wet[1]) * width
            outl[s:e] = (mid + side_sig) * WET_GAIN
            outr[s:e] = (mid - side_sig) * WET_GAIN
        return outl, outr

    def process(self, block):
        if not self._ok:
            block.copy_through()
            return
        p = self.p
        n = block.frames
        chans = block.channels
        x = [block.inp[c].astype(np.float64) for c in range(min(chans, 2))]
        dry_in = [v.copy() for v in x]
        if p.c_on and p.c_mix > 0:
            x = [self._chorus(c, x[c]) for c in range(len(x))]
        if p.r_on and p.r_mix > 0:
            xl = x[0]
            xr = x[1] if len(x) > 1 else x[0]
            wl, wr = self._reverb(xl, xr)
            mix = p.r_mix * 0.01
            if len(x) > 1:
                x = [x[0] * (1.0 - 0.5 * mix) + wl * mix, x[1] * (1.0 - 0.5 * mix) + wr * mix]
            else:
                x = [x[0] * (1.0 - 0.5 * mix) + 0.5 * (wl + wr) * mix]
        lvl = up.db_to_lin(p.level)
        pin = max(float(np.max(np.abs(v))) for v in dry_in) if n else 0.0
        pout = 0.0
        for c in range(len(x)):
            y = np.clip(x[c] * lvl, -1.0, 1.0)
            block.out[c][:] = y.astype(np.float32)
            pout = max(pout, float(np.max(np.abs(y))))
        self._in_meter = max(pin, self._in_meter * 0.85)
        self._out_meter = max(pout, self._out_meter * 0.85)
        self.ui_set("m_in", value=min(1.0, self._in_meter))
        self.ui_set("m_out", value=min(1.0, self._out_meter))

    # ---- the two small displays ---------------------------------------------------------------
    def paint_lfo(self, cv):
        w, h = cv.width, cv.height
        cv.gradient(0, 0, w, h, "#1d2027", "#12141a")
        self._anim = (self._anim + 0.03 * max(0.1, self.p.c_rate)) % 1.0
        voices = int(self.p.c_voices)
        depth = self.p.c_depth * 0.01
        for v in range(voices):
            pts = []
            for i in range(0, w - 8, 3):
                ph = self._anim + v / voices + i / (w * 0.5)
                pts.append((4 + i, h / 2 - math.sin(2 * math.pi * ph) * depth * (h / 2 - 5)))
            cv.polyline(pts, up.rgb(90 + 40 * v, 200 - 25 * v, 255 - 30 * v), 1)
        cv.text(6, 2, "DELAY MODULATION", "#8a93a3", 9, True)

    def paint_tail(self, cv):
        w, h = cv.width, cv.height
        cv.gradient(0, 0, w, h, "#1d2027", "#12141a")
        decay = max(0.1, self.p.r_decay)
        pre = self.p.r_pre / 1000.0
        span = max(decay * 1.2, 0.5)
        pts = []
        for i in range(w - 8):
            t = i / (w - 8) * span
            if t < pre:
                pts.append((4 + i, h - 4))
            else:
                db = -60.0 * (t - pre) / decay
                pts.append((4 + i, h - 4 - (h - 12) * max(0.0, 1.0 + db / 60.0)))
        cv.polygon(pts + [(w - 4, h - 4), (4, h - 4)], fill=up.rgb(40, 90, 70), stroke="#6fe0a0")
        x60 = 4 + (w - 8) * (pre + decay) / span
        cv.line(x60, 4, x60, h - 4, "#ffb347", 1, True)
        cv.text(6, 2, "TAIL (-60 dB at the orange line)", "#8a93a3", 9, True)

    # ---- presets and saved state -----------------------------------------------------------------
    def on_preset(self, event, value):
        try:
            idx = int(value)
            if idx <= 0:
                return
            name = PRESET_ORDER[idx - 1]
        except (TypeError, ValueError, IndexError):
            return
        (con, crate, cdep, cdel, cvox, cmix, ron, rtype, rsize, rdec, rdmp, rpre, rwid, rmix, level) = PRESETS[name]
        self._applying = True
        try:
            for pid, v in (("c_on", con), ("c_rate", crate), ("c_depth", cdep), ("c_delay", cdel),
                           ("c_voices", cvox), ("c_mix", cmix), ("r_on", ron), ("r_size", rsize),
                           ("r_decay", rdec), ("r_damp", rdmp), ("r_pre", rpre), ("r_width", rwid),
                           ("r_mix", rmix), ("level", level), ("r_type", rtype)):
                self.set_param(pid, v)
        finally:
            self._applying = False
        self._preset = idx
        self.log("preset: " + name)

    def get_state(self):
        return {"preset": self._preset}

    def set_state(self, state):
        if isinstance(state, dict):
            self._preset = int(state.get("preset", 0))
            self.ui_set("preset", value=self._preset)


#: output scale of the reverb tail, set so a 100% wet room is about as loud as its input
WET_GAIN = 1.8
