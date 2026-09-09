# quality-kit / uninstall-docs-groom.ps1
#
# Removes the "docs-groom" skill directory that install-docs-groom.ps1
# created, for all three AI CLIs. Run it yourself, same as
# install-docs-groom.ps1:
#
#   pwsh -NoProfile -File ./uninstall-docs-groom.ps1
#
# Safe to run even if a skill was never installed for a given AI (it just
# skips it). Takes a timestamped backup of the removed SKILL.md before
# deleting it.

param(
    [string]$ClaudeSkillsDir = '',
    [string]$CodexSkillsDir = '',
    [string]$KimiSkillsDir = ''
)

$ErrorActionPreference = 'Stop'

function Get-QualityKitUserHome {
    if ($env:QUALITY_KIT_USER_HOME) { return $env:QUALITY_KIT_USER_HOME }
    $homePath = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    if ($homePath) { return $homePath }
    if ($env:HOME) { return $env:HOME }
    throw 'No se pudo resolver el directorio personal del usuario.'
}

$UserHome = Get-QualityKitUserHome
if (-not $ClaudeSkillsDir) { $ClaudeSkillsDir = Join-Path $UserHome '.claude/skills' }
if (-not $CodexSkillsDir) { $CodexSkillsDir = Join-Path $UserHome '.codex/skills' }
if (-not $KimiSkillsDir) { $KimiSkillsDir = Join-Path $UserHome '.kimi-code/skills' }

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
