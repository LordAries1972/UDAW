unit UDAW.Timeline.Playback;
{$I udaw.inc}
{$POINTERMATH ON}

{ Timeline playback: renders the project timeline's tracks/clips as the
  live output, advancing TTimeline.PlayheadSeconds each render call so the
  Timeline tab's playhead and position readout track real playback instead
  of only reflecting manual edits.

  Non-destructive: each clip's StartSeconds/SourceOffsetSeconds/
  LengthSeconds/GainDb/fades/Reversed/Muted/Loop, and each track's Mute/
  Solo/GainDb/Pan, are read live on every render call - there is no
  separate "bounce" step, so editing a clip or a track's mix settings
  while the transport is running takes effect on the very next block,
  matching a normal DAW timeline.

  Source media (WAV via UDAW.Codec.WAV, MP3 via the Phase 15 decoder, MP4/M4A
  via UDAW.Codec.MP4 - PCM-in-MP4 and MP3-in-MP4 today; AAC-LC raises and is
  reported as a failed source until Phase 16b's tables land) is decoded up
  front, never on the real-time thread: IAudioSource.Render must
  not allocate, lock or do I/O (see UDAW.Audio.Source's interface comment),
  so EnsureSourcesLoaded runs on the UI thread - once before Play starts the
  engine, and again opportunistically on every UI timer tick so a clip
  added while the transport is already running gets its audio decoded and
  is heard on a later loop/replay without requiring a stop first.

  TTimelinePlayer (a plain, non-reference-counted object, like
  UDAW.Tracker.Player.TTrackerPlayer) owns the decode cache and playback
  state; AsSource hands the audio engine a separate small IAudioSource
  wrapper. Keeping those two lifetimes apart matters: if TTimelinePlayer
  itself implemented IAudioSource and a plain object-typed field held it,
  the engine's interface-typed reference would be the ONLY thing keeping
  it alive - ClearSource dropping that reference would free the object out
  from under a later FreeAndNil, a classic ref-counting/manual-ownership
  double-free. The wrapper sidesteps that entirely. }

interface

uses {$IFDEF FPC}UDAW.Compat,{$ENDIF}
  SysUtils, Classes, Math, Generics.Collections, System.SyncObjs, System.Threading,
  UDAW.Errors, UDAW.Audio.Types, UDAW.Audio.Buffer, UDAW.Audio.Source,
  UDAW.DSP.Interpolation, UDAW.DSP.Math, UDAW.DSP.TimeStretch,
  UDAW.Codec.WAV, UDAW.Codec.MP3, UDAW.Codec.MP4, UDAW.Codec.FLAC,
  UDAW.Jobs, UDAW.Timeline.Model, UDAW.Mixer.Model, UDAW.Mixer.Engine,
  UDAW.MIDI.Sequence, UDAW.MIDI.Serialization, UDAW.MIDI.Engine;

var
  { Settings > "Conform clip tempo by resampling": every new TTimelinePlayer
    (live Play and export alike) starts with this tempo-conform method. }
  TimelineResampleTempo: Boolean = False;

type
  TDecodedSource = class
    Channels: Integer;
    SampleRate: Integer;
    FrameCount: Integer;
    Data: TAudioPlanar;   // [ch][frame]
    Failed: Boolean;      // decode was attempted and failed - don't retry every tick
    Factor: Double;       // time-stretched copies only: output length / input length
  end;

  TTimelinePlayer = class;

  { Background job: decodes every timeline source and builds the tempo-stretched
    clips (TTimelinePlayer.EnsureSourcesLoaded) off the UI thread, reporting
    each stage through the job's Note/Progress. The caller must not touch the
    player or edit the timeline until the job is terminal. }
  TTimelinePrepareJob = class(TJob)
  private
    FPlayer: TTimelinePlayer;
  protected
    function Execute: Boolean; override;
  public
    constructor Create(APlayer: TTimelinePlayer);
  end;

  TTimelinePlayer = class
  private
    FTimeline: TTimeline;
    FCache: TObjectDictionary<Integer, TDecodedSource>;
    FOutSampleRate: Integer;
    FSource: IAudioSource;
    FLastMasterVolLin: Double;   // click-free ramp state for MasterVolumeDb
    FReachedEnd: Boolean;   // RT-thread-written, UI-thread-read - see RenderBlock/FReachedEnd's comment
    FDirection: Integer;    // +1 forward, -1 reverse - see Direction
    FPingPong: Boolean;     // see PingPong
    FMixer: TMixerProcessor;        // not owned; see AttachMixer
    FMixerModel: TMixerModel;       // not owned
    FMixerProvider: IMixInputProvider;
    FMixScratch: TAudioBuffer;
    FBlockTimes: TArray<Double>;    // per-frame timeline seconds for the block in progress -
                                     // shared with FMixerProvider so a mixer-linked track's dry
                                     // render lines up sample-for-sample with the direct path
    FBlockAnySoloed: Boolean;
    FLinkedTrackIds: TDictionary<Integer, Boolean>;   // track ids fed to the mixer instead of summed directly
    FTempoFunc: TFunc<Double>;   // live current tempo (BPM), read fresh every block - see SetTempoTracking
    FBaseTempoBPM: Double;       // tempo in effect when Play was pressed; ratio to FTempoFunc() is the varispeed rate
    { Phase 38 - MIDI Timeline clips/live monitor (see AttachMidi/
      AttachLiveMidiMonitor). Engines are keyed by TIMELINE CLIP id (not MIDI
      clip id), so two clips referencing the same MIDI performance keep
      independent playback heads. }
    FMidiProject: TMidiProject;                          // not owned
    FMidiEngines: TObjectDictionary<Integer, TMidiPlaybackEngine>;  // owned
    FMidiActiveClip: TDictionary<Integer, Integer>;       // track id -> currently-sounding clip id (0 = none)
    FLiveMidiMonitor: TMidiSynth;                         // not owned
    FMidiScratch: TAudioBuffer;
    FMidiAccumL, FMidiAccumR: TArray<Single>;
    FMetroOn: Boolean;
    FMetroBpm, FMetroGain: Double;
    FMetroBeats: Integer;
    FStretchBPM: Double;                                  // project tempo clips are conformed to (0 = off)
    FStretchResample: Boolean;                            // conform by plain resampling (pitch follows tempo) instead of the phase vocoder
    FStretchOwned: TObjectDictionary<string, TDecodedSource>;   // 'sourceId|factor' -> stretched copy, owned
    FClipStretch: TDictionary<Integer, TDecodedSource>;   // clip id -> entry of FStretchOwned (not owned)
    FOnStatus: TProc<string>;
    procedure Status(const AText: string);
    procedure BuildStretchedClips(AOnProgress: TProc<Double>);
    function ClipStretchFactor(AClip: TTimelineClip): Double;
    function CurrentPlaybackRate: Double;
    function DecodeSource(ASrc: TMediaSource): TDecodedSource;
    function TapAt(ADecoded: TDecodedSource; AChannel: Integer; APos: Double): Single;
    function RenderTrackSample(ATrack: TTimelineTrack; AAnySoloed: Boolean;
      ATimeSeconds: Double; AApplyTrackGainPan: Boolean; out AL, AR: Single): Boolean;
    procedure RefreshLinkedTracks;
    procedure RenderMidiBlock(AFrameCount: Integer; AAnySoloed: Boolean);
  public
    constructor Create(ATimeline: TTimeline);
    destructor Destroy; override;

    { UI-thread only: decode every source the timeline currently references
      that isn't cached yet. Call once before starting playback, and again
      periodically while playing so newly-added clips get their audio.
      AOnProgress (fraction 0..1), when given, is only invoked around
      sources actually being decoded - a call with nothing new to decode
      never fires it, so the periodic poll from AdvanceTimelinePlayback can
      omit it entirely without flickering the status bar every tick. }
    procedure EnsureSourcesLoaded(AOnProgress: TProc<Double> = nil);
    { False when every source is decoded and every stretched copy is current, so
      EnsureSourcesLoaded would do nothing. }
    function NeedsPrepare: Boolean;
    { Exchange decoded/stretched caches with another player (see the UI's
      cache-holder player: caches survive Stop/Play). }
    procedure SwapCacheWith(AOther: TTimelinePlayer);
    { Optional text of what EnsureSourcesLoaded is doing right now (decoding
      which file, stretching which clip), for the status bar. }
    property OnStatus: TProc<string> read FOnStatus write FOnStatus;
    { Tempo (BPM) that clips with a SourceBPM are conformed to - normally the
      project tempo. Call before EnsureSourcesLoaded (Play and export both do);
      each such clip is then phase-vocoder time-stretched (pitch preserved) by
      SourceBPM / ABPM so it plays at the Timeline BPM whatever the file's own
      speed. 0 disables stretching. The stretch is built once per load, so a
      tempo change takes effect on the next Play/export. }
    procedure SetStretchTempo(ABPM: Double);
    { Click track: a short accented click on every beat (downbeat higher),
      mixed in after the tracks under the same master gain. Rendered from the
      block's timeline seconds, so it stays locked to the playhead through
      loops and seeks. }
    procedure SetMetronome(AEnabled: Boolean; ABpm: Double; ABeatsPerBar: Integer;
      AGainDb: Double);
    { Tempo conform method. Default (False) = phase vocoder, pitch preserved.
      True = plain resampling: the clip is shrunk/stretched like tape, so pitch
      follows tempo (Settings > "Conform tempo by resampling"). The class-level
      default is set by the UI from Settings and picked up by every new player,
      so live Play and export always agree (see TimelineResampleTempo). }
    { Direct cache lookup - nil if ASourceId hasn't been decoded yet (see
      EnsureSourcesLoaded). Lets an offline per-clip render (UDAW.UI.MainForm's
      "Apply Effect to Selection" - TlApplyEffectToRange) reuse the exact same
      decoded PCM this player already holds instead of decoding the file a
      second time. }
    function GetDecodedSource(ASourceId: Integer): TDecodedSource;
    { Route every timeline track that a mixer strip's InputSourceId points at
      through AMixer/AModel instead of this player's own direct gain/pan/sum -
      that strip's fader, pan, inserts, sends and routing then actually affect
      what's heard, instead of the Mixer tab being a dead-end UI over a
      separate mix that RenderBlock computes on its own. Tracks with no
      linked strip keep rendering exactly as before, so a project that never
      touches the Mixer tab is unaffected. Pass AMixer = nil to detach (the
      caller owns AMixer/AModel; this player only holds references). Safe to
      call again after the mixer model's strips change - it just re-scans
      InputSourceId. }
    procedure AttachMixer(AMixer: TMixerProcessor; AModel: TMixerModel);
    { Phase 38 - MIDI Timeline clips: lets RenderBlock resolve a tkMidi
      track's active clip (TTimelineClip.MidiClipId) to the TMidiSequence it
      plays. Pass nil to detach (every MIDI/instrument track then renders
      silent, exactly like before this phase). Not owned. }
    procedure AttachMidi(AMidi: TMidiProject);
    { Every captured/thru MIDI event dispatched here (typically by
      UDAW.MIDI.Capture.TMidiCaptureEngine.Monitor or a live-input Thru
      toggle) is heard mixed into the Timeline output on the very next
      block, for real-time feedback while recording or just playing a
      connected controller - independent of whatever is on the timeline
      itself. Pass nil to detach. Not owned. }
    procedure AttachLiveMidiMonitor(ASynth: TMidiSynth);
    { Drops every cached MIDI playback engine so the next block re-reads the
      current TMidiSequence content for whatever clip is under the playhead -
      call after any edit to a MIDI clip that might be playing right now
      (note add/move/delete, quantize, undo/redo, ...). Cheap: engines are
      recreated lazily, one per clip actually heard. }
    procedure InvalidateAllMidi;
    { Live tempo-follow ("varispeed"): AFunc must return the project's current
      TempoBPM, read fresh every RenderBlock, so moving the Timeline/Project
      tempo field while the transport is running changes playback speed (and
      pitch, like a turntable - there is no time-stretch engine here)
      immediately, not just on the next Play. ABaseTempoBPM is the tempo in
      effect at the moment Play was pressed: the rate is
      AFunc()/ABaseTempoBPM, so a fresh Play always starts at rate 1.0
      regardless of what the tempo happens to be. Call before the first
      RenderBlock (see TfrmMain.StartTimelinePlayback); omit to play at a
      fixed rate of 1.0 (e.g. export, where tempo must not drift mid-render). }
    procedure SetTempoTracking(ABaseTempoBPM: Double; AFunc: TFunc<Double>);
    { Drops the whole decode cache (e.g. after a source's file was
      replaced) so the next EnsureSourcesLoaded re-decodes everything. }
    procedure InvalidateAll;
    procedure ValidateLoadedSources;

    { Test-only seam: register already-decoded PCM for a source id directly,
      bypassing file I/O, so the mix/gain/mute/solo/fade logic in Render can
      be exercised deterministically without real WAV/MP3 fixtures. Takes
      ownership of ADecoded. }
    procedure InjectForTest(ASourceId: Integer; ADecoded: TDecodedSource);

    { RT: render AOut.FrameCount frames of the timeline from the current
      playhead, advancing it. }
    procedure RenderBlock(AOut: TAudioBuffer);
    procedure Prepare(ASampleRate, AMaxFrames, AChannels: Integer);

    function AsSource: IAudioSource;

    { True once RenderBlock has advanced the playhead past the end of the
      arrangement (TTimeline.LastClipEndSeconds) with the region loop off.
      Same plain-Boolean RT-writes/UI-polls pattern UDAW.Tracker.Player uses
      for TTrackerPlayer.SongEnded - see tmrUITimer's Timeline tick, which
      stops the transport once this is set instead of playing silence
      forever past the last clip. }
    property ReachedEnd: Boolean read FReachedEnd;

    { Transport direction/mode, set before Play starts the engine (see
      TfrmMain.StartTimelinePlayback). Direction: +1 plays forward from the
      current playhead toward LastClipEndSeconds (the normal case); -1 plays
      backward toward 0. PingPong, when True, bounces the direction at
      whichever end is reached instead of setting ReachedEnd - Play Ping
      Pong then runs forward-then-backward-then-forward... until Stop is
      pressed, never auto-stopping on its own. The region loop (LoopEnabled)
      only applies to forward playback - reverse/ping-pong ignore it, like a
      distinct transport mode rather than a variant of the loop feature. }
    property Direction: Integer read FDirection write FDirection;
    property PingPong: Boolean read FPingPong write FPingPong;
  end;

implementation

const
  SUBSYS = 'Timeline.Playback';

constructor TTimelinePrepareJob.Create(APlayer: TTimelinePlayer);
begin
  inherited Create('Prepare timeline playback');
  FPlayer := APlayer;
end;

function TTimelinePrepareJob.Execute: Boolean;
var
  frac: Double;
begin
  frac := 0;
  SetProgress(0, 'Starting');
  FPlayer.OnStatus :=
    procedure(AText: string)
    begin
      ThrowIfCancelled;
      SetProgress(frac, AText);
    end;
  try
    FPlayer.EnsureSourcesLoaded(
      procedure(AFraction: Double)
      begin
        ThrowIfCancelled;
        frac := AFraction;
        SetProgress(frac);
      end);
  finally
    FPlayer.OnStatus := nil;
  end;
  SetProgress(1, 'Sources decoded and tempo-conformed');
  Result := True;
end;

{ TTimelineClip.GainAt already applies its own dB->linear conversion
  internally (UDAW.Timeline.Model.DbToGain), but that helper is private to
  that unit - this is the same formula for the track-level dB gain. }
function DbToLinear(ADb: Double): Double;
begin
  Result := Power(10.0, ADb / 20.0);
end;

type
  { Thin IAudioSource forwarder - see the header comment for why this is a
    separate reference-counted object rather than TTimelinePlayer itself. }
  TTimelineAudioSource = class(TInterfacedObject, IAudioSource)
  private
    FPlayer: TTimelinePlayer;   // not owned; the player outlives or frees this
  public
    constructor Create(APlayer: TTimelinePlayer);
    procedure Render(ABuffer: TAudioBuffer);
    procedure Prepare(ASampleRate, AMaxFrames, AChannels: Integer);
    procedure Reset;
    function Name: string;
  end;

  { Supplies TMixerProcessor's skAudioTrack strips with the dry (no track
    gain/pan - the strip's own trim/fader/pan/inserts own placement from here
    on) per-block audio for whichever TTimelineTrack a strip's InputSourceId
    names. FPlayer.FBlockTimes/FBlockAnySoloed are filled once per block by
    RenderBlock before the mixer is asked to process it, so this stays
    sample-aligned with tracks rendered directly (unlinked ones). }
  TTimelineMixInputProvider = class(TInterfacedObject, IMixInputProvider)
  private
    FPlayer: TTimelinePlayer;    // not owned
    FModel: TMixerModel;         // not owned
  public
    constructor Create(APlayer: TTimelinePlayer; AModel: TMixerModel);
    procedure RenderStripInput(AStripId: Integer; ABuffer: TAudioBuffer);
  end;

