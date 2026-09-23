unit Tests.Phase6;
{$IFDEF FPC}{$MODE DELPHI}{$MODESWITCH ADVANCEDRECORDS}{$H+}{$ENDIF}

{ Phase 6 acceptance tests: the internal PCM / WAV engine.

  Covers every supported sample format (PCM 8/16/24/32, IEEE float 32/64) in
  mono, stereo and multichannel; RIFF and RF64 containers; header-signature
  detection that ignores the file extension; TWavInfo probing; partial reads
  and frame seeking; loud rejection of malformed / truncated / unsupported
  files; and the rate-adapting TWavPlayerSource.

  Requires src/common, src/audio, src/audio/dsp and src/codecs/pcm on the
  search path. }

interface

procedure RegisterPhase6Tests;

implementation

uses
  SysUtils, Classes, Math,
  UDAW.Testing,
  UDAW.Errors,
  UDAW.Paths,
  UDAW.Audio.Types,
  UDAW.Audio.Source,
  UDAW.Audio.Offline,
  UDAW.Codec.WAV;

function ScratchDir: string;
begin
  Result := IncludeTrailingPathDelimiter(Paths.Temp) + 'phase6-tests' + PathDelim;
  ForceDirectories(Result);
end;

procedure WipeFile(const AFileName: string);
begin
  if FileExists(AFileName) then
    DeleteFile(AFileName);
end;

{ A deterministic band-limited-ish test signal, distinct per channel. }
function MakeSignal(AChannels, AFrames: Integer): TAudioPlanar;
var
  ch, i: Integer;
  ph: Double;
begin
  SetLength(Result, AChannels);
  for ch := 0 to AChannels - 1 do
  begin
    SetLength(Result[ch], AFrames);
    for i := 0 to AFrames - 1 do
    begin
      ph := 2 * Pi * (60.0 + ch * 40.0) * i / 48000.0;
      Result[ch][i] := 0.80 * Sin(ph) + 0.10 * Sin(3 * ph);
    end;
  end;
end;

function MaxAbsDiff(const A, B: TAudioPlanar; AChannels, AFrames: Integer): Double;
var
  ch, i: Integer;
  d: Double;
begin
  Result := 0;
  for ch := 0 to AChannels - 1 do
    for i := 0 to AFrames - 1 do
    begin
      d := Abs(Double(A[ch][i]) - Double(B[ch][i]));
      if d > Result then Result := d;
    end;
end;

{ ================= round-trip per format ================= }

procedure RoundTrip(AFmt: TWavSampleFormat; AChannels: Integer; ATol: Double;
  const AWhat: string);
const
  FRAMES = 4000;
  SR = 44100;
var
  fn: string;
  src, back: TAudioPlanar;
  ch2, sr2: Integer;
begin
  fn := ScratchDir + 'rt_' + AWhat + '.wav';
  WipeFile(fn);
  src := MakeSignal(AChannels, FRAMES);
  try
    SaveWavFile(fn, src, AChannels, SR, FRAMES, AFmt);
    Check(FileLooksLikeWav(fn), AWhat + ': written file has a WAV signature');

    back := LoadWavFile(fn, ch2, sr2);
    CheckEqualInt(AChannels, ch2, AWhat + ': channel count round-trips');
    CheckEqualInt(SR, sr2, AWhat + ': sample rate round-trips');
    CheckEqualInt(FRAMES, Length(back[0]), AWhat + ': frame count round-trips');
    CheckNear(0, MaxAbsDiff(src, back, AChannels, FRAMES), ATol,
      AWhat + ': samples round-trip within tolerance');
  finally
    WipeFile(fn);
  end;
end;

