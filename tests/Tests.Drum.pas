unit Tests.Drum;
{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}

{ Drum machine acceptance tests (UDAW.Drum.Machine): pad loading, note mapping, the
  voice mixer (level / pan / mute / solo), choke groups, gate release, and the kit
  file round trip. Samples are constant (DC) signals so every expected amplitude is
  exact arithmetic. }

interface

procedure RegisterDrumTests;

implementation

uses
  SysUtils, Classes, Math,
  UDAW.Testing,
  UDAW.Paths,
  UDAW.Audio.Types,
  UDAW.Audio.Buffer,
  UDAW.Codec.WAV,
  UDAW.Drum.Machine,
  UDAW.Drum.KitModel,
  UDAW.Project.Document,
  UDAW.Project.Serialization;

const
  RATE = 44100;

function ScratchDir: string;
begin
  Result := IncludeTrailingPathDelimiter(Paths.Temp) + 'drum-tests' + PathDelim;
  ForceDirectories(Result);
end;

{ a stereo WAV of AFrames frames at a constant AValue }
function MakeDc(const AName: string; AFrames: Integer; AValue: Single): string;
var
  d: TAudioPlanar;
  ch, i: Integer;
begin
  Result := ScratchDir + AName;
  SetLength(d, 2);
  for ch := 0 to 1 do
  begin
    SetLength(d[ch], AFrames);
    for i := 0 to AFrames - 1 do d[ch][i] := AValue;
  end;
  SaveWavFile(Result, d, 2, RATE, AFrames, wsfFloat32);
end;

function NewMachine: TDrumMachine;
begin
  Result := TDrumMachine.Create;
  Result.Prepare(RATE, 512, 2);
end;

function Block(AM: TDrumMachine; AFrames: Integer): TAudioBuffer;
begin
  Result := TAudioBuffer.Create(2, AFrames, RATE);
  Result.SetActiveFrames(AFrames);
  AM.Render(Result);
end;

function LoadOrFail(AM: TDrumMachine; APad: Integer; const APath: string): Boolean;
var
  err: string;
begin
  Result := AM.LoadPad(APad, APath, err);
  Check(Result, 'LoadPad(' + IntToStr(APad) + '): ' + err);
end;

procedure Test_NoteMapping;
var
  m: TDrumMachine;
  iface: IInterface;
begin
  m := NewMachine;
  iface := m;
  CheckEqualInt(36, m.PadForNote(36), 'note 36 is pad 36');
  CheckEqualInt(51, m.PadForNote(51), 'note 51 is pad 51');
  CheckEqualInt(0, m.PadForNote(0), 'note 0 is pad 0');
  CheckEqualInt(127, m.PadForNote(127), 'note 127 is pad 127');
  CheckEqualInt(-1, m.PadForNote(128), 'note 128 is no pad');
  CheckFalse(m.HitNote(36, 100), 'an empty pad does not take a hit');
  CheckEqualStr('C1', DrumNoteName(36), 'pad 0 is C1');
  CheckEqualStr('D#2', DrumNoteName(51), 'pad 15 is D#2');
end;

procedure Test_HitMixesSample;
var
  m: TDrumMachine;
  iface: IInterface;
  b: TAudioBuffer;
begin
  m := NewMachine;
  iface := m;
  if not LoadOrFail(m, 0, MakeDc('dc50.wav', 4000, 0.5)) then Exit;
  CheckEqualInt(0, m.ActiveVoices, 'no voice before a hit');
  m.Hit(0, 127);
  b := Block(m, 256);
  try
    { centre pan: the constant-power law is normalised to unity at the centre }
    CheckNear(0.5, b.ChannelPtr(0)^, 0.01, 'left carries the sample');
    CheckNear(0.5, b.ChannelPtr(1)^, 0.01, 'right carries the sample');
    CheckEqualInt(1, m.ActiveVoices, 'one voice sounding');
  finally
    b.Free;
  end;
end;

procedure Test_VelocityAndLevel;
var
  m: TDrumMachine;
  iface: IInterface;
  b: TAudioBuffer;
begin
  m := NewMachine;
  iface := m;
  if not LoadOrFail(m, 0, MakeDc('dc50b.wav', 4000, 0.5)) then Exit;
  m.Pads[0].Level := 0.5;
  m.Hit(0, 64);   // velocity 64/127
  b := Block(m, 128);
  try
    CheckNear(0.5 * (64 / 127) * 0.5, b.ChannelPtr(0)^, 0.01, 'level times velocity');
  finally
    b.Free;
  end;
end;

procedure Test_Pan_HardLeft;
var
  m: TDrumMachine;
  iface: IInterface;
  b: TAudioBuffer;
