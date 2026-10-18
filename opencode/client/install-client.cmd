@echo off
rem Double-click to install opencode on Windows and connect it to the lab laptop's vLLM.
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-client.ps1" %*
pause
