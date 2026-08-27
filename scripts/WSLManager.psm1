# WSLManager.psm1
# WSL 发行版管理工具核心模块
# 提供新增、备份、还原、删除 WSL 发行版的完整功能
# 兼容 PowerShell 5.1（Windows 10/11 默认版本）

# ========== 1. 编码设置 ==========
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# ========== 2. 全局变量定义 ==========
$script:Config = $null
# 数据统一收纳于工具目录下的 Data\ 文件夹。脚本统一收纳于 scripts\，故工具根为其上一级。
$script:RootPath = Split-Path -Parent $PSScriptRoot
$script:DefaultDataRoot = Join-Path $script:RootPath "Data"
$script:ConfigPath = Join-Path $script:DefaultDataRoot "Config\config.json"

# ========== 3. 配置管理函数 ==========

<#
.SYNOPSIS
    读取 WSLManager 配置文件
.DESCRIPTION
    读取 Config/config.json，若文件不存在则创建默认配置
#>
function Get-WSLConfig {
    if ($null -ne $script:Config) {
        return $script:Config
    }

    # 若配置文件不存在，先迁移旧布局数据（工具根下的数据目录），再自动创建默认配置
    if (-not (Test-Path $script:ConfigPath)) {
        Invoke-DataMigration
        if (-not (Test-Path $script:ConfigPath)) {
            Initialize-WSLConfig
        }
    }

    try {
        $content = Get-Content $script:ConfigPath -Raw -Encoding UTF8
        $script:Config = $content | ConvertFrom-Json
    }
    catch {
        Write-Warning "配置文件损坏，将使用默认配置并重建文件"
        $script:Config = [PSCustomObject]@{
            WSLRoot              = ""
            DefaultWSLVersion    = 2
            BackupRetentionCount = 5
        }
        # 重建配置文件
        $script:Config | ConvertTo-Json -Depth 3 | Out-File -FilePath $script:ConfigPath -Encoding UTF8
    }

    return $script:Config
}

<#
.SYNOPSIS
    初始化配置文件
.DESCRIPTION
    在 Config 目录下创建默认 config.json
#>
function Initialize-WSLConfig {
    $configDir = Join-Path $script:DefaultDataRoot "Config"
    Ensure-Directory $configDir

    $defaultConfig = @{
        WSLRoot              = ""
        DefaultWSLVersion    = 2
        BackupRetentionCount = 5
    }

    $defaultConfig | ConvertTo-Json -Depth 3 | Out-File -FilePath $script:ConfigPath -Encoding UTF8
}

# ========== 4. 路径管理函数 ==========

<#
.SYNOPSIS
    获取 WSL 根目录路径
.DESCRIPTION
    优先使用 config.json 中 WSLRoot 字段，否则使用 Data 目录
#>
function Get-WSLRoot {
    $config = Get-WSLConfig
    $wslRoot = $config.WSLRoot

    # 若配置了 WSLRoot，使用配置路径并自动创建目录
    if (-not [string]::IsNullOrWhiteSpace($wslRoot)) {
        try {
            Ensure-Directory $wslRoot
            return $wslRoot
        } catch {
            Write-Warning "无法创建自定义根目录 '$wslRoot'，将回退到 Data 目录。错误: $($_.Exception.Message)"
        }
    }

    # 默认回退到 Data 目录（确保完全可移植）
    return $script:DefaultDataRoot
}

<#
.SYNOPSIS
    确保指定目录存在，不存在则自动创建
.PARAMETER path
    需要确保存在的目录路径
#>
function Ensure-Directory {
    param([string]$path)
    if (-not (Test-Path $path)) {
        New-Item -Path $path -ItemType Directory -Force | Out-Null
    }
}

<#
.SYNOPSIS
    将旧布局（工具根下的数据目录）迁移进统一的 Data\ 文件夹（幂等，仅默认布局）
.DESCRIPTION
    首次在 Data\ 布局下运行时调用：若 Data\Config\config.json 尚不存在，
    说明仍是旧布局（数据散落在工具根）。将 Config/Repositories/Instances/Backups
    逐一迁入 Data\。目标统一为 DefaultDataRoot，符合 WSLRoot 留空的场景。
    任何单项失败均跳过，不阻断启动。