procedure Test_RoundTrip_PCM8_Mono;    begin RoundTrip(wsfPCM8,   1, 1.0 / 100,     'pcm8mono');   end;
procedure Test_RoundTrip_PCM16_Stereo; begin RoundTrip(wsfPCM16,  2, 1.0 / 16000,   'pcm16st');    end;
procedure Test_RoundTrip_PCM24_Stereo; begin RoundTrip(wsfPCM24,  2, 1.0 / 4000000, 'pcm24st');    end;
procedure Test_RoundTrip_PCM32_Stereo; begin RoundTrip(wsfPCM32,  2, 1.0E-6,        'pcm32st');    end;
procedure Test_RoundTrip_F32_Stereo;   begin RoundTrip(wsfFloat32, 2, 1.0E-6,       'f32st');      end;
procedure Test_RoundTrip_F64_Stereo;   begin RoundTrip(wsfFloat64, 2, 1.0E-6,       'f64st');      end;
procedure Test_RoundTrip_F32_6ch;      begin RoundTrip(wsfFloat32, 6, 1.0E-6,       'f32_6ch');    end;
procedure Test_RoundTrip_PCM24_8ch;    begin RoundTrip(wsfPCM24,   8, 1.0 / 4000000,'pcm24_8ch');  end;

{ ================= header probe ================= }

procedure Test_ReadWavInfo_Fields;
const
  FRAMES = 1500;
var
  fn: string;
  src: TAudioPlanar;
  info: TWavInfo;
begin
  fn := ScratchDir + 'info.wav';
  WipeFile(fn);
  src := MakeSignal(2, FRAMES);
  try
    SaveWavFile(fn, src, 2, 48000, FRAMES, wsfPCM16);
    info := ReadWavInfo(fn);
    CheckEqualInt(Ord(wsfPCM16), Ord(info.SampleFormat), 'format detected');
    CheckEqualInt(2, info.Channels, 'channels');
    CheckEqualInt(48000, info.SampleRate, 'sample rate');
    CheckEqualInt(FRAMES, info.FrameCount, 'frame count');
    CheckEqualInt(16, info.BitsPerSample, 'bits per sample');
    CheckEqualInt(4, info.BytesPerFrame, 'bytes per frame');
    CheckEqualInt(FRAMES * 4, info.DataSize, 'data size');
    CheckFalse(info.IsRF64, 'plain RIFF, not RF64');
    CheckNear(FRAMES / 48000, info.DurationSeconds, 1e-9, 'duration');
  finally
    WipeFile(fn);
  end;
end;

procedure Test_Extensible_Multichannel_Info;
const
  FRAMES = 800;
var
  fn: string;
  src: TAudioPlanar;
  info: TWavInfo;
begin
  fn := ScratchDir + 'ext6.wav';
  WipeFile(fn);
  src := MakeSignal(6, FRAMES);
  try
    SaveWavFile(fn, src, 6, 48000, FRAMES, wsfFloat32);
    info := ReadWavInfo(fn);
    Check(info.IsExtensible, '6-channel file is written WAVE_FORMAT_EXTENSIBLE');
    CheckEqualInt(6, info.Channels, 'channels');
    CheckEqualInt(Ord(wsfFloat32), Ord(info.SampleFormat), 'sub-format decoded from EXTENSIBLE');
  finally
    WipeFile(fn);
  end;
end;

{ ================= RF64 ================= }

procedure Test_RF64_RoundTrip;
const
  FRAMES = 5000;
var
  fn: string;
  src, back: TAudioPlanar;
  info: TWavInfo;
  ch2, sr2: Integer;
begin
  fn := ScratchDir + 'rf64.wav';
  WipeFile(fn);
  src := MakeSignal(2, FRAMES);
  try
    SaveWavFile(fn, src, 2, 96000, FRAMES, wsfPCM24, {ForceRF64=} True);
    info := ReadWavInfo(fn);
    Check(info.IsRF64, 'container tag is RF64');
    CheckEqualInt(FRAMES, info.FrameCount, 'RF64 frame count (from ds64)');

    back := LoadWavFile(fn, ch2, sr2);
    CheckEqualInt(FRAMES, Length(back[0]), 'RF64 data round-trips (length)');
    CheckNear(0, MaxAbsDiff(src, back, 2, FRAMES), 1.0 / 4000000,
      'RF64 data round-trips (samples)');
  finally
    WipeFile(fn);
  end;
