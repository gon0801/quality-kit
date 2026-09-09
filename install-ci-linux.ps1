# install-ci-linux.ps1 -- instala el job de CI que corre la suite bash
# COMPLETA de un repo en un runner Linux (.github\workflows\suite-linux.yml).
#
# Por que existe (medido en summonaikit-claude, fila 10.5 de su Plans.md): en
# Git Bash/MSYS2 cada fork de subproceso cuesta ~28 ms; en Linux ~0.1 ms
# (~300x). Una suite de shell que en Windows tarda ~18 min corre en ~1-2 min
# en ubuntu-latest. Este installer generaliza ese patron para cualquier repo
# cuya suite sea scripts de shell.
#
# A quien SI y a quien NO: solo repos con suite bash (por default
# tests\run.sh). Los repos con suite PowerShell (este mismo kit), pytest o
# jest no pagan el impuesto de MSYS2 -- el installer se rehusa si no
# encuentra el entrypoint, para que no quede un workflow que falla en cada
# push.
#
# Tests atados a Windows: el runner del repo los saltea DECLARANDOLOS
# (nombrados uno por uno en su salida, detras de una variable de entorno que
# se pasa aca con -EnvVar), nunca en silencio -- "not_observed != absent".
#
# Uso:
#   pwsh -NoProfile -File ./install-ci-linux.ps1 -RepoPath <repo> `
#       [-TestEntry tests/run.sh] [-TimeoutMinutes 30] `
#       [-EnvVar "SAIKIT_CI_LINUX=1,OTRA=valor"]
#
# Idempotente: re-correrlo refresca el workflow si lo genero el kit; si el
# repo tiene un suite-linux.yml propio (sin marca), se respeta y no se toca.
#
# PowerShell 5.1 compatible (mismas convenciones que init-repo.ps1).

param(
    [string]$RepoPath = (Get-Location).Path,
    [string]$TestEntry = 'tests/run.sh',
    # 1..360: cross-review 2026-08-15 (hallazgo 6) -- 0/negativo generaria un
    # workflow que GitHub Actions rechaza; 360 es el tope de un job hosted.
    [ValidateRange(1, 360)]
    [int]$TimeoutMinutes = 30,
    [string[]]$EnvVar = @()
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$KitDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$TemplatePath = Join-Path $KitDir 'templates\suite-linux.yml'
$WorkflowMarker = 'Generado por quality-kit (install-ci-linux.ps1)'

function Read-TextFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

if (-not (Test-Path (Join-Path $RepoPath '.git'))) {
    Write-Host "==> [X] $RepoPath no es un repo git -- nada que hacer."
    exit 1
}
if (-not (Test-Path -LiteralPath $TemplatePath)) {
    Write-Host "==> [X] Falta $TemplatePath -- el kit esta incompleto."
    exit 1
}

# --- 1. El repo tiene que TENER la suite bash que este job corre ------------
# TestEntry viaja en forma POSIX (tests/run.sh) porque asi va al yaml; para
# mirar el disco local se traduce a forma Windows.
# Cross-review 2026-08-15 (hallazgo 4): TestEntry se interpola en el yaml
# (nombre del step y linea `run:`) -- allowlist estricta: relativo al repo,
# sin `..`, sin espacios ni metacaracteres. Con ese alfabeto, la
# interpolacion sin comillas es segura por construccion.
if ($TestEntry -notmatch '^[A-Za-z0-9._/-]+$' -or $TestEntry -match '(^|/)\.\.(/|$)' -or $TestEntry.StartsWith('/')) {
    Write-Host "==> [X] -TestEntry '$TestEntry' invalido: tiene que ser una ruta RELATIVA dentro del repo (letras/numeros/._/-), sin '..', espacios ni metacaracteres."
    exit 1
}
$entryLocal = Join-Path $RepoPath ($TestEntry -replace '/', '\')
if (-not (Test-Path -LiteralPath $entryLocal -PathType Leaf)) {
    Write-Host "==> [X] No existe $TestEntry (como archivo) en $RepoPath -- este job es SOLO para repos con suite bash."
    Write-Host '    Si la suite del repo es PowerShell, pytest o jest, no paga el impuesto de MSYS2: le basta el quality.yml de init-repo.ps1.'
    Write-Host '    Si la suite bash vive en otra ruta, pasala con -TestEntry <ruta/relativa.sh>.'
    exit 1
}

# --- 2. Validar y armar el bloque env ---------------------------------------
# Cada -EnvVar es NOMBRE=valor. Se acepta ademas UNA lista separada por comas
# ('A=1,B=2') porque invocado con `powershell -File` un parametro nombrado no
# se puede repetir y las comas llegan como parte de un solo string (limite
# conocido: un VALOR con coma no se puede pasar por esa via). El valor va al
# yaml entre comillas simples (la unica forma segura de citar en YAML sin
# interpretar nada).
$envPairs = @()
foreach ($raw in $EnvVar) { $envPairs += ($raw -split ',') }
$envLines = @()
foreach ($pair in $envPairs) {
    if ($pair -notmatch '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
        Write-Host "==> [X] -EnvVar '$pair' no tiene forma NOMBRE=valor -- no se escribio nada."
        exit 1
    }
    $name = $Matches[1]
    $value = $Matches[2] -replace "'", "''"
    $envLines += "          ${name}: '$value'"
}
$envBlock = ''
if ($envLines.Count -gt 0) {
    $envBlock = "        env:`n" + (($envLines -join "`n") + "`n")
}

# --- 3. Tres estados sobre el destino ---------------------------------------
$workflowDir = Join-Path $RepoPath '.github\workflows'
$workflowPath = Join-Path $workflowDir 'suite-linux.yml'
$existing = Read-TextFile -Path $workflowPath
if ($null -ne $existing -and $existing -notmatch [regex]::Escape($WorkflowMarker)) {
    Write-Host "==> Ya existe .github\workflows\suite-linux.yml y NO fue generado por quality-kit -- no lo toco."
    exit 1
}

# .Replace() de string a proposito (literal, sin regex): el bloque env puede
# contener `$` (p.ej. `${{ github.workspace }}`), que en un replacement de
# -replace tiene significado propio y corromperia el YAML (mismo bug real que
# documenta install-repo-hygiene.ps1).
$content = Read-TextFile -Path $TemplatePath
$content = $content.Replace('__TIMEOUT_MINUTES__', [string]$TimeoutMinutes)
$content = $content.Replace('__TEST_ENTRY__', $TestEntry)
$content = $content.Replace('__ENV_BLOCK__', $envBlock)

if ($null -ne $existing -and $existing -eq $content) {
    Write-Host '==> [OK] .github\workflows\suite-linux.yml ya esta al dia -- sin cambios.'
    exit 0
}
if (-not (Test-Path -LiteralPath $workflowDir)) {
    New-Item -ItemType Directory -Path $workflowDir -Force | Out-Null
}
[System.IO.File]::WriteAllText($workflowPath, $content, $Utf8NoBom)
Write-Host "==> [OK] Escribi .github\workflows\suite-linux.yml (entry: $TestEntry, timeout: $TimeoutMinutes min)."
if ($envLines.Count -gt 0) {
    Write-Host "    Variables de entorno del job: $($EnvVar -join ', ')"
} else {
    Write-Host '    Sin variables de entorno. Si la suite tiene tests atados a Windows, el runner debe saltearlos DECLARANDOLOS detras de una variable (p.ej. -EnvVar SAIKIT_CI_LINUX=1).'
}
Write-Host '    Commitea el archivo para que el job corra en el proximo push/PR.'
exit 0