#>
function Invoke-DataMigration {
    $newConfig = Join-Path $script:DefaultDataRoot "Config\config.json"
    if (Test-Path $newConfig) {
        return
    }
    Ensure-Directory $script:DefaultDataRoot
    foreach ($name in @("Config", "Repositories", "Instances", "Backups")) {
        $legacy = Join-Path $script:RootPath $name
        $dest   = Join-Path $script:DefaultDataRoot $name
        if ((Test-Path $legacy -PathType Container) -and -not (Test-Path $dest)) {
            try {
                Move-Item -LiteralPath $legacy -Destination $dest -ErrorAction Stop
            } catch {
                # 迁移失败（如目录被占用），跳过该目录，不阻断启动
            }
        }
    }
}

# ========== 5. 核心功能函数 ==========

<#
.SYNOPSIS
    显示主菜单并处理用户选择
.DESCRIPTION
    循环显示菜单，直到用户选择退出
#>
function Show-Menu {
    while ($true) {
        Clear-Host
        Write-Host ""
        Write-Host "========================================" -ForegroundColor Cyan
        Write-Host "    WSL 发行版管理工具 v1.0" -ForegroundColor Cyan
        Write-Host "========================================" -ForegroundColor Cyan
        Write-Host "  1. 列出所有已安装的发行版"
        Write-Host "  2. 新增发行版"
        Write-Host "  3. 备份发行版"
        Write-Host "  4. 还原发行版"
        Write-Host "  5. 删除发行版"
        Write-Host "  6. 退出"
        Write-Host "========================================" -ForegroundColor Cyan

        $choice = Read-Host "请输入您的选择 (1-6)"

        switch ($choice) {
            "1" { List-Instances }
            "2" { New-WSLInstance }
            "3" { Backup-WSLInstance }
            "4" { Restore-WSLInstance }
            "5" { Remove-WSLInstance }
            "6" {
                Write-Host "`n感谢使用，再见！" -ForegroundColor Green
                return
            }
            default {
                Write-Host "`n无效选择，请重新输入。" -ForegroundColor Yellow
                Start-Sleep -Seconds 2
            }
        }
    }
}

<#
.SYNOPSIS
    列出所有已安装的 WSL 发行版
.DESCRIPTION
    执行 wsl -l -v 获取所有实例，解析并以表格形式展示
