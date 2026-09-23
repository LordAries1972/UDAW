unit Tests.DAWImportAbleton;
{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}

{ Ableton Live Set (.als) importer tests - UDAW.Codec.Ableton only (the pure
  parser; the undoable TImportAlsProjectCommand in
  UDAW.Codec.Ableton.Timeline is a thin, already-covered-by-precedent wrapper
  over TTimeline's own AddTrack/AddSource/AddClip, mirrored line-for-line
  from TImportMp3Command/TImportFlacCommand).

  Every fixture is a REAL temporary file on disk (never an in-memory-only
  buffer), gzip-compressed with the same System.ZLib / TGZFileStream path
  AlsParseFile itself decompresses with, so the round trip through the
  compiler's own RTL zlib binding is exercised, not just the hand-rolled XML
  layer underneath it - mirroring how Tests.PhaseFLAC writes a real
  temp file to prove FlacSniffFile never trusts an extension. }

interface

procedure RegisterDAWImportAbletonTests;

implementation

uses
  SysUtils, Classes,
  {$IFDEF FPC}
  zstream,
  {$ELSE}
  System.ZLib,
  {$ENDIF}
  UDAW.Testing,
  UDAW.Paths,
  UDAW.Audio.Types,
  UDAW.Codec.WAV,
  UDAW.Codec.Ableton;

const
  GRP = 'daw-import.ableton';

{ ==================== fixture plumbing ==================== }

function TempPath(const AName: string): string;
begin
  Result := IncludeTrailingPathDelimiter(Paths.Temp) + AName;
  ForceDirectories(ExtractFilePath(Result));
end;

{ Gzip-compresses AXml (as UTF-8) directly into a real file at APath, using
  the same RTL zlib binding AlsGunzipToBytes decompresses with (System.ZLib
  windowBits=31 on Delphi, TGZFileStream on FPC) - see
  UDAW.Codec.Ableton.AlsGunzipToBytes's header comment for why each leg uses
  what it uses. }
procedure WriteGzipFile(const APath, AXml: string);
var
  bytes: TBytes;
  {$IFDEF FPC}
  gz: TGZFileStream;
  {$ELSE}
  fs: TFileStream;
  zs: TZCompressionStream;
  {$ENDIF}
begin
  bytes := TEncoding.UTF8.GetBytes(AXml);
  {$IFDEF FPC}
  gz := TGZFileStream.Create(APath, gzopenwrite);
  try
    if Length(bytes) > 0 then gz.WriteBuffer(bytes[0], Length(bytes));
  finally
    gz.Free;
  end;
  {$ELSE}
  fs := TFileStream.Create(APath, fmCreate);
  try
    zs := TZCompressionStream.Create(fs, zcDefault, 15 + 16);
    try
      if Length(bytes) > 0 then zs.WriteBuffer(bytes[0], Length(bytes));
    finally
      zs.Free;
    end;
  finally
    fs.Free;
  end;
  {$ENDIF}
end;

{ A minimal but structurally real fixture: one AudioTrack with one resolvable
  clip (its SampleRef/FileRef/RelativePath points at AWavName next to the
  .als file) and one MidiTrack (must be counted, never crash the parse). }
