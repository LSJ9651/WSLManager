# WSLManager.Engine.psm1
# WSL 发行版管理工具 —— 核心引擎层（GUI 与 CLI 共用）
# 职责：参数化函数 + 日志回调 + 统一结果对象 + 按需提权执行器
# 兼容 PowerShell 5.1（Windows 10/11 默认版本），不使用 PS 7+ 特性

# ========== 1. 全局状态 ==========
# 数据统一收纳于工具目录下的 Data\ 文件夹。脚本统一收纳于 scripts\，故工具根为其上一级。
$script:RootPath = Split-Path -Parent $PSScriptRoot
$script:DefaultDataRoot = Join-Path $script:RootPath "Data"
$script:ConfigPath = Join-Path $script:DefaultDataRoot "Config\config.json"
$script:ConfigCache = $null

# ========== 2. 基础工具 ==========

<#
.SYNOPSIS 构造统一结果对象
#>
function New-EngineResult {
    param(
        [bool]$Success = $false,
        [string]$Message = "",
        $Data = $null
    )
    return [PSCustomObject]@{
        Success = $Success
        Message = $Message
        Data    = $Data
    }
}

<#
.SYNOPSIS 向日志回调发送一条日志（线程安全由调用方保证）
.PARAMETER LogCallback 脚本块，接收一个 Hashtable：@{ Message = ""; Level = "info|success|warning|error|danger" }
#>
function Write-EngineLog {
    param(
        [scriptblock]$LogCallback,
        [string]$Message,
        [string]$Level = "info"
    )
    if ($null -ne $LogCallback) {
        try {
            & $LogCallback @{ Message = $Message; Level = $Level }
        } catch {
            # 日志回调失败不应中断主流程
        }
    }
}

