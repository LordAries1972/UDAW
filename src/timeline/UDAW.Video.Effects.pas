unit UDAW.Video.Effects;
{$I udaw.inc}
{$POINTERMATH ON}
{$OVERFLOWCHECKS OFF}
{$RANGECHECKS OFF}

{ Per-picture video effects and transitions for the Timeline's video channels.

  Every picture is 32-bit BGRX, top row first, W x H pixels (the same layout the
  video export composes).  Two kinds of effect exist:

    filter      one picture in, one out (fade, blur, colour grades, glitch ...)
    transition  the outgoing picture and the incoming picture in, one out
                (dissolve, wipes, slides, zoom, iris, clock ...)

  Both are driven by Progress, 0..1 across the effect region, so the same call
  serves the export, the on-screen preview and the tests.  No third-party
  library: plain pixel arithmetic. }

interface

type
  TVideoFxClass = (vfFilter, vfTransition);

  TVideoFxInfo = record
    Id: string;             // stored in the project
    Name: string;           // shown in the menus
    Group: string;          // menu sub-group
    Cls: TVideoFxClass;
  end;

function VideoFxCount: Integer;
function VideoFxInfoAt(AIndex: Integer): TVideoFxInfo;
function VideoFxFind(const AId: string; out AInfo: TVideoFxInfo): Boolean;
function VideoFxIsTransition(const AId: string): Boolean;
{ Value of AKey in a "k=v;k=v" settings string. }
function VideoFxParam(const AParams, AKey, ADefault: string): string;

{ Filter: ASrc -> ADst (distinct buffers, W*H*4 bytes each). ASeed varies the
  random effects (grain, glitch, shake) from one picture to the next. }
procedure VideoFxRenderFilter(const AId, AParams: string; AProgress: Double;
  ASrc, ADst: PByte; W, H, ASeed: Integer);

{ Transition: AFrom (outgoing) and ATo (incoming) -> ADst. }
procedure VideoFxRenderTransition(const AId, AParams: string; AProgress: Double;
  AFrom, ATo, ADst: PByte; W, H, ASeed: Integer);

implementation

uses
  SysUtils, Math;

const
  FX_COUNT = 52;

  { id, name, group, class }
  FX_TABLE: array[0..FX_COUNT - 1] of array[0..3] of string = (
    ('crossfade', 'Cross Dissolve', 'Dissolve', 'T'),
    ('dipblack', 'Dip to Black', 'Dissolve', 'T'),
    ('dipwhite', 'Dip to White', 'Dissolve', 'T'),
    ('blurdissolve', 'Blur Dissolve', 'Dissolve', 'T'),
    ('pixeldissolve', 'Pixelate Dissolve', 'Dissolve', 'T'),
    ('wipeleft', 'Wipe Left', 'Wipe', 'T'),
    ('wiperight', 'Wipe Right', 'Wipe', 'T'),
    ('wipeup', 'Wipe Up', 'Wipe', 'T'),
    ('wipedown', 'Wipe Down', 'Wipe', 'T'),
    ('clock', 'Clock Wipe', 'Wipe', 'T'),
    ('barndoor', 'Barn Doors', 'Wipe', 'T'),
    ('circleopen', 'Iris Open', 'Wipe', 'T'),
    ('circleclose', 'Iris Close', 'Wipe', 'T'),
    ('slideleft', 'Push Left', 'Slide and Zoom', 'T'),
    ('slideright', 'Push Right', 'Slide and Zoom', 'T'),
    ('slideup', 'Push Up', 'Slide and Zoom', 'T'),
    ('slidedown', 'Push Down', 'Slide and Zoom', 'T'),
    ('zoomin', 'Zoom In', 'Slide and Zoom', 'T'),
    ('zoomout', 'Zoom Out', 'Slide and Zoom', 'T'),
    ('glitchtrans', 'Glitch Transition', 'Slide and Zoom', 'T'),
    ('fadein', 'Fade In', 'Fade', 'F'),
    ('fadeout', 'Fade Out', 'Fade', 'F'),
    ('flash', 'Flash', 'Fade', 'F'),
    ('blur', 'Blur', 'Blur and Sharpen', 'F'),
    ('sharpen', 'Sharpen', 'Blur and Sharpen', 'F'),
    ('pixelate', 'Pixelate', 'Blur and Sharpen', 'F'),
    ('bw', 'Black and White', 'Colour', 'F'),
    ('sepia', 'Sepia', 'Colour', 'F'),
    ('invert', 'Invert', 'Colour', 'F'),
    ('duotone', 'Duotone', 'Colour', 'F'),
    ('tint', 'Colour Tint', 'Colour', 'F'),
    ('warm', 'Warm', 'Colour', 'F'),
    ('cool', 'Cool', 'Colour', 'F'),
    ('brighten', 'Brighten', 'Colour', 'F'),
    ('darken', 'Darken', 'Colour', 'F'),
    ('contrast', 'Contrast', 'Colour', 'F'),
    ('vivid', 'Vivid', 'Colour', 'F'),
    ('desaturate', 'Desaturate', 'Colour', 'F'),
    ('posterize', 'Posterize', 'Colour', 'F'),
    ('vignette', 'Vignette', 'Style', 'F'),
    ('grain', 'Film Grain', 'Style', 'F'),
    ('scanlines', 'VHS Scanlines', 'Style', 'F'),
    ('sketch', 'Sketch', 'Style', 'F'),
    ('emboss', 'Emboss', 'Style', 'F'),
    ('glitch', 'Glitch', 'Distort', 'F'),
    ('rgbsplit', 'RGB Split', 'Distort', 'F'),
    ('mirror', 'Mirror', 'Distort', 'F'),
    ('flipv', 'Flip Vertical', 'Distort', 'F'),
    ('shake', 'Shake', 'Motion', 'F'),
    ('slowzoom', 'Slow Zoom In', 'Motion', 'F'),
    ('spin', 'Spin', 'Motion', 'F'),
    ('pulse', 'Zoom Pulse', 'Motion', 'F'));

