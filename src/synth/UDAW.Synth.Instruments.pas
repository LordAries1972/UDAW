unit UDAW.Synth.Instruments;
{$I udaw.inc}
{$POINTERMATH ON}

{ Built-in instruments so a project is playable with no third-party plugins:
  - TSubtractiveSynth: 2 band-limited (polyBLEP) oscillators + sub, unison
    detune, resonant low-pass with envelope + LFO modulation, ADSR amp env,
    glide-free polyphonic voice allocation.
  - TSampler: pitch-mapped single-sample instrument (root key, loop, ADSR)
    with linear-interpolated resampling.
  Both render a list of TSeqNote (quarter-note beats) offline to stereo at a
  given BPM, so the result drops onto the timeline like any recorded clip. }

interface

uses
  SysUtils, Math,
  UDAW.Audio.Types, UDAW.DSP.Filters, UDAW.DSP.Math, UDAW.Sequencer.Patterns;

type
  TOscShape = (osSine, osSaw, osSquare, osTriangle);

  TSynthPatch = record
    Osc1, Osc2: TOscShape;
    Osc2Semis: Double;      { coarse tune of osc 2 }
    Osc2Detune: Double;     { cents }
    OscMix: Double;         { 0 = osc1, 1 = osc2 }
    SubLevel: Double;       { sine one octave down, 0..1 }
    Unison: Integer;        { 1..7 voices per note }
    UnisonDetune: Double;   { cents spread }
    CutoffHz: Double;
    Resonance: Double;      { Q, 0.5..12 }
    FilterEnvAmount: Double;{ octaves }
    LfoRateHz: Double;
    LfoToCutoff: Double;    { octaves }
    LfoToPitch: Double;     { cents }
    AmpA, AmpD, AmpS, AmpR: Double; { seconds / level }
    FltA, FltD, FltS, FltR: Double;
    Gain: Double;
    class function Default: TSynthPatch; static;
    class function Bass: TSynthPatch; static;
    class function Pad: TSynthPatch; static;
    class function Lead: TSynthPatch; static;
  end;

  TSubtractiveSynth = class
  private
    FSampleRate: Integer;
  public
    Patch: TSynthPatch;
    constructor Create(ASampleRate: Integer);
    procedure Render(const ANotes: TSeqNotes; ABpm: Double; ATailSec: Double;
      out AL, AR: TAudioSampleArray);
  end;

  TSampler = class
  private
    FSampleRate: Integer;
  public
    Data: TAudioSampleArray;   { mono source }
    SourceRate: Integer;
    RootKey: Integer;
    LoopStart, LoopEnd: Integer; { LoopEnd <= LoopStart disables looping }
    AttackSec, ReleaseSec: Double;
    constructor Create(ASampleRate: Integer);
    procedure Render(const ANotes: TSeqNotes; ABpm: Double; ATailSec: Double;
      out AL, AR: TAudioSampleArray);
  end;

implementation


uses
  UDAW.DSP.MathTables;

class function TSynthPatch.Default: TSynthPatch;
begin
  Result.Osc1 := osSaw; Result.Osc2 := osSaw;
  Result.Osc2Semis := 0; Result.Osc2Detune := 7; Result.OscMix := 0.5;
  Result.SubLevel := 0.0; Result.Unison := 1; Result.UnisonDetune := 12;
  Result.CutoffHz := 4000; Result.Resonance := 0.9; Result.FilterEnvAmount := 1.0;
  Result.LfoRateHz := 5; Result.LfoToCutoff := 0; Result.LfoToPitch := 0;
  Result.AmpA := 0.005; Result.AmpD := 0.2; Result.AmpS := 0.7; Result.AmpR := 0.25;
  Result.FltA := 0.005; Result.FltD := 0.3; Result.FltS := 0.3; Result.FltR := 0.25;
  Result.Gain := 0.25;
end;

class function TSynthPatch.Bass: TSynthPatch;
begin
  Result := Default;
  Result.Osc1 := osSaw; Result.Osc2 := osSquare; Result.Osc2Semis := -12;
  Result.SubLevel := 0.6; Result.CutoffHz := 500; Result.Resonance := 2.5;
  Result.FilterEnvAmount := 2.5; Result.AmpS := 0.85; Result.AmpR := 0.1;
  Result.FltD := 0.18; Result.FltS := 0.1;
end;

class function TSynthPatch.Pad: TSynthPatch;
begin
  Result := Default;
  Result.Unison := 5; Result.UnisonDetune := 18; Result.CutoffHz := 1800;
  Result.AmpA := 0.6; Result.AmpR := 1.4; Result.FltA := 0.8; Result.FltD := 1.2;
  Result.FltS := 0.6; Result.LfoToCutoff := 0.3; Result.LfoRateHz := 0.3;
end;

class function TSynthPatch.Lead: TSynthPatch;
begin
  Result := Default;
  Result.Osc1 := osSquare; Result.Osc2 := osSaw; Result.Unison := 3;
  Result.UnisonDetune := 8; Result.CutoffHz := 3200; Result.Resonance := 1.8;
  Result.LfoToPitch := 8; Result.LfoRateHz := 5.5; Result.AmpR := 0.15;
