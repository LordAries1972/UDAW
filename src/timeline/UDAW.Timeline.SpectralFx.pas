unit UDAW.Timeline.SpectralFx;
{$I udaw.inc}

{ Glue between the Timeline range-FX menu and the offline spectral tools
  (UDAW.DSP.Spectral): parameter parsing, per-channel dispatch with progress
  reporting, stem splitting to files. UI-free so it can be tested. }

interface

uses
  SysUtils, Math, Classes,
  UDAW.Audio.Types, UDAW.DSP.Spectral, UDAW.Codec.WAV, UDAW.Timeline.ExtraFx;

const
  SFX_DENOISE = '@denoise';
  SFX_AUTOTUNE = '@autotune';
  SFX_CONVOLVE = '@convolve';
  SFX_ADAPTIVE = '@adaptivedenoise';
  SFX_VOICE = '@voiceisolate';
  SFX_MUSIC = '@musicextract';

type
  {$IFDEF FPC}
  TSpectralProgress = procedure(AChannel, AChannels: Integer) of object;
  {$ELSE}
  TSpectralProgress = reference to procedure(AChannel, AChannels: Integer);
  {$ENDIF}

function IsSpectralKind(const AKind: string): Boolean;

{ "C major", "A minor", "F# major", "chromatic" -> scale mask. False if unparsable. }
function ParseScaleText(const AText: string; ACorrector: TPitchCorrector): Boolean;

{ AKind is one of the SFX_* ids. AParams: "reduce=12" (denoise, dB),
  "scale=C major;strength=1" (autotune), "ir=<wav path>;mix=0.3" (convolve).
  AIn/AOut are planar, AFrames long; AOut is fully overwritten. }
procedure ApplySpectralFx(const AKind, AParams: string; const AIn: TAudioPlanar;
  AChannels, AFrames, ASampleRate: Integer; var AOut: TAudioPlanar;
  const AProgress: TSpectralProgress = nil);

{ Splits a planar buffer into a speech/voice WAV and a music/background WAV
  (classical masking, see SeparateSpeechMusic). }
function SplitSpeechMusicToFiles(const AIn: TAudioPlanar; AChannels, AFrames,
  ASampleRate: Integer; const ABaseName: string; out AVoice, AMusic: string): Boolean;

{ Splits a stereo/mono planar buffer into drums/bass/vocals/other WAV files
  written next to ABaseName; returns the four file names. }
function SplitStemsToFiles(const AIn: TAudioPlanar; AChannels, AFrames,
  ASampleRate: Integer; const ABaseName: string;
  out ADrums, ABass, AVocals, AOther: string): Boolean;

implementation

function IsSpectralKind(const AKind: string): Boolean;
begin
  Result := SameText(AKind, SFX_DENOISE) or SameText(AKind, SFX_AUTOTUNE) or
    SameText(AKind, SFX_CONVOLVE) or SameText(AKind, SFX_ADAPTIVE) or
    SameText(AKind, SFX_VOICE) or SameText(AKind, SFX_MUSIC) or IsExtraFxKind(AKind);
end;

function ParamStr(const AParams, AKey, ADef: string): string;
var
  parts: TStringList;
  i: Integer;
begin
  Result := ADef;
  parts := TStringList.Create;
  try
    parts.Delimiter := ';';
    parts.StrictDelimiter := True;
    parts.DelimitedText := AParams;
    for i := 0 to parts.Count - 1 do
      if SameText(parts.Names[i], AKey) then
        Exit(parts.ValueFromIndex[i]);
  finally
    parts.Free;
  end;
end;

{ start of the quietest window of ALen frames: the best stand-in for "noise only" audio }
function QuietestWindowStart(const X: TAudioSampleArray; AFrames, ALen, AHop: Integer): Integer;
var
  pre: array of Double;
  i, st: Integer;
  e, best: Double;
begin
  Result := 0;
  if (ALen < 1) or (AFrames <= ALen) then Exit;
  SetLength(pre, AFrames + 1);
  pre[0] := 0;
  for i := 0 to AFrames - 1 do pre[i + 1] := pre[i] + Sqr(X[i]);
  best := MaxDouble;
  st := 0;
  while st + ALen <= AFrames do
  begin
    e := pre[st + ALen] - pre[st];
    if e < best then
    begin
      best := e;
      Result := st;
    end;
    Inc(st, Max(1, AHop));
  end;
end;

function ParamFloat(const AParams, AKey: string; ADef: Double): Double;
begin
  Result := StrToFloatDef(ParamStr(AParams, AKey, ''), ADef, TFormatSettings.Invariant);
end;

