@echo off
rem Installs EVERYTHING (use other PCs + share this PC). Which role is active is switched in the app.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" -Role both
