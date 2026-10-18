@echo off
rem Double-click to remove opencode and the lab vLLM settings that install-client added.
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall-client.ps1" %*
pause
