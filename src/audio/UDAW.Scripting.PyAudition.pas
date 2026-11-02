unit UDAW.Scripting.PyAudition;
{$I udaw.inc}

{ Hearing a Python plug-in before it is put on the mixer.

  TPyAuditionSource is an audio source for the audio engine: it loops some program material through a
  running plug-in (UDAW.Scripting.PyPlugin) and plays the result. The material is either what the user
  highlighted on the Timeline, or the built-in fallback, a plucked-string guitar phrase (BuildGuitarPhrase,
  Karplus-Strong strings, no sample files needed). Bypass plays the material without the plug-in for an
  A/B comparison. }

interface

uses
  SysUtils, Math, UDAW.Audio.Types, UDAW.Audio.Buffer, UDAW.Audio.Source, UDAW.Scripting.PyPlugin;

type
  TPyPlanar = TArray<TArray<Single>>;

  TPyAuditionSource = class(TInterfacedObject, IAudioSource)
  private
    FHost: TPyPluginHost;
    FMat: TPyPlanar;
    FLen, FPos, FChans: Integer;
    FIn, FOut: TPyPlanar;
    FInPtrs, FOutPtrs: TArray<System.PSingle>;
    FBypass: Boolean;
  public
    { retains AHost; AMaterial is planar audio at the engine's sample rate }
    constructor Create(AHost: TPyPluginHost; const AMaterial: TPyPlanar);
    destructor Destroy; override;
    procedure Render(ABuffer: TAudioBuffer);
    procedure Prepare(ASampleRate, AMaxFrames, AChannels: Integer);
    procedure Reset;
    function Name: string;
    property Bypass: Boolean read FBypass write FBypass;
  end;

{ a clean electric-guitar riff (two stereo-identical channels), about ten seconds, peaking at -7 dBFS }
function BuildGuitarPhrase(ARate: Integer): TPyPlanar;

implementation

constructor TPyAuditionSource.Create(AHost: TPyPluginHost; const AMaterial: TPyPlanar);
var
  c: Integer;
begin
  inherited Create;
  FHost := AHost;
  FHost.Retain;
  FMat := AMaterial;
  FChans := Max(1, FHost.Channels);
  if Length(FMat) > 0 then FLen := Length(FMat[0]) else FLen := 0;
  SetLength(FIn, FChans);
  SetLength(FOut, FChans);
  SetLength(FInPtrs, FChans);
  SetLength(FOutPtrs, FChans);
  for c := 0 to FChans - 1 do
  begin
    SetLength(FIn[c], FHost.MaxFrames);
    SetLength(FOut[c], FHost.MaxFrames);
    FInPtrs[c] := @FIn[c][0];
    FOutPtrs[c] := @FOut[c][0];
  end;
end;

destructor TPyAuditionSource.Destroy;
begin
  FHost.Release;
  inherited Destroy;
end;

procedure TPyAuditionSource.Prepare(ASampleRate, AMaxFrames, AChannels: Integer);
begin
  FPos := 0;
end;

procedure TPyAuditionSource.Reset;
begin
  FPos := 0;
end;

function TPyAuditionSource.Name: string;
begin
  Result := 'Python plug-in audition';
end;

procedure TPyAuditionSource.Render(ABuffer: TAudioBuffer);
var
  n, done, m, c, i, p, nch, sc: Integer;
  ok: Boolean;
begin
  n := ABuffer.FrameCount;
  nch := ABuffer.ChannelCount;
  if FLen <= 0 then
  begin
    ABuffer.Clear;
    Exit;
  end;
  done := 0;
  while done < n do
  begin
    m := Min(n - done, FHost.MaxFrames);
    for i := 0 to m - 1 do
    begin
      p := (FPos + i) mod FLen;
      for c := 0 to FChans - 1 do FIn[c][i] := FMat[Min(c, High(FMat))][p];
    end;
    FPos := (FPos + m) mod FLen;
    ok := (not FBypass) and FHost.ProcessBlock(FInPtrs, FOutPtrs, m);
    if not ok then
      for c := 0 to FChans - 1 do Move(FIn[c][0], FOut[c][0], m * SizeOf(Single));
    for c := 0 to nch - 1 do
    begin
      sc := Min(c, FChans - 1);
      Move(FOut[sc][0], PSingle(PByte(ABuffer.ChannelPtr(c)) + done * SizeOf(Single))^, m * SizeOf(Single));
    end;
    Inc(done, m);
  end;
end;

{ ---- the built-in phrase ---- }

{ a plucked string: a burst of noise circulating in a delay line whose loop averages neighbouring samples,
  which dies away from the top down like a real string }
procedure AddPluck(var ABuf: TArray<Single>; AStart: Integer; AFreq, ADur, AAmp: Double; ARate: Integer;
  var ASeed: Cardinal);
var
  line: TArray<Single>;
  n, i, p, q, len, idx: Integer;
  y, decay: Double;
begin
  n := Round(ARate / AFreq);
  if n < 2 then Exit;
  SetLength(line, n);
  for i := 0 to n - 1 do
  begin
    ASeed := ASeed * 1664525 + 1013904223;
    line[i] := (ASeed shr 8) / 8388608.0 - 1.0;
  end;
  { a softer pick: smooth the initial burst once }
  for i := n - 1 downto 1 do line[i] := 0.6 * line[i] + 0.4 * line[i - 1];
  decay := 0.9965 + 0.0025 * Min(1.0, 110.0 / AFreq);
  len := Round(ADur * ARate);
  p := 0;
  for i := 0 to len - 1 do
  begin
    idx := AStart + i;
    if idx >= Length(ABuf) then Break;
    q := p + 1;
    if q >= n then q := 0;
    y := line[p];
    line[p] := 0.5 * (y + line[q]) * decay;
    ABuf[idx] := ABuf[idx] + y * AAmp;
    p := q;
  end;
end;

function BuildGuitarPhrase(ARate: Integer): TPyPlanar;
const
  STEP = 0.3125;   // an eighth note at 96 BPM
  RIFF: array[0..15] of Double = (82.41, 82.41, 98.0, 82.41, 110.0, 82.41, 123.47, 82.41,
                                  82.41, 82.41, 98.0, 110.0, 123.47, 110.0, 98.0, 82.41);
  CHORD: array[0..3] of Double = (82.41, 123.47, 164.81, 196.0);
var
  buf: TArray<Single>;
  total, bar, k, i: Integer;
  seed: Cardinal;
  peak, g: Double;
begin
  total := Round((2 * 16 * STEP + 3.2) * ARate);
  SetLength(buf, total);
  seed := 20241031;
  for bar := 0 to 1 do
    for k := 0 to 15 do
      { palm-muted low E pulses (short), the other notes ring }
      AddPluck(buf, Round((bar * 16 + k) * STEP * ARate), RIFF[k],
        IfThen(RIFF[k] < 83, 0.22, 0.42), IfThen(RIFF[k] < 83, 0.8, 1.0), ARate, seed);
  for k := 0 to High(CHORD) do
    AddPluck(buf, Round((32 * STEP + k * 0.018) * ARate), CHORD[k], 3.0, 0.7, ARate, seed);
  peak := 0;
  for i := 0 to High(buf) do
    if Abs(buf[i]) > peak then peak := Abs(buf[i]);
  if peak > 0 then g := 0.45 / peak else g := 1;
  for i := 0 to High(buf) do buf[i] := buf[i] * g;
  SetLength(Result, 2);
  Result[0] := buf;
  Result[1] := Copy(buf);
end;

end.
