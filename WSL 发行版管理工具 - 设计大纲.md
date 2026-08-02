# WSL 发行版管理工具 - 设计大纲

> **版本**: v2.0
> **目标**: 提供一个可移植、自包含、用户友好的 WSL 发行版图形化管理工具（基于命令行菜单）


## 一、项目定位与设计目标

### 1.1 核心定位
- **通用性**: 脚本解压到任意目录即可使用，无需修改代码，支持 Win10/Win11
- **自包含性**: 所有 WSL 相关文件（母版、实例、备份）统一存放在脚本根目录下，整个文件夹可随意移动
- **易用性**: 用户双击 `.bat` 文件即可进入交互式菜单，无需记忆任何命令
- **安全性**: 危险操作（删除）需二次确认，提供分级清理选项

### 1.2 设计哲学
> **".tar 做母版（存储），.vhdx 做实例（运行）"**
> - 母版仓库存储压缩的 `.tar` 文件，节省磁盘空间
> - 运行实例使用 `wsl --import` 生成的 `ext4.vhdx` 文件，性能最优


## 二、技术选型与架构

### 2.1 技术栈
| 组件 | 选择 | 理由 |
| :--- | :--- | :--- |
| **主脚本语言** | PowerShell 5.1+ | Win10/Win11 原生支持，无需额外安装 |
| **启动器** | Batch (.bat) | 解决双击运行和权限提权问题 |
| **配置文件** | JSON | 结构清晰，便于读写和版本管理 |
| **WSL 交互** | `wsl.exe` 命令 | 官方管理接口，稳定可靠 |

### 2.2 文件架构
```
WSLManager\                          # 📁 用户自定义根目录（可任意放置）
│
├── WSLManager.bat                   # 🚀 启动器（用户双击入口）
├── WSLManager.psm1                  # ⚙️ 核心功能模块
│
├── Config\                          # ⚙️ 配置目录
│   └── config.json                  # 用户配置文件（路径、偏好等）
│
├── Repositories\                    # 📦 母版仓库（存储 .tar 压缩包）
│   └── <发行版名>\
│       └── base.tar                # 干净的黄金母版
│
├── Instances\                       # 🖥️ 运行实例（存储 .vhdx 文件）
│   └── <实例名>\
│       └── ext4.vhdx               # WSL 实际运行文件
│
├── Backups\                         # 💾 备份存档
│   └── <实例名>\
│       ├── full_20260802_143025.tar
│       └── full_20260715_091030.tar
│
└── Temp\                            # 🧹 临时工作区（脚本自动清理）
    └── (运行时产生的中间文件)
```

### 2.3 启动流程
```
用户双击 WSLManager.bat
    ├── 1. 设置控制台编码为 UTF-8 (chcp 65001)
    ├── 2. 检测管理员权限（net session）
    │   └── 若非管理员 → 通过 PowerShell Start-Process -Verb RunAs 重新提权启动
    ├── 3. 确定脚本所在目录
    ├── 4. 以 -NoProfile -ExecutionPolicy Bypass 启动 PowerShell
    │   ├── Set-Location 到脚本目录
    │   └── Import-Module .\WSLManager.psm1 -Force
    └── 5. 调用 Show-Menu 进入主循环
```

### 2.4 模块初始化流程
```
Import-Module WSLManager.psm1
    ├── 1. 设置控制台编码为 UTF-8
    ├── 2. 定义全局变量（Config, RootPath, ConfigPath）
    ├── 3. 读取配置（Get-WSLConfig），若文件不存在则自动创建默认配置
    ├── 4. 确保所有必要目录存在（Repositories / Instances / Backups / Temp / Config）
    └── 5. 清理 Temp\ 中超过 AutoCleanTempDays 天的旧文件
```


## 三、核心功能模块设计

### 3.1 功能全景图
| 编号 | 功能 | 描述 |
| :--- | :--- | :--- |
| 1 | **列出所有实例** | 显示已安装的 WSL 发行版列表及运行状态 |
| 2 | **新增发行版** | 从在线商店/本地母版/自定义 `.tar` 创建新实例 |
| 3 | **备份发行版** | 将运行中的实例导出为 `.tar` 压缩存档 |
| 4 | **还原发行版** | 从备份 `.tar` 文件恢复实例 |
| 5 | **删除发行版** | 分级删除（仅注销/删备份/删母版/全量清理） |
| 6 | **退出** | 退出程序 |

