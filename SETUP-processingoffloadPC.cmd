@echo off
rem Double-click on the processing offload PC. Asks for admin rights. Run again after a reboot if asked.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" -Role offload
