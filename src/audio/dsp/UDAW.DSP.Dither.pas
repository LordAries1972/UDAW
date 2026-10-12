unit UDAW.DSP.Dither;
{$I udaw.inc}
{$POINTERMATH ON}

{ TPDF dither with optional first-order noise shaping, applied before
  quantising a float mix down to 16/24-bit for export. }

interface

uses
  SysUtils, Math;

type
  TDitherShape = (dsNone, dsTPDF, dsShaped);

  TDitherer = class
  private
    FBits: Integer;
    FShape: TDitherShape;
    FSeed: Cardinal;
    FErr: array[0..7] of Double;
    function Rand: Double;
  public
    constructor Create(ABits: Integer; AShape: TDitherShape);
    procedure Reset;
    { quantises in place; result stays float in [-1,1] on the integer grid }
    procedure Process(AData: PSingle; AFrames, AChannel: Integer);
  end;

implementation

constructor TDitherer.Create(ABits: Integer; AShape: TDitherShape);
begin
  inherited Create;
  FBits := EnsureRange(ABits, 8, 24);
  FShape := AShape;
  Reset;
end;

procedure TDitherer.Reset;
begin
  FSeed := 22222;
  FillChar(FErr, SizeOf(FErr), 0);
end;

function TDitherer.Rand: Double;
begin
  FSeed := Cardinal((UInt64(FSeed) * 1664525 + 1013904223) and $FFFFFFFF);   // wraps by design (no overflow trap)
  Result := (FSeed shr 8) / 16777216.0;
end;

procedure TDitherer.Process(AData: PSingle; AFrames, AChannel: Integer);
var
  i, ch: Integer;
  scale, v, q, d: Double;
begin
  ch := AChannel and 7;
  scale := Power(2.0, FBits - 1);
  for i := 0 to AFrames - 1 do
  begin
    v := AData[i] * scale;
    if FShape = dsNone then d := 0 else d := Rand - Rand; { triangular, +-1 LSB }
    if FShape = dsShaped then v := v - FErr[ch];
    q := Round(v + d);
    if q > scale - 1 then q := scale - 1 else if q < -scale then q := -scale;
    if FShape = dsShaped then FErr[ch] := q - v;
    AData[i] := Single(q / scale);
  end;
end;

end.