### 3.2 各功能详细逻辑

#### 🔹 功能 1：列出所有实例
```
用户选择"列出"
    ├── 执行 wsl -l -v 获取所有实例及运行状态
    ├── 直接输出原始结果（保留 WSL 原生命令的完整信息）
    └── 按任意键返回主菜单
```

#### 🔹 功能 2：新增发行版（重点设计）
```
用户选择新增
    ├── 来源1: 从微软官方在线商店下载
    │   ├── 执行 wsl -l -o 显示可安装列表
    │   ├── 用户输入发行版名称
    │   ├── 执行 wsl --install -d <名称> 安装到系统默认位置
    │   ├── 检查安装结果（$LASTEXITCODE），失败则提示并返回
    │   ├── 自动导出为母版 → Repositories\<名称>\base.tar
    │   ├── 检查导出结果，失败则清理残留实例并返回
    │   ├── 注销默认位置实例 → wsl --unregister <名称>
    │   ├── 用户输入新实例名（默认使用发行版名）
    │   ├── 检查实例名是否已存在，存在则提示并返回
    │   ├── 导入到 Instances\<实例名>\ → wsl --import ... --version N
    │   └── 导入失败时自动重试一次
    │
    ├── 来源2: 从本地母版仓库创建
    │   ├── 扫描 Repositories\ 下所有含 base.tar 的文件夹
    │   ├── 显示母版列表（含文件大小，使用 Format-FileSize 格式化）
    │   ├── 用户通过编号选择母版
    │   ├── 用户输入新实例名（默认自动生成：<母版名>_YYYYMMDD）
    │   ├── 检查实例名是否已存在，存在则提示并返回
    │   └── wsl --import <实例名> Instances\<实例名>\ base.tar --version N
    │
    └── 来源3: 从自定义 .tar 文件导入
        ├── 用户输入 .tar 文件完整路径
        ├── 校验文件是否存在（Test-Path），不存在则报错返回
        ├── 自动提取文件名作为发行版名 → [System.IO.Path]::GetFileNameWithoutExtension
        ├── 复制 .tar 到 Repositories\<发行版名>\base.tar（作为母版）
        ├── 用户输入新实例名（默认自动生成：<发行版名>_YYYYMMDD）
        ├── 检查实例名是否已存在，存在则提示并返回
        └── wsl --import <实例名> Instances\<实例名>\ base.tar --version N
```

#### 🔹 功能 3：备份发行版
```
用户选择备份
    ├── 执行 wsl -l -q 获取所有已安装实例列表
    ├── 过滤空行，Trim 处理实例名
    ├── 若无实例，提示并返回
    ├── 用户通过编号选择要备份的实例
    ├── 生成备份文件名: full_YYYYMMDD_HHmmss.tar（精确到秒）
    ├── 确保 Backups\<实例名>\ 目录存在
    ├── 磁盘空间检测
    │   ├── 获取备份目录所在驱动器的剩余空间（Get-PSDrive）
    │   └── 若 < 5GB，发出警告并询问是否继续
    ├── 执行 wsl --export <实例名> Backups\<实例名>\<文件名>.tar
    ├── 备份失败时清理可能产生的空文件
    ├── 显示备份文件路径和大小（Format-FileSize）
    └── 自动清理旧备份
        ├── 读取 BackupRetentionCount 配置
        ├── 若 > 0，列出该实例所有 .tar 备份，按名称降序排列
        └── 删除超出保留数量的旧备份文件
```

#### 🔹 功能 4：还原发行版
```
用户选择还原
    ├── 扫描 Backups\ 下所有子文件夹的 .tar 文件
    ├── 收集备份元数据（实例名、文件名、路径、大小、最后写入时间）
    ├── 按时间降序排列（最新备份优先显示）
    ├── 若无备份，提示并返回
    ├── 用户通过编号选择要还原的备份文件
    ├── 用户选择还原方式
    │   ├── 方式1: 覆盖原实例
    │   │   ├── wsl -t <实例名> 停止原实例
    │   │   ├── sleep 1 秒等待停止完成
    │   │   ├── wsl --unregister <实例名> 注销原实例
    │   │   ├── 检查注销结果，失败则中止
    │   │   └── wsl --import <实例名> Instances\<实例名>\ <备份文件> --version N
    │   │
    │   └── 方式2: 创建新实例
    │       ├── 用户输入新实例名
    │       ├── 检查实例名是否已存在，存在则提示并返回
    │       └── wsl --import <新实例名> Instances\<新实例名>\ <备份文件> --version N
    │
    └── 提示还原结果
```