<#
.SYNOPSIS 检测当前进程是否具有管理员权限
#>
function Test-IsAdmin {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

<#
.SYNOPSIS 将字符串包裹为 PowerShell 单引号字面量（内部单引号转义）
#>
function ConvertTo-SingleQuoted {
    param([string]$Value)
    return "'" + ($Value -replace "'", "''") + "'"
}

<#
.SYNOPSIS 确保目录存在
#>
function Ensure-Directory {
    param([string]$Path)
    if (-not [string]::IsNullOrWhiteSpace($Path) -and -not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

<#
.SYNOPSIS 将旧布局（工具根下的数据目录）迁移进统一的 Data\ 文件夹（幂等，仅默认布局）
.DESCRIPTION 首次在 Data\ 布局下运行时调用：若 Data\Config\config.json 尚不存在，
    说明仍是旧布局（数据散落在工具根）。将 Config/Repositories/Instances/Backups
    逐一迁入 Data\（同盘 rename 瞬时，跨盘则复制）。目标统一为 DefaultDataRoot，
    符合 WSLRoot 留空（数据实际位于 Data\）的场景。任何单项失败均跳过，不阻断启动。
#>
function Invoke-DataMigration {
    $newConfig = Join-Path $script:DefaultDataRoot "Config\config.json"
    if (Test-Path -LiteralPath $newConfig) {
        return
    }
    Ensure-Directory $script:DefaultDataRoot
    foreach ($name in @("Config", "Repositories", "Instances", "Backups")) {
        $legacy = Join-Path $script:RootPath $name
        $dest   = Join-Path $script:DefaultDataRoot $name
        if ((Test-Path -LiteralPath $legacy -PathType Container) -and -not (Test-Path -LiteralPath $dest)) {
            try {
                Move-Item -LiteralPath $legacy -Destination $dest -ErrorAction Stop
            } catch {
                # 迁移失败（如目录被占用），跳过该目录，不阻断启动
            }
        }
    }
}

<#
.SYNOPSIS 格式化文件大小
#>
function Format-EngineSize {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) {
        return "{0:N2} GB" -f ($Bytes / 1GB)
    } elseif ($Bytes -ge 1MB) {
        return "{0:N2} MB" -f ($Bytes / 1MB)
    } elseif ($Bytes -ge 1KB) {
        return "{0:N2} KB" -f ($Bytes / 1KB)
    } else {
        return "$Bytes B"
    }
}

# ========== 3. 配置管理 ==========

<#
.SYNOPSIS 读取配置（带缓存与自愈）
#>
function Get-WSLConfig {
    if ($null -ne $script:ConfigCache) {
        return $script:ConfigCache
    }

    $default = @{
        WSLRoot              = ""
        DefaultWSLVersion    = 2
        BackupRetentionCount = 5
    }

    if (-not (Test-Path -LiteralPath $script:ConfigPath)) {
        # 旧布局数据仍留在工具根 → 迁移进 Data\ 后重试读取，避免丢失用户配置
        Invoke-DataMigration
        if (Test-Path -LiteralPath $script:ConfigPath) {
            $content = Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding UTF8
            $script:ConfigCache = $content | ConvertFrom-Json
            return $script:ConfigCache
        }
        $script:ConfigCache = [PSCustomObject]$default
        Set-WSLConfig -Config ([PSCustomObject]$default)
        return $script:ConfigCache
    }

    try {
        $content = Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding UTF8
        $script:ConfigCache = $content | ConvertFrom-Json
    } catch {
        $script:ConfigCache = [PSCustomObject]$default
        Set-WSLConfig -Config ([PSCustomObject]$default)
    }

    return $script:ConfigCache
}

<#
.SYNOPSIS 写回配置并立即生效
#>
function Set-WSLConfig {
    param([Parameter(Mandatory = $true)]$Config)

    # 补全缺失字段，防止旧配置缺字段
    $default = @{
        WSLRoot              = ""
        DefaultWSLVersion    = 2
        BackupRetentionCount = 5
    }
    foreach ($key in $default.Keys) {
        if ($null -eq $Config.$key) {
            $Config | Add-Member -MemberType NoteProperty -Name $key -Value $default[$key] -Force
        }
    }

    $configDir = Split-Path -Parent $script:ConfigPath
    Ensure-Directory $configDir

    $Config | ConvertTo-Json -Depth 4 | Out-File -FilePath $script:ConfigPath -Encoding UTF8
    $script:ConfigCache = $Config
    return $Config
}

<#
.SYNOPSIS 获取 WSL 数据根目录（WSLRoot 优先，回退 Data 目录）
#>
function Get-WSLRoot {
    $config = Get-WSLConfig
    $wslRoot = $config.WSLRoot

    if (-not [string]::IsNullOrWhiteSpace($wslRoot)) {
        try {
            Ensure-Directory $wslRoot
            return $wslRoot
        } catch {
            # 自定义根目录不可用则回退
        }
    }
    return $script:DefaultDataRoot
}

# ========== 4. WSL 命令封装 ==========

<#
.SYNOPSIS 获取 wsl.exe 完整路径
#>
function Get-WslExePath {
    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if ($null -ne $wsl) {
        return $wsl.Source
    }
    # 兜底：系统目录
    $sysWsl = Join-Path $env:SystemRoot "System32\wsl.exe"
    if (Test-Path -LiteralPath $sysWsl) {
        return $sysWsl
    }
    return $null
}

<#
.SYNOPSIS 探测字节流编码（wsl 输出为 UTF-16LE，普通命令为 UTF-8）
.DESCRIPTION
    优先识别 BOM；无 BOM 时通过"奇数位（高字节）大量为 0x00"特征判定 UTF-16LE。
    解决 PowerShell 5.1 把 wsl 的 UTF-16 输出按 ANSI/GBK 解码导致的中文乱码。
#>
function Detect-OutputEncoding {
    param([byte[]]$Bytes)
    if ($null -eq $Bytes -or $Bytes.Length -lt 2) {
        return [System.Text.Encoding]::UTF8
    }
    # UTF-8 BOM
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        return [System.Text.Encoding]::UTF8
    }
    # UTF-16LE BOM
    if ($Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) {
        return [System.Text.Encoding]::Unicode
    }
    # UTF-16BE BOM
    if ($Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) {
        return [System.Text.Encoding]::BigEndianUnicode
    }
    # 无 BOM：探测 UTF-16LE（奇数位高字节大量为 0x00）
    $pairs = [math]::Floor($Bytes.Length / 2)
    if ($pairs -ge 4) {
        $zeroHigh = 0
        for ($i = 1; $i -lt $Bytes.Length; $i += 2) {
            if ($Bytes[$i] -eq 0) { $zeroHigh++ }
        }
        if ($zeroHigh -gt ($pairs * 0.4)) {
            return [System.Text.Encoding]::Unicode
        }
    }
    return [System.Text.Encoding]::UTF8
}

<#
.SYNOPSIS 以正确编码执行 wsl 命令并返回输出（UTF-16 输出不乱码）
.PARAMETER Arguments wsl 参数串，如 "-l -o"、"-l -v"、"-l -q"
#>
function Get-WslRawOutput {
    param([string]$Arguments)

    $wslPath = Get-WslExePath
    if ($null -eq $wslPath) {
        return [PSCustomObject]@{ ExitCode = -1; Output = "" }
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $wslPath
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        $outMs = New-Object System.IO.MemoryStream
        $errMs = New-Object System.IO.MemoryStream
        $proc.StandardOutput.BaseStream.CopyTo($outMs)
        $proc.StandardError.BaseStream.CopyTo($errMs)
        $proc.WaitForExit()

        $outBytes = $outMs.ToArray()
        $errBytes = $errMs.ToArray()
        $enc = Detect-OutputEncoding $outBytes
        $text = $enc.GetString($outBytes)
        if ($errBytes.Length -gt 0) {
            $enc2 = Detect-OutputEncoding $errBytes
            $text += $enc2.GetString($errBytes)
        }
        return [PSCustomObject]@{ ExitCode = $proc.ExitCode; Output = $text }
    } catch {
        return [PSCustomObject]@{ ExitCode = -1; Output = "" }
    }
}

<#
.SYNOPSIS 系统状态检测：wsl.exe 是否存在、内核版本、根目录是否可写
#>
function Test-WSLAvailability {
    $wslPath = Get-WslExePath

    if ($null -eq $wslPath) {
        return New-EngineResult -Success $false -Message "未检测到 WSL（wsl.exe）。请先在 PowerShell 中运行 wsl --install 启用 WSL。" -Data @{ WslInstalled = $false }
    }

    # 获取 wsl 版本信息
    $versionText = ""
    try {
        $versionText = (& $wslPath --version 2>&1 | Out-String).Trim()
    } catch {
        $versionText = ""
    }

    $wslRoot = Get-WSLRoot
    $rootWritable = $false
    try {
        $probeFile = Join-Path $wslRoot ".wslmgr_write_test"
        [System.IO.File]::WriteAllText($probeFile, "test")
        Remove-Item -LiteralPath $probeFile -Force -ErrorAction SilentlyContinue
        $rootWritable = $true
    } catch {
        $rootWritable = $false
    }

    return New-EngineResult -Success $true -Message "WSL 可用" -Data @{
        WslInstalled = $true
        WslVersion   = $versionText
        WslRoot      = $wslRoot
        RootWritable = $rootWritable
        IsAdmin      = (Test-IsAdmin)
    }
}

<#
.SYNOPSIS 获取所有 WSL 实例（名称、状态、版本）
#>
function Get-WSLInstances {
    $r = Get-WslRawOutput "-l -v"
    if ($r.ExitCode -ne 0) {
        return @()
    }

    $lines = $r.Output -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }

    $instances = @()
    $started = $false
    foreach ($line in $lines) {
        # 跳过表头（包含 NAME / STATE / VERSION 的行）
        if (-not $started) {
            if ($line -match 'VERSION') {
                $started = $true
            }
            continue
        }

        $isDefault = $false
        $clean = $line.Trim()
        if ($clean.StartsWith('*')) {
            $isDefault = $true
            $clean = $clean.Substring(1).Trim()
        }

        if ($clean -match '^(.*)\s+(Running|Stopped|Converting|Installing|Uninstalling|Unspecified)\s+(\d+)$') {
            $instances += [PSCustomObject]@{
                Name      = $Matches[1].Trim()
                State     = $Matches[2]
                Version   = [int]$Matches[3]
                IsDefault = $isDefault
                IsRunning = ($Matches[2] -eq 'Running')
            }
        }
    }

    return @($instances)
}

<#
.SYNOPSIS 获取实例名称列表（wsl -l -q，处理 NUL 字节）
#>
function Get-WSLInstanceNames {
    $r = Get-WslRawOutput "-l -q"
    if ($r.ExitCode -ne 0) {
        return @()
    }
    $names = $r.Output -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    return @($names)
}

<#
.SYNOPSIS 获取单个实例的详细信息（状态、版本、磁盘占用）
#>
function Get-WSLInstanceDetail {
    param([string]$InstanceName)

    $instances = Get-WSLInstances
    $match = $instances | Where-Object { $_.Name -eq $InstanceName } | Select-Object -First 1

    if ($null -eq $match) {
        return New-EngineResult -Success $false -Message "实例 '$InstanceName' 不存在。" -Data $null
    }

    # 磁盘占用：优先从 WSLRoot\Instances\<name>\ext4.vhdx 读取
    $vhdxSize = 0
    $vhdxPath = ""
    $wslRoot = Get-WSLRoot
    $candidate = Join-Path $wslRoot "Instances\$InstanceName\ext4.vhdx"
    if (Test-Path -LiteralPath $candidate) {
        $vhdxSize = (Get-Item -LiteralPath $candidate).Length
        $vhdxPath = $candidate
    }

    $detail = [PSCustomObject]@{
        Name      = $match.Name
        State     = $match.State
        Version   = $match.Version
        IsRunning = $match.IsRunning
        IsDefault = $match.IsDefault
        VhdxSize  = $vhdxSize
        VhdxPath  = $vhdxPath
    }

    return New-EngineResult -Success $true -Message "" -Data $detail
}

