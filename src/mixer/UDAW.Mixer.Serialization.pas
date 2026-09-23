unit UDAW.Mixer.Serialization;
{$I udaw.inc}

{ Phase 9 - Mixer: a small, versioned, human-readable text serializer for
  TMixerModel. It is embedded in the project file as the MIXER-BEGIN / MIXER-END
  section (project file v3), exactly the way the Phase 4 graph and Phase 7
  timeline sections are.

  It never deserializes raw class memory: every line is parsed field by field,
  the version is checked, unknown strip kinds / send modes are rejected, and
  strip ids from the file are validated for uniqueness before any route is
  resolved.

  Format (line-oriented, '#' comments and blank lines ignored):

    UDAWMIXER 1
    NEXTID 7
    STRIP 1 master "Master" in=0 out=0 trim=0 pol=0 pan=0 width=1 fader=0 mute=0 solo=0 arm=0 auto=off vca=0 color=0
    STRIP 2 audiotrack "Drums" in=11 out=3 trim=0 pol=1 pan=-0.3 width=1 fader=-2 mute=0 solo=0 arm=1 auto=read vca=6 color=0
    INSERT 2 gain db=-6
    INSERT 2 biquad type=peaking;freq=1200;q=1;gaindb=3 bypass=1
    SEND 2 5 gain=-12 mode=post en=1
    STRIP 3 bus "Drum Bus" ...
    STRIP 5 aux "Reverb" ...
    STRIP 6 vca "Rhythm VCA" ... }

interface

uses
  SysUtils, Classes, StrUtils,
  UDAW.Errors,
  UDAW.Mixer.Model, UDAW.Mixer.Automation, UDAW.Mixer.Modulation;

const
  MIXER_FILE_MAGIC   = 'UDAWMIXER';
  { v2 adds AUTO lines. v3 adds target/sub selectors for send and hosted-plugin
    parameter lanes; v1/v2 documents still load with selector zero. }
  MIXER_FILE_VERSION = 3;

function MixerToString(AModel: TMixerModel): string;
{ Parse text into a new model (caller owns the result). Raises EUDAWError
  (errConfig) on a malformed or unsupported document. }
function MixerFromString(const AText: string): TMixerModel;

procedure MixerToFile(AModel: TMixerModel; const AFileName: string);
function MixerFromFile(const AFileName: string): TMixerModel;

implementation

function FloatId(AValue: Double): string;
begin
  Result := FloatToStr(AValue, TFormatSettings.Invariant);
end;

function ParseFloat(const AText: string; ADefault: Double): Double;
begin
  if not TryStrToFloat(AText, Result, TFormatSettings.Invariant) then
    Result := ADefault;
end;

