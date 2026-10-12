unit UDAW.DSP.Distortion;
{$I udaw.inc}
{$POINTERMATH ON}

{ Phase 10 - non-linear processors (plan section 11): saturation, hard-clip
  distortion, wave-folder and bit-crusher (bit-depth + sample-rate reduction).

  drive is a linear pre-gain into the shaper; trim is a linear post-gain; mix
  blends the shaped signal with the dry one (parallel / New-York style). A
  gentle DC-safe design: tanh and the folder are odd functions, hard-clip is
  symmetric, the crusher's quantiser is mid-rise. Per-channel, no allocation
  after Configure.

  Quality: the smooth shapers (saturation, fold-back, tube, soft clip) run 2x
  oversampled through 4th-order Butterworth anti-alias filters so the harmonics
  they generate do not fold back as inharmonic aliasing. Tube is an
  asymmetric (even-harmonic) curve with a DC blocker; soft clip is a smooth
  cubic limiter. Hard clip and the bit-crusher stay un-oversampled on purpose
  (hard clip must pin to the ceiling; the crusher's aliasing is its sound). }

interface

uses
  SysUtils, Math,
  UDAW.Audio.Types, UDAW.DSP.Math, UDAW.DSP.Filters;

type
  TDistMode = (distSaturation, distHardClip, distFoldback, distBitCrush,
    distTube, distSoftClip);

  TDistortionProcessor = class
  private
    FSampleRate: Integer;
    FChannels: Integer;
    FMode: TDistMode;
    FDrive: Double;          // linear pre-gain (>= 1 typical)
    FTrim: Double;           // linear post-gain
    FMix: Double;            // 0..1 wet
    FBits: Double;           // crusher quantiser bits (1..24)
    FDownsample: Integer;    // crusher sample-and-hold factor (1..64)
    FHold: array of Double;  // [channel] last held sample
    FHoldCount: Integer;
    FUp: array of array[0..1] of TBiquad;   // [channel] 2x anti-image filters
    FDn: array of array[0..1] of TBiquad;   // [channel] 2x anti-alias filters
    FDcX, FDcY: array of Double;            // [channel] DC blocker state
    FDcR: Double;
    function Shape(AX: Double): Double;
    function IsOversampled: Boolean;
    function ShapeOversampled(ACh: Integer; AX: Double): Double;
  public
    constructor Create;
    procedure Configure(ASampleRate, AChannels: Integer);
    procedure Reset;
    procedure SetParams(AMode: TDistMode; ADrive, ATrimDb, AMix, ABits: Double;
      ADownsample: Integer);
    procedure ProcessBlock(const AIn, AOut: array of PSingle; AFrames: Integer);
    property Mode: TDistMode read FMode;
  end;

function DistModeId(AMode: TDistMode): string;
function DistModeFromId(const AId: string; out AMode: TDistMode): Boolean;

implementation

function DistModeId(AMode: TDistMode): string;
begin
  case AMode of
    distHardClip: Result := 'hardclip';
    distFoldback: Result := 'foldback';
    distBitCrush: Result := 'bitcrush';
    distTube:     Result := 'tube';
    distSoftClip: Result := 'softclip';
  else
    Result := 'saturation';
  end;
end;

function DistModeFromId(const AId: string; out AMode: TDistMode): Boolean;
var
  m: TDistMode;
begin
  for m := Low(TDistMode) to High(TDistMode) do
    if SameText(AId, DistModeId(m)) then
    begin
      AMode := m;
      Exit(True);
    end;
  Result := False;
end;

{ ================= TDistortionProcessor ================= }

constructor TDistortionProcessor.Create;
begin
  inherited Create;
  FSampleRate := UDAW_DEFAULT_SAMPLE_RATE;
  FChannels := 2;
  FMode := distSaturation;
  FDrive := 2.0;
  FTrim := 1.0;
  FMix := 1.0;
  FBits := 8.0;
  FDownsample := 1;
end;

procedure TDistortionProcessor.Configure(ASampleRate, AChannels: Integer);
var
  ch, k: Integer;
begin
  if ASampleRate > 0 then FSampleRate := ASampleRate;
  if AChannels > 0 then FChannels := AChannels;
  SetLength(FHold, FChannels);
  SetLength(FUp, FChannels);
  SetLength(FDn, FChannels);
  SetLength(FDcX, FChannels);
  SetLength(FDcY, FChannels);
  FDcR := 1.0 - 2.0 * DSP_PI * 10.0 / FSampleRate;     // ~10 Hz high-pass
  for ch := 0 to FChannels - 1 do
    for k := 0 to 1 do
    begin
      FUp[ch][k].Init(FSampleRate * 2.0);
      FDn[ch][k].Init(FSampleRate * 2.0);
      { 4th-order Butterworth = two sections, Q 0.5412 and 1.3066 }
      FUp[ch][k].SetParams(bqLowpass, FSampleRate * 0.45, IfThen(k = 0, 0.5412, 1.3066));
      FDn[ch][k].SetParams(bqLowpass, FSampleRate * 0.45, IfThen(k = 0, 0.5412, 1.3066));
    end;
  Reset;
end;

procedure TDistortionProcessor.Reset;
var
  ch, k: Integer;
begin
  for ch := 0 to High(FHold) do FHold[ch] := 0;
  for ch := 0 to High(FUp) do
    for k := 0 to 1 do
    begin
      FUp[ch][k].Reset;
      FDn[ch][k].Reset;
    end;
  for ch := 0 to High(FDcX) do
  begin
    FDcX[ch] := 0;
    FDcY[ch] := 0;
  end;
  FHoldCount := 0;
end;

procedure TDistortionProcessor.SetParams(AMode: TDistMode; ADrive, ATrimDb, AMix,
  ABits: Double; ADownsample: Integer);
begin
  FMode := AMode;
  FDrive := Max(0.01, ADrive);
  FTrim := DbToLinear(ATrimDb);
  FMix := Min(1.0, Max(0.0, AMix));
  FBits := Min(24.0, Max(1.0, ABits));
  FDownsample := Min(64, Max(1, ADownsample));
end;

function TDistortionProcessor.Shape(AX: Double): Double;
var
  d, levels, folded: Double;
begin
  d := AX * FDrive;
  case FMode of
    distSaturation:
      Result := Tanh(d);
    distHardClip:
      begin
        if d > 1.0 then Result := 1.0
        else if d < -1.0 then Result := -1.0
        else Result := d;
      end;
    distTube:
      begin
        { asymmetric: full-range positive half, softer-ceiling negative half }
        if d >= 0 then Result := Tanh(d)
        else Result := 0.85 * Tanh(d / 0.85);
      end;
    distSoftClip:
      begin
        { smooth cubic limiter, slope 0 at the ceiling }
        if d > 1.0 then d := 1.0 else if d < -1.0 then d := -1.0;
        Result := 1.5 * (d - d * d * d / 3.0);
      end;
    distFoldback:
      begin
        folded := d;
        while (folded > 1.0) or (folded < -1.0) do
        begin
          if folded > 1.0 then folded := 2.0 - folded
          else if folded < -1.0 then folded := -2.0 - folded;
        end;
        Result := folded;
      end;
    distBitCrush:
      begin
        { quantise to 2^bits mid-rise levels }
        levels := Power(2.0, FBits);
        if d > 1.0 then d := 1.0 else if d < -1.0 then d := -1.0;
        Result := (Floor(d * (levels * 0.5)) + 0.5) / (levels * 0.5);
      end;
  else
    Result := d;
  end;
end;

function TDistortionProcessor.IsOversampled: Boolean;
begin
  Result := FMode in [distSaturation, distFoldback, distTube, distSoftClip];
end;

{ 2x oversampled shaping: zero-stuff + anti-image, shape both samples,
  anti-alias, keep the second (decimate). }
function TDistortionProcessor.ShapeOversampled(ACh: Integer; AX: Double): Double;
var
  a, b: Double;
begin
  a := FUp[ACh][1].ProcessSample(FUp[ACh][0].ProcessSample(Single(2.0 * AX)));
  b := FUp[ACh][1].ProcessSample(FUp[ACh][0].ProcessSample(0.0));
  FDn[ACh][1].ProcessSample(FDn[ACh][0].ProcessSample(Single(Shape(a))));
  Result := FDn[ACh][1].ProcessSample(FDn[ACh][0].ProcessSample(Single(Shape(b))));
  if Result > 1.0 then Result := 1.0 else if Result < -1.0 then Result := -1.0;
end;

procedure TDistortionProcessor.ProcessBlock(const AIn, AOut: array of PSingle;
  AFrames: Integer);
var
  i, ch, nc: Integer;
  wetV, dry, wet, s: Double;
  refresh: Boolean;
begin
  nc := Length(AIn);
  if nc = 0 then Exit;
  dry := 1.0 - FMix;
  wet := FMix;

  for i := 0 to AFrames - 1 do
  begin
    refresh := True;
    if (FMode = distBitCrush) and (FDownsample > 1) then
    begin
      refresh := (FHoldCount = 0);
      Inc(FHoldCount);
      if FHoldCount >= FDownsample then FHoldCount := 0;
    end;

    for ch := 0 to nc - 1 do
    begin
      if refresh then
      begin
        if IsOversampled then wetV := ShapeOversampled(ch, AIn[ch][i])
        else wetV := Shape(AIn[ch][i]);
        if FMode = distTube then
        begin
          { remove the DC the asymmetric curve introduces }
          s := wetV - FDcX[ch] + FDcR * FDcY[ch];
          FDcX[ch] := wetV;
          FDcY[ch] := FlushDenorm(Single(s));
          wetV := s;
        end;
        wetV := wetV * FTrim;
        FHold[ch] := wetV;
      end
      else
        wetV := FHold[ch];
      s := dry * AIn[ch][i] + wet * wetV;
      AOut[ch][i] := Single(FlushDenorm(Single(s)));
    end;
  end;
end;

end.
