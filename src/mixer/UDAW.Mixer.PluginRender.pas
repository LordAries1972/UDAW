unit UDAW.Mixer.PluginRender;
{$I udaw.inc}
{$POINTERMATH ON}

{ Running a hosted VST2 / VST3 plug-in outside the live mixer:

    * CollectRangeMidi  - the notes and controllers of the MIDI clips under a highlighted Timeline
                          range, as timed messages (for an instrument, or an effect that takes MIDI)
    * RenderPluginToPlanar - renders the plug-in over the range offline: MIDI from the clips, audio
                          from the highlighted audio clips ("sample input"), or both at once (a
                          vocoder or sampler played from MIDI while it listens to the audio)
    * TPluginAuditionSource - an audio source that plays the plug-in through the audio device so the
                          plug-in window can be listened to: material looping through it (the
                          highlighted range, a built-in phrase, or live input) plus the MIDI keyboard }

interface

uses
  SysUtils, Classes, Math, Generics.Collections, Generics.Defaults,
  UDAW.Audio.Types, UDAW.Audio.Buffer, UDAW.Audio.Ring, UDAW.Audio.Source,
  UDAW.Audio.Graph.Nodes, UDAW.Mixer.PluginHost, UDAW.Mixer.PluginMidi,
  UDAW.Timeline.Model, UDAW.MIDI.Types, UDAW.MIDI.Sequence, UDAW.MIDI.Serialization;

type
  TTimedMidi = record
    Sample: Int64;              // position from the start of the render
    Status, Data1, Data2: Byte;
  end;
  TTimedMidiArray = TArray<TTimedMidi>;

  TPluginRenderRequest = record
    Kind: string;               // 'vst2' / 'vst3'
    Params: string;             // the insert's text: path=...;state=...
    Name: string;
    SampleRate: Integer;
    Channels: Integer;
    Frames: Integer;            // length of the range
    TailSeconds: Double;        // an instrument rings on for up to this long past the range
    Tempo: Double;              // BPM at the range start
    StartPpq: Double;           // quarter-note position of the range start
    TimeSigNum, TimeSigDen: Integer;
    class function Make(const AKind, AParams, AName: string; ARate, AChannels, AFrames: Integer): TPluginRenderRequest; static;
  end;

  EPluginRenderError = class(Exception);

{ the MIDI of every MIDI clip on ATrackIds that sounds inside [AStartSec, AEndSec), positions relative
  to AStartSec; a note already sounding at the start begins at sample 0, one still sounding at the end
  is cut there }
function CollectRangeMidi(ATimeline: TTimeline; AMidi: TMidiProject; const ATrackIds: TArray<Integer>;
  AStartSec, AEndSec: Double; ASampleRate: Integer): TTimedMidiArray;

{ AInput may be empty (an instrument played only from MIDI). The result has AOutFrames valid frames
  (the range plus whatever tail the plug-in produced); AProgress(0..100) is called now and then. }
function RenderPluginToPlanar(const AReq: TPluginRenderRequest; const AInput: TAudioPlanar;
  const AMidi: TTimedMidiArray; const AProgress: TProc<Integer>; out AOutFrames: Integer): TAudioPlanar;

type
  TPluginAuditionSource = class(TInterfacedObject, IAudioSource)
  private
    FHost: TPluginHostBase;      // not owned: the plug-in window owns it and detaches this source first
    FKey: Pointer;               // the plug-in window's key in the MIDI hub
    FMat: TArray<TArray<Single>>;
    FLen, FPos, FChans, FMax: Integer;
    FIn, FOut: TArray<TArray<Single>>;
    FInPtrs, FOutPtrs: TArray<System.PSingle>;
    FBypass: Boolean;
    FFault: string;
    FRing: TAudioRing;           // live input mode (nil = looped material or silence)
    FRingBuf: TArray<Single>;
    FRingCh: Integer;
    FMidiBuf: array[0..PLUGIN_MAX_MIDI - 1] of TPluginMidi;
    FSamples: Int64;
  public
    { AMaterial may be empty: the plug-in then hears silence (an instrument played from MIDI) }
    constructor Create(AHost: TPluginHostBase; AKey: Pointer; AChannels, AMaxFrames: Integer;
      const AMaterial: TArray<TArray<Single>>);
    constructor CreateLive(AHost: TPluginHostBase; AKey: Pointer; AChannels, AMaxFrames,
      AInputChannels, ASampleRate: Integer);
    destructor Destroy; override;
    procedure Render(ABuffer: TAudioBuffer);
    procedure Prepare(ASampleRate, AMaxFrames, AChannels: Integer);
    procedure Reset;
    function Name: string;
    property Bypass: Boolean read FBypass write FBypass;
    property Ring: TAudioRing read FRing;
    property Fault: string read FFault;
  end;