function MinimalAlsXml(const AWavName: string): string;
begin
  Result :=
    '<?xml version="1.0" encoding="UTF-8"?>' +
    '<Ableton MajorVersion="5" MinorVersion="11.0_11202" Creator="Ableton Live 11.0.12">' +
    '<LiveSet>' +
      '<MasterTrack>' +
        '<DeviceChain>' +
          '<Mixer>' +
            '<Tempo><Manual Value="128"/></Tempo>' +
          '</Mixer>' +
        '</DeviceChain>' +
      '</MasterTrack>' +
      '<Tracks>' +
        '<AudioTrack Id="0">' +
          '<Name><EffectiveName Value="Drums"/></Name>' +
          '<DeviceChain>' +
            '<MainSequencer>' +
              '<Sample>' +
                '<ArrangerAutomation>' +
                  '<Events>' +
                    '<AudioClip Time="4">' +
                      '<Name Value="Kick Loop"/>' +
                      '<CurrentStart Value="4"/>' +
                      '<CurrentEnd Value="8"/>' +
                      '<SampleRef>' +
                        '<FileRef>' +
                          '<RelativePathType Value="3"/>' +
                          '<RelativePath Value="' + AWavName + '"/>' +
                          '<Path Value="C:\nonexistent\' + AWavName + '"/>' +
                        '</FileRef>' +
                      '</SampleRef>' +
                    '</AudioClip>' +
                    '<AudioClip Time="0">' +
                      '<Name Value="Missing Sample"/>' +
                      '<CurrentStart Value="0"/>' +
                      '<CurrentEnd Value="4"/>' +
                      '<SampleRef>' +
                        '<FileRef>' +
                          '<RelativePathType Value="3"/>' +
                          '<RelativePath Value="nope_does_not_exist.wav"/>' +
                          '<Path Value="C:\nonexistent\nope_does_not_exist.wav"/>' +
                        '</FileRef>' +
                      '</SampleRef>' +
                    '</AudioClip>' +
                  '</Events>' +
                '</ArrangerAutomation>' +
              '</Sample>' +
            '</MainSequencer>' +
          '</DeviceChain>' +
        '</AudioTrack>' +
        '<MidiTrack Id="1">' +
          '<Name><EffectiveName Value="Lead"/></Name>' +
        '</MidiTrack>' +
      '</Tracks>' +
    '</LiveSet>' +
    '</Ableton>';
end;

function WriteTinyWav(const APath: string): Boolean;
var
  planar: TAudioPlanar;
begin
  EnsurePlanar(planar, 1, 32);
  SaveWavFile(APath, planar, 1, 44100, 32);
  Result := FileExists(APath);
end;

{ ==================== tests: gzip sniff ==================== }

procedure Test_Sniff_AcceptsRealGzip;
var
  path: string;
begin
  path := TempPath('udaw_als_sniff_ok.als');
  WriteGzipFile(path, '<Ableton/>');
  try
    Check(AlsSniffFile(path), 'a real gzip-compressed file sniffs as .als');
  finally
    if FileExists(path) then DeleteFile(path);
  end;
end;

procedure Test_Sniff_RejectsPlainText;
var
  path: string;
  sl: TStringList;
begin
  path := TempPath('udaw_als_sniff_bad.als');
  sl := TStringList.Create;
  try
    sl.Text := '<Ableton>not actually gzipped</Ableton>';
    sl.SaveToFile(path);
  finally
    sl.Free;
  end;
  try
    CheckFalse(AlsSniffFile(path), 'plain-text XML with an .als extension must not sniff as gzip');
  finally
    if FileExists(path) then DeleteFile(path);
  end;
end;

procedure Test_Sniff_RejectsMissingFile;
begin
  CheckFalse(AlsSniffFile(TempPath('udaw_als_does_not_exist_at_all.als')),
    'a nonexistent path never sniffs true');
end;

{ ==================== tests: parse round-trip ==================== }

procedure Test_Parse_RoundTripsTrackAndClip;
var
  alsPath, wavPath: string;
  project: TAbletonProject;
  warnings: TArray<string>;
  ok: Boolean;
