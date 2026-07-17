@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~dp0mailan-zapret.cmd' -WorkingDirectory '%~dp0' -Verb RunAs"