#>
function List-Instances {
    Clear-Host
    Write-Host ""
    Write-Host "正在获取已安装的 WSL 发行版列表..." -ForegroundColor Cyan
    Write-Host ""

    # 执行 wsl -l -v 获取发行版列表
    wsl -l -v 2>&1 | Out-String | ForEach-Object { Write-Host $_ }

    Write-Host ""
    Write-Host "按任意键返回主菜单..." -ForegroundColor Gray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

<#
.SYNOPSIS
    新增 WSL 发行版
.DESCRIPTION
    提供三种来源：从微软商店下载、从本地母版创建、从自定义 .tar 文件导入
#>
function New-WSLInstance {
    Clear-Host
    Write-Host ""
    Write-Host "新增发行版" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  1. 从微软官方在线商店下载"
    Write-Host "  2. 从本地母版仓库创建"
    Write-Host "  3. 从自定义 .tar 文件导入"
    Write-Host "  0. 返回主菜单"
    Write-Host "========================================" -ForegroundColor Cyan

    $sourceChoice = Read-Host "请选择来源 (0-3)"

    switch ($sourceChoice) {
        "1" { New-WSLInstanceFromStore }
        "2" { New-WSLInstanceFromRepo }
        "3" { New-WSLInstanceFromTar }
        "0" { return }
        default {
            Write-Host "`n无效选择，按任意键返回。" -ForegroundColor Yellow
            $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        }
    }
}

<#
.SYNOPSIS
    Install a WSL distro from the Microsoft Store.
.DESCRIPTION
    Lists available distros, user selects one, installs it, exports as repo template,
    unregisters the default instance, then re-imports to managed location.
#>
function New-WSLInstanceFromStore {
    Clear-Host
    Write-Host ""
    Write-Host "正在获取可安装的发行版列表..." -ForegroundColor Cyan
    Write-Host ""

    # 获取可安装发行版列表
    wsl -l -o 2>&1 | Out-String | ForEach-Object { Write-Host $_ }

    Write-Host ""
    $distroName = Read-Host "请输入要安装的发行版名称"

    if ([string]::IsNullOrWhiteSpace($distroName)) {
        Write-Host "`n发行版名称不能为空。" -ForegroundColor Yellow
        Pause-And-Return
        return
    }

    Write-Host "`n正在安装 '$distroName'，请稍候..." -ForegroundColor Cyan

    # 安装发行版到系统默认位置（--no-launch 防止自动进入 Linux，确保脚本后续流程完整运行）
    wsl --install -d $distroName --no-launch

    if ($LASTEXITCODE -ne 0) {
        Write-Host "`n安装失败，请检查发行版名称是否正确。" -ForegroundColor Red
        Pause-And-Return
        return
    }

    Write-Host "`n安装成功！正在导出为母版..." -ForegroundColor Green

    # 确保母版仓库目录存在
    $repositoriesPath = Join-Path (Get-WSLRoot) "Repositories\$distroName"
    Ensure-Directory $repositoriesPath

    # 导出为母版 tar 文件
    wsl --export $distroName (Join-Path $repositoriesPath "base.tar")

    if ($LASTEXITCODE -ne 0) {
        Write-Host "`n导出母版失败，正在清理残留实例..." -ForegroundColor Yellow
        wsl --unregister $distroName 2>&1 | Out-Null
        Write-Host "安装失败，已清理。" -ForegroundColor Red
        Pause-And-Return
        return
    }

    Write-Host "`n母版已保存至: $repositoriesPath\base.tar" -ForegroundColor Green

    # 注销默认实例
    Write-Host "`n正在注销默认实例..." -ForegroundColor Cyan
    wsl --unregister $distroName 2>&1 | Out-String | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "注销默认实例失败，请手动处理。" -ForegroundColor Red
        Pause-And-Return
        return
    }

    # 提示用户输入新实例名称（循环重试，防止名称冲突导致已注销的实例无法恢复）
    Write-Host ""
    do {
        $instanceName = Read-Host "请输入新实例名称（默认: $distroName，直接回车使用默认）"
        if ([string]::IsNullOrWhiteSpace($instanceName)) {
            $instanceName = $distroName
        }

        # 检查实例名是否已存在
        $existingInstances = ((wsl -l -q 2>&1 | Out-String) -replace '\0', '') -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
        if ($instanceName -in $existingInstances) {
            Write-Host "实例名 '$instanceName' 已存在，请选择其他名称。" -ForegroundColor Yellow
            $instanceName = $null  # 触发循环重试
        }
    } while ([string]::IsNullOrWhiteSpace($instanceName))

    # 确保实例目录存在
    $instancesPath = Join-Path (Get-WSLRoot) "Instances\$instanceName"
    Ensure-Directory $instancesPath

    $config = Get-WSLConfig
    $version = $config.DefaultWSLVersion

    Write-Host "`n正在导入实例 '$instanceName'..." -ForegroundColor Cyan
    wsl --import $instanceName $instancesPath (Join-Path $repositoriesPath "base.tar") --version $version

    if ($LASTEXITCODE -ne 0) {
        Write-Host "`n导入失败，尝试从母版恢复..." -ForegroundColor Yellow
        wsl --import $instanceName $instancesPath (Join-Path $repositoriesPath "base.tar") --version $version
        if ($LASTEXITCODE -ne 0) {
            Write-Host "恢复失败，请手动处理。母版文件保存在: $(Join-Path $repositoriesPath "base.tar")" -ForegroundColor Red
        } else {
            Write-Host "`n发行版 '$instanceName' 恢复成功！" -ForegroundColor Green
        }
    } else {
        Write-Host "`n发行版 '$instanceName' 创建成功！" -ForegroundColor Green
    }

    Pause-And-Return
}

<#
.SYNOPSIS
    从本地母版仓库创建新实例
.DESCRIPTION
    扫描 Repositories 目录，用户选择母版后创建新实例
