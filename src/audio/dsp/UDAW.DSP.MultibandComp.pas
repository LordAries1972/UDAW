unit UDAW.DSP.MultibandComp;
{$I udaw.inc}
{$POINTERMATH ON}

{ Phase 19 - Advanced DSP (plan section, docs/UDAW-Original-Plan.txt lines
  3706-3719): multiband dynamics.

  * TMultibandCompressor - a fixed 3-band (low/mid/high) compressor/limiter.
    Each channel is split by a cascaded 4th-order Linkwitz-Riley crossover
    (two cascaded 2nd-order Butterworth TBiquad sections per crossover point,
    which is what makes an LR4 split sum back to a flat, in-phase response
    when the bands are otherwise untouched) into low / mid / high bands; each
    band is then run through its own Phase 10 TDynamicsProcessor, and the
    three processed bands are summed back into the channel.

  * TAdvancedCompressor - a lookahead-capable compressor/limiter. Reuses
    TDynamicsProcessor for the whole detector/curve/ballistics chain, and adds
    a per-channel circular delay line so the *audio* path lags the *detector*
    path by LookaheadMs: the gain the detector computes from an unshifted copy
    of the signal is applied to the delayed (still-to-come) audio, so a
    transient can be caught before it reaches the output - the classic
    lookahead-limiter trick.

  Nothing allocates after Configure; all scratch buffers are sized once. }

interface

uses
  SysUtils, Math,
  UDAW.Audio.Types, UDAW.DSP.Math, UDAW.DSP.Filters, UDAW.DSP.Dynamics;

type
  { ---------------- TMultibandCompressor ---------------- }

  TMultibandCompressor = class
  private
    FSampleRate: Integer;
    FChannels: Integer;
    FLowMidHz: Double;
    FMidHighHz: Double;

    { Per channel, per crossover point, two cascaded Butterworth sections
      (LR4 = 4th order = 2 x 2nd order) for the lowpass and highpass leg. }
    FLowLP1, FLowLP2: array of TBiquad;    // crossover @ LowMidHz, lowpass leg -> low band
    FLowHP1, FLowHP2: array of TBiquad;    // crossover @ LowMidHz, highpass leg -> feeds mid/high split
    FMidLP1, FMidLP2: array of TBiquad;    // crossover @ MidHighHz, lowpass leg -> mid band
    FMidHP1, FMidHP2: array of TBiquad;    // crossover @ MidHighHz, highpass leg -> high band

    FBandProc: array[0..2] of TDynamicsProcessor;

    { scratch, sized once at Configure: [band][channel][frame] }
    FBandBuf: array[0..2] of array of TAudioSampleArray;
    FScratch: array of TAudioSampleArray;   // one temp buffer per channel (highpass leg)
    FBandPtr: array[0..2] of array of PSingle;   // pointers into FBandBuf, reused every block
    FBandFrames: Integer;

    procedure EnsureScratch(AFrames: Integer);
    procedure RecalcCrossovers;
  public
    constructor Create;
    destructor Destroy; override;

    procedure Configure(ASampleRate, AChannels: Integer);
    procedure Reset;

    procedure SetCrossovers(ALowMidHz, AMidHighHz: Double);
    procedure SetBandParams(ABand: Integer; AThresholdDb, ARatio, AKneeDb,
      AAttackMs, AReleaseMs, AMakeupDb: Double);

    { Planar in-place-capable processing; AIn/AOut are channel pointers. }
    procedure ProcessBlock(const AIn, AOut: array of PSingle; AFrames: Integer);

    function BandGainReductionDb(ABand: Integer): Double;

    property LowMidHz: Double read FLowMidHz;
    property MidHighHz: Double read FMidHighHz;
  end;

  { ---------------- TAdvancedCompressor ---------------- }

  TAdvancedCompressor = class
  private
    FSampleRate: Integer;
    FChannels: Integer;
    FLookaheadMs: Double;
    FDelaySamplesMax: Integer;   // capacity, sized for 20 ms ceiling
    FDelaySamples: Integer;      // active delay for the current LookaheadMs
    FCore: TDynamicsProcessor;
    FDelayLine: array of TAudioSampleArray;   // [channel][ring index]
    FWritePos: array of Integer;
    { scratch buffers, sized once and only grown, never shrunk mid-stream }
    FDetectBuf: array of TAudioSampleArray;
    FDelayedBuf: array of TAudioSampleArray;
    FDetectPtr: array of PSingle;
    FDelayedPtr: array of PSingle;
    FScratchFrames: Integer;
    procedure EnsureDelayLine;
    procedure EnsureScratch(AFrames: Integer);
  public
    constructor Create;
    destructor Destroy; override;

    procedure Configure(ASampleRate, AChannels: Integer);
    procedure Reset;

    procedure SetParams(AMode: TDynamicsMode; AThresholdDb, ARatio, AKneeDb,
      AAttackMs, AReleaseMs, AMakeupDb: Double);
    procedure SetLookaheadMs(AMs: Double);

    procedure ProcessBlock(const AIn, AOut: array of PSingle; AFrames: Integer);

    function CurrentGainReductionDb: Double;
  end;

