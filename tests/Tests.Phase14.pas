unit Tests.Phase14;
{$IFDEF FPC}{$MODE DELPHI}{$MODESWITCH ADVANCEDRECORDS}{$H+}{$ENDIF}
{$POINTERMATH ON}

{ Phase 14 acceptance tests: MPTM support.

  Covers the IT / MPTM reader and writer in UDAW.Codec.MPTM - header sniffing,
  the offset tables, the packed IT pattern format with per-channel mask memory,
  the effect + volume column mapping onto UDAW's internal effect set, C5Speed
  -> sample-rate pitch, uncompressed 8-bit PCM, forward loops, playback through
  the Phase 11 TTrackerPlayer, the exporter, round-tripping, the
  export-representability report and - importantly - safe handling of malformed
  files (truncation, corrupt header, enormous declared lengths, bad channel /
  pattern counts).

  Requires src/common, src/audio, src/audio/dsp, src/timeline, src/project,
  src/mixer, src/tracker and src/codecs/tracker on the search path. }

interface

procedure RegisterPhase14Tests;

implementation

uses
  SysUtils, Classes, Math,
  UDAW.Testing,
  UDAW.Errors,
  UDAW.Audio.Types,
  UDAW.Tracker.Types, UDAW.Tracker.Instrument, UDAW.Tracker.Pattern,
  UDAW.Tracker.Player,
  UDAW.Project.Document, UDAW.Project.Serialization, UDAW.Project.Commands,
  UDAW.Tracker.Commands,
  UDAW.Codec.MPTM;

const
  SR = 48000;

{ ---------------- shared helpers ---------------- }

function DomFreq(const P: TAudioPlanar; ACh, AFrom, ATo: Integer): Double;
var
  i, firstX, lastX, cross: Integer;
  prev, cur: Single;
begin
  Result := 0;
  firstX := -1; lastX := -1; cross := 0;
  if AFrom < 1 then AFrom := 1;
  prev := P[ACh][AFrom - 1];
  for i := AFrom to ATo - 1 do
  begin
    cur := P[ACh][i];
    if (prev <= 0) and (cur > 0) then
    begin
      if firstX < 0 then firstX := i;
      lastX := i;
      Inc(cross);
    end;
    prev := cur;
  end;
  if (cross < 2) or (lastX <= firstX) then Exit;
  Result := (cross - 1) * SR / (lastX - firstX);
end;

function PlanarRms(const P: TAudioPlanar; ACh, AFrom, ATo: Integer): Double;
var
  i: Integer;
  acc: Double;
begin
  acc := 0;
  for i := AFrom to ATo - 1 do
    acc := acc + Sqr(Double(P[ACh][i]));
  if ATo - AFrom <= 0 then Exit(0);
  Result := Sqrt(acc / (ATo - AFrom));
end;

function AllFinitePl(const P: TAudioPlanar): Boolean;
var
  ch, i: Integer;
begin
  for ch := 0 to High(P) do
    for i := 0 to High(P[ch]) do
      if IsNan(P[ch][i]) or IsInfinite(P[ch][i]) then Exit(False);
  Result := True;
end;

type
  TCellSpec = record
    Pat, Row, Chn, Note, Instr, Vol, Cmd, Param: Integer;   // Note: 0 none, else internal note value; Vol: -1 none
  end;

function Spec(APat, ARow, AChn, ANote, AInstr, AVol, ACmd, AParam: Integer): TCellSpec;
begin
  Result.Pat := APat; Result.Row := ARow; Result.Chn := AChn;
  Result.Note := ANote; Result.Instr := AInstr; Result.Vol := AVol;
  Result.Cmd := ACmd; Result.Param := AParam;
end;

procedure PutW(var B: TBytes; AOfs, AValue: Integer);
begin
  B[AOfs] := AValue and $FF;
  B[AOfs + 1] := (AValue shr 8) and $FF;
end;

procedure PutD(var B: TBytes; AOfs, AValue: Integer);
begin
  B[AOfs] := AValue and $FF;
  B[AOfs + 1] := (AValue shr 8) and $FF;
  B[AOfs + 2] := (AValue shr 16) and $FF;
  B[AOfs + 3] := (AValue shr 24) and $FF;