var
  FInv: TFormatSettings;

function VideoFxCount: Integer;
begin
  Result := FX_COUNT;
end;

function VideoFxInfoAt(AIndex: Integer): TVideoFxInfo;
begin
  Result.Id := FX_TABLE[AIndex][0];
  Result.Name := FX_TABLE[AIndex][1];
  Result.Group := FX_TABLE[AIndex][2];
  if FX_TABLE[AIndex][3] = 'T' then Result.Cls := vfTransition
  else Result.Cls := vfFilter;
end;

function VideoFxFind(const AId: string; out AInfo: TVideoFxInfo): Boolean;
var
  i: Integer;
begin
  for i := 0 to FX_COUNT - 1 do
    if SameText(FX_TABLE[i][0], AId) then
    begin
      AInfo := VideoFxInfoAt(i);
      Exit(True);
    end;
  Result := False;
end;

function VideoFxIsTransition(const AId: string): Boolean;
var
  info: TVideoFxInfo;
begin
  Result := VideoFxFind(AId, info) and (info.Cls = vfTransition);
end;

function VideoFxParam(const AParams, AKey, ADefault: string): string;
var
  part: string;
  p: Integer;
begin
  Result := ADefault;
  for part in AParams.Split([';']) do
  begin
    p := Pos('=', part);
    if (p > 0) and SameText(Trim(Copy(part, 1, p - 1)), AKey) then
      Exit(Trim(Copy(part, p + 1, MaxInt)));
  end;
end;

function ParamF(const AParams, AKey: string; ADefault: Double): Double;
begin
  Result := StrToFloatDef(VideoFxParam(AParams, AKey, ''), ADefault, FInv);
end;

{ ============================== pixel helpers ============================= }

function C8(V: Integer): Byte; inline;
begin
  if V < 0 then Result := 0
  else if V > 255 then Result := 255
  else Result := Byte(V);
end;

function Luma(P: PByte): Integer; inline;
begin
  { P is BGR: 0.114 B + 0.587 G + 0.299 R, in 1/256 units }
  Result := (P[0] * 29 + P[1] * 150 + P[2] * 77) shr 8;
end;

function Rnd(var S: Cardinal): Cardinal; inline;
begin
  S := S xor (S shl 13);
  S := S xor (S shr 17);
  S := S xor (S shl 5);
  Result := S;
end;

function Smooth(A, B, X: Double): Double;
begin
  if B = A then Exit(0);
  Result := (X - A) / (B - A);
  if Result < 0 then Result := 0
  else if Result > 1 then Result := 1;
  Result := Result * Result * (3 - 2 * Result);
end;

function Clamp01(X: Double): Double; inline;
begin
  if X < 0 then Result := 0
  else if X > 1 then Result := 1
  else Result := X;
end;

{ dst := a*(256-w) + b*w, w in 0..256 }
procedure Blend(A, B, D: PByte; W256: Integer); inline;
begin
  D[0] := (A[0] * (256 - W256) + B[0] * W256) shr 8;
  D[1] := (A[1] * (256 - W256) + B[1] * W256) shr 8;
  D[2] := (A[2] * (256 - W256) + B[2] * W256) shr 8;
  D[3] := 0;
end;

procedure CopyPic(ASrc, ADst: PByte; W, H: Integer);
begin
  Move(ASrc^, ADst^, Int64(W) * H * 4);
end;

{ Box blur, radius R, separable running sums; edges clamp. }
procedure BoxBlur(ASrc, ADst: PByte; W, H, R: Integer);
var
  tmp: TBytes;
  x, y, c, k, n, sum, x0, x1: Integer;
  s, d: PByte;
