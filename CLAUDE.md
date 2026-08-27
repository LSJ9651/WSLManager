# CLAUDE.md

本文件为 Claude Code（claude.ai/code）在此仓库中编写代码时提供指导。

## 项目概述

WSLManager 是一个便携式、自包含的 WSL（Windows Subsystem for Linux）发行版管理器。两个前端共享同一个核心引擎：

- **TUI** — `WSLManager.bat` → 交互式 CLI 菜单（启动时对整个进程提权）
- **GUI** — `WSLManager.GUI.bat` → WPF 图形界面（以普通用户身份运行，仅写操作时提权）

所有 WSL 数据（模板、实例、备份）都存放在工具目录中，位于工具所在盘符上（或 `Config/config.json` 的 `WSLRoot`）。

## 架构

```
WSLManager.bat              → TUI 启动器：提权 + Import-Module scripts\WSLManager.psm1; Show-Menu
WSLManager.GUI.bat          → GUI 启动器：-WindowStyle Hidden + 运行 scripts\WSLManager.GUI.ps1
config.example.json         → 随附的参考配置（Config/config.json 的模板）
scripts/
  WSLManager.Engine.psm1    → 共享业务逻辑（参数化，供 GUI 使用）
  WSLManager.psm1           → TUI 菜单（旧版：自包含，仅导出 Show-Menu）
  WSLManager.GUI.ps1        → WPF GUI；导入 WSLManager.Engine.psm1
Data/Config/config.json     → 用户配置（gitignored，首次运行时自动创建）
Data/Repositories/ Data/Instances/ Data/Backups/   → 运行时数据（gitignored，首次运行时重新创建）
```

**引擎是权威。** `WSLManager.GUI.ps1` 是 `WSLManager.Engine.psm1` 之上的薄 UI 层。引擎函数是参数化的（返回 `New-EngineResult` 对象，接收 `LogCallback` 脚本块和可选的 `CancelFile`），这是 GUI 所依赖的契约。TUI `WSLManager.psm1` 不使用引擎——它带有自己的业务逻辑内联副本，实际上已冻结。

**切勿在同一会话中同时导入 `WSLManager.psm1` 和 `WSLManager.Engine.psm1`** —— 它们定义了相同的函数名（`Get-WSLConfig`、`Get-WSLRoot`、`Ensure-Directory`、`New-WSLInstanceFrom*`、`Backup/Restore/Remove-WSLInstance`），但函数体不同；第二次导入会覆盖第一次。

**引擎结果契约：** 每个引擎操作返回 `[PSCustomObject]@{ Success; Message; Data }`。`Write-EngineLog` 向 `LogCallback` 发送 `@{ Message; Level }` 哈希表；GUI 从 `ConcurrentQueue` 中排出它们。`Invoke-ElevatedScript` 返回 `@{ Success; ExitCode; Output; Elevated; TimedOut; Cancelled }`。GUI 的 `Handle-BgResult` 读取 `Success`/`Message`/`Cancelled`。

## 命令

```bash
# 加载 TUI 模块并显示菜单
powershell -NoProfile -ExecutionPolicy Bypass -Command "Set-Location '<repo>'; Import-Module .\scripts\WSLManager.psm1 -Force; Show-Menu"

# 语法检查脚本
powershell -NoProfile -Command '$t=@();$e=@();$null=[System.Management.Automation.Language.Parser]::ParseFile("<repo>\scripts\WSLManager.Engine.psm1",[ref]$t,[ref]$e);$e|%{$_.Message}'

# BOM 检查（.psm1/.ps1 前 3 字节必须为 EF BB BF；.bat 用 CRLF）
xxd -l 3 scripts/WSLManager.psm1
```

GUI 是交互式的（WPF），无法有意义地进行无头脚本化——通过启动 `WSLManager.GUI.bat` 并演练一个流程来验证它。

## 文件编码（关键 — 已验证当前状态）

| 文件 | 编码 | 换行符 | 状态 |
|---|---|---|---|
| `scripts/*.ps1` / `*.psm1` | 带 BOM 的 UTF-8 | **LF** | ✅ 正确 |
| `WSLManager.bat` | 不带 BOM 的 UTF-8 | **CRLF** | ✅ 正确 |
| `WSLManager.GUI.bat` | 不带 BOM 的 UTF-8 | **CRLF** | ✅ 正确 |
| `README.md` / `*.md` | 不带 BOM 的 UTF-8 | LF | ✅ 正确 |