begin
  m := NewMachine;
  iface := m;
  if not LoadOrFail(m, 0, MakeDc('dc50c.wav', 4000, 0.5)) then Exit;
  m.Pads[0].Pan := -1;
  m.Hit(0, 127);
  b := Block(m, 128);
  try
    Check(b.ChannelPtr(0)^ > 0.6, 'hard left is louder on the left');
    CheckNear(0, b.ChannelPtr(1)^, 0.001, 'hard left is silent on the right');
  finally
    b.Free;
  end;
end;

procedure Test_MuteAndSolo;
var
  m: TDrumMachine;
  iface: IInterface;
  b: TAudioBuffer;
  f: string;
begin
  m := NewMachine;
  iface := m;
  f := MakeDc('dc50d.wav', 4000, 0.5);
  if not LoadOrFail(m, 0, f) then Exit;
  if not LoadOrFail(m, 1, f) then Exit;
  m.Pads[0].Muted := True;
  m.Hit(0, 127);
  b := Block(m, 128);
  try
    CheckNear(0, b.ChannelPtr(0)^, 0.0001, 'a muted pad is silent');
  finally
    b.Free;
  end;
  m.Pads[0].Muted := False;
  m.Pads[1].Soloed := True;
  m.Hit(0, 127);
  b := Block(m, 128);
  try
    CheckNear(0, b.ChannelPtr(0)^, 0.0001, 'with another pad soloed, this one is silent');
  finally
    b.Free;
  end;
end;

procedure Test_ChokeGroup;
var
  m: TDrumMachine;
  iface: IInterface;
  b: TAudioBuffer;
  f: string;
begin
  m := NewMachine;
  iface := m;
  f := MakeDc('dc50e.wav', 40000, 0.5);
  if not LoadOrFail(m, 2, f) then Exit;
  if not LoadOrFail(m, 3, f) then Exit;
  m.Pads[2].Choke := 1;
  m.Pads[3].Choke := 1;
  m.Hit(2, 100);
  b := Block(m, 128);
  b.Free;
  CheckEqualInt(1, m.ActiveVoices, 'the open hat sounds');
  m.Hit(3, 100);   // the closed hat chokes the open one
  b := Block(m, 1024);
  b.Free;
  CheckEqualInt(1, m.ActiveVoices, 'the choked voice has faded out');
end;

procedure Test_Gate_ReleasesOnNoteOff;
var
  m: TDrumMachine;
  iface: IInterface;
  b: TAudioBuffer;
begin
  m := NewMachine;
  iface := m;
  if not LoadOrFail(m, 0, MakeDc('dc50f.wav', 40000, 0.5)) then Exit;
  m.Pads[0].Mode := dmGate;
  m.Hit(0, 100);
  b := Block(m, 256);
  b.Free;
  CheckEqualInt(1, m.ActiveVoices, 'sounding while held');
  m.Release(0);
  b := Block(m, 2048);
  b.Free;
  CheckEqualInt(0, m.ActiveVoices, 'a gate pad stops after release');
end;

procedure Test_OneShot_IgnoresRelease;
var
  m: TDrumMachine;
  iface: IInterface;
  b: TAudioBuffer;
begin
  m := NewMachine;
  iface := m;
  if not LoadOrFail(m, 0, MakeDc('dc50g.wav', 40000, 0.5)) then Exit;
  m.Hit(0, 100);
  b := Block(m, 256);
  b.Free;
  m.Release(0);
  b := Block(m, 2048);
  b.Free;
  CheckEqualInt(1, m.ActiveVoices, 'a one-shot plays on after release');
end;

procedure Test_SampleEnds;
var
  m: TDrumMachine;
  iface: IInterface;
  b: TAudioBuffer;
begin
  m := NewMachine;
  iface := m;
  if not LoadOrFail(m, 0, MakeDc('dc50h.wav', 300, 0.5)) then Exit;
  m.Hit(0, 100);
  b := Block(m, 1024);
  b.Free;
  CheckEqualInt(0, m.ActiveVoices, 'the voice frees itself when the sample ends');
end;

procedure Test_ClearPad;
var
  m: TDrumMachine;
  iface: IInterface;
begin
  m := NewMachine;
  iface := m;
  if not LoadOrFail(m, 5, MakeDc('dc50i.wav', 500, 0.5)) then Exit;
  Check(m.HasSample(5), 'loaded');
  m.ClearPad(5);
  CheckFalse(m.HasSample(5), 'cleared');
end;

procedure Test_RejectsBadFile;
var
  m: TDrumMachine;
  iface: IInterface;
  err: string;
begin
  m := NewMachine;
  iface := m;
  CheckFalse(m.LoadPad(0, ScratchDir + 'nothing-here.wav', err), 'a missing file is rejected');
  Check(err <> '', 'with a reason');
  CheckFalse(m.LoadPad(0, ScratchDir + 'x.mp3', err), 'an unsupported format is rejected');
  CheckFalse(m.HasSample(0), 'and the pad stays empty');
end;

