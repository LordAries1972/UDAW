unit UDAW.Codec.TrackerLegacy;
{$I udaw.inc}

{ Further tracker module formats, read by hand into the same TTrackerModule the MOD / XM /
  IT readers produce, so they play, edit and export through the one tracker engine:

    .s3m  ScreamTracker 3        .stm  ScreamTracker 2       .669  Composer 669 / UNIS 669
    .okt  Oktalyzer              .mtm  MultiTracker          .ult  UltraTracker
    .amf  DSMI / ASYLUM Music    .ptm  PolyTracker           .far  Farandole Composer
    .dsm  DSIK / Digisound

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
  TLegacyFormat = (lfNone, lfS3M, lfSTM, lf669, lfOKT, lfMTM, lfULT, lfAMFAsylum, lfAMF, lfPTM,
    lfFAR, lfDSM);

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

function RdB(const D: TBytes; AOfs: Integer): Integer; inline;
begin
  if (AOfs < 0) or (AOfs >= Length(D)) then Exit(0);
  Result := D[AOfs];
end;

function BeW(const D: TBytes; AOfs: Integer): Integer; inline;
begin
  if (AOfs < 0) or (AOfs + 1 >= Length(D)) then Exit(0);
  Result := (D[AOfs] shl 8) or D[AOfs + 1];
end;

function BeD(const D: TBytes; AOfs: Integer): Integer; inline;
begin
  if (AOfs < 0) or (AOfs + 3 >= Length(D)) then Exit(0);
  Result := (D[AOfs] shl 24) or (D[AOfs + 1] shl 16) or (D[AOfs + 2] shl 8) or D[AOfs + 3];
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
    lfSTM: Result := 'ScreamTracker 2';
    lf669: Result := 'Composer 669';
    lfOKT: Result := 'Oktalyzer';
    lfMTM: Result := 'MultiTracker';
    lfULT: Result := 'UltraTracker';
    lfAMFAsylum: Result := 'ASYLUM Music Format';
    lfAMF: Result := 'DSMI Advanced Music Format';
    lfPTM: Result := 'PolyTracker';
    lfFAR: Result := 'Farandole Composer';
    lfDSM: Result := 'DSIK';
  else
    Result := 'unknown';
  end;
end;

{ ================= sniffing ================= }

function Printable8(const D: TBytes; AOfs: Integer): Boolean;
var
  i: Integer;
begin
  Result := False;
  if AOfs + 8 > Length(D) then Exit;
  for i := 0 to 7 do
    if (D[AOfs + i] < $20) or (D[AOfs + i] >= $7F) then Exit;
  Result := True;
end;

function Is669(const D: TBytes): Boolean;
var
  i: Integer;
begin
  Result := False;
  if Length(D) < 497 then Exit;
  if not (Sig(D, 0, 'if') or Sig(D, 0, 'JN')) then Exit;
  if (D[110] > 64) or (D[112] >= 128) or (D[111] > 128) then Exit;
  for i := 0 to 127 do
  begin
    if (D[113 + i] >= 128) and (D[113 + i] < $FE) then Exit;
    if (D[113 + i] < 128) and (D[241 + i] = 0) then Exit;
    if D[241 + i] > 15 then Exit;
    if D[369 + i] >= 64 then Exit;
  end;
  Result := True;
end;

function LegacyFormatOfData(const AData: TBytes): TLegacyFormat;
begin
  Result := lfNone;
  if Length(AData) < 64 then Exit;
  if Sig(AData, 0, 'OKTASONG') then Exit(lfOKT);
  if Sig(AData, 0, 'MAS_UTrack_V00') and (AData[14] >= Ord('1')) and (AData[14] <= Ord('4')) then Exit(lfULT);
  if Sig(AData, 0, 'ASYLUM Music Format V1.0') then Exit(lfAMFAsylum);
  if Sig(AData, 0, 'FAR'#$FE) and Sig(AData, 44, #$0D#$0A#$1A) then Exit(lfFAR);
  if Sig(AData, 44, 'PTMF') and (AData[28] = 26) then Exit(lfPTM);
  if (Length(AData) >= $60) and Sig(AData, $2C, 'SCRM') then Exit(lfS3M);
  if Sig(AData, 0, 'AMF') and ((AData[3] = 1) or ((AData[3] >= 8) and (AData[3] <= 14))) then Exit(lfAMF);
  if Sig(AData, 0, 'MTM') and (AData[3] < $20) and (AData[27] <= 127) and
     (AData[32] <= 64) and (AData[33] >= 1) and (AData[33] <= 32) then Exit(lfMTM);
  if (Sig(AData, 0, 'RIFF') and Sig(AData, 8, 'DSMF')) or Sig(AData, 0, 'DSMF') then Exit(lfDSM);
  if Is669(AData) then Exit(lf669);
  { STM: file type 2 (module), version 2.x, a printable tracker name }
  if (Length(AData) > 1100) and (AData[29] = 2) and ((AData[28] = $1A) or (AData[28] = 2)) and
     (AData[30] = 2) and (AData[31] in [0, 10, 20, 21]) and (AData[33] <= 64) and
     ((AData[34] <= 64) or (AData[34] = $58)) and Printable8(AData, 20) then Exit(lfSTM);
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
  Result := MatchStr(AExt, ['.s3m', '.stm', '.669', '.okt', '.mtm', '.ult', '.amf', '.ptm', '.far', '.dsm']);
end;

{ ================= shared pieces ================= }

function Mod2XmFine(AMod: Integer): Integer;
begin
  { MOD finetune nibble (0..15, 8..15 are negative) -> XM units of 1/128 semitone }
  AMod := AMod and $0F;
  if AMod >= 8 then Dec(AMod, 16);
  Result := AMod * 16;
end;

{ a sample's playing rate for a tuning given in 1/128 semitone steps from 8363 Hz }
function TunedRate(ABase: Double; AXmFine: Integer): Integer;
begin
  Result := Max(1, Round(ABase * Power(2.0, AXmFine / (128.0 * 12.0))));
end;

{ one sample of any of the formats, ready to become an instrument }
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

{ 8-bit delta-coded samples (PolyTracker); 16-bit ones store the low bytes' deltas and then the
  high bytes' deltas }
function DecodeDelta(const D: TBytes; AOfs, AFrames: Integer; A16: Boolean;
  var ATruncated: Boolean): TAudioSampleArray;
var
  i, avail, acc, hi: Integer;
begin
  SetLength(Result, 0);
  if (AFrames <= 0) or (AFrames > 64 * 1024 * 1024) then Exit;
  if (AOfs < 0) or (AOfs >= Length(D)) then begin ATruncated := True; Exit; end;
  avail := (Length(D) - AOfs) div IfThen(A16, 2, 1);
  if avail < AFrames then begin ATruncated := True; AFrames := avail; end;
  SetLength(Result, AFrames);
  acc := 0;
  if not A16 then
  begin
    for i := 0 to AFrames - 1 do
    begin
      acc := (acc + D[AOfs + i]) and $FF;
      Result[i] := Single(ShortInt(acc) / 128.0);
    end;
  end
  else
  begin
    for i := 0 to AFrames - 1 do
    begin
      acc := (acc + D[AOfs + i]) and $FF;
      Result[i] := acc;
    end;
    hi := 0;
    for i := 0 to AFrames - 1 do
    begin
      hi := (hi + D[AOfs + AFrames + i]) and $FF;
      Result[i] := Single(SmallInt((hi shl 8) or Integer(Round(Result[i]))) / 32768.0);
    end;
  end;
end;

{ ----- slide / effect helpers ----- }

{ period units of 4 per tick -> the engine's 1/16 semitone steps (about 0.65 per unit at the
  middle of the keyboard) }
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

{ the ScreamTracker effect set (S3M / STM / PTM / AMF); ACmd is the 1-based letter (A = 1) }
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

{ the ProTracker effect set as OpenMPT converts it (MTM, ASYLUM, DSIK, PolyTracker's first sixteen) }
function MapModEffect(ACmd, AParam: Integer; out AEffect: TTrackerEffect; out AOut: Byte): Boolean;
var
  hi, lo: Integer;
begin
  Result := True;
  AEffect := tfxNone;
  AOut := 0;
  hi := AParam shr 4;
  lo := AParam and $0F;
  case ACmd of
    0:  if AParam <> 0 then begin AEffect := tfxArpeggio; AOut := Byte(AParam); end else Result := False;
    1:  begin AEffect := tfxPortaUp; AOut := SlideParam(AParam); end;
    2:  begin AEffect := tfxPortaDown; AOut := SlideParam(AParam); end;
    3:  begin AEffect := tfxTonePorta; AOut := SlideParam(AParam); end;
    4:  begin AEffect := tfxVibrato; AOut := Byte(AParam); end;
    5:  begin AEffect := tfxTonePortaVolSlide; AOut := Byte(AParam); end;
    6:  begin AEffect := tfxVibratoVolSlide; AOut := Byte(AParam); end;
    7:  begin AEffect := tfxTremolo; AOut := Byte(AParam); end;
    8:  begin AEffect := tfxSetPanning; AOut := Byte(AParam); end;
    9:  begin AEffect := tfxSampleOffset; AOut := Byte(AParam); end;
    10: begin AEffect := tfxVolSlide; AOut := Byte(AParam); end;
    11: begin AEffect := tfxPositionJump; AOut := Byte(AParam); end;
    12: begin AEffect := tfxSetVolume; AOut := Byte(Min(64, AParam)); end;
    13: begin AEffect := tfxPatternBreak; AOut := Byte(ClampInt(hi * 10 + lo, 0, 255)); end;
    14: case hi of
          1: begin AEffect := tfxFinePortaUp; AOut := Byte(Min(15, Round(lo * 0.65 + 0.4))); end;
          2: begin AEffect := tfxFinePortaDown; AOut := Byte(Min(15, Round(lo * 0.65 + 0.4))); end;
          4: begin AEffect := tfxVibratoWaveform; AOut := Byte(lo and 3); end;
          6: begin AEffect := tfxPatternLoop; AOut := Byte(lo); end;
          7: begin AEffect := tfxTremoloWaveform; AOut := Byte(lo and 3); end;
          8: begin AEffect := tfxSetPanning; AOut := Byte(lo * 17); end;
          9: begin AEffect := tfxRetrigger; AOut := Byte(Max(1, lo)); end;
          $A: begin AEffect := tfxFineVolUp; AOut := Byte(lo); end;
          $B: begin AEffect := tfxFineVolDown; AOut := Byte(lo); end;
          $C: begin AEffect := tfxNoteCut; AOut := Byte(lo); end;
          $D: begin AEffect := tfxNoteDelay; AOut := Byte(lo); end;
          $E: begin AEffect := tfxPatternDelay; AOut := Byte(lo); end;
        else
          Result := False;
        end;
    15: if AParam = 0 then Result := False
        else if AParam < 32 then begin AEffect := tfxSetSpeed; AOut := Byte(AParam); end
        else begin AEffect := tfxSetBPM; AOut := Byte(AParam); end;
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

{ writes an effect into the first channel of ARow that has none (a global command that has no
  cell of its own in the file) }
procedure WriteFree(APat: TTrackerPattern; ARow: Integer; AEffect: TTrackerEffect; AParam: Byte);
var
  ch: Integer;
  c: TTrackerCell;
begin
  if (ARow < 0) or (ARow >= APat.Rows) then Exit;
  for ch := 0 to APat.Channels - 1 do
  begin
    c := APat.GetCell(ARow, ch);
    if c.Effect = tfxNone then
    begin
      c.Effect := AEffect;
      c.Param := AParam;
      APat.SetCell(ARow, ch, c);
      Exit;
    end;
  end;
end;

{ a pan position (0..255) for AChannel on the first row of the first pattern played }
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

{ ================= ScreamTracker 2 ================= }

{ ST2's tick length depends on both speed nibble and the factor table: its tempo as a BPM }
function ConvertSt2Tempo(ATempo: Integer): Integer;
const
  FACTOR: array[0..15] of Integer = (140, 50, 25, 15, 10, 7, 6, 4, 3, 3, 2, 2, 2, 2, 1, 1);
var
  spt: Integer;
begin
  spt := 23863 div Max(1, 50 - ((FACTOR[(ATempo shr 4) and $0F] * (ATempo and $0F)) shr 4));
  if spt <= 0 then Inc(spt, 65536);
  Result := ClampInt(Round(23863 * 5 / (spt * 2.0)), TRK_MIN_BPM, TRK_MAX_BPM);
end;

procedure ReadSTM(const D: TBytes; m: TTrackerModule; var AInfo: TLegacyImportInfo);
var
  patCount, i, p, r, ch, ofs, b0, vol, len, loopS, loopE, vl, c2, off, verMinor, cmd, par: Integer;
  ins: TTrackerInstrument;
  pat: TTrackerPattern;
  cell: TTrackerCell;
  hdr, initTempo, orderLen, newTempo, breakPos, breakRow: Integer;
  s: TSmp;
  offs: array[0..30] of Integer;
  ids: array[0..30] of Boolean;
  insVol, volCmd, cmdInf: Integer;
  orderBytes: TArray<Integer>;
begin
  AInfo.Format := lfSTM;
  AInfo.Title := Text(D, 0, 20);
  verMinor := D[31];
  initTempo := D[32];
  if verMinor < 21 then initTempo := ((initTempo div 10) shl 4) + initTempo mod 10;
  if initTempo = 0 then initTempo := $60;
  patCount := ClampInt(D[33], 0, 64);
  m.SetChannels(4);
  m.InitialSpeed := ClampInt(initTempo shr 4, TRK_MIN_SPEED, TRK_MAX_SPEED);
  m.InitialBPM := ConvertSt2Tempo(initTempo);
  m.GlobalVolume := IfThen((verMinor > 10) and (D[34] <= 64), D[34] / 64.0, 1.0);

  for i := 0 to 30 do
  begin
    hdr := 48 + i * 32;
    ins := m.AddInstrument(Text(D, hdr, 12));
    ins.RootNote := NOTE_C5;
    offs[i] := 0;
    ids[i] := False;
    if hdr + 32 > Length(D) then Continue;
    off := RdW(D, hdr + 14);
    len := RdW(D, hdr + 16);
    loopS := RdW(D, hdr + 18);
    loopE := RdW(D, hdr + 20);
    vl := D[hdr + 22];
    c2 := RdW(D, hdr + 24);
    if len < 2 then len := 0;
    if (len <= 0) or (off = 0) or (vl = 0) then Continue;   // ST2 plays noise for volume 0
    Inc(AInfo.SampleCount);
    FillChar(s, SizeOf(s), 0);
    s.Name := ins.Name;
    s.Rate := IfThen(c2 > 0, c2, 8363);
    s.Volume := Min(64, vl) / 64.0;
    if (loopS < len) and (loopE > loopS) and (loopE <> $FFFF) then
    begin
      s.Loop := True;
      s.LoopStart := loopS;
      s.LoopEnd := loopE;
      len := Max(loopE, len);   // ST2 lets the loop end run into the next sample's data
    end;
    s.Pcm := DecodePcm(D, off * 16, len, False, True, False, AInfo.Truncated);
    ApplySmp(ins, s);
    ids[i] := True;
  end;

  orderLen := IfThen(verMinor = 0, 64, 128);
  SetLength(orderBytes, orderLen);
  for i := 0 to orderLen - 1 do
    orderBytes[i] := IfThen(48 + 31 * 32 + i < Length(D), D[48 + 31 * 32 + i], 99);

  ofs := 48 + 31 * 32 + orderLen;
  for p := 0 to patCount - 1 do
  begin
    pat := m.AddPattern(64);
    breakPos := -1;
    breakRow := 63;
    for r := 0 to 63 do
    begin
      newTempo := 0;
      for ch := 0 to 3 do
      begin
        if ofs >= Length(D) then begin AInfo.Truncated := True; Break; end;
        b0 := D[ofs]; Inc(ofs);
        cell := TTrackerCell.Empty;
        if b0 = $FB then Continue;             // empty
        if b0 = $FC then Continue;             // empty, no data follows
        if b0 = $FD then begin cell.Note := TRK_NOTE_CUT; pat.SetCell(r, ch, cell); Continue; end;
        if ofs + 3 > Length(D) then begin AInfo.Truncated := True; Break; end;
        insVol := D[ofs]; volCmd := D[ofs + 1]; cmdInf := D[ofs + 2];
        Inc(ofs, 3);
        if b0 = $FE then cell.Note := TRK_NOTE_CUT
        else if b0 < $60 then
          cell.Note := Byte(ClampInt((b0 shr 4) * 12 + (b0 and $0F) + 37, TRK_NOTE_MIN, TRK_NOTE_MAX));
        if ((insVol shr 3) > 0) and ((insVol shr 3) <= 31) then cell.Instrument := Byte(insVol shr 3);
        vol := (insVol and 7) or ((volCmd and $F0) shr 1);
        if vol <= 64 then cell.Volume := Byte(vol);
        cmd := volCmd and $0F;
        par := cmdInf;
        case cmd of
          1:  begin                                       // A: speed (and ST2's tempo)
                if verMinor < 21 then par := ((par div 10) shl 4) + par mod 10;
                if par > 0 then
                begin
                  cell.Effect := tfxSetSpeed;
                  cell.Param := Byte(ClampInt(par shr 4, 1, TRK_MAX_SPEED));
                  newTempo := par;
                end;
              end;
          2:  begin breakPos := par; breakRow := 63; end;  // B: sets the next order, takes effect at pattern end
          3:  begin                                       // C: pattern break
                par := (par and $F0) shr 4 * 10 + (par and $0F);
                if (breakPos >= 0) and (par = 0) then
                begin
                  cell.Effect := tfxPositionJump;
                  cell.Param := Byte(breakPos);
                  breakPos := -1;
                end
                else begin cell.Effect := tfxPatternBreak; cell.Param := Byte(ClampInt(par, 0, 63)); end;
                breakRow := Min(breakRow, r);
              end;
          4:  begin                                       // D: volume slide, lower nibble wins, no fine slides
                cell.Effect := tfxVolSlide;
                cell.Param := Byte(IfThen((par and $0F) <> 0, par and $0F, par and $F0));
              end;
          5:  if par <> 0 then begin cell.Effect := tfxPortaDown; cell.Param := SlideParam(par); end;
          6:  if par <> 0 then begin cell.Effect := tfxPortaUp; cell.Param := SlideParam(par); end;
          7:  if par <> 0 then begin cell.Effect := tfxTonePorta; cell.Param := SlideParam(par); end;
          8:  if par <> 0 then begin cell.Effect := tfxVibrato; cell.Param := Byte(par); end;
          9:  begin cell.Effect := tfxTremor; cell.Param := Byte((Max(0, (par shr 4) - 1) shl 4) or Max(0, (par and $F) - 1)); end;
          10: if par <> 0 then begin cell.Effect := tfxArpeggio; cell.Param := Byte(par); end;
        end;
        pat.SetCell(r, ch, cell);
      end;
      if newTempo <> 0 then WriteFree(pat, r, tfxSetBPM, Byte(ConvertSt2Tempo(newTempo)));
    end;
    if breakPos >= 0 then WriteFree(pat, breakRow, tfxPositionJump, Byte(breakPos));
  end;
  if m.PatternCount = 0 then m.AddPattern(64);

  { order list: 99 and 255 end it; a pattern number out of range is skipped }
  for i := 0 to orderLen - 1 do
  begin
    if (orderBytes[i] = 99) or (orderBytes[i] = 255) then Break;
    if orderBytes[i] < m.PatternCount then m.AppendOrder(orderBytes[i]);
  end;
  if m.OrderLength = 0 then m.AppendOrder(0);
  AInfo.OrderLength := m.OrderLength;
end;

{ ================= Composer 669 ================= }

procedure Read669(const D: TBytes; m: TTrackerModule; var AInfo: TLegacyImportInfo);
var
  nos, nop, i, p, r, ch, ofs, len, loopS, loopE, noteInstr, instrVol, effParam, patBase, smpBase,
    command, par, v, ordBase, tempoBase, breakBase, dataPos, lastNote: Integer;
  pat: TTrackerPattern;
  cell: TTrackerCell;
  effMem: array[0..7] of Integer;     // the slide a channel keeps applying until its next note
  noteOf: array[0..7] of Integer;
  s: TSmp;
  ins: TTrackerInstrument;
  isExt: Boolean;
  f, delta: Double;

  { semitone steps (1/16) a slide of AHz per tick makes at the channel's current pitch }
  function HzToStep(AHz: Double; ANote: Integer): Byte;
  begin
    f := 8363.0 * Power(2.0, (ANote - NOTE_C5) / 12.0);
    delta := 16.0 * 12.0 * Ln(1.0 + AHz / f) / Ln(2.0);
    Result := Byte(ClampInt(Round(delta), 1, 255));
  end;

begin
  AInfo.Format := lf669;
  AInfo.Title := Text(D, 2, 36);
  isExt := Sig(D, 0, 'JN');
  nos := ClampInt(D[110], 0, 64);
  nop := ClampInt(D[111], 1, 128);
  ordBase := 113;
  tempoBase := ordBase + 128;
  breakBase := tempoBase + 128;
  smpBase := breakBase + 128;
  m.SetChannels(8);
  m.InitialSpeed := 4;
  m.InitialBPM := 78;
  m.GlobalVolume := 1.0;

  patBase := smpBase + nos * 25;
  dataPos := patBase + nop * 1536;
  for i := 0 to nos - 1 do
  begin
    ofs := smpBase + i * 25;
    if ofs + 25 > Length(D) then begin AInfo.Truncated := True; Break; end;
    ins := m.AddInstrument(Text(D, ofs, 13));
    ins.RootNote := NOTE_C5;
    len := Integer(RdD(D, ofs + 13));
    loopS := Integer(RdD(D, ofs + 17));
    loopE := Integer(RdD(D, ofs + 21));
    if (len <= 0) or (len >= $4000000) then Continue;
    Inc(AInfo.SampleCount);
    FillChar(s, SizeOf(s), 0);
    s.Name := ins.Name;
    s.Pcm := DecodePcm(D, dataPos, len, False, False, False, AInfo.Truncated);
    Inc(dataPos, len);
    s.Rate := 8363;
    s.Volume := 1.0;
    { a loop end past the sample with the loop at 0 means no loop }
    if (loopE > len) and (loopS = 0) then loopE := 0;
    if loopE <> 0 then
    begin
      s.Loop := True;
      s.LoopStart := loopS;
      s.LoopEnd := Min(loopE, len);
    end;
    ApplySmp(ins, s);
  end;

  for ch := 0 to 7 do begin effMem[ch] := -1; noteOf[ch] := NOTE_C5; end;
  for p := 0 to nop - 1 do
  begin
    pat := m.AddPattern(64);
    ofs := patBase + p * 1536;
    if ofs + 1536 > Length(D) then begin AInfo.Truncated := True; Continue; end;
    for r := 0 to 63 do
      for ch := 0 to 7 do
      begin
        noteInstr := D[ofs]; instrVol := D[ofs + 1]; effParam := D[ofs + 2];
        Inc(ofs, 3);
        cell := TTrackerCell.Empty;
        if noteInstr < $FE then
        begin
          cell.Note := Byte(ClampInt((noteInstr shr 2) + 37, TRK_NOTE_MIN, TRK_NOTE_MAX));
          cell.Instrument := Byte((((noteInstr and 3) shl 4) or (instrVol shr 4)) + 1);
          effMem[ch] := -1;
          noteOf[ch] := cell.Note;
        end;
        if noteInstr <= $FE then
          cell.Volume := Byte(Min(64, ((instrVol and $0F) * 64 + 8) div 15));
        if effParam <> $FF then effMem[ch] := effParam;
        if effMem[ch] <> -1 then
        begin
          command := effMem[ch] shr 4;
          par := effMem[ch] and $0F;
          lastNote := noteOf[ch];
          case command of
            0: begin cell.Effect := tfxPortaUp; cell.Param := HzToStep(80.0 * par, lastNote); end;
            1: begin cell.Effect := tfxPortaDown; cell.Param := HzToStep(80.0 * par, lastNote); end;
            2: begin cell.Effect := tfxTonePorta; cell.Param := HzToStep(40.0 * par, lastNote); end;
            4: begin cell.Effect := tfxVibrato; cell.Param := Byte((par shl 4) or par); end;
            5: if par > 0 then begin cell.Effect := tfxSetSpeed; cell.Param := Byte(par); end;
            6: if par <= 1 then
               begin
                 cell.Effect := tfxPanSlide;
                 cell.Param := IfThen(par = 0, $4F, $F4);
               end;
            7: if (cell.Note <> TRK_NOTE_NONE) and isExt then
               begin cell.Effect := tfxRetrigger; cell.Param := Byte(Max(1, par)); end;
          else
            Inc(AInfo.LostEffectCells);
          end;
          { the slides keep going on following rows; everything else happens once }
          if not (command in [0, 1, 2]) then effMem[ch] := -1;
        end;
        pat.SetCell(r, ch, cell);
      end;
    { the pattern ends early at its break row; its tempo opens it }
    v := D[breakBase + p];
    if v < 63 then WriteFree(pat, v, tfxPatternBreak, 0);
    if D[tempoBase + p] > 0 then WriteFree(pat, 0, tfxSetSpeed, Byte(Min(D[tempoBase + p], TRK_MAX_SPEED)));
  end;

  for i := 0 to 127 do
  begin
    v := D[ordBase + i];
    if v = $FF then Break;
    if v = $FE then Continue;
    if v < m.PatternCount then m.AppendOrder(v);
  end;
  if m.OrderLength = 0 then m.AppendOrder(0);
  for ch := 0 to 7 do SetChannelPan(m, ch, IfThen((ch and 1) <> 0, $D0, $30));
  AInfo.OrderLength := m.OrderLength;
end;

{ ================= Oktalyzer ================= }

procedure ReadOKT(const D: TBytes; m: TTrackerModule; var AInfo: TLegacyImportInfo);
type
  TOktSample = record
    Name: string;
    Len, LoopStart, LoopLen, Vol, Kind: Integer;
  end;
var
  pos, len, i, j, p, r, ch, nChan, plen, rows, ofs, nSamples, sbod, smpIdx, k, hw: Integer;
  id: string;
  split: array[0..3] of Boolean;
  paired: array[0..7] of Boolean;
  smp: array of TOktSample;
  order: array[0..127] of Byte;
  pbods: TArray<Integer>;
  sbods: TArray<Integer>;
  ins: TTrackerInstrument;
  cell: TTrackerCell;
  pat: TTrackerPattern;
  nb, sb, eb, pb, v, n2: Integer;
  speed: Integer;
  s: TSmp;
  pcm: TAudioSampleArray;
  orderList: array[0..127] of Integer;

  function InvertArp(AParam: Integer): Integer;
  begin
    AParam := AParam and $0F;
    if AParam = 0 then Result := 0
    else if AParam <= $0C then Result := $0C - AParam
    else Result := $18 - AParam;
  end;

begin
  AInfo.Format := lfOKT;
  AInfo.Title := 'Oktalyzer module';
  FillChar(split, SizeOf(split), 0);
  FillChar(paired, SizeOf(paired), 0);
  FillChar(order, SizeOf(order), 0);
  nChan := 0;
  speed := 6;
  plen := 0;
  nSamples := 0;
  pos := 8;
  while pos + 8 <= Length(D) do
  begin
    id := Text(D, pos, 4);
    len := BeD(D, pos + 4);
    Inc(pos, 8);
    if (len < 0) or (pos + len > Length(D)) then
    begin
      AInfo.Truncated := True;
      len := Max(0, Length(D) - pos);
    end;
    if id = 'CMOD' then
    begin
      for i := 0 to 3 do split[i] := BeW(D, pos + i * 2) <> 0;
    end
    else if id = 'SAMP' then
    begin
      nSamples := Min(len div 32, 36);
      SetLength(smp, nSamples);
      for i := 0 to nSamples - 1 do
      begin
        ofs := pos + i * 32;
        smp[i].Name := Text(D, ofs, 20);
        smp[i].Len := BeD(D, ofs + 20) and not 1;
        smp[i].LoopStart := BeW(D, ofs + 24) * 2;
        smp[i].LoopLen := BeW(D, ofs + 26) * 2;
        smp[i].Vol := Min(64, BeW(D, ofs + 28));
        smp[i].Kind := BeW(D, ofs + 30);
      end;
    end
    else if id = 'SPEE' then speed := BeW(D, pos)
    else if id = 'PLEN' then plen := BeW(D, pos)
    else if id = 'PATT' then
    begin
      for i := 0 to Min(127, len - 1) do order[i] := D[pos + i];
    end
    else if id = 'PBOD' then pbods := pbods + [pos]
    else if id = 'SBOD' then begin if len > 0 then sbods := sbods + [pos]; end;
    pos := pos + len;
    if (len and 1) <> 0 then Inc(pos);   // chunks are word-aligned
  end;

  { channel columns: every hardware channel, doubled when CMOD says it is split in two }
  for hw := 0 to 3 do
  begin
    if split[hw] then
    begin
      paired[nChan] := True;
      paired[nChan + 1] := True;
      Inc(nChan, 2);
    end
    else Inc(nChan);
  end;
  m.SetChannels(ClampInt(nChan, TRK_MIN_CHANNELS, TRK_MAX_CHANNELS));
  m.InitialSpeed := ClampInt(speed, TRK_MIN_SPEED, TRK_MAX_SPEED);
  m.InitialBPM := 125;
  m.GlobalVolume := 1.0;

  { samples: signed 8-bit, the data of the ones with a length following in SBOD order }
  sbod := 0;
  for i := 0 to nSamples - 1 do
  begin
    ins := m.AddInstrument(smp[i].Name);
    ins.RootNote := NOTE_C5;
    if smp[i].Len <= 0 then Continue;
    smpIdx := sbod;
    Inc(sbod);
    if smpIdx >= Length(sbods) then begin AInfo.Truncated := True; Continue; end;
    Inc(AInfo.SampleCount);
    k := Min(smp[i].Len, Length(D) - sbods[smpIdx]);
    if k < smp[i].Len then AInfo.Truncated := True;
    SetLength(pcm, Max(0, k));
    for j := 0 to k - 1 do
      pcm[j] := Single(ShortInt(D[sbods[smpIdx] + j]) / 128.0);
    FillChar(s, SizeOf(s), 0);
    s.Name := smp[i].Name;
    s.Pcm := pcm;
    s.Rate := 8287;
    s.Volume := smp[i].Vol / 64.0;
    if (smp[i].LoopLen > 2) and (smp[i].LoopStart + smp[i].LoopLen <= smp[i].Len) then
    begin
      s.Loop := True;
      s.LoopStart := smp[i].LoopStart;
      s.LoopEnd := smp[i].LoopStart + smp[i].LoopLen;
    end;
    ApplySmp(ins, s);
  end;

  { patterns }
  for p := 0 to High(pbods) do
  begin
    ofs := pbods[p];
    rows := ClampInt(BeW(D, ofs), 1, 256);
    Inc(ofs, 2);
    pat := m.AddPattern(rows);
    for r := 0 to rows - 1 do
      for ch := 0 to m.Channels - 1 do
      begin
        if ofs + 4 > Length(D) then begin AInfo.Truncated := True; Break; end;
        nb := D[ofs]; sb := D[ofs + 1]; eb := D[ofs + 2]; pb := D[ofs + 3];
        Inc(ofs, 4);
        cell := TTrackerCell.Empty;
        if (nb >= 1) and (nb <= 36) then
        begin
          n2 := nb + 48;
          if paired[ch] and (n2 >= NOTE_C5 + 22) then n2 := NOTE_C5 + 21;
          cell.Note := Byte(n2);
          cell.Instrument := Byte(sb + 1);
          if (sb < nSamples) then
          begin
            { mixed channels play at full volume; a sample on the wrong kind of channel is silent }
            if paired[ch] then cell.Volume := 64;
            if ((smp[sb].Kind = 1) and paired[ch]) or ((smp[sb].Kind = 0) and not paired[ch]) then
              cell.Instrument := 200;
          end;
        end;
        case eb of
          0: ;
          1: if pb <> 0 then begin cell.Effect := tfxPortaUp; cell.Param := Byte(pb); end;
          2: if pb <> 0 then begin cell.Effect := tfxPortaDown; cell.Param := Byte(pb); end;
          10: if pb <> 0 then
              begin cell.Effect := tfxArpeggio; cell.Param := Byte((pb and $0F) or (InvertArp(pb shr 4) shl 4)); end;
          11: if pb <> 0 then
              begin cell.Effect := tfxArpeggio; cell.Param := Byte((pb and $F0) or InvertArp(pb and $0F)); end;
          12: if pb <> 0 then begin cell.Effect := tfxArpeggio; cell.Param := Byte(pb); end;
          13: if pb <> 0 then begin cell.Effect := tfxPortaDown; cell.Param := Byte(Min(15, pb) * 16); end;
          30: if pb <> 0 then begin cell.Effect := tfxPortaUp; cell.Param := Byte(Min(15, pb) * 16); end;
          15: ;   // filter: the engine has none
          25: begin cell.Effect := tfxPositionJump; cell.Param := Byte(pb); end;
          27: begin cell.Note := TRK_NOTE_OFF; cell.Instrument := 0; end;
          28: if (pb < $20) and (pb > 0) then begin cell.Effect := tfxSetSpeed; cell.Param := Byte(pb); end;
          31: begin
                v := pb shr 4;
                if (pb and $0F) <> 0 then begin cell.Effect := tfxVolSlide; cell.Param := Byte(pb and $0F); end;
                case v of
                  0, 1, 2, 3: begin cell.Volume := Byte(Min(64, pb)); cell.Effect := tfxNone; cell.Param := 0; end;
                  4: if pb = $40 then begin cell.Volume := 64; cell.Effect := tfxNone; cell.Param := 0; end;
                  5: begin cell.Effect := tfxVolSlide; cell.Param := Byte((pb and $0F) shl 4); end;
                  6: begin cell.Effect := tfxFineVolDown; cell.Param := Byte(Min(pb and $0F, $0E)); end;
                  7: begin cell.Effect := tfxFineVolUp; cell.Param := Byte(Min(pb and $0F, $0E)); end;
                else
                  cell.Effect := tfxNone;
                  cell.Param := 0;
                end;
              end;
        else
          Inc(AInfo.LostEffectCells);   // L and H note slides and the rest
        end;
        pat.SetCell(r, ch, cell);
      end;
  end;
  if m.PatternCount = 0 then m.AddPattern(64);

  for i := 0 to 127 do orderList[i] := order[i];
  FillOrders(m, orderList, Min(plen, 128), 255, 254);

  { the Amiga's fixed stereo: hardware channels 0 and 3 left, 1 and 2 right }
  ch := 0;
  for hw := 0 to 3 do
    for i := 0 to Ord(split[hw]) do
    begin
      SetChannelPan(m, ch, IfThen(hw in [1, 2], $C0, $40));
      Inc(ch);
    end;
  AInfo.OrderLength := m.OrderLength;
end;

{ ================= MultiTracker ================= }

procedure ReadMTM(const D: TBytes; m: TTrackerModule; var AInfo: TLegacyImportInfo);
var
  numTracks, lastPat, lastOrder, commentSize, numSamples, beats, numChans, rows, ofs, i, p, ch, row,
    track, trkOfs, seqOfs, smpOfs, dataOfs, fin, len, loopS, loopE, attr, vol, r: Integer;
  ins: TTrackerInstrument;
  pat: TTrackerPattern;
  cell: TTrackerCell;
  b0, b1, b2, cmd, param: Integer;
  eff: TTrackerEffect;
  op: Byte;
  s: TSmp;
  orders: array[0..127] of Integer;
  hasSpeed, hasTempo, sameRow, sp, tp: Boolean;
begin
  AInfo.Format := lfMTM;
  AInfo.Title := Text(D, 4, 20);
  numTracks := RdW(D, 24);
  lastPat := RdB(D, 26);
  lastOrder := RdB(D, 27);
  commentSize := RdW(D, 28);
  numSamples := RdB(D, 30);
  beats := RdB(D, 32);
  numChans := ClampInt(RdB(D, 33), 1, 32);
  rows := IfThen(beats > 0, beats, 64);
  m.SetChannels(numChans);
  m.InitialSpeed := 6;
  m.InitialBPM := 125;
  m.GlobalVolume := 1.0;

  smpOfs := 66;
  for i := 0 to numSamples - 1 do
  begin
    ins := m.AddInstrument(Text(D, smpOfs + i * 37, 22));
    ins.RootNote := NOTE_C5;
  end;
  { orders, tracks, sequencing, comment, then the sample data }
  ofs := smpOfs + numSamples * 37;
  for i := 0 to 127 do orders[i] := RdB(D, ofs + i);
  trkOfs := ofs + 128;
  seqOfs := trkOfs + 192 * numTracks;
  dataOfs := seqOfs + 64 * (lastPat + 1) + commentSize;

  for i := 0 to numSamples - 1 do
  begin
    ofs := smpOfs + i * 37;
    ins := m.GetInstrument(i + 1);
    len := Integer(RdD(D, ofs + 22));
    loopS := Integer(RdD(D, ofs + 26));
    loopE := Integer(RdD(D, ofs + 30));
    fin := RdB(D, ofs + 34);
    if fin >= 128 then Dec(fin, 256);
    vol := RdB(D, ofs + 35);
    attr := RdB(D, ofs + 36);
    if (len > 2) and (len < 64 * 1024 * 1024) then
    begin
      Inc(AInfo.SampleCount);
      FillChar(s, SizeOf(s), 0);
      s.Name := ins.Name;
      s.Volume := Min(64, vol) / 64.0;
      s.Rate := TunedRate(8363.0, fin * 16);
      if (attr and 1) <> 0 then
      begin
        len := len div 2;
        loopS := loopS div 2;
        loopE := loopE div 2;
        s.Pcm := DecodePcm(D, dataOfs, len, True, False, False, AInfo.Truncated);
        Inc(dataOfs, len * 2);
      end
      else
      begin
        s.Pcm := DecodePcm(D, dataOfs, len, False, False, False, AInfo.Truncated);
        Inc(dataOfs, len);
      end;
      loopE := Min(Max(loopE, 1) - 1, len);
      if loopS + 4 >= loopE then begin loopS := 0; loopE := 0; end;
      if loopE > 2 then
      begin
        s.Loop := True;
        s.LoopStart := loopS;
        s.LoopEnd := loopE;
      end;
      ApplySmp(ins, s);
    end;
  end;

  hasSpeed := False;
  hasTempo := False;
  for p := 0 to lastPat do
  begin
    pat := m.AddPattern(rows);
    for ch := 0 to 31 do
    begin
      track := RdW(D, seqOfs + p * 64 + ch * 2);
      if (track = 0) or (track > numTracks) or (ch >= numChans) then Continue;
      ofs := trkOfs + 192 * (track - 1);
      for row := 0 to rows - 1 do
      begin
        if ofs + 3 > Length(D) then begin AInfo.Truncated := True; Break; end;
        b0 := D[ofs]; b1 := D[ofs + 1]; b2 := D[ofs + 2];
        Inc(ofs, 3);
        cell := TTrackerCell.Empty;
        if (b0 and $FC) <> 0 then cell.Note := Byte(ClampInt((b0 shr 2) + 37, TRK_NOTE_MIN, TRK_NOTE_MAX));
        cell.Instrument := Byte(((b0 and 3) shl 4) or (b1 shr 4));
        cmd := b1 and $0F;
        param := b2;
        if cmd = $0A then
        begin
          if (param and $F0) <> 0 then param := param and $F0 else param := param and $0F;
        end
        else if cmd = $08 then begin cmd := 0; param := 0; end   // no 8xx panning in MultiTracker
        else if cmd = $0E then
          case param and $F0 of
            $00, $30, $40, $60, $70, $F0: begin cmd := 0; param := 0; end;
          end;
        if (cmd <> 0) or (param <> 0) then
        begin
          op := 0;
          eff := tfxNone;
          PutFx(cell, MapModEffect(cmd, param, eff, op), eff, op, AInfo);
          if cell.Effect = tfxSetSpeed then hasSpeed := True
          else if cell.Effect = tfxSetBPM then hasTempo := True;
        end;
        pat.SetCell(row, ch, cell);
      end;
    end;
  end;

  { MultiTracker's speed command resets the tempo to 125 and its tempo command resets the speed
    to 6, but players of the time (and many modules) assume the ProTracker reading instead. As
    OpenMPT does: keep the ProTracker reading when both appear on one row, else apply the
    MultiTracker one }
  if hasSpeed and hasTempo then
  begin
    sameRow := False;
    for p := 0 to m.PatternCount - 1 do
    begin
      pat := m.GetPattern(p);
      for r := 0 to pat.Rows - 1 do
      begin
        sp := False;
        tp := False;
        for ch := 0 to pat.Channels - 1 do
        begin
          if pat.GetCell(r, ch).Effect = tfxSetSpeed then sp := True
          else if pat.GetCell(r, ch).Effect = tfxSetBPM then tp := True;
        end;
        if sp and tp then sameRow := True;
      end;
    end;
    if not sameRow then
      for p := 0 to m.PatternCount - 1 do
      begin
        pat := m.GetPattern(p);
        for r := 0 to pat.Rows - 1 do
          for ch := 0 to pat.Channels - 1 do
          begin
            cell := pat.GetCell(r, ch);
            if cell.Effect = tfxSetSpeed then begin WriteFree(pat, r, tfxSetBPM, 125); Break; end
            else if cell.Effect = tfxSetBPM then begin WriteFree(pat, r, tfxSetSpeed, 6); Break; end;
          end;
      end;
  end;

  if m.PatternCount = 0 then m.AddPattern(64);
  FillOrders(m, orders, lastOrder + 1, 255, 254);
  for ch := 0 to numChans - 1 do
    SetChannelPan(m, ch, ((RdB(D, 34 + ch) and $0F) shl 4) + 8);
  AInfo.OrderLength := m.OrderLength;
end;

{ ================= UltraTracker ================= }

type
  TUltFx = record
    Eff: TTrackerEffect;
    Par: Byte;
    IsVol, IsOffset, Used: Boolean;
  end;

function UltTranslate(AVer, AE, AP: Integer): TUltFx;
var
  hi, lo: Integer;
begin
  Result.Eff := tfxNone;
  Result.Par := 0;
  Result.IsVol := False;
  Result.IsOffset := False;
  Result.Used := False;
  hi := AP shr 4;
  lo := AP and $0F;
  case AE and $0F of
    0:  if (AP <> 0) and (AVer >= Ord('3')) then
        begin Result.Eff := tfxArpeggio; Result.Par := Byte(AP); Result.Used := True; end;
    1:  begin Result.Eff := tfxPortaUp; Result.Par := SlideParam(AP); Result.Used := True; end;
    2:  begin Result.Eff := tfxPortaDown; Result.Par := SlideParam(AP); Result.Used := True; end;
    3:  begin Result.Eff := tfxTonePorta; Result.Par := SlideParam(AP); Result.Used := True; end;
    4:  begin Result.Eff := tfxVibrato; Result.Par := Byte(AP); Result.Used := True; end;
    5:  if ((lo = $C) or (hi = $C)) and (AVer >= Ord('3')) then   // 5xC key off; 5x2 (play backwards) has no equivalent
        begin Result.Eff := tfxKeyOff; Result.Par := 0; Result.Used := True; end;
    7:  if AVer >= Ord('4') then begin Result.Eff := tfxTremolo; Result.Par := Byte(AP); Result.Used := True; end;
    9:  begin Result.Eff := tfxSampleOffset; Result.Par := Byte(Min(255, AP * 4)); Result.IsOffset := True; Result.Used := True; end;
    10: begin
          if (AP and $F0) <> 0 then AP := AP and $F0;
          Result.Eff := tfxVolSlide; Result.Par := Byte(AP); Result.Used := True;
        end;
    11: begin Result.Eff := tfxSetPanning; Result.Par := Byte(lo * 17); Result.Used := True; end;
    12: begin Result.Eff := tfxSetVolume; Result.Par := Byte(Min(64, AP div 4)); Result.IsVol := True; Result.Used := True; end;
    13: begin Result.Eff := tfxPatternBreak; Result.Par := Byte(ClampInt(10 * hi + lo, 0, 63)); Result.Used := True; end;
    14: case hi of
          1: begin Result.Eff := tfxFinePortaUp; Result.Par := Byte(Min(15, Round(lo * 2.6))); Result.Used := True; end;
          2: begin Result.Eff := tfxFinePortaDown; Result.Par := Byte(Min(15, Round(lo * 2.6))); Result.Used := True; end;
          8: if AVer >= Ord('4') then begin Result.Eff := tfxPatternLoop; Result.Par := Byte(lo); Result.Used := True; end;
          9: begin Result.Eff := tfxRetrigger; Result.Par := Byte(Max(1, lo)); Result.Used := True; end;
          $A: begin Result.Eff := tfxFineVolUp; Result.Par := Byte(lo); Result.Used := True; end;
          $B: begin Result.Eff := tfxFineVolDown; Result.Par := Byte(lo); Result.Used := True; end;
          $C: begin Result.Eff := tfxNoteCut; Result.Par := Byte(lo); Result.Used := True; end;
          $D: begin Result.Eff := tfxNoteDelay; Result.Par := Byte(lo); Result.Used := True; end;
        end;
    15: begin
          Result.Used := True;
          if AP > $2F then begin Result.Eff := tfxSetBPM; Result.Par := Byte(AP); end
          else begin Result.Eff := tfxSetSpeed; Result.Par := Byte(ClampInt(AP, 1, TRK_MAX_SPEED)); end;
        end;
  end;
end;

{ the two effects of one ULT event -> the engine's single effect + volume column }
procedure UltEvent(AVer: Integer; var ACell: TTrackerCell; ACmd, APar1, APar2: Integer;
  var AInfo: TLegacyImportInfo);
var
  f1, f2, pick: TUltFx;
begin
  f1 := UltTranslate(AVer, ACmd and $0F, APar1);
  f2 := UltTranslate(AVer, ACmd shr 4, APar2);
  if f1.IsVol and f1.Used then ACell.Volume := f1.Par;
  if f2.IsVol and f2.Used then ACell.Volume := f2.Par;
  pick.Used := False;
  pick.Eff := tfxNone;
  pick.Par := 0;
  if f1.Used and not f1.IsVol then pick := f1;
  if f2.Used and not f2.IsVol then
  begin
    if not pick.Used then pick := f2
    else
    begin
      { two real effects: the engine keeps one (a sample offset wins over a slide) }
      if f2.IsOffset and not f1.IsOffset then pick := f2;
      Inc(AInfo.LostEffectCells);
    end;
  end;
  if pick.Used and (pick.Eff <> tfxNone) then
  begin
    ACell.Effect := pick.Eff;
    ACell.Param := pick.Par;
  end
  else if ((APar1 <> 0) or (APar2 <> 0)) and not f1.Used and not f2.Used then
    Inc(AInfo.LostEffectCells);
end;

procedure ReadULT(const D: TBytes; m: TTrackerModule; var AInfo: TLegacyImportInfo);
type
  TUltSmp = record
    Name: string;
    LoopS, LoopE, Frames, Vol, Flags, Speed, Fine: Integer;
  end;
var
  ver, msgLen, numSamples, i, ofs, numChans, numPats, chn, pat, row, rep, b, dataOfs: Integer;
  hdr: array of TUltSmp;
  s: TSmp;
  orders: array[0..255] of Integer;
  chanPan: array of Integer;
  cell: TTrackerCell;
  pt: TTrackerPattern;
  ins: TTrackerInstrument;
  instr, cmd, p1, p2, sizeStart, sizeEnd: Integer;
  is16: Boolean;
begin
  AInfo.Format := lfULT;
  ver := D[14];
  AInfo.Title := Text(D, 15, 32);
  msgLen := D[47];
  ofs := 48 + msgLen * 32;
  numSamples := RdB(D, ofs);
  Inc(ofs);
  SetLength(hdr, numSamples);
  for i := 0 to numSamples - 1 do
  begin
    hdr[i].Name := Text(D, ofs, 32);
    hdr[i].LoopS := Integer(RdD(D, ofs + 44));
    hdr[i].LoopE := Integer(RdD(D, ofs + 48));
    sizeStart := Integer(RdD(D, ofs + 52));
    sizeEnd := Integer(RdD(D, ofs + 56));
    hdr[i].Frames := Max(0, sizeEnd - sizeStart);
    hdr[i].Vol := RdB(D, ofs + 60);
    hdr[i].Flags := RdB(D, ofs + 61);
    hdr[i].Speed := RdW(D, ofs + 62);
    hdr[i].Fine := RdW(D, ofs + 64);
    if hdr[i].Fine >= 32768 then Dec(hdr[i].Fine, 65536);
    if ver >= Ord('4') then Inc(ofs, 66)
    else
    begin
      { before 1.4 there is no speed field: its place holds the finetune }
      hdr[i].Fine := hdr[i].Speed;
      if hdr[i].Fine >= 32768 then Dec(hdr[i].Fine, 65536);
      hdr[i].Speed := 8363;
      Inc(ofs, 64);
    end;
  end;
  for i := 0 to 255 do orders[i] := RdB(D, ofs + i);
  Inc(ofs, 256);
  numChans := RdB(D, ofs) + 1;
  numPats := RdB(D, ofs + 1) + 1;
  Inc(ofs, 2);
  if numChans > TRK_MAX_CHANNELS then
    RaiseUDAW(errConfig, LEGACY_SUBSYS, 'UltraTracker module with too many channels');
  m.SetChannels(numChans);
  m.InitialSpeed := 6;
  m.InitialBPM := 125;
  m.GlobalVolume := 1.0;
  for i := 0 to numSamples - 1 do
  begin
    ins := m.AddInstrument(hdr[i].Name);
    ins.RootNote := NOTE_C5;
  end;
  SetLength(chanPan, numChans);
  for chn := 0 to numChans - 1 do
  begin
    if ver >= Ord('3') then
    begin
      chanPan[chn] := ((RdB(D, ofs) and $0F) shl 4) + 8;
      Inc(ofs);
    end
    else chanPan[chn] := IfThen((chn and 1) <> 0, 192, 64);
  end;
  for pat := 0 to numPats - 1 do m.AddPattern(64);

  { events are stored channel by channel, pattern by pattern }
  for chn := 0 to numChans - 1 do
    for pat := 0 to numPats - 1 do
    begin
      pt := m.GetPattern(pat);
      row := 0;
      while row < 64 do
      begin
        if ofs + 6 > Length(D) then begin AInfo.Truncated := True; Break; end;
        rep := 1;
        b := D[ofs]; Inc(ofs);
        if b = $FC then
        begin
          rep := D[ofs];
          b := D[ofs + 1];
          Inc(ofs, 2);
        end;
        cell := TTrackerCell.Empty;
        if (b > 0) and (b < 97) then cell.Note := Byte(Min(TRK_NOTE_MAX, b + 24));
        instr := D[ofs]; cmd := D[ofs + 1]; p1 := D[ofs + 2]; p2 := D[ofs + 3];
        Inc(ofs, 4);
        cell.Instrument := Byte(instr);
        UltEvent(ver, cell, cmd, p1, p2, AInfo);
        if rep + row > 64 then rep := 64 - row;
        if rep = 0 then Break;
        while rep > 0 do
        begin
          pt.SetCell(row, chn, cell);
          Inc(row);
          Dec(rep);
        end;
      end;
    end;

  { sample data follows the patterns: signed, 8 or 16 bit }
  dataOfs := ofs;
  for i := 0 to numSamples - 1 do
  begin
    ins := m.GetInstrument(i + 1);
    if hdr[i].Frames <= 0 then Continue;
    Inc(AInfo.SampleCount);
    is16 := (hdr[i].Flags and 4) <> 0;
    FillChar(s, SizeOf(s), 0);
    s.Name := hdr[i].Name;
    s.Volume := hdr[i].Vol / 255.0;
    { C5Speed is twice the stored rate "to fit the note range", fine-tuned by finetune/32768 semitones }
    s.Rate := Max(1, Round(hdr[i].Speed * 2 * Power(2.0, hdr[i].Fine / 32768.0 / 12.0)));
    s.Loop := (hdr[i].Flags and 8) <> 0;
    s.PingPong := (hdr[i].Flags and 16) <> 0;
    if is16 then
    begin
      s.LoopStart := hdr[i].LoopS div 2;
      s.LoopEnd := hdr[i].LoopE div 2;
    end
    else
    begin
      s.LoopStart := hdr[i].LoopS;
      s.LoopEnd := hdr[i].LoopE;
    end;
    s.Pcm := DecodePcm(D, dataOfs, hdr[i].Frames, is16, True, False, AInfo.Truncated);
    Inc(dataOfs, hdr[i].Frames * IfThen(is16, 2, 1));
    ApplySmp(ins, s);
  end;

  FillOrders(m, orders, 256, 255, 254);
  for chn := 0 to numChans - 1 do SetChannelPan(m, chn, chanPan[chn]);
  AInfo.OrderLength := m.OrderLength;
end;

{ ================= ASYLUM Music Format ================= }

procedure ReadAsylum(const D: TBytes; m: TTrackerModule; var AInfo: TLegacyImportInfo);
var
  numSamples, numPatterns, numOrders, restart, i, p, r, ch, ofs, len, loopS, loopLen, fin, trans, vol,
    dataOfs, nb, ib, cmd, param, n: Integer;
  ins: TTrackerInstrument;
  s: TSmp;
  pat: TTrackerPattern;
  cell: TTrackerCell;
  eff: TTrackerEffect;
  op: Byte;
  orders: array[0..255] of Integer;
begin
  AInfo.Format := lfAMFAsylum;
  AInfo.Title := 'ASYLUM module';
  numSamples := ClampInt(D[34], 0, 64);
  numPatterns := D[35];
  numOrders := D[36];
  restart := D[37];
  m.SetChannels(8);
  m.InitialSpeed := IfThen((D[32] > 0) and (D[32] <= TRK_MAX_SPEED), D[32], 6);
  m.InitialBPM := IfThen(D[33] >= 32, D[33], 125);
  m.GlobalVolume := 1.0;
  for i := 0 to 255 do orders[i] := RdB(D, 38 + i);
  ofs := 38 + 256;

  for i := 0 to numSamples - 1 do
  begin
    ins := m.AddInstrument(Text(D, ofs + i * 37, 22));
    ins.RootNote := NOTE_C5;
  end;
  dataOfs := ofs + 64 * 37 + numPatterns * 64 * 8 * 4;

  for i := 0 to numSamples - 1 do
  begin
    ofs := 38 + 256 + i * 37;
    ins := m.GetInstrument(i + 1);
    fin := RdB(D, ofs + 22);
    vol := RdB(D, ofs + 23);
    trans := RdB(D, ofs + 24);
    if trans >= 128 then Dec(trans, 256);
    len := Integer(RdD(D, ofs + 25));
    loopS := Integer(RdD(D, ofs + 29));
    loopLen := Integer(RdD(D, ofs + 33));
    if (len <= 0) or (len > 32 * 1024 * 1024) then Continue;
    Inc(AInfo.SampleCount);
    FillChar(s, SizeOf(s), 0);
    s.Name := ins.Name;
    s.Volume := Min(64, vol) / 64.0;
    { MOD finetune and a semitone transpose on top of the usual 8363 Hz }
    s.Rate := TunedRate(8363.0, Mod2XmFine(fin) + trans * 128);
    s.Pcm := DecodePcm(D, dataOfs, len, False, True, False, AInfo.Truncated);
    Inc(dataOfs, len);
    if (loopLen > 2) and (loopS + loopLen <= len) then
    begin
      s.Loop := True;
      s.LoopStart := loopS;
      s.LoopEnd := loopS + loopLen;
    end;
    ApplySmp(ins, s);
  end;

  ofs := 38 + 256 + 64 * 37;
  for p := 0 to numPatterns - 1 do
  begin
    pat := m.AddPattern(64);
    for r := 0 to 63 do
      for ch := 0 to 7 do
      begin
        if ofs + 4 > Length(D) then begin AInfo.Truncated := True; Break; end;
        nb := D[ofs]; ib := D[ofs + 1]; cmd := D[ofs + 2]; param := D[ofs + 3];
        Inc(ofs, 4);
        cell := TTrackerCell.Empty;
        if nb <> 0 then
        begin
          n := nb + 13;
          if n <= TRK_NOTE_MAX then cell.Note := Byte(n);
        end;
        cell.Instrument := Byte(ib);
        if (cmd <> 0) or (param <> 0) then
        begin
          op := 0;
          eff := tfxNone;
          if cmd = 8 then param := Min(255, param * 2);   // 7-bit panning to 8-bit
          PutFx(cell, MapModEffect(cmd, param, eff, op), eff, op, AInfo);
        end;
        pat.SetCell(r, ch, cell);
      end;
  end;
  if m.PatternCount = 0 then m.AddPattern(64);
  FillOrders(m, orders, numOrders, -1, -1);
  if restart < m.OrderLength then m.RestartPos := restart;
  for ch := 0 to 7 do SetChannelPan(m, ch, IfThen((ch and 3) in [1, 2], 192, 64));
  AInfo.OrderLength := m.OrderLength;
end;

{ ================= DSMI Advanced Music Format ================= }

procedure ReadAMF(const D: TBytes; m: TTrackerModule; var AInfo: TLegacyImportInfo);
type
  TAmfSmp = record
    Name: string;
    Index, Len, Rate, Vol, LoopS, LoopE, Kind: Integer;
  end;
var
  ver, pos, numSamples, numOrders, numTracks, numChans, i, o, ch, tempo, speed, hdrSize, trackStart,
    trackCount, patLen, trk, realTrack, ev, k, row, cmd, value, tgt, startPos, stride, prm: Integer;
  hdr: array of TAmfSmp;
  trackMap, trackPos, trackEvents, patLens, sampleMap, chanPan: array of Integer;
  truncatedHdr, ok, up, loopOk: Boolean;
  pat: TTrackerPattern;
  cell: TTrackerCell;
  s: TSmp;
  ins: TTrackerInstrument;
  eff: TTrackerEffect;
  op: Byte;

  function Sgn(AB: Integer): Integer;
  begin
    if AB >= 128 then Result := AB - 256 else Result := AB;
  end;

  function ReadNewHdr(AOfs, ALen: Integer): TAmfSmp;
  begin
    Result.Kind := RdB(D, AOfs);
    Result.Name := Text(D, AOfs + 1, 32);
    Result.Index := Integer(RdD(D, AOfs + 46));
    Result.Len := Integer(RdD(D, AOfs + 50));
    Result.Rate := RdW(D, AOfs + 54);
    Result.Vol := RdB(D, AOfs + 56);
    if ALen >= 65 then
    begin
      Result.LoopS := Integer(RdD(D, AOfs + 57));
      Result.LoopE := Integer(RdD(D, AOfs + 61));
    end
    else
    begin
      { the truncated v10 layout: a 16-bit loop start and no loop end }
      Result.LoopS := RdW(D, AOfs + 57);
      Result.LoopE := 0;
      if Result.LoopS > 0 then Result.LoopE := Result.Len;
    end;
  end;

begin
  AInfo.Format := lfAMF;
  ver := D[3];
  AInfo.Title := Text(D, 4, 32);
  pos := 36;
  numSamples := RdB(D, pos);
  numOrders := RdB(D, pos + 1);
  numTracks := RdW(D, pos + 2);
  if ver >= 9 then begin numChans := RdB(D, pos + 4); Inc(pos, 5); end
  else begin numChans := 4; Inc(pos, 4); end;
  if (numSamples = 0) or (numOrders = 0) or (numTracks = 0) or (numChans < 1) or (numChans > 32) or
     ((ver >= 9) and (ver < 12) and (numChans > 16)) then
    RaiseUDAW(errConfig, LEGACY_SUBSYS, 'not a usable DSMI AMF header');
  m.SetChannels(numChans);
  m.GlobalVolume := 1.0;
  SetLength(chanPan, numChans);
  for ch := 0 to numChans - 1 do chanPan[ch] := IfThen((ch and 1) <> 0, $C0, $40);

  if ver >= 11 then
  begin
    for ch := 0 to numChans - 1 do
    begin
      k := Sgn(RdB(D, pos + ch));
      if k = 100 then chanPan[ch] := 128
      else chanPan[ch] := ClampInt((k + 64) * 2, 0, 255);
    end;
    Inc(pos, IfThen(ver >= 12, 32, 16));
  end
  else if ver >= 9 then Inc(pos, 16);

  tempo := 125;
  speed := 6;
  if ver >= 13 then
  begin
    tempo := RdB(D, pos);
    speed := RdB(D, pos + 1);
    Inc(pos, 2);
    if tempo < 32 then tempo := 125;
  end;
  m.InitialBPM := ClampInt(tempo, TRK_MIN_BPM, TRK_MAX_BPM);
  m.InitialSpeed := ClampInt(IfThen(speed > 0, speed, 6), TRK_MIN_SPEED, TRK_MAX_SPEED);

  { one pattern per order; each lists a track number per channel }
  stride := numChans * 2 + IfThen(ver >= 14, 2, 0);
  trackStart := pos + IfThen(ver >= 14, 2, 0);
  SetLength(patLens, numOrders);
  for i := 0 to numOrders - 1 do
  begin
    patLens[i] := 64;
    if ver >= 14 then patLens[i] := RdW(D, pos);
    Inc(pos, stride);
  end;

  { sample headers: 59 bytes before v10, 65 from v10 (M2AMF 1.3 wrote the new layout at the old length) }
  hdrSize := IfThen(ver >= 10, 65, 59);
  truncatedHdr := False;
  if ver = 10 then
  begin
    for i := 0 to numSamples - 1 do
    begin
      o := pos + i * 65;
      if (o + 65 <= Length(D)) and ((RdB(D, o) > 1) or (Integer(RdD(D, o + 46)) > numSamples) or
         (RdB(D, o + 56) > 64) or (Integer(RdD(D, o + 50)) > $100000)) then
      begin
        truncatedHdr := True;
        Break;
      end;
    end;
    if truncatedHdr then hdrSize := 59;
  end;
  SetLength(hdr, numSamples);
  SetLength(sampleMap, numSamples);
  for i := 0 to numSamples - 1 do
  begin
    o := pos + i * hdrSize;
    if ver < 10 then
    begin
      hdr[i].Kind := RdB(D, o);
      hdr[i].Name := Text(D, o + 1, 32);
      hdr[i].Index := Integer(RdD(D, o + 46));
      hdr[i].Len := RdW(D, o + 50);
      hdr[i].Rate := RdW(D, o + 52);
      hdr[i].Vol := RdB(D, o + 54);
      hdr[i].LoopS := RdW(D, o + 55);
      hdr[i].LoopE := RdW(D, o + 57);
    end
    else
      hdr[i] := ReadNewHdr(o, hdrSize);
    sampleMap[i] := hdr[i].Index;
  end;
  Inc(pos, numSamples * hdrSize);

  { the track mapping table, then the tracks themselves }
  SetLength(trackMap, numTracks);
  trackCount := 0;
  for i := 0 to numTracks - 1 do
  begin
    trackMap[i] := RdW(D, pos + i * 2);
    trackCount := Max(trackCount, trackMap[i]);
  end;
  Inc(pos, numTracks * 2);
  SetLength(trackPos, trackCount);
  SetLength(trackEvents, trackCount);
  for i := 0 to trackCount - 1 do
  begin
    if pos + 3 > Length(D) then begin AInfo.Truncated := True; Break; end;
    ev := RdW(D, pos);
    Inc(pos, 3);
    trackPos[i] := pos;
    trackEvents[i] := ev;
    Inc(pos, ev * 3 + IfThen(ver = 1, 3, 0));
  end;

  { sample data: unsigned 8-bit, in the order of the sample index }
  for i := 0 to numSamples - 1 do
  begin
    ins := m.AddInstrument(hdr[i].Name);
    ins.RootNote := NOTE_C5;
  end;
  for k := 1 to numSamples do
  begin
    if pos >= Length(D) then Break;
    startPos := pos;
    for tgt := 0 to numSamples - 1 do
    begin
      if sampleMap[tgt] <> k then Continue;
      pos := startPos;
      ins := m.GetInstrument(tgt + 1);
      if hdr[tgt].Len <= 0 then Continue;
      Inc(AInfo.SampleCount);
      FillChar(s, SizeOf(s), 0);
      s.Name := hdr[tgt].Name;
      s.Rate := Max(1, hdr[tgt].Rate);
      s.Volume := Min(64, hdr[tgt].Vol) / 64.0;
      s.Pcm := DecodePcm(D, pos, hdr[tgt].Len, False, False, False, AInfo.Truncated);
      loopOk := (hdr[tgt].Kind <> 0) and (hdr[tgt].LoopE > hdr[tgt].LoopS + 2) and (hdr[tgt].LoopE <= hdr[tgt].Len);
      if (ver < 10) and (hdr[tgt].LoopE = $FFFF) then loopOk := False;
      s.Loop := loopOk;
      s.LoopStart := hdr[tgt].LoopS;
      s.LoopEnd := hdr[tgt].LoopE;
      ApplySmp(ins, s);
      Inc(pos, hdr[tgt].Len);
    end;
  end;

  { patterns from the tracks }
  for i := 0 to numOrders - 1 do
  begin
    patLen := ClampInt(patLens[i], 1, TRK_MAX_ROWS);
    pat := m.AddPattern(patLen);
    o := trackStart + i * stride;
    for ch := 0 to numChans - 1 do
    begin
      trk := RdW(D, o + ch * 2);
      if (trk <= 0) or (trk > numTracks) then Continue;
      realTrack := trackMap[trk - 1];
      if (realTrack <= 0) or (realTrack > trackCount) then Continue;
      Dec(realTrack);
      for ev := 0 to trackEvents[realTrack] - 1 do
      begin
        k := trackPos[realTrack] + ev * 3;
        if k + 3 > Length(D) then Break;
        row := D[k]; cmd := D[k + 1]; value := D[k + 2];
        if row >= patLen then Break;
        cell := pat.GetCell(row, ch);
        if cmd < $7F then
        begin
          { note + volume }
          if (cmd = 0) and (value = 0) then cell.Note := TRK_NOTE_CUT
          else
          begin
            cell.Note := Byte(Min(TRK_NOTE_MAX, cmd + 1));
            if value <> $FF then cell.Volume := Byte(Min(64, value));
          end;
        end
        else if cmd = $80 then cell.Instrument := Byte(value + 1)
        else if cmd > $80 then
        begin
          prm := value;
          ok := True;
          eff := tfxNone;
          op := 0;
          case cmd and $7F of
            1: begin eff := tfxSetSpeed; op := Byte(ClampInt(prm, 1, TRK_MAX_SPEED)); end;
            2, 10, 11:
              begin
                if (prm and $80) <> 0 then prm := (-Sgn(prm)) and $0F else prm := (prm and $0F) shl 4;
                case cmd and $7F of
                  2: eff := tfxVolSlide;
                  10: eff := tfxTonePortaVolSlide;
                else
                  eff := tfxVibratoVolSlide;
                end;
                op := Byte(prm);
              end;
            3: begin cell.Volume := Byte(Min(64, prm)); ok := False; end;   // a volume command: the volume column
            4: begin
                 if (prm and $80) <> 0 then begin eff := tfxPortaUp; prm := (-Sgn(prm)) and $7F; end
                 else eff := tfxPortaDown;
                 op := SlideParam(prm);
               end;
            6: begin eff := tfxTonePorta; op := SlideParam(prm); end;
            7: begin eff := tfxTremor; op := Byte(prm); end;
            8: begin eff := tfxArpeggio; op := Byte(prm); end;
            9: begin eff := tfxVibrato; op := Byte(prm); end;
            12: begin eff := tfxPatternBreak; op := Byte(prm); end;
            13: begin eff := tfxPositionJump; op := Byte(prm); end;
            15: begin eff := tfxRetrigger; op := Byte(Max(1, prm and $0F)); end;
            16: begin eff := tfxSampleOffset; op := Byte(prm); end;
            17: if prm <> 0 then
                begin
                  if (prm and $80) <> 0 then begin eff := tfxFineVolDown; op := Byte((-Sgn(prm)) and $0F); end
                  else begin eff := tfxFineVolUp; op := Byte(prm and $0F); end;
                end
                else ok := False;
            18, 22:
              if prm <> 0 then
              begin
                up := (prm and $80) <> 0;
                if up then prm := (-Sgn(prm)) and $0F else prm := prm and $0F;
                op := Byte(Min(15, Round(prm * 2.6)));
                if (cmd and $7F) = 22 then
                  begin if up then eff := tfxXFinePortaUp else eff := tfxXFinePortaDown; end
                else
                  begin if up then eff := tfxFinePortaUp else eff := tfxFinePortaDown; end;
              end
              else ok := False;
            19: begin eff := tfxNoteDelay; op := Byte(prm and $0F); end;
            20: begin eff := tfxNoteCut; op := Byte(prm and $0F); end;
            21: if prm >= 32 then begin eff := tfxSetBPM; op := Byte(prm); end else ok := False;
            23: if prm = 100 then ok := False   // surround panning has no equivalent
                else begin eff := tfxSetPanning; op := Byte(ClampInt((Sgn(prm) + 64) * 2, 0, 255)); end;
          else
            ok := False;
          end;
          if ok then begin cell.Effect := eff; cell.Param := op; end
          else if (cmd and $7F) <> 3 then Inc(AInfo.LostEffectCells);
        end;
        pat.SetCell(row, ch, cell);
      end;
    end;
    m.AppendOrder(i);
  end;
  for ch := 0 to numChans - 1 do SetChannelPan(m, ch, chanPan[ch]);
  AInfo.OrderLength := m.OrderLength;
end;

{ ================= PolyTracker ================= }

procedure ReadPTM(const D: TBytes; m: TTrackerModule; var AInfo: TLegacyImportInfo);
var
  numOrders, numSamples, numPatterns, numChans, i, p, ofs, row, b, chn, note, instr, cmd, par, len, loopS,
    loopE, flags, vol, c4, dataOfs, patOfs, pos: Integer;
  ins: TTrackerInstrument;
  s: TSmp;
  pat: TTrackerPattern;
  cell: TTrackerCell;
  eff: TTrackerEffect;
  op: Byte;
  orders: array[0..255] of Integer;
  is16, ok: Boolean;
begin
  AInfo.Format := lfPTM;
  AInfo.Title := Text(D, 0, 28);
  numOrders := ClampInt(RdW(D, 32), 1, 256);
  numSamples := ClampInt(RdW(D, 34), 1, 255);
  numPatterns := ClampInt(RdW(D, 36), 1, 128);
  numChans := ClampInt(RdW(D, 38), 1, 32);
  m.SetChannels(numChans);
  m.InitialSpeed := 6;
  m.InitialBPM := 125;
  m.GlobalVolume := 1.0;
  for i := 0 to 255 do orders[i] := RdB(D, 96 + i);

  for i := 0 to numSamples - 1 do
  begin
    ofs := 608 + i * 80;
    ins := m.AddInstrument(Text(D, ofs + 48, 28));
    ins.RootNote := NOTE_C5;
    if ofs + 80 > Length(D) then begin AInfo.Truncated := True; Continue; end;
    flags := RdB(D, ofs);
    vol := RdB(D, ofs + 13);
    c4 := RdW(D, ofs + 14);
    dataOfs := Integer(RdD(D, ofs + 18));
    len := Integer(RdD(D, ofs + 22));
    loopS := Integer(RdD(D, ofs + 26));
    loopE := Integer(RdD(D, ofs + 30));
    if ((flags and 3) <> 1) or (len <= 0) then Continue;
    Inc(AInfo.SampleCount);
    is16 := (flags and $10) <> 0;
    FillChar(s, SizeOf(s), 0);
    s.Name := ins.Name;
    s.Volume := Min(64, vol) / 64.0;
    s.Rate := Max(1, c4 * 2);
    if loopE > loopS then Dec(loopE);
    if is16 then
    begin
      len := len div 2;
      loopS := loopS div 2;
      loopE := loopE div 2;
    end;
    s.Pcm := DecodeDelta(D, dataOfs, len, is16, AInfo.Truncated);
    s.Loop := (flags and 4) <> 0;
    s.PingPong := (flags and 8) <> 0;
    s.LoopStart := loopS;
    s.LoopEnd := loopE;
    ApplySmp(ins, s);
  end;

  for p := 0 to numPatterns - 1 do
  begin
    pat := m.AddPattern(64);
    patOfs := RdW(D, 352 + p * 2) shl 4;
    if patOfs = 0 then Continue;
    pos := patOfs;
    row := 0;
    while (row < 64) and (pos < Length(D)) do
    begin
      b := D[pos]; Inc(pos);
      if b = 0 then begin Inc(row); Continue; end;
      chn := b and $1F;
      cell := TTrackerCell.Empty;
      if chn < numChans then cell := pat.GetCell(row, chn);
      if (b and $20) <> 0 then
      begin
        if pos + 2 > Length(D) then Break;
        note := D[pos]; instr := D[pos + 1]; Inc(pos, 2);
        if note = 254 then cell.Note := TRK_NOTE_CUT
        else if (note > 0) and (note <= 120) then cell.Note := Byte(note);
        cell.Instrument := Byte(instr);
      end;
      if (b and $40) <> 0 then
      begin
        if pos + 2 > Length(D) then Break;
        cmd := D[pos]; par := D[pos + 1]; Inc(pos, 2);
        ok := True;
        eff := tfxNone;
        op := 0;
        { the letters are MOD's, but slides behave as in S3M (fine slides share the letters) }
        case cmd of
          0:  ok := MapStEffect(10, par, eff, op);
          1:  ok := MapStEffect(6, par, eff, op);
          2:  ok := MapStEffect(5, par, eff, op);
          3:  ok := MapStEffect(7, par, eff, op);
          4:  ok := MapStEffect(8, par, eff, op);
          5:  ok := MapStEffect(12, par, eff, op);
          6:  ok := MapStEffect(11, par, eff, op);
          7:  ok := MapStEffect(18, par, eff, op);
          8:  begin eff := tfxSetPanning; op := Byte(((Max(par shr 3, 1) - 1) and $0F) * 17); end;
          9:  ok := MapStEffect(15, par, eff, op);
          10: ok := MapStEffect(4, par, eff, op);
          11: ok := MapStEffect(2, par, eff, op);
          12: begin eff := tfxSetVolume; op := Byte(Min(64, par)); end;
          13: ok := MapStEffect(3, par, eff, op);
          14: ok := MapModEffect(14, par, eff, op);
          15: ok := MapModEffect(15, par, eff, op);
          16: begin eff := tfxGlobalVol; op := Byte(Min(64, par)); end;
          17: begin eff := tfxRetrigger; op := Byte(Max(1, par and $0F)); end;
          18: begin eff := tfxVibrato; op := Byte(par); end;
        else
          ok := False;
        end;
        if ok then begin cell.Effect := eff; cell.Param := op; end
        else Inc(AInfo.LostEffectCells);
      end;
      if (b and $80) <> 0 then
      begin
        if pos >= Length(D) then Break;
        cell.Volume := Byte(Min(64, D[pos]));
        Inc(pos);
      end;
      if chn < numChans then pat.SetCell(row, chn, cell);
    end;
  end;

  FillOrders(m, orders, numOrders, 255, 254);
  for chn := 0 to numChans - 1 do
    SetChannelPan(m, chn, ((RdB(D, 64 + chn) and $0F) shl 4) + 4);
  AInfo.OrderLength := m.OrderLength;
end;

{ ================= Farandole Composer ================= }

procedure ReadFAR(const D: TBytes; m: TTrackerModule; var AInfo: TLegacyImportInfo);
var
  headerLen, msgLen, ofs, i, p, r, ch, numRows, size, nb, ib, vb, eb, par, breakRow, numOrders, mapOfs,
    smp, len, loopS, loopE, vol, lastPat, lastSmp, hdrOfs: Integer;
  patSizes: array[0..255] of Integer;
  orders: array[0..255] of Integer;
  pat: TTrackerPattern;
  cell: TTrackerCell;
  s: TSmp;
  ins: TTrackerInstrument;
  is16: Boolean;
  n: Integer;
begin
  AInfo.Format := lfFAR;
  AInfo.Title := Text(D, 4, 40);
  headerLen := RdW(D, 47);
  msgLen := RdW(D, 96);
  m.SetChannels(16);
  m.InitialSpeed := IfThen((RdB(D, 75) > 0) and (RdB(D, 75) <= TRK_MAX_SPEED), RdB(D, 75), 6);
  m.InitialBPM := 80;
  m.GlobalVolume := 1.0;

  ofs := 98 + msgLen;
  for i := 0 to 255 do orders[i] := RdB(D, ofs + i);
  numOrders := RdB(D, ofs + 257);
  for i := 0 to 255 do patSizes[i] := RdW(D, ofs + 259 + i * 2);
  if (headerLen >= 98) and (headerLen <= Length(D)) then ofs := headerLen else ofs := ofs + 771;

  lastPat := -1;
  for i := 0 to 255 do
    if patSizes[i] > 0 then lastPat := i;
  for i := 0 to numOrders - 1 do
    if (orders[i] < 254) and (orders[i] > lastPat) then lastPat := orders[i];
  for p := 0 to lastPat do
  begin
    size := patSizes[p];
    if size < 66 then
    begin
      m.AddPattern(64);
      Inc(ofs, size);
      Continue;
    end;
    numRows := ClampInt((size - 2) div (16 * 4), 1, TRK_MAX_ROWS);
    pat := m.AddPattern(numRows);
    breakRow := RdB(D, ofs);
    if (breakRow > 0) and (breakRow < numRows - 2) then Inc(breakRow) else breakRow := -1;
    mapOfs := ofs + 2;
    for r := 0 to numRows - 1 do
      for ch := 0 to 15 do
      begin
        if mapOfs + 4 > Length(D) then begin AInfo.Truncated := True; Break; end;
        nb := D[mapOfs]; ib := D[mapOfs + 1]; vb := D[mapOfs + 2]; eb := D[mapOfs + 3];
        Inc(mapOfs, 4);
        cell := TTrackerCell.Empty;
        if (nb > 0) and (nb <= 72) then
        begin
          cell.Note := Byte(nb + 36);
          cell.Instrument := Byte(ib + 1);
        end;
        if (vb > 0) and (vb <= 16) then cell.Volume := Byte((vb - 1) * 64 div 15);
        par := eb and $0F;
        case eb shr 4 of
          1: begin cell.Effect := tfxFinePortaUp; cell.Param := Byte(Min(15, par)); end;
          2: begin cell.Effect := tfxFinePortaDown; cell.Param := Byte(Min(15, par)); end;
          3: if par <> 0 then begin cell.Effect := tfxTonePorta; cell.Param := SlideParam(60 div par); end;
          4: begin cell.Effect := tfxRetrigger; cell.Param := Byte(Max(1, 6 div (1 + par) + 1)); end;
          5: begin cell.Effect := tfxVibrato; cell.Param := Byte(par); end;                 // depth
          6: begin cell.Effect := tfxVibrato; cell.Param := Byte((par * 8) and $F0); end;   // speed
          7: begin cell.Effect := tfxVolSlide; cell.Param := Byte((par * 8) and $FF); end;
          8: begin cell.Effect := tfxVolSlide; cell.Param := Byte(par); end;
          9: begin cell.Effect := tfxVibrato; cell.Param := Byte(par); end;
          10: begin cell.Volume := Byte(Min(64, (par shl 2) + 4)); end;   // slide-to-volume, taken as a set
          11: begin cell.Effect := tfxSetPanning; cell.Param := Byte(par * 17); end;
          12: begin cell.Effect := tfxNoteDelay; cell.Param := Byte(Min(15, 6 div (1 + par) + 1)); end;
          15: if par > 0 then begin cell.Effect := tfxSetSpeed; cell.Param := Byte(par); end;
          13, 14: Inc(AInfo.LostEffectCells);   // fine tempo changes
        end;
        pat.SetCell(r, ch, cell);
      end;
    if breakRow >= 0 then WriteFree(pat, breakRow, tfxPatternBreak, 0);
    Inc(ofs, size);
  end;
  if m.PatternCount = 0 then m.AddPattern(64);

  { samples: a bit map of the 64 slots in use, then each header and its signed data }
  lastSmp := -1;
  if ofs + 8 <= Length(D) then
  begin
    mapOfs := ofs;
    Inc(ofs, 8);
    for smp := 0 to 63 do
    begin
      if (D[mapOfs + (smp shr 3)] and (1 shl (smp and 7))) = 0 then Continue;
      lastSmp := smp;
    end;
    for smp := 0 to lastSmp do
      m.AddInstrument('').RootNote := NOTE_C5;
    for smp := 0 to 63 do
    begin
      if (D[mapOfs + (smp shr 3)] and (1 shl (smp and 7))) = 0 then Continue;
      if ofs + 48 > Length(D) then begin AInfo.Truncated := True; Break; end;
      ins := m.GetInstrument(smp + 1);
      hdrOfs := ofs;
      len := Integer(RdD(D, hdrOfs + 32));
      vol := RdB(D, hdrOfs + 37);
      loopS := Integer(RdD(D, hdrOfs + 38));
      loopE := Integer(RdD(D, hdrOfs + 42));
      is16 := (RdB(D, hdrOfs + 46) and 1) <> 0;
      Inc(ofs, 48);
      if is16 then begin len := len div 2; loopS := loopS div 2; loopE := loopE div 2; end;
      FillChar(s, SizeOf(s), 0);
      s.Name := Text(D, hdrOfs, 32);
      s.Rate := 8363 * 2;
      s.Volume := Min(16, vol) / 16.0;
      s.Loop := ((RdB(D, hdrOfs + 47) and 8) <> 0) and (loopE > loopS);
      s.LoopStart := loopS;
      s.LoopEnd := loopE;
      s.Pcm := DecodePcm(D, ofs, len, is16, True, False, AInfo.Truncated);
      Inc(ofs, len * IfThen(is16, 2, 1));
      Inc(AInfo.SampleCount);
      ApplySmp(ins, s);
    end;
  end;

  FillOrders(m, orders, numOrders, 255, 254);
  n := RdB(D, 98 + msgLen + 258);
  if n < m.OrderLength then m.RestartPos := n;
  for ch := 0 to 15 do
  begin
    if RdB(D, 50 + ch) = 0 then m.SetChannelMuted(ch, True);
    SetChannelPan(m, ch, ((RdB(D, 76 + ch) and $0F) shl 4) + 8);
  end;
  AInfo.OrderLength := m.OrderLength;
end;

{ ================= DSIK / Digisound Interface Kit ================= }

procedure ReadDSM(const D: TBytes; m: TTrackerModule; var AInfo: TLegacyImportInfo);
var
  pos, size, numOrders, numChans, numPatterns, i, row, flag, chn, ch, note, cmd, par, sPos,
    chunkEnd, flags, len, loopS, loopE, rate, vol, patNum, restart: Integer;
  id: string;
  orders: array[0..127] of Integer;
  pans: array[0..15] of Integer;
  pat: TTrackerPattern;
  cell: TTrackerCell;
  eff: TTrackerEffect;
  op: Byte;
  ins: TTrackerInstrument;
  s: TSmp;
  is16, delta, ok: Boolean;
  acc: Integer;
begin
  AInfo.Format := lfDSM;
  { RIFF form: 'RIFF' size 'DSMF'; the bare form: 'DSMF', 4 more bytes, the size, 4 more bytes }
  if Sig(D, 0, 'RIFF') then pos := 12 else pos := 16;
  for ch := 0 to 15 do pans[ch] := -1;
  { the SONG chunk comes first }
  id := Text(D, pos, 4);
  size := Integer(RdD(D, pos + 4));
  Inc(pos, 8);
  if id <> 'SONG' then
    RaiseUDAW(errConfig, LEGACY_SUBSYS, 'DSIK module without a SONG chunk');
  AInfo.Title := Text(D, pos, 28);
  restart := RdW(D, pos + 34);
  numOrders := RdW(D, pos + 36);
  numPatterns := RdW(D, pos + 40);
  numChans := RdW(D, pos + 42);
  if (numOrders > 128) or (numChans > 16) or (numPatterns > 256) then
    RaiseUDAW(errConfig, LEGACY_SUBSYS, 'DSIK module with out-of-range counts');
  m.SetChannels(Max(1, numChans));
  m.InitialSpeed := IfThen((RdB(D, pos + 46) > 0) and (RdB(D, pos + 46) <= TRK_MAX_SPEED), RdB(D, pos + 46), 6);
  m.InitialBPM := IfThen(RdB(D, pos + 47) >= 32, RdB(D, pos + 47), 125);
  m.GlobalVolume := IfThen(RdB(D, pos + 44) > 0, Min(64, RdB(D, pos + 44)) / 64.0, 1.0);
  for i := 0 to 127 do orders[i] := RdB(D, pos + 64 + i);
  for ch := 0 to Min(numChans, 16) - 1 do
    if RdB(D, pos + 48 + ch) <= $80 then pans[ch] := Min(255, RdB(D, pos + 48 + ch) * 2);
  Inc(pos, size);

  patNum := 0;
  while pos + 8 <= Length(D) do
  begin
    id := Text(D, pos, 4);
    size := Integer(RdD(D, pos + 4));
    Inc(pos, 8);
    chunkEnd := Min(Length(D), pos + Max(0, size));
    if id = 'PATT' then
    begin
      pat := m.AddPattern(64);
      sPos := pos + 2;
      row := 0;
      while (sPos < chunkEnd) and (row < 64) do
      begin
        flag := D[sPos]; Inc(sPos);
        if flag = 0 then begin Inc(row); Continue; end;
        chn := flag and $0F;
        cell := TTrackerCell.Empty;
        if chn < m.Channels then cell := pat.GetCell(row, chn);
        if (flag and $80) <> 0 then
        begin
          note := RdB(D, sPos); Inc(sPos);
          if note <> 0 then
          begin
            if note <= 12 * 9 then Inc(note, 12);
            cell.Note := Byte(ClampInt(note, TRK_NOTE_MIN, TRK_NOTE_MAX));
          end;
        end;
        if (flag and $40) <> 0 then begin cell.Instrument := Byte(RdB(D, sPos)); Inc(sPos); end;
        if (flag and $20) <> 0 then begin cell.Volume := Byte(Min(64, RdB(D, sPos))); Inc(sPos); end;
        if (flag and $10) <> 0 then
        begin
          cmd := RdB(D, sPos); par := RdB(D, sPos + 1); Inc(sPos, 2);
          op := 0;
          eff := tfxNone;
          ok := MapModEffect(cmd, par, eff, op);
          PutFx(cell, ok, eff, op, AInfo);
        end;
        if chn < m.Channels then pat.SetCell(row, chn, cell);
      end;
      Inc(patNum);
    end
    else if id = 'INST' then
    begin
      ins := m.AddInstrument(Text(D, pos + 36, 28));
      ins.RootNote := NOTE_C5;
      flags := RdW(D, pos + 13);
      vol := RdB(D, pos + 15);
      len := Integer(RdD(D, pos + 16));
      loopS := Integer(RdD(D, pos + 20));
      loopE := Integer(RdD(D, pos + 24));
      rate := Integer(RdD(D, pos + 32));
      if (len > 0) and (len < 64 * 1024 * 1024) then
      begin
        is16 := (flags and 4) <> 0;
        delta := (flags and $40) <> 0;
        Inc(AInfo.SampleCount);
        FillChar(s, SizeOf(s), 0);
        s.Name := ins.Name;
        s.Rate := Max(1, rate);
        s.Volume := Min(64, vol) / 64.0;
        s.Loop := (flags and 1) <> 0;
        s.LoopStart := loopS;
        s.LoopEnd := loopE;
        if delta then
        begin
          SetLength(s.Pcm, Max(0, Min(len, chunkEnd - (pos + 64))));
          acc := 0;
          for i := 0 to High(s.Pcm) do
          begin
            acc := (acc + D[pos + 64 + i]) and $FF;
            s.Pcm[i] := Single(ShortInt(acc) / 128.0);
          end;
        end
        else if is16 then
          s.Pcm := DecodePcm(D, pos + 64, len div 2, True, (flags and 2) <> 0, False, AInfo.Truncated)
        else
          s.Pcm := DecodePcm(D, pos + 64, len, False, (flags and 2) <> 0, False, AInfo.Truncated);
        ApplySmp(ins, s);
      end;
    end;
    pos := chunkEnd;
  end;
  if m.PatternCount = 0 then m.AddPattern(64);
  FillOrders(m, orders, numOrders, 255, 254);
  if restart < m.OrderLength then m.RestartPos := restart;
  for ch := 0 to Min(m.Channels, 16) - 1 do
    if pans[ch] >= 0 then SetChannelPan(m, ch, pans[ch]);
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
    RaiseUDAW(errConfig, LEGACY_SUBSYS, 'not a recognisable tracker module (S3M, STM, 669, OKT, MTM, ULT, AMF, PTM, FAR, DSM)');
  m := TTrackerModule.Create;
  try
    m.Clear;
    case fmt of
      lfS3M: ReadS3M(AData, m, AInfo);
      lfSTM: ReadSTM(AData, m, AInfo);
      lf669: Read669(AData, m, AInfo);
      lfOKT: ReadOKT(AData, m, AInfo);
      lfMTM: ReadMTM(AData, m, AInfo);
      lfULT: ReadULT(AData, m, AInfo);
      lfAMFAsylum: ReadAsylum(AData, m, AInfo);
      lfAMF: ReadAMF(AData, m, AInfo);
      lfPTM: ReadPTM(AData, m, AInfo);
      lfFAR: ReadFAR(AData, m, AInfo);
      lfDSM: ReadDSM(AData, m, AInfo);
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
