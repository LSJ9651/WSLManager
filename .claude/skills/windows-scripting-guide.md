# Windows Script Writing Standards

A comprehensive guide for writing robust Windows scripts (PowerShell `.ps1`/`.psm1` and Batch `.bat`/`.cmd`), with emphasis on PowerShell 5.1 compatibility, WSL integration, and encoding safety. All rules are derived from real bugs encountered and fixed in production.

---

## 1. File Encoding & Line Endings (CRITICAL)

### 1.1 Encoding Matrix

| File Type | Encoding | Line Ending | Rationale |
|:----------|:---------|:------------|:----------|
| `.psm1` / `.ps1` | **UTF-8 with BOM** | **LF** | PS 5.1 defaults to system ANSI codepage (e.g., GBK) when BOM is absent — multi-byte UTF-8 characters get corrupted |
| `.bat` / `.cmd` | **UTF-8 with BOM** | **CRLF** | CMD parser requires CRLF; LF-only breaks command parsing |

### 1.2 Why BOM Is Non-Negotiable for PS 5.1

Without BOM, PowerShell 5.1 interprets UTF-8 files as the system's ANSI codepage. On Chinese Windows, this means GBK. A 3-byte UTF-8 Chinese character gets read as 3 separate GBK characters, shifting all subsequent bytes. The worst-case failure: `#>` (comment block terminator) becomes `?>` when one byte of a preceding Chinese character corrupts it, causing the entire rest of the script to be treated as a comment.

**Before committing any `.psm1`/`.ps1` file with non-ASCII characters, verify:**
```powershell
# Check that the parser finds no errors
$t = @(); $e = @()
[System.Management.Automation.Language.Parser]::ParseFile(".\YourFile.psm1", [ref]$t, [ref]$e)
$e | ForEach-Object { $_.Message }
```

### 1.3 BOM Verification

```bash
# Check first 3 bytes — should be EF BB BF (UTF-8 BOM)
xxd -l 3 YourFile.psm1
# Expected: 00000000: efbb bf
```

### 1.4 How to Add BOM

```bash
# Python (most reliable)
python -c "import codecs; data=open('file.psm1','rb').read().decode('utf-8-sig'); codecs.open('file.psm1','w','utf-8-sig').write(data)"
```

---

## 2. PowerShell 5.1 Compatibility

### 2.1 Forbidden Features (PS 7+ only)

- **No `??` null-coalescing operator** — use `if ($null -eq $x) { ... }`
- **No `?:` ternary operator** — use `if/else`
- **No `ForEach-Object -Parallel`**
- **No `ConvertFrom-Json -Depth` higher than default** (PS 5.1 default depth is 100, normally fine)
- **No `Join-Path -AdditionalChildPath`**

### 2.2 `Write-Host` Colors

