@echo off
REM ===========================================================================
REM  L-SIAMS - load a database file
REM
REM  Drag a file onto this icon, or double-click it and type the path when
REM  asked. It works out what the file is:
REM
REM    - a phpMyAdmin export, a mysqldump, or a backup from the MariaDB version
REM      of L-SIAMS: imported with import-from-mariadb.bat's checks;
REM    - a SQLite .sql dump (what console.bat backup:decrypt writes): replaces
REM      the database, as one transaction.
REM
REM  Either way, a failure changes nothing.
REM ===========================================================================

setlocal enabledelayedexpansion
cd /d "%~dp0"

set "SQLFILE=%~1"

if not defined SQLFILE (
    echo.
    echo   L-SIAMS database import
    echo   -----------------------
    echo.
    echo   Drag the .sql file into this window and press Enter,
    echo   or type its full path.
    echo.
    set /p "SQLFILE=  File: "
)

REM Dragging a file into the window wraps the path in quotes. The quotes must
REM come off before the path is quoted again below, and the stripping itself
REM cannot be written inside quotes - cmd would take the first one as the end
REM of the assignment.
set SQLFILE=!SQLFILE:"=!

if not defined SQLFILE (
    echo   [X] No file given.
    pause
    exit /b 1
)

if not exist "!SQLFILE!" (
    echo   [X] No such file: !SQLFILE!
    pause
    exit /b 1
)

set "PHP="
for %%D in (C D E) do (
    if not defined PHP if exist "%%D:\xampp\php\php.exe" set "PHP=%%D:\xampp\php\php.exe"
)
if not defined PHP for %%I in (php.exe) do if not "%%~$PATH:I"=="" set "PHP=%%~$PATH:I"

if not defined PHP (
    echo   [X] Could not find php.exe. Install XAMPP, or add PHP to your PATH.
    pause
    exit /b 1
)

echo.
echo   Importing !SQLFILE!
echo.

REM db:import opens backups and .gz files itself and recognises a file from
REM the MariaDB version by its contents, handing it to the MariaDB importer.
REM --force is deliberately not passed: dropping a file onto an icon should
REM never replace a database that holds data by surprise.
"%PHP%" bin\console db:import "!SQLFILE!"

if errorlevel 1 (
    echo.
    echo   The import stopped and nothing was changed. The reason is above.
    echo   To replace a database that already holds data, run:
    echo     console.bat db:import "!SQLFILE!" --force
    pause
    exit /b 1
)

echo.
echo   Done. If migrations were listed as missing, run:  console.bat migrate
echo.
pause

endlocal
