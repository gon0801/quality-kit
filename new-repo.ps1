# new-repo.ps1 -- boton unico para dejar un repo (nuevo o existente) con todo
# el quality-kit por-repo de un jalon:
#
#   1. init-repo.ps1            -> candados base de pre-commit segun el stack
#                                  (higiene de archivos, ruff/eslint, tests pre-push)
#   2. install-repo-hygiene.ps1 -> candado de capa de contexto (CLAUDE.md/AGENTS.md)
#                                  + sweep de basura
#
# Lo global (reglas de IA, cross-review, harness de SummonAI) NO se toca aqui:
# ya esta instalado a nivel usuario y aplica solo. Este script es lo unico que
# hay que correr al crear/adoptar un repo.
#
# Uso:  pwsh -NoProfile -File ./new-repo.ps1 [-RepoPath <ruta>]

param(
    [string]$RepoPath = (Get-Location).Path
)

$ErrorActionPreference = 'Stop'
$KitDir = Split-Path -Parent $MyInvocation.MyCommand.Path

function Get-CurrentPowerShellExe {
    $current = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    if ($current -and ((Split-Path -Leaf $current) -match '^(pwsh|powershell)(\.exe)?$')) { return $current }
    foreach ($name in @('pwsh', 'powershell')) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($null -ne $command) { return $command.Source }
    }
    throw 'No se encontro el ejecutable de PowerShell actual.'
}

$PowerShellExe = Get-CurrentPowerShellExe

if (-not (Test-Path (Join-Path $RepoPath '.git'))) {
    Write-Host "==> [X] $RepoPath no es un repo git. Si es un proyecto nuevo, corre 'git init' primero."
    exit 1
}

Write-Host "=== quality-kit new-repo: $RepoPath ==="
Write-Host ''
Write-Host '--- Paso 1/2: candados base (init-repo.ps1) ---'
& $PowerShellExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $KitDir 'init-repo.ps1') -RepoPath $RepoPath
if ($LASTEXITCODE -ne 0) {
    Write-Host "==> [!] init-repo.ps1 termino con codigo $LASTEXITCODE -- revisa arriba; sigo con la higiene igual."
}
Write-Host ''
Write-Host '--- Paso 2/2: higiene de repo (install-repo-hygiene.ps1) ---'
& $PowerShellExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $KitDir 'install-repo-hygiene.ps1') -RepoPath $RepoPath
exit $LASTEXITCODE
