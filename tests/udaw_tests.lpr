program udaw_tests;

{ Free Pascal / Lazarus console test runner for Phases 1-2.
  Build:  fpc -MDelphi -Fu../src/common -Fu../src/audio -Fu../src/audio/backend \
              -Fi../src/common -FE../build/bin udaw_tests.lpr }

{$MODE DELPHI}{$H+}
{$APPTYPE CONSOLE}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils,
  UDAW.Types, UDAW.Errors, UDAW.Platform, UDAW.Paths, UDAW.Threading,
  UDAW.Logging, UDAW.Config, UDAW.Jobs, UDAW.SecureStorage,
  UDAW.Audio.Types, UDAW.Audio.Buffer, UDAW.Audio.Ring, UDAW.Audio.Source,
  UDAW.Audio.Offline, UDAW.Audio.Device, UDAW.Audio.Backend.Software,
  UDAW.Audio.Backend.WASAPI, UDAW.Audio.Backend.Factory, UDAW.Audio.Engine,
  UDAW.DSP.MathTables, UDAW.DSP.Math, UDAW.DSP.Interpolation, UDAW.DSP.Filters, UDAW.DSP.FFT,
  UDAW.DSP.Resampler, UDAW.DSP.Envelope, UDAW.DSP.Meter,
  UDAW.DSP.Dynamics, UDAW.DSP.Modulation, UDAW.DSP.Distortion,
  UDAW.DSP.Reverb, UDAW.DSP.GraphicEQ,
  UDAW.DSP.Visualization, UDAW.DSP.MultibandComp, UDAW.DSP.Mastering,
  UDAW.DSP.TimeStretch, UDAW.DSP.TempoDetect, UDAW.DSP.PitchShift,
  UDAW.Audio.Graph.Nodes, UDAW.Audio.Graph, UDAW.Audio.Graph.Serializer,
  UDAW.Codec.WAV,
  UDAW.Codec.MP3.Frame, UDAW.Codec.MP3.Tables, UDAW.Codec.MP3.Decoder,
  UDAW.Codec.MP3.Encoder, UDAW.Codec.MP3.Metadata, UDAW.Codec.MP3,
  UDAW.Codec.MP3.Source,
  UDAW.Codec.FLAC.Frame, UDAW.Codec.FLAC.Decoder, UDAW.Codec.FLAC.Encoder, UDAW.Codec.FLAC,
  UDAW.Codec.FLAC.Source, UDAW.Codec.FLAC.Timeline,
  UDAW.Codec.Ableton, UDAW.Codec.Ableton.Timeline,
  UDAW.Codec.AAC.Types, UDAW.Codec.AAC.Tables, UDAW.Codec.AAC.Decoder, UDAW.Codec.AAC,
  UDAW.Codec.MP4.Atoms, UDAW.Codec.MP4.Container, UDAW.Codec.MP4,
  UDAW.MIDI.Types, UDAW.MIDI.SMF, UDAW.MIDI.Sequence, UDAW.MIDI.PianoRoll,
  UDAW.MIDI.Engine, UDAW.MIDI.Serialization,
  UDAW.Composer.SongSpec, UDAW.Composer.Lyrics, UDAW.Composer.Validation,
  UDAW.Composer.Serialization, UDAW.Composer.Commands,
  UDAW.Browser.Catalogue,
  UDAW.Timeline.Time, UDAW.Timeline.Waveform, UDAW.Timeline.Model,
  UDAW.Timeline.Serialization, UDAW.Timeline.View,
  UDAW.Mixer.Model, UDAW.Mixer.Serialization, UDAW.Mixer.Engine,
  UDAW.Tracker.Types, UDAW.Tracker.Instrument, UDAW.Tracker.Pattern,
  UDAW.Tracker.Player, UDAW.Tracker.Serialization,
  UDAW.Codec.ProTracker, UDAW.Codec.XM, UDAW.Codec.MPTM,
  UDAW.Project.Document, UDAW.Project.Serialization, UDAW.Project.Commands,
  UDAW.Project.Recovery,
  UDAW.Codec.MP3.Timeline,
  UDAW.Codec.FLStudio, UDAW.Codec.FLStudio.Timeline,
  UDAW.Timeline.Commands, UDAW.Timeline.Playback,
  UDAW.Mixer.Commands, UDAW.Tracker.Commands, UDAW.MIDI.Commands,
  UDAW.Recording.Types, UDAW.Recording.ChunkFile, UDAW.Recording.Engine,
  UDAW.Recording.Writer, UDAW.Recording.Takes, UDAW.Recording.Recovery,
  UDAW.Recording.Commands,
  UDAW.AI.JSON, UDAW.AI.Credentials, UDAW.AI.RateLimiter, UDAW.AI.SecureLog,
  UDAW.AI.HTTP, UDAW.AI.Types, UDAW.AI.MCP,
  UDAW.AI.OpenAI, UDAW.AI.Claude, UDAW.AI.DeepSeek, UDAW.AI.Providers,
  UDAW.AI.Suno, UDAW.Voice.Command,
  UDAW.Testing, Tests.Phase1, Tests.Phase2, Tests.Phase3, Tests.Phase4,
  Tests.Phase5, Tests.Phase6, Tests.Phase7, Tests.TimelineExport, Tests.Phase8, Tests.Phase9, Tests.Phase10,
  Tests.Phase11, Tests.Phase12, Tests.Phase13, Tests.Phase14, Tests.Phase15,
  Tests.PhaseFLAC,
  Tests.Phase16, Tests.Phase16b, Tests.Phase17,
  Tests.Phase18, Tests.Phase19, Tests.Phase20, Tests.Phase21, Tests.Phase22,
  Tests.Phase23, Tests.Phase24, Tests.Phase25,
  Tests.Phase26, Tests.Phase26MCP, Tests.Phase27, Tests.Phase28, Tests.Phase29,
  Tests.Phase32, Tests.Phase33,
  Tests.DAWImportAbleton,
  Tests.DAWImportFLStudio;

begin
  try
    RegisterPhase1Tests;
    RegisterPhase2Tests;
    RegisterPhase3Tests;
    RegisterPhase4Tests;
    RegisterPhase5Tests;
    RegisterPhase6Tests;
    RegisterPhase7Tests;
    RegisterTimelineExportTests;
    RegisterPhase8Tests;
    RegisterPhase9Tests;
    RegisterPhase10Tests;
    RegisterPhase11Tests;
    RegisterPhase12Tests;
    RegisterPhase13Tests;
    RegisterPhase14Tests;
    RegisterPhase15Tests;
    RegisterPhaseFLACTests;
    RegisterPhase16Tests;
    RegisterPhase16bTests;
    RegisterPhase17Tests;
    RegisterPhase18Tests;
    RegisterPhase19Tests;
    RegisterPhase20Tests;
    RegisterPhase21Tests;
    RegisterPhase22Tests;
    RegisterPhase23Tests;
    RegisterPhase24Tests;
    RegisterPhase25Tests;
    RegisterPhase26Tests;
    RegisterPhase26MCPTests;
    RegisterPhase27Tests;
    RegisterPhase28Tests;
    RegisterPhase29Tests;
    RegisterPhase32Tests;
    RegisterPhase33Tests;
    RegisterDAWImportAbletonTests;
    RegisterDAWImportFLStudioTests;
    ExitCode := RunRegisteredTests;
  except
    on E: Exception do
    begin
      Writeln('FATAL: ', E.ClassName, ': ', E.Message);
      ExitCode := 2;
    end;
  end;
end.