#### 🔹 功能 5：删除发行版（分级清理）
```
用户选择删除
    ├── 列出所有已安装实例（wsl -l -q）
    ├── 用户通过编号选择要删除的实例
    ├── 显示红色警告（操作不可恢复）
    ├── 二次确认：输入实例完整名称，与目标名称完全匹配才继续
    ├── 选择删除级别（四级）
    │   ├── 1. 仅注销 WSL 实例
    │   │   ├── [1/4] wsl -t <实例名>（停止实例）
    │   │   └── [1/4] wsl --unregister <实例名>（注销）
    │   │
    │   ├── 2. 注销 + 删除备份
    │   │   ├── [1/4] 停止 + 注销实例
    │   │   └── [2/4] Remove-Item Backups\<实例名>\ -Recurse -Force
    │   │
    │   ├── 3. 注销 + 删除备份 + 删除母版
    │   │   ├── [1/4] 停止 + 注销实例
    │   │   ├── [2/4] 删除备份目录
    │   │   └── [3/4] 删除母版目录
    │   │       ├── 扫描 Repositories\ 下所有子目录
    │   │       ├── 模糊匹配实例名（双向 like 匹配）
    │   │       ├── 匹配到 0 个 → 跳过
    │   │       ├── 匹配到 1 个 → 直接删除
    │   │       └── 匹配到多个 → 列出候选，用户选择或跳过
    │   │
    │   └── 4. 全量清理
    │       ├── [1/4] 停止 + 注销实例
    │       ├── [2/4] 删除备份目录
    │       ├── [3/4] 删除母版目录（模糊匹配）
    │       └── [4/4] Remove-Item Instances\<实例名>\ -Recurse -Force
    │
    ├── 每步操作显示执行结果（$? 检查）
    └── 汇总最终结果（全部成功 / 部分失败）
```


## 四、代码模块结构

### 4.1 WSLManager.bat — 启动器
| 职责 | 说明 |
| :--- | :--- |
| 编码设置 | `chcp 65001` 设置控制台为 UTF-8 |
| 权限检测 | `net session` 检测管理员权限，非管理员则调用 PowerShell `Start-Process -Verb RunAs` 重新启动 |
| 模块加载 | 使用 `-NoProfile -ExecutionPolicy Bypass` 加载 `.psm1` 模块，`Set-Location` 到脚本目录后 `Import-Module -Force` |
| 用户停留 | 脚本退出后 `pause` 保持窗口 |

### 4.2 WSLManager.psm1 — 核心模块结构

```
WSLManager.psm1
│
├── 1. 编码设置
│   ├── [Console]::OutputEncoding = UTF8
│   └── $OutputEncoding = UTF8
│
├── 2. 全局变量
│   ├── $script:Config = $null
│   ├── $script:RootPath = $PSScriptRoot
│   └── $script:ConfigPath = "$RootPath\Config\config.json"
│
├── 3. 配置管理函数
│   ├── Get-WSLConfig         — 读取配置（首次调用时初始化）
│   └── Initialize-WSLConfig  — 创建默认 config.json
│
├── 4. 路径管理函数
│   ├── Get-WSLRoot           — 解析 WSL 根目录（配置优先，脚本目录兜底）
│   └── Ensure-Directory      — 确保目录存在（不存在则 New-Item -Force）
│
├── 5. 核心功能函数
│   ├── Show-Menu             — 主菜单循环（唯一导出的函数）
│   ├── List-Instances        — 列表显示
│   ├── New-WSLInstance       — 新增入口（分发到三个子函数）
│   │   ├── New-WSLInstanceFromStore  — 来源1: 在线商店
│   │   ├── New-WSLInstanceFromRepo   — 来源2: 本地母版
│   │   └── New-WSLInstanceFromTar    — 来源3: 自定义 tar
│   ├── Backup-WSLInstance    — 备份实例
│   ├── Restore-WSLInstance   — 还原实例
│   └── Remove-WSLInstance     — 删除实例（四级清理）
│
├── 6. 辅助工具函数
│   ├── Format-FileSize       — 字节数转人类可读（B/KB/MB/GB）
│   ├── Pause-And-Return      — 暂停等待按键返回菜单
│   └── Clean-TempFiles       — 清理过期临时文件
│
├── 7. 模块导出
│   └── Export-ModuleMember -Function Show-Menu
│
└── 8. 启动时初始化
    ├── 确保五大目录存在（Repositories/Instances/Backups/Temp/Config）
    └── 清理 Temp\ 中过期文件
```


