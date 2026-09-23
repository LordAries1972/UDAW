unit UDAW.Codec.XM;
{$I udaw.inc}

{ Phase 13 - XM support: a from-scratch FastTracker 2 Extended Module reader
  and writer that map onto the Phase 11 tracker engine (TTrackerModule /
  TTrackerPlayer). The plan forbids a third-party module library (no OpenMPT);
  every byte here is parsed and emitted by hand with strict bounds checking -
  an unknown or truncated field is clamped or reported, never allowed to
  corrupt memory.

    XmToModule    .XM bytes        -> TTrackerModule   (import / play / edit)
    ModuleToXm    TTrackerModule   -> .XM bytes        (export, v1.04)
    XmExportIssues                  - what a module loses on the way to XM
    XmKindFromData / FileLooksLikeXm / DataLooksLikeXm
                                    - header sniffing, never the file extension
    LoadXmFile / SaveXmFile         - one-shot file helpers

  Import covers:
    * the "Extended Module: " v1.02 / v1.03 / v1.04 layouts
    * up to 32 channels, 256 patterns, 128 instruments
    * the FT2 packed pattern format (bit-7 mask bytes + literal rows)
    * per-instrument sample keymap, volume / panning envelopes (with sustain
      and loop points), volume fade-out and vibrato depth
    * per-sample volume, finetune, relative note, panning, forward / ping-pong
      loops, 8-bit and 16-bit delta-encoded PCM
    * the FT2 effect column incl. the Exy extended set and the volume column,
      mapped onto UDAW's internal effect set; commands with no internal
      equivalent are counted in the import report rather than guessed at

  Pitch: relative note + finetune are baked into each instrument's root note
  and sample rate (RootNote = C-4 = 49, SampleRate = 8363 * 2^((rel +
  ft/128)/12)) so a plain equal-tempered cell note reproduces FT2 pitch - an
  XM is not flattened to plain audio clips. Only the linear frequency model is
  used (a few cents from the Amiga table, as with the MOD importer). }

interface

uses
  SysUtils, Classes, Math, StrUtils,
  UDAW.Errors,
  UDAW.Audio.Types,
  UDAW.Tracker.Types, UDAW.Tracker.Instrument, UDAW.Tracker.Pattern;

const
  XM_SUBSYS = 'XM';

  XM_MAGIC        = 'Extended Module: ';   // 17 bytes
  XM_C4_RATE      = 8363.0;                // Hz for note C-4, relnote 0, ft 0
  XM_C4_NOTE      = 49;                    // XM/internal note value of C-4
  XM_MAX_FILE     = 32 * 1024 * 1024;
  XM_MAX_CHANNELS = 32;
  XM_MAX_PATTERNS = 256;
  XM_MAX_INSTRS   = 128;
  XM_MAX_SAMPLES_PER_INSTR = 16;
  XM_MAX_ROWS     = 256;
  XM_MAX_SAMPLE_BYTES = 8 * 1024 * 1024;
  XM_KEYOFF_NOTE  = 97;                    // FT2 key-off marker in a pattern cell

type
  TXmImportInfo = record
    Title: string;
    TrackerName: string;
    Version: Integer;              // e.g. $0104
    Channels: Integer;
    PatternCount: Integer;
    InstrumentCount: Integer;      // XM instrument slots
    SampleCount: Integer;          // total samples across all instruments
    OrderLength: Integer;
    RestartPos: Integer;
    LinearFreq: Boolean;
    TotalCells: Integer;
    NoteCells: Integer;
    EffectCells: Integer;
    LostEffectCells: Integer;      // effect / volume-column commands with no internal equivalent
    Truncated: Boolean;            // pattern / sample data ran short and was padded
    function Summary: string;
  end;

{ ---- sniffing ---- }
function DataLooksLikeXm(const AData: TBytes): Boolean;
function FileLooksLikeXm(const AFileName: string): Boolean;
function XmKindFromData(const AData: TBytes): Boolean;   // alias, kept parallel to the MOD codec

{ ---- import ---- }
function XmToModule(const AData: TBytes; out AInfo: TXmImportInfo): TTrackerModule; overload;
function XmToModule(const AData: TBytes): TTrackerModule; overload;
function LoadXmFile(const AFileName: string; out AInfo: TXmImportInfo): TTrackerModule; overload;
function LoadXmFile(const AFileName: string): TTrackerModule; overload;

{ ---- export ---- }
function XmExportIssues(AModule: TTrackerModule): TArray<string>;
function ModuleToXm(AModule: TTrackerModule): TBytes;
procedure SaveXmFile(const AFileName: string; AModule: TTrackerModule);

{ ---- note / rate helpers (exposed for the tests) ---- }
function XmSampleRate(ARelativeNote, AFinetune: Integer): Integer;

implementation

{ ================= byte helpers ================= }

function RdWord(const D: TBytes; AOfs: Integer): Integer; inline;
begin
  Result := D[AOfs] or (D[AOfs + 1] shl 8);
end;

function RdDWord(const D: TBytes; AOfs: Integer): Cardinal; inline;
begin
  Result := Cardinal(D[AOfs]) or (Cardinal(D[AOfs + 1]) shl 8)
         or (Cardinal(D[AOfs + 2]) shl 16) or (Cardinal(D[AOfs + 3]) shl 24);
end;

function RdShortInt(AByte: Byte): Integer; inline;
begin
  Result := AByte;
  if Result >= 128 then Dec(Result, 256);
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
      if (i < 0) or (i >= Length(D)) then Break;
      c := D[i];
      if c = 0 then Continue;
      if (c >= 32) and (c < 127) then sb.Append(Chr(c))
      else sb.Append(' ');
    end;
    Result := TrimRight(sb.ToString);
  finally
    sb.Free;
  end;
end;

function XmSampleRate(ARelativeNote, AFinetune: Integer): Integer;
begin
  { one finetune step = 1/128 semitone }
  Result := Round(XM_C4_RATE * Power(2.0, ARelativeNote / 12.0 + AFinetune / (128.0 * 12.0)));
  if Result < 1 then Result := 1;
