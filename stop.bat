@echo off
REM ===========================================================================
REM  L-SIAMS — stop everything start.bat opened
REM
REM  Closes the web, worker and realtime windows. The database is a file in
REM  this folder, so there is nothing else to stop; once these are closed it is
REM  safe to copy or back up storage\database.
REM ===========================================================================

title L-SIAMS - stopping
echo.
echo   Stopping L-SIAMS...
echo.

REM Match on window title rather than image name, so this cannot kill an
REM unrelated PHP process you happen to be running.
for %%W in ("L-SIAMS web" "L-SIAMS worker" "L-SIAMS realtime") do (
    taskkill /fi "WINDOWTITLE eq %%~W*" /t /f >nul 2>&1
    if errorlevel 1 (
        echo   [--] %%~W was not running
    ) else (
        echo   [ok] %%~W stopped
    )
)

echo.
echo   Done. Nothing else needs stopping - the database is a file,
echo   storage\database\lsiams.sqlite, and nothing has it open now.
echo.
timeout /t 3 /nobreak >nul
