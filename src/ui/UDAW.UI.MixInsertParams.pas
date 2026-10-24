unit UDAW.UI.MixInsertParams;
{$I udaw.inc}

{ The parameter window for one mixer insert (a UDAW DSP effect kind with its plain
  "key=value;key=value" settings string - see UDAW.Mixer.Model.TMixInsert).

  This used to be a list of "key=value" lines with a text box. It is now the same window every
  other effect uses, UDAW.UI.EffectEditor: every numeric setting is a knob on the OpenGL 3.3
  widget set (range, caption and steps from the editor's table of known settings), every on/off
  switch a check box, with the effect's response curve beside them and a preset bar
  (Load / Save / Del) kept in MixerPresets.ini, one section per effect kind.

  Reused for two call sites in UDAW.UI.MainForm:
    - btnMixAddEQClick: edit the new insert's default settings before it is committed;
    - pbMixerDblClick: edit an existing insert's settings in place (undo-safe).
  VST2 / VST3 / CLAP inserts are NOT edited here - they host a real plug-in (TfrmVST2Editor). }

interface

uses
  Classes;

type
  TfrmMixInsertParams = class
  public
    { Opens the window modally. AKindId is the raw insert Kind (e.g. 'parametriceq'), the preset
      section and the curve selector; ADisplayName is what the user sees. Returns True, with
      AResultParams filled, only when the user clicked OK; on False the caller must not touch the
      insert. }
    class function Edit(AOwnerForm: TComponent; const AKindId, ADisplayName,
      AInitialParams: string; out AResultParams: string): Boolean;
  end;

implementation

uses
  UDAW.UI.EffectEditor;

class function TfrmMixInsertParams.Edit(AOwnerForm: TComponent; const AKindId, ADisplayName,
  AInitialParams: string; out AResultParams: string): Boolean;
begin
  Result := TfrmEffectEditor.Edit(AOwnerForm, ADisplayName, AKindId, AInitialParams, AResultParams,
    nil, nil, 0, AKindId);
end;

end.
