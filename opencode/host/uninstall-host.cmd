@echo off
rem Double-click: uninstall vLLM / opencode from this laptop and restore the settings setup-host changed (asks for administrator rights).
chcp 65001 >nul
net session >nul 2>&1
if %errorlevel% neq 0 (
    if "%~1"=="" (
        powershell -NoProfile -Command "Start-Process -Verb RunAs -FilePath '%~f0'"
    ) else (
        powershell -NoProfile -Command "Start-Process -Verb RunAs -FilePath '%~f0' -ArgumentList '%*'"
    )
    exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall-host.ps1" %*
pause
