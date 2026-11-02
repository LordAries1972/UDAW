unit UDAW.Codec.MPTM;
{$I udaw.inc}

{ Phase 14 - MPTM support: a from-scratch reader and writer for the OpenMPT
  module format. MPTM is, on disk, the Impulse Tracker container ("IMPM")
  extended with trailing OpenMPT chunks; this unit implements a *supported
  compatibility layer* over the IT core (which is what every MPTM file carries)
  with exhaustive bounds / size / overflow validation, per the plan's
  section 16 requirements. Trailing OpenMPT extension chunks are recognised and
  reported but not interpreted - they can never steer allocation or reads.

  The plan names these components; they are provided as records / helpers over
  the Phase 11 tracker engine rather than a parallel object tree, so playback,
  editing, undo and project embedding all reuse the existing model:

    TMPTMSample / TMPTMInstrument / TMPTMPattern / TMPTMModule  - parsed views
    TMPTMReader  = MptmToModule       .MPTM/.IT bytes -> TTrackerModule
    TMPTMWriter  = ModuleToMptm       TTrackerModule  -> .MPTM bytes (IT core)

  Also:
    MptmExportIssues                  - what a module loses on the way out
    MptmKindFromData / FileLooksLikeMptm / DataLooksLikeMptm
                                      - header sniffing, never the file extension
    LoadMptmFile / SaveMptmFile       - one-shot file helpers

  Import covers:
    * the IT header, order table, and instrument / sample / pattern offset
      tables, all strictly bounds-checked
    * "instrument mode" (one TTrackerInstrument per IT instrument, backed by the
      sample its middle-C key maps to) and "sample mode" (one per IT sample)
    * the IT packed pattern format with per-channel mask / last-value memory
    * uncompressed 8-bit and 16-bit samples, signed or unsigned, optional
      delta encoding, forward / ping-pong loops; IT2.14/IT2.15-compressed
      samples are decoded via a from-scratch implementation of the IT
      variable-width delta bitstream (single or double delta, selected by
      cwtv), with the same exhaustive bounds checking as everything else -
      a malformed block length or width can never read or write out of range
    * volume / panning envelopes with sustain and loop points, volume fade-out
    * the IT effect column (A..Z incl. the Sxy special set) and volume column,
      mapped onto UDAW's internal effect set; the rest is counted, never guessed

  Pitch: each sample's C5Speed is its playback rate for note C-5, baked into the
  instrument (RootNote = C-5 = 61, SampleRate = C5Speed) so a plain cell note
  reproduces IT pitch. The linear model is used throughout. }

interface

uses
  SysUtils, Classes, Math, StrUtils,
  UDAW.Errors,
  UDAW.Audio.Types,
  UDAW.Tracker.Types, UDAW.Tracker.Instrument, UDAW.Tracker.Pattern,
  UDAW.Codec.FLAC.Decoder, UDAW.Codec.MP3, UDAW.Codec.WAV;

const
  MPTM_SUBSYS = 'MPTM';

  MPTM_MAGIC   = 'IMPM';
  MPTM_C5_NOTE = 61;                    // internal note value for C-5 (IT middle C)
  MPTM_MAX_FILE      = 64 * 1024 * 1024;
  MPTM_MAX_CHANNELS  = 64;
  MPTM_MAX_ORDERS    = 256;
  MPTM_MAX_INSTR     = 240;
  MPTM_MAX_SAMPLES   = 240;
  MPTM_MAX_PATTERNS  = 240;
  MPTM_MAX_ROWS      = 1024;
  MPTM_MAX_SAMPLE_FRAMES = 16 * 1024 * 1024;

type
  TMPTMSample = record
    Name: string;
    Is16Bit: Boolean;
    Signed: Boolean;
    BigEndian: Boolean;
    Delta: Boolean;
    Stereo: Boolean;
    Compressed: Boolean;
    HasSample: Boolean;
    LoopOn: Boolean;
    PingPong: Boolean;
    Volume: Integer;         // 0..64
    DefaultPan: Integer;     // -1 = none, else 0..64
    LengthFrames: Cardinal;
    LoopBegin: Cardinal;
    LoopEnd: Cardinal;
    C5Speed: Cardinal;
    DataPtr: Cardinal;
  end;

  TMPTMEnvPoint = record X, Y: Integer; end;

  TMPTMEnvelope = record
    Enabled: Boolean;
    HasLoop: Boolean;
    HasSustain: Boolean;
    Count: Integer;
    LoopBegin, LoopEnd, SusBegin, SusEnd: Integer;
    Points: array[0..24] of TMPTMEnvPoint;
  end;

  TMPTMInstrument = record
    Name: string;
    Fadeout: Integer;
    MiddleCSample: Integer;   // 1-based IT sample, 0 = none
    VolEnv: TMPTMEnvelope;
    PanEnv: TMPTMEnvelope;
  end;

  TMPTMImportInfo = record
    Title: string;
    Cwtv, Cmwt: Integer;
    InstrumentMode: Boolean;
    Channels: Integer;
    OrderLength: Integer;
    RestartPos: Integer;
    InstrumentCount: Integer;
    SampleCount: Integer;
    PatternCount: Integer;
    UsedSamples: Integer;
    CompressedSamples: Integer;   // IT2.14/IT2.15-compressed, decoded
    TotalCells: Integer;
    NoteCells: Integer;
    EffectCells: Integer;
    LostEffectCells: Integer;
    ExtensionBytes: Int64;        // trailing OpenMPT chunk bytes ignored
    Truncated: Boolean;
    function Summary: string;
  end;

{ ---- sniffing ---- }
function DataLooksLikeMptm(const AData: TBytes): Boolean;
function FileLooksLikeMptm(const AFileName: string): Boolean;
function MptmKindFromData(const AData: TBytes): Boolean;