implementation

{ ================= TMultibandCompressor ================= }

constructor TMultibandCompressor.Create;
var
  b: Integer;
begin
  inherited Create;
  FSampleRate := UDAW_DEFAULT_SAMPLE_RATE;
  FChannels := 2;
  FLowMidHz := 250.0;
  FMidHighHz := 2500.0;
  for b := 0 to 2 do
  begin
    FBandProc[b] := TDynamicsProcessor.Create;
    FBandProc[b].SetParams(dynCompressor, 0.0, 1.0, 0.0, 10.0, 120.0, 0.0);
  end;
end;

destructor TMultibandCompressor.Destroy;
var
  b: Integer;
begin
  for b := 0 to 2 do
    FBandProc[b].Free;
  inherited Destroy;
end;

procedure TMultibandCompressor.EnsureScratch(AFrames: Integer);
var
  ch, b: Integer;
begin
  if (AFrames <= FBandFrames) and (Length(FScratch) = FChannels) then Exit;
  FBandFrames := AFrames;
  SetLength(FScratch, FChannels);
  for b := 0 to 2 do
  begin
    SetLength(FBandBuf[b], FChannels);
    SetLength(FBandPtr[b], FChannels);
  end;
  for ch := 0 to FChannels - 1 do
  begin
    SetLength(FScratch[ch], FBandFrames);
    for b := 0 to 2 do
    begin
      SetLength(FBandBuf[b][ch], FBandFrames);
      FBandPtr[b][ch] := @FBandBuf[b][ch][0];
    end;
  end;
end;

procedure TMultibandCompressor.RecalcCrossovers;
var
  ch: Integer;
begin
  if FLowMidHz < 20.0 then FLowMidHz := 20.0;
  if FMidHighHz < FLowMidHz + 20.0 then FMidHighHz := FLowMidHz + 20.0;
  if FMidHighHz > FSampleRate * 0.45 then FMidHighHz := FSampleRate * 0.45;
  if FLowMidHz > FMidHighHz - 20.0 then FLowMidHz := FMidHighHz - 20.0;

  for ch := 0 to FChannels - 1 do
  begin
    FLowLP1[ch].SetParams(bqLowpass, FLowMidHz, 0.70710678);
    FLowLP2[ch].SetParams(bqLowpass, FLowMidHz, 0.70710678);
    FLowHP1[ch].SetParams(bqHighpass, FLowMidHz, 0.70710678);
    FLowHP2[ch].SetParams(bqHighpass, FLowMidHz, 0.70710678);

    FMidLP1[ch].SetParams(bqLowpass, FMidHighHz, 0.70710678);
    FMidLP2[ch].SetParams(bqLowpass, FMidHighHz, 0.70710678);
    FMidHP1[ch].SetParams(bqHighpass, FMidHighHz, 0.70710678);
    FMidHP2[ch].SetParams(bqHighpass, FMidHighHz, 0.70710678);
  end;
