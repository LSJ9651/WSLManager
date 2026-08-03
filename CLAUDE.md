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

## Open Source & Release

- **License**: MIT (2026, LSJ) — `LICENSE` must ship in every release zip
- **Repo**: PUBLIC at `LSJ9651/WSLManager`, default branch `master`, topics: `wsl`, `powershell`, `windows`, `wsl2`, `cli`
- **Version sync**: the version in the `Show-Menu` header (`WSL 发行版管理工具 v1.0`, ~line 124) is **hardcoded**. When cutting a release, bump the header, the git tag, and the Release notes together — all three must agree
- **Release zip contents**: ONLY `WSLManager.bat`, `WSLManager.psm1`, `README.md`, `LICENSE`. NEVER package `Config/config.json` or `Backups/` — they hold personal data (config.json is the user's gitignored default config; Backups/ may contain real backups). Runtime dirs are recreated on first launch, so they don't belong in the zip either
- **`docs/` is gitignored** (local-only design docs, e.g. 设计大纲) — don't reference it for anything user-facing
- **Commit messages**: Chinese, consistent with existing history
- **README is the user contract**: its 功能说明 / 配置说明 / 安全说明 / 注意事项 sections must be updated in the same change as any behavior change

### Security claims (must not regress)
README's 安全说明 makes auditable promises: **no network access, no registry / scheduled-task / service writes, only talks to WSL via official commands and touches files under tool-owned dirs**. Any new feature that would break these claims (auto-update, telemetry, external paths) must update that README section in the same PR — do not silently invalidate the documented guarantees.

## File Encoding (Critical)

- **`.psm1` / `.ps1`**: LF line endings + UTF-8 with BOM — PowerShell 5.1 will NOT parse UTF-8 correctly without BOM, mangling Chinese characters and corrupting syntax (`#>` comment terminators become `?>`)
- **`.bat` / `.cmd`**: CRLF line endings + UTF-8 with BOM
- **`.md`** (README.md etc.): UTF-8 **without** BOM — Markdown is fine without BOM, unlike `.psm1`

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
- **Store install flow** (`New-WSLInstanceFromStore`): install with `wsl --install -d <name> --no-launch` (avoids auto-entering Linux and stalling the script) → export template → `wsl --unregister` the default instance → re-import to managed location. If `--install` fails, the whole flow aborts BEFORE any unregister (no data lost); if template export fails, unregister the installed distro to clean up
- **Name-collision retry**: in creation flows, instance-name validation uses a `do { read; if name taken → null } while (empty)` loop, NOT a one-shot check-and-return (Store) — keep the retry so an invalid name can't strand an already-unregistered distro

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

## WSL Commands in Use

| Command | Purpose | Where |
| --- | --- | --- |
| `wsl -l -v` | List instances w/ status | List-Instances |
| `wsl -l -o` | List online distros | New-WSLInstanceFromStore |
| `wsl -l -q` | Silent name list (NUL-strip pattern!) | Backup / Restore / Remove / name checks |
| `wsl --install -d <name> --no-launch` | Install from store | New-WSLInstanceFromStore |
| `wsl --export <name> <path>.tar` | Backup / template | Backup / New-WSLInstanceFromStore |
| `wsl --import <name> <dir> <tar> --version N` | Create instance | New / Restore |
| `wsl --unregister <name>` | Remove instance | Remove / Restore / New-WSLInstanceFromStore |
| `wsl -t <name>` | Stop instance | Remove / Restore |
