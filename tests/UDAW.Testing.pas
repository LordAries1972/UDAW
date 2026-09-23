unit UDAW.Testing;
{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}

{ Tiny dependency-free test harness shared by the Delphi and FPC test runners.
  (The plan forbids third-party frameworks; DUnitX / FPCUnit would also work but
  a 120-line runner keeps the two toolchains identical.) }

interface

uses
  SysUtils;

type
  TTestProc = procedure;

  ETestFailure = class(Exception)
  end;

procedure RegisterTest(const AGroup, AName: string; AProc: TTestProc);

procedure Check(ACondition: Boolean; const AMessage: string);
procedure CheckFalse(ACondition: Boolean; const AMessage: string);
procedure CheckEqualStr(const AExpected, AActual: string; const AMessage: string = '');
procedure CheckEqualInt(AExpected, AActual: Int64; const AMessage: string = '');
procedure CheckEqualBool(AExpected, AActual: Boolean; const AMessage: string = '');
procedure CheckNear(AExpected, AActual, ATolerance: Double; const AMessage: string = '');
procedure Fail(const AMessage: string);

{ Runs every registered test; prints a report; returns 0 if all passed. }
function RunRegisteredTests: Integer;

implementation

type
  TTestItem = record
    Group: string;
    Name: string;
    Proc: TTestProc;
  end;

var
  GTests: array of TTestItem;

procedure RegisterTest(const AGroup, AName: string; AProc: TTestProc);
var
  n: Integer;
begin
  n := Length(GTests);
  SetLength(GTests, n + 1);
  GTests[n].Group := AGroup;
  GTests[n].Name := AName;
  GTests[n].Proc := AProc;
end;

procedure Fail(const AMessage: string);
begin
  raise ETestFailure.Create(AMessage);
end;

procedure Check(ACondition: Boolean; const AMessage: string);
begin
  if not ACondition then
    Fail('expected TRUE: ' + AMessage);
end;

procedure CheckFalse(ACondition: Boolean; const AMessage: string);
begin
  if ACondition then
    Fail('expected FALSE: ' + AMessage);
end;

procedure CheckEqualStr(const AExpected, AActual: string; const AMessage: string);
begin
  if AExpected <> AActual then
    Fail(Format('expected "%s" but got "%s". %s', [AExpected, AActual, AMessage]));
end;

procedure CheckEqualInt(AExpected, AActual: Int64; const AMessage: string);
begin
  if AExpected <> AActual then
    Fail(Format('expected %d but got %d. %s', [AExpected, AActual, AMessage]));
end;

procedure CheckEqualBool(AExpected, AActual: Boolean; const AMessage: string);
begin
  if AExpected <> AActual then
    Fail(Format('expected %s but got %s. %s',
      [BoolToStr(AExpected, True), BoolToStr(AActual, True), AMessage]));
end;

procedure CheckNear(AExpected, AActual, ATolerance: Double; const AMessage: string);
begin
  if Abs(AExpected - AActual) > ATolerance then
    Fail(Format('expected %.6f +/- %.6f but got %.6f. %s',
      [AExpected, ATolerance, AActual, AMessage]));
end;

function RunRegisteredTests: Integer;
var
  i, passed, failed: Integer;
  lastGroup: string;
begin
  passed := 0;
  failed := 0;
  lastGroup := #0;
  Writeln('UDAW test run - ', Length(GTests), ' tests');
  Writeln('----------------------------------------');
  for i := 0 to High(GTests) do
  begin
    if GTests[i].Group <> lastGroup then
    begin
      Writeln;
      Writeln('[', GTests[i].Group, ']');
      lastGroup := GTests[i].Group;
    end;
    Write('  .... ', GTests[i].Name);
    Flush(Output);
    try
      GTests[i].Proc();
      Inc(passed);
      Writeln(#13'  PASS  ', GTests[i].Name);
    except
      on E: Exception do
      begin
        Inc(failed);
        Writeln(#13'  FAIL  ', GTests[i].Name, '  --  ', E.ClassName, ': ', E.Message);
      end;
    end;
    Flush(Output);
  end;
  Writeln;
  Writeln('----------------------------------------');
  Writeln(Format('%d passed, %d failed, %d total', [passed, failed, passed + failed]));
  if failed = 0 then
    Result := 0
  else
    Result := 1;
end;

end.