begin
  if R < 1 then
  begin
    CopyPic(ASrc, ADst, W, H);
    Exit;
  end;
  SetLength(tmp, W * H * 4);
  n := 2 * R + 1;
  for y := 0 to H - 1 do
  begin
    s := ASrc + Int64(y) * W * 4;
    d := @tmp[y * W * 4];
    for c := 0 to 2 do
    begin
      sum := 0;
      for k := -R to R do
        sum := sum + s[Min(W - 1, Max(0, k)) * 4 + c];
      for x := 0 to W - 1 do
      begin
        d[x * 4 + c] := sum div n;
        x0 := Max(0, x - R);
        x1 := Min(W - 1, x + R + 1);
        sum := sum - s[x0 * 4 + c] + s[x1 * 4 + c];
      end;
    end;
  end;
  for x := 0 to W - 1 do
    for c := 0 to 2 do
    begin
      sum := 0;
      for k := -R to R do
        sum := sum + tmp[Min(H - 1, Max(0, k)) * W * 4 + x * 4 + c];
      for y := 0 to H - 1 do
      begin
        ADst[(Int64(y) * W + x) * 4 + c] := sum div n;
        sum := sum - tmp[Max(0, y - R) * W * 4 + x * 4 + c] +
          tmp[Min(H - 1, y + R + 1) * W * 4 + x * 4 + c];
      end;
    end;
  for y := 0 to H - 1 do
    for x := 0 to W - 1 do
      ADst[(Int64(y) * W + x) * 4 + 3] := 0;
end;

{ Nearest-neighbour sample with clamped coordinates. }
function PixAt(ASrc: PByte; W, H, X, Y: Integer): PByte; inline;
begin
  if X < 0 then X := 0 else if X >= W then X := W - 1;
  if Y < 0 then Y := 0 else if Y >= H then Y := H - 1;
  Result := ASrc + (Int64(Y) * W + X) * 4;
end;

{ Mosaic: every BS x BS block takes its centre pixel. }
procedure Mosaic(ASrc, ADst: PByte; W, H, BS: Integer);
var
  x, y: Integer;
  s, d: PByte;
begin
  if BS < 2 then
  begin
    CopyPic(ASrc, ADst, W, H);
    Exit;
  end;
  for y := 0 to H - 1 do
    for x := 0 to W - 1 do
    begin
      s := PixAt(ASrc, W, H, (x div BS) * BS + BS div 2, (y div BS) * BS + BS div 2);
      d := ADst + (Int64(y) * W + x) * 4;
      PCardinal(d)^ := PCardinal(s)^;
    end;
end;

{ Scales ASrc about the centre by AScale (>1 = zoom in) and rotates by ARad. }
procedure ZoomRotate(ASrc, ADst: PByte; W, H: Integer; AScale, ARad: Double);
var
  x, y, sx, sy: Integer;
  cx, cy, dx, dy, ca, sa: Double;
  d: PByte;
begin
  if AScale < 0.01 then AScale := 0.01;
  cx := (W - 1) / 2;
  cy := (H - 1) / 2;
  ca := Cos(ARad);
  sa := Sin(ARad);
  for y := 0 to H - 1 do
    for x := 0 to W - 1 do
    begin
      dx := (x - cx) / AScale;
      dy := (y - cy) / AScale;
      sx := Round(cx + dx * ca + dy * sa);
      sy := Round(cy - dx * sa + dy * ca);
      d := ADst + (Int64(y) * W + x) * 4;
      if (sx < 0) or (sx >= W) or (sy < 0) or (sy >= H) then
        PCardinal(d)^ := 0
      else
        PCardinal(d)^ := PCardinal(ASrc + (Int64(sy) * W + sx) * 4)^;
    end;
end;

{ ================================ filters ================================= }

procedure PerPixelFilter(const AId, AParams: string; AProgress: Double;
  ASrc, ADst: PByte; W, H, ASeed: Integer);
var
  x, y, v, l, i, n, r, g, b: Integer;
  amt, f, nx, ny, d: Double;
  s, o: PByte;
  seed: Cardinal;
  tr, tg, tb: Integer;
  levels: Integer;
  col: Cardinal;
