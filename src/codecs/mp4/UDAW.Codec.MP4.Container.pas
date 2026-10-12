unit UDAW.Codec.MP4.Container;
{$I udaw.inc}
{$POINTERMATH ON}

{ Phase 16 - MP4 support (plan section 19).  The *container* subsystem built on
  UDAW.Codec.MP4.Atoms:

    TMP4SampleRef   - one media sample: file offset, byte size, decode + composition
                      timestamp (in the media timescale), sync flag.
    TMP4SampleTable - the stbl decode: stsd / stts / ctts / stsc / stsz|stz2 /
                      stco|co64 / stss folded into a flat per-sample list.
    TMP4Track       - one trak: identity, media timescale/duration, handler type,
                      and - for a sound track - the DETECTED audio codec (from
                      the sample-entry FourCC and, for 'mp4a', the esds /
                      AudioSpecificConfig), sample rate, channel count, bit depth
                      and the raw AudioSpecificConfig bytes.
    TMP4Reader      - parse a whole file: major/compatible brands, fragmented?,
                      the track list, first-audio-track helper, and a
                      container-vs-codec report string (the plan insists the two
                      are named separately and MP4 is never called a codec).
    TMP4Writer      - assemble a minimal but standards-valid MP4 from scratch:
                      ftyp + moov(mvhd,trak(...)) + mdat, for a single audio
                      track carrying either raw AAC access units (mp4a + esds)
                      or interleaved PCM ('sowt'/'in24'/'fl32').

  Every length/count read from the file is bounds- and sanity-checked before it
  is used to size an array or index the buffer: a hostile or truncated file
  fails loudly (EUDAWError) or degrades to "fewer samples", never a bad read. }

interface

uses
  UDAW.Media.Attribution, SysUtils, Classes, Math,
  UDAW.Errors,
  UDAW.Codec.MP4.Atoms;

type
  TMP4CodecKind = (
    mckUnknown,
    mckAAC_LC, mckAAC_Main, mckAAC_SSR, mckAAC_LTP,
    mckHE_AAC, mckHE_AACv2, mckAAC_LD, mckAAC_ELD, mckAAC_Scalable,
    mckALAC,
    mckMP3, mckMP2, mckMP1,
    mckAC3, mckEAC3, mckDTS, mckOpus, mckFLAC, mckAMR,
    mckPCM_S16LE, mckPCM_S16BE, mckPCM_S24LE, mckPCM_S24BE,
    mckPCM_S32LE, mckPCM_S32BE, mckPCM_F32, mckPCM_F64, mckPCM_U8,
    mckPCM_ISO
  );

  TMP4SampleRef = record
    Offset: Int64;      // absolute byte offset in the file
    Size: Int64;        // byte length of the sample / access unit
    DTS: Int64;         // decode timestamp, media timescale units
    CTS: Int64;         // composition timestamp (DTS + ctts offset)
    Sync: Boolean;      // is a random-access point (stss, or "all" when no stss)
    DescIndex: Integer; // 1-based sample_description_index (from stsc)
  end;
  TMP4SampleRefArray = TArray<TMP4SampleRef>;

  TMP4SampleTable = class
  private
    FSamples: TMP4SampleRefArray;
    FSampleCount: Integer;
    FConstantSampleDelta: Int64;   // if stts is a single run, else 0
  public
    { Decode a track's stbl.  ASampleEntryFourCC/params come from the caller
      after it has read stsd.  Raises EUDAWError only on structurally impossible
      input; a merely truncated table yields fewer samples. }
    procedure Parse(ATree: TMP4AtomTree; AStbl: TMP4Atom);
    function TotalSize: Int64;
    function DurationTicks: Int64;
    property Samples: TMP4SampleRefArray read FSamples;
    property SampleCount: Integer read FSampleCount;
    property ConstantSampleDelta: Int64 read FConstantSampleDelta;
  end;

  TMP4Track = class
  private
    FTrackID: Cardinal;
    FHandlerType: string;      // 'soun', 'vide', 'text', ...
    FMediaTimescale: Cardinal;
    FMediaDuration: Int64;
    FLanguage: string;         // ISO-639-2/T (3 chars) when decodable
    FSampleEntry: string;      // the FourCC found inside stsd
    FCodec: TMP4CodecKind;
    FCodecName: string;        // human readable, e.g. "AAC LC"
    FObjectTypeIndication: Byte;// esds OTI (0 when not present)
    FAudioObjectType: Integer; // ASC AOT (0 when not AAC)
    FSampleRate: Integer;
    FChannelCount: Integer;
    FBitsPerSample: Integer;
    FAvgBitrate: Cardinal;
    FMaxBitrate: Cardinal;
    FAudioSpecificConfig: TBytes;   // raw ASC / DecoderSpecificInfo
    FTable: TMP4SampleTable;
    FVideoWidth: Integer;
    FVideoHeight: Integer;
    FEditStartTicks: Int64;    // elst: media time the first real edit starts at (encoder priming)
    FEditLengthTicks: Int64;   // elst: that edit's length in media ticks; -1 = not stated
    procedure DetectAudioCodec(ATree: TMP4AtomTree; AStsd: TMP4Atom);
    procedure DetectVideoEntry(ATree: TMP4AtomTree; AStsd: TMP4Atom);
  public
    constructor Create;
    destructor Destroy; override;
    function IsAudio: Boolean;
    function IsVideo: Boolean;
    property VideoWidth: Integer read FVideoWidth;
    property VideoHeight: Integer read FVideoHeight;
    function DurationSeconds: Double;
    { PCM sample entries have a natural per-sample decoder here; AAC/ALAC/... are
      handed to their own codec unit. }
    function IsPCM: Boolean;
    function PCMBytesPerFrame: Integer;   // channels * container bytes/sample
    function Describe: string;
    property TrackID: Cardinal read FTrackID;
    property HandlerType: string read FHandlerType;
    property MediaTimescale: Cardinal read FMediaTimescale;
    property MediaDuration: Int64 read FMediaDuration;
    property Language: string read FLanguage;
    property SampleEntry: string read FSampleEntry;
    property Codec: TMP4CodecKind read FCodec;
    property CodecName: string read FCodecName;
    property ObjectTypeIndication: Byte read FObjectTypeIndication;
    property AudioObjectType: Integer read FAudioObjectType;
    property SampleRate: Integer read FSampleRate;
    property ChannelCount: Integer read FChannelCount;
    property BitsPerSample: Integer read FBitsPerSample;
    property AvgBitrate: Cardinal read FAvgBitrate;
    property MaxBitrate: Cardinal read FMaxBitrate;
    property AudioSpecificConfig: TBytes read FAudioSpecificConfig;
    property Table: TMP4SampleTable read FTable;
    { Edit list (elst): leading media ticks to discard, and how many media ticks
      to keep after that (-1 = to the end).  Encoders put their priming samples
      in front of the real audio and say so only here. }
    property EditStartTicks: Int64 read FEditStartTicks;
    property EditLengthTicks: Int64 read FEditLengthTicks;
  end;

  TMP4Reader = class
  private
    FTree: TMP4AtomTree;
    FMajorBrand: string;
    FCompatibleBrands: TArray<string>;
    FMovieTimescale: Cardinal;
    FMovieDuration: Int64;
    FFragmented: Boolean;
    FTracks: TArray<TMP4Track>;
    procedure ParseMoov(AMoov: TMP4Atom);
    procedure ParseTrak(ATrak: TMP4Atom);
  public
    constructor Create(const AData: TBytes);
    destructor Destroy; override;
    function TrackCount: Integer;
    function GetTrack(AIndex: Integer): TMP4Track;
    function FirstAudioTrack: TMP4Track;
    { the Nth sound track in file order (0-based); nil past the last }
    function AudioTrackAt(AIndex: Integer): TMP4Track;
    function AudioTrackCount: Integer;
    function FirstVideoTrack: TMP4Track;
    { "Container: MP4 (brand ...)  |  Audio codec: AAC LC 44100 Hz 2 ch" }
    function ContainerReport: string;
    function Describe: string;
    property Tree: TMP4AtomTree read FTree;
    property MajorBrand: string read FMajorBrand;
    property CompatibleBrands: TArray<string> read FCompatibleBrands;
    property MovieTimescale: Cardinal read FMovieTimescale;
    property MovieDuration: Int64 read FMovieDuration;
    property Fragmented: Boolean read FFragmented;
  end;

  { What the writer should put in the sample-description box. }
  TMP4WriteCodec = (
    mwcAAC_LC,        // mp4a + esds(ASC), samples are raw AAC access units
    mwcPCM_S16LE,     // 'sowt'
    mwcPCM_S24LE,     // 'in24'
    mwcPCM_F32LE      // 'fl32'
  );

  TMP4Writer = class
  public
    { AAC: ASamples is a list of raw access units (1024 PCM frames each),
      AAudioSpecificConfig is the 2..5 byte ASC to embed in esds.
      Returns the finished file bytes.  ADurationPerSample defaults to 1024. }
    class function BuildAAC(const ASamples: TArray<TBytes>;
      const AAudioSpecificConfig: TBytes; ASampleRate, AChannels: Integer;
      AAvgBitrate: Cardinal = 0; ASamplesPerFrame: Integer = 1024): TBytes; static;
    { PCM: AInterleaved is the whole interleaved PCM payload; the sample table
      describes AFrameCount audio frames of AChannels*bytes each. }
    class function BuildPCM(AWriteCodec: TMP4WriteCodec; const AInterleaved: TBytes;
      ASampleRate, AChannels, AFrameCount: Integer): TBytes; static;
  end;

