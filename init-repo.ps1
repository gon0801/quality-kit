# quality-kit / init-repo.ps1
#
# Sets up deterministic quality guards (pre-commit hooks, optional pre-push
# tests, optional CI workflow, and a short "Calidad" note in the repo's own
# docs) inside a single repository. Run it from inside the repo you want to
# protect:
#
#   pwsh -NoProfile -File ./init-repo.ps1
#
# Idempotent: running it again re-checks everything and only changes what
# needs changing. Never touches a pre-existing, non-quality-kit config file
# of the same name -- it skips those and tells you so, rather than
# clobbering something you already had.
#
# Custom rules CAN live directly inside .pre-commit-config.yaml -- an
# earlier version of this comment pointed customizations at a separate
# ".pre-commit-config.local.yaml" file, but pre-commit does not natively
# merge multiple config files, so that advice was a dead end nobody could
# actually follow. Real incident this protects against now: another AI
# session added a documented "exclude:" line (with its own explanatory
# comment) directly in this file for a legitimate reason, and a later
# full-file regeneration silently deleted it. init-repo.ps1 now detects
# when the existing file differs from what it would generate today in ANY
# way -- not just "not ours at all" -- and preserves it untouched rather
# than guessing whether the difference is safe to overwrite.
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
$PythonRunnerMarker = 'QUALITY-KIT PYTHON RUNNER'
$CalidadStartMarker = '<!-- >>> QUALITY-KIT CALIDAD SECTION START -- managed by quality-kit''s init-repo.ps1. Do not hand-edit between these markers; re-running init-repo.ps1 will refresh this block cleanly. -->'
$CalidadEndMarker = '<!-- >>> QUALITY-KIT CALIDAD SECTION END -->'

function Get-CurrentPowerShellExe {
    $current = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    if ($current -and ((Split-Path -Leaf $current) -match '^(pwsh|powershell)(\.exe)?$')) { return $current }
    foreach ($name in @('pwsh', 'powershell')) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($null -ne $command) { return $command.Source }
    }
    throw 'No se encontro el ejecutable de PowerShell actual.'
}

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

function Copy-PortablePythonRunner {
    param([string]$RepoPath)
    $source = Join-Path $TemplatesDir 'quality-run-python-tests.py'
    $toolsDir = Join-Path $RepoPath 'tools'
    $target = Join-Path $toolsDir 'quality_run_python_tests.py'
    if (Test-Path -LiteralPath $target) {
        $existing = Read-TextFile -Path $target
        if ($null -eq $existing -or $existing -notmatch [regex]::Escape($PythonRunnerMarker)) {
            throw "Ya existe $target y no pertenece a quality-kit; no puedo instalar el runner portable sin pisarlo."
        }
    }
    if (-not (Test-Path -LiteralPath $toolsDir)) {
        New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
    }
    $content = Read-TextFile -Path $source
    Write-Utf8NoBomFile -Path $target -Content $content
    Write-Host '==> Runner portable de pruebas Python instalado/refrescado.'
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
    $candidates = @('python', 'python3', 'py', $KnownGoodPython)
    foreach ($c in $candidates) {
        if (Test-CommandWorks -Exe $c -TestArgs @('--version')) { return $c }
    }
    return $null
}

# Resolves a real, invocable path to bash the same way Git itself finds it
# -- NOT a bare 'bash' string. Real incident: on at least one machine,
# PowerShell's own process-launch mechanism cannot see bash on PATH at all
# (Get-Command bash finds nothing there), even though bash works perfectly
# fine for real git hooks (which run under Git Bash's own environment, not
# PowerShell's). Spawning a bare "bash" from PowerShell on a machine like
# that throws immediately -- and that is an INFRASTRUCTURE problem with how
# this validator looks for bash, not evidence that the hook itself (or bash
# itself) is broken. Tried in order: whatever PATH already resolves (works
# on machines where it is visible to PowerShell), then the two fixed
# locations Git for Windows itself installs bash.exe at.
function Get-BashExe {
    $viaPath = Get-Command bash -ErrorAction SilentlyContinue
    if ($null -ne $viaPath) { return $viaPath.Source }
    $fixedCandidates = @()
    if ($env:ProgramFiles) {
        $fixedCandidates += (Join-Path $env:ProgramFiles 'Git\bin\bash.exe')
        $fixedCandidates += (Join-Path $env:ProgramFiles 'Git\usr\bin\bash.exe')
    }
    foreach ($c in $fixedCandidates) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    return $null
}

