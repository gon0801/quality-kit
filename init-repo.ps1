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

# Directories a recursive Python-file search must never descend into: they
# either aren't the repo's own code (dependencies, virtualenvs) or aren't
# code at all (vcs internals, bytecode cache). Real-world bug found piloting
# this script on an actual repo: the trading repo's strategy code lives
# entirely under user_data\strategies\*.py, with no pyproject.toml or
# requirements.txt at the root, and the original root-only *.py check
# missed it completely, misreporting the stack as "generic".
$PySearchExcludedDirNames = @('.git', '.venv', 'venv', 'node_modules', '__pycache__')
$PySearchMaxDepth = 4

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
# Verify-before-enable: the core lesson from a real deploy incident (MCP-2).
# A pre-push test hook that structurally fails (wrong runner, or the runner
# itself crashing on this machine -- confirmed live: pytest 9.0.3 on Python
# 3.14 hit an internal "ValueError: I/O operation on closed file" during
# capture teardown) is WORSE than no hook at all: it blocks every push for a
# reason that has nothing to do with the code being pushed. So the chosen
# runner is always actually run once, cheaply, before init-repo.ps1 ever
# writes a pre-push hook for it. If that trial run fails for ANY structural
# reason (crash, non-zero exit, or it does not even finish in time), no
# pre-push hook is installed at all -- a loud warning explains why and how
# to add it back by hand once it is fixed.
# ------------------------------------------------------------------

# Runs an external command with redirected stdio and a hard timeout,
# without risking the classic parent-process deadlock: reading stdout and
# stderr via ReadToEndAsync BEFORE WaitForExit means both streams drain
# concurrently, so neither can back up and block the child if it writes a
# lot to both (confirmed live: sequential .ReadToEnd() calls do not exhibit
# this here with small output, but there is no reason to rely on that
# holding for an arbitrary test suite's real output).
function Invoke-CommandWithTimeout {
    param([string]$Exe, [string]$Arguments, [string]$WorkingDirectory, [int]$TimeoutSeconds = 30)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = $Arguments
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    try {
        $proc.Start() | Out-Null
    } catch {
        return [PSCustomObject]@{ TimedOut = $false; ExitCode = -1; Stdout = ''; Stderr = "No se pudo iniciar '$Exe': $_" }
    }
    $proc.StandardInput.Close()
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    $finished = $proc.WaitForExit($TimeoutSeconds * 1000)
    if (-not $finished) {
        try { $proc.Kill() } catch {
            # Best-effort: if the process already exited between the
            # WaitForExit timeout and this Kill call, that is fine too.
        }
        return [PSCustomObject]@{ TimedOut = $true; ExitCode = -1; Stdout = ''; Stderr = '' }
    }
    $stdout = ''
    $stderr = ''
    try { $stdout = $stdoutTask.Result } catch {}
    try { $stderr = $stderrTask.Result } catch {}
    return [PSCustomObject]@{ TimedOut = $false; ExitCode = $proc.ExitCode; Stdout = $stdout; Stderr = $stderr }
}

function Get-ValidationFailureDetail {
    param($Result)
    if ($Result.TimedOut) { return 'no termino dentro del tiempo esperado (se cancelo)' }
    $tail = ($Result.Stderr + "`n" + $Result.Stdout).Trim()
    if ($tail.Length -gt 300) { $tail = $tail.Substring($tail.Length - 300) }
    $detail = "codigo de salida $($Result.ExitCode)"
    if ($tail) { $detail = $detail + ': ' + $tail }
    return $detail
}

