unit UDAW.Audio.Types;
{$I udaw.inc}

{ Phase 2 - Audio Device Engine: core shared types.

  Canonical internal audio representation for the whole DAW:
    * IEEE Float32 samples
    * PLANAR (non-interleaved): one contiguous array per channel

  This unit also owns the byte-level conversion between the device's interleaved
  PCM/float block and the engine's planar float buffers - the "format
  negotiation" edge every backend (WASAPI, Core Audio, ALSA, software) shares.
  It must not depend on any other UDAW.Audio unit. }

interface

uses
  SysUtils, Math,
  UDAW.Types, UDAW.Errors, UDAW.DSP.MathTables;

const
  AUDIO_SUBSYS = 'Audio';

  { Standard sample rates the engine advertises. Custom rates are still accepted
    when the hardware reports support for them (see ValidSampleRate). }
  UDAW_STANDARD_SAMPLE_RATES: array[0..7] of Integer =
    (22050, 32000, 44100, 48000, 88200, 96000, 176400, 192000);

  UDAW_MIN_SAMPLE_RATE   = 8000;
  UDAW_MAX_SAMPLE_RATE   = 768000;
  UDAW_DEFAULT_SAMPLE_RATE = 48000;

  UDAW_MAX_CHANNELS      = 32;

  { Frames per processing block (callback quantum) guard rails. }
  UDAW_MIN_BUFFER_FRAMES = 16;
  UDAW_MAX_BUFFER_FRAMES = 65536;
  UDAW_DEFAULT_BUFFER_FRAMES = 480;   // 10 ms @ 48 kHz

type
  { Canonical internal sample type. }
  TAudioSample = Single;
  PAudioSample = ^TAudioSample;
  TAudioSampleArray = array of Single;
  { Planar layout: Data[channel][frame]. }
  TAudioPlanar = array of TAudioSampleArray;

  { Interchange formats for byte-level conversion at the backend edge. All
    integer formats are little-endian, signed, and full-scale = +/- 1.0. }
  TAudioDeviceFormat = (
    dfUnknown,
    dfInt16,        // 16-bit signed PCM
    dfInt24Packed,  // 24-bit signed PCM stored in 3 bytes
    dfInt32,        // 32-bit signed PCM
    dfFloat32,      // IEEE 754 single
    dfFloat64       // IEEE 754 double
  );

  TAudioChannelLayout = (
    clMono, clStereo, cl21, cl40, cl51, cl71, clDiscrete
  );

  TAudioDirection = (adRender, adCapture, adDuplex);

  { High-resolution stream timing handed to the render callback. }
  TAudioStreamTime = record
    CallbackIndex: Int64;   // monotonically increasing, starts at 0
    StreamFrames: Int64;    // frames elapsed since Start (render position)
    HostTimeNs: Int64;      // best-effort monotonic host clock, nanoseconds
    SampleRate: Integer;
  end;

function DeviceFormatName(AFmt: TAudioDeviceFormat): string;
function DeviceFormatBytes(AFmt: TAudioDeviceFormat): Integer;
function ChannelLayoutName(ALayout: TAudioChannelLayout): string;
function ChannelLayoutCount(ALayout: TAudioChannelLayout): Integer;
function LayoutForChannelCount(ACount: Integer): TAudioChannelLayout;
function DirectionName(ADir: TAudioDirection): string;

function IsStandardSampleRate(ARate: Integer): Boolean;
function ValidSampleRate(ARate: Integer): Boolean;
function ValidChannelCount(ACount: Integer): Boolean;
function ClampBufferFrames(AFrames: Integer): Integer;

function LinearToDb(ALinear: Double): Double;
function DbToLinear(ADb: Double): Double;

function ClampSample(AValue: Single): Single; inline;

{ Convert an interleaved device block to planar float.
  ADst must be at least [ANumChannels] x [>= ANumFrames].
  Raises EUDAWError on an unsupported format. }
procedure DecodeInterleaved(const ASrc; AFmt: TAudioDeviceFormat;
  ANumChannels, ANumFrames: Integer; const ADst: TAudioPlanar);

{ Convert planar float to an interleaved device block.
  ADst must point at >= ANumFrames*ANumChannels*DeviceFormatBytes(AFmt) bytes. }
procedure EncodeInterleaved(const ASrc: TAudioPlanar;
  ANumChannels, ANumFrames: Integer; AFmt: TAudioDeviceFormat; var ADst);

{ Allocate / grow a planar buffer to [AChannels] x [AFrames] (no shrink of the
  per-channel arrays below AFrames - callers may keep spare capacity). }
procedure EnsurePlanar(var APlanar: TAudioPlanar; AChannels, AFrames: Integer);

implementation

const
  INT24_MAX =  8388607.0;
  INT24_MIN = -8388608.0;

