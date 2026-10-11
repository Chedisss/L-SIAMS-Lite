@echo off
REM ===========================================================================
REM  L-SIAMS - let phones, tablets and laptops on the school network open it
REM
REM  Double-click once on the PC that runs L-SIAMS, and click Yes when Windows
REM  asks for administrator rights. It sets the network to Private, opens the
REM  ports L-SIAMS uses (8080 pages, 8443 live updates) on private networks
REM  only, removes any rule Windows made to block PHP, and prints the address
REM  to type on the other devices. Safe to run again at any time.
REM
REM  What it does, step by step, is in bin\allow-network.ps1 and
REM  docs\NETWORK-ACCESS.md.
REM ===========================================================================

setlocal
cd /d "%~dp0"

set "PHP="
for %%D in (C D E) do (
    if not defined PHP if exist "%%D:\xampp\php\php.exe" set "PHP=%%D:\xampp\php\php.exe"
)
if not defined PHP for %%I in (php.exe) do if not "%%~$PATH:I"=="" set "PHP=%%~$PATH:I"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0bin\allow-network.ps1" -Php "%PHP%"
set "RESULT=%errorlevel%"

echo.
if "%RESULT%"=="0" (
    echo   Done. Start L-SIAMS with start.bat if it is not running, then open
    echo   the address above on the other device.
) else (
    echo   Something above is marked [X]. Fix that, then run this again.
    echo   docs\NETWORK-ACCESS.md has every step by hand.
)
echo.
pause
endlocal
exit /b %RESULT%
