@echo off
setlocal
title Mailan Zapret

if "%~1"=="" (
    fltmc.exe >nul 2>&1
    if errorlevel 1 (
        echo Mailan Zapret requires Administrator rights.
        echo Confirm the Windows security prompt to continue.
        powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -WorkingDirectory '%~dp0' -Verb RunAs"
        if errorlevel 1 (
            echo.
            echo Failed to request Administrator rights. Press any key to close.
            pause >nul
        )
        exit /b
    )

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\mailan-zapret.ps1" menu
    echo.
    echo Mailan Zapret stopped. Press any key to close this window.
    pause >nul
    exit /b
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\mailan-zapret.ps1" %*
