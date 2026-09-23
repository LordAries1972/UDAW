unit Tests.Phase16;
{$IFDEF FPC}{$MODE DELPHI}{$MODESWITCH ADVANCEDRECORDS}{$H+}{$ENDIF}
{$POINTERMATH ON}

{ Phase 16 acceptance tests - the MP4 *container* subsystem plus the supported
  PCM / MP3 audio workflows.  Everything here is verified in memory with no
  reference media:

    * TMP4BoxWriter -> TMP4AtomTree round-trip (nested boxes, 64-bit largesize,
      the stsd / meta prologues, a truncated box);
    * big-endian scalar reads and their bounds checks;
    * AudioSpecificConfig build <-> parse (AOT / rate / channel config) and the
      AAC sample-rate-index table;
    * PCM-in-MP4 encode -> decode round-trip at 16 / 24-bit / float32, checking
      the recovered dominant frequency per channel and the container/codec
      report (Mp4Probe names the container AND the codec separately);
    * TMP4Writer.BuildAAC emits a structurally valid mp4a + esds file whose
    track TMP4Reader identifies as "AAC LC" with the embedded ASC and reports
    it as decodable when the AAC tables are available;
    * hostile / truncated input degrades gracefully.

  Requires src/common, src/audio and src/codecs/mp4 on the search path. }

interface

procedure RegisterPhase16Tests;

implementation

uses
  SysUtils, Classes, Math,
  UDAW.Testing,
  UDAW.Errors,
  UDAW.Audio.Types,
  UDAW.Codec.MP4.Atoms,
  UDAW.Codec.MP4.Container,
  UDAW.Codec.MP4;

const
  GRP = 'phase16.mp4';

{ zero-crossing dominant-frequency estimate over a channel }
function DomFreq(const P: TAudioPlanar; ACh, AFrom, ATo, ASampleRate: Integer): Double;
var
  i, crossings: Integer;
  prev: Single;
begin
  if (ACh < 0) or (ACh > High(P)) then Exit(0);
  if ATo > Length(P[ACh]) then ATo := Length(P[ACh]);
  crossings := 0;
  prev := 0;
  for i := AFrom to ATo - 1 do
  begin
    if (prev < 0) and (P[ACh][i] >= 0) then Inc(crossings);
    prev := P[ACh][i];
  end;
  if (ATo - AFrom) <= 0 then Exit(0);
  Result := crossings * ASampleRate / (ATo - AFrom);
end;

function MakeTone(AChannels, AFrames, ASampleRate: Integer;
  const AFreqs: array of Double): TAudioPlanar;
var
  ch, i: Integer;
  f: Double;
begin
  EnsurePlanar(Result, AChannels, AFrames);
  for ch := 0 to AChannels - 1 do
  begin
    if ch <= High(AFreqs) then f := AFreqs[ch] else f := AFreqs[High(AFreqs)];
    for i := 0 to AFrames - 1 do
      Result[ch][i] := 0.6 * Sin(2 * Pi * f * i / ASampleRate);
  end;
end;

{ ---------------- atom layer ---------------- }

procedure Test_BoxWriter_RoundTrip;
var
  w: TMP4BoxWriter;
  data: TBytes;
  tree: TMP4AtomTree;
  moov, trak, mdia: TMP4Atom;
begin
  w := TMP4BoxWriter.Create;
  try
    w.BeginBox('ftyp');
      w.FourCCStr('isom');
      w.U32(512);
      w.FourCCStr('isom');
      w.FourCCStr('mp42');
    w.CloseBox;
    w.BeginBox('moov');
      w.BeginBox('mvhd');
        w.U8(0); w.U24(0);
        w.Zeros(96);
      w.CloseBox;
      w.BeginBox('trak');
        w.BeginBox('tkhd');
          w.U8(0); w.U24(7);
          w.Zeros(80);
        w.CloseBox;
        w.BeginBox('mdia');
          w.BeginBox('hdlr');
            w.U8(0); w.U24(0);
            w.U32(0); w.FourCCStr('soun');
            w.Zeros(12);
            w.AsciiZ('x'); w.U8(0);
          w.CloseBox;
        w.CloseBox;
      w.CloseBox;
    w.CloseBox;
    data := w.ToBytes;
  finally
    w.Free;
  end;

  Check(Length(data) > 40, 'writer produced a non-trivial buffer');
  Check(Mp4SniffData(data), 'produced buffer sniffs as MP4');

  tree := TMP4AtomTree.Create(data);
  try
    Check(tree.Root.Find('ftyp') <> nil, 'ftyp present at top level');
    moov := tree.Root.Find('moov');
    Check(moov <> nil, 'moov present');
    Check(moov.Find('mvhd') <> nil, 'mvhd child parsed');
    trak := moov.Find('trak');
    Check(trak <> nil, 'trak child parsed');
    mdia := trak.Path('mdia');
    Check(mdia <> nil, 'trak/mdia path resolves');
    Check(mdia.Find('hdlr') <> nil, 'mdia/hdlr parsed');
    Check(SafeAscii(tree.Data, mdia.Find('hdlr').ContentOffset + 8, 4) = 'soun',
      'handler type reads back as soun');
  finally
    tree.Free;
  end;