implementation

class function TPluginRenderRequest.Make(const AKind, AParams, AName: string; ARate, AChannels,
  AFrames: Integer): TPluginRenderRequest;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Kind := AKind;
  Result.Params := AParams;
  Result.Name := AName;
  Result.SampleRate := ARate;
  Result.Channels := AChannels;
  Result.Frames := AFrames;
  Result.TailSeconds := 3.0;
  Result.Tempo := 120;
  Result.TimeSigNum := 4;
  Result.TimeSigDen := 4;
end;

function CollectRangeMidi(ATimeline: TTimeline; AMidi: TMidiProject; const ATrackIds: TArray<Integer>;
  AStartSec, AEndSec: Double; ASampleRate: Integer): TTimedMidiArray;
var
  list: TList<TTimedMidi>;
  tid, j, ti, ni, ci, ai: Integer;
  trk: TTimelineTrack;
  clip: TTimelineClip;
  seq: TMidiSequence;
  mt: TMidiTrackSeq;
  nt: TMidiNote;
  tOn, tOff, tEv: Double;
  m: TTimedMidi;

  function ClipTime(ASeqSec: Double): Double;
  begin
    Result := clip.StartSeconds + (ASeqSec - clip.SourceOffsetSeconds);
  end;

  function ToSample(ATimeSec: Double): Int64;
  begin
    Result := Round((ATimeSec - AStartSec) * ASampleRate);
  end;

  procedure Add(ASample: Int64; AStatus, AD1, AD2: Byte);
  begin
    m.Sample := Max(0, ASample);
    m.Status := AStatus;
    m.Data1 := AD1;
    m.Data2 := AD2;
    list.Add(m);
  end;

begin
  list := TList<TTimedMidi>.Create;
  try
    if (ATimeline <> nil) and (AMidi <> nil) and (ASampleRate > 0) then
      for tid in ATrackIds do
      begin
        trk := ATimeline.TrackById(tid);
        if (trk = nil) or not (trk.Kind in [tkMidi, tkInstrument]) then Continue;
        for j := 0 to trk.ClipCount - 1 do
        begin
          clip := trk.GetClip(j);
          if (not clip.IsMidiClip) or clip.Muted then Continue;
          if (clip.EndSeconds <= AStartSec) or (clip.StartSeconds >= AEndSec) then Continue;
          seq := AMidi.ClipById(clip.MidiClipId);
          if seq = nil then Continue;
          for ti := 0 to seq.TrackCount - 1 do
          begin
            mt := seq.GetTrack(ti);
            for ni := 0 to mt.NoteCount - 1 do
            begin
              nt := mt.Notes[ni];
              tOn := ClipTime(seq.TickToSeconds(nt.StartTick));
              tOff := Min(ClipTime(seq.TickToSeconds(nt.EndTick)), clip.EndSeconds);
              if (tOn < clip.StartSeconds) or (tOn >= clip.EndSeconds) then Continue;
              if (tOff <= AStartSec) or (tOn >= AEndSec) then Continue;
              Add(ToSample(Max(tOn, AStartSec)), MIDI_NOTE_ON or (nt.Channel and 15), nt.Note and 127,
                Max(1, Min(127, nt.Velocity)));
              Add(ToSample(Min(tOff, AEndSec)), MIDI_NOTE_OFF or (nt.Channel and 15), nt.Note and 127,
                Max(0, Min(127, nt.OffVelocity)));
            end;
            for ci := 0 to mt.CCCount - 1 do
            begin
              tEv := ClipTime(seq.TickToSeconds(mt.Controllers[ci].Tick));
              if (tEv < clip.StartSeconds) or (tEv >= clip.EndSeconds) or (tEv >= AEndSec) then Continue;
              { a controller set before the range still holds inside it: it is applied at the start }
              Add(ToSample(tEv), MIDI_CONTROL_CHANGE or (mt.Controllers[ci].Channel and 15),
                mt.Controllers[ci].Controller and 127, Max(0, Min(127, mt.Controllers[ci].Value)));
            end;
            for ai := 0 to mt.AuxCount - 1 do
              if mt.Aux[ai].Kind = mekChannel then
              begin
                tEv := ClipTime(seq.TickToSeconds(mt.Aux[ai].Tick));
                if (tEv < clip.StartSeconds) or (tEv >= clip.EndSeconds) or (tEv >= AEndSec) then Continue;
                Add(ToSample(tEv), mt.Aux[ai].Msg.Status, mt.Aux[ai].Msg.Data1, mt.Aux[ai].Msg.Data2);
              end;
          end;
        end;
      end;
    { by time; at the same instant a note ends before the next one starts }
    list.Sort(TComparer<TTimedMidi>.Construct(
      function(const A, B: TTimedMidi): Integer
      begin
        if A.Sample <> B.Sample then
          Result := Sign(A.Sample - B.Sample)
        else
          Result := Ord((A.Status and $F0) = MIDI_NOTE_ON) - Ord((B.Status and $F0) = MIDI_NOTE_ON);
      end));
    Result := list.ToArray;
  finally
    list.Free;
  end;
