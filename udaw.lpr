program udaw;

{ macOS / Linux executable (Lazarus / Free Pascal, LCL).
  The Windows build uses UDAW.dpr with Delphi 12. All units under src/common,
  src/application and src/ui are shared verbatim between the two toolchains. }

{$MODE DELPHI}{$H+}

uses
  UDAW.Compat in 'src\common\UDAW.Compat.pas',
  UDAW.Media.Attribution in 'src\common\UDAW.Media.Attribution.pas',
  UDAW.Media.Progress in 'src\common\UDAW.Media.Progress.pas',
  UDAW.Media.Transcode in 'src\common\UDAW.Media.Transcode.pas',
  UDAW.Timeline.Export in 'src\timeline\UDAW.Timeline.Export.pas',
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Interfaces, Forms, SysUtils,
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
  UDAW.Codec.AAC.Types, UDAW.Codec.AAC.Tables, UDAW.Codec.AAC.Decoder, UDAW.Codec.AAC,
  UDAW.Codec.MP4.Atoms, UDAW.Codec.MP4.Container, UDAW.Codec.MP4,
  UDAW.Codec.MP4.Source, UDAW.Codec.MP4.Timeline,
  UDAW.MIDI.Types, UDAW.MIDI.SMF, UDAW.MIDI.Sequence, UDAW.MIDI.PianoRoll,
  UDAW.MIDI.Engine, UDAW.MIDI.Serialization,
  UDAW.MIDI.Hardware, UDAW.MIDI.Capture,
  UDAW.Composer.SongSpec, UDAW.Composer.Lyrics, UDAW.Composer.Validation,
  UDAW.Composer.Serialization, UDAW.Composer.Commands,
  UDAW.Browser.Catalogue,
  UDAW.Timeline.Time, UDAW.Timeline.Waveform, UDAW.Timeline.Model,
  UDAW.Timeline.Serialization, UDAW.Timeline.View, UDAW.Timeline.Playback,
  UDAW.Mixer.Model, UDAW.Mixer.Serialization, UDAW.Mixer.Engine,
  UDAW.Tracker.Types, UDAW.Tracker.Instrument, UDAW.Tracker.Pattern,
  UDAW.Tracker.Player, UDAW.Tracker.Serialization,
  UDAW.Codec.ProTracker, UDAW.Codec.XM, UDAW.Codec.MPTM,
  UDAW.Project.Document, UDAW.Project.Serialization, UDAW.Project.Commands,
  UDAW.Project.Recovery,
  UDAW.Codec.MP3.Timeline,
  UDAW.Codec.FLStudio, UDAW.Codec.FLStudio.Timeline,
  UDAW.Timeline.Commands,
  UDAW.Mixer.Commands, UDAW.Tracker.Commands, UDAW.MIDI.Commands,
  UDAW.Recording.Types, UDAW.Recording.ChunkFile, UDAW.Recording.Engine,
  UDAW.Recording.Writer, UDAW.Recording.Takes, UDAW.Recording.Recovery,
  UDAW.Recording.Commands,
  UDAW.AI.JSON, UDAW.AI.Credentials, UDAW.AI.RateLimiter, UDAW.AI.SecureLog,
  UDAW.AI.HTTP, UDAW.AI.Types, UDAW.AI.MCP,
  UDAW.AI.OpenAI, UDAW.AI.Claude, UDAW.AI.DeepSeek, UDAW.AI.Providers,
  UDAW.AI.Suno,
  UDAW.AI.ToolCommands, UDAW.DSP.Analysis, UDAW.AI.Mixing, UDAW.AI.Mastering,
  UDAW.Voice.Command, UDAW.Voice.Capture, UDAW.Voice.Recognition,
  UDAW.App,
  UDAW.UI.Theme,
  UDAW.UI.ThemeColors,
  UDAW.UI.AboutForm,
  UDAW.UI.LogForm, UDAW.UI.MainForm;

{$R *.res}

var
  LCore: TUDAWApp;
begin
  RequireDerivedFormResource := True;
  Application.Scaled := True;
  Application.Title := 'Ultimanium Audio Studio';
  Application.Initialize;

  LCore := TUDAWApp.Create;
  SetApp(LCore);
  try
    try
      LCore.Initialize;
    except
      on E: Exception do
      begin
        Application.MessageBox(PChar('UDAW failed to start:'#10 + E.Message),
          'UDAW', 0);
        SetApp(nil);
        LCore.Free;
        Halt(1);
      end;
    end;

    Application.CreateForm(TfrmMain, frmMain);
    Application.Run;
  finally
    SetApp(nil);
    LCore.Free;
  end;
end.
