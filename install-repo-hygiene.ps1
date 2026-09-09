# install-repo-hygiene.ps1 -- instala el candado de higiene de repo
# (capa de contexto + sweep de basura) en cualquier repo, nuevo o existente.
#
# Que hace (idempotente, se puede re-correr para refrescar):
#   1. Copia templates\check-context-docs.py -> <repo>\tools\check_context_docs.py
#      (solo crea/refresca copias con la marca QUALITY-KIT REPO-HYGIENE; si el
#      repo tiene una version propia sin marca, la respeta y avisa).
#   2. Agrega el hook `context-docs-budget` a .pre-commit-config.yaml entre
#      marcas propias (refresca entre marcas si ya estan; salta si el repo ya
#      tiene un hook con ese id fuera de las marcas).
#   3. `python -m pre_commit install` para activar los hooks de git.
#   4. Corre el candado y el sweep una vez y reporta (no borra nada).
#
# Uso:  powershell -ExecutionPolicy Bypass -File install-repo-hygiene.ps1 [-RepoPath <ruta>]
#
# PowerShell 5.1 compatible (mismas convenciones que init-repo.ps1).

param(
    [string]$RepoPath = (Get-Location).Path
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$KitDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$TemplatePath = Join-Path $KitDir 'templates\check-context-docs.py'
$HygieneMark = 'QUALITY-KIT REPO-HYGIENE'
$BeginMark = '# >>> QUALITY-KIT REPO-HYGIENE HOOK START -- managed by install-repo-hygiene.ps1'
$EndMark = '# >>> QUALITY-KIT REPO-HYGIENE HOOK END'

if (-not (Test-Path (Join-Path $RepoPath '.git'))) {
    Write-Host "==> [X] $RepoPath no es un repo git -- nada que hacer."
    exit 1
}
if (-not (Test-Path $TemplatePath)) {
    Write-Host "==> [X] Falta $TemplatePath -- el kit esta incompleto."
    exit 1
}

# --- 1. Copiar el checker ---------------------------------------------------
$ToolsDir = Join-Path $RepoPath 'tools'
$TargetScript = Join-Path $ToolsDir 'check_context_docs.py'
if (-not (Test-Path $ToolsDir)) { New-Item -ItemType Directory -Path $ToolsDir | Out-Null }

$copyScript = $true
if (Test-Path $TargetScript) {
    $existing = [System.IO.File]::ReadAllText($TargetScript, [System.Text.Encoding]::UTF8)
    if ($existing -notmatch [regex]::Escape($HygieneMark)) {
        Write-Host "==> tools\check_context_docs.py ya existe y es version PROPIA del repo (sin marca) -- se respeta, no se toca."
        $copyScript = $false
    }
}
if ($copyScript) {
    $templateText = [System.IO.File]::ReadAllText($TemplatePath, [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText($TargetScript, $templateText, $Utf8NoBom)
    Write-Host "==> [OK] tools\check_context_docs.py instalado/refrescado."
}

# --- 2. Cablear el hook en .pre-commit-config.yaml ---------------------------
$ConfigPath = Join-Path $RepoPath '.pre-commit-config.yaml'
# Here-string de comillas SIMPLES a proposito: el regex de `files:` termina en
# `$'` y un here-string doble-comilla lo interpola/rompe (bug real del primer
# install en goncloud-accounting: YAML invalido por quote sin cerrar).
$HookBlock = @'
# >>> QUALITY-KIT REPO-HYGIENE HOOK START -- managed by install-repo-hygiene.ps1
# Candado de capa de contexto: CLAUDE.md raiz <=200 lineas, anidados <=80,
# AGENTS.md <=400, sin diarios '## Estado anterior' (van a docs/).
# Sweep manual de basura: python tools/check_context_docs.py . --sweep
  - repo: local
    hooks:
      - id: context-docs-budget
        name: capa de contexto dentro de presupuesto (repo-hygiene)
        entry: python tools/check_context_docs.py
        # El entorno aislado de pre-commit aporta `python` en Windows,
        # macOS y Linux; no depende de aliases del sistema anfitrion.
        language: python
        pass_filenames: false
        files: '(^|/)(CLAUDE|AGENTS|AGENT)\.md$'
# >>> QUALITY-KIT REPO-HYGIENE HOOK END
'@

if (-not (Test-Path $ConfigPath)) {
    $minimal = @"
# .pre-commit-config.yaml minimo creado por install-repo-hygiene.ps1.
# Para el kit completo (lint, tests, higiene de archivos) corre despues:
#   powershell -ExecutionPolicy Bypass -File $KitDir\init-repo.ps1
repos:
$HookBlock
"@
    [System.IO.File]::WriteAllText($ConfigPath, $minimal, $Utf8NoBom)
    Write-Host "==> [OK] .pre-commit-config.yaml minimo creado (correr init-repo.ps1 para el kit completo)."
} else {
    $config = [System.IO.File]::ReadAllText($ConfigPath, [System.Text.Encoding]::UTF8)
    if ($config -match [regex]::Escape($BeginMark)) {
        $pattern = '(?s)' + [regex]::Escape($BeginMark) + '.*?' + [regex]::Escape($EndMark)
        # MatchEvaluator (scriptblock) a proposito: el bloque contiene `$'`,
        # que en un replacement string de .NET significa "input despues del
        # match" y corrompe el YAML (segundo bug real del install piloto).
        $evaluator = { $HookBlock.TrimEnd() }.GetNewClosure()
        $config = [regex]::Replace($config, $pattern, $evaluator)
        [System.IO.File]::WriteAllText($ConfigPath, $config, $Utf8NoBom)
        Write-Host "==> [OK] Hook context-docs-budget refrescado entre marcas."
    } elseif ($config -match 'id:\s*context-docs-budget') {
        Write-Host "==> El repo ya tiene un hook context-docs-budget propio (sin marcas) -- se respeta, no se duplica."
    } else {
        if ($config -notmatch '(\r?\n)$') { $config += "`n" }
        $config += $HookBlock + "`n"
        [System.IO.File]::WriteAllText($ConfigPath, $config, $Utf8NoBom)
        Write-Host "==> [OK] Hook context-docs-budget agregado al final de .pre-commit-config.yaml."
    }
}

# --- 3. Activar hooks de git -------------------------------------------------
Push-Location $RepoPath
try {
    # pre-commit se rehusa si core.hooksPath esta seteado. Caso real
    # (goncloud-accounting): apuntaba al DEFAULT .git\hooks (set redundante)
    # -- quitarlo es seguro. Si apunta a otro lado (husky, etc.), NO se toca.
    $hooksPath = (& git config core.hooksPath 2>$null)
    if ($hooksPath) {
        $default = (Join-Path $RepoPath '.git\hooks')
        $resolved = $hooksPath -replace '/', '\'
        if ($resolved -ieq $default) {
            & git config --unset-all core.hooksPath
            Write-Host "==> [OK] core.hooksPath redundante (apuntaba al default) -- quitado para que pre-commit pueda instalar."
        } else {
            Write-Host "==> [!] core.hooksPath apunta a '$hooksPath' (custom) -- pre-commit no puede instalar; resolver a mano."
        }
    }
    & python -m pre_commit install 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "==> [OK] pre-commit install (hooks de git activos)."
    } else {
        Write-Host "==> [!] 'python -m pre_commit install' fallo -- instala pre-commit (pip install pre-commit) y re-corre."
    }
} finally { Pop-Location }

# --- 4. Reporte inicial --------------------------------------------------------
Write-Host ''
Write-Host '==> Estado actual del repo contra el candado:'
& python (Join-Path $ToolsDir 'check_context_docs.py') $RepoPath
if ($LASTEXITCODE -eq 0) { Write-Host '    [OK] capa de contexto dentro de presupuesto.' }
Write-Host ''
Write-Host '==> Sweep de basura (reporte, no borra nada):'
& python (Join-Path $ToolsDir 'check_context_docs.py') $RepoPath --sweep
exit 0
