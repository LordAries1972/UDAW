unit UDAW.Codec.TrackerLegacy;
{$I udaw.inc}

{ Further tracker module formats, read by hand into the same TTrackerModule the MOD / XM /
  IT readers produce, so it plays, edits and exports through the one tracker engine:

    .s3m  ScreamTracker 3

  The other legacy formats (STM, 669, OKT, MTM, ULT, AMF, PTM, FAR, DSM) are deliberately not
  supported; the supported tracker set is MOD, S3M, XM, IT and MPTM.

  Every layout, note number, tuning rate and effect translation here follows OpenMPT's own
  loaders (the BSD-licensed sources of the ModPlug lineage), read side by side with this code:
  notes use OpenMPT's numbering (a middle C is note 61, "C-5", and a sample's C5Speed is the
  rate it plays at there), so a pattern reads the same as in OpenMPT. Where the engine has no
  counterpart for a command it is counted in the import report instead of being guessed at.
  All offsets are bounds-checked; a short file is padded and reported, not rejected. }

interface

uses
  SysUtils, Classes, Math, StrUtils,
  UDAW.Errors,
  UDAW.Audio.Types,
  UDAW.Tracker.Types, UDAW.Tracker.Instrument, UDAW.Tracker.Pattern;

const
  LEGACY_SUBSYS = 'TrackerLegacy';
  LEGACY_MAX_FILE = 64 * 1024 * 1024;

type
  TLegacyFormat = (lfNone, lfS3M);

  TLegacyImportInfo = record
    Format: TLegacyFormat;
    Title: string;
    Channels: Integer;
    PatternCount: Integer;
    SampleCount: Integer;
    OrderLength: Integer;
    LostEffectCells: Integer;
    Truncated: Boolean;
    function Summary: string;
  end;

function LegacyFormatOfData(const AData: TBytes): TLegacyFormat;
function LegacyFormatOfFile(const AFileName: string): TLegacyFormat;
function LegacyFormatName(AFormat: TLegacyFormat): string;
function FileLooksLikeLegacy(const AFileName: string): Boolean;
{ the file extensions (lower case, with the dot) this unit reads }
function IsLegacyModuleExt(const AExt: string): Boolean;

function LegacyToModule(const AData: TBytes; out AInfo: TLegacyImportInfo): TTrackerModule; overload;
function LegacyToModule(const AData: TBytes): TTrackerModule; overload;
function LoadLegacyFile(const AFileName: string; out AInfo: TLegacyImportInfo): TTrackerModule;

implementation

const
  { OpenMPT numbers notes from 1 = C-0, so the middle C that C5Speed refers to is note 61 }
  NOTE_C5 = 61;

{ ================= byte helpers ================= }

function RdW(const D: TBytes; AOfs: Integer): Integer; inline;
begin
  if (AOfs < 0) or (AOfs + 1 >= Length(D)) then Exit(0);
  Result := D[AOfs] or (D[AOfs + 1] shl 8);
end;

function RdD(const D: TBytes; AOfs: Integer): Cardinal; inline;
begin
  if (AOfs < 0) or (AOfs + 3 >= Length(D)) then Exit(0);
  Result := Cardinal(D[AOfs]) or (Cardinal(D[AOfs + 1]) shl 8)
         or (Cardinal(D[AOfs + 2]) shl 16) or (Cardinal(D[AOfs + 3]) shl 24);
end;

function Text(const D: TBytes; AOfs, ALen: Integer): string;
var
  i: Integer;
  c: Byte;
begin
  Result := '';
  for i := AOfs to AOfs + ALen - 1 do
  begin
    if (i < 0) or (i >= Length(D)) then Break;
    c := D[i];
    if c = 0 then Break;
    if (c >= 32) and (c < 127) then Result := Result + Chr(c) else Result := Result + ' ';
  end;
  Result := TrimRight(Result);
end;

function Sig(const D: TBytes; AOfs: Integer; const AMagic: AnsiString): Boolean;
var
  i: Integer;
begin
  Result := False;
  if (AOfs < 0) or (AOfs + Length(AMagic) > Length(D)) then Exit;
  for i := 1 to Length(AMagic) do
    if D[AOfs + i - 1] <> Byte(AMagic[i]) then Exit;
  Result := True;