end;

{ ================= seeking / partial reads ================= }

procedure Test_SeekAndPartialRead;
const
  FRAMES = 2000;
var
  fn: string;
  src, blk: TAudioPlanar;
  r: TWavReader;
  n: Integer;
begin
  fn := ScratchDir + 'seek.wav';
  WipeFile(fn);
  SetLength(src, 1);
  SetLength(src[0], FRAMES);
  for n := 0 to FRAMES - 1 do
    src[0][n] := (n / FRAMES) * 2.0 - 1.0;          // a full-scale ramp
  try
    SaveWavFile(fn, src, 1, 48000, FRAMES, wsfPCM24);

    r := TWavReader.Create(fn);
    try
      r.SeekFrame(500);
      CheckEqualInt(500, r.CurrentFrame, 'seek sets the current frame');
      n := r.ReadFrames(blk, 100);
      CheckEqualInt(100, n, 'partial read returns the requested count');
      CheckNear(src[0][500], blk[0][0], 1.0 / 4000000, 'first sample after seek');
      CheckNear(src[0][599], blk[0][99], 1.0 / 4000000, 'last sample of the partial read');
      CheckEqualInt(600, r.CurrentFrame, 'current frame advanced by the read');

      r.SeekFrame(FRAMES - 10);
      n := r.ReadFrames(blk, 1000);
      CheckEqualInt(10, n, 'read past EOF is clamped to the frames that remain');
      n := r.ReadFrames(blk, 1000);
      CheckEqualInt(0, n, 'reading at EOF returns zero');
    finally
      r.Free;
    end;
  finally
    WipeFile(fn);
  end;
end;

{ ================= 8-bit is unsigned ================= }

procedure Test_PCM8_IsUnsignedMidpoint;
var
  fn: string;
  src: TAudioPlanar;
  fsz: TFileStream;
  info: TWavInfo;
  b: Byte;
begin
  fn := ScratchDir + 'u8.wav';
  WipeFile(fn);
  SetLength(src, 1);
  SetLength(src[0], 16);
  { all-zero signal must serialise to 0x80 bytes in unsigned 8-bit PCM }
  SaveWavFile(fn, src, 1, 8000, 16, wsfPCM8);
  try
    info := ReadWavInfo(fn);
    fsz := TFileStream.Create(fn, fmOpenRead or fmShareDenyWrite);
    try
      fsz.Position := info.DataOffset;
      fsz.ReadBuffer(b, 1);
      CheckEqualInt($80, b, '8-bit PCM silence is stored as the unsigned midpoint 128');
    finally
      fsz.Free;
    end;
  finally
    WipeFile(fn);
  end;
end;

{ ================= detection / rejection ================= }

procedure Test_Detect_RejectsNonWav;
var
  fn: string;
  sl: TStringList;
begin
  fn := ScratchDir + 'notwav.txt';
  sl := TStringList.Create;
  try
    sl.Text := 'this is definitely not a RIFF WAVE file, no matter the extension';
    sl.SaveToFile(fn);
    CheckFalse(FileLooksLikeWav(fn), 'a text file is not detected as WAV');
  finally
    sl.Free;
    WipeFile(fn);
  end;
end;

procedure Test_Reject_Malformed;
var
  raised: Boolean;
  ms: TMemoryStream;
  junk: array[0..63] of Byte;
  i: Integer;
begin
  raised := False;
  ms := TMemoryStream.Create;
  try
    for i := 0 to High(junk) do junk[i] := Byte(i);
    ms.WriteBuffer(junk[0], SizeOf(junk));
    ms.Position := 0;
    try
      with TWavReader.Create(ms, False) do Free;
    except
      on E: EUDAWError do
      begin
        raised := True;
        CheckEqualInt(Ord(errConfig), Ord(E.Code), 'malformed WAV rejected with errConfig');
      end;
    end;
  finally
    ms.Free;
  end;
  Check(raised, 'a non-RIFF byte blob is rejected, not silently parsed');
