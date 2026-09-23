from pathlib import Path
import re
p=Path('src/ui/UDAW.UI.MainForm.pas');s=p.read_text(encoding='utf-8-sig').replace('FTlSelectedTrackId := clip.TrackId;', 'if cmd.CreatedTrackId > 0 then FTlSelectedTrackId := cmd.CreatedTrackId\n        else FTlSelectedTrackId := FRecTrackId;');p.write_text(s,encoding='utf-8-sig')
p=Path('src/audio/backend/UDAW.Audio.Backend.WASAPI.pas');s=p.read_text(encoding='utf-8-sig')
s=re.sub(r'    FInputRing: TAudioRing;[^\n]*\n','',s).replace('  FInputRing.Free;\n','').replace('  inBuf: TAudioBuffer;\n','').replace('  gotIn: Integer;\n','').replace('  scratch: TAudioSampleArray;\n','').replace('  ringScratch: TAudioSampleArray;\n','')
s=re.sub(r'      if FRequest.Direction = adDuplex then\n        inBuf :=.*?      SetLength\(scratch, Integer\(bufFrames\) \* channels\);\n','',s,flags=re.S)
s=s.replace('        inBuf.Free;\n','').replace('      SetLength(ringScratch, Integer(bufFrames) * channels);\n','')
s=re.sub(r'    if FInputRing = nil then\n    begin.*?    end;\n','',s,flags=re.S)
p.write_text(s,encoding='utf-8-sig')
# Give the input callback a bounded chunk staging path even for large native packets.
p=Path('src/audio/UDAW.Audio.Engine.pas');s=p.read_text(encoding='utf-8-sig');s=s.replace('  toWrite: Integer;','  toWrite, offset, frame, blockFrames: Integer;\n  inputSample: PAudioSample;')
a=s.index('      toWrite := AInput.FrameCount;');b=s.index('\n    end;',a)
s=s[:a]+'''      if AInput.ChannelCount = FCaptureRing.Channels then
      begin
        blockFrames := Length(FCaptureScratch) div AInput.ChannelCount;
        offset := 0;
        while (offset < AInput.FrameCount) and (blockFrames > 0) do
        begin
          toWrite := AInput.FrameCount - offset;
          if toWrite > blockFrames then toWrite := blockFrames;
          for ch := 0 to AInput.ChannelCount - 1 do
          begin
            inputSample := AInput.ChannelPtr(ch);
            Inc(inputSample, offset);
            for frame := 0 to toWrite - 1 do
            begin
              FCaptureScratch[frame * AInput.ChannelCount + ch] := inputSample^;
              Inc(inputSample);
            end;
          end;
          FCaptureRing.WriteFrames(FCaptureScratch[0], toWrite);
          Inc(offset, toWrite);
        end;
      end;'''+s[b:];p.write_text(s,encoding='utf-8-sig')
# Unique take folder even for immediate back-to-back recordings.
p=Path('src/recording/UDAW.Recording.Engine.pas');s=p.read_text(encoding='utf-8-sig');s=s.replace('procedure TRecordingEngine.Start(APlayheadSeconds: Double);\nbegin','procedure TRecordingEngine.Start(APlayheadSeconds: Double);\nvar\n  id: TGUID;\nbegin').replace('  FState := rsRolling;\nend;\n\nfunction TRecordingEngine.GateAt', "  CreateGUID(id);\n  FSessionStamp := FSessionStamp + '-' + GUIDToString(id);\n  FState := rsRolling;\nend;\n\nfunction TRecordingEngine.GateAt");p.write_text(s,encoding='utf-8-sig')