begin
  n := W * H;
  amt := ParamF(AParams, 'amt', -1);
  seed := Cardinal(ASeed) * 2654435761 + 12345;
  if seed = 0 then seed := 1;

  if AId = 'fadein' then f := Clamp01(AProgress)
  else if AId = 'fadeout' then f := 1 - Clamp01(AProgress)
  else f := 1;
  if (AId = 'fadein') or (AId = 'fadeout') then
  begin
    v := Round(f * 256);
    for i := 0 to n - 1 do
    begin
      s := ASrc + i * 4; o := ADst + i * 4;
      o[0] := (s[0] * v) shr 8; o[1] := (s[1] * v) shr 8; o[2] := (s[2] * v) shr 8; o[3] := 0;
    end;
    Exit;
  end;

  if AId = 'flash' then
  begin
    if amt < 0 then amt := 0.9;
    v := Round(amt * (1 - Abs(2 * Clamp01(AProgress) - 1)) * 256);
    for i := 0 to n - 1 do
    begin
      s := ASrc + i * 4; o := ADst + i * 4;
      o[0] := s[0] + (((255 - s[0]) * v) shr 8);
      o[1] := s[1] + (((255 - s[1]) * v) shr 8);
      o[2] := s[2] + (((255 - s[2]) * v) shr 8);
      o[3] := 0;
    end;
    Exit;
  end;

  if AId = 'bw' then
  begin
    for i := 0 to n - 1 do
    begin
      s := ASrc + i * 4; o := ADst + i * 4;
      l := Luma(s);
      o[0] := l; o[1] := l; o[2] := l; o[3] := 0;
    end;
    Exit;
  end;

  if AId = 'sepia' then
  begin
    for i := 0 to n - 1 do
    begin
      s := ASrc + i * 4; o := ADst + i * 4;
      r := s[2]; g := s[1]; b := s[0];
      o[2] := C8((r * 101 + g * 197 + b * 48) shr 8);
      o[1] := C8((r * 89 + g * 175 + b * 43) shr 8);
      o[0] := C8((r * 70 + g * 137 + b * 33) shr 8);
      o[3] := 0;
    end;
    Exit;
  end;

  if AId = 'invert' then
  begin
    for i := 0 to n - 1 do
    begin
      s := ASrc + i * 4; o := ADst + i * 4;
      o[0] := 255 - s[0]; o[1] := 255 - s[1]; o[2] := 255 - s[2]; o[3] := 0;
    end;
    Exit;
  end;

  if AId = 'duotone' then
  begin
    { shadows deep blue, highlights warm orange }
    for i := 0 to n - 1 do
    begin
      s := ASrc + i * 4; o := ADst + i * 4;
      l := Luma(s);
      o[2] := (10 * (255 - l) + 255 * l) div 255;
      o[1] := (10 * (255 - l) + 170 * l) div 255;
      o[0] := (60 * (255 - l) + 90 * l) div 255;
      o[3] := 0;
    end;
    Exit;
  end;

  if AId = 'tint' then
  begin
    if amt < 0 then amt := 0.35;
    col := Cardinal(StrToIntDef('$' + VideoFxParam(AParams, 'color', 'FF8000'), $FF8000));
    tr := (col shr 16) and $FF; tg := (col shr 8) and $FF; tb := col and $FF;
    v := Round(Clamp01(amt) * 256);
    for i := 0 to n - 1 do
    begin
      s := ASrc + i * 4; o := ADst + i * 4;
      o[0] := (s[0] * (256 - v) + tb * v) shr 8;
      o[1] := (s[1] * (256 - v) + tg * v) shr 8;
      o[2] := (s[2] * (256 - v) + tr * v) shr 8;
      o[3] := 0;
    end;
    Exit;
  end;

  if (AId = 'warm') or (AId = 'cool') then
  begin
    if amt < 0 then amt := 0.5;
    v := Round(amt * 40);
    if AId = 'cool' then v := -v;
    for i := 0 to n - 1 do
    begin
      s := ASrc + i * 4; o := ADst + i * 4;
      o[2] := C8(s[2] + v); o[1] := s[1]; o[0] := C8(s[0] - v); o[3] := 0;
    end;
    Exit;
  end;

  if (AId = 'brighten') or (AId = 'darken') then
  begin
    if amt < 0 then amt := 0.35;
    v := Round(amt * 100);
    if AId = 'darken' then v := -v;
    for i := 0 to n - 1 do
    begin
      s := ASrc + i * 4; o := ADst + i * 4;
      o[0] := C8(s[0] + v); o[1] := C8(s[1] + v); o[2] := C8(s[2] + v); o[3] := 0;
    end;
    Exit;
  end;

  if AId = 'contrast' then
  begin
    if amt < 0 then amt := 0.5;
    v := Round((1 + amt) * 256);
    for i := 0 to n - 1 do
    begin
      s := ASrc + i * 4; o := ADst + i * 4;
      o[0] := C8(128 + (((s[0] - 128) * v) div 256));
      o[1] := C8(128 + (((s[1] - 128) * v) div 256));
      o[2] := C8(128 + (((s[2] - 128) * v) div 256));
      o[3] := 0;
    end;
    Exit;
  end;

  if (AId = 'vivid') or (AId = 'desaturate') then
  begin
    if AId = 'vivid' then
    begin
      if amt < 0 then amt := 0.6;
      f := 1 + amt;
    end
    else
    begin
      if amt < 0 then amt := 0.7;
      f := 1 - Clamp01(amt);
    end;
    v := Round(f * 256);
    for i := 0 to n - 1 do
    begin
      s := ASrc + i * 4; o := ADst + i * 4;
      l := Luma(s);
      o[0] := C8(l + (((s[0] - l) * v) div 256));
      o[1] := C8(l + (((s[1] - l) * v) div 256));
      o[2] := C8(l + (((s[2] - l) * v) div 256));
      o[3] := 0;
    end;
    Exit;
  end;

  if AId = 'posterize' then
  begin
    if amt < 0 then amt := 0.5;
    levels := Max(2, Round(8 - Clamp01(amt) * 6));
    for i := 0 to n - 1 do
    begin
      s := ASrc + i * 4; o := ADst + i * 4;
      o[0] := (s[0] * levels div 256) * 255 div (levels - 1);
      o[1] := (s[1] * levels div 256) * 255 div (levels - 1);
      o[2] := (s[2] * levels div 256) * 255 div (levels - 1);
      o[3] := 0;
    end;
    Exit;
  end;

  if AId = 'vignette' then
  begin
    if amt < 0 then amt := 0.8;
    for y := 0 to H - 1 do
    begin
      ny := (y - (H - 1) / 2) / (H / 2);
      for x := 0 to W - 1 do
      begin
        nx := (x - (W - 1) / 2) / (W / 2);
        d := Sqrt(nx * nx + ny * ny) / 1.414;
        v := Round((1 - Clamp01(amt) * Smooth(0.35, 1.0, d)) * 256);
        s := ASrc + (Int64(y) * W + x) * 4; o := ADst + (Int64(y) * W + x) * 4;
        o[0] := (s[0] * v) shr 8; o[1] := (s[1] * v) shr 8; o[2] := (s[2] * v) shr 8; o[3] := 0;
      end;
    end;
    Exit;
  end;

  if AId = 'grain' then
  begin
    if amt < 0 then amt := 0.4;
    v := Round(amt * 70);
    for i := 0 to n - 1 do
    begin
      s := ASrc + i * 4; o := ADst + i * 4;
      r := Integer(Rnd(seed) mod Cardinal(2 * v + 1)) - v;
      o[0] := C8(s[0] + r); o[1] := C8(s[1] + r); o[2] := C8(s[2] + r); o[3] := 0;
    end;
    Exit;
  end;

  if AId = 'scanlines' then
  begin
    if amt < 0 then amt := 0.5;
    v := Round((1 - Clamp01(amt) * 0.5) * 256);
    for y := 0 to H - 1 do
    begin
      { slow horizontal wobble, a tape-tracking look }
      r := Round(Sin((y + ASeed * 3) * 0.05) * Clamp01(amt) * 3);
      for x := 0 to W - 1 do
      begin
        s := PixAt(ASrc, W, H, x + r, y);
        o := ADst + (Int64(y) * W + x) * 4;
        if (y and 1) = 1 then
        begin
          o[0] := (s[0] * v) shr 8; o[1] := (s[1] * v) shr 8; o[2] := (s[2] * v) shr 8;
        end
        else
        begin
          o[0] := s[0]; o[1] := s[1]; o[2] := s[2];
        end;
        o[3] := 0;
      end;
    end;
    Exit;
  end;

  if AId = 'mirror' then
  begin
    for y := 0 to H - 1 do
      for x := 0 to W - 1 do
      begin
        if x < W div 2 then s := ASrc + (Int64(y) * W + x) * 4
        else s := ASrc + (Int64(y) * W + (W - 1 - x)) * 4;
        PCardinal(ADst + (Int64(y) * W + x) * 4)^ := PCardinal(s)^;
      end;
    Exit;
  end;

  if AId = 'flipv' then
  begin
    for y := 0 to H - 1 do
      Move((ASrc + Int64(H - 1 - y) * W * 4)^, (ADst + Int64(y) * W * 4)^, W * 4);
    Exit;
  end;

  if AId = 'rgbsplit' then
  begin
    if amt < 0 then amt := 0.5;
    v := Max(1, Round(Clamp01(amt) * W / 40));
    for y := 0 to H - 1 do
      for x := 0 to W - 1 do
      begin
        o := ADst + (Int64(y) * W + x) * 4;
        o[2] := PixAt(ASrc, W, H, x - v, y)[2];
        o[1] := PixAt(ASrc, W, H, x, y)[1];
        o[0] := PixAt(ASrc, W, H, x + v, y)[0];
        o[3] := 0;
      end;
    Exit;
  end;

  if AId = 'glitch' then
  begin
    if amt < 0 then amt := 0.5;
    seed := Cardinal(ASeed div 3) * 2654435761 + 99991;
    if seed = 0 then seed := 7;
    CopyPic(ASrc, ADst, W, H);
    n := 5 + Round(Clamp01(amt) * 10);
    for i := 1 to n do
    begin
      y := Integer(Rnd(seed) mod Cardinal(H));
      r := Max(2, Integer(Rnd(seed) mod Cardinal(Max(1, H div 6))));
      v := Integer(Rnd(seed) mod Cardinal(Max(1, W div 3))) - W div 6;
      for l := y to Min(H - 1, y + r) do
        for x := 0 to W - 1 do
        begin
          s := PixAt(ASrc, W, H, x + v, l);
          o := ADst + (Int64(l) * W + x) * 4;
          o[2] := s[2];
          o[1] := PixAt(ASrc, W, H, x + v div 2, l)[1];
          o[0] := PixAt(ASrc, W, H, x + v + Max(2, W div 80), l)[0];
        end;
    end;
    Exit;
  end;

  if AId = 'shake' then
  begin
    if amt < 0 then amt := 0.5;
    r := Max(1, Round(Clamp01(amt) * W / 40));
    nx := (Integer(Rnd(seed) mod Cardinal(2 * r + 1)) - r);
    ny := (Integer(Rnd(seed) mod Cardinal(2 * r + 1)) - r);
    for y := 0 to H - 1 do
      for x := 0 to W - 1 do
        PCardinal(ADst + (Int64(y) * W + x) * 4)^ :=
          PCardinal(PixAt(ASrc, W, H, x + Round(nx), y + Round(ny)))^;
    Exit;
  end;

  if AId = 'slowzoom' then
  begin
    if amt < 0 then amt := 0.25;
    ZoomRotate(ASrc, ADst, W, H, 1 + amt * Clamp01(AProgress), 0);
    Exit;
  end;

  if AId = 'pulse' then
  begin
    if amt < 0 then amt := 0.15;
    ZoomRotate(ASrc, ADst, W, H, 1 + amt * Sin(Clamp01(AProgress) * Pi), 0);
    Exit;
  end;

  if AId = 'spin' then
  begin
    ZoomRotate(ASrc, ADst, W, H, 1 + 0.4 * Sin(Clamp01(AProgress) * Pi), Clamp01(AProgress) * 2 * Pi);
    Exit;
  end;

  CopyPic(ASrc, ADst, W, H);
