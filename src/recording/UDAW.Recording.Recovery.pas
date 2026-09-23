unit UDAW.Recording.Recovery;
{$I udaw.inc}

{ Phase 8 - Recording: crash recovery for unfinished takes (plan section 22
  RECOVERY: "record to recoverable temporary chunks ... detect unfinished
  recording ... rebuild header/index ... offer recovery"; section 56 "recording
  recovery").

  Every take container carries a take.inprogress marker that only a clean
  TRecordingChunkWriter.Finalize removes. TRecordingRecovery scans the recording
  root for containers that still have that marker - the debris of a session that
  crashed or was killed mid-record - validates each one, rebuilds its usable
  frame count straight from the bytes on disk, and can encode it to a real .wav
  the user is offered on the next launch. Discard deletes a container the user
  does not want. }

interface

uses
  SysUtils, Classes, Generics.Collections,
  UDAW.Errors,
  UDAW.Codec.WAV,
  UDAW.Recording.Types, UDAW.Recording.ChunkFile;

type
  TRecordingRecovery = class
  private
    FRoot: string;
  public
    constructor Create(const ARecordingRoot: string);

    { True if at least one unfinished take container exists under the root. }
    function HasUnfinishedTakes: Boolean;

    { Every unfinished take container under the root, newest first. FrameCount /
      status are the result of a fresh index rebuild, so a torn tail is already
      accounted for. WavFile is '' (nothing has been recovered yet). }
    function ScanUnfinished: TRecordedTakeArray;

    { Rebuild ASessionDir's index and encode its usable audio to AWavFile.
      Returns the recovered take, now Status = tsRecovered with WavFile set.
      Leaves the container in place (call DiscardSession to remove it). }
    function RecoverSession(const ASessionDir, AWavFile: string;
      AFormat: TWavSampleFormat = wsfFloat32): TRecordedTake;

    { Recover every unfinished take into ADestDir (one <id>.wav per take). }
    function RecoverAll(const ADestDir: string;
      AFormat: TWavSampleFormat = wsfFloat32): TRecordedTakeArray;

    { Permanently delete a take container. }
    procedure DiscardSession(const ASessionDir: string);
    { Delete every unfinished take container. }
    procedure DiscardAllUnfinished;

    property Root: string read FRoot;
  end;

implementation

uses
  Math;

constructor TRecordingRecovery.Create(const ARecordingRoot: string);
begin
  inherited Create;
  if Trim(ARecordingRoot) = '' then
    RaiseUDAW(errInvalidArgument, RECORDING_SUBSYS, 'recovery: empty root path');
  FRoot := ExcludeTrailingPathDelimiter(ARecordingRoot);
end;

function TRecordingRecovery.HasUnfinishedTakes: Boolean;
begin
  Result := Length(ScanUnfinished) > 0;
end;

function TRecordingRecovery.ScanUnfinished: TRecordedTakeArray;
var
  sr: TSearchRec;
  dir: string;
  reader: TRecordingChunkReader;
  list: TList<TRecordedTake>;
  i, j: Integer;
  tmp: TRecordedTake;
begin
  list := TList<TRecordedTake>.Create;
  try
    if DirectoryExists(FRoot) and
       (FindFirst(IncludeTrailingPathDelimiter(FRoot) + '*', faDirectory, sr) = 0) then
    begin
      try
        repeat
          if (sr.Name = '.') or (sr.Name = '..') then Continue;
          if (sr.Attr and faDirectory) = 0 then Continue;
          dir := IncludeTrailingPathDelimiter(FRoot) + sr.Name;
          if not IsRecordingSessionDir(dir) then Continue;
          if not FileExists(ChunkMarkerPath(dir)) then Continue;   // finalized cleanly
          try
            reader := TRecordingChunkReader.Create(dir);
            try
              tmp := reader.ToRecordedTake;
              tmp.Status := tsRecording;
              list.Add(tmp);
            finally
              reader.Free;
            end;
          except
            { a container too broken to even parse the meta is skipped, not fatal }
          end;
        until FindNext(sr) <> 0;
      finally
        FindClose(sr);
      end;
    end;

    { newest first, by StartedUTC then id }
    for i := 0 to list.Count - 2 do
      for j := i + 1 to list.Count - 1 do
        if (list[j].StartedUTC > list[i].StartedUTC) or
           ((list[j].StartedUTC = list[i].StartedUTC) and (list[j].Id > list[i].Id)) then
        begin
          tmp := list[i];
          list[i] := list[j];
          list[j] := tmp;
        end;

    SetLength(Result, list.Count);
    for i := 0 to list.Count - 1 do
      Result[i] := list[i];
  finally
    list.Free;
  end;
end;

function TRecordingRecovery.RecoverSession(const ASessionDir, AWavFile: string;
  AFormat: TWavSampleFormat): TRecordedTake;
var
  reader: TRecordingChunkReader;
begin
  if not IsRecordingSessionDir(ASessionDir) then
    RaiseUDAWFmt(errFileNotFound, RECORDING_SUBSYS,
      'not a take container: "%s"', [ASessionDir]);
  reader := TRecordingChunkReader.Create(ASessionDir);   // ctor rebuilds the index
  try
    reader.FinalizeToWav(AWavFile, AFormat);
    Result := reader.ToRecordedTake;
  finally
    reader.Free;
  end;
  Result.Status := tsRecovered;
  Result.WavFile := AWavFile;
end;

function TRecordingRecovery.RecoverAll(const ADestDir: string;
  AFormat: TWavSampleFormat): TRecordedTakeArray;
var
  pending: TRecordedTakeArray;
  i: Integer;
  wav: string;
begin
  pending := ScanUnfinished;
  ForceDirectories(ADestDir);
  SetLength(Result, Length(pending));
  for i := 0 to High(pending) do
  begin
    wav := IncludeTrailingPathDelimiter(ADestDir) + pending[i].Id + '.wav';
    Result[i] := RecoverSession(pending[i].SessionDir, wav, AFormat);
  end;
end;

procedure TRecordingRecovery.DiscardSession(const ASessionDir: string);
var
  sr: TSearchRec;
  base: string;
begin
  base := IncludeTrailingPathDelimiter(ASessionDir);
  if FindFirst(base + '*', faAnyFile, sr) = 0 then
  begin
    try
      repeat
        if (sr.Name = '.') or (sr.Name = '..') then Continue;
        if (sr.Attr and faDirectory) = 0 then
          DeleteFile(base + sr.Name);
      until FindNext(sr) <> 0;
    finally
      FindClose(sr);
    end;
  end;
  RemoveDir(ExcludeTrailingPathDelimiter(ASessionDir));
end;

procedure TRecordingRecovery.DiscardAllUnfinished;
var
  pending: TRecordedTakeArray;
  i: Integer;
begin
  pending := ScanUnfinished;
  for i := 0 to High(pending) do
    DiscardSession(pending[i].SessionDir);
end;

end.
