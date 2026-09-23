from pathlib import Path
p=Path('src/recording/UDAW.Recording.ChunkFile.pas');s=p.read_text(encoding='utf-8-sig').replace('procedure Finalize;', 'procedure Finalize(AKeepRecoveryMarker: Boolean = False);').replace('procedure TRecordingChunkWriter.Finalize;', 'procedure TRecordingChunkWriter.Finalize(AKeepRecoveryMarker: Boolean);').replace('    if FileExists(ChunkMarkerPath(FSessionDir)) then','    if (not AKeepRecoveryMarker) and FileExists(ChunkMarkerPath(FSessionDir)) then');p.write_text(s,encoding='utf-8-sig')
p=Path('src/recording/UDAW.Recording.Engine.pas');s=p.read_text(encoding='utf-8-sig').replace('  FWriter.Finalize;', '  FWriter.Finalize(True);').replace('    reader.FinalizeToWav(wavPath, FSettings.TakeFormat);', '    reader.FinalizeToWav(wavPath, FSettings.TakeFormat);\n    DeleteFile(ChunkMarkerPath(sessionDir));');p.write_text(s,encoding='utf-8-sig')
p=Path('src/ui/UDAW.UI.MainForm.pas');s=p.read_text(encoding='utf-8-sig').replace('    FRecTrackId: Integer;', '    FRecTrackId: Integer;\n    FRecInsertSeconds: Double;');s=s.replace('else Result := Max(0, FProject.Timeline.PlayheadSeconds);','else Result := Max(0, FRecInsertSeconds);');s=s.replace('tl.PlayheadSeconds := FTlView.Snap(sec);','tl.PlayheadSeconds := FTlView.Snap(sec);\n    FRecInsertSeconds := tl.PlayheadSeconds;');s=s.replace('  FTlSelectedTrackId := -1;', '  FTlSelectedTrackId := -1;\n  FRecInsertSeconds := 0;');s=s.replace('  FProject.Timeline.PlayheadSeconds := 0;', '  FProject.Timeline.PlayheadSeconds := 0;\n  FRecInsertSeconds := 0;');s=s.replace('  tl.PlayheadSeconds := endSec;', '  tl.PlayheadSeconds := endSec;\n  FRecInsertSeconds := endSec;')
# All declarations used by streamed form events must be published.
# Keep capture UI status readable and avoid painting mutable engine state.
s=s.replace("  ShowStatusProgress('Finishing recording: draining captured audio...', 3);", "  ShowStatusProgress('Finishing recording: draining and saving complete audio...', 3);")
# Simplify obsolete simulation comment.
a=s.index('{ ---- Recording (Phase 8):');b=s.index('function TfrmMain.BuildRecordSettings:',a);s=s[:a]+'''{ Live recording: the audio callback feeds a bounded ring; the dedicated writer
  drains and finalizes the take before the UI commits it to the timeline. }

'''+s[b:]
p.write_text(s,encoding='utf-8-sig')
p=Path('src/audio/UDAW.Audio.Device.pas');s=p.read_text(encoding='utf-8-sig').replace('  { input may be nil for adRender; output may be nil for adCapture. }','''  { Input/output can arrive independently, including duplex WASAPI streams:
    capture calls with AOutput=nil, render calls with AInput=nil on separate
    workers. Consumers must keep input and output scratch/state independent. }''');p.write_text(s,encoding='utf-8-sig')