#>
function New-WSLInstanceFromRepo {
    Clear-Host
    Write-Host ""
    Write-Host "正在扫描本地母版仓库..." -ForegroundColor Cyan

    $repositoriesPath = Join-Path (Get-WSLRoot) "Repositories"

    if (-not (Test-Path $repositoriesPath)) {
        Write-Host "`n母版仓库目录不存在，请先添加母版。" -ForegroundColor Yellow
        Pause-And-Return
        return
    }

    # 扫描包含 base.tar 的目录
    $availableDistros = @()
    Get-ChildItem -LiteralPath $repositoriesPath -Directory | ForEach-Object {
        $tarPath = Join-Path $_.FullName "base.tar"
        if (Test-Path $tarPath) {
            $availableDistros += [PSCustomObject]@{
                Name  = $_.Name
                Path  = $_.FullName
                Tar   = $tarPath
            }
        }
    }

    if ($availableDistros.Count -eq 0) {
        Write-Host "`n母版仓库中没有可用的母版文件。" -ForegroundColor Yellow
        Pause-And-Return
        return
    }

    Write-Host "`n可用的母版列表：" -ForegroundColor Cyan
    for ($i = 0; $i -lt $availableDistros.Count; $i++) {
        $size = (Get-Item $availableDistros[$i].Tar).Length
        $sizeStr = Format-FileSize $size
        Write-Host "  [$($i + 1)] $($availableDistros[$i].Name)  ($sizeStr)"
    }

    Write-Host ""
    $choice = Read-Host "请选择母版编号"

    if (-not ($choice -match '^\d+$') -or [int]$choice -lt 1 -or [int]$choice -gt $availableDistros.Count) {
        Write-Host "`n无效选择。" -ForegroundColor Yellow
        Pause-And-Return
        return
    }

    $selected = $availableDistros[[int]$choice - 1]
    Write-Host "`n已选择母版: $($selected.Name)" -ForegroundColor Green

    # 自动生成默认实例名
    $dateStr = Get-Date -Format "yyyyMMdd"
    $defaultName = "$($selected.Name)_$dateStr"

    Write-Host ""
    do {
        $instanceName = Read-Host "请输入新实例名称（默认: $defaultName）"
        if ([string]::IsNullOrWhiteSpace($instanceName)) {
            $instanceName = $defaultName
        }

        # 检查实例名是否已存在
        $existingInstances = ((wsl -l -q 2>&1 | Out-String) -replace '\0', '') -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
        if ($instanceName -in $existingInstances) {
            Write-Host "实例名 '$instanceName' 已存在，请选择其他名称。" -ForegroundColor Yellow
            $instanceName = $null
        }
    } while ([string]::IsNullOrWhiteSpace($instanceName))

    # 确保实例目录存在
    $instancesPath = Join-Path (Get-WSLRoot) "Instances\$instanceName"
    Ensure-Directory $instancesPath

    $config = Get-WSLConfig
    $version = $config.DefaultWSLVersion

    Write-Host "`n正在导入实例 '$instanceName'..." -ForegroundColor Cyan
    wsl --import $instanceName $instancesPath $selected.Tar --version $version

    if ($LASTEXITCODE -ne 0) {
        Write-Host "`n导入实例失败。" -ForegroundColor Red
    } else {
        Write-Host "`n发行版 '$instanceName' 创建成功！" -ForegroundColor Green
    }

    Pause-And-Return
}

<#
.SYNOPSIS
    从自定义 .tar 文件导入发行版
.DESCRIPTION
    用户指定 .tar 路径，复制到母版仓库后创建实例
#>
function New-WSLInstanceFromTar {
    Clear-Host
    Write-Host ""
    Write-Host "从自定义 .tar 文件导入" -ForegroundColor Cyan

    $tarPath = Read-Host "请输入 .tar 文件的完整路径"

    if ([string]::IsNullOrWhiteSpace($tarPath)) {
        Write-Host "`n路径不能为空。" -ForegroundColor Yellow
        Pause-And-Return
        return
    }

    if (-not (Test-Path $tarPath)) {
        Write-Host "`n文件不存在: $tarPath" -ForegroundColor Red
        Pause-And-Return
        return
    }

    # 自动提取文件名（不含扩展名）作为发行版名称
    $distroName = [System.IO.Path]::GetFileNameWithoutExtension($tarPath)
    Write-Host "`n将使用名称: $distroName" -ForegroundColor Cyan

    # 复制 .tar 到母版仓库
    $repositoriesPath = Join-Path (Get-WSLRoot) "Repositories\$distroName"
    Ensure-Directory $repositoriesPath
    $destTar = Join-Path $repositoriesPath "base.tar"

    Write-Host "`n正在复制母版文件..." -ForegroundColor Cyan
    Copy-Item -Path $tarPath -Destination $destTar -Force
    Write-Host "母版已保存至: $destTar" -ForegroundColor Green

    # 后续流程同来源二
    Write-Host ""
    $dateStr = Get-Date -Format "yyyyMMdd"
    $defaultName = "$distroName`_$dateStr"

    do {
        $instanceName = Read-Host "请输入新实例名称（默认: $defaultName）"
        if ([string]::IsNullOrWhiteSpace($instanceName)) {
            $instanceName = $defaultName
        }

        # 检查实例名是否已存在
        $existingInstances = ((wsl -l -q 2>&1 | Out-String) -replace '\0', '') -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
        if ($instanceName -in $existingInstances) {
            Write-Host "实例名 '$instanceName' 已存在，请选择其他名称。" -ForegroundColor Yellow
            $instanceName = $null
        }
    } while ([string]::IsNullOrWhiteSpace($instanceName))

    # 确保实例目录存在
    $instancesPath = Join-Path (Get-WSLRoot) "Instances\$instanceName"
    Ensure-Directory $instancesPath

    $config = Get-WSLConfig
    $version = $config.DefaultWSLVersion

    Write-Host "`n正在导入实例 '$instanceName'..." -ForegroundColor Cyan
    wsl --import $instanceName $instancesPath $destTar --version $version

    if ($LASTEXITCODE -ne 0) {
        Write-Host "`n导入实例失败。" -ForegroundColor Red
    } else {
        Write-Host "`n发行版 '$instanceName' 创建成功！" -ForegroundColor Green
    }

    Pause-And-Return
}

