unit UDAW.DSP.Resampler;
{$I udaw.inc}
{$POINTERMATH ON}

{ Phase 3 - arbitrary-ratio sample-rate conversion. No third-party code.

  TResampler streams planar Float32 through a chosen kernel:

    rqLinear  - 1st-order; lowest cost / latency, audible HF loss
    rqCubic   - 4-point Hermite; good for pitch / preview
    rqSinc    - windowed-sinc polyphase FIR (Blackman window, configurable
                half-width); the mastering-grade path. On downsampling the
                kernel cutoff tracks the ratio so it doubles as the anti-alias
                filter.

  The converter keeps an internal per-channel "pending input" buffer so it can
  be fed unequal blocks and pulled for as many output frames as are currently
  available. Linear-phase: the group delay is reported by Latency.

  ResamplePlanar is a one-shot convenience wrapper (import / offline render). }

interface

uses
  SysUtils, Math,
  UDAW.Errors, UDAW.Audio.Types,
  UDAW.DSP.Math, UDAW.DSP.Interpolation;

type
  TResampleQuality = (rqLinear, rqCubic, rqSinc);

  TResampler = class
  private
    FChannels: Integer;
    FQuality: TResampleQuality;
    FInRate: Double;
    FOutRate: Double;
    FStep: Double;              // input frames advanced per output frame
    FZeroCross: Integer;        // sinc half-width in zero crossings
    FGuardR: Integer;           // samples needed to the right of the read index
    FTableDensity: Integer;
    FKernel: array of Double;   // one-sided h(x), x in [0..FZeroCross]
    FCutoff: Double;
    FPending: array of array of Single;   // [channel][sample] unconsumed input
    FPos: Double;               // read position within FPending (frames)
    FStarted: Boolean;
    procedure BuildKernel;
    function KernelAt(AX: Double): Double; {$IFDEF FPC}inline;{$ENDIF}
    procedure EnsurePendingShape;
  public
    constructor Create(AChannels: Integer; AQuality: TResampleQuality = rqSinc;
      AZeroCrossings: Integer = 16);
    procedure SetRates(AInRate, AOutRate: Double);
    procedure Reset;

    { Push AInFrames of input (AIn[ch][0..AInFrames-1]) and pull up to
      AMaxOutFrames of output into AOut[ch]. Returns the number of output frames
      actually written. Call repeatedly; unconsumed input is retained. }
    function Process(const AIn: TAudioPlanar; AInFrames: Integer;
      var AOut: TAudioPlanar; AMaxOutFrames: Integer): Integer;

    { Upper bound on the output frames a Process(...AInFrames...) can yield now. }
    function MaxOutputFor(AInFrames: Integer): Integer;
    { Group delay in output frames. }
    function Latency: Double;

    property Channels: Integer read FChannels;
    property Quality: TResampleQuality read FQuality;
    property InRate: Double read FInRate;
    property OutRate: Double read FOutRate;
    property Ratio: Double read FStep;   // = InRate/OutRate
  end;

function ResampleQualityName(AQ: TResampleQuality): string;

{ One-shot: resample every channel of ASrc from ASrcRate to ADstRate. }
function ResamplePlanar(const ASrc: TAudioPlanar; ASrcFrames: Integer;
  ASrcRate, ADstRate: Double; AQuality: TResampleQuality = rqSinc): TAudioPlanar;

implementation

function ResampleQualityName(AQ: TResampleQuality): string;
begin
  case AQ of
    rqLinear: Result := 'linear';
    rqCubic:  Result := 'cubic';
    rqSinc:   Result := 'sinc';
  else
    Result := '?';
  end;
end;

{ ---------------- TResampler ---------------- }

constructor TResampler.Create(AChannels: Integer; AQuality: TResampleQuality;
  AZeroCrossings: Integer);
begin
  inherited Create;
  if AChannels < 1 then AChannels := 1;
  FChannels := AChannels;
  FQuality := AQuality;
  if AZeroCrossings < 2 then AZeroCrossings := 2;
  if AZeroCrossings > 64 then AZeroCrossings := 64;
  FZeroCross := AZeroCrossings;
  FTableDensity := 512;
  FInRate := UDAW_DEFAULT_SAMPLE_RATE;
  FOutRate := UDAW_DEFAULT_SAMPLE_RATE;
  FStep := 1.0;
  FCutoff := 1.0;

  case FQuality of
    rqLinear: FGuardR := 1;
    rqCubic:  FGuardR := 2;
  else
    FGuardR := FZeroCross;
  end;

  EnsurePendingShape;
  BuildKernel;
  Reset;
