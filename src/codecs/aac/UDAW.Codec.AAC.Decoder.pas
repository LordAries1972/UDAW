unit UDAW.Codec.AAC.Decoder;
{$I udaw.inc}
{$POINTERMATH ON}

{ Phase 16b - AAC-LC decoder (ISO/IEC 14496-3 subclause 4.5, Low Complexity
  profile; the HE-AAC core also runs through here, SBR/PS reconstruction is a
  separate pass).

  TAACDecoder decodes one raw_data_block per DecodeFrame call into the
  engine-wide planar Float32 layout, 1024 (or 960) samples per channel.  The
  pipeline is the standard one:

    raw_data_block
      -> per element (SCE / CPE / LFE):
           individual_channel_stream:
             global_gain, ics_info, section_data, scale_factor_data,
             pulse_data, tns_data, spectral_data (Huffman + escape)
      -> inverse quantisation  x = sign(q) * |q|^(4/3) * 2^(0.25*(sf-100))
      -> PNS (perceptual noise substitution) fill
      -> TNS synthesis lattice (all-pole)
      -> M/S stereo  (per CPE, per group/sfb)
      -> intensity stereo
      -> filterbank: IMDCT (2048 long / 8x256 short), window (KBD|sine, with the
         previous frame's shape on the left half), overlap-add

  It does NOT implement AAC-Main prediction (LC has none) - the predictor bits
  are parsed and skipped so a Main stream still stays bit-aligned.  Coupling
  channel elements (CCE) are parsed and skipped.  A stream whose Huffman
  codebooks are not populated (see UDAW.Codec.AAC.HuffData.inc) is refused up
  front with a precise errNotImplemented. }

interface

uses
  SysUtils, Math,
  UDAW.Errors, UDAW.Audio.Types, UDAW.DSP.FFT,
  UDAW.Codec.AAC.Types, UDAW.Codec.AAC.Tables;

type
  TAACDecodeStatus = (adsOK, adsRefusedNoTables, adsError);

  { per single channel of ICS state that must persist between frames }
  TAacChannelState = record
    Overlap: array[0..1023] of Double;    // left half carry (max 1024)
    PrevWindowShape: Integer;
    Initialised: Boolean;
  end;

  TAacTnsData = record
    NFilt: array[0..7] of Integer;
    CoefRes: array[0..7] of Integer;
    Len: array[0..7, 0..2] of Integer;
    Order: array[0..7, 0..2] of Integer;
    Dir: array[0..7, 0..2] of Integer;
    Coef: array[0..7, 0..2, 0..31] of Double;
    Present: Boolean;
  end;

  TAacPulseData = record
    Count, StartSfb: Integer;
    Offset: array[0..3] of Integer;
    Amp: array[0..3] of Integer;
  end;

  TAACDecoder = class
  private
    FCfg: TAacAudioConfig;
    FSampleRate: Integer;
    FFrameLen: Integer;                    // 1024 or 960
    FShortLen: Integer;                    // 128 or 120
    FSrIndex: Integer;
    FChannels: Integer;
    FHaveTables: Boolean;
    FChState: array[0..AAC_MAX_CHANNELS - 1] of TAacChannelState;
    { scratch reused each element }
    FSpec: array[0..1, 0..1023] of Double;         // 2 channels of a CPE
    FSfbCb: array[0..1, 0..7, 0..AAC_MAX_SFB_LONG - 1] of Integer;
    FScf:   array[0..1, 0..7, 0..AAC_MAX_SFB_LONG - 1] of Double;   // gain 2^(0.25*(sf-100))
    FIsPos: array[0..1, 0..7, 0..AAC_MAX_SFB_LONG - 1] of Integer;
    FWinSeq: array[0..1] of Integer;
    FWinShape: array[0..1] of Integer;
    FMaxSfb: array[0..1] of Integer;
    FNumWindows: array[0..1] of Integer;
    FNumGroups: array[0..1] of Integer;
    FGroupLen: array[0..1, 0..7] of Integer;
    FGlobalGain: array[0..1] of Integer;
    FScaleGrouping: array[0..1] of Integer;
    FMsMask: Integer;                              // 0 none, 1 per-sfb, 2 all
    FMsUsed: array[0..7, 0..AAC_MAX_SFB_LONG - 1] of Boolean;
    FTns: array[0..1] of TAacTnsData;
    FPulsePresent: array[0..1] of Boolean;
    FPulse: array[0..1] of TAacPulseData;
    FNoiseState: Cardinal;
    FSbrSeen: Boolean;

    procedure ResetChannelState;
    function NextNoise: Double;
    procedure ReadICSInfo(var ABr: TAacBitReader; c: Integer);
    procedure ReadSectionData(var ABr: TAacBitReader; c: Integer);
    procedure ReadScaleFactors(var ABr: TAacBitReader; c: Integer);
    procedure ReadPulseData(var ABr: TAacBitReader; c: Integer);
    procedure ReadTNSData(var ABr: TAacBitReader; c: Integer);
    procedure ReadSpectralData(var ABr: TAacBitReader; c: Integer);
    procedure DecodeICS(var ABr: TAacBitReader; c: Integer; ACommonWindow: Boolean);
    procedure Dequantise(c: Integer);
    procedure ApplyPulses(c: Integer);
    procedure ApplyPNS(c: Integer; AOtherC: Integer; APair: Boolean);
    procedure ApplyTNS(c: Integer; AInverse: Boolean);
    procedure ApplyMSStereo;
    procedure ApplyIntensity;
    procedure Filterbank(c: Integer; AOutChannel: Integer; var AOut: TAudioPlanar);
    function SwbTable(c: Integer): TArray<Integer>;
  public
    constructor Create;
    procedure InitFromConfig(const ACfg: TAacAudioConfig);
    procedure InitFromParams(AObjectType, ASampleRate, AChannelConfig: Integer);
    procedure Flush;                        // clear overlap between discontinuities

    { Decode one raw_data_block sitting at ABr's current position.  On success
      AOut is planar [FChannels][FrameLen] and AProduced = FrameLen. }
    function DecodeFrame(var ABr: TAacBitReader; var AOut: TAudioPlanar;
      out AProduced: Integer): TAACDecodeStatus;

    property SampleRate: Integer read FSampleRate;
    property Channels: Integer read FChannels;
    property FrameLength: Integer read FFrameLen;
    property Config: TAacAudioConfig read FCfg;
    property HaveTables: Boolean read FHaveTables;
    { an SBR extension payload was met in a fill element: the stream carries
      high-band data this decoder does not reconstruct }
    property SbrSeen: Boolean read FSbrSeen;
  end;

implementation

const
  DEC_SUBSYS = 'Codec.AAC.Dec';
  { 2^(0.25*(sf - SCALE_CONST)) is the inverse-quantisation gain exponent
    base.  This was 100 (the textbook ISO SF_OFFSET), which is right for the
    scale-factor DELTA arithmetic but leaves the dequantised PCM exactly
    2^16 too loud - measured empirically: decoding real AAC-LC files (an
    Android voice memo and an unrelated music file) and correlating sample-
    for-sample against ffmpeg's decode of the same files gave >0.99999
    waveform correlation (i.e. the dequant/TNS/IMDCT/window math is right)
    but a constant, content-independent amplitude ratio of 65536.03/65535.91
    - i.e. exactly 2^16 - on both, unrelated, files.  0.25*64 = 16, so
    shifting this constant by 64 (100 -> 164) removes exactly that factor
    with no other change to the formula.  Re-verified after the change:
    both files land within 0.01% of ffmpeg's PCM. }
  SCALE_CONST = 164;
  NOISE_OFFSET = 90;

{ ============================ construction ====================== }

constructor TAACDecoder.Create;
var
  err: string;
begin
  inherited Create;
  InitAacTables;
  FHaveTables := HuffBooksSelfCheck(err);
  FNoiseState := $1F2E3D4C;
end;

procedure TAACDecoder.ResetChannelState;
var
  i: Integer;
begin
  for i := 0 to AAC_MAX_CHANNELS - 1 do
  begin
    FillChar(FChState[i].Overlap, SizeOf(FChState[i].Overlap), 0);
    FChState[i].PrevWindowShape := WSHAPE_SINE;
    FChState[i].Initialised := True;
  end;
end;

procedure TAACDecoder.InitFromConfig(const ACfg: TAacAudioConfig);
begin
  FCfg := ACfg;
  FSampleRate := ACfg.SampleRate;
  if FSampleRate <= 0 then FSampleRate := 44100;
  FSrIndex := ACfg.SampleRateIndex;
  if (FSrIndex < 0) or (FSrIndex > 12) then
  begin
    FSrIndex := AacIndexFromRate(FSampleRate);
    if FSrIndex < 0 then FSrIndex := 4;
  end;
  if ACfg.FrameLength = AAC_LONG_WIN_LEN_960 then
  begin
    FFrameLen := 960; FShortLen := 120;
  end
  else
  begin
    FFrameLen := 1024; FShortLen := 128;
  end;
  FChannels := ACfg.Channels;
  if FChannels <= 0 then FChannels := 2;    // PCE-defined; refined on first PCE
  ResetChannelState;
end;

procedure TAACDecoder.InitFromParams(AObjectType, ASampleRate, AChannelConfig: Integer);
var
  cfg: TAacAudioConfig;
  asc: TBytes;
begin
  asc := BuildAudioSpecificConfig(AObjectType, ASampleRate, AChannelConfig);
  ParseAudioSpecificConfig(asc, cfg);
  InitFromConfig(cfg);
end;

procedure TAACDecoder.Flush;
begin
  ResetChannelState;
end;

{ ============================ helpers ========================== }

{ The generator's arithmetic wraps modulo 2^32 on purpose - overflow checking
  would turn that into an exception (and the frame into silence). }
{$IFOPT Q+}{$DEFINE UDAW_AAC_RESTORE_Q}{$Q-}{$ENDIF}
{$IFOPT R+}{$DEFINE UDAW_AAC_RESTORE_R}{$R-}{$ENDIF}
function TAACDecoder.NextNoise: Double;
begin
  { 32-bit linear congruential generator (the sequence is not normative; this
    one is the common reference choice, so output can be compared sample for
    sample with reference decoders) }
  FNoiseState := FNoiseState * 1664525 + 1013904223;
  Result := Integer(FNoiseState);
end;
{$IFDEF UDAW_AAC_RESTORE_Q}{$Q+}{$UNDEF UDAW_AAC_RESTORE_Q}{$ENDIF}
{$IFDEF UDAW_AAC_RESTORE_R}{$R+}{$UNDEF UDAW_AAC_RESTORE_R}{$ENDIF}

function TAACDecoder.SwbTable(c: Integer): TArray<Integer>;
begin
  if FWinSeq[c] = WS_EIGHT_SHORT then
    Result := SwbOffsetShort(FSrIndex)
  else
    Result := SwbOffsetLong(FSrIndex);
end;

{ ============================ ics_info ========================= }

procedure TAACDecoder.ReadICSInfo(var ABr: TAacBitReader; c: Integer);
var
  i, predSfb, grp: Integer;
  predPresent: Boolean;
begin
  ABr.SkipBits(1);                                  // ics_reserved_bit
  FWinSeq[c]   := ABr.ReadBits(2);
  FWinShape[c] := ABr.ReadBit;

  if FWinSeq[c] = WS_EIGHT_SHORT then
  begin
    FMaxSfb[c] := ABr.ReadBits(4);
    FScaleGrouping[c] := ABr.ReadBits(7);
    FNumWindows[c] := 8;
    { window_group_length from scale_factor_grouping: bit i (from MSB, i=1..7)
      set means window i is grouped with the previous }
    FNumGroups[c] := 1;
    FGroupLen[c, 0] := 1;
    grp := 0;
    for i := 1 to 7 do
    begin
      if (FScaleGrouping[c] and (1 shl (7 - i))) <> 0 then
        Inc(FGroupLen[c, grp])
      else
      begin
        Inc(grp);
        FGroupLen[c, grp] := 1;
      end;
    end;
    FNumGroups[c] := grp + 1;
  end
  else
  begin
    FMaxSfb[c] := ABr.ReadBits(6);
    FNumWindows[c] := 1;
    FNumGroups[c] := 1;
    FGroupLen[c, 0] := 1;
    predPresent := ABr.ReadBit = 1;
    if predPresent then
    begin
      { AAC-Main predictor_data - LC has none; parse to stay aligned }
      if ABr.ReadBit = 1 then                        // predictor_reset
        ABr.SkipBits(5);                             // predictor_reset_group_number
      predSfb := FMaxSfb[c];
      if predSfb > 40 then predSfb := 40;            // PRED_SFB_MAX ceiling
      for i := 0 to predSfb - 1 do
        ABr.SkipBits(1);                             // prediction_used[sfb]
    end;
  end;

  if FMaxSfb[c] > AAC_MAX_SFB_LONG then FMaxSfb[c] := AAC_MAX_SFB_LONG;
end;

{ ============================ section_data ==================== }

procedure TAACDecoder.ReadSectionData(var ABr: TAacBitReader; c: Integer);
var
  g, k, sectBits, escVal, sectCb, sectLen, sfb: Integer;
begin
  for g := 0 to 7 do
    for k := 0 to AAC_MAX_SFB_LONG - 1 do
      FSfbCb[c, g, k] := HCB_ZERO;

  if FWinSeq[c] = WS_EIGHT_SHORT then sectBits := 3 else sectBits := 5;

  for g := 0 to FNumGroups[c] - 1 do
  begin
    k := 0;
    while k < FMaxSfb[c] do
    begin
      sectCb := ABr.ReadBits(4);
      sectLen := 0;
      escVal := (1 shl sectBits) - 1;
      repeat
        sfb := ABr.ReadBits(sectBits);
        sectLen := sectLen + sfb;
      until sfb <> escVal;
      if k + sectLen > FMaxSfb[c] then sectLen := FMaxSfb[c] - k;
      for sfb := k to k + sectLen - 1 do
        FSfbCb[c, g, sfb] := sectCb;
      k := k + sectLen;
      if ABr.Overrun then Exit;
    end;
  end;
end;

{ ============================ scale_factor_data ============== }

procedure TAACDecoder.ReadScaleFactors(var ABr: TAacBitReader; c: Integer);
var
  g, sfb, cb, delta: Integer;
  sf, isp, ne: Integer;
  noiseStarted: Boolean;
begin
  sf := FGlobalGain[c];
  isp := 0;
  ne := FGlobalGain[c] - NOISE_OFFSET;
  noiseStarted := False;

  for g := 0 to FNumGroups[c] - 1 do
    for sfb := 0 to FMaxSfb[c] - 1 do
    begin
      cb := FSfbCb[c, g, sfb];
      FScf[c, g, sfb] := 0;
      FIsPos[c, g, sfb] := 0;
      case cb of
        HCB_ZERO: ;                                  // nothing
        HCB_INTENSITY, HCB_INTENSITY2:
          begin
            delta := AacHCB[0].Decode(ABr) - 60;
            isp := isp + delta;
            FIsPos[c, g, sfb] := isp;
          end;
        HCB_NOISE:
          begin
            if not noiseStarted then
            begin
              ne := ne + Integer(ABr.ReadBits(9)) - 256;
              noiseStarted := True;
            end
            else
              ne := ne + (AacHCB[0].Decode(ABr) - 60);
            { The noise energy exponent has no 100-step bias (unlike a
              scalefactor), so it sits 100 above the SCALE_CONST-relative
              scalefactor exponent; stored as the band's total-energy gain. }
            if ne < -255 then ne := -255;
            if ne > 255 then ne := 255;
            FScf[c, g, sfb] := GainScale2(ne - SCALE_CONST + 100);
          end;
      else
        begin
          delta := AacHCB[0].Decode(ABr) - 60;
          sf := sf + delta;
          if sf < 0 then sf := 0;
          if sf > 255 then sf := 255;
          FScf[c, g, sfb] := GainScale2(sf - SCALE_CONST);
        end;
      end;
      if ABr.Overrun then Exit;
    end;
end;

{ ============================ pulse_data ==================== }

procedure TAACDecoder.ReadPulseData(var ABr: TAacBitReader; c: Integer);
var
  i: Integer;
begin
  FPulse[c].Count := ABr.ReadBits(2) + 1;
  FPulse[c].StartSfb := ABr.ReadBits(6);
  for i := 0 to FPulse[c].Count - 1 do
  begin
    FPulse[c].Offset[i] := ABr.ReadBits(5);
    FPulse[c].Amp[i] := ABr.ReadBits(4);
  end;
end;

{ ============================ tns_data ==================== }

procedure TAACDecoder.ReadTNSData(var ABr: TAacBitReader; c: Integer);
var
  w, filt, o, nFiltBits, lenBits, ordBits, startBit, compress: Integer;
  coefBits, nWin, k, raw, resBits: Integer;
  iqfac, iqfacM, pc: Double;
begin
  FTns[c].Present := True;
  nWin := FNumWindows[c];
  if FWinSeq[c] = WS_EIGHT_SHORT then
  begin
    nFiltBits := 1; lenBits := 4; ordBits := 3;
  end
  else
  begin
    nFiltBits := 2; lenBits := 6; ordBits := 5;
  end;

  for w := 0 to nWin - 1 do
  begin
    FTns[c].NFilt[w] := ABr.ReadBits(nFiltBits);
    FTns[c].CoefRes[w] := 0;
    if FTns[c].NFilt[w] > 0 then
      FTns[c].CoefRes[w] := ABr.ReadBit;              // 0 -> 3 bit, 1 -> 4 bit
    for filt := 0 to FTns[c].NFilt[w] - 1 do
    begin
      if filt > 2 then Break;
      FTns[c].Len[w, filt] := ABr.ReadBits(lenBits);
      FTns[c].Order[w, filt] := ABr.ReadBits(ordBits);
      o := FTns[c].Order[w, filt];
      FTns[c].Dir[w, filt] := 0;
      if o > 0 then
      begin
        FTns[c].Dir[w, filt] := ABr.ReadBit;
        compress := ABr.ReadBit;
        resBits := 3 + FTns[c].CoefRes[w];
        coefBits := resBits - compress;
        startBit := (1 shl (coefBits - 1));
        { ISO 14496-3 4.6.9.3: the quantiser is asymmetric around zero (step
          (2^(resBits-1) -/+ 0.5) / (pi/2)); a compressed coefficient is stored
          one bit narrower and with its sign inverted. The stored value is the
          reflection (PARCOR) coefficient itself. }
        iqfac := ((1 shl (resBits - 1)) - 0.5) / (Pi / 2);
        iqfacM := ((1 shl (resBits - 1)) + 0.5) / (Pi / 2);
        for k := 0 to o - 1 do
        begin
          raw := Integer(ABr.ReadBits(coefBits));
          if raw >= startBit then raw := raw - 2 * startBit;
          if raw >= 0 then pc := Sin(raw / iqfac) else pc := Sin(raw / iqfacM);
          FTns[c].Coef[w, filt, k] := pc;
        end;
      end;
      if ABr.Overrun then Exit;
    end;
  end;
end;

{ ============================ spectral_data ================ }

procedure TAACDecoder.ReadSpectralData(var ABr: TAacBitReader; c: Integer);
var
  swb: TArray<Integer>;
  g, sfb, win, cb, wOff, gWinLen: Integer;
  k, coefStart, coefEnd, nCoef, i: Integer;
  bk: ^TAacHuffBook;
  leaf, w4, x4, y4, z4: Integer;
  vals: array[0..3] of Integer;
  d: Integer;
  esc, prefix, ev: Integer;
  baseIdx: Integer;
begin
  FillChar(FSpec[c], SizeOf(FSpec[c]), 0);
  swb := SwbTable(c);
  wOff := 0;

  for g := 0 to FNumGroups[c] - 1 do
  begin
    gWinLen := FGroupLen[c, g];
    for sfb := 0 to FMaxSfb[c] - 1 do
    begin
      cb := FSfbCb[c, g, sfb];
      if (cb = HCB_ZERO) or (cb = HCB_NOISE) or
         (cb = HCB_INTENSITY) or (cb = HCB_INTENSITY2) then
        Continue;
      if (cb < 1) or (cb > 11) then Continue;

      bk := @AacHCB[cb];
      if sfb + 1 >= Length(swb) then Break;
      coefStart := swb[sfb];
      coefEnd := swb[sfb + 1];
      nCoef := coefEnd - coefStart;

      for win := 0 to gWinLen - 1 do
      begin
        { destination base for this window inside the deinterleaved group.
          Short: 8 windows each FShortLen long, interleaved by group. }
        if FWinSeq[c] = WS_EIGHT_SHORT then
          baseIdx := (wOff + win) * FShortLen + coefStart
        else
          baseIdx := coefStart;

        k := 0;
        while k < nCoef do
        begin
          leaf := bk^.Decode(ABr);
          bk^.UnpackTuple(leaf, w4, x4, y4, z4);
          if bk^.Dim = 4 then
          begin
            vals[0] := w4; vals[1] := x4; vals[2] := y4; vals[3] := z4;
            d := 4;
          end
          else
          begin
            vals[0] := y4; vals[1] := z4;
            d := 2;
          end;
          if d > nCoef - k then d := nCoef - k;

          { Sign bits for the whole tuple are read as ONE pass over all its
            values, THEN escape codes are read as a SEPARATE second pass over
            all its values - not interleaved per value.  ISO/IEC 14496-3
            subclause 4.6.3.3 (and every real decoder) reads it that way; a
            tuple with two escaped values (both |v|=16, common on loud/
            broadband cb=11 content) has its second value's sign bit sitting
            where an interleaved reader would expect the first value's escape
            bits, desyncing the rest of the frame - which is what surfaced
            downstream as a bogus "gain_control_data / SSR" error. }
          if not bk^.Signed then
            for i := 0 to d - 1 do
              if (vals[i] <> 0) and (ABr.ReadBit = 1) then
                vals[i] := -vals[i];

          if cb = HCB_ESC then
            for i := 0 to d - 1 do
              if Abs(vals[i]) = 16 then
              begin
                prefix := 0;
                while (ABr.ReadBit = 1) and (prefix < 20) do Inc(prefix);
                ev := ABr.ReadBits(prefix + 4);
                esc := ev + (1 shl (prefix + 4));
                if vals[i] < 0 then vals[i] := -esc else vals[i] := esc;
              end;

          for i := 0 to d - 1 do
          begin
            if (baseIdx + k) < 1024 then
              FSpec[c, baseIdx + k] := vals[i];
            Inc(k);
          end;
          if ABr.Overrun then Exit;
        end;
      end;
    end;
    Inc(wOff, gWinLen);
  end;
end;

{ ============================ one ICS ===================== }

procedure TAACDecoder.DecodeICS(var ABr: TAacBitReader; c: Integer;
  ACommonWindow: Boolean);
var
  pulsePresent, tnsPresent, gainPresent: Boolean;
begin
  FGlobalGain[c] := ABr.ReadBits(8);
  if not ACommonWindow then
    ReadICSInfo(ABr, c);

  ReadSectionData(ABr, c);
  ReadScaleFactors(ABr, c);

  pulsePresent := ABr.ReadBit = 1;
  FPulsePresent[c] := pulsePresent;
  if pulsePresent then
    ReadPulseData(ABr, c);

  tnsPresent := ABr.ReadBit = 1;
  FTns[c].Present := False;
  if tnsPresent then
    ReadTNSData(ABr, c);

  gainPresent := ABr.ReadBit = 1;
  if gainPresent then
    { gain_control_data is SSR only - not valid for LC; skip conservatively by
      bailing (the stream is not LC) }
    RaiseUDAW(errNotImplemented, DEC_SUBSYS,
      'gain_control_data present (SSR profile) - not supported');

  ReadSpectralData(ABr, c);
end;

{ ============================ inverse quantise ============ }

procedure TAACDecoder.Dequantise(c: Integer);
var
  swb: TArray<Integer>;
  g, sfb, win, gWinLen, wOff: Integer;
  cs, ce, idx, i: Integer;
  q: Double;
  gain: Double;
begin
  swb := SwbTable(c);
  wOff := 0;
  for g := 0 to FNumGroups[c] - 1 do
  begin
    gWinLen := FGroupLen[c, g];
    for sfb := 0 to FMaxSfb[c] - 1 do
    begin
      if FSfbCb[c, g, sfb] in [HCB_ZERO, HCB_NOISE, HCB_INTENSITY, HCB_INTENSITY2] then
        Continue;
      if sfb + 1 >= Length(swb) then Break;
      cs := swb[sfb]; ce := swb[sfb + 1];
      gain := FScf[c, g, sfb];
      for win := 0 to gWinLen - 1 do
      begin
        for i := cs to ce - 1 do
        begin
          if FWinSeq[c] = WS_EIGHT_SHORT then
            idx := (wOff + win) * FShortLen + i
          else
            idx := i;
          if idx >= 1024 then Break;
          q := FSpec[c, idx];
          if q = 0 then Continue;
          if q > 0 then
            FSpec[c, idx] := Iq43(Round(q)) * gain
          else
            FSpec[c, idx] := -Iq43(Round(-q)) * gain;
        end;
      end;
    end;
    Inc(wOff, gWinLen);
  end;
end;

procedure TAACDecoder.ApplyPulses(c: Integer);
var
  swb: TArray<Integer>;
  i, k, idx: Integer;
begin
  if not FPulsePresent[c] then Exit;
  if FWinSeq[c] = WS_EIGHT_SHORT then Exit;         // pulses are long-window only
  swb := SwbTable(c);
  if FPulse[c].StartSfb >= Length(swb) then Exit;
  k := swb[FPulse[c].StartSfb];
  for i := 0 to FPulse[c].Count - 1 do
  begin
    k := k + FPulse[c].Offset[i];
    idx := k;
    if (idx >= 0) and (idx < 1024) then
    begin
      if FSpec[c, idx] >= 0 then
        FSpec[c, idx] := FSpec[c, idx] + FPulse[c].Amp[i]
      else
        FSpec[c, idx] := FSpec[c, idx] - FPulse[c].Amp[i];
    end;
  end;
end;

procedure TAACDecoder.ApplyPNS(c: Integer; AOtherC: Integer; APair: Boolean);
var
  swb: TArray<Integer>;
  g, sfb, win, gWinLen, wOff, cs, ce, i, idx: Integer;
  energy, scale, s: Double;
begin
  swb := SwbTable(c);
  wOff := 0;
  for g := 0 to FNumGroups[c] - 1 do
  begin
    gWinLen := FGroupLen[c, g];
    for sfb := 0 to FMaxSfb[c] - 1 do
    begin
      if FSfbCb[c, g, sfb] <> HCB_NOISE then Continue;
      if sfb + 1 >= Length(swb) then Break;
      cs := swb[sfb]; ce := swb[sfb + 1];
      energy := FScf[c, g, sfb];                    // linear gain from noise energy
      for win := 0 to gWinLen - 1 do
      begin
        { fill this sfb/window with scaled noise, normalised to unit power * gain }
        scale := 0;
        for i := cs to ce - 1 do
        begin
          if FWinSeq[c] = WS_EIGHT_SHORT then
            idx := (wOff + win) * FShortLen + i
          else idx := i;
          if idx >= 1024 then Break;
          s := NextNoise;
          FSpec[c, idx] := s;
          scale := scale + s * s;
        end;
        if scale > 0 then
        begin
          { total band energy = gain^2 (4.6.13), not per-coefficient }
          scale := energy / Sqrt(scale);
          for i := cs to ce - 1 do
          begin
            if FWinSeq[c] = WS_EIGHT_SHORT then
              idx := (wOff + win) * FShortLen + i
            else idx := i;
            if idx >= 1024 then Break;
            FSpec[c, idx] := FSpec[c, idx] * scale;
          end;
        end;
      end;
    end;
    Inc(wOff, gWinLen);
  end;
  if APair and (AOtherC >= 0) then ;                // correlated PNS not modelled
end;

{ ============================ TNS ======================== }

procedure TAACDecoder.ApplyTNS(c: Integer; AInverse: Boolean);
var
  swb: TArray<Integer>;
  w, filt, o, i, m, start, stop, size, inc_, idx: Integer;
  nWin, tnsMaxBands, coefBaseIdx, maxBand, numSwb, top, bottom: Integer;
  b, tmp: array[0..31] of Double;
  y: Double;
begin
  if not FTns[c].Present then Exit;
  swb := SwbTable(c);
  if FWinSeq[c] = WS_EIGHT_SHORT then
  begin
    nWin := FNumWindows[c];
    tnsMaxBands := TnsMaxBandsShort(FSrIndex);
  end
  else
  begin
    nWin := 1;
    tnsMaxBands := TnsMaxBandsLong(FSrIndex);
  end;

  maxBand := Min(tnsMaxBands, FMaxSfb[c]);
  numSwb := Length(swb) - 1;

  for w := 0 to nWin - 1 do
  begin
    { filters stack downward from the top scalefactor band (4.6.9.3) }
    bottom := numSwb;
    for filt := 0 to FTns[c].NFilt[w] - 1 do
    begin
      if filt > 2 then Break;
      top := bottom;
      bottom := Max(top - FTns[c].Len[w, filt], 0);
      o := FTns[c].Order[w, filt];
      if o = 0 then Continue;
      if o > 31 then o := 31;

      { reflection coefficients -> direct-form LPC (step-up recursion) }
      FillChar(b, SizeOf(b), 0);
      b[0] := 1.0;
      for m := 1 to o do
      begin
        for i := 1 to m - 1 do
          tmp[i] := b[i] + FTns[c].Coef[w, filt, m - 1] * b[m - i];
        for i := 1 to m - 1 do
          b[i] := tmp[i];
        b[m] := FTns[c].Coef[w, filt, m - 1];
      end;

      if FWinSeq[c] = WS_EIGHT_SHORT then coefBaseIdx := w * FShortLen
      else coefBaseIdx := 0;
      start := swb[Min(bottom, maxBand)];
      stop := swb[Min(top, maxBand)];
      size := stop - start;
      if size <= 0 then Continue;

      if FTns[c].Dir[w, filt] = 1 then
      begin
        inc_ := -1; idx := coefBaseIdx + stop - 1;
      end
      else
      begin
        inc_ := 1; idx := coefBaseIdx + start;
      end;

      { all-pole synthesis filter over the region; history starts at zero }
      for i := 0 to size - 1 do
      begin
        y := FSpec[c, idx];
        for m := 1 to o do
          if i - m >= 0 then
            y := y - b[m] * FSpec[c, idx - inc_ * m];
        FSpec[c, idx] := y;
        idx := idx + inc_;
      end;
    end;
  end;
  if AInverse then ;
end;

{ ============================ stereo tools =============== }

procedure TAACDecoder.ApplyMSStereo;
var
  swb: TArray<Integer>;
  g, sfb, win, gWinLen, wOff, cs, ce, i, idx: Integer;
  a, b_: Double;
begin
  if FMsMask = 0 then Exit;
  swb := SwbOffsetLong(FSrIndex);
  if FWinSeq[0] = WS_EIGHT_SHORT then swb := SwbOffsetShort(FSrIndex);
  wOff := 0;
  for g := 0 to FNumGroups[0] - 1 do
  begin
    gWinLen := FGroupLen[0, g];
    for sfb := 0 to FMaxSfb[0] - 1 do
    begin
      if (FMsMask = 2) or ((FMsMask = 1) and FMsUsed[g, sfb]) then
      begin
        { M/S never touches a band either channel codes as noise or intensity }
        if (FSfbCb[0, g, sfb] >= HCB_NOISE) or (FSfbCb[1, g, sfb] >= HCB_NOISE) then Continue;
        if sfb + 1 >= Length(swb) then Break;
        cs := swb[sfb]; ce := swb[sfb + 1];
        for win := 0 to gWinLen - 1 do
          for i := cs to ce - 1 do
          begin
            if FWinSeq[0] = WS_EIGHT_SHORT then
              idx := (wOff + win) * FShortLen + i
            else idx := i;
            if idx >= 1024 then Break;
            a := FSpec[0, idx]; b_ := FSpec[1, idx];
            FSpec[0, idx] := a + b_;
            FSpec[1, idx] := a - b_;
          end;
      end;
    end;
    Inc(wOff, gWinLen);
  end;
end;

procedure TAACDecoder.ApplyIntensity;
var
  swb: TArray<Integer>;
  g, sfb, win, gWinLen, wOff, cs, ce, i, idx, cb: Integer;
  scale: Double;
  sign: Double;
begin
  swb := SwbOffsetLong(FSrIndex);
  if FWinSeq[1] = WS_EIGHT_SHORT then swb := SwbOffsetShort(FSrIndex);
  wOff := 0;
  for g := 0 to FNumGroups[1] - 1 do
  begin
    gWinLen := FGroupLen[1, g];
    for sfb := 0 to FMaxSfb[1] - 1 do
    begin
      cb := FSfbCb[1, g, sfb];
      if not (cb in [HCB_INTENSITY, HCB_INTENSITY2]) then Continue;
      if sfb + 1 >= Length(swb) then Break;
      cs := swb[sfb]; ce := swb[sfb + 1];
      if cb = HCB_INTENSITY then sign := 1.0 else sign := -1.0;
      { ms_mask_present 2 means every band is M/S: the phase flips there too }
      if (FMsMask = 2) or ((FMsMask = 1) and FMsUsed[g, sfb]) then sign := -sign;
      scale := sign * Power(0.5, FIsPos[1, g, sfb] * 0.25);
      for win := 0 to gWinLen - 1 do
        for i := cs to ce - 1 do
        begin
          if FWinSeq[1] = WS_EIGHT_SHORT then
            idx := (wOff + win) * FShortLen + i
          else idx := i;
          if idx >= 1024 then Break;
          FSpec[1, idx] := FSpec[0, idx] * scale;
        end;
    end;
    Inc(wOff, gWinLen);
  end;
end;

{ ============================ filterbank ================ }

type
  { A Bluestein (chirp-z) plan for one fixed IMDCT size N.  Only 4 sizes ever
    occur (2048/1920 long, 256/240 short), so these are built once and cached
    for the process lifetime, exactly like the AAC Huffman tables.

    out[n] = (2/N2) * sum_k in[k] * cos( w*(n+0.5+N2/2)*(k+0.5) ), w = pi/N2,
    n in 0..N-1, N2 = N/2, k in 0..N2-1 - a direct evaluation is O(N^2) with a
    Cos() call per term (roughly 2.1 million transcendental calls per LONG
    frame), which is what made whole-file decode look like a multi-minute
    hang with zero feedback.

    The chirp identity a*b = (a^2 + b^2 - (a-b)^2)/2 turns the double sum
    into exp(j*w*a^2/2) * sum_k [in[k]*exp(j*w*b_k^2/2)] * exp(-j*w*(a-b_k)^2/2),
    and because a_n - b_k = (n + N2/2 - k) is always an integer here, that
    inner sum is a linear convolution of a length-N2 "pre-chirped" sequence
    with a fixed "chirp" kernel - computable via one zero-padded FFT of the
    kernel (built once, here) and, per call, one forward + one inverse FFT of
    size L = next_pow2(N2 + kernel_len - 1), i.e. O(N log N) instead of
    O(N^2). Verified bit-for-bit (to ~1e-13) against the direct O(N^2) sum in
    a standalone numeric check (N2 up to 1024) before being ported here. }
  TImdctPlan = record
    N2: Integer;
    L: Integer;
    FFT: TFFT;
    Offset: Integer;                 // conv[n + Offset] is this n's inner sum
    HRe, HIm: TArray<Double>;        // FFT of the chirp kernel, length L
    GPhaseCos, GPhaseSin: TArray<Double>;  // pre-chirp per k, length N2
    APhaseCos, APhaseSin: TArray<Double>;  // post-chirp per n, length N
  end;

var
  GImdctPlans: array of TImdctPlan;
  GImdctPlanN: array of Integer;    // parallel: the N each plan was built for

function GetImdctPlan(N: Integer): Integer;
var
  i, n2v, mMin, mMax, lh, convLen, lv, idx, m: Integer;
  w, ang: Double;
  hRe, hIm: TArray<Double>;
begin
  for i := 0 to High(GImdctPlanN) do
    if GImdctPlanN[i] = N then Exit(i);

  n2v := N div 2;
  w := Pi / n2v;
  mMin := (n2v div 2) - (n2v - 1);
  mMax := (N - 1) + (n2v div 2);
  lh := mMax - mMin + 1;
  convLen := n2v + lh - 1;
  lv := 1;
  while lv < convLen do lv := lv shl 1;

  SetLength(GImdctPlans, Length(GImdctPlans) + 1);
  SetLength(GImdctPlanN, Length(GImdctPlanN) + 1);
  Result := High(GImdctPlans);
  GImdctPlanN[Result] := N;

  GImdctPlans[Result].N2 := n2v;
  GImdctPlans[Result].L := lv;
  GImdctPlans[Result].FFT := TFFT.Create(lv);
  GImdctPlans[Result].Offset := (n2v div 2) - mMin;

  SetLength(hRe, lv);
  SetLength(hIm, lv);
  for idx := 0 to lh - 1 do
  begin
    m := mMin + idx;
    ang := -w * Sqr(Double(m)) / 2.0;
    hRe[idx] := Cos(ang);
    hIm[idx] := Sin(ang);
  end;
  GImdctPlans[Result].FFT.ForwardInPlace(hRe, hIm);
  GImdctPlans[Result].HRe := hRe;
  GImdctPlans[Result].HIm := hIm;

  SetLength(GImdctPlans[Result].GPhaseCos, n2v);
  SetLength(GImdctPlans[Result].GPhaseSin, n2v);
  for idx := 0 to n2v - 1 do
  begin
    ang := w * Sqr(idx + 0.5) / 2.0;
    GImdctPlans[Result].GPhaseCos[idx] := Cos(ang);
    GImdctPlans[Result].GPhaseSin[idx] := Sin(ang);
  end;

  SetLength(GImdctPlans[Result].APhaseCos, N);
  SetLength(GImdctPlans[Result].APhaseSin, N);
  for idx := 0 to N - 1 do
  begin
    ang := w * Sqr(idx + 0.5 + n2v / 2.0) / 2.0;
    GImdctPlans[Result].APhaseCos[idx] := Cos(ang);
    GImdctPlans[Result].APhaseSin[idx] := Sin(ang);
  end;
end;

procedure IMDCT(const AIn: array of Double; N: Integer; var AOut: array of Double);
var
  planIdx, n2v, lv, offs, nOut, k: Integer;
  plan: ^TImdctPlan;
  gRe, gIm: TArray<Double>;
  cr, ci, sumRe, sumIm: Double;
begin
  planIdx := GetImdctPlan(N);
  plan := @GImdctPlans[planIdx];
  n2v := plan^.N2;
  lv := plan^.L;

  SetLength(gRe, lv);   // zero-filled by SetLength; indices n2v..lv-1 stay 0
  SetLength(gIm, lv);
  for k := 0 to n2v - 1 do
  begin
    gRe[k] := AIn[k] * plan^.GPhaseCos[k];
    gIm[k] := AIn[k] * plan^.GPhaseSin[k];
  end;

  plan^.FFT.ForwardInPlace(gRe, gIm);
  for k := 0 to lv - 1 do
  begin
    cr := gRe[k] * plan^.HRe[k] - gIm[k] * plan^.HIm[k];
    ci := gRe[k] * plan^.HIm[k] + gIm[k] * plan^.HRe[k];
    gRe[k] := cr;
    gIm[k] := ci;
  end;
  plan^.FFT.InverseInPlace(gRe, gIm);

  offs := plan^.Offset;
  for nOut := 0 to N - 1 do
  begin
    sumRe := gRe[nOut + offs];
    sumIm := gIm[nOut + offs];
    cr := plan^.APhaseCos[nOut];
    ci := plan^.APhaseSin[nOut];
    AOut[nOut] := (cr * sumRe - ci * sumIm) * (2.0 / n2v);
  end;
end;

procedure TAACDecoder.Filterbank(c: Integer; AOutChannel: Integer;
  var AOut: TAudioPlanar);
var
  longN, shortN, i, w: Integer;
  coeffsLong: array[0..1023] of Double;
  timeLong: array[0..2047] of Double;
  winL, winR: TArray<Double>;
  winPlainL, winPlainR, winShortProto: TArray<Double>;
  prevShape: Integer;
  st: ^TAacChannelState;
  is960: Boolean;
  shortIn: array[0..127] of Double;
  shortOut: array[0..255] of Double;
  acc: array[0..2047] of Double;
  base: Integer;
begin
  st := @FChState[AOutChannel];
  is960 := FFrameLen = 960;
  longN := 2 * FFrameLen;                 // 2048 / 1920
  shortN := 2 * FShortLen;                // 256 / 240
  prevShape := st^.PrevWindowShape;

  if FWinSeq[c] <> WS_EIGHT_SHORT then
  begin
    for i := 0 to FFrameLen - 1 do coeffsLong[i] := FSpec[c, i];
    IMDCT(coeffsLong, longN, timeLong);

    { window: left half uses the previous frame's shape, right half this
      one's.  LONG_START / LONG_STOP get the proper asymmetric transition
      window (mostly flat, short-shaped only at the edge nearest the
      EIGHT_SHORT run) instead of a plain long window - a plain long window
      there breaks TDAC (time-domain aliasing cancellation) against the
      adjacent short-block sequence and audibly clicks/crackles on every
      such transition, i.e. on essentially any transient. }
    GetWindow(True, prevShape, is960, winPlainL);
    GetWindow(True, FWinShape[c], is960, winPlainR);
    if FWinSeq[c] = WS_LONG_STOP then
    begin
      GetWindow(False, prevShape, is960, winShortProto);
      BuildLongStopWindow(winPlainL, winShortProto, longN, shortN, winL);
    end
    else
      winL := winPlainL;
    if FWinSeq[c] = WS_LONG_START then
    begin
      GetWindow(False, FWinShape[c], is960, winShortProto);
      BuildLongStartWindow(winPlainR, winShortProto, longN, shortN, winR);
    end
    else
      winR := winPlainR;

    for i := 0 to FFrameLen - 1 do
      timeLong[i] := timeLong[i] * winL[i];
    { direct index, not the mirrored winR[FrameLen-1-i] this used to be: that
      form only equals winR[FrameLen+i] when winR is symmetric (true for a
      plain long/short window, false for the LONG_START transition window
      built above - a mirrored index there would apply it backwards). }
    for i := 0 to FFrameLen - 1 do
      timeLong[FFrameLen + i] := timeLong[FFrameLen + i] * winR[FFrameLen + i];

    for i := 0 to FFrameLen - 1 do
      AOut[AOutChannel][i] := timeLong[i] + st^.Overlap[i];
    for i := 0 to FFrameLen - 1 do
      st^.Overlap[i] := timeLong[FFrameLen + i];
  end
  else
  begin
    { eight short transforms, overlap-add at 128-sample hop inside a 2048 frame }
    FillChar(acc, SizeOf(acc), 0);
    GetWindow(False, prevShape, is960, winL);
    GetWindow(False, FWinShape[c], is960, winR);
    for w := 0 to 7 do
    begin
      for i := 0 to FShortLen - 1 do
        shortIn[i] := FSpec[c, w * FShortLen + i];
      IMDCT(shortIn, shortN, shortOut);
      { only the first short window overlaps the previous frame's shape; the
        others follow this frame's own previous short window (same shape) }
      if w = 0 then
        for i := 0 to FShortLen - 1 do
          shortOut[i] := shortOut[i] * winL[i]
      else
        for i := 0 to FShortLen - 1 do
          shortOut[i] := shortOut[i] * winR[i];
      for i := 0 to FShortLen - 1 do
        shortOut[FShortLen + i] := shortOut[FShortLen + i] * winR[FShortLen - 1 - i];
      base := (FFrameLen - FShortLen) div 2 + w * FShortLen;   // first short centred
      for i := 0 to shortN - 1 do
        if (base + i >= 0) and (base + i < longN) then
          acc[base + i] := acc[base + i] + shortOut[i];
    end;
    for i := 0 to FFrameLen - 1 do
      AOut[AOutChannel][i] := acc[i] + st^.Overlap[i];
    for i := 0 to FFrameLen - 1 do
      st^.Overlap[i] := acc[FFrameLen + i];
  end;

  st^.PrevWindowShape := FWinShape[c];
end;

{ ============================ raw_data_block =========== }

function TAACDecoder.DecodeFrame(var ABr: TAacBitReader; var AOut: TAudioPlanar;
  out AProduced: Integer): TAACDecodeStatus;
var
  idEle, i, tag, chOut: Integer;
  commonWindow, dseAlign: Boolean;
  outCh: Integer;
  done: Boolean;
  cnt, sfb, g: Integer;
begin
  AProduced := 0;
  if not FHaveTables then
    Exit(adsRefusedNoTables);

  EnsurePlanar(AOut, Max(1, FChannels), FFrameLen);
  for i := 0 to High(AOut) do
    FillChar(AOut[i][0], FFrameLen * SizeOf(Single), 0);

  outCh := 0;
  done := False;

  while (not done) and (not ABr.Overrun) do
  begin
    idEle := ABr.ReadBits(3);
    case idEle of
      ID_SCE, ID_LFE:
        begin
          tag := ABr.ReadBits(4);
          FMsMask := 0;
          FNumGroups[0] := 1; FGroupLen[0, 0] := 1;
          DecodeICS(ABr, 0, False);
          Dequantise(0);
          ApplyPulses(0);
          ApplyPNS(0, -1, False);
          ApplyTNS(0, True);
          if outCh < FChannels then
          begin
            Filterbank(0, outCh, AOut);
            Inc(outCh);
          end;
          if tag = tag then ;
        end;

      ID_CPE:
        begin
          tag := ABr.ReadBits(4);
          commonWindow := ABr.ReadBit = 1;
          FMsMask := 0;
          if commonWindow then
          begin
            ReadICSInfo(ABr, 0);
            { copy window params to channel 1 }
            FWinSeq[1] := FWinSeq[0];
            FWinShape[1] := FWinShape[0];
            FMaxSfb[1] := FMaxSfb[0];
            FNumWindows[1] := FNumWindows[0];
            FNumGroups[1] := FNumGroups[0];
            for i := 0 to 7 do FGroupLen[1, i] := FGroupLen[0, i];
            FScaleGrouping[1] := FScaleGrouping[0];
            FMsMask := ABr.ReadBits(2);
            if FMsMask = 1 then
              for g := 0 to FNumGroups[0] - 1 do
                for sfb := 0 to FMaxSfb[0] - 1 do
                  FMsUsed[g, sfb] := ABr.ReadBit = 1;
          end;
          DecodeICS(ABr, 0, commonWindow);
          DecodeICS(ABr, 1, commonWindow);

          Dequantise(0);
          Dequantise(1);
          ApplyPulses(0);
          ApplyPulses(1);

          if commonWindow and (FMsMask <> 0) then
            ApplyMSStereo;
          ApplyIntensity;

          ApplyPNS(0, 1, True);
          ApplyPNS(1, 0, True);
          ApplyTNS(0, True);
          ApplyTNS(1, True);

          if outCh < FChannels then begin Filterbank(0, outCh, AOut); Inc(outCh); end;
          if outCh < FChannels then begin Filterbank(1, outCh, AOut); Inc(outCh); end;
          if tag = tag then ;
        end;

      ID_CCE:
        begin
          { coupling channel element - parse enough to skip.  Fall back: bail to
            end-of-block so we at least emit what we have. }
          done := True;
        end;

      ID_DSE:
        begin
          { data_stream_element(): element_instance_tag (4 bits), then
            data_byte_align_flag (1 bit) - NOT an escape-count flag.  count is
            always an unconditional 8 bits; only when it reads as 255 does an
            escape byte follow.  byte_alignment() then only runs if the align
            flag said so.  Getting this wrong desyncs every element that
            follows - which is exactly what surfaced as a bogus
            "gain_control_data / SSR profile" error on plain LC streams that
            carry a DSE (e.g. Android's hardware AAC encoder). }
          tag := ABr.ReadBits(4);
          dseAlign := ABr.ReadBit = 1;
          cnt := ABr.ReadBits(8);
          if cnt = 255 then
            cnt := cnt + Integer(ABr.ReadBits(8));
          if dseAlign then
            ABr.ByteAlign;
          ABr.SkipBits(cnt * 8);
          if tag = tag then ;
        end;

      ID_PCE:
        begin
          { program_config_element - minimally parsed: we only need channel
            counts, which for the container case we already have.  Skip to byte
            boundary + comment field. }
          ABr.SkipBits(4 + 2 + 4);                 // element_instance_tag, object_type, sf_index
          cnt := ABr.ReadBits(4);                  // num_front_channel_elements
          i := ABr.ReadBits(4);                    // num_side
          g := ABr.ReadBits(4);                    // num_back
          sfb := ABr.ReadBits(2);                  // num_lfe
          chOut := ABr.ReadBits(3);                // num_assoc_data
          ABr.SkipBits(4);                         // num_valid_cc
          if ABr.ReadBit = 1 then ABr.SkipBits(4); // mono_mixdown
          if ABr.ReadBit = 1 then ABr.SkipBits(4); // stereo_mixdown
          if ABr.ReadBit = 1 then ABr.SkipBits(3); // matrix_mixdown
          ABr.SkipBits((cnt + i + g) * 5 + sfb * 4 + chOut * 4);
          ABr.ByteAlign;
          cnt := ABr.ReadBits(8);                  // comment_field_bytes
          ABr.SkipBits(cnt * 8);
        end;

      ID_FIL:
        begin
          cnt := ABr.ReadBits(4);
          if cnt = 15 then
            cnt := cnt + Integer(ABr.ReadBits(8)) - 1;
          { extension_payload: for HE-AAC this carries the SBR data; the SBR
            pass consumes it separately.  Here we just skip. }
          if cnt > 0 then
          begin
            { extension_type 13 / 14 = SBR data (without / with CRC) }
            i := ABr.ReadBits(4);
            if (i = 13) or (i = 14) then FSbrSeen := True;
            ABr.SkipBits(cnt * 8 - 4);
          end;
        end;

      ID_END:
        done := True;
    else
      done := True;
    end;
  end;

  ABr.ByteAlign;
  AProduced := FFrameLen;
  Result := adsOK;
end;

end.
