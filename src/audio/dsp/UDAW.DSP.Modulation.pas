unit UDAW.DSP.Modulation;
{$I udaw.inc}
{$POINTERMATH ON}

{ Phase 10 - LFO-driven modulation effects (plan section 11): chorus, flanger,
  phaser, tremolo and auto-pan in one processor.

  Chorus / flanger are a per-channel fractional (linear-interpolated) delay line
  whose read offset is swept by a sine LFO, mixed back with the dry signal;
  flanger adds feedback and a shorter base delay. Phaser is a cascade of
  first-order all-pass sections whose break frequency is swept, with feedback.
  Tremolo modulates amplitude in phase on both channels; auto-pan modulates a
  constant-power pan position with the channels in anti-phase. A stereo LFO
  phase offset widens chorus / flanger / auto-pan.

  Delay lines are allocated once in Configure (ceiling MOD_MAX_DELAY_MS). All
  other state is value-type. }

interface

uses
  SysUtils, Math,
  UDAW.Audio.Types, UDAW.DSP.Math;

const
  MOD_MAX_DELAY_MS = 60.0;
  MOD_PHASER_STAGES_MAX = 12;

type
  TModEffect = (modChorus, modFlanger, modPhaser, modTremolo, modAutoPan);

  TModulationProcessor = class
  private
    FSampleRate: Integer;
    FChannels: Integer;
    FEffect: TModEffect;
    FRateHz: Double;
    FDepth: Double;          // 0..1
    FMix: Double;            // 0..1 wet
    FFeedback: Double;       // -0.95..0.95 (flanger / phaser)
    FStages: Integer;        // phaser
    FStereoDeg: Double;      // L/R LFO phase offset in degrees
    FLine: array of array of Single;   // [channel][pos]
    FLen: Integer;
    FWrite: Integer;
    FPhase: Double;          // LFO phase, radians
    FAllpassZ: array of array of Double;   // [channel][stage]
    procedure Recalc;
    function BaseDelayMs: Double;
    function SweepMs: Double;
  public
    constructor Create;
    procedure Configure(ASampleRate, AChannels: Integer);
    procedure Reset;
    procedure SetParams(AEffect: TModEffect; ARateHz, ADepth, AMix, AFeedback: Double;
      AStages: Integer; AStereoDeg: Double);
    procedure ProcessBlock(const AIn, AOut: array of PSingle; AFrames: Integer);
    property Effect: TModEffect read FEffect;
    property RateHz: Double read FRateHz;
  end;

function ModEffectId(AEffect: TModEffect): string;
function ModEffectFromId(const AId: string; out AEffect: TModEffect): Boolean;

implementation

function ModEffectId(AEffect: TModEffect): string;
begin
  case AEffect of
    modFlanger: Result := 'flanger';
    modPhaser:  Result := 'phaser';
    modTremolo: Result := 'tremolo';
    modAutoPan: Result := 'autopan';
  else
    Result := 'chorus';
  end;
end;

function ModEffectFromId(const AId: string; out AEffect: TModEffect): Boolean;
var
  e: TModEffect;
begin
  for e := Low(TModEffect) to High(TModEffect) do
    if SameText(AId, ModEffectId(e)) then
    begin
      AEffect := e;
      Exit(True);
    end;
  Result := False;
end;

{ ================= TModulationProcessor ================= }

constructor TModulationProcessor.Create;
begin
  inherited Create;
  FSampleRate := UDAW_DEFAULT_SAMPLE_RATE;
  FChannels := 2;
  FEffect := modChorus;
  FRateHz := 0.5;
  FDepth := 0.6;
  FMix := 0.5;
  FFeedback := 0.0;
  FStages := 4;
  FStereoDeg := 90.0;
end;

procedure TModulationProcessor.Configure(ASampleRate, AChannels: Integer);
var
  ch, want: Integer;
begin
  if ASampleRate > 0 then FSampleRate := ASampleRate;
  if AChannels > 0 then FChannels := AChannels;
  want := Round(MOD_MAX_DELAY_MS * 0.001 * FSampleRate) + 4;
  if (Length(FLine) <> FChannels) or (FLen <> want) then
  begin
    FLen := want;
    SetLength(FLine, FChannels);
    for ch := 0 to FChannels - 1 do
      SetLength(FLine[ch], FLen);
  end;
  SetLength(FAllpassZ, FChannels);
  for ch := 0 to FChannels - 1 do
    SetLength(FAllpassZ[ch], MOD_PHASER_STAGES_MAX);
  Recalc;
  Reset;
end;

procedure TModulationProcessor.Recalc;
begin
  if FDepth < 0 then FDepth := 0 else if FDepth > 1 then FDepth := 1;
  if FMix < 0 then FMix := 0 else if FMix > 1 then FMix := 1;
  if FFeedback < -0.95 then FFeedback := -0.95 else if FFeedback > 0.95 then FFeedback := 0.95;
  if FStages < 1 then FStages := 1 else if FStages > MOD_PHASER_STAGES_MAX then FStages := MOD_PHASER_STAGES_MAX;
  if FRateHz < 0.01 then FRateHz := 0.01 else if FRateHz > 20.0 then FRateHz := 20.0;
end;

