# quality-kit / uninstall-ai-rules.ps1
#
# Strips the "REGLAS DE CALIDAD (quality-kit)" section that
# install-ai-rules.ps1 added, from each AI CLI's global rules file. Leaves
# everything else in each file exactly as it was. Run it yourself, same as
# install-ai-rules.ps1:
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\ehven\quality-kit\uninstall-ai-rules.ps1
#
# Safe to run even if a file was never touched by install-ai-rules.ps1 (it
# just skips it). Takes a timestamped backup before changing any file. If
# only ONE of the two markers is present (hand-edited or truncated since
# install), it warns explicitly and leaves that file untouched rather than
# guess what to remove.

param(
    [string]$ClaudeMdPath = (Join-Path $env:USERPROFILE '.claude\CLAUDE.md'),
    [string]$CodexAgentsPath = (Join-Path $env:USERPROFILE '.codex\AGENTS.md'),
    [string]$KimiAgentsPath = (Join-Path $env:USERPROFILE '.kimi-code\AGENTS.md')
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$StartMarker = '<!-- >>> QUALITY-KIT REGLAS DE CALIDAD START -- managed by quality-kit''s install-ai-rules.ps1 / uninstall-ai-rules.ps1. Do not hand-edit between these markers. -->'
$EndMarker = '<!-- >>> QUALITY-KIT REGLAS DE CALIDAD END -->'

function Write-Utf8NoBomFile {
    param([string]$Path, [string]$Content)
    [System.IO.File]::WriteAllText($Path, $Content, $Utf8NoBom)
}

function Read-TextFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8)
}

function New-TimestampedBackup {
    param([string]$Path)
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupPath = "$Path.bak-$stamp"
    Copy-Item -LiteralPath $Path -Destination $backupPath -Force
    return $backupPath
}

function Remove-CalidadBlock {
    param([string]$TargetPath, [string]$Label)
    $existing = Read-TextFile -Path $TargetPath
    if ($null -eq $existing) {
        Write-Host "==> [$Label] $TargetPath no existe -- nada que quitar."
        return
    }
    $startIdx = $existing.IndexOf($StartMarker)
    $endIdx = $existing.IndexOf($EndMarker)
    if ($startIdx -ge 0 -and $endIdx -ge 0 -and $endIdx -gt $startIdx) {
        $backupPath = New-TimestampedBackup -Path $TargetPath
        $before = $existing.Substring(0, $startIdx)
        $after = $existing.Substring($endIdx + $EndMarker.Length)
        # Trim ONE trailing blank line install-ai-rules.ps1 would have
        # added right before the block, so uninstalling doesn't leave a
        # growing gap of blank lines behind after repeated install/
        # uninstall cycles.
        $before = $before -replace "(\r?\n)\r?\n$", '$1'
        $updated = $before + $after
        if ([string]::IsNullOrWhiteSpace($updated)) {
            # Nothing left besides whitespace -- this was a file
            # install-ai-rules.ps1 created from nothing (only
            # ~/.codex/AGENTS.md is normally in this situation), so remove
            # it entirely instead of leaving a near-empty file behind.
            Remove-Item -LiteralPath $TargetPath -Force
            Write-Host "==> [$Label] Quite la seccion de reglas de $TargetPath -- no quedaba nada mas, asi que borre el archivo (respaldo: $backupPath)"
        } else {
            Write-Utf8NoBomFile -Path $TargetPath -Content $updated
            Write-Host "==> [$Label] Quite la seccion de reglas de $TargetPath (respaldo: $backupPath)"
        }
    } elseif ($startIdx -ge 0 -or $endIdx -ge 0) {
        $backupPath = New-TimestampedBackup -Path $TargetPath
        Write-Host "==> [$Label] ADVERTENCIA: $TargetPath tiene solo UNA de las dos marcas (start o end), no ambas. No lo toco para no arriesgar el archivo -- revisalo a mano. (Se hizo un respaldo igual: $backupPath)"
    } else {
        Write-Host "==> [$Label] $TargetPath no tiene la seccion de quality-kit -- nada que quitar."
    }
}

Write-Host '=== quality-kit uninstall-ai-rules.ps1 ==='
Remove-CalidadBlock -TargetPath $ClaudeMdPath -Label 'Claude'
Remove-CalidadBlock -TargetPath $CodexAgentsPath -Label 'Codex'
Remove-CalidadBlock -TargetPath $KimiAgentsPath -Label 'Kimi'
Write-Host '=== Listo ==='