end;

function NodeLoadError(ANode: TAudioNode): string;
begin
  Result := '';
  if ANode is TVST2Node then Result := TVST2Node(ANode).LoadError
  else if ANode is TVST3Node then Result := TVST3Node(ANode).LoadError;
end;

function RenderPluginToPlanar(const AReq: TPluginRenderRequest; const AInput: TAudioPlanar;
  const AMidi: TTimedMidiArray; const AProgress: TProc<Integer>; out AOutFrames: Integer): TAudioPlanar;
const
  BLOCK = 1024;
var
  nk: TNodeKind;
  node: TAudioNode;
  host: TPluginHostBase;
  inBuf, outBuf: TAudioBuffer;
  tp: TPluginTransport;
  sr, ch, total, lat, pos, n, c, i, mi, silentRun, outPos, srcPos, inLen, k: Integer;
  isSynth: Boolean;
  peak: Single;
  p: PSingle;
  err: string;
begin
  AOutFrames := 0;
  SetLength(Result, 0);
  sr := AReq.SampleRate;
  ch := Max(1, AReq.Channels);
  if (sr <= 0) or (AReq.Frames <= 0) then Exit;
  if not NodeKindFromId(AReq.Kind, nk) or not (nk in [nkVST2, nkVST3]) then
    raise EPluginRenderError.Create('Not a VST2 / VST3 plug-in insert: ' + AReq.Kind);
  node := CreateNode(1, nk, AReq.Name);
  try
    node.DeserializeParams(AReq.Params);
    if node is TVST2Node then
    begin
      TVST2Node(node).LiveMidi := False;            { the keyboard must not play into a render }
      TVST2Node(node).OwnTransport := True;
    end
    else
    begin
      TVST3Node(node).LiveMidi := False;
      TVST3Node(node).OwnTransport := True;
    end;
    node.Configure(sr, BLOCK, ch);
    host := PluginHostOf(node);
    if (host = nil) or not host.IsLoaded then
    begin
      err := NodeLoadError(node);
      if err = '' then err := 'the plug-in did not load';
      raise EPluginRenderError.Create(AReq.Name + ': ' + err);
    end;
    isSynth := host.IsSynth;
    lat := 0;
    if not isSynth then lat := Max(0, host.LatencySamples);
    total := AReq.Frames + lat;
    if isSynth or (Length(AMidi) > 0) then
      total := total + Round(Max(0.0, AReq.TailSeconds) * sr);
    SetLength(Result, ch);
    for c := 0 to ch - 1 do
    begin
      SetLength(Result[c], AReq.Frames + Round(Max(0.0, AReq.TailSeconds) * sr) + 1);
      FillChar(Result[c][0], Length(Result[c]) * SizeOf(Single), 0);
    end;
    inLen := 0;
    if Length(AInput) > 0 then inLen := Length(AInput[0]);

    inBuf := TAudioBuffer.Create(ch, BLOCK, sr);
    outBuf := TAudioBuffer.Create(ch, BLOCK, sr);
    try
      mi := 0;
      pos := 0;
      silentRun := 0;
      while pos < total do
      begin
        n := Min(BLOCK, total - pos);
        inBuf.SetActiveFrames(n);
        outBuf.SetActiveFrames(n);

        tp := TPluginTransport.Make(True, AReq.Tempo, AReq.StartPpq + pos / sr * AReq.Tempo / 60.0);
        tp.SamplePos := pos;
        tp.TimeSigNum := AReq.TimeSigNum;
        tp.TimeSigDen := AReq.TimeSigDen;
        host.SetTransport(tp);

        while (mi < Length(AMidi)) and (AMidi[mi].Sample < pos + n) do
        begin
          host.SendMidi(AMidi[mi].Status, AMidi[mi].Data1, AMidi[mi].Data2, Max(0, AMidi[mi].Sample - pos));
          Inc(mi);
        end;

        for c := 0 to ch - 1 do
        begin
          p := PSingle(inBuf.ChannelPtr(c));
          if (inLen > 0) and (pos < inLen) then
          begin
            srcPos := Min(c, High(AInput));
            k := Min(n, inLen - pos);
            Move(AInput[srcPos][pos], p^, k * SizeOf(Single));
            if k < n then FillChar((p + k)^, (n - k) * SizeOf(Single), 0);
          end
          else
            FillChar(p^, n * SizeOf(Single), 0);
        end;

        node.Process(inBuf, outBuf);

        { latency compensation: the first lat output samples of an effect are dropped }
        for c := 0 to ch - 1 do
        begin
          p := PSingle(outBuf.ChannelPtr(c));
          for i := 0 to n - 1 do
          begin
            outPos := pos + i - lat;
            if (outPos >= 0) and (outPos <= High(Result[c])) then Result[c][outPos] := (p + i)^;
          end;
        end;

        { an instrument that has gone quiet after the last MIDI message is finished }
        if isSynth and (mi >= Length(AMidi)) and (pos >= AReq.Frames) then
        begin
          peak := 0;
          for c := 0 to ch - 1 do
          begin
            p := PSingle(outBuf.ChannelPtr(c));
            for i := 0 to n - 1 do
              if Abs((p + i)^) > peak then peak := Abs((p + i)^);
          end;
          if peak < 0.00003 then Inc(silentRun, n) else silentRun := 0;
          if silentRun > sr div 2 then
          begin
            Inc(pos, n);
            Break;
          end;
        end;

        Inc(pos, n);
        if Assigned(AProgress) and ((pos div BLOCK) mod 8 = 0) then
          AProgress(Min(100, Round(pos / Max(1, total) * 100)));
      end;
      AOutFrames := Min(Max(0, pos - lat), Length(Result[0]));
    finally
      inBuf.Free;
      outBuf.Free;
    end;
    err := NodeLoadError(node);
    if (err <> '') and (System.Pos('fault', err) > 0) then
      raise EPluginRenderError.Create(AReq.Name + ': ' + err);
    if Assigned(AProgress) then AProgress(100);
  finally
    node.Free;
  end;