end;

procedure VideoFxRenderFilter(const AId, AParams: string; AProgress: Double;
  ASrc, ADst: PByte; W, H, ASeed: Integer);
var
  amt: Double;
  r, x, y, c, gx, gy, k: Integer;
  tmp: TBytes;
  s, o: PByte;
begin
  if (ASrc = nil) or (ADst = nil) or (W <= 0) or (H <= 0) then Exit;
  amt := ParamF(AParams, 'amt', -1);

  if AId = 'blur' then
  begin
    if amt < 0 then amt := 0.5;
    BoxBlur(ASrc, ADst, W, H, Max(1, Round(Clamp01(amt) * Min(W, H) / 25)));
    Exit;
  end;

  if AId = 'sharpen' then
  begin
    if amt < 0 then amt := 0.8;
    SetLength(tmp, W * H * 4);
    BoxBlur(ASrc, @tmp[0], W, H, 1);
    k := Round(amt * 256);
    for y := 0 to H * W - 1 do
    begin
      s := ASrc + y * 4; o := ADst + y * 4;
      for c := 0 to 2 do
        o[c] := C8(s[c] + (((s[c] - tmp[y * 4 + c]) * k) div 256));
      o[3] := 0;
    end;
    Exit;
  end;

  if AId = 'pixelate' then
  begin
    if amt < 0 then amt := 0.5;
    Mosaic(ASrc, ADst, W, H, Max(2, Round(Clamp01(amt) * Min(W, H) / 12)));
    Exit;
  end;

  if (AId = 'sketch') or (AId = 'emboss') then
  begin
    for y := 0 to H - 1 do
      for x := 0 to W - 1 do
      begin
        o := ADst + (Int64(y) * W + x) * 4;
        if AId = 'sketch' then
        begin
          gx := Luma(PixAt(ASrc, W, H, x + 1, y)) - Luma(PixAt(ASrc, W, H, x - 1, y));
          gy := Luma(PixAt(ASrc, W, H, x, y + 1)) - Luma(PixAt(ASrc, W, H, x, y - 1));
          r := 255 - Min(255, (Abs(gx) + Abs(gy)) * 3);
        end
        else
          r := 128 + Luma(PixAt(ASrc, W, H, x + 1, y + 1)) - Luma(PixAt(ASrc, W, H, x - 1, y - 1));
        o[0] := C8(r); o[1] := C8(r); o[2] := C8(r); o[3] := 0;
      end;
    Exit;
  end;

  PerPixelFilter(AId, AParams, AProgress, ASrc, ADst, W, H, ASeed);