function QuoteName(const S: string): string;
begin
  Result := '"' + StringReplace(S, '"', '''', [rfReplaceAll]) + '"';
end;

function BoolId(AValue: Boolean): string;
begin
  if AValue then Result := '1' else Result := '0';
end;

{ ---- tiny key=value scanner over the trailing part of a STRIP / SEND line ---- }

function KV(const AText, AKey, ADefault: string): string;
var
  parts: TArray<string>;
  p, k: string;
  eq: Integer;
begin
  parts := AText.Split([' ', #9], TStringSplitOptions.ExcludeEmpty);
  for p in parts do
  begin
    eq := Pos('=', p);
    if eq <= 0 then Continue;
    k := Copy(p, 1, eq - 1);
    if SameText(k, AKey) then
      Exit(Copy(p, eq + 1, MaxInt));
  end;
  Result := ADefault;
end;

function KVInt(const AText, AKey: string; ADefault: Integer): Integer;
begin
  if not TryStrToInt(KV(AText, AKey, ''), Result) then
    Result := ADefault;
end;

function KVFloat(const AText, AKey: string; ADefault: Double): Double;
var
  s: string;
begin
  s := KV(AText, AKey, '');
  if s = '' then Exit(ADefault);
  Result := ParseFloat(s, ADefault);
end;

function KVBool(const AText, AKey: string; ADefault: Boolean): Boolean;
var
  s: string;
begin
  s := LowerCase(KV(AText, AKey, ''));
  if s = '' then Exit(ADefault);
  Result := (s = '1') or (s = 'true') or (s = 'yes') or (s = 'on');
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
    RaiseUDAW(errConfig, MIXER_SUBSYS, 'mixer parse: expected a quoted name');
  closeAt := 0;
  for i := 2 to Length(S) do
    if S[i] = '"' then begin closeAt := i; Break; end;
  if closeAt = 0 then
    RaiseUDAW(errConfig, MIXER_SUBSYS, 'mixer parse: unterminated quoted name');
  Result := Copy(S, 2, closeAt - 2);
  S := TrimLeft(Copy(S, closeAt + 1, MaxInt));
end;

{ ---- serialize ---- }

function MixerToString(AModel: TMixerModel): string;
var
  sb: TStringBuilder;
  i, j: Integer;
  s: TMixStrip;
  ins: TMixInsert;
  snd: TMixSend;
  lane: TAutomationLane;
  modLines: TStringList;
  pt: TAutomationPoint;
begin
  sb := TStringBuilder.Create;
  try
    sb.Append(MIXER_FILE_MAGIC).Append(' ').Append(MIXER_FILE_VERSION).AppendLine;
    sb.Append('NEXTID ').Append(AModel.NextId).AppendLine;
    sb.Append('METER holdms=').Append(FloatId(AModel.MeterHoldMs))
      .Append(' decaydb=').Append(FloatId(AModel.MeterHoldDecayDbPerSec)).AppendLine;
    for i := 0 to AModel.StripCount - 1 do
    begin
      s := AModel.GetStrip(i);
      sb.Append('STRIP ').Append(s.Id).Append(' ')
        .Append(MixStripKindId(s.Kind)).Append(' ')
        .Append(QuoteName(s.Name))
        .Append(' in=').Append(s.InputSourceId)
        .Append(' out=').Append(s.OutputTargetId)
        .Append(' trim=').Append(FloatId(s.TrimGainDb))
        .Append(' pol=').Append(BoolId(s.PolarityInvert))
        .Append(' pan=').Append(FloatId(s.Pan))
        .Append(' width=').Append(FloatId(s.StereoWidth))
        .Append(' fader=').Append(FloatId(s.FaderDb))
        .Append(' mute=').Append(BoolId(s.Muted))
        .Append(' solo=').Append(BoolId(s.Soloed))
        .Append(' arm=').Append(BoolId(s.RecordArmed))
        .Append(' auto=').Append(MixAutomationModeId(s.AutomationMode))
        .Append(' vca=').Append(s.VCAGroupId)
        .Append(' color=').Append(s.Color)
        .AppendLine;
      for j := 0 to s.InsertCount - 1 do
      begin
        ins := s.GetInsert(j);
        sb.Append('INSERT ').Append(s.Id).Append(' ')
          .Append(ins.Kind).Append(' ')
          .Append(IfThen(ins.Params = '', '-', ins.Params));
        if ins.Bypass then sb.Append(' bypass=1');
        if ins.SidechainStripId <> 0 then
          sb.Append(' sc=').Append(ins.SidechainStripId);
        sb.AppendLine;
      end;
      for j := 0 to s.SendCount - 1 do
      begin
        snd := s.GetSend(j);
        sb.Append('SEND ').Append(s.Id).Append(' ').Append(snd.TargetStripId)
          .Append(' gain=').Append(FloatId(snd.GainDb))
          .Append(' mode=').Append(MixSendModeId(snd.Mode))
          .Append(' en=').Append(BoolId(snd.Enabled))
          .AppendLine;
      end;
    end;
    for i := 0 to AModel.Automation.LaneCount - 1 do
    begin
      lane := AModel.Automation.GetLane(i);
      for j := 0 to lane.PointCount - 1 do
      begin
        pt := lane.GetPoint(j);
        sb.Append('AUTO ').Append(lane.StripId).Append(' ')
          .Append(AutomationParamId(lane.Param)).Append(' ')
          .Append(lane.TargetIndex).Append(' ')
          .Append(lane.SubIndex).Append(' ')
          .Append(FloatId(pt.TimeSeconds)).Append(' ')
          .Append(FloatId(pt.Value)).AppendLine;
      end;
    end;
    modLines := TStringList.Create;
    try
      AModel.Modulation.Serialize(modLines);
      for i := 0 to modLines.Count - 1 do sb.AppendLine(modLines[i]);
    finally
      modLines.Free;
    end;
    Result := sb.ToString;
  finally
    sb.Free;
  end;
end;

{ ---- deserialize ---- }

function MixerFromString(const AText: string): TMixerModel;
var
  lines: TStringList;
  li, ver, stripId, targetId, savedNextId, autoTarget, autoSub: Integer;
  raw, line, tok, kindId, nm, rest, params, modeId, autoId, paramId: string;
  kind: TMixStripKind;
  mode: TMixSendMode;
  am: TMixAutomationMode;
  autoParam: TAutomationParam;
  autoTime, autoValue: Double;
  m: TMixerModel;
  cur: TMixStrip;
  haveHeader: Boolean;
begin
  lines := TStringList.Create;
  m := TMixerModel.Create;
  savedNextId := -1;
  try
    lines.Text := AText;
    haveHeader := False;

    for li := 0 to lines.Count - 1 do
    begin
      raw := Trim(lines[li]);
      if (raw = '') or (raw[1] = '#') then Continue;
      if haveHeader and ((Pos('MODSRC ', raw) = 1) or (Pos('MODROUTE ', raw) = 1)) then
      begin
        m.Modulation.TryParseLine(raw);
        Continue;
      end;

      if not haveHeader then
      begin
        line := raw;
        tok := TakeToken(line);
        if not SameText(tok, MIXER_FILE_MAGIC) then
          RaiseUDAW(errConfig, MIXER_SUBSYS,
            'not a UDAW mixer document (missing ' + MIXER_FILE_MAGIC + ' header)');
        if not TryStrToInt(Trim(line), ver) then
          RaiseUDAW(errConfig, MIXER_SUBSYS, 'mixer header: missing version number');
        if (ver <= 0) or (ver > MIXER_FILE_VERSION) then
          RaiseUDAWFmt(errConfig, MIXER_SUBSYS,
            'unsupported mixer document version %d (reader supports up to %d)',
            [ver, MIXER_FILE_VERSION]);
        haveHeader := True;
        Continue;
      end;

      line := raw;
      tok := TakeToken(line);

      if SameText(tok, 'NEXTID') then
      begin
        if not TryStrToInt(Trim(line), savedNextId) then
          RaiseUDAW(errConfig, MIXER_SUBSYS, 'NEXTID: not an integer');
      end
      else if SameText(tok, 'METER') then
      begin
        m.MeterHoldMs := KVFloat(line, 'holdms', MIX_METER_HOLD_MS_DEFAULT);
        m.MeterHoldDecayDbPerSec := KVFloat(line, 'decaydb', MIX_METER_HOLD_DECAY_DEFAULT);
      end
      else if SameText(tok, 'STRIP') then
      begin
        tok := TakeToken(line);
        if not TryStrToInt(tok, stripId) then
          RaiseUDAW(errConfig, MIXER_SUBSYS, 'STRIP: bad id');
        kindId := TakeToken(line);
        if not MixStripKindFromId(kindId, kind) then
          RaiseUDAWFmt(errConfig, MIXER_SUBSYS, 'STRIP: unknown kind "%s"', [kindId]);
        nm := TakeQuoted(line);
        rest := line;
        cur := m.AddStripWithId(stripId, kind, nm);
        cur.InputSourceId := KVInt(rest, 'in', 0);
        cur.OutputTargetId := KVInt(rest, 'out', 0);
        cur.TrimGainDb := KVFloat(rest, 'trim', 0);
        cur.PolarityInvert := KVBool(rest, 'pol', False);
        cur.Pan := KVFloat(rest, 'pan', 0);
        cur.StereoWidth := KVFloat(rest, 'width', 1);
        cur.FaderDb := KVFloat(rest, 'fader', 0);
        cur.Muted := KVBool(rest, 'mute', False);
        cur.Soloed := KVBool(rest, 'solo', False);
        cur.RecordArmed := KVBool(rest, 'arm', False);
        autoId := KV(rest, 'auto', 'off');
        if MixAutomationModeFromId(autoId, am) then
          cur.AutomationMode := am;
        cur.VCAGroupId := KVInt(rest, 'vca', 0);
        cur.Color := KVInt(rest, 'color', 0);
      end
      else if SameText(tok, 'INSERT') then
      begin
        tok := TakeToken(line);
        if not TryStrToInt(tok, stripId) then
          RaiseUDAW(errConfig, MIXER_SUBSYS, 'INSERT: bad strip id');
        cur := m.StripById(stripId);
        if cur = nil then
          RaiseUDAWFmt(errConfig, MIXER_SUBSYS, 'INSERT: strip %d not defined yet', [stripId]);
        kindId := TakeToken(line);
        rest := line;
        params := TakeToken(rest);
        if params = '-' then params := '';
        cur.AddInsert(TMixInsert.Make(kindId, params, KVBool(rest, 'bypass', False),
          KVInt(rest, 'sc', 0)));
      end
      else if SameText(tok, 'SEND') then
      begin
        tok := TakeToken(line);
        if not TryStrToInt(tok, stripId) then
          RaiseUDAW(errConfig, MIXER_SUBSYS, 'SEND: bad strip id');
        cur := m.StripById(stripId);
        if cur = nil then
          RaiseUDAWFmt(errConfig, MIXER_SUBSYS, 'SEND: strip %d not defined yet', [stripId]);
        tok := TakeToken(line);
        if not TryStrToInt(tok, targetId) then
          RaiseUDAW(errConfig, MIXER_SUBSYS, 'SEND: bad target id');
        rest := line;
        modeId := KV(rest, 'mode', 'post');
        if not MixSendModeFromId(modeId, mode) then
          RaiseUDAWFmt(errConfig, MIXER_SUBSYS, 'SEND: unknown mode "%s"', [modeId]);
        cur.AddSend(targetId, KVFloat(rest, 'gain', 0), mode, KVBool(rest, 'en', True));
      end
      else if SameText(tok, 'AUTO') then
      begin
        tok := TakeToken(line);
        if not TryStrToInt(tok, stripId) then
          RaiseUDAW(errConfig, MIXER_SUBSYS, 'AUTO: bad strip id');
        paramId := TakeToken(line);
        if not AutomationParamFromId(paramId, autoParam) then
          RaiseUDAWFmt(errConfig, MIXER_SUBSYS, 'AUTO: unknown parameter "%s"', [paramId]);
        autoTarget := 0;
        autoSub := 0;
        if ver >= 3 then
        begin
          tok := TakeToken(line);
          if not TryStrToInt(tok, autoTarget) then
            RaiseUDAW(errConfig, MIXER_SUBSYS, 'AUTO: bad target selector');
          tok := TakeToken(line);
          if not TryStrToInt(tok, autoSub) then
            RaiseUDAW(errConfig, MIXER_SUBSYS, 'AUTO: bad sub-parameter selector');
        end;
        tok := TakeToken(line);
        autoTime := ParseFloat(tok, 0);
        autoValue := ParseFloat(Trim(line), 0);
        cur := m.StripById(stripId);
        if cur = nil then
          RaiseUDAWFmt(errConfig, MIXER_SUBSYS, 'AUTO: strip %d not defined', [stripId]);
        if (autoParam = apSendGain) and
           ((autoTarget <= 0) or (cur.SendToStrip(autoTarget) = nil)) then
          RaiseUDAWFmt(errConfig, MIXER_SUBSYS,
            'AUTO: strip %d has no send to target %d', [stripId, autoTarget]);
        if (autoParam = apInsertParam) and
           ((autoTarget < 0) or (autoTarget >= cur.InsertCount) or (autoSub < 0)) then
          RaiseUDAWFmt(errConfig, MIXER_SUBSYS,
            'AUTO: bad insert parameter selector %d:%d', [autoTarget, autoSub]);
        m.Automation.LaneFor(stripId, autoParam, True, autoTarget, autoSub)
          .AddPoint(autoTime, autoValue);
      end
      else
        RaiseUDAWFmt(errConfig, MIXER_SUBSYS, 'mixer parse: unexpected line "%s"', [raw]);
    end;

    if not haveHeader then
      RaiseUDAW(errConfig, MIXER_SUBSYS, 'empty or headerless mixer document');

    if (savedNextId > 0) and (savedNextId > m.NextId) then
      m.NextId := savedNextId;

    Result := m;
    m := nil;
  finally
    lines.Free;
    m.Free;   // only non-nil if we raised before handing ownership over
  end;
end;

procedure MixerToFile(AModel: TMixerModel; const AFileName: string);
var
  sl: TStringList;
begin
  sl := TStringList.Create;
  try
    sl.Text := MixerToString(AModel);
    sl.SaveToFile(AFileName);
  finally
    sl.Free;
  end;
end;

function MixerFromFile(const AFileName: string): TMixerModel;
var
  sl: TStringList;
begin
  if not FileExists(AFileName) then
    RaiseUDAWFmt(errFileNotFound, MIXER_SUBSYS, 'mixer file not found: %s', [AFileName]);
  sl := TStringList.Create;
  try
    sl.LoadFromFile(AFileName);
    Result := MixerFromString(sl.Text);
  finally
    sl.Free;
  end;
end;

end.
