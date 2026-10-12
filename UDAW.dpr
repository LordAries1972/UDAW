program UDAW;

{ Windows 64-bit executable (Delphi 12 / VCL).
  macOS and Linux are built from udaw.lpr with Lazarus/FPC - the shared units
  under src\common and src\application compile unchanged on both toolchains. }

uses
  UDAW.Media.Attribution in 'src\common\UDAW.Media.Attribution.pas',
  UDAW.Media.Progress in 'src\common\UDAW.Media.Progress.pas',
  UDAW.Media.Transcode in 'src\common\UDAW.Media.Transcode.pas',
  UDAW.Timeline.Export in 'src\timeline\UDAW.Timeline.Export.pas',
  Vcl.Forms,
  Vcl.Dialogs,
  System.UITypes,
  System.SysUtils,
  UDAW.Types in 'src\common\UDAW.Types.pas',
  UDAW.Version in 'src\common\UDAW.Version.pas',
  UDAW.Errors in 'src\common\UDAW.Errors.pas',
  UDAW.Platform in 'src\common\UDAW.Platform.pas',
  UDAW.Paths in 'src\common\UDAW.Paths.pas',
  UDAW.Threading in 'src\common\UDAW.Threading.pas',
  UDAW.Logging in 'src\common\UDAW.Logging.pas',
  UDAW.Config in 'src\common\UDAW.Config.pas',
  UDAW.Jobs in 'src\common\UDAW.Jobs.pas',
  UDAW.SecureStorage in 'src\common\UDAW.SecureStorage.pas',
  UDAW.Audio.Types in 'src\audio\UDAW.Audio.Types.pas',
  UDAW.Audio.Buffer in 'src\audio\UDAW.Audio.Buffer.pas',
  UDAW.Audio.Ring in 'src\audio\UDAW.Audio.Ring.pas',
  UDAW.Audio.Source in 'src\audio\UDAW.Audio.Source.pas',
  UDAW.Audio.Offline in 'src\audio\UDAW.Audio.Offline.pas',
  UDAW.Audio.Device in 'src\audio\UDAW.Audio.Device.pas',
  UDAW.Audio.Backend.Software in 'src\audio\backend\UDAW.Audio.Backend.Software.pas',
  UDAW.Audio.Backend.WASAPI in 'src\audio\backend\UDAW.Audio.Backend.WASAPI.pas',
  UDAW.Audio.Backend.Factory in 'src\audio\UDAW.Audio.Backend.Factory.pas',
  UDAW.Audio.Engine in 'src\audio\UDAW.Audio.Engine.pas',
  UDAW.DSP.Math in 'src\audio\dsp\UDAW.DSP.Math.pas',
  UDAW.DSP.Interpolation in 'src\audio\dsp\UDAW.DSP.Interpolation.pas',
  UDAW.DSP.Filters in 'src\audio\dsp\UDAW.DSP.Filters.pas',
  UDAW.DSP.FFT in 'src\audio\dsp\UDAW.DSP.FFT.pas',
  UDAW.DSP.Resampler in 'src\audio\dsp\UDAW.DSP.Resampler.pas',
  UDAW.DSP.Envelope in 'src\audio\dsp\UDAW.DSP.Envelope.pas',
  UDAW.DSP.Meter in 'src\audio\dsp\UDAW.DSP.Meter.pas',
  UDAW.DSP.Dynamics in 'src\audio\dsp\UDAW.DSP.Dynamics.pas',
  UDAW.DSP.Modulation in 'src\audio\dsp\UDAW.DSP.Modulation.pas',
  UDAW.DSP.Distortion in 'src\audio\dsp\UDAW.DSP.Distortion.pas',
  UDAW.DSP.Reverb in 'src\audio\dsp\UDAW.DSP.Reverb.pas',
  UDAW.DSP.GraphicEQ in 'src\audio\dsp\UDAW.DSP.GraphicEQ.pas',
  UDAW.DSP.Visualization in 'src\audio\dsp\UDAW.DSP.Visualization.pas',
  UDAW.DSP.MultibandComp in 'src\audio\dsp\UDAW.DSP.MultibandComp.pas',
  UDAW.DSP.Mastering in 'src\audio\dsp\UDAW.DSP.Mastering.pas',
  UDAW.DSP.TimeStretch in 'src\audio\dsp\UDAW.DSP.TimeStretch.pas',
  UDAW.DSP.TempoDetect in 'src\audio\dsp\UDAW.DSP.TempoDetect.pas',
  UDAW.DSP.PitchShift in 'src\audio\dsp\UDAW.DSP.PitchShift.pas',
  UDAW.DSP.ParametricEQ in 'src\audio\dsp\UDAW.DSP.ParametricEQ.pas',
  UDAW.DSP.StereoWidth in 'src\audio\dsp\UDAW.DSP.StereoWidth.pas',
  UDAW.DSP.TransientShaper in 'src\audio\dsp\UDAW.DSP.TransientShaper.pas',
  UDAW.DSP.Delay in 'src\audio\dsp\UDAW.DSP.Delay.pas',
  UDAW.DSP.Dither in 'src\audio\dsp\UDAW.DSP.Dither.pas',
  UDAW.DSP.Spectral in 'src\audio\dsp\UDAW.DSP.Spectral.pas',
  UDAW.Sequencer.Patterns in 'src\sequencer\UDAW.Sequencer.Patterns.pas',
  UDAW.Synth.Instruments in 'src\synth\UDAW.Synth.Instruments.pas',
  UDAW.Mixer.Modulation in 'src\mixer\UDAW.Mixer.Modulation.pas',
  UDAW.Mixer.CLAP in 'src\mixer\UDAW.Mixer.CLAP.pas',
  UDAW.Mixer.VST3 in 'src\mixer\UDAW.Mixer.VST3.pas',
  UDAW.DSP.AudioToMidi in 'src\audio\dsp\UDAW.DSP.AudioToMidi.pas',
  UDAW.Timeline.SpectralFx in 'src\timeline\UDAW.Timeline.SpectralFx.pas',
  UDAW.Timeline.Warp in 'src\timeline\UDAW.Timeline.Warp.pas',
  UDAW.Timeline.VideoPlayer in 'src\timeline\UDAW.Timeline.VideoPlayer.pas',
  UDAW.Video.Effects in 'src\timeline\UDAW.Video.Effects.pas',
  UDAW.Timeline.VideoFxCache in 'src\timeline\UDAW.Timeline.VideoFxCache.pas',
  UDAW.Media.DirectShow in 'src\video\UDAW.Media.DirectShow.pas',
  UDAW.Timeline.VideoExport in 'src\timeline\UDAW.Timeline.VideoExport.pas',
  UDAW.Codec.MKV.Writer in 'src\codecs\mp4\UDAW.Codec.MKV.Writer.pas',
  UDAW.DSP.Exciter in 'src\audio\dsp\UDAW.DSP.Exciter.pas',
  UDAW.DSP.LookaheadLimiter in 'src\audio\dsp\UDAW.DSP.LookaheadLimiter.pas',
  UDAW.Audio.Graph.Nodes in 'src\audio\graph\UDAW.Audio.Graph.Nodes.pas',
  UDAW.Audio.Graph in 'src\audio\graph\UDAW.Audio.Graph.pas',
  UDAW.Audio.Graph.Serializer in 'src\audio\graph\UDAW.Audio.Graph.Serializer.pas',
  UDAW.Codec.WAV in 'src\codecs\pcm\UDAW.Codec.WAV.pas',
  UDAW.Codec.MP3.Frame in 'src\codecs\mp3\UDAW.Codec.MP3.Frame.pas',
  UDAW.Codec.MP3.Tables in 'src\codecs\mp3\UDAW.Codec.MP3.Tables.pas',
  UDAW.Codec.MP3.Decoder in 'src\codecs\mp3\UDAW.Codec.MP3.Decoder.pas',
  UDAW.Codec.MP3.Encoder in 'src\codecs\mp3\UDAW.Codec.MP3.Encoder.pas',
  UDAW.Codec.MP3.Metadata in 'src\codecs\mp3\UDAW.Codec.MP3.Metadata.pas',
  UDAW.Codec.MP3 in 'src\codecs\mp3\UDAW.Codec.MP3.pas',
  UDAW.Codec.MP3.Source in 'src\codecs\mp3\UDAW.Codec.MP3.Source.pas',
  UDAW.Codec.MP3.Timeline in 'src\codecs\mp3\UDAW.Codec.MP3.Timeline.pas',
  UDAW.Codec.AAC.Types in 'src\codecs\aac\UDAW.Codec.AAC.Types.pas',
  UDAW.Codec.AAC.Tables in 'src\codecs\aac\UDAW.Codec.AAC.Tables.pas',
  UDAW.Codec.AAC.Decoder in 'src\codecs\aac\UDAW.Codec.AAC.Decoder.pas',
  UDAW.Codec.AAC in 'src\codecs\aac\UDAW.Codec.AAC.pas',
  UDAW.Codec.MP4.Atoms in 'src\codecs\mp4\UDAW.Codec.MP4.Atoms.pas',
  UDAW.Codec.MP4.Container in 'src\codecs\mp4\UDAW.Codec.MP4.Container.pas',
  UDAW.Codec.MP4 in 'src\codecs\mp4\UDAW.Codec.MP4.pas',
  UDAW.Codec.MP4.Source in 'src\codecs\mp4\UDAW.Codec.MP4.Source.pas',
  UDAW.Codec.MP4.Timeline in 'src\codecs\mp4\UDAW.Codec.MP4.Timeline.pas',
  UDAW.MIDI.Types in 'src\midi\UDAW.MIDI.Types.pas',
  UDAW.MIDI.SMF in 'src\midi\UDAW.MIDI.SMF.pas',
  UDAW.MIDI.Sequence in 'src\midi\UDAW.MIDI.Sequence.pas',
  UDAW.MIDI.PianoRoll in 'src\midi\UDAW.MIDI.PianoRoll.pas',
  UDAW.MIDI.Engine in 'src\midi\UDAW.MIDI.Engine.pas',
  UDAW.MIDI.Serialization in 'src\midi\UDAW.MIDI.Serialization.pas',
  UDAW.MIDI.Hardware in 'src\midi\UDAW.MIDI.Hardware.pas',
  UDAW.MIDI.Capture in 'src\midi\UDAW.MIDI.Capture.pas',
  UDAW.Composer.SongSpec in 'src\composer\UDAW.Composer.SongSpec.pas',
  UDAW.Composer.Lyrics in 'src\composer\UDAW.Composer.Lyrics.pas',
  UDAW.Composer.Validation in 'src\composer\UDAW.Composer.Validation.pas',
  UDAW.Composer.Serialization in 'src\composer\UDAW.Composer.Serialization.pas',
  UDAW.Composer.Commands in 'src\composer\UDAW.Composer.Commands.pas',
  UDAW.Composer.RevisionHistory in 'src\composer\UDAW.Composer.RevisionHistory.pas',
  UDAW.Composer.Arrangement in 'src\composer\UDAW.Composer.Arrangement.pas',
  UDAW.Browser.Catalogue in 'src\browser\UDAW.Browser.Catalogue.pas',
  UDAW.Timeline.Time in 'src\timeline\UDAW.Timeline.Time.pas',
  UDAW.Timeline.Waveform in 'src\timeline\UDAW.Timeline.Waveform.pas',
  UDAW.Timeline.Model in 'src\timeline\UDAW.Timeline.Model.pas',
  UDAW.Timeline.Serialization in 'src\timeline\UDAW.Timeline.Serialization.pas',
  UDAW.Timeline.View in 'src\timeline\UDAW.Timeline.View.pas',
  UDAW.Mixer.Model in 'src\mixer\UDAW.Mixer.Model.pas',
  UDAW.Mixer.Automation in 'src\mixer\UDAW.Mixer.Automation.pas',
  UDAW.Mixer.Serialization in 'src\mixer\UDAW.Mixer.Serialization.pas',
  UDAW.Mixer.Engine in 'src\mixer\UDAW.Mixer.Engine.pas',
  UDAW.Mixer.VST2 in 'src\mixer\UDAW.Mixer.VST2.pas',
  UDAW.Tracker.Types in 'src\tracker\UDAW.Tracker.Types.pas',
  UDAW.Tracker.Instrument in 'src\tracker\UDAW.Tracker.Instrument.pas',
  UDAW.Tracker.Pattern in 'src\tracker\UDAW.Tracker.Pattern.pas',
  UDAW.Tracker.Player in 'src\tracker\UDAW.Tracker.Player.pas',
  UDAW.Tracker.Serialization in 'src\tracker\UDAW.Tracker.Serialization.pas',
  UDAW.Codec.ProTracker in 'src\codecs\tracker\UDAW.Codec.ProTracker.pas',
  UDAW.Codec.XM in 'src\codecs\tracker\UDAW.Codec.XM.pas',
  UDAW.Codec.MPTM in 'src\codecs\tracker\UDAW.Codec.MPTM.pas',
  UDAW.Codec.FLStudio in 'src\codecs\flstudio\UDAW.Codec.FLStudio.pas',
  UDAW.Codec.FLStudio.Timeline in 'src\codecs\flstudio\UDAW.Codec.FLStudio.Timeline.pas',
  UDAW.Project.Document in 'src\project\UDAW.Project.Document.pas',
  UDAW.Project.Serialization in 'src\project\UDAW.Project.Serialization.pas',
  UDAW.Project.Commands in 'src\project\UDAW.Project.Commands.pas',
  UDAW.Project.Recovery in 'src\project\UDAW.Project.Recovery.pas',
  UDAW.Project.WindowLayout in 'src\project\UDAW.Project.WindowLayout.pas',
  UDAW.Timeline.Commands in 'src\timeline\UDAW.Timeline.Commands.pas',
  UDAW.Timeline.Playback in 'src\timeline\UDAW.Timeline.Playback.pas',
  UDAW.Mixer.Commands in 'src\mixer\UDAW.Mixer.Commands.pas',
  UDAW.Tracker.Commands in 'src\tracker\UDAW.Tracker.Commands.pas',
  UDAW.MIDI.Commands in 'src\midi\UDAW.MIDI.Commands.pas',
  UDAW.Recording.Types in 'src\recording\UDAW.Recording.Types.pas',
  UDAW.Recording.ChunkFile in 'src\recording\UDAW.Recording.ChunkFile.pas',
  UDAW.Recording.Engine in 'src\recording\UDAW.Recording.Engine.pas',
  UDAW.Recording.Writer in 'src\recording\UDAW.Recording.Writer.pas',
  UDAW.Recording.Takes in 'src\recording\UDAW.Recording.Takes.pas',
  UDAW.Recording.Recovery in 'src\recording\UDAW.Recording.Recovery.pas',
  UDAW.Recording.Commands in 'src\recording\UDAW.Recording.Commands.pas',
  UDAW.AI.JSON in 'src\ai\UDAW.AI.JSON.pas',
  UDAW.AI.Credentials in 'src\ai\UDAW.AI.Credentials.pas',
  UDAW.AI.RateLimiter in 'src\ai\UDAW.AI.RateLimiter.pas',
  UDAW.AI.SecureLog in 'src\ai\UDAW.AI.SecureLog.pas',
  UDAW.AI.HTTP in 'src\ai\UDAW.AI.HTTP.pas',
  UDAW.AI.Types in 'src\ai\UDAW.AI.Types.pas',
  UDAW.AI.MCP in 'src\ai\UDAW.AI.MCP.pas',
  UDAW.AI.MCPBridge in 'src\ai\UDAW.AI.MCPBridge.pas',
  UDAW.AI.MCPServer in 'src\ai\UDAW.AI.MCPServer.pas',
  UDAW.AI.OpenAI in 'src\ai\UDAW.AI.OpenAI.pas',
  UDAW.AI.Claude in 'src\ai\UDAW.AI.Claude.pas',
  UDAW.AI.DeepSeek in 'src\ai\UDAW.AI.DeepSeek.pas',
  UDAW.AI.Providers in 'src\ai\UDAW.AI.Providers.pas',
  UDAW.AI.Composer in 'src\ai\UDAW.AI.Composer.pas',
  UDAW.AI.Suno in 'src\ai\UDAW.AI.Suno.pas',
  UDAW.AI.Luma in 'src\ai\UDAW.AI.Luma.pas',
  UDAW.AI.MusicTab in 'src\ai\UDAW.AI.MusicTab.pas',
  UDAW.AI.ToolCommands in 'src\ai\UDAW.AI.ToolCommands.pas',
  UDAW.DSP.Analysis in 'src\audio\dsp\UDAW.DSP.Analysis.pas',
  UDAW.AI.Mixing in 'src\ai\UDAW.AI.Mixing.pas',
  UDAW.AI.Mastering in 'src\ai\UDAW.AI.Mastering.pas',
  UDAW.AI.Revision in 'src\ai\UDAW.AI.Revision.pas',
  UDAW.Voice.Command in 'src\voice\UDAW.Voice.Command.pas',
  UDAW.Voice.Capture in 'src\voice\UDAW.Voice.Capture.pas',
  UDAW.Voice.Recognition in 'src\voice\UDAW.Voice.Recognition.pas',
  UDAW.App in 'src\application\UDAW.App.pas',
  UDAW.UI.Theme in 'src\ui\UDAW.UI.Theme.pas',
  UDAW.UI.ThemeColors in 'src\ui\UDAW.UI.ThemeColors.pas',
  UDAW.UI.Hints in 'src\ui\UDAW.UI.Hints.pas',
  UDAW.Web.HelpClient in 'src\web\UDAW.Web.HelpClient.pas',
  UDAW.Licensing in 'src\web\UDAW.Licensing.pas',
  UDAW.Update in 'src\web\UDAW.Update.pas',
  UDAW.Input.KeyHooks in 'src\input\UDAW.Input.KeyHooks.pas',
  UDAW.UI.HelpForm in 'src\ui\UDAW.UI.HelpForm.pas' {frmHelp},
  UDAW.UI.AboutForm in 'src\ui\UDAW.UI.AboutForm.pas' {frmAbout},
  UDAW.UI.VST2Editor in 'src\ui\UDAW.UI.VST2Editor.pas' {frmVST2Editor},
  UDAW.UI.SplashForm in 'src\ui\UDAW.UI.SplashForm.pas' {frmSplash},
  UDAW.UI.LogForm in 'src\ui\UDAW.UI.LogForm.pas' {frmLogViewer},
  UDAW.UI.MainForm in 'src\ui\UDAW.UI.MainForm.pas' {frmMain};

