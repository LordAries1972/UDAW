unit UDAW.Drum.Machine;

{ UDAW's drum machine: sample pads on every MIDI note 0..127, shown 16 at a time
  (a 4x4 bank that scrolls; the default view is C1..D#2, notes 36..51).

  Each pad holds one decoded sample and its own level, pan, mute, solo, choke group
  and play mode (one-shot plays to the end, gate stops when the note is released).
  Hits fire a voice from a fixed pool; a hit on a pad of a choke group cuts every
  other voice of that group (open / closed hi-hat).

  Threading. Hit / Release / StopAll may be called from any thread - the UI, a MIDI
  input thread, or the real-time audio thread (when the MIDI synth routes channel-10
  notes here). They only enqueue a command in a lock-free multi-producer ring;
  RenderAdd (real-time thread) consumes the ring, owns every voice, and allocates
  nothing. Loading a pad (UI thread) builds the new sample first and publishes it
  with one pointer write; the replaced sample is retired and freed only after no
  voice uses it and a grace period has passed.

  As an IAudioSource it plays stand-alone (pad audition); TMidiSynth.DrumMachine
  plugs the same instance into the MIDI engine so a clip's channel-10 notes play
  the pads.

  The machine also carries a small step sequencer for auditioning a pattern: the
  UI publishes an immutable TDrumSeqData (the hits of each step) and the real-time
  thread fires them sample-accurately, looping, while the sequence runs. }

interface

uses
  System.SysUtils, System.Classes, System.Math, System.Generics.Collections,
  System.SyncObjs, System.IOUtils, UDAW.Audio.Types, UDAW.Audio.Buffer,
  UDAW.Audio.Source, UDAW.Codec.WAV;

const
  DRUM_PAD_COUNT = 128;      // one pad per MIDI note
  DRUM_BANK_SIZE = 16;       // pads in one 4x4 view
  DRUM_BASE_NOTE = 36;       // C1, the bottom-left pad of the default view
  DRUM_MAX_VOICES = 32;
  DRUM_CHOKE_GROUPS = 8;

type
  TDrumPlayMode = (dmOneShot, dmGate);

  TDrumHit = record
    Pad: Integer;            // MIDI note / pad index
    Vel: Integer;            // 1..127
  end;

  { the hits of every step of a looping pattern; immutable once published }
  TDrumSeqData = class
  public
    StepsPerBeat: Integer;
    Bpm: Double;
    Steps: TArray<TArray<TDrumHit>>;
    RetiredAt: UInt64;
  end;

  { immutable once published to a pad }
  TDrumSample = class
  public
    Data: TAudioPlanar;      // [channel][frame]
    Channels, Rate, Frames: Integer;
    Path: string;
    Users: Integer;          // voices currently reading it (atomic)
    RetiredAt: UInt64;       // tick count when replaced; 0 = still in use by a pad
    function DurationSeconds: Double;
    { min / max per column, for a waveform preview }
    procedure Peaks(AColumns: Integer; out AMin, AMax: TArray<Single>);
  end;

  TDrumPad = class
  public
    Name: string;
    Sample: TDrumSample;
    Level: Single;           // 0..2 (1 = unity)
    Pan: Single;             // -1..+1
    Muted, Soloed: Boolean;
    Choke: Integer;          // 0 = off, 1..DRUM_CHOKE_GROUPS
    Mode: TDrumPlayMode;
    Activity: Single;        // 1 on a hit, fades; the pads' flash
    constructor Create;
  end;

  TDrumMachine = class(TInterfacedObject, IAudioSource)
  private
    type
      TVoice = record
        Active: Boolean;
        Pad: Integer;
        Sample: TDrumSample;
        Pos: Double;
        Gain: Single;
        Releasing: Boolean;
        Fade: Single;          // 1 -> 0 while releasing
        FadeStep: Single;
        Age: Int64;
      end;
      TCmd = record
        Ready: Integer;
        Kind: Integer;         // 1 hit, 2 release, 3 stop all, 4/5 sequence start/stop, 6 stop one pad
        Pad: Integer;
        Vel: Single;
      end;
  private
    FPads: array[0..DRUM_PAD_COUNT - 1] of TDrumPad;
    FVoices: array[0..DRUM_MAX_VOICES - 1] of TVoice;
    FCmds: array[0..255] of TCmd;
    FTail, FHead: Integer;
    FRate: Integer;
    FAge: Int64;
    FGrave: TObjectList<TDrumSample>;
    FGraveLock: TCriticalSection;
    FMasterGain: Single;
    FSeq: TDrumSeqData;            // published by the UI, read by the real-time thread
    FSeqGrave: TObjectList<TDrumSeqData>;
    FSeqRun: Boolean;              // real-time thread only
    FSeqStep: Integer;             // the step to fire next (real-time thread)
    FSeqCountdown: Double;         // frames until it fires
    FSeqShown: Integer;            // last fired step, for the UI (-1 stopped)
    procedure MixVoices(APl, APr: PAudioSample; AFrames: Integer; AAnySolo: Boolean);
    procedure FireStep(ASeq: TDrumSeqData; AStep: Integer);
    function GetPad(AIndex: Integer): TDrumPad;
    procedure Enqueue(AKind, APad: Integer; AVel: Single);
    procedure StartVoice(APad: Integer; AVel: Single);
    procedure ReleasePad(APad: Integer; AFastMs: Double);
    procedure SweepGrave;
    procedure PublishSample(AIndex: Integer; ASample: TDrumSample);
  public
    constructor Create;
    destructor Destroy; override;
    { UI thread }
    function LoadPad(AIndex: Integer; const APath: string; out AError: string): Boolean;
    procedure ClearPad(AIndex: Integer);
    { gives a pad a sound built in memory (the instrument editor's work in progress); APath is
      what the kit remembers for it. The data is copied. }
    function SetPadData(AIndex: Integer; const AData: TAudioPlanar; ARate: Integer;
      const APath: string): Boolean;
    function SaveKit(const AFileName: string): Boolean;
    function LoadKit(const AFileName: string): Boolean;
    { any thread }
    procedure Hit(APad, AVelocity: Integer);
    procedure Release(APad: Integer);
    { fades out whatever the pad is playing, in either play mode }
    procedure StopPad(APad: Integer);
    function HitNote(ANote, AVelocity: Integer): Boolean;
    function ReleaseNote(ANote: Integer): Boolean;
    procedure StopAll;
    { pattern audition: publish the steps, then start / stop the loop }
    procedure SetSequence(AStepsPerBeat: Integer; ABpm: Double;
      const ASteps: TArray<TArray<TDrumHit>>);
    procedure StartSequence;
    procedure StopSequence;
    function PadForNote(ANote: Integer): Integer;
    function HasSample(APad: Integer): Boolean;
    { real-time thread: adds the drum voices into ABuffer }
    procedure RenderAdd(ABuffer: TAudioBuffer; AFrames: Integer);
    { IAudioSource }
    procedure Render(ABuffer: TAudioBuffer);
    procedure Prepare(ASampleRate, AMaxFrames, AChannels: Integer);
    procedure Reset;
    function Name: string;
    function ActiveVoices: Integer;
    property Pads[AIndex: Integer]: TDrumPad read GetPad;
    property MasterGain: Single read FMasterGain write FMasterGain;
    { step being played (-1 when the sequence is stopped) }
    property SequenceStep: Integer read FSeqShown;
  end;

{ "C1", "C#1", ... for a pad's MIDI note (36 = C1) }
function DrumNoteName(ANote: Integer): string;

implementation


uses
  UDAW.DSP.MathTables;

const
  NOTE_NAMES: array[0..11] of string = ('C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B');
  GRAVE_MS = 3000;

function DrumNoteName(ANote: Integer): string;
begin
  Result := NOTE_NAMES[ANote mod 12] + IntToStr(ANote div 12 - 2);
end;

{ TDrumSample }

function TDrumSample.DurationSeconds: Double;
begin
  if Rate > 0 then Result := Frames / Rate else Result := 0;
end;

procedure TDrumSample.Peaks(AColumns: Integer; out AMin, AMax: TArray<Single>);
var
  c, k, f0, f1, f, ch: Integer;
  lo, hi, v: Single;
begin
  SetLength(AMin, Max(1, AColumns));
  SetLength(AMax, Max(1, AColumns));
  if (Frames <= 0) or (Channels <= 0) then Exit;
  for c := 0 to High(AMin) do
  begin
    f0 := Trunc(c * Frames / Length(AMin));
    f1 := Max(f0 + 1, Trunc((c + 1) * Frames / Length(AMin)));
    lo := 0;
    hi := 0;
    for f := f0 to Min(f1, Frames) - 1 do
      for ch := 0 to Channels - 1 do
      begin
        v := Data[ch][f];
        if v < lo then lo := v;
        if v > hi then hi := v;
      end;
    k := c;
    AMin[k] := lo;
    AMax[k] := hi;
  end;
end;

{ TDrumPad }

constructor TDrumPad.Create;
begin
  inherited Create;
  Level := 1.0;
end;

{ TDrumMachine }

constructor TDrumMachine.Create;
var
  i: Integer;
begin
  inherited Create;
  for i := 0 to DRUM_PAD_COUNT - 1 do FPads[i] := TDrumPad.Create;
  FGrave := TObjectList<TDrumSample>.Create(True);
  FSeqGrave := TObjectList<TDrumSeqData>.Create(True);
  FGraveLock := TCriticalSection.Create;
  FSeqShown := -1;
  FRate := 48000;
  FMasterGain := 1.0;
end;

destructor TDrumMachine.Destroy;
var
  i: Integer;
begin
  for i := 0 to DRUM_PAD_COUNT - 1 do
  begin
    FPads[i].Sample.Free;
    FPads[i].Free;
  end;
  FGrave.Free;
  FSeqGrave.Free;
  FSeq.Free;
  FGraveLock.Free;
  inherited Destroy;
end;

function TDrumMachine.GetPad(AIndex: Integer): TDrumPad;
begin
  Result := FPads[EnsureRange(AIndex, 0, DRUM_PAD_COUNT - 1)];
end;

function TDrumMachine.Name: string;
begin
  Result := 'Drum Machine';
end;

procedure TDrumMachine.Prepare(ASampleRate, AMaxFrames, AChannels: Integer);
begin
  if ASampleRate > 0 then FRate := ASampleRate;
end;

procedure TDrumMachine.Reset;
begin
  StopAll;
end;

function TDrumMachine.PadForNote(ANote: Integer): Integer;
begin
  if (ANote >= 0) and (ANote < DRUM_PAD_COUNT) then
    Result := ANote
  else
    Result := -1;
end;

function TDrumMachine.HasSample(APad: Integer): Boolean;
begin
  Result := (APad >= 0) and (APad < DRUM_PAD_COUNT) and (FPads[APad].Sample <> nil);
end;

{ ---- commands ---- }

procedure TDrumMachine.Enqueue(AKind, APad: Integer; AVel: Single);
var
  idx: Integer;
begin
  idx := (TInterlocked.Increment(FTail) - 1) and 255;
  if FCmds[idx].Ready <> 0 then Exit;   // ring full: drop the hit rather than block
  FCmds[idx].Kind := AKind;
  FCmds[idx].Pad := APad;
  FCmds[idx].Vel := AVel;
  MemoryBarrier;
  FCmds[idx].Ready := 1;
end;

procedure TDrumMachine.Hit(APad, AVelocity: Integer);
begin
  if (APad < 0) or (APad >= DRUM_PAD_COUNT) then Exit;
  Enqueue(1, APad, EnsureRange(AVelocity, 1, 127) / 127.0);
end;

procedure TDrumMachine.Release(APad: Integer);
begin
  if (APad < 0) or (APad >= DRUM_PAD_COUNT) then Exit;
  Enqueue(2, APad, 0);
end;

procedure TDrumMachine.StopPad(APad: Integer);
begin
  if (APad < 0) or (APad >= DRUM_PAD_COUNT) then Exit;
  Enqueue(6, APad, 0);
end;

function TDrumMachine.HitNote(ANote, AVelocity: Integer): Boolean;
var
  p: Integer;
begin
  p := PadForNote(ANote);
  Result := HasSample(p);
  if Result then Hit(p, AVelocity);
end;

function TDrumMachine.ReleaseNote(ANote: Integer): Boolean;
var
  p: Integer;
begin
  p := PadForNote(ANote);
  Result := HasSample(p);
  if Result then Release(p);
end;

procedure TDrumMachine.StopAll;
begin
  Enqueue(3, 0, 0);
end;

{ ---- real-time side ---- }

procedure TDrumMachine.ReleasePad(APad: Integer; AFastMs: Double);
var
  i: Integer;
begin
  for i := 0 to DRUM_MAX_VOICES - 1 do
    if FVoices[i].Active and (FVoices[i].Pad = APad) and not FVoices[i].Releasing then
    begin
      FVoices[i].Releasing := True;
      FVoices[i].FadeStep := 1.0 / Max(1.0, AFastMs * 0.001 * FRate);
    end;
end;

procedure TDrumMachine.StartVoice(APad: Integer; AVel: Single);
var
  i, slot, g: Integer;
  oldest: Int64;
  pad: TDrumPad;
  smp: TDrumSample;
begin
  pad := FPads[APad];
  smp := pad.Sample;
  if smp = nil then Exit;
  { choke group: cut the other pads of the group }
  g := pad.Choke;
  if g > 0 then
    for i := 0 to DRUM_PAD_COUNT - 1 do
      if (i <> APad) and (FPads[i].Choke = g) then ReleasePad(i, 4);
  { a retrigger of the same pad restarts it (cut the old tail quickly) }
  ReleasePad(APad, 3);
  slot := -1;
  for i := 0 to DRUM_MAX_VOICES - 1 do
    if not FVoices[i].Active then
    begin
      slot := i;
      Break;
    end;
  if slot < 0 then
  begin
    oldest := High(Int64);
    for i := 0 to DRUM_MAX_VOICES - 1 do
      if FVoices[i].Age < oldest then
      begin
        oldest := FVoices[i].Age;
        slot := i;
      end;
    TInterlocked.Decrement(FVoices[slot].Sample.Users);
  end;
  Inc(FAge);
  TInterlocked.Increment(smp.Users);
  FVoices[slot].Active := True;
  FVoices[slot].Pad := APad;
  FVoices[slot].Sample := smp;
  FVoices[slot].Pos := 0;
  FVoices[slot].Gain := AVel;
  FVoices[slot].Releasing := False;
  FVoices[slot].Fade := 1.0;
  FVoices[slot].Age := FAge;
  pad.Activity := 1.0;
end;

procedure TDrumMachine.RenderAdd(ABuffer: TAudioBuffer; AFrames: Integer);
var
  idx, i, f, chOut, pos, n: Integer;
  cmd: Integer;
  anySolo: Boolean;
  pl, pr: PAudioSample;
  fr: Integer;
  seq: TDrumSeqData;
begin
  if AFrames <= 0 then Exit;
  if ABuffer.SampleRate > 0 then FRate := ABuffer.SampleRate;

  { commands }
  while True do
  begin
    idx := FHead and 255;
    if FCmds[idx].Ready = 0 then Break;
    cmd := FCmds[idx].Kind;
    i := FCmds[idx].Pad;
    case cmd of
      1: StartVoice(i, FCmds[idx].Vel);
      2:
        if FPads[i].Mode = dmGate then ReleasePad(i, 12);
      3:
        for f := 0 to DRUM_MAX_VOICES - 1 do
          if FVoices[f].Active then
          begin
            FVoices[f].Releasing := True;
            FVoices[f].FadeStep := 1.0 / Max(1.0, 0.005 * FRate);
          end;
      4:
        begin
          FSeqRun := True;
          FSeqStep := 0;
          FSeqCountdown := 0;
        end;
      5:
        begin
          FSeqRun := False;
          FSeqShown := -1;
        end;
      6: ReleasePad(i, 8);
    end;
    MemoryBarrier;
    FCmds[idx].Ready := 0;
    Inc(FHead);
  end;

  anySolo := False;
  for i := 0 to DRUM_PAD_COUNT - 1 do
    if FPads[i].Soloed then anySolo := True;

  chOut := ABuffer.ChannelCount;
  if chOut < 1 then Exit;
  pl := ABuffer.ChannelPtr(0);
  if chOut > 1 then pr := ABuffer.ChannelPtr(1) else pr := nil;

  { the sequencer cuts the block at each step so a hit starts on its exact frame }
  seq := FSeq;
  if FSeqRun and ((seq = nil) or (Length(seq.Steps) = 0)) then
  begin
    FSeqRun := False;
    FSeqShown := -1;
  end;
  pos := 0;
  while pos < AFrames do
  begin
    n := AFrames - pos;
    if FSeqRun then
    begin
      while FSeqCountdown <= 0 do
      begin
        if FSeqStep >= Length(seq.Steps) then FSeqStep := 0;
        FireStep(seq, FSeqStep);
        FSeqShown := FSeqStep;
        Inc(FSeqStep);
        FSeqCountdown := FSeqCountdown +
          60.0 / Max(20.0, seq.Bpm) / Max(1, seq.StepsPerBeat) * Max(1, FRate);
      end;
      n := Min(n, Max(1, Ceil(FSeqCountdown)));
      FSeqCountdown := FSeqCountdown - n;
    end;
    if pr <> nil then
      MixVoices(PAudioSample(PByte(pl) + pos * SizeOf(TAudioSample)),
        PAudioSample(PByte(pr) + pos * SizeOf(TAudioSample)), n, anySolo)
    else
      MixVoices(PAudioSample(PByte(pl) + pos * SizeOf(TAudioSample)), nil, n, anySolo);
    Inc(pos, n);
  end;
  fr := AFrames;
  for i := 0 to DRUM_PAD_COUNT - 1 do
    if FPads[i].Activity > 0 then
      FPads[i].Activity := Max(0, FPads[i].Activity - fr / (0.25 * Max(1, FRate)));
end;

procedure TDrumMachine.FireStep(ASeq: TDrumSeqData; AStep: Integer);
var
  k: Integer;
begin
  for k := 0 to High(ASeq.Steps[AStep]) do
    if (ASeq.Steps[AStep][k].Pad >= 0) and (ASeq.Steps[AStep][k].Pad < DRUM_PAD_COUNT) then
      StartVoice(ASeq.Steps[AStep][k].Pad, EnsureRange(ASeq.Steps[AStep][k].Vel, 1, 127) / 127.0);
end;

{ adds the sounding voices into AFrames frames at APl / APr (APr nil on a mono bus) }
procedure TDrumMachine.MixVoices(APl, APr: PAudioSample; AFrames: Integer; AAnySolo: Boolean);
var
  i, f, nCh, i0: Integer;
  pad: TDrumPad;
  smp: TDrumSample;
  audible: Boolean;
  step, gl, gr, th, g, s0, s1, frac, l, r, fade: Double;
  pl, pr: PAudioSample;
begin
  pl := APl;
  pr := APr;
  for i := 0 to DRUM_MAX_VOICES - 1 do
  begin
    if not FVoices[i].Active then Continue;
    pad := FPads[FVoices[i].Pad];
    smp := FVoices[i].Sample;
    nCh := smp.Channels;
    audible := (not pad.Muted) and ((not AAnySolo) or pad.Soloed);
    step := smp.Rate / Max(1, FRate);
    th := (EnsureRange(pad.Pan, -1, 1) + 1.0) * Pi / 4.0;
    gl := FastCos(th) * Sqrt(2.0);
    gr := FastSin(th) * Sqrt(2.0);
    g := FVoices[i].Gain * pad.Level * FMasterGain;
    for f := 0 to AFrames - 1 do
    begin
      i0 := Trunc(FVoices[i].Pos);
      if i0 >= smp.Frames - 1 then
      begin
        FVoices[i].Active := False;
        TInterlocked.Decrement(smp.Users);
        Break;
      end;
      frac := FVoices[i].Pos - i0;
      if audible then
      begin
        s0 := smp.Data[0][i0];
        s1 := smp.Data[0][i0 + 1];
        l := s0 + (s1 - s0) * frac;
        if nCh > 1 then
        begin
          s0 := smp.Data[1][i0];
          s1 := smp.Data[1][i0 + 1];
          r := s0 + (s1 - s0) * frac;
        end
        else r := l;
        fade := g * FVoices[i].Fade;
        if pr <> nil then
        begin
          PAudioSample(PByte(pl) + f * SizeOf(TAudioSample))^ :=
            PAudioSample(PByte(pl) + f * SizeOf(TAudioSample))^ + l * gl * fade;
          PAudioSample(PByte(pr) + f * SizeOf(TAudioSample))^ :=
            PAudioSample(PByte(pr) + f * SizeOf(TAudioSample))^ + r * gr * fade;
        end
        else
          PAudioSample(PByte(pl) + f * SizeOf(TAudioSample))^ :=
            PAudioSample(PByte(pl) + f * SizeOf(TAudioSample))^ + 0.5 * (l + r) * fade;
      end;
      FVoices[i].Pos := FVoices[i].Pos + step;
      if FVoices[i].Releasing then
      begin
        FVoices[i].Fade := FVoices[i].Fade - FVoices[i].FadeStep;
        if FVoices[i].Fade <= 0 then
        begin
          FVoices[i].Active := False;
          TInterlocked.Decrement(smp.Users);
          Break;
        end;
      end;
    end;
  end;
end;

procedure TDrumMachine.Render(ABuffer: TAudioBuffer);
var
  c: Integer;
begin
  for c := 0 to ABuffer.ChannelCount - 1 do ABuffer.ClearChannel(c);
  RenderAdd(ABuffer, ABuffer.FrameCount);
end;

function TDrumMachine.ActiveVoices: Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to DRUM_MAX_VOICES - 1 do
    if FVoices[i].Active then Inc(Result);
end;

{ ---- UI side ---- }

procedure TDrumMachine.SweepGrave;
var
  i: Integer;
  now: UInt64;
begin
  now := TThread.GetTickCount64;
  FGraveLock.Enter;
  try
    for i := FGrave.Count - 1 downto 0 do
      if (FGrave[i].Users <= 0) and (now - FGrave[i].RetiredAt >= GRAVE_MS) then
        FGrave.Delete(i);
    for i := FSeqGrave.Count - 1 downto 0 do
      if now - FSeqGrave[i].RetiredAt >= GRAVE_MS then FSeqGrave.Delete(i);
  finally
    FGraveLock.Leave;
  end;
end;

procedure TDrumMachine.SetSequence(AStepsPerBeat: Integer; ABpm: Double;
  const ASteps: TArray<TArray<TDrumHit>>);
var
  d, old: TDrumSeqData;
begin
  d := TDrumSeqData.Create;
  d.StepsPerBeat := Max(1, AStepsPerBeat);
  d.Bpm := ABpm;
  d.Steps := ASteps;
  old := FSeq;
  FSeq := d;                              // one pointer write publishes it
  if old <> nil then
  begin
    old.RetiredAt := TThread.GetTickCount64;
    FGraveLock.Enter;
    try
      FSeqGrave.Add(old);
    finally
      FGraveLock.Leave;
    end;
  end;
  SweepGrave;
end;

procedure TDrumMachine.StartSequence;
begin
  Enqueue(4, 0, 0);
end;

procedure TDrumMachine.StopSequence;
begin
  Enqueue(5, 0, 0);
end;

function TDrumMachine.LoadPad(AIndex: Integer; const APath: string; out AError: string): Boolean;
var
  smp: TDrumSample;
  ext: string;
begin
  Result := False;
  AError := '';
  if (AIndex < 0) or (AIndex >= DRUM_PAD_COUNT) then
  begin
    AError := 'no such pad';
    Exit;
  end;
  ext := LowerCase(ExtractFileExt(APath));
  if ext <> '.wav' then
  begin
    AError := 'drum pads load WAV files for now (' + ext + ' is not supported yet)';
    Exit;
  end;
  smp := TDrumSample.Create;
  try
    try
      smp.Data := LoadWavFile(APath, smp.Channels, smp.Rate);
    except
      on E: Exception do
      begin
        AError := E.Message;
        smp.Free;
        Exit;
      end;
    end;
    if (smp.Channels < 1) or (Length(smp.Data) < 1) then
    begin
      AError := 'the file holds no audio';
      smp.Free;
      Exit;
    end;
    smp.Frames := Length(smp.Data[0]);
    if smp.Frames < 2 then
    begin
      AError := 'the file is too short';
      smp.Free;
      Exit;
    end;
    smp.Path := APath;
  except
    smp.Free;
    raise;
  end;
  PublishSample(AIndex, smp);
  Result := True;
end;

{ one pointer write publishes the new sample; the replaced one is retired }
procedure TDrumMachine.PublishSample(AIndex: Integer; ASample: TDrumSample);
var
  old: TDrumSample;
begin
  old := FPads[AIndex].Sample;
  FPads[AIndex].Sample := ASample;
  if FPads[AIndex].Name = '' then
    FPads[AIndex].Name := ChangeFileExt(ExtractFileName(ASample.Path), '');
  if old <> nil then
  begin
    old.RetiredAt := TThread.GetTickCount64;
    FGraveLock.Enter;
    try
      FGrave.Add(old);
    finally
      FGraveLock.Leave;
    end;
  end;
  SweepGrave;
end;

function TDrumMachine.SetPadData(AIndex: Integer; const AData: TAudioPlanar; ARate: Integer;
  const APath: string): Boolean;
var
  smp: TDrumSample;
  c: Integer;
begin
  Result := False;
  if (AIndex < 0) or (AIndex >= DRUM_PAD_COUNT) or (Length(AData) < 1) or (ARate < 1) then Exit;
  if Length(AData[0]) < 2 then Exit;
  smp := TDrumSample.Create;
  smp.Channels := Length(AData);
  smp.Rate := ARate;
  smp.Frames := Length(AData[0]);
  smp.Path := APath;
  { the pad owns its own copy: the editor keeps changing its buffer }
  SetLength(smp.Data, smp.Channels);
  for c := 0 to smp.Channels - 1 do
    smp.Data[c] := Copy(AData[c], 0, smp.Frames);
  PublishSample(AIndex, smp);
  Result := True;
end;

procedure TDrumMachine.ClearPad(AIndex: Integer);
var
  old: TDrumSample;
begin
  if (AIndex < 0) or (AIndex >= DRUM_PAD_COUNT) then Exit;
  old := FPads[AIndex].Sample;
  FPads[AIndex].Sample := nil;
  FPads[AIndex].Name := '';
  if old <> nil then
  begin
    old.RetiredAt := TThread.GetTickCount64;
    FGraveLock.Enter;
    try
      FGrave.Add(old);
    finally
      FGraveLock.Leave;
    end;
  end;
  SweepGrave;
end;

const
  KIT_HEADER = '#udawkit 2';   // v2: the index is the MIDI note; v1 (no header) was pad 0..15 from note 36

{ a header line, then one line per pad: note|path|name|level|pan|mute|solo|choke|mode }
function TDrumMachine.SaveKit(const AFileName: string): Boolean;
var
  sl: TStringList;
  i: Integer;
  p: TDrumPad;
  fs: TFormatSettings;
begin
  fs := TFormatSettings.Invariant;
  sl := TStringList.Create;
  try
    sl.Add(KIT_HEADER);
    for i := 0 to DRUM_PAD_COUNT - 1 do
    begin
      p := FPads[i];
      if p.Sample <> nil then
        sl.Add(Format('%d|%s|%s|%s|%s|%d|%d|%d|%d', [i, p.Sample.Path,
          StringReplace(p.Name, '|', ' ', [rfReplaceAll]),
          FormatFloat('0.###', p.Level, fs), FormatFloat('0.###', p.Pan, fs),
          Ord(p.Muted), Ord(p.Soloed), p.Choke, Ord(p.Mode)]));
    end;
    try
      ForceDirectories(ExtractFilePath(AFileName));
      sl.SaveToFile(AFileName, TEncoding.UTF8);
      Result := True;
    except
      Result := False;
    end;
  finally
    sl.Free;
  end;
end;

function TDrumMachine.LoadKit(const AFileName: string): Boolean;
var
  sl: TStringList;
  line: string;
  f: TArray<string>;
  i, idx, legacy: Integer;
  err: string;
  fs: TFormatSettings;
  v: Double;
begin
  Result := False;
  if not FileExists(AFileName) then Exit;
  fs := TFormatSettings.Invariant;
  sl := TStringList.Create;
  try
    sl.LoadFromFile(AFileName, TEncoding.UTF8);
    if (sl.Count > 0) and (Trim(sl[0]) = KIT_HEADER) then legacy := 0 else legacy := DRUM_BASE_NOTE;
    for line in sl do
    begin
      f := line.Split(['|']);
      if Length(f) < 9 then Continue;
      if not TryStrToInt(f[0], idx) then Continue;
      Inc(idx, legacy);
      if (idx < 0) or (idx >= DRUM_PAD_COUNT) or not FileExists(f[1]) then Continue;
      if not LoadPad(idx, f[1], err) then Continue;
      FPads[idx].Name := f[2];
      if TryStrToFloat(f[3], v, fs) then FPads[idx].Level := v;
      if TryStrToFloat(f[4], v, fs) then FPads[idx].Pan := v;
      FPads[idx].Muted := f[5] = '1';
      FPads[idx].Soloed := f[6] = '1';
      FPads[idx].Choke := EnsureRange(StrToIntDef(f[7], 0), 0, DRUM_CHOKE_GROUPS);
      i := StrToIntDef(f[8], 0);
      if i = 1 then FPads[idx].Mode := dmGate else FPads[idx].Mode := dmOneShot;
      Result := True;
    end;
  finally
    sl.Free;
  end;
end;

end.