end;

{ ================= TPluginAuditionSource ================= }

constructor TPluginAuditionSource.Create(AHost: TPluginHostBase; AKey: Pointer; AChannels,
  AMaxFrames: Integer; const AMaterial: TArray<TArray<Single>>);
var
  c: Integer;
begin
  inherited Create;
  FHost := AHost;
  FKey := AKey;
  FMat := AMaterial;
  FChans := Max(1, AChannels);
  FMax := Max(64, AMaxFrames);
  if Length(FMat) > 0 then FLen := Length(FMat[0]) else FLen := 0;
  SetLength(FIn, FChans);
  SetLength(FOut, FChans);
  SetLength(FInPtrs, FChans);
  SetLength(FOutPtrs, FChans);
  for c := 0 to FChans - 1 do
  begin
    SetLength(FIn[c], FMax);
    SetLength(FOut[c], FMax);
    FInPtrs[c] := @FIn[c][0];
    FOutPtrs[c] := @FOut[c][0];
  end;
end;

constructor TPluginAuditionSource.CreateLive(AHost: TPluginHostBase; AKey: Pointer; AChannels,
  AMaxFrames, AInputChannels, ASampleRate: Integer);
var
  none: TArray<TArray<Single>>;
begin
  SetLength(none, 0);
  Create(AHost, AKey, AChannels, AMaxFrames, none);
  FRingCh := Max(1, AInputChannels);
  FRing := TAudioRing.Create(FRingCh, Max(4096, ASampleRate));
  SetLength(FRingBuf, FMax * FRingCh);
