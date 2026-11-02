unit UDAW.UI.FoleySampler;
{$I udaw.inc}

{ Foley Sampler engine: sixteen pads, each holding one sound effect (WAV or MP3).  The Foley page of
  the Timeline dock drives it - hit a pad with the mouse or the 4 x 4 keyboard block
  1234 / QWER / ASDF / ZXCV to hear it.  While the Timeline plays, "Record hits" notes where the
  playhead was for every hit; "Add hits to Timeline" then lays them out as clips (one track per pad),
  so a sound performed live against the picture lands in time.  "Place pad at playhead" drops one
  sound at the playhead without recording.

  Pad sounds play through UDAW's audio engine (as an overlay on whatever the Timeline is playing),
  so they follow the Output device and backend chosen in Settings.  Pad assignments are remembered
  between sessions.  This unit has no user interface of its own. }

interface

uses
  SysUtils, Classes, UDAW.Audio.Source, UDAW.Drum.Machine;

const
  FOLEY_PAD_COUNT = 16;
  FOLEY_PAD_KEYS = '1234QWERASDFZXCV';

type
  TFoleyHit = record
    PadIndex: Integer;
    SampleFile: string;
    Seconds: Double;
  end;

  TFoleyPlayheadFunc = function: Double of object;
  TFoleyPlayingFunc = function: Boolean of object;
  TFoleyCommitEvent = procedure(const AHits: TArray<TFoleyHit>) of object;
  TFoleyPlaceEvent = procedure(const AFile: string; ASeconds: Double) of object;

  TFoleySampler = class
  private
    FFiles: array[0..FOLEY_PAD_COUNT - 1] of string;
    FHeld: array[0..FOLEY_PAD_COUNT - 1] of Boolean;
    FSelected: Integer;
    FHits: TArray<TFoleyHit>;
    FDrum: TDrumMachine;       // plays the pads; owned through FDrumRef
    FDrumRef: IAudioSource;
    FOnPlayhead: TFoleyPlayheadFunc;
    FOnIsPlaying: TFoleyPlayingFunc;
    FOnCommit: TFoleyCommitEvent;
    FOnPlace: TFoleyPlaceEvent;
    FOnInsert: TFoleyPlaceEvent;
    FOnChange: TNotifyEvent;
    function IniPath: string;
    function GetFile(AIndex: Integer): string;
    function GetHitCount: Integer;
    procedure LoadSound(AIndex: Integer);
    procedure SavePads;
    procedure Changed;
  public
    constructor Create;
    destructor Destroy; override;
    { index of the pad a key belongs to, or -1 }
    class function PadForKey(AKey: Word): Integer; static;
    procedure LoadPads;
    procedure AttachToEngine;
    procedure DetachFromEngine;
    procedure SelectPad(AIndex: Integer);
    { plays the pad; a pad KEY (AFromKey) may also insert its sound on the Timeline (AInsertOnKey),
      and while the Timeline plays the hit may be recorded (ARecord) }
    procedure Hit(AIndex: Integer; AFromKey, AInsertOnKey, ARecord: Boolean);
    { keyboard auto-repeat guard: False while the key is already down }
    function KeyDown(APad: Integer): Boolean;
    procedure KeyUp(APad: Integer);
    procedure AssignFile(AIndex: Integer; const AFileName: string);
    procedure ClearPad(AIndex: Integer);
    procedure PlaceSelected;
    procedure CommitHits;
    procedure DiscardHits;
    property Files[AIndex: Integer]: string read GetFile;
    property Selected: Integer read FSelected;
    property HitCount: Integer read GetHitCount;
    property OnPlayhead: TFoleyPlayheadFunc read FOnPlayhead write FOnPlayhead;
    property OnIsPlaying: TFoleyPlayingFunc read FOnIsPlaying write FOnIsPlaying;
    property OnCommit: TFoleyCommitEvent read FOnCommit write FOnCommit;
    property OnPlace: TFoleyPlaceEvent read FOnPlace write FOnPlace;
    { a pad KEY was pressed: put its sound on the Timeline at the playhead (splitting the clip
      the playhead is inside, so the sound lands between the two halves) }
    property OnInsert: TFoleyPlaceEvent read FOnInsert write FOnInsert;
    { pads, selection or recorded hits changed - the page refreshes itself }
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;

implementation

uses
  IniFiles, UDAW.Paths, UDAW.App, UDAW.Audio.Engine, UDAW.Codec.MP3, UDAW.Codec.MP3.Decoder;

constructor TFoleySampler.Create;
begin
  inherited Create;
  FDrum := TDrumMachine.Create;
  FDrumRef := FDrum;
end;

destructor TFoleySampler.Destroy;
begin
  DetachFromEngine;
  FDrum := nil;
  FDrumRef := nil;
  inherited Destroy;
end;

procedure TFoleySampler.Changed;
begin
  if Assigned(FOnChange) then FOnChange(Self);
end;

function TFoleySampler.IniPath: string;
begin
  Result := DataFile('FoleyPads.ini');
end;

function TFoleySampler.GetFile(AIndex: Integer): string;
begin
  if (AIndex >= 0) and (AIndex < FOLEY_PAD_COUNT) then Result := FFiles[AIndex] else Result := '';
end;

function TFoleySampler.GetHitCount: Integer;
begin
  Result := Length(FHits);
end;

class function TFoleySampler.PadForKey(AKey: Word): Integer;
var
  p: Integer;