# Validates the chosen runner by actually invoking it once, cheaply:
#   - pytest: "--collect-only" collects tests without running them -- fast,
#     and still catches a crashing pytest installation (exactly the MCP-2
#     failure mode) or a genuinely wrong runner choice.
#   - unittest: the standard library's unittest CLI has no equivalent
#     collect-only mode (confirmed: "python -m unittest -h" lists no such
#     flag), so validating it means actually running the discovered tests
#     once, with -f (failfast) and -q (quiet) to keep this cheap and to
#     stop at the first problem rather than running a whole slow suite.
function Test-PythonRunnerValidates {
    param([string]$RepoPath, [string]$PythonExeForHook, [PSCustomObject]$RunnerPlan)
    if ($RunnerPlan.Type -eq 'pytest') {
        $result = Invoke-CommandWithTimeout -Exe $PythonExeForHook -Arguments '-m pytest --collect-only -q' -WorkingDirectory $RepoPath -TimeoutSeconds 30
        if ($result.TimedOut -or $result.ExitCode -ne 0) {
            return [PSCustomObject]@{ Ok = $false; Detail = (Get-ValidationFailureDetail $result) }
        }
        return [PSCustomObject]@{ Ok = $true; Detail = '' }
    }
    if ($RunnerPlan.Type -eq 'unittest') {
        $workDir = $RepoPath
        if ($null -ne $RunnerPlan.TestsDirInfo.ParentSubdir) {
            $workDir = Join-Path $RepoPath $RunnerPlan.TestsDirInfo.ParentSubdir
        }
        $arguments = "-m unittest discover -s $($RunnerPlan.TestsDirInfo.StartDir) -t . -f -q"
        $result = Invoke-CommandWithTimeout -Exe $PythonExeForHook -Arguments $arguments -WorkingDirectory $workDir -TimeoutSeconds 30
        if ($result.TimedOut -or $result.ExitCode -ne 0) {
            return [PSCustomObject]@{ Ok = $false; Detail = (Get-ValidationFailureDetail $result) }
        }
        return [PSCustomObject]@{ Ok = $true; Detail = '' }
    }
    return [PSCustomObject]@{ Ok = $false; Detail = 'tipo de runner desconocido' }
}

# ------------------------------------------------------------------
# Stack / tooling detection
# ------------------------------------------------------------------

function Test-HasNestedPyFile {
    param([string]$DirPath, [int]$DepthRemaining)
    # Fast path: files directly in this directory, checked before
    # recursing further, so a real hit at a shallow depth returns
    # immediately without needlessly walking siblings.
    $filesHere = @(Get-ChildItem -LiteralPath $DirPath -Filter '*.py' -File -ErrorAction SilentlyContinue)
    if ($filesHere.Count -gt 0) { return $true }
    if ($DepthRemaining -le 0) { return $false }
    $subDirs = @(Get-ChildItem -LiteralPath $DirPath -Directory -ErrorAction SilentlyContinue | Where-Object { $PySearchExcludedDirNames -notcontains $_.Name })
    foreach ($sub in $subDirs) {
        if (Test-HasNestedPyFile -DirPath $sub.FullName -DepthRemaining ($DepthRemaining - 1)) { return $true }
    }
    return $false
}

function Test-HasPythonStack {
    param([string]$RepoPath)
    if (Test-Path -LiteralPath (Join-Path $RepoPath 'pyproject.toml')) { return $true }
    if (Test-Path -LiteralPath (Join-Path $RepoPath 'requirements.txt')) { return $true }
    # Recursive on purpose (real-world bug fix): plenty of real Python repos
    # -- the trading repo that surfaced this is a live example -- keep all
    # their actual code a few directories deep (e.g. user_data\strategies\
    # *.py) with no manifest file at the root at all. Capped at
    # $PySearchMaxDepth and skipping $PySearchExcludedDirNames (so it never
    # wanders into .venv/node_modules/__pycache__ and misfires on someone
    # else's bundled *.py files, and never turns into an unbounded walk on
    # a huge repo) and stops at the very first match for speed.
    return (Test-HasNestedPyFile -DirPath $RepoPath -DepthRemaining $PySearchMaxDepth)
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
    # Config files ONLY -- deliberately does NOT treat "a tests/ dir exists"
    # as pytest config by itself anymore (real-world bug: MCP-2's tests/ is
    # unittest-based, not pytest, and the old version of this function
    # folded "has a tests dir" into "has pytest", so init-repo.ps1 always
    # assumed pytest -x -q was the right command regardless of what the
    # tests actually were). Whether a bare tests/ dir with no config at all
    # should still try pytest (the common no-config pytest style) is decided
    # by Get-PythonTestRunnerPlan, not here.
    if (Test-Path -LiteralPath (Join-Path $RepoPath 'pytest.ini')) { return $true }
    $pyproject = Read-TextFile -Path (Join-Path $RepoPath 'pyproject.toml')
    if ($null -ne $pyproject -and $pyproject -match '(?m)^\[tool\.pytest\.ini_options\]') { return $true }
    $setupCfg = Read-TextFile -Path (Join-Path $RepoPath 'setup.cfg')
    if ($null -ne $setupCfg -and $setupCfg -match '(?m)^\[tool:pytest\]') { return $true }
    return $false
}

