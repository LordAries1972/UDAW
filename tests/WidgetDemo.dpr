program WidgetDemo;

{ Visual check of UDAW.GL.Widgets: builds every widget on a plain form, opens the
  combo, then screenshots the form to the PNG named by the first argument and
  exits. Without an argument the form just stays open. }

{$APPTYPE GUI}

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Classes, Vcl.Forms, Vcl.Controls,
  Vcl.Graphics, Vcl.ExtCtrls, Vcl.Imaging.pngimage, Vcl.Themes, Vcl.Styles,
  UDAW.GL.Canvas, UDAW.GL.Widgets;

type
  TDemo = class
    Form: TForm;
    Combo: TGLCombo;
    Edit: TGLEdit;
    Shot, Results: string;
    Slider: TGLSlider;
    KnobW: TGLKnob;
    Scroll: TGLScrollBar;
    Tabs: TGLTabStrip;
    Check: TGLCheck;
    Memo: TGLMemo;
    Toggle: TGLButton;
    Log: TStringList;
    Tm, FrameTm: TTimer;
    StylePath: string;
    Frame: Integer;
    Step: Integer;
    procedure Tick(Sender: TObject);
    procedure Expect(const AName: string; ACond: Boolean);
    procedure Click(W: TWinControl; X, Y: Integer);
    procedure RunTests;
    procedure SaveShot(const AFile: string);
    procedure FrameTick(Sender: TObject);
  end;

procedure TDemo.Expect(const AName: string; ACond: Boolean);
begin
  if ACond then Log.Add('PASS ' + AName) else Log.Add('FAIL ' + AName);
end;

procedure TDemo.Click(W: TWinControl; X, Y: Integer);
begin
  W.Perform(WM_LBUTTONDOWN, MK_LBUTTON, MakeLong(X, Y));
  W.Perform(WM_LBUTTONUP, 0, MakeLong(X, Y));
end;

procedure TDemo.RunTests;
var
  b: Double;
  lst: TWinControl;