end;

procedure TResampler.EnsurePendingShape;
var
  ch: Integer;
begin
  if Length(FPending) <> FChannels then
    SetLength(FPending, FChannels);
  for ch := 0 to FChannels - 1 do
    SetLength(FPending[ch], 0);
end;

procedure TResampler.BuildKernel;
var
  i, n: Integer;
  x, w: Double;
begin
  if FQuality <> rqSinc then
  begin
    SetLength(FKernel, 0);
    Exit;
  end;
  n := FZeroCross * FTableDensity;
  SetLength(FKernel, n + 1);
  for i := 0 to n do
  begin
    x := i / FTableDensity;                 // 0 .. FZeroCross
    { Blackman window over [-ZC, ZC] }
    if x >= FZeroCross then
      w := 0.0
    else
      w := 0.42
         + 0.5  * Cos(DSP_PI * x / FZeroCross)
         + 0.08 * Cos(2.0 * DSP_PI * x / FZeroCross);
    FKernel[i] := FCutoff * SincNorm(FCutoff * x) * w;
  end;
end;

function TResampler.KernelAt(AX: Double): Double;
var
  fpos: Double;
  i0: Integer;
  frac: Double;
begin
  AX := Abs(AX);
  if AX >= FZeroCross then Exit(0.0);
  fpos := AX * FTableDensity;
  i0 := Trunc(fpos);
  frac := fpos - i0;
  if i0 >= High(FKernel) then Exit(FKernel[High(FKernel)]);
  Result := FKernel[i0] + (FKernel[i0 + 1] - FKernel[i0]) * frac;
end;

procedure TResampler.SetRates(AInRate, AOutRate: Double);
var
  newCutoff: Double;
begin
  if (AInRate <= 0) or (AOutRate <= 0) then
    RaiseUDAW(errInvalidArgument, DSP_SUBSYS, 'TResampler.SetRates: rates must be > 0');
  FInRate := AInRate;
  FOutRate := AOutRate;
  FStep := AInRate / AOutRate;

  if FStep > 1.0 then
    newCutoff := 1.0 / FStep    // downsampling: lower the cutoff to the new Nyquist
  else
    newCutoff := 1.0;
  if Abs(newCutoff - FCutoff) > 1.0E-9 then
  begin
    FCutoff := newCutoff;
    BuildKernel;
  end;
end;

procedure TResampler.Reset;
var
  ch: Integer;
begin
  for ch := 0 to FChannels - 1 do
    SetLength(FPending[ch], 0);
  FPos := FGuardR;   // linear-phase lead-in delay
  FStarted := False;
end;

function TResampler.Latency: Double;
begin
  { output-frame group delay = lead-in input frames scaled to the output rate }
  Result := FGuardR / FStep;
end;

function TResampler.MaxOutputFor(AInFrames: Integer): Integer;
var
  avail: Integer;
begin
  if FChannels = 0 then Exit(0);
  avail := Length(FPending[0]) + AInFrames;
  { last usable centre index is avail-1-FGuardR }
  Result := Trunc(((avail - 1 - FGuardR) - FPos) / FStep) + 1;
  if Result < 0 then Result := 0;
end;

function TResampler.Process(const AIn: TAudioPlanar; AInFrames: Integer;
  var AOut: TAudioPlanar; AMaxOutFrames: Integer): Integer;
var
  ch, produced, avail, i0, k, kmin, kmax, shift, keep, i: Integer;
  work: array of array of Single;
  pos, frac, acc, wsum, wt: Double;