end;

{ ============================== transitions =============================== }

procedure VideoFxRenderTransition(const AId, AParams: string; AProgress: Double;
  AFrom, ATo, ADst: PByte; W, H, ASeed: Integer);
var
  p: Double;
  x, y, i, n, w256, sh, edge, bs, band: Integer;
  cx, cy, dx, dy, rad, maxR, ang, s: Double;
  a, b, o: PByte;
  ta, tb: TBytes;
  seed: Cardinal;
  useB: Boolean;
  v: Integer;

  procedure PutPix(AX, AY: Integer; AUseB: Boolean);
  begin
    if AUseB then PCardinal(ADst + (Int64(AY) * W + AX) * 4)^ := PCardinal(ATo + (Int64(AY) * W + AX) * 4)^
    else PCardinal(ADst + (Int64(AY) * W + AX) * 4)^ := PCardinal(AFrom + (Int64(AY) * W + AX) * 4)^;
  end;

  { soft-edged reveal: AMask 0 = outgoing .. 1 = incoming across a few pixels }
  procedure PutSoft(AX, AY: Integer; AEdgeDist: Double);
  var
    wt: Integer;
  begin
    wt := Round(Clamp01(0.5 + AEdgeDist / 6) * 256);
    Blend(AFrom + (Int64(AY) * W + AX) * 4, ATo + (Int64(AY) * W + AX) * 4,
      ADst + (Int64(AY) * W + AX) * 4, wt);
  end;

