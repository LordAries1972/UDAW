unit UDAW.Codec.ProTracker;
{$I udaw.inc}

{ Phase 12 - MOD support: a from-scratch ProTracker / Soundtracker .MOD
  reader and writer that map onto the Phase 11 tracker engine
  (TTrackerModule / TTrackerPlayer). The plan forbids a third-party module
  library (no OpenMPT); every byte here is parsed and emitted by hand with
  strict bounds checking - an unknown or truncated field is clamped or
  reported, never allowed to corrupt memory.

    ModToModule   .MOD bytes       -> TTrackerModule   (import / play / edit)
    ModuleToMod   TTrackerModule   -> .MOD bytes       (export, 31-sample)
    ModExportIssues                 - what a module loses on the way to MOD
    ModKindFromData / FileLooksLikeMod / DataLooksLikeMod
                                    - header sniffing, never the file extension
    LoadModFile / SaveModFile       - one-shot file helpers

  Import covers:
    * 15-sample (Soundtracker, no tag) and 31-sample layouts
    * tags M.K. M!K! M&K! FLT4 FLT8 4CHN 6CHN 8CHN OCTA OKTA CD81 and the
      generic "nnCH" / "nCHN" (1..32 channels)
    * 20-char song title, 22-char sample names
    * sample headers: length, signed-nibble finetune, volume, loop start /
      length (all big-endian word counts), 8-bit signed PCM, forward loops
    * the full ProTracker effect column incl. the Exy extended set, mapped
      onto UDAW's internal effect set; commands with no internal equivalent
      are counted in the import report rather than guessed at
    * order table + restart position; pattern count taken from the order table

  Pitch: notes resolve through an Amiga period table (8363 Hz = C-3, the
  sample finetune baked into the instrument's sample rate) so the Phase 11
  player reproduces Amiga playback pitch - a MOD is not flattened to plain
  audio clips. }

interface

uses
  SysUtils, Classes, Math, StrUtils,
  UDAW.Errors,
  UDAW.Audio.Types,
  UDAW.Tracker.Types, UDAW.Tracker.Instrument, UDAW.Tracker.Pattern;

const
  MOD_SUBSYS = 'MOD';

  MOD_C3_RATE       = 8363.0;        // Hz a finetune-0 sample plays at for the
                                    // reference note (period 428)
  MOD_PAL_CLOCK     = 7093789.2;     // Amiga PAL colour clock (period<->Hz)
  MOD_NOTE_BASE     = 37;            // UDAW note value of MOD note index 0 (C-3)
  MOD_NOTES         = 36;            // 3 octaves, ProTracker periods 856..113
  MOD_REF_INDEX     = 12;            // reference note (period ~428) in the range
  MOD_ROWS          = 64;            // every MOD pattern is 64 rows
  MOD_MAX_CHANNELS  = 32;
  MOD_MAX_PATTERNS  = 128;
  MOD_MAX_ORDERS    = 128;
  MOD_MAX_SAMPLE_BYTES = 128 * 1024; // 0xFFFF words, ProTracker's ceiling
  MOD_MAX_FILE      = 32 * 1024 * 1024;
  MOD_DEFAULT_SPEED = 6;
  MOD_DEFAULT_BPM   = 125;

type
  TModKind = (mkNone, mk15, mk31);

  TModImportInfo = record
    Kind: TModKind;
    Tag: string;               // 4-char format tag ('' for 15-sample)
    Title: string;
    Channels: Integer;
    SampleCount: Integer;      // header slots (15 or 31)
    UsedSamples: Integer;      // slots that actually carry PCM
    PatternCount: Integer;
    OrderLength: Integer;
    RestartPos: Integer;
    TotalCells: Integer;
    NoteCells: Integer;
    EffectCells: Integer;
    LostEffectCells: Integer;  // effect commands with no internal equivalent
    Truncated: Boolean;        // pattern / sample data ran short and was padded
    function Summary: string;
  end;

{ ---- sniffing ---- }
function ModKindFromData(const AData: TBytes): TModKind;
function DataLooksLikeMod(const AData: TBytes): Boolean;
function FileLooksLikeMod(const AFileName: string): Boolean;

{ ---- import ---- }
function ModToModule(const AData: TBytes; out AInfo: TModImportInfo): TTrackerModule; overload;
function ModToModule(const AData: TBytes): TTrackerModule; overload;
function LoadModFile(const AFileName: string; out AInfo: TModImportInfo): TTrackerModule; overload;
function LoadModFile(const AFileName: string): TTrackerModule; overload;

{ ---- export ---- }
{ Human-readable notes about what the module cannot represent in MOD; empty
  when the module maps cleanly. The export itself is always best-effort. }
function ModExportIssues(AModule: TTrackerModule): TArray<string>;
function ModuleToMod(AModule: TTrackerModule): TBytes;
procedure SaveModFile(const AFileName: string; AModule: TTrackerModule);

{ ---- period / note helpers (exposed for the tests) ---- }
function ModFinetuneSigned(ANibble: Byte): Integer;
function ModNoteFreq(ANoteIndex, AFinetune: Integer): Double;
function ModNotePeriod(ANoteIndex, AFinetune: Integer): Double;
function ModPeriodToNoteIndex(APeriod, AFinetune: Integer): Integer;

implementation

{ ================= period maths ================= }

function ModFinetuneSigned(ANibble: Byte): Integer;
begin
  Result := ANibble and $0F;
  if Result >= 8 then Dec(Result, 16);
end;

function ModNoteFreq(ANoteIndex, AFinetune: Integer): Double;
begin
  { one finetune step = 1/8 semitone }
  Result := MOD_C3_RATE * Power(2.0,
    (ANoteIndex - MOD_REF_INDEX) / 12.0 + AFinetune / 96.0);
end;

function ModNotePeriod(ANoteIndex, AFinetune: Integer): Double;
begin
  Result := MOD_PAL_CLOCK / (2.0 * ModNoteFreq(ANoteIndex, AFinetune));
end;

function ModPeriodToNoteIndex(APeriod, AFinetune: Integer): Integer;
var
  i, best: Integer;
  err, bestErr: Double;
begin
  if APeriod <= 0 then Exit(-1);
  best := 0;
  bestErr := 1e30;
  for i := 0 to MOD_NOTES - 1 do
  begin
    err := Abs(ModNotePeriod(i, AFinetune) - APeriod);
    if err < bestErr then
    begin
      bestErr := err;
      best := i;
    end;
  end;
  Result := best;
end;

function FinetuneForRate(ARate: Integer): Integer;
begin
  if ARate <= 0 then Exit(0);
  Result := Round(96.0 * Ln(ARate / MOD_C3_RATE) / Ln(2.0));
  Result := ClampInt(Result, -8, 7);
end;

{ ================= effect mapping ================= }

{ MOD command nibble + parameter -> UDAW internal effect. Returns False when
  the command has no internal equivalent (it is dropped and counted). }
function MapModEffect(ACmd, AParam: Byte; out AEffect: TTrackerEffect;
  out AOutParam: Byte): Boolean;
var
  sub, lo: Byte;
begin
  AEffect := tfxNone;
  AOutParam := 0;
  Result := True;
  case ACmd of
    $0:
      if AParam = 0 then Result := False
      else begin AEffect := tfxArpeggio; AOutParam := AParam; end;
    $1: begin AEffect := tfxPortaUp;     AOutParam := AParam; end;
    $2: begin AEffect := tfxPortaDown;   AOutParam := AParam; end;
    $3: begin AEffect := tfxTonePorta;   AOutParam := AParam; end;
    $4: begin AEffect := tfxVibrato;     AOutParam := AParam; end;
    $5: begin AEffect := tfxTonePorta;   AOutParam := 0; end;   // + volslide: lost
    $6: begin AEffect := tfxVibrato;     AOutParam := 0; end;    // + volslide: lost
    $7: begin AEffect := tfxTremolo;     AOutParam := AParam; end;
    $8: begin AEffect := tfxSetPanning;  AOutParam := AParam; end;
    $9: begin AEffect := tfxSampleOffset; AOutParam := AParam; end;
    $A: begin AEffect := tfxVolSlide;    AOutParam := AParam; end;
    $B: begin AEffect := tfxPositionJump; AOutParam := AParam; end;
    $C: begin AEffect := tfxSetVolume;   AOutParam := Byte(ClampInt(AParam, 0, TRK_VOL_MAX)); end;
    $D: begin
          AEffect := tfxPatternBreak;
          { MOD stores the break row in BCD }
          AOutParam := Byte(ClampInt((AParam shr 4) * 10 + (AParam and $0F), 0, MOD_ROWS - 1));
        end;
    $E:
      begin
        sub := AParam shr 4;
        lo := AParam and $0F;
        case sub of
          $1: begin AEffect := tfxPortaUp;     AOutParam := lo; end;   // fine porta up
          $2: begin AEffect := tfxPortaDown;   AOutParam := lo; end;   // fine porta down
          $8: begin AEffect := tfxSetPanning;  AOutParam := Byte(lo * 17); end;
          $9: begin AEffect := tfxRetrigger;   AOutParam := lo; end;
          $A: begin AEffect := tfxFineVolUp;   AOutParam := lo; end;
          $B: begin AEffect := tfxFineVolDown; AOutParam := lo; end;
          $C: begin AEffect := tfxNoteCut;     AOutParam := lo; end;
          $D: begin AEffect := tfxNoteDelay;   AOutParam := lo; end;
          $4: begin AEffect := tfxVibratoWaveform; AOutParam := lo; end;
          $7: begin AEffect := tfxTremoloWaveform; AOutParam := lo; end;
        else
          { E0 filter, E3 glissando, E5 finetune (baked in), E6 pattern loop,
            EE pattern delay, EF invert loop }
          Result := False;
        end;
      end;
    $F:
      if AParam = 0 then Result := False
      else begin AEffect := tfxSetSpeed; AOutParam := AParam; end;  // <$20 speed, >=$20 BPM
  else
    Result := False;
  end;
end;

{ UDAW internal effect -> MOD command nibble + parameter. Returns False when
  the effect cannot be represented in MOD. }
function MapUdawEffect(AEffect: TTrackerEffect; AParam: Byte;
  out ACmd, AOutParam: Byte): Boolean;
begin
  ACmd := 0;
  AOutParam := 0;
  Result := True;
  case AEffect of
    tfxNone:         Result := False;
    tfxArpeggio:     begin ACmd := $0; AOutParam := AParam; end;
    tfxPortaUp:      begin ACmd := $1; AOutParam := AParam; end;
    tfxPortaDown:    begin ACmd := $2; AOutParam := AParam; end;
    tfxTonePorta:    begin ACmd := $3; AOutParam := AParam; end;
    tfxVibrato:      begin ACmd := $4; AOutParam := AParam; end;
    tfxTremolo:      begin ACmd := $7; AOutParam := AParam; end;
    tfxVolSlide:     begin ACmd := $A; AOutParam := AParam; end;
    tfxSetVolume:    begin ACmd := $C; AOutParam := Byte(ClampInt(AParam, 0, TRK_VOL_MAX)); end;
    tfxSampleOffset: begin ACmd := $9; AOutParam := AParam; end;
    tfxPositionJump: begin ACmd := $B; AOutParam := AParam; end;
    tfxPatternBreak:
      begin
        ACmd := $D;
        AOutParam := Byte(((AParam div 10) shl 4) or (AParam mod 10));  // -> BCD
      end;
    tfxSetSpeed:     begin ACmd := $F; AOutParam := AParam; end;
    tfxSetBPM:
      begin
        ACmd := $F;
        AOutParam := Byte(Max(Integer($20), Integer(AParam)));  // force the tempo range
      end;
    tfxSetPanning:   begin ACmd := $8; AOutParam := AParam; end;
    tfxRetrigger:    begin ACmd := $E; AOutParam := Byte($90 or (AParam and $0F)); end;
    tfxFineVolUp:    begin ACmd := $E; AOutParam := Byte($A0 or (AParam and $0F)); end;
    tfxFineVolDown:  begin ACmd := $E; AOutParam := Byte($B0 or (AParam and $0F)); end;
    tfxNoteCut:      begin ACmd := $E; AOutParam := Byte($C0 or (AParam and $0F)); end;
    tfxNoteDelay:    begin ACmd := $E; AOutParam := Byte($D0 or (AParam and $0F)); end;
    tfxVibratoWaveform: begin ACmd := $E; AOutParam := Byte($40 or (AParam and $0F)); end;
    tfxTremoloWaveform: begin ACmd := $E; AOutParam := Byte($70 or (AParam and $0F)); end;
  else
    { tfxPanSlide has no single-command MOD equivalent }
    Result := False;
  end;
end;

{ ================= byte helpers ================= }

function BEWord(const D: TBytes; AOfs: Integer): Integer; inline;
begin
  Result := (D[AOfs] shl 8) or D[AOfs + 1];
end;

function CleanText(const D: TBytes; AOfs, ALen: Integer): string;
var
  i: Integer;
  c: Byte;
  sb: TStringBuilder;
begin
  sb := TStringBuilder.Create;
  try
    for i := AOfs to AOfs + ALen - 1 do
    begin
      if i >= Length(D) then Break;
      c := D[i];
      if c = 0 then Break;
      if (c >= 32) and (c < 127) then sb.Append(Chr(c))
      else sb.Append(' ');
    end;
    Result := TrimRight(sb.ToString);
  finally
    sb.Free;
  end;
end;

function TagChannels(const ATag: string): Integer;
var
  n: Integer;
begin
  if (ATag = 'M.K.') or (ATag = 'M!K!') or (ATag = 'M&K!')
     or (ATag = 'FLT4') or (ATag = '4CHN') or (ATag = 'NSMS') then Exit(4);
  if (ATag = 'FLT8') or (ATag = 'OCTA') or (ATag = 'OKTA')
     or (ATag = 'CD81') or (ATag = '8CHN') then Exit(8);
  if ATag = '6CHN' then Exit(6);
  { generic "nnCH" }
  if (Length(ATag) = 4) and (ATag[3] = 'C') and (ATag[4] = 'H')
     and CharInSet(ATag[1], ['0'..'9']) and CharInSet(ATag[2], ['0'..'9']) then
  begin
    n := (Ord(ATag[1]) - Ord('0')) * 10 + (Ord(ATag[2]) - Ord('0'));
    if (n >= 1) and (n <= MOD_MAX_CHANNELS) then Exit(n);
  end;
  { generic "nCHN" }
  if (Length(ATag) = 4) and (ATag[2] = 'C') and (ATag[3] = 'H') and (ATag[4] = 'N')
     and CharInSet(ATag[1], ['1'..'9']) then
    Exit(Ord(ATag[1]) - Ord('0'));
  Result := 0;
end;

function ChannelsToTag(AChannels: Integer): AnsiString;
begin
  if AChannels = 4 then Exit('M.K.');
  if (AChannels >= 2) and (AChannels <= 9) then
    Exit(AnsiString(IntToStr(AChannels) + 'CHN'));
  Exit(AnsiString(Format('%.2dCH', [ClampInt(AChannels, 10, MOD_MAX_CHANNELS)])));
end;

{ ================= TModImportInfo ================= }

function TModImportInfo.Summary: string;
const
  KIND_NAMES: array[TModKind] of string = ('not a MOD', '15-sample Soundtracker', '31-sample');
begin
  Result := Format(
    '%s  tag=%s  "%s"'#10 +
    '%d channels, %d/%d samples used, %d patterns, %d orders (restart @ %d)'#10 +
    '%d cells: %d notes, %d effects (%d dropped, no internal equivalent)%s',
    [KIND_NAMES[Kind], Tag, Title, Channels, UsedSamples, SampleCount, PatternCount,
     OrderLength, RestartPos, TotalCells, NoteCells, EffectCells, LostEffectCells,
     IfThen(Truncated, #10'NOTE: file data ran short and was zero-padded', '')]);
end;

{ ================= layout ================= }

type
  TModLayout = record
    Kind: TModKind;
    Samples: Integer;         // 15 or 31
    SongLenOfs: Integer;
    RestartOfs: Integer;
    OrderOfs: Integer;
    PatternOfs: Integer;
    Channels: Integer;
    Tag: string;
  end;

function DetectLayout(const D: TBytes): TModLayout;
var
  tag: string;
  ch, i, sl: Integer;
  ok15: Boolean;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Kind := mkNone;

  { 31-sample: a recognised 4-char tag at offset 1080 }
  if Length(D) >= 1084 then
  begin
    tag := CleanText(D, 1080, 4);
    if Length(tag) < 4 then tag := '';
    ch := TagChannels(tag);
    if ch > 0 then
    begin
      Result.Kind := mk31;
      Result.Samples := 31;
      Result.SongLenOfs := 950;
      Result.RestartOfs := 951;
      Result.OrderOfs := 952;
      Result.PatternOfs := 1084;
      Result.Channels := ch;
      Result.Tag := tag;
      Exit;
    end;
  end;

  { 15-sample Soundtracker: no tag. Sanity-check the song length + a plausible
    order table before committing. }
  if Length(D) >= 600 + MOD_ROWS * 4 * 4 then
  begin
    sl := D[470];
    ok15 := (sl >= 1) and (sl <= MOD_MAX_ORDERS) and (D[471] <= 127);
    if ok15 then
      for i := 0 to sl - 1 do
        if D[472 + i] >= MOD_MAX_PATTERNS then
        begin
          ok15 := False;
          Break;
        end;
    if ok15 then
    begin
      Result.Kind := mk15;
      Result.Samples := 15;
      Result.SongLenOfs := 470;
      Result.RestartOfs := 471;
      Result.OrderOfs := 472;
      Result.PatternOfs := 600;
      Result.Channels := 4;
      Result.Tag := '';
    end;
  end;
end;

{ ================= sniffing ================= }

function ModKindFromData(const AData: TBytes): TModKind;
begin
  Result := DetectLayout(AData).Kind;
end;

function DataLooksLikeMod(const AData: TBytes): Boolean;
begin
  Result := DetectLayout(AData).Kind <> mkNone;
end;

function FileLooksLikeMod(const AFileName: string): Boolean;
var
  fs: TFileStream;
  buf: TBytes;
  n: Int64;
begin
  Result := False;
  if not FileExists(AFileName) then Exit;
  fs := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
  try
    n := Min(fs.Size, Int64(1 * 1024 * 1024));
    if n < 600 then Exit;
    SetLength(buf, n);
    fs.ReadBuffer(buf[0], n);
  finally
    fs.Free;
  end;
  Result := DataLooksLikeMod(buf);
end;

{ ================= import ================= }

function ModToModule(const AData: TBytes; out AInfo: TModImportInfo): TTrackerModule;
var
  L: TModLayout;
  m: TTrackerModule;
  sampLen, sampLoopStart, sampLoopLen, sampVol, sampFT: array[1..31] of Integer;
  i, s, songLen, restart, maxPat, numPat, rowBytes, patBase, ci, r, p: Integer;
  ord: array[0..MOD_MAX_ORDERS - 1] of Integer;
  hdrOfs, dataOfs, avail, want, si: Integer;
  ins: TTrackerInstrument;
  pcm: TAudioSampleArray;
  pat: TTrackerPattern;
  b0, b1, b2, b3, cmd, prm: Byte;
  period, smp, noteIdx: Integer;
  eff: TTrackerEffect;
  op: Byte;
  cell: TTrackerCell;
begin
  FillChar(AInfo, SizeOf(AInfo), 0);
  if Length(AData) > MOD_MAX_FILE then
    RaiseUDAWFmt(errConfig, MOD_SUBSYS, 'MOD file too large (%d bytes)', [Length(AData)]);

  L := DetectLayout(AData);
  if L.Kind = mkNone then
    RaiseUDAW(errConfig, MOD_SUBSYS, 'not a recognisable ProTracker / Soundtracker MOD');

  AInfo.Kind := L.Kind;
  AInfo.Tag := L.Tag;
  AInfo.Title := CleanText(AData, 0, 20);
  AInfo.Channels := ClampInt(L.Channels, TRK_MIN_CHANNELS, MOD_MAX_CHANNELS);
  AInfo.SampleCount := L.Samples;

  { --- sample headers (30 bytes each, from offset 20) --- }
  for s := 1 to L.Samples do
  begin
    hdrOfs := 20 + (s - 1) * 30;
    if hdrOfs + 30 > Length(AData) then
      RaiseUDAW(errConfig, MOD_SUBSYS, 'MOD truncated inside the sample headers');
    sampLen[s]       := BEWord(AData, hdrOfs + 22) * 2;
    sampFT[s]        := ModFinetuneSigned(AData[hdrOfs + 24]);
    sampVol[s]       := ClampInt(AData[hdrOfs + 25], 0, 64);
    sampLoopStart[s] := BEWord(AData, hdrOfs + 26) * 2;
    sampLoopLen[s]   := BEWord(AData, hdrOfs + 28) * 2;
    if sampLen[s] > MOD_MAX_SAMPLE_BYTES then sampLen[s] := MOD_MAX_SAMPLE_BYTES;
  end;

  songLen := ClampInt(AData[L.SongLenOfs], 1, MOD_MAX_ORDERS);
  restart := AData[L.RestartOfs];
  if restart >= songLen then restart := 0;

  maxPat := 0;
  for i := 0 to MOD_MAX_ORDERS - 1 do
  begin
    ord[i] := AData[L.OrderOfs + i];
    if (i < songLen) and (ord[i] > maxPat) then maxPat := ord[i];
  end;
  numPat := ClampInt(maxPat + 1, 1, MOD_MAX_PATTERNS);

  rowBytes := AInfo.Channels * 4;
  patBase := L.PatternOfs;

  { clamp the pattern count to what the file actually carries }
  avail := Length(AData) - patBase;
  if avail < rowBytes * MOD_ROWS then
    RaiseUDAW(errConfig, MOD_SUBSYS, 'MOD has no complete pattern data');
  if numPat * rowBytes * MOD_ROWS > avail then
  begin
    numPat := avail div (rowBytes * MOD_ROWS);
    AInfo.Truncated := True;
    if numPat < 1 then
      RaiseUDAW(errConfig, MOD_SUBSYS, 'MOD pattern data is unusably short');
  end;

  m := TTrackerModule.Create;
  try
    m.Clear;
    m.Name := AInfo.Title;
    if m.Name = '' then m.Name := 'Imported MOD';
    m.SetChannels(AInfo.Channels);
    m.InitialSpeed := MOD_DEFAULT_SPEED;
    m.InitialBPM := MOD_DEFAULT_BPM;
    m.GlobalVolume := 1.0;

    { --- instruments (one slot per MOD sample, so ids line up 1:1) --- }
    dataOfs := patBase + numPat * rowBytes * MOD_ROWS;
    for s := 1 to L.Samples do
    begin
      ins := m.AddInstrument(CleanText(AData, 20 + (s - 1) * 30, 22));
      if ins.Name = '' then ins.Name := Format('Sample %d', [s]);
      ins.RootNote := Byte(MOD_NOTE_BASE + MOD_REF_INDEX);   // reference note
      ins.SampleRate := Round(MOD_C3_RATE * Power(2.0, sampFT[s] / 96.0));
      ins.Volume := sampVol[s] / 64.0;
      ins.Pan := 0.0;

      if sampLen[s] > 0 then
      begin
        want := sampLen[s];
        if dataOfs + want > Length(AData) then
        begin
          want := Max(0, Length(AData) - dataOfs);
          AInfo.Truncated := True;
        end;
        SetLength(pcm, sampLen[s]);
        for i := 0 to sampLen[s] - 1 do
          if i < want then
            pcm[i] := ShortInt(AData[dataOfs + i]) / 128.0
          else
            pcm[i] := 0;
        ins.SetData(pcm, ins.SampleRate);
        Inc(AInfo.UsedSamples);

        if sampLoopLen[s] > 2 then
        begin
          ins.LoopMode := tlmForward;
          ins.LoopStart := ClampInt(sampLoopStart[s], 0, sampLen[s]);
          ins.LoopEnd := ClampInt(sampLoopStart[s] + sampLoopLen[s], ins.LoopStart + 1, sampLen[s]);
        end
        else
          ins.LoopMode := tlmOff;

        Inc(dataOfs, sampLen[s]);
      end;
    end;

    { --- patterns --- }
    for p := 0 to numPat - 1 do
    begin
      pat := m.AddPattern(MOD_ROWS);
      for r := 0 to MOD_ROWS - 1 do
        for ci := 0 to AInfo.Channels - 1 do
        begin
          si := patBase + (p * MOD_ROWS + r) * rowBytes + ci * 4;
          b0 := AData[si]; b1 := AData[si + 1]; b2 := AData[si + 2]; b3 := AData[si + 3];
          smp := (b0 and $F0) or (b2 shr 4);
          period := ((b0 and $0F) shl 8) or b1;
          cmd := b2 and $0F;
          prm := b3;

          cell := TTrackerCell.Empty;
          Inc(AInfo.TotalCells);

          if smp > 0 then
            cell.Instrument := Byte(ClampInt(smp, 0, L.Samples));

          if period > 0 then
          begin
            if (smp >= 1) and (smp <= 31) then
              noteIdx := ModPeriodToNoteIndex(period, sampFT[smp])
            else
              noteIdx := ModPeriodToNoteIndex(period, 0);
            if noteIdx >= 0 then
            begin
              cell.Note := Byte(MOD_NOTE_BASE + noteIdx);
              Inc(AInfo.NoteCells);
            end;
          end;

          if (cmd <> 0) or (prm <> 0) then
          begin
            Inc(AInfo.EffectCells);
            if MapModEffect(cmd, prm, eff, op) then
            begin
              cell.Effect := eff;
              cell.Param := op;
            end
            else
              Inc(AInfo.LostEffectCells);
          end;

          pat.SetCell(r, ci, cell);
        end;
    end;

    for i := 0 to songLen - 1 do
      m.AppendOrder(ClampInt(ord[i], 0, numPat - 1));
    if m.OrderLength = 0 then m.AppendOrder(0);
    m.RestartPos := ClampInt(restart, 0, m.OrderLength - 1);

    AInfo.PatternCount := m.PatternCount;
    AInfo.OrderLength := m.OrderLength;
    AInfo.RestartPos := m.RestartPos;

    Result := m;
    m := nil;
  finally
    m.Free;
  end;
end;

function ModToModule(const AData: TBytes): TTrackerModule;
var
  info: TModImportInfo;
begin
  Result := ModToModule(AData, info);
end;

function LoadModFile(const AFileName: string; out AInfo: TModImportInfo): TTrackerModule;
var
  fs: TFileStream;
  buf: TBytes;
begin
  if not FileExists(AFileName) then
    RaiseUDAWFmt(errFileNotFound, MOD_SUBSYS, 'MOD file not found: %s', [AFileName]);
  fs := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
  try
    if fs.Size > MOD_MAX_FILE then
      RaiseUDAWFmt(errConfig, MOD_SUBSYS, 'MOD file too large: %s', [AFileName]);
    SetLength(buf, fs.Size);
    if Length(buf) > 0 then fs.ReadBuffer(buf[0], Length(buf));
  finally
    fs.Free;
  end;
  Result := ModToModule(buf, AInfo);
end;

function LoadModFile(const AFileName: string): TTrackerModule;
var
  info: TModImportInfo;
begin
  Result := LoadModFile(AFileName, info);
end;

{ ================= export ================= }

function ModExportIssues(AModule: TTrackerModule): TArray<string>;
var
  list: TStringList;
  pi, r, c, lost, badNote: Integer;
  pat: TTrackerPattern;
  cell: TTrackerCell;
  cmd, op: Byte;
begin
  list := TStringList.Create;
  try
    if AModule.Channels > MOD_MAX_CHANNELS then
      list.Add(Format('%d channels: MOD tops out at %d; extra channels are dropped',
        [AModule.Channels, MOD_MAX_CHANNELS]));
    if AModule.InstrumentCount > 31 then
      list.Add(Format('%d instruments: MOD stores 31; instruments 32+ are dropped',
        [AModule.InstrumentCount]));
    if AModule.PatternCount > MOD_MAX_PATTERNS then
      list.Add(Format('%d patterns: MOD stores %d; the rest are dropped',
        [AModule.PatternCount, MOD_MAX_PATTERNS]));
    if AModule.OrderLength > MOD_MAX_ORDERS then
      list.Add(Format('%d order entries: MOD stores %d; the rest are dropped',
        [AModule.OrderLength, MOD_MAX_ORDERS]));

    lost := 0;
    badNote := 0;
    for pi := 0 to AModule.PatternCount - 1 do
    begin
      pat := AModule.GetPattern(pi);
      if pat = nil then Continue;
      if pat.Rows <> MOD_ROWS then
        list.Add(Format('pattern %d has %d rows: MOD patterns are always %d (padded / truncated)',
          [pi, pat.Rows, MOD_ROWS]));
      for r := 0 to pat.Rows - 1 do
        for c := 0 to pat.Channels - 1 do
        begin
          cell := pat.GetCell(r, c);
          if (cell.Note >= TRK_NOTE_MIN) and (cell.Note <= TRK_NOTE_MAX) then
            if (cell.Note < MOD_NOTE_BASE) or (cell.Note >= MOD_NOTE_BASE + MOD_NOTES) then
              Inc(badNote);
          if (cell.Effect <> tfxNone) or (cell.Param <> 0) then
            if not MapUdawEffect(cell.Effect, cell.Param, cmd, op) then
              Inc(lost);
        end;
    end;
    if badNote > 0 then
      list.Add(Format('%d note(s) outside MOD''s 3-octave range (C-3..B-5) are clamped', [badNote]));
    if lost > 0 then
      list.Add(Format('%d effect command(s) have no MOD equivalent and are dropped', [lost]));

    for r := 0 to AModule.InstrumentCount - 1 do
      if r < 31 then
      begin
        if AModule.GetInstrument(r + 1).FrameCount > MOD_MAX_SAMPLE_BYTES then
        begin
          list.Add(Format('instrument %d sample is longer than %d bytes and is truncated',
            [r + 1, MOD_MAX_SAMPLE_BYTES]));
          Break;
        end;
      end;

    Result := list.ToStringArray;
  finally
    list.Free;
  end;
end;

procedure WriteSampleHeader(var buf: TBytes; AOfs: Integer; AInstr: TTrackerInstrument;
  out ADataBytes: Integer; out AFinetune: Integer);
var
  nm: RawByteString;
  i, lenBytes, loopStartWords, loopLenWords, vol: Integer;
begin
  { name (22) }
  if AInstr <> nil then
    nm := RawByteString(AInstr.Name)
  else
    nm := '';
  for i := 0 to 21 do
    if i < Length(nm) then buf[AOfs + i] := Byte(nm[i + 1]) else buf[AOfs + i] := 0;

  if AInstr = nil then
  begin
    { empty slot }
    FillChar(buf[AOfs + 22], 8, 0);
    buf[AOfs + 29] := 1;   { loop length word = 1 -> "no loop" }
    ADataBytes := 0;
    AFinetune := 0;
    Exit;
  end;

  AFinetune := FinetuneForRate(AInstr.SampleRate);
  lenBytes := AInstr.FrameCount;
  if lenBytes > MOD_MAX_SAMPLE_BYTES then lenBytes := MOD_MAX_SAMPLE_BYTES;
  lenBytes := lenBytes and not 1;   { MOD lengths are whole words }
  ADataBytes := lenBytes;

  buf[AOfs + 22] := (lenBytes div 2) shr 8;
  buf[AOfs + 23] := (lenBytes div 2) and $FF;
  buf[AOfs + 24] := Byte(AFinetune and $0F);
  vol := ClampInt(Round(AInstr.Volume * 64.0), 0, 64);
  buf[AOfs + 25] := Byte(vol);

  if (AInstr.LoopMode <> tlmOff) and (AInstr.LoopEnd > AInstr.LoopStart) then
  begin
    loopStartWords := ClampInt(AInstr.LoopStart, 0, lenBytes) div 2;
    loopLenWords := ClampInt(AInstr.LoopEnd - AInstr.LoopStart, 2, lenBytes) div 2;
    if loopLenWords < 1 then loopLenWords := 1;
  end
  else
  begin
    loopStartWords := 0;
    loopLenWords := 1;
  end;
  buf[AOfs + 26] := loopStartWords shr 8;
  buf[AOfs + 27] := loopStartWords and $FF;
  buf[AOfs + 28] := loopLenWords shr 8;
  buf[AOfs + 29] := loopLenWords and $FF;
end;

function ModuleToMod(AModule: TTrackerModule): TBytes;
var
  channels, numPat, orderLen, i, s, pi, r, c, restart: Integer;
  hdr, patBytes, sampBytes: TBytes;
  dataBytes: array[1..31] of Integer;
  finetune: array[1..31] of Integer;
  tag: AnsiString;
  pat: TTrackerPattern;
  cell: TTrackerCell;
  smp, noteIdx, period: Integer;
  cmd, op, b0, b1, b2, b3: Byte;
  ins: TTrackerInstrument;
  outStream: TBytesStream;
  pp, si: Integer;
  fval: Single;
  iv: Integer;
begin
  channels := ClampInt(AModule.Channels, 1, MOD_MAX_CHANNELS);
  orderLen := ClampInt(AModule.OrderLength, 1, MOD_MAX_ORDERS);

  numPat := 1;
  for i := 0 to orderLen - 1 do
    if AModule.GetOrder(i) + 1 > numPat then numPat := AModule.GetOrder(i) + 1;
  numPat := ClampInt(numPat, 1, MOD_MAX_PATTERNS);
  if numPat > AModule.PatternCount then numPat := AModule.PatternCount;

  restart := AModule.RestartPos;
  if (restart < 0) or (restart >= orderLen) then restart := 0;

  { --- header: 20 title + 31*30 sample headers + 1 songlen + 1 restart
        + 128 order + 4 tag = 1084 bytes --- }
  SetLength(hdr, 1084);
  FillChar(hdr[0], Length(hdr), 0);
  tag := AnsiString(AModule.Name);
  for i := 0 to 19 do
    if i < Length(tag) then hdr[i] := Byte(tag[i + 1]) else hdr[i] := 0;

  for s := 1 to 31 do
  begin
    if s <= AModule.InstrumentCount then
      ins := AModule.GetInstrument(s)
    else
      ins := nil;
    WriteSampleHeader(hdr, 20 + (s - 1) * 30, ins, dataBytes[s], finetune[s]);
  end;

  hdr[950] := Byte(orderLen);
  hdr[951] := Byte(ClampInt(restart, 0, 127));
  for i := 0 to MOD_MAX_ORDERS - 1 do
    if i < orderLen then
      hdr[952 + i] := Byte(ClampInt(AModule.GetOrder(i), 0, numPat - 1))
    else
      hdr[952 + i] := 0;

  tag := ChannelsToTag(channels);
  for i := 0 to 3 do
    hdr[1080 + i] := Byte(tag[i + 1]);

  { --- pattern data --- }
  SetLength(patBytes, numPat * MOD_ROWS * channels * 4);
  FillChar(patBytes[0], Length(patBytes), 0);
  for pi := 0 to numPat - 1 do
  begin
    pat := AModule.GetPattern(pi);
    for r := 0 to MOD_ROWS - 1 do
      for c := 0 to channels - 1 do
      begin
        pp := ((pi * MOD_ROWS + r) * channels + c) * 4;
        b0 := 0; b1 := 0; b2 := 0; b3 := 0;
        if (pat <> nil) and (r < pat.Rows) and (c < pat.Channels) then
        begin
          cell := pat.GetCell(r, c);
          smp := 0;
          if (cell.Instrument >= 1) and (cell.Instrument <= 31)
             and (cell.Instrument <= AModule.InstrumentCount) then
            smp := cell.Instrument;

          period := 0;
          if (cell.Note >= TRK_NOTE_MIN) and (cell.Note <= TRK_NOTE_MAX) then
          begin
            noteIdx := ClampInt(cell.Note - MOD_NOTE_BASE, 0, MOD_NOTES - 1);
            if (smp >= 1) and (smp <= 31) then
              period := Round(ModNotePeriod(noteIdx, finetune[smp]))
            else
              period := Round(ModNotePeriod(noteIdx, 0));
          end;

          cmd := 0; op := 0;
          if (cell.Effect <> tfxNone) or (cell.Param <> 0) then
            if not MapUdawEffect(cell.Effect, cell.Param, cmd, op) then
            begin
              cmd := 0; op := 0;
            end;

          b0 := (smp and $F0) or ((period shr 8) and $0F);
          b1 := period and $FF;
          b2 := ((smp and $0F) shl 4) or (cmd and $0F);
          b3 := op;
        end;
        patBytes[pp] := b0;
        patBytes[pp + 1] := b1;
        patBytes[pp + 2] := b2;
        patBytes[pp + 3] := b3;
      end;
  end;

  { --- sample PCM (8-bit signed) --- }
  outStream := TBytesStream.Create;
  try
    outStream.WriteBuffer(hdr[0], Length(hdr));
    outStream.WriteBuffer(patBytes[0], Length(patBytes));
    for s := 1 to 31 do
    begin
      if dataBytes[s] <= 0 then Continue;
      ins := AModule.GetInstrument(s);
      SetLength(sampBytes, dataBytes[s]);
      for si := 0 to dataBytes[s] - 1 do
      begin
        if si < ins.FrameCount then fval := ins.Data[si] else fval := 0;
        iv := Round(Max(-1.0, Min(1.0, Double(fval))) * 127.0);
        if iv > 127 then iv := 127 else if iv < -128 then iv := -128;
        sampBytes[si] := Byte(iv and $FF);
      end;
      outStream.WriteBuffer(sampBytes[0], Length(sampBytes));
    end;
    Result := Copy(outStream.Bytes, 0, outStream.Size);
  finally
    outStream.Free;
  end;
end;

procedure SaveModFile(const AFileName: string; AModule: TTrackerModule);
var
  bytes: TBytes;
  fs: TFileStream;
begin
  bytes := ModuleToMod(AModule);
  fs := TFileStream.Create(AFileName, fmCreate);
  try
    if Length(bytes) > 0 then fs.WriteBuffer(bytes[0], Length(bytes));
  finally
    fs.Free;
  end;
end;

end.
