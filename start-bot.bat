@echo off
chcp 65001 >nul
title Local LLM Discord Bot
echo 啟動 Discord bot 中... 關閉此視窗即可停止 bot。
powershell -ExecutionPolicy Bypass -File "%~dp0run-bot.ps1"
echo.
echo bot 已停止。按任意鍵關閉視窗。
pause >nul