begin
  if (AFrom = nil) or (ATo = nil) or (ADst = nil) or (W <= 0) or (H <= 0) then Exit;
  p := Clamp01(AProgress);
  n := W * H;
  w256 := Round(p * 256);
  cx := (W - 1) / 2;
  cy := (H - 1) / 2;
  maxR := Sqrt(cx * cx + cy * cy) + 1;

  if AId = 'crossfade' then
  begin
    for i := 0 to n - 1 do Blend(AFrom + i * 4, ATo + i * 4, ADst + i * 4, w256);
    Exit;
  end;

  if (AId = 'dipblack') or (AId = 'dipwhite') then
  begin
    if AId = 'dipblack' then v := 0 else v := 255;
    for i := 0 to n - 1 do
    begin
      a := AFrom + i * 4; b := ATo + i * 4; o := ADst + i * 4;
      if p < 0.5 then
      begin
        w256 := Round(p * 2 * 256);
        o[0] := (a[0] * (256 - w256) + v * w256) shr 8;
        o[1] := (a[1] * (256 - w256) + v * w256) shr 8;
        o[2] := (a[2] * (256 - w256) + v * w256) shr 8;
      end
      else
      begin
        w256 := Round((p - 0.5) * 2 * 256);
        o[0] := (v * (256 - w256) + b[0] * w256) shr 8;
        o[1] := (v * (256 - w256) + b[1] * w256) shr 8;
        o[2] := (v * (256 - w256) + b[2] * w256) shr 8;
      end;
      o[3] := 0;
    end;
    Exit;
  end;

  if AId = 'blurdissolve' then
  begin
    SetLength(ta, n * 4);
    SetLength(tb, n * 4);
    sh := Max(1, Round(Sin(p * Pi) * Min(W, H) / 18));
    BoxBlur(AFrom, @ta[0], W, H, sh);
    BoxBlur(ATo, @tb[0], W, H, sh);
    for i := 0 to n - 1 do Blend(@ta[i * 4], @tb[i * 4], ADst + i * 4, w256);
    Exit;
  end;

  if AId = 'pixeldissolve' then
  begin
    SetLength(ta, n * 4);
    SetLength(tb, n * 4);
    bs := 1 + Round(Sin(p * Pi) * Min(W, H) / 14);
    Mosaic(AFrom, @ta[0], W, H, bs);
    Mosaic(ATo, @tb[0], W, H, bs);
    for i := 0 to n - 1 do Blend(@ta[i * 4], @tb[i * 4], ADst + i * 4, w256);
    Exit;
  end;

  if (AId = 'wipeleft') or (AId = 'wiperight') then
  begin
    if AId = 'wiperight' then edge := Round(p * W) else edge := Round((1 - p) * W);
    for y := 0 to H - 1 do
      for x := 0 to W - 1 do
        if AId = 'wiperight' then PutSoft(x, y, edge - x) else PutSoft(x, y, x - edge);
    Exit;
  end;

  if (AId = 'wipeup') or (AId = 'wipedown') then
  begin
    if AId = 'wipedown' then edge := Round(p * H) else edge := Round((1 - p) * H);
    for y := 0 to H - 1 do
      for x := 0 to W - 1 do
        if AId = 'wipedown' then PutSoft(x, y, edge - y) else PutSoft(x, y, y - edge);
    Exit;
  end;

  if AId = 'barndoor' then
  begin
    edge := Round(p * W / 2);
    for y := 0 to H - 1 do
      for x := 0 to W - 1 do
        PutSoft(x, y, edge - Abs(x - cx));
    Exit;
  end;

  if AId = 'clock' then
  begin
    for y := 0 to H - 1 do
      for x := 0 to W - 1 do
      begin
        ang := ArcTan2(x - cx, -(y - cy));          // 0 = straight up, clockwise
        if ang < 0 then ang := ang + 2 * Pi;
        PutPix(x, y, ang < p * 2 * Pi);
      end;
    Exit;
  end;

  if (AId = 'circleopen') or (AId = 'circleclose') then
  begin
    if AId = 'circleopen' then rad := p * maxR else rad := (1 - p) * maxR;
    for y := 0 to H - 1 do
      for x := 0 to W - 1 do
      begin
        dx := x - cx; dy := y - cy;
        s := Sqrt(dx * dx + dy * dy);
        if AId = 'circleopen' then PutSoft(x, y, rad - s)
        else PutSoft(x, y, s - rad);
      end;
    Exit;
  end;

  if (AId = 'slideleft') or (AId = 'slideright') then
  begin
    sh := Round(p * W);
    for y := 0 to H - 1 do
      for x := 0 to W - 1 do
        if AId = 'slideleft' then
        begin
          if x + sh < W then PCardinal(ADst + (Int64(y) * W + x) * 4)^ := PCardinal(AFrom + (Int64(y) * W + x + sh) * 4)^
          else PCardinal(ADst + (Int64(y) * W + x) * 4)^ := PCardinal(ATo + (Int64(y) * W + x + sh - W) * 4)^;
        end
        else
        begin
          if x - sh >= 0 then PCardinal(ADst + (Int64(y) * W + x) * 4)^ := PCardinal(AFrom + (Int64(y) * W + x - sh) * 4)^
          else PCardinal(ADst + (Int64(y) * W + x) * 4)^ := PCardinal(ATo + (Int64(y) * W + x - sh + W) * 4)^;
        end;
    Exit;
  end;

  if (AId = 'slideup') or (AId = 'slidedown') then
  begin
    sh := Round(p * H);
    for y := 0 to H - 1 do
      for x := 0 to W - 1 do
        if AId = 'slideup' then
        begin
          if y + sh < H then PCardinal(ADst + (Int64(y) * W + x) * 4)^ := PCardinal(AFrom + (Int64(y + sh) * W + x) * 4)^
          else PCardinal(ADst + (Int64(y) * W + x) * 4)^ := PCardinal(ATo + (Int64(y + sh - H) * W + x) * 4)^;
        end
        else
        begin
          if y - sh >= 0 then PCardinal(ADst + (Int64(y) * W + x) * 4)^ := PCardinal(AFrom + (Int64(y - sh) * W + x) * 4)^
          else PCardinal(ADst + (Int64(y) * W + x) * 4)^ := PCardinal(ATo + (Int64(y - sh + H) * W + x) * 4)^;
        end;
    Exit;
  end;

  if AId = 'zoomin' then
  begin
    SetLength(ta, n * 4);
    ZoomRotate(AFrom, @ta[0], W, H, 1 + p * 1.5, 0);
    for i := 0 to n - 1 do Blend(@ta[i * 4], ATo + i * 4, ADst + i * 4, w256);
    Exit;
  end;

  if AId = 'zoomout' then
  begin
    SetLength(tb, n * 4);
    ZoomRotate(ATo, @tb[0], W, H, 1 + (1 - p) * 1.5, 0);
    for i := 0 to n - 1 do Blend(AFrom + i * 4, @tb[i * 4], ADst + i * 4, w256);
    Exit;
  end;

  if AId = 'glitchtrans' then
  begin
    seed := Cardinal(ASeed div 2) * 2654435761 + 4242;
    if seed = 0 then seed := 9;
    band := Max(4, H div 24);
    y := 0;
    while y < H do
    begin
      useB := (Rnd(seed) mod 1000) / 1000 < p;
      sh := Integer(Rnd(seed) mod Cardinal(Max(1, W div 6))) - W div 12;
      sh := Round(sh * Sin(p * Pi));
      for i := y to Min(H - 1, y + band - 1) do
        for x := 0 to W - 1 do
        begin
          if useB then o := PixAt(ATo, W, H, x + sh, i)
          else o := PixAt(AFrom, W, H, x + sh, i);
          PCardinal(ADst + (Int64(i) * W + x) * 4)^ := PCardinal(o)^;
        end;
      Inc(y, band);
    end;
    if p >= 1 then for i := 0 to n - 1 do PCardinal(ADst + i * 4)^ := PCardinal(ATo + i * 4)^;
    Exit;
  end;

  for i := 0 to n - 1 do Blend(AFrom + i * 4, ATo + i * 4, ADst + i * 4, w256);
end;

initialization
  {$IFDEF FPC}
  FInv := DefaultFormatSettings;
  {$ELSE}
  FInv := TFormatSettings.Create('en-US');
  {$ENDIF}
  FInv.DecimalSeparator := '.';

end.
