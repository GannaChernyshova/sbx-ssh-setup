@echo off
rem sbx-doctor — shim so `sbx-doctor ...` works from cmd.exe and PowerShell.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0sbx-doctor.ps1" %*
