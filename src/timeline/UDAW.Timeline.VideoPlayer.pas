unit UDAW.Timeline.VideoPlayer;
{$I udaw.inc}

{ Shows the Timeline's video clips in a host window while the transport runs.

  Threading: every video operation (open, seek, play, pause, drift checks)
  runs on ONE dedicated worker thread, TMfVideoWorker.  The UI thread only
  posts "what should be on screen right now" (a few fields, under a lock) and
  never waits on the picture - so a slow open, a slow seek or a heavy codec can
  never stall the window.  The audio itself is rendered by the audio engine's
  own real-time thread; this unit only follows its clock.

  Decoding and display follow MPC-HC's pipeline: a DirectShow graph (the
  registered splitter and decoder - LAV Splitter / LAV Video where installed,
  which read MP4 and MKV and decode on the GPU via D3D11 / DXVA2 with a software
  fallback) drawn by the Enhanced Video Renderer straight into the host window.
  The video is muted - the sound comes from the clip's audio channel.  Windows
  alone opens only what its built-in filters cover; LastError names the gap.

  The audio engine is the master clock: TTimeline.PlayheadSeconds advances with
  the audio, the worker follows it and re-seeks only when the picture has
  genuinely drifted or the playhead jumped. }

interface

uses
  SysUtils, Classes, Math, SyncObjs,
  Winapi.Windows, Winapi.ActiveX, Winapi.DirectShow9,
  Vcl.Controls, Vcl.Graphics,
  UDAW.Timeline.Model;

type
  { What should be on screen right now, as last posted by the UI thread. }
  TVideoTarget = record
    Active: Boolean;        // a video clip lies under the playhead
    Playing: Boolean;       // transport running forward (else: hold a still frame)
    Prepare: Boolean;       // a Prepare call is waiting for this to be handled
    Path: string;
    WantSeconds: Double;    // source time at PostTick
    PostTick: UInt64;
    Host: HWND;
  end;

  TVideoFileCheck = record
    Id: Integer;
    Ok: Boolean;
  end;

  TTimelineVideoPlayer = class
  private
    FHost: TWinControl;
    FWorker: TObject;                           // TMfVideoWorker
    FFileOk: TArray<TVideoFileCheck>;           // source id -> file exists (UI thread only)
    FLastActive, FLastPlaying: Boolean;         // last posted state - repeats are throttled
    FLastClipId: Integer;
    FLastPostTick: UInt64;
    FStretchBPM: Double;
    FRenderedPath: string;                      // pre-rendered picture (effects applied), '' = play the clips
    FRenderedStart, FRenderedDuration: Double;
    function ActiveClip(ATl: TTimeline; ASeconds: Double; out ASrc: TMediaSource): TTimelineClip;
    function FileOk(ASrc: TMediaSource): Boolean;
    function GetLastError: string;
  public
    constructor Create(AHost: TWinControl);
    destructor Destroy; override;
    { Follow the playhead (cheap: only posts a target to the worker).  APlaying
      False, or a reverse transport, holds a still frame at the playhead. }
    procedure Sync(ATl: TTimeline; APlayheadSeconds: Double; APlaying: Boolean;
      ADirection: Integer);
    { Opens and positions the clip under the playhead BEFORE the transport
      starts, so the first frame is ready when the audio begins.  Waits at most
      a couple of seconds. }
    procedure Prepare(ATl: TTimeline; APlayheadSeconds: Double);
    { Pause the picture (the last frame stays up). }
    procedure Stop;
    { Plays AFile - the Timeline's picture rendered with its video effects,
      starting at timeline second AStart - instead of the raw clips, until
      called again with ''. }
    procedure SetRendered(const AFile: string; AStart, ADuration: Double);
    function RenderedActive: Boolean;
    { The host window changed size: have the renderer re-fit the picture. }
    procedure HostResized;
    { Timeline tempo that clips with a SourceBPM are conformed to (same rule as
      their sound). A reversed or tempo-conformed picture cannot run through the
      forward player, so it follows the playhead as a stepped still picture
      (about ten per second) instead of being shown at the wrong speed/direction. }
    property StretchBPM: Double read FStretchBPM write FStretchBPM;
    property LastError: string read GetLastError;
  end;

  { A decoded still of a video file at a moment, shrunk for a hover preview. }
  TVideoThumb = record
    Path: string;
    Ms: Integer;
    W, H: Integer;
    Bits: TBytes;           // 24-bit DIB rows, bottom-up, each row padded to 4 bytes
  end;

  { Grabs single frames on its own worker thread (a second, paused DirectShow
    graph ending in a sample grabber - the UI never waits on a decoder).  The UI
    asks with Request and collects with TryGet; AOnReady is queued to the UI
    thread whenever a new frame lands. }
  TVideoThumbnailer = class(TThread)
  private
    FLock: TCriticalSection;
    FWake: TEvent;
    FOnReady: TThreadProcedure;
    FReqPath: string;
    FReqMs: Integer;
    FReqPending: Boolean;
    FCache: TArray<TVideoThumb>;
    { ---- worker-thread-only ---- }
    FGraph: IGraphBuilder;
    FControl: IMediaControl;
    FSeeking: IMediaSeeking;
    FGrabber: ISampleGrabber;
    FOpenPath: string;
    FFailedPath: string;
    FSrcW, FSrcH: Integer;
    FTopDown: Boolean;
    FMaxW: Integer;
    FStepMs: Integer;
    procedure CloseGraph;
    procedure OpenGraph(const APath: string);
    function Grab(AMs: Integer; var AThumb: TVideoThumb): Boolean;
    function Cached(const APath: string; AMs: Integer): Boolean;
    procedure Store(const AThumb: TVideoThumb);
  protected
    procedure Execute; override;
  public
    constructor Create(AOnReady: TThreadProcedure);
    destructor Destroy; override;
    function QuantizeMs(ASeconds: Double): Integer;
    { Widest picture kept (pixels) and the time step requests are rounded to.
      Hover thumbnails use the defaults; the effect preview asks for bigger,
      finer-grained pictures. Set before the first Request. }
    procedure Configure(AMaxWidth, AStepMs: Integer);
    procedure Request(const APath: string; ASeconds: Double);
    { Copies the frame into ABmp (24-bit); False while it is not decoded yet. }
    function TryGet(const APath: string; ASeconds: Double; ABmp: TBitmap): Boolean;
  end;