# Locates a tests directory either at the repo root, or ONE level nested
# inside a subdirectory (the MCP-2 shape: app\tests, with the real project
# living under app\ and no tests/ at the repo root at all). Deliberately
# shallow (not a deep recursive search like the Python-file detector above)
# -- this is specifically about finding the ONE tests directory a test
# runner should be pointed at, not a general file search.
function Find-TestsDir {
    param([string]$RepoPath)
    foreach ($name in @('tests', 'test')) {
        if (Test-Path -LiteralPath (Join-Path $RepoPath $name) -PathType Container) {
            return [PSCustomObject]@{ Found = $true; StartDir = $name; ParentSubdir = $null }
        }
    }
    $subDirs = @(Get-ChildItem -LiteralPath $RepoPath -Directory -ErrorAction SilentlyContinue | Where-Object { $PySearchExcludedDirNames -notcontains $_.Name })
    foreach ($sub in $subDirs) {
        foreach ($name in @('tests', 'test')) {
            if (Test-Path -LiteralPath (Join-Path $sub.FullName $name) -PathType Container) {
                return [PSCustomObject]@{ Found = $true; StartDir = $name; ParentSubdir = $sub.Name }
            }
        }
    }
    return [PSCustomObject]@{ Found = $false; StartDir = $null; ParentSubdir = $null }
}

# Real signal that a repo's tests are written against the standard library's
# unittest module (as opposed to plain pytest-style "def test_x():"
# functions, which need no such import) -- confirmed against MCP-2's actual
# test files, which import unittest and subclass unittest.TestCase.
function Test-TestsDirUsesUnittest {
    param([string]$RepoPath, [PSCustomObject]$TestsDirInfo)
    if (-not $TestsDirInfo.Found) { return $false }
    $base = $RepoPath
    if ($null -ne $TestsDirInfo.ParentSubdir) { $base = Join-Path $RepoPath $TestsDirInfo.ParentSubdir }
    $testsPath = Join-Path $base $TestsDirInfo.StartDir
    $pyFiles = @(Get-ChildItem -LiteralPath $testsPath -Filter '*.py' -File -Recurse -ErrorAction SilentlyContinue)
    foreach ($f in $pyFiles) {
        $content = Read-TextFile -Path $f.FullName
        if ($null -ne $content -and ($content -match '(?m)^\s*import unittest\b' -or $content -match '(?m)^\s*from unittest\b' -or $content -match 'unittest\.TestCase')) {
            return $true
        }
    }
    return $false
}