```powershell
# CORRECT — works in PS 5.1 and PS 7+
Write-Host "Success!" -ForegroundColor Green
Write-Host "Warning" -ForegroundColor Yellow
Write-Host "Error!"  -ForegroundColor Red

# WRONG — `-f` is the format operator, NOT a color parameter
Write-Host ("text" -f $ColorRed)          # This REPLACES {0} placeholders, doesn't set color
Write-Host ("text" -f "Cyan")             # No error, but no color either — just prints "text"

# WRONG — ANSI escape sequences are unreliable in PS 5.1 legacy console
Write-Host "`e[31mError`e[0m"
```

**Coloring convention**: Cyan=info/prompts, Yellow=warnings, Red=errors/danger, Green=success, Gray=secondary info

### 2.3 `$LASTEXITCODE` vs `$?`

```powershell
# CORRECT: $LASTEXITCODE only for EXTERNAL commands (.exe like wsl.exe)
wsl --unregister $name
if ($LASTEXITCODE -ne 0) { Write-Host "Failed!" -ForegroundColor Red }

# CORRECT: $? for PowerShell CMDLETS
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $path
if ($?) { Write-Host "Deleted!" -ForegroundColor Green }

# WRONG: $LASTEXITCODE after a PowerShell cmdlet — it won't reflect Remove-Item's result
Remove-Item -Recurse -Force $path
if ($LASTEXITCODE -ne 0) { ... }  # $LASTEXITCODE is from whatever ran BEFORE Remove-Item
```

**Rule**: After ANY PowerShell cmdlet (`Remove-Item`, `Copy-Item`, `New-Item`, etc.), use `$?` to check success. After ANY `.exe` invocation (`wsl.exe`, `git.exe`, etc.), use `$LASTEXITCODE`.

### 2.4 `-ErrorAction SilentlyContinue`

Always add `-ErrorAction SilentlyContinue` to `Remove-Item -Recurse -Force` calls. Without it, permission errors or locked files will produce non-terminating errors that may still disrupt script flow depending on `$ErrorActionPreference`:

```powershell
# CORRECT
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $path
if (-not $?) { Write-Host "Warning: Could not delete $path" -ForegroundColor Yellow }

# WRONG — may crash on permission errors
Remove-Item -Recurse -Force $path
```

---

## 3. Path & Directory Handling

### 3.1 `$PSScriptRoot`

`$PSScriptRoot` is ALREADY the directory containing the current script/module. Do NOT call `Split-Path -Parent` on it:

```powershell
# CORRECT
$script:RootPath = $PSScriptRoot

# WRONG — goes one level ABOVE the script directory
$script:RootPath = Split-Path -Parent $PSScriptRoot
```

Use `Split-Path -Parent` only when you have a FILE path and want its containing directory:
```powershell
$configDir = Split-Path -Parent $configFilePath  # Correct: file → parent dir
```

### 3.2 Directory Auto-Creation

```powershell
function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}
```

Always call `Ensure-Directory` (or equivalent) before writing files. Wrapped in try/catch for paths that may be on inaccessible drives.

### 3.3 Disk Space Checking

```powershell
# CORRECT: Check the drive where data will ACTUALLY be written
$targetDrive = [System.IO.Path]::GetPathRoot($backupDirectory)
$driveInfo = Get-PSDrive -Name $targetDrive[0]
if ($driveInfo.Free -lt 5GB) { Write-Host "Low disk space!" -ForegroundColor Yellow }

# WRONG: Checking system drive when data goes elsewhere
Get-PSDrive -Name C  # Backup might be on D:\
```

---

## 4. WSL Command Patterns

### 4.1 Instance Listing (Always Trim + Filter)

```powershell
# CORRECT — handles empty lines and whitespace
$instances = wsl -l -q 2>&1 | Where-Object { $_ -match '\S' } | ForEach-Object { $_.Trim() }

# WRONG — restrictive regex rejects valid names
$instances = wsl -l -q | Where-Object { $_ -match '^[0-9a-zA-Z_-]+$' }
# This rejects names with dots, spaces, Chinese characters, etc.
```

Use `-match '\S'` (contains any non-whitespace) to filter out blank lines — WSL allows dots, spaces, and Unicode in instance names.

### 4.2 Before `wsl --unregister`

```powershell
# ALWAYS stop first, then wait
wsl -t $instanceName
Start-Sleep -Seconds 1
wsl --unregister $instanceName
if ($LASTEXITCODE -ne 0) {
    Write-Host "Unregister failed! Aborting subsequent cleanup." -ForegroundColor Red
    return  # <-- CRITICAL: abort, don't continue to delete files
}
```

**Never proceed with file deletion after a failed unregister** — this creates orphan instances where WSL still knows about the instance but the VHDX files are gone.

### 4.3 Before `wsl --import`

```powershell
# ALWAYS check for name conflicts
$existing = wsl -l -q 2>&1 | Where-Object { $_ -match '\S' } | ForEach-Object { $_.Trim() }
if ($existing -contains $newInstanceName) {
    Write-Host "Instance '$newInstanceName' already exists!" -ForegroundColor Yellow
    return
}
wsl --import $newInstanceName $installPath $tarPath --version $wslVersion
```

This check must be in ALL import paths: from store, from repo, from tar, and from backup restore.

### 4.4 Export → Import Lifecycle for Online Store

```
wsl --install -d <distro>     → installs to system default location
wsl --export <distro> <tar>   → capture as template
wsl --unregister <distro>     → remove system-default instance
wsl --import <name> <dir> <tar>  → re-import to our managed location
```

Check `$LASTEXITCODE` after EACH step. If export fails, unregister the temp instance and abort. If import fails, retry once before giving up.

### 4.5 Backup Operations

```powershell
# Generate unique filename
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$backupPath = "$backupDir\$instanceName\full_$timestamp.tar"

# Export
wsl --export $instanceName $backupPath
if ($LASTEXITCODE -ne 0) {
    # Clean up potentially empty/broken file
    Remove-Item $backupPath -ErrorAction SilentlyContinue
    Write-Host "Backup failed!" -ForegroundColor Red
    return
}
```

### 4.6 Template Matching for Cleanup

When deleting a repository template that MAY have a different name than the instance:
```powershell
# Fuzzy match: scan subdirectories, find names that are substrings of each other
$matches = Get-ChildItem -Directory $repoPath | Where-Object {
    $_.Name -like "*$instanceName*" -or $instanceName -like "*$($_.Name)*"
}
# Handle 0 matches (skip), 1 match (delete), or multiple matches (ask user)
```

---

## 5. Batch File (.bat) Rules

### 5.1 Windows Shell Syntax

```batch
:: CORRECT — Windows uses nul, not /dev/null
chcp 65001 >nul 2>&1

:: WRONG — /dev/null doesn't exist on Windows
chcp 65001 >/dev/null 2>&1
```

### 5.2 Statement Separators in PowerShell -Command

```batch
:: CORRECT — semicolons separate statements
powershell -NoProfile -Command "Set-Location '%DIR%'; Import-Module .\Module.psm1 -Force; Show-Menu"

:: WRONG — commas create arrays, they don't separate statements
powershell -NoProfile -Command "Set-Location '%DIR%', Import-Module .\Module.psm1 -Force"
```

### 5.3 Path Variable with Trailing Backslash

```batch
:: %~dp0 includes trailing backslash: C:\path\to\script\
:: When passed inside SINGLE quotes to PowerShell, this is fine
powershell -Command "Set-Location 'C:\path\to\script\'; ..."

:: But when used in DOUBLE quotes or concatenation, strip it:
set "SCRIPT_DIR=%~dp0"
set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"
powershell -Command "Set-Location ""%SCRIPT_DIR%""; ..."
```

**Preferred pattern**: Use single quotes around the path in PowerShell `-Command` — single quotes prevent `\` from being interpreted as an escape character for the following `"`:

```batch
:: CORRECT — single quotes around path
powershell -NoProfile -Command "Set-Location '%SCRIPT_DIR%'; Import-Module .\WSLManager.psm1 -Force; Show-Menu"

:: WRONG — \" is interpreted as escaped quote
powershell -NoProfile -Command "Set-Location ""%SCRIPT_DIR%""; ..."
```

### 5.4 Admin Elevation Pattern

```batch
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)
```

`exit /b` (not `exit`) — exits the batch script without closing the parent CMD window when not elevated.

### 5.5 Console Encoding

Always start with `chcp 65001 >nul 2>&1` for UTF-8 console output.

---

## 6. Config File Patterns

### 6.1 Auto-Create + Self-Heal

```powershell
function Get-Config {
    if (Test-Path $configPath) {
        try {
            $config = Get-Content $configPath -Raw | ConvertFrom-Json
            return $config
        } catch {
            Write-Host "Config corrupted, rebuilding..." -ForegroundColor Yellow
            # Fall through to create defaults
        }
    }
    # Create default config
    $defaults = @{ Key = "value" }
    $defaults | ConvertTo-Json | Out-File -FilePath $configPath -Encoding UTF8
    return $defaults
}
```

Key: after catching a parse error, actually WRITE the defaults back (not just use them in memory).

### 6.2 Path Resolution Priority

```
1. Config file's WSLRoot (if set and directory is creatable)
2. $PSScriptRoot (script's own directory)
```

Validate that the configured path's parent drive is accessible before committing to it.

---

## 7. Cleanup & Safety Patterns

### 7.1 Destructive Operation Sequence

```
1. Verify target exists
2. Show RED warning (not just yellow)
3. Require FULL name retype (not just Y/N)
4. Execute most-reversible step first (unregister)
5. Check each step's result before proceeding
6. If a step fails, SKIP all subsequent steps
7. Report final status clearly (all passed / partial failure)
```

### 7.2 Comment Block Safety

Avoid non-ASCII characters inside PowerShell comment blocks (`<# ... #>`) when possible. If you must use them, ensure UTF-8 BOM is present. The `#>` terminator getting corrupted to `?>` is silent and catastrophic — everything after it becomes a comment.

**Defense**: After any edit touching a comment block with non-ASCII text, run the parser check from §1.2.

---

## 8. Quick Reference: Common Mistakes

| Symptom | Root Cause | Fix |
|:--------|:-----------|:----|
| Chinese characters display as garbled text | Missing UTF-8 BOM on .psm1 | Add BOM via Python: `codecs.open(f,'w','utf-8-sig')` |
| `#>` terminator broken to `?>` | Multi-byte char corruption due to missing BOM | Add BOM, verify with parser check |
| Script runs but half the code is "missing" | Unclosed comment block (corrupted `#>`) | Run brace-count: `{` vs `}` should match |
| `Write-Host` shows placeholder `{0}` | Used `-f` operator instead of `-ForegroundColor` | Change to `-ForegroundColor` |
| `$LASTEXITCODE` is stale/wrong | Used after PowerShell cmdlet instead of `.exe` | Use `$?` for cmdlets, `$LASTEXITCODE` only for .exe |
| `Remove-Item` crashes script | Missing `-ErrorAction SilentlyContinue` | Add `-ErrorAction SilentlyContinue`, check `$?` |
| Module creates dirs in wrong location | `Split-Path -Parent $PSScriptRoot` goes up one level | Use `$PSScriptRoot` directly |
| `.bat` fails to launch PowerShell | Used commas instead of semicolons in `-Command` | Use `;` as statement separator |
| `.bat` path escaping broken | Trailing `\` before `"` creates `\"` escape | Strip with `%VAR:~0,-1%` or use single quotes |
| Instance not found in list | Restrictive regex rejected valid name | Use `-match '\S'` for filtering |
| Orphan WSL instance after failed delete | Proceeded with file cleanup after unregister failure | Check `$LASTEXITCODE`, abort on failure |
| Backup fills wrong drive | Checked `$env:SystemDrive` instead of backup drive | Use `[IO.Path]::GetPathRoot($backupDir)` |
| Instance name collision | Didn't check before `wsl --import` | Always check `wsl -l -q` before importing |

---

## 9. WSL-Specific Guidelines

### 9.1 Command Exit Code Checking

ALL `wsl.exe` calls must have their exit code checked:

```powershell
wsl --export $name $path
if ($LASTEXITCODE -ne 0) {
    # Handle failure — clean up partial output, notify user, abort
}
```

### 9.2 Timeouts and Waiting

WSL operations (especially export/import) can take minutes for large filesystems. Don't set aggressive timeouts. After `wsl -t` (terminate), always `Start-Sleep -Seconds 1` before the next WSL command.

### 9.3 Default WSL Version

Respect the user's `DefaultWSLVersion` config setting. Pass `--version $config.DefaultWSLVersion` to all `wsl --import` calls.

### 9.4 Templates vs Instances

- **Templates** (`.tar` in `Repositories/`): Compact, portable, storage-optimized. Used as source material.
- **Instances** (`.vhdx` in `Instances/`): Live filesystems, performance-optimized. What WSL actually runs.

Never directly run from a template — always import to an instance first.
