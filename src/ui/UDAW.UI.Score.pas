unit UDAW.UI.Score;

{ Music notation for the Score mode, drawn on UDAW's OpenGL 3.3 canvas (TGLCanvas).

  ScoreRender lays MIDI notes out on wrapping systems of bars - treble, bass or a
  grand staff - and draws clefs, the time signature, bar lines and numbers,
  note heads with accidentals, stems, flags and dots, rests for the gaps, chord
  symbols from the Chords lane, and the playhead. Notes are quantized to a grid
  first, so a performance reads as written music.

  This is a reader, not an editor: each note is one head (a note that crosses a
  bar line is cut at the bar, there are no ties), and flagged notes are not
  beamed. Time is in quarter notes throughout; the caller converts from the
  Timeline's seconds. }

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Math, System.Generics.Collections,
  Vcl.Graphics, UDAW.GL.Canvas, UDAW.UI.ThemeColors;

type
  TScoreNote = record
    StartQ, LenQ: Double;
    Pitch: Integer;
    Color: TColor;       // clNone = the theme text colour
  end;

  TScoreChord = record
    StartQ: Double;
    Name: string;
  end;

  TScoreClef = (scAuto, scTreble, scBass, scGrand);

  TScoreOptions = record
    Clef: TScoreClef;
    QuantQ: Double;      // quantize grid in quarter notes (0.25 = 1/16)
    Zoom: Double;
    Spread: Double;      // vertical spacing: 1 = normal, more spreads the staves and the lines of music apart (0 = normal)
    BarQ: Double;        // quarter notes per bar
    SigNum, SigDen: Integer;
    ShowChords: Boolean;
    Tab: Boolean;        // guitar tablature (six lines, fret numbers) instead of staff notation
    PlayQ: Double;
    PlayVisible: Boolean;
    ScrollY: Integer;
    ScrollX: Integer;    // horizontal scroll, in pixels
    Print: Boolean;      // black ink on white paper, whatever the theme (the PDF)
  end;

  TScoreLayout = record
    LeftX, BarW, BarsPerSystem, SystemH, TopPad, ContentH, TotalBars: Integer;
    LeftX0, ContentW: Integer;   // the left edge before scrolling, and the full width of a system
    BarQ: Double;
  end;

procedure ScoreRender(cv: TGLCanvas; AWidth, AHeight: Integer; const ANotes: TArray<TScoreNote>;
  const AChords: TArray<TScoreChord>; const AOpt: TScoreOptions; out ALayout: TScoreLayout);

{ the time (in quarters) under a click, False when the click is not over a bar }
function ScoreHitQ(const ALayout: TScoreLayout; AX, AY, AScrollY: Integer; out AQ: Double): Boolean;

implementation

const
  SYM_FONT = 'Segoe UI Symbol';

const
  { open strings of a standard-tuned guitar, lowest first: E2 A2 D3 G3 B3 E4 }
  GUITAR_OPEN: array[0..5] of Integer = (40, 45, 50, 55, 59, 64);
  GUITAR_FRETS = 24;
  PC_STEP: array[0..11] of Integer = (0, 0, 1, 1, 2, 3, 3, 4, 4, 5, 5, 6);
  PC_SHARP: array[0..11] of Boolean = (False, True, False, True, False, False, True, False, True, False, True, False);

{ diatonic position of a pitch: 7 per octave, C = 0 (sharps share their natural's line) }
function DiatonicPos(APitch: Integer): Integer;
begin
  Result := (APitch div 12 - 1) * 7 + PC_STEP[APitch mod 12];
end;

type
  TNoteGroup = record
    StartQ, EndQ: Double;
    Bar: Integer;
    Pitches: TArray<Integer>;
    Colors: TArray<TColor>;
    BaseQ: Double;
    Dotted: Boolean;
  end;

{ largest written duration <= ALen: whole, half, quarter, eighth, 16th, 32nd - and a dot
  when the length is about 1.5 of it }
procedure NoteDuration(ALen: Double; out ABase: Double; out ADotted: Boolean);
const
  BASES: array[0..5] of Double = (4, 2, 1, 0.5, 0.25, 0.125);
var
  i: Integer;
begin
  ABase := 0.125;
  ADotted := False;
  for i := 0 to High(BASES) do
    if ALen >= BASES[i] * 0.99 then
    begin
      ABase := BASES[i];
      ADotted := (i < High(BASES) + 1) and (ALen >= BASES[i] * 1.45) and (BASES[i] < 4);
      Break;
    end;
end;

procedure ScoreRender(cv: TGLCanvas; AWidth, AHeight: Integer; const ANotes: TArray<TScoreNote>;
  const AChords: TArray<TScoreChord>; const AOpt: TScoreOptions; out ALayout: TScoreLayout);
var
  spread: Double;
  extraOuter: Integer;
  sp, staffH, gap, chordRowH, aboveH, barW, bps, totalBars, sysCount, sysH, i, s, b, x0, x1: Integer;
  clef: TScoreClef;
  lastQ, q, e, minP, maxP, sumP: Double;
  qn: TArray<TScoreNote>;
  inkCol, dimCol, lineCol, bgCol: TColor;
  baseFont: string;
  groups: array of TList<TNoteGroup>;   // [bar*2 + staff]
  grp: TNoteGroup;
  n: TScoreNote;
  staff, bar, k, gi, tx, staffTop: Integer;
  trebleTop, bassTop: Integer;
  barStartQ, cursorQ: Double;
  tabMode: Boolean;
  nLines, headTop, footBot, firstStaff, lastStaff, tabPos, dp, stf: Integer;
  ledgerAbove, ledgerBelow: array[0..1] of Integer;   // ledger lines needed above / below each staff
  ledgerCol: TColor;
  tabFont, digitW, slots, maxCnt: Integer;
  tabStringCol, tabNumberCol, tabHaloCol, chordCol: TColor;
  slotUsed: TArray<Boolean>;

  function BarX(ABar: Integer): Integer;
  begin
    Result := ALayout.LeftX + (ABar mod bps) * barW;
  end;

  function SysTopY(ASys: Integer): Integer;
  begin
    Result := ALayout.TopPad + ASys * sysH - AOpt.ScrollY;
  end;

  function NoteX(ABar: Integer; AQ: Double): Integer;
  begin
    Result := BarX(ABar) + 14 + Round((AQ - ABar * AOpt.BarQ) / AOpt.BarQ * (barW - 28));
  end;

  { y of a pitch on a staff (staff 0 treble, 1 bass) of a system whose top is ATop }
  function PitchY(ATop, AStaff, APitch: Integer): Integer;
  var
    ref: Integer;
  begin
    if AStaff = 0 then ref := 30 else ref := 18;   // E4 / G2: the bottom lines
    Result := ATop + 4 * sp - Round((DiatonicPos(APitch) - ref) * sp / 2);
  end;

  { which staff a pitch is written on: 0 treble (also the tablature), 1 bass }
  function StaffOf(APitch: Integer): Integer;
  begin
    if tabMode then Result := 0
    else if clef = scGrand then Result := IfThen(APitch >= 60, 0, 1)
    else if clef = scBass then Result := 1
    else Result := 0;
  end;

  procedure Glyph(const AText: string; AX, AY, ASize: Integer; AColor: TColor);
  begin
    cv.Font.Name := SYM_FONT;
    cv.Font.Size := ASize;
    cv.Font.Color := AColor;
    cv.Brush.Style := bsClear;
    cv.TextOut(AX, AY, AText);
    cv.Font.Name := baseFont;
  end;

  procedure StaffLines(AX0, AX1, ATop: Integer);
  var
    l: Integer;
  begin
    cv.Pen.Style := psSolid;
    if tabMode then cv.Pen.Color := tabStringCol else cv.Pen.Color := lineCol;
    for l := 0 to nLines - 1 do
    begin
      cv.MoveTo(AX0, ATop + l * sp);
      cv.LineTo(AX1, ATop + l * sp);
    end;
  end;

  procedure Rest(AX, ATop: Integer; ADur: Double; AWhole: Boolean);
  var
    cy: Integer;
  begin
    cv.Pen.Style := psSolid;
    cv.Pen.Color := inkCol;
    cv.Brush.Style := bsSolid;
    cv.Brush.Color := inkCol;
    if AWhole or (ADur >= 4 * 0.99) then
      cv.FillRect(Rect(AX - sp, ATop + sp, AX + sp, ATop + sp + Max(2, sp div 2)))        // hangs from line 4
    else if ADur >= 2 * 0.99 then
      cv.FillRect(Rect(AX - sp, ATop + 2 * sp - Max(2, sp div 2), AX + sp, ATop + 2 * sp)) // sits on line 3
    else if ADur >= 0.99 then
    begin
      cy := ATop + sp;
      cv.Pen.Width := 2;
      cv.MoveTo(AX - sp div 3, cy); cv.LineTo(AX + sp div 3, cy + sp div 2);
      cv.LineTo(AX - sp div 3, cy + sp);
      cv.LineTo(AX + sp div 3, cy + 3 * sp div 2);
      cv.LineTo(AX, cy + 2 * sp);
      cv.Pen.Width := 1;
    end
    else
    begin
      cy := ATop + sp + sp div 2;
      cv.Pen.Style := psClear;
      cv.Ellipse(AX - sp div 3, cy, AX + sp div 6, cy + sp div 2 + 1);
      cv.Pen.Style := psSolid;
      cv.Pen.Width := 2;
      cv.MoveTo(AX + sp div 4, cy + 1); cv.LineTo(AX - sp div 3, cy + 2 * sp);
      cv.Pen.Width := 1;
    end;
  end;

  procedure DrawGroup(const AGrp: TNoteGroup; ATop, AStaff: Integer);
  var
    j, hx, hy, lo, hi, yLo, yHi, stemX, stemY0, stemY1, midY, yy, nFlags: Integer;
    up, open: Boolean;
    col: TColor;
  begin
    hx := NoteX(AGrp.Bar, AGrp.StartQ);
    lo := MaxInt; hi := -MaxInt;
    for j := 0 to High(AGrp.Pitches) do
    begin
      lo := Min(lo, AGrp.Pitches[j]);
      hi := Max(hi, AGrp.Pitches[j]);
    end;
    yLo := PitchY(ATop, AStaff, lo);
    yHi := PitchY(ATop, AStaff, hi);
    midY := ATop + 2 * sp;
    up := (yLo + yHi) / 2 >= midY;
    open := AGrp.BaseQ >= 2 * 0.99;

    { ledger lines above and below the staff: darker than the staff lines and a touch
      thicker, so notes far outside the staff stay easy to count }
    cv.Pen.Style := psSolid;
    cv.Pen.Color := ledgerCol;
    if sp >= 7 then cv.Pen.Width := 2;
    for j := 0 to High(AGrp.Pitches) do
    begin
      hy := PitchY(ATop, AStaff, AGrp.Pitches[j]);
      if hy < ATop - sp div 2 then
      begin
        yy := ATop - sp;
        while yy >= hy - 1 do
        begin
          cv.MoveTo(hx - sp, yy); cv.LineTo(hx + sp, yy);
          Dec(yy, sp);
        end;
      end
      else if hy > ATop + 4 * sp + sp div 2 then
      begin
        yy := ATop + 5 * sp;
        while yy <= hy + 1 do
        begin
          cv.MoveTo(hx - sp, yy); cv.LineTo(hx + sp, yy);
          Inc(yy, sp);
        end;
      end;
    end;
    cv.Pen.Width := 1;

    for j := 0 to High(AGrp.Pitches) do
    begin
      hy := PitchY(ATop, AStaff, AGrp.Pitches[j]);
      col := AGrp.Colors[j];
      if col = clNone then col := inkCol;
      if PC_SHARP[AGrp.Pitches[j] mod 12] then
        Glyph(#$266F, hx - sp - sp div 2 - 2, hy - sp - 2, Max(8, sp + 3), col);
      cv.Pen.Style := psSolid;
      cv.Pen.Color := col;
      cv.Pen.Width := 1;
      if open then
      begin
        cv.Brush.Style := bsClear;
        cv.Pen.Width := 2;
      end
      else
      begin
        cv.Brush.Style := bsSolid;
        cv.Brush.Color := col;
      end;
      cv.Ellipse(hx - sp * 5 div 8, hy - sp * 3 div 8, hx + sp * 5 div 8 + 1, hy + sp * 3 div 8 + 1);
      cv.Pen.Width := 1;
      if AGrp.Dotted then
      begin
        cv.Brush.Style := bsSolid;
        cv.Brush.Color := col;
        cv.Pen.Style := psClear;
        cv.Ellipse(hx + sp, hy - 2, hx + sp + 4, hy + 2);
      end;
    end;

    { stem, flags }
    if AGrp.BaseQ < 4 * 0.99 then
    begin
      col := AGrp.Colors[0];
      if col = clNone then col := inkCol;
      cv.Pen.Style := psSolid;
      cv.Pen.Color := col;
      cv.Pen.Width := 1;
      if up then
      begin
        stemX := hx + sp * 5 div 8;
        stemY0 := yLo;
        stemY1 := Min(yHi - Round(sp * 3.2), midY);
      end
      else
      begin
        stemX := hx - sp * 5 div 8;
        stemY0 := yHi;
        stemY1 := Max(yLo + Round(sp * 3.2), midY);
      end;
      cv.MoveTo(stemX, stemY0);
      cv.LineTo(stemX, stemY1);
      nFlags := 0;
      if AGrp.BaseQ <= 0.5 * 1.01 then nFlags := 1;
      if AGrp.BaseQ <= 0.25 * 1.01 then nFlags := 2;
      if AGrp.BaseQ <= 0.125 * 1.01 then nFlags := 3;
      cv.Pen.Width := 2;
      for j := 0 to nFlags - 1 do
        if up then
        begin
          cv.MoveTo(stemX, stemY1 + j * (sp * 2 div 3));
          cv.LineTo(stemX + sp * 7 div 8, stemY1 + sp + j * (sp * 2 div 3));
        end
        else
        begin
          cv.MoveTo(stemX, stemY1 - j * (sp * 2 div 3));
          cv.LineTo(stemX + sp * 7 div 8, stemY1 - sp - j * (sp * 2 div 3));
        end;
      cv.Pen.Width := 1;
    end;
  end;

  { Guitar tablature for one chord / note: every pitch gets a string and a fret (standard
    tuning, 24 frets) near the hand position of the previous group; pitches the guitar
    cannot reach are moved by octaves into its range. The fret number sits on its string
    line with the line cut out behind it so it reads clearly. }
  procedure DrawTabGroup(const AGrp: TNoteGroup; ATop: Integer);
  var
    j, hx, st, f, p, best, bestCost, cost, usedMask, sumF, nF, yS, tw, th2, dx, dy: Integer;
    sorted: TArray<Integer>;
    txt: string;
    col: TColor;
  begin
    hx := NoteX(AGrp.Bar, AGrp.StartQ);
    sorted := Copy(AGrp.Pitches);
    TArray.Sort<Integer>(sorted);            // low to high
    usedMask := 0;
    sumF := 0;
    nF := 0;
    col := AGrp.Colors[0];
    if col = clNone then col := tabNumberCol;
    cv.Font.Name := baseFont;
    cv.Font.Style := [fsBold];
    cv.Font.Size := tabFont;
    for j := High(sorted) downto 0 do        // highest pitch first
    begin
      p := sorted[j];
      while p < GUITAR_OPEN[0] do Inc(p, 12);
      while p > GUITAR_OPEN[5] + GUITAR_FRETS do Dec(p, 12);
      best := -1;
      bestCost := MaxInt;
      for st := 0 to 5 do
      begin
        f := p - GUITAR_OPEN[st];
        if (f < 0) or (f > GUITAR_FRETS) or ((usedMask and (1 shl st)) <> 0) then Continue;
        cost := Abs(f - tabPos);
        if f = 0 then Dec(cost);             // an open string is easy to play
        if cost < bestCost then
        begin
          bestCost := cost;
          best := st;
        end;
      end;
      if best < 0 then Continue;
      usedMask := usedMask or (1 shl best);
      f := p - GUITAR_OPEN[best];
      if f > 0 then
      begin
        Inc(sumF, f);
        Inc(nF);
      end;
      yS := ATop + (5 - best) * sp;
      { the fret number, centred on its string with the line cut out behind it }
      txt := IntToStr(f);
      tw := cv.TextWidth(txt);
      th2 := cv.TextHeight(txt);
      { no box behind the number: a thin outline in the page colour keeps it legible where the
        string runs through it, and the page shows through everywhere else }
      cv.Brush.Style := bsClear;
      cv.Font.Color := tabHaloCol;
      for dy := -1 to 1 do
        for dx := -1 to 1 do
          if (dx <> 0) or (dy <> 0) then
            cv.TextOut(hx - tw div 2 + dx, yS - th2 div 2 + dy, txt);
      cv.Font.Color := col;
      cv.TextOut(hx - tw div 2, yS - th2 div 2, txt);
    end;
    if nF > 0 then tabPos := sumF div nF;
    cv.Font.Style := [];
    cv.Font.Size := 9;
  end;

  { rests for the empty stretch [AFromQ, AToQ) of one bar: a whole-bar rest when the
    bar is empty, else the largest standard rests that fit, left to right }
  procedure FillRests(AFromQ, AToQ, ABarStartQ: Double; ABar, ATop: Integer);
  var
    rem, pos, d: Double;
  begin
    rem := AToQ - AFromQ;
    pos := AFromQ;
    while rem > 0.01 do
    begin
      if (Abs(rem - AOpt.BarQ) < 0.01) and (Abs(pos - ABarStartQ) < 0.01) then
      begin
        Rest(BarX(ABar) + barW div 2, ATop, 4, True);
        rem := 0;
      end
      else
      begin
        d := 2;
        while (d > 0.125) and (d > rem + 0.01) do d := d / 2;
        Rest(NoteX(ABar, pos) + 4, ATop, d, False);
        rem := rem - d;
        pos := pos + d;
      end;
    end;
  end;

  procedure BuildGroups;
  var
    j, ni, idx: Integer;
    found: Boolean;
    gl: TList<TNoteGroup>;
    gg: TNoteGroup;
    st: Double;
    bs: Double;
    dt: Boolean;
  begin
    for ni := 0 to High(qn) do
    begin
      n := qn[ni];
      bar := Trunc(n.StartQ / AOpt.BarQ + 1e-9);
      if (bar < 0) or (bar >= totalBars) then Continue;
      staff := StaffOf(n.Pitch);
      idx := bar * 2 + staff;
      gl := groups[idx];
      found := False;
      for j := 0 to gl.Count - 1 do
      begin
        gg := gl[j];
        if Abs(gg.StartQ - n.StartQ) < 0.001 then
        begin
          SetLength(gg.Pitches, Length(gg.Pitches) + 1);
          gg.Pitches[High(gg.Pitches)] := n.Pitch;
          SetLength(gg.Colors, Length(gg.Colors) + 1);
          gg.Colors[High(gg.Colors)] := n.Color;
          if n.StartQ + n.LenQ > gg.EndQ then gg.EndQ := n.StartQ + n.LenQ;
          gl[j] := gg;
          found := True;
          Break;
        end;
      end;
      if not found then
      begin
        gg := Default(TNoteGroup);
        gg.StartQ := n.StartQ;
        gg.EndQ := Min(n.StartQ + n.LenQ, (bar + 1) * AOpt.BarQ);
        gg.Bar := bar;
        SetLength(gg.Pitches, 1);
        gg.Pitches[0] := n.Pitch;
        SetLength(gg.Colors, 1);
        gg.Colors[0] := n.Color;
        gl.Add(gg);
      end;
    end;
    { written duration of every group, from its (bar-clamped) length }
    for idx := 0 to High(groups) do
      for j := 0 to groups[idx].Count - 1 do
      begin
        gg := groups[idx][j];
        gg.EndQ := Min(gg.EndQ, (gg.Bar + 1) * AOpt.BarQ);
        st := gg.EndQ - gg.StartQ;
        NoteDuration(st, bs, dt);
        gg.BaseQ := bs;
        gg.Dotted := dt;
        groups[idx][j] := gg;
      end;
  end;

begin
  { every colour comes from the Score / tab swatches on the Colors settings page }
  inkCol := ScoreColor(scrInk);
  dimCol := ScoreColor(scrBarNumber);
  lineCol := ScoreColor(scrStaff);
  ledgerCol := ScoreColor(scrLedger);
  bgCol := ScoreColor(scrPage);
  tabStringCol := ScoreColor(scrTabString);
  tabNumberCol := ScoreColor(scrTabNumber);
  tabHaloCol := ScoreColor(scrTabOutline);
  chordCol := ScoreColor(scrChord);
  if AOpt.Print then
  begin
    inkCol := clBlack;
    dimCol := TColor($00606060);
    lineCol := TColor($00303030);
    ledgerCol := clBlack;
    bgCol := clWhite;
    tabStringCol := TColor($00303030);
    tabNumberCol := clBlack;
    tabHaloCol := clWhite;
    chordCol := TColor($00800000);
  end;
  tabMode := AOpt.Tab;
  if tabMode then nLines := 6 else nLines := 5;
  baseFont := cv.Font.Name;
  cv.Brush.Style := bsSolid;
  cv.Brush.Color := bgCol;
  cv.Pen.Style := psClear;
  cv.FillRect(Rect(0, 0, AWidth, AHeight));

  sp := Max(3, Round(8 * AOpt.Zoom));
  staffH := (nLines - 1) * sp;
  gap := 8 * sp;
  if AOpt.ShowChords then chordRowH := 24 else chordRowH := 0;
  aboveH := 5 * sp;

  { quantize, and find the extent }
  SetLength(qn, Length(ANotes));
  lastQ := 0;
  minP := 127; maxP := 0; sumP := 0;
  for i := 0 to High(ANotes) do
  begin
    n := ANotes[i];
    if AOpt.QuantQ > 0 then
    begin
      q := Round(n.StartQ / AOpt.QuantQ) * AOpt.QuantQ;
      e := Max(q + AOpt.QuantQ, Round((n.StartQ + n.LenQ) / AOpt.QuantQ) * AOpt.QuantQ);
    end
    else
    begin
      q := n.StartQ;
      e := n.StartQ + n.LenQ;
    end;
    n.StartQ := Max(0, q);
    n.LenQ := Max(0.0625, e - q);
    qn[i] := n;
    lastQ := Max(lastQ, n.StartQ + n.LenQ);
    minP := Min(minP, n.Pitch);
    maxP := Max(maxP, n.Pitch);
    sumP := sumP + n.Pitch;
  end;

  clef := AOpt.Clef;
  if clef = scAuto then
  begin
    if Length(ANotes) = 0 then clef := scTreble
    else if (maxP - minP > 24) or ((minP < 55) and (maxP > 67)) then clef := scGrand
    else if sumP / Length(ANotes) >= 57 then clef := scTreble
    else clef := scBass;
  end;

  totalBars := Max(4, Ceil(lastQ / AOpt.BarQ - 1e-9));   // an empty score still shows a few bars
  ALayout.LeftX0 := 28 + 78;
  ALayout.LeftX := ALayout.LeftX0 - AOpt.ScrollX;
  barW := Max(Round(90 * Min(1.0, AOpt.Zoom)), Round(AOpt.BarQ * 36 * AOpt.Zoom));
  if tabMode then
  begin
    { tablature needs room for every fret number: widen the bars until the busiest one fits
      its notes side by side, double digits included }
    tabFont := Max(10, sp + 4);
    cv.Font.Name := baseFont;
    cv.Font.Style := [fsBold];
    cv.Font.Size := tabFont;
    digitW := cv.TextWidth('00') + 8;
    cv.Font.Style := [];
    cv.Font.Size := 9;
    slots := Max(1, Round(AOpt.BarQ / Max(0.0625, AOpt.QuantQ))) + 1;
    SetLength(slotUsed, totalBars * slots);
    for i := 0 to High(slotUsed) do slotUsed[i] := False;
    for i := 0 to High(qn) do
    begin
      k := Trunc(qn[i].StartQ / AOpt.BarQ + 1e-9);
      if (k < 0) or (k >= totalBars) then Continue;
      stf := EnsureRange(Round((qn[i].StartQ - k * AOpt.BarQ) / Max(0.0625, AOpt.QuantQ)), 0, slots - 1);
      slotUsed[k * slots + stf] := True;
    end;
    maxCnt := 1;
    for k := 0 to totalBars - 1 do
    begin
      dp := 0;
      for stf := 0 to slots - 1 do
        if slotUsed[k * slots + stf] then Inc(dp);
      maxCnt := Max(maxCnt, dp);
    end;
    barW := Max(barW, maxCnt * digitW + 28);
  end;
  bps := Max(1, (AWidth - ALayout.LeftX0 - 24) div barW);
  barW := Max(barW, (AWidth - ALayout.LeftX0 - 24) div bps);
  ALayout.ContentW := ALayout.LeftX0 + bps * barW + 24;
  { room for notes outside the staff: count the ledger lines the music needs above and
    below each staff and grow the system to hold them, so nothing runs into the chord
    row, the next staff or the next system }
  if tabMode then clef := scTreble;
  FillChar(ledgerAbove, SizeOf(ledgerAbove), 0);
  FillChar(ledgerBelow, SizeOf(ledgerBelow), 0);
  if not tabMode then
    for i := 0 to High(qn) do
    begin
      stf := StaffOf(qn[i].Pitch);
      dp := DiatonicPos(qn[i].Pitch);
      if stf = 0 then k := 30 else k := 18;      // bottom line (E4 / G2)
      if dp > k + 9 then ledgerAbove[stf] := Max(ledgerAbove[stf], (dp - (k + 8)) div 2);
      if dp < k - 1 then ledgerBelow[stf] := Max(ledgerBelow[stf], (k - dp) div 2);
    end;
  if clef = scBass then begin firstStaff := 1; lastStaff := 1; end
  else if clef = scGrand then begin firstStaff := 0; lastStaff := 1; end
  else begin firstStaff := 0; lastStaff := 0; end;
  headTop := Max(aboveH, (ledgerAbove[firstStaff] + 3) * sp);
  footBot := Max(aboveH + 2 * sp, (ledgerBelow[lastStaff] + 3) * sp + 2 * sp);
  if tabMode then footBot := 3 * sp;   // tablature is just the strings and their numbers
  { vertical spread: the outer spacing (space around each line of music) grows or shrinks, never
    below what the ledger lines and chord names need; the inner spacing (between the two staves
    of a grand staff) follows the same factor }
  spread := AOpt.Spread;
  if spread <= 0 then spread := 1.0;
  extraOuter := Round((spread - 1.0) * 8 * sp);
  headTop := Max(Max(2 * sp, (ledgerAbove[firstStaff] + 2) * sp), headTop + extraOuter div 2);
  footBot := Max(Max(2 * sp, (ledgerBelow[lastStaff] + 1) * sp + sp), footBot + extraOuter - extraOuter div 2);
  if clef = scGrand then
  begin
    gap := Max((ledgerBelow[0] + ledgerAbove[1] + 3) * sp, Round(gap * spread));
    sysH := chordRowH + headTop + staffH + gap + staffH + footBot;
  end
  else sysH := chordRowH + headTop + staffH + footBot;
  sysCount := Ceil(totalBars / bps);
  ALayout.BarW := barW;
  ALayout.BarsPerSystem := bps;
  ALayout.SystemH := sysH;
  ALayout.TopPad := 24;
  ALayout.ContentH := ALayout.TopPad + sysCount * sysH + 40;
  ALayout.TotalBars := totalBars;
  ALayout.BarQ := AOpt.BarQ;

  SetLength(groups, totalBars * 2);
  for i := 0 to High(groups) do groups[i] := TList<TNoteGroup>.Create;
  try
    BuildGroups;
    tabPos := 5;   { the guitar hand starts around the fifth fret }

    for s := 0 to sysCount - 1 do
    begin
      if (SysTopY(s) > AHeight) or (SysTopY(s) + sysH < 0) then Continue;
      tabPos := 5;   { every system starts the same way, so scrolling never changes the frets }
      trebleTop := SysTopY(s) + chordRowH + headTop;
      bassTop := trebleTop;
      if clef = scGrand then bassTop := trebleTop + staffH + gap
      else if clef = scBass then bassTop := trebleTop;
      b := s * bps;
      x0 := ALayout.LeftX;
      x1 := ALayout.LeftX + Min(bps, totalBars - b) * barW;

      { staves, brace, clefs }
      if clef in [scTreble, scGrand] then StaffLines(x0 - 70, x1, trebleTop);
      if clef in [scBass, scGrand] then StaffLines(x0 - 70, x1, bassTop);
      cv.Pen.Style := psSolid;
      cv.Pen.Color := lineCol;
      cv.MoveTo(x0 - 70, trebleTop);
      if clef = scGrand then cv.LineTo(x0 - 70, bassTop + staffH)
      else if clef = scBass then cv.LineTo(x0 - 70, bassTop + staffH)
      else cv.LineTo(x0 - 70, trebleTop + staffH);
      if tabMode then
      begin
        { the TAB clef: T A B stacked down the strings }
        { the three letters sit at the centres of the staff's top, middle and bottom thirds, so
          the A is exactly on the middle of the strings }
        cv.Font.Name := baseFont;
        cv.Font.Style := [fsBold];
        cv.Font.Size := Max(9, sp + 2);
        cv.Font.Color := inkCol;
        cv.Brush.Style := bsClear;
        tx := cv.TextHeight('TAB');
        cv.TextOut(x0 - 56, trebleTop + staffH div 6 - tx div 2, 'T');
        cv.TextOut(x0 - 56, trebleTop + staffH div 2 - tx div 2, 'A');
        cv.TextOut(x0 - 56, trebleTop + staffH * 5 div 6 - tx div 2, 'B');
        cv.Font.Style := [];
        cv.Font.Size := 9;
      end
      else
      begin
        if clef in [scTreble, scGrand] then
          Glyph(#$D834#$DD1E, x0 - 62, trebleTop - sp - sp div 2, Max(14, sp * 4), inkCol);   // G clef
        if clef in [scBass, scGrand] then
          Glyph(#$D834#$DD22, x0 - 62, bassTop - sp div 2, Max(14, sp * 3), inkCol);   // F clef
      end;
      if s = 0 then
      begin
        cv.Font.Style := [fsBold];
        if clef in [scTreble, scGrand] then
        begin
          Glyph(IntToStr(AOpt.SigNum), x0 - 32, trebleTop - 1, Max(10, sp + 3), inkCol);
          Glyph(IntToStr(AOpt.SigDen), x0 - 32, trebleTop + 2 * sp - 1, Max(10, sp + 3), inkCol);
        end;
        if clef in [scBass, scGrand] then
        begin
          Glyph(IntToStr(AOpt.SigNum), x0 - 32, bassTop - 1, Max(10, sp + 3), inkCol);
          Glyph(IntToStr(AOpt.SigDen), x0 - 32, bassTop + 2 * sp - 1, Max(10, sp + 3), inkCol);
        end;
        cv.Font.Style := [];
      end;

      for k := 0 to Min(bps, totalBars - b) - 1 do
      begin
        { bar line + number }
        cv.Pen.Style := psSolid;
        cv.Pen.Color := lineCol;
        tx := x0 + (k + 1) * barW;
        if clef = scGrand then begin cv.MoveTo(tx, trebleTop); cv.LineTo(tx, bassTop + staffH); end
        else if clef = scBass then begin cv.MoveTo(tx, bassTop); cv.LineTo(tx, bassTop + staffH); end
        else begin cv.MoveTo(tx, trebleTop); cv.LineTo(tx, trebleTop + staffH); end;
        cv.Brush.Style := bsClear;
        cv.Font.Size := 7;
        cv.Font.Color := dimCol;
        cv.TextOut(x0 + k * barW + 3, trebleTop - 2 * sp, IntToStr(b + k + 1));
        cv.Font.Size := 9;

        barStartQ := (b + k) * AOpt.BarQ;
        for staff := 0 to 1 do
        begin
          if (staff = 0) and not (clef in [scTreble, scGrand]) then Continue;
          if (staff = 1) and not (clef in [scBass, scGrand]) then Continue;
          if staff = 0 then staffTop := trebleTop else staffTop := bassTop;
          cursorQ := barStartQ;
          for gi := 0 to groups[(b + k) * 2 + staff].Count - 1 do
          begin
            grp := groups[(b + k) * 2 + staff][gi];
            if (grp.StartQ > cursorQ + 0.01) and not tabMode then
              FillRests(cursorQ, grp.StartQ, barStartQ, b + k, staffTop);
            if tabMode then DrawTabGroup(grp, staffTop)
            else DrawGroup(grp, staffTop, staff);
            cursorQ := Max(cursorQ, grp.EndQ);
          end;
          if (cursorQ < barStartQ + AOpt.BarQ - 0.01) and not tabMode then
            FillRests(cursorQ, barStartQ + AOpt.BarQ, barStartQ, b + k, staffTop);
        end;
      end;
      { chord symbols over the system }
      if AOpt.ShowChords then
        for i := 0 to High(AChords) do
        begin
          bar := Trunc(AChords[i].StartQ / AOpt.BarQ + 1e-9);
          if (bar < b) or (bar >= b + bps) or (bar >= totalBars) then Continue;
          cv.Brush.Style := bsClear;
          cv.Font.Style := [fsBold];
          cv.Font.Size := 9;
          cv.Font.Color := chordCol;
          cv.TextOut(NoteX(bar, AChords[i].StartQ) - 4, SysTopY(s) + 4, AChords[i].Name);
          cv.Font.Style := [];
        end;

      { the playhead }
      if AOpt.PlayVisible then
      begin
        bar := Trunc(AOpt.PlayQ / AOpt.BarQ + 1e-9);
        if (bar >= b) and (bar < b + bps) then
        begin
          cv.Pen.Style := psSolid;
          cv.Pen.Color := ScoreColor(scrPlayhead);
          cv.Pen.Width := 5;   // a thick line, easy to follow while the music plays
          cv.MoveTo(NoteX(bar, AOpt.PlayQ), trebleTop - sp);
          if clef = scTreble then cv.LineTo(NoteX(bar, AOpt.PlayQ), trebleTop + staffH + sp)
          else cv.LineTo(NoteX(bar, AOpt.PlayQ), bassTop + staffH + sp);
          cv.Pen.Width := 1;
        end;
      end;
    end;
  finally
    for i := 0 to High(groups) do groups[i].Free;
  end;
  cv.Font.Name := baseFont;
  cv.Brush.Style := bsSolid;
  cv.Pen.Style := psSolid;
end;

function ScoreHitQ(const ALayout: TScoreLayout; AX, AY, AScrollY: Integer; out AQ: Double): Boolean;
var
  s, k, bar: Integer;
  fx: Double;
begin
  Result := False;
  AQ := 0;
  if (ALayout.SystemH <= 0) or (ALayout.BarW <= 0) or (AX < ALayout.LeftX) then Exit;
  s := (AY + AScrollY - ALayout.TopPad) div ALayout.SystemH;
  if (AY + AScrollY < ALayout.TopPad) or (s < 0) then Exit;
  k := (AX - ALayout.LeftX) div ALayout.BarW;
  if k >= ALayout.BarsPerSystem then Exit;
  bar := s * ALayout.BarsPerSystem + k;
  if bar >= ALayout.TotalBars then Exit;
  fx := ((AX - ALayout.LeftX) - k * ALayout.BarW - 14) / Max(1, ALayout.BarW - 28);
  AQ := (bar + EnsureRange(fx, 0, 1)) * ALayout.BarQ;
  Result := True;
end;

end.