# Decides which Python test runner to ATTEMPT, in the priority order the
# real MCP-2 incident calls for:
#   a. An actual pytest config file -> pytest (highest confidence).
#   b. No pytest config, but the tests clearly import unittest /
#      subclass TestCase -> unittest, matching MCP-2's real shape exactly
#      (this is the fix for bug #1: assuming pytest just because a tests/
#      dir existed, when the repo's tests were never pytest's to run).
#   c. No pytest config, no unittest signal -> still attempt pytest as the
#      default (this is by far the most common shape for undecorated
#      "def test_x():" style tests, which need neither a config file nor a
#      unittest import to work correctly under pytest -- treating this as
#      an outright "unclear, skip" would regress the single most common
#      real-world case). Whether that guess actually works is exactly what
#      Test-PythonRunnerValidates below checks BEFORE anything gets
#      installed -- that verification, not a perfect guess here, is the
#      real fix for bug #2 (a test command that structurally fails must
#      never become an installed gate).
function Get-PythonTestRunnerPlan {
    param([string]$RepoPath)
    $testsDirInfo = Find-TestsDir -RepoPath $RepoPath
    if (-not $testsDirInfo.Found) {
        return [PSCustomObject]@{ Type = 'none'; TestsDirInfo = $testsDirInfo }
    }
    if (Test-HasPytestConfig -RepoPath $RepoPath) {
        return [PSCustomObject]@{ Type = 'pytest'; TestsDirInfo = $testsDirInfo }
    }
    if (Test-TestsDirUsesUnittest -RepoPath $RepoPath -TestsDirInfo $testsDirInfo) {
        return [PSCustomObject]@{ Type = 'unittest'; TestsDirInfo = $testsDirInfo }
    }
    return [PSCustomObject]@{ Type = 'pytest'; TestsDirInfo = $testsDirInfo }
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
    if ($Detected.PythonTestRunner -eq 'pytest') {
        $pytestFragment = Read-TextFile -Path (Join-Path $TemplatesDir 'pre-commit-test-pytest.yaml')
        $pytestFragment = $pytestFragment.Replace('<PYTHON_EXE>', $PythonExeForHook)
        $content += $pytestFragment
        $components.Add('pytest -x -q (pre-push)')
    }
    if ($Detected.PythonTestRunner -eq 'unittest') {
        $unittestFragment = Read-TextFile -Path (Join-Path $TemplatesDir 'pre-commit-test-unittest.yaml')
        $unittestFragment = $unittestFragment.Replace('<UNITTEST_ENTRY_CMD>', $Detected.UnittestEntryCmd)
        $content += $unittestFragment
        $components.Add('unittest discover (pre-push)')
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
    param([hashtable]$Detected, [string]$PythonExeForHook, [System.Collections.Generic.List[string]]$Components, [bool]$ConfigWritten, [string]$SkippedTestWarning = '')
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('## Calidad (quality-kit)')
    $lines.Add('')
    if ($ConfigWritten) {
        $lines.Add('Candados de commit instalados (pre-commit):')
        foreach ($c in $Components) { $lines.Add("- $c") }
        $lines.Add('')
        $lines.Add('Comandos para correr los candados a mano:')
        $lines.Add('- `pre-commit run --all-files` (todos los candados de commit)')
        if ($Detected.PythonTestRunner -eq 'pytest') { $lines.Add("- ``$PythonExeForHook -m pytest -x -q`` (pruebas, normalmente corren solas en cada ``git push``)") }
        if ($Detected.PythonTestRunner -eq 'unittest') { $lines.Add("- ``$($Detected.UnittestEntryCmd)`` (pruebas, normalmente corren solas en cada ``git push``)") }
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
    if ($SkippedTestWarning) {
        $lines.Add('')
        $lines.Add("ADVERTENCIA: $SkippedTestWarning")
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
    PythonTestRunner = 'none'
    UnittestEntryCmd = ''
    NpmTest = $false
}
if ($detected.Node) {
    $detected.Eslint = (Test-HasEslintConfig -RepoPath $RepoPath -PackageJson $packageJson)
    $detected.Prettier = (Test-HasPrettierConfig -RepoPath $RepoPath -PackageJson $packageJson)
    $detected.NpmTest = (Test-HasRealNpmTestScript -PackageJson $packageJson)
}

$stackLabel = 'generico (ni Python ni Node detectados -- solo los chequeos base)'
if ($detected.Python -and $detected.Node) { $stackLabel = 'Python + Node' }
elseif ($detected.Python) { $stackLabel = 'Python' }
elseif ($detected.Node) { $stackLabel = 'Node' }
Write-Host "Stack detectado: $stackLabel"

$pythonExeForHook = $null
$skippedTestWarning = ''
if ($detected.Python) {
    $runnerPlan = Get-PythonTestRunnerPlan -RepoPath $RepoPath
    if ($runnerPlan.Type -ne 'none') {
        $pythonExeForHook = Get-RepoPythonExe -RepoPath $RepoPath
        if (-not $pythonExeForHook) {
            Write-Host "==> ADVERTENCIA: se detectaron pruebas de Python ($($runnerPlan.Type)) pero no encontre ningun Python utilizable en esta maquina -- no se instala el candado de pre-push. Instala Python y volve a correr este script."
            $skippedTestWarning = "no se instalo el candado de pruebas (pre-push) porque no se encontro Python en esta maquina para correrlas. Instala Python y volve a correr init-repo.ps1."
        } else {
            if ($runnerPlan.Type -eq 'unittest') {
                if ($null -ne $runnerPlan.TestsDirInfo.ParentSubdir) {
                    # Mirrors the real hand-fix from the MCP-2 incident
                    # exactly: a nested tests dir (e.g. app\tests) needs a
                    # directory change before running discover, and a
                    # pre-commit "repo: local" hook has no working-directory
                    # key of its own -- "bash -c 'cd ... && ...'" is how the
                    # actual fix expressed that, and bash ships with any Git
                    # install (already a hard prerequisite for pre-commit
                    # itself), so it is always available where this runs.
                    $detected.UnittestEntryCmd = "bash -c 'cd $($runnerPlan.TestsDirInfo.ParentSubdir) && $pythonExeForHook -m unittest discover -s $($runnerPlan.TestsDirInfo.StartDir) -t . 2>&1 | tail -5'"
                } else {
                    $detected.UnittestEntryCmd = "$pythonExeForHook -m unittest discover -s $($runnerPlan.TestsDirInfo.StartDir) -t ."
                }
            }
            Write-Host "==> Verificando el runner de pruebas elegido ($($runnerPlan.Type)) antes de instalar el candado de pre-push..."
            $validation = Test-PythonRunnerValidates -RepoPath $RepoPath -PythonExeForHook $pythonExeForHook -RunnerPlan $runnerPlan
            if ($validation.Ok) {
                $detected.PythonTestRunner = $runnerPlan.Type
                Write-Host "==> El runner de pruebas ($($runnerPlan.Type)) funciona -- se instala el candado de pre-push."
            } else {
                # THE CORE LESSON: a test command that fails structurally
                # (crashes, wrong runner, or just does not finish) is worse
                # than no gate at all -- it blocks every push for a reason
                # that has nothing to do with the code being pushed (this
                # is exactly what happened live: pytest hit an internal
                # "ValueError: I/O operation on closed file" during capture
                # teardown on this Python version). So it is never
                # installed; this is a loud, impossible-to-miss warning
                # instead of a silently broken gate.
                Write-Host ''
                Write-Host "==> ADVERTENCIA: se detectaron pruebas de Python ($($runnerPlan.Type)) pero el comando fallo al verificarlo ($($validation.Detail)) -- NO se instala el candado de pre-push para no bloquear pushes por un problema del runner, no del codigo."
                Write-Host '==> Para agregarlo a mano una vez que lo arregles: corre el comando de pruebas vos mismo hasta que funcione, despues volve a correr init-repo.ps1.'
                Write-Host ''
                $skippedTestWarning = "se detectaron pruebas de Python ($($runnerPlan.Type)) pero el comando fallo al verificarlo ($($validation.Detail)) -- el candado de pre-push NO se instalo a proposito. Corre las pruebas a mano hasta confirmarlas y volve a correr init-repo.ps1."
            }
        }
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

$needsPrePush = (($detected.PythonTestRunner -ne 'none') -or $detected.NpmTest)
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

$sectionBody = Get-CalidadSectionBody -Detected $detected -PythonExeForHook $pythonExeForHook -Components $built.Components -ConfigWritten $configWritten -SkippedTestWarning $skippedTestWarning
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
if ($skippedTestWarning) {
    Write-Host "ADVERTENCIA: $skippedTestWarning"
}
Write-Host '=== Listo ==='
