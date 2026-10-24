unit UDAW.Tracker.Serialization;
{$I udaw.inc}

{ Phase 11 - Tracker Engine: a versioned, line-oriented, human-readable text
  serializer for TTrackerModule. Embedded in the project file as the
  TRACKER-BEGIN / TRACKER-END section (project file v4), the same way the
  graph / timeline / mixer sections are.

  It never deserializes raw class memory: the version is checked, every line is
  parsed field by field, note / effect tokens go through the Types unit's
  validated parsers, and sample PCM is carried as hex (Float32 LE) so the
  module is fully self-contained - persistence is complete, not a reference.

  Format:

    UDAWTRACKER 1
    NAME "Demo"
    CHANNELS 4
    SPEED 6
    BPM 125
    GLOBALVOL 1
    RESTART 0
    ORDER 0 0 1
    INSTR 1 "Sine" root=58 rate=48000 vol=1 pan=0 loop=forward lstart=0 lend=480 fade=0
    VOLENV 1 sustain=-1 lstart=-1 lend=-1 pts=0:1;64:0.5;128:0
    SAMPLE 1 <hex Float32 LE>
    PATTERN 0 rows=64
    R00 C-4 01 40 A06 | ... | ... | ...
    R01 ... | ... | ... | ... }

interface

uses
  SysUtils, Classes,
  UDAW.Errors,
  UDAW.Audio.Types,
  UDAW.Tracker.Types, UDAW.Tracker.Instrument, UDAW.Tracker.Pattern;

const
  TRACKER_FILE_MAGIC   = 'UDAWTRACKER';
  TRACKER_FILE_VERSION = 1;

function TrackerModuleToString(AModule: TTrackerModule): string;
{ Caller owns the result. Raises EUDAWError (errConfig) on a malformed doc. }
function TrackerModuleFromString(const AText: string): TTrackerModule;

procedure TrackerModuleToFile(AModule: TTrackerModule; const AFileName: string);
function TrackerModuleFromFile(const AFileName: string): TTrackerModule;

implementation

function FloatId(AValue: Double): string;
begin
  Result := FloatToStr(AValue, TFormatSettings.Invariant);
end;

function ParseFloat(const S: string; ADefault: Double): Double;
begin
  if not TryStrToFloat(S, Result, TFormatSettings.Invariant) then
    Result := ADefault;
end;

