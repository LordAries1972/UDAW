unit UDAW.Codec.FLAC;
{$I udaw.inc}

{ FLAC decode/encode support: the single entry point other code uses,
  mirroring UDAW.Codec.MP3's shape. Decoding was the original scope (see
  docs/PhaseFLAC-Decoder.md); FlacEncodeFile (UDAW.Codec.FLAC.Encoder) adds a
  fixed-predictor-only encoder for the Timeline exporter's FLAC option.

  Nothing here trusts a file extension - FlacSniff* look for the literal
  4-byte "fLaC" signature (optionally past a leading ID3v2 tag).  Decoding
  produces the engine-wide planar Float32 layout. }

interface

uses {$IFDEF FPC}UDAW.Compat,{$ENDIF}
  SysUtils, Classes,
  UDAW.Errors, UDAW.Audio.Types,
  UDAW.Codec.FLAC.Frame,
  UDAW.Codec.FLAC.Decoder,
  UDAW.Codec.FLAC.Encoder;

type
  { re-exported so callers only need this unit }
  TFLACStreamInfo   = UDAW.Codec.FLAC.Frame.TFlacStreamInfo;
  TFLACDecodeResult = UDAW.Codec.FLAC.Decoder.TFLACDecodeResult;

{ ---- sniffing ---- }
function FlacSniffData(const AData: TBytes): Boolean;
function FlacSniffFile(const AFileName: string): Boolean;

{ ---- inspect without decoding audio (STREAMINFO only, fast) ---- }
function FlacProbe(const AData: TBytes; out AInfo: TFLACStreamInfo): Boolean;
function FlacProbeFile(const AFileName: string; out AInfo: TFLACStreamInfo): Boolean;

{ ---- decode ---- }
function FlacDecode(const AData: TBytes; out ARes: TFLACDecodeResult): Boolean;
function FlacDecodeFile(const AFileName: string; out ARes: TFLACDecodeResult): Boolean;

{ ---- encode ---- }
procedure FlacEncodeToFile(const AWavFile, AOutputFile: string; AProgress: TProc<Double> = nil);

implementation

function LoadFile(const AFileName: string; const ASubsys: string): TBytes;
var
  fs: TFileStream;
begin
  if not FileExists(AFileName) then
    RaiseUDAWFmt(errFileNotFound, ASubsys, 'FLAC file not found: %s', [AFileName]);
  fs := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Result, fs.Size);
    if Length(Result) > 0 then fs.ReadBuffer(Result[0], Length(Result));
  finally
    fs.Free;
  end;
end;

function FlacSniffData(const AData: TBytes): Boolean;
begin
  Result := (Length(AData) >= 4) and DataLooksLikeFlac(AData[0], Length(AData));
end;

function FlacSniffFile(const AFileName: string): Boolean;
begin
  Result := FileLooksLikeFlac(AFileName);
end;

function FlacProbe(const AData: TBytes; out AInfo: TFLACStreamInfo): Boolean;
var
  audioStart: Int64;
begin
  Result := ScanFlacMetadata(AData, AInfo, audioStart);
end;

function FlacProbeFile(const AFileName: string; out AInfo: TFLACStreamInfo): Boolean;
begin
  Result := FlacProbe(LoadFile(AFileName, FLAC_SUBSYS), AInfo);
end;

function FlacDecode(const AData: TBytes; out ARes: TFLACDecodeResult): Boolean;
begin
  Result := DecodeFlac(AData, ARes);
end;

function FlacDecodeFile(const AFileName: string; out ARes: TFLACDecodeResult): Boolean;
begin
  Result := DecodeFlacFile(AFileName, ARes);
end;

procedure FlacEncodeToFile(const AWavFile, AOutputFile: string; AProgress: TProc<Double>);
begin
  FlacEncodeFile(AWavFile, AOutputFile, AProgress);
end;

end.
