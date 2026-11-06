"""Stutter Edit  -  a performance effect that turns ordinary audio into rhythmic glitches, for UDAW.

Written by Daniel J. Hobson, Australia.

What it does
------------
Stutter Edit listens to the audio all the time and keeps the last few seconds in a capture buffer.  When
you TRIGGER it (the STUTTER button, a MIDI key, or automation of the Stutter parameter) it grabs a piece of
that buffer and repeats it, over and over, in place of the live sound.

  * REPEAT LENGTH decides what you hear.  A long repeat (1/4, 1/8 note) gives recognisable chopped phrases -
    grab the last word of a vocal and it becomes a rhythmic fill.  Make it very short (a millisecond or two)
    and the repeats fuse into a buzzing, pitched texture: the repeat rate IS the pitch (1 ms = 1 kHz).
  * CAPTURE is how much of the recent past is grabbed, LOOK-BACK moves the grab further into the past, and
    POSITION chooses which part of the grab the repeat plays (oldest to newest).
  * GESTURES are the presets.  A Gesture sets up the knobs and then moves several of them for you over a
    number of beats: the repeat gets shorter and shorter, the pitch steps up a scale, a filter sweeps, the
    sound crushes.  Trigger one at the right moment during playback and it plays out by itself.
  * Every repeat can be reversed, pitched, gated, filtered, bit-crushed, faded and panned left and right.

Triggering
----------
STUTTER button on / off.  With QUANTIZE the start waits for the next 1/4, 1/8, 1/16 or 1/32 (the plug-in
counts from the start of playback at the BPM you set).  From a MIDI keyboard a key starts it (hold the key,
or latch), the key can transpose the pitch, and the velocity sets how loud.  Sustain pedal (CC 64) triggers
too.  The stutter can send MIDI back out - one note per repeat - to play a synth in time with the glitch.

How it is written
-----------------
numpy only.  The input is written to a ring buffer; at the trigger a snapshot is copied out and the
repeats read from the snapshot, so the stutter never feeds back on itself.  Audio is processed in small
chunks; inside a chunk every repeat is rendered in one go (linear-interpolated read at the pitch ratio,
declick fades, gate, per-repeat gain and pan, optional bit/rate crush).  The filter is an exact biquad
computed a chunk at a time (a short impulse response convolved with the chunk, the state carried over).
Without numpy the plug-in passes the audio through and says so in its log.
"""

import math

import udaw_plugin as up

try:
    import numpy as np
except Exception:                                   # numpy missing: the plug-in explains itself
    np = None

CH = 256                                            # processing chunk (about 5 ms)
MIN_L = 8                                           # shortest repeat, in samples
RING_SECONDS = 8.5                                  # capture buffer length

SUBDIV = ["1/1", "1/2", "1/4", "1/8", "1/16", "1/32", "1/64", "1/128"]
SUBDIV_BEATS = (4.0, 2.0, 1.0, 0.5, 0.25, 0.125, 0.0625, 0.03125)
FEELS = ["Straight", "Triplet", "Dotted"]
FEEL_MULT = (1.0, 2.0 / 3.0, 1.5)
QUANT = ["Quantize: off", "Quantize: 1/4", "Quantize: 1/8", "Quantize: 1/16", "Quantize: 1/32"]
QUANT_BEATS = (0.0, 1.0, 0.5, 0.25, 0.125)
REVERSE = ["Forward", "Reverse", "Alternate"]
FILTERS = ["Filter off", "Low-pass", "High-pass", "Band-pass"]
GEST_END = ["Hold last", "Loop", "Stop"]
MIDI_TRIG = ["Hold key", "Latch"]

#: what a gesture lane leaves alone
NEUTRAL = {"len": 1.0, "pitch": 0.0, "gate": 1.0, "cut": 0.0, "vol": 0.0, "crush": 0.0, "pan": 0.0, "start": 0.0}
#: lane -> (colour, low, high, label) for the gesture display
LANE_LOOK = {
    "len": ("#7ab8ff", 0.03, 4.0, "Length"),
    "pitch": ("#ff9f5a", -24.0, 24.0, "Pitch"),
    "gate": ("#9be37a", 0.0, 1.0, "Gate"),
    "cut": ("#e07aff", -5.0, 5.0, "Filter"),
    "vol": ("#ffe066", -30.0, 6.0, "Volume"),
    "crush": ("#ff6b6b", 0.0, 1.0, "Crush"),
    "pan": ("#6be0d0", 0.0, 1.0, "Ping-pong"),
    "start": ("#c0c0c0", 0.0, 1.0, "Position"),
}

#: what every gesture starts from, so a gesture always sounds the same whatever was set before it
DEFAULT_BASE = dict(sync=True, div=4, feel=0, free_ms=10.0, cap_ms=750.0, look_ms=0.0, start=100.0, gate=100.0,
                    fade=1.5, decay=0.0, reverse=0, semi=0, fine=0.0, f_type=0, cutoff=8000.0, res=0.9,
                    crush=0.0, pingpong=0.0, g_amount=100.0, g_end=0, mix=100.0)

