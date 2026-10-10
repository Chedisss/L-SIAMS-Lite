@echo off
REM ===========================================================================
REM  L-SIAMS - bring your data over from the MariaDB (XAMPP MySQL) version
REM
REM  Two ways, depending on whether the old MySQL will still start:
REM
REM    1. MySQL starts:  start it in the XAMPP Control Panel, then double-click
REM                      this file. It reads the old database directly, using
REM                      DB_HOST / DB_NAME / DB_USER / DB_PASS from .env.
REM
REM    2. MySQL will not start:  drag a file onto this one —
REM                      a backup the old L-SIAMS made (database\backups\
REM                      *.sql.gz.lsiams), or a phpMyAdmin / mysqldump export
REM                      (.sql or .sql.gz). No MySQL is needed for this.
REM
REM  Either way the new database is checked table by table against the old
REM  data before it is used, and nothing is changed if anything does not match.
REM
REM  The .env from the old installation MUST be in this folder first. It holds
REM  the keys that unlock the terminals' secrets, the fingerprint templates and
REM  the old backups; with new keys none of those can be read.
REM ===========================================================================

setlocal enabledelayedexpansion
cd /d "%~dp0"

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
echo   ================================================
echo    Import from the MariaDB version of L-SIAMS
echo   ================================================
echo.

REM ------------------------------------------------------------- .env ------
if not exist ".env" (
    echo   [X] There is no .env file in this folder.
    echo.
    echo       Copy the .env file from your OLD L-SIAMS folder into this one
    echo       first ^(for example C:\xampp\htdocs\L-SIAMS\.env^). It holds the
    echo       keys your fingerprints, terminals and backups were encrypted
    echo       with - new keys cannot read them.
    echo.
    pause
    exit /b 1
)

"%PHP%" bin\env-check.php keys >nul 2>&1
if errorlevel 1 (
    echo   [X] The .env in this folder has no encryption keys.
    echo.
    echo       Replace it with the .env from your OLD L-SIAMS folder, which has
    echo       APP_KEY, API_KEY_PEPPER and REALTIME_TICKET_SECRET filled in.
    echo.
    pause
    exit /b 1
)

"%PHP%" bin\env-check.php required >nul 2>&1
if errorlevel 1 (
    echo   [X] PHP is missing an extension it needs:
    "%PHP%" bin\env-check.php required
    echo       Open C:\xampp\php\php.ini, remove the ';' in front of that
    echo       extension's line, save, and run this again.
    echo.
    pause
    exit /b 1
)

REM ----------------------------------------------------------- import ------
if not "%~1"=="" (
    echo   Reading the file: %~nx1
    echo.
    "%PHP%" bin\console db:import-mysql "--from-file=%~f1" %2 %3
) else (
    echo   Reading the old database directly. MySQL must be running in the
    echo   XAMPP Control Panel for this.
    echo.
    "%PHP%" bin\console db:import-mysql %2 %3
)

if errorlevel 1 (
    echo.
    echo   The import did not complete, and nothing was changed.
    echo.
    if "%~1"=="" (
        echo   If MySQL will not start, you do not need it: drag your newest
        echo   backup from the OLD folder's database\backups ^(a .sql.gz.lsiams
        echo   file^) onto import-from-mariadb.bat instead.
        echo.
    )
    echo   If this folder already has a database you want to replace, run:
    echo     import-from-mariadb.bat "path\to\file" --force
    echo   or, reading MySQL directly:
    echo     console.bat db:import-mysql --force
    echo.
    pause
    exit /b 1
)

echo.
echo   [ok] Your data is in. Start L-SIAMS with start.bat and sign in as before.
echo.

REM Only pause when double-clicked or dropped onto, so the result is readable.
echo %CMDCMDLINE% | find /i "/c" >nul && pause

endlocal
exit /b 0
