@echo off
rem Builds dist\ComputingPowerNetwork.exe. Needs Python 3.10+ (python.org) on this PC.
rem You only rebuild when a new dashboard version needs a new Python package - code updates
rem download by themselves (see launcher.py).
cd /d "%~dp0"
python -m pip install --upgrade pygame pyinstaller || goto :error
python -m PyInstaller --noconfirm --onefile --windowed --name ComputingPowerNetwork --hidden-import app launcher.py || goto :error
echo.
echo Built: %~dp0dist\ComputingPowerNetwork.exe
pause
exit /b 0
:error
echo Build failed.
pause
exit /b 1
