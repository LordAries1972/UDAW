unit UDAW.Compat;
{$I udaw.inc}
{ FPC 3.2 has no TProc<T> / TFunc<T> (System.SysUtils) and no anonymous
  methods. Under Delphi these come from SysUtils, so this unit is empty
  there. Under FPC they are method-pointer types: callers pass a method
  of an object, not an inline closure. }
interface

{$IFDEF FPC}
type
  TProc<T> = procedure(Arg: T) of object;
  TFunc<TResult> = function: TResult of object;
{$ENDIF}

implementation

end.