# Prefer a repo-local virtualenv's Python (it has the repo's real
# dependencies installed, so pytest actually finds what it needs), falling
# back to whatever generic Python this machine has.
function Get-RepoPythonExe {
    param([string]$RepoPath)
    $venvCandidates = @(
        (Join-Path $RepoPath '.venv/bin/python'),
        (Join-Path $RepoPath '.venv\Scripts\python.exe'),
        (Join-Path $RepoPath 'venv/bin/python'),
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
        # SpawnFailed = $true is the key distinction lesson 3c adds: this
        # means OUR OWN validator could not even launch the process (wrong
        # path, exe missing, permissions) -- an infrastructure problem with
        # the check itself, NOT proof that the command/hook it was trying
        # to run is broken. Every other outcome below (ran and returned
        # non-zero, or timed out) means the process DID start, so
        # SpawnFailed stays $false there.
        return [PSCustomObject]@{ TimedOut = $false; SpawnFailed = $true; ExitCode = -1; Stdout = ''; Stderr = "No se pudo iniciar '$Exe': $_" }
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
        return [PSCustomObject]@{ TimedOut = $true; SpawnFailed = $false; ExitCode = -1; Stdout = ''; Stderr = '' }
    }
    $stdout = ''
    $stderr = ''
    try { $stdout = $stdoutTask.Result } catch {}
    try { $stderr = $stderrTask.Result } catch {}
    return [PSCustomObject]@{ TimedOut = $false; SpawnFailed = $false; ExitCode = $proc.ExitCode; Stdout = $stdout; Stderr = $stderr }
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
    # by Get-PythonTestRunnerCandidates, not here.
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

# Builds the ORDERED LIST of Python test runners to ATTEMPT, in the
# priority order the real MCP-2 incident calls for -- and, since lesson 3b
# (a SECOND live incident), as a real fallback CHAIN, not a single guess:
#   a. An actual pytest config file -> pytest first (highest confidence).
#      MCP-2 itself has both a pytest.ini AND unittest-style tests (its own
#      docs mandate unittest even though pytest.ini also exists) -- when
#      that happens, unittest is queued right behind pytest as a real
#      fallback, so a broken/wrong pytest does not mean giving up entirely.
#   b. No pytest config, but the tests clearly import unittest / subclass
#      TestCase -> unittest only, matching MCP-2's real shape (this is the
#      original fix for bug #1: assuming pytest just because a tests/ dir
#      existed, when the repo's tests were never pytest's to run).
#   c. No pytest config, no unittest signal -> pytest only, as the default
#      guess (this is by far the most common shape for undecorated
#      "def test_x():" style tests, which need neither a config file nor a
#      unittest import to work correctly under pytest -- treating this as
#      an outright "unclear, skip" would regress the single most common
#      real-world case).
# Whether the FIRST candidate actually works is exactly what
# Test-PythonRunnerValidates checks before anything gets installed; if it
# does not, the next candidate in this list (if any) gets the same
# treatment. Only when every candidate in the list fails does init-repo.ps1
# give up and warn -- that is bug #2's fix, still intact.
function Get-PythonTestRunnerCandidates {
    param([string]$RepoPath)
    $testsDirInfo = Find-TestsDir -RepoPath $RepoPath
    $candidates = New-Object System.Collections.Generic.List[PSCustomObject]
    if (-not $testsDirInfo.Found) {
        # The leading comma is NOT decorative -- confirmed live, this is a
        # real PowerShell 5.1 gotcha distinct from the Where-Object/.Count
        # one already documented at the top of this file: "return $list"
        # for an IEnumerable does not hand the list object itself back to
        # the caller, it ENUMERATES the list into the pipeline. An empty
        # list enumerates to zero items, so the caller's "$x = Get-Foo"
        # silently receives $null instead of an empty collection; a
        # one-item list enumerates to exactly that one item, unwrapped, so
        # the caller receives the bare element instead of a list containing
        # it. "return ,$list" wraps the list as the single element of an
        # outer one-item array, so exactly ONE item -- the list itself,
        # intact -- reaches the pipeline. Every early-return and the final
        # return in this function needs this, not just one of them.
        return ,$candidates
    }
    $hasPytestConfig = Test-HasPytestConfig -RepoPath $RepoPath
    $usesUnittest = Test-TestsDirUsesUnittest -RepoPath $RepoPath -TestsDirInfo $testsDirInfo
    if ($hasPytestConfig) {
        $candidates.Add([PSCustomObject]@{ Type = 'pytest'; TestsDirInfo = $testsDirInfo })
        if ($usesUnittest) {
            $candidates.Add([PSCustomObject]@{ Type = 'unittest'; TestsDirInfo = $testsDirInfo })
        }
    } elseif ($usesUnittest) {
        $candidates.Add([PSCustomObject]@{ Type = 'unittest'; TestsDirInfo = $testsDirInfo })
    } else {
        $candidates.Add([PSCustomObject]@{ Type = 'pytest'; TestsDirInfo = $testsDirInfo })
    }
    return ,$candidates
}

# Does this repo's CI already run the WHOLE Python suite? If it does, paying
# the full battery again on every local push is duplication -- and an expensive
# one: measured on a Windows machine the same suite took ~6 min locally vs
# ~1.5-2 min in Linux CI, and it is paid on EVERY push (17 pushes in one day =
# ~1.7 h of pure waiting; goncloud-Orbit, 2026-08-29). The gate is not dropped,
# it MOVES: pre-push keeps a fast smoke (collection) and CI owns the battery.
#
# "Runs the suite" means an actual pytest INVOCATION with no test paths -- a
# `pip install ... pytest ...` line does not count (that exact false positive
# was caught by a reviewer bot on the Orbit fix).
function Test-CiRunsFullPytest {
    param([string]$RepoPath)
    # ORDEN (hallazgo Greptile PR #3): en un repo NUEVO con remoto de GitHub
    # esta deteccion corre ANTES de que Copy-QualityWorkflowIfSafe escriba
    # quality.yml, asi que sin esto el repo nacia con la bateria completa en
    # local aunque la MISMA corrida le instalara el CI que la corre. La
    # plantilla del kit (templates/quality.yml) corre `pytest -n auto -q` entero
    # (o `pytest -q` con QUALITY_KIT_PYTEST_SERIAL=1): si el kit va a
    # instalarla, cuenta como CI que corre la suite.
    $nuestroWorkflow = Join-Path (Join-Path $RepoPath '.github\workflows') 'quality.yml'
    # El paso de tests de templates/quality.yml esta condicionado a
    # `hashFiles('pyproject.toml', 'requirements.txt') != ''`: SIN uno de esos
    # manifiestos CI se saltea la suite, y si ademas aligeraramos el hook local
    # la bateria no correria en NINGUN lado (hallazgo Greptile PR #3, 2a
    # pasada). Se exige el mismo predicado que usa el workflow.
    $tieneManifiesto = (Test-Path -LiteralPath (Join-Path $RepoPath 'pyproject.toml')) -or
                       (Test-Path -LiteralPath (Join-Path $RepoPath 'requirements.txt'))
    if ($tieneManifiesto -and (Test-HasGithubRemote -RepoPath $RepoPath)) {
        if (-not (Test-Path -LiteralPath $nuestroWorkflow)) { return $true }
        $existente = Read-TextFile -Path $nuestroWorkflow
        $plantilla = Get-QualityWorkflowContent -RepoPath $RepoPath
        # Un quality.yml AJENO no cuenta aca: no sabemos que corre, y ademas
        # el kit no lo pisa (Copy-QualityWorkflowIfSafe lo respeta). Cae al
        # analisis literal de abajo, que mira lo que realmente ejecuta. Un
        # workflow nuestro pero personalizado tambien cae al analisis literal:
        # conservar el marker no demuestra que el paso pytest siga intacto.
        if ($null -ne $existente -and $existente -eq $plantilla) { return $true }
    }
    $workflowsDir = Join-Path $RepoPath '.github\workflows'
    if (-not (Test-Path -LiteralPath $workflowsDir)) { return $false }
    foreach ($wf in Get-ChildItem -LiteralPath $workflowsDir -Filter '*.yml' -File -ErrorAction SilentlyContinue) {
        $contenido = Read-TextFile -Path $wf.FullName
        # El workflow del KIT tiene su paso de tests condicionado al manifiesto:
        # sin pyproject/requirements ese `pytest -q` NO corre, asi que leerlo
        # literalmente mentiria (hallazgo Greptile PR #4: el guard del
        # manifiesto se saltaba por esta segunda puerta).
        if (-not $tieneManifiesto -and $null -ne $contenido -and
            $contenido -match [regex]::Escape($WorkflowMarker)) { continue }
        foreach ($line in (Get-Content -LiteralPath $wf.FullName)) {
            $texto = $line.Trim()
            if ($texto -match '^[#-]') { continue }
            # quitar prefijos de entorno tipo "PYTHONPATH=. pytest -q"
            $sinEnv = [regex]::Replace($texto, '^(\s*[A-Za-z_][A-Za-z0-9_]*=\S*\s+)+', '')
            if ($sinEnv -match '^(pip|pip3|uv|poetry|npm|apt|apt-get|echo|printf)\b') { continue }
            if ($sinEnv -notmatch '(^|\s|/)pytest(\s|$)') { continue }
            $despues = ($sinEnv -split '(^|\s|/)pytest(\s|$)')[-1]
            # ACOTADA por filtro (-k/-m/--deselect/--last-failed) tampoco es la
            # bateria: corre un subconjunto (hallazgo Greptile PR #3).
            if ($despues -match '(^|\s)(-k|-m|--deselect|--lf|--last-failed|--ignore)(\s|=)') { continue }
            # Flags cuyo SIGUIENTE token es valor, no un path. Sin esto,
            # `pytest -n auto` / `pytest -c pytest.ini` se leian como pytest
            # acotado a la ruta "auto"/"pytest.ini" y CI NO contaba como
            # bateria completa (el pre-push volvia a cobrarla en local).
            $pytestFlagsConValor = '(?:-(?:n|c|p|o|W)|--(?:numprocesses|config|maxfail|junitxml|rootdir|basetemp|override-ini|tb|color|durations|confcutdir|import-mode))'
            $despues = [regex]::Replace($despues, '(^|\s)' + $pytestFlagsConValor + '(\s+|=)\S+', ' ')
            # ACOTADA por ruta: cualquier argumento posicional (no-opcion) es un
            # path o nodeid -- `pytest tests`, `pytest tests/x.py::test` incluidos.
            $args = ($despues -split '\s+') | Where-Object { $_ -ne '' }
            $posicionales = @($args | Where-Object { $_ -notmatch '^-' -and $_ -notmatch '^[A-Za-z_][A-Za-z0-9_]*=' })
            if ($posicionales.Count -gt 0) { continue }
            return $true
        }
    }
    return $false
}

# Computes the entry command for a freshly-chosen (not preserved-verbatim)
# candidate, the same way the main flow used to build it inline.
function Get-FreshEntryCmdForCandidate {
    param([PSCustomObject]$Candidate, [bool]$CiRunsFullSuite = $false)
    if ($Candidate.Type -eq 'pytest') {
        if ($CiRunsFullSuite) {
            # Smoke rapido y GENERICO: --collect-only importa todo el arbol de
            # tests y su conftest, asi que caza el error de sintaxis / import
            # roto / conftest reventado (lo que pondria CI en rojo al instante)
            # en segundos, sin correr la bateria que CI ya corre.
            return 'python tools/quality_run_python_tests.py pytest -x -q --collect-only'
        }
        return 'python tools/quality_run_python_tests.py pytest -x -q'
    }
    if ($null -ne $Candidate.TestsDirInfo.ParentSubdir) {
        # A nested tests dir needs a directory change before discovery.
        # The portable runner owns that change without depending on bash.
        return "python tools/quality_run_python_tests.py --cwd $($Candidate.TestsDirInfo.ParentSubdir) unittest discover -s $($Candidate.TestsDirInfo.StartDir) -t ."
    }
    return "python tools/quality_run_python_tests.py unittest discover -s $($Candidate.TestsDirInfo.StartDir) -t ."
}

# ------------------------------------------------------------------
# Never downgrade a working hook: lesson 3b from a SECOND live incident.
# Regenerating .pre-commit-config.yaml on every run (by design, for
# idempotency and to pick up stack changes) must never silently drop a
# pre-push test hook that is still working, just because fresh detection
# picked a different answer this time. Real incident: MCP-2 has BOTH
# pytest.ini AND unittest-style tests; a re-run's fresh detection tried
# pytest first (as the priority rules say), pytest failed validation
# (pytest is broken machine-wide on this Python version), and the OLD
# logic gave up entirely -- silently deleting the working unittest hook
# that a human had already hand-fixed into the config. The fix: before
# doing any fresh detection at all, check whether the EXISTING kit-managed
# config already has a Python pre-push test hook, and if that exact
# command still runs successfully, keep it byte-for-byte and skip fresh
# detection entirely.
# ------------------------------------------------------------------

# Finds the entry command of an existing pytest-pre-push or
# unittest-pre-push hook inside an already-generated .pre-commit-config.yaml
# (only ever called on a file already confirmed to carry the quality-kit
# marker -- never on a hand-written config, which init-repo.ps1 never reads
# hooks out of).
function Get-ExistingPythonTestHookEntry {
    param([string]$ExistingConfigText)
    if ($null -eq $ExistingConfigText) { return $null }
    foreach ($pair in @(@{ Id = 'pytest-pre-push'; Type = 'pytest' }, @{ Id = 'unittest-pre-push'; Type = 'unittest' })) {
        $pattern = '(?ms)-\s*id:\s*' + [regex]::Escape($pair.Id) + '\b.*?^\s*entry:\s*(.+?)\r?$'
        $m = [regex]::Match($ExistingConfigText, $pattern)
        if ($m.Success) {
            return [PSCustomObject]@{ Type = $pair.Type; Entry = $m.Groups[1].Value.Trim() }
        }
    }
    return $null
}

# Runs an existing hook's entry command EXACTLY as pre-commit itself would
# (not a cheaper "--collect-only" stand-in like fresh detection uses) --
# this is checking "does the thing that is already configured still work",
# not "would some new command work", so it has to be the real thing. Two
# shapes only, since these are the only two this script itself ever
# writes: a plain "<exe> <args...>" command, or our own
# "bash -c '<command>'" wrapper for the nested-tests-dir case.
function Invoke-ExistingEntryCommand {
    param([string]$Entry, [string]$RepoPath, [int]$TimeoutSeconds = 60)
    $bashMatch = [regex]::Match($Entry, "^bash -c '(.*)'$")
    if ($bashMatch.Success) {
        # Real incident (lesson 3c): spawning a bare "bash" from PowerShell
        # threw immediately on a machine where PowerShell's own PATH
        # resolution cannot see it, even though the exact same command
        # works fine as a real git hook (which runs under Git Bash's own
        # environment). Resolving the real path first, the same way Git
        # itself would find bash, fixes this without changing what
        # actually gets run.
        $inner = $bashMatch.Groups[1].Value
        $bashExe = Get-BashExe
        if ($null -eq $bashExe) {
            return [PSCustomObject]@{ TimedOut = $false; SpawnFailed = $true; ExitCode = -1; Stdout = ''; Stderr = 'No se encontro bash.exe en esta maquina (ni en PATH ni en las rutas de instalacion de Git).' }
        }
        return Invoke-CommandWithTimeout -Exe $bashExe -Arguments ('-c "' + $inner + '"') -WorkingDirectory $RepoPath -TimeoutSeconds $TimeoutSeconds
    }
    $splitIdx = $Entry.IndexOf(' ')
    if ($splitIdx -lt 0) {
        return Invoke-CommandWithTimeout -Exe $Entry -Arguments '' -WorkingDirectory $RepoPath -TimeoutSeconds $TimeoutSeconds
    }
    $exe = $Entry.Substring(0, $splitIdx)
    $rest = $Entry.Substring($splitIdx + 1)
    return Invoke-CommandWithTimeout -Exe $exe -Arguments $rest -WorkingDirectory $RepoPath -TimeoutSeconds $TimeoutSeconds
}

# Checks whether the repo's EXISTING, already-kit-managed config has a
# Python pre-push hook that still works. Returns $null if there is no such
# existing config/hook to preserve (first-ever run, or a "generic"/no-tests
# state before) -- in that case the caller falls through to fresh
# detection as normal.
function Test-ExistingPythonHookStillValidates {
    param([string]$RepoPath)
    $configPath = Join-Path $RepoPath '.pre-commit-config.yaml'
    $existingConfigText = Read-TextFile -Path $configPath
    if ($null -eq $existingConfigText -or $existingConfigText -notmatch [regex]::Escape($PreCommitConfigMarker)) {
        return $null
    }
    $existingHook = Get-ExistingPythonTestHookEntry -ExistingConfigText $existingConfigText
    if ($null -eq $existingHook) {
        return $null
    }
    Write-Host "==> Ya habia un candado de pruebas de Python ($($existingHook.Type)) de una corrida anterior -- lo verifico antes de decidir si hace falta volver a detectar el runner..."
    $result = Invoke-ExistingEntryCommand -Entry $existingHook.Entry -RepoPath $RepoPath -TimeoutSeconds 60
    if ($result.SpawnFailed) {
        # THE SHARPENED INVARIANT (lesson 3c): a real incident showed this
        # distinction matters. The validator itself failed to even launch
        # the check (here: bash was not resolvable from PowerShell on that
        # machine) -- that is OUR infrastructure problem, not proof the
        # hook is broken (the real git hook ran that exact command fine,
        # under Git Bash's own environment). Since we cannot prove it is
        # broken, we must not degrade it: keep it exactly as it is.
        Write-Host "==> No se pudo verificar el candado existente ($($existingHook.Type)) por un problema de esta maquina, no del candado en si ($($result.Stderr)) -- lo mantengo tal cual sin tocarlo (no se puede probar que este roto, asi que no se degrada)."
        return $existingHook
    }
    if ($result.TimedOut -or $result.ExitCode -ne 0) {
        Write-Host "==> El candado de pruebas existente ($($existingHook.Type)) ya NO funciona ($(Get-ValidationFailureDetail $result)) -- vuelvo a detectar desde cero."
        return $null
    }
    Write-Host "==> El candado de pruebas existente ($($existingHook.Type)) todavia funciona -- lo mantengo tal cual, sin volver a detectar (nunca se degrada un candado que funciona)."
    return $existingHook
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

function Test-HasJestOrVitest {
    param($PackageJson)
    # Solo el script `test` importa: `--shard` se le pasa a `npm test`. Un
    # jest/vitest en devDependencies con `scripts.test = node --test` no se
    # shardea (el runner no entiende --shard).
    if (-not (Test-HasRealNpmTestScript -PackageJson $PackageJson)) { return $false }
    $testCmd = [string]$PackageJson.scripts.test
    if ($testCmd -match '(^|[\s/])(jest|vitest)(\s|$)') { return $true }
    return $false
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

# Substitutes a placeholder ONLY where it appears as the value of an
# "entry:" line -- NOT anywhere else the same token might appear (a real
# bug found while testing this: both test-runner templates also mention
# their own placeholder inside their explanatory comments, so a naive
# whole-text .Replace() corrupted that prose with the actual command text
# whenever the entry value differed from what the comment happened to
# already say). Uses a MatchEvaluator (not a plain replacement string) so
# a "$" that might appear inside the real entry command (unlikely here,
# but not impossible in an arbitrary path) is never misread as a regex
# backreference.
function Set-TemplateEntryPlaceholder {
    param([string]$TemplateText, [string]$Placeholder, [string]$ReplacementValue)
    $pattern = '(?m)^(\s*entry:\s*)' + [regex]::Escape($Placeholder) + '\s*$'
    $evaluator = [System.Text.RegularExpressions.MatchEvaluator] { param($m) $m.Groups[1].Value + $ReplacementValue }
    return [regex]::Replace($TemplateText, $pattern, $evaluator)
}

function Build-PreCommitConfigContent {
    param([string]$RepoPath, [hashtable]$Detected)
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
        # <PYTEST_ENTRY_CMD> is either freshly built ("<python> -m pytest -x
        # -q") or, when an already-working hook existed, reused VERBATIM --
        # see Test-ExistingPythonHookStillValidates below for why that
        # matters (never downgrade a working gate to nothing on a re-run).
        $pytestFragment = Read-TextFile -Path (Join-Path $TemplatesDir 'pre-commit-test-pytest.yaml')
        $pytestFragment = Set-TemplateEntryPlaceholder -TemplateText $pytestFragment -Placeholder '<PYTEST_ENTRY_CMD>' -ReplacementValue $Detected.PytestEntryCmd
        $content += $pytestFragment
        $components.Add('pytest -x -q (pre-push)')
    }
    if ($Detected.PythonTestRunner -eq 'unittest') {
        $unittestFragment = Read-TextFile -Path (Join-Path $TemplatesDir 'pre-commit-test-unittest.yaml')
        $unittestFragment = Set-TemplateEntryPlaceholder -TemplateText $unittestFragment -Placeholder '<UNITTEST_ENTRY_CMD>' -ReplacementValue $Detected.UnittestEntryCmd
        $content += $unittestFragment
        $components.Add('unittest discover (pre-push)')
    }
    if ($Detected.NpmTest) {
        $content += (Read-TextFile -Path (Join-Path $TemplatesDir 'pre-commit-test-npm.yaml'))
        $components.Add('npm test (pre-push)')
    }

    return [PSCustomObject]@{ Content = $content; Components = $components }
}

# Lines present in $ExistingText but NOT present anywhere in
# $CandidateText -- a deliberately simple line-set difference (not a real
# diff algorithm), good enough to surface an added "exclude:" key or an
# explanatory comment a person added by hand, without needing anything
# fancier than that for this purpose.
function Get-CustomLines {
    param([string]$ExistingText, [string]$CandidateText)
    $existingLines = @($ExistingText -split "`r?`n")
    $candidateLinesSet = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($line in @($CandidateText -split "`r?`n")) { $candidateLinesSet.Add($line) | Out-Null }
    $custom = New-Object System.Collections.Generic.List[string]
    foreach ($line in $existingLines) {
        if (-not $candidateLinesSet.Contains($line)) { $custom.Add($line) }
    }
    # Leading comma: PowerShell 5.1 unrolls a returned collection into the
    # pipeline instead of handing back the list object itself (the same
    # real gotcha documented at Get-PythonTestRunnerCandidates above) --
    # without it, zero or one detected custom lines would come back as
    # $null or a bare string instead of a real (possibly empty) list.
    return ,$custom
}

function Write-PreCommitConfigIfSafe {
    # Returns one of three outcomes, not a plain bool, so the rest of the
    # script (and the Calidad doc) can tell apart "we never touched this
    # because it's not ours" from "we never touched this because it's
    # ours but customized" -- they need different, honest messages.
    #   'Written'    -> we wrote/regenerated the file, safe to describe our hooks.
    #   'Foreign'    -> the file exists and was never quality-kit's to begin with.
    #   'Customized' -> the file is kit-managed but differs from what we'd
    #                   generate today; preserved untouched, customization warned.
    param([string]$RepoPath, [string]$NewContent)
    $configPath = Join-Path $RepoPath '.pre-commit-config.yaml'
    if (Test-Path -LiteralPath $configPath) {
        $existing = Read-TextFile -Path $configPath
        if ($null -ne $existing -and $existing -notmatch [regex]::Escape($PreCommitConfigMarker)) {
            Write-Host "==> Ya existe .pre-commit-config.yaml y NO fue generado por quality-kit -- no lo toco, para no pisar tu configuracion."
            return 'Foreign'
        }
        if ($null -ne $existing -and $existing -ne $NewContent) {
            # THE FIX (real incident, twice): a kit-managed file that
            # differs in ANY way from what init-repo.ps1 would generate
            # today (for the current detected stack, and reusing an
            # already-validated test hook verbatim per the never-degrade
            # fixes above) is NOT assumed stale -- it might carry a real,
            # deliberate customization someone added directly in the file
            # (confirmed live: a documented "exclude:" line with its own
            # explanatory comment, added by another AI session for a real
            # reason). A full-file rewrite used to delete that silently.
            # Never again: ANY difference means preserve the file exactly
            # as it is, and say so loudly -- never guess which differences
            # are "safe" to overwrite. This also means a repo whose stack
            # genuinely changed since the last run will now ALSO be left
            # alone here rather than silently upgraded -- an intentional
            # trade-off (erring toward never touching a file someone may
            # have hand-edited) confirmed and accepted for this kit.
            $customLines = Get-CustomLines -ExistingText $existing -CandidateText $NewContent
            Write-Host '==> Config personalizado detectado -- se conserva .pre-commit-config.yaml tal cual, no se sobreescribe.'
            $realCustomLines = @($customLines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($realCustomLines.Count -gt 0) {
                Write-Host '    Lineas que el kit no reconoce (probablemente algo agregado a mano):'
                foreach ($line in $realCustomLines) {
                    Write-Host "      $($line.Trim())"
                }
            }
            Write-Host '    Si el kit necesita actualizar sus propios fragmentos aca, fusiona a mano (o pedile a una IA con contexto de este archivo que lo haga) -- init-repo.ps1 no fusiona automaticamente.'
            return 'Customized'
        }
    }
    Write-Utf8NoBomFile -Path $configPath -Content $NewContent
    Write-Host '==> Escribi .pre-commit-config.yaml'
    return 'Written'
}

# ------------------------------------------------------------------
# GitHub Actions workflow
# ------------------------------------------------------------------

function Get-QualityWorkflowContent {
    param([string]$RepoPath)
    $templateContent = Read-TextFile -Path (Join-Path $TemplatesDir 'quality.yml')
    $pytestCmd = 'pytest -n auto -q'
    if ($env:QUALITY_KIT_PYTEST_SERIAL -eq '1') {
        $pytestCmd = 'pytest -q'
    }
    $packageJson = Get-PackageJson -RepoPath $RepoPath
    $shardNode = Test-HasJestOrVitest -PackageJson $packageJson

    $nodeInQuality = "      - name: Run Node tests`n        if: hashFiles('package.json') != ''`n        run: npm test --if-present"
    $nodeShardJob = ''
    $gateNeeds = '[quality]'
    $gateEnv = '          R_QUALITY: ${{ needs.quality.result }}'
    $gateFor = '"quality=$R_QUALITY"'
    if ($shardNode) {
        $nodeInQuality = ''
        $nodeShardJob = @'

  quality-node:
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        shard: ['1/2', '2/2']
    steps:
      - uses: actions/checkout@v7
      - name: Set up Node
        uses: actions/setup-node@v6
        with:
          node-version: '20'
      - name: Install Node dependencies
        if: hashFiles('package.json') != ''
        run: |
          if [ -f package-lock.json ]; then npm ci
          else npm install
          fi
      - name: Run Node tests (shard)
        run: npm test -- --shard=${{ matrix.shard }}
'@
        $gateNeeds = '[quality, quality-node]'
        $gateEnv = @'
          R_QUALITY: ${{ needs.quality.result }}
          R_NODE: ${{ needs['quality-node'].result }}
'@
        $gateFor = '"quality=$R_QUALITY" "quality-node=$R_NODE"'
    }

    # .Replace() literal (no regex): el yaml interpola `${{ }}` y un -replace
    # de PowerShell lo corromperia.
    $content = $templateContent.Replace('__PYTEST_CMD__', $pytestCmd)
    $content = $content.Replace('__NODE_IN_QUALITY_JOB__', $nodeInQuality)
    $content = $content.Replace('__NODE_SHARD_JOB__', $nodeShardJob)
    $content = $content.Replace('__GATE_NEEDS__', $gateNeeds)
    $content = $content.Replace('__GATE_RESULTS_ENV__', $gateEnv)
    $content = $content.Replace('__GATE_RESULTS_FOR__', $gateFor)
    return $content
}

function Copy-QualityWorkflowIfSafe {
    param([string]$RepoPath)
    $workflowDir = Join-Path $RepoPath '.github\workflows'
    $workflowPath = Join-Path $workflowDir 'quality.yml'
    $generated = Get-QualityWorkflowContent -RepoPath $RepoPath
    if (Test-Path -LiteralPath $workflowPath) {
        $existing = Read-TextFile -Path $workflowPath
        if ($null -ne $existing -and $existing -notmatch [regex]::Escape($WorkflowMarker)) {
            Write-Host "==> Ya existe .github\workflows\quality.yml y NO fue generado por quality-kit -- no lo toco."
            return $false
        }
        if ($null -ne $existing -and $existing -ne $generated) {
            Write-Host "==> .github\workflows\quality.yml fue generado por quality-kit pero ya no coincide con la plantilla actual (edicion o plantilla vieja) -- no lo toco. Para adoptar la plantilla nueva, borralo y re-corre init-repo.ps1."
            return $false
        }
    }
    if (-not (Test-Path -LiteralPath $workflowDir)) {
        New-Item -ItemType Directory -Path $workflowDir -Force | Out-Null
    }
    Write-Utf8NoBomFile -Path $workflowPath -Content $generated
    Write-Host '==> Escribi .github\workflows\quality.yml'
    return $true
}

# ------------------------------------------------------------------
# CLAUDE.md / AGENTS.md "Calidad" section
# ------------------------------------------------------------------

function Get-CalidadSectionBody {
    param([hashtable]$Detected, [System.Collections.Generic.List[string]]$Components, [string]$ConfigOutcome, [string]$SkippedTestWarning = '')
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('## Calidad (quality-kit)')
    $lines.Add('')
    if ($ConfigOutcome -eq 'Written') {
        $lines.Add('Candados de commit instalados (pre-commit):')
        foreach ($c in $Components) { $lines.Add("- $c") }
        $lines.Add('')
        $lines.Add('Comandos para correr los candados a mano:')
        $lines.Add('- `pre-commit run --all-files` (todos los candados de commit)')
        if ($Detected.PythonTestRunner -eq 'pytest') { $lines.Add("- ``$($Detected.PytestEntryCmd)`` (pruebas, normalmente corren solas en cada ``git push``)") }
        if ($Detected.PythonTestRunner -eq 'unittest') { $lines.Add("- ``$($Detected.UnittestEntryCmd)`` (pruebas, normalmente corren solas en cada ``git push``)") }
        if ($Detected.NpmTest) { $lines.Add('- `npm test` (pruebas, normalmente corren solas en cada `git push`)') }
    } elseif ($ConfigOutcome -eq 'Customized') {
        # Kit-managed, but it now differs from what we'd generate today --
        # someone (or another AI) added something directly in the file.
        # Never claim ownership of hooks we didn't actually write; point at
        # the real file instead, same as the "foreign" case, but honestly
        # worded (this file genuinely started as ours).
        $lines.Add('Este archivo `.pre-commit-config.yaml` tiene agregados propios (detectados por quality-kit) -- no lo pisamos.')
        $lines.Add('Para ver que candados tiene realmente: `pre-commit run --all-files` (o mira `.pre-commit-config.yaml`).')
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
    $lines.Add('8. CI: la bateria completa corre en jobs paralelos cuya union es la bateria (con candado); si un job pasa de ~10 min se shardea, nunca se recorta ni se saltea por tipo de cambio.')
    $lines.Add('   Checks de docs/ledger en un job propio de segundos. Carril: docs/chore/cierre = fast; codigo = gate; medicion/release = +cross-review. Cierres de ledger de un bloque = un PR.')
    $lines.Add('')
    $lines.Add('Flujo de verificacion:')
    $lines.Add('- Durante la implementacion, corre solo las pruebas focalizadas del comportamiento modificado.')
    $lines.Add('- Agrupa los hallazgos de revision y corrigelos en una sola ronda por bloque. Solo un hallazgo bloqueante (seguridad, datos, regla innegociable, comportamiento pedido roto o prueba que no discrimina), con el comando que lo reproduce, abre otra ronda; cada ronda siguiente revisa solo el diff de los arreglos (cross-review -Con <otro revisor> -Desde <sha>). Se repite mientras salga un bloqueante y para en la primera ronda sin ninguno; si el mismo bloqueante vuelve en dos rondas seguidas, decide el operador.')
    $lines.Add('- Ejecuta Ruff y las pruebas focalizadas despues del ultimo cambio del bloque.')
    $lines.Add('- Ejecuta la bateria completa una sola vez por bloque, sobre el commit final y preferentemente en CI mediante PR.')
    $lines.Add('- Si commit, push o CI ya validaron tests, Ruff o pre-commit sobre ese SHA, no los repitas manualmente.')
    $lines.Add('- No vuelvas a ejecutar CI si el commit verificado no cambio.')
    $lines.Add('- Un bloqueante nunca va a una fila del plan ni se mergea abierto: se corrige o decide el operador. Lo no bloqueante que no se corrige va a una fila del plan (Plans.md o el tracker del repo) y se nombra en el PR; una observacion tardia no bloqueante no reabre el ciclo.')
    $lines.Add('- Despues del deploy, ejecuta una sola vez el checklist del repo y no repitas evidencia valida sin un cambio que pueda invalidarla.')
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
    PytestEntryCmd = ''
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

$skippedTestWarning = ''
if ($detected.Python) {
    # STEP 1 -- never downgrade a working hook: check the EXISTING
    # kit-managed config first. If it already has a Python pre-push hook
    # and that exact command still runs successfully, keep it verbatim and
    # skip fresh detection entirely (see Test-ExistingPythonHookStillValidates
    # for the real incident this fixes).
    $existingHook = Test-ExistingPythonHookStillValidates -RepoPath $RepoPath
    if ($null -ne $existingHook) {
        $detected.PythonTestRunner = $existingHook.Type
        if ($existingHook.Type -eq 'pytest') { $detected.PytestEntryCmd = $existingHook.Entry }
        else { $detected.UnittestEntryCmd = $existingHook.Entry }
        # Un candado que funciona JAMAS se toca solo (esa es la regla). Pero si
        # esta pagando la bateria entera en cada push y CI ya la corre, eso es
        # duplicacion cara (~6 min por push medidos en Windows): se AVISA, con
        # el comando exacto, y lo decide la persona.
        if ($existingHook.Type -eq 'pytest' -and
            $existingHook.Entry -notmatch '--collect-only' -and
            $existingHook.Entry -notmatch '(tests?/|\.py)(\s|$)' -and
            (Test-CiRunsFullPytest -RepoPath $RepoPath)) {
            Write-Host '==> AVISO: el candado de pre-push corre la bateria COMPLETA y CI ya la corre tambien. Es duplicacion cara (medido: ~6 min por push en Windows vs ~1.5-2 min en CI).'
            Write-Host "    Si queres moverla: en .pre-commit-config.yaml deja el entry como '$($existingHook.Entry) --collect-only' (smoke rapido) y que CI siga corriendo la bateria entera."
            Write-Host '    No lo cambio yo: un candado que funciona no se degrada sin tu decision.'
        }
    } else {
        # STEP 2 -- fresh detection with a FALLBACK CHAIN: try each
        # candidate runner in priority order; the first one that actually
        # validates wins. Only if EVERY candidate fails does this give up
        # and warn (mentioning everything that was tried).
        $candidates = Get-PythonTestRunnerCandidates -RepoPath $RepoPath
        if ($candidates.Count -gt 0) {
            $pythonExeForHook = Get-RepoPythonExe -RepoPath $RepoPath
            if (-not $pythonExeForHook) {
                $candidateTypes = ($candidates | ForEach-Object { $_.Type }) -join ', '
                Write-Host "==> ADVERTENCIA: se detectaron pruebas de Python ($candidateTypes) pero no encontre ningun Python utilizable en esta maquina -- no se instala el candado de pre-push. Instala Python y volve a correr este script."
                $skippedTestWarning = "no se instalo el candado de pruebas (pre-push) porque no se encontro Python en esta maquina para correrlas. Instala Python y volve a correr init-repo.ps1."
            } else {
                $attempts = New-Object System.Collections.Generic.List[string]
                $chosenCandidate = $null
                $chosenEntryCmd = ''
                $ciCorreLaSuite = Test-CiRunsFullPytest -RepoPath $RepoPath
                if ($ciCorreLaSuite) {
                    Write-Host '==> CI ya corre la bateria completa de pytest: el candado de pre-push queda RAPIDO (smoke de coleccion) y la bateria se cobra UNA vez, en CI.'
                }
                foreach ($candidate in $candidates) {
                    $entryCmd = Get-FreshEntryCmdForCandidate -Candidate $candidate -CiRunsFullSuite $ciCorreLaSuite
                    Write-Host "==> Verificando el runner de pruebas ($($candidate.Type)) antes de instalar el candado de pre-push..."
                    $validation = Test-PythonRunnerValidates -RepoPath $RepoPath -PythonExeForHook $pythonExeForHook -RunnerPlan $candidate
                    if ($validation.Ok) {
                        $chosenCandidate = $candidate
                        $chosenEntryCmd = $entryCmd
                        break
                    }
                    $attempts.Add("$($candidate.Type) ($($validation.Detail))")
                }
                if ($null -ne $chosenCandidate) {
                    $detected.PythonTestRunner = $chosenCandidate.Type
                    if ($chosenCandidate.Type -eq 'pytest') { $detected.PytestEntryCmd = $chosenEntryCmd }
                    else { $detected.UnittestEntryCmd = $chosenEntryCmd }
                    if ($attempts.Count -gt 0) {
                        Write-Host "==> El runner de pruebas ($($chosenCandidate.Type)) funciono como alternativa, despues de que fallara: $($attempts -join '; ')."
                    } else {
                        Write-Host "==> El runner de pruebas ($($chosenCandidate.Type)) funciona -- se instala el candado de pre-push."
                    }
                } else {
                    # THE CORE LESSON: a test command that fails
                    # structurally (crashes, wrong runner, or just does not
                    # finish) is worse than no gate at all -- it blocks
                    # every push for a reason that has nothing to do with
                    # the code being pushed (this is exactly what happened
                    # live: pytest hit an internal "ValueError: I/O
                    # operation on closed file" during capture teardown on
                    # this Python version). So it is never installed; this
                    # is a loud, impossible-to-miss warning instead of a
                    # silently broken gate, and it names every runner that
                    # was tried so there is no need to guess.
                    $attemptsText = $attempts -join '; '
                    Write-Host ''
                    Write-Host "==> ADVERTENCIA: se probaron estos runners de Python y todos fallaron al verificarlos: $attemptsText -- NO se instala el candado de pre-push para no bloquear pushes por un problema del runner, no del codigo."
                    Write-Host '==> Para agregarlo a mano una vez que lo arregles: corre el comando de pruebas vos mismo hasta que funcione, despues volve a correr init-repo.ps1.'
                    Write-Host ''
                    $skippedTestWarning = "se probaron estos runners de Python y todos fallaron al verificarlos: $attemptsText -- el candado de pre-push NO se instalo a proposito. Corre las pruebas a mano hasta confirmarlas y volve a correr init-repo.ps1."
                }
            }
        }
    }
}

$portableRunnerNeeded = (($detected.PythonTestRunner -eq 'pytest') -or ($detected.PythonTestRunner -eq 'unittest'))
if ($portableRunnerNeeded) {
    Copy-PortablePythonRunner -RepoPath $RepoPath
}

$built = Build-PreCommitConfigContent -RepoPath $RepoPath -Detected $detected
$configOutcome = Write-PreCommitConfigIfSafe -RepoPath $RepoPath -NewContent $built.Content
$configWritten = ($configOutcome -eq 'Written')

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

# Politica de push a ramas protegidas (claude-code-harness). init-repo corre
# SIEMPRE en manos del operador, asi que instalarla aca respeta el
# control-plane: el agente sigue sin poder escribirla desde una sesion.
# `allow` SOLO cuando la red quedo armada en este mismo repo: candados de
# pre-commit (instalados unas lineas arriba, o el script ya habria tirado) +
# remoto de GitHub + algun workflow de CI. Sin esa red se saltea con aviso --
# un allow desnudo dejaria la rama protegida sin nada que la respalde, que es
# exactamente lo que la politica presupone que existe.
$policyOutcome = 'salteada (sin remoto de GitHub o sin CI)'
$policyScript = Join-Path $QualityKitDir 'install-branch-push-policy.ps1'
$ciWorkflowsDir = Join-Path $RepoPath '.github\workflows'
$hasCiNet = $false
if (Test-Path -LiteralPath $ciWorkflowsDir) {
    $hasCiNet = (@(Get-ChildItem -LiteralPath $ciWorkflowsDir -Filter '*.y*ml' -File -ErrorAction SilentlyContinue).Count -gt 0)
}
if (-not (Test-Path -LiteralPath $policyScript)) {
    Write-Host '==> [!] Falta install-branch-push-policy.ps1 en el kit -- politica de push no instalada.'
    $policyOutcome = 'no instalada (kit incompleto)'
} elseif ($hasGithubRemote -and $hasCiNet) {
    $powerShellExe = Get-CurrentPowerShellExe
    & $powerShellExe -NoProfile -ExecutionPolicy Bypass -File $policyScript -RepoPath $RepoPath -Mode allow
    if ($LASTEXITCODE -eq 0) {
        $policyOutcome = 'allow (red armada: pre-commit + CI)'
    } else {
        $policyOutcome = "fallo (codigo $LASTEXITCODE) -- ver arriba"
    }
} else {
    Write-Host '==> Salteo la politica de push a ramas protegidas: `allow` presupone la red (remoto de GitHub + CI en cada push). Se instala al re-correr este script cuando el repo la tenga, o a mano con install-branch-push-policy.ps1 (-Mode ask si la red no va a existir).'
}

$sectionBody = Get-CalidadSectionBody -Detected $detected -Components $built.Components -ConfigOutcome $configOutcome -SkippedTestWarning $skippedTestWarning
Update-CalidadDoc -DocPath (Join-Path $RepoPath 'CLAUDE.md') -SectionBody $sectionBody
Update-CalidadDoc -DocPath (Join-Path $RepoPath 'AGENTS.md') -SectionBody $sectionBody

Write-Host ''
Write-Host '=== Resumen ==='
Write-Host "Stack: $stackLabel"
if ($configOutcome -eq 'Written') {
    Write-Host "Candados configurados: $($built.Components -join ', ')"
} elseif ($configOutcome -eq 'Customized') {
    Write-Host 'Candados configurados: (el .pre-commit-config.yaml tiene agregados propios -- no se toco, ver arriba)'
} else {
    Write-Host 'Candados configurados: (el repo ya tenia su propio .pre-commit-config.yaml -- no se toco)'
}
Write-Host "Pre-push (pruebas): $needsPrePush"
Write-Host "Workflow de CI copiado: $workflowWritten (remoto de GitHub detectado: $hasGithubRemote)"
Write-Host "Politica de push (claude-code-harness): $policyOutcome"
Write-Host "CLAUDE.md / AGENTS.md actualizados con la seccion Calidad."
if ($skippedTestWarning) {
    Write-Host "ADVERTENCIA: $skippedTestWarning"
}
Write-Host '=== Listo ==='