{$R *.res}

{ Resolves udaw-icon-image.png for the splash logo against a couple of
  candidate locations, since the exe can run from build\bin (dev layout,
  two levels below the project root where the image lives) or from wherever
  it was deployed alongside a copy of the image. Never raises - ShowSplash
  already treats a missing/blank path as "skip the logo", never fatal. }
function FindSplashLogo: string;
var
  exeDir: string;
  candidate: string;
begin
  exeDir := ExtractFilePath(System.ParamStr(0));
  candidate := exeDir + 'udaw-icon-image.png';
  if FileExists(candidate) then Exit(candidate);
  candidate := exeDir + '..\..\udaw-icon-image.png';   // build\bin\ -> project root (dev layout)
  if FileExists(candidate) then Exit(ExpandFileName(candidate));
  Result := '';
end;

var
  LCore: TUDAWApp;
  splash: TfrmSplash;
  updInfo: TUDAWUpdateInfo;
  {$IFDEF RELEASE}
  recheck: TUDAWUpdateInfo;
  {$ENDIF}
  updErr: string;
  licResult: TLicenseResult;
begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.Title := 'Ultimanium Audio Studio';

  splash := ShowSplash(FindSplashLogo, UDAW_PRODUCT_NAME,
    'Version ' + UDAWDisplayVersionString, UDAW_AUTHOR_LINE);

  LCore := TUDAWApp.Create;
  SetApp(LCore);
  try
    LCore.OnProgress := splash.OnAppProgress;
    try
      try
        LCore.Initialize;
      except
        on E: Exception do
        begin
          CloseSplash(splash);
          MessageDlg('UDAW failed to start:' + sLineBreak + E.Message, mtError, [mbOK], 0);
          SetApp(nil);
          LCore.Free;
          Halt(1);
        end;
      end;

      ThemeInitFromConfig(LCore.Config);

      { Online executable-checksum check + update check (one signed manifest).
        Any failure or an unreachable server is "no verdict", never fatal. In
        RELEASE builds a newer published build is downloaded, verified,
        installed by UDAWUpdater.exe and UDAW is restarted before the main
        window is ever created. Debug builds only run the check. }
      splash.OnAppProgress('Checking for updates...', 0, 0);
      if UDAWCheckForUpdateBounded(updInfo, updErr) then
      begin
        {$IFDEF RELEASE}
        { Any file of this exact build differing from the signed server
          manifest = tampered install: notice, then shut down. }
        if updInfo.ExeMismatch or updInfo.FilesMismatch then
        begin
          { Re-fetch the manifest first: a build published meanwhile makes this
            install merely outdated (handled by the update below), not pirated. }
          splash.OnAppProgress('Re-checking for updates...', 0, 0);
          recheck := updInfo;
          if UDAWCheckForUpdateBounded(recheck, updErr) and
            (recheck.UpdateAvailable or
             not (recheck.ExeMismatch or recheck.FilesMismatch)) then
          begin
            updInfo := recheck;   // newer build, or the mismatch went away
            if not (updInfo.ExeMismatch or updInfo.FilesMismatch) then
              TUDAWLicense.TamperDetected := False;
          end;
        end;
        if updInfo.ExeMismatch or updInfo.FilesMismatch then
        begin
          CloseSplash(splash);
          UDAWShowPiracyNotice;
          SetApp(nil);
          LCore.Free;
          Halt(1);
        end;
        { A newer published build is mandatory: install it and restart. If it
          cannot be installed the old build is not allowed to run. }
        if updInfo.UpdateAvailable then
        begin
          if UDAWUpdaterPresent then
          begin
            splash.OnAppProgress('Installing update ' + updInfo.ServerVersion + '...', 0, 0);
            if UDAWApplyUpdateBounded(updErr,
              procedure(const ADetail: string; APosition, ATotal: Integer)
              begin
                splash.OnAppProgress(ADetail, APosition, ATotal);
              end) then
            begin
              CloseSplash(splash);
              SetApp(nil);
              LCore.Free;
              Halt(0);   // UDAWUpdater.exe replaces the files and relaunches UDAW
            end;
          end
          else
            updErr := 'UDAWUpdater.exe is missing.';
          Logger.Warn('update', 'Mandatory update could not be applied: ' + updErr);
          CloseSplash(splash);
          MessageDlg('A required update (' + updInfo.ServerVersion +
            ') could not be installed:'#13#10 + updErr +
            #13#10#13#10'UDAW must update before it can start.', mtError, [mbOK], 0);
          SetApp(nil);
          LCore.Free;
          Halt(1);
        end;
        {$ENDIF}
      end
      else
        Logger.Warn('update', 'Update/checksum check skipped: ' + updErr);

      { Registration: re-verify the DPAPI-cached credentials online. }
      splash.OnAppProgress('Verifying registration...', 0, 0);
      licResult := TUDAWLicense.AttemptSilentVerifyBounded;
      if TUDAWLicense.IsRegistered then
        TUDAWLicense.StartHeartbeat
      else
        splash.OnAppProgress('Running unregistered - export and AI are disabled', 0, 0);

      splash.OnAppProgress('Loading interface...', 0, 0);
      Application.CreateForm(TfrmMain, frmMain);
    finally
      CloseSplash(splash);
    end;
    Application.Run;
  finally
    TUDAWLicense.EndSession;   // frees this run's licence seat; keeps the cached registration
    SetApp(nil);
    LCore.Free;
  end;
end.