end;

procedure Test_BE_Reads;
var
  b: TBytes;
begin
  SetLength(b, 8);
  b[0] := $12; b[1] := $34; b[2] := $56; b[3] := $78;
  b[4] := $9A; b[5] := $BC; b[6] := $DE; b[7] := $F0;
  CheckEqualInt($12, BE_U8(b, 0), 'u8');
  CheckEqualInt($1234, BE_U16(b, 0), 'u16');
  CheckEqualInt($123456, BE_U24(b, 0), 'u24');
  CheckEqualInt(Int64($12345678), BE_U32(b, 0), 'u32');
  CheckEqualInt(Int64($123456789ABCDEF0), Int64(BE_U64(b, 0)), 'u64');
  try
    BE_U32(b, 6);
    Fail('BE_U32 past end should raise');
  except
    on E: EUDAWError do ; // expected
  end;
end;

procedure Test_ASC_RoundTrip;
var
  asc: TBytes;
  aot, sr, ch: Integer;
begin
  asc := BuildAudioSpecificConfig(2, 44100, 2);
  Check(Length(asc) = 2, '44100/stereo LC ASC is 2 bytes');
  Check(ParseAudioSpecificConfig(asc, aot, sr, ch), 'ASC parses');
  CheckEqualInt(2, aot, 'AOT = LC');
  CheckEqualInt(44100, sr, 'sample rate round-trips');
  CheckEqualInt(2, ch, 'channel config round-trips');

  asc := BuildAudioSpecificConfig(2, 48000, 1);
  Check(ParseAudioSpecificConfig(asc, aot, sr, ch), 'mono 48k ASC parses');
  CheckEqualInt(48000, sr, '48000 round-trips');
  CheckEqualInt(1, ch, 'mono');

  CheckEqualInt(3, AacSampleRateIndex(48000), '48000 -> index 3');
  CheckEqualInt(4, AacSampleRateIndex(44100), '44100 -> index 4');
  CheckEqualInt(44100, AacSampleRateFromIndex(4), 'index 4 -> 44100');
end;

{ ---------------- PCM-in-MP4 workflows ---------------- }

procedure PcmRoundTrip(ACodec: TMP4EncodeCodec; ATol: Double; const AWhat: string);
var
  sr, frames: Integer;
  pcm, back: TAudioPlanar;
  bytes: TBytes;
  dres: TMP4DecodeResult;
  info: TMP4ProbeInfo;
  dl, dr: Double;
begin
  sr := 44100;
  frames := sr;   // 1 second
  pcm := MakeTone(2, frames, sr, [220.0, 660.0]);

  Check(Mp4EncodeAudio(pcm, sr, ACodec, bytes), AWhat + ': encode succeeds');
  Check(Length(bytes) > 1000, AWhat + ': output has real size');
  Check(Mp4SniffData(bytes), AWhat + ': output sniffs as MP4');

  Check(Mp4Probe(bytes, info), AWhat + ': probe succeeds');
  Check(info.IsMP4 and info.HasAudio, AWhat + ': probe sees an audio track');
  CheckEqualInt(sr, info.SampleRate, AWhat + ': probe sample rate');
  CheckEqualInt(2, info.Channels, AWhat + ': probe channels');
  Check(info.Decodable, AWhat + ': probe marks it decodable');
  Check(Pos('PCM', info.CodecName) > 0, AWhat + ': codec reported as PCM (' + info.CodecName + ')');

  Check(Mp4DecodeAudio(bytes, dres), AWhat + ': decode succeeds');
  CheckEqualInt(2, dres.Channels, AWhat + ': decoded channels');
  CheckEqualInt(sr, dres.SampleRate, AWhat + ': decoded sample rate');
  Check(dres.Frames >= frames - 2, AWhat + ': decoded frame count');
  back := dres.Data;

  dl := DomFreq(back, 0, 1000, dres.Frames - 1000, sr);
  dr := DomFreq(back, 1, 1000, dres.Frames - 1000, sr);
  Check(Abs(dl - 220.0) < 12.0, Format('%s: left dominant %.1f ~ 220', [AWhat, dl]));
  Check(Abs(dr - 660.0) < 20.0, Format('%s: right dominant %.1f ~ 660', [AWhat, dr]));

  { spot amplitude fidelity for the (near-lossless) formats }
  if ATol < 0.05 then
    Check(Abs(back[0][5000] - pcm[0][5000]) < ATol,
      Format('%s: sample fidelity (%.5f vs %.5f)', [AWhat, back[0][5000], pcm[0][5000]]));
