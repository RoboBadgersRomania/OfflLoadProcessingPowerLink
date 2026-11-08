@echo off
rem Removes the Computing Power Network client (shortcuts, VS Code extension, Claude skill) from this PC.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1" -Role me
