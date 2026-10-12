unit UDAW.DSP.AudioToMidi;
{$I udaw.inc}
{$POINTERMATH ON}

{ Audio -> MIDI note transcription, offline.
  - Mono mode: per-frame normalised autocorrelation pitch (YIN-style
    difference function with parabolic refinement) + median smoothing +
    note segmentation with a minimum length and level gate.
  - Poly mode: STFT magnitude peak picking with harmonic suppression (a peak
    that is an integer multiple of a stronger lower peak is treated as its
    overtone), tracked frame-to-frame into notes.
  Result notes are in quarter-note beats at the given BPM, ready to convert
  to ticks (Beat * PPQ) for the Piano Roll. }

interface

uses
  SysUtils, Math, Generics.Collections,
  UDAW.Audio.Types, UDAW.DSP.FFT, UDAW.DSP.Math,
  UDAW.Sequencer.Patterns;

type
  TA2MMode = (a2mMono, a2mPoly);

  TA2MOptions = record
    Mode: TA2MMode;
    Bpm: Double;
    MinNoteSec: Double;    { discard shorter notes }
    GateDb: Double;        { frames below this RMS dBFS are silence }
    MinHz, MaxHz: Double;
    MaxVoices: Integer;    { poly: peaks per frame }
    PeakDb: Double;        { poly: peak must be within this of the frame max }
    class function Default: TA2MOptions; static;
  end;

function AudioToMidi(const AMono: array of Single; ASampleRate: Integer;
  const AOpts: TA2MOptions): TSeqNotes;

implementation

class function TA2MOptions.Default: TA2MOptions;
begin
  Result.Mode := a2mMono;
  Result.Bpm := 120;
  Result.MinNoteSec := 0.06;
  Result.GateDb := -45;
  Result.MinHz := 55;
  Result.MaxHz := 2000;
  Result.MaxVoices := 4;
  Result.PeakDb := 24;
end;

type
  TOpenNote = record
    Key: Integer;
    StartFrame: Integer;
    LastFrame: Integer;
    PeakLevel: Double;
    Active: Boolean;
  end;

function HzToKey(AHz: Double): Integer;
begin
  Result := Round(69.0 + 12.0 * Log2(AHz / 440.0));
end;

{ YIN difference-function pitch for one window; 0 when unvoiced }
function FramePitch(const AX: array of Single; AStart, AN, ASR: Integer;
  AMinHz, AMaxHz: Double): Double;
var
  tauMin, tauMax, tau, j, best: Integer;
  d: TArray<Double>;
  run, v, a, b, c, denom, shift: Double;
begin
  Result := 0;
  tauMin := Max(Trunc(ASR / AMaxHz), 2);
  tauMax := Min(Trunc(ASR / AMinHz), AN div 2 - 1);
  if tauMax <= tauMin + 2 then Exit;
  SetLength(d, tauMax + 2);
  for tau := 1 to tauMax + 1 do
  begin
    v := 0;
    for j := 0 to AN div 2 - 1 do
      v := v + Sqr(AX[AStart + j] - AX[AStart + j + tau]);
    d[tau] := v;
  end;
  { cumulative-mean normalised difference }
  run := 0;
  best := -1;
  for tau := 1 to tauMax + 1 do
  begin
    run := run + d[tau];
    if run > 0 then d[tau] := d[tau] * tau / run else d[tau] := 1.0;
  end;
  tau := tauMin;
  while tau <= tauMax do
  begin
    if d[tau] < 0.15 then
    begin
      while (tau + 1 <= tauMax) and (d[tau + 1] < d[tau]) do Inc(tau);
      best := tau;
      Break;
    end;
    Inc(tau);
  end;
  if best < 0 then Exit;
  { parabolic refinement }
  a := d[best - 1]; b := d[best]; c := d[best + 1];
  denom := a - 2.0 * b + c;
  if Abs(denom) > 1e-12 then shift := 0.5 * (a - c) / denom else shift := 0;
  Result := ASR / (best + shift);
end;

