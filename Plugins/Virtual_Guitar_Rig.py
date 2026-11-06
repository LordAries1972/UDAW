"""Virtual Guitar Rig  -  amplifier, cabinet, transpose and doubler for UDAW.

Written by Daniel J. Hobson, Australia.

What it does
------------
It takes a recorded (DI) guitar and plays it through a simulated rig, so the amp, speaker cabinet and
microphone can be chosen and changed after the performance has been recorded:

  * NOISE GATE   - closes between notes so a high-gain tone stays quiet when you stop playing.
  * TRANSPOSE    - shifts the pitch up or down (+-12 semitones, with a fine control in cents) before the amp,
                   for drop tunings, octave shimmer or a harmony blended in underneath.
  * AMP          - four voicings (Clean, Crunch, Lead, High Gain) with tight / gain / bass / mid / treble /
                   presence controls, a "sag" control (power-supply give: loud notes squash the next ones)
                   and an optional 2x oversampling of the distortion stages to keep it smooth.
  * CABINET      - four speaker cabinets, four microphones, a mic position from centre to edge of the cone,
                   and a room amount that adds the first reflections of a small studio.
  * DOUBLER      - two slightly detuned, slightly delayed copies spread left and right: the "played it twice"
                   width of a double-tracked rhythm guitar from one performance.

Try it for: a clean DI take developed into a heavy rhythm tone or an atmospheric lead, then add it to any
strip of the Mixer (a lane, a bus or the Master) with Add to Mixer.  It processes your playing; you supply
the performance.

How it is written
-----------------
Everything is plain signal processing, not a capture of any particular real amplifier.  The tone shaping and
the cabinet are minimum-phase filters designed from magnitude curves and run by fast convolution, so changing a
knob re-designs the filter without per-sample work; the distortion stages are vectorised waveshapers; the
pitch shifter is a two-tap cross-faded delay line; the doubler is two modulated delay lines.  All of it is
vectorised with numpy, one chunk at a time, so it fits comfortably in the real-time budget.  Without numpy the
plug-in passes the audio through and says so in its log.
"""

import math

import udaw_plugin as up

try:
    import numpy as np
except Exception:                                   # numpy missing: the plug-in explains itself
    np = None

CH = 2048                                           # largest chunk handled in one go (bounds every delay line)

AMPS = ["Clean", "Crunch", "Lead", "High Gain"]
CABS = ["1x12 Open Back", "2x12 Combo", "4x12 British", "4x12 Modern"]
MICS = ["Dynamic On-Axis", "Dynamic Off-Axis", "Condenser", "Ribbon"]


# ---- distortion stages (input is already scaled by the drive gain) -------------------------------

def _st_tanh(v):
    return np.tanh(v)


def _st_bias(v):
    # a little bias gives the even harmonics of a pushed tube stage; tanh(0.2) re-centres it
    return np.tanh(v + 0.2) - 0.19738


def _st_asym(v):
    # exponential soft clip with a different knee for each half-wave (class-A feel)
    pos = 1.0 - np.exp(-np.maximum(v, 0.0))
    neg = -0.85 * (1.0 - np.exp(1.15 * np.minimum(v, 0.0)))
    return np.where(v >= 0.0, pos, neg)


def _st_hard(v):
    # a stiff knee: v / (1 + |v|^3)^(1/3)
    return v / np.cbrt(1.0 + np.abs(v) ** 3)


#: per amp: gain range in dB, the cascade of stages, gain between stages, output trim, tone-stack centres
AMP_SPECS = [
    dict(lo=-6.0, hi=20.0, stages=(_st_tanh,), sg=1.0, trim=-1.0, bass=140.0, mid=500.0, hump=0.0, hump_fc=800.0),
    dict(lo=0.0, hi=34.0, stages=(_st_bias, _st_tanh), sg=2.0, trim=-8.0, bass=120.0, mid=650.0, hump=3.0,
         hump_fc=750.0),
    dict(lo=8.0, hi=44.0, stages=(_st_asym, _st_tanh, _st_tanh), sg=2.5, trim=-11.0, bass=110.0, mid=800.0,
         hump=5.0, hump_fc=850.0),
    dict(lo=14.0, hi=54.0, stages=(_st_bias, _st_hard, _st_tanh, _st_tanh), sg=3.0, trim=-13.0, bass=100.0,
         mid=700.0, hump=6.0, hump_fc=900.0),
]

#: per cabinet: high-pass Hz, (resonance Hz, dB, width in octaves), [(Hz, dB, width) bumps], low-pass Hz
CAB_SPECS = [
    dict(hp=95.0, res=(120.0, 3.0, 0.8), bumps=[(2400.0, 3.0, 0.7), (900.0, -1.5, 0.8)], lp=5600.0),
    dict(hp=85.0, res=(105.0, 3.5, 0.8), bumps=[(1800.0, 3.5, 0.7), (3500.0, 1.0, 0.6)], lp=5900.0),
    dict(hp=78.0, res=(98.0, 5.0, 0.8), bumps=[(2300.0, 4.0, 0.6), (1100.0, 1.5, 0.8), (4600.0, -2.5, 0.3)],
         lp=5200.0),
    dict(hp=70.0, res=(85.0, 4.5, 0.8), bumps=[(3200.0, 4.0, 0.6), (1300.0, -2.5, 0.7)], lp=6400.0),
]