{ ================= TTimelinePlayer ================= }

constructor TTimelinePlayer.Create(ATimeline: TTimeline);
begin
  inherited Create;
  FTimeline := ATimeline;
  FCache := TObjectDictionary<Integer, TDecodedSource>.Create([doOwnsValues]);
  FOutSampleRate := 48000;
  FLastMasterVolLin := 1.0;
  FReachedEnd := False;
  FDirection := 1;
  FPingPong := False;
  FLinkedTrackIds := TDictionary<Integer, Boolean>.Create;
  FMidiEngines := TObjectDictionary<Integer, TMidiPlaybackEngine>.Create([doOwnsValues]);
  FMidiActiveClip := TDictionary<Integer, Integer>.Create;
  FStretchOwned := TObjectDictionary<string, TDecodedSource>.Create([doOwnsValues]);
  FClipStretch := TDictionary<Integer, TDecodedSource>.Create;
  FStretchResample := TimelineResampleTempo;
end;

destructor TTimelinePlayer.Destroy;
begin
  FClipStretch.Free;
  FStretchOwned.Free;
  if FMixer <> nil then FMixer.SetInputProvider(nil);
  FMixerProvider := nil;
  FSource := nil;
  FMixScratch.Free;
  FMidiScratch.Free;
  FMidiEngines.Free;
  FMidiActiveClip.Free;
  FLinkedTrackIds.Free;
  FCache.Free;
  inherited Destroy;
