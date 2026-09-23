unit Tests.Phase16b;
{$IFDEF FPC}{$MODE DELPHI}{$MODESWITCH ADVANCEDRECORDS}{$H+}{$ENDIF}
{$POINTERMATH ON}

{ Phase 16b acceptance tests - the AAC subsystem that can be verified without
  reference media:

    * TAacBitReader MSB-first read / peek / byte-align / overrun;
    * AudioSpecificConfig build <-> parse, incl. explicit backward-compatible
      SBR (AOT 5) signalling and the frame-length flag;
    * SWB offset tables: monotonic, terminate at 1024 / 128, count agrees with
      NumSwb*;
    * KBD / sine analysis windows: correct length, bounded, and the sine window
      satisfies the Princen-Bradley overlap identity w[i]^2 + w[i+N/2]^2 = 1;
    * the Huffman self-check (Test_TablesGateAndRefuse still exercises both
      branches: it names a book if a table is ever short/malformed, and now
      that UDAW.Codec.AAC.HuffData.inc is populated from FFmpeg's
      ff_aac_scalefactor_bits/code + bits1..11/codes1..11 - the ISO/IEC
      14496-3:2009 4.A.1..4.A.12 transcription - it confirms AacTablesReady
      and skips the refusal-only assertions);
    * ADTS: a hand-built header is sniffed, probed (rate / channels / frame
      count) and its frames are walked. }

interface

procedure RegisterPhase16bTests;

implementation

uses
  SysUtils, Classes, Math,
  UDAW.Testing,
  UDAW.Errors,
  UDAW.Audio.Types,
  UDAW.Codec.AAC.Types,
  UDAW.Codec.AAC.Tables,
  UDAW.Codec.AAC.Decoder,
  UDAW.Codec.AAC;

const
  GRP = 'phase16b.aac';

{ ---------------- bit reader ---------------- }

procedure Test_BitReader_MSBFirst;
var
  buf: array[0..3] of Byte;
  br: TAacBitReader;
begin
  buf[0] := $B5;  // 1011 0101
  buf[1] := $2C;  // 0010 1100
  buf[2] := $FF;
  buf[3] := $00;
  br.Init(@buf[0], 4, 0);
  CheckEqualInt(1, br.ReadBit, 'bit 0');
  CheckEqualInt(0, br.ReadBit, 'bit 1');
  CheckEqualInt(1, br.ReadBit, 'bit 2');
  CheckEqualInt(1, br.ReadBit, 'bit 3');
  CheckEqualInt($5, br.ReadBits(4), 'low nibble of byte 0');
  CheckEqualInt($2C, br.ReadBits(8), 'byte 1');
  CheckEqualInt(16, br.BitPosition, 'position after 16 bits');
  CheckEqualInt($FF, br.PeekBits(8), 'peek does not advance');
  CheckEqualInt(16, br.BitPosition, 'still 16 after peek');
  br.SkipBits(8);
  br.ByteAlign;
  CheckEqualInt(24, br.BitPosition, 'byte aligned');
  br.SkipBits(64);
  Check(br.Overrun, 'overrun flagged past the end');
  CheckEqualInt(0, br.ReadBits(4), 'reads past the end return 0');
end;

{ ---------------- AudioSpecificConfig ---------------- }

procedure Test_ASC_BuildParse;
var
  asc: TBytes;
  cfg: TAacAudioConfig;
begin
  asc := BuildAudioSpecificConfig(AOT_AAC_LC, 44100, 2);
  CheckEqualInt(2, Length(asc), 'plain ASC is 2 bytes');
  Check(ParseAudioSpecificConfig(asc, cfg), 'ASC parses');
  CheckEqualInt(AOT_AAC_LC, cfg.ObjectType, 'AOT LC');
  CheckEqualInt(4, cfg.SampleRateIndex, '44100 -> index 4');
  CheckEqualInt(44100, cfg.SampleRate, 'rate resolved');
  CheckEqualInt(2, cfg.ChannelConfig, 'chan cfg 2');
  CheckEqualInt(2, cfg.Channels, '2 channels');
  CheckEqualInt(1024, cfg.FrameLength, 'long frame');
  Check(cfg.Extension = aeNone, 'no SBR');