end;

function SineS8(ACycles, ACount: Integer): TBytes;
var
  i, v: Integer;
begin
  SetLength(Result, ACount);
  for i := 0 to ACount - 1 do
  begin
    v := Round(120.0 * Sin(2 * Pi * ACycles * i / ACount));
    if v > 127 then v := 127 else if v < -128 then v := -128;
    Result[i] := Byte(v and $FF);
  end;
end;

{ Build a minimal sample-mode IT/MPTM: 1 sine sample (slot 1, whole-sample
  forward loop), ANumPat patterns of 64 rows, an order table and literal cells.
  Notes in ACells are internal note values (C-5 = 61). }
function BuildMptm(AChannels, ANumPat: Integer; const AOrder: array of Integer;
  const ACells: array of TCellSpec; ASampleCycles: Integer = 27;
  ASampleBytes: Integer = 512): TBytes;
var
  st: TBytesStream;
  hdr, tbl, sh, ph, pcm: TBytes;
  i, p, r, c, ci, ordNum, tablesEnd, curOfs: Integer;
  smpHdrOfs: Integer;
  patOfs: array of Integer;
  packs: array of TBytes;
  bs: TBytesStream;
  nm: AnsiString;
  mask, bb: Byte;
  cs: TCellSpec;
  has: Boolean;
begin
  ordNum := Length(AOrder);

  { pack patterns }
  SetLength(packs, ANumPat);
  for p := 0 to ANumPat - 1 do
  begin
    bs := TBytesStream.Create;
    try
      for r := 0 to 63 do
      begin
        for c := 0 to AChannels - 1 do
        begin
          has := False;
          cs := Spec(0, 0, 0, 0, 0, -1, 0, 0);
          for ci := 0 to High(ACells) do
            if (ACells[ci].Pat = p) and (ACells[ci].Row = r) and (ACells[ci].Chn = c) then
            begin cs := ACells[ci]; has := True; Break; end;
          if not has then Continue;
          mask := 0;
          if cs.Note <> 0 then mask := mask or $01;
          if cs.Instr <> 0 then mask := mask or $02;
          if cs.Vol >= 0 then mask := mask or $04;
          if (cs.Cmd <> 0) or (cs.Param <> 0) then mask := mask or $08;
          if mask = 0 then Continue;
          bb := Byte(((c + 1) and 63) or $80);
          bs.Write(bb, 1);
          bs.Write(mask, 1);
          if (mask and $01) <> 0 then begin bb := Byte(cs.Note - 1); bs.Write(bb, 1); end;
          if (mask and $02) <> 0 then begin bb := Byte(cs.Instr); bs.Write(bb, 1); end;
          if (mask and $04) <> 0 then begin bb := Byte(cs.Vol); bs.Write(bb, 1); end;
          if (mask and $08) <> 0 then
          begin
            bb := Byte(cs.Cmd); bs.Write(bb, 1);
            bb := Byte(cs.Param); bs.Write(bb, 1);
          end;
        end;
        bb := 0; bs.Write(bb, 1);   { end of row }
      end;
      packs[p] := Copy(bs.Bytes, 0, bs.Size);
    finally
      bs.Free;
    end;
  end;

  tablesEnd := 192 + ordNum + 1 * 4 + ANumPat * 4;
  smpHdrOfs := tablesEnd;
  curOfs := tablesEnd + 80;
  SetLength(patOfs, ANumPat);
  for p := 0 to ANumPat - 1 do
  begin
    patOfs[p] := curOfs;
    Inc(curOfs, 8 + Length(packs[p]));
  end;

  st := TBytesStream.Create;
  try
    SetLength(hdr, 192);
    FillChar(hdr[0], 192, 0);
    hdr[0] := Ord('I'); hdr[1] := Ord('M'); hdr[2] := Ord('P'); hdr[3] := Ord('M');
    nm := 'PHASE14 MPTM TEST';
    for i := 0 to Length(nm) - 1 do hdr[4 + i] := Byte(nm[i + 1]);
    PutW(hdr, 32, ordNum);
    PutW(hdr, 34, 0);
    PutW(hdr, 36, 1);
    PutW(hdr, 38, ANumPat);
    PutW(hdr, 40, $5000);
    PutW(hdr, 42, $0214);
    PutW(hdr, 44, $0009);
    hdr[48] := 128;
    hdr[50] := 6;
    hdr[51] := 125;
    st.WriteBuffer(hdr[0], 192);

    SetLength(tbl, ordNum);
    for i := 0 to ordNum - 1 do tbl[i] := Byte(AOrder[i]);
    if ordNum > 0 then st.WriteBuffer(tbl[0], ordNum);

    SetLength(tbl, 4 + ANumPat * 4);
    FillChar(tbl[0], Length(tbl), 0);
    PutD(tbl, 0, smpHdrOfs);
    for p := 0 to ANumPat - 1 do PutD(tbl, 4 + p * 4, patOfs[p]);
    st.WriteBuffer(tbl[0], Length(tbl));

    { sample header }
    SetLength(sh, 80);
    FillChar(sh[0], 80, 0);
    sh[0] := Ord('I'); sh[1] := Ord('M'); sh[2] := Ord('P'); sh[3] := Ord('S');
    sh[17] := 64;
    sh[18] := $01 or $10;                 { has sample, 8-bit, loop on }
    sh[19] := 64;                         { default volume }
    sh[46] := $01;                        { Cvt: signed }
    sh[47] := $80 or 32;                  { centre pan }
    PutD(sh, 48, ASampleBytes);           { length in frames }
    PutD(sh, 52, 0);                      { loop begin }
    PutD(sh, 56, ASampleBytes);           { loop end }
    PutD(sh, 60, 8363);                   { C5Speed }
    PutD(sh, 72, curOfs);                 { sample data pointer }
    st.WriteBuffer(sh[0], 80);

    for p := 0 to ANumPat - 1 do
    begin
      SetLength(ph, 8);
      FillChar(ph[0], 8, 0);
      PutW(ph, 0, Length(packs[p]));
      PutW(ph, 2, 64);
      st.WriteBuffer(ph[0], 8);
      if Length(packs[p]) > 0 then st.WriteBuffer(packs[p][0], Length(packs[p]));
    end;

    pcm := SineS8(ASampleCycles, ASampleBytes);
    st.WriteBuffer(pcm[0], Length(pcm));

    Result := Copy(st.Bytes, 0, st.Size);
  finally
    st.Free;
  end;
