@echo off
rem server-diag: read-only health check of Windows. Changes nothing.
rem Asks for administrator rights (UAC) for the full check; if you say No, a reduced check runs.
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0server-diag.ps1" -Lang auto -Pause
if errorlevel 1 pause