end;

procedure TTimelinePlayer.AttachMidi(AMidi: TMidiProject);
begin
  FMidiProject := AMidi;
  InvalidateAllMidi;
end;

procedure TTimelinePlayer.AttachLiveMidiMonitor(ASynth: TMidiSynth);
begin
  FLiveMidiMonitor := ASynth;
end;

procedure TTimelinePlayer.InvalidateAllMidi;
begin
  FMidiEngines.Clear;
  FMidiActiveClip.Clear;
end;

procedure TTimelinePlayer.AttachMixer(AMixer: TMixerProcessor; AModel: TMixerModel);
begin
  if FMixer <> nil then FMixer.SetInputProvider(nil);
  FMixer := AMixer;
  FMixerModel := AModel;
  FMixerProvider := nil;
  if (FMixer <> nil) and (FMixerModel <> nil) then
  begin
    FMixerProvider := TTimelineMixInputProvider.Create(Self, FMixerModel);
    FMixer.SetInputProvider(FMixerProvider);
  end;
  RefreshLinkedTracks;
end;

procedure TTimelinePlayer.SetTempoTracking(ABaseTempoBPM: Double; AFunc: TFunc<Double>);
begin
  FBaseTempoBPM := ABaseTempoBPM;
  FTempoFunc := AFunc;
end;

function TTimelinePlayer.CurrentPlaybackRate: Double;
var
  bpm: Double;
begin
  Result := 1.0;
  if not Assigned(FTempoFunc) or (FBaseTempoBPM <= 0) then Exit;
  bpm := FTempoFunc();
  if bpm <= 0 then Exit;
  Result := bpm / FBaseTempoBPM;
end;

procedure TTimelinePlayer.RefreshLinkedTracks;
var
  i: Integer;
  s: TMixStrip;
begin
  FLinkedTrackIds.Clear;
  if (FMixerModel = nil) or (FMixer = nil) then Exit;
  for i := 0 to FMixerModel.StripCount - 1 do
  begin
    s := FMixerModel.GetStrip(i);
    if (s.Kind = skAudioTrack) and (s.InputSourceId <> 0) then
      FLinkedTrackIds.AddOrSetValue(s.InputSourceId, True);
  end;
end;

function TTimelinePlayer.DecodeSource(ASrc: TMediaSource): TDecodedSource;
var
  planar: TAudioPlanar;
  ch, sr: Integer;
  mp3Res: TMP3DecodeResult;
  mp4Res: TMP4DecodeResult;
  flacRes: TFLACDecodeResult;