end;

procedure Test_Reject_UnsupportedBitDepth;
var
  raised: Boolean;
  ms: TMemoryStream;

  procedure Tag(const T: string);
  var a: array[0..3] of Byte; k: Integer;
  begin
    for k := 0 to 3 do a[k] := Byte(Ord(T[k + 1]));
    ms.WriteBuffer(a[0], 4);
  end;
  procedure U32(V: LongWord);
  var a: array[0..3] of Byte;
  begin
    a[0] := V and $FF; a[1] := (V shr 8) and $FF; a[2] := (V shr 16) and $FF; a[3] := (V shr 24) and $FF;
    ms.WriteBuffer(a[0], 4);
  end;
  procedure U16(V: Word);
  var a: array[0..1] of Byte;
  begin
    a[0] := V and $FF; a[1] := (V shr 8) and $FF;
    ms.WriteBuffer(a[0], 2);
  end;

begin
  raised := False;
  ms := TMemoryStream.Create;
  try
    { a structurally valid RIFF/WAVE whose fmt claims PCM @ 12 bits }
    Tag('RIFF'); U32(4 + 8 + 16 + 8 + 4); Tag('WAVE');
    Tag('fmt '); U32(16);
    U16(WAVE_FORMAT_PCM); U16(1); U32(44100); U32(44100 * 2); U16(2); U16(12);
    Tag('data'); U32(4); U32(0);
    ms.Position := 0;
    try
      with TWavReader.Create(ms, False) do Free;
    except
      on E: EUDAWError do raised := True;
    end;
  finally
    ms.Free;
  end;
  Check(raised, 'an unsupported bit depth (12-bit PCM) is rejected');
end;

{ ================= streaming through a TStream ================= }

procedure Test_MemoryStream_RoundTrip;
const
  FRAMES = 1000;
var
  ms: TMemoryStream;
  w: TWavWriter;
  r: TWavReader;
  src, back: TAudioPlanar;
  ch2, sr2: Integer;
begin
  src := MakeSignal(2, FRAMES);
  ms := TMemoryStream.Create;
  try
    w := TWavWriter.Create(ms, False, wsfFloat32, 2, 48000);
    try
      w.WriteFrames(src, FRAMES);
      w.Finalize;
    finally
      w.Free;
    end;

    ms.Position := 0;
    r := TWavReader.Create(ms, False);
    try
      back := r.ReadAll(ch2, sr2);
      CheckEqualInt(FRAMES, Length(back[0]), 'stream round-trip frame count');
      CheckNear(0, MaxAbsDiff(src, back, 2, FRAMES), 1e-6, 'stream round-trip samples');
    finally
      r.Free;
    end;
  finally
    ms.Free;
  end;
end;

{ ================= TWavPlayerSource ================= }

procedure Test_PlayerSource_SameRate;
const
  SR = 48000;
var
  fn: string;
  tone: TAudioPlanar;
  i: Integer;
  ph: Double;
  player: TWavPlayerSource;
  si: IAudioSource;
  res: TOfflineResult;
begin
  fn := ScratchDir + 'sine440.wav';
  WipeFile(fn);
  SetLength(tone, 1);
  SetLength(tone[0], SR);
  for i := 0 to SR - 1 do
  begin
    ph := 2 * Pi * 440.0 * i / SR;
    tone[0][i] := 0.5 * Sin(ph);
  end;
  try
    SaveWavFile(fn, tone, 1, SR, SR, wsfPCM16);
    player := TWavPlayerSource.Create(fn);
    si := player;                       // hold the interface ref for the test
    try
      res := RenderSourceOffline(si, SR, 2, SR, 512);
      CheckNear(440.0, EstimateFrequency(res, 0), 2.0,
        'a 440 Hz WAV plays back at 440 Hz');
      CheckNear(0.5, ChannelPeak(res, 0), 0.02, 'playback level matches the file');
      Check(player.AtEnd, 'non-looping player reports end after the file is consumed');
    finally
      si := nil;                        // releases and frees the player
    end;
  finally
    WipeFile(fn);
  end;
