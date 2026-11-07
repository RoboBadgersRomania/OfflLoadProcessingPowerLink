@echo off
rem Removes the ROS 2 offload client setup (shortcuts, VS Code extension) from this PC.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1" -Role me
