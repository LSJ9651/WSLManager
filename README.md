# WSL 发行版管理工具

一个用于管理 WSL（Windows Subsystem for Linux）发行版的 PowerShell 工具，通过图形化菜单界面完成新增、备份、还原、删除等操作。

## 功能特性

- **列出发行版**：显示所有已安装的 WSL 发行版及其运行状态
- **新增发行版**：支持从微软商店下载、本地母版仓库、自定义 .tar 文件三种方式
- **备份发行版**：将发行版导出为 .tar 文件，支持自动清理旧备份
- **还原发行版**：从备份文件还原，支持覆盖原实例或创建新实例
- **删除发行版**：四级清理选项，带二次确认机制防止误删
- **完全可移植**：整个文件夹可随意移动，脚本自动适配位置
- **自包含管理**：所有 WSL 相关文件统一存放在脚本目录下

## 目录结构

```
WSLManager\
├── WSLManager.bat          # 双击启动入口
├── WSLManager.psm1         # 核心功能模块
├── README.md               # 使用说明文档
├── Config\
│   └── config.json         # 用户配置文件
├── Repositories\           # 母版仓库（.tar 压缩包）
├── Instances\              # 运行实例（.vhdx 文件）
├── Backups\                # 备份存档
└── Temp\                   # 临时工作区
```

## 使用方法
1. 首次运行可自定义存放WSLManager目录，推荐使用英文路径
2. 双击 `WSLManager.bat` 启动工具，会自动创建Config/、Repositories/、Instances/、Backups/、Temp/目录
3. 工具会自动请求管理员权限
4. 在菜单中选择相应功能进行操作

## 配置说明

首次启动时会自动创建 `Config\config.json`，包含以下配置项：

| 配置项 | 说明 | 默认值 |
|--------|------|--------|
| WSLRoot | WSL 根目录路径（留空则使用脚本所在目录） | 空 |
| DefaultWSLVersion | 默认 WSL 版本（1 或 2） | 2 |
| AutoCleanTempDays | 自动清理超过 N 天的临时文件 | 3 |
| BackupRetentionCount | 每个实例保留的最新备份数量 | 5 |

## 兼容性

- Windows 10（版本 2004+）/ Windows 11
- PowerShell 5.1
- 同时支持 WSL 1 和 WSL 2

## 注意事项

- 需要管理员权限运行
- 删除操作不可恢复，请谨慎操作
- 备份文件默认保留最新的 5 个，可在配置中调整
