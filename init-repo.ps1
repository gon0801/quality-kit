# quality-kit / init-repo.ps1
#
# Sets up deterministic quality guards (pre-commit hooks, optional pre-push
# tests, optional CI workflow, and a short "Calidad" note in the repo's own
# docs) inside a single repository. Run it from inside the repo you want to
# protect:
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\ehven\quality-kit\init-repo.ps1
#
# Idempotent: running it again re-checks everything and only changes what
# needs changing. Never touches a pre-existing, non-quality-kit config file
# of the same name -- it skips those and tells you so, rather than
# clobbering something you already had.
#
# PowerShell 5.1 (Windows PowerShell) compatible on purpose: no ternary /
# null-coalescing operators, explicit -Encoding on every text read, and
# every Where-Object result destined for a .Count check is wrapped in
# @(...) -- see kimi-summonaikit's README for why that last one matters on
# this PowerShell version (a single-match Where-Object result comes back
# bare, not array-wrapped, and PSCustomObject has no synthetic .Count).

param(
    [string]$RepoPath = (Get-Location).Path
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$QualityKitDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$TemplatesDir = Join-Path $QualityKitDir 'templates'

$PreCommitConfigMarker = 'QUALITY-KIT MANAGED'
$WorkflowMarker = 'Generado por quality-kit'
$CalidadStartMarker = '<!-- >>> QUALITY-KIT CALIDAD SECTION START -- managed by quality-kit''s init-repo.ps1. Do not hand-edit between these markers; re-running init-repo.ps1 will refresh this block cleanly. -->'
$CalidadEndMarker = '<!-- >>> QUALITY-KIT CALIDAD SECTION END -->'

function Write-Utf8NoBomFile {
    param([string]$Path, [string]$Content)
    [System.IO.File]::WriteAllText($Path, $Content, $Utf8NoBom)
}

function Read-TextFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8)
}

# ------------------------------------------------------------------
# Interpreter / tool resolution
# ------------------------------------------------------------------

# Known-good fallback confirmed on this machine; used only if nothing else
# on PATH already provides a working Python.
$KnownGoodPython = 'C:\Python314\python.exe'