<#
.SYNOPSIS 启动实例（打开该系统的终端窗口）
#>
function Start-WSLInstance {
    param([string]$InstanceName)

    $wslPath = Get-WslExePath
    if ($null -eq $wslPath) {
        return New-EngineResult -Success $false -Message "未检测到 WSL。"
    }

    $names = Get-WSLInstanceNames
    if ($InstanceName -notin $names) {
        return New-EngineResult -Success $false -Message "实例 '$InstanceName' 不存在。"
    }

    try {
        Start-Process -FilePath $wslPath -ArgumentList @("-d", $InstanceName)
        return New-EngineResult -Success $true -Message "已启动 '$InstanceName'（已在独立终端窗口中打开）。"
    } catch {
        return New-EngineResult -Success $false -Message "启动失败：$($_.Exception.Message)"
    }
}

<#
.SYNOPSIS 停止实例
#>
function Stop-WSLInstance {
    param([string]$InstanceName)

    $wslPath = Get-WslExePath
    if ($null -eq $wslPath) {
        return New-EngineResult -Success $false -Message "未检测到 WSL。"
    }

    & $wslPath --terminate $InstanceName 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        return New-EngineResult -Success $false -Message "停止 '$InstanceName' 失败（退出码 $LASTEXITCODE）。"
    }
    return New-EngineResult -Success $true -Message "已停止 '$InstanceName'。"
}

# ========== 5. 来源枚举 ==========

<#
.SYNOPSIS 获取微软商店可安装发行版列表（首次查询后缓存到本地，之后快速读取）
.DESCRIPTION
    缓存文件：WSLRoot\Config\store_distros_cache.json，默认 7 天有效。
    传 -ForceRefresh 可强制重新联网查询并更新缓存。
    输出使用正确编码解码（UTF-16LE），中文提示行不再乱码；
    解析只接受"名称=字母/数字/点/下划线/连字符"的行，乱码行不会被误当成发行版。
#>
function Get-WSLStoreDistros {
    param([switch]$ForceRefresh)

    $wslPath = Get-WslExePath
    if ($null -eq $wslPath) {
        return New-EngineResult -Success $false -Message "未检测到 WSL。" -Data @()
    }

    $cachePath = Join-Path (Get-WSLRoot) "Config\store_distros_cache.json"
    $cacheMaxAgeDays = 7

    # 非强制刷新时，优先读本地缓存（解决每次联网查询慢的问题）
    if (-not $ForceRefresh -and (Test-Path -LiteralPath $cachePath)) {
        try {
            $cache = Get-Content -LiteralPath $cachePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $savedAt = [datetime]$cache.SavedAt
            $cacheAge = (Get-Date) - $savedAt
            if ($cacheAge.TotalDays -lt $cacheMaxAgeDays -and $null -ne $cache.Distros -and @($cache.Distros).Count -gt 0) {
                return New-EngineResult -Success $true -Message "列表来自本地缓存（保存于 $($savedAt.ToString('yyyy-MM-dd HH:mm'))），可点刷新更新" -Data @($cache.Distros)
            }
        } catch {
            # 缓存缺失/损坏则重新查询
        }
    }

    # 执行 wsl -l -o（正确编码，解决中文乱码）
    $r = Get-WslRawOutput "-l -o"
    if ($r.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($r.Output)) {
        return New-EngineResult -Success $false -Message "获取商店列表失败（可能需要网络）。" -Data @()
    }

    $lines = $r.Output -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }

    $distros = @()
    foreach ($line in $lines) {
        # 跳过提示行与表头（正确编码后中文提示可正常匹配）
        if ($line -match '以下是可安装|NAME|FRIENDLY') {
            continue
        }
        # 严格匹配：名称 = 字母/数字/点/下划线/连字符，后跟友好名；乱码行不会匹配，天然被过滤
        if ($line -match '^([A-Za-z0-9._-]+)\s+(.+)$') {
            $distros += [PSCustomObject]@{
                Name         = $Matches[1]
                FriendlyName = $Matches[2].Trim()
            }
        }
    }

    if ($distros.Count -eq 0) {
        return New-EngineResult -Success $true -Message "商店列表为空（可能需要网络）。" -Data @()
    }

    # 保存缓存，之后打开可秒加载
    try {
        $cacheData = [PSCustomObject]@{
            SavedAt = (Get-Date).ToString("o")
            Distros = $distros
        }
        $cacheData | ConvertTo-Json -Depth 3 | Out-File -FilePath $cachePath -Encoding UTF8
    } catch {
        # 缓存写入失败不影响本次使用
    }

    return New-EngineResult -Success $true -Message "" -Data @($distros)
}

<#
.SYNOPSIS 商店在线安装前预检：系统盘空间 + 下载端点连通性（快速失败，避免长时间空转）
.DESCRIPTION
    wsl --install 会先把发行版下载并解包到系统盘默认位置（即使 WSLRoot 配置在其他盘），
    因此需检查系统盘空间；再对微软下载端点做一次 8 秒超时的连通性探测，
    网络不通时立刻给出可读提示，而不是让用户在 1-2GB 下载前空等。
#>
function Test-WSLStorePreflight {
    if ($null -eq (Get-WslExePath)) {
        return New-EngineResult -Success $false -Message "未检测到 WSL（wsl.exe）。请先启用 WSL。"
    }

    # 系统盘空间（wsl --install 的目标盘）
    $sysRoot = [System.IO.Path]::GetPathRoot($env:SystemDrive)
    $driveName = $sysRoot.TrimEnd('\').TrimEnd(':')
    $driveInfo = Get-PSDrive -Name $driveName -ErrorAction SilentlyContinue
    if ($null -ne $driveInfo) {
        $freeGB = [math]::Round($driveInfo.Free / 1GB, 1)
        if ($freeGB -lt 3) {
            return New-EngineResult -Success $false -Message "系统盘（$sysRoot）可用空间仅 $freeGB GB，不足以在线安装（约需 3 GB 以上）。请清理空间后重试，或改用「本地系统模板 / 自定义 .tar」。"
        }
    }

    # 微软下载端点连通性（HEAD 8 秒超时；收到任何 HTTP 响应即视为通路，404 也说明网络连通）
    try {
        $req = [System.Net.HttpWebRequest]::Create("https://wslstorestorage.blob.core.windows.net/wslblob/")
        $req.Method = "HEAD"
        $req.Timeout = 8000
        $resp = $req.GetResponse()
        $resp.Close()
    } catch [System.Net.WebException] {
        if ($_.Exception.Response -ne $null) {
            $_.Exception.Response.Close()
        } else {
            return New-EngineResult -Success $false -Message "无法连接微软发行版下载服务器（$($_.Exception.Message)）。请检查网络后重试，或改用「本地系统模板 / 自定义 .tar」。"
        }
    } catch {
        return New-EngineResult -Success $false -Message "无法连接微软发行版下载服务器（$($_.Exception.Message)）。请检查网络后重试，或改用「本地系统模板 / 自定义 .tar」。"
    }

    return New-EngineResult -Success $true -Message "预检通过。"
}

<#
.SYNOPSIS 扫描本地母版仓库（含 base.tar 的目录）
#>
function Get-WSLRepositories {
    $wslRoot = Get-WSLRoot
    $repositoriesPath = Join-Path $wslRoot "Repositories"

    $repos = @()
    if (Test-Path -LiteralPath $repositoriesPath) {
        Get-ChildItem -LiteralPath $repositoriesPath -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $tarPath = Join-Path $_.FullName "base.tar"
            if (Test-Path -LiteralPath $tarPath) {
                $repos += [PSCustomObject]@{
                    Name = $_.Name
                    Path = $_.FullName
                    Tar  = $tarPath
                    Size = (Get-Item -LiteralPath $tarPath).Length
                }
            }
        }
    }

    return @($repos)
}