begin
  Result := TDecodedSource.Create;
  try
    if not FileExists(ASrc.Path) then
    begin
      Result.Failed := True;
      Exit;
    end;
    if Mp3SniffFile(ASrc.Path) then
    begin
      if not Mp3DecodeFile(ASrc.Path, mp3Res) then
      begin
        Result.Failed := True;
        Exit;
      end;
      Result.Channels := mp3Res.Channels;
      Result.SampleRate := mp3Res.SampleRate;
      Result.Data := mp3Res.Pcm;
      Result.FrameCount := mp3Res.Frames;
    end
    else if Mp4SniffFile(ASrc.Path) then
    begin
      if not Mp4DecodeAudioFile(ASrc.Path, mp4Res) then
      begin
        Result.Failed := True;
        Exit;
      end;
      Result.Channels := mp4Res.Channels;
      Result.SampleRate := mp4Res.SampleRate;
      Result.Data := mp4Res.Data;
      Result.FrameCount := mp4Res.Frames;
    end
    else if FlacSniffFile(ASrc.Path) then
    begin
      if not FlacDecodeFile(ASrc.Path, flacRes) then
      begin
        Result.Failed := True;
        Exit;
      end;
      Result.Channels := flacRes.Channels;
      Result.SampleRate := flacRes.SampleRate;
      Result.Data := flacRes.Pcm;
      Result.FrameCount := Integer(flacRes.TotalFrames);
    end
    else if FileLooksLikeWav(ASrc.Path) then
    begin
      planar := LoadWavFile(ASrc.Path, ch, sr);
      Result.Channels := ch;
      Result.SampleRate := sr;
      Result.Data := planar;
      if ch > 0 then Result.FrameCount := Length(planar[0])
      else Result.FrameCount := 0;
    end
    else
      Result.Failed := True;
  except
    on E: Exception do
      Result.Failed := True;
  end;
end;

procedure TTimelinePlayer.Status(const AText: string);
begin
  if Assigned(FOnStatus) then FOnStatus(AText);
end;

{ Two stages share one 0..1 bar: decoding sources is 0..0.6, time-stretching
  clips 0.6..1.0 (a call with nothing to stretch just jumps to 1). }
procedure TTimelinePlayer.EnsureSourcesLoaded(AOnProgress: TProc<Double>);
var
  i, todoIdx, todoCount: Integer;
  src: TMediaSource;
  stretchProgress: TProc<Double>;
begin
  if FTimeline = nil then Exit;
  stretchProgress := nil;
  if Assigned(AOnProgress) then
    stretchProgress := procedure(AFraction: Double)
      begin
        AOnProgress(0.6 + 0.4 * AFraction);
      end;
  todoCount := 0;
  for i := 0 to FTimeline.SourceCount - 1 do
    if (FTimeline.GetSource(i).Kind <> mkVideoFile) and
       not FCache.ContainsKey(FTimeline.GetSource(i).Id) then
      Inc(todoCount);
  if todoCount = 0 then
  begin
    Status('All sources already decoded');
    BuildStretchedClips(stretchProgress);
    Exit;
  end;

  todoIdx := 0;
  if Assigned(AOnProgress) then AOnProgress(0);
  for i := 0 to FTimeline.SourceCount - 1 do
  begin
    src := FTimeline.GetSource(i);
    if (src.Kind <> mkVideoFile) and not FCache.ContainsKey(src.Id) then
    begin
      Status(Format('Stage 1/2: decoding source %d of %d - %s',
        [todoIdx + 1, todoCount, ExtractFileName(src.Path)]));
      FCache.Add(src.Id, DecodeSource(src));
      Inc(todoIdx);
      if Assigned(AOnProgress) then AOnProgress(0.6 * todoIdx / todoCount);
    end;
  end;
  BuildStretchedClips(stretchProgress);
end;

procedure TTimelinePlayer.SetMetronome(AEnabled: Boolean; ABpm: Double;
  ABeatsPerBar: Integer; AGainDb: Double);
begin
  FMetroBpm := Max(ABpm, 20.0);
  FMetroBeats := Max(ABeatsPerBar, 1);
  FMetroGain := DbToLinear(AGainDb);
  FMetroOn := AEnabled;
end;

procedure TTimelinePlayer.SetStretchTempo(ABPM: Double);
begin
  if ABPM < 0 then ABPM := 0;
  { No cache flush: BuildStretchedClips compares each clip's stretch factor
    with its cached copy, so only clips whose factor really changed are redone
    and superseded copies are freed there. }
  FStretchBPM := ABPM;
end;

{ Stretch factor (output length / input length) a clip needs to conform to the
  stretch tempo, or 0 when it needs none (no SourceBPM, MIDI, ~1.0, or outside
  the supported 0.25..4 range). }
function TTimelinePlayer.ClipStretchFactor(AClip: TTimelineClip): Double;
begin
  Result := 0;
  if (FStretchBPM <= 0) or AClip.IsMidiClip or (AClip.SourceBPM <= 0) then Exit;
  Result := AClip.SourceBPM / FStretchBPM;
  if (Abs(Result - 1.0) < 0.001) or (Result < 0.25) or (Result > 4.0) then Result := 0;
end;

{ True when EnsureSourcesLoaded has real work: a source not decoded yet, or a
  clip whose stretched copy is missing/stale. Lets the caller skip the
  background job entirely when the cache is already warm (the common case for
  a second Play with no tempo change). }
function TTimelinePlayer.NeedsPrepare: Boolean;
var
  i, ti, ci: Integer;
  trk: TTimelineTrack;
  clip: TTimelineClip;
  f: Double;
  st, dec: TDecodedSource;
begin
  Result := True;
  if FTimeline = nil then Exit(False);
  for i := 0 to FTimeline.SourceCount - 1 do
    if (FTimeline.GetSource(i).Kind <> mkVideoFile) and
       not FCache.ContainsKey(FTimeline.GetSource(i).Id) then Exit;
  for ti := 0 to FTimeline.TrackCount - 1 do
  begin
    trk := FTimeline.GetTrack(ti);
    if trk.Kind = tkVideo then Continue;
    for ci := 0 to trk.ClipCount - 1 do
    begin
      clip := trk.GetClip(ci);
      if clip.IsMidiClip then Continue;
      f := ClipStretchFactor(clip);
      if FClipStretch.TryGetValue(clip.Id, st) then
      begin
        if (f <= 0) or (Abs(st.Factor - f) > 0.0005) then Exit;
      end
      else if (f > 0) and FCache.TryGetValue(clip.SourceId, dec) and (dec <> nil) and
              not dec.Failed and (dec.FrameCount >= 2048) then
        Exit;
    end;
  end;
  Result := False;
end;

{ Hands this player's decoded/stretched caches to AOther and takes AOther's in
  exchange. The UI parks the caches in a spare player between Plays so a new
  Play reuses every decode and stretch instead of redoing them. }
procedure TTimelinePlayer.SwapCacheWith(AOther: TTimelinePlayer);
var
  c: TObjectDictionary<Integer, TDecodedSource>;
  o: TObjectDictionary<string, TDecodedSource>;
  s: TDictionary<Integer, TDecodedSource>;
  b: Double;
begin
  c := FCache; FCache := AOther.FCache; AOther.FCache := c;
  o := FStretchOwned; FStretchOwned := AOther.FStretchOwned; AOther.FStretchOwned := o;
  s := FClipStretch; FClipStretch := AOther.FClipStretch; AOther.FClipStretch := s;
  b := FStretchBPM; FStretchBPM := AOther.FStretchBPM; AOther.FStretchBPM := b;
end;

{ Brings every clip's stretched copy up to date. Already-correct copies are
  kept (this is the expensive part - phase-vocoder over whole files - so it only
  runs for a clip whose source/tempo actually changed). New work is split into
  one task per (distinct source+factor, channel) and run on the thread pool; the
  calling (job) thread only polls, reports progress and honours cancellation.
  Copies no clip refers to any more are freed. }
