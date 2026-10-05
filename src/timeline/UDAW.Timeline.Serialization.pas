unit UDAW.Timeline.Serialization;
{$I udaw.inc}

{ Phase 7 - Timeline: a small, versioned, human-readable text serializer for
  TTimeline, in the same spirit as the Phase 4 graph serializer and the Phase 5
  project serializer (plan section 27: never persist raw class memory; a file
  must fail loudly, not silently).

  It is used two ways:
    * standalone (TimelineToString / ...FromString / file variants), and
    * embedded verbatim inside the project file between TIMELINE-BEGIN /
      TIMELINE-END (see UDAW.Project.Serialization).

  Format (line-oriented, '#' comments and blank lines ignored):

    UDAWTIMELINE 1
    PLAYHEAD 12.500000
    LOOP 1 4.000000 8.000000
    SOURCE 1 audiofile 44100 2 220500 "C:\loops\drums.wav"
    TRACK 3 audio "Drums" color=-1;height=84;mute=0;solo=0;arm=0;gain=0;pan=0 "+ Compressor"
    CLIP 7 3 1 "Loop A" start=0;off=0;len=2.5;gain=-3;fin=0.01;fout=0.02;finsh=eqp;foutsh=eqp;rev=0;mute=0;lock=0;loop=0;color=-1 "Compressor"
    MARKER 2 8.000000 "Verse"
    REGION 5 16.000000 8.000000 -1 "Chorus"

  The parameter blob on TRACK / CLIP lines is a single whitespace-free
  key=value;... token so track and clip names may contain spaces. }

interface

uses
  SysUtils, Classes,
  UDAW.Errors,
  UDAW.Timeline.Model;

const
  TIMELINE_FILE_MAGIC   = 'UDAWTIMELINE';
  { v2 adds the MVOL line (Timeline-tab master playback volume). A v1 file
    simply lacks the line and MasterVolumeDb reads back as its 0 dB default.
    v3 adds the HWIDTH line (left track-header column width); an older file
    simply lacks it and HeaderWidth reads back as its default.
    v4 adds the TRACK line's "title=" param (per-channel title-band text);
    an older file simply lacks it and Title reads back empty. }
  TIMELINE_FILE_VERSION = 4;
  TIMELINE_FILE_EXT     = '.udawtl';

function TimelineToString(ATimeline: TTimeline): string;
{ Caller owns the returned timeline. Raises EUDAWError (errConfig) on a
  malformed or unsupported document. }
function TimelineFromString(const AText: string): TTimeline;
{ Parse into an existing (cleared) timeline - used by the project reader. }
procedure TimelineFromStringInto(const AText: string; ATimeline: TTimeline);

procedure SaveTimelineToFile(ATimeline: TTimeline; const AFileName: string);
function LoadTimelineFromFile(const AFileName: string): TTimeline;

implementation

{$IFDEF MSWINDOWS}
uses
  Windows;   // expands the inline RenameFile (H2443)
{$ENDIF}

const
  SUBSYS = 'Timeline.Serial';

function Inv: TFormatSettings;
begin
  Result := TFormatSettings.Invariant;
end;

function F(AValue: Double): string;
begin
  Result := FloatToStr(AValue, Inv);
end;

{ Effect kind/settings text may hold spaces, file paths, the region
  separators and the clip line's own ';'/'=' delimiters, so it is %-escaped
  to stay one plain token. }