PowerShell 5.1 在没有 UTF-8 BOM 时无法正确解析 `.psm1`/`.ps1`——它会按 ANSI 代码页解码（在 zh-CN Windows 上是 GBK），从而损坏中文并使语法出错（`#>` 变成 `?>`）。有疑问时用 BOM 重新编码 *.psm1/*.ps1（最可靠）：

`.bat`/`.cmd` 则相反：**绝不能带 UTF-8 BOM。** 开头的 BOM 会在 `chcp` 运行之前被 cmd 在控制台的默认代码页下读取——在 zh-CN 上是 GBK，所以 `@echo off` 会变成乱码命令（`'﻿@echo' 不是内部或外部命令`）并且 echo 保持开启。保持 `.bat` 为不带 BOM 的 UTF-8 + CRLF，在任何非 ASCII 输出前运行 `chcp 65001 >nul`，并保持 `chcp` 之前的每行仅含 ASCII（`::` 注释可含中文——它会被跳过，不执行）。

```bash
python -c "import codecs; d=open('f.psm1','rb').read().decode('utf-8-sig'); codecs.open('f.psm1','w','utf-8-sig').write(d)"
```

## 关键模式与陷阱

### 路径解析（已更改 — 旧版本规则现已反转）
- `$script:RootPath = Split-Path -Parent $PSScriptRoot` 同时用于引擎和 TUI。脚本现在位于 `scripts\`，所以 `$PSScriptRoot` 是 `scripts` 目录，而 `Split-Path -Parent` 正确地得到工具根目录。旧的“不要用 `Split-Path -Parent`”指引已过时。
- `Get-WSLRoot`：config 的 `WSLRoot` 优先（包裹在 try/catch 中，失败时回退到 `Data` 目录）。默认数据根为 `$script:DefaultDataRoot = <RootPath>\Data`，脚本与 GUI/TUI 均据此创建数据目录。
- `$script:ConfigPath` 固定为 `<RootPath>\Data\Config\config.json`，不随 `WSLRoot` 迁移（`WSLRoot` 只迁移 Repositories/Instances/Backups 三大体积数据）。
- 运行时数据（Config/Repositories/Instances/Backups）统一存放于 `<工具根>\Data\`；`Invoke-DataMigration` 在首次运行且检测到旧布局（数据散落在工具根）时自动把它们迁入 `Data\`。
- `.bat` 去掉尾部反斜杠：在带单引号传给 PowerShell 之前执行 `set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"`。

### WSL 输出解码（健壮、引擎级）
引擎不使用终端 `& wsl.exe`。`Get-WslRawOutput` 通过 `ProcessStartInfo` 启动 `wsl.exe`，重定向流，读取原始字节，然后 `Detect-OutputEncoding` 判断是 UTF-16LE 还是 UTF-8（先看 BOM，再用“奇数位多为 0x00”的启发式）并正确解码。这就是 GUI 的 `wsl -l -v` / `-o` / `-q` 输出不乱码的原因。TUI 仍使用旧的 `((wsl -l -q ...) -replace '\0','') -split ...` 去 NUL 模式——两者都有效，但新代码优先用 `Get-WslRawOutput`。

### PowerShell 5.1 兼容性
- 颜色不用 `-f`——直接用 `-ForegroundColor Cyan`。
- `$LASTEXITCODE` 只用于外部 `.exe`（`wsl.exe`）。对于 cmdlet（`Remove-Item`、`Copy-Item`）用 `$?` 并加上 `-ErrorAction SilentlyContinue`。
- 文件大小格式化（引擎中的 `Format-EngineSize` / TUI 中的 `Format-FileSize`）在两个模块间重复——如有更改请保持两者同步。

### 提权模型
- **`WSLManager.bat`（TUI）** 提前对整个进程提权（`net session` 检查 → `Start-Process -Verb RunAs`）。
- **`WSLManager.GUI.bat`（GUI）** 启动时不提权。它以普通用户身份用 `-WindowStyle Hidden` 启动，每次写操作（导入/删除/商店安装）通过引擎中的 `Invoke-ElevatedScript` 触发一次 UAC。
- `Invoke-ElevatedScript`：如果已是管理员，则内联运行脚本块。否则写入临时 `.ps1`，用 `runas` 启动它，并通过轮询追加的结果文件**逐行流式输出**回调用方（让 GUI 显示实时下载/安装进度）。它还可选地生成一个看门狗 `.ps1`，轮询 `CancelFile` 并 `taskkill` 提权进程树——这是 GUI「取消操作」按钮背后的机制。临时脚本用 `UTF8Encoding($true)` 写入，以便提权子进程解析中文。

### WSL 命令安全
- **在任何 `wsl --unregister` 之前**：先 `wsl -t <name>`，再 `Start-Sleep -Seconds 1`。
- **在 `wsl --unregister` 之后**：检查 `$LASTEXITCODE`。如果失败，中止所有后续清理（防止孤儿实例）。
- **在所有创建路径中于导入前进行名称冲突检查**：商店 / 仓库 / tar / 备份恢复。引擎函数提前做这件事。
- 商店安装流程（`New-WSLInstanceFromStore`）：`wsl --install -d <name> --no-launch --web-download`（避免商店 UI 挂起；`--web-download` 绕过商店）→ 导出模板 → 注销默认 → 重新导入到受管位置。任何步骤失败都会返回带有 `__FAIL__:` 标记；引擎从 `$exec.Output` 中解析这些标记。

### 备份 / 恢复 / 移除安全
- 磁盘空间检查目标为备份目录所在盘符（`GetPathRoot` 的 `Backups`），而不是 `SystemDrive`。
- 恢复“覆盖”：停止 → 注销（检查结果，失败则中止）→ 导入。
- 移除（`Remove-WSLInstance`）使用**一次 UAC**，把停止 → 注销 → 2/3/4 级清理作为一个脚本运行。注销失败会中止一切。模板匹配使用模糊 `-like` 在 `Repositories\` 子目录上进行，在非提权进程中扫描它们并把路径传给提权脚本（因为提权后可能无法访问目录）。

## 开源与发布

- **许可证**：MIT（2026，LSJ）——`LICENSE` 随每个发布 zip 附带。
- **仓库**：公开 `LSJ9651/WSLManager`，默认分支 `master`，主题 `wsl powershell windows wsl2 cli`。
- **版本同步**：版本仅存在于 TUI 头部 `WSL 发行版管理工具 v1.0`，位于 `scripts/WSLManager.psm1:124`（GUI 不显示版本）。发布时，同时更新头部、git 标签和 Release 说明。
- **发布 zip**：`WSLManager.bat`、`WSLManager.GUI.bat`、`scripts/`、`README.md`、`LICENSE`、`config.example.json`。**绝不打包** `Config/`、`Repositories/`、`Instances/`、`Backups/`——它们包含个人数据。运行时目录在首次运行时会重新创建，所以它们不属于 zip。
- **`docs/` 被 gitignored**（本地专属设计文档）——不要在任何面向用户的内容中引用它。
- **提交消息**：中文，与现有历史一致。
- **README 是用户契约**：其 功能说明 / 配置说明 / 安全说明 / 注意事项 部分必须与任何行为更改同步更新。

## ⚠️ 必须协调的 README 偏差

README 的安全说明做出了一个**“无网络访问 / 不发起任何 HTTP/HTTPS 请求”**声明，但引擎现在会进行网络调用：
- `Test-WSLStorePreflight` 向 `https://wslstorestorage.blob.core.windows.net/wslblob/` 执行一次 **HTTP HEAD**。
- `Get-WSLStoreDistros` 运行 `wsl -l -o`（网络查询）。
- 商店安装使用 `--web-download`，GUI 首次运行屏幕有 `wsl --install` 按钮。

这里的网络访问是用户发起的（仅在从商店添加系统时），所以不是遥测——但这个声明在字面上是假的。另外，README 的 目录结构 与 配置说明 此前引用的 `Temp/` 目录与 `AutoCleanTempDays` 配置已不存在（config 现在只有 `WSLRoot`、`DefaultWSLVersion`、`BackupRetentionCount`），且运行时目录已统一为 `Data\` 下的 `Config`/`Repositories`/`Instances`/`Backups`——这些均已在 README 中修正。**任何触及 README 安全说明或商店安装路径的更改都应在同一更改中修复这些。**