## 五、配置管理设计

### 5.1 配置文件 (`Config\config.json`)
```json
{
    "WSLRoot": "",                    // 留空则自动识别为脚本所在目录
    "DefaultWSLVersion": 2,           // 默认 WSL 版本（1 或 2）
    "AutoCleanTempDays": 3,           // 自动清理 Temp\ 中超过 N 天的文件
    "BackupRetentionCount": 5         // 每个实例保留的最新备份数量（0=不自动清理）
}
```

### 5.2 配置生命周期
```
首次启动（config.json 不存在）
    → Initialize-WSLConfig 自动创建默认配置

后续启动（config.json 存在）
    → Get-WSLConfig 读取并缓存到 $script:Config
    → JSON 解析失败时 → 使用默认配置 + 自动重建配置文件（容错自愈）
```

### 5.3 路径解析逻辑（核心）
- **优先使用** `config.json` 中用户指定的 `WSLRoot`
- **自定义路径校验**：若指定了 WSLRoot 但目录创建失败 → 回退到脚本目录并警告
- **若未指定**：自动使用 `$PSScriptRoot`（脚本所在目录）
- **所有子路径**（`Repositories\`, `Instances\`, `Backups\`, `Temp\`）基于 `WSLRoot` 动态拼接


## 六、安全与容错机制

| 机制 | 实现方式 | 状态 |
| :--- | :--- | :---: |
| **管理员权限** | `.bat` 启动时 `net session` 检测 + `Start-Process -Verb RunAs` 提权 | ✅ |
| **执行策略绕过** | `.bat` 中使用 `-ExecutionPolicy Bypass` 参数启动 PowerShell | ✅ |
| **二次确认** | 删除操作需输入发行版完整名称，与目标名称完全匹配才执行 | ✅ |
| **实例名冲突检测** | 新增/还原前检查实例名是否已存在（`wsl -l -q` 对比），存在则拒绝 | ✅ |
| **路径有效性校验** | 每次读取配置后使用 `Test-Path` 检查目录和文件是否存在 | ✅ |
| **配置文件自愈** | JSON 解析失败时自动使用默认配置并重建文件 | ✅ |
| **导入失败重试** | 在线商店导入失败时自动重试一次 | ✅ |
| **备份失败清理** | 备份失败时自动删除可能产生的空文件 | ✅ |
| **删除步骤保护** | 注销实例失败时立即中止后续清理操作，防止数据丢失 | ✅ |
| **异常捕获** | 关键操作使用 `try/catch` 捕获并显示友好错误信息 | ✅ |
| **自动清理** | 脚本启动时自动清理 `Temp\` 中超过 `AutoCleanTempDays` 天的旧文件 | ✅ |
| **空间预警** | 备份前检测磁盘剩余空间（Get-PSDrive），若不足 5GB 则警告并询问 | ✅ |
| **操作日志** | 记录所有操作到 `Logs\` 目录（设计中，尚未实现） | ❌ |


## 七、用户交互设计

### 7.1 菜单结构
```text
========================================
    WSL 发行版管理工具 v1.0
========================================
  1. 列出所有已安装的发行版
  2. 新增发行版
  3. 备份发行版
  4. 还原发行版
  5. 删除发行版
  6. 退出
========================================
请输入您的选择 (1-6)：
```

### 7.2 交互原则
- **色彩规范**：`Cyan`=提示/信息、`Yellow`=警告、`Red`=错误/危险、`Green`=成功、`Gray`=次要信息
- **分步引导**：复杂操作采用向导式交互（新增三选一、还原二选一、删除四选一）
- **默认值友好**：输入框提供合理默认值，直接回车即可使用
  - 在线商店新建：默认实例名 = 发行版名
  - 母版/自定义新建：默认实例名 = `<母版名>_YYYYMMDD`
- **编号选择**：列表项使用数字编号，输入编号即可选择
- **操作反馈**：每个操作完成后显示明确的结果（成功/失败/跳过）
- **暂停机制**：操作完成后暂停等待按键（`$Host.UI.RawUI.ReadKey`），防止结果被清屏覆盖

### 7.3 辅助函数细节

#### Format-FileSize
```
输入字节数 → 输出人类可读字符串
  ≥ 1GB  → "X.XX GB"
  ≥ 1MB  → "X.XX MB"
  ≥ 1KB  → "X.XX KB"
  否则   → "X B"
