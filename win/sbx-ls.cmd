@echo off
rem sbx-ls — shim so `sbx-ls ...` works from cmd.exe and PowerShell.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0sbx-ls.ps1" %*
