@echo off
rem Builds dist\ComputingPowerNetwork-Setup-<version>.exe
rem  1. compiles the dashboard (dashboard\build.bat -> dashboard\dist\ComputingPowerNetwork.exe)
rem  2. packs everything with Inno Setup 6 (free: https://jrsoftware.org/isinfo.php,
rem     or:  winget install JRSoftware.InnoSetup)
cd /d "%~dp0"
call ..\dashboard\build.bat nopause || goto :error
set ISCC=
for %%P in ("%ProgramFiles(x86)%\Inno Setup 6\ISCC.exe" "%ProgramFiles%\Inno Setup 6\ISCC.exe" "%LocalAppData%\Programs\Inno Setup 6\ISCC.exe") do if exist %%P set ISCC=%%P
if not defined ISCC (
  echo Inno Setup 6 not found. Install it:  winget install JRSoftware.InnoSetup   then run this again.
  goto :error
)
%ISCC% ComputingPowerNetwork.iss || goto :error
echo.
echo Installer built in %~dp0..\dist
pause
exit /b 0
:error
echo Installer build failed.
pause
exit /b 1
