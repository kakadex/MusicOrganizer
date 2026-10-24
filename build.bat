@echo off
REM ============================================================
REM  Music Organizer (Android) - Windows launcher
REM  All build logic lives in build.sh (single source of truth);
REM  this file only locates a bash and forwards arguments.
REM    build.bat           -> release: build + align + sign + archive
REM    build.bat debug     -> debug apk
REM    build.bat install   -> release then adb install -r
REM ============================================================
setlocal EnableDelayedExpansion
set "PKG=%~dp0"

set "BASH="
for /f "delims=" %%b in ('where bash 2^>nul') do (
    if not defined BASH set "BASH=%%b"
)
if not defined BASH if exist "C:\Program Files\Git\bin\bash.exe" set "BASH=C:\Program Files\Git\bin\bash.exe"
if not defined BASH if exist "C:\Program Files (x86)\Git\bin\bash.exe" set "BASH=C:\Program Files (x86)\Git\bin\bash.exe"
if not defined BASH if exist "%LOCALAPPDATA%\Programs\Git\bin\bash.exe" set "BASH=%LOCALAPPDATA%\Programs\Git\bin\bash.exe"
if not defined BASH for /d %%d in ("%USERPROFILE%\.workbuddy\binaries\PortableGit\versions\*") do (
    if exist "%%d\bin\bash.exe" set "BASH=%%d\bin\bash.exe"
)

if not defined BASH (
    echo [ERROR] Git Bash not found.
    echo         Install Git for Windows, then run: build.bat
    pause
    exit /b 1
)

echo Using bash: %BASH%
pushd "%PKG%"
"%BASH%" build.sh %*
set "RC=%ERRORLEVEL%"
popd

if not "%RC%"=="0" echo [ERROR] Build failed, exit code %RC%.
pause
exit /b %RC%