end;

{ ---------------- IT2.14 / IT2.15 compressed-sample decode ---------------- }

{ LSB-first pack ACodes (each a fixed AWidth-bit value) into bytes - used to
  build a compressed-sample block whose codes are all in 0..255 with
  AWidth=9, so the decoder's "high" branch (raw pass-through, width never
  changes) is taken for every sample. This isolates and exercises the
  bit-reader / delta-accumulation core independently of the escape /
  width-change logic. }
function PackBitsLSB(const ACodes: array of Integer; AWidth: Integer): TBytes;
var
  st: TBytesStream;
  bitBuf: Cardinal;
  bitNum, i: Integer;
  bb: Byte;
begin
  st := TBytesStream.Create;
  try
    bitBuf := 0; bitNum := 0;
    for i := 0 to High(ACodes) do
    begin
      bitBuf := bitBuf or (Cardinal(ACodes[i]) shl bitNum);
      Inc(bitNum, AWidth);
      while bitNum >= 8 do
      begin
        bb := Byte(bitBuf and $FF);
        st.Write(bb, 1);
        bitBuf := bitBuf shr 8;
        Dec(bitNum, 8);
      end;
    end;
    if bitNum > 0 then
    begin
      bb := Byte(bitBuf and $FF);
      st.Write(bb, 1);
    end;
    Result := Copy(st.Bytes, 0, st.Size);
  finally
    st.Free;
  end;
end;

{ A minimal IT/MPTM file - no patterns, no orders, one 8-bit compressed
  sample built from a single IT block of raw width-9 codes (each 0..255). }
