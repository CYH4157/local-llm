@echo off
rem Manage the vLLM service running inside WSL: vllmctl.cmd info | status | logs | restart | models | switch | preset small | new-key | edit
chcp 65001 >nul
set ARGS=%*
if "%ARGS%"=="" (
    echo commands: info  status  logs  start  stop  restart  models  switch  preset small^|medium^|large  new-key  edit
    set /p ARGS=vllmctl ^>
)
set DISTRO=Ubuntu
if exist "%~dp0wsl-distro.txt" set /p DISTRO=<"%~dp0wsl-distro.txt"
wsl.exe -d %DISTRO% --cd ~ -- bash vllm-opencode-setup/vllmctl.sh %ARGS%
pause
