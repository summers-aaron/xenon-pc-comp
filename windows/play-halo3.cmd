@echo off
rem Runs play-halo3.ps1 (see it for options) without changing the PowerShell execution policy.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0play-halo3.ps1" %*
