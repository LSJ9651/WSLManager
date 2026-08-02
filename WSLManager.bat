@echo off
:: WSLManager.bat - WSL 发行版管理工具启动器

chcp 65001 >nul 2>&1

:: ---------- 自动提权检查 ----------
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo 正在请求管理员权限...
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

:: ---------- 确定脚本所在目录 ----------
set "SCRIPT_DIR=%~dp0"

:: ---------- 启动 PowerShell 模块 ----------
:: 改用单引号包裹路径，避免反斜杠与双引号冲突
powershell -NoProfile -ExecutionPolicy Bypass -Command "Set-Location '%SCRIPT_DIR%'; Import-Module .\WSLManager.psm1 -Force; Show-Menu"

pause