end;

destructor TPluginAuditionSource.Destroy;
begin
  FreeAndNil(FRing);
  inherited Destroy;
end;

procedure TPluginAuditionSource.Prepare(ASampleRate, AMaxFrames, AChannels: Integer);
begin
  FPos := 0;
  FSamples := 0;
end;

procedure TPluginAuditionSource.Reset;
begin
  FPos := 0;
  FSamples := 0;
end;

function TPluginAuditionSource.Name: string;
begin
  Result := 'Plug-in audition';
end;

procedure TPluginAuditionSource.Render(ABuffer: TAudioBuffer);
var
  n, done, m, c, i, p, nch, sc, k: Integer;
  ok: Boolean;
  tp: TPluginTransport;
  hubTp: TPluginTransport;
  out3: array[0..255] of TPluginMidi;
begin
  n := ABuffer.FrameCount;
  nch := ABuffer.ChannelCount;
  if (FHost = nil) or (not FHost.IsLoaded) then
  begin
    ABuffer.Clear;
    Exit;
  end;
  hubTp := PluginMidi.Transport;
  done := 0;
  while done < n do
  begin
    m := Min(n - done, FMax);
    if FRing <> nil then
    begin
      { keep the delay short: if the input has run ahead by more than a few blocks, drop the oldest }
      if FRing.FramesAvailable > m * 6 then FRing.SkipFrames(FRing.FramesAvailable - m * 2);
      FRing.ReadFrames(FRingBuf[0], m, True);
      for i := 0 to m - 1 do
        for c := 0 to FChans - 1 do FIn[c][i] := FRingBuf[i * FRingCh];
    end
    else if FLen > 0 then
    begin
      for i := 0 to m - 1 do
      begin
        p := (FPos + i) mod FLen;
        for c := 0 to FChans - 1 do FIn[c][i] := FMat[Min(c, High(FMat))][p];
      end;
      FPos := (FPos + m) mod FLen;
    end
    else
      for c := 0 to FChans - 1 do FillChar(FIn[c][0], m * SizeOf(Single), 0);

    ok := False;
    if not FBypass then
    try
      k := PluginMidi.Take(FKey, FMidiBuf);
      for i := 0 to k - 1 do
        FHost.SendMidi(FMidiBuf[i].Status, FMidiBuf[i].Data1, FMidiBuf[i].Data2, FMidiBuf[i].DeltaFrames);
      tp := TPluginTransport.Make(True, hubTp.Tempo, FSamples / Max(1, ABuffer.SampleRate) * hubTp.Tempo / 60.0);
      tp.SamplePos := FSamples;
      FHost.SetTransport(tp);
      FHost.Process(FInPtrs, FOutPtrs, m);
      k := FHost.PopMidiOut(out3);
      for i := 0 to k - 1 do PluginMidi.PostOut(out3[i].Status, out3[i].Data1, out3[i].Data2);
      ok := True;
    except
      on E: Exception do
      begin
        FFault := E.Message;
        FBypass := True;
      end;
    end;
    if not ok then
      for c := 0 to FChans - 1 do Move(FIn[c][0], FOut[c][0], m * SizeOf(Single));
    for c := 0 to nch - 1 do
    begin
      sc := Min(c, FChans - 1);
      Move(FOut[sc][0], PSingle(PByte(ABuffer.ChannelPtr(c)) + done * SizeOf(Single))^, m * SizeOf(Single));
    end;
    Inc(FSamples, m);
    Inc(done, m);
  end;
end;

end.