procedure TTimelinePlayer.BuildStretchedClips(AOnProgress: TProc<Double>);
type
  TClipWork = record ClipId: Integer; Key: string; end;
  TUnit = record
    Key: string;
    Factor: Double;
    Src, St: TDecodedSource;
    Added: Boolean;
  end;
var
  clips: TArray<TClipWork>;
  units: TArray<TUnit>;
  tasks: TArray<ITask>;
  errs: TArray<string>;
  ti, ci, k, u, ch, t, total, d: Integer;
  trk: TTimelineTrack;
  clip: TTimelineClip;
  dec, st: TDecodedSource;
  f: Double;
  key: string;
  found: Boolean;
  doneCount, cancelFlag: Integer;
  unusedKeys: TArray<string>;
  pair: TPair<string, TDecodedSource>;
  used: Boolean;
  cp: TPair<Integer, TDecodedSource>;
  modeTxt: string;

  function StartTask(AUnit, ACh, AIdx: Integer): ITask;
  begin
    Result := TTask.Run(
      procedure
      var
        stretcher: TPhaseVocoderStretch;
        outBuf: TArray<Single>;
        n, m, q: Integer;
        srcCh: TAudioSampleArray;
      begin
        try
          if TInterlocked.CompareExchange(cancelFlag, 0, 0) = 0 then
          begin
            if FStretchResample then
            begin
              { plain resample: output frame q reads the source at q / Factor, so
                the clip becomes Factor x as long and its pitch moves with it }
              srcCh := units[AUnit].Src.Data[ACh];
              m := Length(srcCh);
              n := Round(m * units[AUnit].Factor);
              SetLength(outBuf, n);
              for q := 0 to n - 1 do
                outBuf[q] := ReadFractional(@srcCh[0], m, q / units[AUnit].Factor, ikHermite);
            end
            else
            begin
              stretcher := TPhaseVocoderStretch.Create(2048);
              try
                stretcher.Process(units[AUnit].Src.Data[ACh], units[AUnit].Factor, outBuf);
              finally
                stretcher.Free;
              end;
            end;
            n := Length(outBuf);
            SetLength(units[AUnit].St.Data[ACh], n);
            if n > 0 then Move(outBuf[0], units[AUnit].St.Data[ACh][0], n * SizeOf(Single));
          end;
        except
          on E: Exception do errs[AIdx] := E.Message;
        end;
        TInterlocked.Increment(doneCount);
      end);
  end;

begin
  if FTimeline = nil then Exit;

  { 1. classify every clip: keep an up-to-date copy, drop a stale one, or queue }
  SetLength(clips, 0);
  SetLength(units, 0);
  for ti := 0 to FTimeline.TrackCount - 1 do
  begin
    trk := FTimeline.GetTrack(ti);
    if trk.Kind = tkVideo then Continue;
    for ci := 0 to trk.ClipCount - 1 do
    begin
      clip := trk.GetClip(ci);
      if clip.IsMidiClip then Continue;
      f := ClipStretchFactor(clip);
      if FClipStretch.TryGetValue(clip.Id, st) then
      begin
        if (f > 0) and (Abs(st.Factor - f) <= 0.0005) then Continue;
        FClipStretch.Remove(clip.Id);   // tempo / clip tempo changed, or no longer needed
      end;
      if f <= 0 then Continue;
      if not FCache.TryGetValue(clip.SourceId, dec) or (dec = nil) or dec.Failed or
         (dec.FrameCount < 2048) then Continue;
      key := Format('%d|%.5f|%d', [clip.SourceId, f, Ord(FStretchResample)]);
      k := Length(clips);
      SetLength(clips, k + 1);
      clips[k].ClipId := clip.Id;
      clips[k].Key := key;
      if FStretchOwned.ContainsKey(key) then Continue;   // same source+factor already stretched
      found := False;
      for u := 0 to High(units) do
        if units[u].Key = key then begin found := True; Break; end;
      if not found then
      begin
        u := Length(units);
        SetLength(units, u + 1);
        units[u].Key := key;
        units[u].Factor := f;
        units[u].Src := dec;
        units[u].St := nil;
        units[u].Added := False;
      end;
    end;
  end;

  if Length(units) = 0 then
  begin
    if Length(clips) = 0 then
      Status('Stage 2/2: stretched clips already up to date (cached)')
    else
      Status('Stage 2/2: stretched clips reused from cache');
  end
  else
  begin
    { 2. one task per (distinct source+factor, channel) }
    total := 0;
    for u := 0 to High(units) do
    begin
      units[u].St := TDecodedSource.Create;
      units[u].St.Channels := units[u].Src.Channels;
      units[u].St.SampleRate := units[u].Src.SampleRate;
      SetLength(units[u].St.Data, units[u].Src.Channels);
      Inc(total, units[u].Src.Channels);
    end;
    SetLength(tasks, total);
    SetLength(errs, total);
    doneCount := 0;
    cancelFlag := 0;
    try
      try
        t := 0;
        for u := 0 to High(units) do
          for ch := 0 to units[u].Src.Channels - 1 do
          begin
            tasks[t] := StartTask(u, ch, t);
            Inc(t);
          end;
        { 3. poll: progress text, progress fraction, cancellation }
        repeat
          d := TInterlocked.CompareExchange(doneCount, 0, 0);
          if FStretchResample then modeTxt := 'resampled, pitch follows tempo'
          else modeTxt := 'pitch kept';
          Status(Format('Stage 2/2: time-stretching %d of %d channel(s) in parallel ' +
            '(%d distinct clip(s), %s)', [d, total, Length(units), modeTxt]));
          if Assigned(AOnProgress) then AOnProgress(d / total);
          if d >= total then Break;
          TThread.Sleep(50);
        until False;
      except
        TInterlocked.Exchange(cancelFlag, 1);
        try
          TTask.WaitForAll(tasks);
        except
          // task failures are already captured in errs; the original error wins
        end;
        raise;
      end;
      TTask.WaitForAll(tasks);
      for t := 0 to High(errs) do
        if errs[t] <> '' then
          RaiseUDAWFmt(errIO, SUBSYS, 'Time-stretch failed: %s', [errs[t]]);
      { 4. publish }
      for u := 0 to High(units) do
      begin
        units[u].St.FrameCount := Length(units[u].St.Data[0]);
        units[u].St.Factor := units[u].St.FrameCount / units[u].Src.FrameCount;
        FStretchOwned.Add(units[u].Key, units[u].St);
        units[u].Added := True;
      end;
    finally
      for u := 0 to High(units) do
        if (units[u].St <> nil) and not units[u].Added then units[u].St.Free;
    end;
  end;

  { 5. point every queued clip at its copy }
  for k := 0 to High(clips) do
    if FStretchOwned.TryGetValue(clips[k].Key, st) then
      FClipStretch.AddOrSetValue(clips[k].ClipId, st);

  { 6. free copies no clip uses any more (tempo changed, clip removed) }
  SetLength(unusedKeys, 0);
  for pair in FStretchOwned do
  begin
    used := False;
    for cp in FClipStretch do
      if cp.Value = pair.Value then begin used := True; Break; end;
    if not used then
    begin
      SetLength(unusedKeys, Length(unusedKeys) + 1);
      unusedKeys[High(unusedKeys)] := pair.Key;
    end;
  end;
  for k := 0 to High(unusedKeys) do
    FStretchOwned.Remove(unusedKeys[k]);

  if Assigned(AOnProgress) then AOnProgress(1);
