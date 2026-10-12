unit UDAW.Timeline.VideoFxCache;
{$I udaw.inc}

{ Plays video effects: before the transport starts, the Timeline's picture is
  rendered once - effects and transitions applied - into a cache file, and
  playback shows that file instead of the raw clips.

  The cache file is named after a hash of everything that shapes the picture
  (which clips, from which files, where, reversed or tempo-conformed, and every
  effect with its settings), so an unchanged video is never rendered twice:
  the next Play finds the file and starts at once; any edit that matters gives a
  new name and a fresh render.

  Speed: the render runs on its own job thread beside the audio preparation, at
  a capped picture size without sound, using the hardware encoder when Windows
  offers one (see RenderTimelineVideoPreview), and only the span that holds
  video is rendered. }

interface

uses
  Winapi.Windows, SysUtils, Classes, UDAW.Jobs, UDAW.Timeline.Model;

type
  TVideoFxPlan = record
    Needed: Boolean;        // video effects touch picture that will play
    Start: Double;          // timeline second the rendered file begins at
    Duration: Double;
    Key: string;            // content hash
    CachePath: string;
  end;

{ Works out whether a pre-render is needed and where its file lives. }
function PlanVideoFxRender(ATl: TTimeline; AStretchBPM: Double;
  const ACacheDir: string): TVideoFxPlan;