function EscapeFxText(const S: string): string;
begin
  Result := StringReplace(S, '%', '%25', [rfReplaceAll]);
  Result := StringReplace(Result, ' ', '%20', [rfReplaceAll]);
  Result := StringReplace(Result, '|', '%7C', [rfReplaceAll]);
  Result := StringReplace(Result, '~', '%7E', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '%22', [rfReplaceAll]);
  Result := StringReplace(Result, #9, '%09', [rfReplaceAll]);
  Result := StringReplace(Result, ';', '%3B', [rfReplaceAll]);
  Result := StringReplace(Result, '=', '%3D', [rfReplaceAll]);
end;

function UnescapeFxText(const S: string): string;
begin
  Result := StringReplace(S, '%3D', '=', [rfReplaceAll]);
  Result := StringReplace(Result, '%3B', ';', [rfReplaceAll]);
  Result := StringReplace(Result, '%09', #9, [rfReplaceAll]);
  Result := StringReplace(Result, '%22', '"', [rfReplaceAll]);
  Result := StringReplace(Result, '%7E', '~', [rfReplaceAll]);
  Result := StringReplace(Result, '%7C', '|', [rfReplaceAll]);
  Result := StringReplace(Result, '%20', ' ', [rfReplaceAll]);
  Result := StringReplace(Result, '%25', '%', [rfReplaceAll]);
end;

{ All effect regions of a clip in one space-free token: name~off~len~color
  entries joined by '|' ('-' when none). Spaces in names become '_'. A region
  that knows the effect it was rendered with adds ~kind~params (escaped);
  older readers ignore the extra fields. }
function EncodeEffectRegions(AClip: TTimelineClip): string;
var
  i: Integer;
  r: TClipEffectRegion;
begin
  if Length(AClip.EffectRegions) = 0 then Exit('-');
  Result := '';
  for i := 0 to High(AClip.EffectRegions) do
  begin
    r := AClip.EffectRegions[i];
    if i > 0 then Result := Result + '|';
    Result := Result + StringReplace(StringReplace(StringReplace(r.Name, ' ', '_', [rfReplaceAll]),
      '|', '', [rfReplaceAll]), '~', '', [rfReplaceAll]) + '~' + F(r.OffsetSeconds) + '~' +
      F(r.LengthSeconds) + '~' + IntToStr(r.Color);
    if r.Kind <> '' then
      Result := Result + '~' + EscapeFxText(r.Kind) + '~' + EscapeFxText(r.Params);
  end;
end;

{ -1 = clip has no pre-effect original }
function OrigSrcToken(AClip: TTimelineClip): Integer;
begin
  if AClip.HasOrig then Result := AClip.OrigSourceId else Result := -1;
end;

procedure DecodeEffectRegions(AClip: TTimelineClip; const AText: string);
var
  entries, parts: TArray<string>;
  e: string;
  off, len: Double;
  col: Integer;
  kind, params: string;
begin
  if (AText = '') or (AText = '-') then Exit;
  entries := AText.Split(['|']);
  for e in entries do
  begin
    parts := e.Split(['~']);
    if Length(parts) < 4 then Continue;
    if not TryStrToFloat(parts[1], off, Inv) then Continue;
    if not TryStrToFloat(parts[2], len, Inv) then Continue;
    if not TryStrToInt(parts[3], col) then Continue;
    kind := '';
    params := '';
    if Length(parts) >= 6 then
    begin
      kind := UnescapeFxText(parts[4]);
      params := UnescapeFxText(parts[5]);
    end;
    AClip.AddEffectRegion(StringReplace(parts[0], '_', ' ', [rfReplaceAll]), off, len, col,
      kind, params);
  end;
end;

function QuoteStr(const S: string): string;
begin
  Result := '"' + StringReplace(S, '"', '''', [rfReplaceAll]) + '"';
end;

function TakeToken(var S: string): string;
var
  sp: Integer;
begin
  S := TrimLeft(S);
  sp := Pos(' ', S);
  if sp = 0 then sp := Pos(#9, S);
  if sp = 0 then
  begin
    Result := S;
    S := '';
  end
  else
  begin
    Result := Copy(S, 1, sp - 1);
    S := TrimLeft(Copy(S, sp + 1, MaxInt));
  end;
end;

function TakeQuoted(var S: string): string;
var
  i, closeAt: Integer;
begin
  S := TrimLeft(S);
  if (S = '') or (S[1] <> '"') then
    RaiseUDAW(errConfig, SUBSYS, 'timeline parse: expected a quoted value');
  closeAt := 0;
  for i := 2 to Length(S) do
    if S[i] = '"' then begin closeAt := i; Break; end;
  if closeAt = 0 then
    RaiseUDAW(errConfig, SUBSYS, 'timeline parse: unterminated quoted value');
  Result := Copy(S, 2, closeAt - 2);
  S := TrimLeft(Copy(S, closeAt + 1, MaxInt));
end;

function IntTok(var S: string; const AWhat: string): Integer;
begin
  if not TryStrToInt(TakeToken(S), Result) then
    RaiseUDAWFmt(errConfig, SUBSYS, 'timeline parse: %s must be an integer', [AWhat]);
end;

function Int64Tok(var S: string; const AWhat: string): Int64;
begin
  if not TryStrToInt64(TakeToken(S), Result) then
    RaiseUDAWFmt(errConfig, SUBSYS, 'timeline parse: %s must be an integer', [AWhat]);
end;

function FloatTok(var S: string; const AWhat: string): Double;
begin
  if not TryStrToFloat(TakeToken(S), Result, Inv) then
    RaiseUDAWFmt(errConfig, SUBSYS, 'timeline parse: %s must be a number', [AWhat]);
end;

{ ---- key=value;... blob helpers ---- }

procedure SplitParams(const ABlob: string; AKeys, AVals: TStringList);
var
  parts: TStringList;
  i, eq: Integer;
begin
  AKeys.Clear;
  AVals.Clear;
  if (ABlob = '') or (ABlob = '-') then Exit;
  parts := TStringList.Create;
  try
    parts.Delimiter := ';';
    parts.StrictDelimiter := True;
    parts.DelimitedText := ABlob;
    for i := 0 to parts.Count - 1 do
    begin
      eq := Pos('=', parts[i]);
      if eq > 0 then
      begin
        AKeys.Add(Copy(parts[i], 1, eq - 1));
        AVals.Add(Copy(parts[i], eq + 1, MaxInt));
      end;
    end;
  finally
    parts.Free;
  end;
end;

function PStr(AKeys, AVals: TStringList; const AKey, ADef: string): string;
var
  idx: Integer;
begin
  idx := AKeys.IndexOf(AKey);
  if idx < 0 then Result := ADef else Result := AVals[idx];
end;

function PInt(AKeys, AVals: TStringList; const AKey: string; ADef: Integer): Integer;
begin
  if not TryStrToInt(PStr(AKeys, AVals, AKey, ''), Result) then Result := ADef;
end;

function PFloat(AKeys, AVals: TStringList; const AKey: string; ADef: Double): Double;
begin
  if not TryStrToFloat(PStr(AKeys, AVals, AKey, ''), Result, Inv) then Result := ADef;
end;

function PBool(AKeys, AVals: TStringList; const AKey: string; ADef: Boolean): Boolean;
var
  s: string;
begin
  s := PStr(AKeys, AVals, AKey, '');
  if s = '' then Exit(ADef);
  Result := (s = '1') or SameText(s, 'true') or SameText(s, 'yes');
end;

function IfThen1(ABool: Boolean): string;
begin
  if ABool then Result := '1' else Result := '0';
end;

function MediaKindId(AKind: TMediaKind): string;
begin
  case AKind of
    mkGenerated: Result := 'generated';
    mkVideoFile: Result := 'videofile';
  else
    Result := 'audiofile';
  end;
end;

function MediaKindFromId(const AId: string): TMediaKind;
begin
  if SameText(AId, 'generated') then Result := mkGenerated
  else if SameText(AId, 'videofile') then Result := mkVideoFile
  else Result := mkAudioFile;
end;

{ ================= write ================= }

function TimelineToString(ATimeline: TTimeline): string;
var
  sb: TStringBuilder;
  i, j: Integer;
  src: TMediaSource;
  trk: TTimelineTrack;
  c: TTimelineClip;
  m: TTimelineMarker;
  rg: TTimelineRegion;
begin
  sb := TStringBuilder.Create;
  try
    sb.Append(TIMELINE_FILE_MAGIC).Append(' ').Append(TIMELINE_FILE_VERSION).AppendLine;
    sb.Append('PLAYHEAD ').Append(F(ATimeline.PlayheadSeconds)).AppendLine;
    sb.Append('LOOP ').Append(IfThen1(ATimeline.LoopEnabled)).Append(' ')
      .Append(F(ATimeline.LoopStartSeconds)).Append(' ')
      .Append(F(ATimeline.LoopLengthSeconds)).AppendLine;
    sb.Append('MVOL ').Append(F(ATimeline.MasterVolumeDb)).AppendLine;
    sb.Append('HWIDTH ').Append(ATimeline.HeaderWidth).AppendLine;

    for i := 0 to ATimeline.SourceCount - 1 do
    begin
      src := ATimeline.GetSource(i);
      sb.Append('SOURCE ').Append(src.Id).Append(' ')
        .Append(MediaKindId(src.Kind)).Append(' ')
        .Append(src.SampleRate).Append(' ')
        .Append(src.Channels).Append(' ')
        .Append(src.FrameCount).Append(' ')
        .Append(QuoteStr(src.Path)).AppendLine;
    end;

    for i := 0 to ATimeline.TrackCount - 1 do
    begin
      trk := ATimeline.GetTrack(i);
      sb.Append('TRACK ').Append(trk.Id).Append(' ')
        .Append(TrackKindId(trk.Kind)).Append(' ')
        .Append(QuoteStr(trk.Name)).Append(' ')
        .Append(Format('color=%d;height=%d;mute=%d;solo=%d;arm=%d;gain=%s;pan=%s',
          [trk.Color, trk.Height, Ord(trk.Muted), Ord(trk.Soloed), Ord(trk.Armed),
           F(trk.GainDb), F(trk.Pan)])).Append(' ')
        .Append(QuoteStr(trk.Title)).AppendLine;
      for j := 0 to trk.ClipCount - 1 do
      begin
        c := trk.GetClip(j);
        sb.Append('CLIP ').Append(c.Id).Append(' ').Append(trk.Id).Append(' ')
          .Append(c.SourceId).Append(' ').Append(QuoteStr(c.Name)).Append(' ')
          .Append(Format('start=%s;off=%s;len=%s;gain=%s;fin=%s;fout=%s;finsh=%s;foutsh=%s;rev=%d;mute=%d;lock=%d;loop=%d;color=%d;bpm=%s;fxoff=%s;fxlen=%s;fxr=%s;osrc=%d;odelta=%s',
            [F(c.StartSeconds), F(c.SourceOffsetSeconds), F(c.LengthSeconds), F(c.GainDb),
             F(c.FadeInSeconds), F(c.FadeOutSeconds),
             FadeShapeId(c.FadeInShape), FadeShapeId(c.FadeOutShape),
             Ord(c.Reversed), Ord(c.Muted), Ord(c.Locked), Ord(c.Loop), c.Color,
             F(c.SourceBPM), F(c.EffectOffsetSeconds), F(c.EffectLengthSeconds), EncodeEffectRegions(c),
             OrigSrcToken(c), F(c.OrigDelta)])).Append(' ')
          .Append(QuoteStr(c.EffectName)).AppendLine;
      end;
    end;

    for i := 0 to ATimeline.MarkerCount - 1 do
    begin
      m := ATimeline.GetMarker(i);
      sb.Append('MARKER ').Append(m.Id).Append(' ').Append(F(m.Seconds)).Append(' ')
        .Append(QuoteStr(m.Name)).AppendLine;
    end;

    for i := 0 to ATimeline.RegionCount - 1 do
    begin
      rg := ATimeline.GetRegion(i);
      sb.Append('REGION ').Append(rg.Id).Append(' ').Append(F(rg.StartSeconds)).Append(' ')
        .Append(F(rg.LengthSeconds)).Append(' ').Append(rg.Color).Append(' ')
        .Append(QuoteStr(rg.Name)).AppendLine;
    end;

    Result := sb.ToString;
  finally
    sb.Free;
  end;
end;

{ ================= read ================= }

procedure TimelineFromStringInto(const AText: string; ATimeline: TTimeline);
var
  lines: TStringList;
  keys, vals: TStringList;
  li, ver: Integer;
  raw, line, tok, blob: string;
  haveHeader: Boolean;
  sId, sRate, sChans: Integer;
  sFrames: Int64;
  sPath, sKind: string;
  tId: Integer;
  tKindId, tName: string;
  tKind: TTrackKind;
  trk: TTimelineTrack;
  cId, cTrackId, cSourceId: Integer;
  cName: string;
  clip: TTimelineClip;
  fsh: TFadeShape;
  mId, rId: Integer;
  mSecs, rStart, rLen: Double;
  rColor: Integer;
  nm: string;
begin
  ATimeline.Clear;
  lines := TStringList.Create;
  keys := TStringList.Create;
  vals := TStringList.Create;
  try
    lines.Text := AText;
    haveHeader := False;

    for li := 0 to lines.Count - 1 do
    begin
      raw := Trim(lines[li]);
      if (raw = '') or (raw[1] = '#') then Continue;
      line := raw;
      tok := TakeToken(line);

      if not haveHeader then
      begin
        if not SameText(tok, TIMELINE_FILE_MAGIC) then
          RaiseUDAW(errConfig, SUBSYS,
            'not a UDAW timeline document (missing ' + TIMELINE_FILE_MAGIC + ' header)');
        if not TryStrToInt(Trim(line), ver) then
          RaiseUDAW(errConfig, SUBSYS, 'timeline header: missing version number');
        if (ver <= 0) or (ver > TIMELINE_FILE_VERSION) then
          RaiseUDAWFmt(errConfig, SUBSYS,
            'unsupported timeline document version %d (reader supports up to %d)',
            [ver, TIMELINE_FILE_VERSION]);
        haveHeader := True;
        Continue;
      end;

      if SameText(tok, 'PLAYHEAD') then
        ATimeline.PlayheadSeconds := FloatTok(line, 'PLAYHEAD')
      else if SameText(tok, 'LOOP') then
      begin
        ATimeline.LoopEnabled := IntTok(line, 'LOOP flag') <> 0;
        ATimeline.LoopStartSeconds := FloatTok(line, 'LOOP start');
        ATimeline.LoopLengthSeconds := FloatTok(line, 'LOOP length');
      end
      else if SameText(tok, 'MVOL') then
        ATimeline.MasterVolumeDb := FloatTok(line, 'MVOL')
      else if SameText(tok, 'HWIDTH') then
        ATimeline.HeaderWidth := IntTok(line, 'HWIDTH')
      else if SameText(tok, 'SOURCE') then
      begin
        sId := IntTok(line, 'SOURCE id');
        sKind := TakeToken(line);
        sRate := IntTok(line, 'SOURCE rate');
        sChans := IntTok(line, 'SOURCE channels');
        sFrames := Int64Tok(line, 'SOURCE frames');
        sPath := TakeQuoted(line);
        ATimeline.AddSourceWithId(sId, sPath, sRate, sChans, sFrames, MediaKindFromId(sKind));
      end
      else if SameText(tok, 'TRACK') then
      begin
        tId := IntTok(line, 'TRACK id');
        tKindId := TakeToken(line);
        tName := TakeQuoted(line);
        blob := TakeToken(line);
        if not TrackKindFromId(tKindId, tKind) then
          RaiseUDAWFmt(errConfig, SUBSYS, 'unknown track kind "%s"', [tKindId]);
        trk := ATimeline.AddTrackWithId(tId, tKind, tName);
        SplitParams(blob, keys, vals);
        trk.Color := PInt(keys, vals, 'color', -1);
        trk.Height := PInt(keys, vals, 'height', DefaultTrackHeight(tKind));
        trk.Muted := PBool(keys, vals, 'mute', False);
        trk.Soloed := PBool(keys, vals, 'solo', False);
        trk.Armed := PBool(keys, vals, 'arm', False);
        trk.GainDb := PFloat(keys, vals, 'gain', 0);
        trk.Pan := PFloat(keys, vals, 'pan', 0);
        { title= a per-channel title-band string (v4+); a v3 file simply
          lacks this trailing quoted field, so Title stays empty. }
        if (Trim(line) <> '') and (Trim(line)[1] = '"') then
          trk.Title := TakeQuoted(line);
      end
      else if SameText(tok, 'CLIP') then
      begin
        cId := IntTok(line, 'CLIP id');
        cTrackId := IntTok(line, 'CLIP track');
        cSourceId := IntTok(line, 'CLIP source');
        cName := TakeQuoted(line);
        blob := TakeToken(line);
        SplitParams(blob, keys, vals);
        clip := ATimeline.AddClipWithId(cId, cTrackId, cSourceId, cName,
          PFloat(keys, vals, 'start', 0),
          PFloat(keys, vals, 'off', 0),
          PFloat(keys, vals, 'len', 1));
        clip.GainDb := PFloat(keys, vals, 'gain', 0);
        clip.FadeInSeconds := PFloat(keys, vals, 'fin', 0);
        clip.FadeOutSeconds := PFloat(keys, vals, 'fout', 0);
        if FadeShapeFromId(PStr(keys, vals, 'finsh', 'eqp'), fsh) then clip.FadeInShape := fsh;
        if FadeShapeFromId(PStr(keys, vals, 'foutsh', 'eqp'), fsh) then clip.FadeOutShape := fsh;
        clip.Reversed := PBool(keys, vals, 'rev', False);
        clip.Muted := PBool(keys, vals, 'mute', False);
        clip.Locked := PBool(keys, vals, 'lock', False);
        clip.Loop := PBool(keys, vals, 'loop', False);
        clip.Color := PInt(keys, vals, 'color', -1);
        clip.SourceBPM := PFloat(keys, vals, 'bpm', 0);
        clip.EffectOffsetSeconds := PFloat(keys, vals, 'fxoff', 0);
        clip.EffectLengthSeconds := PFloat(keys, vals, 'fxlen', 0);
        DecodeEffectRegions(clip, PStr(keys, vals, 'fxr', '-'));
        clip.OrigSourceId := PInt(keys, vals, 'osrc', -1);
        clip.HasOrig := clip.OrigSourceId >= 0;
        clip.OrigDelta := PFloat(keys, vals, 'odelta', 0);
        { EffectName is a trailing quoted field added after the original CLIP
          format - guard so a project file saved before this addition (no
          trailing token at all) still loads instead of raising on TakeQuoted }
        if TrimLeft(line) <> '' then
          clip.EffectName := TakeQuoted(line);
      end
      else if SameText(tok, 'MARKER') then
      begin
        mId := IntTok(line, 'MARKER id');
        mSecs := FloatTok(line, 'MARKER seconds');
        nm := TakeQuoted(line);
        ATimeline.AddMarkerWithId(mId, nm, mSecs);
      end
      else if SameText(tok, 'REGION') then
      begin
        rId := IntTok(line, 'REGION id');
        rStart := FloatTok(line, 'REGION start');
        rLen := FloatTok(line, 'REGION length');
        rColor := IntTok(line, 'REGION color');
        nm := TakeQuoted(line);
        ATimeline.AddRegionWithId(rId, nm, rStart, rLen).Color := rColor;
      end
      else
        RaiseUDAWFmt(errConfig, SUBSYS, 'timeline parse: unexpected line "%s"', [raw]);
    end;

    if not haveHeader then
      RaiseUDAW(errConfig, SUBSYS, 'empty or headerless timeline document');
  finally
    vals.Free;
    keys.Free;
    lines.Free;
  end;
end;

function TimelineFromString(const AText: string): TTimeline;
begin
  Result := TTimeline.Create;
  try
    TimelineFromStringInto(AText, Result);
  except
    Result.Free;
    raise;
  end;
end;

procedure SaveTimelineToFile(ATimeline: TTimeline; const AFileName: string);
var
  sl: TStringList;
  dir, tmp: string;
begin
  dir := ExtractFilePath(AFileName);
  if dir <> '' then ForceDirectories(dir);
  tmp := AFileName + '.tmp';
  sl := TStringList.Create;
  try
    sl.Text := TimelineToString(ATimeline);
    if FileExists(tmp) then SysUtils.DeleteFile(tmp);
    sl.SaveToFile(tmp);
  finally
    sl.Free;
  end;
  if FileExists(AFileName) then
    if not SysUtils.DeleteFile(AFileName) then
      RaiseUDAWFmt(errIO, SUBSYS, 'could not remove previous "%s"', [AFileName]);
  if not RenameFile(tmp, AFileName) then
    RaiseUDAWFmt(errIO, SUBSYS, 'could not move "%s" to "%s"', [tmp, AFileName]);
end;

function LoadTimelineFromFile(const AFileName: string): TTimeline;
var
  sl: TStringList;
begin
  if not FileExists(AFileName) then
    RaiseUDAWFmt(errFileNotFound, SUBSYS, 'timeline file not found: %s', [AFileName]);
  sl := TStringList.Create;
  try
    sl.LoadFromFile(AFileName);
    Result := TimelineFromString(sl.Text);
  finally
    sl.Free;
  end;
end;

end.