end;

procedure TMultibandCompressor.Configure(ASampleRate, AChannels: Integer);
var
  ch, b: Integer;
begin
  if ASampleRate > 0 then FSampleRate := ASampleRate;
  if AChannels > 0 then FChannels := AChannels;

  SetLength(FLowLP1, FChannels); SetLength(FLowLP2, FChannels);
  SetLength(FLowHP1, FChannels); SetLength(FLowHP2, FChannels);
  SetLength(FMidLP1, FChannels); SetLength(FMidLP2, FChannels);
  SetLength(FMidHP1, FChannels); SetLength(FMidHP2, FChannels);
  for ch := 0 to FChannels - 1 do
  begin
    FLowLP1[ch].Init(FSampleRate); FLowLP2[ch].Init(FSampleRate);
    FLowHP1[ch].Init(FSampleRate); FLowHP2[ch].Init(FSampleRate);
    FMidLP1[ch].Init(FSampleRate); FMidLP2[ch].Init(FSampleRate);
    FMidHP1[ch].Init(FSampleRate); FMidHP2[ch].Init(FSampleRate);
  end;

  for b := 0 to 2 do
    FBandProc[b].Configure(FSampleRate, FChannels);

  FBandFrames := 0;
  EnsureScratch(UDAW_DEFAULT_BUFFER_FRAMES);
  RecalcCrossovers;
  Reset;
end;

procedure TMultibandCompressor.Reset;
var
  ch, b: Integer;
begin
  for ch := 0 to FChannels - 1 do
  begin
    FLowLP1[ch].Reset; FLowLP2[ch].Reset;
    FLowHP1[ch].Reset; FLowHP2[ch].Reset;
    FMidLP1[ch].Reset; FMidLP2[ch].Reset;
    FMidHP1[ch].Reset; FMidHP2[ch].Reset;
  end;
  for b := 0 to 2 do
    FBandProc[b].Reset;
end;

procedure TMultibandCompressor.SetCrossovers(ALowMidHz, AMidHighHz: Double);
begin
  FLowMidHz := ALowMidHz;
  FMidHighHz := AMidHighHz;
  RecalcCrossovers;
end;

procedure TMultibandCompressor.SetBandParams(ABand: Integer; AThresholdDb, ARatio,
  AKneeDb, AAttackMs, AReleaseMs, AMakeupDb: Double);
begin
  if (ABand < 0) or (ABand > 2) then Exit;
  FBandProc[ABand].SetParams(dynCompressor, AThresholdDb, ARatio, AKneeDb,
    AAttackMs, AReleaseMs, AMakeupDb);
end;

procedure TMultibandCompressor.ProcessBlock(const AIn, AOut: array of PSingle;
  AFrames: Integer);
var
  ch, i, nc: Integer;
