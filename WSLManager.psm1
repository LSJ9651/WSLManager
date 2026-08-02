# WSLManager.psm1
# WSL 发行版管理工具核心模块
# 提供新增、备份、还原、删除 WSL 发行版的完整功能
# 兼容 PowerShell 5.1（Windows 10/11 默认版本）

# ========== 1. 编码设置 ==========
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# ========== 2. 全局变量定义 ==========
$script:Config = $null
$script:RootPath = Split-Path -Parent $PSScriptRoot
$script:ConfigPath = Join-Path $script:RootPath "Config\config.json"

# 颜色常量，统一使用 ANSI 颜色码，确保 PowerShell 5.1 兼容
$script:ColorCyan    = "`e[96m"
$script:ColorYellow  = "`e[33m"
$script:ColorRed     = "`e[91m"
$script:ColorGreen   = "`e[92m"
$script:ColorBold    = "`e[1m"
$script:ColorReset   = "`e[0m"

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

    # 若配置文件不存在，自动创建默认配置
    if (-not (Test-Path $script:ConfigPath)) {
        Initialize-WSLConfig
    }

    try {
        $content = Get-Content $script:ConfigPath -Raw -Encoding UTF8
        $script:Config = $content | ConvertFrom-Json
    }
    catch {
        Write-Warning "配置文件读取失败，将使用默认配置"
        $script:Config = [PSCustomObject]@{
            WSLRoot              = ""
            DefaultWSLVersion    = 2
            AutoCleanTempDays    = 3
            BackupRetentionCount = 5
        }
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
    $configDir = Join-Path $script:RootPath "Config"
    Ensure-Directory $configDir

    $defaultConfig = @{
        WSLRoot              = ""
        DefaultWSLVersion    = 2
        AutoCleanTempDays    = 3
        BackupRetentionCount = 5
    }

    $defaultConfig | ConvertTo-Json -Depth 3 | Out-File -FilePath $script:ConfigPath -Encoding UTF8
}

# ========== 4. 路径管理函数 ==========

<#
.SYNOPSIS
    获取 WSL 根目录路径
.DESCRIPTION
    优先使用 config.json 中 WSLRoot 字段，否则自动使用脚本所在目录