<#
.SYNOPSIS
    备份 WSL 发行版
.DESCRIPTION
    用户选择实例后，导出为 .tar 文件存入 Backups 目录，支持自动清理旧备份
#>
function Backup-WSLInstance {
    Clear-Host
    Write-Host ""
    Write-Host "正在获取已安装的发行版列表..." -ForegroundColor Cyan

    # 获取所有已安装实例
    $instances = ((wsl -l -q 2>&1 | Out-String) -replace '\0', '') -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }

    if ($instances.Count -eq 0) {
        Write-Host "`n没有发现已安装的 WSL 发行版。" -ForegroundColor Yellow
        Pause-And-Return
        return
    }

    Write-Host "`n已安装的发行版：" -ForegroundColor Cyan
    for ($i = 0; $i -lt $instances.Count; $i++) {
        Write-Host "  [$($i + 1)] $($instances[$i])"
    }

    Write-Host ""
    $choice = Read-Host "请选择要备份的实例编号"

    if (-not ($choice -match '^\d+$') -or [int]$choice -lt 1 -or [int]$choice -gt $instances.Count) {
        Write-Host "`n无效选择。" -ForegroundColor Yellow
        Pause-And-Return
        return
    }

    $selectedInstance = $instances[[int]$choice - 1]
    Write-Host "`n正在备份实例 '$selectedInstance'..." -ForegroundColor Cyan

    # 生成备份文件名和时间戳
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $backupDir = Join-Path (Get-WSLRoot) "Backups\$selectedInstance"
    Ensure-Directory $backupDir
    $backupFile = Join-Path $backupDir "full_${timestamp}.tar"

    # 备份前检查备份目录所在驱动器的磁盘空间
    $backupRoot = Join-Path (Get-WSLRoot) "Backups"
    $driveName = [System.IO.Path]::GetPathRoot($backupRoot)
    $driveInfo = Get-PSDrive -Name $driveName.TrimEnd(':\')
    $freeSpace = $driveInfo.Free / 1GB
    if ($freeSpace -lt 5) {
        Write-Host "`n警告：磁盘可用空间不足 5GB（当前约 $([math]::Round($freeSpace, 2))GB），备份可能失败。" -ForegroundColor Yellow
        $confirm = Read-Host "是否继续备份？(y/n)"
        if ($confirm -ne 'y' -and $confirm -ne 'Y') {
            Write-Host "`n已取消备份。" -ForegroundColor Yellow
            Pause-And-Return
            return
        }
    }

    # 执行备份
    wsl --export $selectedInstance $backupFile

    if ($LASTEXITCODE -ne 0) {
        Write-Host "`n备份失败。" -ForegroundColor Red
        # 清理可能产生的空文件
        if (Test-Path $backupFile) { Remove-Item $backupFile -Force }
        Pause-And-Return
        return
    }

    # 显示备份文件大小
    $backupSize = (Get-Item $backupFile).Length
    Write-Host "`n备份成功！" -ForegroundColor Green
    Write-Host "文件路径: $backupFile" -ForegroundColor Cyan
    Write-Host "文件大小: $(Format-FileSize $backupSize)" -ForegroundColor Cyan

    # 自动清理旧备份
    $config = Get-WSLConfig
    $retentionCount = $config.BackupRetentionCount

    if ($retentionCount -gt 0) {
        $allBackups = Get-ChildItem -Path $backupDir -Filter "*.tar" | Sort-Object Name -Descending
        if ($allBackups.Count -gt $retentionCount) {
            $toDelete = $allBackups | Select-Object -Skip $retentionCount
            foreach ($oldBackup in $toDelete) {
                Remove-Item $oldBackup.FullName -Force
                Write-Host "已清理旧备份: $($oldBackup.Name)" -ForegroundColor Gray
            }
        }
    }

    Pause-And-Return
}

<#
.SYNOPSIS
    还原 WSL 发行版
.DESCRIPTION
    扫描所有备份文件，用户选择后按指定方式还原
