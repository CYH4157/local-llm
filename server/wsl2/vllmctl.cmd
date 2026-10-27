@echo off
rem Manage the vLLM service running inside WSL: vllmctl.cmd info | status | logs | restart | models | switch | preset small | new-key | edit
chcp 65001 >nul
set ARGS=%*
if "%ARGS%"=="" (
    echo commands: info  status  logs  start  stop  restart  models  switch  preset small^|medium^|large  new-key  edit  version  upgrade
    set /p ARGS=vllmctl ^>
)
set DISTRO=Ubuntu
if exist "%~dp0wsl-distro.txt" set /p DISTRO=<"%~dp0wsl-distro.txt"
rem Copy the scripts next to this file into WSL first, so pulling a new version is enough (no need to rerun setup-host)
if exist "%~dp0..\vllm\vllmctl.sh" wsl.exe -d %DISTRO% --cd "%~dp0..\vllm" -- bash -c "mkdir -p ~/vllm-opencode-setup && cp *.sh *.py ~/vllm-opencode-setup/ && sed -i 's/\r$//' ~/vllm-opencode-setup/*.sh ~/vllm-opencode-setup/*.py"
wsl.exe -d %DISTRO% --cd ~ -- bash vllm-opencode-setup/vllmctl.sh %ARGS%
pause