function BuildMptmCompressed8(ACwtv: Integer; const ADeltas: array of Byte): TBytes;
var
  st: TBytesStream;
  hdr, tbl, sh, blk, packedBits: TBytes;
  i, sampleHdrOfs, blockOfs: Integer;
  codes: array of Integer;
begin
  SetLength(codes, Length(ADeltas));
  for i := 0 to High(ADeltas) do codes[i] := ADeltas[i];
  packedBits := PackBitsLSB(codes, 9);

  sampleHdrOfs := 192 + 1 * 4;      { header + one 4-byte sample offset entry }
  blockOfs := sampleHdrOfs + 80;

  st := TBytesStream.Create;
  try
    SetLength(hdr, 192);
    FillChar(hdr[0], 192, 0);
    hdr[0] := Ord('I'); hdr[1] := Ord('M'); hdr[2] := Ord('P'); hdr[3] := Ord('M');
    PutW(hdr, 32, 0);            { ordNum }
    PutW(hdr, 34, 0);            { insNum: sample mode }
    PutW(hdr, 36, 1);            { smpNum }
    PutW(hdr, 38, 0);            { patNum }
    PutW(hdr, 40, ACwtv);
    PutW(hdr, 42, ACwtv);
    PutW(hdr, 44, $0009);
    hdr[48] := 128; hdr[50] := 6; hdr[51] := 125;
    st.WriteBuffer(hdr[0], 192);

    SetLength(tbl, 4);
    PutD(tbl, 0, sampleHdrOfs);
    st.WriteBuffer(tbl[0], 4);

    SetLength(sh, 80);
    FillChar(sh[0], 80, 0);
    sh[0] := Ord('I'); sh[1] := Ord('M'); sh[2] := Ord('P'); sh[3] := Ord('S');
    sh[17] := 64;
    sh[18] := $01 or $08;         { has sample, 8-bit, compressed }
    sh[19] := 64;
    sh[46] := $01;
    sh[47] := $80 or 32;
    PutD(sh, 48, Length(ADeltas));  { length in frames }
    PutD(sh, 60, 8363);             { C5Speed }
    PutD(sh, 72, blockOfs);         { sample data pointer: the block-length prefix }
    st.WriteBuffer(sh[0], 80);

    SetLength(blk, 2);
    PutW(blk, 0, Length(packedBits));
    st.WriteBuffer(blk[0], 2);
    if Length(packedBits) > 0 then st.WriteBuffer(packedBits[0], Length(packedBits));

    Result := Copy(st.Bytes, 0, st.Size);
  finally
    st.Free;
  end;
end;

procedure Test_Decompress_IT214;
var
  data: TBytes;
  info: TMPTMImportInfo;
  m: TTrackerModule;
  ins: TTrackerInstrument;
begin
  { cwtv $0214: single-delta (IT2.14) scheme. Deltas chosen to exercise
    unsigned wraparound (250 + 10 -> wraps past 256) and a negative result. }
  data := BuildMptmCompressed8($0214, [10, 250, 5, 200]);
  m := MptmToModule(data, info);
  try
    CheckEqualInt(1, info.CompressedSamples, 'the compressed sample is detected');
    CheckEqualInt(1, info.UsedSamples, 'and decoded (not skipped)');
    ins := m.GetInstrument(1);
    Check(ins <> nil, 'instrument slot created');
    CheckEqualInt(4, ins.FrameCount, 'decoded frame count matches the header');
    CheckNear(10 / 128.0, ins.Data[0], 1e-6, 'IT2.14 sample 0');
    CheckNear(4 / 128.0, ins.Data[1], 1e-6, 'IT2.14 sample 1 (wraps past 256)');
    CheckNear(9 / 128.0, ins.Data[2], 1e-6, 'IT2.14 sample 2');
    CheckNear(-47 / 128.0, ins.Data[3], 1e-6, 'IT2.14 sample 3 (wraps negative)');
  finally
    m.Free;
  end;
end;

procedure Test_Decompress_IT215;
var
  data: TBytes;
  info: TMPTMImportInfo;
  m: TTrackerModule;
  ins: TTrackerInstrument;