function MP4CodecKindName(AKind: TMP4CodecKind): string;
function MP4CodecIsAAC(AKind: TMP4CodecKind): Boolean;
function MP4CodecIsPCM(AKind: TMP4CodecKind): Boolean;
{ ASC helpers, also used by the AAC decoder / MP4 facade }
function AacSampleRateFromIndex(AIndex: Integer): Integer;
function AacSampleRateIndex(ARate: Integer): Integer;
{ Parse an AudioSpecificConfig: AOT, sample rate, channel config. }
function ParseAudioSpecificConfig(const AASC: TBytes;
  out AAOT, ASampleRate, AChannels: Integer): Boolean;
{ Build a minimal 2-byte ASC (AOT<=30, standard rate, channelConfig 1..7). }
function BuildAudioSpecificConfig(AAOT, ASampleRate, AChannels: Integer): TBytes;

implementation

const
  AAC_SAMPLE_RATES: array[0..12] of Integer =
    (96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050,
     16000, 12000, 11025, 8000, 7350);

{ forward: the writer backpatches its own single stco entry after ToBytes }
procedure BackpatchStco(var ABytes: TBytes; AChunkOffset: Int64); forward;

{ seconds since the 1904 Media epoch, for the (cosmetic) creation/mod times }
function MediaEpochNow: Cardinal;
begin
  Result := Cardinal((Int64(Trunc(Now)) + 24107) * Int64(86400));
end;

function JoinBrands(const A: TArray<string>): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(A) do
  begin
    if i > 0 then Result := Result + ' ';
    Result := Result + A[i];
  end;
end;

function AacSampleRateFromIndex(AIndex: Integer): Integer;
begin
  if (AIndex >= 0) and (AIndex <= High(AAC_SAMPLE_RATES)) then
    Result := AAC_SAMPLE_RATES[AIndex]
  else
    Result := 0;
end;

function AacSampleRateIndex(ARate: Integer): Integer;
var
  i: Integer;
begin
  for i := Low(AAC_SAMPLE_RATES) to High(AAC_SAMPLE_RATES) do
    if AAC_SAMPLE_RATES[i] = ARate then Exit(i);
  Result := 15;   // "explicit rate follows" sentinel
end;

function MP4CodecIsAAC(AKind: TMP4CodecKind): Boolean;
begin
  Result := AKind in [mckAAC_LC, mckAAC_Main, mckAAC_SSR, mckAAC_LTP,
    mckHE_AAC, mckHE_AACv2, mckAAC_LD, mckAAC_ELD, mckAAC_Scalable];
end;

function MP4CodecIsPCM(AKind: TMP4CodecKind): Boolean;
begin
  Result := AKind in [mckPCM_S16LE, mckPCM_S16BE, mckPCM_S24LE, mckPCM_S24BE,
    mckPCM_S32LE, mckPCM_S32BE, mckPCM_F32, mckPCM_F64, mckPCM_U8, mckPCM_ISO];
end;

function MP4CodecKindName(AKind: TMP4CodecKind): string;
begin
  case AKind of
    mckAAC_LC:       Result := 'AAC LC';
    mckAAC_Main:     Result := 'AAC Main';
    mckAAC_SSR:      Result := 'AAC SSR';
    mckAAC_LTP:      Result := 'AAC LTP';
    mckHE_AAC:       Result := 'HE-AAC (AAC LC + SBR)';
    mckHE_AACv2:     Result := 'HE-AAC v2 (AAC LC + SBR + PS)';
    mckAAC_LD:       Result := 'AAC LD';
    mckAAC_ELD:      Result := 'AAC ELD';
    mckAAC_Scalable: Result := 'AAC Scalable';
    mckALAC:         Result := 'Apple Lossless (ALAC)';
    mckMP3:          Result := 'MPEG-1/2 Layer III (MP3)';
    mckMP2:          Result := 'MPEG-1/2 Layer II';
    mckMP1:          Result := 'MPEG-1/2 Layer I';
    mckAC3:          Result := 'Dolby AC-3';
    mckEAC3:         Result := 'Dolby E-AC-3';
    mckDTS:          Result := 'DTS';
    mckOpus:         Result := 'Opus';
    mckFLAC:         Result := 'FLAC';
    mckAMR:          Result := 'AMR';
    mckPCM_S16LE:    Result := 'PCM signed 16-bit LE';
    mckPCM_S16BE:    Result := 'PCM signed 16-bit BE';
    mckPCM_S24LE:    Result := 'PCM signed 24-bit LE';
    mckPCM_S24BE:    Result := 'PCM signed 24-bit BE';
    mckPCM_S32LE:    Result := 'PCM signed 32-bit LE';
    mckPCM_S32BE:    Result := 'PCM signed 32-bit BE';
    mckPCM_F32:      Result := 'PCM float 32-bit';
    mckPCM_F64:      Result := 'PCM float 64-bit';
    mckPCM_U8:       Result := 'PCM unsigned 8-bit';
    mckPCM_ISO:      Result := 'PCM (ISO ipcm)';
  else
    Result := 'unknown / unsupported';
  end;
end;

{ ============================ ASC parse/build ======================= }

type
  { tiny MSB-first reader for the few bit fields ASC needs }
  TAscBits = record
    Data: TBytes;
    BitPos: Integer;
    function Bits(N: Integer): Cardinal;
    function BitsLeft: Integer;
  end;

function TAscBits.Bits(N: Integer): Cardinal;
var
  i, byteIdx, bitIdx: Integer;
begin
  Result := 0;
  for i := 1 to N do
  begin
    byteIdx := BitPos shr 3;
    bitIdx := 7 - (BitPos and 7);
    if byteIdx < Length(Data) then
      Result := (Result shl 1) or ((Data[byteIdx] shr bitIdx) and 1)
    else
      Result := Result shl 1;
    Inc(BitPos);
  end;
end;

function TAscBits.BitsLeft: Integer;
begin
  Result := Length(Data) * 8 - BitPos;
end;

function ParseAudioSpecificConfig(const AASC: TBytes;
  out AAOT, ASampleRate, AChannels: Integer): Boolean;
var
  r: TAscBits;
  aot, sfi, chan: Cardinal;
  extAot, extSfi: Cardinal;
begin
  AAOT := 0; ASampleRate := 0; AChannels := 0;
  Result := False;
  if Length(AASC) < 2 then Exit;
  r.Data := AASC;
  r.BitPos := 0;

  aot := r.Bits(5);
  if aot = 31 then
    aot := 32 + r.Bits(6);
  AAOT := Integer(aot);

  sfi := r.Bits(4);
  if sfi = 15 then
    ASampleRate := Integer(r.Bits(24))
  else
    ASampleRate := AacSampleRateFromIndex(Integer(sfi));

  chan := r.Bits(4);
  AChannels := Integer(chan);

  { SBR / PS explicit signalling (HE-AAC): AOT 5 or 29 up front means the base
    is really LC and the "extension" sample rate is 2x.  We still report the
    base-layer rate/channels here; the facade downmixes SBR/PS to LC. }
  if (aot = 5) or (aot = 29) then
  begin
    extSfi := r.Bits(4);
    if extSfi = 15 then r.Bits(24);
    extAot := r.Bits(5);
    if extAot = 22 then r.Bits(4);   // ER
  end;

  if AChannels = 0 then AChannels := 2;   // "defined in PCE" - assume stereo
  Result := (AAOT > 0) and (ASampleRate > 0);