end;

function TTimelinePlayer.GetDecodedSource(ASourceId: Integer): TDecodedSource;
begin
  if not FCache.TryGetValue(ASourceId, Result) then
    Result := nil;
end;

procedure TTimelinePlayer.ValidateLoadedSources;
var
  i: Integer;
  decoded: TDecodedSource;
begin
  for i := 0 to FTimeline.SourceCount - 1 do
    if (FTimeline.GetSource(i).Kind <> mkVideoFile) and
       (not FCache.TryGetValue(FTimeline.GetSource(i).Id, decoded) or
       decoded.Failed) then
      RaiseUDAWFmt(errIO, SUBSYS, 'Cannot export: source could not be decoded: %s',
        [FTimeline.GetSource(i).Path]);
end;

procedure TTimelinePlayer.InvalidateAll;
begin
  FClipStretch.Clear;
  FStretchOwned.Clear;
  FCache.Clear;
end;

procedure TTimelinePlayer.InjectForTest(ASourceId: Integer; ADecoded: TDecodedSource);
begin
  FCache.AddOrSetValue(ASourceId, ADecoded);
end;

function TTimelinePlayer.TapAt(ADecoded: TDecodedSource; AChannel: Integer;
  APos: Double): Single;
var
  ch: Integer;
begin
  if (ADecoded = nil) or ADecoded.Failed or (ADecoded.FrameCount = 0) then Exit(0);
  ch := AChannel;
  if ch >= ADecoded.Channels then ch := ADecoded.Channels - 1;
  if ch < 0 then Exit(0);
  if (APos < 0) or (APos >= ADecoded.FrameCount) then Exit(0);
  Result := ReadFractional(@ADecoded.Data[ch][0], ADecoded.FrameCount, APos, ikHermite);
end;

function TTimelinePlayer.RenderTrackSample(ATrack: TTimelineTrack; AAnySoloed: Boolean;
  ATimeSeconds: Double; AApplyTrackGainPan: Boolean; out AL, AR: Single): Boolean;
var
  clip: TTimelineClip;
  src: TMediaSource;
  dec, stretched: TDecodedSource;
  srcSec, srcPos, gain: Double;
  sL, sR: Single;
  tl_, tr_: Single;
begin
  AL := 0; AR := 0;
  Result := False;
  if ATrack.Muted then Exit;
  if AAnySoloed and not ATrack.Soloed then Exit;

  clip := ATrack.ClipAtSeconds(ATimeSeconds);
  if (clip = nil) or clip.Muted then Exit;

  src := FTimeline.SourceById(clip.SourceId);
  if src = nil then Exit;
  if not FCache.TryGetValue(src.Id, dec) then Exit;   // not preloaded yet
  if (dec = nil) or dec.Failed then Exit;

  srcSec := clip.SourceSecondsAt(ATimeSeconds);
  { Conform to the timeline tempo: read the pre-stretched copy at the scaled
    position (see SetStretchTempo). }
  if (FClipStretch.Count > 0) and FClipStretch.TryGetValue(clip.Id, stretched) then
  begin
    dec := stretched;
    { stretched[u] = original[u / Factor], so timeline-relative time maps 1:1
      into the stretched copy; only the start offset (original seconds) scales.
      (Multiplying the whole position by Factor cancelled the stretch out.) }
    srcSec := srcSec - clip.SourceOffsetSeconds * (1.0 - stretched.Factor);
  end;
  if clip.Loop and (dec.FrameCount > 0) and (dec.SampleRate > 0) then
  begin
    srcSec := srcSec - Floor(srcSec * dec.SampleRate / dec.FrameCount) *
      (dec.FrameCount / dec.SampleRate);
  end;
  srcPos := srcSec * dec.SampleRate;
  if (srcPos < 0) or (srcPos >= dec.FrameCount) then Exit;

  sL := TapAt(dec, 0, srcPos);
  if dec.Channels >= 2 then sR := TapAt(dec, 1, srcPos) else sR := sL;

  gain := clip.GainAt(ATimeSeconds);
  if AApplyTrackGainPan then
  begin
    gain := gain * DbToLinear(ATrack.GainDb);
    PanGains(Single(ATrack.Pan), plConstantPower, tl_, tr_);
  end
  else
  begin
    { linked to a mixer strip: the strip's own trim/fader/pan chain owns
      placement from here, so hand it flat dry audio - no track pan/gain. }
    tl_ := 1.0;
    tr_ := 1.0;
  end;

  AL := Single(sL * gain * tl_);
  AR := Single(sR * gain * tr_);
  Result := True;
end;

{ Phase 38 - MIDI Timeline clips: fills FMidiAccumL/R (sized AFrameCount,
  zeroed first) with the sum of every unmuted/audible tkMidi (or
  tkInstrument) track's synth output for this block, plus the live monitor
  synth if attached. Runs once per block, before the per-frame accumulation
  loop in RenderBlock, rather than per-frame like RenderTrackSample - a MIDI
  synth renders a whole block at once, and per-sample track gain/pan
  interpolation is not worth the extra complexity for a first cut (see the
  header comment's non-destructive promise: still live-read every block, just
  not ramped sample-by-sample the way the master volume is).

  Clip lookup/engine reseek uses the block's FIRST sample's timeline time, so
  a block that straddles a clip boundary rounds to whichever clip is active
  at its start - the same block-rate granularity RenderTrackSample's own
  Pass 3 caller already accepts for track mute/solo. }
procedure TTimelinePlayer.RenderMidiBlock(AFrameCount: Integer; AAnySoloed: Boolean);
var
  ti, i, activeClipId, midiClipId: Integer;
  trk: TTimelineTrack;
  clip: TTimelineClip;
  seq: TMidiSequence;
  eng: TMidiPlaybackEngine;
  localSeconds, gain: Double;
  tl_, tr_: Single;
  pL, pR: PSingle;
  wantSeek: Boolean;
