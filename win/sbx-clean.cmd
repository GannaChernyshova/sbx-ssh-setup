@echo off
rem sbx-clean — shim so `sbx-clean ...` works from cmd.exe and PowerShell.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0sbx-clean.ps1" %*
