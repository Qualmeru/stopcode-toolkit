@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0collect-crash.ps1"
python "%~dp0analyze-dump.py"
pause