# ========== 6. 提权执行器 ==========

<#
.SYNOPSIS 在管理员权限下执行一段脚本。
.DESCRIPTION
    若当前已是管理员，直接在当前进程执行；否则写临时 .ps1 并通过 runas 触发单次 UAC，
    脚本输出与退出码写入临时结果文件后回读。
    返回 @{ Success; ExitCode; Output; Elevated }
#>
function Invoke-ElevatedScript {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptText,
        [int]$TimeoutSeconds = 3600,
        [scriptblock]$ProgressCallback = $null,
        [string]$CancelFile = $null
    )

    $result = [PSCustomObject]@{ Success = $false; ExitCode = -1; Output = ""; Elevated = $false; TimedOut = $false; Cancelled = $false }

    # 已是管理员：当前进程直接执行（无 UAC）
    if (Test-IsAdmin) {
        $ErrorActionPreference = 'Continue'
        $out = (& ([scriptblock]::Create($ScriptText)) 2>&1 | Out-String)
        $result.ExitCode = $LASTEXITCODE
        $result.Output = $out
        $result.Success = $true
        $result.Elevated = $false
        return $result
    }

    # 非管理员：runas 提权子进程
    $guid = [guid]::NewGuid().ToString("N")
    $scriptFile = Join-Path $env:TEMP "wslmgr_$guid.ps1"
    $resultFile = Join-Path $env:TEMP "wslmgr_$guid.out.txt"

    # 取消监视器：GUI 写入取消文件后，提权进程树内 taskkill 终止自身（含正在执行的 wsl.exe）。
    # 监视器以参数接收提权脚本自身 PID；提权进程正常退出后，监视器检测到父进程消失也随之退出。
    $watchFile = $null
    $watchdogLine = ""
    if (-not [string]::IsNullOrWhiteSpace($CancelFile)) {
        $cancelQuoted = ConvertTo-SingleQuoted $CancelFile
        $watchScript = @"
param([int]`$ElePid)
`$cancelFile = $cancelQuoted
while (`$true) {
    Start-Sleep -Milliseconds 500
    if (-not (Get-Process -Id `$ElePid -ErrorAction SilentlyContinue)) { break }
    if (Test-Path -LiteralPath `$cancelFile) {
        taskkill /PID `$ElePid /T /F 2>&1 | Out-Null
        break
    }
}
"@
        $watchFile = Join-Path $env:TEMP "wslmgr_watch_$guid.ps1"
        [System.IO.File]::WriteAllText($watchFile, $watchScript, (New-Object System.Text.UTF8Encoding($true)))
        # 用占位符替换，避免路径含空格/引号破坏 PowerShell 解析；$PID 在提权进程内运行时展开
        $watchdogLine = 'Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"MYWATCH`" $PID" -WindowStyle Hidden | Out-Null'
        $watchdogLine = $watchdogLine.Replace('MYWATCH', $watchFile)
    }

    # 包装脚本：输出逐行【实时追加】到结果文件，主进程轮询回放（不再用 Out-String 一次性收集）
    $wrapped = @"