end;

procedure Test_ASC_ExplicitSBR;
var
  asc: TBytes;
  cfg: TAacAudioConfig;
begin
  { GetAudioSpecificConfig's real field order (ISO/IEC 14496-3 §1.6.2.1,
    matching ParseAudioSpecificConfig below) reads sfIndex/channelConfig
    for the OUTER object type BEFORE the SBR extension fields, not after:
      audioObjectType (5)
      samplingFrequencyIndex (4)
      channelConfiguration (4)
      if audioObjectType == 5 (SBR): extensionSamplingFrequencyIndex (4),
                                      audioObjectType [core] (5)
      GASpecificConfig of the (now core) audioObjectType: frameLengthFlag,
      dependsOnCoreCoder, extensionFlag (3 bits, all 0 here)
    AOT 5 (SBR), sfIndex 4 (44.1k), chanCfg 2, extSfIndex 3 (48k),
    core AOT 2 (LC), GA flags 000. Pack MSB-first:
      00101 0100 0010 0011 00010 000  = 25 bits -> 4 bytes }
  SetLength(asc, 4);
  asc[0] := $2A;   // 0010 1010
  asc[1] := $11;   // 0001 0001
  asc[2] := $88;   // 1000 1000
  asc[3] := $00;
  Check(ParseAudioSpecificConfig(asc, cfg), 'SBR ASC parses');
  Check(cfg.Extension = aeSBR, 'SBR extension detected');
  Check(cfg.ObjectType = AOT_AAC_LC, 'core AOT after SBR sync is LC');
  Check(cfg.ExtSampleRate >= cfg.SampleRate, 'SBR output rate >= core rate');
end;

{ ---------------- SWB tables ---------------- }

procedure Test_SWB_Monotonic;
var
  sri, i: Integer;
  a: TArray<Integer>;
begin
  for sri := 0 to 11 do
  begin
    a := SwbOffsetLong(sri);
    Check(Length(a) >= 2, 'long swb table has entries');
    CheckEqualInt(0, a[0], 'long swb starts at 0');
    Check(a[High(a)] = 1024, Format('long swb[%d] ends at 1024', [sri]));
    for i := 1 to High(a) do
      Check(a[i] > a[i - 1], Format('long swb[%d] monotonic at %d', [sri, i]));
    CheckEqualInt(Length(a) - 1, NumSwbLong(sri), 'NumSwbLong agrees');

    a := SwbOffsetShort(sri);
    CheckEqualInt(0, a[0], 'short swb starts at 0');
    Check(a[High(a)] = 128, Format('short swb[%d] ends at 128', [sri]));
    for i := 1 to High(a) do
      Check(a[i] > a[i - 1], Format('short swb[%d] monotonic at %d', [sri, i]));
    CheckEqualInt(Length(a) - 1, NumSwbShort(sri), 'NumSwbShort agrees');
  end;
end;

{ ---------------- windows ---------------- }

procedure Test_Windows;
var
  w: TArray<Double>;
  i, n2: Integer;
  s: Double;
begin
  GetWindow(True, WSHAPE_SINE, False, w);
  CheckEqualInt(2048, Length(w), 'long window length 2048');
  n2 := 1024;
  for i := 0 to n2 - 1 do
  begin
    Check((w[i] >= 0) and (w[i] <= 1.0001), 'window value in [0,1]');
    s := w[i] * w[i] + w[i + n2] * w[i + n2];
    CheckNear(1.0, s, 1.0E-6, Format('Princen-Bradley overlap identity at %d', [i]));
  end;

  GetWindow(False, WSHAPE_KBD, False, w);
  CheckEqualInt(256, Length(w), 'short KBD window length 256');
  Check((w[0] > 0) and (w[0] < w[64]), 'KBD window rises from the edge');
end;

{ ---------------- table gate ---------------- }

procedure Test_TablesGateAndRefuse;
var
  err: string;
  ok: Boolean;
  asc: TBytes;
  units: array of TBytes;
  res: TAACDecodeResult;
  raised: Boolean;