#: name -> dict(base=, beats=, end=, lanes={lane: (mode, [(t, value), ...])}, info=)
GESTURES = {
    "Last Word Fill": dict(
        info="Grabs the last word and chops it faster and faster into the next bar.",
        base=dict(div=3, cap_ms=700.0, gate=85.0), beats=4.0, end=2,
        lanes={"len": ("step", [(0.0, 1.0), (0.375, 0.5), (0.625, 0.25), (0.8125, 0.125)]),
               "vol": ("lin", [(0.0, 0.0), (1.0, -3.0)])}),
    "Accelerate": dict(
        info="The repeat gets shorter and shorter: quarter notes down to thirty-seconds.",
        base=dict(div=2, cap_ms=900.0), beats=4.0, end=2,
        lanes={"len": ("lin", [(0.0, 1.0), (1.0, 0.125)])}),
    "Decelerate": dict(
        info="Starts as a rapid roll and slows to quarter notes.",
        base=dict(div=2, cap_ms=900.0), beats=4.0, end=2,
        lanes={"len": ("lin", [(0.0, 0.125), (1.0, 1.0)])}),
    "Riser Buzz": dict(
        info="A long repeat shrinks to a millisecond: the glitch fuses into a rising buzz.",
        base=dict(sync=False, free_ms=24.0, cap_ms=400.0), beats=4.0, end=0,
        lanes={"len": ("lin", [(0.0, 1.0), (1.0, 0.04)]), "vol": ("lin", [(0.0, -6.0), (1.0, 0.0)])}),
    "Pitch Stairs Up": dict(
        info="Sixteenth-note repeats climbing a scale in steps.",
        base=dict(div=4, cap_ms=600.0, gate=70.0), beats=4.0, end=0,
        lanes={"pitch": ("step", [(0.0, 0.0), (0.2, 2.0), (0.4, 4.0), (0.6, 7.0), (0.8, 12.0)])}),
    "Pitch Fall": dict(
        info="Repeats sinking an octave while they fade away.",
        base=dict(div=4, cap_ms=600.0), beats=4.0, end=2,
        lanes={"pitch": ("lin", [(0.0, 0.0), (1.0, -12.0)]), "vol": ("lin", [(0.0, 0.0), (1.0, -18.0)])}),
    "Pitch Rise": dict(
        info="Repeats rising an octave.",
        base=dict(div=4, cap_ms=600.0), beats=4.0, end=0,
        lanes={"pitch": ("lin", [(0.0, 0.0), (1.0, 12.0)])}),
    "Tape Drag": dict(
        info="Slows to a crawl: lower, longer repeats and a fading tail.",
        base=dict(div=3, cap_ms=800.0), beats=4.0, end=2,
        lanes={"pitch": ("lin", [(0.0, 0.0), (1.0, -24.0)]), "len": ("lin", [(0.0, 1.0), (1.0, 4.0)]),
               "vol": ("lin", [(0.0, 0.0), (0.8, 0.0), (1.0, -24.0)])}),
    "Gate Squeeze": dict(
        info="Sixteenths that get shorter and shorter inside their step.",
        base=dict(div=4, cap_ms=500.0), beats=4.0, end=0,
        lanes={"gate": ("lin", [(0.0, 1.0), (1.0, 0.2)])}),
    "Filter Sweep Up": dict(
        info="Low-passed repeats that open up.",
        base=dict(div=4, cap_ms=600.0, f_type=1, cutoff=12000.0, res=3.0), beats=4.0, end=0,
        lanes={"cut": ("lin", [(0.0, -5.0), (1.0, 0.0)])}),
    "Filter Sweep Down": dict(
        info="Repeats that close down into a low-pass.",
        base=dict(div=4, cap_ms=600.0, f_type=1, cutoff=12000.0, res=3.0), beats=4.0, end=0,
        lanes={"cut": ("lin", [(0.0, 0.0), (1.0, -5.0)])}),
    "Telephone Crush": dict(
        info="Band-passed repeats that crumble into lo-fi.",
        base=dict(div=4, cap_ms=600.0, f_type=3, cutoff=1800.0, res=1.5), beats=4.0, end=0,
        lanes={"crush": ("lin", [(0.0, 0.0), (1.0, 0.9)])}),
    "Ping-Pong Roll": dict(
        info="Sixteenths bouncing left and right, wider and wider.",
        base=dict(div=4, cap_ms=700.0), beats=4.0, end=0,
        lanes={"pan": ("lin", [(0.0, 0.2), (1.0, 1.0)])}),
    "Triplet Roll": dict(
        info="Triplet eighths that double into triplet sixteenths halfway.",
        base=dict(div=3, feel=1, cap_ms=700.0), beats=2.0, end=0,
        lanes={"len": ("step", [(0.0, 1.0), (0.5, 0.5)])}),
    "Slice Walk": dict(
        info="Sixteenths that step through the grabbed phrase, slice by slice.",
        base=dict(div=4, cap_ms=1500.0, start=0.0), beats=4.0, end=1,
        lanes={"start": ("step", [(0.0, 0.0), (0.25, 0.33), (0.5, 0.66), (0.75, 1.0)])}),
    "Stutter Out": dict(
        info="A roll that tightens and fades to nothing, then stops by itself.",
        base=dict(div=3, cap_ms=800.0), beats=2.0, end=2,
        lanes={"len": ("lin", [(0.0, 1.0), (1.0, 0.25)]), "vol": ("lin", [(0.0, 0.0), (1.0, -30.0)])}),
    "Machine Gun": dict(
        info="Tight half-gated thirty-seconds that die away, over and over.",
        base=dict(div=5, cap_ms=300.0, gate=50.0), beats=1.0, end=1,
        lanes={"vol": ("lin", [(0.0, 0.0), (1.0, -12.0)])}),
    "Octave Down Repeat": dict(
        info="Quarter-note repeats an octave down: slow and heavy.",
        base=dict(div=2, cap_ms=900.0), beats=4.0, end=0,
        lanes={"pitch": ("lin", [(0.0, -12.0), (1.0, -12.0)])}),
    "Octave Jump": dict(
        info="Eighth-note repeats that jump up an octave halfway.",
        base=dict(div=3, cap_ms=700.0), beats=2.0, end=0,
        lanes={"pitch": ("step", [(0.0, 0.0), (0.5, 12.0)])}),
}
GEST_ORDER = list(GESTURES)