end;

function BuildAudioSpecificConfig(AAOT, ASampleRate, AChannels: Integer): TBytes;
var
  sfi, b0, b1: Integer;
begin
  sfi := AacSampleRateIndex(ASampleRate);
  if AAOT < 1 then AAOT := 2;
  if AChannels < 1 then AChannels := 2;
  if sfi = 15 then
  begin
    { explicit 24-bit rate: 5 + 4 + 24 + 4 = 37 bits -> 5 bytes }
    SetLength(Result, 5);
    Result[0] := (AAOT shl 3) or ((15 shr 1) and 7);
    Result[1] := ((15 and 1) shl 7) or ((ASampleRate shr 17) and $7F);
    Result[2] := (ASampleRate shr 9) and $FF;
    Result[3] := (ASampleRate shr 1) and $FF;
    Result[4] := ((ASampleRate and 1) shl 7) or ((AChannels and $0F) shl 3);
    Exit;
  end;
  { 5 + 4 + 4 = 13 bits -> 2 bytes, low 3 bits zero (frameLengthFlag etc) }
  b0 := (AAOT shl 3) or ((sfi shr 1) and 7);
  b1 := ((sfi and 1) shl 7) or ((AChannels and $0F) shl 3);
  SetLength(Result, 2);
  Result[0] := b0;
  Result[1] := b1;
end;

{ ============================ TMP4SampleTable ====================== }

procedure TMP4SampleTable.Parse(ATree: TMP4AtomTree; AStbl: TMP4Atom);
var
  data: TBytes;
  sttsA, cttsA, stscA, stszA, stz2A, stcoA, co64A, stssA: TMP4Atom;
  dts, cts: TArray<Int64>;
  sizes, chunkOfs: TArray<Int64>;
  sampleCount: Int64;
  deltaRuns: Integer;
  { stsc runs }
  scEntries: Cardinal;
  scFirstChunk, scSamplesPerChunk, scDescIdx: TArray<Cardinal>;
  o2, i, si: Int64;
  chunkIdx, samplesThisChunk, runIdx: Int64;
  curOffset: Int64;
  descForChunk: Integer;
  syncSet: TArray<Boolean>;
  ssCount: Cardinal;
  ssNum: Cardinal;

  { stts -> per-sample DTS }
  procedure ReadStts(A: TMP4Atom; out ADts: TArray<Int64>; out ADeltaRuns: Integer);
  var
    o, n, i, j, cnt: Int64;
    delta: Cardinal;
    dts: Int64;
    entries: Cardinal;
  begin
    SetLength(ADts, 0);
    ADeltaRuns := 0;
    if A = nil then Exit;
    o := A.ContentOffset;
    entries := BE_U32(ATree.Data, o + 4);
    if entries > MP4_MAX_TABLE_ENTRIES then
      RaiseUDAW(errIO, MP4_SUBSYS, 'stts entry_count absurd');
    { first pass: total sample count }
    n := 0;
    for i := 0 to Int64(entries) - 1 do
    begin
      if o + 8 + i * 8 + 8 > Length(ATree.Data) then Break;
      cnt := BE_U32(ATree.Data, o + 8 + i * 8);
      Inc(n, cnt);
      if n > MP4_MAX_TABLE_ENTRIES then
        RaiseUDAW(errIO, MP4_SUBSYS, 'stts sample total absurd');
    end;
    SetLength(ADts, n);
    dts := 0;
    j := 0;
    ADeltaRuns := Integer(entries);
    for i := 0 to Int64(entries) - 1 do
    begin
      if o + 8 + i * 8 + 8 > Length(ATree.Data) then Break;
      cnt := BE_U32(ATree.Data, o + 8 + i * 8);
      delta := BE_U32(ATree.Data, o + 8 + i * 8 + 4);
      while (cnt > 0) and (j < n) do
      begin
        ADts[j] := dts;
        dts := dts + Int64(delta);
        Inc(j);
        Dec(cnt);
      end;
    end;
    if (ADeltaRuns = 1) and (n > 0) then
      FConstantSampleDelta := BE_U32(ATree.Data, o + 8 + 4);
  end;

  procedure ReadCtts(A: TMP4Atom; var ADts: TArray<Int64>; var ACts: TArray<Int64>);
  var
    o, i, j, cnt: Int64;
    offv: Integer;
    entries: Cardinal;
    ver: Byte;
  begin
    SetLength(ACts, Length(ADts));
    for i := 0 to High(ADts) do ACts[i] := ADts[i];
    if A = nil then Exit;
    o := A.ContentOffset;
    ver := BE_U8(ATree.Data, o);
    entries := BE_U32(ATree.Data, o + 4);
    if entries > MP4_MAX_TABLE_ENTRIES then Exit;
    j := 0;
    for i := 0 to Int64(entries) - 1 do
    begin
      if o + 8 + i * 8 + 8 > Length(ATree.Data) then Break;
      cnt := BE_U32(ATree.Data, o + 8 + i * 8);
      if ver = 0 then
        offv := Integer(BE_U32(ATree.Data, o + 8 + i * 8 + 4))
      else
        offv := Integer(BE_U32(ATree.Data, o + 8 + i * 8 + 4)); // signed reinterpret ok
      while (cnt > 0) and (j <= High(ACts)) do
      begin
        ACts[j] := ADts[j] + offv;
        Inc(j);
        Dec(cnt);
      end;
    end;
  end;

  procedure ReadStsz(A, AStz2: TMP4Atom; ANominal: Int64; out ASizes: TArray<Int64>;
    out ACount: Int64);
  var
    o, i: Int64;
    fixed, cnt: Cardinal;
    fieldSize: Byte;
    b: Byte;
  begin
    SetLength(ASizes, 0);
    ACount := 0;
    if A <> nil then
    begin
      o := A.ContentOffset;
      fixed := BE_U32(ATree.Data, o + 4);
      cnt := BE_U32(ATree.Data, o + 8);
      if cnt > MP4_MAX_TABLE_ENTRIES then
        RaiseUDAW(errIO, MP4_SUBSYS, 'stsz sample_count absurd');
      ACount := cnt;
      SetLength(ASizes, cnt);
      if fixed <> 0 then
      begin
        for i := 0 to Int64(cnt) - 1 do ASizes[i] := fixed;
      end
      else
      begin
        for i := 0 to Int64(cnt) - 1 do
        begin
          if o + 12 + i * 4 + 4 > Length(ATree.Data) then
          begin
            SetLength(ASizes, i);
            ACount := i;
            Break;
          end;
          ASizes[i] := BE_U32(ATree.Data, o + 12 + i * 4);
        end;
      end;
      Exit;
    end;
    if AStz2 <> nil then
    begin
      o := AStz2.ContentOffset;
      fieldSize := BE_U8(ATree.Data, o + 7);   // low byte of the reserved+field_size word
      cnt := BE_U32(ATree.Data, o + 8);
      if cnt > MP4_MAX_TABLE_ENTRIES then
        RaiseUDAW(errIO, MP4_SUBSYS, 'stz2 sample_count absurd');
      ACount := cnt;
      SetLength(ASizes, cnt);
      case fieldSize of
        4:
          for i := 0 to Int64(cnt) - 1 do
          begin
            if o + 12 + (i div 2) >= Length(ATree.Data) then Break;
            b := ATree.Data[o + 12 + (i div 2)];
            if (i and 1) = 0 then ASizes[i] := (b shr 4) and $0F
            else ASizes[i] := b and $0F;
          end;
        8:
          for i := 0 to Int64(cnt) - 1 do
          begin
            if o + 12 + i >= Length(ATree.Data) then Break;
            ASizes[i] := ATree.Data[o + 12 + i];
          end;
        16:
          for i := 0 to Int64(cnt) - 1 do
          begin
            if o + 12 + i * 2 + 2 > Length(ATree.Data) then Break;
            ASizes[i] := BE_U16(ATree.Data, o + 12 + i * 2);
          end;
      end;
    end;
  end;

  procedure ReadOffsets(AStco, ACo64: TMP4Atom; out AOfs: TArray<Int64>);
  var
    o, i: Int64;
    cnt: Cardinal;
    is64: Boolean;
    a: TMP4Atom;
  begin
    SetLength(AOfs, 0);
    if ACo64 <> nil then begin a := ACo64; is64 := True; end
    else if AStco <> nil then begin a := AStco; is64 := False; end
    else Exit;
    o := a.ContentOffset;
    cnt := BE_U32(ATree.Data, o + 4);
    if cnt > MP4_MAX_TABLE_ENTRIES then
      RaiseUDAW(errIO, MP4_SUBSYS, 'stco/co64 entry_count absurd');
    SetLength(AOfs, cnt);
    for i := 0 to Int64(cnt) - 1 do
    begin
      if is64 then
      begin
        if o + 8 + i * 8 + 8 > Length(ATree.Data) then begin SetLength(AOfs, i); Break; end;
        AOfs[i] := Int64(BE_U64(ATree.Data, o + 8 + i * 8));
      end
      else
      begin
        if o + 8 + i * 4 + 4 > Length(ATree.Data) then begin SetLength(AOfs, i); Break; end;
        AOfs[i] := BE_U32(ATree.Data, o + 8 + i * 4);
      end;
    end;
  end;

