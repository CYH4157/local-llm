@echo off
rem Double-click to add the NCHC GenAI API (https://inner-medusa.genai.nchc.org.tw) to opencode.
rem Asks for your own NCHC API key; only models that passed a tool-calling test are added.
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-client.ps1" -Url https://inner-medusa.genai.nchc.org.tw/v1 -Name nchc -Label "NCHC GenAI" -Context 32768 -Models "gpt-oss-120b,gpt-oss-20b,GLM-5.2,GLM-5.3-max,gemma-4-31B-it-with-tool,gemma-4-26B-A4B-it,Llama-3.3-70B-Instruct,NVIDIA-Nemotron-3-Super-120B-A12B,Mistral-Large-3-675B-Instruct-2512,Thanos3.5-397B-A17B" %*
pause