{ True when the plan's cache file already exists (and is not empty). }
function VideoFxCacheHit(const APlan: TVideoFxPlan): Boolean;

{ Keeps the newest AKeep rendered files, removes older ones and any leftovers
  of an interrupted render. }
procedure PruneVideoFxCache(const ACacheDir: string; AKeep: Integer);

type
  { Renders the plan on a worker thread, with progress and cancel through the
    job's own Progress / Note / Cancel. Works on a private copy of the Timeline,
    so the user may keep editing meanwhile. }
  TVideoFxRenderJob = class(TJob)
  private
    FTl: TTimeline;
    FPlan: TVideoFxPlan;
    FStretchBPM: Double;
  protected
    function Execute: Boolean; override;
  public
    constructor Create(ATl: TTimeline; const APlan: TVideoFxPlan; AStretchBPM: Double);
    destructor Destroy; override;
    property Plan: TVideoFxPlan read FPlan;
  end;

implementation

uses
  Math, IOUtils, Types, System.Hash, UDAW.Timeline.VideoExport;

const
  CACHE_FORMAT = 'vfx1';        // bump when the renderer's output changes
  PREVIEW_WIDTH = 960;          // widest pre-rendered picture
  FILE_PREFIX = 'video-fx-';

function F6(AValue: Double): string;
begin
  Result := FloatToStrF(AValue, ffFixed, 15, 6, TFormatSettings.Invariant);
end;

function SourceStamp(const APath: string): string;
var
  sr: TSearchRec;
begin
  Result := 'missing';
  if FindFirst(APath, faAnyFile, sr) = 0 then
  try
    Result := IntToStr(sr.Size) + '/' + IntToStr(Round(sr.TimeStamp * 86400));
  finally
    FindClose(sr);
  end;
end;

function PlanVideoFxRender(ATl: TTimeline; AStretchBPM: Double;
  const ACacheDir: string): TVideoFxPlan;
var
  sb: TStringBuilder;
  i, j: Integer;
  trk: TTimelineTrack;
  c: TTimelineClip;
  src: TMediaSource;
  r: TVideoEffectRegion;
  first, last: Double;
  haveClip, haveFx: Boolean;
begin
  Result.Needed := False;
  Result.Start := 0;
  Result.Duration := 0;
  Result.Key := '';
  Result.CachePath := '';
  if (ATl = nil) or (ATl.VideoEffectCount = 0) then Exit;
  sb := TStringBuilder.Create;
  try
    sb.Append(CACHE_FORMAT).Append('|w').Append(PREVIEW_WIDTH).Append('|t').Append(F6(AStretchBPM));
    first := 1E30;
    last := 0;
    haveClip := False;
    for i := 0 to ATl.TrackCount - 1 do
    begin
      trk := ATl.GetTrack(i);
      if (trk.Kind <> tkVideo) or trk.Muted then Continue;
      sb.Append('|T').Append(i);
      for j := 0 to trk.ClipCount - 1 do
      begin
        c := trk.GetClip(j);
        if c.Muted or c.IsMidiClip then Continue;
        src := ATl.SourceById(c.SourceId);
        if (src = nil) or (src.Kind <> mkVideoFile) then Continue;
        haveClip := True;
        first := Min(first, c.StartSeconds);
        last := Max(last, c.EndSeconds);
        sb.Append('|C').Append(LowerCase(src.Path)).Append('@').Append(SourceStamp(src.Path))
          .Append(',').Append(F6(c.StartSeconds)).Append(',').Append(F6(c.SourceOffsetSeconds))
          .Append(',').Append(F6(c.LengthSeconds)).Append(',').Append(Ord(c.Reversed))
          .Append(',').Append(F6(c.SourceBPM));
      end;
    end;
    if not haveClip then Exit;
    haveFx := False;
    for i := 0 to ATl.VideoEffectCount - 1 do
    begin
      r := ATl.GetVideoEffect(i);
      trk := ATl.TrackById(r.TrackId);
      if (trk = nil) or (trk.Kind <> tkVideo) or trk.Muted then Continue;
      if (r.EndSeconds <= first) or (r.StartSeconds >= last) then Continue;
      haveFx := True;
      sb.Append('|E').Append(ATl.IndexOfTrack(r.TrackId)).Append(',').Append(LowerCase(r.Kind))
        .Append(',').Append(F6(r.StartSeconds)).Append(',').Append(F6(r.LengthSeconds))
        .Append(',').Append(F6(r.PivotSeconds)).Append(',').Append(r.Params);
    end;
    if not haveFx then Exit;
    Result.Needed := True;
    Result.Start := first;
    Result.Duration := last - first;
    Result.Key := THashMD5.GetHashString(sb.ToString);
    Result.CachePath := IncludeTrailingPathDelimiter(ACacheDir) + FILE_PREFIX + Result.Key + '.mp4';
  finally
    sb.Free;
  end;
end;

function VideoFxCacheHit(const APlan: TVideoFxPlan): Boolean;
var
  sr: TSearchRec;
begin
  Result := False;
  if (not APlan.Needed) or (APlan.CachePath = '') then Exit;
  if FindFirst(APlan.CachePath, faAnyFile, sr) = 0 then
  try
    Result := sr.Size > 1024;
  finally
    FindClose(sr);
  end;
end;

procedure PruneVideoFxCache(const ACacheDir: string; AKeep: Integer);
var
  files: TStringDynArray;
  stamps: array of TDateTime;
  i, j, n: Integer;
  tmpS: string;
  tmpT: TDateTime;
begin
  if not DirectoryExists(ACacheDir) then Exit;
  try
    for tmpS in TDirectory.GetFiles(ACacheDir, FILE_PREFIX + '*.part.mp4') do
      DeleteFile(tmpS);
    files := TDirectory.GetFiles(ACacheDir, FILE_PREFIX + '*.mp4');
    n := Length(files);
    if n <= AKeep then Exit;
    SetLength(stamps, n);
    for i := 0 to n - 1 do stamps[i] := TFile.GetLastWriteTime(files[i]);
    { newest first }
    for i := 0 to n - 2 do
      for j := i + 1 to n - 1 do
        if stamps[j] > stamps[i] then
        begin
          tmpS := files[i]; files[i] := files[j]; files[j] := tmpS;
          tmpT := stamps[i]; stamps[i] := stamps[j]; stamps[j] := tmpT;
        end;
    for i := AKeep to n - 1 do DeleteFile(files[i]);
  except
    { housekeeping only - never let it stop playback }
  end;
end;

{ ============================ TVideoFxRenderJob ========================== }

constructor TVideoFxRenderJob.Create(ATl: TTimeline; const APlan: TVideoFxPlan; AStretchBPM: Double);
begin
  inherited Create('Pre-render video effects');
  FTl := ATl.Clone;               // the user may edit while this runs
  FPlan := APlan;
  FStretchBPM := AStretchBPM;
end;

destructor TVideoFxRenderJob.Destroy;
begin
  FTl.Free;
  inherited;
end;

function TVideoFxRenderJob.Execute: Boolean;
var
  part: string;
  started: UInt64;
begin
  SetProgress(0, 'Pre-rendering video effects...');
  ForceDirectories(ExtractFilePath(FPlan.CachePath));
  part := ChangeFileExt(FPlan.CachePath, '') + '.part.mp4';
  DeleteFile(part);
  started := TThread.GetTickCount64;
  try
    RenderTimelineVideoPreview(FTl, part, FPlan.Start, FPlan.Duration, FStretchBPM, PREVIEW_WIDTH,
      procedure(AFraction: Double)
      var
        eta: string;
        spent: Double;
      begin
        ThrowIfCancelled;
        eta := '';
        spent := (TThread.GetTickCount64 - started) / 1000;
        if (AFraction > 0.05) and (spent > 1) then
          eta := Format(', about %d s left', [Round(spent * (1 - AFraction) / AFraction)]);
        SetProgress(AFraction, Format('Pre-rendering video effects - %d%%%s',
          [Round(AFraction * 100), eta]));
      end);
    ThrowIfCancelled;
    DeleteFile(FPlan.CachePath);
    if not RenameFile(part, FPlan.CachePath) then
      raise Exception.Create('could not store the rendered video in the cache');
  except
    DeleteFile(part);
    raise;
  end;
  SetProgress(1, 'Video effects rendered and cached');
  Result := True;
end;

end.