begin
  FConstantSampleDelta := 0;
  data := ATree.Data;
  if AStbl = nil then Exit;

  sttsA := AStbl.Find('stts');
  cttsA := AStbl.Find('ctts');
  stscA := AStbl.Find('stsc');
  stszA := AStbl.Find('stsz');
  stz2A := AStbl.Find('stz2');
  stcoA := AStbl.Find('stco');
  co64A := AStbl.Find('co64');
  stssA := AStbl.Find('stss');

  ReadStts(sttsA, dts, deltaRuns);
  ReadStsz(stszA, stz2A, 0, sizes, sampleCount);
  ReadCtts(cttsA, dts, cts);
  ReadOffsets(stcoA, co64A, chunkOfs);

  if sampleCount = 0 then sampleCount := Length(dts);
  if sampleCount = 0 then Exit;
  if Length(sizes) < sampleCount then
  begin
    { size table shorter than count: cap to what we actually have }
    sampleCount := Length(sizes);
    if sampleCount = 0 then Exit;
  end;

  { --- stsc --- }
  SetLength(scFirstChunk, 0);
  if stscA <> nil then
  begin
    o2 := stscA.ContentOffset;
    scEntries := BE_U32(data, o2 + 4);
    if scEntries > MP4_MAX_TABLE_ENTRIES then
      RaiseUDAW(errIO, MP4_SUBSYS, 'stsc entry_count absurd');
    SetLength(scFirstChunk, scEntries);
    SetLength(scSamplesPerChunk, scEntries);
    SetLength(scDescIdx, scEntries);
    for i := 0 to Int64(scEntries) - 1 do
    begin
      if o2 + 8 + i * 12 + 12 > Length(data) then
      begin
        SetLength(scFirstChunk, i); SetLength(scSamplesPerChunk, i);
        SetLength(scDescIdx, i);
        Break;
      end;
      scFirstChunk[i]      := BE_U32(data, o2 + 8 + i * 12);
      scSamplesPerChunk[i] := BE_U32(data, o2 + 8 + i * 12 + 4);
      scDescIdx[i]         := BE_U32(data, o2 + 8 + i * 12 + 8);
    end;
  end;
  if Length(scFirstChunk) = 0 then
  begin
    { synthesise: everything in one chunk }
    SetLength(scFirstChunk, 1); SetLength(scSamplesPerChunk, 1); SetLength(scDescIdx, 1);
    scFirstChunk[0] := 1;
    scSamplesPerChunk[0] := sampleCount;
    scDescIdx[0] := 1;
    if Length(chunkOfs) = 0 then
    begin
      { no stco either - cannot place samples }
      Exit;
    end;
  end;

  { --- stss --- }
  SetLength(syncSet, sampleCount);
  if stssA = nil then
  begin
    for i := 0 to sampleCount - 1 do syncSet[i] := True;
  end
  else
  begin
    for i := 0 to sampleCount - 1 do syncSet[i] := False;
    o2 := stssA.ContentOffset;
    ssCount := BE_U32(data, o2 + 4);
    for i := 0 to Int64(ssCount) - 1 do
    begin
      if o2 + 8 + i * 4 + 4 > Length(data) then Break;
      ssNum := BE_U32(data, o2 + 8 + i * 4);
      if (ssNum >= 1) and (Int64(ssNum) <= sampleCount) then
        syncSet[ssNum - 1] := True;
    end;
  end;

  { --- fold chunks -> per-sample offsets --- }
  SetLength(FSamples, sampleCount);
  si := 0;
  runIdx := 0;
  chunkIdx := 1;   // 1-based
  while (si < sampleCount) and (chunkIdx <= Length(chunkOfs)) do
  begin
    { advance runIdx so scFirstChunk[runIdx] <= chunkIdx < scFirstChunk[runIdx+1] }
    while (runIdx + 1 < Length(scFirstChunk)) and
          (Int64(scFirstChunk[runIdx + 1]) <= chunkIdx) do
      Inc(runIdx);
    samplesThisChunk := scSamplesPerChunk[runIdx];
    descForChunk := Integer(scDescIdx[runIdx]);
    curOffset := chunkOfs[chunkIdx - 1];
    while (samplesThisChunk > 0) and (si < sampleCount) do
    begin
      FSamples[si].Offset := curOffset;
      FSamples[si].Size := sizes[si];
      if si < Length(dts) then FSamples[si].DTS := dts[si] else FSamples[si].DTS := 0;
      if si < Length(cts) then FSamples[si].CTS := cts[si] else FSamples[si].CTS := FSamples[si].DTS;
      FSamples[si].Sync := syncSet[si];
      FSamples[si].DescIndex := descForChunk;
      curOffset := curOffset + sizes[si];
      Inc(si);
      Dec(samplesThisChunk);
    end;
    Inc(chunkIdx);
  end;

  if si < sampleCount then
    SetLength(FSamples, si);
  FSampleCount := Length(FSamples);
end;

function TMP4SampleTable.TotalSize: Int64;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(FSamples) do
    Inc(Result, FSamples[i].Size);
end;

function TMP4SampleTable.DurationTicks: Int64;
begin
  if FSampleCount = 0 then Exit(0);
  Result := FSamples[FSampleCount - 1].DTS - FSamples[0].DTS;
  if FConstantSampleDelta > 0 then
    Result := Result + FConstantSampleDelta
  else if FSampleCount >= 2 then
    Result := Result + (FSamples[FSampleCount - 1].DTS - FSamples[FSampleCount - 2].DTS);
end;

{ ============================ TMP4Track =========================== }

constructor TMP4Track.Create;
begin
  inherited Create;
  FTable := TMP4SampleTable.Create;
  FCodec := mckUnknown;
  FBitsPerSample := 16;
  FEditLengthTicks := -1;
end;

destructor TMP4Track.Destroy;
begin
  FTable.Free;
  inherited Destroy;
end;

function TMP4Track.IsAudio: Boolean;
begin
  Result := FHandlerType = 'soun';
end;

function TMP4Track.IsVideo: Boolean;
begin
  Result := FHandlerType = 'vide';
end;

{ Visual sample entry: 6 reserved + 2 data_ref_index, 2 pre_defined + 2 reserved
  + 12 pre_defined, then width(2) height(2). Only the FourCC and picture size
  are kept - the video itself is displayed by the OS, never decoded here. }
procedure TMP4Track.DetectVideoEntry(ATree: TMP4AtomTree; AStsd: TMP4Atom);
var
  data: TBytes;
  o, entryStart: Int64;
begin
  data := ATree.Data;
  if AStsd.ChildCount = 0 then
  begin
    o := AStsd.ContentOffset + 8;
    if o + 8 > Length(data) then Exit;
    FSampleEntry := ReadFourCC(data, o + 4).Text;
    entryStart := o + 8;
  end
  else
  begin
    FSampleEntry := AStsd.Child(0).Kind.Text;
    entryStart := AStsd.Child(0).ContentOffset;
  end;
  if entryStart + 28 <= Length(data) then
  begin
    FVideoWidth := BE_U16(data, entryStart + 24);
    FVideoHeight := BE_U16(data, entryStart + 26);
  end;
  if FSampleEntry <> '' then FCodecName := FSampleEntry;
end;

function TMP4Track.DurationSeconds: Double;
begin
  if FMediaTimescale > 0 then
  begin
    if FMediaDuration > 0 then
      Result := FMediaDuration / FMediaTimescale
    else
      Result := FTable.DurationTicks / FMediaTimescale;
  end
  else
    Result := 0;
end;

function TMP4Track.IsPCM: Boolean;
begin
  Result := MP4CodecIsPCM(FCodec);
end;

function TMP4Track.PCMBytesPerFrame: Integer;
var
  bytesPerSample: Integer;
