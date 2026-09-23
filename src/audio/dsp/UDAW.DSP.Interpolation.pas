unit UDAW.DSP.Interpolation;
{$I udaw.inc}
{$POINTERMATH ON}

{ Phase 3 - fractional-position sample interpolation. Used by the resampler, by
  sample playback / pitch, by fractional delay lines and by true-peak
  oversampling.

    ikDrop     - nearest sample (zero-order hold); reference / debug only
    ikLinear   - 1st order; cheap, -6 dB/oct HF loss
    ikHermite  - 4-point 3rd-order Hermite (Catmull-Rom); the general default
    ikLagrange3- 4-point 3rd-order Lagrange; flatter passband than Hermite

  ReadFractional treats positions outside [0, ALength-1] by clamping to the end
  samples, so callers never index out of range. }

interface

uses
  SysUtils,
  UDAW.Audio.Types;

type
  TInterpKind = (ikDrop, ikLinear, ikHermite, ikLagrange3);

function InterpKindName(AKind: TInterpKind): string;

{ Core kernels. AFrac in [0,1). The x* are the four samples straddling the read
  point: xm1 = index-1, x0 = index, x1 = index+1, x2 = index+2. }
function InterpLinear(AX0, AX1: Single; AFrac: Single): Single; {$IFDEF FPC}inline;{$ENDIF}
function InterpHermite4(AXm1, AX0, AX1, AX2: Single; AFrac: Single): Single; {$IFDEF FPC}inline;{$ENDIF}
function InterpLagrange3(AXm1, AX0, AX1, AX2: Single; AFrac: Single): Single; {$IFDEF FPC}inline;{$ENDIF}

{ Read ABuf at the (possibly fractional) position APos using AKind, clamping at
  the buffer edges. ABuf points at ALength contiguous Singles. }
function ReadFractional(ABuf: PSingle; ALength: Integer; APos: Double;
  AKind: TInterpKind): Single;

implementation

function InterpKindName(AKind: TInterpKind): string;
begin
  case AKind of
    ikDrop:      Result := 'drop';
    ikLinear:    Result := 'linear';
    ikHermite:   Result := 'hermite4';
    ikLagrange3: Result := 'lagrange3';
  else
    Result := '?';
  end;
end;

function InterpLinear(AX0, AX1, AFrac: Single): Single;
begin
  Result := AX0 + (AX1 - AX0) * AFrac;
end;

function InterpHermite4(AXm1, AX0, AX1, AX2, AFrac: Single): Single;
var
  c0, c1, c2, c3: Single;
begin
  { Catmull-Rom form (Laurent de Soras' well-known arrangement). }
  c0 := AX0;
  c1 := 0.5 * (AX1 - AXm1);
  c2 := AXm1 - 2.5 * AX0 + 2.0 * AX1 - 0.5 * AX2;
  c3 := 0.5 * (AX2 - AXm1) + 1.5 * (AX0 - AX1);
  Result := ((c3 * AFrac + c2) * AFrac + c1) * AFrac + c0;
end;

function InterpLagrange3(AXm1, AX0, AX1, AX2, AFrac: Single): Single;
var
  d, dm1, d1, d2: Double;
begin
  { 3rd-order Lagrange through the four points at x = -1,0,1,2. }
  d := AFrac;
  dm1 := d + 1.0;
  d1  := d - 1.0;
  d2  := d - 2.0;
  Result :=
      AXm1 * (-(d * d1 * d2) / 6.0)
    + AX0  * ( (dm1 * d1 * d2) / 2.0)
    + AX1  * (-(dm1 * d * d2) / 2.0)
    + AX2  * ( (dm1 * d * d1) / 6.0);
end;

function ReadFractional(ABuf: PSingle; ALength: Integer; APos: Double;
  AKind: TInterpKind): Single;
var
  i0: Integer;
  frac: Single;

  function S(AIdx: Integer): Single; {$IFDEF FPC}inline;{$ENDIF}
  begin
    if AIdx < 0 then AIdx := 0
    else if AIdx > ALength - 1 then AIdx := ALength - 1;
    Result := ABuf[AIdx];
  end;

begin
  if ALength <= 0 then Exit(0);
  if ALength = 1 then Exit(ABuf[0]);
  if APos <= 0 then Exit(ABuf[0]);
  if APos >= ALength - 1 then Exit(ABuf[ALength - 1]);

  i0 := Trunc(APos);
  frac := APos - i0;

  case AKind of
    ikDrop:
      if frac < 0.5 then Result := S(i0) else Result := S(i0 + 1);
    ikLinear:
      Result := InterpLinear(S(i0), S(i0 + 1), frac);
    ikLagrange3:
      Result := InterpLagrange3(S(i0 - 1), S(i0), S(i0 + 1), S(i0 + 2), frac);
  else
    Result := InterpHermite4(S(i0 - 1), S(i0), S(i0 + 1), S(i0 + 2), frac);
  end;
end;

end.
