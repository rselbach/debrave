@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "PS_SCRIPT=%SCRIPT_DIR%debrave.ps1"

if not exist "%PS_SCRIPT%" (
    echo Could not find debrave.ps1 next to this batch file.
    echo Expected: "%PS_SCRIPT%"
    echo.
    pause
    exit /b 1
)

echo debrave for Windows
echo.
echo This will ask Brave to close, then disable Brave crypto and monetization features.
echo Backups will be written to your Brave User Data\debrave-backups folder.
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" -Quit
set "EXIT_CODE=%ERRORLEVEL%"

echo.
if not "%EXIT_CODE%"=="0" (
    echo debrave exited with code %EXIT_CODE%.
    echo Review the message above for details.
) else (
    echo Finished.
)
echo.
pause
exit /b %EXIT_CODE%
