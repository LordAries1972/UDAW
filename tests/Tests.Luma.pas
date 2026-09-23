unit Tests.Luma;
{$IFDEF FPC}{$MODE DELPHI}{$MODESWITCH ADVANCEDRECORDS}{$H+}{$ENDIF}

{ Luma client tests - offline only (request bodies, capability gating, state
  mapping). Live submit/poll need a paid Luma key and are left to manual use. }

interface

procedure RegisterLumaTests;

implementation

uses
  SysUtils, UDAW.Errors, UDAW.AI.JSON, UDAW.Testing, UDAW.AI.Luma;

const
  GRP = 'ai.luma';

procedure Test_Capabilities;
var v, i: TLumaCapabilities;
begin
  v := LumaCapabilities(lmkVideo);
  i := LumaCapabilities(lmkImage);
  Check(v.Duration and v.Resolution and v.Loop and v.Keyframes, 'video controls');
  Check(not (v.Format or v.StyleRef or v.CharacterRef), 'video hides image controls');
  Check(i.Format and i.StyleRef and i.CharacterRef, 'image controls');
  Check(not (i.Duration or i.Resolution or i.Loop or i.Keyframes), 'image hides video controls');
  Check(not (v.Music or v.Lyrics or v.Instrumental or v.SheetMusic or
    i.Music or i.Lyrics or i.Instrumental or i.SheetMusic), 'no music / sheet music');
end;

procedure Test_VideoBody;
var c: TLumaClient; r: TLumaRequest; j: TJSONValue;
begin
  c := TLumaClient.Create('k');
  try
    r := Default(TLumaRequest);
    r.Kind := lmkVideo; r.Model := 'ray-2'; r.Prompt := 'a fox';
    r.Resolution := '720p'; r.Duration := '5s'; r.Loop := True;
    r.StartFrameUrl := 'https://example.com/a.jpg';
    r.Concepts := ['dolly_zoom'];
    j := Parse(c.RequestBody(r));
    try
      Check(j.ByName('concepts').Items[0].ByName('key').AsString = 'dolly_zoom', 'concept key');
      Check(j.ByName('model').AsString = 'ray-2', 'model');
      Check(j.ByName('duration').AsString = '5s', 'duration');
      Check(j.ByName('keyframes').HasName('frame0'), 'frame0');
      Check(not j.ByName('keyframes').HasName('frame1'), 'no frame1');
    finally j.Free; end;
    r.Duration := '7s';
    try
      c.RequestBody(r);
      Check(False, 'bad duration must raise');
    except on EUDAWError do Check(True, 'bad duration raises'); end;
    r.Duration := '5s'; r.Model := 'photon-1';
    try
      c.RequestBody(r);
      Check(False, 'wrong-kind model must raise');
    except on EUDAWError do Check(True, 'wrong-kind model raises'); end;
  finally c.Free; end;
end;

procedure Test_ImageBody_And_State;
var c: TLumaClient; r: TLumaRequest; j: TJSONValue;
begin
  c := TLumaClient.Create('k');
  try
    r := Default(TLumaRequest);
    r.Kind := lmkImage; r.Model := 'photon-1'; r.Prompt := 'a fox'; r.ImageFormat := 'png';
    r.ImageRefUrl := 'https://example.com/i.jpg'; r.ImageRefWeight := -1;
    r.ModifyRefUrl := 'https://example.com/m.jpg'; r.ModifyRefWeight := 0.05;
    j := Parse(c.RequestBody(r));
    try
      Check(j.ByName('format').AsString = 'png', 'format');
      Check(not j.HasName('duration'), 'image has no duration');
      Check(j.ByName('image_ref').Count = 1, 'image_ref');
      Check(Abs(j.ByName('modify_image_ref').ByName('weight').AsNumber - 0.05) < 1e-9, 'modify weight 0.05 kept');
    finally j.Free; end;
  finally c.Free; end;
  Check(LumaStateFromText('dreaming') = lsDreaming, 'dreaming');
  Check(LumaStateFromText('COMPLETED') = lsCompleted, 'completed');
  Check(LumaStateFromText('x') = lsUnknown, 'unknown');
end;

procedure RegisterLumaTests;
begin
  RegisterTest(GRP, 'Luma: capability gating', Test_Capabilities);
  RegisterTest(GRP, 'Luma: video request body', Test_VideoBody);
  RegisterTest(GRP, 'Luma: image body + state map', Test_ImageBody_And_State);
end;

end.
