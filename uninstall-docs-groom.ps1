# quality-kit / uninstall-docs-groom.ps1
#
# Removes the "docs-groom" skill directory that install-docs-groom.ps1
# created, for all three AI CLIs. Run it yourself, same as
# install-docs-groom.ps1:
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\ehven\quality-kit\uninstall-docs-groom.ps1
#
# Safe to run even if a skill was never installed for a given AI (it just
# skips it). Takes a timestamped backup of the removed SKILL.md before
# deleting it.

param(
    [string]$ClaudeSkillsDir = (Join-Path $env:USERPROFILE '.claude\skills'),
    [string]$CodexSkillsDir = (Join-Path $env:USERPROFILE '.codex\skills'),
    [string]$KimiSkillsDir = (Join-Path $env:USERPROFILE '.kimi-code\skills')
)

$ErrorActionPreference = 'Stop'

function New-TimestampedBackup {
    param([string]$Path)
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupPath = "$Path.bak-$stamp"
    Copy-Item -LiteralPath $Path -Destination $backupPath -Force
    return $backupPath
}

function Uninstall-DocsGroomSkill {
    param([string]$SkillsDir, [string]$Label)
    $skillDir = Join-Path $SkillsDir 'docs-groom'
    $skillMdPath = Join-Path $skillDir 'SKILL.md'
    if (-not (Test-Path -LiteralPath $skillMdPath)) {
        Write-Host "==> [$Label] $skillMdPath no existe -- nada que quitar."
        return
    }
    $backupPath = New-TimestampedBackup -Path $skillMdPath
    Remove-Item -LiteralPath $skillMdPath -Force
    # Only remove the skill directory itself if nothing else is left in it
    # (a user could in principle have dropped extra reference files next to
    # SKILL.md -- never delete those silently).
    $remaining = @(Get-ChildItem -LiteralPath $skillDir -Force -ErrorAction SilentlyContinue)
    if ($remaining.Count -eq 0) {
        Remove-Item -LiteralPath $skillDir -Force -ErrorAction SilentlyContinue
    }
    Write-Host "==> [$Label] Quite $skillMdPath (respaldo: $backupPath)"
}

Write-Host '=== quality-kit uninstall-docs-groom.ps1 ==='
Uninstall-DocsGroomSkill -SkillsDir $ClaudeSkillsDir -Label 'Claude'
Uninstall-DocsGroomSkill -SkillsDir $CodexSkillsDir -Label 'Codex'
Uninstall-DocsGroomSkill -SkillsDir $KimiSkillsDir -Label 'Kimi'
Write-Host '=== Listo ==='
