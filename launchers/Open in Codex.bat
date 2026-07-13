@echo off
rem Open in Codex.bat — double-click launcher for Windows.
rem
rem For the least-technical users: either DRAG a project folder onto this file,
rem or double-click it and paste the folder path when asked.
rem Wraps `sbx-open codex <folder>`.

setlocal
cls
echo === Open a project in Codex (safely sandboxed) ===
echo.

if not "%~1"=="" (
    set "folder=%~1"
) else (
    set /p "folder=Paste your project folder path, then press Enter: "
)

rem Strip any surrounding quotes.
set "folder=%folder:"=%"

if "%folder%"=="" (
    echo No folder given. Close this window and try again.
    pause >nul
    exit /b 1
)

where sbx-open >nul 2>&1
if %errorlevel%==0 (
    call sbx-open codex "%folder%"
) else (
    call "%~dp0..\win\sbx-open.cmd" codex "%folder%"
)

echo.
echo Done. Press any key to close.
pause >nul
