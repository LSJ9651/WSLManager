# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

WSLManager is a portable, self-contained PowerShell module for managing WSL (Windows Subsystem for Linux) distributions via an interactive CLI menu. Users double-click `WSLManager.bat` to launch. All WSL files (templates, instances, backups) are stored within the module directory.

## Architecture

```
WSLManager.bat       → Entry point: admin elevation + PowerShell launcher
WSLManager.psm1      → Core module with all business logic
Config/config.json   → User preferences (auto-created on first run)
```

**Module initialization** (runs on `Import-Module`):
1. Set console encoding to UTF-8
2. Read config (or create defaults)
3. Ensure directories exist: `Repositories/`, `Instances/`, `Backups/`, `Temp/`, `Config/`
4. Clean expired temp files

**Key design principle**: `.tar` for template storage (space-efficient), `.vhdx` for running instances (performance-optimal).

## File Encoding (Critical)

- **`.psm1` / `.ps1`**: LF line endings + UTF-8 with BOM — PowerShell 5.1 will NOT parse UTF-8 correctly without BOM, mangling Chinese characters and corrupting syntax (`#>` comment terminators become `?>`)
- **`.bat` / `.cmd`**: CRLF line endings + UTF-8 with BOM

## Commands

```bash
# Load the module and test
powershell -NoProfile -ExecutionPolicy Bypass -Command "Set-Location '<repo>'; Import-Module .\WSLManager.psm1 -Force; Show-Menu"

# Syntax check
powershell -NoProfile -Command '$t=@();$e=@();$null=[System.Management.Automation.Language.Parser]::ParseFile("<repo>\WSLManager.psm1",[ref]$t,[ref]$e);$e|%{$_.Message}'

# Brace balance check
python -c "t=open('<repo>/WSLManager.psm1','rb').read().decode('utf-8-sig');print(f'{{={t.count(\"{\")} }}={t.count(\"}\")}')"
```

## Key Patterns & Gotchas

### PowerShell 5.1 Compatibility
- **No `-f` for colors**: Use `-ForegroundColor Cyan` directly, NOT `Write-Host ("text" -f $colorVar)`. The `-f` operator replaces format placeholders entirely—it has nothing to do with colors.
- **`$LASTEXITCODE` only for external commands** (`.exe` like `wsl.exe`). For PowerShell cmdlets (`Remove-Item`, `Copy-Item`), use `$?` instead, and add `-ErrorAction SilentlyContinue` to prevent terminating errors from crashing the script.
- **UTF-8 BOM is mandatory**: Without BOM, PS5.1 interprets UTF-8 as the system's ANSI codepage (e.g., GBK), corrupting multi-byte characters.

### Instance Name Handling
- `wsl -l -q` outputs UTF-16 LE with embedded NUL bytes (`\0`) between characters. PowerShell 5.1's pipeline interprets NULs as line separators, creating spurious empty entries and corrupting instance names. **Always** use this pattern:
  ```powershell
  ((wsl -l -q 2>&1 | Out-String) -replace '\0', '') -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
  ```
  This collapses the UTF-16 stream via `Out-String`, strips NUL chars, splits on newlines, trims whitespace, and filters empty lines.
- Never use `'^[0-9a-zA-Z_-]+$'` regex — it rejects valid WSL names containing dots or spaces

### Path Resolution
- `$script:RootPath = $PSScriptRoot` — Do NOT use `Split-Path -Parent` on `$PSScriptRoot`; it would go one level up
- `Get-WSLRoot`: config's `WSLRoot` takes priority, wrap `Ensure-Directory` in try/catch (may fail due to permissions/disk space), fall back to `$script:RootPath`
- Remove trailing backslash from `%~dp0` in `.bat`: `set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"` before passing to PowerShell with `'%SCRIPT_DIR%'` (single quotes avoid `\"` escape issues)

### WSL Command Safety
- **Before `wsl --unregister`**: Always `wsl -t <instance>` first (stopping), then `Start-Sleep -Seconds 1`
- **After `wsl --unregister`**: Check `$LASTEXITCODE` — if it fails, abort all subsequent cleanup to prevent orphan instances
- **`wsl --import` failure after unregister**: Data is already lost at this point. Implement a retry from the template, and warn the user that the template file is preserved at the saved path
- **Instance name collision**: Check `wsl -l -q` before importing in ALL creation paths (from store, from repo, from tar, from backup restore)

### Backup/Restore Safety
- Disk space check must target the drive of the backup directory (`GetPathRoot`), NOT `$env:SystemDrive`
- Sort backups by `Time` descending before displaying to user
- Restore "overwrite" path: stop → unregister (check result) → import (stop if unregister fails)

### Removal Safety
- `Remove-Item -Recurse -Force -ErrorAction SilentlyContinue` + `$?` check (NOT `$LASTEXITCODE`)
- Template matching for cleanup: scan `Repositories/` subdirectories with fuzzy match (`-like`), handle 0/1/multiple matches
- Step 1 (unregister) failure must skip ALL subsequent cleanup

### Bat File Launch
- `chcp 65001 >nul 2>&1` (NOT `/dev/null` — Windows doesn't have it)
- Use `;` as statement separator in PowerShell `-Command` (NOT `,` — comma is array operator)
- Path variable: strip trailing backslash before passing to avoid `\"` escaping through double quotes