function QuoteStr(const S: string): string;
begin
  Result := '"' + StringReplace(S, '"', '''', [rfReplaceAll]) + '"';
end;

function SamplesToHex(const D: TAudioSampleArray): string;
var
  bytes: TBytes;
begin
  if Length(D) = 0 then Exit('');
  SetLength(bytes, Length(D) * SizeOf(Single));
  Move(D[0], bytes[0], Length(bytes));
  SetLength(Result, Length(bytes) * 2);
  BinToHex(bytes[0], PWideChar(Result), Length(bytes));
end;

function HexToSamples(const H: string): TAudioSampleArray;
var
  bytes: TBytes;
  hlen: Integer;
begin
  hlen := Length(H);
  if (hlen = 0) or (hlen mod (SizeOf(Single) * 2) <> 0) then Exit(nil);
  SetLength(bytes, hlen div 2);
  if HexToBin(PWideChar(H), bytes[0], Length(bytes)) <> Length(bytes) then
    RaiseUDAW(errConfig, TRK_SUBSYS, 'SAMPLE: malformed hex payload');
  SetLength(Result, Length(bytes) div SizeOf(Single));
  if Length(Result) > 0 then
    Move(bytes[0], Result[0], Length(bytes));
end;

{ ---- small scanners ---- }

function TakeToken(var S: string): string;
var
  sp: Integer;
begin
  S := TrimLeft(S);
  sp := Pos(' ', S);
  if sp = 0 then sp := Pos(#9, S);
  if sp = 0 then begin Result := S; S := ''; end
  else begin Result := Copy(S, 1, sp - 1); S := TrimLeft(Copy(S, sp + 1, MaxInt)); end;
end;

function TakeQuoted(var S: string): string;
var
  i, closeAt: Integer;
begin
  S := TrimLeft(S);
  if (S = '') or (S[1] <> '"') then
    RaiseUDAW(errConfig, TRK_SUBSYS, 'tracker parse: expected a quoted value');
  closeAt := 0;
  for i := 2 to Length(S) do
    if S[i] = '"' then begin closeAt := i; Break; end;
  if closeAt = 0 then
    RaiseUDAW(errConfig, TRK_SUBSYS, 'tracker parse: unterminated quoted value');
  Result := Copy(S, 2, closeAt - 2);
  S := TrimLeft(Copy(S, closeAt + 1, MaxInt));
end;

function KV(const AText, AKey, ADefault: string): string;
var
  parts: TArray<string>;
  p: string;
  eq: Integer;
begin
  parts := AText.Split([' ', #9], TStringSplitOptions.ExcludeEmpty);
  for p in parts do
  begin
    eq := Pos('=', p);
    if (eq > 0) and SameText(Copy(p, 1, eq - 1), AKey) then
      Exit(Copy(p, eq + 1, MaxInt));
  end;
  Result := ADefault;
end;

function KVInt(const AText, AKey: string; ADefault: Integer): Integer;
begin
  if not TryStrToInt(KV(AText, AKey, ''), Result) then Result := ADefault;
end;

function KVFloat(const AText, AKey: string; ADefault: Double): Double;
var
  s: string;
begin
  s := KV(AText, AKey, '');
  if s = '' then Exit(ADefault);
  Result := ParseFloat(s, ADefault);
end;

{ ---- cell <-> "C-4 01 40 A06" ---- }

function CellToText(const C: TTrackerCell): string;
var
  nn, ii, vv, ee: string;
begin
  nn := NoteName(C.Note);
  if C.Instrument = TRK_INSTR_NONE then ii := '..'
  else ii := IntToHex(C.Instrument, 2);
  if C.Volume > TRK_VOL_MAX then vv := '..'
  else vv := IntToHex(C.Volume, 2);
  if (C.Effect = tfxNone) and (C.Param = 0) then ee := '...'
  else ee := EffectLetter(C.Effect) + IntToHex(C.Param, 2);
  Result := nn + ' ' + ii + ' ' + vv + ' ' + ee;
end;

function TextToCell(const AText: string): TTrackerCell;
var
  s, tok: string;
  b: Integer;
  eff: TTrackerEffect;
begin
  Result := TTrackerCell.Empty;
  s := Trim(AText);
  if (s = '') or (s = '...') then Exit;

  tok := TakeToken(s);
  if not NoteFromName(tok, Result.Note) then
    RaiseUDAWFmt(errConfig, TRK_SUBSYS, 'cell: bad note "%s"', [tok]);

  tok := TakeToken(s);
  if (tok <> '') and (tok <> '..') then
  begin
    if not TryStrToInt('$' + tok, b) then
      RaiseUDAWFmt(errConfig, TRK_SUBSYS, 'cell: bad instrument "%s"', [tok]);
    Result.Instrument := Byte(b);
  end;

  tok := TakeToken(s);
  if (tok <> '') and (tok <> '..') then
  begin
    if not TryStrToInt('$' + tok, b) then
      RaiseUDAWFmt(errConfig, TRK_SUBSYS, 'cell: bad volume "%s"', [tok]);
    Result.Volume := Byte(b);
  end;

  tok := TakeToken(s);
  if (tok <> '') and (tok <> '...') then
  begin
    if Length(tok) < 1 then Exit;
    if not EffectFromLetter(tok[1], eff) then
      RaiseUDAWFmt(errConfig, TRK_SUBSYS, 'cell: bad effect "%s"', [tok]);
    Result.Effect := eff;
    if Length(tok) >= 2 then
    begin
      if not TryStrToInt('$' + Copy(tok, 2, MaxInt), b) then
        RaiseUDAWFmt(errConfig, TRK_SUBSYS, 'cell: bad effect param "%s"', [tok]);
      Result.Param := Byte(b);
    end;
  end;
end;

{ ---- envelope pts=0:1;64:0.5;... ---- }

procedure WriteEnv(sb: TStringBuilder; const ATag: string; AInstr: Integer;
  const AEnv: TTrackerEnvelope);
var
  i: Integer;
begin
  if not AEnv.Enabled then Exit;
  sb.Append(ATag).Append(' ').Append(AInstr)
    .Append(' sustain=').Append(AEnv.SustainPoint)
    .Append(' lstart=').Append(AEnv.LoopStart)
    .Append(' lend=').Append(AEnv.LoopEnd)
    .Append(' pts=');
  for i := 0 to High(AEnv.Points) do
  begin
    if i > 0 then sb.Append(';');
    sb.Append(AEnv.Points[i].Tick).Append(':').Append(FloatId(AEnv.Points[i].Value));
  end;
  sb.AppendLine;
end;

procedure ReadEnv(const ALine: string; var AEnv: TTrackerEnvelope);
var
  s, ptsStr, pair: string;
  cp: Integer;
  t: Integer;
  v: Double;
begin
  AEnv.Clear;
  AEnv.Enabled := True;
  AEnv.SustainPoint := KVInt(ALine, 'sustain', -1);
  AEnv.LoopStart := KVInt(ALine, 'lstart', -1);
  AEnv.LoopEnd := KVInt(ALine, 'lend', -1);
  ptsStr := KV(ALine, 'pts', '');
  for pair in ptsStr.Split([';'], TStringSplitOptions.ExcludeEmpty) do
  begin
    cp := Pos(':', pair);
    if cp <= 0 then Continue;
    if TryStrToInt(Copy(pair, 1, cp - 1), t) then
    begin
      v := ParseFloat(Copy(pair, cp + 1, MaxInt), 0);
      AEnv.AddPoint(t, v);
    end;
  end;
  s := '';  // silence hint
  if s <> '' then;
end;

{ ================= serialize ================= }

function TrackerModuleToString(AModule: TTrackerModule): string;
var
  sb: TStringBuilder;
  i, r, c: Integer;
  instr: TTrackerInstrument;
  pat: TTrackerPattern;
  line: string;
  fx: TTrackerChannelFx;
begin
  sb := TStringBuilder.Create;
  try
    sb.Append(TRACKER_FILE_MAGIC).Append(' ').Append(TRACKER_FILE_VERSION).AppendLine;
    sb.Append('NAME ').Append(QuoteStr(AModule.Name)).AppendLine;
    sb.Append('CHANNELS ').Append(AModule.Channels).AppendLine;
    sb.Append('SPEED ').Append(AModule.InitialSpeed).AppendLine;
    sb.Append('BPM ').Append(AModule.InitialBPM).AppendLine;
    sb.Append('GLOBALVOL ').Append(FloatId(AModule.GlobalVolume)).AppendLine;
    sb.Append('RESTART ').Append(AModule.RestartPos).AppendLine;
    for i := 0 to AModule.Channels - 1 do
    begin
      fx := AModule.GetChannelFx(i);
      if AModule.ChannelMuted(i) or (fx.Kind <> '') then
        sb.Append('CHFX ').Append(i).Append(' ').Append(Ord(AModule.ChannelMuted(i)))
          .Append(' ').Append(QuoteStr(fx.Kind)).Append(' ').Append(QuoteStr(fx.Name))
          .Append(' ').Append(QuoteStr(fx.Params)).AppendLine;
    end;

    sb.Append('ORDER');
    for i := 0 to AModule.OrderLength - 1 do
      sb.Append(' ').Append(AModule.GetOrder(i));
    sb.AppendLine;

    for i := 1 to AModule.InstrumentCount do
    begin
      instr := AModule.GetInstrument(i);
      sb.Append('INSTR ').Append(i).Append(' ').Append(QuoteStr(instr.Name))
        .Append(' root=').Append(instr.RootNote)
        .Append(' rate=').Append(instr.SampleRate)
        .Append(' vol=').Append(FloatId(instr.Volume))
        .Append(' pan=').Append(FloatId(instr.Pan))
        .Append(' loop=').Append(LoopModeId(instr.LoopMode))
        .Append(' lstart=').Append(instr.LoopStart)
        .Append(' lend=').Append(instr.LoopEnd)
        .Append(' fade=').Append(FloatId(instr.Fadeout))
        .AppendLine;
      WriteEnv(sb, 'VOLENV', i, instr.VolEnv);
      WriteEnv(sb, 'PANENV', i, instr.PanEnv);
      if instr.FrameCount > 0 then
        sb.Append('SAMPLE ').Append(i).Append(' ').Append(SamplesToHex(instr.Data)).AppendLine;
    end;

    for i := 0 to AModule.PatternCount - 1 do
    begin
      pat := AModule.GetPattern(i);
      sb.Append('PATTERN ').Append(i).Append(' rows=').Append(pat.Rows).AppendLine;
      for r := 0 to pat.Rows - 1 do
      begin
        line := 'R' + IntToHex(r, 2);
        for c := 0 to pat.Channels - 1 do
        begin
          line := line + ' ' + CellToText(pat.GetCell(r, c));
          if c < pat.Channels - 1 then line := line + ' |';
        end;
        sb.AppendLine(line);
      end;
    end;

    Result := sb.ToString;
  finally
    sb.Free;
  end;
end;

{ ================= deserialize ================= }

function TrackerModuleFromString(const AText: string): TTrackerModule;
var
  lines: TStringList;
  li, ver, i, instrId, patId, patRows, curPatIndex, curRow: Integer;
  raw, line, tok, rest: string;
  m: TTrackerModule;
  haveHeader: Boolean;
  instr: TTrackerInstrument;
  pat: TTrackerPattern;
  lm: TTrackerLoopMode;
  chanParts: TArray<string>;
  cIdx: Integer;
  env: TTrackerEnvelope;
  isVolEnv: Boolean;
  orderTmp: array of Integer;
  restartTmp: Integer;
  fxKind, fxName: string;

  procedure EnsureInstr(AId: Integer);
  begin
    while m.InstrumentCount < AId do
      m.AddInstrument(Format('Instrument %d', [m.InstrumentCount + 1]));
  end;

begin
  lines := TStringList.Create;
  m := TTrackerModule.Create;
  curPatIndex := -1;
  curRow := 0;
  try
    lines.Text := AText;
    haveHeader := False;
    SetLength(orderTmp, 0);
    restartTmp := 0;

    for li := 0 to lines.Count - 1 do
    begin
      raw := Trim(lines[li]);
      if (raw = '') or (raw[1] = '#') then Continue;

      if not haveHeader then
      begin
        line := raw;
        tok := TakeToken(line);
        if not SameText(tok, TRACKER_FILE_MAGIC) then
          RaiseUDAW(errConfig, TRK_SUBSYS,
            'not a UDAW tracker document (missing ' + TRACKER_FILE_MAGIC + ' header)');
        if not TryStrToInt(Trim(line), ver) then
          RaiseUDAW(errConfig, TRK_SUBSYS, 'tracker header: missing version number');
        if (ver <= 0) or (ver > TRACKER_FILE_VERSION) then
          RaiseUDAWFmt(errConfig, TRK_SUBSYS,
            'unsupported tracker document version %d (reader supports up to %d)',
            [ver, TRACKER_FILE_VERSION]);
        haveHeader := True;
        m.Clear;
        Continue;
      end;

      line := raw;
      tok := TakeToken(line);

      if SameText(tok, 'NAME') then m.Name := TakeQuoted(line)
      else if SameText(tok, 'CHANNELS') then m.SetChannels(StrToIntDef(Trim(line), TRK_DEFAULT_CHANNELS))
      else if SameText(tok, 'SPEED') then m.InitialSpeed := ClampInt(StrToIntDef(Trim(line), TRK_DEFAULT_SPEED), TRK_MIN_SPEED, TRK_MAX_SPEED)
      else if SameText(tok, 'BPM') then m.InitialBPM := ClampInt(StrToIntDef(Trim(line), TRK_DEFAULT_BPM), TRK_MIN_BPM, TRK_MAX_BPM)
      else if SameText(tok, 'GLOBALVOL') then m.GlobalVolume := ParseFloat(Trim(line), 1.0)
      else if SameText(tok, 'CHFX') then
      begin
        tok := TakeToken(line);
        if TryStrToInt(tok, i) then
        begin
          m.SetChannelMuted(i, TakeToken(line) = '1');
          fxKind := TakeQuoted(line);
          fxName := TakeQuoted(line);
          m.SetChannelFx(i, fxKind, TakeQuoted(line), fxName);
        end;
      end
      else if SameText(tok, 'RESTART') then restartTmp := StrToIntDef(Trim(line), 0)
      else if SameText(tok, 'ORDER') then
      begin
        { buffered - applied after the patterns exist so nothing is clamped away }
        rest := line;
        while rest <> '' do
        begin
          tok := TakeToken(rest);
          if tok = '' then Break;
          SetLength(orderTmp, Length(orderTmp) + 1);
          orderTmp[High(orderTmp)] := StrToIntDef(tok, 0);
        end;
      end
      else if SameText(tok, 'PATTERN') then
      begin
        tok := TakeToken(line);
        if not TryStrToInt(tok, patId) then
          RaiseUDAW(errConfig, TRK_SUBSYS, 'PATTERN: bad index');
        patRows := KVInt(line, 'rows', TRK_DEFAULT_ROWS);
        while m.PatternCount <= patId do
          m.AddPattern(patRows);
        m.GetPattern(patId).Resize(patRows);
        curPatIndex := patId;
        curRow := 0;
      end
      else if (Length(tok) >= 3) and (UpCase(tok[1]) = 'R') and (curPatIndex >= 0) then
      begin
        pat := m.GetPattern(curPatIndex);
        if not TryStrToInt('$' + Copy(tok, 2, MaxInt), i) then i := curRow;
        curRow := i;
        chanParts := line.Split(['|']);
        for cIdx := 0 to High(chanParts) do
        begin
          if cIdx >= pat.Channels then Break;
          pat.SetCell(curRow, cIdx, TextToCell(chanParts[cIdx]));
        end;
        Inc(curRow);
      end
      else if SameText(tok, 'INSTR') then
      begin
        tok := TakeToken(line);
        if not TryStrToInt(tok, instrId) then
          RaiseUDAW(errConfig, TRK_SUBSYS, 'INSTR: bad id');
        EnsureInstr(instrId);
        instr := m.GetInstrument(instrId);
        instr.Name := TakeQuoted(line);
        rest := line;
        instr.RootNote := Byte(ClampInt(KVInt(rest, 'root', A4_NOTE_VALUE), TRK_NOTE_MIN, TRK_NOTE_MAX));
        instr.SampleRate := KVInt(rest, 'rate', 48000);
        instr.Volume := KVFloat(rest, 'vol', 1.0);
        instr.Pan := KVFloat(rest, 'pan', 0.0);
        if LoopModeFromId(KV(rest, 'loop', 'off'), lm) then instr.LoopMode := lm;
        instr.LoopStart := KVInt(rest, 'lstart', 0);
        instr.LoopEnd := KVInt(rest, 'lend', 0);
        instr.Fadeout := KVFloat(rest, 'fade', 0.0);
      end
      else if SameText(tok, 'VOLENV') or SameText(tok, 'PANENV') then
      begin
        isVolEnv := SameText(tok, 'VOLENV');
        tok := TakeToken(line);
        if TryStrToInt(tok, instrId) then
        begin
          EnsureInstr(instrId);
          instr := m.GetInstrument(instrId);
          if isVolEnv then env := instr.VolEnv else env := instr.PanEnv;
          ReadEnv(line, env);
          if isVolEnv then instr.VolEnv := env else instr.PanEnv := env;
        end;
      end
      else if SameText(tok, 'SAMPLE') then
      begin
        tok := TakeToken(line);
        if TryStrToInt(tok, instrId) then
        begin
          EnsureInstr(instrId);
          instr := m.GetInstrument(instrId);
          instr.SetData(HexToSamples(Trim(line)), instr.SampleRate);
        end;
      end
      else
        RaiseUDAWFmt(errConfig, TRK_SUBSYS, 'tracker parse: unexpected line "%s"', [raw]);
    end;

    if not haveHeader then
      RaiseUDAW(errConfig, TRK_SUBSYS, 'empty or headerless tracker document');
    if m.PatternCount = 0 then m.AddPattern(TRK_DEFAULT_ROWS);
    for i := 0 to High(orderTmp) do
      m.AppendOrder(orderTmp[i]);
    if m.OrderLength = 0 then m.AppendOrder(0);
    m.RestartPos := restartTmp;
    if (m.RestartPos < 0) or (m.RestartPos >= m.OrderLength) then m.RestartPos := 0;

    Result := m;
    m := nil;
  finally
    lines.Free;
    m.Free;
  end;
end;

procedure TrackerModuleToFile(AModule: TTrackerModule; const AFileName: string);
var
  sl: TStringList;
begin
  sl := TStringList.Create;
  try
    sl.Text := TrackerModuleToString(AModule);
    sl.SaveToFile(AFileName);
  finally
    sl.Free;
  end;
end;

function TrackerModuleFromFile(const AFileName: string): TTrackerModule;
var
  sl: TStringList;
begin
  if not FileExists(AFileName) then
    RaiseUDAWFmt(errFileNotFound, TRK_SUBSYS, 'tracker file not found: %s', [AFileName]);
  sl := TStringList.Create;
  try
    sl.LoadFromFile(AFileName);
    Result := TrackerModuleFromString(sl.Text);
  finally
    sl.Free;
  end;
end;

end.