#>
function Restore-WSLInstance {
    Clear-Host
    Write-Host ""
    Write-Host "正在扫描备份文件..." -ForegroundColor Cyan

    $backupsPath = Join-Path (Get-WSLRoot) "Backups"

    if (-not (Test-Path $backupsPath)) {
        Write-Host "`n备份目录不存在。" -ForegroundColor Yellow
        Pause-And-Return
        return
    }

    # 收集所有备份文件
    $allBackups = @()

    Get-ChildItem -LiteralPath $backupsPath -Directory | ForEach-Object {
        $instanceName = $_.Name
        $backups = Get-ChildItem -LiteralPath $_.FullName -Filter "*.tar"
        foreach ($backup in $backups) {
            $size = $backup.Length
            $allBackups += [PSCustomObject]@{
                InstanceName = $instanceName
                FileName     = $backup.Name
                Path         = $backup.FullName
                Size         = $size
                Time         = $backup.LastWriteTime
            }
        }
    }

    if ($allBackups.Count -eq 0) {
        Write-Host "`n没有找到任何备份文件。" -ForegroundColor Yellow
        Pause-And-Return
        return
    }

    # 按时间降序排列，最新备份优先显示
    # 使用 @() 强制转为数组：Sort-Object 在只有1个元素时会将数组解包为单个 PSCustomObject，
    # 导致 .Count 变为 $null，for 循环无法遍历、索引访问失败。
    $allBackups = @($allBackups | Sort-Object -Property Time -Descending)

    Write-Host "`n可用的备份文件：" -ForegroundColor Cyan
    for ($i = 0; $i -lt $allBackups.Count; $i++) {
        Write-Host "  [$($i + 1)] $($allBackups[$i].InstanceName) - $($allBackups[$i].FileName) - $(Format-FileSize $allBackups[$i].Size)"
    }

    Write-Host ""
    $choice = Read-Host "请选择要还原的备份编号"

    if (-not ($choice -match '^\d+$') -or [int]$choice -lt 1 -or [int]$choice -gt $allBackups.Count) {
        Write-Host "`n无效选择。" -ForegroundColor Yellow
        Pause-And-Return
        return
    }

    $selected = $allBackups[[int]$choice - 1]
    Write-Host "`n已选择: $($selected.InstanceName) - $($selected.FileName)" -ForegroundColor Green

    # 询问还原方式
    Write-Host ""
    Write-Host "请选择还原方式：" -ForegroundColor Cyan
    Write-Host "  1. 覆盖原实例（先注销再导入）"
    Write-Host "  2. 创建新实例"
    $restoreChoice = Read-Host "请输入选项 (1-2)"

    if ($restoreChoice -eq "1") {
        # 覆盖原实例
        $targetInstance = $selected.InstanceName

        Write-Host "`n正在停止实例 '$targetInstance'..." -ForegroundColor Cyan
        wsl -t $targetInstance 2>&1 | Out-Null
        Start-Sleep -Seconds 1

        Write-Host "正在注销原实例 '$targetInstance'..." -ForegroundColor Cyan
        wsl --unregister $targetInstance 2>&1 | Out-String | ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -ne 0) {
            Write-Host "注销原实例失败，无法继续还原。" -ForegroundColor Red
            Pause-And-Return
            return
        }

        # 重新创建实例目录
        $instancesPath = Join-Path (Get-WSLRoot) "Instances\$targetInstance"
        Ensure-Directory $instancesPath

        $config = Get-WSLConfig
        $version = $config.DefaultWSLVersion

        Write-Host "`n正在从备份还原 '$targetInstance'..." -ForegroundColor Cyan
        wsl --import $targetInstance $instancesPath $selected.Path --version $version

        if ($LASTEXITCODE -ne 0) {
            Write-Host "`n还原失败。" -ForegroundColor Red
        } else {
            Write-Host "`n还原成功！实例 '$targetInstance' 已从备份恢复。" -ForegroundColor Green
        }

    } elseif ($restoreChoice -eq "2") {
        # 创建新实例
        $newInstanceName = Read-Host "请输入新实例名称"

        if ([string]::IsNullOrWhiteSpace($newInstanceName)) {
            Write-Host "`n实例名称不能为空。" -ForegroundColor Yellow
            Pause-And-Return
            return
        }

        # 检查实例名是否已存在
        $existingInstances = ((wsl -l -q 2>&1 | Out-String) -replace '\0', '') -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
        if ($newInstanceName -in $existingInstances) {
            Write-Host "`n实例名 '$newInstanceName' 已存在，请选择其他名称。" -ForegroundColor Red
            Pause-And-Return
            return
        }

        $instancesPath = Join-Path (Get-WSLRoot) "Instances\$newInstanceName"
        Ensure-Directory $instancesPath

        $config = Get-WSLConfig
        $version = $config.DefaultWSLVersion

        Write-Host "`n正在导入新实例 '$newInstanceName'..." -ForegroundColor Cyan
        wsl --import $newInstanceName $instancesPath $selected.Path --version $version

        if ($LASTEXITCODE -ne 0) {
            Write-Host "`n导入失败。" -ForegroundColor Red
        } else {
            Write-Host "`n还原成功！新实例 '$newInstanceName' 已从备份创建。" -ForegroundColor Green
        }
    } else {
        Write-Host "`n无效选项。" -ForegroundColor Yellow
    }

    Pause-And-Return
}

