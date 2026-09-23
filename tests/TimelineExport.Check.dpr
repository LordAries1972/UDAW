program TimelineExportCheck;
{$APPTYPE CONSOLE}
uses UDAW.Testing, Tests.TimelineExport;
begin RegisterTimelineExportTests; ExitCode := RunRegisteredTests; end.
