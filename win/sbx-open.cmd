@echo off
rem sbx-open — shim so `sbx-open ...` works from cmd.exe and PowerShell.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0sbx-open.ps1" %*
