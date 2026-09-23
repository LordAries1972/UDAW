{ udaw.inc - shared compiler switches for every UDAW unit.
  Included as the first line after the unit header. }

{$IFDEF FPC}
  {$MODE DELPHI}
  {$MODESWITCH ADVANCEDRECORDS}
  {$MODESWITCH TYPEHELPERS}
  {$H+}
  {$INLINE ON}
  {$B-}
{$ELSE}
  {$SCOPEDENUMS OFF}
{$ENDIF}

{ Long strings, overflow/range checking left to the project options.
  We intentionally use UNSCOPED RTL unit names (SysUtils, Classes, ...)
  so a single uses clause compiles under both Delphi 12 and FPC/Lazarus. }

{$IFDEF MSWINDOWS}
  {$DEFINE UDAW_WINDOWS}
{$ENDIF}
{$IFDEF DARWIN}
  {$DEFINE UDAW_MACOS}
{$ENDIF}
{$IF DEFINED(LINUX) OR DEFINED(FREEBSD) OR DEFINED(OPENBSD) OR DEFINED(NETBSD)}
  {$DEFINE UDAW_POSIX}
{$IFEND}