end;

{ ================= effect mapping ================= }

{ XM command byte + parameter -> UDAW internal effect. Returns False when the
  command has no internal equivalent (it is dropped and counted). }
function MapXmEffect(ACmd, AParam: Byte; out AEffect: TTrackerEffect;
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
    $1: begin AEffect := tfxPortaUp;      AOutParam := AParam; end;
    $2: begin AEffect := tfxPortaDown;    AOutParam := AParam; end;
    $3: begin AEffect := tfxTonePorta;    AOutParam := AParam; end;
    $4: begin AEffect := tfxVibrato;      AOutParam := AParam; end;
    $5: begin AEffect := tfxTonePorta;    AOutParam := 0; end;   // + volslide: lost
    $6: begin AEffect := tfxVibrato;      AOutParam := 0; end;    // + volslide: lost
    $7: begin AEffect := tfxTremolo;      AOutParam := AParam; end;
    $8: begin AEffect := tfxSetPanning;   AOutParam := AParam; end;
    $9: begin AEffect := tfxSampleOffset; AOutParam := AParam; end;
    $A: begin AEffect := tfxVolSlide;     AOutParam := AParam; end;
    $B: begin AEffect := tfxPositionJump; AOutParam := AParam; end;
    $C: begin AEffect := tfxSetVolume;    AOutParam := Byte(ClampInt(AParam, 0, TRK_VOL_MAX)); end;
    $D: begin
          AEffect := tfxPatternBreak;
          { XM stores the break row in BCD }
          AOutParam := Byte(ClampInt((AParam shr 4) * 10 + (AParam and $0F), 0, XM_MAX_ROWS - 1));
        end;
    $E:
      begin
        sub := AParam shr 4;
        lo := AParam and $0F;
        case sub of
          $1: begin AEffect := tfxPortaUp;     AOutParam := lo; end;   // fine porta up
          $2: begin AEffect := tfxPortaDown;   AOutParam := lo; end;   // fine porta down
          $9: begin AEffect := tfxRetrigger;   AOutParam := lo; end;
          $A: begin AEffect := tfxFineVolUp;   AOutParam := lo; end;
          $B: begin AEffect := tfxFineVolDown; AOutParam := lo; end;
          $C: begin AEffect := tfxNoteCut;     AOutParam := lo; end;
          $D: begin AEffect := tfxNoteDelay;   AOutParam := lo; end;
          $4: begin AEffect := tfxVibratoWaveform; AOutParam := lo; end;
          $7: begin AEffect := tfxTremoloWaveform; AOutParam := lo; end;
        else
          { E3 glissando, E5 finetune (baked in), E6 pattern loop, EE pattern
            delay - no internal equivalent }
          Result := False;
        end;
      end;
    $F:
      if AParam = 0 then Result := False
      else begin AEffect := tfxSetSpeed; AOutParam := AParam; end;  // <$20 speed, >=$20 BPM
    $10 { G }: Result := False;                                     // set global volume
    $11 { H }: Result := False;                                     // global volume slide
    $15 { L }: Result := False;                                     // set envelope position
    { high nibble = slide right, low nibble = slide left - same nibble layout
      as Axy volume slide and as the volume-column D0-DF/E0-EF pan-slide
      codes just below, and what the player (C.PanSlideParam shr/and 4)
      expects. Previously this swapped the nibbles, so any third-party XM
      using Pxy panned in the opposite direction to FT2/OpenMPT/MilkyTracker. }
    $19 { P }: begin AEffect := tfxPanSlide;  AOutParam := AParam; end;
    $1B { R }: begin AEffect := tfxRetrigger; AOutParam := Byte(AParam and $0F); end;
    $1D { T }: Result := False;                                     // tremor
    $21 { X }:
      begin
        sub := AParam shr 4;
        lo := AParam and $0F;
        case sub of
          $1: begin AEffect := tfxPortaUp;   AOutParam := lo; end;  // extra-fine porta up
          $2: begin AEffect := tfxPortaDown; AOutParam := lo; end;  // extra-fine porta down
        else
          Result := False;
        end;
      end;
  else
    Result := False;
  end;
end;

{ FT2 volume column byte (0x10..0xFF) -> either a straight internal volume
  value (0..64, or TRK_VOL_NONE) or an effect. Returns the volume in AVol and,
  if it instead resolves to an effect, sets AEffect/AParam. ATaken says a
  non-empty column was consumed; ALost says it had no representation. }
procedure MapXmVolumeColumn(AVol: Byte; out AOutVol: Byte;
  out AEffect: TTrackerEffect; out AParam: Byte; out ATaken, ALost: Boolean);
begin
  AOutVol := TRK_VOL_NONE;
  AEffect := tfxNone;
  AParam := 0;
  ATaken := AVol <> 0;
  ALost := False;
  if AVol = 0 then Exit;
  case AVol of
    $10..$50: AOutVol := Byte(AVol - $10);                   // set volume 0..64
    $51..$5F: AOutVol := TRK_VOL_MAX;                        // 0x51..0x5F clamp to 64 (FT2 quirk)
    $60..$6F: begin AEffect := tfxVolSlide; AParam := Byte(AVol and $0F); end;          // slide down
    $70..$7F: begin AEffect := tfxVolSlide; AParam := Byte((AVol and $0F) shl 4); end;  // slide up
    $80..$8F: begin AEffect := tfxFineVolDown; AParam := Byte(AVol and $0F); end;
    $90..$9F: begin AEffect := tfxFineVolUp;   AParam := Byte(AVol and $0F); end;
    $A0..$AF: begin AEffect := tfxVibrato; AParam := Byte((AVol and $0F) shl 4); end;   // vibrato speed
    $B0..$BF: begin AEffect := tfxVibrato; AParam := Byte(AVol and $0F); end;           // vibrato depth
    $C0..$CF: begin AEffect := tfxSetPanning; AParam := Byte((AVol and $0F) * 17); end;
    $D0..$DF: begin AEffect := tfxPanSlide; AParam := Byte((AVol and $0F)); end;        // pan slide left
    $E0..$EF: begin AEffect := tfxPanSlide; AParam := Byte((AVol and $0F) shl 4); end;  // pan slide right
    $F0..$FF: begin AEffect := tfxTonePorta; AParam := Byte((AVol and $0F) shl 4); end;
  else
    ALost := True;
  end;
end;

{ UDAW internal effect -> XM command byte + parameter. Returns False when the
  effect cannot be represented in XM. }
function MapUdawToXm(AEffect: TTrackerEffect; AParam: Byte;
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
        AOutParam := Byte(((AParam div 10) shl 4) or (AParam mod 10));   // -> BCD
      end;
    tfxSetSpeed:     begin ACmd := $F; AOutParam := AParam; end;
    tfxSetBPM:       begin ACmd := $F; AOutParam := Byte(Max(Integer($20), Integer(AParam))); end;
    tfxSetPanning:   begin ACmd := $8; AOutParam := AParam; end;
    tfxPanSlide:     begin ACmd := $19; AOutParam := AParam; end;   // no nibble swap - see the import side
    tfxRetrigger:    begin ACmd := $E; AOutParam := Byte($90 or (AParam and $0F)); end;
    tfxFineVolUp:    begin ACmd := $E; AOutParam := Byte($A0 or (AParam and $0F)); end;
    tfxFineVolDown:  begin ACmd := $E; AOutParam := Byte($B0 or (AParam and $0F)); end;
    tfxNoteCut:      begin ACmd := $E; AOutParam := Byte($C0 or (AParam and $0F)); end;
    tfxNoteDelay:    begin ACmd := $E; AOutParam := Byte($D0 or (AParam and $0F)); end;
    tfxVibratoWaveform: begin ACmd := $E; AOutParam := Byte($40 or (AParam and $0F)); end;
    tfxTremoloWaveform: begin ACmd := $E; AOutParam := Byte($70 or (AParam and $0F)); end;
  else
    Result := False;
  end;
end;

{ ================= TXmImportInfo ================= }

function TXmImportInfo.Summary: string;
begin
  Result := Format(
    'XM v%d.%.2d  "%s"  (%s)'#10 +
    'tracker: %s'#10 +
    '%d channels, %d patterns, %d instruments, %d samples, %d orders (restart @ %d)'#10 +
    '%s frequency table'#10 +
    '%d cells: %d notes, %d effects (%d dropped, no internal equivalent)%s',
    [Version shr 8, Version and $FF, Title, TrackerName, TrackerName,
     Channels, PatternCount, InstrumentCount, SampleCount, OrderLength, RestartPos,
     IfThen(LinearFreq, 'linear', 'Amiga'),
     TotalCells, NoteCells, EffectCells, LostEffectCells,
     IfThen(Truncated, #10'NOTE: file data ran short and was zero-padded', '')]);
end;

{ ================= sniffing ================= }

function DataLooksLikeXm(const AData: TBytes): Boolean;
var
  i: Integer;
begin
  Result := False;
  if Length(AData) < 60 + 20 + 256 then Exit;
  for i := 0 to 16 do
    if AData[i] <> Byte(XM_MAGIC[i + 1]) then Exit;
  if AData[37] <> $1A then Exit;   // the mandatory 0x1A after the module name
  Result := True;
end;

function XmKindFromData(const AData: TBytes): Boolean;
begin
  Result := DataLooksLikeXm(AData);
end;

function FileLooksLikeXm(const AFileName: string): Boolean;
var
  fs: TFileStream;
  buf: TBytes;
  n: Int64;
begin
  Result := False;
  if not FileExists(AFileName) then Exit;
  fs := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
  try
    n := Min(fs.Size, Int64(4096));
    if n < 340 then Exit;
    SetLength(buf, n);
    fs.ReadBuffer(buf[0], n);
  finally
    fs.Free;
  end;
  Result := DataLooksLikeXm(buf);
end;

{ ================= import ================= }

type
  TXmSampleHdr = record
    LengthBytes: Cardinal;
    LoopStart: Cardinal;
    LoopLength: Cardinal;
    Volume: Integer;
    Finetune: Integer;      // signed
    Flags: Byte;
    Panning: Integer;
    RelativeNote: Integer;  // signed
    Is16Bit: Boolean;
    LoopKind: Integer;      // 0 none, 1 forward, 2 ping-pong
    Name: string;
  end;

function XmToModule(const AData: TBytes; out AInfo: TXmImportInfo): TTrackerModule;
var
  m: TTrackerModule;
  headerSize, songLen, restart, channels, numPat, numInstr: Integer;
  defTempo, defBPM, flags: Integer;
  order: array of Integer;
  ofs, i, p, r, c, k: Integer;
  patHdrLen, patRows, patPackedSize, patDataStart: Integer;
  pat: TTrackerPattern;
  cell: TTrackerCell;
  maskByte, b: Byte;
  hasNote, hasInstr, hasVol, hasFxType, hasFxParam: Boolean;
  noteB, instrB, volB, fxType, fxParam: Byte;
  eff: TTrackerEffect;
  op, ovol: Byte;
  colEff: TTrackerEffect;
  colParam: Byte;
  colTaken, colLost: Boolean;
  dp: Integer;
  { instrument locals }
  instrHdrSize, numSamples, smpHdrSize: Integer;
  instrName: string;
  volPoints, panPoints: array[0..11] of record X, Y: Integer; end;
  numVolPts, numPanPts: Integer;
  volSustain, volLoopS, volLoopE, panSustain, panLoopS, panLoopE: Integer;
  volType, panType: Integer;
  volFadeout: Integer;
  smp: array of TXmSampleHdr;
  ins: TTrackerInstrument;
  env: TTrackerEnvelope;
  keymap: array[0..95] of Byte;
  firstSampleForInstr: Boolean;
  chosenSample: Integer;
  pcm: TAudioSampleArray;
  sTotalFrames, delta16: Integer;
  cur8: ShortInt;
  cur16: SmallInt;
  n: Integer;
  totalSamplesSeen: Integer;
begin
  FillChar(AInfo, SizeOf(AInfo), 0);
  if Length(AData) > XM_MAX_FILE then
    RaiseUDAWFmt(errConfig, XM_SUBSYS, 'XM file too large (%d bytes)', [Length(AData)]);
  if not DataLooksLikeXm(AData) then
    RaiseUDAW(errConfig, XM_SUBSYS, 'not a recognisable FastTracker 2 Extended Module');

  AInfo.Title := CleanText(AData, 17, 20);
  AInfo.TrackerName := CleanText(AData, 38, 20);
  AInfo.Version := RdWord(AData, 58);

  headerSize := Integer(RdDWord(AData, 60));
  if (headerSize < 20) or (Int64(60) + headerSize + 4 > Length(AData)) then
    RaiseUDAW(errConfig, XM_SUBSYS, 'XM header size field is out of range');

  songLen := RdWord(AData, 64);
  restart := RdWord(AData, 66);
  channels := RdWord(AData, 68);
  numPat := RdWord(AData, 70);
  numInstr := RdWord(AData, 72);
  flags := RdWord(AData, 74);
  defTempo := RdWord(AData, 76);
  defBPM := RdWord(AData, 78);

  channels := ClampInt(channels, TRK_MIN_CHANNELS, XM_MAX_CHANNELS);
  songLen := ClampInt(songLen, 1, 256);
  numPat := ClampInt(numPat, 0, XM_MAX_PATTERNS);
  numInstr := ClampInt(numInstr, 0, XM_MAX_INSTRS);
  AInfo.LinearFreq := (flags and 1) <> 0;

  SetLength(order, songLen);
  for i := 0 to songLen - 1 do
    order[i] := AData[80 + i];

  m := TTrackerModule.Create;
  try
    m.Clear;
    m.Name := AInfo.Title;
    if m.Name = '' then m.Name := 'Imported XM';
    m.SetChannels(channels);
    m.InitialSpeed := ClampInt(IfThen(defTempo > 0, defTempo, TRK_DEFAULT_SPEED), TRK_MIN_SPEED, TRK_MAX_SPEED);
    m.InitialBPM := ClampInt(IfThen(defBPM > 0, defBPM, TRK_DEFAULT_BPM), TRK_MIN_BPM, TRK_MAX_BPM);
    m.GlobalVolume := 1.0;

    { --- patterns --- }
    ofs := 60 + headerSize;
    if numPat = 0 then
    begin
      m.AddPattern(TRK_DEFAULT_ROWS);
      numPat := 1;
    end;
    for p := 0 to numPat - 1 do
    begin
      if Length(AData) - ofs < 9 then
      begin
        { the file ran out before this pattern - keep the remaining slots as
          empty patterns rather than failing the whole import }
        AInfo.Truncated := True;
        m.AddPattern(TRK_DEFAULT_ROWS);
        Continue;
      end;
      patHdrLen := Integer(RdDWord(AData, ofs));
      if patHdrLen < 9 then patHdrLen := 9;
      patRows := RdWord(AData, ofs + 5);
      patPackedSize := RdWord(AData, ofs + 7);
      patRows := ClampInt(patRows, TRK_MIN_ROWS, XM_MAX_ROWS);
      patDataStart := ofs + patHdrLen;

      pat := m.AddPattern(patRows);

      if patPackedSize > 0 then
      begin
        if Int64(patDataStart) + patPackedSize > Length(AData) then
        begin
          patPackedSize := Max(0, Length(AData) - patDataStart);
          AInfo.Truncated := True;
        end;
        dp := patDataStart;
        for r := 0 to patRows - 1 do
          for c := 0 to channels - 1 do
          begin
            cell := TTrackerCell.Empty;
            noteB := 0;
            Inc(AInfo.TotalCells);
            if dp >= patDataStart + patPackedSize then
            begin
              pat.SetCell(r, c, cell);
              Continue;
            end;
            b := AData[dp]; Inc(dp);
            if (b and $80) <> 0 then
            begin
              maskByte := b;
              hasNote   := (maskByte and $01) <> 0;
              hasInstr  := (maskByte and $02) <> 0;
              hasVol    := (maskByte and $04) <> 0;
              hasFxType := (maskByte and $08) <> 0;
              hasFxParam:= (maskByte and $10) <> 0;
            end
            else
            begin
              hasNote := True; hasInstr := True; hasVol := True;
              hasFxType := True; hasFxParam := True;
              noteB := b;
            end;

            if (b and $80) <> 0 then
            begin
              if hasNote and (dp < patDataStart + patPackedSize) then begin noteB := AData[dp]; Inc(dp); end
              else noteB := 0;
            end;
            if hasInstr and (dp < patDataStart + patPackedSize) then begin instrB := AData[dp]; Inc(dp); end else instrB := 0;
            if hasVol and (dp < patDataStart + patPackedSize) then begin volB := AData[dp]; Inc(dp); end else volB := 0;
            if hasFxType and (dp < patDataStart + patPackedSize) then begin fxType := AData[dp]; Inc(dp); end else fxType := 0;
            if hasFxParam and (dp < patDataStart + patPackedSize) then begin fxParam := AData[dp]; Inc(dp); end else fxParam := 0;

            if hasNote and (noteB <> 0) then
            begin
              if noteB = XM_KEYOFF_NOTE then
                cell.Note := TRK_NOTE_OFF
              else if noteB <= TRK_NOTE_MAX then
              begin
                cell.Note := noteB;   // XM C-0 = 1 = internal C-0
                Inc(AInfo.NoteCells);
              end;
            end;
            if hasInstr and (instrB <> 0) then
              cell.Instrument := instrB;

            { volume column }
            if hasVol then
            begin
              MapXmVolumeColumn(volB, ovol, colEff, colParam, colTaken, colLost);
              if ovol <> TRK_VOL_NONE then
                cell.Volume := ovol;
              if colLost then Inc(AInfo.LostEffectCells);
            end
            else
              colEff := tfxNone;

            { effect column (takes priority over a volume-column effect) }
            if hasFxType and ((fxType <> 0) or (fxParam <> 0)) then
            begin
              Inc(AInfo.EffectCells);
              if MapXmEffect(fxType, fxParam, eff, op) then
              begin
                cell.Effect := eff;
                cell.Param := op;
              end
              else
                Inc(AInfo.LostEffectCells);
            end
            else if (colEff <> tfxNone) then
            begin
              cell.Effect := colEff;
              cell.Param := colParam;
            end;

            pat.SetCell(r, c, cell);
          end;
      end;

      ofs := patDataStart + patPackedSize;
    end;

    { --- instruments --- }
    totalSamplesSeen := 0;
    for i := 1 to numInstr do
    begin
      if Length(AData) - ofs < 4 then
      begin
        AInfo.Truncated := True;
        Break;   // no more instrument data - stop here, module is still usable
      end;
      instrHdrSize := Integer(RdDWord(AData, ofs));
      if instrHdrSize < 29 then instrHdrSize := 29;
      if Int64(ofs) + instrHdrSize > Length(AData) then
        RaiseUDAWFmt(errConfig, XM_SUBSYS, 'XM instrument %d header runs past the file', [i]);
      instrName := CleanText(AData, ofs + 4, 22);
      numSamples := RdWord(AData, ofs + 27);
      numSamples := ClampInt(numSamples, 0, XM_MAX_SAMPLES_PER_INSTR);

      FillChar(volPoints, SizeOf(volPoints), 0);
      FillChar(panPoints, SizeOf(panPoints), 0);
      numVolPts := 0; numPanPts := 0;
      volSustain := -1; volLoopS := -1; volLoopE := -1;
      panSustain := -1; panLoopS := -1; panLoopE := -1;
      volType := 0; panType := 0; volFadeout := 0;
      FillChar(keymap, SizeOf(keymap), 0);
      smpHdrSize := 40;

      if numSamples > 0 then
      begin
        if (instrHdrSize < 243) or (Int64(ofs) + 243 > Length(AData)) then
          RaiseUDAWFmt(errConfig, XM_SUBSYS,
            'XM instrument %d claims samples but its header is too small / truncated', [i]);
        { extended instrument header: 4 + 22 + 1 + 2 + 4 + ... }
        smpHdrSize := Integer(RdDWord(AData, ofs + 29));
        if smpHdrSize < 40 then smpHdrSize := 40;
        for k := 0 to 95 do
          keymap[k] := AData[ofs + 33 + k];
        for k := 0 to 11 do
        begin
          volPoints[k].X := RdWord(AData, ofs + 129 + k * 4);
          volPoints[k].Y := RdWord(AData, ofs + 129 + k * 4 + 2);
          panPoints[k].X := RdWord(AData, ofs + 177 + k * 4);
          panPoints[k].Y := RdWord(AData, ofs + 177 + k * 4 + 2);
        end;
        numVolPts := AData[ofs + 225];
        numPanPts := AData[ofs + 226];
        volSustain := AData[ofs + 227];
        volLoopS := AData[ofs + 228];
        volLoopE := AData[ofs + 229];
        panSustain := AData[ofs + 230];
        panLoopS := AData[ofs + 231];
        panLoopE := AData[ofs + 232];
        volType := AData[ofs + 233];
        panType := AData[ofs + 234];
        volFadeout := RdWord(AData, ofs + 239);
        numVolPts := ClampInt(numVolPts, 0, 12);
        numPanPts := ClampInt(numPanPts, 0, 12);
      end;

      ofs := ofs + instrHdrSize;

      { sample headers, then sample data, in order }
      SetLength(smp, numSamples);
      for k := 0 to numSamples - 1 do
      begin
        if Int64(ofs) + 40 > Length(AData) then
          RaiseUDAWFmt(errConfig, XM_SUBSYS, 'XM instrument %d: sample header %d past EOF', [i, k]);
        smp[k].LengthBytes := RdDWord(AData, ofs);
        smp[k].LoopStart   := RdDWord(AData, ofs + 4);
        smp[k].LoopLength  := RdDWord(AData, ofs + 8);
        smp[k].Volume      := AData[ofs + 12];
        smp[k].Finetune    := RdShortInt(AData[ofs + 13]);
        smp[k].Flags       := AData[ofs + 14];
        smp[k].Panning     := AData[ofs + 15];
        smp[k].RelativeNote := RdShortInt(AData[ofs + 16]);
        smp[k].Name        := CleanText(AData, ofs + 18, 22);
        smp[k].Is16Bit     := (smp[k].Flags and $10) <> 0;
        smp[k].LoopKind    := smp[k].Flags and $03;
        if smp[k].LengthBytes > XM_MAX_SAMPLE_BYTES then
          smp[k].LengthBytes := XM_MAX_SAMPLE_BYTES;
        ofs := ofs + smpHdrSize;
      end;

      { pick one sample to represent the instrument (the keymap's most common,
        falling back to sample 0) - the Phase 11 instrument model is one mono
        sample per slot; multi-sample keymaps are a documented later step. }
      chosenSample := 0;
      if numSamples > 0 then
      begin
        chosenSample := keymap[XM_C4_NOTE - 1];   // sample the C-4 key maps to
        if chosenSample >= numSamples then chosenSample := 0;
      end;

      ins := m.AddInstrument(instrName);
      if ins.Name = '' then ins.Name := Format('Instrument %d', [i]);
      ins.RootNote := XM_C4_NOTE;
      firstSampleForInstr := True;

      for k := 0 to numSamples - 1 do
      begin
        Inc(totalSamplesSeen);
        sTotalFrames := smp[k].LengthBytes;
        if smp[k].Is16Bit then sTotalFrames := sTotalFrames div 2;

        n := sTotalFrames;
        if Int64(ofs) + smp[k].LengthBytes > Length(AData) then
        begin
          n := Max(0, (Length(AData) - ofs));
          if smp[k].Is16Bit then n := n div 2;
          AInfo.Truncated := True;
        end;

        if k = chosenSample then
        begin
          SetLength(pcm, sTotalFrames);
          cur8 := 0; cur16 := 0;
          if smp[k].Is16Bit then
          begin
            for dp := 0 to sTotalFrames - 1 do
            begin
              if dp < n then
              begin
                delta16 := SmallInt(Word(AData[ofs + dp * 2]) or (Word(AData[ofs + dp * 2 + 1]) shl 8));
                cur16 := SmallInt(Word(cur16) + Word(delta16));
              end;
              pcm[dp] := cur16 / 32768.0;
            end;
          end
          else
          begin
            for dp := 0 to sTotalFrames - 1 do
            begin
              if dp < n then
                cur8 := ShortInt(Byte(cur8) + AData[ofs + dp]);
              pcm[dp] := cur8 / 128.0;
            end;
          end;

          ins.SampleRate := XmSampleRate(smp[k].RelativeNote, smp[k].Finetune);
          ins.Volume := smp[k].Volume / 64.0;
          ins.Pan := smp[k].Panning / 127.5 - 1.0;
          ins.SetData(pcm, ins.SampleRate);
          ins.Fadeout := volFadeout / 32768.0;

          if smp[k].Is16Bit then
          begin
            smp[k].LoopStart := smp[k].LoopStart div 2;
            smp[k].LoopLength := smp[k].LoopLength div 2;
          end;
          case smp[k].LoopKind of
            1:
              begin
                ins.LoopMode := tlmForward;
                ins.LoopStart := ClampInt(smp[k].LoopStart, 0, sTotalFrames);
                ins.LoopEnd := ClampInt(smp[k].LoopStart + smp[k].LoopLength, ins.LoopStart + 1, sTotalFrames);
              end;
            2:
              begin
                ins.LoopMode := tlmPingPong;
                ins.LoopStart := ClampInt(smp[k].LoopStart, 0, sTotalFrames);
                ins.LoopEnd := ClampInt(smp[k].LoopStart + smp[k].LoopLength, ins.LoopStart + 1, sTotalFrames);
              end;
          else
            ins.LoopMode := tlmOff;
          end;

          { envelopes }
          if (volType and 1) <> 0 then
          begin
            env := ins.VolEnv;
            env.Clear;
            env.Enabled := True;
            for dp := 0 to numVolPts - 1 do
              env.AddPoint(volPoints[dp].X, ClampInt(volPoints[dp].Y, 0, 64) / 64.0);
            if (volType and 2) <> 0 then env.SustainPoint := ClampInt(volSustain, 0, Max(0, numVolPts - 1))
            else env.SustainPoint := -1;
            if (volType and 4) <> 0 then
            begin
              env.LoopStart := ClampInt(volLoopS, 0, Max(0, numVolPts - 1));
              env.LoopEnd := ClampInt(volLoopE, 0, Max(0, numVolPts - 1));
            end;
            ins.VolEnv := env;
          end;
          if (panType and 1) <> 0 then
          begin
            env := ins.PanEnv;
            env.Clear;
            env.Enabled := True;
            for dp := 0 to numPanPts - 1 do
              env.AddPoint(panPoints[dp].X, ClampInt(panPoints[dp].Y, 0, 64) / 64.0);
            if (panType and 2) <> 0 then env.SustainPoint := ClampInt(panSustain, 0, Max(0, numPanPts - 1))
            else env.SustainPoint := -1;
            ins.PanEnv := env;
          end;

          firstSampleForInstr := False;
        end;

        ofs := ofs + Integer(smp[k].LengthBytes);
      end;

      if firstSampleForInstr and (numSamples = 0) then
        ; { instrument with no samples: leave it empty }
    end;

    { --- order table --- }
    for i := 0 to songLen - 1 do
      m.AppendOrder(ClampInt(order[i], 0, m.PatternCount - 1));
    if m.OrderLength = 0 then m.AppendOrder(0);
    m.RestartPos := ClampInt(restart, 0, m.OrderLength - 1);

    AInfo.Channels := m.Channels;
    AInfo.PatternCount := m.PatternCount;
    AInfo.InstrumentCount := m.InstrumentCount;
    AInfo.SampleCount := totalSamplesSeen;
    AInfo.OrderLength := m.OrderLength;
    AInfo.RestartPos := m.RestartPos;

    Result := m;
    m := nil;
  finally
    m.Free;
  end;
end;

function XmToModule(const AData: TBytes): TTrackerModule;
var
  info: TXmImportInfo;
begin
  Result := XmToModule(AData, info);
end;

function LoadXmFile(const AFileName: string; out AInfo: TXmImportInfo): TTrackerModule;
var
  fs: TFileStream;
  buf: TBytes;
begin
  if not FileExists(AFileName) then
    RaiseUDAWFmt(errFileNotFound, XM_SUBSYS, 'XM file not found: %s', [AFileName]);
  fs := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
  try
    if fs.Size > XM_MAX_FILE then
      RaiseUDAWFmt(errConfig, XM_SUBSYS, 'XM file too large: %s', [AFileName]);
    SetLength(buf, fs.Size);
    if Length(buf) > 0 then fs.ReadBuffer(buf[0], Length(buf));
  finally
    fs.Free;
  end;
  Result := XmToModule(buf, AInfo);
end;

function LoadXmFile(const AFileName: string): TTrackerModule;
var
  info: TXmImportInfo;
begin
  Result := LoadXmFile(AFileName, info);
end;

{ ================= export ================= }

function XmExportIssues(AModule: TTrackerModule): TArray<string>;
var
  list: TStringList;
  pi, r, c, lost, badNote: Integer;
  pat: TTrackerPattern;
  cell: TTrackerCell;
  cmd, op: Byte;
begin
  list := TStringList.Create;
  try
    if AModule.Channels > XM_MAX_CHANNELS then
      list.Add(Format('%d channels: XM tops out at %d; extra channels are dropped',
        [AModule.Channels, XM_MAX_CHANNELS]));
    if AModule.InstrumentCount > XM_MAX_INSTRS then
      list.Add(Format('%d instruments: XM stores %d; instruments %d+ are dropped',
        [AModule.InstrumentCount, XM_MAX_INSTRS, XM_MAX_INSTRS + 1]));
    if AModule.PatternCount > XM_MAX_PATTERNS then
      list.Add(Format('%d patterns: XM stores %d; the rest are dropped',
        [AModule.PatternCount, XM_MAX_PATTERNS]));

    lost := 0;
    badNote := 0;
    for pi := 0 to AModule.PatternCount - 1 do
    begin
      pat := AModule.GetPattern(pi);
      if pat = nil then Continue;
      if pat.Rows > XM_MAX_ROWS then
        list.Add(Format('pattern %d has %d rows: XM patterns hold at most %d (truncated)',
          [pi, pat.Rows, XM_MAX_ROWS]));
      for r := 0 to pat.Rows - 1 do
        for c := 0 to pat.Channels - 1 do
        begin
          cell := pat.GetCell(r, c);
          if (cell.Note >= TRK_NOTE_MIN) and (cell.Note <= TRK_NOTE_MAX) then
            if cell.Note > 96 then Inc(badNote);   // XM tops out at B-7 (96)
          if (cell.Effect <> tfxNone) or (cell.Param <> 0) then
            if not MapUdawToXm(cell.Effect, cell.Param, cmd, op) then
              Inc(lost);
        end;
    end;
    if badNote > 0 then
      list.Add(Format('%d note(s) above B-7 are outside XM''s range and are clamped', [badNote]));
    if lost > 0 then
      list.Add(Format('%d effect command(s) have no XM equivalent and are dropped', [lost]));

    Result := list.ToStringArray;
  finally
    list.Free;
  end;
end;

procedure PutWord(var B: TBytes; AOfs, AValue: Integer); inline;
begin
  B[AOfs] := AValue and $FF;
  B[AOfs + 1] := (AValue shr 8) and $FF;
end;

procedure PutDWord(var B: TBytes; AOfs: Integer; AValue: Cardinal); inline;
begin
  B[AOfs] := AValue and $FF;
  B[AOfs + 1] := (AValue shr 8) and $FF;
  B[AOfs + 2] := (AValue shr 16) and $FF;
  B[AOfs + 3] := (AValue shr 24) and $FF;
end;

function ModuleToXm(AModule: TTrackerModule): TBytes;
const
  HDR_EXT = 276;   // header size counted from offset 60 (20 fixed + 256 order)
var
  st: TBytesStream;
  hdr: TBytes;
  channels, numPat, numInstr, songLen, i, p, r, c: Integer;
  nm: RawByteString;
  pat: TTrackerPattern;
  cell: TTrackerCell;
  patBody: TBytes;
  noteOut, instrOut, volOut, cmdB, opB: Byte;
  instrHdr, smpHdr, smpData: TBytes;
  ins: TTrackerInstrument;
  relNote, frames, j, iv: Integer;
  prev8: ShortInt;
begin
  channels := ClampInt(AModule.Channels, TRK_MIN_CHANNELS, XM_MAX_CHANNELS);
  numPat := ClampInt(AModule.PatternCount, 1, XM_MAX_PATTERNS);
  numInstr := ClampInt(AModule.InstrumentCount, 0, XM_MAX_INSTRS);
  songLen := ClampInt(AModule.OrderLength, 1, 256);

  st := TBytesStream.Create;
  try
    { ---- 60-byte fixed header ---- }
    SetLength(hdr, 60);
    FillChar(hdr[0], Length(hdr), 0);
    for i := 1 to 17 do hdr[i - 1] := Byte(XM_MAGIC[i]);
    nm := RawByteString(AModule.Name);
    for i := 0 to 19 do
      if i < Length(nm) then hdr[17 + i] := Byte(nm[i + 1]) else hdr[17 + i] := Byte(' ');
    hdr[37] := $1A;
    nm := 'UDAW Tracker        ';
    for i := 0 to 19 do hdr[38 + i] := Byte(nm[i + 1]);
    PutWord(hdr, 58, $0104);
    st.WriteBuffer(hdr[0], 60);

    { ---- variable header (starts at offset 60) ---- }
    SetLength(hdr, HDR_EXT);
    FillChar(hdr[0], Length(hdr), 0);
    PutDWord(hdr, 0, HDR_EXT);
    PutWord(hdr, 4, songLen);
    PutWord(hdr, 6, ClampInt(AModule.RestartPos, 0, songLen - 1));
    PutWord(hdr, 8, channels);
    PutWord(hdr, 10, numPat);
    PutWord(hdr, 12, numInstr);
    PutWord(hdr, 14, 1);                 // linear frequency table
    PutWord(hdr, 16, ClampInt(AModule.InitialSpeed, 1, 31));
    PutWord(hdr, 18, ClampInt(AModule.InitialBPM, 32, 255));
    for i := 0 to songLen - 1 do
      hdr[20 + i] := Byte(ClampInt(AModule.GetOrder(i), 0, numPat - 1));
    st.WriteBuffer(hdr[0], HDR_EXT);

    { ---- patterns (emitted unpacked: literal note bytes) ---- }
    for p := 0 to numPat - 1 do
    begin
      pat := AModule.GetPattern(p);
      SetLength(patBody, 0);
      if pat <> nil then
      begin
        SetLength(patBody, ClampInt(pat.Rows, 1, XM_MAX_ROWS) * channels * 5);
        for r := 0 to ClampInt(pat.Rows, 1, XM_MAX_ROWS) - 1 do
          for c := 0 to channels - 1 do
          begin
            noteOut := 0; instrOut := 0; volOut := 0; cmdB := 0; opB := 0;
            if (c < pat.Channels) then
            begin
              cell := pat.GetCell(r, c);
              if cell.Note = TRK_NOTE_OFF then noteOut := XM_KEYOFF_NOTE
              else if (cell.Note >= TRK_NOTE_MIN) and (cell.Note <= 96) then noteOut := cell.Note
              else if cell.Note > 96 then noteOut := 96;
              instrOut := cell.Instrument;
              if cell.Volume <= TRK_VOL_MAX then volOut := Byte($10 + cell.Volume);
              if (cell.Effect <> tfxNone) or (cell.Param <> 0) then
                if not MapUdawToXm(cell.Effect, cell.Param, cmdB, opB) then
                begin cmdB := 0; opB := 0; end;
            end;
            j := ((r * channels) + c) * 5;
            patBody[j] := noteOut;
            patBody[j + 1] := instrOut;
            patBody[j + 2] := volOut;
            patBody[j + 3] := cmdB;
            patBody[j + 4] := opB;
          end;
      end;
      SetLength(hdr, 9);
      FillChar(hdr[0], 9, 0);
      PutDWord(hdr, 0, 9);
      hdr[4] := 0;
      PutWord(hdr, 5, IfThen(pat <> nil, ClampInt(pat.Rows, 1, XM_MAX_ROWS), TRK_DEFAULT_ROWS));
      PutWord(hdr, 7, Length(patBody));
      st.WriteBuffer(hdr[0], 9);
      if Length(patBody) > 0 then st.WriteBuffer(patBody[0], Length(patBody));
    end;

    { ---- instruments (one sample each) ---- }
    for i := 1 to numInstr do
    begin
      ins := AModule.GetInstrument(i);
      frames := 0;
      if ins <> nil then frames := ins.FrameCount;

      if (ins = nil) or (frames = 0) then
      begin
        { instrument with no samples: 29-byte header only }
        SetLength(instrHdr, 29);
        FillChar(instrHdr[0], 29, 0);
        PutDWord(instrHdr, 0, 29);
        if ins <> nil then
        begin
          nm := RawByteString(ins.Name);
          for j := 0 to 21 do
            if j < Length(nm) then instrHdr[4 + j] := Byte(nm[j + 1]);
        end;
        instrHdr[26] := 0;
        PutWord(instrHdr, 27, 0);
        st.WriteBuffer(instrHdr[0], 29);
        Continue;
      end;

      { extended instrument header: 263 bytes (4+22+1+2 + 234) }
      SetLength(instrHdr, 263);
      FillChar(instrHdr[0], 263, 0);
      PutDWord(instrHdr, 0, 263);
      nm := RawByteString(ins.Name);
      for j := 0 to 21 do
        if j < Length(nm) then instrHdr[4 + j] := Byte(nm[j + 1]);
      instrHdr[26] := 0;
      PutWord(instrHdr, 27, 1);              // one sample
      PutDWord(instrHdr, 29, 40);            // sample header size
      for j := 0 to 95 do instrHdr[33 + j] := 0;   // keymap -> sample 0
      { volume fade-out (offset 239 in the ext header body -> +239) }
      PutWord(instrHdr, 239, ClampInt(Round(ins.Fadeout * 32768.0), 0, 32767));
      st.WriteBuffer(instrHdr[0], 263);

      { sample header (40 bytes) }
      SetLength(smpHdr, 40);
      FillChar(smpHdr[0], 40, 0);
      PutDWord(smpHdr, 0, Cardinal(frames));               // 8-bit -> length in bytes
      if ins.LoopMode <> tlmOff then
      begin
        PutDWord(smpHdr, 4, Cardinal(ClampInt(ins.LoopStart, 0, frames)));
        PutDWord(smpHdr, 8, Cardinal(ClampInt(ins.LoopEnd - ins.LoopStart, 0, frames)));
      end;
      smpHdr[12] := ClampInt(Round(ins.Volume * 64.0), 0, 64);
      smpHdr[13] := 0;                                     // finetune (baked into rate; approx 0)
      case ins.LoopMode of
        tlmForward:  smpHdr[14] := $01;
        tlmPingPong: smpHdr[14] := $02;
      else
        smpHdr[14] := $00;
      end;
      smpHdr[15] := ClampInt(Round((ins.Pan + 1.0) * 127.5), 0, 255);
      relNote := ClampInt(ins.RootNote - XM_C4_NOTE, -96, 95);
      smpHdr[16] := Byte(relNote and $FF);
      nm := RawByteString(ins.Name);
      for j := 0 to 21 do
        if j < Length(nm) then smpHdr[18 + j] := Byte(nm[j + 1]);
      st.WriteBuffer(smpHdr[0], 40);

      { sample data: 8-bit signed delta }
      SetLength(smpData, frames);
      prev8 := 0;
      for j := 0 to frames - 1 do
      begin
        iv := Round(Max(-1.0, Min(1.0, Double(ins.Data[j]))) * 127.0);
        if iv > 127 then iv := 127 else if iv < -128 then iv := -128;
        smpData[j] := Byte((ShortInt(iv) - prev8) and $FF);
        prev8 := ShortInt(iv);
      end;
      if frames > 0 then st.WriteBuffer(smpData[0], frames);
    end;

    Result := Copy(st.Bytes, 0, st.Size);
  finally
    st.Free;
  end;
end;

procedure SaveXmFile(const AFileName: string; AModule: TTrackerModule);
var
  bytes: TBytes;
  fs: TFileStream;
begin
  bytes := ModuleToXm(AModule);
  fs := TFileStream.Create(AFileName, fmCreate);
  try
    if Length(bytes) > 0 then fs.WriteBuffer(bytes[0], Length(bytes));
  finally
    fs.Free;
  end;
end;

end.