begin
  alsPath := TempPath('udaw_als_roundtrip.als');
  wavPath := TempPath('kick.wav');
  Check(WriteTinyWav(wavPath), 'fixture WAV was written');
  WriteGzipFile(alsPath, MinimalAlsXml('kick.wav'));
  try
    ok := AlsParseFile(alsPath, project, warnings);
    Check(ok, 'AlsParseFile succeeds on a well-formed minimal fixture');
    CheckNear(128, project.Tempo, 1.0E-9, 'project tempo read from Tempo/Manual');
    CheckEqualInt(2, Length(project.Tracks), 'one AudioTrack + one MidiTrack parsed');

    CheckEqualBool(True, project.Tracks[0].Kind = atkAudio, 'track 0 is audio');
    CheckEqualStr('Drums', project.Tracks[0].Name, 'audio track name (EffectiveName)');
    { one clip resolves (kick.wav next to the .als); the other's sample does
      not exist anywhere and must be dropped, not crash the import. }
    CheckEqualInt(1, Length(project.Tracks[0].Clips), 'only the resolvable clip survives');
    CheckEqualStr('Kick Loop', project.Tracks[0].Clips[0].Name, 'clip name');
    { CurrentStart=4 / CurrentEnd=8 beats at 128 BPM -> 60/128 s per beat }
    CheckNear(4 * (60.0 / 128.0), project.Tracks[0].Clips[0].StartSeconds, 1.0E-6, 'clip start seconds');
    CheckNear(4 * (60.0 / 128.0), project.Tracks[0].Clips[0].LengthSeconds, 1.0E-6, 'clip length seconds');
    Check(SameText(ExpandFileName(project.Tracks[0].Clips[0].ResolvedFilePath), ExpandFileName(wavPath)),
      'clip resolved to the WAV sitting next to the .als file');

    CheckEqualBool(True, project.Tracks[1].Kind = atkMidi, 'track 1 is MIDI (recognised, not imported)');

    { the unresolved-sample clip and the skipped MIDI track must both have
      produced a warning instead of failing the whole parse. }
    Check(Length(warnings) > 0, 'at least one warning was collected');
  finally
    if FileExists(alsPath) then DeleteFile(alsPath);
    if FileExists(wavPath) then DeleteFile(wavPath);
  end;
end;

procedure Test_Parse_UnresolvableSampleWarnsInsteadOfFailing;
var
  alsPath: string;
  project: TAbletonProject;
  warnings: TArray<string>;
  i: Integer;
  found: Boolean;
begin
  { same fixture, but the "kick.wav" resolvable sample is never written to
    disk this time - BOTH clips on the audio track must now fail to
    resolve, and the parse must still succeed with two warnings, not raise. }
  alsPath := TempPath('udaw_als_unresolved.als');
  WriteGzipFile(alsPath, MinimalAlsXml('kick_never_written.wav'));
  try
    Check(AlsParseFile(alsPath, project, warnings),
      'a project whose samples cannot be resolved still parses successfully');
    CheckEqualInt(0, Length(project.Tracks[0].Clips),
      'no clips survive when no sample resolves');

    found := False;
    for i := 0 to High(warnings) do
      if Pos('sample not found', warnings[i]) > 0 then found := True;
    Check(found, 'an unresolved sample produces a "sample not found" warning');
  finally
    if FileExists(alsPath) then DeleteFile(alsPath);
  end;
end;

procedure Test_Parse_RejectsNonAbletonDocument;
var
  path: string;
  project: TAbletonProject;
  warnings: TArray<string>;
  raised: Boolean;
begin
  path := TempPath('udaw_als_not_a_liveset.als');
  WriteGzipFile(path, '<SomethingElse/>');
  raised := False;
  try
    try
      AlsParseFile(path, project, warnings);
    except
      raised := True;
    end;
  finally
    if FileExists(path) then DeleteFile(path);
  end;
  Check(raised, 'a gzip file whose XML root is not <Ableton> raises rather than silently succeeding');
end;

{ ---------------- registration ---------------- }

procedure RegisterDAWImportAbletonTests;
begin
  RegisterTest(GRP, 'sniff accepts a real gzip file', Test_Sniff_AcceptsRealGzip);
  RegisterTest(GRP, 'sniff rejects plain text with an .als extension', Test_Sniff_RejectsPlainText);
  RegisterTest(GRP, 'sniff rejects a missing file', Test_Sniff_RejectsMissingFile);
  RegisterTest(GRP, 'parse round-trips tempo/track/clip fields', Test_Parse_RoundTripsTrackAndClip);
  RegisterTest(GRP, 'an unresolvable sample warns instead of failing the import',
    Test_Parse_UnresolvableSampleWarnsInsteadOfFailing);
  RegisterTest(GRP, 'a non-Ableton gzip document raises', Test_Parse_RejectsNonAbletonDocument);
end;

end.
