unit UDAW.Tracker.Player;
{$I udaw.inc}
{$POINTERMATH ON}

{ Phase 11 - Tracker Engine: the native replay core.

  TTrackerPlayer walks a TTrackerModule's order / patterns at FSpeed ticks per
  row and FBPM (2.5/BPM seconds per tick), keeping per-channel voice state -
  fractional sample position, pitch (as a fractional note), volume, pan,
  envelope positions, fade-out and per-effect memory - and renders Float32
  blocks with 4-point Hermite interpolation (UDAW.DSP.Interpolation) and
  forward / ping-pong looping.

  It implements UDAW's documented internal effect set (see UDAW.Tracker.Types):
  arpeggio, pitch slides + tone portamento, vibrato, tremolo, volume / pan
  slides, set volume / panning, sample offset, position jump, pattern break,
  set speed / BPM, note delay / cut, retrigger and fine volume slides.

  GUI-free and clock-free: RenderBlock is a pure function of state, so the same
  code drives the live device engine (via AsSource) and the offline render the
  tests and the "play pattern" UI action use. }

interface

uses
  SysUtils, Math,
  UDAW.Audio.Types, UDAW.Audio.Buffer, UDAW.Audio.Source, UDAW.Audio.Graph.Nodes,
  UDAW.DSP.Math, UDAW.DSP.Interpolation,
  UDAW.Mixer.Model, UDAW.Mixer.Engine,
  UDAW.Tracker.Types, UDAW.Tracker.Instrument, UDAW.Tracker.Pattern;

const
  { frames the per-channel effect scratch buffers hold - larger than any single mix chunk (a tick or a block) }
  TRK_FX_SCRATCH = 16384;

