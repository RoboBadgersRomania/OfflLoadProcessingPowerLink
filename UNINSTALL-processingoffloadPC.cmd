@echo off
rem Removes the nuclear powerplant setup from this PC and restores its original settings.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1" -Role offload
