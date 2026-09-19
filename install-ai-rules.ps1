# quality-kit / install-ai-rules.ps1
#
# Appends a short, marker-guarded "REGLAS DE CALIDAD (quality-kit)" section
# to the GLOBAL rules file of each AI CLI (applies to every repo, not just
# one). YOU (the person, not an AI assistant) run this yourself -- these
# files are exactly the kind of global AI configuration an assistant's own
# permission system should not be touching on its own behalf.
#
#   pwsh -NoProfile -File ./install-ai-rules.ps1
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
    [string]$ClaudeMdPath = '',
    [string]$CodexAgentsPath = '',
    [string]$KimiAgentsPath = '',
    # Kilo Code (VSCode) lee ~/.config/kilo/AGENTS.md como instrucciones
    # globales (doc oficial) -- cubre a GLM y cualquier modelo usado via Kilo.
    [string]$KiloAgentsPath = ''
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$QualityKitDir = Split-Path -Parent $MyInvocation.MyCommand.Path

function Get-QualityKitUserHome {
    if ($env:QUALITY_KIT_USER_HOME) { return $env:QUALITY_KIT_USER_HOME }
    $homePath = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    if ($homePath) { return $homePath }
    if ($env:HOME) { return $env:HOME }
    throw 'No se pudo resolver el directorio personal del usuario.'
}

$UserHome = Get-QualityKitUserHome
if (-not $ClaudeMdPath) { $ClaudeMdPath = Join-Path $UserHome '.claude/CLAUDE.md' }
if (-not $CodexAgentsPath) { $CodexAgentsPath = Join-Path $UserHome '.codex/AGENTS.md' }
if (-not $KimiAgentsPath) { $KimiAgentsPath = Join-Path $UserHome '.kimi-code/AGENTS.md' }
if (-not $KiloAgentsPath) { $KiloAgentsPath = Join-Path $UserHome '.config/kilo/AGENTS.md' }

$StartMarker = '<!-- >>> QUALITY-KIT REGLAS DE CALIDAD START -- managed by quality-kit''s install-ai-rules.ps1 / uninstall-ai-rules.ps1. Do not hand-edit between these markers. -->'
$EndMarker = '<!-- >>> QUALITY-KIT REGLAS DE CALIDAD END -->'

# Kept deliberately short (this repo's own CLAUDE.md discipline: a global
# rules file is expensive shared context loaded every session, so this
# stays compact instead of re-explaining the whole quality-kit here).
$SectionBody = @'
## REGLAS DE CALIDAD (quality-kit)

1. Si el repo tiene candados de commit (pre-commit), correlos antes de dar por terminado -- JAMAS uses --no-verify ni los saltees; si algo falla, se arregla, no se esquiva.
2. Cada bug que arreglas incluye, en el mismo cambio, una prueba que lo habria atrapado.
3. Durante la implementacion corre pruebas focalizadas; ejecuta la bateria completa una sola vez por bloque sobre el commit final, preferentemente en CI. Si commit, push o CI ya validaron el mismo SHA, no repitas esos checks manualmente.
4. Agrupa los hallazgos de revision y corrigelos en una sola ronda por bloque. Para cambios delicados, sugiere una revision cruzada con otra IA: __CROSS_REVIEW__
   Solo un hallazgo BLOQUEANTE abre otra ronda: seguridad, datos, una regla innegociable, el comportamiento pedido roto o una prueba que no discrimina, y siempre con el comando que lo reproduce (sin reproduccion no bloquea). Cada ronda despues de la primera revisa solo el diff de los arreglos de la anterior (cross-review -Con <otro revisor> -Desde <sha que vio la ronda anterior>). Se repite mientras una ronda traiga un bloqueante y para en la primera que no traiga ninguno. Si el mismo bloqueante vuelve en dos rondas seguidas, el arreglo no converge: se para y decide el operador. Un bloqueante nunca va a una fila del plan ni se mergea abierto: se corrige, o se para y decide el operador. Lo no bloqueante no abre ronda: se corrige en la misma si es de una linea y, si no, va a una fila del plan (Plans.md o el tracker del repo) y se nombra en el PR. Cada ronda con un revisor distinto; cada una cuesta ~100-150k tokens.
5. Una observacion tardia no bloqueante va a una fila del plan; solo un hallazgo bloqueante reabre el ciclo. Despues del deploy ejecuta el checklist una sola vez y reutiliza evidencia valida mientras el SHA no cambie.
6. Si el repo no tiene kit de calidad todavia, sugiere correrlo una vez: __INIT_REPO__ (no insistas si dice que no).
7. Higiene de repo (limites de CLAUDE.md/AGENTS.md + sweep de basura): se instala por repo con __REPO_HYGIENE__ -RepoPath <repo>; sweep manual: python tools/check_context_docs.py . --sweep (reporta, no borra).
8. CI: la bateria completa corre en jobs paralelos cuya union es la bateria
   (con candado); si un job pasa de ~10 min se shardea (bash: `SAIKIT_SHARD=i/N`;
   pytest: `-n auto`; jest/vitest: `--shard`), nunca se recorta ni se saltea por
   tipo de cambio. Los checks que leen docs o ledger reales van en un job propio
   de segundos, separado de la bateria. Carril por tipo de cambio: docs/chore/cierre
   = fast (bots + lead); codigo = gate (+ reviewer); medicion viva/release = +
   cross-review. Los cierres de ledger de un bloque van en un solo PR.
'@
$SectionBody = $SectionBody.Replace('__CROSS_REVIEW__', (Join-Path $QualityKitDir 'cross-review.ps1'))
$SectionBody = $SectionBody.Replace('__INIT_REPO__', (Join-Path $QualityKitDir 'init-repo.ps1'))
$SectionBody = $SectionBody.Replace('__REPO_HYGIENE__', (Join-Path $QualityKitDir 'install-repo-hygiene.ps1'))

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
Install-CalidadBlock -TargetPath $KiloAgentsPath -Label 'Kilo/GLM'
Write-Host '=== Listo ==='
