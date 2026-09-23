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
  UDAW.Audio.Types, UDAW.Audio.Buffer, UDAW.Audio.Source,
  UDAW.DSP.Math, UDAW.DSP.Interpolation,
  UDAW.Tracker.Types, UDAW.Tracker.Instrument, UDAW.Tracker.Pattern;

type
  TTrackerChannel = record
    Active: Boolean;
    InstrIdx: Integer;          // 1-based instrument slot, 0 = none
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
    FLoopSong: Boolean;
    FSongEnded: Boolean;
    FLoopCount: Integer;
    FChan: array of TTrackerChannel;
    FSource: IAudioSource;
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

    { The pattern number the current order step plays (resolves the order
      list -> pattern index indirection), for live "now playing" UI. -1 if
      there is no module/order to resolve. }
    function CurrentPatternIndex: Integer;

    property LoopSong: Boolean read FLoopSong write FLoopSong;
    property Speed: Integer read FSpeed;
    property BPM: Integer read FBPM;
    property CurrentOrder: Integer read FOrderPos;
    property CurrentRow: Integer read FRow;
    property CurrentTick: Integer read FTick;
    property LoopCount: Integer read FLoopCount;
    property SongEnded: Boolean read FSongEnded;
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

implementation

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
  FSpeed := TRK_DEFAULT_SPEED;
  FBPM := TRK_DEFAULT_BPM;
  RecalcTickLength;
end;

destructor TTrackerPlayer.Destroy;
begin
  FSource := nil;
  inherited Destroy;
end;

procedure TTrackerPlayer.RecalcTickLength;
begin
  if FBPM < TRK_MIN_BPM then FBPM := TRK_MIN_BPM;
  FSamplesPerTick := 2.5 * FSampleRate / FBPM;
end;

procedure TTrackerPlayer.Prepare(ASampleRate, AMaxFrames, AChannels: Integer);
begin
  if ASampleRate > 0 then FSampleRate := ASampleRate;
  if AMaxFrames > 0 then FMaxFrames := AMaxFrames;
  Reset;
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
  end;
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
  FSongEnded := False;
  FLoopCount := 0;
  ResetChannels;
end;

function TTrackerPlayer.CurrentPattern: TTrackerPattern;
begin
  if (FModule = nil) or (FModule.OrderLength = 0) then Exit(nil);
  Result := FModule.GetPattern(FModule.GetOrder(ClampInt(FOrderPos, 0, FModule.OrderLength - 1)));
end;

procedure TTrackerPlayer.TriggerNote(var C: TTrackerChannel; ANote: Byte; AResetPos: Boolean);
var
  instr: TTrackerInstrument;
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
    C.Volume := instr.Volume;
    C.Pan := instr.Pan;
  end;
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

    isTonePorta := cell.Effect = tfxTonePorta;
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
    Result := Sin(APos * DSP_PI / 32.0);                         // sine
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
      tfxTonePorta:
        if FTick > 0 then
        begin
          d := C.TonePortaSpeed / 16.0;
          if C.PitchNote < C.PortaTargetNote then
            C.PitchNote := Min(C.PortaTargetNote, C.PitchNote + d)
          else if C.PitchNote > C.PortaTargetNote then
            C.PitchNote := Max(C.PortaTargetNote, C.PitchNote - d);
        end;
      tfxVibrato:
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

  if FPendingOrderJump >= 0 then
  begin
    FOrderPos := FPendingOrderJump;
    FRow := 0;
  end
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
  instr: TTrackerInstrument;
  inc_, renderNote, chanVol, volEnvV, panEff, gl, gr, s: Double;
  loopLen: Integer;
  pL, pR: PSingle;
  gVol: Double;
  tlS, trS: Single;
begin
  nOut := AOut.ChannelCount;
  if nOut = 0 then Exit;
  gVol := FModule.GlobalVolume;
  pL := PSingle(AOut.ChannelPtr(0));
  if nOut >= 2 then pR := PSingle(AOut.ChannelPtr(1)) else pR := pL;

  for ci := 0 to High(FChan) do
  begin
    C := @FChan[ci];
    if not C.Active then Continue;
    instr := FModule.GetInstrument(C.InstrIdx);
    if (instr = nil) or (instr.FrameCount = 0) then Continue;

    renderNote := C.PitchNote + C.ArpSemi + C.VibSemi;
    inc_ := Power(2.0, (renderNote - instr.RootNote) / 12.0)
            * instr.SampleRate / FSampleRate;
    if inc_ <= 0 then Continue;

    chanVol := C.Volume * C.FadeoutVol * (1.0 + C.TremAmp) * gVol;
    if chanVol < 0 then chanVol := 0;

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

    loopLen := instr.LoopEnd - instr.LoopStart;

    for i := 0 to ACount - 1 do
    begin
      if not C.Active then Break;

      s := SampleAt(instr.Data, C.SamplePos) * chanVol;
      pL[AStart + i] := pL[AStart + i] + Single(s * gl);
      pR[AStart + i] := pR[AStart + i] + Single(s * gr);

      C.SamplePos := C.SamplePos + inc_ * C.Direction;

      case instr.LoopMode of
        tlmForward:
          if (loopLen > 0) and (C.SamplePos >= instr.LoopEnd) then
            C.SamplePos := C.SamplePos - loopLen;
        tlmPingPong:
          if loopLen > 0 then
          begin
            if (C.Direction > 0) and (C.SamplePos >= instr.LoopEnd) then
            begin
              C.SamplePos := instr.LoopEnd - (C.SamplePos - instr.LoopEnd) - 1;
              C.Direction := -1;
            end
            else if (C.Direction < 0) and (C.SamplePos <= instr.LoopStart) then
            begin
              C.SamplePos := instr.LoopStart + (instr.LoopStart - C.SamplePos) + 1;
              C.Direction := 1;
            end;
          end;
      else
        if C.SamplePos >= instr.FrameCount then
        begin
          C.Active := False;
          C.SamplePos := instr.FrameCount;
        end;
      end;
    end;
  end;
end;

procedure TTrackerPlayer.RenderBlock(AOut: TAudioBuffer);
var
  n, i, chunk: Integer;
begin
  n := AOut.FrameCount;
  AOut.Clear;
  if (FModule = nil) or (FModule.OrderLength = 0) then Exit;

  i := 0;
  while i < n do
  begin
    if FTickCounter <= 0.0 then
    begin
      if FTick = 0 then ProcessRow;
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

function TTrackerPlayer.DebugChannelVolume(AChannel: Integer): Double;
begin
  if (AChannel < 0) or (AChannel >= Length(FChan)) then Exit(0);
  Result := FChan[AChannel].Volume;
end;

function TTrackerPlayer.CurrentPatternIndex: Integer;
begin
  if (FModule = nil) or (FModule.OrderLength = 0) then Exit(-1);
  Result := FModule.GetOrder(ClampInt(FOrderPos, 0, FModule.OrderLength - 1));
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
