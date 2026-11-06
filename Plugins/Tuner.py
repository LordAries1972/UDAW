"""Tuner  -  a chromatic / guitar / bass / violin / viola / cello / ukulele / vocal tuner for UDAW.

Written by Daniel J. Hobson, Australia.

What it does
------------
Tuner listens to the audio on the lane (or mixer strip) it is inserted on, finds the pitch of the note being
played or sung and shows how many cents sharp or flat it is against the note you want.  The audio passes
through untouched (or muted, if you wish) so it can sit on a live input while you tune.

  * INSTRUMENT picks guitar, bass, violin, viola, cello, ukulele, vocal or plain chromatic.
  * TUNING picks a tuning for that instrument: standard, drop, open, DADGAD, 5/6/7-string, cross-tuning...
  * LOW STRING TO moves the whole tuning to a key: choose D and a standard guitar becomes whole-step-down
    (D G C F A D).  "As written" leaves the tuning alone.
  * KEY and SCALE (Vocal and Chromatic) decide which notes count as "in key": sing a C major scale and a
    note between C and D is judged against whichever of the two it is nearer, never against C#.
  * AUTO finds the string you are playing; click a string to lock onto it (click again to go back to auto).
  * A4 REFERENCE moves the pitch of the whole tuner from 415 to 466 Hz (440 is concert pitch).
  * REFERENCE TONE plays the target note so you can tune by ear - a sine, a soft triangle or an organ-like tone.

MIDI
----
MIDI in: a key selects the string nearest to it (Vocal / Chromatic: that exact note) and, with "Keys play the
reference tone" on, sounds it while the key is held.  Program change 0-7 picks the instrument.  Controllers
move the tone level, A4 reference, noise gate, in-tune window and detection threshold.
MIDI out: with "Send detected note as MIDI" on, the note being played is sent out as a MIDI note with pitch
bend for the cents, so a synth can follow your voice or instrument.

How it is written
-----------------
numpy only.  process() copies the input into a ring buffer and mixes the reference tone; the pitch is found
on the control thread (about 20 times a second) with the YIN algorithm - the input is averaged down to about
12 kHz, the difference function is computed with an FFT, the cumulative-mean-normalised version is searched
for the first dip under the threshold and the dip is refined with a parabola.  Without numpy the plug-in
passes the audio through and says so in its log.
"""

import math
from collections import deque

import udaw_plugin as up

try:
    import numpy as np
except Exception:                                   # numpy missing: the plug-in explains itself
    np = None

INSTRUMENTS = ["Guitar", "Bass", "Violin", "Viola", "Cello", "Ukulele", "Vocal", "Chromatic"]
SCALE_MODES = ("Vocal", "Chromatic")

#: instrument -> [(tuning name, [MIDI note of each string, as drawn left to right])]
TUNINGS = {
    "Guitar": [
        ("Standard (E A D G B E)", [40, 45, 50, 55, 59, 64]),
        ("Drop D (D A D G B E)", [38, 45, 50, 55, 59, 64]),
        ("Half-step down (Eb)", [39, 44, 49, 54, 58, 63]),
        ("Whole-step down (D)", [38, 43, 48, 53, 57, 62]),
        ("Drop C (C G C F A D)", [36, 43, 48, 53, 57, 62]),
        ("DADGAD", [38, 45, 50, 55, 57, 62]),
        ("Open G (D G D G B D)", [38, 43, 50, 55, 59, 62]),
        ("Open D (D A D F# A D)", [38, 45, 50, 54, 57, 62]),
        ("Open E (E B E G# B E)", [40, 47, 52, 56, 59, 64]),
        ("Open A (E A C# E A E)", [40, 45, 49, 52, 57, 64]),
        ("Double drop D (D A D G B D)", [38, 45, 50, 55, 59, 62]),
        ("Nashville (high-strung)", [52, 57, 62, 67, 59, 64]),
        ("7-string (B E A D G B E)", [35, 40, 45, 50, 55, 59, 64]),
    ],
    "Bass": [
        ("4-string standard (E A D G)", [28, 33, 38, 43]),
        ("5-string (B E A D G)", [23, 28, 33, 38, 43]),
        ("6-string (B E A D G C)", [23, 28, 33, 38, 43, 48]),
        ("Drop D (D A D G)", [26, 33, 38, 43]),
        ("Half-step down (Eb)", [27, 32, 37, 42]),
        ("D standard (D G C F)", [26, 31, 36, 41]),
    ],
    "Violin": [
        ("Standard (G D A E)", [55, 62, 69, 76]),
        ("Cross-tuning (A E A E)", [57, 64, 69, 76]),
    ],
    "Viola": [
        ("Standard (C G D A)", [48, 55, 62, 69]),
    ],
    "Cello": [
        ("Standard (C G D A)", [36, 43, 50, 57]),
        ("Bach suite 5 (C G D G)", [36, 43, 50, 55]),
    ],
    "Ukulele": [
        ("Standard (G C E A)", [67, 60, 64, 69]),
        ("Low G (G C E A)", [55, 60, 64, 69]),
        ("Baritone (D G B E)", [50, 55, 59, 64]),
    ],
}
TUN_MAX = max(len(v) for v in TUNINGS.values())

