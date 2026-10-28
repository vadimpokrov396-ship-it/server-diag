@echo off
rem server-diag: read-only health check of Windows. Changes nothing.
rem Asks for administrator rights (UAC) for the full check; if you say No, a reduced check runs.
cd /d "%~dp0"
if not exist "%~dp0server-diag.ps1" goto nofile
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0server-diag.ps1" -Lang ru -Pause
if errorlevel 1 pause
exit /b
:nofile
chcp 65001 >nul
echo.
echo   Не найден файл server-diag.ps1 рядом с этим .bat.
echo   Сначала распакуйте архив: правой кнопкой по ZIP-файлу - "Извлечь всё...",
echo   затем запустите ЗАПУСТИ-МЕНЯ.bat из распакованной папки.
echo.
pause