begin
  { knob: drag up 40 px = +20 of 100 }
  b := KnobW.Position;
  KnobW.Perform(WM_LBUTTONDOWN, MK_LBUTTON, MakeLong(30, 40));
  KnobW.Perform(WM_MOUSEMOVE, MK_LBUTTON, MakeLong(30, 0));
  KnobW.Perform(WM_LBUTTONUP, 0, MakeLong(30, 0));
  Expect(Format('knob drag up (%.1f -> %.1f)', [b, KnobW.Position]), Abs(KnobW.Position - (b + 20)) < 1.5);
  KnobW.Perform(WM_LBUTTONDBLCLK, MK_LBUTTON, MakeLong(30, 30));
  Expect('knob double-click resets to default', KnobW.Position = KnobW.DefaultPosition);
  KnobW.Position := 10;
  KnobW.Perform(WM_MOUSEWHEEL, MakeLong(0, 120), MakeLong(0, 0));
  Expect(Format('knob wheel up (%.1f)', [KnobW.Position]), KnobW.Position > 10);

  { slider click at mid track }
  Click(Slider, 100, 12);
  Expect(Format('slider click mid (%.1f)', [Slider.Position]), Abs(Slider.Position - 50) < 2);

  { scroll bar track click pages forward }
  Scroll.Position := 0;
  Click(Scroll, 190, 8);
  Expect(Format('scrollbar page forward (%d)', [Scroll.Position]), Scroll.Position > 0);

  { tabs }
  Click(Tabs, 330, 14);
  Expect(Format('tab click (%d)', [Tabs.TabIndex]), Tabs.TabIndex = 3);

  { check + toggle button }
  b := Ord(Check.Checked);
  Click(Check, 10, 10);
  Expect('check toggles', Check.Checked = (b = 0));
  b := Ord(Toggle.Down);
  Click(Toggle, 10, 10);
  Expect('toggle button flips', Toggle.Down = (b = 0));

  { edit: type, backspace, caret keys }
  Edit.Text := 'abc';
  Click(Edit, 190, 10);
  Edit.Perform(WM_CHAR, Ord('x'), 0);
  Expect('edit type at end: ' + Edit.Text, Edit.Text = 'abcx');
  Edit.Perform(WM_KEYDOWN, VK_BACK, 0);
  Expect('edit backspace: ' + Edit.Text, Edit.Text = 'abc');
  Edit.Perform(WM_KEYDOWN, VK_HOME, 0);
  Edit.Perform(WM_CHAR, Ord('Z'), 0);
  Expect('edit home + insert: ' + Edit.Text, Edit.Text = 'Zabc');
  Edit.Perform(WM_KEYDOWN, VK_DELETE, 0);
  Expect('edit delete: ' + Edit.Text, Edit.Text = 'Zbc');
  Edit.MaxLength := 3;
  Edit.Perform(WM_CHAR, Ord('q'), 0);
  Expect('edit MaxLength: ' + Edit.Text, Edit.Text = 'Zbc');
  Edit.MaxLength := 0;
  Edit.SelectAll;
  Edit.Perform(WM_CHAR, Ord('k'), 0);
  Expect('edit replace selection: ' + Edit.Text, Edit.Text = 'k');

  { editable memo }
  Memo.Perform(WM_CHAR, Ord('a'), 0);
  Memo.Perform(WM_CHAR, Ord('b'), 0);
  Memo.Perform(WM_CHAR, 13, 0);
  Memo.Perform(WM_CHAR, Ord('c'), 0);
  Expect('memo type + enter: ' + StringReplace(Memo.Text, #13#10, '|', []), Memo.Text = 'ab' + sLineBreak + 'c');
  Memo.Perform(WM_KEYDOWN, VK_BACK, 0);
  Memo.Perform(WM_KEYDOWN, VK_BACK, 0);
  Expect('memo backspace joins lines: ' + Memo.Text, Memo.Text = 'ab');
  Memo.Perform(WM_KEYDOWN, VK_HOME, 0);
  Memo.Perform(WM_CHAR, Ord('X'), 0);
  Expect('memo home + insert: ' + Memo.Text, Memo.Text = 'Xab');
  Memo.SelStart := 1;
  Memo.SelLength := 1;
  Memo.SelText := '';
  Expect('memo SelText delete: ' + Memo.Text, Memo.Text = 'Xb');
  Memo.MaxLength := 3;
  Memo.Perform(WM_KEYDOWN, VK_END, 0);
  Memo.Perform(WM_CHAR, Ord('1'), 0);
  Memo.Perform(WM_CHAR, Ord('2'), 0);
  Expect('memo MaxLength: ' + Memo.Text, Memo.Text = 'Xb1');
  Memo.Perform(WM_KEYDOWN, VK_LEFT, 0);
  Memo.Perform(WM_KEYDOWN, VK_DELETE, 0);
  Expect('memo delete: ' + Memo.Text, Memo.Text = 'Xb');

  { combo: pick a row, then outside click keeps the value }
  Combo.ItemIndex := 2;
  Combo.DropDown;
  Expect('combo opens', Combo.DroppedDown and (Combo.ListWindow <> nil));
  lst := Combo.ListWindow;
  Click(lst, 20, 5);
  Expect(Format('combo pick row 0 (%d)', [Combo.ItemIndex]), (Combo.ItemIndex = 0) and not Combo.DroppedDown);
  Combo.DropDown;
  lst := Combo.ListWindow;
  Click(lst, -20, -20);
  Expect('combo outside click closes, keeps value', (not Combo.DroppedDown) and (Combo.ItemIndex = 0));
  Combo.ItemIndex := 2;
end;

procedure TDemo.SaveShot(const AFile: string);
var
  bmp: TBitmap;
  png: TPngImage;
  dc: HDC;
  r: TRect;
begin
  r := Form.BoundsRect;
  bmp := TBitmap.Create;
  png := TPngImage.Create;
  try
    bmp.SetSize(r.Width, r.Height + 200);
    dc := GetDC(0);
    BitBlt(bmp.Canvas.Handle, 0, 0, bmp.Width, bmp.Height, dc, r.Left, r.Top, SRCCOPY);
    ReleaseDC(0, dc);
    png.Assign(bmp);
    png.SaveToFile(AFile);
  finally
    png.Free;
    bmp.Free;
  end;
end;

procedure TDemo.FrameTick(Sender: TObject);
begin
  SaveShot(ChangeFileExt(Shot, '') + '_f' + IntToStr(Frame) + '.png');
  Inc(Frame);
  if Frame >= 12 then Application.Terminate;
end;

procedure TDemo.Tick(Sender: TObject);
var
  bmp: TBitmap;
  png: TPngImage;
  dc: HDC;
  r: TRect;
begin
  Inc(Step);
  case Step of
    1:
      begin
        Edit.SetFocus;
        if Results <> '' then
        begin
          Log := TStringList.Create;
          try
            RunTests;
          except
            on E: Exception do Log.Add('EXCEPTION ' + E.ClassName + ': ' + E.Message);
          end;
          Log.SaveToFile(Results);
        end;
        Combo.DropDown;
      end;
    4:
      if StylePath <> '' then
      begin
        Tm.Enabled := False;
        TStyleManager.LoadFromFile(StylePath);
        FrameTm.Enabled := True;
        TStyleManager.SetStyle(TStyleManager.StyleNames[High(TStyleManager.StyleNames)]);
      end
      else
      begin
        if Shot <> '' then
        begin
          r := Form.BoundsRect;
          bmp := TBitmap.Create;
          png := TPngImage.Create;
          try
            bmp.SetSize(r.Width, r.Height + 200);
            dc := GetDC(0);
            BitBlt(bmp.Canvas.Handle, 0, 0, bmp.Width, bmp.Height, dc, r.Left, r.Top, SRCCOPY);
            ReleaseDC(0, dc);
            png.Assign(bmp);
            png.SaveToFile(Shot);
          finally
            png.Free;
            bmp.Free;
          end;
          Application.Terminate;
        end;
      end;
  end;
end;

var
  d: TDemo;
  f: TForm;
  w: TGLWidget;

function Put(AWidget: TGLWidget; L, T, W, H: Integer; const ACaption, AHint: string): TGLWidget;
begin
  AWidget.Parent := f;
  AWidget.SetBounds(L, T, W, H);
  AWidget.Caption := ACaption;
  AWidget.Hint := AHint;
  Result := AWidget;
end;

begin
  Application.Initialize;
  Application.ShowHint := True;
  Application.CreateForm(TForm, f);
  f.Caption := 'UDAW GL widgets';
  f.ClientWidth := 560;
  f.ClientHeight := 320;
  f.Position := poScreenCenter;
  f.DoubleBuffered := True;

  d := TDemo.Create;
  d.Form := f;
  if ParamCount > 0 then d.Shot := ParamStr(1);
  if ParamCount > 1 then d.Results := ParamStr(2);
  if ParamCount > 2 then d.StylePath := ParamStr(3);

  Put(TGLButton.Create(f), 16, 16, 90, 28, 'Button', 'Push button');
  w := Put(TGLButton.Create(f), 116, 16, 90, 28, 'Toggle', 'Toggle button');
  TGLButton(w).Toggle := True;
  TGLButton(w).Down := True;
  d.Toggle := TGLButton(w);
  w := Put(TGLButton.Create(f), 216, 16, 90, 28, 'Disabled', 'Disabled');
  w.Enabled := False;
  w := Put(TGLCheck.Create(f), 320, 18, 120, 24, 'Check me', 'Check box');
  TGLCheck(w).Checked := True;
  d.Check := TGLCheck(w);

  w := Put(TGLKnob.Create(f), 16, 64, 60, 78, 'Cutoff', 'Knob');
  TGLKnob(w).Max := 100;
  TGLKnob(w).Position := 65;
  d.KnobW := TGLKnob(w);
  Put(TGLKnob.Create(f), 90, 64, 60, 78, 'Mix', 'Knob at zero');
  w := Put(TGLSlider.Create(f), 170, 72, 200, 24, '', 'Horizontal slider');
  TGLSlider(w).Position := 40;
  d.Slider := TGLSlider(w);
  w := Put(TGLSlider.Create(f), 400, 64, 24, 100, '', 'Vertical slider');
  TGLSlider(w).Vertical := True;
  TGLSlider(w).Position := 70;
  w := Put(TGLProgress.Create(f), 170, 112, 200, 12, '', 'Progress');
  TGLProgress(w).Position := 55;
  w := Put(TGLScrollBar.Create(f), 170, 140, 200, 16, '', 'Scroll bar');
  d.Scroll := TGLScrollBar(w);
  TGLScrollBar(w).Position := 30;

  w := Put(TGLTabStrip.Create(f), 16, 176, 360, 28, '', '');
  TGLTabStrip(w).Tabs := 'Mixer;Piano;Tracker;Record';
  TGLTabStrip(w).Hints := 'Mixer tab;Piano roll tab;Tracker tab;Recording tab';
  TGLTabStrip(w).TabIndex := 1;
  d.Tabs := TGLTabStrip(w);

  d.Edit := TGLEdit.Create(f);
  d.Edit.Parent := f;
  d.Edit.SetBounds(16, 224, 200, 26);
  d.Edit.Hint := 'Text box';
  d.Edit.Text := 'Hello UDAW';

  d.Combo := TGLCombo.Create(f);
  d.Combo.Parent := f;
  d.Combo.SetBounds(240, 224, 160, 26);
  d.Combo.Hint := 'Drop-down';
  d.Combo.Items.CommaText := 'Sine,Square,Saw,Triangle,Noise';
  d.Combo.ItemIndex := 2;

  d.Memo := TGLMemo.Create(f);
  d.Memo.Parent := f;
  d.Memo.SetBounds(440, 224, 100, 60);
  d.Memo.ReadOnly := False;
  f.Show;
  d.Tm := TTimer.Create(f);
  d.Tm.Interval := 500;
  d.Tm.OnTimer := d.Tick;
  d.FrameTm := TTimer.Create(f);
  d.FrameTm.Enabled := False;
  d.FrameTm.Interval := 60;
  d.FrameTm.OnTimer := d.FrameTick;
  Application.Run;
end.