begin
  nc := Length(AIn);
  if nc = 0 then Exit;
  if nc > FChannels then nc := FChannels;
  EnsureScratch(AFrames);

  { --- split each channel into low / mid / high via cascaded LR4 crossovers --- }
  for ch := 0 to nc - 1 do
  begin
    for i := 0 to AFrames - 1 do
    begin
      { low band: LR4 lowpass @ LowMidHz on the raw input }
      FBandBuf[0][ch][i] :=
        FLowLP2[ch].ProcessSample(FLowLP1[ch].ProcessSample(AIn[ch][i]));
      { the complementary highpass leg feeds the mid/high split }
      FScratch[ch][i] :=
        FLowHP2[ch].ProcessSample(FLowHP1[ch].ProcessSample(AIn[ch][i]));
    end;
    for i := 0 to AFrames - 1 do
    begin
      FBandBuf[1][ch][i] :=
        FMidLP2[ch].ProcessSample(FMidLP1[ch].ProcessSample(FScratch[ch][i]));
      FBandBuf[2][ch][i] :=
        FMidHP2[ch].ProcessSample(FMidHP1[ch].ProcessSample(FScratch[ch][i]));
    end;
  end;

  { --- run each band through its own dynamics processor. FBandPtr[b] is a
    persistent (Configure-time-sized) pointer array of length FChannels; in
    the normal case nc = FChannels and it is passed straight through with no
    per-block allocation. The nc < FChannels case (a caller passing fewer
    channel pointers than Configure was told about) is not the real-time hot
    path, so it falls back to a short-lived Copy rather than complicating the
    steady-state buffer layout. }
  if nc = FChannels then
  begin
    FBandProc[0].ProcessBlock(FBandPtr[0], FBandPtr[0], AFrames, []);
    FBandProc[1].ProcessBlock(FBandPtr[1], FBandPtr[1], AFrames, []);
    FBandProc[2].ProcessBlock(FBandPtr[2], FBandPtr[2], AFrames, []);
  end
  else
  begin
    FBandProc[0].ProcessBlock(Copy(FBandPtr[0], 0, nc), Copy(FBandPtr[0], 0, nc), AFrames, []);
    FBandProc[1].ProcessBlock(Copy(FBandPtr[1], 0, nc), Copy(FBandPtr[1], 0, nc), AFrames, []);
    FBandProc[2].ProcessBlock(Copy(FBandPtr[2], 0, nc), Copy(FBandPtr[2], 0, nc), AFrames, []);
  end;

  { --- sum bands back to the output --- }
  for ch := 0 to nc - 1 do
    for i := 0 to AFrames - 1 do
      AOut[ch][i] := Single(FlushDenorm(
        FBandBuf[0][ch][i] + FBandBuf[1][ch][i] + FBandBuf[2][ch][i]));
end;

function TMultibandCompressor.BandGainReductionDb(ABand: Integer): Double;
begin
  if (ABand < 0) or (ABand > 2) then Exit(0.0);
  Result := FBandProc[ABand].CurrentGainReductionDb;
end;

{ ================= TAdvancedCompressor ================= }

constructor TAdvancedCompressor.Create;
begin
  inherited Create;
  FSampleRate := UDAW_DEFAULT_SAMPLE_RATE;
  FChannels := 2;
  FLookaheadMs := 5.0;
  FCore := TDynamicsProcessor.Create;
  FCore.SetParams(dynLimiter, -1.0, 20.0, 1.0, 0.1, 60.0, 0.0);
end;

destructor TAdvancedCompressor.Destroy;
begin
  FCore.Free;
  inherited Destroy;
end;

procedure TAdvancedCompressor.EnsureDelayLine;
var
  ch: Integer;
begin
  FDelaySamplesMax := Round(0.020 * FSampleRate) + 4;   // 20 ms ceiling
  SetLength(FDelayLine, FChannels);
  SetLength(FWritePos, FChannels);
  for ch := 0 to FChannels - 1 do
  begin
    SetLength(FDelayLine[ch], FDelaySamplesMax);
    FWritePos[ch] := 0;
  end;
end;

procedure TAdvancedCompressor.EnsureScratch(AFrames: Integer);
var
  ch: Integer;
begin
  if (AFrames <= FScratchFrames) and (Length(FDetectBuf) = FChannels) then Exit;
  FScratchFrames := AFrames;
  SetLength(FDetectBuf, FChannels);
  SetLength(FDelayedBuf, FChannels);
  SetLength(FDetectPtr, FChannels);
  SetLength(FDelayedPtr, FChannels);
  for ch := 0 to FChannels - 1 do
  begin
    SetLength(FDetectBuf[ch], FScratchFrames);
    SetLength(FDelayedBuf[ch], FScratchFrames);
    FDetectPtr[ch] := @FDetectBuf[ch][0];
    FDelayedPtr[ch] := @FDelayedBuf[ch][0];
  end;
end;