PRESETS = {
    "Clean Sparkle": dict(gate_on=False, amp_type=0, gain=3.0, bass=5.0, mid=4.5, treble=6.5, presence=6.0,
                          bright=True, sag=10, cab_type=1, mic=2, mic_pos=20, room=25,
                          d_on=True, d_time=18, d_detune=8, d_width=100, d_mix=25),
    "Edge of Breakup": dict(amp_type=1, gain=4.0, bass=5.0, mid=6.0, treble=5.5, presence=5.0, sag=40,
                            cab_type=0, mic=0, mic_pos=30, room=20, gate_on=False),
    "Classic Rock Crunch": dict(amp_type=1, gain=6.5, bass=5.0, mid=6.0, treble=6.0, presence=5.5, tight=2.0,
                                sag=30, cab_type=2, mic=0, mic_pos=25, room=15, gate_on=False),
    "Heavy Rhythm": dict(amp_type=3, gain=7.0, bass=6.0, mid=4.5, treble=5.5, presence=5.5, tight=6.5, sag=10,
                         gate_on=True, gate_thr=-55, cab_type=3, mic=0, mic_pos=20, room=8,
                         d_on=True, d_time=20, d_detune=10, d_width=100, d_mix=45),
    "Atmospheric Lead": dict(amp_type=2, gain=6.0, bass=4.0, mid=6.5, treble=5.0, presence=4.0, tight=3.0,
                             sag=35, gate_on=False, cab_type=1, mic=3, mic_pos=35, room=45,
                             tr_on=True, tr_semi=12, tr_mix=18,
                             d_on=True, d_time=28, d_detune=14, d_width=100, d_mix=55),
    "Tight Djent": dict(amp_type=3, gain=8.5, bass=5.0, mid=3.0, treble=6.0, presence=6.0, tight=9.0, sag=0,
                        gate_on=True, gate_thr=-50, gate_rel=60, cab_type=3, mic=0, mic_pos=15, room=5),
    "Drop-Tune Sludge": dict(amp_type=3, gain=6.0, bass=7.0, mid=5.0, treble=4.5, presence=4.0, tight=3.0,
                             sag=50, gate_on=True, gate_thr=-58, cab_type=2, mic=0, mic_pos=30, room=10,
                             tr_on=True, tr_semi=-5, tr_mix=100),
}
PRESET_ORDER = list(PRESETS)


# ---- magnitude building blocks (frequency in Hz, arrays over the FFT bins) ------------------------

def _hp(f, fc, n=2):
    return 1.0 / np.sqrt(1.0 + (fc / f) ** (2 * n))


def _lp(f, fc, n=2):
    return 1.0 / np.sqrt(1.0 + (f / fc) ** (2 * n))


def _bell_db(f, fc, db, bw_oct):
    return db * np.exp(-0.5 * (np.log2(f / fc) / bw_oct) ** 2)


def _lowshelf_db(f, fc, db):
    return db / (1.0 + (f / fc) ** 2)


def _highshelf_db(f, fc, db):
    return db * (f * f) / (f * f + fc * fc)