function ParseScaleText(const AText: string; ACorrector: TPitchCorrector): Boolean;
const
  NAMES: array[0..11] of string = ('C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B');
  FLATS: array[0..11] of string = ('C', 'DB', 'D', 'EB', 'E', 'F', 'GB', 'G', 'AB', 'A', 'BB', 'B');
var
  t, rootTxt, mode: string;
  sp, i, root: Integer;
begin
  Result := False;
  t := UpperCase(Trim(AText));
  if (t = '') or (t = 'CHROMATIC') then
  begin
    ACorrector.SetChromatic;
    Exit(True);
  end;
  sp := Pos(' ', t);
  if sp = 0 then Exit;
  rootTxt := Copy(t, 1, sp - 1);
  mode := Trim(Copy(t, sp + 1, MaxInt));
  root := -1;
  for i := 0 to 11 do
    if (rootTxt = UpperCase(NAMES[i])) or (rootTxt = FLATS[i]) then
      root := i;
  if root < 0 then Exit;
  if (mode = 'MAJOR') or (mode = 'MAJ') then ACorrector.SetMajor(root)
  else if (mode = 'MINOR') or (mode = 'MIN') then ACorrector.SetMinor(root)
  else Exit;
  Result := True;
end;

procedure ApplySpectralFx(const AKind, AParams: string; const AIn: TAudioPlanar;
  AChannels, AFrames, ASampleRate: Integer; var AOut: TAudioPlanar;
  const AProgress: TSpectralProgress);
var
  ch, i, irCh, irSr, noiseLen: Integer;
  src: TAudioSampleArray;
  res: TAudioSampleArray;
  chL, chR, sepVL, sepVR, sepML, sepMR: TAudioSampleArray;
  ir: TAudioPlanar;
  reduce, mix, strength, peak: Double;
  pc: TPitchCorrector;
  irPath: string;
begin
  if IsExtraFxKind(AKind) then
  begin
    if Assigned(AProgress) then AProgress(0, 1);
    ApplyExtraFx(AKind, AParams, AIn, AChannels, AFrames, ASampleRate, AOut);
    if Assigned(AProgress) then AProgress(0, 1);
    Exit;
  end;
  if Length(AOut) < AChannels then SetLength(AOut, AChannels);
  for ch := 0 to AChannels - 1 do
    if Length(AOut[ch]) < AFrames then SetLength(AOut[ch], AFrames);

  if SameText(AKind, SFX_VOICE) or SameText(AKind, SFX_MUSIC) then
  begin
    { Voice Isolation / Music Separator: both channels are analysed together so the
      "is it centred" cue works; further channels pass through untouched }
    if Assigned(AProgress) then AProgress(0, 1);
    SetLength(chL, AFrames);
    SetLength(chR, AFrames);
    Move(AIn[0][0], chL[0], AFrames * SizeOf(Single));
    if AChannels > 1 then Move(AIn[1][0], chR[0], AFrames * SizeOf(Single))
    else Move(AIn[0][0], chR[0], AFrames * SizeOf(Single));
    SeparateSpeechMusic(chL, chR, ASampleRate, ParamFloat(AParams, 'strength', 0.6),
      sepVL, sepVR, sepML, sepMR);
    for ch := 0 to AChannels - 1 do
    begin
      for i := 0 to AFrames - 1 do
        if ch > 1 then AOut[ch][i] := AIn[ch][i]
        else if SameText(AKind, SFX_VOICE) then
        begin
          if ch = 0 then AOut[ch][i] := sepVL[i] else AOut[ch][i] := sepVR[i];
        end
        else
        begin
          if ch = 0 then AOut[ch][i] := sepML[i] else AOut[ch][i] := sepMR[i];
        end;
    end;
    if Assigned(AProgress) then AProgress(1, 1);
    Exit;
  end;

  pc := nil;
  try
    if SameText(AKind, SFX_AUTOTUNE) then
    begin
      pc := TPitchCorrector.Create;
      if not ParseScaleText(ParamStr(AParams, 'scale', 'chromatic'), pc) then
        pc.SetChromatic;
      strength := ParamFloat(AParams, 'strength', 1.0);
      pc.Strength := EnsureRange(strength, 0.0, 1.0);
    end;
    if SameText(AKind, SFX_CONVOLVE) then
    begin
      irPath := ParamStr(AParams, 'ir', '');
      if (irPath = '') or not FileExists(irPath) then
        raise Exception.Create('Convolution Reverb: impulse response file not found');
      ir := LoadWavFile(irPath, irCh, irSr);
      if (irCh < 1) or (Length(ir) = 0) or (Length(ir[0]) = 0) then
        raise Exception.Create('Convolution Reverb: impulse response is empty');
    end;
    mix := EnsureRange(ParamFloat(AParams, 'mix', 0.3), 0.0, 1.0);
    reduce := ParamFloat(AParams, 'reduce', 12);

    for ch := 0 to AChannels - 1 do
    begin
      if Assigned(AProgress) then AProgress(ch, AChannels);
      SetLength(src, AFrames);
      Move(AIn[ch][0], src[0], AFrames * SizeOf(Single));
      if SameText(AKind, SFX_ADAPTIVE) then
      begin
        { no hand-placed noise sample: the quietest 0.4 s of the selection is the profile }
        noiseLen := Min(Round(0.4 * ASampleRate), AFrames div 4);
        SpectralDenoise(src, ASampleRate, QuietestWindowStart(src, AFrames, noiseLen, Max(1, ASampleRate div 20)),
          noiseLen, reduce, res);
      end
      else if SameText(AKind, SFX_DENOISE) then
      begin
        { the noise profile is learnt from the first 0.4 s (at most a quarter)
          of the selection, which the user places over noise-only audio }
        noiseLen := Min(Round(0.4 * ASampleRate), AFrames div 4);
        SpectralDenoise(src, ASampleRate, 0, noiseLen, reduce, res);
      end
      else if SameText(AKind, SFX_AUTOTUNE) then
        pc.Process(src, ASampleRate, res)
      else
      begin
        { wet = input convolved with the IR (mono IR channel per source
          channel); IR is peak-normalised so the wet level is predictable }
        ConvolveIR(src, ir[Min(ch, irCh - 1)], res);
        peak := 0;
        for i := 0 to Min(AFrames, Length(res)) - 1 do
          peak := Max(peak, Abs(res[i]));
        if peak > 1e-9 then
          for i := 0 to Length(res) - 1 do res[i] := res[i] / peak * 0.7;
        for i := 0 to AFrames - 1 do
          res[i] := src[i] * (1.0 - mix) + res[i] * mix;
      end;
      for i := 0 to AFrames - 1 do
        if i < Length(res) then AOut[ch][i] := res[i] else AOut[ch][i] := 0;
    end;
  finally
    pc.Free;
  end;