begin
  InitAacTables;
  ok := HuffBooksSelfCheck(err);
  { with the stub HuffData the self-check MUST fail and name a book }
  if not ok then
    Check(Pos('book', LowerCase(err)) > 0, 'self-check error names a book: ' + err)
  else
    Check(True, 'Huffman tables are populated - spectral decode is live');

  CheckEqualBool(ok, AacTablesReady, 'AacTablesReady mirrors the self-check');

  if not ok then
  begin
    asc := BuildAudioSpecificConfig(AOT_AAC_LC, 44100, 2);
    SetLength(units, 1);
    SetLength(units[0], 16);
    raised := False;
    try
      AacDecodeRaw(asc, units, res);
    except
      on E: EUDAWError do
      begin
        raised := True;
        Check(Pos('HuffData', E.Message) > 0, 'refusal names HuffData.inc');
      end;
    end;
    Check(raised, 'AacDecodeRaw refuses while tables are stubbed');
  end;
end;

{ ---------------- ADTS ---------------- }

function BuildAdtsFrame(ASfIndex, AChanCfg, APayloadLen: Integer): TBytes;
var
  frameLen: Integer;
  p: Integer;
begin
  frameLen := 7 + APayloadLen;
  SetLength(Result, frameLen);
  { syncword 0xFFF, MPEG-4, layer 00, protection_absent 1 }
  Result[0] := $FF;
  Result[1] := $F1;                                  // 1111 0001
  { profile(2)=01 (LC), sf_index(4), private(1)=0, chan_cfg high bit }
  Result[2] := (($01) shl 6) or ((ASfIndex and $0F) shl 2) or
               ((AChanCfg shr 2) and $01);
  Result[3] := ((AChanCfg and $03) shl 6) or ((frameLen shr 11) and $03);
  Result[4] := (frameLen shr 3) and $FF;
  Result[5] := ((frameLen and $07) shl 5) or $1F;    // buffer fullness high
  Result[6] := $FC;                                   // fullness low + rdb=0
  for p := 7 to frameLen - 1 do
    Result[p] := $00;
end;

procedure Test_ADTS_SniffProbe;
var
  stream: TBytes;
  f: TBytes;
  info: TAACStreamInfo;
  i, n: Integer;
begin
  { three back-to-back LC frames, 44.1k stereo, 20-byte payloads }
  SetLength(stream, 0);
  for i := 0 to 2 do
  begin
    f := BuildAdtsFrame(4, 2, 20);
    n := Length(stream);
    SetLength(stream, n + Length(f));
    Move(f[0], stream[n], Length(f));
  end;

  Check(AacSniffData(stream), 'ADTS stream sniffs as AAC');
  Check(AacProbe(stream, info), 'ADTS stream probes');
  Check(info.IsADTS, 'flagged ADTS');
  CheckEqualInt(AOT_AAC_LC, info.ObjectType, 'ADTS profile 01 -> AOT LC (2)');
  CheckEqualInt(44100, info.SampleRate, 'ADTS 44100');
  CheckEqualInt(2, info.Channels, 'ADTS stereo');
  CheckEqualInt(3, info.FrameCount, 'walked three raw-data blocks');
end;

{ ---------------- registration ---------------- }

procedure RegisterPhase16bTests;
begin
  RegisterTest(GRP, 'AAC bit reader MSB-first / peek / align / overrun', Test_BitReader_MSBFirst);
  RegisterTest(GRP, 'AudioSpecificConfig build <-> parse', Test_ASC_BuildParse);
  RegisterTest(GRP, 'AudioSpecificConfig explicit SBR signalling', Test_ASC_ExplicitSBR);
  RegisterTest(GRP, 'SWB offset tables monotonic + terminate', Test_SWB_Monotonic);
  RegisterTest(GRP, 'KBD / sine windows + Princen-Bradley identity', Test_Windows);
  RegisterTest(GRP, 'Huffman table gate + decode refusal while stubbed', Test_TablesGateAndRefuse);
  RegisterTest(GRP, 'ADTS sniff / probe / frame walk', Test_ADTS_SniffProbe);
end;

end.