end;

function TLegacyImportInfo.Summary: string;
begin
  Result := SysUtils.Format('%s "%s": %d channels, %d patterns, %d samples, %d orders%s%s',
    [LegacyFormatName(Self.Format), Title, Channels, PatternCount, SampleCount, OrderLength,
     IfThen(LostEffectCells > 0, SysUtils.Format(', %d command(s) without an equivalent', [LostEffectCells]), ''),
     IfThen(Truncated, ', data ran short and was padded', '')]);
end;

function LegacyFormatName(AFormat: TLegacyFormat): string;
begin
  case AFormat of
    lfS3M: Result := 'ScreamTracker 3';
  else
    Result := 'unknown';
  end;
end;

{ ================= sniffing ================= }

function LegacyFormatOfData(const AData: TBytes): TLegacyFormat;
begin
  Result := lfNone;
  if Length(AData) < 64 then Exit;
  if (Length(AData) >= $60) and Sig(AData, $2C, 'SCRM') then Exit(lfS3M);
end;

function LegacyFormatOfFile(const AFileName: string): TLegacyFormat;
var
  fs: TFileStream;
  buf: TBytes;
  n: Integer;
begin
  Result := lfNone;
  if not FileExists(AFileName) then Exit;
  try
    fs := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
    try
      n := Integer(Min(fs.Size, 4096));
      SetLength(buf, n);
      if n > 0 then fs.ReadBuffer(buf[0], n);
    finally
      fs.Free;
    end;
    { the sniffers look at the first bytes only; pad so the length guards pass }
    if Length(buf) < 2000 then SetLength(buf, 2000);
    Result := LegacyFormatOfData(buf);
  except
    Result := lfNone;
  end;
end;

function FileLooksLikeLegacy(const AFileName: string): Boolean;
begin
  Result := LegacyFormatOfFile(AFileName) <> lfNone;
end;

function IsLegacyModuleExt(const AExt: string): Boolean;
begin
  Result := MatchStr(AExt, ['.s3m']);
end;

{ ================= shared pieces ================= }

type
  TSmp = record
    Name: string;
    Pcm: TAudioSampleArray;
    Rate: Integer;          // C5Speed: the rate it plays at note 61
    Volume: Double;         // 0..1
    Loop: Boolean;
    PingPong: Boolean;
    LoopStart, LoopEnd: Integer;
  end;

procedure ApplySmp(ins: TTrackerInstrument; const S: TSmp);
begin
  ins.Name := S.Name;
  ins.RootNote := NOTE_C5;
  if Length(S.Pcm) = 0 then Exit;
  ins.SampleRate := S.Rate;
  ins.Volume := Max(0.0, Min(1.0, S.Volume));
  ins.SetData(S.Pcm, S.Rate);
  if S.Loop and (S.LoopEnd > S.LoopStart + 1) then
  begin
    if S.PingPong then ins.LoopMode := tlmPingPong else ins.LoopMode := tlmForward;
    ins.LoopStart := ClampInt(S.LoopStart, 0, Length(S.Pcm));
    ins.LoopEnd := ClampInt(S.LoopEnd, ins.LoopStart + 1, Length(S.Pcm));
  end
  else ins.LoopMode := tlmOff;
end;

{ frames of PCM at AOfs: 8 or 16 bit, signed or unsigned, little endian, mono or stereo
  (left half then right half) }
function DecodePcm(const D: TBytes; AOfs, AFrames: Integer; A16, ASigned, AStereo: Boolean;
  var ATruncated: Boolean): TAudioSampleArray;
var
  i, bytesPer, chn, avail, k: Integer;
  v, acc: Double;
  raw: Integer;