end;

function SplitSpeechMusicToFiles(const AIn: TAudioPlanar; AChannels, AFrames,
  ASampleRate: Integer; const ABaseName: string; out AVoice, AMusic: string): Boolean;
var
  l, r, vl, vr, ml, mr: TAudioSampleArray;
  voice, music: TAudioPlanar;
begin
  Result := False;
  if (AChannels < 1) or (AFrames < 4096) then Exit;
  SetLength(l, AFrames);
  SetLength(r, AFrames);
  Move(AIn[0][0], l[0], AFrames * SizeOf(Single));
  if AChannels > 1 then Move(AIn[1][0], r[0], AFrames * SizeOf(Single))
  else Move(AIn[0][0], r[0], AFrames * SizeOf(Single));
  SeparateSpeechMusic(l, r, ASampleRate, 0.6, vl, vr, ml, mr);
  SetLength(voice, 2);
  SetLength(music, 2);
  voice[0] := vl; voice[1] := vr;
  music[0] := ml; music[1] := mr;
  AVoice := ABaseName + '-speech.wav';
  AMusic := ABaseName + '-music.wav';
  SaveWavFile(AVoice, voice, 2, ASampleRate, AFrames, wsfPCM24);
  SaveWavFile(AMusic, music, 2, ASampleRate, AFrames, wsfPCM24);
  Result := True;
end;

function SplitStemsToFiles(const AIn: TAudioPlanar; AChannels, AFrames,
  ASampleRate: Integer; const ABaseName: string;
  out ADrums, ABass, AVocals, AOther: string): Boolean;
var
  st: TStemSet;
  l, r: TAudioSampleArray;

  procedure Save(const ASuffix: string; const AStem: TAudioPlanar; out AName: string);
  begin
    AName := ABaseName + '-' + ASuffix + '.wav';
    SaveWavFile(AName, AStem, 2, ASampleRate, AFrames, wsfPCM24);
  end;
begin
  Result := False;
  if (AChannels < 1) or (AFrames < 4096) then Exit;
  SetLength(l, AFrames);
  SetLength(r, AFrames);
  Move(AIn[0][0], l[0], AFrames * SizeOf(Single));
  if AChannels > 1 then Move(AIn[1][0], r[0], AFrames * SizeOf(Single))
  else Move(AIn[0][0], r[0], AFrames * SizeOf(Single));
  SplitStems(l, r, ASampleRate, st);
  Save('drums', st.Drums, ADrums);
  Save('bass', st.Bass, ABass);
  Save('vocals', st.Vocals, AVocals);
  Save('other', st.Other, AOther);
  Result := True;
end;

end.
