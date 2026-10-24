unit UDAW.Timeline.OfflineFx;
{$I udaw.inc}

{ Renders one effect over a stretch of a planar buffer, in place: the fades, the offline
  spectral tools and every DSP node kind, the same three routes the Timeline's range effects
  take. Used by the instrument editor to apply an effect to a marked region of a drum sample.
  UI-free. }

interface

uses
  SysUtils, Math, UDAW.Audio.Types;

{ Processes frames [AFrom, AFrom + ALen) of APlanar with the effect AKind (a node kind id, or
  an '@' tool id) and its settings AParams ("key=value;key=value"). False, with AError, when
  the kind is unknown or the effect failed; the buffer is untouched then. }
function ApplyEffectOffline(const AKind, AParams: string; var APlanar: TAudioPlanar;
  AChannels, ASampleRate, AFrom, ALen: Integer; out AError: string): Boolean;

implementation

uses
  UDAW.Audio.Buffer, UDAW.Audio.Graph.Nodes, UDAW.Timeline.SpectralFx;

const
  BLOCK = 1024;

function ApplyEffectOffline(const AKind, AParams: string; var APlanar: TAudioPlanar;
  AChannels, ASampleRate, AFrom, ALen: Integer; out AError: string): Boolean;
var
  nodeKind: TNodeKind;
  node: TAudioNode;
  inBuf, outBuf: TAudioBuffer;
  fxIn, fxOut: TAudioPlanar;
  i, n, done: Integer;
  ramp: Single;
begin
  Result := False;
  AError := '';
  if (AChannels < 1) or (Length(APlanar) < AChannels) or (ALen < 1) or (AFrom < 0) or
     (AFrom + ALen > Length(APlanar[0])) then
  begin
    AError := 'nothing to process';
    Exit;
  end;
  try
    if (AKind = '@fadein') or (AKind = '@fadeout') then
    begin
      { a linear ramp across the stretch: 0 -> 1 (in) or 1 -> 0 (out) }
      for i := 0 to AChannels - 1 do
        for n := 0 to ALen - 1 do
        begin
          if ALen > 1 then ramp := n / (ALen - 1) else ramp := 1;
          if AKind = '@fadeout' then ramp := 1 - ramp;
          APlanar[i][AFrom + n] := APlanar[i][AFrom + n] * ramp;
        end;
      Exit(True);
    end;
    if IsSpectralKind(AKind) then
    begin
      EnsurePlanar(fxIn, AChannels, ALen);
      for i := 0 to AChannels - 1 do
        Move(APlanar[i][AFrom], fxIn[i][0], ALen * SizeOf(Single));
      ApplySpectralFx(AKind, AParams, fxIn, AChannels, ALen, ASampleRate, fxOut);
      for i := 0 to AChannels - 1 do
        Move(fxOut[i][0], APlanar[i][AFrom], ALen * SizeOf(Single));
      Exit(True);
    end;
    if (Copy(AKind, 1, 1) = '@') or not NodeKindFromId(AKind, nodeKind) then
    begin
      AError := 'unknown effect "' + AKind + '"';
      Exit;
    end;
    node := CreateNode(1, nodeKind, AKind);
    try
      node.DeserializeParams(AParams);
      node.Configure(ASampleRate, BLOCK, AChannels);
      EnsurePlanar(fxIn, AChannels, ALen);
      EnsurePlanar(fxOut, AChannels, ALen);
      for i := 0 to AChannels - 1 do
        Move(APlanar[i][AFrom], fxIn[i][0], ALen * SizeOf(Single));
      inBuf := TAudioBuffer.Create(AChannels, BLOCK, ASampleRate);
      outBuf := TAudioBuffer.Create(AChannels, BLOCK, ASampleRate);
      try
        done := 0;
        while done < ALen do
        begin
          n := Min(BLOCK, ALen - done);
          inBuf.SetActiveFrames(n);
          outBuf.SetActiveFrames(n);
          for i := 0 to AChannels - 1 do
            Move(fxIn[i][done], inBuf.ChannelPtr(i)^, n * SizeOf(Single));
          node.Process(inBuf, outBuf);
          for i := 0 to AChannels - 1 do
            Move(outBuf.ChannelPtr(i)^, fxOut[i][done], n * SizeOf(Single));
          Inc(done, n);
        end;
      finally
        inBuf.Free;
        outBuf.Free;
      end;
      for i := 0 to AChannels - 1 do
        Move(fxOut[i][0], APlanar[i][AFrom], ALen * SizeOf(Single));
    finally
      node.Free;
    end;
    Result := True;
  except
    on E: Exception do
    begin
      AError := E.Message;
      Result := False;
    end;
  end;
end;

end.
