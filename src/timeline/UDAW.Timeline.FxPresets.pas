unit UDAW.Timeline.FxPresets;
{$I udaw.inc}

{ The fixed-setting effects of the Timeline's Effects menu, by menu tag: the effect's kind, its
  starting settings ("key=value;key=value") and its display name. The same presets the Mixer
  tab's insert palette offers. The Timeline menu, the effect editor and the instrument editor
  all read them from here. Effects that ask for a value first (Amplify, Balance, ...) are
  listed by FxExtraPresets. UI-free. }

interface

type
  TFxPresetInfo = record
    Name: string;
    Kind: string;
    Params: string;
  end;

const
  FX_PRESET_MAX_TAG = 130;

{ False when ATag is not a fixed-setting effect }
function FxPresetByTag(ATag: Integer; out AKind, AParams, AName: string): Boolean;

{ every fixed-setting effect, in menu-tag order }
function FxPresetList: TArray<TFxPresetInfo>;

{ the effects that start from a value of their own, with a sensible first value }
function FxExtraPresets: TArray<TFxPresetInfo>;

implementation

function FxPresetByTag(ATag: Integer; out AKind, AParams, AName: string): Boolean;
begin
  Result := True;
  case ATag of
    1: begin AKind := 'compressor'; AParams := 'type=compressor;thresh=-18;ratio=3;knee=6;attack=10;release=120;makeup=0'; AName := 'Compressor'; end;
    2: begin AKind := 'reverb'; AParams := 'size=0.7;damp=0.4;width=1;mix=0.3;predelay=15'; AName := 'Reverb'; end;
    3: begin AKind := 'modulation'; AParams := 'type=chorus;rate=0.6;depth=0.6;mix=0.4;stereo=90'; AName := 'Chorus'; end;
    4: begin AKind := 'modulation'; AParams := 'type=flanger;rate=0.25;depth=0.7;mix=0.5;fb=0.4;stereo=90'; AName := 'Flanger'; end;
    5: begin AKind := 'modulation'; AParams := 'type=phaser;rate=0.4;depth=0.8;mix=0.5;fb=0.3;stages=6;stereo=90'; AName := 'Phaser'; end;
    6: begin AKind := 'modulation'; AParams := 'type=tremolo;rate=4;depth=0.6;mix=1'; AName := 'Tremolo'; end;
    7: begin AKind := 'modulation'; AParams := 'type=autopan;rate=0.5;depth=1;mix=1'; AName := 'Auto-Pan'; end;
    8: begin AKind := 'distortion'; AParams := 'type=saturation;drive=3;trim=0;mix=1'; AName := 'Saturation'; end;
    9: begin AKind := 'distortion'; AParams := 'type=bitcrush;bits=8;down=4;mix=1'; AName := 'Bit Crusher'; end;
    10: begin AKind := 'graphiceq'; AParams := 'bands=10;gains=0,0,1,2,3,3,2,1,0,0'; AName := 'Brighten EQ'; end;
    13: begin AKind := 'compressor'; AParams := 'type=deesser;thresh=-24;ratio=4;knee=3;attack=1;release=80;makeup=0'; AName := 'De-Esser'; end;
    14: begin AKind := 'delay'; AParams := 'ms=250;fb=0.3;mix=0.3;pingpong=0'; AName := 'Delay'; end;
    15: begin AKind := 'compressor'; AParams := 'type=expander;thresh=-30;ratio=2;knee=6;attack=5;release=100;makeup=0'; AName := 'Expander'; end;
    16: begin AKind := 'distortion'; AParams := 'type=foldback;drive=3;trim=0;mix=1'; AName := 'Foldback'; end;
    17: begin AKind := 'compressor'; AParams := 'type=gate;thresh=-40;ratio=6;knee=2;attack=1;release=60;makeup=0;hold=15;range=-60'; AName := 'Gate'; end;
    18: begin AKind := 'distortion'; AParams := 'type=hardclip;drive=3;trim=0;mix=1'; AName := 'Hard Clip'; end;
    19: begin AKind := 'lookaheadlimiter'; AParams := 'ceiling=-0.3;release=100;lookahead=5'; AName := 'Limiter'; end;
    20: begin AKind := 'delay'; AParams := 'ms=250;fb=0.35;mix=0.35;pingpong=1'; AName := 'Ping-Pong Delay'; end;
    22: begin AKind := 'biquad'; AParams := 'type=lowshelf;freq=100;q=0.707;gaindb=6'; AName := 'Bass Enhance'; end;
    23: begin AKind := 'dcblock'; AParams := 'hz=20'; AName := 'DC Offset Remover'; end;
    24: begin AKind := 'exciter'; AParams := 'freq=3000;drive=4;mix=0.25'; AName := 'Exciter'; end;
    25: begin AKind := 'biquad'; AParams := 'type=highpass;freq=80;q=0.707;gaindb=0'; AName := 'High-Pass Filter'; end;
    26: begin AKind := 'biquad'; AParams := 'type=lowpass;freq=8000;q=0.707;gaindb=0'; AName := 'Low-Pass Filter'; end;
    27: begin AKind := 'stereowidth'; AParams := 'width=0'; AName := 'Make Mono'; end;
    28: begin AKind := 'multibandcomp'; AParams := ''; AName := 'Multiband Compressor'; end;
    29: begin AKind := 'biquad'; AParams := 'type=notch;freq=60;q=8;gaindb=0'; AName := 'Notch Filter'; end;
    31: begin AKind := 'biquad'; AParams := 'type=peaking;freq=3000;q=1;gaindb=4'; AName := 'Presence Boost'; end;
    32: begin AKind := 'stereowidth'; AParams := 'width=1.5'; AName := 'Stereo Widener'; end;
    33: begin AKind := 'transientshaper'; AParams := 'attack=6;sustain=0'; AName := 'Transient Shaper'; end;
    34: begin AKind := 'biquad'; AParams := 'type=highshelf;freq=8000;q=0.707;gaindb=6'; AName := 'Treble Boost'; end;
    40: begin AKind := 'distortion'; AParams := 'type=tube;drive=3;trim=0;mix=1'; AName := 'Tube Saturation'; end;
    41: begin AKind := 'distortion'; AParams := 'type=softclip;drive=2;trim=0;mix=1'; AName := 'Soft Clip'; end;
    42: begin AKind := '@echo'; AParams := 'ms=380;fb=0.45;mix=0.35'; AName := 'Echo'; end;
    43: begin AKind := '@swaplr'; AParams := ''; AName := 'Swap Channels'; end;
    44: begin AKind := '@invertphase'; AParams := ''; AName := 'Invert Phase'; end;
    45: begin AKind := '@ringmod'; AParams := 'freq=440;mix=0.6'; AName := 'Ring Modulator'; end;
    46: begin AKind := '@vibrato'; AParams := 'rate=5.5;depth=3'; AName := 'Vibrato'; end;
    47: begin AKind := '@vocalchannel'; AParams := 'amt=1'; AName := 'Vocal Channel'; end;
    48: begin AKind := '@dialogueleveler'; AParams := 'target=-20'; AName := 'Dialogue Leveler'; end;
    49: begin AKind := '@loudnorm'; AParams := 'lufs=-16'; AName := 'Loudness Normalize'; end;
    50: begin AKind := '@dehum'; AParams := 'hz=50'; AName := 'De-Hummer 50 Hz'; end;
    51: begin AKind := '@dehum'; AParams := 'hz=60'; AName := 'De-Hummer 60 Hz'; end;
    52: begin AKind := '@declick'; AParams := 'sens=9'; AName := 'De-Clicker'; end;
    53: begin AKind := '@declip'; AParams := ''; AName := 'De-Clipper'; end;
    54: begin AKind := '@bandpass'; AParams := 'freq=1000;q=1.2'; AName := 'Band-Pass Filter'; end;
    55: begin AKind := '@telephone'; AParams := ''; AName := 'Telephone'; end;
    56: begin AKind := 'delay'; AParams := 'ms=90;fb=0.1;mix=0.3;pingpong=0'; AName := 'Slapback Delay'; end;
    57: begin AKind := 'distortion'; AParams := 'type=bitcrush;bits=12;down=2;mix=1'; AName := 'Lo-Fi'; end;
    58: begin AKind := 'reverb'; AParams := 'size=0.9;damp=0.3;width=1;mix=0.35;predelay=30'; AName := 'Hall Reverb'; end;
    59: begin AKind := 'reverb'; AParams := 'size=0.35;damp=0.5;width=0.8;mix=0.25;predelay=5'; AName := 'Room Reverb'; end;
    60: begin AKind := 'reverb'; AParams := 'size=0.6;damp=0.2;width=1;mix=0.3;predelay=10'; AName := 'Plate Reverb'; end;
    61: begin AKind := '@stereofixer'; AParams := 'width=1;fixphase=1;fixbalance=1'; AName := 'Stereo Fixer'; end;
    62: begin AKind := '@midside'; AParams := 'mid=0;side=-3'; AName := 'Mid/Side Balance'; end;
    63: begin AKind := '@crossfeed'; AParams := 'amt=0.3'; AName := 'Headphone Crossfeed'; end;
    64: begin AKind := '@lfefilter'; AParams := 'hz=120'; AName := 'LFE Filter'; end;
    65: begin AKind := '@subbass'; AParams := 'mix=0.5;hz=80'; AName := 'Sub Bass Synth'; end;
    66: begin AKind := '@freqshift'; AParams := 'hz=50;mix=1'; AName := 'Frequency Shifter'; end;
    67: begin AKind := '@autowah'; AParams := 'sens=0.8;q=4'; AName := 'Auto-Wah'; end;
    68: begin AKind := '@robot'; AParams := ''; AName := 'Robot Voice'; end;
    69: begin AKind := '@megaphone'; AParams := ''; AName := 'Megaphone'; end;
    70: begin AKind := '@underwater'; AParams := ''; AName := 'Underwater'; end;
    71: begin AKind := '@tapestop'; AParams := 'ms=1500'; AName := 'Tape Stop'; end;
    72: begin AKind := '@gater'; AParams := 'rate=8;depth=1;duty=0.5'; AName := 'Trance Gate'; end;
    73: begin AKind := '@rotary'; AParams := 'rate=0.8;depth=0.5'; AName := 'Rotary Speaker'; end;
    74: begin AKind := '@vinyl'; AParams := 'amt=0.5'; AName := 'Vinyl Crackle'; end;
    75: begin AKind := '@comb'; AParams := 'ms=5;fb=0.6;mix=0.5'; AName := 'Comb Filter'; end;
    76: begin AKind := '@peaknorm'; AParams := 'peak=-1'; AName := 'Peak Normalize'; end;
    77: begin AKind := '@vocoder'; AParams := 'bands=16;pitch=110;mix=1'; AName := 'Vocoder'; end;
    78: begin AKind := '@wahwah'; AParams := 'rate=0.8;depth=0.9;q=5'; AName := 'Wah-Wah'; end;
    79: begin AKind := '@autofilter'; AParams := 'rate=0.4;depth=0.8;q=3'; AName := 'Auto-Filter'; end;
    80: begin AKind := '@formant'; AParams := 'vowel=0'; AName := 'Vowel Filter (Ah)'; end;
    81: begin AKind := '@formant'; AParams := 'vowel=1'; AName := 'Vowel Filter (Eh)'; end;
    82: begin AKind := '@formant'; AParams := 'vowel=2'; AName := 'Vowel Filter (Ee)'; end;
    83: begin AKind := '@formant'; AParams := 'vowel=3'; AName := 'Vowel Filter (Oh)'; end;
    84: begin AKind := '@formant'; AParams := 'vowel=4'; AName := 'Vowel Filter (Oo)'; end;
    85: begin AKind := '@haas'; AParams := 'ms=18'; AName := 'Haas Widener'; end;
    86: begin AKind := '@monobass'; AParams := 'hz=120'; AName := 'Mono Bass'; end;
    87: begin AKind := '@vocalremove'; AParams := 'amt=1;keepbass=1'; AName := 'Vocal Remover'; end;
    88: begin AKind := '@tape'; AParams := ''; AName := 'Tape Wow & Flutter'; end;
    89: begin AKind := '@radio'; AParams := ''; AName := 'AM Radio'; end;
    90: begin AKind := '@fuzz'; AParams := 'drive=25'; AName := 'Fuzz'; end;
    91: begin AKind := '@rectifier'; AParams := 'mix=0.6'; AName := 'Octave-Up Rectifier'; end;
    92: begin AKind := '@ensemble'; AParams := ''; AName := 'String Ensemble'; end;
    93: begin AKind := '@multitap'; AParams := 'ms=600;mix=0.5'; AName := 'Multi-Tap Delay'; end;
    94: begin AKind := '@tapedelay'; AParams := 'ms=350;fb=0.5;mix=0.35'; AName := 'Tape Delay'; end;
    95: begin AKind := '@stutter'; AParams := 'ms=250;rep=4'; AName := 'Stutter'; end;
    96: begin AKind := '@parallelcomp'; AParams := 'mix=0.5'; AName := 'Parallel Compression'; end;
    97: begin AKind := '@tilteq'; AParams := 'tilt=3'; AName := 'Tilt EQ (Brighter)'; end;
    98: begin AKind := '@tilteq'; AParams := 'tilt=-3'; AName := 'Tilt EQ (Darker)'; end;
    99: begin AKind := '@depop'; AParams := 'amt=1;hz=150'; AName := 'De-Popper (Plosive Remover)'; end;
    100: begin AKind := '@levelrider'; AParams := 'target=-20;range=6;ms=400'; AName := 'Level Rider'; end;
    101: begin AKind := '@dialogrider'; AParams := 'target=-20;range=9;ms=300;gate=-55'; AName := 'Dialog Rider'; end;
    102: begin AKind := '@tplimiter'; AParams := 'ceiling=-1;look=5;release=100'; AName := 'True-Peak Limiter'; end;
    103: begin AKind := '@oversat'; AParams := 'drive=3;mix=1'; AName := 'Oversampled Saturation'; end;
    104: begin AKind := '@adaptivedenoise'; AParams := 'reduce=12'; AName := 'Adaptive Noise Reduction'; end;
    105: begin AKind := '@fadecurve'; AParams := 'shape=1;out=0'; AName := 'Fade In (S-Curve)'; end;
    106: begin AKind := '@fadecurve'; AParams := 'shape=2;out=0'; AName := 'Fade In (Equal Power)'; end;
    107: begin AKind := '@fadecurve'; AParams := 'shape=3;out=0'; AName := 'Fade In (Exponential)'; end;
    108: begin AKind := '@fadecurve'; AParams := 'shape=4;out=0'; AName := 'Fade In (Logarithmic)'; end;
    109: begin AKind := '@fadecurve'; AParams := 'shape=1;out=1'; AName := 'Fade Out (S-Curve)'; end;
    110: begin AKind := '@fadecurve'; AParams := 'shape=2;out=1'; AName := 'Fade Out (Equal Power)'; end;
    111: begin AKind := '@fadecurve'; AParams := 'shape=3;out=1'; AName := 'Fade Out (Exponential)'; end;
    112: begin AKind := '@fadecurve'; AParams := 'shape=4;out=1'; AName := 'Fade Out (Logarithmic)'; end;
    115: begin AKind := '@voiceisolate'; AParams := 'strength=0.6'; AName := 'Voice Isolation'; end;
    116: begin AKind := '@musicextract'; AParams := 'strength=0.6'; AName := 'Music Separator'; end;
  else
    AKind := ''; AParams := ''; AName := '';
    Result := False;
  end;
end;

function FxPresetList: TArray<TFxPresetInfo>;
var
  tag, n: Integer;
  k, p, nm: string;
begin
  SetLength(Result, FX_PRESET_MAX_TAG);
  n := 0;
  for tag := 1 to FX_PRESET_MAX_TAG do
    if FxPresetByTag(tag, k, p, nm) then
    begin
      Result[n].Name := nm;
      Result[n].Kind := k;
      Result[n].Params := p;
      Inc(n);
    end;
  SetLength(Result, n);
end;

function FxExtraPresets: TArray<TFxPresetInfo>;

  function Make(const AName, AKind, AParams: string): TFxPresetInfo;
  begin
    Result.Name := AName;
    Result.Kind := AKind;
    Result.Params := AParams;
  end;

begin
  Result := [
    Make('Amplify', 'gain', 'db=6'),
    Make('Balance', 'pan', 'pos=0'),
    Make('Pitch Shift', 'pitchshift', 'semitones=2'),
    Make('Noise Reduction', '@denoise', 'reduce=12'),
    Make('Fade In', '@fadein', ''),
    Make('Fade Out', '@fadeout', '')];
end;

end.
