@echo off
:: WSLManager.bat - WSL 发行版管理工具启动器
:: 自动请求管理员权限后启动 PowerShell 模块

:: 禁止命令回显，保持界面整洁
@echo off
chcp 65001 >nul 2>&1

:: ---------- 自动提权检查 ----------
:: 使用 net session 命令检测当前是否以管理员身份运行
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo 正在请求管理员权限...
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

:: ---------- 确定脚本所在目录 ----------
:: %~dp0 获取脚本完整路径（含末尾反斜杠），确保可移植
set "SCRIPT_DIR=%~dp0"

:: ---------- 启动 PowerShell 模块 ----------
:: -NoProfile: 不加载用户配置文件，启动更快更干净
:: -ExecutionPolicy Bypass: 绕过执行策略限制
:: -Command: 直接执行导入和调用菜单
powershell -NoProfile -ExecutionPolicy Bypass -Command "Set-Location '%SCRIPT_DIR%'; Import-Module .\WSLManager.psm1 -Force; Show-Menu"

:: 暂停等待用户按键，避免窗口立即关闭
pause