begin
  if Length(FMidiAccumL) < AFrameCount then
  begin
    SetLength(FMidiAccumL, AFrameCount);
    SetLength(FMidiAccumR, AFrameCount);
  end;
  for i := 0 to AFrameCount - 1 do
  begin
    FMidiAccumL[i] := 0;
    FMidiAccumR[i] := 0;
  end;

  if (FMidiScratch = nil) or (FMidiScratch.ChannelCount < 2) or (FMidiScratch.CapacityFrames < AFrameCount) then
  begin
    FMidiScratch.Free;
    FMidiScratch := TAudioBuffer.Create(2, Max(AFrameCount, 1), FOutSampleRate);
  end;

  for ti := 0 to FTimeline.TrackCount - 1 do
  begin
    trk := FTimeline.GetTrack(ti);
    if not (trk.Kind in [tkMidi, tkInstrument]) then Continue;
    if trk.Muted then Continue;
    if AAnySoloed and not trk.Soloed then Continue;

    clip := trk.ClipAtSeconds(FBlockTimes[0]);
    activeClipId := 0;
    if (clip <> nil) and clip.IsMidiClip and not clip.Muted then
      activeClipId := clip.Id;

    if activeClipId = 0 then
    begin
      FMidiActiveClip.AddOrSetValue(trk.Id, 0);
      Continue;
    end;

    if (FMidiProject = nil) then Continue;
    midiClipId := clip.MidiClipId;
    seq := FMidiProject.ClipById(midiClipId);
    if seq = nil then Continue;

    if not FMidiEngines.TryGetValue(activeClipId, eng) then
    begin
      eng := TMidiPlaybackEngine.Create;
      eng.Prepare(FOutSampleRate, Max(AFrameCount, 1), 2);
      eng.SetSequence(seq);
      FMidiEngines.Add(activeClipId, eng);
    end;

    localSeconds := (FBlockTimes[0] - clip.StartSeconds) + clip.SourceOffsetSeconds;

    { just switched onto this clip (was a different clip, or nothing) -
      seek and start fresh; otherwise let it run continuously, only
      correcting for a large jump (scrub/loop wrap). }
    wantSeek := (not eng.Playing) or (not FMidiActiveClip.ContainsKey(trk.Id)) or
      (FMidiActiveClip[trk.Id] <> activeClipId) or
      (Abs(eng.PositionSeconds - localSeconds) > 0.25);
    if wantSeek then
    begin
      eng.SeekSeconds(Max(0.0, localSeconds));
      eng.Play;
    end;
    FMidiActiveClip.AddOrSetValue(trk.Id, activeClipId);

    FMidiScratch.SetActiveFrames(AFrameCount);
    FMidiScratch.Clear;
    eng.Render(FMidiScratch);

    gain := clip.GainAt(FBlockTimes[0]) * DbToLinear(trk.GainDb);
    PanGains(Single(trk.Pan), plConstantPower, tl_, tr_);
    pL := PSingle(FMidiScratch.ChannelPtr(0));
    pR := PSingle(FMidiScratch.ChannelPtr(1));
    for i := 0 to AFrameCount - 1 do
    begin
      FMidiAccumL[i] := FMidiAccumL[i] + Single(pL[i] * gain * tl_);
      FMidiAccumR[i] := FMidiAccumR[i] + Single(pR[i] * gain * tr_);
    end;
  end;

  if Assigned(FLiveMidiMonitor) then
  begin
    FMidiScratch.SetActiveFrames(AFrameCount);
    FMidiScratch.Clear;
    FLiveMidiMonitor.RenderAdd(FMidiScratch, AFrameCount);
    pL := PSingle(FMidiScratch.ChannelPtr(0));
    pR := PSingle(FMidiScratch.ChannelPtr(1));
    for i := 0 to AFrameCount - 1 do
    begin
      FMidiAccumL[i] := FMidiAccumL[i] + pL[i];
      FMidiAccumR[i] := FMidiAccumR[i] + pR[i];
    end;
  end;
end;

procedure TTimelinePlayer.RenderBlock(AOut: TAudioBuffer);
var
  nOut, i, ti, n: Integer;
  pL, pR: PSingle;
  mL, mR: PSingle;
  anySoloed, loopOn, haveLinked: Boolean;
  t, loopStart, loopEnd, newPlayhead, totalDur: Double;
  accL, accR, l, r: Single;
  volTarget, vol, volStep: Double;
  trk: TTimelineTrack;
  rate: Double;
  metroBeat: Int64;
  metroT, metroF, metroV: Double;