end;

procedure Test_PlayerSource_ResampleRate;
const
  SRC_SR = 44100;
  DEV_SR = 48000;
var
  fn: string;
  tone: TAudioPlanar;
  i: Integer;
  ph: Double;
  player: TWavPlayerSource;
  si: IAudioSource;
  res: TOfflineResult;
begin
  fn := ScratchDir + 'sine1k_441.wav';
  WipeFile(fn);
  SetLength(tone, 1);
  SetLength(tone[0], SRC_SR);
  for i := 0 to SRC_SR - 1 do
  begin
    ph := 2 * Pi * 1000.0 * i / SRC_SR;
    tone[0][i] := 0.5 * Sin(ph);
  end;
  try
    SaveWavFile(fn, tone, 1, SRC_SR, SRC_SR, wsfFloat32);
    player := TWavPlayerSource.Create(fn);
    si := player;
    try
      CheckEqualInt(SRC_SR, player.SourceRate, 'player reports the file sample rate');
      res := RenderSourceOffline(si, DEV_SR, 1, DEV_SR div 2, 256);
      CheckNear(1000.0, EstimateFrequency(res, 0), 5.0,
        'a 44.1 kHz file resamples to the 48 kHz device without shifting pitch');
    finally
      si := nil;
    end;
  finally
    WipeFile(fn);
  end;
end;

{ ---------------- registration ---------------- }

procedure RegisterPhase6Tests;
begin
  RegisterTest('codec.wav.roundtrip', 'PCM 8-bit mono',        @Test_RoundTrip_PCM8_Mono);
  RegisterTest('codec.wav.roundtrip', 'PCM 16-bit stereo',     @Test_RoundTrip_PCM16_Stereo);
  RegisterTest('codec.wav.roundtrip', 'PCM 24-bit stereo',     @Test_RoundTrip_PCM24_Stereo);
  RegisterTest('codec.wav.roundtrip', 'PCM 32-bit stereo',     @Test_RoundTrip_PCM32_Stereo);
  RegisterTest('codec.wav.roundtrip', 'IEEE float 32 stereo',  @Test_RoundTrip_F32_Stereo);
  RegisterTest('codec.wav.roundtrip', 'IEEE float 64 stereo',  @Test_RoundTrip_F64_Stereo);
  RegisterTest('codec.wav.roundtrip', 'float32 6-channel',     @Test_RoundTrip_F32_6ch);
  RegisterTest('codec.wav.roundtrip', 'PCM 24-bit 8-channel',  @Test_RoundTrip_PCM24_8ch);

  RegisterTest('codec.wav.header', 'ReadWavInfo fields',        @Test_ReadWavInfo_Fields);
  RegisterTest('codec.wav.header', 'EXTENSIBLE multichannel',   @Test_Extensible_Multichannel_Info);
  RegisterTest('codec.wav.header', 'RF64 round-trip',           @Test_RF64_RoundTrip);

  RegisterTest('codec.wav.io', 'seek + partial read',           @Test_SeekAndPartialRead);
  RegisterTest('codec.wav.io', '8-bit PCM is unsigned',         @Test_PCM8_IsUnsignedMidpoint);
  RegisterTest('codec.wav.io', 'memory-stream round-trip',      @Test_MemoryStream_RoundTrip);

  RegisterTest('codec.wav.reject', 'not-a-WAV detection',       @Test_Detect_RejectsNonWav);
  RegisterTest('codec.wav.reject', 'malformed blob rejected',   @Test_Reject_Malformed);
  RegisterTest('codec.wav.reject', 'unsupported bit depth',     @Test_Reject_UnsupportedBitDepth);

  RegisterTest('codec.wav.play', 'player - matching rate',      @Test_PlayerSource_SameRate);
  RegisterTest('codec.wav.play', 'player - rate adaptation',    @Test_PlayerSource_ResampleRate);
end;

end.
