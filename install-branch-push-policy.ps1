# install-branch-push-policy.ps1 -- escribe en un repo la politica de push a
# ramas protegidas del plugin claude-code-harness
# (<repo>\.claude-code-harness.config.yaml -> safety.protected_branch_push).
#
# Por que existe (medido 2026-08-15 en summonaikit-claude, commit aca3284):
# el guardrail del plugin lee ese yaml por repo; con el default (`ask`), cada
# push directo a master deja un prompt colgado cuando el operador no esta --
# fue uno de los bloques grandes de una task de 18 h de pared. El fallback
# (harness.toml en la raiz VERSIONADA del plugin) muere en cada update del
# plugin, asi que el lugar correcto es el yaml del repo, commiteado para que
# aplique en todos los checkouts y worktrees.
#
# PARA EL OPERADOR, NO PARA UNA SESION DE IA: el harness le bloquea al agente
# escribir este archivo (control-plane), con razon -- un agente no desarma
# sus propios candados. Corre este script vos, decidi vos el modo.
#
# `allow` solo tiene sentido si el repo tiene OTRA red sobre la rama
# protegida (pre-commit + un job de CI en cada push, p.ej. init-repo.ps1 +
# install-ci-linux.ps1). Sin esa red, dejalo en `ask`.
#
# Uso:
#   powershell -ExecutionPolicy Bypass -File install-branch-push-policy.ps1 `
#       -RepoPath <repo> [-Mode allow|ask]
#
# PowerShell 5.1 compatible (mismas convenciones que init-repo.ps1).

param(
    [string]$RepoPath = (Get-Location).Path,
    [ValidateSet('allow', 'ask')]
    [string]$Mode = 'allow'
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$ConfigName = '.claude-code-harness.config.yaml'
$ConfigPath = Join-Path $RepoPath $ConfigName

if (-not (Test-Path (Join-Path $RepoPath '.git'))) {
    Write-Host "==> [X] $RepoPath no es un repo git -- nada que hacer."
    exit 1
}

# Cross-review 2026-08-15 (hallazgo 3, aceptado como ADVERTENCIA): `allow`
# presupone la red pre-commit + CI. Si no se ve ninguna, se avisa fuerte --
# pero se procede: la decision es del operador por diseno, no del script.
if ($Mode -eq 'allow') {
    $red = @()
    if (-not (Test-Path (Join-Path $RepoPath '.pre-commit-config.yaml'))) {
        $red += 'sin .pre-commit-config.yaml (candados: init-repo.ps1)'
    }
    $wfDir = Join-Path $RepoPath '.github\workflows'
    $wfCount = 0
    if (Test-Path -LiteralPath $wfDir) {
        $wfCount = @(Get-ChildItem -LiteralPath $wfDir -Filter '*.y*ml' -File -ErrorAction SilentlyContinue).Count
    }
    if ($wfCount -eq 0) { $red += 'sin workflows de CI (init-repo.ps1 / install-ci-linux.ps1)' }
    if ($red.Count -gt 0) {
        Write-Host "==> [!] allow SIN red detectada en el repo: $($red -join '; ')."
        Write-Host '    El guardrail queda desactivado sin candados/CI que lo respalden -- considera -Mode ask, o instala la red primero.'
    }
}

# Bloque nuevo, con el porque adentro para que el proximo que abra el archivo
# no tenga que ir a buscarlo al historial de otro repo. Here-string de
# comillas SIMPLES a proposito: en uno doble, los backticks del texto serian
# escapes de PowerShell y corromperian el comentario.
$PolicyBlock = @'
# Politica del guardrail de claude-code-harness para push a ramas protegidas.
# Decision del operador (escrita por quality-kit\install-branch-push-policy.ps1;
# el harness le bloquea al agente tocar este archivo, y esta bien que asi sea).
# Con `ask` cada push directo a master deja un prompt colgado si el operador no
# esta. `allow` presupone que la red real de la rama son los candados de
# pre-commit y el CI en cada push -- si este repo no los tiene, volver a `ask`.
safety:
  protected_branch_push: __MODE__
'@
$PolicyBlock = $PolicyBlock.Replace('__MODE__', $Mode)
# Newline final SIEMPRE: un here-string no lo trae, y un archivo sin EOL
# final rompe el candado end-of-file-fixer en el primer commit del yaml
# (medido 2026-08-15 en goncloud-MCP-2/accounting).
if (-not $PolicyBlock.EndsWith("`n")) { $PolicyBlock += "`n" }

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    [System.IO.File]::WriteAllText($ConfigPath, $PolicyBlock, $Utf8NoBom)
    Write-Host "==> [OK] $ConfigName creado con protected_branch_push: $Mode."
    Write-Host '    Commitea el archivo para que aplique en todos los checkouts y worktrees del repo.'
    exit 0
}