function Median3(A, B, C: Integer): Integer;
begin
  if A > B then begin Result := A; A := B; B := Result; end;
  if B > C then B := C;
  if A > B then Result := A else Result := B;
end;

function AudioToMidi(const AMono: array of Single; ASampleRate: Integer;
  const AOpts: TA2MOptions): TSeqNotes;
const
  WIN = 2048;
var
  hop, frames, f, i, k, nv, bins, peakBin, m, key: Integer;
  keys: TArray<Integer>;
  levels: TArray<Double>;
  notes: TList<TSeqNote>;
  opens: array of TOpenNote;
  fft: TFFT;
  buf: TArray<Single>;
  re, im, mag: TArray<Double>;
  hann: TArray<Single>;
  hz, rms, gate, maxMag, binHz, secPerBeat, hzk: Double;
  peakKeys: TArray<Integer>;
  peakMag: TArray<Double>;
  used: TArray<Boolean>;
  cnt: Integer;

  procedure CloseNote(var AN: TOpenNote);
  var
    nt: TSeqNote;
    lenSec: Double;
  begin
    if not AN.Active then Exit;
    lenSec := (AN.LastFrame - AN.StartFrame + 1) * hop / ASampleRate;
    if lenSec >= AOpts.MinNoteSec then
    begin
      nt.Beat := (AN.StartFrame * hop / ASampleRate) / secPerBeat;
      nt.Length := lenSec / secPerBeat;
      nt.Key := EnsureRange(AN.Key, 0, 127);
      nt.Velocity := EnsureRange(Round(30 + AN.PeakLevel * 97), 1, 127);
      notes.Add(nt);
    end;
    AN.Active := False;
  end;