def _min_phase(mag, taps):
    """Minimum-phase impulse response (``taps`` long) with the magnitude ``mag`` (rfft bins)."""
    nfft = (len(mag) - 1) * 2
    cep = np.fft.irfft(np.log(np.maximum(mag, 1e-5)), nfft)
    fold = np.zeros(nfft)
    fold[0] = cep[0]
    fold[1:nfft // 2] = 2.0 * cep[1:nfft // 2]
    fold[nfft // 2] = cep[nfft // 2]
    h = np.fft.ifft(np.exp(np.fft.fft(fold))).real[:taps].copy()
    k = taps // 4
    h[-k:] *= np.hanning(2 * k)[k:]
    return h


class StreamFIR:
    """Fast convolution of a stream with an impulse response, block after block (overlap-add)."""

    def __init__(self, ir):
        self.tail = np.zeros(0)
        self._H = {}
        self.ir = np.zeros(1)
        self.set_ir(ir)

    def set_ir(self, ir):
        self.ir = np.asarray(ir, dtype=np.float64)
        self._H = {}
        keep = len(self.ir) - 1
        if len(self.tail) < keep:
            self.tail = np.concatenate((self.tail, np.zeros(keep - len(self.tail))))
        else:
            self.tail = self.tail[:keep].copy()

    def clear(self):
        self.tail[:] = 0.0

    def apply(self, x):
        n = len(x)
        length = len(self.ir)
        size = 1 << (n + length - 2).bit_length()
        spec = self._H.get(size)
        if spec is None:
            spec = np.fft.rfft(self.ir, size)
            self._H[size] = spec
        y = np.fft.irfft(np.fft.rfft(x, size) * spec, size)
        y[:len(self.tail)] += self.tail
        self.tail = y[n:n + length - 1].copy()
        return y[:n]


class Shifter:
    """Pitch shifter: two read taps sweep through a delay line and are cross-faded, so the pitch moves
    without changing the duration."""

    def __init__(self, sr):
        self.size = 1 << (int(0.13 * sr) + CH + 16).bit_length()
        self.buf = np.zeros(self.size)
        self.wp = 0
        self.ph = 0.0
        self.win = int(0.05 * sr)

    def clear(self):
        self.buf[:] = 0.0
        self.ph = 0.0

    def apply(self, x, ratio, win):
        n = len(x)
        self.win = win
        size = self.size
        t = np.arange(n)
        self.buf[(self.wp + t) % size] = x
        inc = (1.0 - ratio) / self.win
        ph = (self.ph + inc * t) % 1.0
        out = np.zeros(n)
        for p in (ph, (ph + 0.5) % 1.0):
            pos = (self.wp + t) - (2.0 + p * self.win)
            i0 = np.floor(pos).astype(np.int64)
            fr = pos - i0
            a = self.buf[i0 % size]
            b = self.buf[(i0 + 1) % size]
            out += np.sin(math.pi * p) ** 2 * (a + (b - a) * fr)
        self.ph = (self.ph + inc * n) % 1.0
        self.wp = (self.wp + n) % size
        return out


def _ramp(g0, g1, n, sr, ms):
    """Gain ramp from g0 to g1 over ``ms`` milliseconds, then held."""
    r = np.full(n, g1)
    m = min(n, max(1, int(ms * 0.001 * sr)))
    r[:m] = np.linspace(g0, g1, m, endpoint=False)
    return r


class Plugin(up.Plugin):
    midi_cc = {1: "gain", 7: "out_level", 11: "mix", 71: "presence", 74: "treble"}
    midi_notes = ("Keys set Transpose (middle C = no shift) and switch it on; pitch bend sets Fine.",
                  "Program change 0-6 loads the presets in list order.")
    name = "Virtual Guitar Rig"
    vendor = "UDAW examples"
    author = "Daniel J. Hobson, Australia"
    version = "1.0"
    description = ("A virtual guitar rig: four amp voicings, four cabinets and microphones, transpose, "
                   "a noise gate and a doubler for width.")
    use_numpy = True

    # ---- parameters -------------------------------------------------------------------------------
    def setup(self):
        self.add_param("in_gain", "Input", min=-24, max=24, default=0, unit="dB", decimals=1, group="Input")
        self.add_bool("gate_on", "Gate", default=True, group="Input")
        self.add_param("gate_thr", "Gate threshold", min=-90, max=-20, default=-62, unit="dB", decimals=0,
                       group="Input")
        self.add_param("gate_rel", "Gate release", min=10, max=500, default=90, unit="ms", log=True, decimals=0,
                       group="Input")
        self.add_param("gate_hold", "Gate hold", min=0, max=500, default=60, unit="ms", decimals=0, group="Input")
        self.add_param("gate_depth", "Gate depth", min=-90, max=-6, default=-70, unit="dB", decimals=0,
                       group="Input")

        self.add_bool("tr_on", "Transpose", default=False, group="Transpose")
        self.add_param("tr_semi", "Semitones", min=-24, max=24, default=0, kind="int", group="Transpose")
        self.add_param("tr_fine", "Fine", min=-99, max=99, default=0, unit="cents", decimals=0, group="Transpose")
        self.add_param("tr_mix", "Transpose mix", min=0, max=100, default=100, unit="%", decimals=0,
                       group="Transpose")

        self.add_param("tr_win", "Smoothness", min=20, max=120, default=50, unit="ms", decimals=0, group="Transpose")

        self.add_bool("amp_on", "Amp", default=True, group="Amp")
        self.add_choice("amp_type", "Amp type", AMPS, default=1, group="Amp")
        self.add_param("gain", "Gain", min=0, max=10, default=5, decimals=1, group="Amp")
        self.add_param("bass", "Bass", min=0, max=10, default=5, decimals=1, group="Amp")
        self.add_param("mid", "Mid", min=0, max=10, default=5, decimals=1, group="Amp")
        self.add_param("treble", "Treble", min=0, max=10, default=5, decimals=1, group="Amp")
        self.add_param("presence", "Presence", min=0, max=10, default=5, decimals=1, group="Amp")
        self.add_param("master", "Master", min=-24, max=12, default=0, unit="dB", decimals=1, group="Amp")
        self.add_param("tight", "Tight", min=0, max=10, default=3, decimals=1, group="Amp")
        self.add_param("sag", "Sag", min=0, max=100, default=20, unit="%", decimals=0, group="Amp")
        self.add_param("depth", "Depth", min=-6, max=9, default=0, unit="dB", decimals=1, group="Amp")
        self.add_param("mid_shift", "Mid focus", min=-1, max=1, default=0, unit="oct", decimals=2, group="Amp")
        self.add_param("fizz", "Fizz filter", min=2000, max=12000, default=7000, unit="Hz", log=True, decimals=0,
                       group="Amp")
        self.add_bool("bright", "Bright", default=False, group="Amp")
        self.add_bool("os", "Oversample", default=True, group="Amp")

        self.add_bool("cab_on", "Cabinet", default=True, group="Cabinet")
        self.add_choice("cab_type", "Cabinet", CABS, default=2, group="Cabinet")
        self.add_choice("mic", "Microphone", MICS, default=0, group="Cabinet")
        self.add_param("mic_pos", "Mic position", min=0, max=100, default=25, unit="%", decimals=0,
                       group="Cabinet")
        self.add_param("room", "Room", min=0, max=100, default=15, unit="%", decimals=0, group="Cabinet")
        self.add_param("mic_dist", "Mic distance", min=0, max=100, default=10, unit="%", decimals=0, group="Cabinet")
        self.add_param("cab_lo", "Cab low cut", min=20, max=300, default=20, unit="Hz", log=True, decimals=0,
                       group="Cabinet")
        self.add_param("cab_hi", "Cab high cut", min=2000, max=16000, default=16000, unit="Hz", log=True,
                       decimals=0, group="Cabinet")
        self.add_param("cab_level", "Cab level", min=-12, max=12, default=0, unit="dB", decimals=1, group="Cabinet")

        self.add_bool("d_on", "Doubler", default=False, group="Doubler")
        self.add_param("d_time", "Time", min=5, max=60, default=22, unit="ms", decimals=1, group="Doubler")
        self.add_param("d_detune", "Detune", min=0, max=50, default=12, unit="cents", decimals=0, group="Doubler")
        self.add_param("d_rate", "Rate", min=0.1, max=2.0, default=0.31, unit="Hz", log=True, decimals=2,
                       group="Doubler")
        self.add_param("d_spread", "Spread", min=1.0, max=2.0, default=1.37, decimals=2, group="Doubler")
        self.add_param("d_width", "Width", min=0, max=100, default=100, unit="%", decimals=0, group="Doubler")
        self.add_param("d_mix", "Doubler mix", min=0, max=100, default=50, unit="%", decimals=0, group="Doubler")

        self.add_param("out_level", "Level", min=-36, max=12, default=0, unit="dB", decimals=1, group="Output")
        self.add_param("mix", "Mix", min=0, max=100, default=100, unit="%", decimals=0, group="Output")
        self.add_param("out_width", "Stereo width", min=0, max=200, default=100, unit="%", decimals=0,
                       group="Output")
        self.add_midi_params(control="midi_on", control_default=False)
        self._preset = 0
        self._ok = False
        self._pre_dirty = True
        self._post_dirty = True

    # ---- window -----------------------------------------------------------------------------------
    def ui(self, ui):
        ui.window(940, 560, "Virtual Guitar Rig", color="#16181d")
        ui.label("title", "VIRTUAL GUITAR RIG", 16, 10, 300, 22, font_size=15, bold=True)
        ui.label("sub", "amp  -  cabinet  -  transpose  -  doubler", 16, 32, 360, 16, font_color="#8a93a3")

        ui.tabs("tabs", ["Rig", "Detail", "MIDI", "About"], 8, 56, 924, 496)

        ui.group("g_amp", "AMP", 8, 8, 576, 192, parent="tabs#0")
        ui.check("x_amp", "Amp on", 18, 28, 86, 22, param="amp_on", parent="tabs#0")
        ui.combo("c_amp", AMPS, 110, 26, 150, 26, param="amp_type", parent="tabs#0")
        ui.check("x_bright", "Bright", 274, 28, 80, 22, param="bright", parent="tabs#0",
                 hint="Adds treble sparkle at low gain")
        ui.check("x_os", "Oversample 2x", 366, 28, 130, 22, param="os", parent="tabs#0",
                 hint="Runs the distortion at twice the sample rate for a smoother top end")
        knobs = [("gain", "Gain", "How hard the preamp is driven"),
                 ("bass", "Bass", None), ("mid", "Mid", None), ("treble", "Treble", None),
                 ("presence", "Presence", "Top-end bite after the distortion"),
                 ("master", "Master", "Amp output level"),
                 ("tight", "Tight", "Cuts low end before the distortion: tighter, clearer riffs"),
                 ("sag", "Sag", "Power-supply give: loud notes squash what follows")]
        for i, (pid, label, hint) in enumerate(knobs):
            kw = {"hint": hint} if hint else {}
            ui.knob("k_" + pid, 14 + i * 70, 62, 66, 98, param=pid, label=label, parent="tabs#0", **kw)

        ui.group("g_cab", "CABINET", 592, 8, 316, 192, parent="tabs#0")
        ui.check("x_cab", "Cabinet on", 602, 28, 110, 22, param="cab_on", parent="tabs#0")
        ui.combo("c_cab", CABS, 718, 26, 178, 26, param="cab_type", parent="tabs#0")
        ui.combo("c_mic", MICS, 602, 58, 294, 26, param="mic", parent="tabs#0")
        ui.knob("k_micpos", 608, 92, 66, 98, param="mic_pos", label="Position", parent="tabs#0",
                hint="From the centre of the speaker cone (bright, direct) to its edge (darker)")
        ui.knob("k_room", 684, 92, 66, 98, param="room", label="Room", parent="tabs#0",
                hint="Early reflections of a small studio around the cabinet")

        ui.group("g_in", "INPUT", 8, 208, 214, 164, parent="tabs#0")
        ui.check("x_gate", "Noise gate", 18, 228, 120, 22, param="gate_on", parent="tabs#0")
        ui.knob("k_in", 16, 254, 62, 98, param="in_gain", label="Input", parent="tabs#0")
        ui.knob("k_thr", 82, 254, 62, 98, param="gate_thr", label="Threshold", parent="tabs#0",
                hint="The level below which the gate closes")
        ui.knob("k_rel", 148, 254, 62, 98, param="gate_rel", label="Release", parent="tabs#0")

        ui.group("g_tr", "TRANSPOSE", 230, 208, 210, 164, parent="tabs#0")
        ui.check("x_tr", "Transpose on", 240, 228, 130, 22, param="tr_on", parent="tabs#0")
        ui.knob("k_semi", 238, 254, 62, 98, param="tr_semi", label="Semitones", parent="tabs#0")
        ui.knob("k_fine", 304, 254, 62, 98, param="tr_fine", label="Fine", parent="tabs#0")
        ui.knob("k_trmix", 370, 254, 62, 98, param="tr_mix", label="Mix", parent="tabs#0",
                hint="100% replaces the note, less blends the shifted copy under the original")

        ui.group("g_dbl", "DOUBLER", 448, 208, 290, 164, parent="tabs#0")
        ui.check("x_dbl", "Doubler on", 458, 228, 120, 22, param="d_on", parent="tabs#0")
        ui.knob("k_dtime", 456, 254, 62, 98, param="d_time", label="Time", parent="tabs#0",
                hint="Delay of the copies behind the original")
        ui.knob("k_ddet", 524, 254, 62, 98, param="d_detune", label="Detune", parent="tabs#0",
                hint="How far the copies drift out of tune")
        ui.knob("k_dwid", 592, 254, 62, 98, param="d_width", label="Width", parent="tabs#0")
        ui.knob("k_dmix", 660, 254, 62, 98, param="d_mix", label="Mix", parent="tabs#0")

        ui.group("g_out", "OUTPUT", 746, 208, 162, 164, parent="tabs#0")
        ui.knob("k_lvl", 754, 232, 62, 98, param="out_level", label="Level", parent="tabs#0")
        ui.knob("k_mix", 826, 232, 62, 98, param="mix", label="Mix", parent="tabs#0",
                hint="Blend of the original (dry) and the rig")

        ui.canvas("xfer", 8, 380, 300, 76, parent="tabs#0", fps=12, mouse=False)
        ui.canvas("resp", 316, 380, 300, 76, parent="tabs#0", fps=8, mouse=False)
        ui.label("l_in", "IN", 628, 384, 24, 16, parent="tabs#0", font_color="#8a93a3")
        ui.meter("m_in", 654, 386, 252, 12, vertical=False, parent="tabs#0", hint="Input level")
        ui.label("l_out", "OUT", 628, 410, 28, 16, parent="tabs#0", font_color="#8a93a3")
        ui.meter("m_out", 654, 412, 252, 12, vertical=False, parent="tabs#0", hint="Output level")

        ui.group("g_din", "INPUT", 8, 8, 158, 140, parent="tabs#1")
        ui.knob("k_ghold", 16, 30, 62, 98, param="gate_hold", label="Hold", parent="tabs#1",
                hint="How long the gate stays open after the signal drops below the threshold")
        ui.knob("k_gdep", 86, 30, 62, 98, param="gate_depth", label="Depth", parent="tabs#1",
                hint="How far the gate turns the signal down when closed")
        ui.group("g_dtr", "TRANSPOSE", 174, 8, 92, 140, parent="tabs#1")
        ui.knob("k_twin", 182, 30, 62, 98, param="tr_win", label="Smoothness", parent="tabs#1",
                hint="Longer is smoother on sustained notes, shorter is tighter on fast playing")
        ui.group("g_damp", "AMP", 274, 8, 222, 140, parent="tabs#1")
        ui.knob("k_depth", 282, 30, 62, 98, param="depth", label="Depth", parent="tabs#1",
                hint="Low-end thump of the power stage")
        ui.knob("k_mfoc", 352, 30, 62, 98, param="mid_shift", label="Mid focus", parent="tabs#1",
                hint="Moves the centre of the Mid control down or up")
        ui.knob("k_fizz", 422, 30, 62, 98, param="fizz", label="Fizz filter", parent="tabs#1",
                hint="Rolls off harsh top end before the distortion")
        ui.group("g_dcab", "CABINET", 504, 8, 292, 140, parent="tabs#1")
        ui.knob("k_mdist", 512, 30, 62, 98, param="mic_dist", label="Distance", parent="tabs#1",
                hint="Microphone distance: farther is darker, thinner and roomier")
        ui.knob("k_clo", 580, 30, 62, 98, param="cab_lo", label="Low cut", parent="tabs#1")
        ui.knob("k_chi", 648, 30, 62, 98, param="cab_hi", label="High cut", parent="tabs#1")
        ui.knob("k_clv", 716, 30, 62, 98, param="cab_level", label="Level", parent="tabs#1")
        ui.group("g_ddbl", "DOUBLER", 8, 156, 158, 140, parent="tabs#1")
        ui.knob("k_drate", 16, 178, 62, 98, param="d_rate", label="Rate", parent="tabs#1",
                hint="Speed of the slow drift of the copies")
        ui.knob("k_dspr", 86, 178, 62, 98, param="d_spread", label="Spread", parent="tabs#1",
                hint="How much later the second copy is than the first")
        ui.group("g_dout", "OUTPUT", 174, 156, 92, 140, parent="tabs#1")
        ui.knob("k_owid", 182, 178, 62, 98, param="out_width", label="Width", parent="tabs#1",
                hint="Stereo width of the finished sound (100% unchanged)")

        self.ui_midi_page(ui, "tabs#2")
        ui.memo("about", self.about_text(), 12, 12, 880, 410, parent="tabs#3", read_only=True)
        # created last: the preset controls go on the tab row, straight after the page tabs
        self.ui_presets(ui)

    def about_text(self):
        return (
            "Virtual Guitar Rig\nVersion %s  -  written by %s\n\n" % (self.version, self.author) +
            "Signal flow: noise gate -> transpose -> amp (tight, gain, distortion, sag, tone) -> cabinet ->\n"
            "doubler -> mix -> level.  Put it on a lane holding a recorded guitar, or on any strip or bus.\n\n"
            "INPUT      Input - level into the rig.  Gate - closes below Threshold between notes (Release sets how\n"
            "           fast it lets go).\n"
            "TRANSPOSE  Semitones and Fine shift the pitch before the amp.  Mix blends the shifted copy with\n"
            "           the original (try +12 at 15-20% for shimmer, -5 at 100% for a drop tuning).\n"
            "AMP        Clean, Crunch, Lead and High Gain voicings.  Gain drives the preamp; Tight trims the lows\n"
            "           before the distortion; Bass / Mid / Treble / Presence shape the tone; Sag lets loud notes\n"
            "           squash what follows; Bright adds sparkle at low gain; Master sets the output of the amp.\n"
            "CABINET    Four cabinets and four microphones.  Position moves the mic from the centre of the cone\n"
            "           to its edge.  Room adds early reflections.  The small curve (bottom) shows the cabinet\n"
            "           and tone response; the other shows the distortion curve at the current gain.\n"
            "DOUBLER    Two detuned, delayed copies spread across the stereo field: the width of a\n"
            "           double-tracked guitar from a single take.  Time, Detune, Width, Mix.\n"
            "MIDI       Tick 'MIDI control' (Detail tab) and pick a MIDI input in the window: keys set the transpose\n"
            "           (middle C = none), pitch bend sets Fine, the mod wheel sets Gain, CC7 sets Level.\n"
            "OUTPUT     Level, and Mix to blend the untouched input (dry) with the rig.\n\n"
            "The amps and cabinets are synthesised from filters and waveshapers; they are not captures of\n"
            "any particular real equipment.  Needs numpy: pip install numpy."
        )

    # ---- audio setup ------------------------------------------------------------------------------
    def prepare(self, sample_rate, channels, max_frames):
        self._sr = float(sample_rate)
        self._ok = np is not None
        if not self._ok:
            self.log("Virtual Guitar Rig needs numpy (pip install numpy); until then the audio passes through unchanged.")
            return
        sr = self._sr
        self._nch = max(1, min(int(channels), 2))
        self._taps_pre = 512
        self._taps_post = max(2048, int(0.08 * sr))
        self._nfft_post = 1 << (2 * self._taps_post - 1).bit_length()
        self._nfft_pre = 4096
        rng = np.random.RandomState(1234)
        # the room: a fixed burst of darkened, decaying noise starting a few ms after the direct sound
        n = int(0.08 * sr)
        t = np.arange(n) / sr
        noise = np.convolve(rng.standard_normal(n), np.ones(10) / 10.0, "same")
        env = np.exp(-t / 0.022) * (t > 0.003)
        room = noise * env
        self._room_ir = room / max(1e-9, math.sqrt(float(np.sum(room * room))))
        k = np.arange(15) - 7.0
        os_k = 0.44 * np.sinc(0.44 * k) * np.hanning(17)[1:-1]
        self._os_kernel = os_k / np.sum(os_k)
        self._pre = [StreamFIR([1.0]) for _ in range(self._nch)]
        self._post = [StreamFIR([1.0]) for _ in range(self._nch)]
        self._shift = [Shifter(sr) for _ in range(self._nch)]
        self._dL = 1 << (int(0.3 * sr) + CH + 16).bit_length()
        self._resp = []
        self._init_state()
        self._pre_dirty = self._post_dirty = True
        self._rebuild()

    def _init_state(self):
        n = self._nch
        for f in self._pre + self._post:
            f.clear()
        for s in self._shift:
            s.clear()
        self._up_prev = [0.0] * n
        self._os_tail = [np.zeros(14) for _ in range(n)]
        self._g_cur = 1.0
        self._gate_g = 1.0
        self._hold = 0
        self._sag_env = 0.0
        self._sag_cur = 1.0
        self._dhist = np.zeros(self._dL)
        self._dwp = 0
        self._dph = [0.0, 0.0]
        self._in_meter = self._out_meter = 0.0

    def reset(self):
        if self._ok:
            self._init_state()

    def on_param(self, pid, value):
        if not self._ok:
            return
        if pid in ("amp_type", "tight", "fizz"):
            self._pre_dirty = True
            self._post_dirty = True
        elif pid in ("amp_on", "bass", "mid", "treble", "presence", "bright", "gain", "cab_on", "cab_type", "mic",
                     "mic_pos", "room", "depth", "mid_shift", "mic_dist", "cab_lo", "cab_hi", "cab_level"):
            self._post_dirty = True

    # ---- filter design (only when a control changed) --------------------------------------------
    def _freqs(self, nfft):
        f = np.arange(nfft // 2 + 1) * (self._sr / nfft)
        f[0] = f[1] * 0.5
        return f

    def _rebuild(self):
        p = self.p
        spec = AMP_SPECS[p.amp_type]
        if self._pre_dirty:
            f = self._freqs(self._nfft_pre)
            mag = _hp(f, 25.0 + p.tight * 28.0, 2) * _lp(f, p.fizz, 1)
            mag = mag * 10.0 ** (_bell_db(f, spec["hump_fc"], spec["hump"], 1.0) / 20.0)
            ir = _min_phase(mag, self._taps_pre)
            for fir in self._pre:
                fir.set_ir(ir)
            self._pre_dirty = False
        if self._post_dirty:
            f = self._freqs(self._nfft_post)
            db = np.zeros_like(f)
            lin = np.ones_like(f)
            if p.amp_on:
                bass = (p.bass - 5.0) * 2.4
                mid = (p.mid - 5.0) * 2.4
                treble = (p.treble - 5.0) * 2.6
                pres = (p.presence - 5.0) * 2.4
                db += _lowshelf_db(f, spec["bass"], bass)
                db += _bell_db(f, spec["mid"] * 2.0 ** p.mid_shift, mid, 1.2)
                db += _lowshelf_db(f, 90.0, p.depth)
                db += _highshelf_db(f, 2200.0, treble)
                db += _highshelf_db(f, 4800.0, pres)
                if p.bright:
                    db += _highshelf_db(f, 3500.0, 4.0 * (1.0 - p.gain / 10.0))
            if p.cab_on:
                cab = CAB_SPECS[p.cab_type]
                pos = p.mic_pos * 0.01
                dist = p.mic_dist * 0.01
                lp_mult = (1.0 - 0.4 * pos) * (1.0 - 0.2 * dist)
                db += p.cab_level + _lowshelf_db(f, 200.0, -3.0 * dist)
                db += _bell_db(f, cab["res"][0], cab["res"][1], cab["res"][2])
                for fc, g, bw in cab["bumps"]:
                    db += _bell_db(f, fc, g, bw)
                m = p.mic
                if m == 0:
                    db += _bell_db(f, 4000.0, 3.0, 0.8)
                elif m == 1:
                    db += _bell_db(f, 4000.0, -2.0, 0.8)
                    lp_mult *= 0.85
                elif m == 2:
                    db += _highshelf_db(f, 7000.0, 3.0)
                    lp_mult *= 1.35
                else:
                    db += _lowshelf_db(f, 200.0, 3.5) + _bell_db(f, 4000.0, -3.0, 0.8)
                    lp_mult *= 0.8
                db += _bell_db(f, 3500.0, -4.0 * pos, 0.8)
                lin = _hp(f, cab["hp"], 2) * _lp(f, cab["lp"] * lp_mult, 3)
                if p.cab_lo > 20:
                    lin = lin * _hp(f, p.cab_lo, 2)
                if p.cab_hi < 16000:
                    lin = lin * _lp(f, p.cab_hi, 2)
            mag = lin * 10.0 ** (db / 20.0)
            ir = _min_phase(mag, self._taps_post)
            if p.cab_on and p.room > 0:
                ir = ir + self._room_ir[:len(ir)] * (p.room * 0.01 * 0.5 * (1.0 + 1.5 * p.mic_dist * 0.01))
            for fir in self._post:
                fir.set_ir(ir)
            pts = np.geomspace(40.0, 12000.0, 150)
            full = 20.0 * np.log10(np.maximum(np.abs(np.fft.rfft(ir, self._nfft_post)), 1e-5))
            self._resp = np.interp(pts, f, full).tolist()
            self._post_dirty = False

    # ---- the amp stages --------------------------------------------------------------------------
    @staticmethod
    def _shape(v, spec):
        stages = spec["stages"]
        last = len(stages) - 1
        for i, fn in enumerate(stages):
            v = fn(v)
            if i < last:
                v = v * spec["sg"]
        return v

    def _amp_channel(self, c, x, spec):
        if self.p.os:
            n = len(x)
            up2 = np.empty(2 * n)
            xs = np.concatenate(([self._up_prev[c]], x))
            up2[0::2] = 0.5 * (xs[:-1] + xs[1:])
            up2[1::2] = x
            self._up_prev[c] = float(x[-1])
            y = self._shape(up2, spec)
            buf = np.concatenate((self._os_tail[c], y))
            self._os_tail[c] = buf[-14:]
            return np.convolve(buf, self._os_kernel, "valid")[1::2]
        return self._shape(x, spec)

    # ---- the doubler ---------------------------------------------------------------------------
    def _doubler(self, xs):
        p = self.p
        sr = self._sr
        n = len(xs[0])
        size = self._dL
        t = np.arange(n)
        mono = xs[0] if len(xs) == 1 else 0.5 * (xs[0] + xs[1])
        self._dhist[(self._dwp + t) % size] = mono
        ratio = 2.0 ** (p.d_detune / 1200.0) - 1.0
        voices = []
        for k, (mult, rate, sign) in enumerate(((1.0, p.d_rate, 1.0), (p.d_spread, p.d_rate * 1.39, -1.0))):
            base = p.d_time * 0.001 * sr * mult
            amp = min(ratio * sr / (2.0 * math.pi * rate), base * 0.9)
            lfo = np.sin(2.0 * math.pi * (self._dph[k] + t * rate / sr))
            pos = (self._dwp + t) - (base + sign * amp * lfo)
            i0 = np.floor(pos).astype(np.int64)
            fr = pos - i0
            a = self._dhist[i0 % size]
            b = self._dhist[(i0 + 1) % size]
            voices.append(a + (b - a) * fr)
            self._dph[k] = (self._dph[k] + n * rate / sr) % 1.0
        self._dwp = (self._dwp + n) % size
        va, vb = voices
        w = p.d_width * 0.01
        wl = va * (0.5 + 0.5 * w) + vb * (0.5 - 0.5 * w)
        wr = vb * (0.5 + 0.5 * w) + va * (0.5 - 0.5 * w)
        mix = p.d_mix * 0.01
        keep = 1.0 - 0.4 * mix
        if len(xs) == 1:
            return [xs[0] * keep + 0.5 * (wl + wr) * mix * 0.9]
        return [xs[0] * keep + wl * mix * 0.9, xs[1] * keep + wr * mix * 0.9]

    # ---- processing --------------------------------------------------------------------------------
    def process(self, block):
        if not self._ok:
            block.copy_through()
            return
        if self._pre_dirty or self._post_dirty:
            self._rebuild()
        n = block.frames
        pin = pout = 0.0
        for s in range(0, n, CH):
            e = min(n, s + CH)
            a, b = self._chunk(block, s, e)
            pin = max(pin, a)
            pout = max(pout, b)
        self._in_meter = max(pin, self._in_meter * 0.85)
        self._out_meter = max(pout, self._out_meter * 0.85)
        self.ui_set("m_in", value=min(1.0, self._in_meter))
        self.ui_set("m_out", value=min(1.0, self._out_meter))

    def _chunk(self, block, s, e):
        p = self.p
        sr = self._sr
        m = e - s
        nch = self._nch
        dry = [block.inp[c][s:e].astype(np.float64) for c in range(nch)]
        pin = max(float(np.max(np.abs(d))) for d in dry)

        # input gain and noise gate
        xs = [d * up.db_to_lin(p.in_gain) for d in dry]
        if p.gate_on:
            lvl = 20.0 * math.log10(math.sqrt(max(float(np.mean(x * x)) for x in xs)) + 1e-9)
            if lvl > p.gate_thr:
                self._hold = int(p.gate_hold * 0.001 * sr)
            target = 1.0 if (lvl > p.gate_thr or self._hold > 0) else up.db_to_lin(p.gate_depth)
            self._hold = max(0, self._hold - m)
            if target >= self._gate_g:
                g1 = target
            else:
                g1 = max(target, self._gate_g * math.exp(-m / (max(10.0, p.gate_rel) * 0.001 * sr)))
        else:
            g1 = 1.0
        gr = _ramp(self._gate_g, g1, m, sr, 2.0)
        self._gate_g = g1
        xs = [x * gr for x in xs]

        # transpose
        if p.tr_on and (p.tr_semi != 0 or p.tr_fine != 0):
            ratio = 2.0 ** ((p.tr_semi + p.tr_fine * 0.01) / 12.0)
            tm = p.tr_mix * 0.01
            win = int(p.tr_win * 0.001 * sr)
            xs = [x * (1.0 - tm) + self._shift[c].apply(x, ratio, win) * tm for c, x in enumerate(xs)]

        # amp
        if p.amp_on:
            spec = AMP_SPECS[p.amp_type]
            xs = [self._pre[c].apply(x) for c, x in enumerate(xs)]
            g_db = spec["lo"] + (spec["hi"] - spec["lo"]) * (p.gain * 0.1)
            g1 = up.db_to_lin(g_db)
            gr = _ramp(self._g_cur, g1, m, sr, 10.0)
            self._g_cur = g1
            ys = [self._amp_channel(c, x * gr, spec) for c, x in enumerate(xs)]
            env = max(float(np.max(np.abs(y))) for y in ys)
            self._sag_env = max(env, self._sag_env * 0.9)
            sag = 1.0 / (1.0 + p.sag * 0.01 * 0.5 * self._sag_env)
            sr_ramp = _ramp(self._sag_cur, sag, m, sr, 20.0)
            self._sag_cur = sag
            trim = up.db_to_lin(spec["trim"] + p.master)
            xs = [y * sr_ramp * trim for y in ys]

        # tone stack + cabinet (one filter)
        if p.amp_on or p.cab_on:
            xs = [self._post[c].apply(x) for c, x in enumerate(xs)]

        # doubler
        if p.d_on and p.d_mix > 0:
            xs = self._doubler(xs)

        # blend with the dry input, level, soft limiter
        wet = p.mix * 0.01
        lvl = up.db_to_lin(p.out_level)
        pout = 0.0
        bad = False
        ys = [(xs[c] * wet + dry[c] * (1.0 - wet)) * lvl for c in range(nch)]
        if nch == 2 and p.out_width != 100:
            mid = 0.5 * (ys[0] + ys[1])
            side = 0.5 * (ys[0] - ys[1]) * (p.out_width * 0.01)
            ys = [mid + side, mid - side]
        for c in range(nch):
            y = ys[c]
            if not np.all(np.isfinite(y)):
                bad = True
                y = np.nan_to_num(y, nan=0.0, posinf=0.0, neginf=0.0)
            a = np.abs(y)
            y = np.where(a > 0.8, np.sign(y) * (0.8 + 0.2 * np.tanh((a - 0.8) * 5.0)), y)
            block.out[c][s:e] = y.astype(np.float32)
            pout = max(pout, float(np.max(np.abs(y))))
        if bad:
            self._init_state()
        return pin, pout

    # ---- the two small displays ---------------------------------------------------------------
    def paint_xfer(self, cv):
        w, h = cv.width, cv.height
        cv.gradient(0, 0, w, h, "#1d2027", "#12141a")
        cv.line(4, h / 2, w - 4, h / 2, "#2a2f38", 1)
        cv.line(w / 2, 4, w / 2, h - 4, "#2a2f38", 1)
        if self._ok and w > 12:
            spec = AMP_SPECS[self.p.amp_type]
            g = up.db_to_lin(spec["lo"] + (spec["hi"] - spec["lo"]) * self.p.gain * 0.1)
            xs = np.linspace(-1.0, 1.0, w - 8) * 0.5 * g
            ys = self._shape(xs, spec)
            ys = ys / max(1e-6, float(np.max(np.abs(ys))))
            cv.polyline([(4 + i, h / 2 - float(ys[i]) * (h / 2 - 8)) for i in range(len(ys))], "#6fe0a0", 2)
        cv.text(6, 2, "DISTORTION CURVE", "#8a93a3", 9, True)

    def paint_resp(self, cv):
        w, h = cv.width, cv.height
        cv.gradient(0, 0, w, h, "#1d2027", "#12141a")
        cv.line(4, h / 2, w - 4, h / 2, "#2a2f38", 1)
        r = self._resp if self._ok else []
        if len(r) > 1:
            lo, hi = -30.0, 18.0
            n = len(r)
            pts = []
            for i, db in enumerate(r):
                yy = h - 6 - (min(hi, max(lo, db)) - lo) / (hi - lo) * (h - 16)
                pts.append((4 + i * (w - 8) / (n - 1), yy))
            cv.polyline(pts, "#7ab8ff", 2)
        cv.text(6, 2, "TONE + CABINET RESPONSE (40 Hz - 12 kHz)", "#8a93a3", 9, True)

    # ---- MIDI (a keyboard or controller chosen in the plug-in window) --------------------------------
    def on_midi(self, kind, channel, data1, data2):
        if kind == "note_on":
            self.set_param("tr_semi", data1 - 60)
            self.set_param("tr_on", True)
        elif kind == "pitch_bend":
            self.set_param("tr_fine", data1 / 8192.0 * 99.0)
        elif kind == "program":
            self.select_builtin(data1)

    # ---- presets and saved state -----------------------------------------------------------------
    def on_preset(self, event, value):
        try:
            idx = int(value)
            if idx <= 0:
                return
            name = PRESET_ORDER[idx - 1]
        except (TypeError, ValueError, IndexError):
            return
        for prm in self._params:
            self.set_param(prm.id, prm.default)
        for pid, v in PRESETS[name].items():
            self.set_param(pid, v)
        self._preset = idx
        self.log("preset: " + name)

    def get_state(self):
        return {"preset": self._preset}

    def set_state(self, state):
        if isinstance(state, dict):
            self._preset = int(state.get("preset", 0))
