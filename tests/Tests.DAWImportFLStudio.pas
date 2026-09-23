unit Tests.DAWImportFLStudio;
{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}

{ Focused fixtures for the pure FLP parser.  The fixture is a structurally
  valid FLhd/FLdt stream, assembled here rather than checked into the source
  tree as a binary blob so each event boundary and byte order remains
  reviewable. }

interface

procedure RegisterDAWImportFLStudioTests;

implementation

uses
  SysUtils, Classes,
  UDAW.Testing, UDAW.Paths, UDAW.Codec.FLStudio;

const
  GRP = 'daw-import.flstudio';

procedure AddByte(var AData: TBytes; AValue: Byte);
var
  n: Integer;
begin
  n := Length(AData); SetLength(AData, n + 1); AData[n] := AValue;
end;

procedure AddWordLE(var AData: TBytes; AValue: Word);
begin
  AddByte(AData, Byte(AValue));
  AddByte(AData, Byte(AValue shr 8));
end;

procedure AddDwordLE(var AData: TBytes; AValue: Cardinal);
begin
  AddByte(AData, Byte(AValue));
  AddByte(AData, Byte(AValue shr 8));
  AddByte(AData, Byte(AValue shr 16));
  AddByte(AData, Byte(AValue shr 24));
end;

procedure AddData(var AData: TBytes; const APayload: TBytes);
var
  i: Integer;
begin
  for i := 0 to High(APayload) do AddByte(AData, APayload[i]);
end;

procedure AddVarEvent(var AData: TBytes; AId: Byte; const APayload: TBytes);
var
  value: Integer;
begin
  AddByte(AData, AId);
  value := Length(APayload);
  repeat
    if value >= 128 then AddByte(AData, Byte(value and $7F) or $80)
    else AddByte(AData, Byte(value));
    value := value shr 7;
  until value = 0;
  AddData(AData, APayload);
end;

function AsciiZ(const AText: string): TBytes;
var
  i: Integer;
begin
  SetLength(Result, Length(AText) + 1);
  for i := 1 to Length(AText) do Result[i - 1] := Ord(AText[i]);
  Result[High(Result)] := 0;
end;

function TempPath(const AName: string): string;
begin
  Result := IncludeTrailingPathDelimiter(Paths.Temp) + AName;
  ForceDirectories(ExtractFilePath(Result));
end;

function MinimalFlp(const ASamplePath: string): TBytes;
var
  body, playlist: TBytes;
begin
  SetLength(body, 0);
  { Channel 1 is a sampler with a path, a name, and 120 BPM. }
  AddByte(body, 64); AddWordLE(body, 1);       // New channel
  AddByte(body, 21); AddByte(body, 0);         // Sampler channel
  AddByte(body, 156); AddDwordLE(body, 120000);
  AddVarEvent(body, 199, AsciiZ('11.0.0'));    // text is ASCII before 11.5
  AddVarEvent(body, 192, AsciiZ('Kick'));
  AddVarEvent(body, 196, AsciiZ(ASamplePath));

  SetLength(playlist, 32);
  playlist[0] := 96;                           // start tick
  playlist[4] := 0; playlist[5] := 80;         // pattern base = 20480
  playlist[6] := 1;                            // channel id
  playlist[8] := 96;                           // length ticks
  playlist[12] := 1;                           // FL playlist track
  AddVarEvent(body, 233, playlist);

  SetLength(Result, 0);
  AddByte(Result, $46); AddByte(Result, $4C); AddByte(Result, $68); AddByte(Result, $64); // FLhd
  AddDwordLE(Result, 6);
  AddWordLE(Result, 0); AddWordLE(Result, 1); AddWordLE(Result, 96);
  AddByte(Result, $46); AddByte(Result, $4C); AddByte(Result, $64); AddByte(Result, $74); // FLdt
  AddDwordLE(Result, Length(body));
  AddData(Result, body);
end;

procedure Test_Sniff_UsesMagicNotExtension;
var
  data: TBytes;
begin
  data := MinimalFlp('does-not-matter.wav');
  Check(FlpSniffData(data), 'FLhd magic is accepted');
  data[0] := 0;
  CheckFalse(FlpSniffData(data), 'a changed magic is rejected');
end;

procedure Test_Parse_ImportsResolvedPlaylistClip;
var
  flpPath, samplePath: string;
  fs: TFileStream;
  project: TFlpProject;
  warnings: TArray<string>;
begin
  flpPath := TempPath('udaw_flp_roundtrip.flp');
  samplePath := TempPath('kick.wav');
  fs := TFileStream.Create(samplePath, fmCreate);
  fs.Free;
  try
    Check(FlpParseData(MinimalFlp('kick.wav'), flpPath, project, warnings),
      'a minimal valid FLP parses');
    CheckNear(120, project.Tempo, 1.0E-9, 'tempo comes from the DWORD event');
    CheckEqualInt(96, project.PPQ, 'PPQ comes from FLhd');
    CheckEqualInt(1, Length(project.Clips), 'one resolved sampler block imports');
    CheckEqualStr('Kick', project.Clips[0].Name, 'channel name is preserved');
    CheckNear(0.5, project.Clips[0].StartSeconds, 1.0E-9, '96 ticks at 120 BPM / 96 PPQ');
    CheckNear(0.5, project.Clips[0].LengthSeconds, 1.0E-9, 'clip length uses the same timebase');
    Check(SameText(ExpandFileName(samplePath), project.Clips[0].ResolvedFilePath),
      'a sibling sample path resolves next to the FLP');
  finally
    if FileExists(samplePath) then DeleteFile(samplePath);
  end;
end;

procedure Test_Parse_UnresolvedSampleWarns;
var
  project: TFlpProject;
  warnings: TArray<string>;
begin
  Check(FlpParseData(MinimalFlp('missing-forever.wav'), '', project, warnings),
    'unresolved audio does not make a valid project fail to parse');
  CheckEqualInt(0, Length(project.Clips), 'unresolved sample is not fabricated as a clip');
  Check(Length(warnings) > 0, 'unresolved sample is reported to the caller');
end;

procedure RegisterDAWImportFLStudioTests;
begin
  RegisterTest(GRP, 'sniff uses FLhd content magic', Test_Sniff_UsesMagicNotExtension);
  RegisterTest(GRP, 'parse imports a resolved playlist sampler clip', Test_Parse_ImportsResolvedPlaylistClip);
  RegisterTest(GRP, 'unresolved sample warns without failing the project', Test_Parse_UnresolvedSampleWarns);
end;

end.
