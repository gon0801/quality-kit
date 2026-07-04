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
    $fixedCandidates = @(
        (Join-Path $env:ProgramFiles 'Git\bin\bash.exe'),
        (Join-Path $env:ProgramFiles 'Git\usr\bin\bash.exe')
    )
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

# Computes the entry command for a freshly-chosen (not preserved-verbatim)
# candidate, the same way the main flow used to build it inline.
function Get-FreshEntryCmdForCandidate {
    param([PSCustomObject]$Candidate, [string]$PythonExeForHook)
    if ($Candidate.Type -eq 'pytest') {
        return "$PythonExeForHook -m pytest -x -q"
    }
    if ($null -ne $Candidate.TestsDirInfo.ParentSubdir) {
        # Mirrors the real hand-fix from the MCP-2 incident exactly: a
        # nested tests dir (e.g. app\tests) needs a directory change before
        # running discover, and a pre-commit "repo: local" hook has no
        # working-directory key of its own -- "bash -c 'cd ... && ...'" is
        # how the actual fix expressed that, and bash ships with any Git
        # install (already a hard prerequisite for pre-commit itself), so
        # it is always available where this runs.
        return "bash -c 'cd $($Candidate.TestsDirInfo.ParentSubdir) && $PythonExeForHook -m unittest discover -s $($Candidate.TestsDirInfo.StartDir) -t . 2>&1 | tail -5'"
    }
    return "$PythonExeForHook -m unittest discover -s $($Candidate.TestsDirInfo.StartDir) -t ."
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
    param([hashtable]$Detected, [System.Collections.Generic.List[string]]$Components, [bool]$ConfigWritten, [string]$SkippedTestWarning = '')
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('## Calidad (quality-kit)')
    $lines.Add('')
    if ($ConfigWritten) {
        $lines.Add('Candados de commit instalados (pre-commit):')
        foreach ($c in $Components) { $lines.Add("- $c") }
        $lines.Add('')
        $lines.Add('Comandos para correr los candados a mano:')
        $lines.Add('- `pre-commit run --all-files` (todos los candados de commit)')
        if ($Detected.PythonTestRunner -eq 'pytest') { $lines.Add("- ``$($Detected.PytestEntryCmd)`` (pruebas, normalmente corren solas en cada ``git push``)") }
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
                foreach ($candidate in $candidates) {
                    $entryCmd = Get-FreshEntryCmdForCandidate -Candidate $candidate -PythonExeForHook $pythonExeForHook
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

$built = Build-PreCommitConfigContent -RepoPath $RepoPath -Detected $detected
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

$sectionBody = Get-CalidadSectionBody -Detected $detected -Components $built.Components -ConfigWritten $configWritten -SkippedTestWarning $skippedTestWarning
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