# El archivo ya existe: es control-plane y puede traer mas configuracion que
# la nuestra, asi que solo se hacen ediciones QUIRURGICAS con backup previo.
$existing = [System.IO.File]::ReadAllText($ConfigPath, [System.Text.Encoding]::UTF8)
# `[ \t]*\r?` explicito en vez de `\s*$`: con archivos CRLF, `\s*` se traga
# el `\r` (y hasta lineas en blanco) y la edicion perderia el fin de linea.
# `(?:#[^\r\n]*)?` en ambas regex: cross-review 2026-08-15 (hallazgo 2) --
# un comentario inline (`ask # motivo`, `safety: # motivo`) hacia fallar el
# match y la rama de insercion duplicaba la clave/seccion.
$safetyRegex = [regex]'(?m)^safety[ \t]*:[ \t]*(?:#[^\r\n]*)?\r?$'
$keyRegex = [regex]'(?m)^([ \t]+protected_branch_push[ \t]*:[ \t]*)(\S+)([ \t]*(?:#[^\r\n]*)?\r?)$'

# Cross-review 2026-08-15 (hallazgo 1): la clave se busca SOLO dentro de la
# seccion safety (desde su linea hasta la siguiente clave top-level), no en
# el archivo entero -- una clave homonima de otra seccion no se toca.
$secMatch = $safetyRegex.Match($existing)
if ($secMatch.Success) {
    $sectionStart = $secMatch.Index + $secMatch.Length
    $resto = $existing.Substring($sectionStart)
    $nextTop = [regex]::Match($resto, '(?m)^[^\s#]')
    $sectionEnd = $existing.Length
    if ($nextTop.Success) { $sectionEnd = $sectionStart + $nextTop.Index }
    $span = $existing.Substring($sectionStart, $sectionEnd - $sectionStart)

    $keyMatch = $keyRegex.Match($span)
    if ($keyMatch.Success) {
        $current = $keyMatch.Groups[2].Value
        if ($current -eq $Mode) {
            Write-Host "==> [OK] $ConfigName ya tiene protected_branch_push: $Mode -- sin cambios."
            exit 0
        }
        $backup = "$ConfigPath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item -LiteralPath $ConfigPath -Destination $backup
        # MatchEvaluator a proposito: un replacement string interpretaria `$1`
        # y cualquier `$` del valor (leccion de install-repo-hygiene.ps1).
        $evaluator = { param($m) $m.Groups[1].Value + $Mode + $m.Groups[3].Value }.GetNewClosure()
        $updated = $existing.Substring(0, $sectionStart) + $keyRegex.Replace($span, $evaluator, 1) + $existing.Substring($sectionEnd)
        [System.IO.File]::WriteAllText($ConfigPath, $updated, $Utf8NoBom)
        Write-Host "==> [OK] protected_branch_push: $current -> $Mode (backup en $(Split-Path -Leaf $backup))."
        exit 0
    }

    # Hay seccion safety: sin nuestra clave -- se inserta adentro, sin tocar
    # el resto de la seccion.
    $backup = "$ConfigPath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item -LiteralPath $ConfigPath -Destination $backup
    $evaluator = { param($m) $m.Value + "`n  protected_branch_push: " + $Mode }.GetNewClosure()
    $updated = $safetyRegex.Replace($existing, $evaluator, 1)
    [System.IO.File]::WriteAllText($ConfigPath, $updated, $Utf8NoBom)
    Write-Host "==> [OK] protected_branch_push: $Mode agregado a la seccion safety existente (backup en $(Split-Path -Leaf $backup))."
    exit 0
}

# Ni la clave ni una seccion safety reconocible: se agrega el bloque completo
# al final. YAML admite una sola seccion safety top-level, y acabamos de
# verificar que no hay ninguna.
$backup = "$ConfigPath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
Copy-Item -LiteralPath $ConfigPath -Destination $backup
if ($existing -notmatch '(\r?\n)$') { $existing += "`n" }
[System.IO.File]::WriteAllText($ConfigPath, ($existing + "`n" + $PolicyBlock), $Utf8NoBom)
Write-Host "==> [OK] Bloque safety agregado al final de $ConfigName (backup en $(Split-Path -Leaf $backup))."
exit 0