begin
  case FCodec of
    mckPCM_U8:               bytesPerSample := 1;
    mckPCM_S16LE, mckPCM_S16BE: bytesPerSample := 2;
    mckPCM_S24LE, mckPCM_S24BE: bytesPerSample := 3;
    mckPCM_S32LE, mckPCM_S32BE, mckPCM_F32: bytesPerSample := 4;
    mckPCM_F64:              bytesPerSample := 8;
    mckPCM_ISO:              bytesPerSample := Max(1, FBitsPerSample div 8);
  else
    bytesPerSample := 2;
  end;
  Result := bytesPerSample * Max(1, FChannelCount);
end;

procedure TMP4Track.DetectAudioCodec(ATree: TMP4AtomTree; AStsd: TMP4Atom);
var
  data: TBytes;
  o, entryStart: Int64;
  fourcc: TFourCC;
  ver: Word;
  soundVer: Word;
  childScan: Int64;
  cSize: Cardinal;
  cType: TFourCC;
  se: TMP4Atom;
  scanP, scanStop: Int64;

  { minimal descriptor walker inside esds: find tag, return payload range }
  function DescPayload(AStart, AEnd: Int64; ATag: Byte; out APayStart, APayEnd: Int64): Boolean;
  var
    p: Int64;
    tag: Byte;
    len: Cardinal;
    b: Byte;
    guard: Integer;
  begin
    Result := False;
    p := AStart;
    while p + 2 <= AEnd do
    begin
      tag := data[p]; Inc(p);
      len := 0; guard := 0;
      repeat
        if p >= AEnd then Exit;
        b := data[p]; Inc(p);
        len := (len shl 7) or (b and $7F);
        Inc(guard);
      until ((b and $80) = 0) or (guard >= 4);
      if p + Int64(len) > AEnd then len := Cardinal(AEnd - p);
      if tag = ATag then
      begin
        APayStart := p;
        APayEnd := p + Int64(len);
        Exit(True);
      end;
      { descend into ES_Descriptor (0x03) automatically }
      if tag = $03 then
      begin
        { ES_Descriptor: 2 bytes ES_ID + 1 byte flags, then sub-descriptors }
        if DescPayload(p + 3, p + Int64(len), ATag, APayStart, APayEnd) then
          Exit(True);
      end;
      p := p + Int64(len);
    end;
  end;

  { AEsdsContentStart/End bracket the esds box PAYLOAD (after the 8-byte box
    header).  The first 4 bytes are the FullBox version/flags. }
  procedure ApplyEsdsAt(AEsdsContentStart, AEsdsContentEnd: Int64);
  var
    ps, pe, dsiS, dsiE: Int64;
    oti: Byte;
    aot, sr, ch: Integer;
  begin
    if not DescPayload(AEsdsContentStart + 4, AEsdsContentEnd, $04, ps, pe) then Exit;
    if ps >= Length(data) then Exit;
    oti := data[ps];
    FObjectTypeIndication := oti;
    if pe - ps >= 13 then
    begin
      FMaxBitrate := BE_U32(data, ps + 5);
      FAvgBitrate := BE_U32(data, ps + 9);
    end;
    case oti of
      $69, $6B: FCodec := mckMP3;
      $6C:      FCodec := mckMP1;
      $A5:      FCodec := mckAC3;
      $A6:      FCodec := mckEAC3;
      $A9, $AA, $AB: FCodec := mckDTS;
      $DD:      FCodec := mckOpus;
    end;
    if DescPayload(ps + 13, pe, $05, dsiS, dsiE) then
      if (dsiE > dsiS) and (dsiE <= Length(data)) then
      begin
        SetLength(FAudioSpecificConfig, dsiE - dsiS);
        Move(data[dsiS], FAudioSpecificConfig[0], dsiE - dsiS);
      end;
    if (oti = $40) or ((oti >= $66) and (oti <= $68)) then
    begin
      if ParseAudioSpecificConfig(FAudioSpecificConfig, aot, sr, ch) then
      begin
        FAudioObjectType := aot;
        if sr > 0 then FSampleRate := sr;
        if ch > 0 then FChannelCount := ch;
        case aot of
          1:  FCodec := mckAAC_Main;
          2, 17: FCodec := mckAAC_LC;
          3:  FCodec := mckAAC_SSR;
          4:  FCodec := mckAAC_LTP;
          5:  FCodec := mckHE_AAC;
          6:  FCodec := mckAAC_Scalable;
          23: FCodec := mckAAC_LD;
          29: FCodec := mckHE_AACv2;
          39: FCodec := mckAAC_ELD;
        else
          FCodec := mckAAC_LC;
        end;
      end
      else
        FCodec := mckAAC_LC;
    end;
  end;