begin
  { cwtv $0215: double-delta (IT2.15) scheme - same raw codes, different
    (delta-of-delta) accumulation, so this also proves the two schemes are
    not accidentally aliased to the same code path. }
  data := BuildMptmCompressed8($0215, [10, 250, 5, 200]);
  m := MptmToModule(data, info);
  try
    ins := m.GetInstrument(1);
    CheckEqualInt(4, ins.FrameCount, 'decoded frame count matches the header');
    CheckNear(10 / 128.0, ins.Data[0], 1e-6, 'IT2.15 sample 0');
    CheckNear(14 / 128.0, ins.Data[1], 1e-6, 'IT2.15 sample 1 (delta-of-delta)');
    CheckNear(23 / 128.0, ins.Data[2], 1e-6, 'IT2.15 sample 2');
    CheckNear(-24 / 128.0, ins.Data[3], 1e-6, 'IT2.15 sample 3 (wraps negative)');
  finally
    m.Free;
  end;
end;

procedure Test_Decompress_Malformed_Safe;
var
  data, evil: TBytes;
begin
  { a truncated compressed block (declared length runs past EOF) must clamp
    and zero-pad, never crash or read out of bounds }
  data := BuildMptmCompressed8($0215, [10, 250, 5, 200, 77, 99, 123, 8]);
  evil := Copy(data, 0, Length(data) - 3);
  with MptmToModule(evil) do
  try
    Check(GetInstrument(1) <> nil, 'a truncated compressed sample still builds a module');
  finally
    Free;
  end;
end;

{ ---------------- tests ---------------- }

procedure Test_Sniff;
var
  data, junk: TBytes;
begin
  data := BuildMptm(4, 1, [0], [Spec(0, 0, 0, 61, 1, -1, 0, 0)]);
  Check(DataLooksLikeMptm(data), 'generated buffer sniffs as IMPM');
  Check(MptmKindFromData(data), 'MptmKindFromData agrees');
  SetLength(junk, 4000);
  FillChar(junk[0], Length(junk), 0);
  CheckFalse(DataLooksLikeMptm(junk), 'all-zero buffer is not IMPM');
end;

procedure Test_Import_Structure;
var
  data: TBytes;
  info: TMPTMImportInfo;
  m: TTrackerModule;
begin
  data := BuildMptm(6, 3, [0, 1, 2, 1],
    [Spec(0, 0, 0, 61, 1, -1, 0, 0), Spec(2, 0, 5, 0, 1, -1, 0, 0)]);
  m := MptmToModule(data, info);
  try
    CheckEqualInt(6, m.Channels, 'channel count from the pattern scan');
    CheckEqualInt(3, m.PatternCount, 'pattern count');
    CheckEqualInt(4, m.OrderLength, 'order length');
    CheckEqualInt(1, m.InstrumentCount, 'one instrument slot (sample mode)');
    CheckEqualStr('PHASE14 MPTM TEST', m.Name, 'song title');
    CheckFalse(info.InstrumentMode, 'sample mode detected');
    Check(m.GetInstrument(1).FrameCount = 512, 'sample PCM length');
    Check(m.GetInstrument(1).LoopMode = tlmForward, 'whole-sample forward loop');
    CheckEqualInt(61, m.GetPattern(0).GetCell(0, 0).Note, 'IT note 60 -> internal C-5 (61)');
    CheckEqualInt(1, m.GetPattern(0).GetCell(0, 0).Instrument, 'instrument 1 referenced');
  finally
    m.Free;
  end;
end;

procedure Test_Effect_And_VolColumn;
var
  data: TBytes;
  m: TTrackerModule;
  info: TMPTMImportInfo;
  p: TTrackerPattern;

  procedure ExpectFx(ARow: Integer; AEff: TTrackerEffect; AParam: Integer; const AWhat: string);
  var cell: TTrackerCell;
  begin
    cell := p.GetCell(ARow, 0);
    Check(cell.Effect = AEff, AWhat + ': effect');
    CheckEqualInt(AParam, cell.Param, AWhat + ': param');
  end;