procedure Test_KitRoundTrip;
var
  a, b: TDrumMachine;
  ia, ib: IInterface;
  kit, f: string;
begin
  a := NewMachine;
  ia := a;
  f := MakeDc('dc50j.wav', 800, 0.5);
  if not LoadOrFail(a, 4, f) then Exit;
  a.Pads[4].Name := 'Snare';
  a.Pads[4].Level := 1.25;
  a.Pads[4].Pan := -0.5;
  a.Pads[4].Muted := True;
  a.Pads[4].Choke := 3;
  a.Pads[4].Mode := dmGate;
  kit := ScratchDir + 'kit.cfg';
  Check(a.SaveKit(kit), 'kit saved');
  b := NewMachine;
  ib := b;
  Check(b.LoadKit(kit), 'kit loaded');
  Check(b.HasSample(4), 'the sample is back');
  CheckEqualStr('Snare', b.Pads[4].Name, 'name');
  CheckNear(1.25, b.Pads[4].Level, 0.001, 'level');
  CheckNear(-0.5, b.Pads[4].Pan, 0.001, 'pan');
  Check(b.Pads[4].Muted, 'mute');
  CheckEqualInt(3, b.Pads[4].Choke, 'choke group');
  Check(b.Pads[4].Mode = dmGate, 'gate mode');
  CheckFalse(b.HasSample(5), 'other pads stay empty');
end;

{ the kit is saved in the project file with its waveform overview, and an older file has none }
procedure Test_KitInProject;
var
  doc, back: TProjectDocument;
  d: TDrumKitPadData;
  k: Integer;
begin
  doc := TProjectDocument.CreateNew('kit');
  try
    CheckFalse(doc.DrumKit.Defined, 'a new project has no kit yet');
    d := Default(TDrumKitPadData);
    d.Note := 38;
    d.Path := 'C:/samples/snare.wav';
    d.Name := 'Snare';
    d.Level := 1.25;
    d.Pan := -0.5;
    d.Muted := True;
    d.Choke := 3;
    d.Mode := 1;
    d.Rate := 44100;
    d.Frames := 22050;
    d.Channels := 2;
    SetLength(d.Peaks, DRUMKIT_PEAK_COLUMNS * 2);
    for k := 0 to High(d.Peaks) do d.Peaks[k] := (k mod 21 - 10) * 50;
    doc.DrumKit.Put(d);
    back := ProjectFromString(ProjectToString(doc));
    try
      Check(back.DrumKit.Defined, 'the kit is defined after loading');
      CheckEqualInt(1, back.DrumKit.Count, 'one pad');
      CheckEqualInt(38, back.DrumKit[0].Note, 'note');
      CheckEqualStr('Snare', back.DrumKit[0].Name, 'name');
      CheckEqualStr('C:/samples/snare.wav', back.DrumKit[0].Path, 'path');
      CheckNear(1.25, back.DrumKit[0].Level, 0.001, 'level');
      CheckNear(-0.5, back.DrumKit[0].Pan, 0.001, 'pan');
      Check(back.DrumKit[0].Muted, 'mute');
      CheckEqualInt(3, back.DrumKit[0].Choke, 'choke');
      CheckEqualInt(1, back.DrumKit[0].Mode, 'mode');
      CheckEqualInt(Length(d.Peaks), Length(back.DrumKit[0].Peaks), 'overview length');
      CheckEqualInt(d.Peaks[7], back.DrumKit[0].Peaks[7], 'overview value');
    finally
      back.Free;
    end;
  finally
    doc.Free;
  end;
end;

procedure RegisterDrumTests;
begin
  RegisterTest('drum.machine', 'kit in the project file',    @Test_KitInProject);
  RegisterTest('drum.machine', 'note to pad mapping',        @Test_NoteMapping);
  RegisterTest('drum.machine', 'a hit mixes the sample',     @Test_HitMixesSample);
  RegisterTest('drum.machine', 'velocity and level',         @Test_VelocityAndLevel);
  RegisterTest('drum.machine', 'hard-left pan',              @Test_Pan_HardLeft);
  RegisterTest('drum.machine', 'mute and solo',              @Test_MuteAndSolo);
  RegisterTest('drum.machine', 'choke group',                @Test_ChokeGroup);
  RegisterTest('drum.machine', 'gate releases on note-off',  @Test_Gate_ReleasesOnNoteOff);
  RegisterTest('drum.machine', 'one-shot ignores release',   @Test_OneShot_IgnoresRelease);
  RegisterTest('drum.machine', 'voice frees at sample end',  @Test_SampleEnds);
  RegisterTest('drum.machine', 'clear pad',                  @Test_ClearPad);
  RegisterTest('drum.machine', 'bad files are rejected',     @Test_RejectsBadFile);
  RegisterTest('drum.machine', 'kit save / load',            @Test_KitRoundTrip);
end;

end.
