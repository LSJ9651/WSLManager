# Windows Script Writing Standards

> Claude Code Skill — 规范 Windows 脚本（PowerShell / Batch）的编写，沉淀 WSL 管理工具开发中遇到的实际问题。

## 适用场景

当你需要编写或审查以下类型的脚本时，应启用此 skill：

- PowerShell 模块 (`.psm1`) 和脚本 (`.ps1`)，尤其是需要兼容 PowerShell 5.1 的场景
- Windows 批处理文件 (`.bat` / `.cmd`)
- 与 WSL (`wsl.exe`) 交互的自动化脚本
- 需要处理中文或其他非 ASCII 字符的 Windows 脚本

## 使用方法

在 Claude Code 对话中输入 `/windows-scripting-guide` 即可加载此 skill。也可以直接描述你的脚本需求，Claude 会自动匹配并应用相关规范。

## 内容概览

| 章节 | 主题 | 关键规则 |
|:-----|:-----|:---------|
| **1** | 文件编码与换行符 | `.psm1` / `.ps1` → UTF-8 BOM + LF；`.bat` → UTF-8 BOM + CRLF |
| **2** | PowerShell 5.1 兼容性 | `$LASTEXITCODE` vs `$?`、禁止 ANSI 转义序列、颜色参数规范 |
| **3** | 路径与目录处理 | `$PSScriptRoot` 的正确用法、磁盘空间检查 |
| **4** | WSL 命令模式 | 实例列表过滤、注销/导入安全流程、备份操作 |
| **5** | Batch 文件规则 | 分隔符（`;` 非 `,`）、提权模式、路径引号处理 |
| **6** | 配置文件模式 | 自动创建 + 自愈（解析失败时重建） |
| **7** | 清理与安全模式 | 破坏性操作七步序列、注释块安全 |
| **8** | 常见错误速查表 | 13 种典型症状 + 根因 + 修复方案 |
| **9** | WSL 专项指南 | 退出码检查、超时策略、模板 vs 实例的生命周期 |

## 背景

此 skill 的全部规则来源于 [WSLManager](https://github.com) 项目的实战经验。在开发一个可移植的 WSL 发行版管理工具过程中，我们经历了 6 轮审查，累计修复了 26 个 bug，涵盖编码损坏、路径解析错误、命令语义误用、WSL 生命周期管理遗漏等多种类型。每个规则背后都有一个真实的故障案例。

## 协议

本项目采用 [MIT License](LICENSE)。
