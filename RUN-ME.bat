@echo off
rem server-diag: read-only health check of Windows. Changes nothing.
rem Asks for administrator rights (UAC) for the full check; if you say No, a reduced check runs.
cd /d "%~dp0"
if not exist "%~dp0server-diag.ps1" goto nofile
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0server-diag.ps1" -Lang auto -Pause
if errorlevel 1 pause
exit /b
:nofile
echo.
echo   server-diag.ps1 was not found next to this .bat file.
echo   Unzip the archive first: right-click the ZIP file - "Extract All...",
echo   then run RUN-ME.bat from the extracted folder.
echo.
pause