{ ---- import (TMPTMReader) ---- }
{ folder that relative external-sample paths (a Samples subfolder reference) resolve against;
  set it to the module file's folder before MptmToModule }
procedure MptmSetSampleFolder(const AFolder: string);
function MptmSampleFolder: string;
function MptmToModule(const AData: TBytes; out AInfo: TMPTMImportInfo): TTrackerModule; overload;
function MptmToModule(const AData: TBytes): TTrackerModule; overload;
function LoadMptmFile(const AFileName: string; out AInfo: TMPTMImportInfo): TTrackerModule; overload;
function LoadMptmFile(const AFileName: string): TTrackerModule; overload;

{ ---- export (TMPTMWriter) ---- }
function MptmExportIssues(AModule: TTrackerModule): TArray<string>;
function ModuleToMptm(AModule: TTrackerModule): TBytes;
procedure SaveMptmFile(const AFileName: string; AModule: TTrackerModule);

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
      if (c >= 32) and (c < 127) then sb.Append(Chr(c)) else sb.Append(' ');
    end;
    Result := TrimRight(sb.ToString);
  finally
    sb.Free;
  end;
end;

{ ================= effect mapping ================= }

{ IT command index 1..26 (= A..Z) + parameter -> UDAW internal effect.
  Returns False when the command has no internal equivalent. }
function MapItEffect(ACmd, AParam: Byte; out AEffect: TTrackerEffect;
  out AOutParam: Byte): Boolean;
var
  sub, lo: Byte;
begin
  AEffect := tfxNone;
  AOutParam := 0;
  Result := True;
  case ACmd of
    1  { A speed }:        begin AEffect := tfxSetSpeed;     AOutParam := AParam; end;
    2  { B pos jump }:     begin AEffect := tfxPositionJump; AOutParam := AParam; end;
    3  { C pat break }:    begin AEffect := tfxPatternBreak; AOutParam := Byte(ClampInt(AParam, 0, MPTM_MAX_ROWS - 1)); end;
    4  { D vol slide }:    begin AEffect := tfxVolSlide;     AOutParam := AParam; end;
    5  { E porta down }:   begin AEffect := tfxPortaDown;    AOutParam := AParam; end;
    6  { F porta up }:     begin AEffect := tfxPortaUp;      AOutParam := AParam; end;
    7  { G tone porta }:   begin AEffect := tfxTonePorta;    AOutParam := AParam; end;
    8  { H vibrato }:      begin AEffect := tfxVibrato;      AOutParam := AParam; end;
    9  { I tremor }:       Result := False;
    10 { J arpeggio }:     begin AEffect := tfxArpeggio;     AOutParam := AParam; end;
    11 { K vib+volsl }:    begin AEffect := tfxVibrato;      AOutParam := 0; end;
    12 { L porta+volsl }:  begin AEffect := tfxTonePorta;    AOutParam := 0; end;
    13 { M chan vol }:     Result := False;
    14 { N chan volsl }:   Result := False;
    15 { O offset }:       begin AEffect := tfxSampleOffset; AOutParam := AParam; end;
    16 { P pan slide }:    begin AEffect := tfxPanSlide;     AOutParam := AParam; end;
    17 { Q retrig }:       begin AEffect := tfxRetrigger;    AOutParam := Byte(AParam and $0F); end;
    18 { R tremolo }:      begin AEffect := tfxTremolo;      AOutParam := AParam; end;
    19 { S special }:
      begin
        sub := AParam shr 4;
        lo := AParam and $0F;
        case sub of
          $8: begin AEffect := tfxSetPanning; AOutParam := Byte(lo * 17); end;
          $C: begin AEffect := tfxNoteCut;    AOutParam := lo; end;
          $D: begin AEffect := tfxNoteDelay;  AOutParam := lo; end;
        else
          Result := False;   // S3/S4 waveforms, S6 fine delay, SEx pattern delay, ...
        end;
      end;
    20 { T tempo }:
      if AParam >= $20 then begin AEffect := tfxSetBPM; AOutParam := AParam; end
      else Result := False;
    21 { U fine vibrato }: begin AEffect := tfxVibrato;      AOutParam := AParam; end;
    22 { V global vol }:   Result := False;
    23 { W global volsl }: Result := False;
    24 { X set pan }:      begin AEffect := tfxSetPanning;   AOutParam := AParam; end;
    25 { Y panbrello }:    Result := False;
    26 { Z MIDI macro }:   Result := False;
  else
    Result := False;
  end;
end;

{ IT volume-column byte -> a straight internal volume, or an effect. }
procedure MapItVolumeColumn(AVol: Byte; out AOutVol: Byte;
  out AEffect: TTrackerEffect; out AParam: Byte; out ALost: Boolean);
begin
  AOutVol := TRK_VOL_NONE;
  AEffect := tfxNone;
  AParam := 0;
  ALost := False;
  case AVol of
    0..64:    AOutVol := AVol;                                   // set volume
    128..192: begin AEffect := tfxSetPanning; AParam := Byte(ClampInt((AVol - 128) * 4, 0, 255)); end;
    65..74:   begin AEffect := tfxFineVolUp;   AParam := Byte(AVol - 65); end;
    75..84:   begin AEffect := tfxFineVolDown; AParam := Byte(AVol - 75); end;
    85..94:   begin AEffect := tfxVolSlide;    AParam := Byte((AVol - 85) shl 4); end;
    95..104:  begin AEffect := tfxVolSlide;    AParam := Byte(AVol - 95); end;
    193..202: begin AEffect := tfxTonePorta;   AParam := Byte((AVol - 193) * 16); end;
    203..212: begin AEffect := tfxVibrato;     AParam := Byte(AVol - 203); end;
  else
    ALost := AVol <> 0;
  end;
end;

{ UDAW internal effect -> IT command index + parameter. }
function MapUdawToIt(AEffect: TTrackerEffect; AParam: Byte;
  out ACmd, AOutParam: Byte): Boolean;
begin
  ACmd := 0;
  AOutParam := 0;
  Result := True;
  case AEffect of
    tfxNone:         Result := False;
    tfxSetSpeed:     begin ACmd := 1;  AOutParam := AParam; end;
    tfxPositionJump: begin ACmd := 2;  AOutParam := AParam; end;
    tfxPatternBreak: begin ACmd := 3;  AOutParam := AParam; end;
    tfxVolSlide:     begin ACmd := 4;  AOutParam := AParam; end;
    tfxPortaDown:    begin ACmd := 5;  AOutParam := AParam; end;
    tfxPortaUp:      begin ACmd := 6;  AOutParam := AParam; end;
    tfxTonePorta:    begin ACmd := 7;  AOutParam := AParam; end;
    tfxVibrato:      begin ACmd := 8;  AOutParam := AParam; end;
    tfxArpeggio:     begin ACmd := 10; AOutParam := AParam; end;
    tfxSampleOffset: begin ACmd := 15; AOutParam := AParam; end;
    tfxPanSlide:     begin ACmd := 16; AOutParam := AParam; end;
    tfxRetrigger:    begin ACmd := 17; AOutParam := Byte(AParam and $0F); end;
    tfxTremolo:      begin ACmd := 18; AOutParam := AParam; end;
    tfxSetPanning:   begin ACmd := 24; AOutParam := AParam; end;
    tfxSetBPM:       begin ACmd := 20; AOutParam := Byte(Max(Integer($20), Integer(AParam))); end;
    tfxNoteCut:      begin ACmd := 19; AOutParam := Byte($C0 or (AParam and $0F)); end;
    tfxNoteDelay:    begin ACmd := 19; AOutParam := Byte($D0 or (AParam and $0F)); end;
    tfxSetVolume:    Result := False;   // IT carries set-volume in the volume column
    tfxFineVolUp:    Result := False;
    tfxFineVolDown:  Result := False;
  else
    Result := False;
  end;
end;

{ ================= TMPTMImportInfo ================= }

function TMPTMImportInfo.Summary: string;
begin
  Result := Format(
    'MPTM / IT  "%s"  (cwt %.4x / cmwt %.4x)'#10 +
    '%s mode, %d channels, %d patterns, %d instruments, %d/%d samples used'#10 +
    '%d compressed sample(s) decoded (IT2.14/2.15), %d orders (restart @ %d)'#10 +
    '%d cells: %d notes, %d effects (%d dropped, no internal equivalent)'#10 +
    '%d byte(s) of trailing OpenMPT extension data ignored%s',
    [Title, Cwtv, Cmwt, IfThen(InstrumentMode, 'instrument', 'sample'),
     Channels, PatternCount, InstrumentCount, UsedSamples, SampleCount,
     CompressedSamples, OrderLength, RestartPos,
     TotalCells, NoteCells, EffectCells, LostEffectCells, ExtensionBytes,
     IfThen(Truncated, #10'NOTE: file data ran short and was zero-padded', '')]);
end;

{ ================= sniffing ================= }

function DataLooksLikeMptm(const AData: TBytes): Boolean;
var
  ordNum, insNum, smpNum, patNum: Integer;
begin
  Result := False;
  if Length(AData) < 192 then Exit;
  if (AData[0] <> Ord('I')) or (AData[1] <> Ord('M'))
     or (AData[2] <> Ord('P')) or (AData[3] <> Ord('M')) then Exit;
  ordNum := RdWord(AData, 32);
  insNum := RdWord(AData, 34);
  smpNum := RdWord(AData, 36);
  patNum := RdWord(AData, 38);
  if (ordNum > MPTM_MAX_ORDERS + 2) or (insNum > MPTM_MAX_INSTR)
     or (smpNum > MPTM_MAX_SAMPLES) or (patNum > MPTM_MAX_PATTERNS) then Exit;
  if 192 + ordNum + (insNum + smpNum + patNum) * 4 > Length(AData) then Exit;
  Result := True;
end;

function MptmKindFromData(const AData: TBytes): Boolean;
begin
  Result := DataLooksLikeMptm(AData);
end;

function FileLooksLikeMptm(const AFileName: string): Boolean;
var
  fs: TFileStream;
  buf: TBytes;
  n: Int64;
begin
  Result := False;
  if not FileExists(AFileName) then Exit;
  fs := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
  try
    n := Min(fs.Size, Int64(64 * 1024));
    if n < 192 then Exit;
    SetLength(buf, n);
    fs.ReadBuffer(buf[0], n);
  finally
    fs.Free;
  end;
  Result := DataLooksLikeMptm(buf);
end;

{ ================= import ================= }

procedure Guard(ACond: Boolean; const AMsg: string);
begin
  if not ACond then RaiseUDAW(errConfig, MPTM_SUBSYS, AMsg);
end;

{ Walk one packed IT pattern purely to find the highest channel it references,
  so the module's channel count is known before patterns are created. }
function ScanPatternMaxChannel(const D: TBytes; AOfs, ALen: Integer): Integer;
var
  i, endp, ch, row, rows: Integer;
  b, mask: Byte;
  lastMask: array[0..63] of Byte;
begin
  Result := 0;
  if (AOfs < 0) or (AOfs + 8 > Length(D)) then Exit;
  rows := RdWord(D, AOfs + 2);
  FillChar(lastMask, SizeOf(lastMask), 0);
  i := AOfs + 8;
  endp := AOfs + 8 + ALen;
  if endp > Length(D) then endp := Length(D);
  row := 0;
  while (row < rows) and (i < endp) do
  begin
    b := D[i]; Inc(i);
    if b = 0 then begin Inc(row); Continue; end;
    ch := (b - 1) and 63;
    if ch + 1 > Result then Result := ch + 1;
    if (b and $80) <> 0 then
    begin
      if i >= endp then Break;
      lastMask[ch] := D[i]; Inc(i);
    end;
    mask := lastMask[ch];
    if (mask and $01) <> 0 then Inc(i);
    if (mask and $02) <> 0 then Inc(i);
    if (mask and $04) <> 0 then Inc(i);
    if (mask and $08) <> 0 then Inc(i, 2);
  end;
end;

function ReadEnvelope(const D: TBytes; AOfs: Integer): TMPTMEnvelope;
var
  k: Integer;
begin
  FillChar(Result, SizeOf(Result), 0);
  if (AOfs < 0) or (AOfs + 82 > Length(D)) then Exit;
  Result.Enabled    := (D[AOfs] and $01) <> 0;
  Result.HasLoop    := (D[AOfs] and $02) <> 0;
  Result.HasSustain := (D[AOfs] and $04) <> 0;
  Result.Count      := ClampInt(D[AOfs + 1], 0, 25);
  Result.LoopBegin  := D[AOfs + 2];
  Result.LoopEnd    := D[AOfs + 3];
  Result.SusBegin   := D[AOfs + 4];
  Result.SusEnd     := D[AOfs + 5];
  for k := 0 to Result.Count - 1 do
  begin
    Result.Points[k].Y := ShortInt(D[AOfs + 6 + k * 3]);
    Result.Points[k].X := RdWord(D, AOfs + 6 + k * 3 + 1);
  end;
end;

procedure ApplyEnvelope(AInstr: TTrackerInstrument; const AEnv: TMPTMEnvelope; AIsVol: Boolean);
var
  env: TTrackerEnvelope;
  k: Integer;
begin
  if not AEnv.Enabled or (AEnv.Count = 0) then Exit;
  if AIsVol then env := AInstr.VolEnv else env := AInstr.PanEnv;
  env.Clear;
  env.Enabled := True;
  for k := 0 to AEnv.Count - 1 do
    if AIsVol then
      env.AddPoint(AEnv.Points[k].X, ClampInt(AEnv.Points[k].Y, 0, 64) / 64.0)
    else
      env.AddPoint(AEnv.Points[k].X, (ClampInt(AEnv.Points[k].Y, -32, 32) + 32) / 64.0);
  if AEnv.HasSustain then env.SustainPoint := ClampInt(AEnv.SusBegin, 0, Max(0, AEnv.Count - 1))
  else env.SustainPoint := -1;
  if AEnv.HasLoop then
  begin
    env.LoopStart := ClampInt(AEnv.LoopBegin, 0, Max(0, AEnv.Count - 1));
    env.LoopEnd := ClampInt(AEnv.LoopEnd, 0, Max(0, AEnv.Count - 1));
  end;
  if AIsVol then AInstr.VolEnv := env else AInstr.PanEnv := env;
end;

{ ================= IT2.14 / IT2.15 sample decompression =================

  IT's compressed sample format packs each channel as a sequence of blocks
  (0x8000 samples/block for 8-bit, 0x4000 for 16-bit; each preceded by its
  own uint16-LE compressed byte length). Within a block, samples are a
  string of variable-width delta codes read LSB-first; the width adapts
  per-sample via three escape ranges (low/medium/high, split at width<7 and
  width<Bits+1) that either read a few extra bits or repurpose out-of-range
  code values to signal a new width, with no separate "table" - the encoder
  and decoder derive everything from the current width alone. cwtv >= $215
  selects the newer double-delta ("IT215") accumulation; older files use a
  single running delta. This is a clean-room implementation against the
  publicly documented bitstream technique (ITTECH.TXT), not linked to or
  copied from any existing decoder. }

function DecompressITChannel(const D: TBytes; var APos: Integer; AFrames, ABits: Integer;
  AIt215: Boolean; var ATruncated: Boolean): TArray<Integer>;
const
  MAX_ITER_PER_SAMPLE = 64;   // defensive cap: legitimate streams need far fewer
var
  blockSamples, maxWidth, lowBits, halfSpan: Integer;
  bitBuf: Cardinal;
  bitNum: Integer;
  width: Integer;
  temp, temp2: Integer;
  posOut, blockLen, blockEnd, blockCount, i, iterGuard: Integer;
  v, extra, upper, lower: Integer;
  handled, eof: Boolean;

  function NextByte: Byte; {$IFDEF FPC}inline;{$ENDIF}
  begin
    if (APos < 0) or (APos >= blockEnd) or (APos >= Length(D)) then
    begin
      eof := True;
      ATruncated := True;
      Exit(0);
    end;
    Result := D[APos];
    Inc(APos);
  end;

  function ReadBits(AWidth: Integer): Integer;
  begin
    while (bitNum < AWidth) and not eof do
    begin
      bitBuf := bitBuf or (Cardinal(NextByte) shl bitNum);
      Inc(bitNum, 8);
    end;
    Result := Integer(bitBuf and ((Cardinal(1) shl AWidth) - 1));
    bitBuf := bitBuf shr AWidth;
    Dec(bitNum, AWidth);
    if bitNum < 0 then bitNum := 0;
  end;

begin
  SetLength(Result, AFrames);
  if AFrames <= 0 then Exit;
  maxWidth := ABits + 1;
  lowBits := IfThen(ABits >= 16, 4, 3);
  halfSpan := ABits div 2;                    // 4 for 8-bit, 8 for 16-bit
  blockSamples := IfThen(ABits >= 16, $4000, $8000);
  posOut := 0;
  eof := False;
  while (posOut < AFrames) and not eof do
  begin
    if APos + 2 > Length(D) then begin ATruncated := True; Break; end;
    blockLen := D[APos] or (D[APos + 1] shl 8);
    Inc(APos, 2);
    blockEnd := APos + blockLen;
    if (blockEnd > Length(D)) or (blockEnd < APos) then
    begin
      blockEnd := Length(D);
      ATruncated := True;
    end;

    bitBuf := 0; bitNum := 0;
    temp := 0; temp2 := 0;   { delta accumulators restart every block }
    width := maxWidth;
    blockCount := AFrames - posOut;
    if blockCount > blockSamples then blockCount := blockSamples;

    i := 0;
    while i < blockCount do
    begin
      if eof then Break;
      iterGuard := 0;
      repeat
        Inc(iterGuard);
        v := ReadBits(width);
        handled := False;

        if width < 7 then
        begin
          if v = (1 shl (width - 1)) then
          begin
            extra := ReadBits(lowBits) + 1;
            if extra < width then width := extra else width := (extra + 1) and $FF;
            width := ClampInt(width, 1, maxWidth);
            handled := True;
          end;
        end
        else if width < maxWidth then
        begin
          upper := (((1 shl ABits) - 1) shr (maxWidth - width)) + halfSpan;
          lower := upper - 2 * halfSpan;
          if (v > lower) and (v <= upper) then
          begin
            v := v - lower;
            if v < width then width := v else width := (v + 1) and $FF;
            width := ClampInt(width, 1, maxWidth);
            handled := True;
          end;
        end
        else   { width = maxWidth: the "high" escape }
        begin
          if (v and (1 shl (maxWidth - 1))) <> 0 then
          begin
            width := (v + 1) and $FF;
            width := ClampInt(width, 1, maxWidth);
            handled := True;
          end;
        end;
      until not handled or eof or (iterGuard >= MAX_ITER_PER_SAMPLE);

      if eof then Break;

      if width < ABits then
      begin
        if (v and (1 shl (width - 1))) <> 0 then v := v - (1 shl width);
      end;

      temp := temp + v;
      if ABits >= 16 then
      begin
        temp := temp and $FFFF; if temp > 32767 then temp := temp - 65536;
      end
      else
      begin
        temp := temp and $FF; if temp > 127 then temp := temp - 256;
      end;

      if AIt215 then
      begin
        temp2 := temp2 + temp;
        if ABits >= 16 then
        begin
          temp2 := temp2 and $FFFF; if temp2 > 32767 then temp2 := temp2 - 65536;
        end
        else
        begin
          temp2 := temp2 and $FF; if temp2 > 127 then temp2 := temp2 - 256;
        end;
        Result[posOut] := temp2;
      end
      else
        Result[posOut] := temp;

      Inc(posOut);
      Inc(i);
    end;

    APos := blockEnd;   { always resync to the declared block length }
  end;
end;

{ OpenMPT can store a sample as a reference to an external audio file: the
  sample's data pointer then addresses a length-prefixed path string instead of
  PCM. Decode the referenced file (FLAC / WAV / MP3) to mono. }
var
  GExtBaseDir: string;   { folder of the module being imported; set by LoadMptmFile }

procedure MptmSetSampleFolder(const AFolder: string);
begin
  GExtBaseDir := AFolder;
end;

function MptmSampleFolder: string;
begin
  Result := GExtBaseDir;
end;

function ExtRefPath(const D: TBytes; APos: Integer): string;
var
  n, i: Integer;
  hasSep, hasDot: Boolean;
begin
  Result := '';
  if (APos <= 0) or (APos >= Length(D)) then Exit;
  n := D[APos];
  if (n = 0) or (APos + n >= Length(D)) then Exit;
  hasSep := False; hasDot := False;
  for i := 1 to n do
  begin
    if (D[APos + i] < $20) or (D[APos + i] > $7E) then Exit;
    if D[APos + i] in [Ord('\'), Ord('/'), Ord(':')] then hasSep := True;
    if D[APos + i] = Ord('.') then hasDot := True;
  end;
  if not (hasSep and hasDot) then Exit;
  SetLength(Result, n);
  for i := 1 to n do Result[i] := Char(D[APos + i]);
end;

function ResolveExtPath(const ARef: string): string;
var
  nm: string;
  base: string;
begin
  Result := '';
  if FileExists(ARef) then Exit(ARef);
  if GExtBaseDir = '' then Exit;
  base := IncludeTrailingPathDelimiter(GExtBaseDir);
  nm := ExtractFileName(StringReplace(ARef, '/', PathDelim, [rfReplaceAll]));
  if FileExists(base + StringReplace(ARef, '/', PathDelim, [rfReplaceAll])) then
    Exit(base + StringReplace(ARef, '/', PathDelim, [rfReplaceAll]));
  if FileExists(base + 'Samples' + PathDelim + nm) then
    Exit(base + 'Samples' + PathDelim + nm);
  if FileExists(base + nm) then
    Exit(base + nm);
end;

function PlanarToMono(const APcm: TAudioPlanar; AChannels: Integer;
  AFrames: Int64): TAudioSampleArray;
var
  c, i: Integer;
  acc: Single;
begin
  SetLength(Result, AFrames);
  if AChannels < 1 then Exit;
  for i := 0 to AFrames - 1 do
  begin
    acc := 0;
    for c := 0 to AChannels - 1 do acc := acc + APcm[c][i];
    Result[i] := acc / AChannels;
  end;
end;

function DecodeExternalSample(const APath: string): TAudioSampleArray;
var
  ext: string;
  fl: TFLACDecodeResult;
  mp: TMP3DecodeResult;
  ch, sr: Integer;
  pl: TAudioPlanar;
begin
  Result := nil;
  if APath = '' then Exit;
  ext := LowerCase(ExtractFileExt(APath));
  try
    if ext = '.flac' then
    begin
      if DecodeFlacFile(APath, fl) then
        Result := PlanarToMono(fl.Pcm, fl.Channels, fl.TotalFrames);
    end
    else if ext = '.mp3' then
    begin
      if Mp3DecodeFile(APath, mp) then
        Result := PlanarToMono(mp.Pcm, mp.Channels, mp.Frames);
    end
    else
    begin
      pl := LoadWavFile(APath, ch, sr);
      if Length(pl) > 0 then
        Result := PlanarToMono(pl, ch, Length(pl[0]));
    end;
  except
    Result := nil;
  end;
end;

function DecodeSamplePCM(const D: TBytes; const S: TMPTMSample; ACwtv: Integer;
  var ATruncated: Boolean): TAudioSampleArray;
var
  frames, bytesPer, needBytes, i: Integer;
  p: Integer;
  cur: Integer;
  raw: Integer;
  raws: TArray<Integer>;
  extPath: string;
  extPcm: TAudioSampleArray;
begin
  frames := S.LengthFrames;
  if frames > MPTM_MAX_SAMPLE_FRAMES then frames := MPTM_MAX_SAMPLE_FRAMES;
  SetLength(Result, frames);
  if frames = 0 then Exit;

  { a corrupt / out-of-range data pointer -> no PCM (zero-filled), never an
    out-of-bounds read }
  if (S.DataPtr = 0) or (S.DataPtr >= Cardinal(Length(D))) then
  begin
    ATruncated := True;
    Exit;
  end;
  p := Integer(S.DataPtr);

  { external-file sample (OpenMPT): data pointer addresses a path string }
  if S.Compressed or (Int64(p) + Int64(frames) * IfThen(S.Is16Bit, 2, 1) > Length(D)) then
  begin
    extPath := ExtRefPath(D, p);
    if extPath <> '' then
    begin
      extPcm := DecodeExternalSample(ResolveExtPath(extPath));
      if Length(extPcm) = 0 then ATruncated := True;
      Exit(extPcm);
    end;
  end;

  if S.Compressed then
  begin
    raws := DecompressITChannel(D, p, frames, IfThen(S.Is16Bit, 16, 8),
      S.Delta, ATruncated);   { IT2.15 is flagged by Cvt bit 2, not by tracker version }
    if S.Is16Bit then
      for i := 0 to frames - 1 do Result[i] := raws[i] / 32768.0
    else
      for i := 0 to frames - 1 do Result[i] := raws[i] / 128.0;
    Exit;
  end;

  bytesPer := IfThen(S.Is16Bit, 2, 1);
  needBytes := frames * bytesPer * IfThen(S.Stereo, 2, 1);
  if Int64(p) + needBytes > Length(D) then
  begin
    needBytes := Max(0, Length(D) - p);
    ATruncated := True;
  end;

  cur := 0;
  for i := 0 to frames - 1 do
  begin
    if S.Is16Bit then
    begin
      if i * 2 + 1 < needBytes then
      begin
        if S.BigEndian then
          raw := (D[p + i * 2] shl 8) or D[p + i * 2 + 1]
        else
          raw := D[p + i * 2] or (D[p + i * 2 + 1] shl 8);
        if S.Signed then raw := SmallInt(raw) else raw := Integer(raw) - 32768;
      end
      else
        raw := 0;
      if S.Delta then
      begin
        cur := SmallInt(cur + raw);
        Result[i] := cur / 32768.0;
      end
      else
        Result[i] := raw / 32768.0;
    end
    else
    begin
      if i < needBytes then
      begin
        if S.Signed then raw := ShortInt(D[p + i]) else raw := Integer(D[p + i]) - 128;
      end
      else
        raw := 0;
      if S.Delta then
      begin
        cur := ShortInt(cur + raw);
        Result[i] := cur / 128.0;
      end
      else
        Result[i] := raw / 128.0;
    end;
  end;
end;

function MptmToModule(const AData: TBytes; out AInfo: TMPTMImportInfo): TTrackerModule;
var
  m: TTrackerModule;
  ordNum, insNum, smpNum, patNum, flags, i, k, p, r: Integer;
  gv, speed, tempo: Integer;
  useInstruments: Boolean;
  orders: array of Integer;
  insOfs, smpOfs, patOfs: array of Cardinal;
  channels, tblOfs: Integer;
  smp: array of TMPTMSample;
  inst: array of TMPTMInstrument;
  flg, cvt: Byte;
  ins: TTrackerInstrument;
  pcm: TAudioSampleArray;
  chosen: Integer;
  { pattern unpack }
  packLen, rows, pofs, ip, endp, ch: Integer;
  b, mask: Byte;
  noteV, insV, volV, cmdV, prmV: Integer;
  lastMask, lastNote, lastIns, lastVol, lastCmd, lastPrm: array[0..63] of Byte;
  pat: TTrackerPattern;
  cell: TTrackerCell;
  eff: TTrackerEffect;
  op, ovol: Byte;
  colEff: TTrackerEffect;
  colParam: Byte;
  colLost: Boolean;
  lastPatEnd: Int64;
begin
  FillChar(AInfo, SizeOf(AInfo), 0);
  if Length(AData) > MPTM_MAX_FILE then
    RaiseUDAWFmt(errConfig, MPTM_SUBSYS, 'MPTM file too large (%d bytes)', [Length(AData)]);
  if not DataLooksLikeMptm(AData) then
    RaiseUDAW(errConfig, MPTM_SUBSYS, 'not a recognisable IMPM (IT / MPTM) module');

  AInfo.Title := CleanText(AData, 4, 26);
  ordNum := RdWord(AData, 32);
  insNum := RdWord(AData, 34);
  smpNum := RdWord(AData, 36);
  patNum := RdWord(AData, 38);
  AInfo.Cwtv := RdWord(AData, 40);
  AInfo.Cmwt := RdWord(AData, 42);
  flags := RdWord(AData, 44);
  gv := AData[48];
  speed := AData[50];
  tempo := AData[51];

  ordNum := ClampInt(ordNum, 0, MPTM_MAX_ORDERS + 2);
  insNum := ClampInt(insNum, 0, MPTM_MAX_INSTR);
  smpNum := ClampInt(smpNum, 0, MPTM_MAX_SAMPLES);
  patNum := ClampInt(patNum, 0, MPTM_MAX_PATTERNS);
  useInstruments := (flags and $04) <> 0;
  AInfo.InstrumentMode := useInstruments;

  { --- order table --- }
  SetLength(orders, 0);
  for i := 0 to ordNum - 1 do
  begin
    k := AData[192 + i];
    if k >= 254 then Continue;            // 255 = end, 254 = +++ skip
    SetLength(orders, Length(orders) + 1);
    orders[High(orders)] := k;
  end;

  tblOfs := 192 + ordNum;
  SetLength(insOfs, insNum);
  SetLength(smpOfs, smpNum);
  SetLength(patOfs, patNum);
  Guard(tblOfs + (insNum + smpNum + patNum) * 4 <= Length(AData),
    'MPTM offset tables run past the end of the file');
  for i := 0 to insNum - 1 do insOfs[i] := RdDWord(AData, tblOfs + i * 4);
  Inc(tblOfs, insNum * 4);
  for i := 0 to smpNum - 1 do smpOfs[i] := RdDWord(AData, tblOfs + i * 4);
  Inc(tblOfs, smpNum * 4);
  for i := 0 to patNum - 1 do patOfs[i] := RdDWord(AData, tblOfs + i * 4);

  { --- samples --- }
  SetLength(smp, smpNum);
  for i := 0 to smpNum - 1 do
  begin
    FillChar(smp[i], SizeOf(smp[i]), 0);
    p := smpOfs[i];
    if (p <= 0) or (Int64(p) + 80 > Length(AData)) then Continue;
    if (AData[p] <> Ord('I')) or (AData[p + 1] <> Ord('M'))
       or (AData[p + 2] <> Ord('P')) or (AData[p + 3] <> Ord('S')) then Continue;
    flg := AData[p + 18];
    cvt := AData[p + 46];
    smp[i].Name := CleanText(AData, p + 20, 26);
    smp[i].HasSample  := (flg and $01) <> 0;
    smp[i].Is16Bit    := (flg and $02) <> 0;
    smp[i].Stereo     := (flg and $04) <> 0;
    smp[i].Compressed := (flg and $08) <> 0;
    smp[i].LoopOn     := (flg and $10) <> 0;
    smp[i].PingPong   := (flg and $40) <> 0;
    smp[i].Signed     := (cvt and $01) <> 0;
    smp[i].BigEndian  := (cvt and $02) <> 0;
    smp[i].Delta      := (cvt and $04) <> 0;
    smp[i].Volume     := ClampInt(AData[p + 19], 0, 64);
    if (AData[p + 47] and $80) <> 0 then
      smp[i].DefaultPan := ClampInt(AData[p + 47] and $7F, 0, 64)
    else
      smp[i].DefaultPan := -1;
    smp[i].LengthFrames := RdDWord(AData, p + 48);
    smp[i].LoopBegin    := RdDWord(AData, p + 52);
    smp[i].LoopEnd      := RdDWord(AData, p + 56);
    smp[i].C5Speed      := RdDWord(AData, p + 60);
    smp[i].DataPtr      := RdDWord(AData, p + 72);
    if smp[i].C5Speed = 0 then smp[i].C5Speed := 8363;
    if smp[i].LengthFrames > MPTM_MAX_SAMPLE_FRAMES then
      smp[i].LengthFrames := MPTM_MAX_SAMPLE_FRAMES;
    if smp[i].Compressed and smp[i].HasSample then Inc(AInfo.CompressedSamples);
  end;

  { --- instruments (new IMPI layout) --- }
  SetLength(inst, insNum);
  for i := 0 to insNum - 1 do
  begin
    FillChar(inst[i], SizeOf(inst[i]), 0);
    p := insOfs[i];
    if (p <= 0) or (Int64(p) + 554 > Length(AData)) then Continue;
    if (AData[p] <> Ord('I')) or (AData[p + 1] <> Ord('M'))
       or (AData[p + 2] <> Ord('P')) or (AData[p + 3] <> Ord('I')) then Continue;
    inst[i].Name := CleanText(AData, p + 32, 26);
    inst[i].Fadeout := RdWord(AData, p + 20);
    { NoteSample keyboard table: 120 * (note, sample), middle C = index 60 }
    inst[i].MiddleCSample := AData[p + 64 + 60 * 2 + 1];
    inst[i].VolEnv := ReadEnvelope(AData, p + 304);
    inst[i].PanEnv := ReadEnvelope(AData, p + 386);
  end;

  { --- channel count: scan every pattern --- }
  channels := 0;
  for i := 0 to patNum - 1 do
  begin
    p := patOfs[i];
    if (p <= 0) or (Int64(p) + 8 > Length(AData)) then Continue;
    packLen := RdWord(AData, p);
    k := ScanPatternMaxChannel(AData, p, packLen);
    if k > channels then channels := k;
  end;
  if channels < TRK_MIN_CHANNELS then channels := TRK_MIN_CHANNELS;
  channels := ClampInt(channels, TRK_MIN_CHANNELS, MPTM_MAX_CHANNELS);

  m := TTrackerModule.Create;
  try
    m.Clear;
    m.Name := AInfo.Title;
    if m.Name = '' then m.Name := 'Imported MPTM';
    m.SetChannels(channels);
    m.InitialSpeed := ClampInt(IfThen(speed > 0, speed, TRK_DEFAULT_SPEED), TRK_MIN_SPEED, TRK_MAX_SPEED);
    m.InitialBPM := ClampInt(IfThen(tempo >= 32, tempo, TRK_DEFAULT_BPM), TRK_MIN_BPM, TRK_MAX_BPM);
    m.GlobalVolume := ClampInt(gv, 0, 128) / 128.0;
    if m.GlobalVolume <= 0 then m.GlobalVolume := 1.0;

    { --- build instrument slots --- }
    if useInstruments then
    begin
      for i := 0 to insNum - 1 do
      begin
        ins := m.AddInstrument(inst[i].Name);
        if ins.Name = '' then ins.Name := Format('Instrument %d', [i + 1]);
        ins.RootNote := MPTM_C5_NOTE;
        chosen := inst[i].MiddleCSample;      // 1-based IT sample
        if (chosen >= 1) and (chosen <= smpNum) then
        begin
          pcm := DecodeSamplePCM(AData, smp[chosen - 1], AInfo.Cwtv, AInfo.Truncated);
          if Length(pcm) > 0 then
          begin
            ins.SampleRate := smp[chosen - 1].C5Speed;
            ins.Volume := smp[chosen - 1].Volume / 64.0;
            if smp[chosen - 1].DefaultPan >= 0 then
              ins.Pan := smp[chosen - 1].DefaultPan / 32.0 - 1.0;
            ins.SetData(pcm, ins.SampleRate);
            if smp[chosen - 1].LoopOn then
            begin
              if smp[chosen - 1].PingPong then ins.LoopMode := tlmPingPong
              else ins.LoopMode := tlmForward;
              ins.LoopStart := ClampInt(smp[chosen - 1].LoopBegin, 0, ins.FrameCount);
              ins.LoopEnd := ClampInt(smp[chosen - 1].LoopEnd, ins.LoopStart + 1, ins.FrameCount);
            end
            else
              ins.LoopMode := tlmOff;
            Inc(AInfo.UsedSamples);
          end;
        end;
        ins.Fadeout := inst[i].Fadeout / 1024.0;
        ApplyEnvelope(ins, inst[i].VolEnv, True);
        ApplyEnvelope(ins, inst[i].PanEnv, False);
      end;
    end
    else
    begin
      for i := 0 to smpNum - 1 do
      begin
        ins := m.AddInstrument(smp[i].Name);
        if ins.Name = '' then ins.Name := Format('Sample %d', [i + 1]);
        ins.RootNote := MPTM_C5_NOTE;
        pcm := DecodeSamplePCM(AData, smp[i], AInfo.Cwtv, AInfo.Truncated);
        ins.SampleRate := smp[i].C5Speed;
        ins.Volume := smp[i].Volume / 64.0;
        if smp[i].DefaultPan >= 0 then ins.Pan := smp[i].DefaultPan / 32.0 - 1.0;
        if Length(pcm) > 0 then
        begin
          ins.SetData(pcm, ins.SampleRate);
          if smp[i].LoopOn then
          begin
            if smp[i].PingPong then ins.LoopMode := tlmPingPong
            else ins.LoopMode := tlmForward;
            ins.LoopStart := ClampInt(smp[i].LoopBegin, 0, ins.FrameCount);
            ins.LoopEnd := ClampInt(smp[i].LoopEnd, ins.LoopStart + 1, ins.FrameCount);
          end;
          if smp[i].HasSample then Inc(AInfo.UsedSamples);
        end;
      end;
    end;

    { --- patterns --- }
    if patNum = 0 then
      m.AddPattern(TRK_DEFAULT_ROWS);
    for i := 0 to patNum - 1 do
    begin
      pofs := patOfs[i];
      if (pofs <= 0) or (Int64(pofs) + 8 > Length(AData)) then
      begin
        m.AddPattern(TRK_DEFAULT_ROWS);   // "empty pattern" convention
        Continue;
      end;
      packLen := RdWord(AData, pofs);
      rows := ClampInt(RdWord(AData, pofs + 2), TRK_MIN_ROWS, MPTM_MAX_ROWS);
      lastPatEnd := Int64(pofs) + 8 + packLen;
      if lastPatEnd > Length(AData) then
      begin
        packLen := Max(0, Length(AData) - (Integer(pofs) + 8));
        AInfo.Truncated := True;
      end;

      pat := m.AddPattern(rows);
      FillChar(lastMask, SizeOf(lastMask), 0);
      FillChar(lastNote, SizeOf(lastNote), 0);
      FillChar(lastIns, SizeOf(lastIns), 0);
      FillChar(lastVol, SizeOf(lastVol), 0);
      FillChar(lastCmd, SizeOf(lastCmd), 0);
      FillChar(lastPrm, SizeOf(lastPrm), 0);
      ip := Integer(pofs) + 8;
      endp := ip + packLen;
      r := 0;
      while (r < rows) and (ip < endp) do
      begin
        b := AData[ip]; Inc(ip);
        if b = 0 then begin Inc(r); Continue; end;
        ch := (b - 1) and 63;
        if (b and $80) <> 0 then
        begin
          if ip >= endp then Break;
          lastMask[ch] := AData[ip]; Inc(ip);
        end;
        mask := lastMask[ch];
        noteV := -1; insV := -1; volV := -1; cmdV := 0; prmV := 0;

        if (mask and $01) <> 0 then
        begin
          if ip >= endp then Break;
          noteV := AData[ip]; Inc(ip); lastNote[ch] := noteV;
        end;
        if (mask and $02) <> 0 then
        begin
          if ip >= endp then Break;
          insV := AData[ip]; Inc(ip); lastIns[ch] := insV;
        end;
        if (mask and $04) <> 0 then
        begin
          if ip >= endp then Break;
          volV := AData[ip]; Inc(ip); lastVol[ch] := volV;
        end;
        if (mask and $08) <> 0 then
        begin
          if ip + 1 >= endp then Break;
          cmdV := AData[ip]; prmV := AData[ip + 1]; Inc(ip, 2);
          lastCmd[ch] := cmdV; lastPrm[ch] := prmV;
        end;
        if (mask and $10) <> 0 then noteV := lastNote[ch];
        if (mask and $20) <> 0 then insV := lastIns[ch];
        if (mask and $40) <> 0 then volV := lastVol[ch];
        if (mask and $80) <> 0 then begin cmdV := lastCmd[ch]; prmV := lastPrm[ch]; end;

        if ch >= pat.Channels then Continue;

        cell := TTrackerCell.Empty;
        Inc(AInfo.TotalCells);

        if noteV >= 0 then
        begin
          if noteV = 255 then cell.Note := TRK_NOTE_OFF
          else if noteV = 254 then cell.Note := TRK_NOTE_CUT
          else if noteV = 253 then cell.Note := TRK_NOTE_OFF
          else if noteV < 120 then
          begin
            cell.Note := Byte(ClampInt(noteV + 1, TRK_NOTE_MIN, TRK_NOTE_MAX));
            Inc(AInfo.NoteCells);
          end;
        end;
        if (insV >= 1) and (insV <= 255) then
          cell.Instrument := Byte(ClampInt(insV, 0, m.InstrumentCount));

        if volV >= 0 then
        begin
          MapItVolumeColumn(Byte(volV), ovol, colEff, colParam, colLost);
          if ovol <> TRK_VOL_NONE then cell.Volume := ovol;
          if colLost then Inc(AInfo.LostEffectCells);
        end
        else
          colEff := tfxNone;

        if (cmdV >= 1) and (cmdV <= 26) then
        begin
          Inc(AInfo.EffectCells);
          if MapItEffect(Byte(cmdV), Byte(prmV), eff, op) then
          begin
            cell.Effect := eff;
            cell.Param := op;
          end
          else
            Inc(AInfo.LostEffectCells);
        end
        else if colEff <> tfxNone then
        begin
          cell.Effect := colEff;
          cell.Param := colParam;
        end;

        pat.SetCell(r, ch, cell);
      end;
    end;

    { --- orders --- }
    for i := 0 to High(orders) do
      m.AppendOrder(ClampInt(orders[i], 0, Max(0, m.PatternCount - 1)));
    if m.OrderLength = 0 then m.AppendOrder(0);
    m.RestartPos := 0;

    { --- trailing OpenMPT extension size (informational only) --- }
    lastPatEnd := 0;
    for i := 0 to smpNum - 1 do
      if (smp[i].DataPtr > 0) and not smp[i].Compressed then
        lastPatEnd := Max(lastPatEnd, Int64(smp[i].DataPtr) + Int64(smp[i].LengthFrames)
          * IfThen(smp[i].Is16Bit, 2, 1) * IfThen(smp[i].Stereo, 2, 1));
    if (lastPatEnd > 0) and (lastPatEnd < Length(AData)) then
      AInfo.ExtensionBytes := Int64(Length(AData)) - lastPatEnd;

    AInfo.Channels := m.Channels;
    AInfo.OrderLength := m.OrderLength;
    AInfo.RestartPos := m.RestartPos;
    AInfo.InstrumentCount := m.InstrumentCount;
    AInfo.SampleCount := smpNum;
    AInfo.PatternCount := m.PatternCount;

    Result := m;
    m := nil;
  finally
    m.Free;
  end;
end;

function MptmToModule(const AData: TBytes): TTrackerModule;
var
  info: TMPTMImportInfo;
begin
  Result := MptmToModule(AData, info);
end;

function LoadMptmFile(const AFileName: string; out AInfo: TMPTMImportInfo): TTrackerModule;
var
  fs: TFileStream;
  buf: TBytes;
begin
  if not FileExists(AFileName) then
    RaiseUDAWFmt(errFileNotFound, MPTM_SUBSYS, 'MPTM file not found: %s', [AFileName]);
  fs := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
  try
    if fs.Size > MPTM_MAX_FILE then
      RaiseUDAWFmt(errConfig, MPTM_SUBSYS, 'MPTM file too large: %s', [AFileName]);
    SetLength(buf, fs.Size);
    if Length(buf) > 0 then fs.ReadBuffer(buf[0], Length(buf));
  finally
    fs.Free;
  end;
  GExtBaseDir := ExtractFilePath(ExpandFileName(AFileName));
  Result := MptmToModule(buf, AInfo);
end;

function LoadMptmFile(const AFileName: string): TTrackerModule;
var
  info: TMPTMImportInfo;
begin
  Result := LoadMptmFile(AFileName, info);
end;

{ ================= export ================= }

function MptmExportIssues(AModule: TTrackerModule): TArray<string>;
var
  list: TStringList;
  pi, r, c, lost: Integer;
  pat: TTrackerPattern;
  cell: TTrackerCell;
  cmd, op: Byte;
begin
  list := TStringList.Create;
  try
    if AModule.Channels > MPTM_MAX_CHANNELS then
      list.Add(Format('%d channels: this MPTM writer stores %d', [AModule.Channels, MPTM_MAX_CHANNELS]));
    if AModule.InstrumentCount > MPTM_MAX_SAMPLES then
      list.Add(Format('%d instruments: this MPTM writer stores %d samples',
        [AModule.InstrumentCount, MPTM_MAX_SAMPLES]));
    if AModule.PatternCount > MPTM_MAX_PATTERNS then
      list.Add(Format('%d patterns: this MPTM writer stores %d',
        [AModule.PatternCount, MPTM_MAX_PATTERNS]));
    if AModule.OrderLength > MPTM_MAX_ORDERS then
      list.Add(Format('%d order entries: this MPTM writer stores %d',
        [AModule.OrderLength, MPTM_MAX_ORDERS]));

    lost := 0;
    for pi := 0 to AModule.PatternCount - 1 do
    begin
      pat := AModule.GetPattern(pi);
      if pat = nil then Continue;
      for r := 0 to pat.Rows - 1 do
        for c := 0 to pat.Channels - 1 do
        begin
          cell := pat.GetCell(r, c);
          if (cell.Effect <> tfxNone) and (cell.Effect <> tfxSetVolume)
             and (cell.Effect <> tfxFineVolUp) and (cell.Effect <> tfxFineVolDown) then
            if not MapUdawToIt(cell.Effect, cell.Param, cmd, op) then
              Inc(lost);
        end;
    end;
    if lost > 0 then
      list.Add(Format('%d effect command(s) have no IT/MPTM equivalent and are dropped', [lost]));
    list.Add('MPTM export writes a plain IT-compatible core (no OpenMPT extension chunks, '
      + 'no plugins, no per-channel plugins or tempo swing)');

    Result := list.ToStringArray;
  finally
    list.Free;
  end;
end;

procedure PutW(var B: TBytes; AOfs, AValue: Integer); inline;
begin
  B[AOfs] := AValue and $FF;
  B[AOfs + 1] := (AValue shr 8) and $FF;
end;

procedure PutD(var B: TBytes; AOfs: Integer; AValue: Cardinal); inline;
begin
  B[AOfs] := AValue and $FF;
  B[AOfs + 1] := (AValue shr 8) and $FF;
  B[AOfs + 2] := (AValue shr 16) and $FF;
  B[AOfs + 3] := (AValue shr 24) and $FF;
end;

function PackPattern(APat: TTrackerPattern; AChannels: Integer): TBytes;
var
  st: TBytesStream;
  r, c: Integer;
  cell: TTrackerCell;
  mask, cmd, op: Byte;
  bb: Byte;
begin
  st := TBytesStream.Create;
  try
    for r := 0 to APat.Rows - 1 do
    begin
      for c := 0 to AChannels - 1 do
      begin
        if c >= APat.Channels then Continue;
        cell := APat.GetCell(r, c);
        mask := 0;
        cmd := 0; op := 0;
        if cell.Note <> TRK_NOTE_NONE then mask := mask or $01;
        if cell.Instrument <> TRK_INSTR_NONE then mask := mask or $02;
        if cell.Volume <= TRK_VOL_MAX then mask := mask or $04;
        if (cell.Effect <> tfxNone) or (cell.Param <> 0) then
        begin
          if MapUdawToIt(cell.Effect, cell.Param, cmd, op) then
            mask := mask or $08
          else if (cell.Effect = tfxSetVolume) and (cell.Volume > TRK_VOL_MAX) then
            mask := mask or $04;   // carry set-volume through the volume column
        end;
        if mask = 0 then Continue;

        bb := Byte(((c + 1) and 63) or $80);
        st.Write(bb, 1);
        st.Write(mask, 1);
        if (mask and $01) <> 0 then
        begin
          if cell.Note = TRK_NOTE_OFF then bb := 255
          else if cell.Note = TRK_NOTE_CUT then bb := 254
          else bb := Byte(ClampInt(cell.Note - 1, 0, 119));
          st.Write(bb, 1);
        end;
        if (mask and $02) <> 0 then
        begin
          bb := cell.Instrument;
          st.Write(bb, 1);
        end;
        if (mask and $04) <> 0 then
        begin
          if cell.Volume <= TRK_VOL_MAX then bb := cell.Volume
          else bb := Byte(ClampInt(cell.Param, 0, 64));   // set-volume effect
          st.Write(bb, 1);
        end;
        if (mask and $08) <> 0 then
        begin
          st.Write(cmd, 1);
          st.Write(op, 1);
        end;
      end;
      bb := 0;
      st.Write(bb, 1);   // end of row
    end;
    Result := Copy(st.Bytes, 0, st.Size);
  finally
    st.Free;
  end;
end;

function ModuleToMptm(AModule: TTrackerModule): TBytes;
var
  st: TBytesStream;
  channels, numOrd, numSmp, numPat, i, j, frames, iv, tablesEnd, curOfs: Integer;
  hdr, tbl, sh, ph: TBytes;
  packs: array of TBytes;
  smpHdrOfs, patOfs, smpDataOfs: array of Integer;
  ins: TTrackerInstrument;
  nm: RawByteString;
begin
  channels := ClampInt(AModule.Channels, TRK_MIN_CHANNELS, MPTM_MAX_CHANNELS);
  numOrd := ClampInt(AModule.OrderLength, 1, MPTM_MAX_ORDERS);
  numSmp := ClampInt(AModule.InstrumentCount, 0, MPTM_MAX_SAMPLES);
  numPat := ClampInt(AModule.PatternCount, 1, MPTM_MAX_PATTERNS);

  { --- pack every pattern once --- }
  SetLength(packs, numPat);
  for i := 0 to numPat - 1 do
    if AModule.GetPattern(i) <> nil then
      packs[i] := PackPattern(AModule.GetPattern(i), channels)
    else
      SetLength(packs[i], 0);

  { --- offset plan (all absolute) --- }
  tablesEnd := 192 + numOrd + numSmp * 4 + numPat * 4;
  SetLength(smpHdrOfs, numSmp);
  SetLength(patOfs, numPat);
  SetLength(smpDataOfs, numSmp);
  curOfs := tablesEnd;
  for i := 0 to numSmp - 1 do begin smpHdrOfs[i] := curOfs; Inc(curOfs, 80); end;
  for i := 0 to numPat - 1 do begin patOfs[i] := curOfs; Inc(curOfs, 8 + Length(packs[i])); end;
  for i := 0 to numSmp - 1 do
  begin
    smpDataOfs[i] := curOfs;
    ins := AModule.GetInstrument(i + 1);
    if ins <> nil then Inc(curOfs, ins.FrameCount);
  end;

  st := TBytesStream.Create;
  try
    { --- 192-byte header --- }
    SetLength(hdr, 192);
    FillChar(hdr[0], 192, 0);
    hdr[0] := Ord('I'); hdr[1] := Ord('M'); hdr[2] := Ord('P'); hdr[3] := Ord('M');
    nm := RawByteString(AModule.Name);
    for i := 0 to 25 do
      if i < Length(nm) then hdr[4 + i] := Byte(nm[i + 1]);
    PutW(hdr, 32, numOrd);
    PutW(hdr, 34, 0);                 // sample mode: no separate instruments
    PutW(hdr, 36, numSmp);
    PutW(hdr, 38, numPat);
    PutW(hdr, 40, $5000);             // cwtv
    PutW(hdr, 42, $0214);             // cmwt: IT 2.14
    PutW(hdr, 44, $0009);             // flags: stereo + linear slides
    hdr[48] := 128;                   // global volume
    hdr[49] := 48;                    // mix volume
    hdr[50] := ClampInt(AModule.InitialSpeed, 1, 255);
    hdr[51] := ClampInt(AModule.InitialBPM, 32, 255);
    hdr[52] := 128;
    for i := 0 to 63 do hdr[64 + i] := 32;
    for i := 0 to 63 do hdr[128 + i] := 64;
    st.WriteBuffer(hdr[0], 192);

    { --- order table --- }
    SetLength(tbl, numOrd);
    for i := 0 to numOrd - 1 do
      tbl[i] := Byte(ClampInt(AModule.GetOrder(i), 0, numPat - 1));
    st.WriteBuffer(tbl[0], numOrd);

    { --- sample + pattern offset tables --- }
    SetLength(tbl, numSmp * 4 + numPat * 4);
    if Length(tbl) > 0 then FillChar(tbl[0], Length(tbl), 0);
    for i := 0 to numSmp - 1 do PutD(tbl, i * 4, Cardinal(smpHdrOfs[i]));
    for i := 0 to numPat - 1 do PutD(tbl, numSmp * 4 + i * 4, Cardinal(patOfs[i]));
    if Length(tbl) > 0 then st.WriteBuffer(tbl[0], Length(tbl));

    { --- sample headers --- }
    for i := 0 to numSmp - 1 do
    begin
      ins := AModule.GetInstrument(i + 1);
      SetLength(sh, 80);
      FillChar(sh[0], 80, 0);
      sh[0] := Ord('I'); sh[1] := Ord('M'); sh[2] := Ord('P'); sh[3] := Ord('S');
      if ins <> nil then
      begin
        frames := ins.FrameCount;
        nm := RawByteString(ins.Name);
        for j := 0 to 25 do
          if j < Length(nm) then sh[20 + j] := Byte(nm[j + 1]);
        sh[17] := 64;                                 // global vol
        if frames > 0 then sh[18] := $01;             // has sample, 8-bit
        if ins.LoopMode = tlmForward then sh[18] := sh[18] or $10
        else if ins.LoopMode = tlmPingPong then sh[18] := sh[18] or $10 or $40;
        sh[19] := ClampInt(Round(ins.Volume * 64.0), 0, 64);
        sh[46] := $01;                                // Cvt: signed PCM, no delta
        sh[47] := Byte($80 or ClampInt(Round((ins.Pan + 1.0) * 32.0), 0, 64));
        PutD(sh, 48, Cardinal(frames));
        PutD(sh, 52, Cardinal(ClampInt(ins.LoopStart, 0, frames)));
        PutD(sh, 56, Cardinal(ClampInt(ins.LoopEnd, 0, frames)));
        PutD(sh, 60, Cardinal(Max(1, ins.SampleRate)));
        PutD(sh, 72, Cardinal(smpDataOfs[i]));
      end;
      st.WriteBuffer(sh[0], 80);
    end;

    { --- packed patterns --- }
    for i := 0 to numPat - 1 do
    begin
      SetLength(ph, 8);
      FillChar(ph[0], 8, 0);
      PutW(ph, 0, Length(packs[i]));
      if AModule.GetPattern(i) <> nil then
        PutW(ph, 2, ClampInt(AModule.GetPattern(i).Rows, 1, MPTM_MAX_ROWS))
      else
        PutW(ph, 2, TRK_DEFAULT_ROWS);
      st.WriteBuffer(ph[0], 8);
      if Length(packs[i]) > 0 then st.WriteBuffer(packs[i][0], Length(packs[i]));
    end;

    { --- sample data: 8-bit signed, no delta --- }
    for i := 0 to numSmp - 1 do
    begin
      ins := AModule.GetInstrument(i + 1);
      if (ins = nil) or (ins.FrameCount = 0) then Continue;
      SetLength(sh, ins.FrameCount);
      for j := 0 to ins.FrameCount - 1 do
      begin
        iv := Round(Max(-1.0, Min(1.0, Double(ins.Data[j]))) * 127.0);
        if iv > 127 then iv := 127 else if iv < -128 then iv := -128;
        sh[j] := Byte(ShortInt(iv));
      end;
      st.WriteBuffer(sh[0], Length(sh));
    end;

    Result := Copy(st.Bytes, 0, st.Size);
  finally
    st.Free;
  end;
end;

procedure SaveMptmFile(const AFileName: string; AModule: TTrackerModule);
var
  bytes: TBytes;
  fs: TFileStream;
begin
  bytes := ModuleToMptm(AModule);
  fs := TFileStream.Create(AFileName, fmCreate);
  try
    if Length(bytes) > 0 then fs.WriteBuffer(bytes[0], Length(bytes));
  finally
    fs.Free;
  end;
end;

end.