end;

{ ---- helpers ---- }

function PolyBlep(t, dt: Double): Double; inline;
begin
  if t < dt then
  begin
    t := t / dt;
    Result := t + t - t * t - 1.0;
  end
  else if t > 1.0 - dt then
  begin
    t := (t - 1.0) / dt;
    Result := t * t + t + t + 1.0;
  end
  else
    Result := 0.0;
end;

function OscSample(AShape: TOscShape; APhase, ADt: Double; var ATri: Double): Double;
begin
  case AShape of
    osSine: Result := FastSin(2.0 * Pi * APhase);
    osSaw: Result := 2.0 * APhase - 1.0 - PolyBlep(APhase, ADt);
    osSquare:
      begin
        if APhase < 0.5 then Result := 1.0 else Result := -1.0;
        Result := Result + PolyBlep(APhase, ADt);
        Result := Result - PolyBlep(Frac(APhase + 0.5), ADt);
      end;
  else
    { triangle: leaky-integrated band-limited square }
    begin
      if APhase < 0.5 then Result := 1.0 else Result := -1.0;
      Result := Result + PolyBlep(APhase, ADt) - PolyBlep(Frac(APhase + 0.5), ADt);
      ATri := ATri + 4.0 * ADt * Result;
      ATri := ATri * 0.9995;
      Result := ATri;
    end;
  end;
end;

{ linear ADSR evaluated from note-relative time; ARelT < 0 while held }
function Adsr(A, D, S, R, T, NoteLen, RelT: Double; ALevelAtRel: Double): Double;
begin
  if RelT >= 0 then
  begin
    if R <= 1e-4 then Result := 0 else Result := ALevelAtRel * (1.0 - RelT / R);
    if Result < 0 then Result := 0;
    Exit;
  end;
  if T < A then
    Result := T / Max(A, 1e-4)
  else if T < A + D then
    Result := 1.0 - (1.0 - S) * (T - A) / Max(D, 1e-4)
  else
    Result := S;
end;

function EnvAtRelease(A, D, S, NoteLen: Double): Double;
begin
  if NoteLen < A then Result := NoteLen / Max(A, 1e-4)
  else if NoteLen < A + D then Result := 1.0 - (1.0 - S) * (NoteLen - A) / Max(D, 1e-4)
  else Result := S;
end;

function KeyToHz(AKey: Double): Double; inline;
begin
  Result := 440.0 * SemitoneRatio(AKey - 69.0);
end;

{ TSubtractiveSynth }

constructor TSubtractiveSynth.Create(ASampleRate: Integer);
begin
  inherited Create;
  FSampleRate := ASampleRate;
  Patch := TSynthPatch.Default;
end;

procedure TSubtractiveSynth.Render(const ANotes: TSeqNotes; ABpm: Double;
  ATailSec: Double; out AL, AR: TAudioSampleArray);
var
  spb, endBeat, totalSec: Double;
  total, ni, u, i, i0, i1, nUni: Integer;
  nt: TSeqNote;
  noteSec, relSec, t, relT, sr, f0, det, ph3, dt1, dt2: Double;
  lfo, lfoPh, s, envA, envF, levelA, levelF, fc, vel, pan, gl, gr: Double;
  flt, fltR: TBiquad;
  ph1a, ph2a: array[0..6] of Double;
  tri1a, tri2a: array[0..6] of Double;
  ratio1, ratio2: Double;
