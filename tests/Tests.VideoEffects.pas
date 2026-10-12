unit Tests.VideoEffects;
{ Video effects and transitions: the catalogue, the pixel engine, region
  lookup, undo and the project round trip. }
interface
procedure RegisterVideoEffectsTests;
implementation
uses SysUtils, Math, UDAW.Testing, UDAW.Video.Effects, UDAW.Project.Document,
  UDAW.Timeline.Model, UDAW.Timeline.Commands, UDAW.Timeline.Serialization,
  UDAW.Timeline.VideoExport;

const
  W = 32;
  H = 24;

function Pic(AB, AG, AR: Byte): TBytes;
var i: Integer;
begin
  SetLength(Result, W * H * 4);
  for i := 0 to W * H - 1 do
  begin
    Result[i * 4] := AB; Result[i * 4 + 1] := AG; Result[i * 4 + 2] := AR; Result[i * 4 + 3] := 0;
  end;
end;

{ a picture with a horizontal gradient and a vertical one, so geometry effects show }
function Gradient: TBytes;
var x, y: Integer;
begin
  SetLength(Result, W * H * 4);
  for y := 0 to H - 1 do
    for x := 0 to W - 1 do
    begin
      Result[(y * W + x) * 4] := x * 255 div (W - 1);
      Result[(y * W + x) * 4 + 1] := y * 255 div (H - 1);
      Result[(y * W + x) * 4 + 2] := (x + y) * 255 div (W + H - 2);
      Result[(y * W + x) * 4 + 3] := 0;
    end;
end;

function Differs(const A, B: TBytes): Boolean;
var i: Integer;
begin
  for i := 0 to Length(A) - 1 do
    if A[i] <> B[i] then Exit(True);
  Result := False;
end;

procedure CatalogueIsConsistent;
var
  i, j, filters, transitions: Integer;
  a, b: TVideoFxInfo;
begin
  Check(VideoFxCount >= 40, 'at least 40 effects and transitions');
  filters := 0;
  transitions := 0;
  for i := 0 to VideoFxCount - 1 do
  begin
    a := VideoFxInfoAt(i);
    Check((a.Id <> '') and (a.Name <> '') and (a.Group <> ''), 'entry ' + IntToStr(i) + ' is complete');
    Check(VideoFxFind(a.Id, b) and (b.Name = a.Name), 'lookup by id: ' + a.Id);
    for j := i + 1 to VideoFxCount - 1 do
      CheckFalse(SameText(a.Id, VideoFxInfoAt(j).Id), 'unique id ' + a.Id);
    if a.Cls = vfTransition then Inc(transitions) else Inc(filters);
  end;
  Check(transitions >= 15, 'transitions present');
  Check(filters >= 25, 'effects present');
  CheckFalse(VideoFxFind('nosuchthing', b), 'unknown id');
end;

procedure EveryFilterRenders;
var
  i: Integer;
  info: TVideoFxInfo;
  src, dst: TBytes;
  changed: Integer;
begin
  src := Gradient;
  changed := 0;
  for i := 0 to VideoFxCount - 1 do
  begin
    info := VideoFxInfoAt(i);
    if info.Cls <> vfFilter then Continue;
    SetLength(dst, Length(src));
    FillChar(dst[0], Length(dst), 7);
    VideoFxRenderFilter(info.Id, '', 0.5, @src[0], @dst[0], W, H, 3);
    if Differs(src, dst) then Inc(changed);
    { the unused byte of every pixel stays zero }
    Check(dst[3] = 0, 'filter keeps the pad byte clear: ' + info.Id);
  end;
  Check(changed >= 22, 'filters change the picture (' + IntToStr(changed) + ')');
end;

procedure EveryTransitionRenders;
var
  i: Integer;
  info: TVideoFxInfo;
  a, b, dst: TBytes;
begin
  a := Pic(10, 20, 30);
  b := Pic(200, 210, 220);
  for i := 0 to VideoFxCount - 1 do
  begin
    info := VideoFxInfoAt(i);
    if info.Cls <> vfTransition then Continue;
    SetLength(dst, Length(a));
    FillChar(dst[0], Length(dst), 7);
    VideoFxRenderTransition(info.Id, '', 0.5, @a[0], @b[0], @dst[0], W, H, 1);
    { the glitch picks random bands, so only it may land entirely on one side }
    if info.Id = 'glitchtrans' then Continue;
    Check(Differs(a, dst), 'halfway differs from the outgoing picture: ' + info.Id);
    Check(Differs(b, dst), 'halfway differs from the incoming picture: ' + info.Id);
  end;
end;

procedure DissolveEnds;
var
  a, b, dst: TBytes;
begin
  a := Pic(10, 20, 30);
  b := Pic(200, 210, 220);
  SetLength(dst, Length(a));
  VideoFxRenderTransition('crossfade', '', 0, @a[0], @b[0], @dst[0], W, H, 0);
  Check(not Differs(a, dst), 'cross dissolve starts on the outgoing picture');
  VideoFxRenderTransition('crossfade', '', 1, @a[0], @b[0], @dst[0], W, H, 0);
  Check(not Differs(b, dst), 'cross dissolve ends on the incoming picture');
  VideoFxRenderTransition('dipblack', '', 0.5, @a[0], @b[0], @dst[0], W, H, 0);
  CheckEqualInt(0, dst[0], 'dip to black is black in the middle');
  VideoFxRenderTransition('slideleft', '', 1, @a[0], @b[0], @dst[0], W, H, 0);
  Check(not Differs(b, dst), 'push ends on the incoming picture');
