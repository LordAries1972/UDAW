program UDAW.Tests;

{ Delphi 12 console test runner for Phases 1-2.
  Build:  dcc64 -B -E..\build\bin UDAW.Tests.dpr
  (the build/test scripts add the src\common and src\audio search paths). }

{$APPTYPE CONSOLE}

uses
  SysUtils,
  UDAW.Types in '..\src\common\UDAW.Types.pas',
  UDAW.Errors in '..\src\common\UDAW.Errors.pas',
  UDAW.Platform in '..\src\common\UDAW.Platform.pas',
  UDAW.Paths in '..\src\common\UDAW.Paths.pas',
  UDAW.Threading in '..\src\common\UDAW.Threading.pas',
  UDAW.Logging in '..\src\common\UDAW.Logging.pas',
  UDAW.Config in '..\src\common\UDAW.Config.pas',
  UDAW.Jobs in '..\src\common\UDAW.Jobs.pas',
  UDAW.SecureStorage in '..\src\common\UDAW.SecureStorage.pas',
  UDAW.Audio.Types in '..\src\audio\UDAW.Audio.Types.pas',
  UDAW.Audio.Buffer in '..\src\audio\UDAW.Audio.Buffer.pas',
  UDAW.Audio.Ring in '..\src\audio\UDAW.Audio.Ring.pas',
  UDAW.Audio.Source in '..\src\audio\UDAW.Audio.Source.pas',
  UDAW.Audio.Offline in '..\src\audio\UDAW.Audio.Offline.pas',
  UDAW.Audio.Device in '..\src\audio\UDAW.Audio.Device.pas',
  UDAW.Audio.Backend.Software in '..\src\audio\backend\UDAW.Audio.Backend.Software.pas',
  UDAW.Audio.Backend.WASAPI in '..\src\audio\backend\UDAW.Audio.Backend.WASAPI.pas',
  UDAW.Audio.Backend.DirectSound in '..\src\audio\backend\UDAW.Audio.Backend.DirectSound.pas',
  UDAW.Audio.Backend.Factory in '..\src\audio\UDAW.Audio.Backend.Factory.pas',
  UDAW.Audio.Engine in '..\src\audio\UDAW.Audio.Engine.pas',
  UDAW.DSP.MathTables in '..\src\audio\dsp\UDAW.DSP.MathTables.pas',
  UDAW.DSP.Math in '..\src\audio\dsp\UDAW.DSP.Math.pas',
  UDAW.DSP.Interpolation in '..\src\audio\dsp\UDAW.DSP.Interpolation.pas',
  UDAW.DSP.Filters in '..\src\audio\dsp\UDAW.DSP.Filters.pas',
  UDAW.DSP.FFT in '..\src\audio\dsp\UDAW.DSP.FFT.pas',
  UDAW.DSP.Resampler in '..\src\audio\dsp\UDAW.DSP.Resampler.pas',
  UDAW.DSP.Envelope in '..\src\audio\dsp\UDAW.DSP.Envelope.pas',
  UDAW.DSP.Meter in '..\src\audio\dsp\UDAW.DSP.Meter.pas',
  UDAW.DSP.Dynamics in '..\src\audio\dsp\UDAW.DSP.Dynamics.pas',
  UDAW.DSP.CurveMath in '..\src\audio\dsp\UDAW.DSP.CurveMath.pas',
  UDAW.DSP.Modulation in '..\src\audio\dsp\UDAW.DSP.Modulation.pas',
  UDAW.DSP.Distortion in '..\src\audio\dsp\UDAW.DSP.Distortion.pas',
  UDAW.DSP.Reverb in '..\src\audio\dsp\UDAW.DSP.Reverb.pas',
  UDAW.DSP.GraphicEQ in '..\src\audio\dsp\UDAW.DSP.GraphicEQ.pas',
  UDAW.DSP.Visualization in '..\src\audio\dsp\UDAW.DSP.Visualization.pas',
  UDAW.DSP.MultibandComp in '..\src\audio\dsp\UDAW.DSP.MultibandComp.pas',
  UDAW.DSP.Mastering in '..\src\audio\dsp\UDAW.DSP.Mastering.pas',
  UDAW.DSP.TimeStretch in '..\src\audio\dsp\UDAW.DSP.TimeStretch.pas',
  UDAW.DSP.TempoDetect in '..\src\audio\dsp\UDAW.DSP.TempoDetect.pas',
  UDAW.DSP.PitchShift in '..\src\audio\dsp\UDAW.DSP.PitchShift.pas',
  UDAW.DSP.ParametricEQ in '..\src\audio\dsp\UDAW.DSP.ParametricEQ.pas',
  UDAW.DSP.StereoWidth in '..\src\audio\dsp\UDAW.DSP.StereoWidth.pas',
  UDAW.DSP.TransientShaper in '..\src\audio\dsp\UDAW.DSP.TransientShaper.pas',
  UDAW.DSP.Delay in '..\src\audio\dsp\UDAW.DSP.Delay.pas',
  UDAW.DSP.Dither in '..\src\audio\dsp\UDAW.DSP.Dither.pas',
  UDAW.DSP.Spectral in '..\src\audio\dsp\UDAW.DSP.Spectral.pas',
  UDAW.Sequencer.Patterns in '..\src\sequencer\UDAW.Sequencer.Patterns.pas',
  UDAW.Pattern.Model in '..\src\sequencer\UDAW.Pattern.Model.pas',
  UDAW.Pattern.Commands in '..\src\sequencer\UDAW.Pattern.Commands.pas',
  UDAW.Drum.KitModel in '..\src\sequencer\UDAW.Drum.KitModel.pas',
  UDAW.Synth.Instruments in '..\src\synth\UDAW.Synth.Instruments.pas',
  UDAW.Mixer.Modulation in '..\src\mixer\UDAW.Mixer.Modulation.pas',
  UDAW.Mixer.CLAP in '..\src\mixer\UDAW.Mixer.CLAP.pas',
  UDAW.Mixer.VST3 in '..\src\mixer\UDAW.Mixer.VST3.pas',
  UDAW.DSP.AudioToMidi in '..\src\audio\dsp\UDAW.DSP.AudioToMidi.pas',
  UDAW.Timeline.ExtraFx in '..\src\timeline\UDAW.Timeline.ExtraFx.pas',
  UDAW.Timeline.SpectralFx in '..\src\timeline\UDAW.Timeline.SpectralFx.pas',
  UDAW.Timeline.Warp in '..\src\timeline\UDAW.Timeline.Warp.pas',
  UDAW.DSP.Exciter in '..\src\audio\dsp\UDAW.DSP.Exciter.pas',
  UDAW.DSP.LookaheadLimiter in '..\src\audio\dsp\UDAW.DSP.LookaheadLimiter.pas',
  UDAW.Audio.Graph.Nodes in '..\src\audio\graph\UDAW.Audio.Graph.Nodes.pas',
  UDAW.Audio.Graph in '..\src\audio\graph\UDAW.Audio.Graph.pas',
  UDAW.Audio.Graph.Serializer in '..\src\audio\graph\UDAW.Audio.Graph.Serializer.pas',
  UDAW.Codec.WAV in '..\src\codecs\pcm\UDAW.Codec.WAV.pas',
  UDAW.Codec.MP3.Frame in '..\src\codecs\mp3\UDAW.Codec.MP3.Frame.pas',
  UDAW.Codec.MP3.Tables in '..\src\codecs\mp3\UDAW.Codec.MP3.Tables.pas',
  UDAW.Codec.MP3.Decoder in '..\src\codecs\mp3\UDAW.Codec.MP3.Decoder.pas',
  UDAW.Codec.MP3.Encoder in '..\src\codecs\mp3\UDAW.Codec.MP3.Encoder.pas',
  UDAW.Codec.MP3.Metadata in '..\src\codecs\mp3\UDAW.Codec.MP3.Metadata.pas',
  UDAW.Codec.MP3 in '..\src\codecs\mp3\UDAW.Codec.MP3.pas',
  UDAW.Codec.MP3.Source in '..\src\codecs\mp3\UDAW.Codec.MP3.Source.pas',
  UDAW.Codec.MP3.Timeline in '..\src\codecs\mp3\UDAW.Codec.MP3.Timeline.pas',
  UDAW.Codec.FLAC.Frame in '..\src\codecs\flac\UDAW.Codec.FLAC.Frame.pas',
  UDAW.Codec.FLAC.Decoder in '..\src\codecs\flac\UDAW.Codec.FLAC.Decoder.pas',
  UDAW.Codec.FLAC.Encoder in '..\src\codecs\flac\UDAW.Codec.FLAC.Encoder.pas',
  UDAW.Codec.FLAC in '..\src\codecs\flac\UDAW.Codec.FLAC.pas',
  UDAW.Codec.FLAC.Source in '..\src\codecs\flac\UDAW.Codec.FLAC.Source.pas',
  UDAW.Codec.FLAC.Timeline in '..\src\codecs\flac\UDAW.Codec.FLAC.Timeline.pas',
  UDAW.Codec.Ableton in '..\src\codecs\ableton\UDAW.Codec.Ableton.pas',
  UDAW.Codec.Ableton.Timeline in '..\src\codecs\ableton\UDAW.Codec.Ableton.Timeline.pas',
  UDAW.Codec.AAC.Types in '..\src\codecs\aac\UDAW.Codec.AAC.Types.pas',
  UDAW.Codec.AAC.Tables in '..\src\codecs\aac\UDAW.Codec.AAC.Tables.pas',
  UDAW.Codec.AAC.Decoder in '..\src\codecs\aac\UDAW.Codec.AAC.Decoder.pas',
  UDAW.Codec.AAC in '..\src\codecs\aac\UDAW.Codec.AAC.pas',
  UDAW.Codec.MP4.Atoms in '..\src\codecs\mp4\UDAW.Codec.MP4.Atoms.pas',
  UDAW.Codec.MP4.Container in '..\src\codecs\mp4\UDAW.Codec.MP4.Container.pas',
  UDAW.Codec.MP4 in '..\src\codecs\mp4\UDAW.Codec.MP4.pas',
  UDAW.MIDI.Types in '..\src\midi\UDAW.MIDI.Types.pas',
  UDAW.MIDI.SMF in '..\src\midi\UDAW.MIDI.SMF.pas',
  UDAW.MIDI.Sequence in '..\src\midi\UDAW.MIDI.Sequence.pas',
  UDAW.MIDI.PianoRoll in '..\src\midi\UDAW.MIDI.PianoRoll.pas',
  UDAW.MIDI.Engine in '..\src\midi\UDAW.MIDI.Engine.pas',
  UDAW.MIDI.Serialization in '..\src\midi\UDAW.MIDI.Serialization.pas',
  UDAW.MIDI.Hardware in '..\src\midi\UDAW.MIDI.Hardware.pas',
  UDAW.MIDI.Capture in '..\src\midi\UDAW.MIDI.Capture.pas',
  UDAW.Composer.SongSpec in '..\src\composer\UDAW.Composer.SongSpec.pas',
  UDAW.Composer.Lyrics in '..\src\composer\UDAW.Composer.Lyrics.pas',
  UDAW.Composer.Validation in '..\src\composer\UDAW.Composer.Validation.pas',
  UDAW.Composer.Serialization in '..\src\composer\UDAW.Composer.Serialization.pas',
  UDAW.Composer.Commands in '..\src\composer\UDAW.Composer.Commands.pas',
  UDAW.Browser.Catalogue in '..\src\browser\UDAW.Browser.Catalogue.pas',
  UDAW.Timeline.Time in '..\src\timeline\UDAW.Timeline.Time.pas',
  UDAW.Timeline.Waveform in '..\src\timeline\UDAW.Timeline.Waveform.pas',
  UDAW.Timeline.Model in '..\src\timeline\UDAW.Timeline.Model.pas',
  UDAW.Timeline.Serialization in '..\src\timeline\UDAW.Timeline.Serialization.pas',
  UDAW.Timeline.View in '..\src\timeline\UDAW.Timeline.View.pas',
  UDAW.Mixer.Model in '..\src\mixer\UDAW.Mixer.Model.pas',
  UDAW.Mixer.Automation in '..\src\mixer\UDAW.Mixer.Automation.pas',
  UDAW.Mixer.Serialization in '..\src\mixer\UDAW.Mixer.Serialization.pas',
  UDAW.Mixer.Engine in '..\src\mixer\UDAW.Mixer.Engine.pas',
  UDAW.Mixer.VST2 in '..\src\mixer\UDAW.Mixer.VST2.pas',
  UDAW.Tracker.Types in '..\src\tracker\UDAW.Tracker.Types.pas',
  UDAW.Tracker.Instrument in '..\src\tracker\UDAW.Tracker.Instrument.pas',
  UDAW.Tracker.Pattern in '..\src\tracker\UDAW.Tracker.Pattern.pas',
  UDAW.Tracker.Player in '..\src\tracker\UDAW.Tracker.Player.pas',
  UDAW.Tracker.ScoreNotes in '..\src\tracker\UDAW.Tracker.ScoreNotes.pas',
  UDAW.Tracker.Serialization in '..\src\tracker\UDAW.Tracker.Serialization.pas',
  UDAW.Codec.ProTracker in '..\src\codecs\tracker\UDAW.Codec.ProTracker.pas',
  UDAW.Codec.XM in '..\src\codecs\tracker\UDAW.Codec.XM.pas',
  UDAW.Codec.MPTM in '..\src\codecs\tracker\UDAW.Codec.MPTM.pas',
  UDAW.Codec.TrackerLegacy in '..\src\codecs\tracker\UDAW.Codec.TrackerLegacy.pas',
  UDAW.Codec.FLStudio in '..\src\codecs\flstudio\UDAW.Codec.FLStudio.pas',
  UDAW.Codec.FLStudio.Timeline in '..\src\codecs\flstudio\UDAW.Codec.FLStudio.Timeline.pas',
  UDAW.Project.Document in '..\src\project\UDAW.Project.Document.pas',
  UDAW.Project.Serialization in '..\src\project\UDAW.Project.Serialization.pas',
  UDAW.Project.Commands in '..\src\project\UDAW.Project.Commands.pas',
  UDAW.Project.Recovery in '..\src\project\UDAW.Project.Recovery.pas',
  UDAW.Timeline.Commands in '..\src\timeline\UDAW.Timeline.Commands.pas',
  UDAW.Timeline.Playback in '..\src\timeline\UDAW.Timeline.Playback.pas',
  UDAW.Mixer.Commands in '..\src\mixer\UDAW.Mixer.Commands.pas',
  UDAW.Tracker.Commands in '..\src\tracker\UDAW.Tracker.Commands.pas',
  UDAW.MIDI.Commands in '..\src\midi\UDAW.MIDI.Commands.pas',
  UDAW.Recording.Types in '..\src\recording\UDAW.Recording.Types.pas',
  UDAW.Recording.ChunkFile in '..\src\recording\UDAW.Recording.ChunkFile.pas',
  UDAW.Recording.Engine in '..\src\recording\UDAW.Recording.Engine.pas',
  UDAW.Recording.Writer in '..\src\recording\UDAW.Recording.Writer.pas',
  UDAW.Recording.Takes in '..\src\recording\UDAW.Recording.Takes.pas',
  UDAW.Recording.Recovery in '..\src\recording\UDAW.Recording.Recovery.pas',
  UDAW.Recording.Commands in '..\src\recording\UDAW.Recording.Commands.pas',
  UDAW.AI.JSON in '..\src\ai\UDAW.AI.JSON.pas',
  UDAW.AI.Credentials in '..\src\ai\UDAW.AI.Credentials.pas',
  UDAW.AI.RateLimiter in '..\src\ai\UDAW.AI.RateLimiter.pas',
  UDAW.AI.SecureLog in '..\src\ai\UDAW.AI.SecureLog.pas',
  UDAW.AI.HTTP in '..\src\ai\UDAW.AI.HTTP.pas',
  UDAW.AI.Types in '..\src\ai\UDAW.AI.Types.pas',
  UDAW.AI.MCP in '..\src\ai\UDAW.AI.MCP.pas',
  UDAW.AI.OpenAI in '..\src\ai\UDAW.AI.OpenAI.pas',
  UDAW.AI.Claude in '..\src\ai\UDAW.AI.Claude.pas',
  UDAW.AI.DeepSeek in '..\src\ai\UDAW.AI.DeepSeek.pas',
  UDAW.AI.Providers in '..\src\ai\UDAW.AI.Providers.pas',
  UDAW.AI.Suno in '..\src\ai\UDAW.AI.Suno.pas',
  UDAW.Voice.Command in '..\src\voice\UDAW.Voice.Command.pas',
  UDAW.Testing in 'UDAW.Testing.pas',
  Tests.Phase1 in 'Tests.Phase1.pas',
  Tests.Phase2 in 'Tests.Phase2.pas',
  Tests.Phase3 in 'Tests.Phase3.pas',
  Tests.Phase4 in 'Tests.Phase4.pas',
  Tests.Phase5 in 'Tests.Phase5.pas',
  Tests.Phase6 in 'Tests.Phase6.pas',
  Tests.TimelineExport in 'Tests.TimelineExport.pas',
  Tests.VideoExport in 'Tests.VideoExport.pas',
  Tests.VideoEffects in 'Tests.VideoEffects.pas',
  Tests.ExtraFx in 'Tests.ExtraFx.pas',
  Tests.MediaDecode in 'Tests.MediaDecode.pas',
  Tests.Phase7 in 'Tests.Phase7.pas',
  Tests.Phase8 in 'Tests.Phase8.pas',
  Tests.Phase9 in 'Tests.Phase9.pas',
  Tests.Phase10 in 'Tests.Phase10.pas',
  Tests.Phase11 in 'Tests.Phase11.pas',
  Tests.Phase12 in 'Tests.Phase12.pas',
  Tests.Phase13 in 'Tests.Phase13.pas',
  Tests.Phase14 in 'Tests.Phase14.pas',
  Tests.Phase15 in 'Tests.Phase15.pas',
  Tests.PhaseFLAC in 'Tests.PhaseFLAC.pas',
  Tests.Phase16 in 'Tests.Phase16.pas',
  Tests.Phase16b in 'Tests.Phase16b.pas',
  Tests.Phase17 in 'Tests.Phase17.pas',
  Tests.Phase18 in 'Tests.Phase18.pas',
  Tests.Phase19 in 'Tests.Phase19.pas',
  Tests.Phase20 in 'Tests.Phase20.pas',
  Tests.Phase21 in 'Tests.Phase21.pas',
  Tests.Phase22 in 'Tests.Phase22.pas',
  Tests.Phase23 in 'Tests.Phase23.pas',
  Tests.Phase24 in 'Tests.Phase24.pas',
  Tests.Luma in 'Tests.Luma.pas',
  Tests.Phase25 in 'Tests.Phase25.pas',
  Tests.Phase26 in 'Tests.Phase26.pas',
  Tests.Phase26MCP in 'Tests.Phase26MCP.pas',
  Tests.Phase27 in 'Tests.Phase27.pas',
  Tests.Phase28 in 'Tests.Phase28.pas',
  Tests.Phase29 in 'Tests.Phase29.pas',
  Tests.Phase32 in 'Tests.Phase32.pas',
  Tests.Phase33 in 'Tests.Phase33.pas',
  Tests.Phase36 in 'Tests.Phase36.pas',
  Tests.Phase37 in 'Tests.Phase37.pas',
  Tests.Phase39 in 'Tests.Phase39.pas',
  Tests.Drum in 'Tests.Drum.pas',
  Tests.Pattern in 'Tests.Pattern.pas',
  Tests.Phase38 in 'Tests.Phase38.pas',
  Tests.DAWImportAbleton in 'Tests.DAWImportAbleton.pas',
  Tests.DAWImportFLStudio in 'Tests.DAWImportFLStudio.pas';

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
    RegisterVideoExportTests;
    RegisterVideoEffectsTests;
    RegisterExtraFxTests;
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
    RegisterMediaDecodeTests;
    RegisterPhase17Tests;
    RegisterPhase18Tests;
    RegisterPhase19Tests;
    RegisterPhase20Tests;
    RegisterPhase21Tests;
    RegisterPhase22Tests;
    RegisterPhase23Tests;
    RegisterPhase24Tests;
    RegisterLumaTests;
    RegisterPhase25Tests;
    RegisterPhase26Tests;
    RegisterPhase26MCPTests;
    RegisterPhase27Tests;
    RegisterPhase28Tests;
    RegisterPhase29Tests;
    RegisterPhase32Tests;
    RegisterPhase33Tests;
    RegisterPhase36Tests;
    RegisterPhase37Tests;
    RegisterPhase38Tests;
    RegisterPhase39Tests;
    RegisterDrumTests;
    RegisterPatternTests;
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