begin
  Result := -1;
  if AKey > 255 then Exit;
  p := Pos(UpCase(Chr(AKey)), FOLEY_PAD_KEYS);
  if p > 0 then Result := p - 1;
end;

{ decodes the pad's file into the drum machine (WAV directly, MP3 through the decoder); a file that
  cannot be read leaves the pad silent }
procedure TFoleySampler.LoadSound(AIndex: Integer);
var
  err: string;
  res: TMP3DecodeResult;
begin
  FDrum.ClearPad(AIndex);
  if FFiles[AIndex] = '' then Exit;
  try
    if SameText(ExtractFileExt(FFiles[AIndex]), '.mp3') then
    begin
      if Mp3DecodeFile(FFiles[AIndex], res) then
        FDrum.SetPadData(AIndex, res.Pcm, res.SampleRate, FFiles[AIndex]);
    end
    else
      FDrum.LoadPad(AIndex, FFiles[AIndex], err);
  except
    on E: Exception do ;   // an unreadable file just stays silent
  end;
end;

{ the pads sound through the audio engine - the output device and backend chosen in Settings }
procedure TFoleySampler.AttachToEngine;
begin
  if (App <> nil) and (App.Audio <> nil) then
    App.Audio.SetOverlay(FDrumRef);
end;

procedure TFoleySampler.DetachFromEngine;
begin
  if (App <> nil) and (App.Audio <> nil) then
    App.Audio.SetOverlay(nil);
end;

procedure TFoleySampler.LoadPads;
var
  ini: TMemIniFile;
  i: Integer;
begin
  ini := TMemIniFile.Create(IniPath);
  try
    for i := 0 to FOLEY_PAD_COUNT - 1 do
    begin
      FFiles[i] := ini.ReadString('Pads', 'Pad' + IntToStr(i + 1), '');
      if (FFiles[i] <> '') and not FileExists(FFiles[i]) then FFiles[i] := '';
      LoadSound(i);
    end;
  finally
    ini.Free;
  end;
  Changed;
end;

procedure TFoleySampler.SavePads;
var
  ini: TMemIniFile;
  i: Integer;
begin
  ini := TMemIniFile.Create(IniPath);
  try
    for i := 0 to FOLEY_PAD_COUNT - 1 do
      ini.WriteString('Pads', 'Pad' + IntToStr(i + 1), FFiles[i]);
    ini.UpdateFile;
  finally
    ini.Free;
  end;
end;

procedure TFoleySampler.SelectPad(AIndex: Integer);
begin
  if (AIndex < 0) or (AIndex >= FOLEY_PAD_COUNT) then Exit;
  FSelected := AIndex;
  Changed;
end;

procedure TFoleySampler.Hit(AIndex: Integer; AFromKey, AInsertOnKey, ARecord: Boolean);
var
  h: TFoleyHit;
  inserted: Boolean;
begin
  if (AIndex < 0) or (AIndex >= FOLEY_PAD_COUNT) then Exit;
  SelectPad(AIndex);
  if FFiles[AIndex] = '' then Exit;
  AttachToEngine;   // idempotent; also re-attaches after the audio engine was reopened
  FDrum.Hit(AIndex, 127);
  inserted := False;
  if AFromKey and AInsertOnKey and Assigned(FOnInsert) and Assigned(FOnPlayhead) then
  begin
    FOnInsert(FFiles[AIndex], FOnPlayhead());
    inserted := True;   { already on the Timeline: not also kept as a recorded hit }
  end;
  if (not inserted) and ARecord and Assigned(FOnIsPlaying) and FOnIsPlaying() and Assigned(FOnPlayhead) then
  begin
    h.PadIndex := AIndex;
    h.SampleFile := FFiles[AIndex];
    h.Seconds := FOnPlayhead();
    SetLength(FHits, Length(FHits) + 1);
    FHits[High(FHits)] := h;
    Changed;
  end;
end;

function TFoleySampler.KeyDown(APad: Integer): Boolean;
begin
  Result := (APad >= 0) and (APad < FOLEY_PAD_COUNT) and not FHeld[APad];
  if Result then FHeld[APad] := True;   // a held key must not retrigger on keyboard auto-repeat
end;

procedure TFoleySampler.KeyUp(APad: Integer);
begin
  if (APad >= 0) and (APad < FOLEY_PAD_COUNT) then FHeld[APad] := False;
end;

procedure TFoleySampler.AssignFile(AIndex: Integer; const AFileName: string);
begin
  if (AIndex < 0) or (AIndex >= FOLEY_PAD_COUNT) then Exit;
  FFiles[AIndex] := AFileName;
  LoadSound(AIndex);
  SavePads;
  Changed;
end;

procedure TFoleySampler.ClearPad(AIndex: Integer);
begin
  AssignFile(AIndex, '');
end;

procedure TFoleySampler.PlaceSelected;
begin
  if (FFiles[FSelected] = '') or not Assigned(FOnPlace) or not Assigned(FOnPlayhead) then Exit;
  FOnPlace(FFiles[FSelected], FOnPlayhead());
end;

procedure TFoleySampler.CommitHits;
begin
  if (Length(FHits) = 0) or not Assigned(FOnCommit) then Exit;
  FOnCommit(FHits);
  FHits := nil;
  Changed;
end;

procedure TFoleySampler.DiscardHits;
begin
  FHits := nil;
  Changed;
end;

end.
