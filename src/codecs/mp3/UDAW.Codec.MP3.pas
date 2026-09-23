unit UDAW.Codec.MP3;
{$I udaw.inc}

{ Phase 15 - MP3 support: the single entry point that ties the frame walker,
  the Layer III decoder, the Layer III encoder and the ID3 metadata reader /
  writer together, mirroring UDAW.Codec.WAV for the PCM/WAV area.

  Nothing here trusts a file extension - Mp3Sniff* look for a real MPEG-audio
  sync (or a leading ID3v2 tag).  Decoding produces the engine-wide planar
  Float32 layout; encoding accepts the same. }

interface

uses
  SysUtils, Classes,
  UDAW.Errors, UDAW.Audio.Types,
  UDAW.Codec.MP3.Frame,
  UDAW.Codec.MP3.Tables,
  UDAW.Codec.MP3.Decoder,
  UDAW.Codec.MP3.Encoder,
  UDAW.Codec.MP3.Metadata;

type
  { re-exported so callers only need this unit }
  TMP3StreamInfo   = UDAW.Codec.MP3.Frame.TMP3StreamInfo;
  TMP3DecodeResult = UDAW.Codec.MP3.Decoder.TMP3DecodeResult;
  TMP3EncodeMode   = UDAW.Codec.MP3.Encoder.TMP3EncodeMode;
  TMP3EncodeOptions = UDAW.Codec.MP3.Encoder.TMP3EncodeOptions;
  TMP3EncodeResult = UDAW.Codec.MP3.Encoder.TMP3EncodeResult;
  TMP3Metadata     = UDAW.Codec.MP3.Metadata.TMP3Metadata;

{ ---- sniffing ---- }
function Mp3SniffData(const AData: TBytes): Boolean;
function Mp3SniffFile(const AFileName: string): Boolean;

{ ---- inspect without decoding audio ---- }
function Mp3Probe(const AData: TBytes; out AInfo: TMP3StreamInfo): Boolean;
function Mp3ProbeFile(const AFileName: string; out AInfo: TMP3StreamInfo): Boolean;

{ ---- decode ---- }
function Mp3Decode(const AData: TBytes; out ARes: TMP3DecodeResult;
  ATrimEncoderDelay: Boolean = True): Boolean;
function Mp3DecodeFile(const AFileName: string; out ARes: TMP3DecodeResult;
  ATrimEncoderDelay: Boolean = True): Boolean;

{ ---- encode ---- }
function Mp3DefaultEncodeOptions: TMP3EncodeOptions;
function Mp3Encode(const APcm: TAudioPlanar; ASampleRate: Integer;
  const AOpts: TMP3EncodeOptions; out ARes: TMP3EncodeResult): Boolean;
function Mp3EncodeToFile(const APcm: TAudioPlanar; ASampleRate: Integer;
  const AFileName: string; const AOpts: TMP3EncodeOptions): Boolean;

{ ---- metadata ---- }
function Mp3ReadMetadata(const AData: TBytes): TMP3Metadata;
function Mp3ReadMetadataFile(const AFileName: string): TMP3Metadata;
{ rewrite AInFile to AOutFile with a fresh ID3v2 (front) + ID3v1 (back),
  preserving the audio bytes verbatim }
function Mp3WriteMetadataFile(const AInFile, AOutFile: string;
  const AMeta: TMP3Metadata): Boolean;

implementation

function LoadFile(const AFileName: string; const ASubsys: string): TBytes;
var
  fs: TFileStream;
begin
  if not FileExists(AFileName) then
    RaiseUDAWFmt(errFileNotFound, ASubsys, 'MP3 file not found: %s', [AFileName]);
  fs := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Result, fs.Size);
    if Length(Result) > 0 then fs.ReadBuffer(Result[0], Length(Result));
  finally
    fs.Free;
  end;
end;

function Mp3SniffData(const AData: TBytes): Boolean;
begin
  Result := (Length(AData) >= 4) and DataLooksLikeMp3(AData[0], Length(AData));
end;

function Mp3SniffFile(const AFileName: string): Boolean;
begin
  Result := FileLooksLikeMp3(AFileName);
end;

function Mp3Probe(const AData: TBytes; out AInfo: TMP3StreamInfo): Boolean;
begin
  Result := ScanMp3Stream(AData, AInfo);
end;

function Mp3ProbeFile(const AFileName: string; out AInfo: TMP3StreamInfo): Boolean;
begin
  Result := ScanMp3Stream(LoadFile(AFileName, MP3_SUBSYS), AInfo);
end;

function Mp3Decode(const AData: TBytes; out ARes: TMP3DecodeResult;
  ATrimEncoderDelay: Boolean): Boolean;
begin
  Result := DecodeMp3(AData, ARes, ATrimEncoderDelay);
end;

function Mp3DecodeFile(const AFileName: string; out ARes: TMP3DecodeResult;
  ATrimEncoderDelay: Boolean): Boolean;
begin
  Result := DecodeMp3File(AFileName, ARes, ATrimEncoderDelay);
end;

function Mp3DefaultEncodeOptions: TMP3EncodeOptions;
begin
  Result := TMP3EncodeOptions.Default;
end;

function Mp3Encode(const APcm: TAudioPlanar; ASampleRate: Integer;
  const AOpts: TMP3EncodeOptions; out ARes: TMP3EncodeResult): Boolean;
begin
  Result := EncodeMp3(APcm, ASampleRate, AOpts, ARes);
end;

function Mp3EncodeToFile(const APcm: TAudioPlanar; ASampleRate: Integer;
  const AFileName: string; const AOpts: TMP3EncodeOptions): Boolean;
begin
  Result := EncodeMp3ToFile(APcm, ASampleRate, AFileName, AOpts);
end;

function Mp3ReadMetadata(const AData: TBytes): TMP3Metadata;
begin
  Result := ReadMp3Metadata(AData);
end;

function Mp3ReadMetadataFile(const AFileName: string): TMP3Metadata;
begin
  Result := ReadMp3MetadataFile(AFileName);
end;

function Mp3WriteMetadataFile(const AInFile, AOutFile: string;
  const AMeta: TMP3Metadata): Boolean;
begin
  Result := WriteMp3WithMetadata(AInFile, AOutFile, AMeta) > 0;
end;

end.