end;

procedure FadeAndInvert;
var
  src, dst: TBytes;
begin
  src := Pic(100, 100, 100);
  SetLength(dst, Length(src));
  VideoFxRenderFilter('fadein', '', 0, @src[0], @dst[0], W, H, 0);
  CheckEqualInt(0, dst[0], 'fade in starts black');
  VideoFxRenderFilter('fadein', '', 1, @src[0], @dst[0], W, H, 0);
  CheckEqualInt(100, dst[0], 'fade in ends on the picture');
  VideoFxRenderFilter('fadeout', '', 1, @src[0], @dst[0], W, H, 0);
  CheckEqualInt(0, dst[1], 'fade out ends black');
  VideoFxRenderFilter('invert', '', 0, @src[0], @dst[0], W, H, 0);
  CheckEqualInt(155, dst[2], 'invert');
end;

function TwoClipTimeline: TTimeline;
var
  s: TMediaSource;
  t: TTimelineTrack;
begin
  Result := TTimeline.Create;
  s := Result.AddSource('x.mp4', 1000, 1, 4000, mkVideoFile);
  t := Result.AddTrack(tkVideo, 'V');
  Result.AddClip(t.Id, s.Id, 'one', 0, 0, 2);
  Result.AddClip(t.Id, s.Id, 'two', 2, 0, 2);
end;

procedure RegionLookupAndClips;
var
  tl: TTimeline;
  trk: TTimelineTrack;
  r: TVideoEffectRegion;
  oc, ic: TTimelineClip;
begin
  tl := TwoClipTimeline;
  try
    trk := tl.GetTrack(0);
    r := tl.AddVideoEffect(trk.Id, 'crossfade', 'Cross Dissolve', 1.5, 1.0, 2.0, '');
    Check(VideoFxRegionAt(tl, 1.0) = nil, 'before the region');
    Check(VideoFxRegionAt(tl, 1.6) = r, 'inside the region');
    Check(VideoFxRegionAt(tl, 2.5) = nil, 'end of the region is exclusive');
    CheckNear(0.5, VideoFxProgressAt(r, 2.0), 1e-9, 'progress at the pivot');
    VideoFxTransitionClips(tl, r, oc, ic);
    Check((oc <> nil) and (oc.Name = 'one'), 'outgoing clip');
    Check((ic <> nil) and (ic.Name = 'two'), 'incoming clip');
    trk.Muted := True;
    Check(VideoFxRegionAt(tl, 1.6) = nil, 'a muted channel has no effect');
  finally
    tl.Free;
  end;
end;

procedure UndoAndRoundTrip;
var
  doc: TProjectDocument;
  trk: TTimelineTrack;
  cmd: TAddVideoEffectCommand;
  rm: TRemoveVideoEffectCommand;
  text: string;
  copy: TTimeline;
  r: TVideoEffectRegion;
begin
  doc := TProjectDocument.CreateNew('vfx');
  try
    doc.Timeline.AddSource('x.mp4', 1000, 1, 4000, mkVideoFile);
    trk := doc.Timeline.AddTrack(tkVideo, 'V');
    cmd := TAddVideoEffectCommand.Create(doc, trk.Id, 'blur', 'Blur', 1, 2, 1, 'amt=0.7');
    try
      Check(cmd.Execute, 'add');
      CheckEqualInt(1, doc.Timeline.VideoEffectCount, 'one effect');
      text := TimelineToString(doc.Timeline);
      copy := TimelineFromString(text);
      try
        CheckEqualInt(1, copy.VideoEffectCount, 'effect survives save/load');
        r := copy.GetVideoEffect(0);
        CheckEqualStr('blur', r.Kind);
        CheckEqualStr('amt=0.7', r.Params);
        CheckNear(2, r.LengthSeconds, 1e-6, 'length');
      finally
        copy.Free;
      end;
      copy := doc.Timeline.Clone;
      try
        CheckEqualInt(1, copy.VideoEffectCount, 'effect survives Clone');
      finally
        copy.Free;
      end;
      cmd.Undo;
      CheckEqualInt(0, doc.Timeline.VideoEffectCount, 'undo removes it');
      Check(cmd.Redo, 'redo');
      CheckEqualInt(1, doc.Timeline.VideoEffectCount, 'redo restores it');
    finally
      cmd.Free;
    end;
    rm := TRemoveVideoEffectCommand.Create(doc, doc.Timeline.GetVideoEffect(0).Id);
    try
      Check(rm.Execute, 'remove');
      CheckEqualInt(0, doc.Timeline.VideoEffectCount, 'removed');
      rm.Undo;
      CheckEqualInt(1, doc.Timeline.VideoEffectCount, 'remove undone');
    finally
      rm.Free;
    end;
  finally
    doc.Free;
  end;
end;

procedure RegisterVideoEffectsTests;
begin
  RegisterTest('timeline.videofx', 'catalogue is complete and unique', CatalogueIsConsistent);
  RegisterTest('timeline.videofx', 'every effect renders', EveryFilterRenders);
  RegisterTest('timeline.videofx', 'every transition renders', EveryTransitionRenders);
  RegisterTest('timeline.videofx', 'dissolve and push end on the incoming picture', DissolveEnds);
  RegisterTest('timeline.videofx', 'fades and invert', FadeAndInvert);
  RegisterTest('timeline.videofx', 'region lookup and the clips of a cut', RegionLookupAndClips);
  RegisterTest('timeline.videofx', 'undo, redo, clone and save/load', UndoAndRoundTrip);
end;

end.