begin
  SetLength(Result, 0);
  if (AFrames <= 0) or (AFrames > 64 * 1024 * 1024) then Exit;
  bytesPer := IfThen(A16, 2, 1);
  chn := IfThen(AStereo, 2, 1);
  if (AOfs < 0) or (AOfs >= Length(D)) then
  begin
    ATruncated := True;
    Exit;
  end;
  avail := (Length(D) - AOfs) div (bytesPer * chn);
  if avail < AFrames then
  begin
    ATruncated := True;
    AFrames := avail;
  end;
  SetLength(Result, AFrames);
  for i := 0 to AFrames - 1 do
  begin
    acc := 0;
    for k := 0 to chn - 1 do
    begin
      if A16 then
      begin
        raw := RdW(D, AOfs + (k * AFrames + i) * 2);
        if ASigned then begin if raw >= 32768 then Dec(raw, 65536); v := raw / 32768.0; end
        else v := (raw - 32768) / 32768.0;
      end
      else
      begin
        raw := D[AOfs + k * AFrames + i];
        if ASigned then begin if raw >= 128 then Dec(raw, 256); v := raw / 128.0; end
        else v := (raw - 128) / 128.0;
      end;
      acc := acc + v;
    end;
    Result[i] := Single(acc / chn);
  end;
end;

function SlideParam(AP: Integer): Byte;
begin
  Result := Byte(ClampInt(Round(AP * 0.65), IfThen(AP > 0, 1, 0), 255));
end;

{ volume-slide parameter in the S3M style (Dxy: x up, y down, DFy / DxF = fine) }
procedure MapVolSlide(AParam: Integer; out AEffect: TTrackerEffect; out AOut: Byte);
var
  hi, lo: Integer;
begin
  hi := AParam shr 4;
  lo := AParam and $0F;
  AEffect := tfxVolSlide;
  AOut := Byte(AParam);
  if (lo = $F) and (hi > 0) then begin AEffect := tfxFineVolUp; AOut := Byte(hi); end
  else if (hi = $F) and (lo > 0) then begin AEffect := tfxFineVolDown; AOut := Byte(lo); end;
end;

{ the ScreamTracker effect set (S3M); ACmd is the 1-based letter (A = 1) }
function MapStEffect(ACmd, AParam: Integer; out AEffect: TTrackerEffect; out AOut: Byte): Boolean;
var
  hi, lo: Integer;
begin
  Result := True;
  AEffect := tfxNone;
  AOut := 0;
  hi := AParam shr 4;
  lo := AParam and $0F;
  case ACmd of
    1:  if AParam > 0 then begin AEffect := tfxSetSpeed; AOut := Byte(Min(AParam, TRK_MAX_SPEED)); end
        else Result := False;
    2:  begin AEffect := tfxPositionJump; AOut := Byte(AParam); end;
    3:  begin AEffect := tfxPatternBreak; AOut := Byte(ClampInt(hi * 10 + lo, 0, 63)); end;
    4:  MapVolSlide(AParam, AEffect, AOut);
    5:  begin
          if hi = $F then begin AEffect := tfxFinePortaDown; AOut := Byte(Min(15, Round(lo * 2.6))); end
          else if hi = $E then begin AEffect := tfxXFinePortaDown; AOut := Byte(Min(15, Round(lo * 2.6))); end
          else begin AEffect := tfxPortaDown; AOut := SlideParam(AParam); end;
        end;
    6:  begin
          if hi = $F then begin AEffect := tfxFinePortaUp; AOut := Byte(Min(15, Round(lo * 2.6))); end
          else if hi = $E then begin AEffect := tfxXFinePortaUp; AOut := Byte(Min(15, Round(lo * 2.6))); end
          else begin AEffect := tfxPortaUp; AOut := SlideParam(AParam); end;
        end;
    7:  begin AEffect := tfxTonePorta; AOut := SlideParam(AParam); end;
    8:  begin AEffect := tfxVibrato; AOut := Byte(AParam); end;
    9:  begin
          AEffect := tfxTremor;
          AOut := Byte((Max(0, hi - 1) shl 4) or Max(0, lo - 1));
        end;
    10: begin AEffect := tfxArpeggio; AOut := Byte(AParam); end;
    11: begin AEffect := tfxVibratoVolSlide; AOut := Byte(AParam); end;
    12: begin AEffect := tfxTonePortaVolSlide; AOut := Byte(AParam); end;
    15: begin AEffect := tfxSampleOffset; AOut := Byte(AParam); end;
    17: begin AEffect := tfxRetrigger; AOut := Byte(Max(1, lo)); end;
    18: begin AEffect := tfxTremolo; AOut := Byte(AParam); end;
    19: case hi of
          3: begin AEffect := tfxVibratoWaveform; AOut := Byte(lo and 3); end;
          4: begin AEffect := tfxTremoloWaveform; AOut := Byte(lo and 3); end;
          8: begin AEffect := tfxSetPanning; AOut := Byte(lo * 17); end;
          $B: begin AEffect := tfxPatternLoop; AOut := Byte(lo); end;
          $C: begin AEffect := tfxNoteCut; AOut := Byte(lo); end;
          $D: begin AEffect := tfxNoteDelay; AOut := Byte(lo); end;
          $E: begin AEffect := tfxPatternDelay; AOut := Byte(lo); end;
        else
          Result := False;
        end;
    20: if AParam >= 32 then begin AEffect := tfxSetBPM; AOut := Byte(AParam); end
        else Result := False;
    22: begin AEffect := tfxGlobalVol; AOut := Byte(Min(64, AParam)); end;
    24: begin AEffect := tfxSetPanning; AOut := Byte(Min(255, AParam * 2)); end;   // X: 00..7F
  else
    Result := False;
  end;