begin
  data := BuildMptm(1, 1, [0],
    [ Spec(0, 0, 0, 0, 0, -1, 10, $37),   // J arpeggio 3/7
      Spec(0, 1, 0, 0, 0, -1, 1,  $06),   // A set speed 6
      Spec(0, 2, 0, 0, 0, -1, 3,  12),    // C pattern break -> row 12 (plain, no BCD)
      Spec(0, 3, 0, 0, 0, -1, 19, $C4),   // S C4 -> note cut on tick 4
      Spec(0, 4, 0, 0, 0, -1, 24, $80),   // X set panning 0x80
      Spec(0, 5, 0, 0, 0, -1, 22, $40),   // V set global volume -> no internal equivalent
      Spec(0, 6, 0, 0, 0, 32,  0,  0),    // volume column: set volume 32
      Spec(0, 7, 0, 0, 0, 144, 0,  0) ]); // volume column 144 -> set panning
  m := MptmToModule(data, info);
  try
    p := m.GetPattern(0);
    ExpectFx(0, tfxArpeggio, $37, 'J arpeggio');
    ExpectFx(1, tfxSetSpeed, $06, 'A set speed');
    ExpectFx(2, tfxPatternBreak, 12, 'C pattern break is not BCD');
    ExpectFx(3, tfxNoteCut, 4, 'S C4 note cut');
    ExpectFx(4, tfxSetPanning, $80, 'X set panning');
    Check(p.GetCell(5, 0).Effect = tfxNone, 'unmapped V leaves no effect');
    CheckEqualInt(32, p.GetCell(6, 0).Volume, 'volume column set-volume 32');
    Check(p.GetCell(7, 0).Effect = tfxSetPanning, 'volume column 144 -> set panning');
    Check(info.LostEffectCells >= 1, 'the dropped command is counted');
  finally
    m.Free;
  end;
end;

procedure Test_Play_Tone;
var
  data: TBytes;
  m: TTrackerModule;
  pl: TTrackerPlayer;
  o: TAudioPlanar;
begin
  data := BuildMptm(4, 1, [0], [Spec(0, 0, 0, 61, 1, -1, 0, 0)], 27, 512);
  m := MptmToModule(data);
  pl := nil;
  try
    pl := TTrackerPlayer.Create(m);
    pl.LoopSong := True;
    o := pl.RenderToPlanar(SR div 2, 2);
    Check(AllFinitePl(o), 'rendered output is finite');
    Check(PlanarRms(o, 0, SR div 20, Length(o[0])) > 0.03, 'the note produces audio');
    CheckNear(441.0, DomFreq(o, 0, SR div 20, Length(o[0])), 40.0, 'C-5 sample streams at ~441 Hz');
  finally
    pl.Free;
    m.Free;
  end;
end;

procedure Test_Play_OctaveDown;
var
  hi, lo: TBytes;
  m1, m2: TTrackerModule;
  p1, p2: TTrackerPlayer;
  o1, o2: TAudioPlanar;
  f1, f2: Double;
begin
  hi := BuildMptm(4, 1, [0], [Spec(0, 0, 0, 61, 1, -1, 0, 0)], 27, 512);
  lo := BuildMptm(4, 1, [0], [Spec(0, 0, 0, 49, 1, -1, 0, 0)], 27, 512);
  m1 := MptmToModule(hi);
  m2 := MptmToModule(lo);
  p1 := nil; p2 := nil;
  try
    p1 := TTrackerPlayer.Create(m1);
    p2 := TTrackerPlayer.Create(m2);
    o1 := p1.RenderToPlanar(SR div 2, 2);
    o2 := p2.RenderToPlanar(SR div 2, 2);
    f1 := DomFreq(o1, 0, SR div 20, Length(o1[0]));
    f2 := DomFreq(o2, 0, SR div 20, Length(o2[0]));
    Check((f1 > 0) and (f2 > 0), 'both render a pitch');
    CheckNear(2.0, f1 / f2, 0.15, 'one octave lower halves the frequency');
  finally
    p1.Free; p2.Free;
    m1.Free; m2.Free;
  end;