function Test-CommandWorks {
    param([string]$Exe, [string[]]$TestArgs)
    try {
        $null = & $Exe @TestArgs 2>&1
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

function Get-PythonExe {
    $candidates = @('python', 'py', $KnownGoodPython)
    foreach ($c in $candidates) {
        if (Test-CommandWorks -Exe $c -TestArgs @('--version')) { return $c }
    }
    return $null
}

# Prefer a repo-local virtualenv's Python (it has the repo's real
# dependencies installed, so pytest actually finds what it needs), falling
# back to whatever generic Python this machine has.
function Get-RepoPythonExe {
    param([string]$RepoPath)
    $venvCandidates = @(
        (Join-Path $RepoPath '.venv\Scripts\python.exe'),
        (Join-Path $RepoPath 'venv\Scripts\python.exe')
    )
    foreach ($v in $venvCandidates) {
        if (Test-Path -LiteralPath $v) { return $v }
    }
    return (Get-PythonExe)
}

# Returns an object describing how to invoke pre-commit: .Exe and .ArgsPrefix
# (an array to prepend to whatever command-specific args are needed).
# Installs pre-commit via pip using the known-good Python if nothing on this
# machine already provides it.
function Get-PreCommitInvoker {
    if (Test-CommandWorks -Exe 'pre-commit' -TestArgs @('--version')) {
        return [PSCustomObject]@{ Exe = 'pre-commit'; ArgsPrefix = @() }
    }
    $pythonExe = Get-PythonExe
    if ($pythonExe) {
        if (Test-CommandWorks -Exe $pythonExe -TestArgs @('-m', 'pre_commit', '--version')) {
            return [PSCustomObject]@{ Exe = $pythonExe; ArgsPrefix = @('-m', 'pre_commit') }
        }
    }
    Write-Host '==> pre-commit no esta instalado en esta maquina; instalando con pip...'
    if (-not $pythonExe) { $pythonExe = $KnownGoodPython }
    & $pythonExe -m pip install --quiet pre-commit
    if ($LASTEXITCODE -ne 0) {
        throw "No se pudo instalar pre-commit con '$pythonExe -m pip install pre-commit'. Instalalo a mano e intenta de nuevo."
    }
    if (-not (Test-CommandWorks -Exe $pythonExe -TestArgs @('-m', 'pre_commit', '--version'))) {
        throw "pre-commit se instalo pero '$pythonExe -m pre_commit --version' sigue fallando."
    }
    return [PSCustomObject]@{ Exe = $pythonExe; ArgsPrefix = @('-m', 'pre_commit') }
}

function Invoke-PreCommit {
    param($Invoker, [string[]]$CmdArgs, [string]$RepoPath)
    $allArgs = @()
    $allArgs += $Invoker.ArgsPrefix
    $allArgs += $CmdArgs
    Push-Location -LiteralPath $RepoPath
    try {
        # IMPORTANT: an external command's own stdout, if not redirected,
        # becomes part of THIS function's pipeline output -- and gets
        # silently concatenated with a bare "return $exitCode" when the
        # caller does "$x = Invoke-PreCommit ...", corrupting $x into a
        # mix of text and the exit code. Routing through Out-Host prints it
        # for the user immediately without polluting the function's actual
        # return value.
        & $Invoker.Exe @allArgs | Out-Host
        $exitCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    return $exitCode
}

# ------------------------------------------------------------------
# Stack / tooling detection
# ------------------------------------------------------------------

function Test-HasPythonStack {
    param([string]$RepoPath)
    if (Test-Path -LiteralPath (Join-Path $RepoPath 'pyproject.toml')) { return $true }
    if (Test-Path -LiteralPath (Join-Path $RepoPath 'requirements.txt')) { return $true }
    # Deliberately NOT recursive: a deep scan would wander into .venv/
    # site-packages or node_modules and misfire on unrelated *.py files
    # bundled inside other tools' installs. A top-level check is enough to
    # catch "a repo of loose Python scripts with no project manifest yet";
    # anything more structured already has pyproject.toml/requirements.txt.
    $pyFiles = @(Get-ChildItem -LiteralPath $RepoPath -Filter '*.py' -File -ErrorAction SilentlyContinue)
    return ($pyFiles.Count -gt 0)
}

function Test-HasNodeStack {
    param([string]$RepoPath)
    return (Test-Path -LiteralPath (Join-Path $RepoPath 'package.json'))
}

function Get-PackageJson {
    param([string]$RepoPath)
    $pkgPath = Join-Path $RepoPath 'package.json'
    if (-not (Test-Path -LiteralPath $pkgPath)) { return $null }
    try {
        return (Read-TextFile -Path $pkgPath | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        return $null
    }
}

function Test-HasEslintConfig {
    param([string]$RepoPath, $PackageJson)
    $patterns = @('.eslintrc', '.eslintrc.js', '.eslintrc.cjs', '.eslintrc.json', '.eslintrc.yml', '.eslintrc.yaml', 'eslint.config.js', 'eslint.config.mjs', 'eslint.config.cjs', 'eslint.config.ts')
    foreach ($p in $patterns) {
        if (Test-Path -LiteralPath (Join-Path $RepoPath $p)) { return $true }
    }
    if ($null -ne $PackageJson -and ($PackageJson.PSObject.Properties.Name -contains 'eslintConfig')) { return $true }
    return $false
}

function Test-HasPrettierConfig {
    param([string]$RepoPath, $PackageJson)
    $patterns = @('.prettierrc', '.prettierrc.json', '.prettierrc.yml', '.prettierrc.yaml', '.prettierrc.js', '.prettierrc.cjs', '.prettierrc.mjs', 'prettier.config.js', 'prettier.config.cjs', 'prettier.config.mjs')
    foreach ($p in $patterns) {
        if (Test-Path -LiteralPath (Join-Path $RepoPath $p)) { return $true }
    }
    if ($null -ne $PackageJson -and ($PackageJson.PSObject.Properties.Name -contains 'prettier')) { return $true }
    return $false
}

function Test-HasPytestConfig {
    param([string]$RepoPath)
    if (Test-Path -LiteralPath (Join-Path $RepoPath 'pytest.ini')) { return $true }
    $pyproject = Read-TextFile -Path (Join-Path $RepoPath 'pyproject.toml')
    if ($null -ne $pyproject -and $pyproject -match '(?m)^\[tool\.pytest\.ini_options\]') { return $true }
    $setupCfg = Read-TextFile -Path (Join-Path $RepoPath 'setup.cfg')
    if ($null -ne $setupCfg -and $setupCfg -match '(?m)^\[tool:pytest\]') { return $true }
    if (Test-Path -LiteralPath (Join-Path $RepoPath 'tests') -PathType Container) { return $true }
    if (Test-Path -LiteralPath (Join-Path $RepoPath 'test') -PathType Container) { return $true }
    return $false
}

# npm's own `npm init` default is a placeholder that always fails; only a
# real, non-placeholder test script counts as "this repo has tests".
function Test-HasRealNpmTestScript {
    param($PackageJson)
    if ($null -eq $PackageJson) { return $false }
    if (-not ($PackageJson.PSObject.Properties.Name -contains 'scripts')) { return $false }
    $scripts = $PackageJson.scripts
    if ($null -eq $scripts) { return $false }
    if (-not ($scripts.PSObject.Properties.Name -contains 'test')) { return $false }
    $testCmd = [string]$scripts.test
    if ([string]::IsNullOrWhiteSpace($testCmd)) { return $false }
    if ($testCmd -match 'Error: no test specified') { return $false }
    return $true
}

function Test-HasGithubRemote {
    param([string]$RepoPath)
    Push-Location -LiteralPath $RepoPath
    try {
        $remotes = @(& git remote -v 2>&1)
        if ($LASTEXITCODE -ne 0) { return $false }
    } finally {
        Pop-Location
    }
    $matches = @($remotes | Where-Object { $_ -match 'github\.com' })
    return ($matches.Count -gt 0)
}

function Test-IsGitRepo {
    param([string]$RepoPath)
    return (Test-Path -LiteralPath (Join-Path $RepoPath '.git'))
}

# ------------------------------------------------------------------
# .pre-commit-config.yaml assembly
# ------------------------------------------------------------------

function Build-PreCommitConfigContent {
    param([string]$RepoPath, [string]$PythonExeForHook, [hashtable]$Detected)
    $content = Read-TextFile -Path (Join-Path $TemplatesDir 'pre-commit-generic.yaml')
    $components = New-Object System.Collections.Generic.List[string]
    $components.Add('base (limpieza de archivos)')

    if ($Detected.Python) {
        $content += (Read-TextFile -Path (Join-Path $TemplatesDir 'pre-commit-python.yaml'))
        $components.Add('ruff (lint + formato Python)')
    }
    if ($Detected.Eslint) {
        $content += (Read-TextFile -Path (Join-Path $TemplatesDir 'pre-commit-node-eslint.yaml'))
        $components.Add('eslint (config existente del repo)')
    }
    if ($Detected.Prettier) {
        $content += (Read-TextFile -Path (Join-Path $TemplatesDir 'pre-commit-node-prettier.yaml'))
        $components.Add('prettier (config existente del repo)')
    }
    if ($Detected.Pytest) {
        $pytestFragment = Read-TextFile -Path (Join-Path $TemplatesDir 'pre-commit-test-pytest.yaml')
        $pytestFragment = $pytestFragment.Replace('<PYTHON_EXE>', $PythonExeForHook)
        $content += $pytestFragment
        $components.Add('pytest -x -q (pre-push)')
    }
    if ($Detected.NpmTest) {
        $content += (Read-TextFile -Path (Join-Path $TemplatesDir 'pre-commit-test-npm.yaml'))
        $components.Add('npm test (pre-push)')
    }

    return [PSCustomObject]@{ Content = $content; Components = $components }
}

function Write-PreCommitConfigIfSafe {
    param([string]$RepoPath, [string]$NewContent)
    $configPath = Join-Path $RepoPath '.pre-commit-config.yaml'
    if (Test-Path -LiteralPath $configPath) {
        $existing = Read-TextFile -Path $configPath
        if ($null -ne $existing -and $existing -notmatch [regex]::Escape($PreCommitConfigMarker)) {
            Write-Host "==> Ya existe .pre-commit-config.yaml y NO fue generado por quality-kit -- no lo toco, para no pisar tu configuracion."
            return $false
        }
    }
    Write-Utf8NoBomFile -Path $configPath -Content $NewContent
    Write-Host '==> Escribi .pre-commit-config.yaml'
    return $true
}

# ------------------------------------------------------------------
# GitHub Actions workflow
# ------------------------------------------------------------------

function Copy-QualityWorkflowIfSafe {
    param([string]$RepoPath)
    $workflowDir = Join-Path $RepoPath '.github\workflows'
    $workflowPath = Join-Path $workflowDir 'quality.yml'
    if (Test-Path -LiteralPath $workflowPath) {
        $existing = Read-TextFile -Path $workflowPath
        if ($null -ne $existing -and $existing -notmatch [regex]::Escape($WorkflowMarker)) {
            Write-Host "==> Ya existe .github\workflows\quality.yml y NO fue generado por quality-kit -- no lo toco."
            return $false
        }
    }
    if (-not (Test-Path -LiteralPath $workflowDir)) {
        New-Item -ItemType Directory -Path $workflowDir -Force | Out-Null
    }
    $templateContent = Read-TextFile -Path (Join-Path $TemplatesDir 'quality.yml')
    Write-Utf8NoBomFile -Path $workflowPath -Content $templateContent
    Write-Host '==> Escribi .github\workflows\quality.yml'
    return $true
}

# ------------------------------------------------------------------
# CLAUDE.md / AGENTS.md "Calidad" section
# ------------------------------------------------------------------

function Get-CalidadSectionBody {
    param([hashtable]$Detected, [string]$PythonExeForHook, [System.Collections.Generic.List[string]]$Components, [bool]$ConfigWritten)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('## Calidad (quality-kit)')
    $lines.Add('')
    if ($ConfigWritten) {
        $lines.Add('Candados de commit instalados (pre-commit):')
        foreach ($c in $Components) { $lines.Add("- $c") }
        $lines.Add('')
        $lines.Add('Comandos para correr los candados a mano:')
        $lines.Add('- `pre-commit run --all-files` (todos los candados de commit)')
        if ($Detected.Pytest) { $lines.Add("- ``$PythonExeForHook -m pytest -x -q`` (pruebas, normalmente corren solas en cada ``git push``)") }
        if ($Detected.NpmTest) { $lines.Add('- `npm test` (pruebas, normalmente corren solas en cada `git push`)') }
    } else {
        # This repo already had its own .pre-commit-config.yaml before
        # quality-kit ever ran here -- init-repo.ps1 never overwrites a
        # config it didn't create, so listing OUR specific hooks here would
        # be a lie about what's actually active. Point at the real source
        # of truth instead.
        $lines.Add('Este repo ya tenia su propia configuracion de pre-commit antes de quality-kit -- no la pisamos.')
        $lines.Add('Para ver que candados tiene realmente: `pre-commit run --all-files` (o mira `.pre-commit-config.yaml`).')
    }
    $lines.Add('')
    $lines.Add('Reglas de hierro:')
    $lines.Add('1. Si un candado falla, se arregla el problema real -- JAMAS se usa `--no-verify` ni se saltea un candado.')
    $lines.Add('2. Cada bug arreglado incluye, en el mismo cambio, una prueba que lo habria atrapado.')
    return ($lines -join "`n")
}

function Update-CalidadDoc {
    param([string]$DocPath, [string]$SectionBody)
    $block = "$CalidadStartMarker`n$SectionBody`n$CalidadEndMarker"
    if (-not (Test-Path -LiteralPath $DocPath)) {
        Write-Utf8NoBomFile -Path $DocPath -Content ($block + "`n")
        Write-Host "==> Cree $DocPath con la seccion Calidad"
        return
    }
    $existing = Read-TextFile -Path $DocPath
    $startIdx = $existing.IndexOf($CalidadStartMarker)
    $endIdx = $existing.IndexOf($CalidadEndMarker)
    if ($startIdx -ge 0 -and $endIdx -ge 0 -and $endIdx -gt $startIdx) {
        $before = $existing.Substring(0, $startIdx)
        $after = $existing.Substring($endIdx + $CalidadEndMarker.Length)
        $updated = $before + $block + $after
        Write-Utf8NoBomFile -Path $DocPath -Content $updated
        Write-Host "==> Actualice la seccion Calidad en $DocPath"
    } else {
        $sep = ''
        if ($existing.Length -gt 0 -and -not $existing.EndsWith("`n")) { $sep = "`n" }
        $updated = $existing + $sep + "`n" + $block + "`n"
        Write-Utf8NoBomFile -Path $DocPath -Content $updated
        Write-Host "==> Agregue la seccion Calidad a $DocPath"
    }
}

# ------------------------------------------------------------------
# Main
# ------------------------------------------------------------------

$RepoPath = (Resolve-Path -LiteralPath $RepoPath).Path
Write-Host "=== quality-kit init-repo.ps1 ==="
Write-Host "Repo: $RepoPath"

if (-not (Test-IsGitRepo -RepoPath $RepoPath)) {
    throw "Esta carpeta no es un repositorio git todavia (no encontre .git). Corre 'git init' primero y volve a intentar."
}

$packageJson = Get-PackageJson -RepoPath $RepoPath
$detected = @{
    Python  = (Test-HasPythonStack -RepoPath $RepoPath)
    Node    = (Test-HasNodeStack -RepoPath $RepoPath)
    Eslint  = $false
    Prettier = $false
    Pytest  = $false
    NpmTest = $false
}
if ($detected.Node) {
    $detected.Eslint = (Test-HasEslintConfig -RepoPath $RepoPath -PackageJson $packageJson)
    $detected.Prettier = (Test-HasPrettierConfig -RepoPath $RepoPath -PackageJson $packageJson)
    $detected.NpmTest = (Test-HasRealNpmTestScript -PackageJson $packageJson)
}
if ($detected.Python) {
    $detected.Pytest = (Test-HasPytestConfig -RepoPath $RepoPath)
}

$stackLabel = 'generico (ni Python ni Node detectados -- solo los chequeos base)'
if ($detected.Python -and $detected.Node) { $stackLabel = 'Python + Node' }
elseif ($detected.Python) { $stackLabel = 'Python' }
elseif ($detected.Node) { $stackLabel = 'Node' }
Write-Host "Stack detectado: $stackLabel"

$pythonExeForHook = $null
if ($detected.Pytest) {
    $pythonExeForHook = Get-RepoPythonExe -RepoPath $RepoPath
    if (-not $pythonExeForHook) {
        Write-Host '==> ADVERTENCIA: se detecto pytest pero no encontre ningun Python utilizable en esta maquina; el hook de pre-push para pytest no va a funcionar hasta que instales Python.'
        $pythonExeForHook = 'python'
    }
}

$built = Build-PreCommitConfigContent -RepoPath $RepoPath -PythonExeForHook $pythonExeForHook -Detected $detected
$configWritten = Write-PreCommitConfigIfSafe -RepoPath $RepoPath -NewContent $built.Content

$invoker = Get-PreCommitInvoker
Write-Host "==> Usando pre-commit via: $($invoker.Exe) $($invoker.ArgsPrefix -join ' ')"

$installExit = Invoke-PreCommit -Invoker $invoker -CmdArgs @('install') -RepoPath $RepoPath
if ($installExit -ne 0) {
    throw "'pre-commit install' fallo (codigo $installExit). Revisa el mensaje de arriba."
}
Write-Host '==> pre-commit install (pre-commit) listo'

$needsPrePush = ($detected.Pytest -or $detected.NpmTest)
if ($needsPrePush) {
    $prePushExit = Invoke-PreCommit -Invoker $invoker -CmdArgs @('install', '--hook-type', 'pre-push') -RepoPath $RepoPath
    if ($prePushExit -ne 0) {
        throw "'pre-commit install --hook-type pre-push' fallo (codigo $prePushExit)."
    }
    Write-Host '==> pre-commit install --hook-type pre-push listo'
}

$hasGithubRemote = Test-HasGithubRemote -RepoPath $RepoPath
$workflowWritten = $false
if ($hasGithubRemote) {
    $workflowWritten = Copy-QualityWorkflowIfSafe -RepoPath $RepoPath
} else {
    Write-Host '==> Sin remoto de GitHub todavia -- salteo la nube (.github\workflows\quality.yml). Se activa solo el dia que subas este repo a GitHub; volve a correr este script despues.'
}

$sectionBody = Get-CalidadSectionBody -Detected $detected -PythonExeForHook $pythonExeForHook -Components $built.Components -ConfigWritten $configWritten
Update-CalidadDoc -DocPath (Join-Path $RepoPath 'CLAUDE.md') -SectionBody $sectionBody
Update-CalidadDoc -DocPath (Join-Path $RepoPath 'AGENTS.md') -SectionBody $sectionBody

Write-Host ''
Write-Host '=== Resumen ==='
Write-Host "Stack: $stackLabel"
if ($configWritten) {
    Write-Host "Candados configurados: $($built.Components -join ', ')"
} else {
    Write-Host 'Candados configurados: (el repo ya tenia su propio .pre-commit-config.yaml -- no se toco)'
}
Write-Host "Pre-push (pruebas): $needsPrePush"
Write-Host "Workflow de CI copiado: $workflowWritten (remoto de GitHub detectado: $hasGithubRemote)"
Write-Host "CLAUDE.md / AGENTS.md actualizados con la seccion Calidad."
Write-Host '=== Listo ==='