begin
  data := ATree.Data;
  { stsd content: version/flags(4) entry_count(4) then sample entry box(es).
    ParseAtomTree already skipped that 8-byte prologue, so AStsd.Children[0]
    is the first sample entry box. }
  if AStsd.ChildCount = 0 then
  begin
    { fall back to a manual read if the tree didn't recurse }
    o := AStsd.ContentOffset + 8;
    if o + 8 > Length(data) then Exit;
    fourcc := ReadFourCC(data, o + 4);
    entryStart := o + 8;
  end
  else
  begin
    fourcc := AStsd.Child(0).Kind;
    entryStart := AStsd.Child(0).ContentOffset;
  end;

  FSampleEntry := fourcc.Text;

  { AudioSampleEntry: 6 reserved + 2 data_ref_index = 8, then
    version(2) revision(2) vendor(4) = 8, channelcount(2) samplesize(2)
    compressionID(2) packetsize(2) samplerate(4 as 16.16). }
  if entryStart + 28 <= Length(data) then
  begin
    soundVer := BE_U16(data, entryStart + 8);
    FChannelCount := BE_U16(data, entryStart + 8 + 8);
    FBitsPerSample := BE_U16(data, entryStart + 8 + 10);
    FSampleRate := Round(BE_Fixed1616(data, entryStart + 8 + 16));
    if FSampleRate = 0 then
      FSampleRate := BE_U16(data, entryStart + 8 + 16); // some muxers store plain
    ver := soundVer;
  end
  else
    ver := 0;

  { child boxes of the sample entry start after the fixed part.
    v0: +28 ; v1: +28 +16 ; v2: +28 +36 }
  case ver of
    1: childScan := entryStart + 28 + 16;
    2: childScan := entryStart + 28 + 36;
  else
    childScan := entryStart + 28;
  end;

  { map the raw sample-entry FourCC to a codec (PCM + a few coded kinds) }
  if fourcc.Equals('mp4a') then FCodec := mckUnknown   // decided by esds below
  else if fourcc.Equals('alac') then FCodec := mckALAC
  else if fourcc.Equals('.mp3') or fourcc.Equals('mp3 ') then FCodec := mckMP3
  else if fourcc.Equals('ac-3') then FCodec := mckAC3
  else if fourcc.Equals('ec-3') then FCodec := mckEAC3
  else if fourcc.Equals('Opus') then FCodec := mckOpus
  else if fourcc.Equals('fLaC') then FCodec := mckFLAC
  else if fourcc.Equals('sowt') then FCodec := mckPCM_S16LE
  else if fourcc.Equals('twos') then FCodec := mckPCM_S16BE
  else if fourcc.Equals('in24') then FCodec := mckPCM_S24BE
  else if fourcc.Equals('in32') then FCodec := mckPCM_S32BE
  else if fourcc.Equals('fl32') then FCodec := mckPCM_F32
  else if fourcc.Equals('fl64') then FCodec := mckPCM_F64
  else if fourcc.Equals('raw ') then FCodec := mckPCM_U8
  else if fourcc.Equals('lpcm') then FCodec := mckPCM_S16LE
  else if fourcc.Equals('ipcm') then FCodec := mckPCM_ISO
  else if fourcc.Equals('fpcm') then FCodec := mckPCM_F32
  else if fourcc.Equals('samr') then FCodec := mckAMR;

  { Scan the sample-entry's own content bytes for child boxes (esds / pcmC).
    The atom tree does not recurse sample entries, so we walk them by hand. }
  if AStsd.ChildCount > 0 then
  begin
    se := AStsd.Child(0);
    scanP := childScan;
    scanStop := se.ContentOffset + se.ContentSize;
    while scanP + 8 <= scanStop do
    begin
      cSize := BE_U32(data, scanP);
      cType := ReadFourCC(data, scanP + 4);
      if (cSize < 8) or (scanP + Int64(cSize) > scanStop + 4) then Break;
      if cType.Equals('esds') then
        ApplyEsdsAt(scanP + 8, scanP + Int64(cSize))
      else if cType.Equals('pcmC') and (scanP + 14 <= scanStop) then
      begin
        { ISO 23003-5 pcmC: version/flags(4) format_flags(1) pcm_sample_size(1) }
        FBitsPerSample := data[scanP + 13];
        if (data[scanP + 12] and 1) = 1 then
          case FBitsPerSample of
            16: FCodec := mckPCM_S16LE;
            24: FCodec := mckPCM_S24LE;
            32: FCodec := mckPCM_S32LE;
          else FCodec := mckPCM_ISO;
          end
        else
          case FBitsPerSample of
            16: FCodec := mckPCM_S16BE;
            24: FCodec := mckPCM_S24BE;
            32: FCodec := mckPCM_S32BE;
          else FCodec := mckPCM_ISO;
          end;
      end;
      scanP := scanP + Int64(cSize);
    end;
  end;

  FCodecName := MP4CodecKindName(FCodec);
  if FChannelCount <= 0 then FChannelCount := 2;
  if FSampleRate <= 0 then FSampleRate := 44100;
end;

function TMP4Track.Describe: string;
begin
  Result := Format('track #%d [%s] %s: %s, %d Hz, %d ch, %d-bit, %d samples, %.3f s',
    [FTrackID, FHandlerType, FSampleEntry, FCodecName, FSampleRate, FChannelCount,
     FBitsPerSample, FTable.SampleCount, DurationSeconds]);
end;

{ ============================ TMP4Reader ========================== }

constructor TMP4Reader.Create(const AData: TBytes);
var
  ftyp: TMP4Atom;
  o: Int64;
  moov: TMP4Atom;
  n: Integer;
begin
  inherited Create;
  FTree := TMP4AtomTree.Create(AData);

  ftyp := FTree.Root.Find('ftyp');
  if ftyp <> nil then
  begin
    FMajorBrand := SafeAscii(AData, ftyp.ContentOffset, 4);
    n := 0;
    o := ftyp.ContentOffset + 8;   // major(4) + minor_version(4)
    while o + 4 <= ftyp.ContentOffset + ftyp.ContentSize do
    begin
      SetLength(FCompatibleBrands, n + 1);
      FCompatibleBrands[n] := SafeAscii(AData, o, 4);
      Inc(n);
      Inc(o, 4);
    end;
  end
  else
    FMajorBrand := '';

  FFragmented := (FTree.Root.Find('moof') <> nil) or
    ((FTree.Root.Find('moov') <> nil) and (FTree.Root.Find('moov').Find('mvex') <> nil));

  moov := FTree.Root.Find('moov');
  if moov = nil then
    RaiseUDAW(errIO, MP4_SUBSYS, 'MP4 has no moov box (fragmented-init-only or not an MP4)');
  ParseMoov(moov);
end;

destructor TMP4Reader.Destroy;
var
  i: Integer;
begin
  for i := 0 to High(FTracks) do
    FTracks[i].Free;
  FTracks := nil;
  FTree.Free;
  inherited Destroy;
end;

procedure TMP4Reader.ParseMoov(AMoov: TMP4Atom);
var
  mvhd: TMP4Atom;
  o: Int64;
  ver: Byte;
  traks: TMP4AtomList;
  i: Integer;
begin
  mvhd := AMoov.Find('mvhd');
  if mvhd <> nil then
  begin
    o := mvhd.ContentOffset;
    ver := BE_U8(FTree.Data, o);
    if ver = 1 then
    begin
      FMovieTimescale := BE_U32(FTree.Data, o + 4 + 8 + 8);
      FMovieDuration := Int64(BE_U64(FTree.Data, o + 4 + 8 + 8 + 4));
    end
    else
    begin
      FMovieTimescale := BE_U32(FTree.Data, o + 4 + 4 + 4);
      FMovieDuration := BE_U32(FTree.Data, o + 4 + 4 + 4 + 4);
    end;
  end;

  traks := AMoov.FindAll('trak');
  for i := 0 to High(traks) do
    ParseTrak(traks[i]);
end;

procedure TMP4Reader.ParseTrak(ATrak: TMP4Atom);
var
  t: TMP4Track;
  tkhd, mdia, mdhd, hdlr, minf, stbl, stsd, edts, elst: TMP4Atom;
  o: Int64;
  ver: Byte;
  langPacked: Word;
  n: Integer;
  cnt: Cardinal;
  segDur, mediaTime: Int64;
begin
  t := TMP4Track.Create;
  try
    tkhd := ATrak.Find('tkhd');
    if tkhd <> nil then
    begin
      o := tkhd.ContentOffset;
      ver := BE_U8(FTree.Data, o);
      if ver = 1 then
        t.FTrackID := BE_U32(FTree.Data, o + 4 + 8 + 8)
      else
        t.FTrackID := BE_U32(FTree.Data, o + 4 + 4 + 4);
    end;

    mdia := ATrak.Find('mdia');
    if mdia = nil then
    begin
      FreeAndNil(t);
      Exit;
    end;

    mdhd := mdia.Find('mdhd');
    if mdhd <> nil then
    begin
      o := mdhd.ContentOffset;
      ver := BE_U8(FTree.Data, o);
      if ver = 1 then
      begin
        t.FMediaTimescale := BE_U32(FTree.Data, o + 4 + 8 + 8);
        t.FMediaDuration := Int64(BE_U64(FTree.Data, o + 4 + 8 + 8 + 4));
        langPacked := BE_U16(FTree.Data, o + 4 + 8 + 8 + 4 + 8);
      end
      else
      begin
        t.FMediaTimescale := BE_U32(FTree.Data, o + 4 + 4 + 4);
        t.FMediaDuration := BE_U32(FTree.Data, o + 4 + 4 + 4 + 4);
        langPacked := BE_U16(FTree.Data, o + 4 + 4 + 4 + 4 + 4);
      end;
      if langPacked <> 0 then
        t.FLanguage :=
          Chr(((langPacked shr 10) and $1F) + $60) +
          Chr(((langPacked shr 5) and $1F) + $60) +
          Chr((langPacked and $1F) + $60);
    end;

    t.FEditLengthTicks := -1;
    edts := ATrak.Find('edts');
    if edts <> nil then
    begin
      elst := edts.Find('elst');
      if elst <> nil then
      begin
        o := elst.ContentOffset;
        ver := BE_U8(FTree.Data, o);
        cnt := BE_U32(FTree.Data, o + 4);
        o := o + 8;
        for n := 0 to Integer(Min(cnt, 32)) - 1 do
        begin
          if ver = 1 then
          begin
            if o + 20 > Length(FTree.Data) then Break;
            segDur := Int64(BE_U64(FTree.Data, o));
            mediaTime := Int64(BE_U64(FTree.Data, o + 8));
            Inc(o, 20);
          end
          else
          begin
            if o + 12 > Length(FTree.Data) then Break;
            segDur := BE_U32(FTree.Data, o);
            mediaTime := Integer(BE_U32(FTree.Data, o + 4));
            Inc(o, 12);
          end;
          if mediaTime < 0 then Continue;            // empty edit: a gap, not media
          t.FEditStartTicks := mediaTime;
          if (segDur > 0) and (FMovieTimescale > 0) and (t.FMediaTimescale > 0) then
            t.FEditLengthTicks := (segDur * t.FMediaTimescale + FMovieTimescale div 2) div FMovieTimescale;
          Break;
        end;
      end;
    end;

    hdlr := mdia.Find('hdlr');
    if hdlr <> nil then
      t.FHandlerType := SafeAscii(FTree.Data, hdlr.ContentOffset + 8, 4);

    minf := mdia.Find('minf');
    if minf <> nil then
    begin
      stbl := minf.Find('stbl');
      if stbl <> nil then
      begin
        stsd := stbl.Find('stsd');
        if (stsd <> nil) and (t.FHandlerType = 'soun') then
          t.DetectAudioCodec(FTree, stsd)
        else if (stsd <> nil) and (t.FHandlerType = 'vide') then
          t.DetectVideoEntry(FTree, stsd);
        t.FTable.Parse(FTree, stbl);
      end;
    end;

    n := Length(FTracks);
    SetLength(FTracks, n + 1);
    FTracks[n] := t;
    t := nil;
  finally
    t.Free;
  end;
end;

function TMP4Reader.TrackCount: Integer;
begin
  Result := Length(FTracks);
end;

function TMP4Reader.GetTrack(AIndex: Integer): TMP4Track;
begin
  if (AIndex < 0) or (AIndex > High(FTracks)) then Result := nil
  else Result := FTracks[AIndex];
end;

function TMP4Reader.FirstAudioTrack: TMP4Track;
var
  i: Integer;
begin
  Result := nil;
  for i := 0 to High(FTracks) do
    if FTracks[i].IsAudio then Exit(FTracks[i]);
end;

function TMP4Reader.AudioTrackCount: Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(FTracks) do
    if FTracks[i].IsAudio then Inc(Result);
end;

function TMP4Reader.AudioTrackAt(AIndex: Integer): TMP4Track;
var
  i, n: Integer;
begin
  Result := nil;
  n := 0;
  for i := 0 to High(FTracks) do
    if FTracks[i].IsAudio then
    begin
      if n = AIndex then Exit(FTracks[i]);
      Inc(n);
    end;
end;

function TMP4Reader.FirstVideoTrack: TMP4Track;
var
  i: Integer;
begin
  Result := nil;
  for i := 0 to High(FTracks) do
    if FTracks[i].IsVideo then Exit(FTracks[i]);
end;

function TMP4Reader.ContainerReport: string;
var
  at: TMP4Track;
begin
  at := FirstAudioTrack;
  if at <> nil then
    Result := Format('Container: MP4 (brand ''%s'')  |  Audio codec: %s, %d Hz, %d ch',
      [FMajorBrand, at.CodecName, at.SampleRate, at.ChannelCount])
  else
    Result := Format('Container: MP4 (brand ''%s'')  |  Audio codec: (no sound track)',
      [FMajorBrand]);
end;

function TMP4Reader.Describe: string;
var
  sb: TStringBuilder;
  i: Integer;
begin
  sb := TStringBuilder.Create;
  try
    sb.Append(ContainerReport).AppendLine;
    sb.Append(Format('  major brand : %s', [FMajorBrand])).AppendLine;
    sb.Append(Format('  compatible  : %s', [JoinBrands(FCompatibleBrands)])).AppendLine;
    sb.Append(Format('  fragmented  : %s', [BoolToStr(FFragmented, True)])).AppendLine;
    sb.Append(Format('  movie       : timescale %d, duration %d (%.3f s)',
      [FMovieTimescale, FMovieDuration,
       IfThen(FMovieTimescale > 0, FMovieDuration / FMovieTimescale, 0)])).AppendLine;
    for i := 0 to High(FTracks) do
      sb.Append('  ').Append(FTracks[i].Describe).AppendLine;
    Result := sb.ToString;
  finally
    sb.Free;
  end;
end;

{ ============================ TMP4Writer ========================== }

class function TMP4Writer.BuildAAC(const ASamples: TArray<TBytes>;
  const AAudioSpecificConfig: TBytes; ASampleRate, AChannels: Integer;
  AAvgBitrate: Cardinal; ASamplesPerFrame: Integer): TBytes;
var
  w: TMP4BoxWriter;
  i: Integer;
  mdatOffset: Int64;
  asc: TBytes;
  nSamples: Integer;
  now32: Cardinal;
  durationTicks: Int64;

  procedure WriteEsds;
  var
    dsiLen, dcdLen, esdLen: Integer;
  begin
    asc := AAudioSpecificConfig;
    if Length(asc) = 0 then
      asc := BuildAudioSpecificConfig(2, ASampleRate, AChannels);
    dsiLen := Length(asc);
    { DecoderConfigDescriptor payload: 13 bytes + DecoderSpecificInfo(2+dsiLen) }
    dcdLen := 13 + (2 + dsiLen);
    { ES_Descriptor payload: 3 bytes + DecoderConfigDescriptor(2+dcdLen) + SLConfig(2+1) }
    esdLen := 3 + (2 + dcdLen) + 3;

    w.BeginFullBox('esds', 0, 0);
      w.U8($03);                          // ES_Descriptor tag
      w.U8(Byte(esdLen));
      w.U16(0);                           // ES_ID
      w.U8(0);                            // flags
      w.U8($04);                          // DecoderConfigDescriptor tag
      w.U8(Byte(dcdLen));
      w.U8($40);                          // OTI: MPEG-4 Audio
      w.U8((5 shl 2) or 1);              // streamType=AudioStream(5), upStream=0, reserved=1
      w.U24(0);                           // bufferSizeDB
      w.U32(AAvgBitrate);                // maxBitrate (reuse avg)
      w.U32(AAvgBitrate);                // avgBitrate
      w.U8($05);                          // DecoderSpecificInfo tag
      w.U8(Byte(dsiLen));
      w.RawBytes(asc);
      w.U8($06);                          // SLConfigDescriptor tag
      w.U8(1);
      w.U8($02);                          // predefined = MP4
    w.CloseBox;
  end;

begin
  nSamples := Length(ASamples);
  if nSamples = 0 then
    RaiseUDAW(errInvalidArgument, MP4_SUBSYS, 'BuildAAC: no samples');
  if ASamplesPerFrame <= 0 then ASamplesPerFrame := 1024;
  if AChannels < 1 then AChannels := 1;
  now32 := MediaEpochNow;
  durationTicks := Int64(nSamples) * ASamplesPerFrame;

  w := TMP4BoxWriter.Create;
  try
    { ---- ftyp ---- }
    w.BeginBox('ftyp');
      w.FourCCStr('M4A ');
      w.U32(512);
      w.FourCCStr('M4A ');
      w.FourCCStr('mp42');
      w.FourCCStr('isom');
    w.CloseBox;

    { ---- moov ---- }
    w.BeginBox('moov');
      w.BeginBox('udta');
        w.BeginFullBox('cprt', 0, 0);
          w.U16($15C7);
          w.RawBytes(TEncoding.UTF8.GetBytes(UDAW_MEDIA_COPYRIGHT + #0));
        w.CloseBox;
      w.CloseBox;

      w.BeginFullBox('mvhd', 0, 0);
        w.U32(now32); w.U32(now32);
        w.U32(ASampleRate);                 // movie timescale
        w.U32(Cardinal(durationTicks));
        w.Fixed1616(1.0);                   // rate
        w.Fixed88(1.0);                     // volume
        w.U16(0); w.U32(0); w.U32(0);       // reserved
        { unity matrix }
        w.U32($00010000); w.U32(0); w.U32(0);
        w.U32(0); w.U32($00010000); w.U32(0);
        w.U32(0); w.U32(0); w.U32($40000000);
        w.Zeros(24);                        // pre_defined
        w.U32(2);                           // next_track_ID
      w.CloseBox;

      w.BeginBox('trak');

        w.BeginFullBox('tkhd', 0, 7);       // enabled | in movie | in preview
          w.U32(now32); w.U32(now32);
          w.U32(1);                         // track_ID
          w.U32(0);
          w.U32(Cardinal(durationTicks));
          w.U32(0); w.U32(0);
          w.U16(0);                         // layer
          w.U16(0);                         // alternate_group
          w.Fixed88(1.0);                   // volume
          w.U16(0);
          w.U32($00010000); w.U32(0); w.U32(0);
          w.U32(0); w.U32($00010000); w.U32(0);
          w.U32(0); w.U32(0); w.U32($40000000);
          w.Fixed1616(0.0);                 // width
          w.Fixed1616(0.0);                 // height
        w.CloseBox;

        w.BeginBox('mdia');

          w.BeginFullBox('mdhd', 0, 0);
            w.U32(now32); w.U32(now32);
            w.U32(ASampleRate);             // media timescale
            w.U32(Cardinal(durationTicks));
            w.U16($55C4);                   // language 'und'
            w.U16(0);
          w.CloseBox;

          w.BeginFullBox('hdlr', 0, 0);
            w.U32(0);                       // pre_defined
            w.FourCCStr('soun');
            w.U32(0); w.U32(0); w.U32(0);
            w.AsciiZ('UDAW Sound Handler');
            w.U8(0);
          w.CloseBox;

          w.BeginBox('minf');

            w.BeginFullBox('smhd', 0, 0);
              w.U16(0);                     // balance
              w.U16(0);
            w.CloseBox;

            w.BeginBox('dinf');
              w.BeginFullBox('dref', 0, 0);
                w.U32(1);
                w.BeginFullBox('url ', 0, 1);   // self-contained
                w.CloseBox;
              w.CloseBox;
            w.CloseBox;

            w.BeginBox('stbl');

              w.BeginFullBox('stsd', 0, 0);
                w.U32(1);                   // entry_count
                w.BeginBox('mp4a');
                  w.Zeros(6);              // reserved
                  w.U16(1);               // data_reference_index
                  w.U16(0); w.U16(0);     // version, revision
                  w.U32(0);              // vendor
                  w.U16(AChannels);
                  w.U16(16);             // samplesize
                  w.U16(0);             // compression ID
                  w.U16(0);            // packet size
                  w.Fixed1616(ASampleRate);
                  WriteEsds;
                w.CloseBox;
              w.CloseBox;

              w.BeginFullBox('stts', 0, 0);
                w.U32(1);
                w.U32(Cardinal(nSamples));
                w.U32(Cardinal(ASamplesPerFrame));
              w.CloseBox;

              w.BeginFullBox('stsc', 0, 0);
                w.U32(1);
                w.U32(1);                  // first_chunk
                w.U32(Cardinal(nSamples)); // samples_per_chunk
                w.U32(1);                  // sample_description_index
              w.CloseBox;

              w.BeginFullBox('stsz', 0, 0);
                w.U32(0);                  // sample_size = 0 -> table follows
                w.U32(Cardinal(nSamples));
                for i := 0 to nSamples - 1 do
                  w.U32(Cardinal(Length(ASamples[i])));
              w.CloseBox;

              w.BeginFullBox('stco', 0, 0);
                w.U32(1);
                w.U32(0);                  // placeholder, backpatched below
              w.CloseBox;

            w.CloseBox; // stbl
          w.CloseBox;   // minf
        w.CloseBox;     // mdia
      w.CloseBox;       // trak
    w.CloseBox;         // moov

    mdatOffset := w.Position;
    w.BeginBox('mdat');
      for i := 0 to nSamples - 1 do
        w.RawBytes(ASamples[i]);
    w.CloseBox;

    Result := w.ToBytes;
  finally
    w.Free;
  end;

  { backpatch the single stco entry: find 'stco' in the produced bytes and write
    the mdat payload offset.  The layout above is fixed, so a scan is safe. }
  BackpatchStco(Result, mdatOffset + 8);
end;

class function TMP4Writer.BuildPCM(AWriteCodec: TMP4WriteCodec;
  const AInterleaved: TBytes; ASampleRate, AChannels, AFrameCount: Integer): TBytes;
var
  w: TMP4BoxWriter;
  fourcc: string;
  bitsPerSample, bytesPerFrame: Integer;
  mdatOffset: Int64;
  now32: Cardinal;
begin
  if AChannels < 1 then AChannels := 1;
  bitsPerSample := 0;
  case AWriteCodec of
    mwcPCM_S16LE: begin fourcc := 'sowt'; bitsPerSample := 16; end;
    mwcPCM_S24LE: begin fourcc := 'in24'; bitsPerSample := 24; end;
    mwcPCM_F32LE: begin fourcc := 'fl32'; bitsPerSample := 32; end;
  else
    RaiseUDAW(errInvalidArgument, MP4_SUBSYS, 'BuildPCM: not a PCM write codec');
  end;
  bytesPerFrame := (bitsPerSample div 8) * AChannels;
  now32 := MediaEpochNow;

  w := TMP4BoxWriter.Create;
  try
    w.BeginBox('ftyp');
      w.FourCCStr('isom');
      w.U32(512);
      w.FourCCStr('isom');
      w.FourCCStr('iso2');
      w.FourCCStr('mp41');
    w.CloseBox;

    w.BeginBox('moov');
      w.BeginBox('udta');
        w.BeginFullBox('cprt', 0, 0);
          w.U16($15C7);
          w.RawBytes(TEncoding.UTF8.GetBytes(UDAW_MEDIA_COPYRIGHT + #0));
        w.CloseBox;
      w.CloseBox;
      w.BeginFullBox('mvhd', 0, 0);
        w.U32(now32); w.U32(now32);
        w.U32(ASampleRate);
        w.U32(Cardinal(AFrameCount));
        w.Fixed1616(1.0); w.Fixed88(1.0);
        w.U16(0); w.U32(0); w.U32(0);
        w.U32($00010000); w.U32(0); w.U32(0);
        w.U32(0); w.U32($00010000); w.U32(0);
        w.U32(0); w.U32(0); w.U32($40000000);
        w.Zeros(24);
        w.U32(2);
      w.CloseBox;

      w.BeginBox('trak');
        w.BeginFullBox('tkhd', 0, 7);
          w.U32(now32); w.U32(now32);
          w.U32(1); w.U32(0);
          w.U32(Cardinal(AFrameCount));
          w.U32(0); w.U32(0);
          w.U16(0); w.U16(0);
          w.Fixed88(1.0); w.U16(0);
          w.U32($00010000); w.U32(0); w.U32(0);
          w.U32(0); w.U32($00010000); w.U32(0);
          w.U32(0); w.U32(0); w.U32($40000000);
          w.Fixed1616(0.0); w.Fixed1616(0.0);
        w.CloseBox;

        w.BeginBox('mdia');
          w.BeginFullBox('mdhd', 0, 0);
            w.U32(now32); w.U32(now32);
            w.U32(ASampleRate);
            w.U32(Cardinal(AFrameCount));
            w.U16($55C4); w.U16(0);
          w.CloseBox;

          w.BeginFullBox('hdlr', 0, 0);
            w.U32(0); w.FourCCStr('soun');
            w.U32(0); w.U32(0); w.U32(0);
            w.AsciiZ('UDAW Sound Handler'); w.U8(0);
          w.CloseBox;

          w.BeginBox('minf');
            w.BeginFullBox('smhd', 0, 0);
              w.U16(0); w.U16(0);
            w.CloseBox;
            w.BeginBox('dinf');
              w.BeginFullBox('dref', 0, 0);
                w.U32(1);
                w.BeginFullBox('url ', 0, 1);
                w.CloseBox;
              w.CloseBox;
            w.CloseBox;

            w.BeginBox('stbl');
              w.BeginFullBox('stsd', 0, 0);
                w.U32(1);
                w.BeginBox(fourcc);
                  w.Zeros(6); w.U16(1);
                  w.U16(0); w.U16(0); w.U32(0);
                  w.U16(AChannels);
                  w.U16(bitsPerSample);
                  w.U16(0); w.U16(0);
                  w.Fixed1616(ASampleRate);
                w.CloseBox;
              w.CloseBox;

              w.BeginFullBox('stts', 0, 0);
                w.U32(1);
                w.U32(Cardinal(AFrameCount));
                w.U32(1);
              w.CloseBox;

              w.BeginFullBox('stsc', 0, 0);
                w.U32(1);
                w.U32(1);
                w.U32(Cardinal(AFrameCount));
                w.U32(1);
              w.CloseBox;

              w.BeginFullBox('stsz', 0, 0);
                w.U32(Cardinal(bytesPerFrame));   // constant sample size
                w.U32(Cardinal(AFrameCount));
              w.CloseBox;

              w.BeginFullBox('stco', 0, 0);
                w.U32(1);
                w.U32(0);
              w.CloseBox;
            w.CloseBox;
          w.CloseBox;
        w.CloseBox;
      w.CloseBox;
    w.CloseBox;

    mdatOffset := w.Position;
    w.BeginBox('mdat');
      w.RawBytes(AInterleaved);
    w.CloseBox;

    Result := w.ToBytes;
  finally
    w.Free;
  end;

  BackpatchStco(Result, mdatOffset + 8);
end;

{ Scan produced bytes for the (single) 'stco' box and write AChunkOffset into
  its first entry.  Used only by the writer on its own fixed output. }
procedure BackpatchStco(var ABytes: TBytes; AChunkOffset: Int64);
var
  i: Integer;
begin
  for i := 0 to Length(ABytes) - 9 do
    if (ABytes[i] = Ord('s')) and (ABytes[i + 1] = Ord('t')) and
       (ABytes[i + 2] = Ord('c')) and (ABytes[i + 3] = Ord('o')) then
    begin
      { box: [size:4]['stco'][ver/flags:4][entry_count:4][entry0:4] ;
        our i points at 's' of the type, so entry0 starts at i+4+4+4 = i+12 }
      if i + 16 <= Length(ABytes) then
      begin
        ABytes[i + 12] := (AChunkOffset shr 24) and $FF;
        ABytes[i + 13] := (AChunkOffset shr 16) and $FF;
        ABytes[i + 14] := (AChunkOffset shr 8) and $FF;
        ABytes[i + 15] := AChunkOffset and $FF;
      end;
      Exit;
    end;
end;

end.
