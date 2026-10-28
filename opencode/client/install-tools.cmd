@echo off
rem Double-click to install opencode, the lab rules, labdoc and the /slides-style commands without connecting to vLLM.
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-client.ps1" -ToolsOnly %*
pause
