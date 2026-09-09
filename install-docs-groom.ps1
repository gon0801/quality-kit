# quality-kit / install-docs-groom.ps1
#
# Installs the "docs-groom" skill (audits and reorganizes a repo's AI
# documentation -- CLAUDE.md, AGENTS.md, docs/) for all three AI CLIs. YOU
# (the person, not an AI) run this yourself -- these skill directories are
# exactly the kind of AI configuration an assistant's own permission system
# should not be touching on its own behalf.
#
#   pwsh -NoProfile -File ./install-docs-groom.ps1
#
# Idempotent: running it again regenerates the same SKILL.md content (taking
# a fresh timestamped backup of whatever was there first). The canonical
# instructions live in docs-groom\INSTRUCTIONS.md; each target gets that
# same body with its own frontmatter (docs-groom\frontmatter-<ai>.yaml)
# glued on top -- Kimi's frontmatter deliberately omits "allowed-tools"
# (confirmed, by reading Kimi's own source strings, that this is a
# Claude/Codex-specific field Kimi does not act on) and was confirmed live,
# via "kimi --skills-dir", to load correctly and be listed under "User"
# scope with the right name and description.
#
# Parameters exist ONLY so the test suite can redirect these paths to
# throwaway fake homes -- when you run this yourself, don't pass any of
# them and it targets your real ~/.claude, ~/.codex, ~/.kimi-code.

param(
    [string]$ClaudeSkillsDir = '',
    [string]$CodexSkillsDir = '',
    [string]$KimiSkillsDir = ''
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$QualityKitDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$DocsGroomDir = Join-Path $QualityKitDir 'docs-groom'

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
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupPath = "$Path.bak-$stamp"
    Copy-Item -LiteralPath $Path -Destination $backupPath -Force
    return $backupPath
}

function Install-DocsGroomSkill {
    param([string]$SkillsDir, [string]$FrontmatterFile, [string]$Label)
    $frontmatter = Read-TextFile -Path (Join-Path $DocsGroomDir $FrontmatterFile)
    $instructions = Read-TextFile -Path (Join-Path $DocsGroomDir 'INSTRUCTIONS.md')
    if ($null -eq $frontmatter -or $null -eq $instructions) {
        throw "Falta un archivo fuente en $DocsGroomDir -- reinstala quality-kit."
    }
    $skillDir = Join-Path $SkillsDir 'docs-groom'
    if (-not (Test-Path -LiteralPath $skillDir)) {
        New-Item -ItemType Directory -Path $skillDir -Force | Out-Null
    }
    $skillMdPath = Join-Path $skillDir 'SKILL.md'
    $backupPath = New-TimestampedBackup -Path $skillMdPath
    $content = $frontmatter + "`n" + $instructions
    Write-Utf8NoBomFile -Path $skillMdPath -Content $content
    if ($null -ne $backupPath) {
        Write-Host "==> [$Label] Actualice $skillMdPath (respaldo: $backupPath)"
    } else {
        Write-Host "==> [$Label] Cree $skillMdPath"
    }
}

Write-Host '=== quality-kit install-docs-groom.ps1 ==='
Install-DocsGroomSkill -SkillsDir $ClaudeSkillsDir -FrontmatterFile 'frontmatter-claude.yaml' -Label 'Claude'
Install-DocsGroomSkill -SkillsDir $CodexSkillsDir -FrontmatterFile 'frontmatter-codex.yaml' -Label 'Codex'
Install-DocsGroomSkill -SkillsDir $KimiSkillsDir -FrontmatterFile 'frontmatter-kimi.yaml' -Label 'Kimi'
Write-Host ''
Write-Host 'Reinicia (o abri una sesion nueva en) cada asistente para que detecte la skill nueva.'
Write-Host '=== Listo ==='
