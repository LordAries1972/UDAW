"""My plug-in: describe what it does and why you would use it."""
import udaw_plugin as up

#: built-in presets: name -> {parameter id: value}.  They appear first in the preset box; the user's own
#: presets (saved with the disk button) are listed after them.
PRESETS = {
    "Unity": {"gain": 0.0},
    "Quieter": {"gain": -6.0},
    "Louder": {"gain": 6.0},
}
PRESET_ORDER = list(PRESETS)


class Plugin(up.Plugin):
    name = "My Plug-in"
    author = "Your Name"
    description = "A simple gain stage with a pan-safe output meter."
    #: MIDI controller number -> parameter id.  CC 7 moves Gain; with MIDI feedback on (MIDI tab), moving
    #: Gain sends CC 7 out again.
    midi_cc = {7: "gain"}
    #: extra lines for the MIDI tab: what your own on_midi does
    midi_notes = ("Program change 0-2 loads the built-in presets.",)

    def setup(self):
        # id, display name, range, default, unit
        self.add_param("gain", "Gain", min=-24, max=24, default=0, unit="dB", decimals=1)
        # MIDI control / feedback / thru / channel, shown on the MIDI tab (see ui)
        self.add_midi_params()

    def ui(self, ui):
        ui.window(820, 396, "My Plug-in")
        ui.tabs("tabs", ["Main", "MIDI"], 8, 8, 804, 380)
        ui.knob("k_gain", 20, 20, 90, 124, param="gain", label="Gain", parent="tabs#0")
        ui.meter("m_out", 140, 24, 20, 110, vertical=True, parent="tabs#0")
        self.ui_midi_page(ui, "tabs#1")
        # Last, so it sits above the tabs: the preset box, a name field and the save / delete icons, put on
        # the tab row straight after the page tabs (it finds the "tabs" control itself).
        self.ui_presets(ui)

    # ---- built-in presets (the SDK adds loading and saving the user's own) ----------------------------
    def load_builtin(self, index):
        for pid, value in PRESETS[PRESET_ORDER[index]].items():
            self.set_param(pid, value)

    # ---- MIDI -----------------------------------------------------------------------------------------
    def on_midi(self, kind, channel, data1, data2):
        """Controllers in midi_cc are applied for you; this gets everything else (and the controllers too)."""
        if kind == "program":
            self.select_builtin(data1)          # program change picks a built-in preset
        # MIDI out: self.send_midi("cc", 0, 74, 100), self.note_on(60, 100), self.note_off(60)

    def process(self, block):
        g = up.db_to_lin(self.p.gain)
        peak = 0.0
        for ch in range(block.channels):
            src, dst = block.inp[ch], block.out[ch]
            for i in range(block.frames):
                v = src[i] * g
                dst[i] = v
                if abs(v) > peak:
                    peak = abs(v)
        self.ui_set("m_out", value=min(1.0, peak))