implementation

{ ======================= DirectShow / EVR subset ======================== }

{ The pipeline is the one MPC-HC uses: a DirectShow graph built by
  IGraphBuilder.RenderFile - the registered splitter (LAV Splitter where
  installed: MP4, MKV, WebM ...) feeding the registered decoder (LAV Video:
  D3D11 / DXVA2 hardware with a software fallback) - drawn by the Enhanced Video
  Renderer.  Only the EVR display-control interfaces are declared here;
  Delphi ships the DirectShow ones (Winapi.DirectShow9). }

type
  IMFGetService = interface(IUnknown)
    ['{FA993888-4383-415A-A930-DD472A8CF6F7}']
    function GetService(const guidService, riid: TGUID; out ppvObject): HRESULT; stdcall;
  end;

  { Method order is the vtable order of evr.h's IMFVideoDisplayControl. }
  IMFVideoDisplayControl = interface(IUnknown)
    ['{A490B1E4-AB84-4D31-A1B2-181E03B1077A}']
    function GetNativeVideoSize(pszVideo, pszARVideo: Pointer): HRESULT; stdcall;
    function GetIdealVideoSize(pszMin, pszMax: Pointer): HRESULT; stdcall;
    function SetVideoPosition(pnrcSource: Pointer; const prcDest: PRect): HRESULT; stdcall;
    function GetVideoPosition(pnrcSource: Pointer; prcDest: PRect): HRESULT; stdcall;
    function SetAspectRatioMode(dwAspectRatioMode: DWORD): HRESULT; stdcall;
    function GetAspectRatioMode(out pdwAspectRatioMode: DWORD): HRESULT; stdcall;
    function SetVideoWindow(hwndVideo: HWND): HRESULT; stdcall;
    function GetVideoWindow(out phwndVideo: HWND): HRESULT; stdcall;
    function RepaintVideo: HRESULT; stdcall;
  end;

const
  CLSID_EnhancedVideoRenderer: TGUID = '{FA10746C-9B63-4B6C-BC49-FC300EA5F256}';
  MR_VIDEO_RENDER_SERVICE: TGUID = '{1092A86C-AB1A-459A-A336-831FBC4D11FF}';
  MFVideoARMode_PreservePicture = 1;
  AM_SEEKING_NO_POSITIONING = 0;
  AM_SEEKING_ABSOLUTE_POSITIONING = 1;
  MUTED_VOLUME = -10000;            // IBasicAudio: hundredths of a dB, fully silent
  HNS_PER_SECOND = 10000000;

  DRIFT_LIMIT_SECONDS = 0.40;       // re-seek once picture and playhead differ by this
  JUMP_LIMIT_SECONDS = 0.60;        // playhead moved this far from where the picture should be
  SETTLE_MS = 1500;                 // after a seek the reported position lags: never judge drift then
  POLL_INTERVAL_MS = 500;           // how often the real position is compared
  SCRUB_MIN_INTERVAL_MS = 80;       // still frame: at most one seek per this
  OPEN_TIMEOUT_MS = 4000;
  PREPARE_TIMEOUT_MS = 2500;
  REPOST_INTERVAL_MS = 100;         // UI side: how often an unchanged target is re-posted
  WORKER_IDLE_TICK_MS = 30;         // opening / scrubbing: react quickly
  WORKER_STEADY_TICK_MS = 100;      // picture running steadily: nothing to do but a drift check

type
  TMfVideoWorker = class(TThread)
  private
    FLock: TCriticalSection;
    FWake: TEvent;
    FPrepared: TEvent;
    FTarget: TVideoTarget;
    FUpdatePending: Boolean;
    FLastError: string;
    { ---- worker-thread-only state ---- }
    FGraph: IGraphBuilder;
    FControl: IMediaControl;
    FSeeking: IMediaSeeking;
    FDisplay: IMFVideoDisplayControl;
    FHostWnd: HWND;
    FOpenPath: string;
    FRunning: Boolean;
    FRunStartTick: UInt64;
    FRunStartPos: Double;
    FLastSeekTick: UInt64;
    FLastPollTick: UInt64;
    FStillPos: Double;
    FFailedPath: string;            // last file that failed to open - not retried every tick
    procedure SetError(const AMsg: string);
    procedure ShutdownPlayer;
    procedure OpenItem(const APath: string; AHost: HWND);
    procedure FitVideo;
    procedure SeekTo(ASeconds: Double);
    procedure SeekPlay(ASeconds: Double);
    procedure SeekStill(ASeconds: Double; ATick: UInt64);
    function PositionSeconds: Double;
    procedure Step;
  protected
    procedure Execute; override;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Post(AActive, APlaying: Boolean; const APath: string;
      AWantSeconds: Double; AHost: HWND);
    function Prepare(AActive: Boolean; const APath: string;
      AWantSeconds: Double; AHost: HWND): Boolean;
    procedure RequestUpdate;
    function LastError: string;
  end;

{ ============================ TMfVideoWorker ========================== }

constructor TMfVideoWorker.Create;
begin
  FLock := TCriticalSection.Create;
  FWake := TEvent.Create(nil, False, False, '');          // auto-reset
  FPrepared := TEvent.Create(nil, True, False, '');       // manual-reset
  FStillPos := -1;
  inherited Create(False);
  Priority := tpHigher;      // mostly asleep; when it must act, it acts before UI work
end;

destructor TMfVideoWorker.Destroy;
begin
  Terminate;
  FWake.SetEvent;
  WaitFor;
  inherited;
  FPrepared.Free;
  FWake.Free;
  FLock.Free;
end;

procedure TMfVideoWorker.SetError(const AMsg: string);
begin
  FLock.Enter;
  try
    FLastError := AMsg;
  finally
    FLock.Leave;
  end;
end;

function TMfVideoWorker.LastError: string;
begin
  FLock.Enter;
  try
    Result := FLastError;
  finally
    FLock.Leave;
  end;
end;

procedure TMfVideoWorker.Post(AActive, APlaying: Boolean; const APath: string;
  AWantSeconds: Double; AHost: HWND);
begin
  FLock.Enter;
  try
    FTarget.Active := AActive;
    FTarget.Playing := APlaying;
    FTarget.Path := APath;
    FTarget.WantSeconds := AWantSeconds;
    FTarget.PostTick := GetTickCount64;
    FTarget.Host := AHost;
  finally
    FLock.Leave;
  end;
  FWake.SetEvent;
end;

function TMfVideoWorker.Prepare(AActive: Boolean; const APath: string;
  AWantSeconds: Double; AHost: HWND): Boolean;
begin
  FPrepared.ResetEvent;
  FLock.Enter;
  try
    FTarget.Active := AActive;
    FTarget.Playing := False;
    FTarget.Prepare := True;
    FTarget.Path := APath;
    FTarget.WantSeconds := AWantSeconds;
    FTarget.PostTick := GetTickCount64;
    FTarget.Host := AHost;
  finally
    FLock.Leave;
  end;
  FWake.SetEvent;
  Result := FPrepared.WaitFor(PREPARE_TIMEOUT_MS) = wrSignaled;
end;

procedure TMfVideoWorker.RequestUpdate;
begin
  FLock.Enter;
  try
    FUpdatePending := True;
  finally
    FLock.Leave;
  end;
  FWake.SetEvent;
end;

procedure TMfVideoWorker.Execute;
begin
  CoInitializeEx(nil, COINIT_MULTITHREADED);
  try
    while not Terminated do
    begin
      if FRunning then FWake.WaitFor(WORKER_STEADY_TICK_MS)
      else FWake.WaitFor(WORKER_IDLE_TICK_MS);
      if Terminated then Break;
      try
        Step;
      except
        on E: Exception do
        begin
          SetError(E.Message);
          { a failed open must not be retried 30 times a second }
          FOpenPath := '';
          FLock.Enter;
          try
            FTarget.Active := False;
          finally
            FLock.Leave;
          end;
          FPrepared.SetEvent;
        end;
      end;
    end;
  finally
    ShutdownPlayer;
    CoUninitialize;
  end;
end;

procedure TMfVideoWorker.ShutdownPlayer;
begin
  if FControl <> nil then FControl.Stop;
  FDisplay := nil;
  FSeeking := nil;
  FControl := nil;
  FGraph := nil;
  FHostWnd := 0;
  FOpenPath := '';
  FRunning := False;
end;

{ Fit the picture to the host window's client area (aspect ratio preserved). }
procedure TMfVideoWorker.FitVideo;
var
  rc: TRect;
begin
  if (FDisplay = nil) or (FHostWnd = 0) then Exit;
  Winapi.Windows.GetClientRect(FHostWnd, rc);
  FDisplay.SetVideoPosition(nil, @rc);
  FDisplay.RepaintVideo;
end;

procedure TMfVideoWorker.OpenItem(const APath: string; AHost: HWND);
var
  evr: IBaseFilter;
  svc: IMFGetService;
  audio: IBasicAudio;
  fs: TFilterState;
  hr: HRESULT;
begin
  ShutdownPlayer;
  FStillPos := -1;

  hr := CoCreateInstance(CLSID_FilterGraph, nil, CLSCTX_INPROC_SERVER, IID_IGraphBuilder, FGraph);
  if hr < 0 then
    raise Exception.CreateFmt('could not create the DirectShow filter graph (0x%.8x)', [Cardinal(hr)]);

  { Enhanced Video Renderer first: RenderFile then connects the decoder to it
    instead of picking a legacy renderer - the same choice as MPC-HC's EVR-CP. }
  hr := CoCreateInstance(CLSID_EnhancedVideoRenderer, nil, CLSCTX_INPROC_SERVER, IID_IBaseFilter, evr);
  if hr < 0 then
  begin
    ShutdownPlayer;
    raise Exception.Create('the Enhanced Video Renderer (evr.dll) is not available on this Windows edition');
  end;
  FGraph.AddFilter(evr, 'EVR');
  if Supports(evr, IMFGetService, svc) then
    svc.GetService(MR_VIDEO_RENDER_SERVICE, IMFVideoDisplayControl, FDisplay);
  if FDisplay = nil then
  begin
    ShutdownPlayer;
    raise Exception.Create('the Enhanced Video Renderer has no display control');
  end;
  FDisplay.SetVideoWindow(AHost);
  FDisplay.SetAspectRatioMode(MFVideoARMode_PreservePicture);
  FHostWnd := AHost;

  hr := FGraph.RenderFile(PWideChar(APath), nil);
  if hr < 0 then
  begin
    ShutdownPlayer;
    raise Exception.CreateFmt('no DirectShow filters can open this video (0x%.8x) - install a ' +
      'splitter/decoder pack such as LAV Filters for this format', [Cardinal(hr)]);
  end;

  FControl := FGraph as IMediaControl;
  FSeeking := FGraph as IMediaSeeking;
  { The sound comes from the clip's audio channel - the picture is silent. }
  if Supports(FGraph, IBasicAudio, audio) then audio.put_Volume(MUTED_VOLUME);

  { Paused = prerolled: the first frame is on screen and Run starts instantly. }
  FControl.Pause;
  hr := FControl.GetState(OPEN_TIMEOUT_MS, fs);
  if hr < 0 then
  begin
    ShutdownPlayer;
    raise Exception.CreateFmt('the video would not start (0x%.8x)', [Cardinal(hr)]);
  end;
  FitVideo;
  FOpenPath := APath;
  SetError('');
end;

procedure TMfVideoWorker.SeekTo(ASeconds: Double);
var
  cur, stop: Int64;
begin
  cur := Round(Max(0, ASeconds) * HNS_PER_SECOND);
  stop := 0;
  FSeeking.SetPositions(cur, AM_SEEKING_ABSOLUTE_POSITIONING, stop, AM_SEEKING_NO_POSITIONING);
end;

procedure TMfVideoWorker.SeekPlay(ASeconds: Double);
var
  tick: UInt64;
begin
  { Prepare already parked the picture on this frame: starting from it avoids a
    second (expensive, keyframe-decoding) seek at the very start of playback. }
  if (FStillPos >= 0) and (Abs(FStillPos - ASeconds) < 0.25) then
    ASeconds := FStillPos
  else
    SeekTo(ASeconds);
  FControl.Run;
  tick := GetTickCount64;
  FRunning := True;
  FRunStartTick := tick;
  FRunStartPos := ASeconds;
  FLastSeekTick := tick;
  FLastPollTick := tick;
  FStillPos := -1;
end;

procedure TMfVideoWorker.SeekStill(ASeconds: Double; ATick: UInt64);
begin
  SeekTo(ASeconds);
  FStillPos := ASeconds;
  FLastSeekTick := ATick;
end;

function TMfVideoWorker.PositionSeconds: Double;
var
  cur: Int64;
begin
  Result := -1;
  if (FSeeking <> nil) and (FSeeking.GetCurrentPosition(cur) >= 0) then
    Result := cur / HNS_PER_SECOND;
end;

procedure TMfVideoWorker.Step;
var
  t: TVideoTarget;
  doUpdate: Boolean;
  tick: UInt64;
  want, est, have: Double;
begin
  FLock.Enter;
  try
    t := FTarget;
    FTarget.Prepare := False;
    doUpdate := FUpdatePending;
    FUpdatePending := False;
  finally
    FLock.Leave;
  end;

  try
    if (not t.Active) or (t.Host = 0) or (t.Path = '') then
    begin
      if FRunning and (FControl <> nil) then
      begin
        FControl.Pause;
        FRunning := False;
      end;
      Exit;
    end;

    if SameText(FFailedPath, t.Path) then Exit;
    if (not SameText(FOpenPath, t.Path)) or (FHostWnd <> t.Host) then
    begin
      FFailedPath := t.Path;
      OpenItem(t.Path, t.Host);
      FFailedPath := '';
    end;
    if doUpdate then FitVideo;

    tick := GetTickCount64;
    want := t.WantSeconds;
    if t.Playing then
      want := want + (tick - t.PostTick) / 1000;

    if t.Playing then
    begin
      if not FRunning then
        SeekPlay(want)
      else
      begin
        { free check: has the playhead jumped away from where the running
          picture should be (loop, relocate, clip change)? }
        est := FRunStartPos + (tick - FRunStartTick) / 1000;
        if Abs(est - want) > JUMP_LIMIT_SECONDS then
          SeekPlay(want)
        else if (tick - FLastSeekTick > SETTLE_MS) and (tick - FLastPollTick >= POLL_INTERVAL_MS) then
        begin
          { real position, never while a fresh seek is still settling - it would
            report the old spot and cause an endless seek loop }
          FLastPollTick := tick;
          have := PositionSeconds;
          if (have >= 0) and (Abs(have - want) > DRIFT_LIMIT_SECONDS) then
            SeekPlay(want);
        end;
      end;
    end
    else
    begin
      if FRunning then
      begin
        FControl.Pause;
        FRunning := False;
      end;
      if ((FStillPos < 0) or (Abs(want - FStillPos) > 0.02)) and
         (tick - FLastSeekTick >= SCRUB_MIN_INTERVAL_MS) then
        SeekStill(want, tick);
    end;
  finally
    if t.Prepare then FPrepared.SetEvent;
  end;
end;

{ ========================= TTimelineVideoPlayer ======================= }

constructor TTimelineVideoPlayer.Create(AHost: TWinControl);
begin
  inherited Create;
  FHost := AHost;
  FLastClipId := -1;
  FWorker := TMfVideoWorker.Create;
end;

destructor TTimelineVideoPlayer.Destroy;
begin
  FWorker.Free;
  inherited;
end;

function TTimelineVideoPlayer.GetLastError: string;
begin
  Result := TMfVideoWorker(FWorker).LastError;
end;

{ The disk is asked once per source, not once per UI tick. }
function TTimelineVideoPlayer.FileOk(ASrc: TMediaSource): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(FFileOk) do
    if FFileOk[i].Id = ASrc.Id then Exit(FFileOk[i].Ok);
  Result := FileExists(ASrc.Path);
  SetLength(FFileOk, Length(FFileOk) + 1);
  FFileOk[High(FFileOk)].Id := ASrc.Id;
  FFileOk[High(FFileOk)].Ok := Result;
end;

{ The video clip under the playhead; the first video channel that has one wins,
  and a muted channel or clip shows nothing. }
function TTimelineVideoPlayer.ActiveClip(ATl: TTimeline; ASeconds: Double;
  out ASrc: TMediaSource): TTimelineClip;
var
  i: Integer;
  trk: TTimelineTrack;
  clip: TTimelineClip;
  src: TMediaSource;
begin
  Result := nil;
  ASrc := nil;
  for i := 0 to ATl.TrackCount - 1 do
  begin
    trk := ATl.GetTrack(i);
    if (trk.Kind <> tkVideo) or trk.Muted then Continue;
    clip := trk.ClipAtSeconds(ASeconds);
    if (clip = nil) or clip.Muted or clip.IsMidiClip then Continue;
    src := ATl.SourceById(clip.SourceId);
    if (src = nil) or (src.Kind <> mkVideoFile) then Continue;
    if FileOk(src) then
    begin
      ASrc := src;
      Exit(clip);
    end;
  end;
end;

procedure TTimelineVideoPlayer.Sync(ATl: TTimeline; APlayheadSeconds: Double;
  APlaying: Boolean; ADirection: Integer);
var
  clip: TTimelineClip;
  src: TMediaSource;
  tick: UInt64;
  playing: Boolean;
  seconds: Double;
begin
  if ATl = nil then Exit;
  tick := GetTickCount64;
  if FRenderedPath <> '' then
  begin
    { the rendered file is already in timeline time (tempo, reverse and effects
      are baked in), so it only needs the playhead }
    playing := APlaying and (ADirection > 0);
    seconds := APlayheadSeconds - FRenderedStart;
    if (seconds < 0) or (seconds > FRenderedDuration) then
    begin
      if FLastActive then
      begin
        TMfVideoWorker(FWorker).Post(False, False, '', 0, 0);
        FLastActive := False;
      end;
      Exit;
    end;
    if FLastActive and (FLastClipId = -2) and (FLastPlaying = playing) and
       (tick - FLastPostTick < REPOST_INTERVAL_MS) then Exit;
    TMfVideoWorker(FWorker).Post(True, playing, FRenderedPath, seconds, FHost.Handle);
    FLastActive := True;
    FLastClipId := -2;
    FLastPlaying := playing;
    FLastPostTick := tick;
    Exit;
  end;
  clip := ActiveClip(ATl, APlayheadSeconds, src);
  { The worker extrapolates the playhead itself, so an unchanged state only
    needs re-posting often enough to catch a jump - not on every UI tick. }
  if clip = nil then
  begin
    if FLastActive then
    begin
      TMfVideoWorker(FWorker).Post(False, False, '', 0, 0);
      FLastActive := False;
      FLastClipId := -1;
    end;
    Exit;
  end;
  playing := APlaying and (ADirection > 0) and (not clip.Reversed) and
    (clip.ConformFactor(FStretchBPM) = 1.0);
  if FLastActive and (FLastClipId = clip.Id) and (FLastPlaying = playing) and
     (tick - FLastPostTick < REPOST_INTERVAL_MS) then Exit;
  TMfVideoWorker(FWorker).Post(True, playing, src.Path,
    clip.VideoSourceSecondsAt(APlayheadSeconds, FStretchBPM), FHost.Handle);
  FLastActive := True;
  FLastClipId := clip.Id;
  FLastPlaying := playing;
  FLastPostTick := tick;
end;

procedure TTimelineVideoPlayer.Prepare(ATl: TTimeline; APlayheadSeconds: Double);
var
  clip: TTimelineClip;
  src: TMediaSource;
begin
  FFileOk := nil;                     // re-check the disk once per Play
  FLastActive := False;
  FLastClipId := -1;
  if ATl = nil then Exit;
  if FRenderedPath <> '' then
  begin
    if (APlayheadSeconds >= FRenderedStart) and (APlayheadSeconds <= FRenderedStart + FRenderedDuration) then
      TMfVideoWorker(FWorker).Prepare(True, FRenderedPath, APlayheadSeconds - FRenderedStart, FHost.Handle)
    else
      TMfVideoWorker(FWorker).Post(False, False, '', 0, 0);
    Exit;
  end;
  clip := ActiveClip(ATl, APlayheadSeconds, src);
  if clip = nil then
    TMfVideoWorker(FWorker).Post(False, False, '', 0, 0)
  else
    TMfVideoWorker(FWorker).Prepare(True, src.Path,
      clip.VideoSourceSecondsAt(APlayheadSeconds, FStretchBPM), FHost.Handle);
end;

procedure TTimelineVideoPlayer.Stop;
begin
  FFileOk := nil;
  FLastActive := False;
  FLastClipId := -1;
  TMfVideoWorker(FWorker).Post(False, False, '', 0, 0);
end;

procedure TTimelineVideoPlayer.SetRendered(const AFile: string; AStart, ADuration: Double);
begin
  FRenderedPath := AFile;
  FRenderedStart := AStart;
  FRenderedDuration := ADuration;
  FLastActive := False;
  FLastClipId := -1;
end;

function TTimelineVideoPlayer.RenderedActive: Boolean;
begin
  Result := FRenderedPath <> '';
end;

procedure TTimelineVideoPlayer.HostResized;
begin
  TMfVideoWorker(FWorker).RequestUpdate;
end;

{ ========================== TVideoThumbnailer ========================= }

const
  THUMB_MAX_W = 176;
  THUMB_CACHE_MAX = 48;
  THUMB_STEP_MS = 500;              // hover positions are rounded to this
  THUMB_SEEK_TIMEOUT_MS = 3000;

constructor TVideoThumbnailer.Create(AOnReady: TThreadProcedure);
begin
  FLock := TCriticalSection.Create;
  FWake := TEvent.Create(nil, False, False, '');
  FOnReady := AOnReady;
  FMaxW := THUMB_MAX_W;
  FStepMs := THUMB_STEP_MS;
  inherited Create(False);
end;

procedure TVideoThumbnailer.Configure(AMaxWidth, AStepMs: Integer);
begin
  FLock.Enter;
  try
    FMaxW := Max(32, AMaxWidth);
    FStepMs := Max(20, AStepMs);
  finally
    FLock.Leave;
  end;
end;

destructor TVideoThumbnailer.Destroy;
begin
  Terminate;
  FWake.SetEvent;
  WaitFor;
  inherited;
  FWake.Free;
  FLock.Free;
end;

function TVideoThumbnailer.QuantizeMs(ASeconds: Double): Integer;
begin
  Result := Round(Max(0, ASeconds) * 1000 / FStepMs) * FStepMs;
end;

function TVideoThumbnailer.Cached(const APath: string; AMs: Integer): Boolean;
var
  i: Integer;
begin
  Result := False;
  FLock.Enter;
  try
    for i := 0 to High(FCache) do
      if (FCache[i].Ms = AMs) and SameText(FCache[i].Path, APath) then Exit(True);
  finally
    FLock.Leave;
  end;
end;

procedure TVideoThumbnailer.Store(const AThumb: TVideoThumb);
begin
  FLock.Enter;
  try
    if Length(FCache) >= THUMB_CACHE_MAX then
      Delete(FCache, 0, 1);
    SetLength(FCache, Length(FCache) + 1);
    FCache[High(FCache)] := AThumb;
  finally
    FLock.Leave;
  end;
end;

procedure TVideoThumbnailer.Request(const APath: string; ASeconds: Double);
var
  ms: Integer;
begin
  ms := QuantizeMs(ASeconds);
  if Cached(APath, ms) then Exit;
  FLock.Enter;
  try
    FReqPath := APath;
    FReqMs := ms;
    FReqPending := True;
  finally
    FLock.Leave;
  end;
  FWake.SetEvent;
end;

function TVideoThumbnailer.TryGet(const APath: string; ASeconds: Double; ABmp: TBitmap): Boolean;
var
  i, y, ms, stride: Integer;
begin
  Result := False;
  ms := QuantizeMs(ASeconds);
  FLock.Enter;
  try
    for i := 0 to High(FCache) do
      if (FCache[i].Ms = ms) and SameText(FCache[i].Path, APath) then
      begin
        ABmp.PixelFormat := pf24bit;
        ABmp.SetSize(FCache[i].W, FCache[i].H);
        stride := (FCache[i].W * 3 + 3) and not 3;
        for y := 0 to FCache[i].H - 1 do
          Move(FCache[i].Bits[(FCache[i].H - 1 - y) * stride], ABmp.ScanLine[y]^, stride);
        Exit(True);
      end;
  finally
    FLock.Leave;
  end;
end;

procedure TVideoThumbnailer.CloseGraph;
begin
  if FControl <> nil then FControl.Stop;
  FGrabber := nil;
  FSeeking := nil;
  FControl := nil;
  FGraph := nil;
  FOpenPath := '';
end;

procedure TVideoThumbnailer.OpenGraph(const APath: string);
var
  builder: ICaptureGraphBuilder2;
  src, grabFilter, nullFilter: IBaseFilter;
  mt: TAMMediaType;
  hr: HRESULT;
  fs: TFilterState;
  vih: PVideoInfoHeader;
begin
  CloseGraph;
  if (CoCreateInstance(CLSID_FilterGraph, nil, CLSCTX_INPROC_SERVER, IID_IGraphBuilder, FGraph) < 0) or
     (CoCreateInstance(CLSID_CaptureGraphBuilder2, nil, CLSCTX_INPROC_SERVER, IID_ICaptureGraphBuilder2, builder) < 0) or
     (CoCreateInstance(CLSID_SampleGrabber, nil, CLSCTX_INPROC_SERVER, IID_IBaseFilter, grabFilter) < 0) or
     (CoCreateInstance(CLSID_NullRenderer, nil, CLSCTX_INPROC_SERVER, IID_IBaseFilter, nullFilter) < 0) or
     (not Supports(grabFilter, ISampleGrabber, FGrabber)) then
  begin
    CloseGraph;
    raise Exception.Create('thumbnail graph could not be created');
  end;
  builder.SetFiltergraph(FGraph);
  FillChar(mt, SizeOf(mt), 0);
  mt.majortype := MEDIATYPE_Video;
  mt.subtype := MEDIASUBTYPE_RGB24;
  FGrabber.SetMediaType(mt);
  FGraph.AddFilter(grabFilter, 'Grabber');
  FGraph.AddFilter(nullFilter, 'Null');
  hr := FGraph.AddSourceFilter(PWideChar(APath), 'Source', src);
  if hr >= 0 then
    hr := builder.RenderStream(nil, @MEDIATYPE_Video, src, grabFilter, nullFilter);
  if hr < 0 then
  begin
    CloseGraph;
    raise Exception.CreateFmt('no filters can decode frames of this video (0x%.8x)', [Cardinal(hr)]);
  end;
  FGrabber.SetBufferSamples(True);
  FGrabber.SetOneShot(False);
  FControl := FGraph as IMediaControl;
  FSeeking := FGraph as IMediaSeeking;
  FControl.Pause;
  FControl.GetState(OPEN_TIMEOUT_MS, fs);

  FSrcW := 0;
  FSrcH := 0;
  FTopDown := False;
  FillChar(mt, SizeOf(mt), 0);
  if (FGrabber.GetConnectedMediaType(mt) >= 0) and (mt.pbFormat <> nil) and
     (mt.cbFormat >= SizeOf(TVideoInfoHeader)) then
  begin
    vih := PVideoInfoHeader(mt.pbFormat);
    FSrcW := vih.bmiHeader.biWidth;
    FSrcH := Abs(vih.bmiHeader.biHeight);
    FTopDown := vih.bmiHeader.biHeight < 0;
  end;
  if mt.pbFormat <> nil then CoTaskMemFree(mt.pbFormat);
  if (FSrcW <= 0) or (FSrcH <= 0) then
  begin
    CloseGraph;
    raise Exception.Create('video size unknown');
  end;
  FOpenPath := APath;
end;

function TVideoThumbnailer.Grab(AMs: Integer; var AThumb: TVideoThumb): Boolean;
var
  cur, stop: Int64;
  fs: TFilterState;
  size, dstW, dstH, srcStride, dstStride, x, y, sy, sx: Integer;
  buf: TBytes;
begin
  Result := False;
  cur := Int64(AMs) * 10000;
  stop := 0;
  FSeeking.SetPositions(cur, AM_SEEKING_ABSOLUTE_POSITIONING, stop, AM_SEEKING_NO_POSITIONING);
  FControl.GetState(THUMB_SEEK_TIMEOUT_MS, fs);
  size := 0;
  if FGrabber.GetCurrentBuffer(size, nil) < 0 then Exit;
  srcStride := (FSrcW * 3 + 3) and not 3;
  if size < srcStride * FSrcH then Exit;
  SetLength(buf, size);
  if FGrabber.GetCurrentBuffer(size, @buf[0]) < 0 then Exit;

  dstW := Min(FSrcW, FMaxW);
  dstH := Max(1, Round(FSrcH * dstW / FSrcW));
  dstStride := (dstW * 3 + 3) and not 3;
  SetLength(AThumb.Bits, dstStride * dstH);
  for y := 0 to dstH - 1 do
  begin
    sy := y * FSrcH div dstH;                    // display row, top first
    if not FTopDown then sy := FSrcH - 1 - sy;   // its row in the source buffer
    for x := 0 to dstW - 1 do
    begin
      sx := x * FSrcW div dstW;
      { output is bottom-up: display row y is stored at row dstH-1-y }
      Move(buf[sy * srcStride + sx * 3], AThumb.Bits[(dstH - 1 - y) * dstStride + x * 3], 3);
    end;
  end;
  AThumb.W := dstW;
  AThumb.H := dstH;
  Result := True;
end;

procedure TVideoThumbnailer.Execute;
var
  path: string;
  ms: Integer;
  th: TVideoThumb;
  pending: Boolean;
begin
  CoInitializeEx(nil, COINIT_MULTITHREADED);
  try
    while not Terminated do
    begin
      FWake.WaitFor(INFINITE);
      if Terminated then Break;
      FLock.Enter;
      try
        path := FReqPath;
        ms := FReqMs;
        pending := FReqPending;
        FReqPending := False;
      finally
        FLock.Leave;
      end;
      if (not pending) or Cached(path, ms) or SameText(path, FFailedPath) then Continue;
      try
        if not SameText(path, FOpenPath) then OpenGraph(path);
        th.Path := path;
        th.Ms := ms;
        if Grab(ms, th) then
        begin
          Store(th);
          if Assigned(FOnReady) and not Terminated then TThread.Queue(nil, FOnReady);
        end;
      except
        FFailedPath := path;
        CloseGraph;
      end;
    end;
  finally
    CloseGraph;
    CoUninitialize;
  end;
end;

end.