procedure TModulationProcessor.Reset;
var
  ch, i: Integer;
begin
  for ch := 0 to High(FLine) do
    if Length(FLine[ch]) > 0 then
      FillChar(FLine[ch][0], Length(FLine[ch]) * SizeOf(Single), 0);
  for ch := 0 to High(FAllpassZ) do
    for i := 0 to High(FAllpassZ[ch]) do
      FAllpassZ[ch][i] := 0;
  FWrite := 0;
  FPhase := 0;
end;

procedure TModulationProcessor.SetParams(AEffect: TModEffect; ARateHz, ADepth, AMix,
  AFeedback: Double; AStages: Integer; AStereoDeg: Double);
begin
  FEffect := AEffect;
  FRateHz := ARateHz;
  FDepth := ADepth;
  FMix := AMix;
  FFeedback := AFeedback;
  FStages := AStages;
  FStereoDeg := AStereoDeg;
  Recalc;
end;

function TModulationProcessor.BaseDelayMs: Double;
begin
  if FEffect = modFlanger then Result := 1.5 else Result := 18.0;   // chorus
end;

function TModulationProcessor.SweepMs: Double;
begin
  if FEffect = modFlanger then Result := 3.0 else Result := 8.0;
end;

procedure TModulationProcessor.ProcessBlock(const AIn, AOut: array of PSingle;
  AFrames: Integer);
var
  i, ch, nc, st, ri0, ri1: Integer;
  incp, lfo, lfoCh, chOff, dry, wet: Double;
  delSamp, frac, base, sweep, rd: Double;
  x, y, ap, g, apf, panPos, gl, gr: Double;
  tl, tr: Single;
begin
  nc := Length(AIn);
  if (nc = 0) or (FLen <= 0) then Exit;
  incp := 2.0 * DSP_PI * FRateHz / FSampleRate;
  chOff := FStereoDeg * DSP_PI / 180.0;
  dry := 1.0 - FMix;
  wet := FMix;
  base := BaseDelayMs * 0.001 * FSampleRate;
  sweep := SweepMs * 0.001 * FSampleRate * FDepth;

  for i := 0 to AFrames - 1 do
  begin
    lfo := Sin(FPhase);

    case FEffect of
      modTremolo:
        begin
          { amplitude modulation, in phase on all channels; depth 1 = full }
          g := 1.0 - FDepth * (0.5 - 0.5 * Cos(FPhase));
          for ch := 0 to nc - 1 do
            AOut[ch][i] := Single(AIn[ch][i] * g);
        end;

      modAutoPan:
        begin
          panPos := FDepth * lfo;             // -depth..+depth
          PanGains(Single(panPos), plConstantPower, tl, tr);
          gl := tl; gr := tr;
          if nc >= 2 then
          begin
            AOut[0][i] := Single(AIn[0][i] * gl);
            AOut[1][i] := Single(AIn[1][i] * gr);
          end
          else
            AOut[0][i] := Single(AIn[0][i] * gl);
        end;

      modPhaser:
        begin
          { swept all-pass cascade with feedback }
          apf := 300.0 + (0.5 + 0.5 * lfo) * FDepth * 3000.0;   // 300 Hz .. ~3.3 kHz
          g := (1.0 - Tan(DSP_PI * apf / FSampleRate)) / (1.0 + Tan(DSP_PI * apf / FSampleRate));
          for ch := 0 to nc - 1 do
          begin
            x := AIn[ch][i] + FFeedback * FAllpassZ[ch][MOD_PHASER_STAGES_MAX - 1];
            for st := 0 to FStages - 1 do
            begin
              ap := -g * x + FAllpassZ[ch][st];
              FAllpassZ[ch][st] := Single(FlushDenorm(Single(x + g * ap)));
              x := ap;
            end;
            FAllpassZ[ch][MOD_PHASER_STAGES_MAX - 1] := x;   // feedback tap
            AOut[ch][i] := Single(dry * AIn[ch][i] + wet * x);
          end;
        end;

    else
      { chorus / flanger: modulated fractional delay per channel }
      begin
        for ch := 0 to nc - 1 do
        begin
          if (ch = 1) then lfoCh := Sin(FPhase + chOff) else lfoCh := lfo;
          rd := base + sweep * (0.5 + 0.5 * lfoCh);
          if rd < 1 then rd := 1;
          if rd > FLen - 2 then rd := FLen - 2;
          delSamp := FWrite - rd;
          while delSamp < 0 do delSamp := delSamp + FLen;
          ri0 := Trunc(delSamp);
          frac := delSamp - ri0;
          ri1 := ri0 + 1;
          if ri1 >= FLen then ri1 := ri1 - FLen;
          y := FLine[ch][ri0] * (1.0 - frac) + FLine[ch][ri1] * frac;
          FLine[ch][FWrite] := Single(FlushDenorm(Single(AIn[ch][i] + FFeedback * y)));
          AOut[ch][i] := Single(dry * AIn[ch][i] + wet * y);
        end;
        Inc(FWrite);
        if FWrite >= FLen then FWrite := 0;
      end;
    end;

    FPhase := FPhase + incp;
    if FPhase > 2.0 * DSP_PI then FPhase := FPhase - 2.0 * DSP_PI;
  end;
end;

end.