begin
  SetLength(Result, 0);
  if Length(AMono) < WIN * 2 then Exit;
  secPerBeat := 60.0 / Max(AOpts.Bpm, 20.0);
  hop := WIN div 4;
  frames := (Length(AMono) - WIN) div hop;
  gate := Power(10.0, AOpts.GateDb / 20.0);
  notes := TList<TSeqNote>.Create;
  try
    if AOpts.Mode = a2mMono then
    begin
      SetLength(keys, frames);
      SetLength(levels, frames);
      for f := 0 to frames - 1 do
      begin
        rms := 0;
        for i := 0 to WIN - 1 do rms := rms + Sqr(AMono[f * hop + i]);
        rms := Sqrt(rms / WIN);
        levels[f] := Min(rms * 4.0, 1.0);
        keys[f] := -1;
        if rms < gate then Continue;
        hz := FramePitch(AMono, f * hop, WIN, ASampleRate, AOpts.MinHz, AOpts.MaxHz);
        if hz > 0 then keys[f] := HzToKey(hz);
      end;
      { median smoothing removes single-frame octave/semitone glitches }
      for f := 1 to frames - 2 do
        if (keys[f - 1] >= 0) and (keys[f] >= 0) and (keys[f + 1] >= 0) then
          keys[f] := Median3(keys[f - 1], keys[f], keys[f + 1]);
      SetLength(opens, 1);
      opens[0].Active := False;
      for f := 0 to frames - 1 do
      begin
        if keys[f] < 0 then
        begin
          CloseNote(opens[0]);
          Continue;
        end;
        if opens[0].Active and (Abs(opens[0].Key - keys[f]) <= 0) then
        begin
          opens[0].LastFrame := f;
          opens[0].PeakLevel := Max(opens[0].PeakLevel, levels[f]);
        end
        else
        begin
          CloseNote(opens[0]);
          opens[0].Active := True;
          opens[0].Key := keys[f];
          opens[0].StartFrame := f;
          opens[0].LastFrame := f;
          opens[0].PeakLevel := levels[f];
        end;
      end;
      CloseNote(opens[0]);
    end
    else
    begin
      fft := TFFT.Create(WIN * 2); { zero-padded x2 for finer bins }
      try
        bins := WIN + 1;
        SetLength(buf, WIN * 2);
        SetLength(re, bins);
        SetLength(im, bins);
        SetLength(mag, bins);
        SetLength(hann, WIN);
        for i := 0 to WIN - 1 do
          hann[i] := 0.5 - 0.5 * Cos(2.0 * Pi * i / WIN);
        binHz := ASampleRate / (WIN * 2);
        SetLength(opens, Max(AOpts.MaxVoices, 1) * 4);
        for k := 0 to High(opens) do opens[k].Active := False;
        for f := 0 to frames - 1 do
        begin
          rms := 0;
          for i := 0 to WIN - 1 do
          begin
            buf[i] := AMono[f * hop + i] * hann[i];
            rms := rms + Sqr(AMono[f * hop + i]);
          end;
          for i := WIN to WIN * 2 - 1 do buf[i] := 0;
          rms := Sqrt(rms / WIN);
          SetLength(peakKeys, 0);
          SetLength(peakMag, 0);
          if rms >= gate then
          begin
            fft.RealForward(buf, re, im);
            maxMag := 0;
            for i := 0 to bins - 1 do
            begin
              mag[i] := Sqrt(re[i] * re[i] + im[i] * im[i]);
              if (i * binHz >= AOpts.MinHz) and (i * binHz <= AOpts.MaxHz) then
                maxMag := Max(maxMag, mag[i]);
            end;
            { candidate peaks strongest-first }
            SetLength(used, 0);
            SetLength(used, bins);   // reset every frame (SetLength alone keeps old flags)
            for m := 1 to Max(AOpts.MaxVoices, 1) do
            begin
              peakBin := -1;
              for i := 2 to bins - 3 do
                if (i * binHz >= AOpts.MinHz) and (i * binHz <= AOpts.MaxHz) and
                   (not used[i]) and (mag[i] > mag[i - 1]) and (mag[i] >= mag[i + 1]) and
                   (mag[i] > maxMag * Power(10.0, -AOpts.PeakDb / 20.0)) then
                  if (peakBin < 0) or (mag[i] > mag[peakBin]) then peakBin := i;
              if peakBin < 0 then Break;
              hz := peakBin * binHz;
              { overtone of an already-picked lower note? }
              nv := 0;
              for k := 0 to High(peakKeys) do
              begin
                hzk := 440.0 * Power(2.0, (peakKeys[k] - 69) / 12.0);
                for cnt := 2 to 6 do
                  if Abs(hz / hzk - cnt) < 0.04 * cnt then nv := 1;
              end;
              for k := Max(peakBin - 3, 0) to Min(peakBin + 3, bins - 1) do used[k] := True;
              if nv = 1 then Continue;
              SetLength(peakKeys, Length(peakKeys) + 1);
              SetLength(peakMag, Length(peakMag) + 1);
              peakKeys[High(peakKeys)] := HzToKey(hz);
              peakMag[High(peakMag)] := Min(rms * 4.0, 1.0);
            end;
          end;
          { track: extend matching opens notes, close others, opens new ones }
          for k := 0 to High(opens) do
            if opens[k].Active then
            begin
              key := -1;
              for m := 0 to High(peakKeys) do
                if peakKeys[m] = opens[k].Key then key := m;
              if key >= 0 then
              begin
                opens[k].LastFrame := f;
                opens[k].PeakLevel := Max(opens[k].PeakLevel, peakMag[key]);
                peakKeys[key] := -1000;
              end
              else if f - opens[k].LastFrame > 2 then
                CloseNote(opens[k]);
            end;
          for m := 0 to High(peakKeys) do
            if peakKeys[m] > -1000 then
              for k := 0 to High(opens) do
                if not opens[k].Active then
                begin
                  opens[k].Active := True;
                  opens[k].Key := peakKeys[m];
                  opens[k].StartFrame := f;
                  opens[k].LastFrame := f;
                  opens[k].PeakLevel := peakMag[m];
                  Break;
                end;
        end;
        for k := 0 to High(opens) do CloseNote(opens[k]);
      finally
        fft.Free;
      end;
    end;
    Result := notes.ToArray;
  finally
    notes.Free;
  end;
end;

end.