end;

procedure PutFx(var ACell: TTrackerCell; AOk: Boolean; AEffect: TTrackerEffect; AParam: Byte;
  var AInfo: TLegacyImportInfo);
begin
  if AOk then
  begin
    ACell.Effect := AEffect;
    ACell.Param := AParam;
  end
  else Inc(AInfo.LostEffectCells);
end;

procedure SetChannelPan(AModule: TTrackerModule; AChannel, APan: Integer);
var
  pat: TTrackerPattern;
  c: TTrackerCell;
begin
  if (AModule.OrderLength = 0) or (AChannel < 0) or (AChannel >= AModule.Channels) then Exit;
  pat := AModule.GetPattern(AModule.GetOrder(0));
  if pat = nil then Exit;
  c := pat.GetCell(0, AChannel);
  if c.Effect <> tfxNone then Exit;
  c.Effect := tfxSetPanning;
  c.Param := Byte(ClampInt(APan, 0, 255));
  pat.SetCell(0, AChannel, c);
end;

procedure FillOrders(AModule: TTrackerModule; const AList: array of Integer; ACount: Integer;
  AEndMark, ASkipMark: Integer);
var
  i: Integer;
begin
  for i := 0 to Min(ACount, Length(AList)) - 1 do
  begin
    if AList[i] = AEndMark then Break;
    if AList[i] = ASkipMark then Continue;
    if (AList[i] >= 0) and (AList[i] < AModule.PatternCount) then AModule.AppendOrder(AList[i]);
  end;
  if AModule.OrderLength = 0 then AModule.AppendOrder(0);
end;

{ ================= ScreamTracker 3 ================= }

procedure ReadS3M(const D: TBytes; m: TTrackerModule; var AInfo: TLegacyImportInfo);
var
  ordNum, smpNum, patNum, ffi, i, p, r, ofs, packedLen, pos, b, chn: Integer;
  chanMap: array[0..31] of Integer;
  nChan, defPan: Integer;
  orders: TArray<Integer>;
  smpPtr, patPtr: TArray<Integer>;
  signed: Boolean;
  ins: TTrackerInstrument;
  hdr, len, loopS, loopE, c2, dataOfs, vol, sflags: Integer;
  pat: TTrackerPattern;
  cell: TTrackerCell;
  nb, ib, vb, cmd, par, ch: Integer;
  eff: TTrackerEffect;
  op: Byte;
  s: TSmp;
  panTab: array[0..31] of Integer;
  stereo: Boolean;
