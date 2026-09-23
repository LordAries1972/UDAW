unit UDAW.DSP.TimeStretch;
{$I udaw.inc}
{$POINTERMATH ON}

{ Phase 19 - Advanced DSP (plan section, docs/UDAW-Original-Plan.txt lines
  3706-3719): offline phase-vocoder time-stretching. No third-party code.

  TPhaseVocoderStretch implements the classic STFT phase-vocoder:

    * analyse overlapping Hann-windowed frames at a fixed hop Ha = FFTSize/4;
    * for each bin, take the phase difference from the previous analysis
      frame, subtract the phase the bin would have advanced by if the signal
      were exactly on-bin (2*pi*Ha*bin/FFTSize), unwrap that residual into
      (-pi, pi], and add it back to get the bin's true instantaneous phase
      advance per analysis hop;
    * scale that true advance by the synthesis hop Hs = Round(Ha*Stretch)
      instead of Ha, and accumulate a running synthesis phase per bin;
    * resynthesise each frame from the original magnitude + accumulated
      synthesis phase, window again, and overlap-add at Hs-spaced positions,
      normalising by the accumulated sum of squared window values so the
      overlap-add itself does not colour the amplitude.

  This is an OFFLINE utility - Process allocates its output and internal
  scratch freely; it is not meant to run on the real-time audio thread. }

interface

uses
  SysUtils, Math,
  UDAW.DSP.Math, UDAW.DSP.FFT;

type
  TPhaseVocoderStretch = class
  private
    FFFTSize: Integer;
    FHopAnalysis: Integer;
    FFFT: TFFT;
    FWindow: array of Single;
  public
    constructor Create(AFFTSize: Integer = 2048);
    destructor Destroy; override;

    { AStretchFactor = output length / input length (clamped to 0.25..4.0). }
    procedure Process(const AIn: array of Single; AStretchFactor: Double;
      out AOut: TArray<Single>);

    function EstimateOutputLength(AInputLength: Integer; AStretchFactor: Double): Integer;

    property FFTSize: Integer read FFFTSize;
    property HopAnalysis: Integer read FHopAnalysis;
  end;

implementation

function WrapPhase(APhase: Double): Double;
begin
  { wrap into (-pi, pi] }
  Result := APhase - DSP_TWO_PI * Round(APhase / DSP_TWO_PI);
end;

{ ================= TPhaseVocoderStretch ================= }

constructor TPhaseVocoderStretch.Create(AFFTSize: Integer);
begin
  inherited Create;
  if not IsPow2(AFFTSize) or (AFFTSize < 64) then
    AFFTSize := NextPow2(Max(64, AFFTSize));
  FFFTSize := AFFTSize;
  FHopAnalysis := FFFTSize div 4;
  FFFT := TFFT.Create(FFFTSize);
  SetLength(FWindow, FFFTSize);
  FillWindow(wkHann, FWindow);
end;

destructor TPhaseVocoderStretch.Destroy;
begin
  FFFT.Free;
  inherited Destroy;
end;

function TPhaseVocoderStretch.EstimateOutputLength(AInputLength: Integer;
  AStretchFactor: Double): Integer;
var
  hs: Integer;
  numFrames: Integer;
begin
  if AStretchFactor < 0.25 then AStretchFactor := 0.25;
  if AStretchFactor > 4.0 then AStretchFactor := 4.0;
  hs := Round(FHopAnalysis * AStretchFactor);
  if hs < 1 then hs := 1;
  if AInputLength <= FFFTSize then
    numFrames := 1
  else
    numFrames := 1 + ((AInputLength - FFFTSize) div FHopAnalysis) + 1;
  Result := (numFrames - 1) * hs + FFFTSize;
  if Result < FFFTSize then Result := FFFTSize;
end;

procedure TPhaseVocoderStretch.Process(const AIn: array of Single;
  AStretchFactor: Double; out AOut: TArray<Single>);