```

#### Pause-And-Return
```
显示灰色 "按任意键返回主菜单..." → 等待非回显按键 → 返回
（使用 $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")）
```

#### Clean-TempFiles
```
参数: $days (默认 3)
逻辑: 遍历 Temp\ 下所有文件 → LastWriteTime < (当前时间 - N天) → Remove-Item
异常: 单个文件删除失败不中断，输出警告继续处理
```


## 八、兼容性与编码规范

### 8.1 平台兼容性
| 平台 | 注意事项 |
| :--- | :--- |
| **Windows 10** | 版本 2004（内部版本 19041）及以上才支持 WSL 2；低版本自动降级为 WSL 1 |
| **Windows 11** | 原生支持 WSL 2，无需特殊处理 |
| **PowerShell 版本** | 兼容 PowerShell 5.1（Win10/11 预装版本），不依赖 PowerShell 7+ 特性 |

### 8.2 文件编码规范
| 文件类型 | 换行符 | 编码 | 说明 |
| :--- | :--- | :--- | :--- |
| `.bat` / `.cmd` | **CRLF** | UTF-8 with BOM | 必须 CRLF，否则命令解析错误 |
| `.psm1` / `.ps1` | **LF** | UTF-8 with BOM | LF 保持跨平台兼容性，BOM 避免不可见字符干扰 |

### 8.3 运行时编码
- 脚本启动时强制设置 `[Console]::OutputEncoding = [System.Text.Encoding]::UTF8`
- `.bat` 启动器使用 `chcp 65001` 设置控制台代码页为 UTF-8


## 九、关键命令速查

| 操作 | 命令 | 使用位置 |
| :--- | :--- | :--- |
| 列出在线发行版 | `wsl -l -o` | New-WSLInstanceFromStore |
| 列出已安装实例 | `wsl -l -v` | List-Instances |
| 列出实例名（静默） | `wsl -l -q` | Backup / Restore / Remove |
| 安装新发行版 | `wsl --install -d <名称>` | New-WSLInstanceFromStore |
| 导出为 tar | `wsl --export <实例名> <路径>.tar` | Backup / New-WSLInstanceFromStore |
| 导入为实例 | `wsl --import <实例名> <安装路径> <tar路径> --version 2` | New / Restore |
| 注销实例 | `wsl --unregister <实例名>` | Remove / Restore / New-WSLInstanceFromStore |
| 停止实例 | `wsl -t <实例名>` | Remove / Restore |
| 启动实例 | `wsl -d <实例名>` | （手动使用） |


## 十、部署与使用

### 10.1 部署方式
- 将 `WSLManager\` 文件夹解压/复制到任意位置（任意盘符、任意路径）
- 双击 `WSLManager.bat` 即可运行
- 首次使用自动创建目录结构（Repositories / Instances / Backups / Temp / Config）和默认配置文件
- 整个文件夹可通过压缩包分发给其他用户，无需任何额外配置

### 10.2 运行要求
- Windows 10 版本 2004+ 或 Windows 11
- 已启用 WSL 功能（`wsl --install` 或通过"启用或关闭 Windows 功能"）
- 管理员权限（脚本自动检测并提权）

### 10.3 后续可扩展方向
- [ ] 支持 WSL 1 / WSL 2 版本切换
- [ ] 支持计划任务自动备份
- [ ] 支持增量备份（仅备份变更的文件）
- [ ] 支持云存储同步（OneDrive / 阿里云盘等）
- [ ] 实现操作日志记录（Logs\ 目录）
- [ ] 添加菜单内配置管理入口（查看/修改路径设置等）
- [ ] 支持批量操作（批量备份、批量删除）


## 十一、附录：设计大纲版本修订记录

| 版本 | 日期 | 修订内容 |
| :--- | :--- | :--- |
| v1.0 | 2026-08 | 初版设计大纲，定义核心功能和架构 |
| v2.0 | 2026-08 | 根据实际代码实现全面更新：修正菜单结构（移除"配置管理"入口）、补充模块初始化流程、细化各功能实现细节（实例名冲突检测、磁盘空间预警、母版模糊匹配删除、导入重试、备份失败清理、配置文件自愈等）、标注"操作日志"为未实现特性、更新代码模块结构树和函数清单、增加编码规范和启动流程说明 |
