# Windows Script Writing Guide

Claude Code Skill — 规范 Windows 脚本（PowerShell 5.1 / Batch / WSL）的编写与审查。

## 适用场景

编写或审查以下类型脚本时启用：

- PowerShell 模块 (`.psm1`) 和脚本 (`.ps1`)，需兼容 PowerShell 5.1
- Windows 批处理文件 (`.bat` / `.cmd`)
- 与 WSL (`wsl.exe`) 交互的自动化脚本
- 处理中文或非 ASCII 字符的 Windows 脚本

## 使用方法

在对话中输入 `/windows-scripting-guide` 加载此 skill，或描述脚本需求时自动匹配。

## 规则概览

| 规则 | 核心内容 |
|:-----|:---------|
| **编码** | `.psm1` → UTF-8 BOM + LF；`.bat` → UTF-8 BOM + CRLF |
| **PS 5.1 兼容** | 禁止 `??`、`?:`、`ForEach-Object -Parallel`；`$?` vs `$LASTEXITCODE` |
| **路径处理** | `$PSScriptRoot` 直接用法；目标驱动器磁盘空间检查 |
| **WSL 命令** | NUL 字符安全列表；unregister/import 安全流程；备份/恢复模式 |
| **Batch** | `;` 分隔语句；提权模式；路径引号处理 |
| **配置** | 自动创建 + 自愈（解析失败重建） |
| **安全** | 破坏性操作七步序列；注释块安全 |

## 来源

规则来源于 [WSLManager](https://github.com/LSJ9651/WSLManager) 项目实战——6 轮审查、26 个 bug 修复，每个规则对应一个真实故障案例。