`$ErrorActionPreference = 'Continue'
$watchdogLine
& ([scriptblock]::Create(@'
$ScriptText
'@)) 2>&1 | ForEach-Object {
    `$_.ToString() | Out-File -LiteralPath '$resultFile' -Append -Encoding UTF8
}
"__EXITCODE__=`$LASTEXITCODE" | Out-File -LiteralPath '$resultFile' -Append -Encoding UTF8
"@

    try {
        [System.IO.File]::WriteAllText($scriptFile, $wrapped, (New-Object System.Text.UTF8Encoding($true)))

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "powershell.exe"
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptFile`""
        $psi.Verb = "runas"
        $psi.UseShellExecute = $true
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $psi.CreateNoWindow = $true

        $proc = [System.Diagnostics.Process]::Start($psi)
        $result.Elevated = $true

        # 等待期间轮询结果文件增量，实时回放进度（用户可看到"正在下载/正在安装"等实时输出）
        $lastPos = 0
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while (-not $proc.HasExited) {
            Start-Sleep -Milliseconds 250
            if ((Get-Date) -gt $deadline) {
                $result.TimedOut = $true
                try { $proc.Kill() } catch { }
                break
            }
            if (Test-Path -LiteralPath $resultFile) {
                try {
                    $fs = [System.IO.File]::Open($resultFile, 'Open', 'Read', 'ReadWrite')
                    $fs.Seek($lastPos, [System.IO.SeekOrigin]::Begin) | Out-Null
                    $reader = New-Object System.IO.StreamReader($fs, (New-Object System.Text.UTF8Encoding($true)))
                    $newText = $reader.ReadToEnd()
                    $lastPos = $fs.Position
                    $reader.Close()
                    if (-not [string]::IsNullOrWhiteSpace($newText) -and $null -ne $ProgressCallback) {
                        foreach ($ln in ($newText -split '\r?\n')) {
                            $ln = $ln.Trim()
                            if ($ln -ne '' -and $ln -notmatch '__EXITCODE__') {
                                & $ProgressCallback $ln
                            }
                        }
                    }
                } catch { }
            }
        }
        $proc.WaitForExit()
        $result.ExitCode = $proc.ExitCode

        if (-not [string]::IsNullOrWhiteSpace($CancelFile) -and (Test-Path -LiteralPath $CancelFile)) {
            $result.Cancelled = $true
        }
        if (Test-Path -LiteralPath $resultFile) {
            $result.Output = Get-Content -LiteralPath $resultFile -Raw -Encoding UTF8
            if ($result.Output -match '__CANCELLED__') {
                $result.Cancelled = $true
            }
            if ($result.Output -match '(?m)__EXITCODE__=(-?\d+)') {
                $result.ExitCode = [int]$Matches[1]
            }
        }
        $result.Success = $true
    } catch {
        # 用户取消 UAC 或提权失败
        $result.Success = $false
        $result.Output = "UAC 提权被取消或失败：$($_.Exception.Message)"
    } finally {
        Remove-Item -LiteralPath $scriptFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $resultFile -Force -ErrorAction SilentlyContinue
        if ($watchFile) { Remove-Item -LiteralPath $watchFile -Force -ErrorAction SilentlyContinue }
    }

    return $result
}

# ========== 7. 新增实例 ==========

<#
.SYNOPSIS 构造 wsl --import 的提权脚本（供三种来源复用）
#>
function New-ImportElevatedScript {
    param(
        [string]$InstanceName,
        [string]$InstancesPath,
        [string]$TarPath,
        [int]$Version
    )
    $name = ConvertTo-SingleQuoted $InstanceName
    $inst = ConvertTo-SingleQuoted $InstancesPath
    $tar = ConvertTo-SingleQuoted $TarPath
    return @"
`$name = $name
`$inst = $inst
`$tar = $tar
if (-not (Test-Path -LiteralPath `$inst)) { New-Item -Path `$inst -ItemType Directory -Force | Out-Null }
Write-Output ("[导入] 正在导入实例 '{0}' ..." -f `$name)
wsl.exe --import `$name `$inst `$tar --version $Version 2>&1
"@
}

<#
.SYNOPSIS 从微软商店创建实例（install -> 导出母版 -> 注销默认 -> 导入到管理目录）
#>
function New-WSLInstanceFromStore {
    param(
        [Parameter(Mandatory = $true)][string]$DistroName,
        [Parameter(Mandatory = $true)][string]$InstanceName,
        [int]$Version = 2,
        [scriptblock]$LogCallback = $null,
        [string]$CancelFile = $null
    )

    $wslPath = Get-WslExePath
    if ($null -eq $wslPath) {
        return New-EngineResult -Success $false -Message "未检测到 WSL。"
    }

    # 名称冲突检查
    $existing = Get-WSLInstanceNames
    if ($InstanceName -in $existing) {
        return New-EngineResult -Success $false -Message "实例名 '$InstanceName' 已存在，请更换名称。"
    }

    # 下载前预检：系统盘空间 + 微软下载端点连通性（快速失败，避免 1-2GB 下载前长时间空转）
    $preflight = Test-WSLStorePreflight
    if (-not $preflight.Success) {
        return $preflight
    }

    $wslRoot = Get-WSLRoot
    $repositoriesPath = Join-Path $wslRoot "Repositories\$DistroName"
    $instancesPath = Join-Path $wslRoot "Instances\$InstanceName"
    $baseTar = Join-Path $repositoriesPath "base.tar"

    # 商店安装需要管理员权限（wsl --install），走提权通道一次性完成
    $name = ConvertTo-SingleQuoted $DistroName
    $repo = ConvertTo-SingleQuoted $repositoriesPath
    $base = ConvertTo-SingleQuoted $baseTar
    $inst = ConvertTo-SingleQuoted $instancesPath
    $targetName = ConvertTo-SingleQuoted $InstanceName

    $scriptText = @"
Write-Output ("[下载] 正在从网络直连下载安装发行版 '{0}' ...（约 1-2 GB，网络慢时可能需要 5-20 分钟，请耐心等待）" -f $name)
Write-Output "[下载] 使用 --web-download 绕过微软商店直连下载，避免商店交互卡死。"
wsl.exe --install -d $name --no-launch --web-download 2>&1
if (`$LASTEXITCODE -ne 0) {
    Write-Output "__FAIL__:安装失败，请检查发行版名称是否正确、网络是否可用。"
    exit 1
}
Write-Output "[导出] 正在导出为母版模板 ..."
if (-not (Test-Path -LiteralPath $repo)) { New-Item -Path $repo -ItemType Directory -Force | Out-Null }
wsl.exe --export $name $base 2>&1
if (`$LASTEXITCODE -ne 0) {
    Write-Output "__FAIL__:导出母版失败。"
    exit 1
}
Write-Output "[注销] 正在注销商店默认安装的实例 ..."
wsl.exe --unregister $name 2>&1
if (`$LASTEXITCODE -ne 0) {
    Write-Output "__FAIL__:注销默认实例失败。"
    exit 1
}
Write-Output ("[导入] 正在导入实例 '{0}' ..." -f $targetName)
if (-not (Test-Path -LiteralPath $inst)) { New-Item -Path $inst -ItemType Directory -Force | Out-Null }
wsl.exe --import $targetName $inst $base --version $Version 2>&1
if (`$LASTEXITCODE -ne 0) {
    Write-Output "__FAIL__:导入实例失败。母版已保存在 $base"
    exit 1
}
Write-Output "__OK__:实例 '$InstanceName' 创建成功。"
"@

    Write-EngineLog $LogCallback "开始直连下载并安装 '$DistroName'（约 1-2 GB，下载阶段可能长时间无输出属正常，可点「取消操作」中止）..." "info"
    # ProgressCallback：安装过程每行输出实时回放到日志（下载/安装进度可见）
    # 超时 30 分钟（网络下载上限），超出即中止
    $exec = Invoke-ElevatedScript -ScriptText $scriptText -TimeoutSeconds 1800 -CancelFile $CancelFile -ProgressCallback {
        param($Line)
        Write-EngineLog $LogCallback $Line "info"
    }

    if ($exec.TimedOut) {
        return New-EngineResult -Success $false -Message "操作超时（超过 30 分钟），已中止。请检查网络后重试。"
    }

    if ($exec.Cancelled) {
        $r = New-EngineResult -Success $false -Message "已取消创建 '$InstanceName'。"
        $r | Add-Member -NotePropertyName Cancelled -NotePropertyValue $true
        return $r
    }

    if (-not $exec.Success) {
        return New-EngineResult -Success $false -Message $exec.Output
    }

    if ($exec.Output -match '__FAIL__:(.+)') {
        return New-EngineResult -Success $false -Message $Matches[1].Trim()
    }

    if ($exec.ExitCode -eq 0 -or $exec.Output -match '__OK__') {
        return New-EngineResult -Success $true -Message "实例 '$InstanceName' 创建成功。"
    }

    return New-EngineResult -Success $false -Message "创建实例失败（退出码 $($exec.ExitCode)）。"
}

<#
.SYNOPSIS 从本地母版仓库创建实例
#>
function New-WSLInstanceFromRepo {
    param(
        [Parameter(Mandatory = $true)][string]$RepoTarPath,
        [Parameter(Mandatory = $true)][string]$InstanceName,
        [int]$Version = 2,
        [scriptblock]$LogCallback = $null,
        [string]$CancelFile = $null
    )

    $wslPath = Get-WslExePath
    if ($null -eq $wslPath) {
        return New-EngineResult -Success $false -Message "未检测到 WSL。"
    }

    if (-not (Test-Path -LiteralPath $RepoTarPath)) {
        return New-EngineResult -Success $false -Message "母版文件不存在：$RepoTarPath"
    }

    $existing = Get-WSLInstanceNames
    if ($InstanceName -in $existing) {
        return New-EngineResult -Success $false -Message "实例名 '$InstanceName' 已存在，请更换名称。"
    }

    $wslRoot = Get-WSLRoot
    $instancesPath = Join-Path $wslRoot "Instances\$InstanceName"

    Write-EngineLog $LogCallback "正在从母版创建实例 '$InstanceName'..." "info"
    $scriptText = New-ImportElevatedScript -InstanceName $InstanceName -InstancesPath $instancesPath -TarPath $RepoTarPath -Version $Version
    $exec = Invoke-ElevatedScript -ScriptText $scriptText -CancelFile $CancelFile -ProgressCallback {
        param($Line)
        Write-EngineLog $LogCallback $Line "info"
    }

    if ($exec.TimedOut) {
        return New-EngineResult -Success $false -Message "操作超时（超过 1 小时），已中止。请检查后重试。"
    }

    if ($exec.Cancelled) {
        $r = New-EngineResult -Success $false -Message "已取消操作。"
        $r | Add-Member -NotePropertyName Cancelled -NotePropertyValue $true
        return $r
    }

    if (-not $exec.Success) {
        return New-EngineResult -Success $false -Message $exec.Output
    }
    if ($exec.ExitCode -eq 0) {
        return New-EngineResult -Success $true -Message "实例 '$InstanceName' 创建成功。"
    }
    return New-EngineResult -Success $false -Message "导入实例失败（退出码 $($exec.ExitCode)）。"
}

<#
.SYNOPSIS 从自定义 .tar 文件导入实例（先复制为母版，再导入）
#>
function New-WSLInstanceFromTar {
    param(
        [Parameter(Mandatory = $true)][string]$TarPath,
        [Parameter(Mandatory = $true)][string]$InstanceName,
        [int]$Version = 2,
        [scriptblock]$LogCallback = $null,
        [string]$CancelFile = $null
    )

    $wslPath = Get-WslExePath
    if ($null -eq $wslPath) {
        return New-EngineResult -Success $false -Message "未检测到 WSL。"
    }

    if (-not (Test-Path -LiteralPath $TarPath)) {
        return New-EngineResult -Success $false -Message "文件不存在：$TarPath"
    }

    $existing = Get-WSLInstanceNames
    if ($InstanceName -in $existing) {
        return New-EngineResult -Success $false -Message "实例名 '$InstanceName' 已存在，请更换名称。"
    }

    $distroName = [System.IO.Path]::GetFileNameWithoutExtension($TarPath)
    $wslRoot = Get-WSLRoot
    $repositoriesPath = Join-Path $wslRoot "Repositories\$distroName"
    $destTar = Join-Path $repositoriesPath "base.tar"
    $instancesPath = Join-Path $wslRoot "Instances\$InstanceName"

    Write-EngineLog $LogCallback "正在复制母版文件..." "info"
    try {
        Ensure-Directory $repositoriesPath
        Copy-Item -Path $TarPath -Destination $destTar -Force
    } catch {
        return New-EngineResult -Success $false -Message "复制母版文件失败：$($_.Exception.Message)"
    }
    Write-EngineLog $LogCallback "母版已保存至：$destTar" "success"

    Write-EngineLog $LogCallback "正在导入实例 '$InstanceName'..." "info"
    $scriptText = New-ImportElevatedScript -InstanceName $InstanceName -InstancesPath $instancesPath -TarPath $destTar -Version $Version
    $exec = Invoke-ElevatedScript -ScriptText $scriptText -CancelFile $CancelFile -ProgressCallback {
        param($Line)
        Write-EngineLog $LogCallback $Line "info"
    }

    if ($exec.TimedOut) {
        return New-EngineResult -Success $false -Message "操作超时（超过 1 小时），已中止。请检查后重试。"
    }

    if ($exec.Cancelled) {
        $r = New-EngineResult -Success $false -Message "已取消操作。"
        $r | Add-Member -NotePropertyName Cancelled -NotePropertyValue $true
        return $r
    }

    if (-not $exec.Success) {
        return New-EngineResult -Success $false -Message $exec.Output
    }
    if ($exec.ExitCode -eq 0) {
        return New-EngineResult -Success $true -Message "实例 '$InstanceName' 创建成功。"
    }
    return New-EngineResult -Success $false -Message "导入实例失败（退出码 $($exec.ExitCode)）。"
}

# ========== 8. 备份 ==========

<#
.SYNOPSIS 备份实例（导出 tar，检查磁盘空间，按保留数清理旧备份）
#>
function Backup-WSLInstance {
    param(
        [Parameter(Mandatory = $true)][string]$InstanceName,
        [scriptblock]$LogCallback = $null
    )

    $wslPath = Get-WslExePath
    if ($null -eq $wslPath) {
        return New-EngineResult -Success $false -Message "未检测到 WSL。"
    }

    $names = Get-WSLInstanceNames
    if ($InstanceName -notin $names) {
        return New-EngineResult -Success $false -Message "实例 '$InstanceName' 不存在。"
    }

    $wslRoot = Get-WSLRoot
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $backupDir = Join-Path $wslRoot "Backups\$InstanceName"
    Ensure-Directory $backupDir
    $backupFile = Join-Path $backupDir "full_${timestamp}.tar"

    # 磁盘空间检查
    $backupRoot = Join-Path $wslRoot "Backups"
    Ensure-Directory $backupRoot
    $driveName = [System.IO.Path]::GetPathRoot($backupRoot).TrimEnd('\').TrimEnd(':')
    $driveInfo = Get-PSDrive -Name $driveName -ErrorAction SilentlyContinue
    $freeSpace = if ($null -ne $driveInfo) { $driveInfo.Free / 1GB } else { 0 }

    if ($freeSpace -gt 0 -and $freeSpace -lt 5) {
        return New-EngineResult -Success $false -Message "磁盘可用空间不足 5GB（当前约 $([math]::Round($freeSpace, 2))GB），备份可能失败。" -Data @{ LowSpace = $true }
    }

    Write-EngineLog $LogCallback "正在导出实例 '$InstanceName'（约需 1-3 分钟，请耐心等待）..." "info"

    & $wslPath --export $InstanceName $backupFile 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        if (Test-Path -LiteralPath $backupFile) {
            Remove-Item -LiteralPath $backupFile -Force -ErrorAction SilentlyContinue
        }
        return New-EngineResult -Success $false -Message "备份失败（退出码 $LASTEXITCODE）。"
    }

    $backupSize = (Get-Item -LiteralPath $backupFile).Length

    # 按保留数清理旧备份
    $config = Get-WSLConfig
    $retentionCount = [int]$config.BackupRetentionCount
    if ($retentionCount -gt 0) {
        $allBackups = @(Get-ChildItem -LiteralPath $backupDir -Filter "*.tar" | Sort-Object Name -Descending)
        if ($allBackups.Count -gt $retentionCount) {
            $toDelete = $allBackups | Select-Object -Skip $retentionCount
            foreach ($old in $toDelete) {
                Remove-Item -LiteralPath $old.FullName -Force -ErrorAction SilentlyContinue
                Write-EngineLog $LogCallback "已清理旧备份：$($old.Name)" "info"
            }
        }
    }

    $result = New-EngineResult -Success $true -Message "备份成功。" -Data @{
        FilePath = $backupFile
        FileSize = $backupSize
    }
    return $result
}

<#
.SYNOPSIS 扫描所有备份文件（按时间倒序）
#>
function Get-WSLBackups {
    $wslRoot = Get-WSLRoot
    $backupsPath = Join-Path $wslRoot "Backups"

    $allBackups = @()
    if (Test-Path -LiteralPath $backupsPath) {
        Get-ChildItem -LiteralPath $backupsPath -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $instanceName = $_.Name
            Get-ChildItem -LiteralPath $_.FullName -Filter "*.tar" -ErrorAction SilentlyContinue | ForEach-Object {
                $allBackups += [PSCustomObject]@{
                    InstanceName = $instanceName
                    FileName     = $_.Name
                    Path         = $_.FullName
                    Size         = $_.Length
                    Time         = $_.LastWriteTime
                }
            }
        }
    }

    return @($allBackups | Sort-Object -Property Time -Descending)
}

# ========== 9. 还原 ==========

<#
.SYNOPSIS 还原实例（覆盖原实例或创建新实例）
#>
function Restore-WSLInstance {
    param(
        [Parameter(Mandatory = $true)][string]$BackupPath,
        [Parameter(Mandatory = $true)][string]$TargetInstanceName,
        [Parameter(Mandatory = $true)][string]$Mode,   # "overwrite" | "new"
        [int]$Version = 2,
        [scriptblock]$LogCallback = $null
    )

    $wslPath = Get-WslExePath
    if ($null -eq $wslPath) {
        return New-EngineResult -Success $false -Message "未检测到 WSL。"
    }

    if (-not (Test-Path -LiteralPath $BackupPath)) {
        return New-EngineResult -Success $false -Message "备份文件不存在：$BackupPath"
    }

    $wslRoot = Get-WSLRoot
    $existing = Get-WSLInstanceNames

    if ($Mode -eq "new") {
        # 创建新实例：名称不能冲突
        if ($TargetInstanceName -in $existing) {
            return New-EngineResult -Success $false -Message "实例名 '$TargetInstanceName' 已存在，请更换名称。"
        }
        $instancesPath = Join-Path $wslRoot "Instances\$TargetInstanceName"
        Write-EngineLog $LogCallback "正在从备份创建新实例 '$TargetInstanceName'..." "info"
        $scriptText = New-ImportElevatedScript -InstanceName $TargetInstanceName -InstancesPath $instancesPath -TarPath $BackupPath -Version $Version
        $exec = Invoke-ElevatedScript -ScriptText $scriptText -ProgressCallback {
            param($Line)
            Write-EngineLog $LogCallback $Line "info"
        }
    } else {
        # 覆盖原实例：停止 + 注销 + 重新导入
        if ($TargetInstanceName -notin $existing) {
            return New-EngineResult -Success $false -Message "实例 '$TargetInstanceName' 不存在，无法覆盖。"
        }
        $instancesPath = Join-Path $wslRoot "Instances\$TargetInstanceName"
        $name = ConvertTo-SingleQuoted $TargetInstanceName
        $inst = ConvertTo-SingleQuoted $instancesPath
        $tar = ConvertTo-SingleQuoted $BackupPath
        Write-EngineLog $LogCallback "正在覆盖还原实例 '$TargetInstanceName'..." "warning"

        $scriptText = @"
Write-Output ("[停止] 正在停止实例 '{0}' ..." -f $name)
wsl.exe -t $name 2>&1 | Out-Null
Start-Sleep -Seconds 1
Write-Output ("[注销] 正在注销原实例 '{0}' ..." -f $name)
wsl.exe --unregister $name 2>&1
if (`$LASTEXITCODE -ne 0) {
    Write-Output "__FAIL__:注销原实例失败，无法继续还原。"
    exit 1
}
Write-Output ("[导入] 正在从备份还原 '{0}' ..." -f $name)
if (-not (Test-Path -LiteralPath $inst)) { New-Item -Path $inst -ItemType Directory -Force | Out-Null }
wsl.exe --import $name $inst $tar --version $Version 2>&1
if (`$LASTEXITCODE -ne 0) {
    Write-Output "__FAIL__:还原失败。"
    exit 1
}
Write-Output "__OK__:还原成功。"
"@
        $exec = Invoke-ElevatedScript -ScriptText $scriptText -ProgressCallback {
            param($Line)
            Write-EngineLog $LogCallback $Line "info"
        }
    }

    if ($exec.TimedOut) {
        return New-EngineResult -Success $false -Message "操作超时（超过 1 小时），已中止。请检查后重试。"
    }

    if ($exec.Cancelled) {
        $r = New-EngineResult -Success $false -Message "已取消操作。"
        $r | Add-Member -NotePropertyName Cancelled -NotePropertyValue $true
        return $r
    }

    if (-not $exec.Success) {
        return New-EngineResult -Success $false -Message $exec.Output
    }
    if ($exec.Output -match '__FAIL__:(.+)') {
        return New-EngineResult -Success $false -Message $Matches[1].Trim()
    }
    if ($exec.ExitCode -eq 0 -or $exec.Output -match '__OK__') {
        if ($Mode -eq "new") {
            return New-EngineResult -Success $true -Message "新实例 '$TargetInstanceName' 已从备份创建。"
        }
        return New-EngineResult -Success $true -Message "实例 '$TargetInstanceName' 已从备份还原。"
    }
    return New-EngineResult -Success $false -Message "还原失败（退出码 $($exec.ExitCode)）。"
}

# ========== 10. 删除 ==========

<#
.SYNOPSIS 删除实例（四级清理，输入名称二次确认在 GUI 层完成）
#>
function Remove-WSLInstance {
    param(
        [Parameter(Mandatory = $true)][string]$InstanceName,
        [Parameter(Mandatory = $true)][ValidateRange(1, 4)][int]$CleanupLevel,
        [scriptblock]$LogCallback = $null
    )

    $wslPath = Get-WslExePath
    if ($null -eq $wslPath) {
        return New-EngineResult -Success $false -Message "未检测到 WSL。"
    }

    $names = Get-WSLInstanceNames
    if ($InstanceName -notin $names) {
        return New-EngineResult -Success $false -Message "实例 '$InstanceName' 不存在。"
    }

    $wslRoot = Get-WSLRoot
    $backupDir = Join-Path $wslRoot "Backups\$InstanceName"
    $instanceDir = Join-Path $wslRoot "Instances\$InstanceName"
    $repositoriesPath = Join-Path $wslRoot "Repositories"

    # 预先扫描匹配的母版目录（在普通权限下扫描，结果传给提权脚本）
    $repoDirs = @()
    if ($CleanupLevel -in 3, 4) {
        $repoDirs = @(Get-ChildItem -LiteralPath $repositoriesPath -Directory -ErrorAction SilentlyContinue |
            Where-Object { $InstanceName -like "$($_.Name)*" -or $_.Name -like "$InstanceName*" } |
            ForEach-Object { $_.FullName })
    }

    $name = ConvertTo-SingleQuoted $InstanceName
    $bk = ConvertTo-SingleQuoted $backupDir
    $idir = ConvertTo-SingleQuoted $instanceDir

    # 构造提权脚本：一次 UAC 完成 stop + unregister + 各级清理
    $scriptText = @"
Write-Output ("[1/4] 正在停止实例 '{0}' ..." -f $name)
wsl.exe -t $name 2>&1 | Out-Null
Start-Sleep -Seconds 1
Write-Output ("[1/4] 正在注销实例 '{0}' ..." -f $name)
wsl.exe --unregister $name 2>&1
if (`$LASTEXITCODE -ne 0) {
    Write-Output "__FAIL__:注销实例失败，已中止后续清理（防止产生孤立实例）。"
    exit 1
}
Write-Output "[1/4] 实例已注销。"
"@

    # 级别 2/3/4：删除备份
    if ($CleanupLevel -in 2, 3, 4) {
        $scriptText += @"

Write-Output "[2/4] 正在删除备份目录 ..."
if (Test-Path -LiteralPath $bk) {
    Remove-Item -LiteralPath $bk -Recurse -Force -ErrorAction SilentlyContinue
    if (`$?) { Write-Output "[2/4] 备份目录已删除。" } else { Write-Output "[2/4] 删除备份目录失败。" }
} else {
    Write-Output "[2/4] 备份目录不存在，跳过。"
}
"@
    }

    # 级别 3/4：删除母版
    if ($CleanupLevel -in 3, 4) {
        if ($repoDirs.Count -eq 0) {
            $scriptText += @"

Write-Output "[3/4] 未找到匹配的母版，跳过。"
"@
        } else {
            $scriptText += @"

Write-Output "[3/4] 正在删除母版目录 ..."
"@
            foreach ($rd in $repoDirs) {
                $rdq = ConvertTo-SingleQuoted $rd
                $scriptText += @"
Remove-Item -LiteralPath $rdq -Recurse -Force -ErrorAction SilentlyContinue
if (`$?) { Write-Output "[3/4] 已删除母版：$rd" } else { Write-Output "[3/4] 删除母版失败：$rd" }
"@
            }
        }
    }

    # 级别 4：删除实例目录
    if ($CleanupLevel -eq 4) {
        $scriptText += @"

Write-Output "[4/4] 正在删除实例目录 ..."
if (Test-Path -LiteralPath $idir) {
    Remove-Item -LiteralPath $idir -Recurse -Force -ErrorAction SilentlyContinue
    if (`$?) { Write-Output "[4/4] 实例目录已删除。" } else { Write-Output "[4/4] 删除实例目录失败。" }
} else {
    Write-Output "[4/4] 实例目录不存在，跳过。"
}
"@
    }

    $scriptText += @"

Write-Output "__OK__:删除完成。"
"@

    Write-EngineLog $LogCallback "正在删除实例 '$InstanceName'（清理级别 $CleanupLevel）..." "danger"
    $exec = Invoke-ElevatedScript -ScriptText $scriptText -ProgressCallback {
        param($Line)
        Write-EngineLog $LogCallback $Line "danger"
    }

    if ($exec.TimedOut) {
        return New-EngineResult -Success $false -Message "操作超时（超过 1 小时），已中止。"
    }

    if (-not $exec.Success) {
        return New-EngineResult -Success $false -Message $exec.Output
    }
    if ($exec.Output -match '__FAIL__:(.+)') {
        return New-EngineResult -Success $false -Message $Matches[1].Trim()
    }
    if ($exec.Output -match '__OK__') {
        return New-EngineResult -Success $true -Message "实例 '$InstanceName' 删除完成。"
    }
    return New-EngineResult -Success $false -Message "删除失败（退出码 $($exec.ExitCode)）。"
}