#>
function Get-WSLRoot {
    $config = Get-WSLConfig
    $wslRoot = $config.WSLRoot

    # 若配置了 WSLRoot 且路径有效，则使用配置路径
    if (-not [string]::IsNullOrWhiteSpace($wslRoot) -and (Test-Path $wslRoot)) {
        return $wslRoot
    }

    # 默认回退到脚本所在目录（确保完全可移植）
    return $script:RootPath
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
    获取所有子目录路径
.PARAMETER basePath
    基础目录路径
#>
function Get-SubDirectories {
    param([string]$basePath)
    if (Test-Path $basePath) {
        Get-ChildItem -Path $basePath -Directory | ForEach-Object { $_.FullName }
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
        Write-Host ("========================================" -f $script:ColorCyan)
        Write-Host ("    WSL 发行版管理工具 v1.0" -f $script:ColorCyan)
        Write-Host ("========================================" -f $script:ColorCyan)
        Write-Host "  1. 列出所有已安装的发行版"
        Write-Host "  2. 新增发行版"
        Write-Host "  3. 备份发行版"
        Write-Host "  4. 还原发行版"
        Write-Host "  5. 删除发行版"
        Write-Host "  6. 退出"
        Write-Host ("========================================" -f $script:ColorCyan)

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
                Start-Sleep -Seconds 1
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
    Write-Host ("新增发行版" -f $script:ColorCyan)
    Write-Host ("========================================" -f $script:ColorCyan)
    Write-Host "  1. 从微软官方在线商店下载"
    Write-Host "  2. 从本地母版仓库创建"
    Write-Host "  3. 从自定义 .tar 文件导入"
    Write-Host "  0. 返回主菜单"
    Write-Host ("========================================" -f $script:ColorCyan)

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
    从微软官方商店安装发行版
.DESCRIPTION
    列出可安装的发行版，用户选择后安装、导出为母版、注销并重新导入
#>
function New-WSLInstanceFromStore {
    Clear-Host
    Write-Host ""
    Write-Host "正在获取可安装的发行版列表..." -ForegroundColor Cyan
    Write-Host ""

    # 获取可安装发行版列表
    $distroList = wsl -l -o 2>&1
    Write-Host $distroList

    Write-Host ""
    $distroName = Read-Host "请输入要安装的发行版名称"

    if ([string]::IsNullOrWhiteSpace($distroName)) {
        Write-Host "`n发行版名称不能为空。" -ForegroundColor Yellow
        Pause-And-Return
        return
    }

    Write-Host "`n正在安装 '$distroName'，请稍候..." -ForegroundColor Cyan

    # 安装发行版到系统默认位置
    wsl --install -d $distroName 2>&1 | Out-String | ForEach-Object { Write-Host $_ }

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
    wsl --export $distroName (Join-Path $repositoriesPath "base.tar") 2>&1 | Out-String | ForEach-Object { Write-Host $_ }

    if ($LASTEXITCODE -ne 0) {
        Write-Host "`n导出母版失败。" -ForegroundColor Red
        Pause-And-Return
        return
    }

    Write-Host "`n母版已保存至: $repositoriesPath\base.tar" -ForegroundColor Green

    # 注销默认实例
    Write-Host "`n正在注销默认实例..." -ForegroundColor Cyan
    wsl --unregister $distroName 2>&1 | Out-String | ForEach-Object { Write-Host $_ }

    # 提示用户输入新实例名称
    Write-Host ""
    $instanceName = Read-Host "请输入新实例名称（默认: $distroName，直接回车使用默认）"
    if ([string]::IsNullOrWhiteSpace($instanceName)) {
        $instanceName = $distroName
    }

    # 确保实例目录存在
    $instancesPath = Join-Path (Get-WSLRoot) "Instances\$instanceName"
    Ensure-Directory $instancesPath

    $config = Get-WSLConfig
    $version = $config.DefaultWSLVersion

    Write-Host "`n正在导入实例 '$instanceName'..." -ForegroundColor Cyan
    wsl --import $instanceName $instancesPath (Join-Path $repositoriesPath "base.tar") --version $version 2>&1 | Out-String | ForEach-Object { Write-Host $_ }

    if ($LASTEXITCODE -ne 0) {
        Write-Host "`n导入实例失败。" -ForegroundColor Red
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
    Get-ChildItem -Path $repositoriesPath -Directory | ForEach-Object {
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
    $instanceName = Read-Host "请输入新实例名称（默认: $defaultName）"
    if ([string]::IsNullOrWhiteSpace($instanceName)) {
        $instanceName = $defaultName
    }

    # 确保实例目录存在
    $instancesPath = Join-Path (Get-WSLRoot) "Instances\$instanceName"
    Ensure-Directory $instancesPath

    $config = Get-WSLConfig
    $version = $config.DefaultWSLVersion

    Write-Host "`n正在导入实例 '$instanceName'..." -ForegroundColor Cyan
    wsl --import $instanceName $instancesPath $selected.Tar --version $version 2>&1 | Out-String | ForEach-Object { Write-Host $_ }

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
    $instanceName = Read-Host "请输入新实例名称（默认: $defaultName）"
    if ([string]::IsNullOrWhiteSpace($instanceName)) {
        $instanceName = $defaultName
    }

    # 确保实例目录存在
    $instancesPath = Join-Path (Get-WSLRoot) "Instances\$instanceName"
    Ensure-Directory $instancesPath

    $config = Get-WSLConfig
    $version = $config.DefaultWSLVersion

    Write-Host "`n正在导入实例 '$instanceName'..." -ForegroundColor Cyan
    wsl --import $instanceName $instancesPath $destTar --version $version 2>&1 | Out-String | ForEach-Object { Write-Host $_ }

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
    $instances = wsl -l -q 2>&1 | Where-Object { $_ -match '^[0-9a-zA-Z_-]+$' } | ForEach-Object { $_.Trim() }

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

    # 备份前检查磁盘空间
    $drive = $env:SystemDrive.Substring(0, 2)
    $freeSpace = (Get-PSDrive $drive).Free / 1GB
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
    wsl --export $selectedInstance $backupFile 2>&1 | Out-String | ForEach-Object { Write-Host $_ }

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
    $backupDirInfo = @{}

    Get-ChildItem -Path $backupsPath -Directory | ForEach-Object {
        $instanceName = $_.Name
        $backups = Get-ChildItem -Path $_.FullName -Filter "*.tar"
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

        Write-Host "`n正在注销原实例 '$targetInstance'..." -ForegroundColor Cyan
        wsl --unregister $targetInstance 2>&1 | Out-String | ForEach-Object { Write-Host $_ }

        # 重新创建实例目录
        $instancesPath = Join-Path (Get-WSLRoot) "Instances\$targetInstance"
        Ensure-Directory $instancesPath

        $config = Get-WSLConfig
        $version = $config.DefaultWSLVersion

        Write-Host "`n正在从备份还原 '$targetInstance'..." -ForegroundColor Cyan
        wsl --import $targetInstance $instancesPath $selected.Path --version $version 2>&1 | Out-String | ForEach-Object { Write-Host $_ }

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

        $instancesPath = Join-Path (Get-WSLRoot) "Instances\$newInstanceName"
        Ensure-Directory $instancesPath

        $config = Get-WSLConfig
        $version = $config.DefaultWSLVersion

        Write-Host "`n正在导入新实例 '$newInstanceName'..." -ForegroundColor Cyan
        wsl --import $newInstanceName $instancesPath $selected.Path --version $version 2>&1 | Out-String | ForEach-Object { Write-Host $_ }

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
    Write-Host ("删除发行版" -f $script:ColorRed)
    Write-Host ("========================================" -f $script:ColorRed)
    Write-Host "  警告：此操作不可恢复！" -ForegroundColor Red

    # 获取所有已安装实例
    Write-Host "`n正在获取已安装的发行版列表..." -ForegroundColor Cyan
    $instances = wsl -l -q 2>&1 | Where-Object { $_ -match '^[0-9a-zA-Z_-]+$' } | ForEach-Object { $_.Trim() }

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
    Write-Host ("========================================" -f $script:ColorRed)
    Write-Host ("  即将删除实例: $targetInstance" -f $script:ColorRed)
    Write-Host ("  此操作将永久删除该实例及其数据！" -f $script:ColorRed)
    Write-Host ("========================================" -f $script:ColorRed)

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

    # 步骤 1：注销 WSL 实例（所有选项都执行）
    Write-Host "`n[1/4] 正在注销 WSL 实例 '$targetInstance'..." -ForegroundColor Cyan
    wsl --unregister $targetInstance 2>&1 | Out-String | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  注销实例失败。" -ForegroundColor Red
        $success = $false
    } else {
        Write-Host "  实例已注销。" -ForegroundColor Green
    }

    # 步骤 2：删除备份（选项 2, 3, 4）
    if ($cleanupChoice -in "2", "3", "4") {
        $backupDir = Join-Path $wslRoot "Backups\$targetInstance"
        if (Test-Path $backupDir) {
            Write-Host "`n[2/4] 正在删除备份目录: $backupDir" -ForegroundColor Cyan
            Remove-Item $backupDir -Recurse -Force
            if ($LASTEXITCODE -eq 0) {
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
        # 根据实例名推断母版名（去掉可能的后缀）
        $repoDir = Join-Path $wslRoot "Repositories\$targetInstance"
        if (Test-Path $repoDir) {
            Write-Host "`n[3/4] 正在删除母版目录: $repoDir" -ForegroundColor Cyan
            Remove-Item $repoDir -Recurse -Force
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  母版目录已删除。" -ForegroundColor Green
            } else {
                Write-Host "  删除母版目录失败。" -ForegroundColor Red
                $success = $false
            }
        } else {
            Write-Host "`n[3/4] 母版目录不存在，跳过。" -ForegroundColor Gray
        }
    }

    # 步骤 4：删除实例目录（仅选项 4）
    if ($cleanupChoice -eq "4") {
        $instanceDir = Join-Path $wslRoot "Instances\$targetInstance"
        if (Test-Path $instanceDir) {
            Write-Host "`n[4/4] 正在删除实例目录: $instanceDir" -ForegroundColor Cyan
            Remove-Item $instanceDir -Recurse -Force
            if ($LASTEXITCODE -eq 0) {
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
    从 .tar 文件名推断发行版名称
#>
function Get-DistroNameFromTar {
    param([string]$tarPath)
    $name = [System.IO.Path]::GetFileNameWithoutExtension($tarPath)
    # 移除常见的时间戳后缀（如 _20240101）
    if ($name -match '^(.+)_\d{8}$') {
        return $matches[1]
    }
    return $name
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

<#
.SYNOPSIS
    清理过期临时文件
.PARAMETER days
    清理超过指定天数的文件
#>
function Clean-TempFiles {
    param([int]$days = 3)

    $tempPath = Join-Path (Get-WSLRoot) "Temp"
    if (-not (Test-Path $tempPath)) {
        return
    }

    $cutoffDate = (Get-Date).AddDays(-$days)
    $oldFiles = Get-ChildItem -Path $tempPath -File | Where-Object { $_.LastWriteTime -lt $cutoffDate }

    foreach ($file in $oldFiles) {
        try {
            Remove-Item $file.FullName -Force
        } catch {
            # 忽略删除失败的文件
        }
    }
}

# ========== 7. 模块导出 ==========
Export-ModuleMember -Function Show-Menu

# ========== 8. 启动时初始化 ==========
# 自动创建必要目录结构
$wslRoot = Get-WSLRoot
Ensure-Directory (Join-Path $wslRoot "Repositories")
Ensure-Directory (Join-Path $wslRoot "Instances")
Ensure-Directory (Join-Path $wslRoot "Backups")
Ensure-Directory (Join-Path $wslRoot "Temp")
Ensure-Directory (Join-Path $wslRoot "Config")

# 清理过期临时文件
$config = Get-WSLConfig
Clean-TempFiles -days $config.AutoCleanTempDays