def _lane_at(lane, u, expo=False):
    """Value of a gesture lane at position u (0..1)."""
    mode, pts = lane
    if u <= pts[0][0]:
        return pts[0][1]
    if mode == "step":
        v = pts[0][1]
        for t, val in pts:
            if t <= u:
                v = val
            else:
                break
        return v
    for i in range(1, len(pts)):
        t1, v1 = pts[i]
        if u <= t1:
            t0, v0 = pts[i - 1]
            f = (u - t0) / (t1 - t0) if t1 > t0 else 1.0
            return v0 * (v1 / v0) ** f if expo else v0 + (v1 - v0) * f
    return pts[-1][1]


class Plugin(up.Plugin):
    midi_cc = {1: "g_amount", 7: "level", 11: "mix", 64: "trig", 71: "res", 72: "gate", 73: "decay",
               74: "cutoff", 75: "semi"}
    midi_notes = ("Keys trigger the stutter (hold the key, or latch - see below); the velocity sets how loud.",
                  "With 'Keys transpose' on, the key sets the pitch (middle C = no change).",
                  "Sustain pedal (CC 64) is the Stutter button.  Program change 0-n picks a Gesture.",
                  "With 'Send notes' on, the plug-in sends a MIDI note for every repeat longer than 12 ms.")
    name = "Stutter Edit"
    vendor = "UDAW examples"
    author = "Daniel J. Hobson, Australia"
    version = "1.0"
    description = ("A performance effect: grabs the audio just played and repeats it into rhythmic glitches "
                   "and buzzing pitched textures, with Gestures that move the controls for you.")
    use_numpy = True

    # ---- parameters ------------------------------------------------------------------------
    def setup(self):
        self.add_bool("trig", "Stutter", default=False, group="Trigger")
        self.add_choice("quant", "Quantize", QUANT, default=0, group="Trigger")
        self.add_bool("sync", "Tempo sync", default=True, group="Repeat")
        self.add_choice("div", "Division", SUBDIV, default=4, group="Repeat")
        self.add_choice("feel", "Feel", FEELS, default=0, group="Repeat")
        self.add_param("free_ms", "Free length", min=0.5, max=2000, default=10, unit="ms", log=True, decimals=1,
                       group="Repeat")
        self.add_param("bpm", "Tempo", min=40, max=300, default=120, unit="BPM", decimals=1, group="Repeat")
        self.add_param("cap_ms", "Capture", min=20, max=4000, default=750, unit="ms", log=True, decimals=0,
                       group="Repeat")
        self.add_param("look_ms", "Look-back", min=0, max=4000, default=0, unit="ms", decimals=0, group="Repeat")
        self.add_param("start", "Position", min=0, max=100, default=100, unit="%", decimals=0, group="Repeat")
        self.add_param("gate", "Gate", min=5, max=100, default=100, unit="%", decimals=0, group="Shape")
        self.add_param("fade", "Fade", min=0.1, max=20, default=1.5, unit="ms", log=True, decimals=1, group="Shape")
        self.add_param("decay", "Decay", min=0, max=48, default=0, unit="dB/beat", decimals=1, group="Shape")
        self.add_choice("reverse", "Direction", REVERSE, default=0, group="Shape")
        self.add_param("crush", "Crush", min=0, max=100, default=0, unit="%", decimals=0, group="Shape")
        self.add_param("semi", "Pitch", min=-24, max=24, default=0, unit="st", kind="int", group="Pitch")
        self.add_param("fine", "Fine", min=-50, max=50, default=0, unit="cents", decimals=0, group="Pitch")
        self.add_choice("f_type", "Filter", FILTERS, default=0, group="Filter")
        self.add_param("cutoff", "Cutoff", min=80, max=16000, default=8000, unit="Hz", log=True, decimals=0,
                       group="Filter")
        self.add_param("res", "Resonance", min=0.5, max=12, default=0.9, log=True, decimals=1, group="Filter")
        self.add_param("pingpong", "Ping-pong", min=0, max=100, default=0, unit="%", decimals=0, group="Output")
        self.add_param("mix", "Mix", min=0, max=100, default=100, unit="%", decimals=0, group="Output")
        self.add_param("rel", "Release", min=1, max=500, default=12, unit="ms", log=True, decimals=0, group="Output")
        self.add_param("level", "Level", min=-24, max=12, default=0, unit="dB", decimals=1, group="Output")
        self.add_param("g_amount", "Gesture amount", min=0, max=100, default=100, unit="%", decimals=0,
                       group="Gesture")
        self.add_param("g_beats", "Gesture length", min=0.25, max=32, default=4, unit="beats", log=True, decimals=2,
                       group="Gesture")
        self.add_choice("g_end", "At the end", GEST_END, default=0, group="Gesture")
        self.add_midi_params()
        self.add_bool("midi_pitch", "Keys transpose", default=True, group="MIDI")
        self.add_choice("midi_trig", "Key mode", MIDI_TRIG, default=0, group="MIDI")
        self.add_bool("midi_rep", "Send notes", default=False, group="MIDI")
        self.add_param("midi_note", "Output note", min=0, max=127, default=60, kind="int", group="MIDI")
        self._gidx = 0
        self._gest = None
        self._applying = False
        self._ok = False

    # ---- window ---------------------------------------------------------------------------------
    def ui(self, ui):
        ui.window(820, 484, "Stutter Edit", color="#16181d")
        ui.label("title", "STUTTER EDIT", 16, 10, 220, 22, font_size=15, bold=True)
        ui.label("sub", "grab it, repeat it, glitch it", 16, 32, 190, 16, font_color="#8a93a3")
        ui.button("b_trig", "STUTTER", 340, 10, 120, 38, toggle=True, param="trig",
                  hint="Grab the audio just played and repeat it. Press again to release. Also: a MIDI key, the sustain pedal, or automation.")
        ui.label("l_state", "idle", 214, 32, 118, 16, font_color="#8a93a3", font_size=10)

        ui.tabs("tabs", ["Stutter", "Gesture", "MIDI", "About"], 8, 56, 804, 424)
        ui.canvas("wave", 8, 4, 756, 74, parent="tabs#0", fps=20, mouse=False)

        ui.group("g_rep", "REPEAT", 8, 84, 440, 150, parent="tabs#0")
        ui.check("x_sync", "Tempo sync", 16, 104, 100, 22, param="sync", parent="tabs#0",
                 hint="Repeat length from the Tempo and the note value (off: a free length in milliseconds)")
        ui.combo("c_div", SUBDIV, 120, 102, 78, 24, param="div", parent="tabs#0")
        ui.combo("c_feel", FEELS, 204, 102, 94, 24, param="feel", parent="tabs#0")
        ui.combo("c_quant", QUANT, 304, 102, 136, 24, param="quant", parent="tabs#0",
                 hint="Wait for the next beat division before the stutter starts (counted from the start of playback at the Tempo)")
        ui.knob("k_free", 14, 130, 62, 98, param="free_ms", label="Free", parent="tabs#0",
                hint="Repeat length when Tempo sync is off. Under about 20 ms the repeats fuse into a pitch (1 ms = 1 kHz)")
        ui.knob("k_bpm", 82, 130, 62, 98, param="bpm", label="Tempo", parent="tabs#0",
                hint="Project tempo: sets the repeat length and the Gesture timing")
        ui.knob("k_cap", 150, 130, 62, 98, param="cap_ms", label="Capture", parent="tabs#0",
                hint="How much of the recent audio is grabbed")
        ui.knob("k_look", 218, 130, 62, 98, param="look_ms", label="Look-back", parent="tabs#0",
                hint="Move the grab further into the past: catch the word you just missed")
        ui.knob("k_start", 286, 130, 62, 98, param="start", label="Position", parent="tabs#0",
                hint="Which part of the grab each repeat plays: 0 = the oldest, 100 = the newest")

        ui.group("g_shape", "SHAPE", 456, 84, 308, 150, parent="tabs#0")
        ui.combo("c_rev", REVERSE, 464, 102, 118, 24, param="reverse", parent="tabs#0")
        ui.knob("k_gate", 462, 130, 56, 98, param="gate", label="Gate", parent="tabs#0",
                hint="How much of each repeat is open")
        ui.knob("k_fade", 522, 130, 56, 98, param="fade", label="Fade", parent="tabs#0",
                hint="Declick fade at the start and end of each repeat")
        ui.knob("k_dec", 582, 130, 56, 98, param="decay", label="Decay", parent="tabs#0",
                hint="Each beat of stuttering is this much quieter")
        ui.knob("k_crush", 642, 130, 56, 98, param="crush", label="Crush", parent="tabs#0",
                hint="Bit and sample-rate reduction")

        ui.group("g_pitch", "PITCH", 8, 242, 150, 150, parent="tabs#0")
        ui.knob("k_semi", 14, 268, 62, 98, param="semi", label="Pitch", parent="tabs#0",
                hint="Semitones: the repeats are read faster or slower")
        ui.knob("k_fine", 84, 268, 62, 98, param="fine", label="Fine", parent="tabs#0")

        ui.group("g_filt", "FILTER", 166, 242, 238, 150, parent="tabs#0")
        ui.combo("c_ft", FILTERS, 174, 262, 118, 24, param="f_type", parent="tabs#0")
        ui.knob("k_cut", 174, 292, 62, 98, param="cutoff", label="Cutoff", parent="tabs#0")
        ui.knob("k_res", 244, 292, 62, 98, param="res", label="Resonance", parent="tabs#0")

        ui.group("g_out", "OUTPUT", 412, 242, 352, 150, parent="tabs#0")
        ui.knob("k_pp", 418, 268, 62, 98, param="pingpong", label="Ping-pong", parent="tabs#0",
                hint="Alternate repeats left and right")
        ui.knob("k_mix", 486, 268, 62, 98, param="mix", label="Mix", parent="tabs#0",
                hint="100% replaces the live sound while stuttering")
        ui.knob("k_rel", 554, 268, 62, 98, param="rel", label="Release", parent="tabs#0",
                hint="How long the stutter takes to fade back to the live sound")
        ui.knob("k_lvl", 622, 268, 62, 98, param="level", label="Level", parent="tabs#0")
        ui.meter("m_out", 696, 268, 18, 96, vertical=True, parent="tabs#0", hint="Output level")

        ui.group("g_gs", "GESTURE", 8, 8, 756, 130, parent="tabs#1")
        ui.knob("k_gamt", 16, 32, 62, 98, param="g_amount", label="Amount", parent="tabs#1",
                hint="How far the Gesture moves the controls: 0 = not at all, 100 = as designed")
        ui.knob("k_gbeats", 86, 32, 62, 98, param="g_beats", label="Length", parent="tabs#1",
                hint="How many beats the Gesture takes to play out")
        ui.label("l_gend", "At the end:", 166, 36, 80, 18, parent="tabs#1")
        ui.combo("c_gend", GEST_END, 250, 32, 110, 24, param="g_end", parent="tabs#1",
                 hint="Hold the last value, loop the Gesture, or release the stutter")
        ui.memo("gesture_info", self.gesture_info(), 372, 28, 384, 100, parent="tabs#1", read_only=True)
        ui.canvas("gcurve", 8, 146, 756, 240, parent="tabs#1", fps=20, mouse=False)

        self.ui_midi_page(ui, "tabs#2", extra_rows=2)
        ui.check("x_mpitch", "Keys transpose the stutter", 20, 146, 330, 22, param="midi_pitch", parent="tabs#2")
        ui.check("x_mrep", "Send a MIDI note for every repeat", 380, 146, 360, 22, param="midi_rep", parent="tabs#2",
                 hint="Needs a MIDI output device: plays a synth in time with the stutter")
        ui.label("l_mkey", "Key mode", 20, 174, 70, 20, parent="tabs#2")
        ui.combo("c_mkey", MIDI_TRIG, 96, 172, 120, 24, param="midi_trig", parent="tabs#2")
        ui.label("l_mnote", "Output note", 380, 174, 80, 20, parent="tabs#2")
        ui.slider("s_mnote", 466, 170, 220, 28, param="midi_note", parent="tabs#2",
                  hint="The MIDI note sent for an unpitched repeat (60 = middle C); the Pitch setting is added to it")

        ui.memo("about", self.about_text(), 12, 12, 780, 390, parent="tabs#3", read_only=True)
        # created last: the preset controls go on the tab row, straight after the page tabs
        self.ui_presets(ui)

    def gesture_info(self):
        if self._gest is None:
            return ("No Gesture loaded - use the controls by hand.\n\n"
                    "Pick one from the Gestures list at the top right, then press STUTTER. A Gesture sets up "
                    "the controls and moves several of them over a number of beats.")
        return "%s\n\n%s\n\nPlays over %g beats; set 'At the end' to hold, loop or release." % (
            GEST_ORDER[self._gidx - 1], self._gest["info"], self._gest["beats"])

    def about_text(self):
        return (
            "Stutter Edit\nVersion %s  -  written by %s\n\n" % (self.version, self.author) +
            "Press STUTTER (or play a MIDI key) to grab the audio just played and repeat it.\n\n"
            "REPEAT  Tempo sync + note value + Feel set the repeat length from the Tempo; turn Tempo sync off for a\n"
            "  free length in milliseconds. Long repeats are chopped phrases. Under about 20 ms they fuse into a\n"
            "  buzzing pitch (1 ms = 1 kHz). Capture is how much past audio is grabbed, Look-back moves the grab\n"
            "  into the past, Position picks which part of the grab each repeat plays.\n"
            "SHAPE  Gate - how much of each repeat sounds.  Fade - declick.  Decay - fade per beat.\n"
            "  Direction - forward, reverse, or alternate.  Crush - bits and sample rate.\n"
            "PITCH  Pitch and Fine read the repeats faster or slower.\n"
            "FILTER  Low-pass, high-pass or band-pass on the stutter.\n"
            "OUTPUT  Ping-pong - alternate repeats left and right.  Mix - 100% replaces the live sound.\n"
            "  Release - fade back to the live sound.\n\n"
            "GESTURES  Presets that set the controls and then move them for you: acceleration, pitch stairs, filter\n"
            "  sweeps, crushes... Amount scales how far, Length sets the beats, 'At the end' holds, loops or releases.\n\n"
            "QUANTIZE waits for the next beat division, counted from the start of playback at the Tempo you set.\n\n"
            "Needs numpy: pip install numpy."
        )

    # ---- audio ------------------------------------------------------------------------------------
    def prepare(self, sample_rate, channels, max_frames):
        self._sr = float(sample_rate)
        self._ok = np is not None
        if not self._ok:
            self.log("Stutter Edit needs numpy (pip install numpy); until then the audio passes through unchanged.")
            return
        self._rn = 1 << int(RING_SECONDS * self._sr).bit_length()
        self._mask = self._rn - 1
        self._ring = np.zeros((2, self._rn), np.float32)
        self._wp = 0
        self._clear_state()

    def _clear_state(self):
        self._want_on = False
        self._active = False
        self._wet = 0.0
        self._snap = np.zeros((2, 64))
        self._r = None
        self._L = 0
        self._phase = 0
        self._elapsed = 0
        self._rep_idx = 0
        self._u = 0.0
        self._vel = 1.0
        self._key_semi = 0
        self._held = set()
        self._stop_req = False
        self._fx = [[0.0, 0.0, 0.0, 0.0], [0.0, 0.0, 0.0, 0.0]]
        self._note = None
        self._state_text = "idle"
        self._peaks_snap = None

    def reset(self):
        if not getattr(self, "_ok", False):
            return
        self._send_note_off()
        self._ring[:] = 0
        self._clear_state()
        self.set_param("trig", False)

    def on_param(self, pid, value):
        if not getattr(self, "_ok", False):
            return
        if pid == "trig":
            on = bool(value >= 0.5)
            if on:
                self._want_on = True
            else:
                self._want_on = False
                self._active = False
                self._vel = 1.0
                self._send_note_off()

    # ---- starting a stutter ---------------------------------------------------------------------
    def _start_offset(self, abs_pos):
        """Samples until the quantised start (0 = now)."""
        qb = QUANT_BEATS[int(self.p.quant)]
        if qb <= 0.0:
            return 0
        grid = int(qb * 60.0 / self.p.bpm * self._sr)
        if grid < 2:
            return 0
        r = abs_pos % grid
        return 0 if r == 0 else grid - r

    def _begin(self, end_abs):
        """Takes the snapshot that ends at ring position end_abs (minus look-back) and starts repeating."""
        p = self.p
        sr = self._sr
        e = end_abs - int(p.look_ms * 0.001 * sr)
        s = int(p.cap_ms * 0.001 * sr)
        s = min(s, e - (self._wp - self._rn) - 4)
        if s < 64:
            s = 64
            e = max(e, s)
        idx = (np.arange(e - s, e)) & self._mask
        self._snap = self._ring[:, idx].astype(np.float64)
        self._active = True
        self._phase = self._L = 0
        self._elapsed = 0
        self._rep_idx = 0
        self._fx = [[0.0, 0.0, 0.0, 0.0], [0.0, 0.0, 0.0, 0.0]]
        self._peaks_snap = None

    def _gesture_values(self, beats_el):
        g = dict(NEUTRAL)
        ge = self._gest
        if ge is None:
            return g, 0.0
        dur = max(0.05, self.p.g_beats)
        u = beats_el / dur
        endm = int(self.p.g_end)
        if endm == 1:
            u = u % 1.0
        elif u >= 1.0:
            u = 1.0
            if endm == 2:
                self._stop_req = True
        a = self.p.g_amount * 0.01
        for k, lane in ge["lanes"].items():
            v = _lane_at(lane, u, expo=(k == "len"))
            n = NEUTRAL[k]
            g[k] = n * (v / n) ** a if k == "len" else n + (v - n) * a
        return g, u

    def _begin_repeat(self):
        p = self.p
        sr = self._sr
        beats_el = self._elapsed / sr * p.bpm / 60.0
        g, u = self._gesture_values(beats_el)
        self._u = u
        if p.sync:
            base = SUBDIV_BEATS[int(p.div)] * FEEL_MULT[int(p.feel)] * 60.0 / p.bpm * sr
        else:
            base = p.free_ms * 0.001 * sr
        L = int(max(MIN_L, min(base * g["len"], 6.0 * sr)))
        S = self._snap.shape[1]
        pos = min(1.0, max(0.0, p.start * 0.01 + g["start"]))
        if L < S:
            s0 = int(round(pos * (S - L)))
            Lw = L
        else:
            s0, Lw = 0, S
        semi = p.semi + g["pitch"] + (self._key_semi if p.midi_pitch else 0) + p.fine * 0.01
        ratio = 2.0 ** (max(-48.0, min(48.0, semi)) / 12.0)
        rm = int(p.reverse)
        rev = rm == 1 or (rm == 2 and self._rep_idx % 2 == 1)
        gate = min(1.0, max(0.02, p.gate * 0.01 * g["gate"]))
        gain = up.db_to_lin(max(-80.0, g["vol"] - p.decay * beats_el)) * (0.35 + 0.65 * self._vel)
        pp = min(1.0, max(0.0, p.pingpong * 0.01 + g["pan"]))
        sgn = 1.0 if self._rep_idx % 2 == 0 else -1.0
        ang = (sgn * pp + 1.0) * math.pi / 4.0
        self._r = dict(
            L=L, Lw=Lw, s0=s0, ratio=ratio, rev=rev, gate=gate, gain=gain,
            gl=math.sqrt(2.0) * math.cos(ang), gr=math.sqrt(2.0) * math.sin(ang),
            crush=min(1.0, max(0.0, p.crush * 0.01 + g["crush"])),
            fade=max(1.0, min(p.fade * 0.001 * sr, L / 6.0)),
            cut=min(0.45 * sr, max(30.0, p.cutoff * 2.0 ** g["cut"])))
        self._L = L
        self._phase = 0
        self._rep_idx += 1
        self._state_text = "%d ms  %+d st" % (int(L / sr * 1000.0 + 0.5), int(round(semi)))
        if p.midi_rep:
            self._send_note(semi, gain, L)

    # ---- MIDI out -------------------------------------------------------------------------------
    def _send_note(self, semi, gain, L):
        long_enough = L >= 0.012 * self._sr
        if self._note is not None and not long_enough:
            return                                  # too fast for a note per repeat: hold the one sounding
        self._send_note_off()
        note = int(min(127, max(0, round(self.p.midi_note + semi))))
        vel = int(min(127, max(1, round(gain * 100.0 + 27.0))))
        ch = max(int(self.p.midi_ch) - 1, 0)
        self.send_midi("note_on", ch, note, vel)
        self._note = (ch, note)

    def _send_note_off(self):
        n = getattr(self, "_note", None)
        if n is not None:
            self.send_midi("note_off", n[0], n[1], 0)
            self._note = None

    # ---- rendering ------------------------------------------------------------------------------
    def _segment(self, ph, m):
        """m samples of the current repeat starting ph samples into it -> (2, m)."""
        r = self._r
        t = np.arange(m) + ph
        if r["rev"]:
            pos = (r["L"] - 1 - t) * r["ratio"]
        else:
            pos = t * r["ratio"]
        pos = np.mod(pos, r["Lw"])
        i0 = np.floor(pos).astype(np.int64)
        fr = pos - i0
        i1 = (i0 + 1) % r["Lw"]
        snap = self._snap
        a = snap[:, r["s0"] + i0]
        b = snap[:, r["s0"] + i1]
        y = a + (b - a) * fr
        f = r["fade"]
        env = np.clip(np.minimum(t / f, (r["gate"] * r["L"] - t) / f), 0.0, 1.0) * r["gain"]
        y[0] *= env * r["gl"]
        y[1] *= env * r["gr"]
        c = r["crush"]
        if c > 0.0:
            q = 2.0 ** (15.0 - 12.0 * c)
            y = np.round(y * q) / q
            dec = 1 + int(15 * c * c)
            if dec > 1:
                hold = np.clip(((np.arange(m) + ph) // dec) * dec - ph, 0, m - 1)
                y = y[:, hold]
        return y

    def _filter(self, w, kind, f0):
        """Exact biquad over the chunk w (2, m): kind 1 low-pass, 2 high-pass, 3 band-pass."""
        sr = self._sr
        q = self.p.res
        w0 = 2.0 * math.pi * f0 / sr
        cw = math.cos(w0)
        al = math.sin(w0) / (2.0 * q)
        if kind == 1:
            b0, b1, b2 = (1.0 - cw) * 0.5, 1.0 - cw, (1.0 - cw) * 0.5
        elif kind == 2:
            b0, b1, b2 = (1.0 + cw) * 0.5, -(1.0 + cw), (1.0 + cw) * 0.5
        else:
            b0, b1, b2 = al, 0.0, -al
        a0 = 1.0 + al
        a1, a2 = -2.0 * cw / a0, (1.0 - al) / a0
        b0, b1, b2 = b0 / a0, b1 / a0, b2 / a0
        m = w.shape[1]
        k = np.arange(m)
        disc = complex(a1 * a1 - 4.0 * a2)
        rt = np.sqrt(disc)
        p1, p2 = (-a1 + rt) * 0.5, (-a1 - rt) * 0.5
        if abs(p1 - p2) < 1e-9:
            g = ((k + 1) * (p1.real ** k))
        else:
            g = np.real((p1 ** (k + 1) - p2 ** (k + 1)) / (p1 - p2))
        out = np.empty_like(w)
        for c in range(2):
            x1, x2, y1, y2 = self._fx[c]
            x = w[c]
            xe = np.concatenate(([x2, x1], x))
            u = b0 * x + b1 * xe[1:m + 1] + b2 * xe[0:m]
            u[0] -= a1 * y1 + a2 * y2
            if m > 1:
                u[1] -= a2 * y1
            y = np.clip(np.convolve(u, g)[:m], -8.0, 8.0)
            out[c] = y
            self._fx[c] = [float(xe[m + 1]), float(xe[m]), float(y[-1]), float(y[-2]) if m > 1 else y1]
        return out

    def _tileable(self):
        p = self.p
        return self._gest is None and p.decay == 0 and p.pingpong == 0 and int(p.reverse) != 2

    def _render(self, x, abs_pos):
        """x: dry chunk (2, m) -> output chunk (2, m)."""
        m = x.shape[1]
        if not self._active and self._wet <= 0.0:
            return x
        w = np.zeros((2, m))
        t = 0
        while t < m:
            if self._phase >= self._L:
                self._begin_repeat()
                rl = self._L
                if rl < 128 and self._tileable():
                    # very short repeats that cannot differ from each other: render one, tile the rest
                    nrep = (m - t) // rl
                    if nrep >= 2:
                        w[:, t:t + nrep * rl] = np.tile(self._segment(0, rl), nrep)
                        self._phase = rl
                        self._elapsed += nrep * rl
                        self._rep_idx += nrep - 1
                        t += nrep * rl
                        continue
            seg = min(m - t, self._L - self._phase)
            w[:, t:t + seg] = self._segment(self._phase, seg)
            self._phase += seg
            self._elapsed += seg
            t += seg
        p = self.p
        ft = int(p.f_type)
        if ft:
            w = self._filter(w, ft, self._r["cut"])
        else:
            self._fx = [[0.0, 0.0, 0.0, 0.0], [0.0, 0.0, 0.0, 0.0]]
        sr = self._sr
        if self._active:
            step = 1.0 / max(1.0, 0.002 * sr)
            g = np.minimum(1.0, self._wet + step * (np.arange(m) + 1))
        else:
            step = 1.0 / max(1.0, p.rel * 0.001 * sr)
            g = np.maximum(0.0, self._wet - step * (np.arange(m) + 1))
        self._wet = float(g[-1])
        amt = g * (p.mix * 0.01)
        return x * (1.0 - amt) + w * amt

    def process(self, block):
        if not self._ok:
            block.copy_through()
            return
        n = block.frames
        chans = block.channels
        x = np.empty((2, n))
        x[0] = block.inp[0]
        x[1] = block.inp[1] if chans > 1 else block.inp[0]
        wp0 = self._wp
        idx = (wp0 + np.arange(n)) & self._mask
        self._ring[0, idx] = x[0]
        self._ring[1, idx] = x[1]
        self._wp += n
        out = np.empty((2, n))
        pos = 0
        while pos < n:
            end = min(n, pos + CH)
            if self._want_on and not self._active:
                off = self._start_offset(block.position + pos)
                if off == 0:
                    self._begin(wp0 + pos)
                else:
                    end = min(end, pos + off)
            out[:, pos:end] = self._render(x[:, pos:end], block.position + pos)
            pos = end
        lvl = up.db_to_lin(self.p.level)
        peak = 0.0
        for c in range(min(chans, 2)):
            y = np.clip(out[c] * lvl, -1.0, 1.0) if chans > 1 else np.clip(0.5 * (out[0] + out[1]) * lvl, -1.0, 1.0)
            block.out[c][:] = y.astype(np.float32)
            peak = max(peak, float(np.max(np.abs(y))))
        self._out_meter = max(peak, getattr(self, "_out_meter", 0.0) * 0.85)
        self.ui_set("m_out", value=min(1.0, self._out_meter))
        if self._stop_req:
            self._stop_req = False
            self.set_param("trig", False)

    # ---- window feedback ------------------------------------------------------------------------
    def on_timer(self):
        if not getattr(self, "_ok", False):
            return
        if self._active:
            txt = self._state_text
        elif self._want_on:
            txt = "waiting..."
        else:
            txt = "idle"
        self.ui_set("l_state", caption=txt)

    def _peaks(self, a, bins):
        s = a.shape[0]
        if s < bins:
            return np.abs(a)
        step = s // bins
        return np.abs(a[:step * bins]).reshape(bins, step).max(axis=1)

    def paint_wave(self, cv):
        w, h = cv.width, cv.height
        cv.gradient(0, 0, w, h, "#1d2027", "#12141a")
        if not getattr(self, "_ok", False):
            return
        sr = self._sr
        bins = 180
        if self._active:
            data = 0.5 * (self._snap[0] + self._snap[1])
            r = self._r or {}
            tag = "GRABBED"
        else:
            e = self._wp - int(self.p.look_ms * 0.001 * sr)
            s = min(int(self.p.cap_ms * 0.001 * sr), max(64, e - max(0, self._wp - self._rn)))
            idx = np.arange(e - s, e) & self._mask
            data = 0.5 * (self._ring[0, idx] + self._ring[1, idx]).astype(np.float64)
            r = {}
            tag = "LIVE CAPTURE"
        pk = self._peaks(data, bins)
        nb = len(pk)
        if nb < 2:
            return
        mid = h / 2.0
        xs = [4 + i * (w - 8) / (nb - 1) for i in range(nb)]
        amp = (h / 2.0 - 8)
        up_pts = [(xs[i], mid - min(1.0, pk[i] * 1.6) * amp) for i in range(nb)]
        dn_pts = [(xs[i], mid + min(1.0, pk[i] * 1.6) * amp) for i in range(nb - 1, -1, -1)]
        cv.polygon(up_pts + dn_pts, fill=up.rgb(40, 80, 110), stroke="#5aa0d0")
        S = data.shape[0]
        if self._active and r:
            x0 = 4 + (w - 8) * r["s0"] / S
            x1 = 4 + (w - 8) * min(S, r["s0"] + r["Lw"]) / S
            cv.rect(x0, 3, max(2.0, x1 - x0), h - 6, "#ffb347", 2)
            ph = (self._phase * r["ratio"]) % max(1, r["Lw"])
            if r["rev"]:
                ph = r["Lw"] - 1 - ph
            xp = 4 + (w - 8) * (r["s0"] + ph) / S
            cv.line(xp, 3, xp, h - 3, "#ffffff", 1)
        else:
            s0 = int(round(self.p.start * 0.01 * max(0, S - 1)))
            cv.line(4 + (w - 8) * s0 / max(1, S), 3, 4 + (w - 8) * s0 / max(1, S), h - 3, "#ffb347", 1, True)
        cv.text(6, 2, tag + " (%d ms)" % int(S / sr * 1000.0), "#8a93a3", 9, True)

    def paint_gcurve(self, cv):
        w, h = cv.width, cv.height
        cv.gradient(0, 0, w, h, "#1d2027", "#12141a")
        ge = self._gest
        if ge is None:
            cv.text(w / 2, h / 2 - 6, "No Gesture loaded", "#8a93a3", 12, False, "center", 0)
            return
        left, top, pw, ph = 8, 22, w - 16, h - 30
        for gi in range(1, 4):
            cv.line(left + pw * gi / 4.0, top, left + pw * gi / 4.0, top + ph, "#2a2f3a", 1, True)
        x_leg = left
        for k, lane in ge["lanes"].items():
            col, lo, hi, label = LANE_LOOK[k]
            pts = []
            for i in range(0, 121):
                u = i / 120.0
                v = _lane_at(lane, u, expo=(k == "len"))
                if k == "len":
                    f = (math.log(max(v, lo)) - math.log(lo)) / (math.log(hi) - math.log(lo))
                else:
                    f = (v - lo) / (hi - lo)
                pts.append((left + pw * u, top + ph - ph * min(1.0, max(0.0, f))))
            cv.polyline(pts, col, 2)
            cv.text(x_leg, 4, label, col, 10, True)
            x_leg += 90
        if self._active:
            xp = left + pw * self._u
            cv.line(xp, top, xp, top + ph, "#ffffff", 1)

    # ---- Gestures and saved state ---------------------------------------------------------------
    def on_gesture(self, event, value):
        try:
            idx = int(value)
        except (TypeError, ValueError):
            return
        if idx <= 0 or idx > len(GEST_ORDER):
            self._gidx = 0
            self._gest = None
            self.ui_set("gesture_info", text=self.gesture_info())
            self.repaint("gcurve")
            return
        ge = GESTURES[GEST_ORDER[idx - 1]]
        base = dict(DEFAULT_BASE)
        base.update(ge["base"])
        base["g_beats"] = ge["beats"]
        base["g_end"] = ge["end"]
        for pid, v in base.items():
            self.set_param(pid, v)
        self._gidx = idx
        self._gest = ge
        self.ui_set("gesture_info", text=self.gesture_info())
        self.repaint("gcurve")
        self.log("gesture: " + GEST_ORDER[idx - 1])

    def on_midi(self, kind, channel, data1, data2):
        if not getattr(self, "_ok", False):
            return
        p = self.p
        if kind == "note_on":
            self._held.add(data1)
            self._vel = data2 / 127.0
            if p.midi_pitch:
                self._key_semi = data1 - 60
            if int(p.midi_trig) == 1:
                self.set_param("trig", not p.trig)
            else:
                self.set_param("trig", True)
        elif kind == "note_off":
            self._held.discard(data1)
            if int(p.midi_trig) == 0 and not self._held:
                self.set_param("trig", False)
        elif kind == "program":
            self.select_builtin(data1)

    preset_skip = ("trig",)

    def builtin_presets(self):
        return list(GEST_ORDER)

    def load_builtin(self, index):
        self.on_gesture("select", index + 1)

    def get_state(self):
        return {"gesture": self._gidx}

    def set_state(self, state):
        if isinstance(state, dict):
            idx = int(state.get("gesture", 0))
            if 0 < idx <= len(GEST_ORDER):
                self._gidx = idx
                self._gest = GESTURES[GEST_ORDER[idx - 1]]