end;

procedure Test_Export_RoundTrip;
var
  data, data2: TBytes;
  a, b: TTrackerModule;
  ca, cb: TTrackerCell;
begin
  data := BuildMptm(4, 2, [0, 1],
    [ Spec(0, 0, 0, 61, 1, -1, 0, 0),
      Spec(0, 4, 0, 49, 1, -1, 10, $24),
      Spec(0, 8, 0, 0, 0, -1, 3, 8),
      Spec(1, 0, 1, 40, 1, -1, 0, 0) ]);
  a := MptmToModule(data);
  try
    data2 := ModuleToMptm(a);
    Check(DataLooksLikeMptm(data2), 're-exported bytes still sniff as IMPM');
    b := MptmToModule(data2);
    try
      CheckEqualInt(a.Channels, b.Channels, 'channels survive export');
      CheckEqualInt(a.PatternCount, b.PatternCount, 'pattern count survives');
      CheckEqualInt(a.OrderLength, b.OrderLength, 'order length survives');

      ca := a.GetPattern(0).GetCell(0, 0);
      cb := b.GetPattern(0).GetCell(0, 0);
      CheckEqualInt(ca.Note, cb.Note, 'note 0,0 round-trips');
      CheckEqualInt(ca.Instrument, cb.Instrument, 'instrument 0,0 round-trips');

      cb := b.GetPattern(0).GetCell(4, 0);
      Check(cb.Effect = tfxArpeggio, 'arpeggio round-trips');
      CheckEqualInt($24, cb.Param, 'arpeggio param round-trips');

      cb := b.GetPattern(0).GetCell(8, 0);
      Check(cb.Effect = tfxPatternBreak, 'pattern break round-trips');
      CheckEqualInt(8, cb.Param, 'pattern break row round-trips (plain, no BCD)');

      Check(b.GetInstrument(1).FrameCount = a.GetInstrument(1).FrameCount,
        'sample length round-trips');
    finally
      b.Free;
    end;
  finally
    a.Free;
  end;
end;

procedure Test_Export_Issues;
var
  m: TTrackerModule;
  issues: TArray<string>;
  i: Integer;
  joined: string;
  cell: TTrackerCell;
begin
  m := TTrackerModule.Create;
  try
    m.Clear;
    m.SetChannels(4);
    m.AddInstrument('clean');
    m.AddPattern(64);
    m.AppendOrder(0);
    cell := TTrackerCell.Empty;
    cell.Effect := tfxPanSlide;   { representable in IT }
    cell.Param := $11;
    m.GetPattern(0).SetCell(0, 0, cell);

    issues := MptmExportIssues(m);
    joined := '';
    for i := 0 to High(issues) do joined := joined + issues[i] + ' | ';
    Check(Pos('IT-compatible core', joined) > 0, 'notes that export is a plain IT core');
  finally
    m.Free;
  end;
end;

procedure Test_Import_RejectsGarbage;
var
  junk: TBytes;
begin
  SetLength(junk, 2500);
  FillChar(junk[0], Length(junk), $AA);
  try
    MptmToModule(junk).Free;
    Fail('garbage should not parse as an MPTM');
  except
    on E: EUDAWError do CheckEqualInt(Ord(errConfig), Ord(E.Code), 'errConfig on a non-IMPM buffer');
  end;
end;

procedure Test_Malformed_Safe;
var
  data, chopped, evil: TBytes;
begin
  data := BuildMptm(4, 3, [0, 1, 2], [Spec(0, 0, 0, 61, 1, -1, 0, 0)]);

  { 1) truncated mid-file: must not raise anything but EUDAWError, must not crash }
  SetLength(chopped, 260);
  Move(data[0], chopped[0], Length(chopped));
  try
    MptmToModule(chopped).Free;
  except
    on E: EUDAWError do ;   { acceptable }
  end;

  { 2) enormous declared sample length + bogus pattern rows: clamped, no OOM }
  evil := Copy(data);
  PutD(evil, 192 + 3 { ordNum } + 4 + 3 * 4 + 48, $7FFFFFFF);  { sample length dword }
  with MptmToModule(evil) do
  try
    Check(Channels >= 1, 'a hostile sample length is clamped, module still built');
  finally
    Free;
  end;

  { 3) header claims far more patterns than the file can hold }
  evil := Copy(data);
  PutW(evil, 38, 9999);
  try
    MptmToModule(evil).Free;
  except
    on E: EUDAWError do ;   { rejected cleanly is fine }
  end;