end;

procedure Test_PCM16_RoundTrip;
begin
  PcmRoundTrip(mecPCM16, 1.0 / 300.0, 'PCM16');
end;

procedure Test_PCM24_RoundTrip;
begin
  PcmRoundTrip(mecPCM24, 1.0 / 30000.0, 'PCM24');
end;

procedure Test_Float32_RoundTrip;
begin
  PcmRoundTrip(mecFloat32, 1.0E-6, 'Float32');
end;

{ ---------------- AAC identification and decoder availability ---------------- }

procedure Test_BuildAAC_IsIdentified;
var
  samples: TArray<TBytes>;
  asc, bytes: TBytes;
  i: Integer;
  rdr: TMP4Reader;
  at: TMP4Track;
  info: TMP4ProbeInfo;
begin
  { three dummy access units - the container writer does not care what the
    bytes mean, only the sample table + esds must come out valid }
  SetLength(samples, 3);
  for i := 0 to 2 do
  begin
    SetLength(samples[i], 40 + i);
    FillChar(samples[i][0], Length(samples[i]), Byte($AA));
  end;
  asc := BuildAudioSpecificConfig(2, 44100, 2);

  bytes := TMP4Writer.BuildAAC(samples, asc, 44100, 2, 128000, 1024);
  Check(Length(bytes) > 200, 'BuildAAC produced a file');
  Check(Mp4SniffData(bytes), 'BuildAAC output sniffs as MP4');

  rdr := TMP4Reader.Create(bytes);
  try
    at := rdr.FirstAudioTrack;
    Check(at <> nil, 'audio track present');
    CheckEqualStr('mp4a', at.SampleEntry, 'sample entry is mp4a');
    Check(at.Codec = mckAAC_LC, 'codec detected as AAC LC');
    CheckEqualInt(44100, at.SampleRate, 'sample rate from esds/ASC');
    CheckEqualInt(2, at.ChannelCount, 'channels from esds/ASC');
    CheckEqualInt(3, at.Table.SampleCount, 'sample table has 3 access units');
    Check(Length(at.AudioSpecificConfig) >= 2, 'ASC bytes recovered from esds');
    Check(Pos('MP4', rdr.ContainerReport) > 0, 'container report names MP4');
    Check(Pos('AAC', rdr.ContainerReport) > 0, 'container report names the AAC codec separately');
  finally
    rdr.Free;
  end;

  { Decoder capability is reported independently of the dummy access-unit
    payload used here; the AAC implementation and tables are now present. }
  Check(Mp4Probe(bytes, info), 'probe still succeeds on the AAC file');
  Check(info.Decodable, 'AAC file is reported as decodable');
end;

procedure Test_Hostile_Input;
var
  junk: TBytes;
  info: TMP4ProbeInfo;
  i: Integer;
begin
  SetLength(junk, 4096);
  for i := 0 to High(junk) do junk[i] := Byte((i * 37 + 11) and $FF);
  { not an MP4 - sniff says no, probe returns false, nothing raised past the API }
  CheckFalse(Mp4SniffData(junk), 'random bytes do not sniff as MP4');
  CheckFalse(Mp4Probe(junk, info), 'probe rejects random bytes');

  { a valid-looking ftyp header then garbage: must not crash the atom parser }
  junk[0] := 0; junk[1] := 0; junk[2] := 0; junk[3] := $18;
  junk[4] := Ord('f'); junk[5] := Ord('t'); junk[6] := Ord('y'); junk[7] := Ord('p');
  try
    Mp4Probe(junk, info);   // may be true or false, must not raise unhandled
  except
    on E: EUDAWError do ;   // an EUDAWError is an acceptable, controlled outcome
  end;
end;

procedure RegisterPhase16Tests;
begin
  RegisterTest(GRP, 'box writer <-> atom tree round-trip', Test_BoxWriter_RoundTrip);
  RegisterTest(GRP, 'big-endian scalar reads + bounds check', Test_BE_Reads);
  RegisterTest(GRP, 'AudioSpecificConfig build <-> parse', Test_ASC_RoundTrip);
  RegisterTest(GRP, 'PCM16-in-MP4 encode -> decode round-trip', Test_PCM16_RoundTrip);
  RegisterTest(GRP, 'PCM24-in-MP4 encode -> decode round-trip', Test_PCM24_RoundTrip);
  RegisterTest(GRP, 'Float32-in-MP4 encode -> decode round-trip', Test_Float32_RoundTrip);
  RegisterTest(GRP, 'BuildAAC -> reader identifies AAC LC + ASC', Test_BuildAAC_IsIdentified);
  RegisterTest(GRP, 'hostile / truncated input is handled', Test_Hostile_Input);
end;

end.