function DeviceFormatName(AFmt: TAudioDeviceFormat): string;
begin
  case AFmt of
    dfInt16:       Result := 'Int16';
    dfInt24Packed: Result := 'Int24';
    dfInt32:       Result := 'Int32';
    dfFloat32:     Result := 'Float32';
    dfFloat64:     Result := 'Float64';
  else
    Result := 'Unknown';
  end;
end;

function DeviceFormatBytes(AFmt: TAudioDeviceFormat): Integer;
begin
  case AFmt of
    dfInt16:       Result := 2;
    dfInt24Packed: Result := 3;
    dfInt32:       Result := 4;
    dfFloat32:     Result := 4;
    dfFloat64:     Result := 8;
  else
    Result := 0;
  end;
end;

function ChannelLayoutName(ALayout: TAudioChannelLayout): string;
begin
  case ALayout of
    clMono:     Result := 'Mono';
    clStereo:   Result := 'Stereo';
    cl21:       Result := '2.1';
    cl40:       Result := '4.0';
    cl51:       Result := '5.1';
    cl71:       Result := '7.1';
  else
    Result := 'Discrete';
  end;
end;

function ChannelLayoutCount(ALayout: TAudioChannelLayout): Integer;
begin
  case ALayout of
    clMono:   Result := 1;
    clStereo: Result := 2;
    cl21:     Result := 3;
    cl40:     Result := 4;
    cl51:     Result := 6;
    cl71:     Result := 8;
  else
    Result := 0;
  end;
end;

function LayoutForChannelCount(ACount: Integer): TAudioChannelLayout;
begin
  case ACount of
    1: Result := clMono;
    2: Result := clStereo;
    3: Result := cl21;
    4: Result := cl40;
    6: Result := cl51;
    8: Result := cl71;
  else
    Result := clDiscrete;
  end;
end;

function DirectionName(ADir: TAudioDirection): string;
begin
  case ADir of
    adRender:  Result := 'Render';
    adCapture: Result := 'Capture';
    adDuplex:  Result := 'Duplex';
  else
    Result := '?';
  end;
end;

function IsStandardSampleRate(ARate: Integer): Boolean;
var
  i: Integer;
begin
  for i := Low(UDAW_STANDARD_SAMPLE_RATES) to High(UDAW_STANDARD_SAMPLE_RATES) do
    if UDAW_STANDARD_SAMPLE_RATES[i] = ARate then
      Exit(True);
  Result := False;
end;

function ValidSampleRate(ARate: Integer): Boolean;
begin
  Result := (ARate >= UDAW_MIN_SAMPLE_RATE) and (ARate <= UDAW_MAX_SAMPLE_RATE);
end;

function ValidChannelCount(ACount: Integer): Boolean;
begin
  Result := (ACount >= 1) and (ACount <= UDAW_MAX_CHANNELS);
end;

function ClampBufferFrames(AFrames: Integer): Integer;
begin
  if AFrames < UDAW_MIN_BUFFER_FRAMES then
    Result := UDAW_MIN_BUFFER_FRAMES
  else if AFrames > UDAW_MAX_BUFFER_FRAMES then
    Result := UDAW_MAX_BUFFER_FRAMES
  else
    Result := AFrames;
end;

function LinearToDb(ALinear: Double): Double;
begin
  if ALinear <= 1.0E-12 then
    Result := -240.0
  else
    Result := FastLinToDb(ALinear);
end;

function DbToLinear(ADb: Double): Double;
begin
  if ADb <= -240.0 then
    Result := 0.0
  else
    Result := FastDbToLin(ADb);
end;

function ClampSample(AValue: Single): Single;
begin
  if AValue > 1.0 then
    Result := 1.0
  else if AValue < -1.0 then
    Result := -1.0
  else if AValue <> AValue then   // NaN
    Result := 0.0
  else
    Result := AValue;
end;

procedure EnsurePlanar(var APlanar: TAudioPlanar; AChannels, AFrames: Integer);
var
  ch: Integer;
begin
  if AChannels < 0 then AChannels := 0;
  if AFrames < 0 then AFrames := 0;
  if Length(APlanar) <> AChannels then
    SetLength(APlanar, AChannels);
  for ch := 0 to AChannels - 1 do
    if Length(APlanar[ch]) < AFrames then
      SetLength(APlanar[ch], AFrames);
end;

{ ---- interleaved <-> planar conversion ---- }

procedure DecodeInterleaved(const ASrc; AFmt: TAudioDeviceFormat;
  ANumChannels, ANumFrames: Integer; const ADst: TAudioPlanar);
var
  frame, ch: Integer;
  p: PByte;
  i16: PSmallInt;
  i32: PInteger;
  f32: PSingle;
  f64: PDouble;
  v: Integer;
