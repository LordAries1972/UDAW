unit UDAW.Codec.AAC.Types;
{$I udaw.inc}
{$POINTERMATH ON}

{ Phase 16b - AAC support (plan section 19: "treat MP4 correctly as a
  CONTAINER", and decode the AAC it carries).

  Shared vocabulary for the from-scratch AAC decoder / encoder:
    * the MSB-first bit reader the whole AAC stack reads through
      (raw_data_block, ADTS, ASC - AAC is a big-endian bit syntax);
    * the Audio Object Type (AOT) and sampling-frequency-index tables;
    * TAacAudioConfig + ParseAudioSpecificConfig: the 2-5 byte
      AudioSpecificConfig / DecoderSpecificInfo that an MP4 esds (or an
      ADTS header, synthesised) carries - object type, rate, channel
      configuration, 960/1024 frame length, and the SBR / PS explicit or
      implicit signalling.

  Nothing here trusts a length field: every read is bounds-guarded and a bad
  config raises EUDAWError(errConfig / errNotImplemented) naming what was seen. }

interface

uses
  SysUtils,
  UDAW.Errors;

const
  AAC_SUBSYS = 'Codec.AAC';

  { Audio Object Type (ISO/IEC 14496-3 Table 1.17, subset we name) }
  AOT_NULL            = 0;
  AOT_AAC_MAIN        = 1;
  AOT_AAC_LC          = 2;
  AOT_AAC_SSR         = 3;
  AOT_AAC_LTP         = 4;
  AOT_SBR             = 5;
  AOT_AAC_SCALABLE    = 6;
  AOT_TWINVQ          = 7;
  AOT_ER_AAC_LC       = 17;
  AOT_ER_AAC_LTP      = 19;
  AOT_ER_AAC_LD       = 23;
  AOT_PS              = 29;
  AOT_AAC_ELD         = 39;

  { window_sequence (ISO 14496-3 Table 4.53) }
  WS_ONLY_LONG        = 0;
  WS_LONG_START       = 1;
  WS_EIGHT_SHORT      = 2;
  WS_LONG_STOP        = 3;

  { window_shape }
  WSHAPE_SINE         = 0;
  WSHAPE_KBD          = 1;

  { syntactic element id_syn_ele (ISO 14496-3 Table 4.71) }
  ID_SCE = 0;   // single channel element
  ID_CPE = 1;   // channel pair element
  ID_CCE = 2;   // coupling channel element
  ID_LFE = 3;   // low frequency effects element
  ID_DSE = 4;   // data stream element
  ID_PCE = 5;   // program config element
  ID_FIL = 6;   // fill element
  ID_END = 7;   // terminator

  { number of scalefactor window bands is codebook-dependent; hard ceilings }
  AAC_MAX_SFB_LONG   = 51;
  AAC_MAX_SFB_SHORT  = 15;
  AAC_MAX_WINDOWS    = 8;
  AAC_SHORT_WIN_LEN  = 128;
  AAC_LONG_WIN_LEN   = 1024;
  AAC_SHORT_WIN_LEN_960 = 120;
  AAC_LONG_WIN_LEN_960  = 960;
  AAC_MAX_CHANNELS   = 8;

  { sampling_frequency_index -> Hz  (ISO 14496-3 Table 4.68). 13/14 reserved,
    15 = "escape: 24 bits follow". }
  AAC_SAMPLE_RATES: array[0..14] of Integer = (
    96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050,
    16000, 12000, 11025, 8000, 7350, 0, 0);

type
  { MSB-first reader over a byte buffer.  Reads past the end return 0 bits and
    set Overrun (callers check ByteAligned / Overrun rather than faulting). }
  TAacBitReader = record
  private
    FData: PByte;
    FLen: Integer;
    FBitPos: Int64;          // absolute bit offset from the buffer start
    FOverrun: Boolean;
  public
    procedure Init(AData: PByte; ALenBytes: Integer; AStartBit: Int64 = 0);
    function ReadBit: Cardinal;
    function ReadBits(ACount: Integer): Cardinal;      // 0..32
    function PeekBits(ACount: Integer): Cardinal;
    procedure SkipBits(ACount: Integer);
    function ByteAlign: Integer;                       // bits skipped
    function BitPosition: Int64;
    procedure SetBitPosition(ABit: Int64);
    function BitsLeft: Int64;
    function BytesLeft: Integer;
    property Overrun: Boolean read FOverrun;
    property LengthBytes: Integer read FLen;
  end;

  TAacExtension = (aeNone, aeSBR, aeSBR_PS);

  TAacAudioConfig = record
    ObjectType: Integer;          // the base AOT (LC=2 etc.)
    SampleRateIndex: Integer;
    SampleRate: Integer;          // Hz (already resolved through the escape)
    ChannelConfig: Integer;       // 0 = defined by PCE; 1..7 standard layouts
    Channels: Integer;            // resolved output channel count (0 if PCE-defined)
    FrameLength: Integer;         // 1024 (long) or 960
    Extension: TAacExtension;     // SBR / PS explicitly or implicitly present
    ExtObjectType: Integer;       // AOT carried after the SBR sync (usually LC)
    ExtSampleRateIndex: Integer;
    ExtSampleRate: Integer;       // the doubled rate SBR reconstructs at
    DependsOnCoreCoder: Boolean;
    Raw: TBytes;                  // the ASC bytes as received
    function Describe: string;
  end;

{ Resolve a sampling_frequency_index (0..15) plus, for index 15, the 24-bit
  explicit rate that followed, to Hz.  Returns 0 for the reserved indices. }
function AacRateFromIndex(AIndex: Integer; AExplicit: Integer = 0): Integer;
function AacIndexFromRate(ARate: Integer): Integer;   // -1 if not a table rate

{ standard channel count for channelConfiguration 1..7 (0 -> 0, "see PCE") }
function AacChannelsForConfig(AConfig: Integer): Integer;

{ Parse an AudioSpecificConfig / DecoderSpecificInfo (>= 2 bytes).  Handles the
  5-bit / 6-bit escaped AOT, the frame-length flag, coreCoderDelay, and the
  explicit backward-compatible SBR (AOT 5) + PS (AOT 29) signalling as well as
  the implicit case (caller may still discover SBR inside the first frame). }
function ParseAudioSpecificConfig(const AAsc: TBytes; out ACfg: TAacAudioConfig): Boolean;

{ Build a minimal 2-byte ASC for a plain AOT/rate/channel-config triple - used
  when only an ADTS header is available. }
function BuildAudioSpecificConfig(AObjectType, ASampleRate, AChannelConfig: Integer): TBytes;

implementation

{ ============================ TAacBitReader ====================== }

procedure TAacBitReader.Init(AData: PByte; ALenBytes: Integer; AStartBit: Int64);
begin
  FData := AData;
  FLen := ALenBytes;
  if FLen < 0 then FLen := 0;
  FBitPos := AStartBit;
  if FBitPos < 0 then FBitPos := 0;
  FOverrun := False;
end;

function TAacBitReader.ReadBit: Cardinal;
var
  bytePos, bitInByte: Int64;
begin
  bytePos := FBitPos shr 3;
  bitInByte := 7 - (FBitPos and 7);
  if (FData = nil) or (bytePos >= FLen) then
  begin
    FOverrun := True;
    Inc(FBitPos);
    Exit(0);
  end;
  Result := (FData[bytePos] shr bitInByte) and 1;
  Inc(FBitPos);
end;

function TAacBitReader.ReadBits(ACount: Integer): Cardinal;
var
  i: Integer;
begin
  Result := 0;
  if ACount <= 0 then Exit;
  if ACount > 32 then ACount := 32;
  for i := 0 to ACount - 1 do
    Result := (Result shl 1) or ReadBit;
end;

function TAacBitReader.PeekBits(ACount: Integer): Cardinal;
var
  save: Int64;
  saveOv: Boolean;
begin
  save := FBitPos;
  saveOv := FOverrun;
  Result := ReadBits(ACount);
  FBitPos := save;
  FOverrun := saveOv;
end;

procedure TAacBitReader.SkipBits(ACount: Integer);
begin
  if ACount <= 0 then Exit;
  Inc(FBitPos, ACount);
  if (FData = nil) or ((FBitPos + 7) shr 3 > FLen) then
    FOverrun := FOverrun or ((FBitPos shr 3) >= FLen);
end;

function TAacBitReader.ByteAlign: Integer;
begin
  Result := Integer((8 - (FBitPos and 7)) and 7);
  Inc(FBitPos, Result);
end;

function TAacBitReader.BitPosition: Int64;
begin
  Result := FBitPos;
end;

procedure TAacBitReader.SetBitPosition(ABit: Int64);
begin
  if ABit < 0 then ABit := 0;
  FBitPos := ABit;
end;

function TAacBitReader.BitsLeft: Int64;
begin
  Result := Int64(FLen) * 8 - FBitPos;
  if Result < 0 then Result := 0;
end;

function TAacBitReader.BytesLeft: Integer;
begin
  Result := FLen - Integer(FBitPos shr 3);
  if Result < 0 then Result := 0;
end;

{ ============================ rate / channel helpers ============= }

function AacRateFromIndex(AIndex: Integer; AExplicit: Integer): Integer;
begin
  if AIndex = 15 then
    Result := AExplicit
  else if (AIndex >= 0) and (AIndex <= 12) then
    Result := AAC_SAMPLE_RATES[AIndex]
  else
    Result := 0;
end;

function AacIndexFromRate(ARate: Integer): Integer;
var
  i: Integer;
begin
  for i := 0 to 12 do
    if AAC_SAMPLE_RATES[i] = ARate then Exit(i);
  Result := -1;
end;

function AacChannelsForConfig(AConfig: Integer): Integer;
begin
  case AConfig of
    1: Result := 1;   // C
    2: Result := 2;   // L R
    3: Result := 3;   // C L R
    4: Result := 4;   // C L R  Cs
    5: Result := 5;   // C L R  Ls Rs
    6: Result := 6;   // C L R  Ls Rs  LFE
    7: Result := 8;   // C L R  Ls Rs  Lsr Rsr  LFE
  else
    Result := 0;      // 0 = defined by a program_config_element
  end;
end;

{ ============================ AudioSpecificConfig =============== }

function ReadAudioObjectType(var ABr: TAacBitReader): Integer;
begin
  Result := ABr.ReadBits(5);
  if Result = 31 then
    Result := 32 + ABr.ReadBits(6);
end;

function TAacAudioConfig.Describe: string;
begin
  Result := Format('AAC AOT %d, %d Hz, chan-cfg %d (%d ch), frame %d',
    [ObjectType, SampleRate, ChannelConfig, Channels, FrameLength]);
  case Extension of
    aeSBR:    Result := Result + ' + SBR';
    aeSBR_PS: Result := Result + ' + SBR + PS';
  end;
end;

function ParseAudioSpecificConfig(const AAsc: TBytes; out ACfg: TAacAudioConfig): Boolean;
var
  br: TAacBitReader;
  sfi, extSfi, extAot, syncExt: Integer;
  frameLenFlag, dependsCore: Boolean;
begin
  FillChar(ACfg, SizeOf(ACfg), 0);
  if Length(AAsc) < 2 then
    RaiseUDAWFmt(errConfig, AAC_SUBSYS,
      'AudioSpecificConfig too short (%d bytes, need >= 2)', [Length(AAsc)]);
  ACfg.Raw := Copy(AAsc, 0, Length(AAsc));

  br.Init(@AAsc[0], Length(AAsc), 0);
  ACfg.ObjectType := ReadAudioObjectType(br);
  sfi := br.ReadBits(4);
  ACfg.SampleRateIndex := sfi;
  if sfi = 15 then
    ACfg.SampleRate := br.ReadBits(24)
  else
    ACfg.SampleRate := AacRateFromIndex(sfi);
  ACfg.ChannelConfig := br.ReadBits(4);
  ACfg.Channels := AacChannelsForConfig(ACfg.ChannelConfig);

  ACfg.Extension := aeNone;
  ACfg.ExtObjectType := 0;
  ACfg.ExtSampleRate := ACfg.SampleRate;

  { explicit backward-compatible SBR / PS signalling: AOT 5 or 29 up front }
  if (ACfg.ObjectType = AOT_SBR) or (ACfg.ObjectType = AOT_PS) then
  begin
    if ACfg.ObjectType = AOT_PS then
      ACfg.Extension := aeSBR_PS
    else
      ACfg.Extension := aeSBR;
    extSfi := br.ReadBits(4);
    ACfg.ExtSampleRateIndex := extSfi;
    if extSfi = 15 then
      ACfg.ExtSampleRate := br.ReadBits(24)
    else
      ACfg.ExtSampleRate := AacRateFromIndex(extSfi);
    extAot := ReadAudioObjectType(br);
    ACfg.ExtObjectType := extAot;
    { the GASpecificConfig that follows belongs to extAot }
    ACfg.ObjectType := extAot;
  end;

  { GASpecificConfig (AOT 1..4, 6, 7, 17, 19..23) : frameLengthFlag,
    dependsOnCoreCoder, extensionFlag }
  case ACfg.ObjectType of
    AOT_AAC_MAIN, AOT_AAC_LC, AOT_AAC_SSR, AOT_AAC_LTP, AOT_AAC_SCALABLE,
    AOT_TWINVQ, AOT_ER_AAC_LC, AOT_ER_AAC_LTP, AOT_ER_AAC_LD:
      begin
        frameLenFlag := br.ReadBit = 1;
        dependsCore := br.ReadBit = 1;
        if dependsCore then
          br.SkipBits(14);                 // coreCoderDelay
        ACfg.DependsOnCoreCoder := dependsCore;
        br.SkipBits(1);                    // extensionFlag (ignored for LC)
        if frameLenFlag then
          ACfg.FrameLength := AAC_LONG_WIN_LEN_960
        else
          ACfg.FrameLength := AAC_LONG_WIN_LEN;
        if ACfg.ChannelConfig = 0 then
          { program_config_element would be here; the decoder reads a PCE from
            the first raw_data_block instead. Leave Channels = 0. }
          ;
      end;
  else
    ACfg.FrameLength := AAC_LONG_WIN_LEN;
  end;

  { trailing syncExtensionType 0x2b7 -> explicit SBR after a plain LC ASC }
  if (ACfg.Extension = aeNone) and (br.BitsLeft >= 16) then
  begin
    syncExt := br.ReadBits(11);
    if syncExt = $2B7 then
    begin
      extAot := ReadAudioObjectType(br);
      if extAot = AOT_SBR then
      begin
        if br.ReadBit = 1 then                       // sbrPresentFlag
        begin
          ACfg.Extension := aeSBR;
          extSfi := br.ReadBits(4);
          ACfg.ExtSampleRateIndex := extSfi;
          if extSfi = 15 then
            ACfg.ExtSampleRate := br.ReadBits(24)
          else
            ACfg.ExtSampleRate := AacRateFromIndex(extSfi);
          if br.BitsLeft >= 12 then
          begin
            syncExt := br.ReadBits(11);
            if syncExt = $548 then
              if br.ReadBit = 1 then
                ACfg.Extension := aeSBR_PS;
          end;
        end;
      end;
    end;
  end;

  if ACfg.ExtSampleRate = 0 then ACfg.ExtSampleRate := ACfg.SampleRate * 2;
  Result := True;
end;

function BuildAudioSpecificConfig(AObjectType, ASampleRate, AChannelConfig: Integer): TBytes;
var
  idx: Integer;
  b0, b1: Byte;
begin
  idx := AacIndexFromRate(ASampleRate);
  if idx < 0 then idx := 4;                 // fall back to 44.1k index
  if AObjectType < 1 then AObjectType := AOT_AAC_LC;
  { 5 bits AOT | 4 bits sfIndex | 4 bits chanCfg | 3 bits (frameLen=0,
    dependsCore=0, extFlag=0) = 16 bits }
  b0 := ((AObjectType and $1F) shl 3) or ((idx shr 1) and $07);
  b1 := ((idx and $01) shl 7) or ((AChannelConfig and $0F) shl 3);
  SetLength(Result, 2);
  Result[0] := b0;
  Result[1] := b1;
end;

end.