begin
  sr := FSampleRate;
  spb := 60.0 / Max(ABpm, 20.0);
  endBeat := 0;
  for ni := 0 to High(ANotes) do
    endBeat := Max(endBeat, ANotes[ni].Beat + ANotes[ni].Length);
  totalSec := endBeat * spb + Patch.AmpR + ATailSec;
  total := Max(Ceil(totalSec * sr), 1);
  SetLength(AL, total);
  SetLength(AR, total);
  nUni := EnsureRange(Patch.Unison, 1, 7);
  for ni := 0 to High(ANotes) do
  begin
    nt := ANotes[ni];
    noteSec := nt.Length * spb;
    relSec := Max(Patch.AmpR, Patch.FltR);
    i0 := Max(Round(nt.Beat * spb * sr), 0);
    i1 := Min(i0 + Round((noteSec + relSec) * sr), total - 1);
    vel := nt.Velocity / 127.0;
    f0 := KeyToHz(nt.Key);
    levelA := EnvAtRelease(Patch.AmpA, Patch.AmpD, Patch.AmpS, noteSec);
    levelF := EnvAtRelease(Patch.FltA, Patch.FltD, Patch.FltS, noteSec);
    flt.Init(sr);
    flt.Reset;
    fltR.Init(sr);
    fltR.Reset;
    for u := 0 to 6 do
    begin
      ph1a[u] := Frac(u * 0.137); ph2a[u] := Frac(u * 0.291);
      tri1a[u] := 0; tri2a[u] := 0;
    end;
    lfoPh := 0;
    ratio2 := FastExp2(Patch.Osc2Semis / 12.0 + Patch.Osc2Detune / 1200.0);
    for i := i0 to i1 do
    begin
      t := (i - i0) / sr;
      if t >= noteSec then relT := t - noteSec else relT := -1;
      envA := Adsr(Patch.AmpA, Patch.AmpD, Patch.AmpS, Patch.AmpR, t, noteSec, relT, levelA);
      envF := Adsr(Patch.FltA, Patch.FltD, Patch.FltS, Patch.FltR, t, noteSec, relT, levelF);
      lfo := FastSin(2.0 * Pi * lfoPh);
      lfoPh := Frac(lfoPh + Patch.LfoRateHz / sr);
      gl := 0; gr := 0;
      for u := 0 to nUni - 1 do
      begin
        if nUni = 1 then det := 0
        else det := (u / (nUni - 1) - 0.5) * 2.0 * Patch.UnisonDetune;
        ratio1 := FastExp2((det + lfo * Patch.LfoToPitch) / 1200.0);
        dt1 := Min(f0 * ratio1 / sr, 0.45);
        dt2 := Min(f0 * ratio1 * ratio2 / sr, 0.45);
        s := (1.0 - Patch.OscMix) * OscSample(Patch.Osc1, ph1a[u], dt1, tri1a[u])
           + Patch.OscMix * OscSample(Patch.Osc2, ph2a[u], dt2, tri2a[u]);
        ph1a[u] := Frac(ph1a[u] + dt1);
        ph2a[u] := Frac(ph2a[u] + dt2);
        if Patch.SubLevel > 0 then
        begin
          ph3 := Frac(ph1a[u] * 0.5);
          s := s + Patch.SubLevel * FastSin(2.0 * Pi * ph3);
        end;
        if nUni = 1 then pan := 0.5 else pan := u / (nUni - 1);
        gl := gl + s * FastCos(pan * Pi * 0.5);
        gr := gr + s * FastSin(pan * Pi * 0.5);
      end;
      fc := Patch.CutoffHz * FastExp2(Patch.FilterEnvAmount * envF + Patch.LfoToCutoff * lfo);
      fc := EnsureRange(fc, 30.0, sr * 0.45);
      flt.SetParams(bqLowpass, fc, EnsureRange(Patch.Resonance, 0.4, 14.0));
      fltR.SetParams(bqLowpass, fc, EnsureRange(Patch.Resonance, 0.4, 14.0));
      s := envA * vel * Patch.Gain / Sqrt(nUni);
      AL[i] := AL[i] + flt.ProcessSample(Single(gl)) * Single(s);
      AR[i] := AR[i] + fltR.ProcessSample(Single(gr)) * Single(s);
    end;
  end;
end;

{ TSampler }

constructor TSampler.Create(ASampleRate: Integer);
begin
  inherited Create;
  FSampleRate := ASampleRate;
  SourceRate := ASampleRate;
  RootKey := 60;
  AttackSec := 0.002;
  ReleaseSec := 0.08;
end;

procedure TSampler.Render(const ANotes: TSeqNotes; ABpm: Double; ATailSec: Double;
  out AL, AR: TAudioSampleArray);
var
  spb, endBeat, sr, step, pos, noteSec, t, relT, env, frac_, v: Double;
  ni, i, i0, i1, total, ip, n: Integer;
  nt: TSeqNote;
begin
  sr := FSampleRate;
  spb := 60.0 / Max(ABpm, 20.0);
  n := Length(Data);
  endBeat := 0;
  for ni := 0 to High(ANotes) do
    endBeat := Max(endBeat, ANotes[ni].Beat + ANotes[ni].Length);
  total := Max(Ceil((endBeat * spb + ReleaseSec + ATailSec) * sr), 1);
  SetLength(AL, total);
  SetLength(AR, total);
  if n < 2 then Exit;
  for ni := 0 to High(ANotes) do
  begin
    nt := ANotes[ni];
    noteSec := nt.Length * spb;
    step := SemitoneRatio(nt.Key - RootKey) * SourceRate / sr;
    i0 := Max(Round(nt.Beat * spb * sr), 0);
    i1 := Min(i0 + Round((noteSec + ReleaseSec) * sr), total - 1);
    pos := 0;
    for i := i0 to i1 do
    begin
      t := (i - i0) / sr;
      if t < AttackSec then env := t / Max(AttackSec, 1e-4) else env := 1.0;
      if t >= noteSec then
      begin
        relT := t - noteSec;
        env := env * Max(1.0 - relT / Max(ReleaseSec, 1e-4), 0.0);
      end;
      if (LoopEnd > LoopStart) and (pos >= LoopEnd) then
        pos := pos - (LoopEnd - LoopStart);
      ip := Trunc(pos);
      if ip >= n - 1 then Break;
      frac_ := pos - ip;
      v := Data[ip] * (1.0 - frac_) + Data[ip + 1] * frac_;
      v := v * env * nt.Velocity / 127.0;
      AL[i] := AL[i] + Single(v);
      AR[i] := AR[i] + Single(v);
      pos := pos + step;
    end;
  end;
end;

end.