begin
  if (ANumChannels <= 0) or (ANumFrames <= 0) then
    Exit;
  if Length(ADst) < ANumChannels then
    RaiseUDAW(errInvalidArgument, AUDIO_SUBSYS, 'DecodeInterleaved: destination has too few channels');

  case AFmt of
    dfInt16:
      begin
        i16 := PSmallInt(@ASrc);
        for frame := 0 to ANumFrames - 1 do
          for ch := 0 to ANumChannels - 1 do
          begin
            ADst[ch][frame] := i16^ / 32768.0;
            Inc(i16);
          end;
      end;
    dfInt24Packed:
      begin
        p := PByte(@ASrc);
        for frame := 0 to ANumFrames - 1 do
          for ch := 0 to ANumChannels - 1 do
          begin
            v := p^ or (PByte(NativeUInt(p) + 1)^ shl 8) or
                 (PByte(NativeUInt(p) + 2)^ shl 16);
            if (v and $800000) <> 0 then
              v := v or Integer($FF000000);   // sign-extend
            ADst[ch][frame] := v / 8388608.0;
            Inc(p, 3);
          end;
      end;
    dfInt32:
      begin
        i32 := PInteger(@ASrc);
        for frame := 0 to ANumFrames - 1 do
          for ch := 0 to ANumChannels - 1 do
          begin
            ADst[ch][frame] := i32^ / 2147483648.0;
            Inc(i32);
          end;
      end;
    dfFloat32:
      begin
        f32 := PSingle(@ASrc);
        for frame := 0 to ANumFrames - 1 do
          for ch := 0 to ANumChannels - 1 do
          begin
            ADst[ch][frame] := f32^;
            Inc(f32);
          end;
      end;
    dfFloat64:
      begin
        f64 := PDouble(@ASrc);
        for frame := 0 to ANumFrames - 1 do
          for ch := 0 to ANumChannels - 1 do
          begin
            ADst[ch][frame] := f64^;
            Inc(f64);
          end;
      end;
  else
    RaiseUDAWFmt(errInvalidArgument, AUDIO_SUBSYS,
      'DecodeInterleaved: unsupported device format %d', [Ord(AFmt)]);
  end;
end;

procedure EncodeInterleaved(const ASrc: TAudioPlanar;
  ANumChannels, ANumFrames: Integer; AFmt: TAudioDeviceFormat; var ADst);
var
  frame, ch, iv: Integer;
  s: Single;
  p: PByte;
  i16: PSmallInt;
  i32: PInteger;
  f32: PSingle;
  f64: PDouble;
begin
  if (ANumChannels <= 0) or (ANumFrames <= 0) then
    Exit;
  if Length(ASrc) < ANumChannels then
    RaiseUDAW(errInvalidArgument, AUDIO_SUBSYS, 'EncodeInterleaved: source has too few channels');

  case AFmt of
    dfInt16:
      begin
        i16 := PSmallInt(@ADst);
        for frame := 0 to ANumFrames - 1 do
          for ch := 0 to ANumChannels - 1 do
          begin
            s := ClampSample(ASrc[ch][frame]);
            iv := Round(s * 32767.0);
            if iv > 32767 then iv := 32767 else if iv < -32768 then iv := -32768;
            i16^ := SmallInt(iv);
            Inc(i16);
          end;
      end;
    dfInt24Packed:
      begin
        p := PByte(@ADst);
        for frame := 0 to ANumFrames - 1 do
          for ch := 0 to ANumChannels - 1 do
          begin
            s := ClampSample(ASrc[ch][frame]);
            if s >= 0 then iv := Round(s * INT24_MAX)
            else iv := Round(s * (-INT24_MIN));
            if iv > 8388607 then iv := 8388607 else if iv < -8388608 then iv := -8388608;
            p^ := Byte(iv and $FF);
            PByte(NativeUInt(p) + 1)^ := Byte((iv shr 8) and $FF);
            PByte(NativeUInt(p) + 2)^ := Byte((iv shr 16) and $FF);
            Inc(p, 3);
          end;
      end;
    dfInt32:
      begin
        i32 := PInteger(@ADst);
        for frame := 0 to ANumFrames - 1 do
          for ch := 0 to ANumChannels - 1 do
          begin
            s := ClampSample(ASrc[ch][frame]);
            { scale to full 32-bit range with headroom against overflow }
            if s >= 1.0 then
              i32^ := 2147483647
            else if s <= -1.0 then
              i32^ := Integer($80000000)
            else
              i32^ := Round(s * 2147483647.0);
            Inc(i32);
          end;
      end;
    dfFloat32:
      begin
        f32 := PSingle(@ADst);
        for frame := 0 to ANumFrames - 1 do
          for ch := 0 to ANumChannels - 1 do
          begin
            f32^ := ClampSample(ASrc[ch][frame]);
            Inc(f32);
          end;
      end;
    dfFloat64:
      begin
        f64 := PDouble(@ADst);
        for frame := 0 to ANumFrames - 1 do
          for ch := 0 to ANumChannels - 1 do
          begin
            f64^ := ClampSample(ASrc[ch][frame]);
            Inc(f64);
          end;
      end;
  else
    RaiseUDAWFmt(errInvalidArgument, AUDIO_SUBSYS,
      'EncodeInterleaved: unsupported device format %d', [Ord(AFmt)]);
  end;
end;

end.