begin
  AOut.Clear;
  nOut := AOut.ChannelCount;
  if (nOut = 0) or (FTimeline = nil) then Exit;
  if FReachedEnd then Exit;   { UI thread hasn't stopped us yet - render silence, not another lap of content }
  pL := PSingle(AOut.ChannelPtr(0));
  if nOut >= 2 then pR := PSingle(AOut.ChannelPtr(1)) else pR := pL;

  anySoloed := False;
  for ti := 0 to FTimeline.TrackCount - 1 do
    if FTimeline.GetTrack(ti).Soloed then
    begin
      anySoloed := True;
      Break;
    end;
  FBlockAnySoloed := anySoloed;

  { region loop (Loop Start/End set on the ruler): wrap the read position -
    not the underlying model - back to LoopStartSeconds once it reaches
    LoopStartSeconds + LoopLengthSeconds. }
  loopOn := FTimeline.LoopEnabled and (FTimeline.LoopLengthSeconds > 0);
  loopStart := FTimeline.LoopStartSeconds;
  loopEnd := loopStart + FTimeline.LoopLengthSeconds;

  { Timeline-tab master output level - a real gain stage applied on top of
    (never instead of) whatever the Mixer's own master strip applies for
    tracks routed through it (see AttachMixer/FLinkedTrackIds). Ramped
    per-sample across the block so riding the slider during playback never
    clicks. }
  volTarget := DbToLinear(FTimeline.MasterVolumeDb);
  n := AOut.FrameCount;
  if n > 0 then volStep := (volTarget - FLastMasterVolLin) / n else volStep := 0;
  vol := FLastMasterVolLin;

  { Pass 1: per-frame timeline seconds for this block, shared with
    FMixerProvider so a mixer-linked track's dry render (done inside
    FMixer.ProcessBlock below) lines up sample-for-sample with tracks
    rendered directly right here. rate (see SetTempoTracking) scales how far
    each frame reads into the source, so a live tempo change takes effect on
    the very next block instead of waiting for the next Play. }
  rate := CurrentPlaybackRate;
  SetLength(FBlockTimes, n);
  for i := 0 to n - 1 do
  begin
    t := FTimeline.PlayheadSeconds + (i / FOutSampleRate) * FDirection * rate;
    if loopOn and (FDirection > 0) and (t >= loopEnd) then
      t := loopStart + (t - loopEnd);
    FBlockTimes[i] := t;
  end;

  { Pass 2: any track with a mixer strip pointed at it (TMixStrip.InputSourceId)
    is rendered through TMixerProcessor instead of directly, so that strip's
    trim/fader/pan/inserts/sends/routing actually reach the output. }
  haveLinked := (FMixer <> nil) and FMixer.IsPrepared and (FLinkedTrackIds.Count > 0);
  if haveLinked then
  begin
    if (FMixScratch = nil) or (FMixScratch.ChannelCount <> nOut) or
       (FMixScratch.CapacityFrames < n) then
    begin
      FMixScratch.Free;
      FMixScratch := TAudioBuffer.Create(nOut, n, FOutSampleRate);
    end;
    FMixScratch.SetActiveFrames(n);
    FMixScratch.Clear;
    FMixer.SetPlayheadSeconds(FTimeline.PlayheadSeconds);
    FMixer.ProcessBlock(FMixScratch);
    mL := PSingle(FMixScratch.ChannelPtr(0));
    if FMixScratch.ChannelCount >= 2 then mR := PSingle(FMixScratch.ChannelPtr(1)) else mR := mL;
  end
  else
  begin
    mL := nil;
    mR := nil;
  end;

  { Pass 2b: every tkMidi/tkInstrument track's synth output for this block,
    plus the live MIDI monitor (see AttachMidi/AttachLiveMidiMonitor) -
    computed once per block, not per frame, since a MIDI synth renders a
    whole block at a time. }
  RenderMidiBlock(n, anySoloed);

  { Pass 3: direct sum of every unlinked track, plus the mixer's contribution
    from Pass 2 and the MIDI contribution from Pass 2b, all under the same
    Timeline master-volume ramp. }
  for i := 0 to n - 1 do
  begin
    accL := 0; accR := 0;
    for ti := 0 to FTimeline.TrackCount - 1 do
    begin
      trk := FTimeline.GetTrack(ti);
      if (trk.Kind = tkVideo) or FLinkedTrackIds.ContainsKey(trk.Id) then Continue;
      if RenderTrackSample(trk, anySoloed, FBlockTimes[i], True, l, r) then
      begin
        accL := accL + l;
        accR := accR + r;
      end;
    end;
    if mL <> nil then
    begin
      accL := accL + mL[i];
      accR := accR + mR[i];
    end;
    accL := accL + FMidiAccumL[i];
    accR := accR + FMidiAccumR[i];
    if FMetroOn and (FBlockTimes[i] >= 0) then
    begin
      metroBeat := Floor(FBlockTimes[i] * FMetroBpm / 60.0);
      metroT := FBlockTimes[i] - metroBeat * 60.0 / FMetroBpm;
      if metroT < 0.04 then
      begin
        if metroBeat mod FMetroBeats = 0 then metroF := 1760.0 else metroF := 1100.0;
        metroV := Sin(2.0 * Pi * metroF * metroT) * Exp(-metroT * 120.0) * FMetroGain;
        accL := accL + metroV;
        accR := accR + metroV;
      end;
    end;
    vol := vol + volStep;
    pL[i] := pL[i] + Single(accL * vol);
    pR[i] := pR[i] + Single(accR * vol);
  end;
  FLastMasterVolLin := volTarget;

  newPlayhead := FTimeline.PlayheadSeconds + (AOut.FrameCount / FOutSampleRate) * FDirection * rate;
  if loopOn and (FDirection > 0) and (newPlayhead >= loopEnd) then
    newPlayhead := loopStart + (newPlayhead - loopEnd);

  { Auto-stop at whichever end of the arrangement this direction is heading
    for, like a normal DAW transport, instead of running on into silence
    indefinitely - but never while the region loop is engaged going forward,
    since looping past the same point is the whole point of that feature.
    Uses LastClipEndSeconds (actual clip content only), not
    TotalDurationSeconds - a marker/region/loop bound left over from before
    the tail clips were cut/trimmed/deleted must not push the stop point out
    past the last real note. A LastClipEndSeconds of 0 means no clips at
    all: never auto-stop forward playback on that, there is nothing to have
    "reached the end" of. PingPong bounces the direction at either end
    instead of stopping - see Direction/PingPong's comment. }
  totalDur := FTimeline.LastClipEndSeconds;
  if FDirection > 0 then
  begin
    if (not loopOn) and (totalDur > 0) and (newPlayhead >= totalDur) then
    begin
      newPlayhead := totalDur;
      if FPingPong then FDirection := -1 else FReachedEnd := True;
    end;
  end
  else
  begin
    if newPlayhead <= 0 then
    begin
      newPlayhead := 0;
      if FPingPong and (totalDur > 0) then FDirection := 1 else FReachedEnd := True;
    end;
  end;
  FTimeline.PlayheadSeconds := newPlayhead;
end;

procedure TTimelinePlayer.Prepare(ASampleRate, AMaxFrames, AChannels: Integer);
begin
  if ASampleRate > 0 then FOutSampleRate := ASampleRate;
  { start the master-volume ramp at the current setting, not unity, so the
    first rendered block (e.g. the start of an export) is already at level }
  FLastMasterVolLin := DbToLinear(FTimeline.MasterVolumeDb);
  { The live monitor synth (see AttachLiveMidiMonitor) is a long-lived
    instance the caller may have created before knowing the real device
    sample rate - (re)initialise it here, the one place that does, so its
    oscillator pitch is correct instead of silently wrong whenever the
    device rate differs from whatever default the synth started with. }
  if Assigned(FLiveMidiMonitor) and (ASampleRate > 0) then
    FLiveMidiMonitor.Init(ASampleRate);
  { Pre-allocate the mixer scratch buffer here (off the RT thread) so
    RenderBlock's own guard never has to allocate once playback is running. }
  if (FMixer <> nil) and (AChannels > 0) and (AMaxFrames > 0) then
  begin
    FMixScratch.Free;
    FMixScratch := TAudioBuffer.Create(AChannels, AMaxFrames, FOutSampleRate);
    { The engine (via TTimelineAudioSource.Prepare) is the only place that
      knows the real device sample rate/buffer size, so (re)preparing the
      mixer plan happens here rather than wherever AttachMixer was called
      from. An invalid mixer routing (e.g. a cycle) must not take Timeline
      playback down with it - swallow it and leave FMixer unprepared, so
      RenderBlock's "haveLinked" check (FMixer.IsPrepared) just falls back to
      rendering every track directly, exactly as if no mixer were attached.
      FMixer.LastError still carries the reason for the caller to surface. }
    try
      FMixer.SetAutomation(FMixerModel.Automation);
      FMixer.SetModulation(FMixerModel.Modulation);
      FMixer.Prepare(ASampleRate, AMaxFrames, AChannels);
    except
      on E: EUDAWError do ;
    end;
  end;
end;

function TTimelinePlayer.AsSource: IAudioSource;
begin
  if FSource = nil then
    FSource := TTimelineAudioSource.Create(Self);
  Result := FSource;
end;

{ ================= TTimelineAudioSource ================= }

constructor TTimelineAudioSource.Create(APlayer: TTimelinePlayer);
begin
  inherited Create;
  FPlayer := APlayer;
end;

procedure TTimelineAudioSource.Render(ABuffer: TAudioBuffer);
begin
  FPlayer.RenderBlock(ABuffer);
end;

procedure TTimelineAudioSource.Prepare(ASampleRate, AMaxFrames, AChannels: Integer);
begin
  FPlayer.Prepare(ASampleRate, AMaxFrames, AChannels);
end;

procedure TTimelineAudioSource.Reset;
begin
  // stateless beyond the timeline's own playhead; nothing to do
end;

function TTimelineAudioSource.Name: string;
begin
  Result := 'Timeline';
end;

{ ================= TTimelineMixInputProvider ================= }

constructor TTimelineMixInputProvider.Create(APlayer: TTimelinePlayer; AModel: TMixerModel);
begin
  inherited Create;
  FPlayer := APlayer;
  FModel := AModel;
end;

procedure TTimelineMixInputProvider.RenderStripInput(AStripId: Integer; ABuffer: TAudioBuffer);
var
  strip: TMixStrip;
  trk: TTimelineTrack;
  i, n: Integer;
  pL, pR: PSingle;
  l, r: Single;
begin
  strip := FModel.StripById(AStripId);
  if (strip = nil) or (strip.InputSourceId = 0) then Exit;
  trk := FPlayer.FTimeline.TrackById(strip.InputSourceId);
  if trk = nil then Exit;

  n := ABuffer.FrameCount;
  if n > Length(FPlayer.FBlockTimes) then n := Length(FPlayer.FBlockTimes);
  pL := PSingle(ABuffer.ChannelPtr(0));
  if ABuffer.ChannelCount >= 2 then pR := PSingle(ABuffer.ChannelPtr(1)) else pR := pL;
  for i := 0 to n - 1 do
    if FPlayer.RenderTrackSample(trk, FPlayer.FBlockAnySoloed, FPlayer.FBlockTimes[i],
       False, l, r) then
    begin
      pL[i] := pL[i] + l;
      if pR <> pL then pR[i] := pR[i] + r;
    end;
end;

end.