begin
  AInfo.Format := lfS3M;
  AInfo.Title := Text(D, 0, 28);
  ordNum := RdW(D, $20);
  smpNum := RdW(D, $22);
  patNum := RdW(D, $24);
  ffi := RdW(D, $2A);
  signed := ffi = 1;
  ordNum := ClampInt(ordNum, 1, 256);
  smpNum := ClampInt(smpNum, 0, 99);
  patNum := ClampInt(patNum, 0, 256);
  stereo := (D[$33] and $80) <> 0;

  { channels: PCM ones (setting < 16) are kept in order, AdLib ones are dropped }
  nChan := 0;
  for i := 0 to 31 do
  begin
    b := D[$40 + i];
    if b < 16 then
    begin
      chanMap[i] := nChan;
      panTab[nChan] := IfThen(b < 8, 51, 204);   // left / right as 0x33 / 0xCC
      Inc(nChan);
    end
    else chanMap[i] := -1;
  end;
  if nChan = 0 then
  begin
    nChan := 4;
    for i := 0 to 3 do begin chanMap[i] := i; panTab[i] := IfThen(i in [0, 3], 51, 204); end;
  end;

  pos := $60;
  SetLength(orders, ordNum);
  for i := 0 to ordNum - 1 do
    orders[i] := IfThen(pos + i < Length(D), D[pos + i], 255);
  Inc(pos, ordNum);
  SetLength(smpPtr, smpNum);
  for i := 0 to smpNum - 1 do begin smpPtr[i] := RdW(D, pos) * 16; Inc(pos, 2); end;
  SetLength(patPtr, patNum);
  for i := 0 to patNum - 1 do begin patPtr[i] := RdW(D, pos) * 16; Inc(pos, 2); end;
  defPan := D[$35];
  if defPan = 252 then
    for i := 0 to 31 do
      if (chanMap[i] >= 0) and (pos + i < Length(D)) and ((D[pos + i] and $20) <> 0) then
        panTab[chanMap[i]] := ((D[pos + i] and $0F) * 256 + 8) div 15;

  m.SetChannels(ClampInt(nChan, TRK_MIN_CHANNELS, TRK_MAX_CHANNELS));
  m.InitialSpeed := IfThen((D[$31] > 0) and (D[$31] <= TRK_MAX_SPEED), D[$31], 6);
  m.InitialBPM := IfThen(D[$32] >= 32, D[$32], 125);
  m.GlobalVolume := IfThen(D[$30] > 0, Min(64, D[$30]) / 64.0, 1.0);

  { ---- samples ---- }
  for i := 0 to smpNum - 1 do
  begin
    hdr := smpPtr[i];
    ins := m.AddInstrument(IfThen(hdr + $50 <= Length(D), Text(D, hdr + $30, 28), ''));
    ins.RootNote := NOTE_C5;
    if (hdr <= 0) or (hdr + $50 > Length(D)) or (D[hdr] <> 1) then Continue;   // empty / AdLib
    len := Integer(RdD(D, hdr + $10));
    loopS := Integer(RdD(D, hdr + $14));
    loopE := Integer(RdD(D, hdr + $18));
    vol := D[hdr + $1C];
    sflags := D[hdr + $1F];
    c2 := Integer(RdD(D, hdr + $20));
    if c2 <= 0 then c2 := 8363;
    dataOfs := ((D[hdr + $0D] shl 16) or RdW(D, hdr + $0E)) * 16;
    if (len <= 0) or (len > 16 * 1024 * 1024) then Continue;
    Inc(AInfo.SampleCount);
    FillChar(s, SizeOf(s), 0);
    s.Name := ins.Name;
    s.Pcm := DecodePcm(D, dataOfs, len, (sflags and 4) <> 0, signed, (sflags and 2) <> 0, AInfo.Truncated);
    s.Rate := c2;
    s.Volume := Min(64, vol) / 64.0;
    s.Loop := (sflags and 1) <> 0;
    s.LoopStart := loopS;
    s.LoopEnd := loopE;
    ApplySmp(ins, s);
  end;

  { ---- patterns ---- }
  for p := 0 to patNum - 1 do
  begin
    pat := m.AddPattern(64);
    ofs := patPtr[p];
    if (ofs <= 0) or (ofs + 2 > Length(D)) then Continue;   // an empty pattern
    packedLen := RdW(D, ofs);
    pos := ofs + 2;
    r := 0;
    while (r < 64) and (pos < Length(D)) and (pos < ofs + packedLen) do
    begin
      b := D[pos]; Inc(pos);
      if b = 0 then begin Inc(r); Continue; end;
      chn := chanMap[b and 31];
      nb := 255; ib := 0; vb := 255; cmd := 0; par := 0;
      if (b and 32) <> 0 then
      begin
        if pos + 1 >= Length(D) then Break;
        nb := D[pos]; ib := D[pos + 1]; Inc(pos, 2);
      end;
      if (b and 64) <> 0 then
      begin
        if pos >= Length(D) then Break;
        vb := D[pos]; Inc(pos);
      end;
      if (b and 128) <> 0 then
      begin
        if pos + 1 >= Length(D) then Break;
        cmd := D[pos]; par := D[pos + 1]; Inc(pos, 2);
      end;
      if chn < 0 then Continue;
      cell := pat.GetCell(r, chn);
      if nb = 254 then cell.Note := TRK_NOTE_CUT
      else if nb <> 255 then
        cell.Note := Byte(ClampInt((nb shr 4) * 12 + (nb and $0F) + 13, TRK_NOTE_MIN, TRK_NOTE_MAX));
      if ib > 0 then cell.Instrument := Byte(Min(ib, 255));
      if (vb <> 255) and (vb <= 64) then cell.Volume := Byte(vb);
      if cmd > 0 then
      begin
        op := 0;
        eff := tfxNone;
        PutFx(cell, MapStEffect(cmd, par, eff, op), eff, op, AInfo);
      end;
      pat.SetCell(r, chn, cell);
    end;
  end;

  if m.PatternCount = 0 then m.AddPattern(64);
  FillOrders(m, orders, ordNum, 255, 254);

  { default stereo: a pan command on row 0 of the first pattern for every channel that is free }
  if stereo then
    for ch := 0 to m.Channels - 1 do SetChannelPan(m, ch, panTab[ch])
  else
    for ch := 0 to m.Channels - 1 do SetChannelPan(m, ch, 128);
  AInfo.OrderLength := m.OrderLength;