<#
.SYNOPSIS
    删除 WSL 发行版
.DESCRIPTION
    提供四级清理选项，包含二次确认机制防止误删
#>
function Remove-WSLInstance {
    Clear-Host
    Write-Host ""
    Write-Host "删除发行版" -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red
    Write-Host "  警告：此操作不可恢复！" -ForegroundColor Red

    # 获取所有已安装实例
    Write-Host "`n正在获取已安装的发行版列表..." -ForegroundColor Cyan
    $instances = ((wsl -l -q 2>&1 | Out-String) -replace '\0', '') -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }

    if ($instances.Count -eq 0) {
        Write-Host "`n没有发现已安装的 WSL 发行版。" -ForegroundColor Yellow
        Pause-And-Return
        return
    }

    Write-Host "`n已安装的发行版：" -ForegroundColor Cyan
    for ($i = 0; $i -lt $instances.Count; $i++) {
        Write-Host "  [$($i + 1)] $($instances[$i])"
    }

    Write-Host ""
    $choice = Read-Host "请选择要删除的实例编号"

    if (-not ($choice -match '^\d+$') -or [int]$choice -lt 1 -or [int]$choice -gt $instances.Count) {
        Write-Host "`n无效选择。" -ForegroundColor Yellow
        Pause-And-Return
        return
    }

    $targetInstance = $instances[[int]$choice - 1]
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Red
    Write-Host "  即将删除实例: $targetInstance" -ForegroundColor Red
    Write-Host "  此操作将永久删除该实例及其数据！" -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red

    # 二次确认：输入完整实例名称
    $confirmName = Read-Host "请输入实例完整名称以确认删除"

    if ($confirmName -ne $targetInstance) {
        Write-Host "`n名称不匹配，操作已取消。" -ForegroundColor Yellow
        Pause-And-Return
        return
    }

    # 显示清理选项
    Write-Host ""
    Write-Host "请选择清理级别：" -ForegroundColor Cyan
    Write-Host "  1. 仅注销 WSL 实例（保留备份和母版）"
    Write-Host "  2. 注销 + 删除备份"
    Write-Host "  3. 注销 + 删除备份 + 删除母版"
    Write-Host "  4. 全量清理（删除所有相关文件）"
    $cleanupChoice = Read-Host "请输入选项 (1-4)"

    $wslRoot = Get-WSLRoot
    $success = $true

    # 步骤 1：先停止实例，再注销（所有选项都执行）
    Write-Host "`n[1/4] 正在停止实例 '$targetInstance'..." -ForegroundColor Cyan
    wsl -t $targetInstance 2>&1 | Out-Null
    Start-Sleep -Seconds 1

    Write-Host "[1/4] 正在注销 WSL 实例 '$targetInstance'..." -ForegroundColor Cyan
    wsl --unregister $targetInstance 2>&1 | Out-String | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  注销实例失败，停止后续清理操作。" -ForegroundColor Red
        Write-Host "  请手动检查实例状态。" -ForegroundColor Yellow
        Pause-And-Return
        return
    } else {
        Write-Host "  实例已注销。" -ForegroundColor Green
    }

    # 步骤 2：删除备份（选项 2, 3, 4）
    if ($cleanupChoice -in "2", "3", "4") {
        $backupDir = Join-Path $wslRoot "Backups\$targetInstance"
        if (Test-Path $backupDir) {
            Write-Host "`n[2/4] 正在删除备份目录: $backupDir" -ForegroundColor Cyan
            Remove-Item $backupDir -Recurse -Force -ErrorAction SilentlyContinue
            if ($?) {
                Write-Host "  备份目录已删除。" -ForegroundColor Green
            } else {
                Write-Host "  删除备份目录失败。" -ForegroundColor Red
                $success = $false
            }
        } else {
            Write-Host "`n[2/4] 备份目录不存在，跳过。" -ForegroundColor Gray
        }
    }

    # 步骤 3：删除母版（选项 3, 4）
    if ($cleanupChoice -in "3", "4") {
        # 扫描 Repositories 下所有子目录，模糊匹配实例名对应的母版
        $repoCandidates = Get-ChildItem -LiteralPath (Join-Path $wslRoot "Repositories") -Directory -ErrorAction SilentlyContinue |
            Where-Object { $targetInstance -like "$($_.Name)*" -or $_.Name -like "$targetInstance*" }

        if ($repoCandidates.Count -eq 0) {
            Write-Host "`n[3/4] 未找到匹配的母版，跳过。" -ForegroundColor Gray
        } elseif ($repoCandidates.Count -eq 1) {
            $repoDir = $repoCandidates[0].FullName
            Write-Host "`n[3/4] 正在删除母版目录: $repoDir" -ForegroundColor Cyan
            Remove-Item $repoDir -Recurse -Force -ErrorAction SilentlyContinue
            if ($?) {
                Write-Host "  母版目录已删除。" -ForegroundColor Green
            } else {
                Write-Host "  删除母版目录失败。" -ForegroundColor Red
                $success = $false
            }
        } else {
            Write-Host "`n[3/4] 找到多个匹配的母版：" -ForegroundColor Yellow
            for ($j = 0; $j -lt $repoCandidates.Count; $j++) {
                Write-Host "  [$($j + 1)] $($repoCandidates[$j].Name)"
            }
            Write-Host "  [0] 跳过"
            $repoChoice = Read-Host "请选择要删除的母版编号"
            if ($repoChoice -match '^\d+$' -and [int]$repoChoice -ge 1 -and [int]$repoChoice -le $repoCandidates.Count) {
                $repoDir = $repoCandidates[[int]$repoChoice - 1].FullName
                Write-Host "正在删除母版目录: $repoDir" -ForegroundColor Cyan
                Remove-Item $repoDir -Recurse -Force -ErrorAction SilentlyContinue
                if ($?) {
                    Write-Host "  母版目录已删除。" -ForegroundColor Green
                } else {
                    Write-Host "  删除母版目录失败。" -ForegroundColor Red
                    $success = $false
                }
            } else {
                Write-Host "  已跳过母版删除。" -ForegroundColor Gray
            }
        }
    }

    # 步骤 4：删除实例目录（仅选项 4）
    if ($cleanupChoice -eq "4") {
        $instanceDir = Join-Path $wslRoot "Instances\$targetInstance"
        if (Test-Path $instanceDir) {
            Write-Host "`n[4/4] 正在删除实例目录: $instanceDir" -ForegroundColor Cyan
            Remove-Item $instanceDir -Recurse -Force -ErrorAction SilentlyContinue
            if ($?) {
                Write-Host "  实例目录已删除。" -ForegroundColor Green
            } else {
                Write-Host "  删除实例目录失败。" -ForegroundColor Red
                $success = $false
            }
        } else {
            Write-Host "`n[4/4] 实例目录不存在，跳过。" -ForegroundColor Gray
        }
    }

    if ($success) {
        Write-Host "`n实例 '$targetInstance' 删除完成。" -ForegroundColor Green
    } else {
        Write-Host "`n部分操作失败，请检查上述日志。" -ForegroundColor Yellow
    }

    Pause-And-Return
}