var
  n, hs: Integer;
  inLen, outLen: Integer;
  numFrames, fr, startIn, startOut, i, bin, nb: Integer;
  frameTime: array of Double;
  frameWin: array of Single;
  re, im: array of Double;
  mag, phase: array of Double;
  prevPhase, sumPhase: array of Double;
  expectedAdv, delta, trueFreqPerHop: Double;
  synRe, synIm: array of Double;
  outFrame: array of Single;
  outSum: array of Double;
  winSumSq: array of Double;
begin
  n := FFFTSize;
  if AStretchFactor < 0.25 then AStretchFactor := 0.25;
  if AStretchFactor > 4.0 then AStretchFactor := 4.0;
  hs := Round(FHopAnalysis * AStretchFactor);
  if hs < 1 then hs := 1;

  inLen := Length(AIn);
  if inLen = 0 then
  begin
    SetLength(AOut, 0);
    Exit;
  end;

  if inLen <= n then
    numFrames := 1
  else
    numFrames := 1 + ((inLen - n) div FHopAnalysis) + 1;

  outLen := (numFrames - 1) * hs + n;
  SetLength(AOut, outLen);
  SetLength(outSum, outLen);
  SetLength(winSumSq, outLen);
  for i := 0 to outLen - 1 do
  begin
    outSum[i] := 0;
    winSumSq[i] := 0;
  end;

  nb := FFFT.SpectrumBins;
  SetLength(frameTime, n);
  SetLength(frameWin, n);
  SetLength(re, nb);
  SetLength(im, nb);
  SetLength(mag, nb);
  SetLength(phase, nb);
  SetLength(prevPhase, nb);
  SetLength(sumPhase, nb);
  SetLength(synRe, n);
  SetLength(synIm, n);
  SetLength(outFrame, n);
  for bin := 0 to nb - 1 do
  begin
    prevPhase[bin] := 0;
    sumPhase[bin] := 0;
  end;

  for fr := 0 to numFrames - 1 do
  begin
    startIn := fr * FHopAnalysis;
    for i := 0 to n - 1 do
    begin
      if (startIn + i) < inLen then
        frameTime[i] := AIn[startIn + i]
      else
        frameTime[i] := 0;
      frameWin[i] := Single(frameTime[i] * FWindow[i]);
    end;

    FFFT.RealForward(frameWin, re, im);
    FFFT.MagnitudeSpectrum(re, im, mag);
    FFFT.PhaseSpectrum(re, im, phase);

    for bin := 0 to nb - 1 do
    begin
      { expected phase advance per analysis hop for an exactly-on-bin signal }
      expectedAdv := DSP_TWO_PI * FHopAnalysis * bin / n;
      delta := WrapPhase(phase[bin] - prevPhase[bin] - expectedAdv);
      trueFreqPerHop := expectedAdv + delta;   // true phase advance per analysis hop
      prevPhase[bin] := phase[bin];

      if fr = 0 then
        sumPhase[bin] := phase[bin]
      else
        { scale the true per-hop advance by the synthesis hop instead }
        sumPhase[bin] := sumPhase[bin] + trueFreqPerHop * (hs / FHopAnalysis);

      synRe[bin] := mag[bin] * Cos(sumPhase[bin]);
      synIm[bin] := mag[bin] * Sin(sumPhase[bin]);
    end;

    FFFT.RealInverse(synRe, synIm, outFrame);

    startOut := fr * hs;
    for i := 0 to n - 1 do
    begin
      outSum[startOut + i] := outSum[startOut + i] + outFrame[i] * FWindow[i];
      winSumSq[startOut + i] := winSumSq[startOut + i] + Sqr(Double(FWindow[i]));
    end;
  end;

  for i := 0 to outLen - 1 do
  begin
    if winSumSq[i] > 1.0E-9 then
      AOut[i] := Single(outSum[i] / winSumSq[i])
    else
      AOut[i] := 0;
  end;
end;

end.
