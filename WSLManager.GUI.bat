@echo off
:: WSLManager GUI 启动器
:: 以普通权限启动图形界面（写操作时会按需弹出 UAC，而非整体提权）

chcp 65001 >nul 2>&1

:: ---------- 确定脚本所在目录 ----------
set "SCRIPT_DIR=%~dp0"
set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"

:: ---------- 启动 WPF 图形界面 ----------
powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "Set-Location '%SCRIPT_DIR%'; & '.\scripts\WSLManager.GUI.ps1'"