procedure TAdvancedCompressor.Configure(ASampleRate, AChannels: Integer);
begin
  if ASampleRate > 0 then FSampleRate := ASampleRate;
  if AChannels > 0 then FChannels := AChannels;
  FCore.Configure(FSampleRate, FChannels);
  EnsureDelayLine;
  FScratchFrames := 0;
  EnsureScratch(UDAW_DEFAULT_BUFFER_FRAMES);
  SetLookaheadMs(FLookaheadMs);
  Reset;
end;

procedure TAdvancedCompressor.Reset;
var
  ch, i: Integer;
begin
  FCore.Reset;
  for ch := 0 to High(FDelayLine) do
  begin
    for i := 0 to High(FDelayLine[ch]) do
      FDelayLine[ch][i] := 0;
    FWritePos[ch] := 0;
  end;
end;

procedure TAdvancedCompressor.SetParams(AMode: TDynamicsMode; AThresholdDb, ARatio,
  AKneeDb, AAttackMs, AReleaseMs, AMakeupDb: Double);
begin
  FCore.SetParams(AMode, AThresholdDb, ARatio, AKneeDb, AAttackMs, AReleaseMs, AMakeupDb);
end;

procedure TAdvancedCompressor.SetLookaheadMs(AMs: Double);
begin
  if AMs < 0 then AMs := 0;
  if AMs > 20.0 then AMs := 20.0;
  FLookaheadMs := AMs;
  FDelaySamples := Round(FLookaheadMs * 0.001 * FSampleRate);
  if FDelaySamples > FDelaySamplesMax - 1 then FDelaySamples := FDelaySamplesMax - 1;
  if FDelaySamples < 0 then FDelaySamples := 0;
end;

procedure TAdvancedCompressor.ProcessBlock(const AIn, AOut: array of PSingle;
  AFrames: Integer);
var
  ch, i, nc, rd: Integer;
begin
  nc := Length(AIn);
  if nc = 0 then Exit;
  if nc > FChannels then nc := FChannels;
  EnsureScratch(AFrames);

  { The detector runs on the un-delayed input (so it can "see the future"
    relative to the delayed audio path); the audio path itself is read out of
    the per-channel ring FLookaheadMs behind the current write position. }
  for ch := 0 to nc - 1 do
  begin
    for i := 0 to AFrames - 1 do
    begin
      FDetectBuf[ch][i] := AIn[ch][i];

      { write the fresh sample into the ring, then read back FDelaySamples behind }
      FDelayLine[ch][FWritePos[ch]] := AIn[ch][i];
      rd := FWritePos[ch] - FDelaySamples;
      while rd < 0 do rd := rd + FDelaySamplesMax;
      FDelayedBuf[ch][i] := FDelayLine[ch][rd];
      FWritePos[ch] := (FWritePos[ch] + 1) mod FDelaySamplesMax;
    end;
  end;

  { Run the core detector/curve/ballistics on the undelayed signal but apply
    its computed gain to the delayed audio: feed the delayed buffer as the
    signal to process and the undelayed buffer as an external sidechain key,
    so the envelope reacts ahead of the audio it is gain-riding. FDelayedPtr /
    FDetectPtr are persistent FChannels-length pointer arrays; in the normal
    case nc = FChannels and they are passed straight through with no
    per-block allocation (the nc < FChannels case is not the real-time hot
    path, so it takes a short-lived Copy instead). }
  if nc = FChannels then
    FCore.ProcessBlock(FDelayedPtr, FDelayedPtr, AFrames, FDetectPtr)
  else
    FCore.ProcessBlock(Copy(FDelayedPtr, 0, nc), Copy(FDelayedPtr, 0, nc), AFrames,
      Copy(FDetectPtr, 0, nc));

  for ch := 0 to nc - 1 do
    for i := 0 to AFrames - 1 do
      AOut[ch][i] := FDelayedBuf[ch][i];
end;

function TAdvancedCompressor.CurrentGainReductionDb: Double;
begin
  Result := FCore.CurrentGainReductionDb;
end;

end.
