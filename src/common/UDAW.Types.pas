unit UDAW.Types;
{$I udaw.inc}

{ Core shared types and product constants used across every UDAW layer.
  This unit must not depend on any other UDAW unit. }

interface

uses
  SysUtils;

const
  UDAW_PRODUCT_NAME    = 'Ultimanium Digital Audio Workstation (UDAW)';
  UDAW_SHORT_NAME      = 'UDAW';
  UDAW_VENDOR_NAME     = 'Ultimanium';
  UDAW_AUTHOR_LINE     = 'Daniel J. Hobson of Australia, 2026';
  { The product version is "1.0.<build>.<dd/mm/yyyy>" - see UDAW.Version
    (UDAWDisplayVersionString) for the full scheme. UDAW_VERSION_MAJOR/MINOR
    are the fixed 1.0 prefix; the build number and date are read from the
    compiled executable's own resource/PE header at runtime, not stored as
    compile-time constants here, since they change on every build. }
  UDAW_VERSION_MAJOR   = 1;
  UDAW_VERSION_MINOR   = 0;
  UDAW_VERSION_PATCH   = 0;   // unused by the 1.0.<build>.<date> scheme; kept for source compat
  { Phase 26 - AI Tool Commands: a structured, validated command interface
    (UDAW.AI.ToolCommands) so an AI reply can drive the DAW through normal,
    undo-safe TDAWCommands instead of prose alone.
    Phase 27 - AI Mixing Assistant: UDAW.DSP.Analysis (local audio analysis,
    never raw PCM, sent to the AI) plus UDAW.AI.Mixing's Preview/Compare/
    Apply/Reject workflow over mixer-fader/pan/EQ suggestions.
    Phase 28 - AI Mastering Assistant: UDAW.AI.Mastering suggests a
    corrective-EQ + compressor + Phase 19 TMasteringChain chain on the
    master strip, with the same Preview/Compare/Apply/Reject workflow,
    always offering Original vs. AI Recommendation.
    Phase 29 - Theming: UDAW.UI.ThemeColors, a platform-independent semantic
    colour model (5 built-in themes + save/export/import/reset) driving the
    custom-drawn surfaces UDAW.UI.Theme's VCL-style skinning never reached.
    All four build on Phase 25's voice/AI-chat foundation and Phase 20's AI
    provider abstraction.

    Phase 30 adds a from-scratch FLAC decoder (src/codecs/flac): metadata +
    frame-header parsing, full subframe decode (CONSTANT/VERBATIM/FIXED/LPC),
    partitioned-Rice residual, all three stereo-decorrelation modes, and a
    facade + IAudioSource + timeline-import command mirroring the MP3 path.
    Decode-only - no FLAC encoder/writer.

    Phase 31 - Mixer feature suite: real VST2-ABI plugin hosting
    (UDAW.Mixer.VST2 - clean-room AEffect/dispatcher/host-callback, DLL
    load/scan/open/process/close, by-index parameters, chunk or per-parameter
    state persistence, native-editor or generic-parameter-list UI via
    UDAW.UI.VST2Editor) wired as a new nkVST2 graph-node insert kind;
    breakpoint automation (UDAW.Mixer.Automation) for fader/pan/mute/send-gain/
    hosted-plugin parameters, read live by TMixerProcessor and recorded from
    the Mixer tab's fader drag during touch/latch/write + playback; mixer-tab
    drag-and-drop strip and insert reorder, resizable strip width, a proper
    pmMixer context-menu sync; per-strip peak-hold/RMS/integrated-LUFS
    metering with configurable hold/decay and latching clip indicators, plus
    a master-bus loudness readout; and a real, undo-safe fader drag on
    pbMixer feeding TMixerEngine live. Also: an independent Timeline-tab
    master playback volume (TTimelinePlayer gain stage, separate from the
    Mixer's own master strip). Mixer document format -> v3 (METER + AUTO
    lines); Timeline document format -> v2 (MVOL line).

    Phase 32-33 begin implementing docs/AIPlan.md, the controlled AI
    composition pipeline (its own internal Phase 1/2 numbering - not to be
    confused with this constant). Phase 32 (src/composer): the Structured
    Song Specification data model (TSongSpec/TSongSection/TSongTrackSpec/
    TChordProgressionEntry), a lyric model (TLyricDocument - nothing existed
    for lyrics before this), a schema/consistency validator
    (TSongSpecValidator), undo-safe spec/lyric-mutation commands against the
    existing TCommandManager, and project-file embedding (AISPEC-BEGIN/END,
    format -> v6, additive/back-compatible). Phase 33 (src/browser): a
    local, tag-searchable instrument/sample/preset catalogue
    (TInstrumentCatalogue) with stable path-hash ids, missing-resource
    detection that marks rather than removes, and an AI-safe description
    view that never exposes a filesystem path - built on the existing
    Browser tab's folder-root concept and UDAW.AI.JSON, with new
    CFG_PATH_INSTRUMENTS/PRESETS/LOOPS/PLUGINS/SOUNDFONTS/VOCALS settings
    keys. Phase 34 adds AIPlan.md PHASE 3 (AI Provider Layer -
    UDAW.AI.Composer.TCompositionProvider, layered on the Phase 20-23
    IAIProvider chat providers) and PHASE 4 (Basic Arrangement Generation -
    UDAW.Composer.Arrangement.TArrangementEngine), so a validated TSongSpec
    can now be turned into real Timeline/Mixer/MIDI content. Phase 35 adds
    AIPlan.md PHASE 5 (Lyrics and Vocals - phrase/syllable timing,
    UDAW.Composer.VocalGuide guide-note generation) and PHASE 6 (Advanced
    Composition - melody generation, drum fills/transitions, section
    variations, automation, side-chaining, instrument-range clamping, all
    in TArrangementEngine.GenerateMidiForTrack/Execute). Phase 36 adds
    AIPlan.md PHASE 7 (Mixing Assistance - generalised frequency-conflict
    detection and real panning suggestions across analyzed strips
    (UDAW.AI.Mixing.SuggestFrequencyConflicts), gate/de-esser effect
    selection, and automation-ride recommendations from the song
    specification's section energy curve) and PHASE 8 (Conversational
    Revision - UDAW.AI.Revision.TAIRevisionSession: scoped revisions that
    preserve Locked sections/tracks (UDAW.Composer.SongSpec.Locked,
    UDAW.AI.Composer.MergeLockedAndOutOfScope), structured change-set
    preview (UDAW.Composer.RevisionHistory.DiffSongSpecs) and an in-memory
    accepted/rejected revision history). Phase 37 adds AIPlan.md PHASE 9
    (Testing and Optimisation - tests/Tests.Phase37.pas covering
    instrumental/lyrical projects, missing-instrument resolution, offline
    operation, provider failures, large arrangements, tempo/time-signature
    changes, undo/redo, project reopening across the AISPEC format, and
    deterministic regeneration) plus a real fix it found along the way:
    UDAW.Audio.Graph.Nodes.TVST2Node.Process now isolates a plugin that
    throws mid-processing instead of letting it take the audio engine down.
    Since Phase 37, the AI composition pipeline also prefers a real
    sample/loop from the instrument catalogue over generated MIDI for every
    track unless TSongTrackSpec.RequireMidi is explicitly set
    (UDAW.Composer.Arrangement.TApplyArrangementCommand.ResolveSampleOrLoop/
    PlaceSampleClips) - MIDI generation now only runs when actually
    requested, not as the default realisation for every track.

    Phase 38 redoes the MIDI subsystem's device story: real Windows MIDI
    hardware I/O (UDAW.MIDI.Hardware - winmm midiIn/midiOut device
    enumeration/open/close, an input device's driver-thread-safe event
    queue, an output device's short-message send and "all notes off"
    panic), live capture from an input device straight into a TMidiSequence
    (UDAW.MIDI.Capture.TMidiCaptureEngine), device selection persisted in
    the Settings tab (by device NAME, not driver index - see
    UDAW.MIDI.Hardware's CFG_SEC_MIDI constants), and - the part that was
    completely missing before - MIDI clips actually placed and heard on the
    Timeline: TMidiProject clips now carry a stable Id that survives
    deletion/reordering (UDAW.MIDI.Serialization, format bumped to v2, a v1
    file still loads with synthesised ids), a Timeline clip references one
    via a negative SourceId (UDAW.Timeline.Model.EncodeMidiSourceId/
    DecodeMidiSourceId/TTimelineClip.IsMidiClip), TTimelinePlayer.RenderBlock
    now renders every tkMidi/tkInstrument track's active clip through a
    per-clip TMidiPlaybackEngine plus an optional live-Thru monitor synth
    (UDAW.Timeline.Playback), and UDAW.MIDI.Commands.TCommitMidiTakeCommand
    drops a captured take onto the Timeline exactly like Phase 8's audio
    TCommitTakeCommand does. Tracker/Piano-Roll-only playback (Phase 17) is
    unchanged; this is additive. See docs/Phase38-MIDIDeviceIO.md. }
  UDAW_PHASE           = 38;

  { The desktop client's own web help centre. The server only serves this
    page to a caller sending Referer: UDAW/1.0 exactly (see
    F:\Projects\Web\EffectualDesigns\index.php, case "about-udaw", and
    library.php's CheckReferer) - anyone else, browsers included, gets 403. }
  UDAW_WEB_DOMAIN      = 'https://ultimanium.com';
  UDAW_HELP_URL        = UDAW_WEB_DOMAIN + '/index.php?action=about-udaw';
  UDAW_HELP_REFERER    = 'UDAW/1.0';

type
  { Result of an operation that can fail without necessarily raising. }
  TUDAWResult = record
    Success: Boolean;
    Code: Integer;
    Message: string;
    class function Ok: TUDAWResult; static;
    class function Fail(ACode: Integer; const AMessage: string): TUDAWResult; static;
  end;

  { A monotonic identifier handed out by subsystems (jobs, log sinks, ...). }
  TUDAWId = Int64;

function UDAWVersionString: string;
function UDAWFullVersionString: string;

implementation

class function TUDAWResult.Ok: TUDAWResult;
begin
  Result.Success := True;
  Result.Code := 0;
  Result.Message := '';
end;

class function TUDAWResult.Fail(ACode: Integer; const AMessage: string): TUDAWResult;
begin
  Result.Success := False;
  Result.Code := ACode;
  Result.Message := AMessage;
end;

function UDAWVersionString: string;
begin
  Result := Format('%d.%d.%d', [UDAW_VERSION_MAJOR, UDAW_VERSION_MINOR, UDAW_VERSION_PATCH]);
end;

function UDAWFullVersionString: string;
begin
  Result := Format('%s %s (phase %d)', [UDAW_SHORT_NAME, UDAWVersionString, UDAW_PHASE]);
end;

end.
