unit UDAW.DSP.PitchShift;
{$I udaw.inc}
{$POINTERMATH ON}

{ Phase 19 - Advanced DSP (plan section, docs/UDAW-Original-Plan.txt lines
  3706-3719): offline pitch-shifting without changing duration.

  TPitchShifter is the classic combination of the Phase 19 phase-vocoder
  time-stretch (UDAW.DSP.TimeStretch) followed by resampling back to the
  original length (UDAW.DSP.Resampler): stretch the input by ratio =
  2^(semitones/12) - which changes its duration but not its pitch - then
  resample that stretched buffer by 1/ratio, which changes its duration back
  to (approximately) the original while raising every frequency by `ratio`,
  i.e. by ASemitones. This is an OFFLINE utility, not real-time-safe. }

interface

uses
  SysUtils, Math,
  UDAW.Audio.Types,
  UDAW.DSP.Math, UDAW.DSP.TimeStretch, UDAW.DSP.Resampler;

type
  TPitchShifter = class
  private
    FStretch: TPhaseVocoderStretch;
  public
    constructor Create(AFFTSize: Integer = 2048);
    destructor Destroy; override;

    procedure Process(const AIn: array of Single; ASemitones: Double;
      ASampleRate: Integer; out AOut: TArray<Single>);

    function EstimateOutputLength(AInputLength: Integer): Integer;
  end;

implementation

constructor TPitchShifter.Create(AFFTSize: Integer);
begin
  inherited Create;
  FStretch := TPhaseVocoderStretch.Create(AFFTSize);
end;

destructor TPitchShifter.Destroy;
begin
  FStretch.Free;
  inherited Destroy;
end;

function TPitchShifter.EstimateOutputLength(AInputLength: Integer): Integer;
begin
  Result := AInputLength;
end;

procedure TPitchShifter.Process(const AIn: array of Single; ASemitones: Double;
  ASampleRate: Integer; out AOut: TArray<Single>);
var
  ratio: Double;
  stretched: TArray<Single>;
  srcPlanar, dstPlanar: TAudioPlanar;
  i, inLen, stretchedLen: Integer;
begin
  inLen := Length(AIn);
  if inLen = 0 then
  begin
    SetLength(AOut, 0);
    Exit;
  end;
  if ASampleRate <= 0 then ASampleRate := UDAW_DEFAULT_SAMPLE_RATE;

  ratio := Power(2.0, ASemitones / 12.0);

  { 1. time-stretch by `ratio` (longer for a rise, shorter for a drop) - this
    changes duration only, pitch is preserved by the phase vocoder. }
  FStretch.Process(AIn, ratio, stretched);
  stretchedLen := Length(stretched);
  if stretchedLen = 0 then
  begin
    SetLength(AOut, 0);
    Exit;
  end;

  { 2. resample the stretched buffer by 1/ratio so its duration returns to
    (approximately) the original: every frequency in it - which the phase
    vocoder left untouched - is scaled by `ratio` in the process, i.e. by
    ASemitones. Modelled as a sample-rate conversion from `ratio * Fs` down
    to `Fs` (equivalently: from `Fs` up to `Fs / ratio` and read back at
    `Fs`), using the Phase 3 resampler's one-shot planar helper. }
  SetLength(srcPlanar, 1);
  srcPlanar[0] := TAudioSampleArray(stretched);
  dstPlanar := ResamplePlanar(srcPlanar, stretchedLen,
    ASampleRate * ratio, ASampleRate, rqSinc);

  if Length(dstPlanar) = 0 then
  begin
    SetLength(AOut, 0);
    Exit;
  end;

  { Trim / pad to the original input length so duration is preserved exactly. }
  SetLength(AOut, inLen);
  for i := 0 to inLen - 1 do
  begin
    if i < Length(dstPlanar[0]) then
      AOut[i] := dstPlanar[0][i]
    else
      AOut[i] := 0;
  end;
end;

end.