# ========== 6. 辅助工具函数 ==========

<#
.SYNOPSIS
    格式化文件大小为人类可读字符串
.PARAMETER bytes
    字节数
#>
function Format-FileSize {
    param([long]$bytes)
    if ($bytes -ge 1GB) {
        return "{0:N2} GB" -f ($bytes / 1GB)
    } elseif ($bytes -ge 1MB) {
        return "{0:N2} MB" -f ($bytes / 1MB)
    } elseif ($bytes -ge 1KB) {
        return "{0:N2} KB" -f ($bytes / 1KB)
    } else {
        return "$bytes B"
    }
}

<#
.SYNOPSIS
    暂停并返回主菜单
#>
function Pause-And-Return {
    Write-Host ""
    Write-Host "按任意键返回主菜单..." -ForegroundColor Gray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

# ========== 7. 模块导出 ==========
Export-ModuleMember -Function Show-Menu

# ========== 8. 启动时初始化 ==========
# 自动创建必要目录结构
$wslRoot = Get-WSLRoot
Ensure-Directory (Join-Path $wslRoot "Repositories")
Ensure-Directory (Join-Path $wslRoot "Instances")
Ensure-Directory (Join-Path $wslRoot "Backups")
Ensure-Directory (Join-Path $wslRoot "Config")
