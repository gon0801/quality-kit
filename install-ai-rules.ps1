# quality-kit / install-ai-rules.ps1
#
# Appends a short, marker-guarded "REGLAS DE CALIDAD (quality-kit)" section
# to the GLOBAL rules file of each AI CLI (applies to every repo, not just
# one). YOU (the person, not an AI assistant) run this yourself -- these
# files are exactly the kind of global AI configuration an assistant's own
# permission system should not be touching on its own behalf.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\ehven\quality-kit\install-ai-rules.ps1
#
# Idempotent: running it again just refreshes the same marker-guarded
# block, never duplicates it. Takes a timestamped backup of each file
# before changing it. Creates a file that does not exist yet (only
# ~/.codex/AGENTS.md is normally missing on this machine).
#
# Parameters exist ONLY so the test suite can redirect these paths to
# throwaway fake homes -- when you run this yourself, don't pass any of
# them and it targets your real ~/.claude, ~/.codex, ~/.kimi-code.

param(
    [string]$ClaudeMdPath = (Join-Path $env:USERPROFILE '.claude\CLAUDE.md'),
    [string]$CodexAgentsPath = (Join-Path $env:USERPROFILE '.codex\AGENTS.md'),
    [string]$KimiAgentsPath = (Join-Path $env:USERPROFILE '.kimi-code\AGENTS.md')
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$StartMarker = '<!-- >>> QUALITY-KIT REGLAS DE CALIDAD START -- managed by quality-kit''s install-ai-rules.ps1 / uninstall-ai-rules.ps1. Do not hand-edit between these markers. -->'
$EndMarker = '<!-- >>> QUALITY-KIT REGLAS DE CALIDAD END -->'

# Kept deliberately short (this repo's own CLAUDE.md discipline: a global
# rules file is expensive shared context loaded every session, so this
# stays compact instead of re-explaining the whole quality-kit here).
$SectionBody = @'
## REGLAS DE CALIDAD (quality-kit)

1. Si el repo tiene candados de commit (pre-commit), correlos antes de dar por terminado -- JAMAS uses --no-verify ni los saltees; si algo falla, se arregla, no se esquiva.
2. Cada bug que arreglas incluye, en el mismo cambio, una prueba que lo habria atrapado.
3. Para cambios delicados, sugiere una revision cruzada con otra IA: C:\Users\ehven\quality-kit\cross-review.ps1
4. Si el repo no tiene kit de calidad todavia, sugiere correrlo una vez: C:\Users\ehven\quality-kit\init-repo.ps1 (no insistas si dice que no).
'@

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

function Install-CalidadBlock {
    param([string]$TargetPath, [string]$Label)
    $dir = Split-Path -Parent $TargetPath
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $block = "$StartMarker`n$SectionBody`n$EndMarker"
    $existing = Read-TextFile -Path $TargetPath
    if ($null -eq $existing) {
        Write-Utf8NoBomFile -Path $TargetPath -Content ($block + "`n")
        Write-Host "==> [$Label] Cree $TargetPath con la seccion de reglas."
        return
    }
    $backupPath = New-TimestampedBackup -Path $TargetPath
    $startIdx = $existing.IndexOf($StartMarker)
    $endIdx = $existing.IndexOf($EndMarker)
    if ($startIdx -ge 0 -and $endIdx -ge 0 -and $endIdx -gt $startIdx) {
        $before = $existing.Substring(0, $startIdx)
        $after = $existing.Substring($endIdx + $EndMarker.Length)
        $updated = $before + $block + $after
        Write-Utf8NoBomFile -Path $TargetPath -Content $updated
        Write-Host "==> [$Label] Actualice la seccion de reglas en $TargetPath (respaldo: $backupPath)"
    } elseif ($startIdx -ge 0 -or $endIdx -ge 0) {
        # Only one marker present -- something hand-edited or truncated
        # this. Do not guess: warn loudly and leave the file untouched
        # beyond the backup we already took, same hardening as
        # kimi-summonaikit's uninstall.ps1 for its own marker block.
        Write-Host "==> [$Label] ADVERTENCIA: $TargetPath tiene solo UNA de las dos marcas (start o end), no ambas. No lo toco para no arriesgar el archivo -- revisalo a mano. (Se hizo un respaldo igual: $backupPath)"
    } else {
        $sep = ''
        if ($existing.Length -gt 0 -and -not $existing.EndsWith("`n")) { $sep = "`n" }
        $updated = $existing + $sep + "`n" + $block + "`n"
        Write-Utf8NoBomFile -Path $TargetPath -Content $updated
        Write-Host "==> [$Label] Agregue la seccion de reglas a $TargetPath (respaldo: $backupPath)"
    }
}

Write-Host '=== quality-kit install-ai-rules.ps1 ==='
Install-CalidadBlock -TargetPath $ClaudeMdPath -Label 'Claude'
Install-CalidadBlock -TargetPath $CodexAgentsPath -Label 'Codex'
Install-CalidadBlock -TargetPath $KimiAgentsPath -Label 'Kimi'
Write-Host '=== Listo ==='