type
  TTrackerChannel = record
    Active: Boolean;
    InstrIdx: Integer;          // 1-based instrument slot, 0 = none
    SmpLayer: Integer;          // key-map layer of the instrument sounding (0 = its own sample), set on trigger
    SamplePos: Double;
    Direction: Integer;         // +1 / -1 (ping-pong)
    PitchNote: Double;          // fractional note value currently sounding
    Volume: Double;             // 0..1
    Pan: Double;                // -1..+1
    KeyOn: Boolean;
    Released: Boolean;
    FadeoutVol: Double;         // 1 -> 0 after key-off
    VolEnvTick: Integer;
    PanEnvTick: Integer;
    { effect run-time }
    CurEffect: TTrackerEffect;
    CurParam: Byte;
    PortaTargetNote: Double;
    PortaSpeed: Byte;
    TonePortaSpeed: Byte;
    VolSlideParam: Byte;
    PanSlideParam: Byte;
    VibPos, TremPos: Integer;
    VibSpeed, VibDepth: Byte;
    TremSpeed, TremDepth: Byte;
    VibWaveform, TremWaveform: Byte;   // 0=sine 1=ramp-down 2=square 3=random; persists across notes
    RetrigTicks: Byte;
    NoteCutTick: Integer;
    NoteDelayTicks: Integer;
    KeyOffTick: Integer;        // Kxx: tick the note is released on, or -1
    TremorParam: Byte;          // Txy memory
    TremorPos: Integer;
    TremorMute: Boolean;        // inside the silent part of a tremor cycle
    PendingNote: Byte;
    { modulation resolved once per tick }
    ArpSemi: Double;
    VibSemi: Double;
    TremAmp: Double;
  end;

  TTrackerProgressEvent = procedure(Sender: TObject; AFraction: Double) of object;

  TTrackerPlayer = class
  private
    FModule: TTrackerModule;    // not owned
    FSampleRate: Integer;
    FMaxFrames: Integer;
    FSpeed: Integer;
    FBPM: Integer;
    FSamplesPerTick: Double;
    FTickCounter: Double;       // output samples until the next tick boundary
    FOrderPos: Integer;
    FRow: Integer;
    FTick: Integer;
    FPendingOrderJump: Integer;
    FPendingBreakRow: Integer;
    FRunGlobal: Double;              // global volume now (Gxx / Hxy move it), 0..1
    FDelayRows: Integer;             // EEx: extra repeats of the current row still to play
    FRowRepeat: Boolean;             // the row is being repeated: its cells are not re-triggered
    FLoopStartRow: Integer;          // E60: row a pattern loop returns to
    FLoopCounter: Integer;           // E6x: loop-backs still to make
    FPendingLoopRow: Integer;        // E6x: row to return to at the end of this one, or -1
    FLoopSong: Boolean;
    FLoopPatternIdx: Integer;        // >= 0: play only this pattern, round and round (the order list is ignored)
    FSongEnded: Boolean;
    FLoopCount: Integer;
    FChan: array of TTrackerChannel;
    FPeak: array of Single;          // per-channel playback level, 0..1 (UI meter)
    FFxNodes: array of TAudioNode;   // whole-channel effects, nil = none
    FFxRev: Integer;
    FFxIn, FFxOut: TAudioBuffer;     // stereo scratch for effect channels
    FSource: IAudioSource;
    { the Tracker mixer: when a model is attached every channel is rendered to its own stereo
      buffer, fed to the strip whose InputSourceId is channel + 1, and the mixer's master output
      is what RenderBlock returns }
    FMixModel: TMixerModel;          // not owned
    FMixProc: TMixerProcessor;       // owned; nil = channels summed directly
    FMixBridge: IMixInputProvider;
    FChanBufs: array of TAudioBuffer;
    FCapture: Boolean;
    procedure PrepareMixer(AChannels: Integer);
    procedure FreeMixer;
    procedure RebuildFx;
    procedure FreeFx;
    procedure RecalcTickLength;
    procedure ResetChannels;
    function CurrentPattern: TTrackerPattern;
    procedure TriggerNote(var C: TTrackerChannel; ANote: Byte; AResetPos: Boolean);
    procedure ProcessRow;
    procedure ProcessTick;
    { -1..+1 modulation value for the 64-step vibrato/tremolo position cycle
      APos, per FT2's four waveform shapes (sine/ramp-down/square/random). }
    function ModWaveform(APos: Integer; AWaveform: Byte): Double;
    procedure AdvanceEnvelopes;
    procedure AdvanceRow;
    procedure MixSamples(AOut: TAudioBuffer; AStart, ACount: Integer);
  public
    constructor Create(AModule: TTrackerModule);
    destructor Destroy; override;

    procedure Prepare(ASampleRate, AMaxFrames, AChannels: Integer);
    procedure Reset;

    { Routes the channels through the Tracker mixer model (strips TRK-CHN1..n and a master). Call
      before Prepare; nil, or a model that does not validate, plays the channels summed as before. }
    procedure AttachMixer(AModel: TMixerModel);
    { rebuilds the mixer plan after strip / insert edits; only while nothing is being rendered
      (stopped or paused) }
    procedure RefreshMixer;
    { the live processor (nil when none) - for pushing equaliser edits while playing }
    function MixerProcessor: TMixerProcessor;
    { one channel's own output for the block being rendered (nil without a mixer) }
    function ChannelBuffer(AChannel: Integer): TAudioBuffer;

    { RT: render AOut.FrameCount frames of the module from the current position. }
    procedure RenderBlock(AOut: TAudioBuffer);

    { Relocates playback to row 0 of order step AOrderPos (clamped into
      range), effective on the very next RenderBlock - safe to call from
      the UI thread (the "sequence list" jump-to-position action) as well
      as from RenderBlock's own thread. Sounding notes are left ringing,
      same as an ordinary row advance - only the position counters move. }
    procedure JumpToOrder(AOrderPos: Integer);

    { Offline helper: render ATotalFrames into planar (stops early only if the
      song ends and looping is off - then the tail is silence). }
    function RenderToPlanar(ATotalFrames: Integer; AChannels: Integer = 2;
      ABlockFrames: Integer = 0): TAudioPlanar;

    { Offline helper: bounces the whole song exactly once - LoopSong is forced
      off for the duration of the call - stopping as soon as SongEnded fires
      instead of rendering out to a fixed length, so the caller doesn't have
      to know the song's duration up front (e.g. "import this module onto the
      timeline as an audio clip"). AMaxFrames is a safety cap only, in case a
      malformed module never reports SongEnded. AOnProgress, if assigned, is
      called after every block with the 0..1 fraction of AMaxFrames rendered
      so far, so the caller can drive a UI progress bar. }
    function RenderSongToPlanar(AMaxFrames: Integer; AChannels: Integer = 2;
      ABlockFrames: Integer = 0;
      AOnProgress: TTrackerProgressEvent = nil): TAudioPlanar;

    function AsSource: IAudioSource;

    { introspection for the tests and the "play pattern" readout }
    function ChannelCountRT: Integer;
    function DebugChannelActive(AChannel: Integer): Boolean;
    function DebugChannelNote(AChannel: Integer): Double;      // sounding note incl. arp/vibrato
    function DebugChannelVolume(AChannel: Integer): Double;
    { recent peak level of one channel's output, 0..1, decaying (UI LED meter) }
    function ChannelLevel(AChannel: Integer): Double;

    { The pattern number the current order step plays (resolves the order
      list -> pattern index indirection), for live "now playing" UI. -1 if
      there is no module/order to resolve. }
    function CurrentPatternIndex: Integer;

    property LoopSong: Boolean read FLoopSong write FLoopSong;
    { the pattern to play on its own, looping until stopped; -1 plays the song through its order list }
    property LoopPattern: Integer read FLoopPatternIdx write FLoopPatternIdx;
    property Speed: Integer read FSpeed;
    property BPM: Integer read FBPM;
    property CurrentOrder: Integer read FOrderPos;
    property CurrentRow: Integer read FRow;
    property CurrentTick: Integer read FTick;
    property LoopCount: Integer read FLoopCount;
    property SongEnded: Boolean read FSongEnded;
  end;

  { hands each TRK-CHN strip its channel's audio; the strip's constant-power pan law would lose 3 dB
    at the centre of an already panned stereo signal, so the feed is scaled back up by sqrt(2) }
  TTrackerMixBridge = class(TInterfacedObject, IMixInputProvider)
  private
    FPlayer: TTrackerPlayer;    // not owned
    FModel: TMixerModel;        // not owned
  public
    constructor Create(APlayer: TTrackerPlayer; AModel: TMixerModel);
    procedure RenderStripInput(AStripId: Integer; ABuffer: TAudioBuffer);
  end;

  TTrackerSource = class(TInterfacedObject, IAudioSource)
  private
    FPlayer: TTrackerPlayer;    // not owned
  public
    constructor Create(APlayer: TTrackerPlayer);
    procedure Render(ABuffer: TAudioBuffer);
    procedure Prepare(ASampleRate, AMaxFrames, AChannels: Integer);
    procedure Reset;
    function Name: string;
  end;

const
  { the Tracker mixer's strips are named TRK-CHN<n> and take channel n (1-based) of the module }
  TRK_MIXER_STRIP_PREFIX = 'TRK-CHN';

{ Makes AModel the Tracker mixer for a module of AChannels channels: a master strip, and one
  TRK-CHN<n> strip per channel (strips for channels the module no longer has are removed). }
procedure EnsureTrackerMixerStrips(AModel: TMixerModel; AChannels: Integer;
  AModule: TTrackerModule = nil);

implementation


uses
  UDAW.DSP.MathTables;

procedure EnsureTrackerMixerStrips(AModel: TMixerModel; AChannels: Integer;
  AModule: TTrackerModule);
var
  i, ch: Integer;
  s: TMixStrip;
  found: Boolean;
  fx: TTrackerChannelFx;
  kind: TNodeKind;
begin
  if AModel = nil then Exit;
  AModel.EnsureMaster;
  for i := AModel.StripCount - 1 downto 0 do
  begin
    s := AModel.GetStrip(i);
    if (s.Kind = skInput) and (Copy(s.Name, 1, Length(TRK_MIXER_STRIP_PREFIX)) = TRK_MIXER_STRIP_PREFIX) and
       (s.InputSourceId > AChannels) then
      AModel.RemoveStrip(s.Id);
  end;
  for ch := 1 to AChannels do
  begin
    found := False;
    for i := 0 to AModel.StripCount - 1 do
    begin
      s := AModel.GetStrip(i);
      if (s.Kind = skInput) and (s.InputSourceId = ch) then
      begin
        found := True;
        Break;
      end;
    end;
    if found then Continue;
    s := AModel.AddStrip(skInput, TRK_MIXER_STRIP_PREFIX + IntToStr(ch));
    s.InputSourceId := ch;
  end;
  { a channel effect set in the pattern grid's channel header lives on that channel's strip as its
    first insert (older projects kept it on the module: moved over here once) }
  if AModule <> nil then
    for ch := 1 to Min(AChannels, AModule.Channels) do
    begin
      fx := AModule.GetChannelFx(ch - 1);
      if (fx.Kind = '') or not NodeKindFromId(fx.Kind, kind) or not MixerInsertKindAllowed(kind) then Continue;
      for i := 0 to AModel.StripCount - 1 do
      begin
        s := AModel.GetStrip(i);
        if (s.Kind = skInput) and (s.InputSourceId = ch) then
        begin
          s.InsertInsertAt(0, TMixInsert.Make(fx.Kind, fx.Params));
          AModule.SetChannelFx(ch - 1, '', '', '');
          Break;
        end;
      end;
    end;
  { the master carries a flat 16-band graphic EQ from the start, so its sliders are heard at once
    while the Tracker plays (a band moved on a running mixer is pushed into this existing node) }
  s := AModel.MasterStrip;
  found := False;
  for i := 0 to s.InsertCount - 1 do
    if SameText(s.GetInsert(i).Kind, 'graphiceq') and (Pos('bands=16', s.GetInsert(i).Params) > 0) then
      found := True;
  if not found then
    s.AddInsert(TMixInsert.Make('graphiceq', 'bands=16;gains=0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0'));
end;

{ 4-point Hermite (Catmull-Rom) interpolation instead of a plain 2-point
  linear lerp: linear has a -6 dB/octave high-frequency roll-off (see
  UDAW.DSP.Interpolation's header comment), which is audible as a dulled /
  "muffled" tone on any note pitched away from an instrument's root note -
  exactly the symptom tracker playback was reported to have. Taps are
  clamped to the sample's own bounds (matching the previous behaviour at
  the very edges of the data); mid-sample this is a strict quality upgrade. }
function SampleAt(const D: TAudioSampleArray; APos: Double): Single;
var
  i0, n: Integer;
  f: Single;

  function Tap(AIdx: Integer): Single; {$IFDEF FPC}inline;{$ENDIF}
  begin
    if AIdx < 0 then AIdx := 0
    else if AIdx >= n then AIdx := n - 1;
    Result := D[AIdx];
  end;

begin
  n := Length(D);
  if n = 0 then Exit(0);
  if APos < 0 then APos := 0;
  i0 := Trunc(APos);
  if i0 >= n then Exit(0);
  f := Single(APos - i0);
  Result := InterpHermite4(Tap(i0 - 1), Tap(i0), Tap(i0 + 1), Tap(i0 + 2), f);
end;

{ ================= TTrackerPlayer ================= }

constructor TTrackerPlayer.Create(AModule: TTrackerModule);
begin
  inherited Create;
  FModule := AModule;
  FSampleRate := UDAW_DEFAULT_SAMPLE_RATE;
  FMaxFrames := UDAW_DEFAULT_BUFFER_FRAMES;
  FLoopSong := True;
  FLoopPatternIdx := -1;
  FSpeed := TRK_DEFAULT_SPEED;
  FBPM := TRK_DEFAULT_BPM;
  FPendingOrderJump := -1;
  FPendingBreakRow := -1;
  FPendingLoopRow := -1;
  if AModule <> nil then FRunGlobal := AModule.GlobalVolume else FRunGlobal := 1.0;
  RecalcTickLength;
end;

destructor TTrackerPlayer.Destroy;
begin
  FSource := nil;
  FreeMixer;
  FreeFx;
  FFxIn.Free;
  FFxOut.Free;
  inherited Destroy;
end;

procedure TTrackerPlayer.RecalcTickLength;
begin
  if FBPM < TRK_MIN_BPM then FBPM := TRK_MIN_BPM;
  FSamplesPerTick := 2.5 * FSampleRate / FBPM;
end;

procedure TTrackerPlayer.FreeFx;
var
  i: Integer;
begin
  for i := 0 to High(FFxNodes) do FFxNodes[i].Free;
  SetLength(FFxNodes, 0);
end;

{ Builds one DSP node per channel that has a whole-channel effect. Runs on the
  render thread (RenderBlock notices FxRevision changed), never mid-block. }
procedure TTrackerPlayer.RebuildFx;
var
  i: Integer;
  fx: TTrackerChannelFx;
  kind: TNodeKind;
  node: TAudioNode;
begin
  FreeFx;
  FFxRev := FModule.FxRevision;
  SetLength(FFxNodes, FModule.Channels);
  if FFxIn = nil then
  begin
    FFxIn := TAudioBuffer.Create(2, TRK_FX_SCRATCH, FSampleRate);
    FFxOut := TAudioBuffer.Create(2, TRK_FX_SCRATCH, FSampleRate);
  end;
  for i := 0 to High(FFxNodes) do
  begin
    FFxNodes[i] := nil;
    fx := FModule.GetChannelFx(i);
    if (fx.Kind = '') or not NodeKindFromId(fx.Kind, kind) then Continue;
    node := CreateNode(i + 1, kind, fx.Name);
    try
      node.DeserializeParams(fx.Params);
      node.Configure(FSampleRate, TRK_FX_SCRATCH, 2);
      FFxNodes[i] := node;
    except
      node.Free;
    end;
  end;
end;

procedure TTrackerPlayer.Prepare(ASampleRate, AMaxFrames, AChannels: Integer);
begin
  if ASampleRate > 0 then FSampleRate := ASampleRate;
  if AMaxFrames > 0 then FMaxFrames := AMaxFrames;
  Reset;
  PrepareMixer(AChannels);
end;

procedure TTrackerPlayer.AttachMixer(AModel: TMixerModel);
begin
  FMixModel := AModel;
  if AModel = nil then FreeMixer;
end;

procedure TTrackerPlayer.RefreshMixer;
begin
  if FMixModel <> nil then PrepareMixer(2);
end;

function TTrackerPlayer.MixerProcessor: TMixerProcessor;
begin
  Result := FMixProc;
end;

function TTrackerPlayer.ChannelBuffer(AChannel: Integer): TAudioBuffer;
begin
  if (AChannel >= 0) and (AChannel < Length(FChanBufs)) then Result := FChanBufs[AChannel]
  else Result := nil;
end;

procedure TTrackerPlayer.FreeMixer;
var
  i: Integer;
begin
  FreeAndNil(FMixProc);
  FMixBridge := nil;
  for i := 0 to High(FChanBufs) do FChanBufs[i].Free;
  SetLength(FChanBufs, 0);
end;

{ Off the audio thread (Prepare): builds the per-channel buffers and the mixer plan. A model that
  fails validation leaves the player mixing its channels directly. }
procedure TTrackerPlayer.PrepareMixer(AChannels: Integer);
var
  i: Integer;
begin
  FreeMixer;
  if (FMixModel = nil) or (FModule = nil) or (AChannels <> 2) then Exit;
  SetLength(FChanBufs, FModule.Channels);
  for i := 0 to High(FChanBufs) do
  begin
    FChanBufs[i] := TAudioBuffer.Create(2, FMaxFrames, FSampleRate);
    FChanBufs[i].Clear;
  end;
  FMixBridge := TTrackerMixBridge.Create(Self, FMixModel);
  FMixProc := TMixerProcessor.Create(FMixModel);
  try
    FMixProc.SetInputProvider(FMixBridge);
    FMixProc.Prepare(FSampleRate, FMaxFrames, 2);
  except
    on E: Exception do FreeMixer;
  end;
end;

procedure TTrackerPlayer.ResetChannels;
var
  i: Integer;
begin
  SetLength(FChan, FModule.Channels);
  for i := 0 to High(FChan) do
  begin
    FillChar(FChan[i], SizeOf(TTrackerChannel), 0);
    FChan[i].Direction := 1;
    FChan[i].Volume := 1.0;
    FChan[i].FadeoutVol := 1.0;
    FChan[i].CurEffect := tfxNone;
    FChan[i].PendingNote := TRK_NOTE_NONE;
    FChan[i].NoteCutTick := -1;
    FChan[i].NoteDelayTicks := -1;
    FChan[i].KeyOffTick := -1;
  end;
  SetLength(FPeak, FModule.Channels);
  for i := 0 to High(FPeak) do FPeak[i] := 0;
  FFxRev := -1;   // force the effect nodes to be rebuilt (their tails restart too)
end;

procedure TTrackerPlayer.Reset;
begin
  if FModule <> nil then
  begin
    FSpeed := ClampInt(FModule.InitialSpeed, TRK_MIN_SPEED, TRK_MAX_SPEED);
    FBPM := ClampInt(FModule.InitialBPM, TRK_MIN_BPM, TRK_MAX_BPM);
  end;
  RecalcTickLength;
  FOrderPos := 0;
  FRow := 0;
  FTick := 0;
  FTickCounter := 0;
  FPendingOrderJump := -1;
  FPendingBreakRow := -1;
  FPendingLoopRow := -1;
  FLoopStartRow := 0;
  FLoopCounter := 0;
  FDelayRows := 0;
  FRowRepeat := False;
  if FModule <> nil then FRunGlobal := FModule.GlobalVolume else FRunGlobal := 1.0;
  FSongEnded := False;
  FLoopCount := 0;
  ResetChannels;
  if FMixProc <> nil then FMixProc.Reset;
end;

function TTrackerPlayer.CurrentPattern: TTrackerPattern;
begin
  if (FModule <> nil) and (FLoopPatternIdx >= 0) then Exit(FModule.GetPattern(FLoopPatternIdx));
  if (FModule = nil) or (FModule.OrderLength = 0) then Exit(nil);
  Result := FModule.GetPattern(FModule.GetOrder(ClampInt(FOrderPos, 0, FModule.OrderLength - 1)));
end;

procedure TTrackerPlayer.TriggerNote(var C: TTrackerChannel; ANote: Byte; AResetPos: Boolean);
var
  instr, smp: TTrackerInstrument;
begin
  C.PitchNote := ANote;
  C.PortaTargetNote := ANote;
  if AResetPos then
  begin
    C.SamplePos := 0;
    C.Direction := 1;
  end;
  C.Active := True;
  C.KeyOn := True;
  C.Released := False;
  C.FadeoutVol := 1.0;
  C.VolEnvTick := 0;
  C.PanEnvTick := 0;
  C.VibPos := 0;
  C.TremPos := 0;
  instr := FModule.GetInstrument(C.InstrIdx);
  if instr <> nil then
  begin
    C.SmpLayer := instr.KeyMapAt(ANote);
    smp := instr.SampleForNote(ANote);
    C.Volume := smp.Volume;
    C.Pan := smp.Pan;
  end
  else C.SmpLayer := 0;
end;

procedure TTrackerPlayer.ProcessRow;
var
  pat: TTrackerPattern;
  ci: Integer;
  cell: TTrackerCell;
  C: ^TTrackerChannel;
  isTonePorta, isNoteDelay: Boolean;
  instr: TTrackerInstrument;
begin
  pat := CurrentPattern;
  if pat = nil then Exit;

  for ci := 0 to High(FChan) do
  begin
    if ci >= pat.Channels then Break;
    C := @FChan[ci];
    cell := pat.GetCell(FRow, ci);

    C.CurEffect := cell.Effect;
    C.CurParam := cell.Param;
    C.NoteCutTick := -1;
    C.NoteDelayTicks := -1;
    C.KeyOffTick := -1;

    isTonePorta := (cell.Effect = tfxTonePorta) or (cell.Effect = tfxTonePortaVolSlide);
    isNoteDelay := cell.Effect = tfxNoteDelay;

    if cell.Instrument <> TRK_INSTR_NONE then
    begin
      C.InstrIdx := cell.Instrument;
      instr := FModule.GetInstrument(C.InstrIdx);
      if instr <> nil then
      begin
        C.Volume := instr.Volume;
        C.Pan := instr.Pan;
      end;
      C.FadeoutVol := 1.0;
      C.Released := False;
      C.VolEnvTick := 0;
      C.PanEnvTick := 0;
    end;

    case cell.Note of
      TRK_NOTE_NONE: ;
      TRK_NOTE_OFF:
        C.Released := True;
      TRK_NOTE_CUT:
        begin
          C.Volume := 0;
          C.Active := False;
        end;
    else
      if (cell.Note >= TRK_NOTE_MIN) and (cell.Note <= TRK_NOTE_MAX) then
      begin
        if isNoteDelay then
        begin
          C.PendingNote := cell.Note;
          C.NoteDelayTicks := cell.Param and $0F;
        end
        else if isTonePorta and C.Active then
          C.PortaTargetNote := cell.Note
        else
          TriggerNote(C^, cell.Note, True);
      end;
    end;

    { volume column }
    if cell.Volume <= TRK_VOL_MAX then
      C.Volume := cell.Volume / TRK_VOL_MAX;

    { row-scope effect handling }
    case cell.Effect of
      tfxSetVolume:
        C.Volume := ClampInt(cell.Param, 0, TRK_VOL_MAX) / TRK_VOL_MAX;
      tfxSetPanning:
        C.Pan := (cell.Param / 255.0) * 2.0 - 1.0;
      tfxSampleOffset:
        if C.Active then
        begin
          C.SamplePos := cell.Param * 256;
          instr := FModule.GetInstrument(C.InstrIdx);
          if (instr <> nil) and (C.SamplePos >= instr.FrameCount) then
            C.SamplePos := Max(0, instr.FrameCount - 1);
        end;
      tfxPositionJump:
        FPendingOrderJump := cell.Param;
      tfxPatternBreak:
        FPendingBreakRow := cell.Param;
      tfxSetSpeed:
        if cell.Param > 0 then
        begin
          if cell.Param < $20 then
            FSpeed := cell.Param
          else
          begin
            FBPM := ClampInt(cell.Param, TRK_MIN_BPM, TRK_MAX_BPM);
            RecalcTickLength;
          end;
        end;
      tfxSetBPM:
        if cell.Param > 0 then
        begin
          FBPM := ClampInt(cell.Param, TRK_MIN_BPM, TRK_MAX_BPM);
          RecalcTickLength;
        end;
      tfxGlobalVol:
        FRunGlobal := ClampInt(cell.Param, 0, 64) / 64.0;
      tfxKeyOff:
        C.KeyOffTick := cell.Param;
      tfxTremor:
        begin
          if cell.Param > 0 then C.TremorParam := cell.Param;
          C.TremorPos := 0;
        end;
      tfxPatternDelay:
        if not FRowRepeat and (FDelayRows = 0) then FDelayRows := cell.Param and $0F;
      tfxPatternLoop:
        if (cell.Param and $0F) = 0 then FLoopStartRow := FRow
        else
        begin
          if FLoopCounter = 0 then FLoopCounter := cell.Param and $0F
          else Dec(FLoopCounter);
          if FLoopCounter > 0 then FPendingLoopRow := FLoopStartRow;
        end;
      tfxTonePortaVolSlide:
        begin
          if cell.Param > 0 then C.VolSlideParam := cell.Param;
        end;
      tfxVibratoVolSlide:
        begin
          if cell.Param > 0 then C.VolSlideParam := cell.Param;
        end;
      tfxFinePortaUp:
        C.PitchNote := C.PitchNote + (cell.Param and $0F) / 16.0;
      tfxFinePortaDown:
        C.PitchNote := C.PitchNote - (cell.Param and $0F) / 16.0;
      tfxXFinePortaUp:
        C.PitchNote := C.PitchNote + (cell.Param and $0F) / 64.0;
      tfxXFinePortaDown:
        C.PitchNote := C.PitchNote - (cell.Param and $0F) / 64.0;
      tfxFineVolUp:
        C.Volume := C.Volume + (cell.Param and $0F) / TRK_VOL_MAX;
      tfxFineVolDown:
        C.Volume := C.Volume - (cell.Param and $0F) / TRK_VOL_MAX;
      tfxVibrato:
        begin
          if (cell.Param shr 4) > 0 then C.VibSpeed := cell.Param shr 4;
          if (cell.Param and $0F) > 0 then C.VibDepth := cell.Param and $0F;
        end;
      tfxTremolo:
        begin
          if (cell.Param shr 4) > 0 then C.TremSpeed := cell.Param shr 4;
          if (cell.Param and $0F) > 0 then C.TremDepth := cell.Param and $0F;
        end;
      tfxPortaUp, tfxPortaDown:
        if cell.Param > 0 then C.PortaSpeed := cell.Param;
      tfxTonePorta:
        if cell.Param > 0 then C.TonePortaSpeed := cell.Param;
      tfxVolSlide, tfxPanSlide:
        if cell.Param > 0 then
        begin
          if cell.Effect = tfxVolSlide then C.VolSlideParam := cell.Param
          else C.PanSlideParam := cell.Param;
        end;
      tfxRetrigger:
        C.RetrigTicks := Max(1, cell.Param and $0F);
      tfxNoteCut:
        C.NoteCutTick := cell.Param and $0F;
      tfxVibratoWaveform:
        C.VibWaveform := cell.Param and $03;
      tfxTremoloWaveform:
        C.TremWaveform := cell.Param and $03;
    end;

    if C.Volume < 0 then C.Volume := 0 else if C.Volume > 1 then C.Volume := 1;
    if C.Pan < -1 then C.Pan := -1 else if C.Pan > 1 then C.Pan := 1;

    C.ArpSemi := 0;
    C.VibSemi := 0;
    C.TremAmp := 0;
  end;
end;

{ FT2's four vibrato/tremolo shapes over a 64-step position cycle (APos is
  already wrapped "and $3F" by the caller). Sine matches the pre-existing
  formula bit-for-bit; ramp-down/square/random are the previously-missing
  shapes (see UDAW.Codec.XM.pas's E4y/E7y import). "Random" approximates
  FT2's per-step noise rather than reproducing its exact PRNG. }
function TTrackerPlayer.ModWaveform(APos: Integer; AWaveform: Byte): Double;
begin
  case AWaveform and $03 of
    1: Result := 1.0 - (APos and $3F) / 32.0;                    // ramp down
    2: if (APos and $3F) < 32 then Result := 1.0 else Result := -1.0;  // square
    3: Result := Random * 2.0 - 1.0;                             // random
  else
    Result := FastSin(APos * DSP_PI / 32.0);                         // sine
  end;
end;

procedure TTrackerPlayer.ProcessTick;
var
  ci: Integer;
  C: ^TTrackerChannel;
  arp: Integer;
  d: Double;
begin
  for ci := 0 to High(FChan) do
  begin
    C := @FChan[ci];
    C.ArpSemi := 0;
    C.VibSemi := 0;
    C.TremAmp := 0;
    C.TremorMute := False;

    case C.CurEffect of
      tfxArpeggio:
        if C.CurParam <> 0 then
        begin
          case FTick mod 3 of
            1: arp := C.CurParam shr 4;
            2: arp := C.CurParam and $0F;
          else
            arp := 0;
          end;
          C.ArpSemi := arp;
        end;
      tfxPortaUp:
        if FTick > 0 then C.PitchNote := C.PitchNote + C.PortaSpeed / 16.0;
      tfxPortaDown:
        if FTick > 0 then C.PitchNote := C.PitchNote - C.PortaSpeed / 16.0;
      tfxTonePorta, tfxTonePortaVolSlide:
        if FTick > 0 then
        begin
          d := C.TonePortaSpeed / 16.0;
          if C.PitchNote < C.PortaTargetNote then
            C.PitchNote := Min(C.PortaTargetNote, C.PitchNote + d)
          else if C.PitchNote > C.PortaTargetNote then
            C.PitchNote := Max(C.PortaTargetNote, C.PitchNote - d);
        end;
      tfxVibrato, tfxVibratoVolSlide:
        begin
          C.VibPos := (C.VibPos + C.VibSpeed) and $3F;
          C.VibSemi := ModWaveform(C.VibPos, C.VibWaveform) * (C.VibDepth / 16.0);
        end;
      tfxTremolo:
        begin
          C.TremPos := (C.TremPos + C.TremSpeed) and $3F;
          C.TremAmp := ModWaveform(C.TremPos, C.TremWaveform) * (C.TremDepth / 64.0);
        end;
      tfxVolSlide:
        if FTick > 0 then
          C.Volume := C.Volume + (C.VolSlideParam shr 4) / TRK_VOL_MAX
                              - (C.VolSlideParam and $0F) / TRK_VOL_MAX;
      tfxGlobalVolSlide:
        if FTick > 0 then
          FRunGlobal := Min(1.0, Max(0.0, FRunGlobal + ((C.CurParam shr 4) - (C.CurParam and $0F)) / 64.0));
      tfxKeyOff:
        if FTick = C.KeyOffTick then C.Released := True;
      tfxTremor:
        begin
          arp := (C.TremorParam shr 4) + 1;                     // ticks sounding
          C.TremorMute := (C.TremorPos mod (arp + (C.TremorParam and $0F) + 1)) >= arp;
          Inc(C.TremorPos);
        end;
      tfxPanSlide:
        if FTick > 0 then
          C.Pan := C.Pan + ((C.PanSlideParam shr 4) - (C.PanSlideParam and $0F)) / 32.0;
      tfxRetrigger:
        if (FTick > 0) and (C.RetrigTicks > 0) and (FTick mod C.RetrigTicks = 0) then
          C.SamplePos := 0;
      tfxNoteCut:
        if (C.NoteCutTick >= 0) and (FTick = C.NoteCutTick) then
          C.Volume := 0;
      tfxNoteDelay:
        if (C.NoteDelayTicks >= 0) and (FTick = C.NoteDelayTicks)
           and (C.PendingNote <> TRK_NOTE_NONE) then
        begin
          TriggerNote(C^, C.PendingNote, True);
          C.PendingNote := TRK_NOTE_NONE;
        end;
    end;

    if ((C.CurEffect = tfxTonePortaVolSlide) or (C.CurEffect = tfxVibratoVolSlide)) and (FTick > 0) then
      C.Volume := C.Volume + (C.VolSlideParam shr 4) / TRK_VOL_MAX
                          - (C.VolSlideParam and $0F) / TRK_VOL_MAX;

    if C.Volume < 0 then C.Volume := 0 else if C.Volume > 1 then C.Volume := 1;
    if C.Pan < -1 then C.Pan := -1 else if C.Pan > 1 then C.Pan := 1;
  end;
end;

procedure TTrackerPlayer.AdvanceEnvelopes;
var
  ci: Integer;
  C: ^TTrackerChannel;
  instr: TTrackerInstrument;
begin
  for ci := 0 to High(FChan) do
  begin
    C := @FChan[ci];
    FPeak[ci] := FPeak[ci] * 0.97;
    if not C.Active then Continue;
    instr := FModule.GetInstrument(C.InstrIdx);
    if instr = nil then Continue;

    if instr.VolEnv.Enabled then
    begin
      if not (C.KeyOn and (instr.VolEnv.SustainPoint >= 0) and not C.Released
              and (C.VolEnvTick >= instr.VolEnv.Points[
                     ClampInt(instr.VolEnv.SustainPoint, 0, High(instr.VolEnv.Points))].Tick)) then
        Inc(C.VolEnvTick);
    end;
    if instr.PanEnv.Enabled then
      Inc(C.PanEnvTick);

    if C.Released and (instr.Fadeout > 0) then
    begin
      C.FadeoutVol := C.FadeoutVol - instr.Fadeout;
      if C.FadeoutVol <= 0 then
      begin
        C.FadeoutVol := 0;
        C.Active := False;
      end;
    end;
  end;
end;

procedure TTrackerPlayer.AdvanceRow;
var
  pat: TTrackerPattern;
begin
  pat := CurrentPattern;

  { EEx: stay on the row for the extra repeats (its cells are not triggered again) }
  if FDelayRows > 0 then
  begin
    Dec(FDelayRows);
    FRowRepeat := True;
    Exit;
  end;
  FRowRepeat := False;

  { a pattern played on its own: a jump has nowhere to go, a break or loop sets the row, and the end
    of the pattern starts it over }
  if FLoopPatternIdx >= 0 then
  begin
    if FPendingBreakRow >= 0 then FRow := FPendingBreakRow
    else if FPendingLoopRow >= 0 then FRow := FPendingLoopRow
    else Inc(FRow);
    FPendingOrderJump := -1;
    FPendingBreakRow := -1;
    FPendingLoopRow := -1;
    if (pat = nil) or (FRow < 0) or (FRow >= pat.Rows) then FRow := 0;
    Exit;
  end;

  if FPendingOrderJump >= 0 then
  begin
    FOrderPos := FPendingOrderJump;
    FRow := 0;
    FLoopStartRow := 0;
    FLoopCounter := 0;
  end
  else if (FPendingLoopRow >= 0) and (FPendingBreakRow < 0) then
    FRow := FPendingLoopRow   // E6x: back to the loop start in the same pattern
  else if FPendingBreakRow >= 0 then
  begin
    Inc(FOrderPos);
    FRow := FPendingBreakRow;
  end
  else
  begin
    Inc(FRow);
    if (pat = nil) or (FRow >= pat.Rows) then
    begin
      FRow := 0;
      Inc(FOrderPos);
    end;
  end;

  FPendingOrderJump := -1;
  FPendingBreakRow := -1;
  FPendingLoopRow := -1;

  if (FModule.OrderLength = 0) or (FOrderPos >= FModule.OrderLength) then
  begin
    if FLoopSong then
    begin
      FOrderPos := ClampInt(FModule.RestartPos, 0, Max(0, FModule.OrderLength - 1));
      Inc(FLoopCount);
    end
    else
    begin
      FSongEnded := True;
      FOrderPos := Max(0, FModule.OrderLength - 1);
    end;
  end;

  pat := CurrentPattern;
  if (pat <> nil) and (FRow >= pat.Rows) then
    FRow := pat.Rows - 1;
end;

procedure TTrackerPlayer.MixSamples(AOut: TAudioBuffer; AStart, ACount: Integer);
var
  ci, i, nOut: Integer;
  C: ^TTrackerChannel;
  instr, smp: TTrackerInstrument;
  inc_, renderNote, chanVol, volEnvV, panEff, gl, gr, s: Double;
  loopLen: Integer;
  pL, pR: PSingle;
  gVol: Double;
  tlS, trS: Single;
  tL, tR: PSingle;
  tOff, k: Integer;
  useFx: Boolean;
  pk, a: Single;
  fxL, fxR: PSingle;
begin
  nOut := AOut.ChannelCount;
  if nOut = 0 then Exit;
  gVol := FRunGlobal;
  pL := PSingle(AOut.ChannelPtr(0));
  if nOut >= 2 then pR := PSingle(AOut.ChannelPtr(1)) else pR := pL;

  for ci := 0 to High(FChan) do
  begin
    C := @FChan[ci];
    if not C.Active then Continue;
    instr := FModule.GetInstrument(C.InstrIdx);
    if instr = nil then Continue;
    smp := instr;
    if (C.SmpLayer > 0) and (C.SmpLayer <= instr.LayerCount) and
       (instr.Layers[C.SmpLayer - 1].FrameCount > 0) then
      smp := instr.Layers[C.SmpLayer - 1];
    if smp.FrameCount = 0 then Continue;
    if FCapture then
    begin
      pL := PSingle(FChanBufs[ci].ChannelPtr(0));
      pR := PSingle(FChanBufs[ci].ChannelPtr(1));
    end;

    renderNote := C.PitchNote + C.ArpSemi + C.VibSemi;
    inc_ := SemitoneRatio(renderNote - smp.RootNote)
            * smp.SampleRate / FSampleRate;
    if inc_ <= 0 then Continue;

    chanVol := C.Volume * C.FadeoutVol * (1.0 + C.TremAmp) * gVol;
    if (chanVol < 0) or C.TremorMute or FModule.ChannelMuted(ci) then chanVol := 0;

    volEnvV := 1.0;
    if instr.VolEnv.Enabled then
      volEnvV := instr.VolEnv.ValueAt(C.VolEnvTick);

    panEff := C.Pan;
    if instr.PanEnv.Enabled then
      panEff := ClampInt(Round((C.Pan + (instr.PanEnv.ValueAt(C.PanEnvTick) * 2.0 - 1.0)) * 1000), -1000, 1000) / 1000.0;

    PanGains(Single(panEff), plConstantPower, tlS, trS);
    gl := tlS;
    gr := trS;
    chanVol := chanVol * volEnvV;

    loopLen := smp.LoopEnd - smp.LoopStart;

    useFx := (ci < Length(FFxNodes)) and (FFxNodes[ci] <> nil) and (FFxIn <> nil)
      and (ACount <= TRK_FX_SCRATCH);
    pk := 0;
    if useFx then
    begin
      FFxIn.SetActiveFrames(ACount);
      FFxOut.SetActiveFrames(ACount);
      tL := PSingle(FFxIn.ChannelPtr(0));
      tR := PSingle(FFxIn.ChannelPtr(1));
      FillChar(tL^, ACount * SizeOf(Single), 0);
      FillChar(tR^, ACount * SizeOf(Single), 0);
      tOff := 0;
    end
    else
    begin
      tL := pL;
      tR := pR;
      tOff := AStart;
    end;

    for i := 0 to ACount - 1 do
    begin
      if not C.Active then Break;

      s := SampleAt(smp.Data, C.SamplePos) * chanVol;
      tL[tOff + i] := tL[tOff + i] + Single(s * gl);
      tR[tOff + i] := tR[tOff + i] + Single(s * gr);
      a := Abs(Single(s));
      if a > pk then pk := a;

      C.SamplePos := C.SamplePos + inc_ * C.Direction;

      case smp.LoopMode of
        tlmForward:
          if (loopLen > 0) and (C.SamplePos >= smp.LoopEnd) then
            C.SamplePos := C.SamplePos - loopLen;
        tlmPingPong:
          if loopLen > 0 then
          begin
            if (C.Direction > 0) and (C.SamplePos >= smp.LoopEnd) then
            begin
              C.SamplePos := smp.LoopEnd - (C.SamplePos - smp.LoopEnd) - 1;
              C.Direction := -1;
            end
            else if (C.Direction < 0) and (C.SamplePos <= smp.LoopStart) then
            begin
              C.SamplePos := smp.LoopStart + (smp.LoopStart - C.SamplePos) + 1;
              C.Direction := 1;
            end;
          end;
      else
        if C.SamplePos >= smp.FrameCount then
        begin
          C.Active := False;
          C.SamplePos := smp.FrameCount;
        end;
      end;
    end;

    if useFx then
    begin
      FFxNodes[ci].Process(FFxIn, FFxOut);
      fxL := PSingle(FFxOut.ChannelPtr(0));
      fxR := PSingle(FFxOut.ChannelPtr(1));
      for k := 0 to ACount - 1 do
      begin
        pL[AStart + k] := pL[AStart + k] + fxL[k];
        pR[AStart + k] := pR[AStart + k] + fxR[k];
        a := Abs(fxL[k]);
        if a > pk then pk := a;
      end;
    end;
    if pk > FPeak[ci] then FPeak[ci] := pk;
  end;
end;

procedure TTrackerPlayer.RenderBlock(AOut: TAudioBuffer);
var
  n, i, chunk: Integer;
  useMix: Boolean;
begin
  n := AOut.FrameCount;
  AOut.Clear;
  if (FModule = nil) or (FModule.OrderLength = 0) then Exit;
  if FFxRev <> FModule.FxRevision then RebuildFx;

  useMix := (FMixProc <> nil) and (AOut.ChannelCount = 2) and (Length(FChanBufs) >= Length(FChan)) and
    (n <= FMaxFrames);
  if useMix then
    for i := 0 to High(FChanBufs) do
    begin
      FChanBufs[i].SetActiveFrames(n);
      FChanBufs[i].Clear;
    end;
  FCapture := useMix;

  i := 0;
  while i < n do
  begin
    if (FTickCounter <= 0.0) and FSongEnded and not FLoopSong then
      { the sequence has finished and must not start over: only let the voices already sounding
        run out (a one-shot audition plays its note once) }
      FTickCounter := FSamplesPerTick
    else if FTickCounter <= 0.0 then
    begin
      if (FTick = 0) and not FRowRepeat then ProcessRow;
      ProcessTick;
      AdvanceEnvelopes;

      Inc(FTick);
      if FTick >= FSpeed then
      begin
        FTick := 0;
        AdvanceRow;
      end;

      FTickCounter := FTickCounter + FSamplesPerTick;
    end;

    chunk := n - i;
    if chunk > Trunc(FTickCounter) + 1 then chunk := Trunc(FTickCounter) + 1;
    if chunk < 1 then chunk := 1;
    if chunk > n - i then chunk := n - i;

    MixSamples(AOut, i, chunk);

    FTickCounter := FTickCounter - chunk;
    i := i + chunk;
  end;
  FCapture := False;
  if useMix then FMixProc.ProcessBlock(AOut);
end;

procedure TTrackerPlayer.JumpToOrder(AOrderPos: Integer);
begin
  if (FModule = nil) or (FModule.OrderLength = 0) then Exit;
  FOrderPos := ClampInt(AOrderPos, 0, FModule.OrderLength - 1);
  FRow := 0;
  FTick := 0;
  FTickCounter := 0;
  FPendingOrderJump := -1;
  FPendingBreakRow := -1;
  FPendingLoopRow := -1;
  FLoopStartRow := 0;
  FLoopCounter := 0;
  FDelayRows := 0;
  FRowRepeat := False;
  FSongEnded := False;
end;

function TTrackerPlayer.RenderToPlanar(ATotalFrames, AChannels, ABlockFrames: Integer): TAudioPlanar;
var
  buf: TAudioBuffer;
  done, nn, ch, k: Integer;
begin
  if AChannels < 1 then AChannels := 2;
  if ABlockFrames <= 0 then ABlockFrames := 1024;
  if ATotalFrames < 0 then ATotalFrames := 0;
  SetLength(Result, AChannels);
  for ch := 0 to AChannels - 1 do
    SetLength(Result[ch], ATotalFrames);
  buf := TAudioBuffer.Create(AChannels, ABlockFrames, FSampleRate);
  try
    Prepare(FSampleRate, ABlockFrames, AChannels);
    done := 0;
    while done < ATotalFrames do
    begin
      nn := ATotalFrames - done;
      if nn > ABlockFrames then nn := ABlockFrames;
      buf.SetActiveFrames(nn);
      RenderBlock(buf);
      for ch := 0 to AChannels - 1 do
        for k := 0 to nn - 1 do
          Result[ch][done + k] := buf.ChannelPtr(ch)[k];
      Inc(done, nn);
    end;
  finally
    buf.Free;
  end;
end;

function TTrackerPlayer.RenderSongToPlanar(AMaxFrames, AChannels,
  ABlockFrames: Integer; AOnProgress: TTrackerProgressEvent): TAudioPlanar;
var
  buf: TAudioBuffer;
  done, nn, ch, k: Integer;
  savedLoop: Boolean;
begin
  if AChannels < 1 then AChannels := 2;
  if ABlockFrames <= 0 then ABlockFrames := 1024;
  if AMaxFrames < 0 then AMaxFrames := 0;
  savedLoop := FLoopSong;
  FLoopSong := False;
  SetLength(Result, AChannels);
  for ch := 0 to AChannels - 1 do
    SetLength(Result[ch], AMaxFrames);
  buf := TAudioBuffer.Create(AChannels, ABlockFrames, FSampleRate);
  try
    Prepare(FSampleRate, ABlockFrames, AChannels);
    done := 0;
    while (done < AMaxFrames) and (not FSongEnded) do
    begin
      nn := AMaxFrames - done;
      if nn > ABlockFrames then nn := ABlockFrames;
      buf.SetActiveFrames(nn);
      RenderBlock(buf);
      for ch := 0 to AChannels - 1 do
        for k := 0 to nn - 1 do
          Result[ch][done + k] := buf.ChannelPtr(ch)[k];
      Inc(done, nn);
      if Assigned(AOnProgress) and (AMaxFrames > 0) then
        AOnProgress(Self, done / AMaxFrames);
    end;
  finally
    buf.Free;
    FLoopSong := savedLoop;
  end;
  for ch := 0 to AChannels - 1 do
    SetLength(Result[ch], done);
end;

function TTrackerPlayer.AsSource: IAudioSource;
begin
  if FSource = nil then
    FSource := TTrackerSource.Create(Self);
  Result := FSource;
end;

function TTrackerPlayer.ChannelCountRT: Integer;
begin
  Result := Length(FChan);
end;

function TTrackerPlayer.DebugChannelActive(AChannel: Integer): Boolean;
begin
  Result := (AChannel >= 0) and (AChannel < Length(FChan)) and FChan[AChannel].Active;
end;

function TTrackerPlayer.DebugChannelNote(AChannel: Integer): Double;
begin
  if (AChannel < 0) or (AChannel >= Length(FChan)) then Exit(0);
  Result := FChan[AChannel].PitchNote + FChan[AChannel].ArpSemi + FChan[AChannel].VibSemi;
end;

function TTrackerPlayer.ChannelLevel(AChannel: Integer): Double;
begin
  if (AChannel < 0) or (AChannel >= Length(FPeak)) then Exit(0);
  Result := FPeak[AChannel];
end;

function TTrackerPlayer.DebugChannelVolume(AChannel: Integer): Double;
begin
  if (AChannel < 0) or (AChannel >= Length(FChan)) then Exit(0);
  Result := FChan[AChannel].Volume;
end;

function TTrackerPlayer.CurrentPatternIndex: Integer;
begin
  if (FModule <> nil) and (FLoopPatternIdx >= 0) and (FLoopPatternIdx < FModule.PatternCount) then Exit(FLoopPatternIdx);
  if (FModule = nil) or (FModule.OrderLength = 0) then Exit(-1);
  Result := FModule.GetOrder(ClampInt(FOrderPos, 0, FModule.OrderLength - 1));
end;

{ ================= TTrackerMixBridge ================= }

constructor TTrackerMixBridge.Create(APlayer: TTrackerPlayer; AModel: TMixerModel);
begin
  inherited Create;
  FPlayer := APlayer;
  FModel := AModel;
end;

procedure TTrackerMixBridge.RenderStripInput(AStripId: Integer; ABuffer: TAudioBuffer);
const
  CENTRE_PAN_MAKEUP = 1.41421356;
var
  strip: TMixStrip;
  src: TAudioBuffer;
begin
  strip := FModel.StripById(AStripId);
  if (strip = nil) or (strip.InputSourceId < 1) then Exit;
  src := FPlayer.ChannelBuffer(strip.InputSourceId - 1);
  if (src = nil) or (src.FrameCount <> ABuffer.FrameCount) then Exit;
  ABuffer.MixFrom(src, CENTRE_PAN_MAKEUP);
end;

{ ================= TTrackerSource ================= }

constructor TTrackerSource.Create(APlayer: TTrackerPlayer);
begin
  inherited Create;
  FPlayer := APlayer;
end;

procedure TTrackerSource.Render(ABuffer: TAudioBuffer);
begin
  FPlayer.RenderBlock(ABuffer);
end;

procedure TTrackerSource.Prepare(ASampleRate, AMaxFrames, AChannels: Integer);
begin
  FPlayer.Prepare(ASampleRate, AMaxFrames, AChannels);
end;

procedure TTrackerSource.Reset;
begin
  FPlayer.Reset;
end;

function TTrackerSource.Name: string;
begin
  Result := 'tracker';
end;

end.