# ========== 11. 统计 ==========

<#
.SYNOPSIS 统计：总磁盘占用、母版数量、备份数量
#>
function Get-WSLStats {
    $wslRoot = Get-WSLRoot

    $totalSize = 0
    $repoCount = 0
    $backupCount = 0

    # 实例磁盘占用
    $instancesDir = Join-Path $wslRoot "Instances"
    if (Test-Path -LiteralPath $instancesDir) {
        Get-ChildItem -LiteralPath $instancesDir -Recurse -File -Filter "*.vhdx" -ErrorAction SilentlyContinue | ForEach-Object {
            $totalSize += $_.Length
        }
    }

    # 母版
    $repos = Get-WSLRepositories
    $repoCount = $repos.Count
    foreach ($r in $repos) {
        $totalSize += $r.Size
    }

    # 备份
    $backups = Get-WSLBackups
    $backupCount = $backups.Count
    foreach ($b in $backups) {
        $totalSize += $b.Size
    }

    return [PSCustomObject]@{
        TotalSize   = $totalSize
        RepoCount   = $repoCount
        BackupCount = $backupCount
        WslRoot     = $wslRoot
    }
}

# ========== 13. 初始化目录 ==========

function Initialize-WSLDirectories {
    $wslRoot = Get-WSLRoot
    Ensure-Directory (Join-Path $wslRoot "Repositories")
    Ensure-Directory (Join-Path $wslRoot "Instances")
    Ensure-Directory (Join-Path $wslRoot "Backups")
    Ensure-Directory (Join-Path $wslRoot "Config")
}

# ========== 14. 模块导出 ==========
Export-ModuleMember -Function @(
    'New-EngineResult', 'Write-EngineLog', 'Test-IsAdmin', 'ConvertTo-SingleQuoted',
    'Ensure-Directory', 'Format-EngineSize',
    'Get-WSLConfig', 'Set-WSLConfig', 'Get-WSLRoot',
    'Get-WslExePath', 'Test-WSLAvailability', 'Detect-OutputEncoding', 'Get-WslRawOutput',
    'Get-WSLInstances', 'Get-WSLInstanceNames', 'Get-WSLInstanceDetail',
    'Start-WSLInstance', 'Stop-WSLInstance',
    'Get-WSLStoreDistros', 'Get-WSLRepositories', 'Test-WSLStorePreflight',
    'Invoke-ElevatedScript', 'New-ImportElevatedScript',
    'New-WSLInstanceFromStore', 'New-WSLInstanceFromRepo', 'New-WSLInstanceFromTar',
    'Backup-WSLInstance', 'Get-WSLBackups', 'Restore-WSLInstance',
    'Remove-WSLInstance', 'Get-WSLStats', 'Initialize-WSLDirectories'
)
