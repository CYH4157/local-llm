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
rem Write to a temp folder then mv: replaces the files instead of overwriting them, so a setup-vllm.sh still running is not affected
if exist "%~dp0..\vllm\vllmctl.sh" wsl.exe -d %DISTRO% --cd "%~dp0..\vllm" -e bash -c "mkdir -p ~/vllm-opencode-setup && t=$(mktemp -d ~/.vllm-sync.XXXXXX) && cp *.sh *.py $t/ && sed -i 's/\r$//' $t/* && mv -f $t/* ~/vllm-opencode-setup/ && rmdir $t"
wsl.exe -d %DISTRO% --cd ~ -- bash vllm-opencode-setup/vllmctl.sh %ARGS%
pause
