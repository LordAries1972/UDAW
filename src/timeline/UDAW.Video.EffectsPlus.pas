unit UDAW.Video.EffectsPlus;
{$I udaw.inc}
{$POINTERMATH ON}
{$OVERFLOWCHECKS OFF}
{$RANGECHECKS OFF}

{ Extended video effect set (blurs, sharpening, colour grades, light, stylise,
  texture, transform, warp, glitch, restoration, beauty, generators, camera
  motion, and many more transitions).  Same contract as UDAW.Video.Effects:
  32-bit BGRX, top row first, Progress 0..1 across the region.  Written from
  scratch with plain pixel arithmetic; the catalogue of what to offer follows
  the effect families found in professional NLE / finishing suites. }

interface

function VfxPlusCount: Integer;
procedure VfxPlusInfo(AIndex: Integer; out AId, AName, AGroup: string; out AIsTransition: Boolean);

{ False when AId is not one of this unit's filters (nothing is written). }
function VfxPlusFilter(const AId, AParams: string; AProgress: Double;
  ASrc, ADst: PByte; W, H, ASeed: Integer): Boolean;
function VfxPlusTransition(const AId, AParams: string; AProgress: Double;
  AFrom, ATo, ADst: PByte; W, H, ASeed: Integer): Boolean;

implementation

uses UDAW.DSP.MathTables,
  SysUtils, Math;

type
  TPlusEntry = record
    Id, Name, Group: string;
    Trans: Boolean;
  end;

var
  FTable: array of TPlusEntry;
  FInv: TFormatSettings;

procedure Reg(const AId, AName, AGroup: string; ATrans: Boolean = False);
var
  n: Integer;
begin
  n := Length(FTable);
  SetLength(FTable, n + 1);
  FTable[n].Id := AId;
  FTable[n].Name := AName;
  FTable[n].Group := AGroup;
  FTable[n].Trans := ATrans;
end;

function VfxPlusCount: Integer;
begin
  Result := Length(FTable);
end;

procedure VfxPlusInfo(AIndex: Integer; out AId, AName, AGroup: string; out AIsTransition: Boolean);
begin
  AId := FTable[AIndex].Id;
  AName := FTable[AIndex].Name;
  AGroup := FTable[AIndex].Group;
  AIsTransition := FTable[AIndex].Trans;
end;

procedure BuildTable;
begin
  { ---- transitions ---- }
  Reg('additive', 'Additive Dissolve', 'Dissolve', True);
  Reg('nonadditive', 'Non-Additive Dissolve', 'Dissolve', True);
  Reg('ditherdissolve', 'Dither Dissolve', 'Dissolve', True);
  Reg('burnaway', 'Burn Away', 'Dissolve', True);
  Reg('irisbox', 'Square Iris', 'Iris', True);
  Reg('irisdiamond', 'Diamond Iris', 'Iris', True);
  Reg('irisoval', 'Oval Iris', 'Iris', True);
  Reg('iriscross', 'Cross Iris', 'Iris', True);
  Reg('shapeheart', 'Heart', 'Shape', True);
  Reg('shapestar', 'Star', 'Shape', True);
  Reg('shapetriup', 'Triangle Up', 'Shape', True);
  Reg('shapetridown', 'Triangle Down', 'Shape', True);
  Reg('shapetrileft', 'Triangle Left', 'Shape', True);
  Reg('shapetriright', 'Triangle Right', 'Shape', True);
  Reg('shapepentagon', 'Pentagon', 'Shape', True);
  Reg('shapehexagon', 'Hexagon', 'Shape', True);
  Reg('bandwipe', 'Band Wipe', 'Wipe', True);
  Reg('venetian', 'Venetian Blinds', 'Wipe', True);
  Reg('venetianv', 'Vertical Blinds', 'Wipe', True);
  Reg('checkerwipe', 'Checker Wipe', 'Wipe', True);
  Reg('diagwipe', 'Diagonal Wipe (Top Left)', 'Wipe', True);
  Reg('diagwipe2', 'Diagonal Wipe (Top Right)', 'Wipe', True);
  Reg('pinwheel', 'Pinwheel', 'Wipe', True);
  Reg('fanwipe', 'Fan Wipe', 'Wipe', True);
  Reg('spiralwipe', 'Spiral Wipe', 'Wipe', True);
  Reg('zigzagwipe', 'Zig-Zag Wipe', 'Wipe', True);
  Reg('xwipe', 'X Wipe', 'Wipe', True);
  Reg('blockwipe', 'Random Blocks', 'Wipe', True);
  Reg('insetwipe', 'Inset Wipe', 'Wipe', True);
  Reg('lumawipe', 'Luma Wipe', 'Wipe', True);
  Reg('coverleft', 'Slide Left', 'Motion', True);
  Reg('coverright', 'Slide Right', 'Motion', True);
  Reg('coverup', 'Slide Up', 'Motion', True);
  Reg('coverdown', 'Slide Down', 'Motion', True);
  Reg('splith', 'Split Open (Horizontal)', 'Motion', True);
  Reg('splitv', 'Split Open (Vertical)', 'Motion', True);
  Reg('squeezeh', 'Squeeze (Horizontal)', 'Motion', True);
  Reg('squeezev', 'Squeeze (Vertical)', 'Motion', True);
  Reg('cardflipx', 'Card Flip (Horizontal)', 'Motion', True);
  Reg('cardflipy', 'Card Flip (Vertical)', 'Motion', True);
  Reg('spintrans', 'Spin Dissolve', 'Motion', True);
  Reg('whippan', 'Whip Pan', 'Motion', True);
  Reg('rippletrans', 'Ripple Dissolve', 'Motion', True);
  Reg('swirltrans', 'Swirl Dissolve', 'Motion', True);
  Reg('zoomblurtrans', 'Zoom Blur Dissolve', 'Motion', True);
  Reg('bandslide', 'Band Slide', 'Motion', True);

  { ---- filters ---- }
  Reg('blurin', 'Blur In', 'Fade');
  Reg('blurout', 'Blur Out', 'Fade');
  Reg('gaussian', 'Gaussian Blur', 'Blur');
  Reg('motionblur', 'Motion Blur', 'Blur');
  Reg('directionalblur', 'Directional Blur (Vertical)', 'Blur');
  Reg('radialblur', 'Radial Blur', 'Blur');
  Reg('zoomblur', 'Zoom Blur', 'Blur');
  Reg('lensblur', 'Lens Blur', 'Blur');
  Reg('tiltshift', 'Tilt-Shift Blur', 'Blur');
  Reg('prismblur', 'Prism Blur', 'Blur');
  Reg('softfocus', 'Soft Focus', 'Blur');
  Reg('unsharp', 'Unsharp Mask', 'Sharpen');
  Reg('ultrasharp', 'Ultra Sharpen', 'Sharpen');
  Reg('sharpenedge', 'Sharpen Edges', 'Sharpen');
  Reg('edgeenhance', 'Edge Enhance', 'Sharpen');
  Reg('clarity', 'Detail Recovery', 'Sharpen');
  Reg('texturepop', 'Texture Pop', 'Sharpen');
  Reg('hueshift', 'Hue Shift', 'Colour');
  Reg('huecycle', 'Hue Cycle', 'Colour');
  Reg('exposure', 'Exposure', 'Colour');
  Reg('gamma', 'Gamma', 'Colour');
  Reg('autolevels', 'Auto Levels', 'Colour');
  Reg('whitebalance', 'Chromatic Adaptation (Auto White Balance)', 'Colour');
  Reg('swaprb', 'Swap Red and Blue', 'Colour');
  Reg('solarize', 'Solarize', 'Colour');
  Reg('threshold', 'Threshold', 'Colour');
  Reg('bleach', 'Bleach Bypass', 'Colour');
  Reg('crossprocess', 'Cross Process', 'Colour');
  Reg('tealorange', 'Teal and Orange', 'Colour');
  Reg('splittone', 'Split Tone', 'Colour');
  Reg('falsecolor', 'False Color', 'Colour');
  Reg('thermal', 'Thermal', 'Colour');
  Reg('nightvision', 'Night Vision', 'Colour');
  Reg('contrastpop', 'Contrast Pop', 'Colour');
  Reg('colorcompress', 'Color Compressor', 'Colour');
  Reg('matte', 'Matte Fade', 'Colour');
  Reg('cyanotype', 'Cyanotype', 'Colour');
  Reg('colorpalette', 'Color Palette (Retro 16)', 'Colour');
  Reg('despill', 'Despill (Green)', 'Colour');
  Reg('filmlook', 'Film Look', 'Colour');
  Reg('glow', 'Glow', 'Light');
  Reg('bloom', 'Bloom', 'Light');
  Reg('halation', 'Halation', 'Light');
  Reg('cinematichaze', 'Cinematic Haze', 'Light');
  Reg('lightrays', 'Light Rays', 'Light');
  Reg('lensflare', 'Lens Flare', 'Light');
  Reg('starglow', 'Aperture Diffraction (Star Glow)', 'Light');
  Reg('spotlight', 'Spotlight', 'Light');
  Reg('lightleak', 'Light Leak', 'Light');
  Reg('strobe', 'Strobe', 'Light');
  Reg('flicker', 'Flicker', 'Light');
  Reg('edgedetect', 'Edge Detect', 'Stylize');
  Reg('pencil', 'Pencil Sketch', 'Stylize');
  Reg('cartoon', 'Cartoon', 'Stylize');
  Reg('oilpaint', 'Oil Paint', 'Stylize');
  Reg('watercolor', 'Watercolor', 'Stylize');
  Reg('halftone', 'Halftone', 'Stylize');
  Reg('anaglyph', 'Anaglyph 3D', 'Stylize');
  Reg('abstraction', 'Abstraction', 'Stylize');
  Reg('xray', 'X-Ray', 'Stylize');
  Reg('dither', 'Dither (Retro)', 'Stylize');
  Reg('shrink', 'Shrink (Erode)', 'Stylize');
  Reg('grow', 'Grow (Dilate)', 'Stylize');
  Reg('jpegdamage', 'JPEG Damage', 'Stylize');
  Reg('noise', 'Colour Noise', 'Texture');
  Reg('filmdamage', 'Film Damage', 'Texture');
  Reg('oldfilm', 'Old Film', 'Texture');
  Reg('canvas', 'Canvas', 'Texture');
  Reg('crt', 'CRT Monitor', 'Texture');
  Reg('fliph', 'Flip Horizontal', 'Transform');
  Reg('mirrorv', 'Mirror (Top to Bottom)', 'Transform');
  Reg('mirror4', 'Mirror (Four Way)', 'Transform');
  Reg('kaleido', 'Kaleidoscope', 'Transform');
  Reg('tile', 'Tile', 'Transform');
  Reg('rot90', 'Rotate 90 Clockwise', 'Transform');
  Reg('rot180', 'Rotate 180', 'Transform');
  Reg('rot270', 'Rotate 90 Counter-Clockwise', 'Transform');
  Reg('zoomcrop', 'Crop and Zoom', 'Transform');
  Reg('keystone', 'Keystone', 'Transform');
  Reg('bulge', 'Bulge', 'Warp');
  Reg('pinch', 'Dent (Pinch)', 'Warp');
  Reg('barrel', 'Lens Distortion', 'Warp');
  Reg('fisheye', 'Fisheye', 'Warp');
  Reg('swirl', 'Swirl', 'Warp');
  Reg('vortex', 'Vortex', 'Warp');
  Reg('ripple', 'Ripple', 'Warp');
  Reg('wave', 'Waviness', 'Warp');
  Reg('magnify', 'Magnify', 'Warp');
  Reg('heathaze', 'Heat Haze', 'Warp');
  Reg('underwater', 'Underwater', 'Warp');
  Reg('chromatic', 'Chromatic Aberration', 'Glitch');
  Reg('vhs', 'Analog Damage (VHS)', 'Glitch');
  Reg('blockglitch', 'Digital Glitch', 'Glitch');
  Reg('tvstatic', 'TV Static', 'Glitch');
  Reg('interlace', 'Interlace Tear', 'Glitch');
  Reg('denoise', 'Noise Reduction', 'Revival');
  Reg('despeckle', 'Despeckle', 'Revival');
  Reg('deadpixel', 'Dead Pixel Fixer', 'Revival');
  Reg('deband', 'Deband', 'Revival');
  Reg('dehaze', 'Dehaze', 'Revival');
  Reg('softskin', 'Beauty (Soften Skin)', 'Beauty');
  Reg('glamour', 'Glamour Glow', 'Beauty');
  Reg('letterbox', 'Letterbox', 'Generate');
  Reg('border', 'Border', 'Generate');
  Reg('gradient', 'Gradient Overlay', 'Generate');
  Reg('grid', 'Grid', 'Generate');
  Reg('colorbars', 'Color Bars', 'Generate');
  Reg('checkerboard', 'Checkerboard', 'Generate');
  Reg('solid', 'Color Generator (Solid)', 'Generate');
  Reg('fastnoise', 'Fast Noise (Clouds)', 'Generate');
  Reg('slowzoomout', 'Slow Zoom Out', 'Camera Motion');
  Reg('panleft', 'Pan Left', 'Camera Motion');
  Reg('panright', 'Pan Right', 'Camera Motion');
  Reg('panup', 'Pan Up', 'Camera Motion');
  Reg('pandown', 'Pan Down', 'Camera Motion');
  Reg('kenburns', 'Ken Burns', 'Camera Motion');
  Reg('dutch', 'Dutch Angle', 'Camera Motion');
  Reg('handheld', 'Handheld', 'Camera Motion');
  Reg('bounce', 'Bounce', 'Camera Motion');
  Reg('earthquake', 'Earthquake', 'Camera Motion');
end;

{ ============================== helpers ================================== }

function C8(V: Integer): Byte; inline;
begin
  if V < 0 then Result := 0
  else if V > 255 then Result := 255
  else Result := Byte(V);
end;

function Cl(X: Double): Double; inline;
begin
  if X < 0 then Result := 0
  else if X > 1 then Result := 1
  else Result := X;
end;

function Lm(P: PByte): Integer; inline;
begin
  Result := (P[0] * 29 + P[1] * 150 + P[2] * 77) shr 8;
end;

function Rnd(var S: Cardinal): Cardinal; inline;
begin
  S := S xor (S shl 13);
  S := S xor (S shr 17);
  S := S xor (S shl 5);
  Result := S;
end;

{ stable 0..1 hash of three integers }
function Hs(A, B, C: Integer): Double;
var
  h: Cardinal;
begin
  h := Cardinal(A) * 374761393 + Cardinal(B) * 668265263 + Cardinal(C) * 2147483647 + 1013904223;
  h := (h xor (h shr 13)) * 1274126177;
  h := h xor (h shr 16);
  Result := (h and $FFFFFF) / 16777215.0;
end;

function Smooth01(X: Double): Double; inline;
begin
  X := Cl(X);
  Result := X * X * (3 - 2 * X);
end;

function ParF(const AParams, AKey: string; ADef: Double): Double;
var
  part: string;
  p: Integer;
begin
  Result := ADef;
  for part in AParams.Split([';']) do
  begin
    p := Pos('=', part);
    if (p > 0) and SameText(Trim(Copy(part, 1, p - 1)), AKey) then
      Exit(StrToFloatDef(Trim(Copy(part, p + 1, MaxInt)), ADef, FInv));
  end;
end;

function ParS(const AParams, AKey, ADef: string): string;
var
  part: string;
  p: Integer;
begin
  Result := ADef;
  for part in AParams.Split([';']) do
  begin
    p := Pos('=', part);
    if (p > 0) and SameText(Trim(Copy(part, 1, p - 1)), AKey) then
      Exit(Trim(Copy(part, p + 1, MaxInt)));
  end;
end;

function PixAt(ASrc: PByte; W, H, X, Y: Integer): PByte; inline;
begin
  if X < 0 then X := 0 else if X >= W then X := W - 1;
  if Y < 0 then Y := 0 else if Y >= H then Y := H - 1;
  Result := ASrc + (Int64(Y) * W + X) * 4;
end;

procedure SetPx(O: PByte; B, G, R: Integer); inline;
begin
  O[0] := C8(B);
  O[1] := C8(G);
  O[2] := C8(R);
  O[3] := 0;
end;

{ bilinear sample, coordinates clamp to the picture }
procedure Bil(ASrc: PByte; W, H: Integer; X, Y: Double; out B, G, R: Integer);
var
  x0, y0: Integer;
  fx, fy, w00, w10, w01, w11: Double;
  p00, p10, p01, p11: PByte;
begin
  if X < 0 then X := 0 else if X > W - 1 then X := W - 1;
  if Y < 0 then Y := 0 else if Y > H - 1 then Y := H - 1;
  x0 := Trunc(X);
  y0 := Trunc(Y);
  fx := X - x0;
  fy := Y - y0;
  p00 := PixAt(ASrc, W, H, x0, y0);
  p10 := PixAt(ASrc, W, H, x0 + 1, y0);
  p01 := PixAt(ASrc, W, H, x0, y0 + 1);
  p11 := PixAt(ASrc, W, H, x0 + 1, y0 + 1);
  w00 := (1 - fx) * (1 - fy);
  w10 := fx * (1 - fy);
  w01 := (1 - fx) * fy;
  w11 := fx * fy;
  B := Round(p00[0] * w00 + p10[0] * w10 + p01[0] * w01 + p11[0] * w11);
  G := Round(p00[1] * w00 + p10[1] * w10 + p01[1] * w01 + p11[1] * w11);
  R := Round(p00[2] * w00 + p10[2] * w10 + p01[2] * w01 + p11[2] * w11);
end;

procedure CopyPic(ASrc, ADst: PByte; W, H: Integer);
begin
  Move(ASrc^, ADst^, Int64(W) * H * 4);
end;

procedure ClearPad(ADst: PByte; N: Integer);
var
  i: Integer;
begin
  for i := 0 to N - 1 do ADst[i * 4 + 3] := 0;
end;

{ separable running-sum box blur, edges clamp }
procedure BoxBlurPic(ASrc, ADst: PByte; W, H, R: Integer);
var
  tmp: TBytes;
  x, y, c, k, n, sum: Integer;
  s, d: PByte;
begin
  if R < 1 then
  begin
    if ASrc <> ADst then CopyPic(ASrc, ADst, W, H);
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
      for k := -R to R do sum := sum + s[Min(W - 1, Max(0, k)) * 4 + c];
      for x := 0 to W - 1 do
      begin
        d[x * 4 + c] := sum div n;
        sum := sum - s[Max(0, x - R) * 4 + c] + s[Min(W - 1, x + R + 1) * 4 + c];
      end;
    end;
  end;
  for x := 0 to W - 1 do
    for c := 0 to 2 do
    begin
      sum := 0;
      for k := -R to R do sum := sum + tmp[Min(H - 1, Max(0, k)) * W * 4 + x * 4 + c];
      for y := 0 to H - 1 do
      begin
        ADst[(Int64(y) * W + x) * 4 + c] := sum div n;
        sum := sum - tmp[Max(0, y - R) * W * 4 + x * 4 + c] +
          tmp[Min(H - 1, y + R + 1) * W * 4 + x * 4 + c];
      end;
    end;
  ClearPad(ADst, W * H);
end;

procedure GaussBlurPic(ASrc, ADst: PByte; W, H, R: Integer);
begin
  BoxBlurPic(ASrc, ADst, W, H, R);
  BoxBlurPic(ADst, ADst, W, H, R);
  BoxBlurPic(ADst, ADst, W, H, R);
end;

{ rotate (radians, clockwise) + scale about the centre, then shift by (AOx*W, AOy*H) }
procedure RotScale(ASrc, ADst: PByte; W, H: Integer; AScale, ARad, AOx, AOy: Double;
  AClamp: Boolean);
var
  x, y, b, g, r: Integer;
  cx, cy, dx, dy, ca, sa, sx, sy: Double;
begin
  if AScale < 0.01 then AScale := 0.01;
  cx := (W - 1) / 2;
  cy := (H - 1) / 2;
  ca := FastCos(ARad);
  sa := FastSin(ARad);
  for y := 0 to H - 1 do
    for x := 0 to W - 1 do
    begin
      dx := (x - cx) / AScale;
      dy := (y - cy) / AScale;
      sx := cx + dx * ca + dy * sa + AOx * W;
      sy := cy - dx * sa + dy * ca + AOy * H;
      if (not AClamp) and ((sx < -0.5) or (sx > W - 0.5) or (sy < -0.5) or (sy > H - 0.5)) then
        PCardinal(ADst + (Int64(y) * W + x) * 4)^ := 0
      else
      begin
        Bil(ASrc, W, H, sx, sy, b, g, r);
        SetPx(ADst + (Int64(y) * W + x) * 4, b, g, r);
      end;
    end;
end;

procedure DirBlurPic(ASrc, ADst: PByte; W, H: Integer; ALen, ARad: Double);
var
  x, y, t, taps, sb, sg, sr: Integer;
  ox, oy, k: Double;
  p: PByte;
begin
  taps := Max(3, Min(32, Round(ALen)));
  ox := FastCos(ARad);
  oy := FastSin(ARad);
  for y := 0 to H - 1 do
    for x := 0 to W - 1 do
    begin
      sb := 0; sg := 0; sr := 0;
      for t := 0 to taps - 1 do
      begin
        k := (t / (taps - 1) - 0.5) * ALen;
        p := PixAt(ASrc, W, H, x + Round(ox * k), y + Round(oy * k));
        sb := sb + p[0]; sg := sg + p[1]; sr := sr + p[2];
      end;
      SetPx(ADst + (Int64(y) * W + x) * 4, sb div taps, sg div taps, sr div taps);
    end;
end;

{ ASpin = false: zoom blur (scale smear); true: spin blur (rotation smear) }
procedure RadialSmear(ASrc, ADst: PByte; W, H: Integer; AStrength: Double; ASpin: Boolean);
const
  TAPS = 14;
var
  x, y, t, sb, sg, sr: Integer;
  cx, cy, dx, dy, k, ca, sa: Double;
  p: PByte;
begin
  cx := (W - 1) / 2;
  cy := (H - 1) / 2;
  for y := 0 to H - 1 do
    for x := 0 to W - 1 do
    begin
      sb := 0; sg := 0; sr := 0;
      for t := 0 to TAPS - 1 do
      begin
        k := (t / (TAPS - 1) - 0.5) * AStrength;
        dx := x - cx;
        dy := y - cy;
        if ASpin then
        begin
          ca := FastCos(k);
          sa := FastSin(k);
          p := PixAt(ASrc, W, H, Round(cx + dx * ca - dy * sa), Round(cy + dx * sa + dy * ca));
        end
        else
          p := PixAt(ASrc, W, H, Round(cx + dx * (1 + k)), Round(cy + dy * (1 + k)));
        sb := sb + p[0]; sg := sg + p[1]; sr := sr + p[2];
      end;
      SetPx(ADst + (Int64(y) * W + x) * 4, sb div TAPS, sg div TAPS, sr div TAPS);
    end;
end;

{ ============================== warps ==================================== }

const
  WK_BULGE = 0; WK_PINCH = 1; WK_BARREL = 2; WK_FISHEYE = 3; WK_SWIRL = 4; WK_VORTEX = 5;
  WK_RIPPLE = 6; WK_WAVE = 7; WK_MAGNIFY = 8; WK_HAZE = 9; WK_WATER = 10; WK_KALEIDO = 11;

procedure WarpKind(ASrc, ADst: PByte; W, H, AKind: Integer; AAmt, AProg: Double);
var
  x, y, b, g, r: Integer;
  cx, cy, r0, dx, dy, rr, rn, k, ang, sx, sy, ca, sa, t, seg, a: Double;
begin
  cx := (W - 1) / 2;
  cy := (H - 1) / 2;
  r0 := Min(W, H) / 2;
  t := AProg * 2 * Pi;
  for y := 0 to H - 1 do
    for x := 0 to W - 1 do
    begin
      dx := x - cx;
      dy := y - cy;
      rr := Sqrt(dx * dx + dy * dy);
      rn := rr / r0;
      sx := x;
      sy := y;
      case AKind of
        WK_BULGE:
          if (rn < 1) and (rr > 0) then
          begin
            k := 1 - AAmt * Sqr(1 - rn);
            sx := cx + dx * k;
            sy := cy + dy * k;
          end;
        WK_PINCH:
          if (rn < 1) and (rr > 0) then
          begin
            k := 1 + AAmt * Sqr(1 - rn);
            sx := cx + dx * k;
            sy := cy + dy * k;
          end;
        WK_BARREL:
          begin
            k := 1 + AAmt * 0.6 * Sqr(rr / Sqrt(cx * cx + cy * cy + 1));
            sx := cx + dx * k;
            sy := cy + dy * k;
          end;
        WK_FISHEYE:
          if rr > 0 then
          begin
            k := Cl(rr / Sqrt(cx * cx + cy * cy + 1));
            k := 1 - AAmt * 0.8 * (1 - k) * (1 - k * 0.3);
            sx := cx + dx * k;
            sy := cy + dy * k;
          end;
        WK_SWIRL, WK_VORTEX:
          begin
            if AKind = WK_SWIRL then
            begin
              if rn < 1 then ang := AAmt * 4 * Sqr(1 - rn) else ang := 0;
            end
            else
              ang := AAmt * 6 * FastExp(-rn * 1.5) + AProg * 0;
            ca := FastCos(ang);
            sa := FastSin(ang);
            sx := cx + dx * ca - dy * sa;
            sy := cy + dx * sa + dy * ca;
          end;
        WK_RIPPLE:
          if rr > 0 then
          begin
            k := AAmt * 0.04 * r0 * FastSin(rn * 18 - t * 2);
            sx := x + dx / rr * k;
            sy := y + dy / rr * k;
          end;
        WK_WAVE:
          begin
            sx := x + AAmt * W / 30 * FastSin(y / Max(8.0, H / 10) + t);
            sy := y + AAmt * H / 60 * FastSin(x / Max(8.0, W / 10) + t * 0.7);
          end;
        WK_MAGNIFY:
          if rn < 0.5 then
          begin
            sx := cx + dx * (1 - AAmt * 0.5);
            sy := cy + dy * (1 - AAmt * 0.5);
          end
          else if rn < 0.62 then
          begin
            k := 1 - AAmt * 0.5 * (1 - Smooth01((rn - 0.5) / 0.12));
            sx := cx + dx * k;
            sy := cy + dy * k;
          end;
        WK_HAZE:
          begin
            sx := x + AAmt * 3 * FastSin(y * 0.09 + t * 3) * FastCos(x * 0.035 + t * 2);
            sy := y + AAmt * 2 * FastSin(x * 0.07 - t * 2.5);
          end;
        WK_WATER:
          begin
            sx := x + AAmt * W / 60 * FastSin(y / Max(6.0, H / 14) + t * 2);
            sy := y + AAmt * H / 80 * FastSin(x / Max(6.0, W / 12) - t * 1.5);
          end;
        WK_KALEIDO:
          begin
            seg := 2 * Pi / 6;
            a := FastArcTan2(dy, dx) + AProg * Pi / 3;
            a := a - Floor(a / seg) * seg;
            if a > seg / 2 then a := seg - a;
            sx := cx + rr * FastCos(a);
            sy := cy + rr * FastSin(a);
          end;
      end;
      Bil(ASrc, W, H, sx, sy, b, g, r);
      if AKind = WK_WATER then SetPx(ADst + (Int64(y) * W + x) * 4, b + Round(18 * AAmt), g + Round(6 * AAmt), r - Round(14 * AAmt))
      else SetPx(ADst + (Int64(y) * W + x) * 4, b, g, r);
    end;
end;

{ ============================ filter families ============================ }

type
  TFx = record
    Id, Params: string;
    Prog, Amt: Double;
    Src, Dst: PByte;
    W, H, N, Seed: Integer;
  end;

function Amount(const F: TFx; ADef: Double): Double; inline;
begin
  if F.Amt < 0 then Result := ADef else Result := F.Amt;
end;

procedure ApplyLut(const F: TFx; const ALut: array of Byte);
var
  i: Integer;
  s, o: PByte;
begin
  for i := 0 to F.N - 1 do
  begin
    s := F.Src + i * 4;
    o := F.Dst + i * 4;
    o[0] := ALut[s[0]]; o[1] := ALut[s[1]]; o[2] := ALut[s[2]]; o[3] := 0;
  end;
end;

{ stops are $RRGGBB, evenly spaced; L in 0..1 }
procedure RampColor(L: Double; const AStops: array of Integer; out B, G, R: Integer);
var
  f: Double;
  i, c0, c1: Integer;
begin
  f := Cl(L) * (High(AStops));
  i := Trunc(f);
  if i >= High(AStops) then i := High(AStops) - 1;
  f := f - i;
  c0 := AStops[i];
  c1 := AStops[i + 1];
  R := Round(((c0 shr 16) and $FF) * (1 - f) + ((c1 shr 16) and $FF) * f);
  G := Round(((c0 shr 8) and $FF) * (1 - f) + ((c1 shr 8) and $FF) * f);
  B := Round((c0 and $FF) * (1 - f) + (c1 and $FF) * f);
end;

procedure ScreenAddPic(ASrc, AGlow, ADst: PByte; N: Integer; AGain: Double);
var
  i, c, gv: Integer;
begin
  for i := 0 to N - 1 do
  begin
    for c := 0 to 2 do
    begin
      gv := Round(AGlow[i * 4 + c] * AGain);
      if gv > 255 then gv := 255;
      ADst[i * 4 + c] := 255 - ((255 - ASrc[i * 4 + c]) * (255 - gv)) div 255;
    end;
    ADst[i * 4 + 3] := 0;
  end;
end;

{ keeps only the part of each pixel above AThr luma }
procedure BrightPass(ASrc, ADst: PByte; N, AThr: Integer);
var
  i, l, k: Integer;
begin
  for i := 0 to N - 1 do
  begin
    l := Lm(ASrc + i * 4);
    if l <= AThr then k := 0 else k := ((l - AThr) * 256) div Max(1, 256 - AThr);
    ADst[i * 4] := (ASrc[i * 4] * k) shr 8;
    ADst[i * 4 + 1] := (ASrc[i * 4 + 1] * k) shr 8;
    ADst[i * 4 + 2] := (ASrc[i * 4 + 2] * k) shr 8;
    ADst[i * 4 + 3] := 0;
  end;
end;

procedure GlowCommon(const F: TFx; AThr: Integer; ARadDiv: Double; AGain: Double);
var
  t1, t2: TBytes;
  rad: Integer;
begin
  SetLength(t1, F.N * 4);
  SetLength(t2, F.N * 4);
  BrightPass(F.Src, @t1[0], F.N, AThr);
  rad := Max(2, Round(Min(F.W, F.H) / ARadDiv * (0.5 + Amount(F, 0.5))));
  GaussBlurPic(@t1[0], @t2[0], F.W, F.H, rad);
  ScreenAddPic(F.Src, @t2[0], F.Dst, F.N, AGain * (0.6 + Amount(F, 0.5)));
end;

function PlusBlur(var F: TFx): Boolean;
var
  t: TBytes;
  x, y, i, c, rad, taps, b, g, r, d: Integer;
  rr, ang, m, v, amt: Double;
  o: PByte;
begin
  Result := True;
  amt := Amount(F, 0.5);
  if F.Id = 'gaussian' then
    GaussBlurPic(F.Src, F.Dst, F.W, F.H, Max(1, Round(Cl(amt) * Min(F.W, F.H) / 40)))
  else if F.Id = 'motionblur' then
    DirBlurPic(F.Src, F.Dst, F.W, F.H, Max(3.0, Cl(amt) * F.W / 10),
      ParF(F.Params, 'angle', 0) * Pi / 180)
  else if F.Id = 'directionalblur' then
    DirBlurPic(F.Src, F.Dst, F.W, F.H, Max(3.0, Cl(amt) * F.H / 8), Pi / 2)
  else if F.Id = 'radialblur' then
    RadialSmear(F.Src, F.Dst, F.W, F.H, Cl(amt) * 0.3, True)
  else if F.Id = 'zoomblur' then
    RadialSmear(F.Src, F.Dst, F.W, F.H, Cl(amt) * 0.3, False)
  else if F.Id = 'lensblur' then
  begin
    rad := Max(2, Round(Cl(amt) * Min(F.W, F.H) / 30));
    taps := 28;
    for y := 0 to F.H - 1 do
      for x := 0 to F.W - 1 do
      begin
        b := 0; g := 0; r := 0;
        for i := 0 to taps - 1 do
        begin
          rr := rad * Sqrt((i + 0.5) / taps);
          ang := i * 2.399963;
          o := PixAt(F.Src, F.W, F.H, x + Round(rr * FastCos(ang)), y + Round(rr * FastSin(ang)));
          b := b + o[0]; g := g + o[1]; r := r + o[2];
        end;
        SetPx(F.Dst + (Int64(y) * F.W + x) * 4, b div taps, g div taps, r div taps);
      end;
  end
  else if F.Id = 'tiltshift' then
  begin
    SetLength(t, F.N * 4);
    GaussBlurPic(F.Src, @t[0], F.W, F.H, Max(2, Round(Cl(amt + 0.3) * Min(F.W, F.H) / 35)));
    for y := 0 to F.H - 1 do
    begin
      m := Smooth01((Abs(y / Max(1, F.H - 1) - 0.5) - 0.12) / 0.3);
      d := Round(m * 256);
      for x := 0 to F.W - 1 do
      begin
        i := (y * F.W + x) * 4;
        for c := 0 to 2 do
          F.Dst[i + c] := (F.Src[i + c] * (256 - d) + t[i + c] * d) shr 8;
        F.Dst[i + 3] := 0;
      end;
    end;
  end
  else if F.Id = 'prismblur' then
  begin
    SetLength(t, F.N * 4);
    BoxBlurPic(F.Src, @t[0], F.W, F.H, Max(1, Round(Cl(amt) * Min(F.W, F.H) / 60)));
    d := Max(2, Round(Cl(amt) * F.W / 40));
    for y := 0 to F.H - 1 do
      for x := 0 to F.W - 1 do
      begin
        o := F.Dst + (Int64(y) * F.W + x) * 4;
        o[2] := PixAt(@t[0], F.W, F.H, x + d, y + d div 2)[2];
        o[1] := PixAt(@t[0], F.W, F.H, x, y)[1];
        o[0] := PixAt(@t[0], F.W, F.H, x - d, y - d div 2)[0];
        o[3] := 0;
      end;
  end
  else if F.Id = 'softfocus' then
  begin
    SetLength(t, F.N * 4);
    GaussBlurPic(F.Src, @t[0], F.W, F.H, Max(2, Round(Min(F.W, F.H) / 40)));
    for i := 0 to F.N - 1 do
    begin
      for c := 0 to 2 do
        F.Dst[i * 4 + c] := C8((F.Src[i * 4 + c] * 256 + t[i * 4 + c] * 256) div 512 + Round(12 * amt));
      F.Dst[i * 4 + 3] := 0;
    end;
  end
  else if (F.Id = 'blurin') or (F.Id = 'blurout') then
  begin
    if F.Id = 'blurin' then v := 1 - Cl(F.Prog) else v := Cl(F.Prog);
    rad := Round(v * Min(F.W, F.H) / 12 * (0.5 + amt));
    GaussBlurPic(F.Src, F.Dst, F.W, F.H, rad);
  end
  else
    Result := False;
end;

function PlusSharpen(var F: TFx): Boolean;
var
  t: TBytes;
  i, c, rad, d, e, gx, gy: Integer;
  amt, mask: Double;
  s, o: PByte;
  x, y: Integer;
begin
  Result := True;
  amt := Amount(F, 0.8);
  SetLength(t, F.N * 4);
  if (F.Id = 'unsharp') or (F.Id = 'ultrasharp') or (F.Id = 'texturepop') then
  begin
    if F.Id = 'unsharp' then rad := Max(2, Min(F.W, F.H) div 80)
    else if F.Id = 'ultrasharp' then rad := Max(1, Min(F.W, F.H) div 200)
    else rad := Max(2, Min(F.W, F.H) div 120);
    BoxBlurPic(F.Src, @t[0], F.W, F.H, rad);
    for i := 0 to F.N - 1 do
    begin
      for c := 0 to 2 do
      begin
        d := F.Src[i * 4 + c] - t[i * 4 + c];
        if (F.Id = 'unsharp') and (Abs(d) < 4) then d := 0;
        if F.Id = 'ultrasharp' then e := Round(d * amt * 3.0) else if F.Id = 'texturepop' then e := Round(d * amt * 2.0) else e := Round(d * amt * 1.5);
        F.Dst[i * 4 + c] := C8(F.Src[i * 4 + c] + e);
      end;
      F.Dst[i * 4 + 3] := 0;
    end;
  end
  else if F.Id = 'sharpenedge' then
  begin
    BoxBlurPic(F.Src, @t[0], F.W, F.H, 1);
    for y := 0 to F.H - 1 do
      for x := 0 to F.W - 1 do
      begin
        gx := Lm(PixAt(F.Src, F.W, F.H, x + 1, y)) - Lm(PixAt(F.Src, F.W, F.H, x - 1, y));
        gy := Lm(PixAt(F.Src, F.W, F.H, x, y + 1)) - Lm(PixAt(F.Src, F.W, F.H, x, y - 1));
        mask := Cl((Abs(gx) + Abs(gy)) / 60);
        i := (y * F.W + x) * 4;
        for c := 0 to 2 do
          F.Dst[i + c] := C8(F.Src[i + c] + Round((F.Src[i + c] - t[i + c]) * amt * 3 * mask));
        F.Dst[i + 3] := 0;
      end;
  end
  else if F.Id = 'edgeenhance' then
  begin
    for y := 0 to F.H - 1 do
      for x := 0 to F.W - 1 do
      begin
        o := F.Dst + (Int64(y) * F.W + x) * 4;
        s := PixAt(F.Src, F.W, F.H, x, y);
        for c := 0 to 2 do
        begin
          d := 5 * s[c] - PixAt(F.Src, F.W, F.H, x - 1, y)[c] - PixAt(F.Src, F.W, F.H, x + 1, y)[c] -
            PixAt(F.Src, F.W, F.H, x, y - 1)[c] - PixAt(F.Src, F.W, F.H, x, y + 1)[c];
          o[c] := C8(s[c] + Round((d - s[c]) * Cl(amt)));
        end;
        o[3] := 0;
      end;
  end
  else if F.Id = 'clarity' then
  begin
    BoxBlurPic(F.Src, @t[0], F.W, F.H, Max(3, Min(F.W, F.H) div 25));
    for i := 0 to F.N - 1 do
    begin
      mask := 1 - Abs(Lm(F.Src + i * 4) / 127.5 - 1);
      for c := 0 to 2 do
        F.Dst[i * 4 + c] := C8(F.Src[i * 4 + c] + Round((F.Src[i * 4 + c] - t[i * 4 + c]) * amt * 0.9 * (0.4 + 0.6 * mask)));
      F.Dst[i * 4 + 3] := 0;
    end;
  end
  else
    Result := False;
end;

const
  PALETTE16: array[0..15] of Integer = ($000000, $1D2B53, $7E2553, $008751, $AB5236, $5F574F,
    $C2C3C7, $FFF1E8, $FF004D, $FFA300, $FFEC27, $00E436, $29ADFF, $83769C, $FF77A8, $FFCCAA);

function PlusColour(var F: TFx): Boolean;
var
  lut: array[0..255] of Byte;
  i, c, v, l, lo, hi, tot, acc: Integer;
  hist: array[0..255] of Integer;
  amt, fv, ang, yy, ii, qq, ni, nq, tt, gam, avgB, avgG, avgR: Double;
  s, o: PByte;
  b, g, r: Integer;
  col: Cardinal;
  sumB, sumG, sumR: Int64;
  bestD, d2, bi, k: Integer;
begin
  Result := True;
  amt := Amount(F, 0.5);

  if (F.Id = 'hueshift') or (F.Id = 'huecycle') then
  begin
    if F.Id = 'huecycle' then ang := Cl(F.Prog) * 2 * Pi
    else ang := Amount(F, 0.33) * 2 * Pi;
    for i := 0 to F.N - 1 do
    begin
      s := F.Src + i * 4;
      yy := 0.299 * s[2] + 0.587 * s[1] + 0.114 * s[0];
      ii := 0.596 * s[2] - 0.274 * s[1] - 0.322 * s[0];
      qq := 0.211 * s[2] - 0.523 * s[1] + 0.312 * s[0];
      ni := ii * FastCos(ang) - qq * FastSin(ang);
      nq := ii * FastSin(ang) + qq * FastCos(ang);
      SetPx(F.Dst + i * 4, Round(yy - 1.106 * ni + 1.703 * nq),
        Round(yy - 0.272 * ni - 0.647 * nq), Round(yy + 0.956 * ni + 0.621 * nq));
    end;
  end
  else if F.Id = 'exposure' then
  begin
    fv := FastExp2(Amount(F, 0.4) * 1.5);
    for i := 0 to 255 do lut[i] := C8(Round(i * fv));
    ApplyLut(F, lut);
  end
  else if F.Id = 'gamma' then
  begin
    gam := 1 / (1 + Amount(F, 0.5) * 1.2);
    for i := 0 to 255 do lut[i] := C8(Round(FastPow(i / 255, gam) * 255));
    ApplyLut(F, lut);
  end
  else if F.Id = 'solarize' then
  begin
    v := Round(Cl(Amount(F, 0.5)) * 255);
    for i := 0 to 255 do
      if i >= v then lut[i] := 255 - i else lut[i] := i;
    ApplyLut(F, lut);
  end
  else if F.Id = 'matte' then
  begin
    for i := 0 to 255 do lut[i] := C8(Round(24 + i * (0.86 - amt * 0.1)));
    ApplyLut(F, lut);
  end
  else if F.Id = 'threshold' then
  begin
    v := Round(Cl(Amount(F, 0.5)) * 255);
    for i := 0 to F.N - 1 do
    begin
      if Lm(F.Src + i * 4) >= v then l := 255 else l := 0;
      F.Dst[i * 4] := l; F.Dst[i * 4 + 1] := l; F.Dst[i * 4 + 2] := l; F.Dst[i * 4 + 3] := 0;
    end;
  end
  else if F.Id = 'swaprb' then
  begin
    for i := 0 to F.N - 1 do
    begin
      s := F.Src + i * 4;
      F.Dst[i * 4] := s[2]; F.Dst[i * 4 + 1] := s[1]; F.Dst[i * 4 + 2] := s[0]; F.Dst[i * 4 + 3] := 0;
    end;
  end
  else if F.Id = 'autolevels' then
  begin
    FillChar(hist, SizeOf(hist), 0);
    for i := 0 to F.N - 1 do Inc(hist[Lm(F.Src + i * 4)]);
    tot := F.N;
    acc := 0; lo := 0;
    for i := 0 to 255 do
    begin
      acc := acc + hist[i];
      if acc > tot div 100 then begin lo := i; Break; end;
    end;
    acc := 0; hi := 255;
    for i := 255 downto 0 do
    begin
      acc := acc + hist[i];
      if acc > tot div 100 then begin hi := i; Break; end;
    end;
    if hi - lo < 16 then begin lo := 0; hi := 255; end;
    for i := 0 to 255 do lut[i] := C8(Round(i + (((i - lo) * 255.0 / (hi - lo)) - i) * Cl(Amount(F, 1))));
    ApplyLut(F, lut);
  end
  else if F.Id = 'whitebalance' then
  begin
    sumB := 0; sumG := 0; sumR := 0;
    for i := 0 to F.N - 1 do
    begin
      Inc(sumB, F.Src[i * 4]); Inc(sumG, F.Src[i * 4 + 1]); Inc(sumR, F.Src[i * 4 + 2]);
    end;
    avgB := Max(1.0, sumB / F.N); avgG := Max(1.0, sumG / F.N); avgR := Max(1.0, sumR / F.N);
    fv := (avgB + avgG + avgR) / 3;
    for i := 0 to F.N - 1 do
    begin
      s := F.Src + i * 4;
      SetPx(F.Dst + i * 4, Round(s[0] * (1 + (fv / avgB - 1) * Cl(amt * 2))),
        Round(s[1] * (1 + (fv / avgG - 1) * Cl(amt * 2))), Round(s[2] * (1 + (fv / avgR - 1) * Cl(amt * 2))));
    end;
  end
  else if F.Id = 'bleach' then
  begin
    for i := 0 to F.N - 1 do
    begin
      s := F.Src + i * 4;
      l := Lm(s);
      for c := 0 to 2 do
      begin
        if l < 128 then v := (2 * l * s[c]) div 255
        else v := 255 - (2 * (255 - l) * (255 - s[c])) div 255;
        F.Dst[i * 4 + c] := C8(Round(s[c] + (v - s[c]) * Cl(amt + 0.2)));
      end;
      F.Dst[i * 4 + 3] := 0;
    end;
  end
  else if F.Id = 'crossprocess' then
  begin
    for i := 0 to F.N - 1 do
    begin
      s := F.Src + i * 4;
      tt := s[2] / 255;
      r := Round(255 * (tt + (Smooth01(tt) - tt) * 1.4));
      g := Round(255 * FastPow(s[1] / 255, 0.9));
      b := Round(255 * (0.12 + 0.72 * s[0] / 255));
      SetPx(F.Dst + i * 4, s[0] + Round((b - s[0]) * Cl(amt + 0.3)), s[1] + Round((g - s[1]) * Cl(amt + 0.3)),
        s[2] + Round((r - s[2]) * Cl(amt + 0.3)));
    end;
  end
  else if (F.Id = 'tealorange') or (F.Id = 'splittone') then
  begin
    for i := 0 to F.N - 1 do
    begin
      s := F.Src + i * 4;
      fv := Lm(s) / 255;
      if F.Id = 'tealorange' then
        SetPx(F.Dst + i * 4, Round(s[0] + (1 - fv) * 22 * amt - fv * 24 * amt),
          Round(s[1] + (1 - fv) * 8 * amt + fv * 6 * amt), Round(s[2] - (1 - fv) * 22 * amt + fv * 28 * amt))
      else
        SetPx(F.Dst + i * 4, Round(s[0] + (1 - fv) * 36 * amt - fv * 30 * amt),
          Round(s[1] - (1 - fv) * 6 * amt + fv * 14 * amt), Round(s[2] - (1 - fv) * 10 * amt + fv * 34 * amt));
    end;
  end
  else if (F.Id = 'falsecolor') or (F.Id = 'thermal') then
  begin
    for i := 0 to F.N - 1 do
    begin
      fv := Lm(F.Src + i * 4) / 255;
      if F.Id = 'falsecolor' then
        RampColor(fv, [$5A0A8C, $1E3CC8, $14B450, $F0DC1E, $E61E1E], b, g, r)
      else
        RampColor(fv, [$000010, $2000A0, $C01060, $FF6000, $FFE000, $FFFFFF], b, g, r);
      SetPx(F.Dst + i * 4, b, g, r);
    end;
  end
  else if F.Id = 'nightvision' then
  begin
    col := Cardinal(F.Seed) * 2654435761 + 77;
    if col = 0 then col := 5;
    for i := 0 to F.N - 1 do
    begin
      l := Min(255, Lm(F.Src + i * 4) * 3 div 2 + 20);
      v := Integer(Rnd(col) mod 41) - 20;
      SetPx(F.Dst + i * 4, l div 5 + v div 3, l + v, l div 4 + v div 3);
    end;
  end
  else if F.Id = 'contrastpop' then
  begin
    for i := 0 to 255 do
    begin
      tt := i / 255;
      lut[i] := C8(Round(255 * (tt + (Smooth01(tt) - tt) * Cl(amt + 0.4))));
    end;
    for i := 0 to F.N - 1 do
    begin
      s := F.Src + i * 4;
      l := Lm(s);
      for c := 0 to 2 do
        F.Dst[i * 4 + c] := lut[C8(l + ((s[c] - l) * 300) div 256)];
      F.Dst[i * 4 + 3] := 0;
    end;
  end
  else if F.Id = 'colorcompress' then
  begin
    for i := 0 to F.N - 1 do
    begin
      s := F.Src + i * 4;
      l := Lm(s);
      d2 := Max(s[0], Max(s[1], s[2])) - Min(s[0], Min(s[1], s[2]));
      fv := 1 / (1 + Amount(F, 0.8) * d2 / 100);
      for c := 0 to 2 do
        F.Dst[i * 4 + c] := C8(Round(l + (s[c] - l) * fv));
      F.Dst[i * 4 + 3] := 0;
    end;
  end
  else if F.Id = 'cyanotype' then
  begin
    for i := 0 to F.N - 1 do
    begin
      RampColor(Lm(F.Src + i * 4) / 255, [$001F4D, $0D5C99, $87C8E6, $F2FAFF], b, g, r);
      SetPx(F.Dst + i * 4, b, g, r);
    end;
  end
  else if F.Id = 'colorpalette' then
  begin
    for i := 0 to F.N - 1 do
    begin
      s := F.Src + i * 4;
      bestD := MaxInt; bi := 0;
      for k := 0 to 15 do
      begin
        c := PALETTE16[k];
        d2 := Sqr(((c shr 16) and $FF) - s[2]) + Sqr(((c shr 8) and $FF) - s[1]) + Sqr((c and $FF) - s[0]);
        if d2 < bestD then begin bestD := d2; bi := k; end;
      end;
      c := PALETTE16[bi];
      SetPx(F.Dst + i * 4, c and $FF, (c shr 8) and $FF, (c shr 16) and $FF);
    end;
  end
  else if F.Id = 'despill' then
  begin
    for i := 0 to F.N - 1 do
    begin
      s := F.Src + i * 4;
      v := (s[0] + s[2]) div 2;
      o := F.Dst + i * 4;
      o[0] := s[0]; o[2] := s[2]; o[3] := 0;
      if s[1] > v then o[1] := C8(Round(s[1] - (s[1] - v) * Cl(Amount(F, 1)))) else o[1] := s[1];
    end;
  end
  else if F.Id = 'filmlook' then
  begin
    col := Cardinal(F.Seed) * 2654435761 + 31337;
    if col = 0 then col := 3;
    for i := 0 to F.N - 1 do
    begin
      s := F.Src + i * 4;
      fv := Lm(s) / 255;
      for c := 0 to 2 do
      begin
        tt := s[c] / 255;
        tt := tt + (Smooth01(tt) - tt) * 0.8;
        v := Round(tt * 255);
        if c = 0 then v := v + Round((1 - fv) * 12 * amt - fv * 8 * amt)
        else if c = 2 then v := v + Round(fv * 14 * amt - (1 - fv) * 8 * amt);
        v := v + Integer(Rnd(col) mod 9) - 4;
        F.Dst[i * 4 + c] := C8(v);
      end;
      F.Dst[i * 4 + 3] := 0;
    end;
  end
  else
    Result := False;
end;

function PlusLight(var F: TFx): Boolean;
var
  t1, t2: TBytes;
  x, y, i, b, g, r, k, taps, gv: Integer;
  amt, px, py, cx, cy, dx, dy, d, inten, m, fv, sc, lx, ly, ox, oy: Double;
  s, o: PByte;
  seed: Cardinal;
const
  FL_F: array[0..4] of Double = (1.0, 0.62, 0.32, -0.42, -0.85);
  FL_R: array[0..4] of Double = (0.20, 0.06, 0.09, 0.13, 0.05);
  FL_B: array[0..4] of Integer = (150, 60, 90, 70, 110);
  FL_G: array[0..4] of Integer = (180, 150, 100, 120, 160);
  FL_RR: array[0..4] of Integer = (255, 90, 70, 150, 100);
begin
  Result := True;
  amt := Amount(F, 0.5);

  if F.Id = 'glow' then GlowCommon(F, 150, 40, 0.9)
  else if F.Id = 'bloom' then GlowCommon(F, 175, 22, 1.2)
  else if F.Id = 'halation' then
  begin
    SetLength(t1, F.N * 4);
    SetLength(t2, F.N * 4);
    BrightPass(F.Src, @t1[0], F.N, 190);
    GaussBlurPic(@t1[0], @t2[0], F.W, F.H, Max(2, Round(Min(F.W, F.H) / 35 * (0.5 + amt))));
    for i := 0 to F.N - 1 do
    begin
      k := Lm(@t2[i * 4]);
      t2[i * 4] := k div 10;
      t2[i * 4 + 1] := k * 35 div 100;
      t2[i * 4 + 2] := k;
    end;
    ScreenAddPic(F.Src, @t2[0], F.Dst, F.N, 1.0 + amt);
  end
  else if F.Id = 'cinematichaze' then
  begin
    SetLength(t1, F.N * 4);
    GaussBlurPic(F.Src, @t1[0], F.W, F.H, Max(2, Min(F.W, F.H) div 30));
    fv := Cl(amt) * 0.45;
    for i := 0 to F.N - 1 do
    begin
      SetPx(F.Dst + i * 4,
        Round(F.Src[i * 4] * (1 - fv) + (t1[i * 4] * 0.7 + 95) * fv),
        Round(F.Src[i * 4 + 1] * (1 - fv) + (t1[i * 4 + 1] * 0.7 + 85) * fv),
        Round(F.Src[i * 4 + 2] * (1 - fv) + (t1[i * 4 + 2] * 0.7 + 70) * fv));
    end;
  end
  else if F.Id = 'lightrays' then
  begin
    SetLength(t1, F.N * 4);
    BrightPass(F.Src, @t1[0], F.N, 170);
    lx := ParF(F.Params, 'x', 0.5 + 0.2 * FastSin(F.Prog * 2 * Pi)) * (F.W - 1);
    ly := ParF(F.Params, 'y', 0.2) * (F.H - 1);
    taps := 24;
    SetLength(t2, F.N * 4);
    for y := 0 to F.H - 1 do
      for x := 0 to F.W - 1 do
      begin
        b := 0; g := 0; r := 0;
        for k := 0 to taps - 1 do
        begin
          fv := k / taps * 0.85;
          o := PixAt(@t1[0], F.W, F.H, Round(x + (lx - x) * fv), Round(y + (ly - y) * fv));
          m := 1 - k / taps;
          b := b + Round(o[0] * m); g := g + Round(o[1] * m); r := r + Round(o[2] * m);
        end;
        SetPx(@t2[(y * F.W + x) * 4], b * 2 div taps, g * 2 div taps, r * 2 div taps);
      end;
    ScreenAddPic(F.Src, @t2[0], F.Dst, F.N, 0.5 + amt);
  end
  else if F.Id = 'starglow' then
  begin
    SetLength(t1, F.N * 4);
    SetLength(t2, F.N * 4);
    BrightPass(F.Src, @t1[0], F.N, 200);
    FillChar(t2[0], F.N * 4, 0);
    sc := Max(6, Cl(amt + 0.2) * F.W / 8);
    for k := 0 to 3 do
    begin
      ox := FastCos(k * Pi / 4 + 0.0);
      oy := FastSin(k * Pi / 4);
      for y := 0 to F.H - 1 do
        for x := 0 to F.W - 1 do
        begin
          b := 0; g := 0; r := 0;
          for i := 0 to 15 do
          begin
            fv := (i / 15 - 0.5) * sc;
            o := PixAt(@t1[0], F.W, F.H, x + Round(ox * fv), y + Round(oy * fv));
            b := b + o[0]; g := g + o[1]; r := r + o[2];
          end;
          o := @t2[(y * F.W + x) * 4];
          o[0] := C8(o[0] + b div 16);
          o[1] := C8(o[1] + g div 16);
          o[2] := C8(o[2] + r div 16);
        end;
    end;
    ScreenAddPic(F.Src, @t2[0], F.Dst, F.N, 1.1);
  end
  else if F.Id = 'lensflare' then
  begin
    px := (0.2 + 0.6 * Cl(F.Prog)) * F.W;
    py := (0.3 + 0.1 * FastSin(F.Prog * Pi)) * F.H;
    cx := F.W / 2;
    cy := F.H / 2;
    for y := 0 to F.H - 1 do
      for x := 0 to F.W - 1 do
      begin
        b := 0; g := 0; r := 0;
        for k := 0 to 4 do
        begin
          dx := x - (cx + (px - cx) * FL_F[k]);
          dy := y - (cy + (py - cy) * FL_F[k]);
          d := Sqrt(dx * dx + dy * dy) / (FL_R[k] * F.H);
          if k = 0 then inten := FastExp(-d * d * 3) * 1.2
          else if k = 3 then inten := FastExp(-Sqr((d - 1) * 4)) * 0.6 + 0.15 * FastExp(-d * d * 3)
          else inten := 0.45 * FastExp(-d * d * 3);
          inten := inten * (0.3 + amt);
          b := b + Round(FL_B[k] * inten);
          g := g + Round(FL_G[k] * inten);
          r := r + Round(FL_RR[k] * inten);
        end;
        o := F.Dst + (Int64(y) * F.W + x) * 4;
        s := F.Src + (Int64(y) * F.W + x) * 4;
        o[0] := C8(s[0] + b); o[1] := C8(s[1] + g); o[2] := C8(s[2] + r); o[3] := 0;
      end;
  end
  else if F.Id = 'spotlight' then
  begin
    cx := ParF(F.Params, 'x', 0.5) * (F.W - 1);
    cy := ParF(F.Params, 'y', 0.5) * (F.H - 1);
    for y := 0 to F.H - 1 do
      for x := 0 to F.W - 1 do
      begin
        dx := (x - cx) / (F.W * 0.45);
        dy := (y - cy) / (F.H * 0.45);
        d := Sqrt(dx * dx + dy * dy);
        m := 1 - Cl(amt + 0.2) * 0.85 * Smooth01((d - 0.35) / 0.65);
        fv := 1 + (1 - Smooth01(d)) * 0.15;
        s := F.Src + (Int64(y) * F.W + x) * 4;
        SetPx(F.Dst + (Int64(y) * F.W + x) * 4, Round(s[0] * m * fv), Round(s[1] * m * fv), Round(s[2] * m * fv));
      end;
  end
  else if F.Id = 'lightleak' then
  begin
    for y := 0 to F.H - 1 do
      for x := 0 to F.W - 1 do
      begin
        dx := x / Max(1, F.W - 1);
        dy := y / Max(1, F.H - 1);
        fv := FastExp(-dx * 3.2) * (0.65 + 0.35 * FastSin(F.Prog * 14 + dy * 4)) * (0.4 + amt);
        s := F.Src + (Int64(y) * F.W + x) * 4;
        o := F.Dst + (Int64(y) * F.W + x) * 4;
        gv := Round(fv * 255);
        o[2] := 255 - ((255 - s[2]) * (255 - Min(255, gv))) div 255;
        o[1] := 255 - ((255 - s[1]) * (255 - Min(255, gv * 5 div 11))) div 255;
        o[0] := 255 - ((255 - s[0]) * (255 - Min(255, gv div 6))) div 255;
        o[3] := 0;
      end;
  end
  else if F.Id = 'strobe' then
  begin
    if (F.Seed mod 6) = 0 then
      for i := 0 to F.N - 1 do
        SetPx(F.Dst + i * 4, F.Src[i * 4] + (255 - F.Src[i * 4]) * 4 div 5,
          F.Src[i * 4 + 1] + (255 - F.Src[i * 4 + 1]) * 4 div 5, F.Src[i * 4 + 2] + (255 - F.Src[i * 4 + 2]) * 4 div 5)
    else
      CopyPic(F.Src, F.Dst, F.W, F.H);
  end
  else if F.Id = 'flicker' then
  begin
    seed := Cardinal(F.Seed) * 2654435761 + 4711;
    if seed = 0 then seed := 11;
    fv := 1 + (((Rnd(seed) mod 2001) / 1000.0) - 1) * 0.28 * Cl(amt + 0.2);
    k := Round(fv * 256);
    for i := 0 to F.N - 1 do
      SetPx(F.Dst + i * 4, (F.Src[i * 4] * k) shr 8, (F.Src[i * 4 + 1] * k) shr 8, (F.Src[i * 4 + 2] * k) shr 8);
  end
  else
    Result := False;
end;

function PlusStylize(var F: TFx): Boolean;
const
  BAYER: array[0..15] of Integer = (0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5);
var
  t, t2: TBytes;
  x, y, i, c, d, gx, gy, l, rad, dy, dx, best, bin, bs, cxp, cyp, lv: Integer;
  cnt: array[0..7] of Integer;
  sb, sg, sr: array[0..7] of Integer;
  amt, dist, rr: Double;
  o, s, p: PByte;
begin
  Result := True;
  amt := Amount(F, 0.5);

  if F.Id = 'edgedetect' then
  begin
    for y := 0 to F.H - 1 do
      for x := 0 to F.W - 1 do
      begin
        gx := Lm(PixAt(F.Src, F.W, F.H, x + 1, y)) - Lm(PixAt(F.Src, F.W, F.H, x - 1, y));
        gy := Lm(PixAt(F.Src, F.W, F.H, x, y + 1)) - Lm(PixAt(F.Src, F.W, F.H, x, y - 1));
        l := Min(255, Round((Abs(gx) + Abs(gy)) * (1 + amt * 3)));
        SetPx(F.Dst + (Int64(y) * F.W + x) * 4, l, l, l);
      end;
  end
  else if F.Id = 'pencil' then
  begin
    SetLength(t, F.N * 4);
    for i := 0 to F.N - 1 do
    begin
      l := 255 - Lm(F.Src + i * 4);
      t[i * 4] := l; t[i * 4 + 1] := l; t[i * 4 + 2] := l; t[i * 4 + 3] := 0;
    end;
    SetLength(t2, F.N * 4);
    BoxBlurPic(@t[0], @t2[0], F.W, F.H, Max(2, Round(Min(F.W, F.H) / 50 * (0.5 + amt))));
    for i := 0 to F.N - 1 do
    begin
      l := Lm(F.Src + i * 4);
      d := t2[i * 4];
      if d >= 255 then l := 255 else l := Min(255, l * 255 div (255 - d));
      SetPx(F.Dst + i * 4, l, l, l);
    end;
  end
  else if F.Id = 'cartoon' then
  begin
    SetLength(t, F.N * 4);
    BoxBlurPic(F.Src, @t[0], F.W, F.H, 2);
    for y := 0 to F.H - 1 do
      for x := 0 to F.W - 1 do
      begin
        gx := Lm(PixAt(@t[0], F.W, F.H, x + 1, y)) - Lm(PixAt(@t[0], F.W, F.H, x - 1, y));
        gy := Lm(PixAt(@t[0], F.W, F.H, x, y + 1)) - Lm(PixAt(@t[0], F.W, F.H, x, y - 1));
        o := F.Dst + (Int64(y) * F.W + x) * 4;
        s := PixAt(@t[0], F.W, F.H, x, y);
        if Abs(gx) + Abs(gy) > 38 then
          SetPx(o, 0, 0, 0)
        else
          SetPx(o, (s[0] div 43) * 51 + 12, (s[1] div 43) * 51 + 12, (s[2] div 43) * 51 + 12);
      end;
  end
  else if F.Id = 'oilpaint' then
  begin
    rad := Max(2, Min(3, Round(1 + amt * 3)));
    for y := 0 to F.H - 1 do
      for x := 0 to F.W - 1 do
      begin
        FillChar(cnt, SizeOf(cnt), 0);
        FillChar(sb, SizeOf(sb), 0);
        FillChar(sg, SizeOf(sg), 0);
        FillChar(sr, SizeOf(sr), 0);
        for dy := -rad to rad do
          for dx := -rad to rad do
          begin
            p := PixAt(F.Src, F.W, F.H, x + dx, y + dy);
            bin := Lm(p) shr 5;
            Inc(cnt[bin]);
            Inc(sb[bin], p[0]); Inc(sg[bin], p[1]); Inc(sr[bin], p[2]);
          end;
        best := 0;
        for i := 1 to 7 do
          if cnt[i] > cnt[best] then best := i;
        SetPx(F.Dst + (Int64(y) * F.W + x) * 4, sb[best] div cnt[best], sg[best] div cnt[best], sr[best] div cnt[best]);
      end;
  end
  else if (F.Id = 'abstraction') or (F.Id = 'watercolor') then
  begin
    SetLength(t, F.N * 4);
    BoxBlurPic(F.Src, @t[0], F.W, F.H, Max(2, Round(Min(F.W, F.H) / 120 * (1 + amt * 3))));
    BoxBlurPic(@t[0], @t[0], F.W, F.H, Max(2, Round(Min(F.W, F.H) / 120 * (1 + amt * 3))));
    lv := 6;
    for y := 0 to F.H - 1 do
      for x := 0 to F.W - 1 do
      begin
        s := @t[(y * F.W + x) * 4];
        o := F.Dst + (Int64(y) * F.W + x) * 4;
        if F.Id = 'abstraction' then
          SetPx(o, (s[0] * lv div 256) * 255 div (lv - 1), (s[1] * lv div 256) * 255 div (lv - 1),
            (s[2] * lv div 256) * 255 div (lv - 1))
        else
        begin
          { soft washes with a pale paper tone and faint darker edges }
          gx := Lm(PixAt(@t[0], F.W, F.H, x + 1, y)) - Lm(PixAt(@t[0], F.W, F.H, x - 1, y));
          gy := Lm(PixAt(@t[0], F.W, F.H, x, y + 1)) - Lm(PixAt(@t[0], F.W, F.H, x, y - 1));
          d := Min(60, (Abs(gx) + Abs(gy)) * 2);
          SetPx(o, (s[0] * 7 + 255) div 8 - d, (s[1] * 7 + 255) div 8 - d, (s[2] * 7 + 255) div 8 - d);
        end;
      end;
  end
  else if F.Id = 'halftone' then
  begin
    bs := Max(6, Round(Min(F.W, F.H) / 60 * (1 + amt)));
    for y := 0 to F.H - 1 do
      for x := 0 to F.W - 1 do
      begin
        cxp := (x div bs) * bs + bs div 2;
        cyp := (y div bs) * bs + bs div 2;
        s := PixAt(F.Src, F.W, F.H, cxp, cyp);
        rr := bs * 0.62 * Sqrt(Lm(s) / 255 + 0.08);
        dist := Sqrt(Sqr(x - cxp) + Sqr(y - cyp));
        o := F.Dst + (Int64(y) * F.W + x) * 4;
        if dist <= rr - 0.5 then SetPx(o, s[0], s[1], s[2])
        else if dist < rr + 0.5 then
          SetPx(o, Round(s[0] * (rr + 0.5 - dist)), Round(s[1] * (rr + 0.5 - dist)), Round(s[2] * (rr + 0.5 - dist)))
        else SetPx(o, 0, 0, 0);
      end;
  end
  else if F.Id = 'anaglyph' then
  begin
    d := Max(2, Round(Cl(amt) * F.W / 60 + 1));
    for y := 0 to F.H - 1 do
      for x := 0 to F.W - 1 do
      begin
        o := F.Dst + (Int64(y) * F.W + x) * 4;
        o[2] := PixAt(F.Src, F.W, F.H, x - d, y)[2];
        o[1] := PixAt(F.Src, F.W, F.H, x + d, y)[1];
        o[0] := PixAt(F.Src, F.W, F.H, x + d, y)[0];
        o[3] := 0;
      end;
  end
  else if F.Id = 'xray' then
  begin
    for y := 0 to F.H - 1 do
      for x := 0 to F.W - 1 do
      begin
        gx := Lm(PixAt(F.Src, F.W, F.H, x + 1, y)) - Lm(PixAt(F.Src, F.W, F.H, x - 1, y));
        gy := Lm(PixAt(F.Src, F.W, F.H, x, y + 1)) - Lm(PixAt(F.Src, F.W, F.H, x, y - 1));
        l := Min(255, 255 - Lm(F.Src + (Int64(y) * F.W + x) * 4) + (Abs(gx) + Abs(gy)));
        SetPx(F.Dst + (Int64(y) * F.W + x) * 4, l, l * 9 div 10, l * 6 div 10);
      end;
  end
  else if F.Id = 'dither' then
  begin
    for y := 0 to F.H - 1 do
      for x := 0 to F.W - 1 do
      begin
        s := F.Src + (Int64(y) * F.W + x) * 4;
        d := BAYER[(y and 3) * 4 + (x and 3)] * 16 + 8;
        o := F.Dst + (Int64(y) * F.W + x) * 4;
        for c := 0 to 2 do
          if s[c] > d then o[c] := 255 else o[c] := 0;
        o[3] := 0;
      end;
  end
  else if (F.Id = 'shrink') or (F.Id = 'grow') then
  begin
    SetLength(t, F.N * 4);
    CopyPic(F.Src, @t[0], F.W, F.H);
    rad := Max(1, Round(Cl(amt) * 3 + 0.5));
    for y := 0 to F.H - 1 do
      for x := 0 to F.W - 1 do
      begin
        o := F.Dst + (Int64(y) * F.W + x) * 4;
        for c := 0 to 2 do
        begin
          best := t[(y * F.W + x) * 4 + c];
          for dy := -rad to rad do
            for dx := -rad to rad do
            begin
              d := PixAt(@t[0], F.W, F.H, x + dx, y + dy)[c];
              if F.Id = 'shrink' then begin if d < best then best := d; end
              else if d > best then best := d;
            end;
          o[c] := best;
        end;
        o[3] := 0;
      end;
  end
  else if F.Id = 'jpegdamage' then
  begin
    bs := 8 + Round(Cl(amt) * 8);
    for y := 0 to F.H - 1 do
      for x := 0 to F.W - 1 do
      begin
        { block mean from the block's centre pixel plus a coarsely quantised residual }
        p := PixAt(F.Src, F.W, F.H, (x div bs) * bs + bs div 2, (y div bs) * bs + bs div 2);
        s := F.Src + (Int64(y) * F.W + x) * 4;
        o := F.Dst + (Int64(y) * F.W + x) * 4;
        for c := 0 to 2 do
          o[c] := C8(p[c] + (((s[c] - p[c]) * 4 div 11) div 16) * 16);
        o[3] := 0;
      end;
  end
  else
    Result := False;
end;


function PlusTexture(var F: TFx): Boolean;
var
  i, x, y, v, l, cxp: Integer;
  amt, fv, nx, ny, d, e: Double;
  s, o: PByte;
  seed: Cardinal;

  procedure Damage(AStrength: Double);
  var
    j, cc, col, yy, ln, px, py: Integer;
  begin
    { vertical scratches }
    for j := 1 to 3 do
      if Hs(F.Seed, j, 5) < 0.5 * AStrength + 0.15 then
      begin
        col := Trunc(Hs(F.Seed div 2, j, 9) * (F.W - 1));
        for yy := 0 to F.H - 1 do
        begin
          o := F.Dst + (Int64(yy) * F.W + col) * 4;
          for cc := 0 to 2 do o[cc] := C8(o[cc] + 70);
        end;
      end;
    { dust specks }
    for j := 1 to 10 do
    begin
      col := Trunc(Hs(F.Seed, j, 21) * (F.W - 1));
      yy := Trunc(Hs(F.Seed, j, 33) * (F.H - 1));
      ln := 1 + Trunc(Hs(F.Seed, j, 47) * Max(1.0, F.W / 160));
      for px := col to Min(F.W - 1, col + ln) do
        for py := yy to Min(F.H - 1, yy + ln) do
        begin
          o := F.Dst + (Int64(py) * F.W + px) * 4;
          if Hs(F.Seed, j, 3) < 0.5 then cc := 20 else cc := 235;
          o[0] := cc; o[1] := cc; o[2] := cc;
        end;
    end;
  end;

begin
  Result := True;
  amt := Amount(F, 0.5);
  seed := Cardinal(F.Seed) * 2654435761 + 9001;
  if seed = 0 then seed := 13;

  if F.Id = 'noise' then
  begin
    v := Round(amt * 80);
    for i := 0 to F.N - 1 do
    begin
      s := F.Src + i * 4;
      SetPx(F.Dst + i * 4, s[0] + Integer(Rnd(seed) mod Cardinal(2 * v + 1)) - v,
        s[1] + Integer(Rnd(seed) mod Cardinal(2 * v + 1)) - v,
        s[2] + Integer(Rnd(seed) mod Cardinal(2 * v + 1)) - v);
    end;
  end
  else if F.Id = 'filmdamage' then
  begin
    fv := 1 + (Hs(F.Seed, 1, 77) - 0.5) * 0.12;
    for i := 0 to F.N - 1 do
      SetPx(F.Dst + i * 4, Round(F.Src[i * 4] * fv), Round(F.Src[i * 4 + 1] * fv), Round(F.Src[i * 4 + 2] * fv));
    Damage(amt);
  end
  else if F.Id = 'oldfilm' then
  begin
    fv := 1 + (Hs(F.Seed, 1, 77) - 0.5) * 0.1;
    for y := 0 to F.H - 1 do
    begin
      ny := (y - (F.H - 1) / 2) / (F.H / 2);
      for x := 0 to F.W - 1 do
      begin
        nx := (x - (F.W - 1) / 2) / (F.W / 2);
        d := 1 - 0.55 * Smooth01((Sqrt(nx * nx + ny * ny) / 1.414 - 0.3) / 0.7);
        s := F.Src + (Int64(y) * F.W + x) * 4;
        l := Round(Lm(s) * fv * d) + Integer(Rnd(seed) mod 31) - 15;
        SetPx(F.Dst + (Int64(y) * F.W + x) * 4, Round(l * 0.55), Round(l * 0.82), l);
      end;
    end;
    Damage(amt + 0.3);
  end
  else if F.Id = 'canvas' then
  begin
    for y := 0 to F.H - 1 do
      for x := 0 to F.W - 1 do
      begin
        e := 1 - 0.22 * Cl(amt + 0.3) * (0.5 + 0.25 * FastSin(x * 1.4) + 0.25 * FastSin(y * 1.4));
        s := F.Src + (Int64(y) * F.W + x) * 4;
        SetPx(F.Dst + (Int64(y) * F.W + x) * 4, Round(s[0] * e), Round(s[1] * e), Round(s[2] * e));
      end;
  end
  else if F.Id = 'crt' then
  begin
    for y := 0 to F.H - 1 do
      for x := 0 to F.W - 1 do
      begin
        nx := (x - (F.W - 1) / 2) / (F.W / 2);
        ny := (y - (F.H - 1) / 2) / (F.H / 2);
        d := 1 + 0.10 * (nx * nx + ny * ny);
        o := F.Dst + (Int64(y) * F.W + x) * 4;
        if (Abs(nx * d) > 1) or (Abs(ny * d) > 1) then
          SetPx(o, 0, 0, 0)
        else
        begin
          s := PixAt(F.Src, F.W, F.H, Round((F.W - 1) / 2 + nx * d * F.W / 2),
            Round((F.H - 1) / 2 + ny * d * F.H / 2));
          e := 1;
          if (y and 1) = 1 then e := 0.72;
          e := e * (1 - 0.35 * Smooth01((Sqrt(nx * nx + ny * ny) - 0.6) / 0.9));
          cxp := x mod 3;
          SetPx(o, Round(s[0] * e * IfThen(cxp = 2, 1.0, 0.8)), Round(s[1] * e * IfThen(cxp = 1, 1.0, 0.8)),
            Round(s[2] * e * IfThen(cxp = 0, 1.0, 0.8)));
        end;
      end;
  end
  else
    Result := False;
end;

function PlusTransform(var F: TFx): Boolean;
var
  x, y, b, g, r: Integer;
  amt, sc, ang, cx, u, sx, sy: Double;
  s: PByte;
begin
  Result := True;
  amt := Amount(F, 0.25);
  cx := (F.W - 1) / 2;
  if F.Id = 'fliph' then
  begin
    for y := 0 to F.H - 1 do
      for x := 0 to F.W - 1 do
        PCardinal(F.Dst + (Int64(y) * F.W + x) * 4)^ := PCardinal(F.Src + (Int64(y) * F.W + (F.W - 1 - x)) * 4)^;
  end
  else if F.Id = 'mirrorv' then
  begin
    for y := 0 to F.H - 1 do
    begin
      if y < F.H div 2 then sy := y else sy := F.H - 1 - y;
      Move((F.Src + Trunc(sy) * Int64(F.W) * 4)^, (F.Dst + Int64(y) * F.W * 4)^, F.W * 4);
    end;
  end
  else if F.Id = 'mirror4' then
  begin
    for y := 0 to F.H - 1 do
      for x := 0 to F.W - 1 do
      begin
        if x < F.W div 2 then sx := x else sx := F.W - 1 - x;
        if y < F.H div 2 then sy := y else sy := F.H - 1 - y;
        PCardinal(F.Dst + (Int64(y) * F.W + x) * 4)^ := PCardinal(F.Src + (Int64(Trunc(sy)) * F.W + Trunc(sx)) * 4)^;
      end;
  end
  else if F.Id = 'kaleido' then
    WarpKind(F.Src, F.Dst, F.W, F.H, WK_KALEIDO, 1, F.Prog)
  else if F.Id = 'tile' then
  begin
    for y := 0 to F.H - 1 do
      for x := 0 to F.W - 1 do
      begin
        s := PixAt(F.Src, F.W, F.H, (x * 2) mod F.W, (y * 2) mod F.H);
        PCardinal(F.Dst + (Int64(y) * F.W + x) * 4)^ := PCardinal(s)^;
      end;
  end
  else if (F.Id = 'rot90') or (F.Id = 'rot270') or (F.Id = 'rot180') then
  begin
    if F.Id = 'rot180' then
      RotScale(F.Src, F.Dst, F.W, F.H, 1, Pi, 0, 0, False)
    else
    begin
      sc := Min(F.W / F.H, F.H / F.W);
      if F.Id = 'rot90' then ang := Pi / 2 else ang := -Pi / 2;
      RotScale(F.Src, F.Dst, F.W, F.H, sc, ang, 0, 0, False);
    end;
  end
  else if F.Id = 'zoomcrop' then
    RotScale(F.Src, F.Dst, F.W, F.H, 1 + amt, 0, 0, 0, True)
  else if F.Id = 'keystone' then
  begin
    for y := 0 to F.H - 1 do
    begin
      u := 1 - Cl(amt + 0.1) * 0.5 * (1 - y / Max(1, F.H - 1));
      for x := 0 to F.W - 1 do
      begin
        sx := cx + (x - cx) / u;
        if (sx < 0) or (sx > F.W - 1) then
          PCardinal(F.Dst + (Int64(y) * F.W + x) * 4)^ := 0
        else
        begin
          Bil(F.Src, F.W, F.H, sx, y, b, g, r);
          SetPx(F.Dst + (Int64(y) * F.W + x) * 4, b, g, r);
        end;
      end;
    end;
  end
  else
    Result := False;
end;

function PlusWarp(var F: TFx): Boolean;
var
  kind: Integer;
begin
  Result := True;
  if F.Id = 'bulge' then kind := WK_BULGE
  else if F.Id = 'pinch' then kind := WK_PINCH
  else if F.Id = 'barrel' then kind := WK_BARREL
  else if F.Id = 'fisheye' then kind := WK_FISHEYE
  else if F.Id = 'swirl' then kind := WK_SWIRL
  else if F.Id = 'vortex' then kind := WK_VORTEX
  else if F.Id = 'ripple' then kind := WK_RIPPLE
  else if F.Id = 'wave' then kind := WK_WAVE
  else if F.Id = 'magnify' then kind := WK_MAGNIFY
  else if F.Id = 'heathaze' then kind := WK_HAZE
  else if F.Id = 'underwater' then kind := WK_WATER
  else
    Exit(False);
  WarpKind(F.Src, F.Dst, F.W, F.H, kind, Amount(F, 0.5), F.Prog);
end;

function PlusGlitch(var F: TFx): Boolean;
var
  x, y, i, j, ofs, bw, bh, bx, by, sx, sy, k, n, band: Integer;
  amt, cx, cy, dx, dy, kk: Double;
  s, o: PByte;
  seed: Cardinal;
begin
  Result := True;
  amt := Amount(F, 0.5);
  seed := Cardinal(F.Seed) * 2654435761 + 424243;
  if seed = 0 then seed := 17;
  cx := (F.W - 1) / 2;
  cy := (F.H - 1) / 2;

  if F.Id = 'chromatic' then
  begin
    kk := Cl(amt) * 0.03 + 0.004;
    for y := 0 to F.H - 1 do
      for x := 0 to F.W - 1 do
      begin
        dx := x - cx;
        dy := y - cy;
        o := F.Dst + (Int64(y) * F.W + x) * 4;
        o[2] := PixAt(F.Src, F.W, F.H, Round(cx + dx * (1 + kk)), Round(cy + dy * (1 + kk)))[2];
        o[1] := PixAt(F.Src, F.W, F.H, x, y)[1];
        o[0] := PixAt(F.Src, F.W, F.H, Round(cx + dx * (1 - kk)), Round(cy + dy * (1 - kk)))[0];
        o[3] := 0;
      end;
  end
  else if F.Id = 'vhs' then
  begin
    band := Round(Cl(F.Prog) * F.H);
    i := Max(2, F.W div 160);
    for y := 0 to F.H - 1 do
    begin
      ofs := Round(FastSin(y * 0.07 + F.Seed * 0.3) * amt * 3);
      if Abs(y - band) < Max(3, F.H div 25) then
        ofs := ofs + Round(amt * F.W / 18) * (1 - 2 * (F.Seed and 1));
      for x := 0 to F.W - 1 do
      begin
        o := F.Dst + (Int64(y) * F.W + x) * 4;
        o[2] := PixAt(F.Src, F.W, F.H, x + ofs + i, y)[2];
        o[1] := PixAt(F.Src, F.W, F.H, x + ofs, y)[1];
        o[0] := PixAt(F.Src, F.W, F.H, x + ofs - i, y)[0];
        o[3] := 0;
        if (y and 1) = 1 then
        begin
          o[0] := o[0] * 85 div 100; o[1] := o[1] * 85 div 100; o[2] := o[2] * 85 div 100;
        end;
        if (Rnd(seed) and 255) < 3 then
        begin
          o[0] := 230; o[1] := 230; o[2] := 230;
        end;
      end;
    end;
  end
  else if F.Id = 'blockglitch' then
  begin
    CopyPic(F.Src, F.Dst, F.W, F.H);
    n := 6 + Round(Cl(amt) * 14);
    for k := 1 to n do
    begin
      bw := 4 + Integer(Rnd(seed) mod Cardinal(Max(1, F.W div 4)));
      bh := 2 + Integer(Rnd(seed) mod Cardinal(Max(1, F.H div 8)));
      bx := Integer(Rnd(seed) mod Cardinal(F.W));
      by := Integer(Rnd(seed) mod Cardinal(F.H));
      sx := Integer(Rnd(seed) mod Cardinal(Max(1, F.W div 2))) - F.W div 4;
      sy := Integer(Rnd(seed) mod Cardinal(Max(1, F.H div 8))) - F.H div 16;
      j := Integer(Rnd(seed) mod 4);
      for y := by to Min(F.H - 1, by + bh) do
        for x := bx to Min(F.W - 1, bx + bw) do
        begin
          s := PixAt(F.Src, F.W, F.H, x + sx, y + sy);
          o := F.Dst + (Int64(y) * F.W + x) * 4;
          case j of
            0: begin o[0] := s[0]; o[1] := s[1]; o[2] := s[2]; end;
            1: begin o[0] := s[2]; o[1] := s[0]; o[2] := s[1]; end;
            2: begin o[0] := 255 - s[0]; o[1] := 255 - s[1]; o[2] := 255 - s[2]; end;
          else
            begin o[0] := s[1]; o[1] := s[1]; o[2] := s[1]; end;
          end;
        end;
    end;
  end
  else if F.Id = 'tvstatic' then
  begin
    kk := Cl(amt) * (0.35 + 0.65 * FastSin(Cl(F.Prog) * Pi));
    j := Round(kk * 256);
    for i := 0 to F.N - 1 do
    begin
      k := Integer(Rnd(seed) and 255);
      s := F.Src + i * 4;
      F.Dst[i * 4] := (s[0] * (256 - j) + k * j) shr 8;
      F.Dst[i * 4 + 1] := (s[1] * (256 - j) + k * j) shr 8;
      F.Dst[i * 4 + 2] := (s[2] * (256 - j) + k * j) shr 8;
      F.Dst[i * 4 + 3] := 0;
    end;
  end
  else if F.Id = 'interlace' then
  begin
    ofs := Max(1, Round(Cl(amt) * F.W / 40));
    for y := 0 to F.H - 1 do
      for x := 0 to F.W - 1 do
      begin
        if (y and 1) = 1 then s := PixAt(F.Src, F.W, F.H, x - ofs, y)
        else s := PixAt(F.Src, F.W, F.H, x + ofs, y);
        PCardinal(F.Dst + (Int64(y) * F.W + x) * 4)^ := PCardinal(s)^;
        F.Dst[(Int64(y) * F.W + x) * 4 + 3] := 0;
      end;
  end
  else
    Result := False;
end;





function PlusRevival(var F: TFx): Boolean;
var
  t, t2: TBytes;
  x, y, i, c, dx, dy, n, d, l, sg, k, hv, cb, cr: Integer;
  amt, wsum, sumB, sumG, sumR, wgt, a, tr: Double;
  s, o: PByte;
  v: array[0..8] of Integer;
  rw: array[0..255] of Double;
  hist: array[0..255] of Integer;
  skin: Boolean;
  seed: Cardinal;
begin
  Result := True;
  amt := Amount(F, 0.5);
  seed := Cardinal(F.Seed) * 2654435761 + 5557;
  if seed = 0 then seed := 19;

  if F.Id = 'denoise' then
  begin
    sg := 12 + Round(Cl(amt) * 40);
    for i := 0 to 255 do rw[i] := FastExp(-Sqr(i) / (2.0 * sg * sg));
    for y := 0 to F.H - 1 do
      for x := 0 to F.W - 1 do
      begin
        l := Lm(F.Src + (Int64(y) * F.W + x) * 4);
        wsum := 0; sumB := 0; sumG := 0; sumR := 0;
        for dy := -2 to 2 do
          for dx := -2 to 2 do
          begin
            o := PixAt(F.Src, F.W, F.H, x + dx, y + dy);
            wgt := rw[Abs(Lm(o) - l)] / (1 + Abs(dx) + Abs(dy));
            wsum := wsum + wgt;
            sumB := sumB + wgt * o[0];
            sumG := sumG + wgt * o[1];
            sumR := sumR + wgt * o[2];
          end;
        SetPx(F.Dst + (Int64(y) * F.W + x) * 4, Round(sumB / wsum), Round(sumG / wsum), Round(sumR / wsum));
      end;
  end
  else if (F.Id = 'despeckle') or (F.Id = 'deadpixel') then
  begin
    for y := 0 to F.H - 1 do
      for x := 0 to F.W - 1 do
      begin
        s := F.Src + (Int64(y) * F.W + x) * 4;
        o := F.Dst + (Int64(y) * F.W + x) * 4;
        for c := 0 to 2 do
        begin
          n := 0;
          for dy := -1 to 1 do
            for dx := -1 to 1 do
            begin
              d := PixAt(F.Src, F.W, F.H, x + dx, y + dy)[c];
              k := n;
              while (k > 0) and (v[k - 1] > d) do
              begin
                v[k] := v[k - 1];
                Dec(k);
              end;
              v[k] := d;
              Inc(n);
            end;
          if (F.Id = 'deadpixel') and (Abs(s[c] - v[4]) < 60) then o[c] := s[c]
          else o[c] := v[4];
        end;
        o[3] := 0;
      end;
  end
  else if F.Id = 'deband' then
  begin
    SetLength(t, F.N * 4);
    BoxBlurPic(F.Src, @t[0], F.W, F.H, 4);
    for i := 0 to F.N - 1 do
    begin
      s := F.Src + i * 4;
      if (Abs(s[0] - t[i * 4]) < 7) and (Abs(s[1] - t[i * 4 + 1]) < 7) and (Abs(s[2] - t[i * 4 + 2]) < 7) then
        SetPx(F.Dst + i * 4, t[i * 4] + Integer(Rnd(seed) mod 3) - 1, t[i * 4 + 1] + Integer(Rnd(seed) mod 3) - 1,
          t[i * 4 + 2] + Integer(Rnd(seed) mod 3) - 1)
      else
        SetPx(F.Dst + i * 4, s[0], s[1], s[2]);
    end;
  end
  else if F.Id = 'dehaze' then
  begin
    SetLength(t, F.N * 4);
    SetLength(t2, F.N * 4);
    FillChar(hist, SizeOf(hist), 0);
    for i := 0 to F.N - 1 do
    begin
      s := F.Src + i * 4;
      d := Min(s[0], Min(s[1], s[2]));
      t[i * 4] := d; t[i * 4 + 1] := d; t[i * 4 + 2] := d; t[i * 4 + 3] := 0;
      Inc(hist[Max(s[0], Max(s[1], s[2]))]);
    end;
    a := 255;
    n := 0;
    for i := 255 downto 0 do
    begin
      n := n + hist[i];
      if n > F.N div 100 then
      begin
        a := Max(160, i);
        Break;
      end;
    end;
    BoxBlurPic(@t[0], @t2[0], F.W, F.H, Max(3, Min(F.W, F.H) div 40));
    for i := 0 to F.N - 1 do
    begin
      tr := Max(0.2, 1 - Cl(amt + 0.2) * 0.95 * t2[i * 4] / a);
      s := F.Src + i * 4;
      SetPx(F.Dst + i * 4, Round((s[0] - a) / tr + a), Round((s[1] - a) / tr + a), Round((s[2] - a) / tr + a));
    end;
  end
  else if F.Id = 'softskin' then
  begin
    SetLength(t, F.N * 4);
    GaussBlurPic(F.Src, @t[0], F.W, F.H, Max(2, Min(F.W, F.H) div 90));
    for i := 0 to F.N - 1 do
    begin
      s := F.Src + i * 4;
      cb := 128 + ((-43 * s[2] - 85 * s[1] + 128 * s[0]) div 256);
      cr := 128 + ((128 * s[2] - 107 * s[1] - 21 * s[0]) div 256);
      skin := (cb >= 77) and (cb <= 127) and (cr >= 133) and (cr <= 173) and (Lm(s) > 40);
      if skin then hv := Round(Cl(amt + 0.3) * 256) else hv := 0;
      for c := 0 to 2 do
        F.Dst[i * 4 + c] := (s[c] * (256 - hv) + t[i * 4 + c] * hv) shr 8;
      F.Dst[i * 4 + 3] := 0;
    end;
  end
  else if F.Id = 'glamour' then
  begin
    SetLength(t, F.N * 4);
    GaussBlurPic(F.Src, @t[0], F.W, F.H, Max(2, Min(F.W, F.H) div 45));
    for i := 0 to F.N - 1 do
    begin
      s := F.Src + i * 4;
      SetPx(F.Dst + i * 4, (s[0] + t[i * 4]) div 2 + Round(8 * amt), (s[1] + t[i * 4 + 1]) div 2 + Round(10 * amt),
        (s[2] + t[i * 4 + 2]) div 2 + Round(16 * amt));
    end;
  end
  else
    Result := False;
end;

function PlusGenerate(var F: TFx): Boolean;
const
  BARS: array[0..6] of Integer = ($C0C0C0, $C0C000, $00C0C0, $00C000, $C000C0, $C00000, $0000C0);
var
  x, y, i, bar, cell, op, tb, tg, tr, th, ix, iy, oct: Integer;
  amt, u, v, h, n, fq, ampl: Double;
  col: Cardinal;
  s, o: PByte;
  line: Boolean;

  procedure Mix(AOut: PByte; AB, AG, AR: Integer);
  begin
    AOut[0] := (AOut[0] * (256 - op) + AB * op) shr 8;
    AOut[1] := (AOut[1] * (256 - op) + AG * op) shr 8;
    AOut[2] := (AOut[2] * (256 - op) + AR * op) shr 8;
    AOut[3] := 0;
  end;

begin
  Result := True;
  amt := Amount(F, 1);
  op := Round(Cl(amt) * 256);
  if (F.Id = 'letterbox') or (F.Id = 'border') or (F.Id = 'gradient') or (F.Id = 'grid') then
    CopyPic(F.Src, F.Dst, F.W, F.H);

  if F.Id = 'letterbox' then
  begin
    th := Round(Max(0.0, (F.H - F.W / ParF(F.Params, 'ratio', 2.39)) / 2));
    for y := 0 to F.H - 1 do
      if (y < th) or (y >= F.H - th) then
        for x := 0 to F.W - 1 do SetPx(F.Dst + (Int64(y) * F.W + x) * 4, 0, 0, 0);
  end
  else if F.Id = 'border' then
  begin
    col := Cardinal(StrToIntDef('$' + ParS(F.Params, 'color', 'FFFFFF'), $FFFFFF));
    th := Max(4, Round(Min(F.W, F.H) * 0.04 * (0.5 + Amount(F, 0.5))));
    op := 256;
    for y := 0 to F.H - 1 do
      for x := 0 to F.W - 1 do
        if (x < th) or (y < th) or (x >= F.W - th) or (y >= F.H - th) then
          Mix(F.Dst + (Int64(y) * F.W + x) * 4, col and $FF, (col shr 8) and $FF, (col shr 16) and $FF);
  end
  else if F.Id = 'gradient' then
  begin
    op := Round(Cl(Amount(F, 0.35)) * 256);
    for y := 0 to F.H - 1 do
    begin
      v := y / Max(1, F.H - 1);
      tr := Round(255 * (1 - v) + 42 * v);
      tg := Round(122 * (1 - v) + 27 * v);
      tb := Round(24 * (1 - v) + 90 * v);
      for x := 0 to F.W - 1 do Mix(F.Dst + (Int64(y) * F.W + x) * 4, tb, tg, tr);
    end;
  end
  else if F.Id = 'grid' then
  begin
    cell := Max(8, Min(F.W, F.H) div 8);
    op := 110;
    for y := 0 to F.H - 1 do
      for x := 0 to F.W - 1 do
      begin
        line := ((x mod cell) = 0) or ((y mod cell) = 0) or (x = F.W div 3) or (x = F.W * 2 div 3) or
          (y = F.H div 3) or (y = F.H * 2 div 3);
        if line then Mix(F.Dst + (Int64(y) * F.W + x) * 4, 255, 255, 255);
      end;
  end
  else if F.Id = 'colorbars' then
  begin
    for y := 0 to F.H - 1 do
      for x := 0 to F.W - 1 do
      begin
        bar := x * 7 div F.W;
        if y < F.H * 2 div 3 then
          i := BARS[bar]
        else if y < F.H * 3 div 4 then
        begin
          case bar of
            0: i := $0000C0;
            2: i := $C000C0;
            4: i := $00C0C0;
            6: i := $C0C0C0;
          else
            i := $101010;
          end;
        end
        else
        begin
          if bar < 2 then i := $00214C
          else if bar < 4 then i := $FFFFFF
          else if bar < 5 then i := $32006A
          else i := $101010;
        end;
        SetPx(F.Dst + (Int64(y) * F.W + x) * 4, i and $FF, (i shr 8) and $FF, (i shr 16) and $FF);
      end;
  end
  else if F.Id = 'checkerboard' then
  begin
    cell := Max(8, Min(F.W, F.H) div 12);
    for y := 0 to F.H - 1 do
      for x := 0 to F.W - 1 do
      begin
        if (((x div cell) + (y div cell)) and 1) = 0 then i := 200 else i := 120;
        SetPx(F.Dst + (Int64(y) * F.W + x) * 4, i, i, i);
      end;
  end
  else if F.Id = 'solid' then
  begin
    col := Cardinal(StrToIntDef('$' + ParS(F.Params, 'color', '1E1E1E'), $1E1E1E));
    for i := 0 to F.N - 1 do
      SetPx(F.Dst + i * 4, col and $FF, (col shr 8) and $FF, (col shr 16) and $FF);
  end
  else if F.Id = 'fastnoise' then
  begin
    for y := 0 to F.H - 1 do
      for x := 0 to F.W - 1 do
      begin
        n := 0;
        fq := 4 / Max(F.W, F.H);
        ampl := 0.5;
        for oct := 0 to 3 do
        begin
          u := x * fq + F.Prog * 3 * (oct + 1) * 0.3;
          v := y * fq + oct * 17.3;
          ix := Floor(u);
          iy := Floor(v);
          h := Smooth01(u - ix);
          n := n + ampl * ((Hs(ix, iy, oct) * (1 - h) + Hs(ix + 1, iy, oct) * h) * (1 - Smooth01(v - iy)) +
            (Hs(ix, iy + 1, oct) * (1 - h) + Hs(ix + 1, iy + 1, oct) * h) * Smooth01(v - iy));
          fq := fq * 2;
          ampl := ampl * 0.5;
        end;
        i := Round(Cl(n * 1.15) * 255);
        s := F.Src + (Int64(y) * F.W + x) * 4;
        o := F.Dst + (Int64(y) * F.W + x) * 4;
        o[0] := (s[0] * (256 - op) + i * op) shr 8;
        o[1] := (s[1] * (256 - op) + i * op) shr 8;
        o[2] := (s[2] * (256 - op) + i * op) shr 8;
        o[3] := 0;
      end;
  end
  else
    Result := False;
end;

function PlusCamera(var F: TFx): Boolean;
var
  amt, sc, ox, oy, rot, t, p: Double;
  seed: Cardinal;
begin
  Result := True;
  amt := Amount(F, 0.5);
  p := Cl(F.Prog);
  t := F.Seed * 0.2;
  seed := Cardinal(F.Seed) * 2654435761 + 8123;
  if seed = 0 then seed := 23;
  if F.Id = 'slowzoomout' then
    RotScale(F.Src, F.Dst, F.W, F.H, 1 + Amount(F, 0.25) * (1 - p), 0, 0, 0, True)
  else if F.Id = 'panleft' then
    RotScale(F.Src, F.Dst, F.W, F.H, 1.2, 0, (p - 0.5) * 0.16, 0, True)
  else if F.Id = 'panright' then
    RotScale(F.Src, F.Dst, F.W, F.H, 1.2, 0, -(p - 0.5) * 0.16, 0, True)
  else if F.Id = 'panup' then
    RotScale(F.Src, F.Dst, F.W, F.H, 1.2, 0, 0, (p - 0.5) * 0.16, True)
  else if F.Id = 'pandown' then
    RotScale(F.Src, F.Dst, F.W, F.H, 1.2, 0, 0, -(p - 0.5) * 0.16, True)
  else if F.Id = 'kenburns' then
  begin
    sc := 1 + 0.3 * p;
    ox := (1 - 1 / sc) / 2 * (p * 2 - 1) * 0.9;
    oy := -(1 - 1 / sc) / 2 * (p * 2 - 1) * 0.5;
    RotScale(F.Src, F.Dst, F.W, F.H, sc, 0, ox, oy, True);
  end
  else if F.Id = 'dutch' then
  begin
    rot := (amt * 16) * Pi / 180;
    sc := FastCos(Abs(rot)) + Max(F.W / F.H, F.H / F.W) * FastSin(Abs(rot));
    RotScale(F.Src, F.Dst, F.W, F.H, sc, rot, 0, 0, True);
  end
  else if F.Id = 'handheld' then
  begin
    ox := amt * 0.012 * (FastSin(t * 1.3) + 0.6 * FastSin(t * 2.7));
    oy := amt * 0.010 * (FastSin(t * 1.1 + 1) + 0.6 * FastSin(t * 3.1));
    rot := amt * 0.007 * FastSin(t * 0.9);
    RotScale(F.Src, F.Dst, F.W, F.H, 1.07, rot, ox, oy, True);
  end
  else if F.Id = 'bounce' then
    RotScale(F.Src, F.Dst, F.W, F.H, 1.08, 0, 0, amt * 0.05 * (Abs(FastSin(p * Pi * 4)) - 0.5), True)
  else if F.Id = 'earthquake' then
  begin
    ox := ((Rnd(seed) mod 2001) / 1000.0 - 1) * amt * 0.03;
    oy := ((Rnd(seed) mod 2001) / 1000.0 - 1) * amt * 0.03;
    rot := ((Rnd(seed) mod 2001) / 1000.0 - 1) * amt * 0.035;
    RotScale(F.Src, F.Dst, F.W, F.H, 1.12, rot, ox, oy, True);
  end
  else
    Result := False;
end;




function VfxPlusFilter(const AId, AParams: string; AProgress: Double;
  ASrc, ADst: PByte; W, H, ASeed: Integer): Boolean;
var
  f: TFx;
begin
  Result := False;
  if (ASrc = nil) or (ADst = nil) or (W <= 0) or (H <= 0) then Exit;
  f.Id := AId;
  f.Params := AParams;
  f.Prog := AProgress;
  f.Amt := ParF(AParams, 'amt', -1);
  f.Src := ASrc;
  f.Dst := ADst;
  f.W := W;
  f.H := H;
  f.N := W * H;
  f.Seed := ASeed;
  Result := PlusBlur(f) or PlusSharpen(f) or PlusColour(f) or PlusLight(f) or PlusStylize(f) or
    PlusTexture(f) or PlusTransform(f) or PlusWarp(f) or PlusGlitch(f) or PlusRevival(f) or
    PlusGenerate(f) or PlusCamera(f);
end;

{ ============================= transitions =============================== }

function FBm(X, Y: Double; ASeed: Integer): Double;
var
  oct, ix, iy: Integer;
  fq, ampl, u, v, h, n: Double;
begin
  n := 0;
  fq := 1;
  ampl := 0.5;
  for oct := 0 to 3 do
  begin
    u := X * fq;
    v := Y * fq;
    ix := Floor(u);
    iy := Floor(v);
    h := Smooth01(u - ix);
    n := n + ampl * ((Hs(ix, iy, ASeed + oct) * (1 - h) + Hs(ix + 1, iy, ASeed + oct) * h) * (1 - Smooth01(v - iy)) +
      (Hs(ix, iy + 1, ASeed + oct) * (1 - h) + Hs(ix + 1, iy + 1, ASeed + oct) * h) * Smooth01(v - iy));
    fq := fq * 2;
    ampl := ampl * 0.5;
  end;
  Result := n / 0.9375;
end;

{ regular N-gon "distance": 1 on its boundary when its circumradius is 1; AVertexAngle points at a corner }
function PolyDist(NX, NY: Double; ASides: Integer; AVertexAngle: Double): Double;
var
  th, seg, phi, r: Double;
begin
  r := Sqrt(NX * NX + NY * NY);
  if r < 1E-9 then Exit(0);
  th := FastArcTan2(NY, NX) - AVertexAngle;
  seg := 2 * Pi / ASides;
  phi := th - Floor(th / seg) * seg - seg / 2;
  Result := r * FastCos(phi) / FastCos(Pi / ASides);
end;

const
  MASK_IDS: array[1..27] of string = ('irisbox', 'irisdiamond', 'irisoval', 'iriscross', 'shapeheart',
    'shapestar', 'shapetriup', 'shapetridown', 'shapetrileft', 'shapetriright', 'shapepentagon',
    'shapehexagon', 'bandwipe', 'venetian', 'venetianv', 'checkerwipe', 'diagwipe', 'diagwipe2',
    'pinwheel', 'fanwipe', 'spiralwipe', 'zigzagwipe', 'xwipe', 'blockwipe', 'insetwipe', 'lumawipe',
    'ditherdissolve');

function MaskCode(const AId: string): Integer;
var
  i: Integer;
begin
  for i := Low(MASK_IDS) to High(MASK_IDS) do
    if MASK_IDS[i] = AId then Exit(i);
  Result := 0;
end;

{ A value that grows from 0 at the "first revealed" spot to ARange at the last. }
function MaskVal(ACode, X, Y, W, H: Integer; APix: PByte; out ARange: Double): Double;
var
  cx, cy, nx, ny, u, v, r, th, rho, wv, cellx, celly, fx, fy, ring: Double;
  ci, cj, nb, k: Integer;
begin
  cx := (W - 1) / 2;
  cy := (H - 1) / 2;
  nx := (X - cx) / Max(1.0, cx);
  ny := (Y - cy) / Max(1.0, cy);
  u := X / Max(1, W - 1);
  v := Y / Max(1, H - 1);
  ARange := 1;
  Result := 0;
  case ACode of
    1: Result := Max(Abs(nx), Abs(ny));
    2: begin ARange := 2; Result := Abs(nx) + Abs(ny); end;
    3: begin ARange := 1.4143; Result := Sqrt(nx * nx + ny * ny); end;
    4: Result := Min(Abs(nx), Abs(ny));
    5:
      begin
        ARange := 3.15;
        r := Sqrt(nx * nx + ny * ny);
        th := FastArcTan2(-ny, nx);
        rho := (2 - 2 * FastSin(th) + FastSin(th) * Sqrt(Abs(FastCos(th))) / (FastSin(th) + 1.4)) / 2.2;
        Result := r / Max(rho, 0.45);
      end;
    6:
      begin
        ARange := 3.15;
        r := Sqrt(nx * nx + ny * ny);
        th := FastArcTan2(ny, nx) + Pi / 2;
        rho := 0.45 + 0.55 * FastPow(Abs(FastCos(2.5 * th)), 1.5);
        Result := r / rho;
      end;
    7: begin ARange := 2.83; Result := PolyDist(nx, ny, 3, -Pi / 2); end;
    8: begin ARange := 2.83; Result := PolyDist(nx, ny, 3, Pi / 2); end;
    9: begin ARange := 2.83; Result := PolyDist(nx, ny, 3, Pi); end;
    10: begin ARange := 2.83; Result := PolyDist(nx, ny, 3, 0); end;
    11: begin ARange := 1.75; Result := PolyDist(nx, ny, 5, -Pi / 2); end;
    12: begin ARange := 1.64; Result := PolyDist(nx, ny, 6, -Pi / 2); end;
    13:
      begin
        ARange := 1.5;
        nb := 10;
        k := Min(nb - 1, Trunc(v * nb));
        Result := u + 0.5 * k / (nb - 1);
      end;
    14: Result := Frac(v * 8);
    15: Result := Frac(u * 8);
    16:
      begin
        ARange := 1.6;
        cellx := u * 10;
        celly := v * 8;
        ci := Min(9, Trunc(cellx));
        cj := Min(7, Trunc(celly));
        fx := cellx - ci;
        fy := celly - cj;
        ring := Max(Abs(fx - 0.5), Abs(fy - 0.5)) * 2;
        Result := (ci / 9 + cj / 7) / 2 + 0.6 * ring;
      end;
    17: Result := (u + v) / 2;
    18: Result := ((1 - u) + v) / 2;
    19:
      begin
        th := FastArcTan2(ny, nx) + Pi;
        Result := Frac(th / (Pi / 2));
      end;
    20: Result := Abs(FastArcTan2(nx, -ny)) / Pi;
    21:
      begin
        r := Sqrt(nx * nx + ny * ny) / 1.4143;
        th := FastArcTan2(ny, nx) + Pi;
        Result := Frac(th / (2 * Pi) + r * 1.2);
      end;
    22:
      begin
        ARange := 1.12;
        wv := Abs(Frac(v * 8) * 2 - 1);
        Result := u + 0.12 * wv;
      end;
    23: Result := Min(Abs(nx - ny), Abs(nx + ny));
    24: Result := Hs(X * 16 div Max(1, W), Y * 9 div Max(1, H), 7);
    25: Result := Max(u, v);
    26: Result := Lm(APix) / 255 * 0.5 + u * 0.5;
    27: Result := Hs(X, Y, 3);
  end;
end;

function SoftD(D: Double): Double; inline;
begin
  Result := Cl(D * 40 + 0.5);
end;

function VfxPlusTransition(const AId, AParams: string; AProgress: Double;
  AFrom, ATo, ADst: PByte; W, H, ASeed: Integer): Boolean;
var
  p, rng, val, cx, cy, s, dd, f: Double;
  code, x, y, i, n, w256, sh, k, hw: Integer;
  ta, tb: TBytes;
  a, bb, o, fc: PByte;
  fire: Integer;

  procedure Crossfade(AA, AB: PByte);
  var
    j: Integer;
  begin
    for j := 0 to n - 1 do
    begin
      ADst[j * 4] := (AA[j * 4] * (256 - w256) + AB[j * 4] * w256) shr 8;
      ADst[j * 4 + 1] := (AA[j * 4 + 1] * (256 - w256) + AB[j * 4 + 1] * w256) shr 8;
      ADst[j * 4 + 2] := (AA[j * 4 + 2] * (256 - w256) + AB[j * 4 + 2] * w256) shr 8;
      ADst[j * 4 + 3] := 0;
    end;
  end;

  procedure Px(AX, AY: Integer; ASrc: PByte; ASX, ASY: Integer);
  begin
    PCardinal(ADst + (Int64(AY) * W + AX) * 4)^ := PCardinal(PixAt(ASrc, W, H, ASX, ASY))^;
  end;

begin
  Result := False;
  if (AFrom = nil) or (ATo = nil) or (ADst = nil) or (W <= 0) or (H <= 0) then Exit;
  code := MaskCode(AId);
  if (code = 0) and (Pos('|' + AId + '|',
    '|additive|nonadditive|burnaway|coverleft|coverright|coverup|coverdown|splith|splitv|squeezeh|squeezev|' +
    'cardflipx|cardflipy|spintrans|whippan|rippletrans|swirltrans|zoomblurtrans|bandslide|') = 0) then Exit;
  Result := True;
  p := Cl(AProgress);
  n := W * H;
  w256 := Round(p * 256);
  cx := (W - 1) / 2;
  cy := (H - 1) / 2;
  if p <= 0 then begin CopyPic(AFrom, ADst, W, H); Exit; end;
  if p >= 1 then begin CopyPic(ATo, ADst, W, H); Exit; end;

  if code > 0 then
  begin
    for y := 0 to H - 1 do
      for x := 0 to W - 1 do
      begin
        a := AFrom + (Int64(y) * W + x) * 4;
        val := MaskVal(code, x, y, W, H, a, rng);
        f := SoftD(p * (rng + 0.1) - val - 0.02);
        i := Round(f * 256);
        bb := ATo + (Int64(y) * W + x) * 4;
        o := ADst + (Int64(y) * W + x) * 4;
        o[0] := (a[0] * (256 - i) + bb[0] * i) shr 8;
        o[1] := (a[1] * (256 - i) + bb[1] * i) shr 8;
        o[2] := (a[2] * (256 - i) + bb[2] * i) shr 8;
        o[3] := 0;
      end;
    Exit;
  end;

  if AId = 'additive' then
  begin
    f := 1 + 0.5 * FastSin(p * Pi);
    for i := 0 to n - 1 do
      for k := 0 to 2 do
        ADst[i * 4 + k] := C8(Round(((AFrom[i * 4 + k] * (256 - w256) + ATo[i * 4 + k] * w256) shr 8) * f));
    ClearPad(ADst, n);
  end
  else if AId = 'nonadditive' then
  begin
    for i := 0 to n - 1 do
      for k := 0 to 2 do
        ADst[i * 4 + k] := Max((AFrom[i * 4 + k] * (256 - w256)) shr 8, (ATo[i * 4 + k] * w256) shr 8);
    ClearPad(ADst, n);
  end
  else if AId = 'burnaway' then
  begin
    for y := 0 to H - 1 do
      for x := 0 to W - 1 do
      begin
        val := FBm(x / Max(W, H) * 5, y / Max(W, H) * 5, 11);
        dd := p * 1.3 - val - 0.1;
        a := AFrom + (Int64(y) * W + x) * 4;
        bb := ATo + (Int64(y) * W + x) * 4;
        o := ADst + (Int64(y) * W + x) * 4;
        if dd >= 0.06 then
          PCardinal(o)^ := PCardinal(bb)^
        else if dd >= 0 then
        begin
          fire := Round(dd / 0.06 * 255);
          SetPx(o, 20 + fire div 6, 90 + fire * 2 div 3, 255 - fire div 8);
        end
        else if dd >= -0.08 then
        begin
          f := Cl(-dd / 0.08);
          SetPx(o, Round(a[0] * f), Round(a[1] * f), Round(a[2] * f));
        end
        else
          PCardinal(o)^ := PCardinal(a)^;
        o[3] := 0;
      end;
  end
  else if (AId = 'coverleft') or (AId = 'coverright') then
  begin
    sh := Round(p * W);
    for y := 0 to H - 1 do
      for x := 0 to W - 1 do
        if AId = 'coverleft' then
        begin
          if x >= W - sh then Px(x, y, ATo, x - (W - sh), y) else Px(x, y, AFrom, x, y);
        end
        else
        begin
          if x < sh then Px(x, y, ATo, x + W - sh, y) else Px(x, y, AFrom, x, y);
        end;
    ClearPad(ADst, n);
  end
  else if (AId = 'coverup') or (AId = 'coverdown') then
  begin
    sh := Round(p * H);
    for y := 0 to H - 1 do
      for x := 0 to W - 1 do
        if AId = 'coverup' then
        begin
          if y >= H - sh then Px(x, y, ATo, x, y - (H - sh)) else Px(x, y, AFrom, x, y);
        end
        else
        begin
          if y < sh then Px(x, y, ATo, x, y + H - sh) else Px(x, y, AFrom, x, y);
        end;
    ClearPad(ADst, n);
  end
  else if AId = 'splith' then
  begin
    hw := W div 2;
    sh := Round(p * hw);
    for y := 0 to H - 1 do
      for x := 0 to W - 1 do
        if x < hw then
        begin
          if x + sh < hw then Px(x, y, AFrom, x + sh, y) else Px(x, y, ATo, x, y);
        end
        else
        begin
          if x - sh >= hw then Px(x, y, AFrom, x - sh, y) else Px(x, y, ATo, x, y);
        end;
    ClearPad(ADst, n);
  end
  else if AId = 'splitv' then
  begin
    hw := H div 2;
    sh := Round(p * hw);
    for y := 0 to H - 1 do
      for x := 0 to W - 1 do
        if y < hw then
        begin
          if y + sh < hw then Px(x, y, AFrom, x, y + sh) else Px(x, y, ATo, x, y);
        end
        else
        begin
          if y - sh >= hw then Px(x, y, AFrom, x, y - sh) else Px(x, y, ATo, x, y);
        end;
    ClearPad(ADst, n);
  end
  else if (AId = 'squeezeh') or (AId = 'squeezev') then
  begin
    s := 1 - p;
    for y := 0 to H - 1 do
      for x := 0 to W - 1 do
        if AId = 'squeezeh' then
        begin
          if Abs(x - cx) <= cx * s then Px(x, y, AFrom, Round(cx + (x - cx) / s), y) else Px(x, y, ATo, x, y);
        end
        else
        begin
          if Abs(y - cy) <= cy * s then Px(x, y, AFrom, x, Round(cy + (y - cy) / s)) else Px(x, y, ATo, x, y);
        end;
    ClearPad(ADst, n);
  end
  else if (AId = 'cardflipx') or (AId = 'cardflipy') then
  begin
    if p < 0.5 then begin s := FastCos(p * Pi); fc := AFrom; end
    else begin s := FastCos((1 - p) * Pi); fc := ATo; end;
    s := Max(s, 0.001);
    for y := 0 to H - 1 do
      for x := 0 to W - 1 do
      begin
        if AId = 'cardflipx' then
        begin
          if Abs(x - cx) <= cx * s then Px(x, y, fc, Round(cx + (x - cx) / s), y)
          else PCardinal(ADst + (Int64(y) * W + x) * 4)^ := 0;
        end
        else
        begin
          if Abs(y - cy) <= cy * s then Px(x, y, fc, x, Round(cy + (y - cy) / s))
          else PCardinal(ADst + (Int64(y) * W + x) * 4)^ := 0;
        end;
      end;
    ClearPad(ADst, n);
  end
  else if AId = 'spintrans' then
  begin
    SetLength(ta, n * 4);
    SetLength(tb, n * 4);
    RotScale(AFrom, @ta[0], W, H, 1 + p * 1.2, p * Pi * 0.8, 0, 0, True);
    RotScale(ATo, @tb[0], W, H, 1 + (1 - p) * 1.2, -(1 - p) * Pi * 0.8, 0, 0, True);
    Crossfade(@ta[0], @tb[0]);
  end
  else if AId = 'whippan' then
  begin
    SetLength(ta, n * 4);
    sh := Round(p * W);
    for y := 0 to H - 1 do
      for x := 0 to W - 1 do
        if x + sh < W then PCardinal(@ta[(y * W + x) * 4])^ := PCardinal(AFrom + (Int64(y) * W + x + sh) * 4)^
        else PCardinal(@ta[(y * W + x) * 4])^ := PCardinal(ATo + (Int64(y) * W + x + sh - W) * 4)^;
    DirBlurPic(@ta[0], ADst, W, H, Max(3.0, FastSin(p * Pi) * W / 5), 0);
  end
  else if AId = 'rippletrans' then
  begin
    SetLength(ta, n * 4);
    SetLength(tb, n * 4);
    WarpKind(AFrom, @ta[0], W, H, WK_RIPPLE, FastSin(p * Pi) * 2, p);
    WarpKind(ATo, @tb[0], W, H, WK_RIPPLE, FastSin(p * Pi) * 2, p);
    Crossfade(@ta[0], @tb[0]);
  end
  else if AId = 'swirltrans' then
  begin
    SetLength(ta, n * 4);
    SetLength(tb, n * 4);
    WarpKind(AFrom, @ta[0], W, H, WK_SWIRL, FastSin(p * Pi) * 1.5, p);
    WarpKind(ATo, @tb[0], W, H, WK_SWIRL, FastSin(p * Pi) * 1.5, p);
    Crossfade(@ta[0], @tb[0]);
  end
  else if AId = 'zoomblurtrans' then
  begin
    SetLength(ta, n * 4);
    SetLength(tb, n * 4);
    RadialSmear(AFrom, @ta[0], W, H, FastSin(p * Pi) * 0.5, False);
    RadialSmear(ATo, @tb[0], W, H, FastSin(p * Pi) * 0.5, False);
    Crossfade(@ta[0], @tb[0]);
  end
  else if AId = 'bandslide' then
  begin
    sh := Round(p * W);
    for y := 0 to H - 1 do
    begin
      k := y * 10 div H;
      for x := 0 to W - 1 do
        if (k and 1) = 0 then
        begin
          if x + sh < W then Px(x, y, AFrom, x + sh, y) else Px(x, y, ATo, x + sh - W, y);
        end
        else
        begin
          if x - sh >= 0 then Px(x, y, AFrom, x - sh, y) else Px(x, y, ATo, x - sh + W, y);
        end;
    end;
    ClearPad(ADst, n);
  end;
end;

initialization
  {$IFDEF FPC}
  FInv := DefaultFormatSettings;
  {$ELSE}
  FInv := TFormatSettings.Create('en-US');
  {$ENDIF}
  FInv.DecimalSeparator := '.';
  BuildTable;

end.
