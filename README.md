<p align="center">
  <h1 align="center">WSLManager</h1>
  <p align="center">
    一款便携式的 WSL 发行版管理工具：双击启动，通过交互式菜单即可创建、备份、恢复和删除 WSL 实例；所有文件收纳于同一目录，可随意移动。
  </p>
</p>

<p align="center">
  <img src="https://img.shields.io/github/license/LSJ9651/WSLManager?style=for-the-badge" alt="许可证">
  <img src="https://img.shields.io/github/v/release/LSJ9651/WSLManager?style=for-the-badge" alt="最新版本">
  <img src="https://img.shields.io/github/stars/LSJ9651/WSLManager?style=for-the-badge&color=gold" alt="Stars">
  <br>
  <img src="https://img.shields.io/badge/PowerShell-5.1-5391FE?style=for-the-badge&logo=powershell" alt="PowerShell">
  <img src="https://img.shields.io/badge/Windows-10/11-0078D6?style=for-the-badge&logo=windows" alt="Windows">
  <img src="https://img.shields.io/badge/WSL-1_&_2-000000?style=for-the-badge&logo=linux" alt="WSL">
</p>

---

## 目录

- [这是什么？](#这是什么)
- [功能特性](#功能特性)
- [快速开始](#快速开始)
- [工作原理](#工作原理)
- [配置说明](#配置说明)
- [安全与隐私](#安全与隐私)
- [目录结构](#目录结构)
- [常见问题](#常见问题)
- [项目链接](#项目链接)

---

## 这是什么？

**WSLManager** 是一款面向 Windows 用户的**零安装、便携化** WSL（Windows Subsystem for Linux）发行版管理工具。无需 `winget`、无需 `apt`、无需注册表改动——双击 `WSLManager.bat` 即可启动，所有数据（母版、实例、备份）全部保存在工具所在目录下。

所有 WSL 文件统一收纳在同一目录，移动文件夹即可带走全部数据。

**适用场景：**

- 需要同一发行版的多个实例（不同配置、不同项目）
- 希望定期备份 WSL 数据，防止系统更新导致数据丢失
- 追求便携——工具可放在 U 盘或任意目录，随时带走
- 重视安全——工具承诺不与外部通信，不写注册表，不创建服务或计划任务

---

## 功能特性

| 功能 | 说明 |
|---|---|
| **列出实例** | 展示所有已安装的 WSL 发行版及其版本信息 |
| **新增发行版** | 三种来源：微软商店在线安装 / 本地母版仓库 / 自定义 `.tar` 文件 |
| **备份发行版** | 将实例导出为 `.tar`，自动检测磁盘空间并按保留数清理旧备份 |
| **还原发行版** | 从备份恢复，支持覆盖原实例或创建新实例 |
| **删除发行版** | 四级清理粒度（仅注销 / 删备份 / 删母版 / 全量清理），删除前需输入完整实例名二次确认 |
| **完全便携** | 无需安装，复制整个文件夹即可在任何 Windows 10/11 机器上运行 |
| **可配置** | `Config/config.json` 控制 WSL 版本、备份保留数、临时文件清理策略 |

---

## 快速开始

### 前置要求

- Windows 10（版本 2004+）或 Windows 11
- WSL 已启用（运行 `wsl --version` 确认）
- 管理员权限（工具启动时会自动请求 UAC 提权）

### 使用方法

```
1. 将 WSLManager 文件夹解压或复制到任意位置
2. 双击 WSLManager.bat 启动
3. 按菜单提示选择功能
```

首次启动时，工具会自动创建目录结构（`Config/`、`Repositories/`、`Instances/`、`Backups/`、`Temp/`）并生成默认配置文件。

---

## 工作原理

工具使用 `.tar` 归档存储母版（节省空间），使用 `.vhdx` 虚拟磁盘运行实例（性能更优）。一个母版可以反复创建多个实例。

**以从微软商店安装为例的核心流程：**

```
wsl --install -d <name> --no-launch              # 下载安装，不自动进入 Linux
wsl --export <name> Repositories/<name>/base.tar # 导出为母版
wsl --unregister <name>                          # 注销默认位置安装的实例
wsl --import <name> Instances/<name> base.tar --version 2  # 导入到工具管理的目录
```

---

## 配置说明

编辑 `Config/config.json`（首次启动自动生成）：

| 配置项 | 说明 | 默认值 |
|---|---|---|
| `WSLRoot` | 所有 WSL 数据的根目录；留空则使用工具所在目录 | `""`（工具目录） |
| `DefaultWSLVersion` | 新建实例时默认的 WSL 版本（1 或 2） | `2` |
| `AutoCleanTempDays` | 启动时自动清理 Temp/ 下超过 N 天的临时文件 | `3` |
| `BackupRetentionCount` | 每个实例保留的最大备份数，超出则删除最旧的（0 = 不自动清理） | `5` |

> **提示：** 将 `WSLRoot` 配置为其他盘符路径（如 `D:\WSLData`），可将所有数据迁移到非系统盘，节省 C 盘空间。工具会在该路径下自动创建所有子目录。

---

## 安全与隐私

本工具在设计上做出了以下承诺，并在代码中逐一落实：

| 承诺 | 实现方式 |
|---|---|
| **无网络访问** | 不发起任何 HTTP/HTTPS 请求；仅调用本地 `wsl.exe` |
| **无注册表写入** | 不调用 `reg add` / `Set-ItemProperty` 等注册表操作 |
| **无服务 / 计划任务** | 不创建 Windows Service 或 Scheduled Task |
| **文件操作范围受限** | 所有文件读写均限制在 `WSLRoot` 指向的目录树内 |
| **管理员权限可控** | 启动器检测权限，不足时自动请求 UAC 提权，无需手动以管理员运行 |
| **删除二次确认** | 删除实例前要求输入完整实例名，防止误操作 |

> [!NOTE]
> 注销、删除 WSL 发行版需要管理员权限，这是 WSL 的系统要求，并非工具额外越权——直接使用 `wsl --unregister` 等命令同样需要管理员权限。

---

## 目录结构

```
WSLManager/
├── WSLManager.bat      ← 启动器（CRLF + UTF-8 BOM）
├── WSLManager.psm1     ← 核心模块（LF + UTF-8 BOM，约 950 行）
├── README.md           ← 本文档
├── LICENSE             ← MIT 许可证
├── Config/             ← 用户配置（gitignore；首次运行自动重建）
│   └── config.json
├── Repositories/       ← 母版仓库（每个发行版一个 base.tar）
├── Instances/          ← WSL 实例虚拟磁盘（.vhdx）
├── Backups/            ← 发行版备份（.tar）
└── Temp/               ← 临时文件（按配置自动清理）
```

> [!WARNING]
> 若 `Instances/` 下存在已注册的实例，直接移动文件夹会导致实例注册路径失效而无法启动。移动前请先使用"备份发行版"功能导出 `.tar`，移动后通过"还原发行版"重建实例。

---

## 常见问题

**Q：启动时提示"需要管理员权限"**
A：这是正常行为。工具会自动弹出 UAC 提权窗口，点击"是"即可。若多次弹出，请检查 `.bat` 文件是否被安全软件拦截。

**Q：能否在非管理员账户下使用？**
A：部分 WSL 操作（如 `wsl --unregister`、`wsl --import`）需要管理员权限。工具会在启动时检测，不足则请求提权。若系统策略禁止 UAC，请改用管理员账户运行。

**Q：删除实例后 `Instances/` 下仍有目录**
A：删除级别 1–3 不会删除实例目录（仅注销 WSL 记录或删除备份 / 母版）。选择级别 4（全量清理）才会一并删除 `Instances/` 下的目录。

**Q：`wsl -l -q` 列出的实例名称乱码**
A：已知 PowerShell 5.1 下 `wsl -l -q` 返回 UTF-16 LE 编码并含 NUL 字节。工具已内置处理逻辑，正常情况下不会乱码。若仍有问题，请在终端执行 `chcp 65001` 切换到 UTF-8 代码页。

**Q：备份时提示"磁盘空间不足"**
A：工具会在备份前检查目标驱动器剩余空间，不足 5GB 时会提示并询问是否继续。建议确保目标盘有至少与源实例同等大小的空闲空间。

**Q：四级清理分别删了什么？**

| 级别 | 删除内容 |
|---|---|
| 1 | 仅注销 WSL 实例（保留备份和母版） |
| 2 | 注销 + 删除该实例的备份 |
| 3 | 注销 + 删除备份 + 删除母版 |
| 4 | 全量清理（删除所有相关文件，含实例目录） |

**Q：支持哪些 WSL 版本？**
A：同时支持 WSL 1 和 WSL 2，默认创建 WSL 2 实例；可在 `config.json` 中修改 `DefaultWSLVersion`。

---

## 项目链接

- **源代码：** [github.com/LSJ9651/WSLManager](https://github.com/LSJ9651/WSLManager)
- **Release 下载（zip 包）：** [GitHub Releases](https://github.com/LSJ9651/WSLManager/releases)
- **问题反馈与建议：** [Issues](https://github.com/LSJ9651/WSLManager/issues)

---

*用 ❤️ 为 Windows 上的 WSL 用户打造——便携、安全、可控。*
