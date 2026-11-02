unit UDAW.Audio.Backend.Factory;
{$I udaw.inc}

{ Phase 2 - selects the audio backend for the current platform.

  Preference order:
    Windows : WASAPI  -> software
    macOS   : (Core Audio, Phase 30) -> software
    Linux   : (PipeWire/ALSA, Phase 30) -> software

  A caller may force a specific backend by id (config key [audio] backend=,
  or the UDAW_AUDIO_BACKEND environment variable) - useful for headless CI
  ("software") and for A/B testing. An unavailable forced backend falls back
  to software with a logged warning; audio must never block startup. }

interface

uses
  SysUtils,
  UDAW.Errors, UDAW.Logging,
  UDAW.Audio.Types, UDAW.Audio.Device, UDAW.Audio.Backend.Software
  {$IFDEF UDAW_WINDOWS}, UDAW.Audio.Backend.WASAPI, UDAW.Audio.Backend.DirectSound{$ENDIF};

{ Create the best available backend. APreferredId '' / 'auto' = platform default;
  'software' | 'wasapi' | 'directsound' force that one (falling back to software if missing). }
function CreateAudioBackend(const APreferredId: string = ''): IAudioBackend;

{ The names accepted by CreateAudioBackend / shown in settings. }
function AvailableBackendIds: TArray<string>;

implementation

const
  SUBSYS = 'AudioFactory';

function MakeSoftware: IAudioBackend;
begin
  Result := TSoftwareBackend.Create(True);
end;

{$IFDEF UDAW_WINDOWS}
function MakeWASAPIOrSoftware: IAudioBackend;
begin
  if WASAPIAvailable then
  begin
    Result := TWASAPIBackend.Create;
    Logger.Info(SUBSYS, 'audio backend: WASAPI');
  end
  else
  begin
    Logger.Warn(SUBSYS, 'WASAPI unavailable; using software backend');
    Result := MakeSoftware;
  end;
end;
{$ENDIF}

function ResolvePreferred(const AId: string): string;
var
  s: string;
begin
  s := LowerCase(Trim(AId));
  if s = '' then
    s := LowerCase(Trim(GetEnvironmentVariable('UDAW_AUDIO_BACKEND')));
  Result := s;
end;

function CreateAudioBackend(const APreferredId: string): IAudioBackend;
var
  want: string;
begin
  want := ResolvePreferred(APreferredId);

  if want = 'software' then
    Exit(MakeSoftware);
  if want = 'null' then
    Exit(MakeSoftware);   // 'null' historically = non-hardware; software fills that role

  {$IFDEF UDAW_WINDOWS}
  if want = 'directsound' then
  begin
    if DirectSoundAvailable then
    begin
      Logger.Info(SUBSYS, 'audio backend: DirectSound');
      Exit(TDirectSoundBackend.Create);
    end;
    Logger.Warn(SUBSYS, 'DirectSound unavailable; using WASAPI/software');
    Exit(MakeWASAPIOrSoftware);
  end;
  if (want = '') or (want = 'auto') or (want = 'wasapi') then
    Exit(MakeWASAPIOrSoftware);
  Logger.Warn(SUBSYS, Format('unknown backend "%s"; using WASAPI/software', [want]));
  Exit(MakeWASAPIOrSoftware);
  {$ELSE}
  if (want <> '') and (want <> 'auto') then
    Logger.Warn(SUBSYS, Format('backend "%s" not available on this platform yet; using software', [want]));
  Result := MakeSoftware;
  {$ENDIF}
end;

function AvailableBackendIds: TArray<string>;
begin
  {$IFDEF UDAW_WINDOWS}
  Result := TArray<string>.Create('auto');
  if WASAPIAvailable then
    Result := Result + TArray<string>.Create('wasapi');
  if DirectSoundAvailable then
    Result := Result + TArray<string>.Create('directsound');
  Result := Result + TArray<string>.Create('software');
  {$ELSE}
  Result := TArray<string>.Create('auto', 'software');
  {$ENDIF}
end;

end.