end;

procedure Test_ImportCommand_UndoRedo;
var
  doc: TProjectDocument;
  mgr: TCommandManager;
  data: TBytes;
  before: string;
begin
  doc := TProjectDocument.CreateNew('mptm host');
  mgr := TCommandManager.Create;
  try
    before := doc.Tracker.Name;
    data := BuildMptm(4, 2, [0, 1], [Spec(0, 0, 0, 61, 1, -1, 0, 0)]);
    mgr.Perform(TImportMptmCommand.Create(doc, data, 'MPTM'));
    CheckEqualStr('PHASE14 MPTM TEST', doc.Tracker.Name, 'module replaced by the import');
    CheckEqualInt(2, doc.Tracker.PatternCount, 'imported patterns present');
    mgr.Undo;
    CheckEqualStr(before, doc.Tracker.Name, 'undo restores the previous module');
    mgr.Redo;
    CheckEqualStr('PHASE14 MPTM TEST', doc.Tracker.Name, 'redo re-imports');
  finally
    mgr.Free;
    doc.Free;
  end;
end;

procedure Test_ImportedModule_EmbedsInProject;
var
  doc, back: TProjectDocument;
  data: TBytes;
  s: string;
begin
  doc := TProjectDocument.CreateNew('embed');
  try
    data := BuildMptm(4, 2, [0, 1, 1],
      [Spec(0, 0, 0, 61, 1, -1, 0, 0), Spec(1, 8, 0, 49, 1, -1, 3, $10)]);
    doc.ReplaceTracker(MptmToModule(data));
    s := ProjectToString(doc);
    back := ProjectFromString(s);
    try
      CheckEqualStr('PHASE14 MPTM TEST', back.Tracker.Name, 'imported module name persists');
      CheckEqualInt(2, back.Tracker.PatternCount, 'patterns persist');
      CheckEqualInt(3, back.Tracker.OrderLength, 'order table persists');
      CheckEqualInt(61, back.Tracker.GetPattern(0).GetCell(0, 0).Note, 'a cell persists');
    finally
      back.Free;
    end;
  finally
    doc.Free;
  end;
end;

{ ---------------- registration ---------------- }

procedure RegisterPhase14Tests;
begin
  RegisterTest('mptm.sniff',  'kind detection',           @Test_Sniff);
  RegisterTest('mptm.import', 'structure',                @Test_Import_Structure);
  RegisterTest('mptm.import', 'effect + volume column',   @Test_Effect_And_VolColumn);
  RegisterTest('mptm.import', 'rejects garbage',          @Test_Import_RejectsGarbage);
  RegisterTest('mptm.import', 'malformed files stay safe', @Test_Malformed_Safe);
  RegisterTest('mptm.import', 'IT2.14 compressed sample decodes',  @Test_Decompress_IT214);
  RegisterTest('mptm.import', 'IT2.15 compressed sample decodes',  @Test_Decompress_IT215);
  RegisterTest('mptm.import', 'truncated compressed sample stays safe', @Test_Decompress_Malformed_Safe);
  RegisterTest('mptm.play',   'note plays a tone',        @Test_Play_Tone);
  RegisterTest('mptm.play',   'octave down halves pitch', @Test_Play_OctaveDown);
  RegisterTest('mptm.export', 'byte-level round trip',    @Test_Export_RoundTrip);
  RegisterTest('mptm.export', 'representability report',  @Test_Export_Issues);
  RegisterTest('mptm.cmd',    'import command undo/redo', @Test_ImportCommand_UndoRedo);
  RegisterTest('mptm.cmd',    'imported module embeds',   @Test_ImportedModule_EmbedsInProject);
end;

end.