KEY_SHARP = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
KEY_FLAT = ["C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"]
KEY_LABELS = ["C", "C#/Db", "D", "D#/Eb", "E", "F", "F#/Gb", "G", "G#/Ab", "A", "A#/Bb", "B"]

SCALES = [
    ("Chromatic (all notes)", (0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11)),
    ("Major", (0, 2, 4, 5, 7, 9, 11)),
    ("Natural minor", (0, 2, 3, 5, 7, 8, 10)),
    ("Harmonic minor", (0, 2, 3, 5, 7, 8, 11)),
    ("Major pentatonic", (0, 2, 4, 7, 9)),
    ("Minor pentatonic", (0, 3, 5, 7, 10)),
    ("Blues", (0, 3, 5, 6, 7, 10)),
    ("Dorian", (0, 2, 3, 5, 7, 9, 10)),
    ("Mixolydian", (0, 2, 4, 5, 7, 9, 10)),
]
WAVES = ["Sine", "Triangle", "Organ"]

#: the preset box: (instrument, tuning index)
PRESETS = [(inst, i) for inst in INSTRUMENTS if inst in TUNINGS for i in range(len(TUNINGS[inst]))]
PRESETS += [("Vocal", 0), ("Chromatic", 0)]
PRESET_ORDER = ["%s: %s" % (inst, TUNINGS[inst][i][0]) if inst in TUNINGS else "%s tuner" % inst
                for inst, i in PRESETS]

COL_BG = "#12151a"
COL_DIM = "#3a4150"
COL_TXT = "#dde3ee"
COL_SUB = "#8a93a3"
COL_OK = "#3fcf7a"
COL_NEAR = "#e8c24a"
COL_FAR = "#ee6a5a"
COL_BLUE = "#5aa8ff"


def yin(x, sr, fmin, fmax, thr):
    """Pitch of ``x`` (mono, float64) by the YIN method: returns (frequency Hz, confidence 0..1) or None.
    ``len(x)`` must be at least ``tmax + window`` samples long (see Plugin._analyse)."""
    tmax = int(sr / fmin) + 1
    tmin = max(2, int(sr / fmax))
    w = len(x) - tmax
    if w < tmax or tmax <= tmin + 2:
        return None
    n = 1 << (len(x) + w - 1).bit_length()
    fa = np.fft.rfft(x[:w], n)
    fb = np.fft.rfft(x, n)
    r = np.fft.irfft(fb * np.conj(fa), n)[:tmax + 1]
    c = np.concatenate(([0.0], np.cumsum(x * x)))
    taus = np.arange(tmax + 1)
    d = c[w] + (c[w + taus] - c[taus]) - 2.0 * r
    d[0] = 0.0
    d = np.maximum(d, 0.0)
    cm = np.ones(tmax + 1)
    cm[1:] = d[1:] * taus[1:] / np.maximum(np.cumsum(d[1:]), 1e-12)
    seg = cm[tmin:tmax]
    below = np.nonzero(seg < thr)[0]
    if len(below):
        t = tmin + int(below[0])
        while t + 1 < tmax and cm[t + 1] < cm[t]:
            t += 1
    else:
        t = tmin + int(np.argmin(seg))
        if cm[t] > 0.3:
            return None
    shift = 0.0
    if 1 <= t < tmax:
        s0, s1, s2 = cm[t - 1], cm[t], cm[t + 1]
        den = s0 - 2.0 * s1 + s2
        if den > 1e-12:
            shift = max(-1.0, min(1.0, 0.5 * (s0 - s2) / den))
    tau = t + shift
    if tau <= 0:
        return None
    return sr / tau, float(max(0.0, min(1.0, 1.0 - cm[t])))