begin
  { Result is assigned unconditionally at the end (= produced). }
  if (AInFrames < 0) then AInFrames := 0;
  if AMaxOutFrames <= 0 then AMaxOutFrames := 0;

  { assemble work[ch] = pending ++ new input }
  SetLength(work, FChannels);
  for ch := 0 to FChannels - 1 do
  begin
    avail := Length(FPending[ch]);
    SetLength(work[ch], avail + AInFrames);
    if avail > 0 then
      Move(FPending[ch][0], work[ch][0], avail * SizeOf(Single));
    for i := 0 to AInFrames - 1 do
      work[ch][avail + i] := AIn[ch][i];
  end;
  avail := Length(work[0]);

  { make sure the output planar can hold what we might write }
  if Length(AOut) < FChannels then SetLength(AOut, FChannels);
  for ch := 0 to FChannels - 1 do
    if Length(AOut[ch]) < AMaxOutFrames then
      SetLength(AOut[ch], AMaxOutFrames);

  produced := 0;
  pos := FPos;
  while produced < AMaxOutFrames do
  begin
    i0 := Trunc(pos);
    if i0 + FGuardR > avail - 1 then Break;   // not enough look-ahead yet
    frac := pos - i0;

    for ch := 0 to FChannels - 1 do
    begin
      case FQuality of
        rqLinear:
          AOut[ch][produced] := InterpLinear(work[ch][i0], work[ch][i0 + 1], frac);
        rqCubic:
          begin
            if i0 - 1 < 0 then
              AOut[ch][produced] := InterpLinear(work[ch][i0], work[ch][i0 + 1], frac)
            else
              AOut[ch][produced] := InterpHermite4(work[ch][i0 - 1], work[ch][i0],
                work[ch][i0 + 1], work[ch][i0 + 2], frac);
          end;
      else
        begin
          { windowed-sinc: taps at i0+k, k = -(ZC-1) .. ZC, weight h(frac - k) }
          kmin := -(FZeroCross - 1);
          kmax := FZeroCross;
          acc := 0;
          wsum := 0;
          for k := kmin to kmax do
          begin
            i := i0 + k;
            if (i < 0) or (i > avail - 1) then Continue;
            wt := KernelAt(frac - k);
            acc := acc + wt * work[ch][i];
            wsum := wsum + wt;
          end;
          if wsum <> 0 then
            AOut[ch][produced] := acc / wsum
          else
            AOut[ch][produced] := 0;
        end;
      end;
    end;

    Inc(produced);
    pos := pos + FStep;
  end;

  { consume input up to (floor(pos) - FGuardR); retain the rest as pending }
  shift := Trunc(pos) - FGuardR;
  if shift < 0 then shift := 0;
  if shift > avail then shift := avail;
  keep := avail - shift;
  for ch := 0 to FChannels - 1 do
  begin
    SetLength(FPending[ch], keep);
    if keep > 0 then
      Move(work[ch][shift], FPending[ch][0], keep * SizeOf(Single));
  end;
  FPos := pos - shift;
  FStarted := True;

  Result := produced;
end;

{ ---------------- one-shot ---------------- }

function ResamplePlanar(const ASrc: TAudioPlanar; ASrcFrames: Integer;
  ASrcRate, ADstRate: Double; AQuality: TResampleQuality): TAudioPlanar;
var
  rs: TResampler;
  ch, chans, cap, got, total: Integer;
  outBlk: TAudioPlanar;
  tail: TAudioPlanar;
begin
  chans := Length(ASrc);
  SetLength(Result, chans);
  if chans = 0 then Exit;

  rs := TResampler.Create(chans, AQuality);
  try
    rs.SetRates(ASrcRate, ADstRate);
    cap := Trunc(ASrcFrames * (ADstRate / ASrcRate)) + 16;
    SetLength(outBlk, chans);
    for ch := 0 to chans - 1 do
      SetLength(outBlk[ch], cap);

    got := rs.Process(ASrc, ASrcFrames, outBlk, cap);
    total := got;
    for ch := 0 to chans - 1 do
    begin
      SetLength(Result[ch], got);
      if got > 0 then Move(outBlk[ch][0], Result[ch][0], got * SizeOf(Single));
    end;

    { flush: feed silence to drain the linear-phase tail }
    SetLength(tail, chans);
    for ch := 0 to chans - 1 do
      SetLength(tail[ch], rs.FGuardR + 2);
    got := rs.Process(tail, rs.FGuardR + 2, outBlk, cap);
    if got > 0 then
    begin
      for ch := 0 to chans - 1 do
      begin
        SetLength(Result[ch], total + got);
        Move(outBlk[ch][0], Result[ch][total], got * SizeOf(Single));
      end;
    end;
  finally
    rs.Free;
  end;
end;

end.