end;

{ ================= entry points ================= }

function LegacyToModule(const AData: TBytes; out AInfo: TLegacyImportInfo): TTrackerModule;
var
  m: TTrackerModule;
  fmt: TLegacyFormat;
begin
  FillChar(AInfo, SizeOf(AInfo), 0);
  if Length(AData) > LEGACY_MAX_FILE then
    RaiseUDAWFmt(errConfig, LEGACY_SUBSYS, 'module file too large (%d bytes)', [Length(AData)]);
  fmt := LegacyFormatOfData(AData);
  if fmt = lfNone then
    RaiseUDAW(errConfig, LEGACY_SUBSYS, 'not a recognisable tracker module (S3M)');
  m := TTrackerModule.Create;
  try
    m.Clear;
    case fmt of
      lfS3M: ReadS3M(AData, m, AInfo);
    end;
    if AInfo.Title = '' then AInfo.Title := 'Imported ' + LegacyFormatName(fmt);
    m.Name := AInfo.Title;
    AInfo.Channels := m.Channels;
    AInfo.PatternCount := m.PatternCount;
    Result := m;
    m := nil;
  finally
    m.Free;
  end;
end;

function LegacyToModule(const AData: TBytes): TTrackerModule;
var
  info: TLegacyImportInfo;
begin
  Result := LegacyToModule(AData, info);
end;

function LoadLegacyFile(const AFileName: string; out AInfo: TLegacyImportInfo): TTrackerModule;
var
  fs: TFileStream;
  buf: TBytes;
begin
  if not FileExists(AFileName) then
    RaiseUDAWFmt(errFileNotFound, LEGACY_SUBSYS, 'module file not found: %s', [AFileName]);
  fs := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
  try
    if fs.Size > LEGACY_MAX_FILE then
      RaiseUDAWFmt(errConfig, LEGACY_SUBSYS, 'module file too large: %s', [AFileName]);
    SetLength(buf, fs.Size);
    if fs.Size > 0 then fs.ReadBuffer(buf[0], fs.Size);
  finally
    fs.Free;
  end;
  Result := LegacyToModule(buf, AInfo);
end;

end.