class Plugin(up.Plugin):
    name = "Tuner"
    vendor = "UDAW examples"
    author = "Daniel J. Hobson, Australia"
    version = "1.0"
    description = ("A tuner for guitar, bass, violin, viola, cello, ukulele and voice: pick the instrument, "
                   "tuning and key, see the cents on a needle, hear a reference tone, and drive it from MIDI.")
    use_numpy = True

    midi_cc = {7: "tone_level", 20: "ref", 21: "gate_db", 22: "tol", 23: "thresh"}
    midi_notes = ("A key selects the string nearest to it (Vocal / Chromatic: that exact note) and, with 'Keys play",
                  "the reference tone' on, sounds it while the key is held.",
                  "Program change 0-7 picks the instrument: Guitar, Bass, Violin, Viola, Cello, Ukulele, Vocal, Chromatic.",
                  "With 'Release returns to auto' on, letting go of the keys goes back to finding the string by ear.",
                  "With 'Send detected note as MIDI' on, the note you play is sent out with pitch bend for the cents",
                  "(a +/-2 semitone bend range is assumed).")

    # class-level defaults so on_param is safe before setup has finished
    _loading = False
    _ok = False
    _sr = 48000.0

    # ---- parameters ------------------------------------------------------------------------
    def setup(self):
        self.add_choice("inst", "Instrument", INSTRUMENTS, default=0, group="Tuner")
        self.add_choice("tuning", "Tuning", ["Tuning %d" % (i + 1) for i in range(TUN_MAX)], default=0, group="Tuner")
        self.add_choice("tune_key", "Low string to", ["As written"] + KEY_LABELS, default=0, group="Tuner")
        self.add_choice("key", "Key", KEY_LABELS, default=0, group="Tuner")
        self.add_choice("scale", "Scale", [s[0] for s in SCALES], default=0, group="Tuner")
        self.add_param("ref", "A4 reference", min=400, max=480, default=440, unit="Hz", decimals=1, group="Tuner")
        self.add_param("tol", "In tune within", min=1, max=25, default=5, unit="cents", decimals=0, group="Tuner")
        self.add_bool("hold", "Hold reading", default=False, group="Tuner")
        self.add_param("gate_db", "Noise gate", min=-80, max=-20, default=-55, unit="dB", decimals=0,
                       group="Detection")
        self.add_param("thresh", "Detection threshold", min=0.05, max=0.35, default=0.15, decimals=2,
                       group="Detection")
        self.add_param("smooth", "Smoothing", min=0, max=100, default=40, unit="%", decimals=0, group="Detection")
        self.add_bool("flats", "Show flats (Bb) instead of sharps (A#)", default=False, group="Display")
        self.add_bool("show_freq", "Show frequency", default=True, group="Display")
        self.add_bool("tone", "Reference tone", default=False, group="Tone")
        self.add_choice("wave", "Tone", WAVES, default=0, group="Tone")
        self.add_param("tone_level", "Tone level", min=-40, max=0, default=-18, unit="dB", decimals=0, group="Tone")
        self.add_bool("mute", "Mute instrument", default=False, group="Tone")
        self.add_midi_params()
        self.add_bool("midi_release", "Release returns to auto", default=True, group="MIDI")
        self.add_bool("midi_tone", "Keys play the reference tone", default=True, group="MIDI")
        self.add_bool("midi_out", "Send detected note as MIDI", default=False, group="MIDI")
        self._sel = -1                  # locked string (-1: auto)
        self._lock = None               # locked MIDI note (Vocal / Chromatic)
        self._held = set()
        self._view = None               # what the canvases draw
        self._reading = None
        self._mf = None                 # smoothed pitch, as a float MIDI note
        self._last_time = 0.0
        self._silent = 0
        self._target = None             # last target MIDI note (int)
        self._hist = deque(maxlen=160)
        self._hit = []
        self._ui_dirty = True
        self._tone_hz = 0.0
        self._tone_on = False
        self._tone_amp = 0.0
        self._phase = 0.0
        self._out_note = None
        self._out_cand = None
        self._intune_since = None
        self._clock = 0

    # ---- helpers about the chosen instrument ---------------------------------------------------
    def _inst(self):
        return INSTRUMENTS[int(self.p.inst)]

    def _tunings(self):
        return TUNINGS.get(self._inst())

    def _notes(self):
        """The strings' MIDI notes after "Low string to", or None for Vocal / Chromatic."""
        t = self._tunings()
        if not t:
            return None
        notes = list(t[min(int(self.p.tuning), len(t) - 1)][1])
        k = int(self.p.tune_key)
        if k > 0:
            low = min(notes)
            shift = ((k - 1) - low % 12 + 6) % 12 - 6
            notes = [n + shift for n in notes]
        return notes

    def _scale_pcs(self):
        root = int(self.p.key)
        return {(root + i) % 12 for i in SCALES[int(self.p.scale)][1]}

    def _hz(self, midi):
        return float(self.p.ref) * 2.0 ** ((midi - 69.0) / 12.0)

    def _name(self, midi, octave=True):
        names = KEY_FLAT if self.p.flats else KEY_SHARP
        n = int(round(midi))
        return names[n % 12] + (str(n // 12 - 1) if octave else "")

    # ---- window ---------------------------------------------------------------------------------
    def ui(self, ui):
        ui.window(820, 484, "Tuner", color="#16181d")
        ui.label("title", "TUNER", 16, 12, 90, 22, font_size=15, bold=True)
        ui.combo("c_inst", INSTRUMENTS, 112, 12, 112, 24, param="inst",
                 hint="Guitar, bass, violin, viola, cello, ukulele, voice or any note (Chromatic)")
        tun = self._tunings()
        ui.combo("c_tuning", [t[0] for t in tun] if tun else ["(not used)"], 232, 12, 230, 24, param="tuning",
                 hint="The tuning of the strings. Vocal and Chromatic use the Key and Scale instead.")
        ui.label("l_tk", "Low string to", 476, 16, 84, 18, font_color="#8a93a3")
        ui.combo("c_tk", ["As written"] + KEY_LABELS, 564, 12, 120, 24, param="tune_key",
                 hint="Move the whole tuning so its lowest string is this note (D turns standard guitar into D standard)")

        ui.tabs("tabs", ["Tuner", "Settings", "MIDI", "About"], 8, 56, 804, 424)
        ui.canvas("gauge", 8, 4, 560, 250, parent="tabs#0", fps=20, mouse=False)
        ui.canvas("strings", 8, 262, 560, 70, parent="tabs#0", fps=20, mouse=True)
        ui.canvas("hist", 8, 338, 560, 50, parent="tabs#0", fps=20, mouse=False)

        ui.group("g_tgt", "TARGET", 576, 4, 212, 250, parent="tabs#0")
        ui.label("l_key", "Key", 584, 30, 50, 18, parent="tabs#0")
        ui.combo("c_key", KEY_LABELS, 640, 26, 140, 24, param="key", parent="tabs#0",
                 hint="Vocal and Chromatic: the key whose notes you want to hit")
        ui.label("l_scale", "Scale", 584, 58, 50, 18, parent="tabs#0")
        ui.combo("c_scale", [s[0] for s in SCALES], 640, 54, 140, 24, param="scale", parent="tabs#0",
                 hint="Vocal and Chromatic: only these notes count as in key")
        ui.button("b_auto", "Auto string", 584, 86, 196, 26, parent="tabs#0",
                  hint="Stop locking a string and find the string by ear (you can also click the locked string again)")
        ui.check("x_hold", "Hold last reading", 584, 116, 196, 22, param="hold", parent="tabs#0",
                 hint="Keep the needle where it was when the note dies away")
        ui.knob("k_ref", 584, 142, 62, 98, param="ref", label="A4", parent="tabs#0",
                hint="Concert pitch: 440 Hz. Baroque is about 415, some orchestras use 442-443")
        ui.knob("k_tol", 654, 142, 62, 98, param="tol", label="In tune", parent="tabs#0",
                hint="How many cents either side of the note count as in tune")

        ui.group("g_tone", "REFERENCE TONE", 576, 262, 212, 126, parent="tabs#0")
        ui.check("x_tone", "Play the target note", 584, 282, 196, 22, param="tone", parent="tabs#0",
                 hint="Sounds the note you are tuning to. MIDI keys can play it too.")
        ui.combo("c_wave", WAVES, 584, 308, 196, 24, param="wave", parent="tabs#0")
        ui.slider("s_tl", 584, 334, 196, 26, param="tone_level", parent="tabs#0", hint="Level of the reference tone")
        ui.check("x_mute", "Mute the instrument", 584, 362, 196, 22, param="mute", parent="tabs#0",
                 hint="Silence the audio passing through so you can tune with the tone alone")

        ui.group("g_det", "DETECTION", 8, 8, 300, 150, parent="tabs#1")
        ui.knob("k_gate", 16, 32, 62, 98, param="gate_db", label="Noise gate", parent="tabs#1",
                hint="Quieter than this is ignored")
        ui.knob("k_thr", 86, 32, 62, 98, param="thresh", label="Threshold", parent="tabs#1",
                hint="Lower = stricter about what counts as a clear pitch; raise it for a noisy or weak signal")
        ui.knob("k_smo", 156, 32, 62, 98, param="smooth", label="Smoothing", parent="tabs#1",
                hint="Steadies the needle; lower is quicker but jumpier")
        ui.group("g_view", "DISPLAY", 316, 8, 300, 150, parent="tabs#1")
        ui.check("x_flat", "Show flats (Bb) instead of sharps (A#)", 324, 32, 280, 22, param="flats", parent="tabs#1")
        ui.check("x_freq", "Show the frequency", 324, 58, 280, 22, param="show_freq", parent="tabs#1")
        ui.memo("set_info", self.settings_text(), 8, 168, 780, 214, parent="tabs#1", read_only=True)

        self.ui_midi_page(ui, "tabs#2", extra_rows=2)
        ui.check("x_mrel", "Release returns to auto", 20, 146, 330, 22, param="midi_release", parent="tabs#2",
                 hint="Letting go of the MIDI keys goes back to finding the string by ear")
        ui.check("x_mtone", "Keys play the reference tone", 380, 146, 360, 22, param="midi_tone", parent="tabs#2")
        ui.check("x_mout", "Send detected note as MIDI", 20, 174, 330, 22, param="midi_out", parent="tabs#2",
                 hint="Needs a MIDI output device: a synth follows the note you play or sing")

        ui.memo("about", self.about_text(), 12, 12, 780, 390, parent="tabs#3", read_only=True)
        self.ui_presets(ui)

    def settings_text(self):
        return ("NOISE GATE  Sound quieter than this is not analysed, so the needle stays still between notes.\n"
                "THRESHOLD  How sure the detector must be before it reports a pitch.  Lower is stricter.  If a weak\n"
                "  low string is never picked up raise it; if the needle jumps to octaves, lower it.\n"
                "SMOOTHING  Averages successive readings.  High = a steady needle, low = a fast but nervous one.\n\n"
                "TIPS  Tune one string at a time and let it ring.  Tune up to the note: if you are sharp, go below the\n"
                "  note and come back up.  Bass strings are slow to settle - give them a second.  For voice, sing a\n"
                "  long steady vowel.")

    def about_text(self):
        return (
            "Tuner\nVersion %s  -  written by %s\n\n" % (self.version, self.author) +
            "Insert it on the lane or channel you want to tune and play a note.  The needle shows how far the\n"
            "note is from the target: left is flat, right is sharp, the green band is in tune.\n\n"
            "INSTRUMENT / TUNING  Guitar (standard, drops, open tunings, DADGAD, 7-string), bass (4, 5 and 6 string),\n"
            "  violin, viola, cello, ukulele.  AUTO finds the string by ear; click a string to lock it.\n"
            "LOW STRING TO  Re-keys the tuning: pick D and standard guitar becomes D standard.\n"
            "VOCAL / CHROMATIC  Key and Scale choose the notes that count; the tuner shows the nearest one.\n"
            "A4  Concert pitch, 400-480 Hz.\n"
            "REFERENCE TONE  Plays the target note (sine, triangle or organ) - tune by ear or against the needle.\n"
            "  MUTE silences the instrument so only the tone is heard.\n\n"
            "MIDI  Keys pick the string / note and sound the reference tone; program change picks the instrument;\n"
            "  controllers 7, 20, 21, 22 and 23 move tone level, A4, noise gate, in-tune window and threshold.\n"
            "  Optionally the detected note is sent out as MIDI with pitch bend.\n\n"
            "Needs numpy: pip install numpy."
        )

    # ---- audio ------------------------------------------------------------------------------------
    def prepare(self, sample_rate, channels, max_frames):
        self._sr = float(sample_rate)
        self._ok = np is not None
        if not self._ok:
            self.log("Tuner needs numpy (pip install numpy); the audio passes through and nothing is detected")
            return
        self._ring = np.zeros(int(self._sr * 0.6), dtype=np.float64)
        self._wp = 0
        self._filled = 0
        self._phase = 0.0
        self._tone_amp = 0.0

    def reset(self):
        if self._ok:
            self._ring[:] = 0.0
            self._filled = 0
        self._mf = None

    def process(self, block):
        if not self._ok:
            return
        n = block.frames
        ring = self._ring
        size = len(ring)
        mono = block.inp[0].astype(np.float64)
        for c in range(1, block.channels):
            mono = mono + block.inp[c]
        if block.channels > 1:
            mono *= 1.0 / block.channels
        if n >= size:
            ring[:] = mono[-size:]
            self._wp = 0
        else:
            e = self._wp + n
            if e <= size:
                ring[self._wp:e] = mono
            else:
                k = size - self._wp
                ring[self._wp:] = mono[:k]
                ring[:n - k] = mono[k:]
            self._wp = e % size
        self._filled = min(size, self._filled + n)

        p = self.p
        if p.mute:
            for c in range(block.channels):
                block.out[c][:] = 0.0
        target = up.db_to_lin(p.tone_level) if self._tone_on else 0.0
        if target == 0.0 and self._tone_amp < 1e-5:
            self._tone_amp = 0.0
            return
        w = 2.0 * math.pi * self._tone_hz / self._sr
        ph = self._phase + w * np.arange(n)
        self._phase = float((ph[-1] + w) % (2.0 * math.pi))
        kind = int(p.wave)
        if kind == 1:
            wave = (2.0 / math.pi) * np.arcsin(np.sin(ph))
        elif kind == 2:
            wave = 0.6 * np.sin(ph) + 0.25 * np.sin(2.0 * ph) + 0.15 * np.sin(3.0 * ph)
        else:
            wave = np.sin(ph)
        amp = np.linspace(self._tone_amp, target, n, endpoint=False)
        self._tone_amp = float(target)
        tone = (wave * amp).astype(np.float32)
        for c in range(block.channels):
            block.out[c][:] = block.out[c] + tone

    # ---- pitch detection (control thread) ------------------------------------------------------------
    def _range_hz(self):
        notes = self._notes()
        if notes:
            lo, hi = min(notes) - 4, max(notes) + 14
        else:
            lo, hi = 33, 88
        return max(20.0, self._hz(lo)), min(2000.0, self._hz(hi))

    def _analyse(self):
        """Returns (frequency, confidence, level dB) or None when there is nothing clear to measure."""
        sr = self._sr
        d = max(1, int(round(sr / 12000.0)))
        sr_d = sr / d
        fmin, fmax = self._range_hz()
        tmax = int(sr_d / fmin) + 1
        w = max(512, 2 * tmax)
        need = (w + tmax) * d
        if self._filled < need:
            return None
        ring = self._ring
        size = len(ring)
        wp = self._wp
        idx = (wp - need + np.arange(need)) % size
        seg = ring[idx]
        seg = seg - seg.mean()
        rms = float(np.sqrt(np.mean(seg * seg)))
        level = 20.0 * math.log10(max(rms, 1e-9))
        if level < float(self.p.gate_db):
            return None
        x = seg.reshape(-1, d).mean(axis=1) if d > 1 else seg
        res = yin(x, sr_d, fmin, fmax, float(self.p.thresh))
        if res is None:
            return None
        return res[0], res[1], level

    def _pick_target(self, mf):
        """The MIDI note the pitch ``mf`` is being judged against."""
        notes = self._notes()
        if notes:
            if 0 <= self._sel < len(notes):
                return notes[self._sel]
            return min(notes, key=lambda n: abs(mf - n))
        if self._lock is not None:
            return self._lock
        pcs = self._scale_pcs()
        c = int(round(mf))
        cands = [n for n in range(c - 7, c + 8) if n % 12 in pcs]
        return min(cands, key=lambda n: abs(mf - n)) if cands else c

    def on_timer(self):
        if not self._ok:
            return
        p = self.p
        if self._ui_dirty:
            self._ui_dirty = False
            self._refresh_ui()
        self._clock += 1
        res = self._analyse()
        if res is not None:
            f, conf, level = res
            mf = 69.0 + 12.0 * math.log2(f / float(p.ref))
            alpha = max(0.08, 1.0 - float(p.smooth) / 100.0 * 0.92)
            if self._mf is None or abs(mf - self._mf) > 0.6:
                self._mf = mf
            else:
                self._mf += alpha * (mf - self._mf)
            self._silent = 0
            tgt = self._pick_target(self._mf)
            self._target = tgt
            cents = (self._mf - tgt) * 100.0
            self._reading = {"f": self._hz(self._mf), "mf": self._mf, "target": tgt, "cents": cents,
                             "conf": conf, "level": level, "live": True}
            self._hist.append(max(-60.0, min(60.0, cents)))
            if abs(cents) <= float(p.tol):
                if self._intune_since is None:
                    self._intune_since = self._clock
            else:
                self._intune_since = None
        else:
            self._silent += 1
            self._intune_since = None
            if self._reading is not None:
                if p.hold:
                    self._reading["live"] = False
                elif self._silent > 8:
                    self._reading = None
                    self._mf = None
                else:
                    self._reading["live"] = False
            self._hist.append(None)
        self._view = self._reading
        self._update_tone()
        self._update_midi_out()

    def _update_tone(self):
        p = self.p
        notes = self._notes()
        if notes:
            if 0 <= self._sel < len(notes):
                t = notes[self._sel]
            elif self._target is not None:
                t = self._target
            else:
                t = notes[0]
        elif self._lock is not None:
            t = self._lock
        elif self._target is not None:
            t = self._target
        else:
            t = 60 + int(p.key)
        self._tone_hz = self._hz(t)
        self._tone_on = bool(p.tone) or bool(p.midi_tone and self._held)

    def _update_midi_out(self):
        p = self.p
        ch = max(int(p.midi_ch) - 1, 0)
        want = None
        if p.midi_out and self._reading is not None and self._reading.get("live"):
            want = int(round(self._reading["mf"]))
        if want != self._out_note:
            if want is not None and self._out_cand != want:
                self._out_cand = want            # needs to be seen twice in a row
                return
            if self._out_note is not None:
                self.note_off(self._out_note, ch)
            if want is not None:
                self.note_on(want, 100, ch)
            self._out_note = want
        self._out_cand = None
        if want is not None:
            bend = int(round((self._reading["mf"] - want) * 4096.0))
            self.send_midi("pitch_bend", ch, bend, 0)

    # ---- user interface events ----------------------------------------------------------------------
    def _refresh_ui(self):
        tun = self._tunings()
        strings = bool(tun)
        if strings:
            self.ui_set("c_tuning", items=[t[0] for t in tun], value=min(int(self.p.tuning), len(tun) - 1),
                        enabled=True)
        else:
            self.ui_set("c_tuning", items=["(not used)"], value=0, enabled=False)
        self.ui_set("c_tk", enabled=strings)
        self.ui_set("c_key", enabled=not strings)
        self.ui_set("c_scale", enabled=not strings)
        self.ui_set("b_auto", enabled=strings)

    def on_param(self, pid, value):
        if pid == "inst" and not self._loading:
            self._sel = -1
            self._lock = None
            self._mf = None
            if int(self.p.tuning) != 0:
                self.set_param("tuning", 0)
            self._ui_dirty = True
        elif pid in ("tuning", "tune_key"):
            self._sel = -1
            self._ui_dirty = True

    def on_b_auto(self, event, data):
        if event == "click":
            self._sel = -1
            self._lock = None

    def on_mouse(self, cid, kind, x, y, button):
        if cid != "strings" or kind != "down":
            return
        notes = self._notes()
        if not notes:
            return
        for i, (x0, x1) in enumerate(self._hit):
            if x0 <= x < x1:
                self._sel = -1 if self._sel == i else i
                return

    # ---- painting ---------------------------------------------------------------------------------
    def _state_colour(self, cents):
        a = abs(cents)
        if a <= float(self.p.tol):
            return COL_OK
        return COL_NEAR if a <= 20 else COL_FAR

    def paint_gauge(self, c):
        W, H = c.width, c.height
        c.clear(COL_BG)
        cx, cy, R = W // 2, H - 34, 170
        tol = float(self.p.tol)
        span = 70.0
        c.arc(cx, cy, R, 270 - span - 4, 270 + span + 4, COL_DIM, 2)
        c.arc(cx, cy, R - 4, 270 - tol / 50.0 * span, 270 + tol / 50.0 * span, COL_OK, 7)
        for k in range(-50, 51, 10):
            a = math.radians(270 + k / 50.0 * span)
            major = k % 50 == 0
            r1 = R - (20 if major else 12)
            c.line(cx + R * math.cos(a), cy + R * math.sin(a), cx + r1 * math.cos(a), cy + r1 * math.sin(a),
                   COL_TXT if major else COL_DIM, 2 if major else 1)
        c.text(cx - R - 6, cy - 30, "FLAT", COL_SUB, 11, True, "left")
        c.text(cx + R - 44, cy - 30, "SHARP", COL_SUB, 11, True, "right", 50)
        c.text(0, cy - R - 2, "0", COL_SUB, 10, False, "center", W)
        v = self._view
        if v is None:
            c.text(0, 78, "--", COL_DIM, 56, True, "center", W)
            c.text(0, 152, "Play or sing a note", COL_SUB, 14, False, "center", W)
            c.line(cx, cy, cx, cy - (R - 6), COL_DIM, 3)
            c.circle(cx, cy, 8, COL_DIM)
        else:
            cents = v["cents"]
            col = self._state_colour(cents) if v["live"] else COL_DIM
            c.text(0, 70, self._name(v["target"]), col, 60, True, "center", W)
            if self._intune_since is not None and v["live"]:
                c.text(0, 138, "IN TUNE", COL_OK, 14, True, "center", W)
            else:
                c.text(0, 138, "tune " + ("UP" if cents < 0 else "DOWN"), COL_SUB, 14, True, "center", W)
            c.text(0, 160, "%+.1f cents" % cents, col, 20, True, "center", W)
            shown = max(-50.0, min(50.0, cents))
            a = math.radians(270 + shown / 50.0 * span)
            c.line(cx, cy, cx + (R - 6) * math.cos(a), cy + (R - 6) * math.sin(a), col, 3)
            c.circle(cx, cy, 8, col)
            if self.p.show_freq:
                c.text(12, H - 24, "%.2f Hz" % v["f"], COL_TXT, 13, False, "left")
                c.text(0, H - 24, "target %s  %.2f Hz" % (self._name(v["target"]), self._hz(v["target"])),
                       COL_SUB, 13, False, "center", W)
        c.text(W - 142, H - 24, "A4 = %.1f Hz" % float(self.p.ref), COL_SUB, 13, False, "right", 130)

    def paint_strings(self, c):
        W, H = c.width, c.height
        c.clear(COL_BG)
        v = self._view
        notes = self._notes()
        self._hit = []
        if notes:
            n = len(notes)
            gap = 6
            bw = min(86, (W - 16 - gap * (n - 1)) // n)
            x = (W - (bw * n + gap * (n - 1))) // 2
            for i, note in enumerate(notes):
                is_t = v is not None and v["target"] == note
                if is_t and v["live"]:
                    col = self._state_colour(v["cents"])
                    c.round_rect(x, 6, bw, H - 12, 8, col, None)
                    txt = "#10131a"
                else:
                    c.round_rect(x, 6, bw, H - 12, 8, "#1c212a", COL_BLUE if i == self._sel else COL_DIM, 2)
                    txt = COL_TXT
                c.text(x, 14, self._name(note), txt, 20, True, "center", bw)
                c.text(x, 42, "string %d%s" % (i + 1, "  (locked)" if i == self._sel else ""), txt, 10, False,
                       "center", bw)
                self._hit.append((x, x + bw + gap))
                x += bw + gap
        else:
            pcs = sorted(self._scale_pcs(), key=lambda q: (q - int(self.p.key)) % 12)
            names = KEY_FLAT if self.p.flats else KEY_SHARP
            n = len(pcs)
            gap = 6
            bw = min(70, (W - 16 - gap * (n - 1)) // n)
            x = (W - (bw * n + gap * (n - 1))) // 2
            tpc = v["target"] % 12 if v is not None else -1
            for q in pcs:
                if q == tpc and v["live"]:
                    c.round_rect(x, 6, bw, H - 12, 8, self._state_colour(v["cents"]), None)
                    txt = "#10131a"
                else:
                    c.round_rect(x, 6, bw, H - 12, 8, "#1c212a", COL_BLUE if q == int(self.p.key) else COL_DIM, 1)
                    txt = COL_TXT
                c.text(x, 20, names[q], txt, 20, True, "center", bw)
                x += bw + gap
            if self._lock is not None:
                c.text(8, H - 16, "locked to %s (MIDI)" % self._name(self._lock), COL_BLUE, 10, False, "left")

    def paint_hist(self, c):
        W, H = c.width, c.height
        c.clear(COL_BG)
        tol = float(self.p.tol)
        mid = H / 2.0
        scale = (H / 2.0 - 3) / 60.0
        c.fill_rect(0, int(mid - tol * scale), W, max(1, int(2 * tol * scale)), "#16301f")
        c.line(0, mid, W, mid, COL_DIM, 1, True)
        pts = []
        n = self._hist.maxlen
        for i, v in enumerate(self._hist):
            if v is None:
                if len(pts) > 1:
                    c.polyline(pts, COL_BLUE, 2)
                pts = []
                continue
            pts.append((W * i / (n - 1), mid - v * scale))
        if len(pts) > 1:
            c.polyline(pts, COL_BLUE, 2)
        c.text(6, 2, "flat / sharp history", COL_SUB, 9)

    # ---- MIDI in ------------------------------------------------------------------------------------
    def on_midi(self, kind, channel, data1, data2):
        if not self._ok:
            return
        p = self.p
        if kind == "note_on" and data2 == 0:
            kind = "note_off"
        if kind == "note_on":
            self._held.add(data1)
            notes = self._notes()
            if notes:
                self._sel = min(range(len(notes)), key=lambda i: abs(notes[i] - data1))
            else:
                self._lock = data1
        elif kind == "note_off":
            self._held.discard(data1)
            if not self._held and p.midi_release:
                self._sel = -1
                self._lock = None
        elif kind == "program":
            if 0 <= data1 < len(INSTRUMENTS):
                self.set_param("inst", data1)
        elif kind == "cc" and data1 == 123:
            self._held.clear()
            if p.midi_release:
                self._sel = -1
                self._lock = None

    # ---- presets and state -----------------------------------------------------------------------------
    preset_skip = ("tone", "mute")

    def builtin_presets(self):
        return list(PRESET_ORDER)

    def load_builtin(self, index):
        if not 0 <= index < len(PRESETS):
            return
        inst, tun = PRESETS[index]
        self.preset_begin()
        try:
            self.set_param("inst", INSTRUMENTS.index(inst))
            self.set_param("tuning", tun)
        finally:
            self.preset_end()
        self._sel = -1

    def preset_begin(self):
        self._loading = True

    def preset_end(self):
        self._loading = False
        self._sel = -1
        self._ui_dirty = True

    def get_state(self):
        return {"sel": self._sel}

    def set_state(self, state):
        if isinstance(state, dict):
            sel = int(state.get("sel", -1))
            notes = self._notes()
            self._sel = sel if notes and 0 <= sel < len(notes) else -1
        self._ui_dirty = True
