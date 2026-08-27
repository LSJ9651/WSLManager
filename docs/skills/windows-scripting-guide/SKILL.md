---
name: windows-scripting-guide
description: '规范 Windows 脚本（PowerShell 5.1 / Batch / WSL）的编写与审查，覆盖编码、兼容性、路径、WSL 命令安全等核心规则'
---

## Role

你是精通 Windows 脚本开发的专家，熟悉 PowerShell 5.1、Batch 文件和 WSL 命令的所有坑点。你编写和审查脚本时，严格遵守以下规范，不依赖外部 LLM 能力猜测行为。

## Context

此 skill 的规则来源于 [WSLManager](https://github.com/LSJ9651/WSLManager) 项目的实战经验——6 轮审查、26 个 bug 修复，涵盖编码损坏、路径解析错误、命令语义误用、WSL 生命周期管理遗漏等。每个规则背后都有一个真实的故障案例。

## Rules

### 1. 文件编码与换行符

| 文件类型 | 编码 | 换行符 | 原因 |
|:---------|:-----|:-------|:-----|
| `.psm1` / `.ps1` | **UTF-8 with BOM** | **LF** | PS 5.1 无 BOM 时使用系统 ANSI 码页（中文 Windows 为 GBK），多字节字符会被破坏 |
| `.bat` / `.cmd` | **UTF-8 with BOM** | **CRLF** | CMD 解析器需要 CRLF；纯 LF 会破坏命令解析 |

**BOM 验证（提交前必跑）：**
```powershell
$t = @(); $e = @()
[System.Management.Automation.Language.Parser]::ParseFile(".\YourFile.psm1", [ref]$t, [ref]$e)
$e | ForEach-Object { $_.Message }
```
```bash
# 检查前 3 字节 — 应为 EF BB BF（UTF-8 BOM）
xxd -l 3 YourFile.psm1
# 预期输出: 00000000: efbb bf
```

**添加 BOM（Python，最可靠）：**
```bash
python -c "import codecs; data=open('file.psm1','rb').read().decode('utf-8-sig'); codecs.open('file.psm1','w','utf-8-sig').write(data)"
```

### 2. PowerShell 5.1 兼容性

**禁止使用的特性（PS 7+ only）：**
- `??` 空合并运算符（null-coalescing） → 用 `if ($null -eq $x) { ... }`
- `?:` 三元运算符（ternary） → 用 `if/else`
- `ForEach-Object -Parallel`
- `Join-Path -AdditionalChildPath`

**Write-Host 颜色：**
```powershell
# 正确
Write-Host "Success!" -ForegroundColor Green
Write-Host "Error!"  -ForegroundColor Red

# 错误：-f 是格式化操作符，不是颜色参数
Write-Host ("text" -f $ColorRed)        # 替换 {0} 占位符，不设置颜色
Write-Host "`e[31mError`e[0m"           # ANSI 转义序列在 PS 5.1 控制台不可靠
```

**颜色约定**：Cyan=信息/提示，Yellow=警告，Red=错误/危险，Green=成功，Gray=次要信息

**`$LASTEXITCODE` vs `$?`：**
```powershell
# 外部命令（.exe）用 $LASTEXITCODE
wsl --unregister $name
if ($LASTEXITCODE -ne 0) { Write-Host "Failed!" -ForegroundColor Red }

# PowerShell 内置 cmdlet 用 $?
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $path
if ($?) { Write-Host "Deleted!" -ForegroundColor Green }
```

**规则**：`Remove-Item`/`Copy-Item`/`New-Item` 等 cmdlet 后始终加 `-ErrorAction SilentlyContinue`，用 `$?` 检查结果。

### 3. 路径与目录处理

**`$PSScriptRoot` 是脚本所在目录，不要再 `Split-Path -Parent`：**
```powershell
# 正确
$script:RootPath = $PSScriptRoot

# 错误：会往上走一层
$script:RootPath = Split-Path -Parent $PSScriptRoot
```

**目录自动创建：**
```powershell
function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}
```
调用时包裹 try/catch（可能因权限或磁盘空间失败）。

**磁盘空间检查：检查目标所在驱动器，而非系统盘：**
```powershell
$targetDrive = [System.IO.Path]::GetPathRoot($backupDirectory)
$driveInfo = Get-PSDrive -Name $targetDrive.TrimEnd(':\')
if ($driveInfo.Free -lt 5GB) { Write-Host "Low disk space!" -ForegroundColor Yellow }
```

### 4. WSL 命令模式

**实例列表（NUL 字符安全）：**
`wsl -l -q` 输出 UTF-16 LE，PowerShell 5.1 把嵌入的 NUL 字节 (`\0`) 当作行分隔符，产生虚假空条目并破坏实例名。

```powershell
# 正确
$instances = ((wsl -l -q 2>&1 | Out-String) -replace '\0', '') -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }

# 错误：NUL 字节导致空行和损坏的实例名
$instances = wsl -l -q 2>&1 | Where-Object { $_ -match '\S' } | ForEach-Object { $_.Trim() }

# 错误：过于严格的正则拒绝有效名称
$instances = wsl -l -q | Where-Object { $_ -match '^[0-9a-zA-Z_-]+$' }
```
WSL 允许名称包含点、空格、Unicode 字符。

**`wsl --unregister` 前：**
```powershell
wsl -t $instanceName
Start-Sleep -Seconds 1
wsl --unregister $instanceName
if ($LASTEXITCODE -ne 0) {
    Write-Host "Unregister failed! Aborting." -ForegroundColor Red
    return   # 关键：中止，不要继续删除文件
}
```
未注销失败时继续删除文件会产生孤儿实例（orphan instance，WSL 仍认识它，但 VHDX 已删除）。

**`wsl --import` 前：**
```powershell
# 必须检查名称冲突（使用 NUL 安全模式）
$existing = ((wsl -l -q 2>&1 | Out-String) -replace '\0', '') -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
if ($existing -contains $newInstanceName) {
    Write-Host "Instance '$newInstanceName' already exists!" -ForegroundColor Yellow
    return
}
wsl --import $newInstanceName $installPath $tarPath --version $wslVersion
```
此检查必须出现在所有导入路径中：从 Store、从仓库、从 tar、从备份恢复。

**Store 安装流程（Export → Import）：**
```
wsl --install -d <distro>      → 安装到系统默认位置
wsl --export <distro> <tar>    → 捕获为模板
wsl --unregister <distro>      → 移除系统默认实例
wsl --import <name> <dir> <tar>  → 重新导入到托管位置
```
每一步都检查 `$LASTEXITCODE`。导出失败时注销临时实例并中止；导入失败时重试一次。

**名称冲突重试（do-while 循环，非一次性检查）：**
```powershell
do {
    $instanceName = Read-Host "Enter instance name"
    $existing = ((wsl -l -q 2>&1 | Out-String) -replace '\0', '') -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    if ($instanceName -in $existing) {
        Write-Host "Name '$instanceName' already exists, choose another." -ForegroundColor Yellow
        $instanceName = $null
    }
} while ([string]::IsNullOrWhiteSpace($instanceName))
```

**备份操作：**
```powershell
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$backupPath = "$backupDir\$instanceName\full_$timestamp.tar"
wsl --export $instanceName $backupPath
if ($LASTEXITCODE -ne 0) {
    Remove-Item $backupPath -ErrorAction SilentlyContinue
    Write-Host "Backup failed!" -ForegroundColor Red
    return
}
```

**模板匹配（fuzzy match，清理仓库模板）：**
```powershell
$matches = Get-ChildItem -Directory $repoPath | Where-Object {
    $_.Name -like "*$instanceName*" -or $instanceName -like "*$($_.Name)*"
}
```

### 5. Batch 文件规则

```batch
:: 正确：Windows 用 nul，不是 /dev/null
chcp 65001 >nul 2>&1

:: 正确：PowerShell -Command 用分号分隔语句
powershell -NoProfile -Command "Set-Location '%DIR%'; Import-Module .\Module.psm1 -Force; Show-Menu"

:: 错误：逗号创建数组，不分离语句
powershell -NoProfile -Command "Set-Location '%DIR%', Import-Module .\Module.psm1 -Force"
```

**提权模式：**
```batch
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)
```
`exit /b`（非 `exit`）—— 未提权时退出批处理而不关闭父 CMD 窗口。

**路径变量去除尾部反斜杠：**
```batch
set "SCRIPT_DIR=%~dp0"
set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"
powershell -NoProfile -Command "Set-Location '%SCRIPT_DIR%'; Import-Module .\WSLManager.psm1 -Force; Show-Menu"
```
在 PowerShell `-Command` 中使用单引号包裹路径，避免 `\` 被解释为转义字符。

**始终在开头执行 `chcp 65001 >nul 2>&1`。**

### 6. 配置文件模式

**自动创建 + 自愈：**
```powershell
function Get-Config {
    if (Test-Path $configPath) {
        try {
            $config = Get-Content $configPath -Raw | ConvertFrom-Json
            return $config
        } catch {
            Write-Host "Config corrupted, rebuilding..." -ForegroundColor Yellow
        }
    }
    $defaults = @{ Key = "value" }
    $defaults | ConvertTo-Json | Out-File -FilePath $configPath -Encoding UTF8
    return $defaults
}
```
关键：捕获解析错误后，必须实际写入默认配置（不只是内存中使用）。

**路径解析优先级：**
1. 配置文件中的 `WSLRoot`（如已设置且目录可创建）
2. `$PSScriptRoot`（脚本所在目录）

### 7. 清理与安全模式

**破坏性操作七步序列：**
1. 验证目标存在
2. 显示红色警告（非仅黄色）
3. 要求完整名称重新输入（非仅 Y/N）
4. 先执行最可逆的步骤（unregister）
5. 每步检查结果后再继续
6. 某步失败则跳过所有后续步骤
7. 清晰报告最终状态（全部通过 / 部分失败）

**注释块安全：**
避免在 `<# ... #>`（PowerShell 注释块 / comment block）中使用非 ASCII 字符。如果必须使用，确保存在 UTF-8 BOM。`#>` 被破坏为 `?>` 是静默且灾难性的——其后所有内容变为注释。

### 8. WSL 专项

- 所有 `wsl.exe` 调用必须检查退出码
- `wsl -t` 后必须 `Start-Sleep -Seconds 1` 再执行下一条 WSL 命令
- 尊重用户的 `DefaultWSLVersion` 配置，传给所有 `wsl --import`
- **模板**（`.tar`）用于存储和传输；**实例**（`.vhdx`）用于运行。不要直接从模板运行。

## Quick Reference: 常见错误速查表

| 症状 | 根因 | 修复 |
|:-----|:-----|:-----|
| 中文字符显示乱码 | `.psm1` 缺少 UTF-8 BOM | 用 Python 添加 BOM |
| `#>` 注释终止符被破坏为 `?>` | 多字节字符因缺少 BOM 被破坏 | 添加 BOM，用 parser 检查 |
| 脚本运行但一半代码"消失" | 注释块未闭合（`#>` 被破坏） | 运行大括号计数：`{` vs `}` |
| `Write-Host` 显示 `{0}` 占位符 | 使用了 `-f` 操作符而非 `-ForegroundColor` | 改为 `-ForegroundColor` |
| `$LASTEXITCODE` 值错误/过期 | 在 PowerShell cmdlet 后使用了 `$LASTEXITCODE` | cmdlet 用 `$?`，仅 `.exe` 用 `$LASTEXITCODE` |
| `Remove-Item` 崩溃脚本 | 缺少 `-ErrorAction SilentlyContinue` | 添加该参数，用 `$?` 检查 |
| 模块创建目录到错误位置 | `Split-Path -Parent $PSScriptRoot` 向上走了一层 | 直接使用 `$PSScriptRoot` |
| `.bat` 无法启动 PowerShell | 在 `-Command` 中使用了逗号而非分号 | 用 `;` 作为语句分隔符 |
| `.bat` 路径转义出错 | 尾部 `\` 在双引号前产生 `\"` 转义 | 用 `%VAR:~0,-1%` 去除或改用单引号 |
| 实例不在列表中 | 过于严格的正则拒绝了有效名称 | 使用 NUL 安全的 `Out-String` + `-split` 模式 |
| 实例列表含空行/路径非法字符 | `wsl -l -q` 的 UTF-16 LE NUL 字节被当作行分隔符 | 改用 `((wsl -l -q 2>&1 \| Out-String) -replace '\0', '') -split '\r?\n'` |
| 删除后出现孤儿 WSL 实例 | unregister 失败后继续删除文件 | 检查 `$LASTEXITCODE`，失败时中止 |
| 备份填满错误驱动器 | 检查了 `$env:SystemDrive` 而非备份目录所在盘 | 用 `[IO.Path]::GetPathRoot($backupDir)` |
| 实例名冲突 | `wsl --import` 前未检查 | 始终检查 `wsl -l -q` |

## When to Skip

- 脚本仅运行在 PS 7+ 环境且无 WSL 交互 → 可跳过 WSL 相关规则
- 纯批处理脚本无任何 PowerShell 调用 → 可跳过 PS 5.1 兼容性规则
