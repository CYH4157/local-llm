@echo off
rem Expose the vLLM API (/v1 only) to the internet with Tailscale Funnel: funnel.cmd on | off | status | test
chcp 65001 >nul
set ARGS=%*
if "%ARGS%"=="" (
    echo commands: on  off  status  test
    set /p ARGS=funnel ^>
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0funnel.ps1" %ARGS%
pause