# Strengthen writer tail coverage: queue a ragged final block and stop immediately.
p=Path('tests/Tests.Phase8.pas');s=p.read_text(encoding='utf-8-sig').replace('  TOTAL = SR;                 // 1 s','  TOTAL = SR + 137;           // ragged final block')
a=s.index('      { wait for the ring to drain }');b=s.index('      wt.Stop;',a);s=s[:a]+s[b:];s=s.replace('  pushed, n, guard: Integer;', '  pushed, n: Integer;');s=s.replace("      CheckEqualInt(TOTAL, wt.FramesConsumed, 'writer thread consumed every frame from the ring');", "      CheckEqualInt(TOTAL, wt.FramesConsumed, 'writer thread consumed every frame from the ring');\n      CheckEqualInt(TOTAL, eng.LastTake.FrameCount, 'Stop finalized every frame including the queued tail');\n      CheckEqualInt(TOTAL, ReadWavInfo(eng.LastTake.WavFile).FrameCount, 'final WAV contains the full tail');")
a=s.index('{ ---------------- registration ---------------- }')
s=s[:a]+'''procedure Test_FullLength_SelectedTrack;
const
  RATE = 8000;
  TOTAL = RATE * 65 + 137;
var
  eng: TRecordingEngine;
  settings: TRecordSettings;
  block: TAudioSampleArray;
  take: TRecordedTake;
  doc: TProjectDocument;
  mgr: TCommandManager;
  target: TTimelineTrack;
  specs: TRecordedClipSpecArray;
  cmd: TCommitTakeCommand;
  clip: TTimelineClip;
  pos, n: Integer;
begin
  settings := TRecordSettings.Default;
  settings.SampleRate := RATE;
  eng := NewEngine('full-length-selected', settings);
  doc := TProjectDocument.CreateNew('full recording');
  mgr := TCommandManager.Create;
  try
    target := doc.Timeline.AddTrack(tkAudio, 'Selected destination');
    eng.Arm;
    eng.Start(12.375);
    block := MakeInterleaved(2, 311);
    pos := 0;
    while pos < TOTAL do
    begin
      n := Min(311, TOTAL - pos);
      eng.ProcessCaptureBlock(block[0], n);
      Inc(pos, n);
    end;
    eng.Stop;
    take := eng.LastTake;
    CheckEqualInt(TOTAL, take.FrameCount, 'capture is not capped at 60 seconds');
    CheckEqualInt(TOTAL, ReadWavInfo(take.WavFile).FrameCount, 'saved WAV has every frame');
    SetLength(specs, 1);
    specs[0].SourceWavFile := take.WavFile;
    specs[0].Name := take.Name;
    specs[0].SampleRate := RATE;
    specs[0].Channels := 2;
    specs[0].SourceFrameCount := take.FrameCount;
    specs[0].TimelineStartSeconds := take.TimelineStartSeconds;
    specs[0].SourceOffsetSeconds := 0;
    specs[0].LengthSeconds := take.LengthSeconds;
    cmd := TCommitTakeCommand.Create(doc, target.Id, specs);
    Check(mgr.Perform(cmd), 'selected-track commit succeeds');
    CheckEqualInt(1, doc.Timeline.TrackCount, 'selected track reused');
    clip := target.GetClip(0);
    CheckNear(12.375, clip.StartSeconds, 1e-9, 'insertion point retained');
    CheckNear(TOTAL / RATE, clip.LengthSeconds, 1e-9, 'full take duration retained');
    mgr.Undo;
    CheckEqualInt(1, doc.Timeline.TrackCount, 'undo preserves existing track');
    CheckEqualInt(0, target.ClipCount, 'undo removes take');
    mgr.Redo;
    CheckEqualInt(1, target.ClipCount, 'redo restores full take');
    eng.ClearTakes;
    eng.Start(0);
    eng.ProcessCaptureBlock(block[0], 137);
    eng.Stop;
    CheckNear(0, eng.LastTake.TimelineStartSeconds, 0, 'unset insertion starts at zero');
    Check(take.SessionDir <> eng.LastTake.SessionDir, 'rapid takes have unique containers');
  finally
    mgr.Free;
    doc.Free;
    eng.Free;
  end;
end;

'''+s[a:];s=s.replace("  RegisterTest('recording.settings', 'defaults + validate'", "  RegisterTest('recording.commit', 'full length on selected track and zero origin', @Test_FullLength_SelectedTrack);\n  RegisterTest('recording.settings', 'defaults + validate'");p.write_text(s,encoding='utf-8-sig')
