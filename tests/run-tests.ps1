# Test suite for quality-kit. Builds real throwaway git repos under
# tests\temp-fixtures\ (git init + real files), runs the real scripts
# against them, and asserts on real files/exit codes -- no mocking.
#
# cross-review.ps1 is only ever exercised here with -DryRun: a real
# invocation calls a real AI CLI and can take anywhere from seconds to
# several minutes (confirmed live, especially for codex's default high
# reasoning effort), which would make this suite slow and would burn real
# quota on every run. -DryRun exercises the exact same diff-assembly,
# capping, and prompt-building code path without ever spawning the CLI.

$ErrorActionPreference = 'Stop'
$QualityKitDir = 'C:\Users\ehven\quality-kit'
$InitRepoScript = Join-Path $QualityKitDir 'init-repo.ps1'
$HealRepoScript = Join-Path $QualityKitDir 'heal-repo.ps1'
$CrossReviewScript = Join-Path $QualityKitDir 'cross-review.ps1'
$InstallAiRulesScript = Join-Path $QualityKitDir 'install-ai-rules.ps1'
$UninstallAiRulesScript = Join-Path $QualityKitDir 'uninstall-ai-rules.ps1'
$InstallDocsGroomScript = Join-Path $QualityKitDir 'install-docs-groom.ps1'
$UninstallDocsGroomScript = Join-Path $QualityKitDir 'uninstall-docs-groom.ps1'
$DocsGroomDir = Join-Path $QualityKitDir 'docs-groom'
$TestFixturesDir = Join-Path $QualityKitDir 'tests\temp-fixtures'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$script:PassCount = 0
$script:FailCount = 0

function Assert-True {
    param([bool]$Condition, [string]$Name, [string]$Detail = '')
    if ($Condition) {
        $script:PassCount++
        Write-Host "PASS: $Name"
    } else {
        $script:FailCount++
        Write-Host "FAIL: $Name  $Detail"
    }
}

function Write-Utf8NoBomFile {
    param([string]$Path, [string]$Content)
    [System.IO.File]::WriteAllText($Path, $Content, $Utf8NoBom)
}

function Read-TextFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8)
}

# Git routinely writes harmless notices to stderr (CRLF/LF, etc). With
# "2>&1" merging streams, PowerShell turns each stderr line into an
# ErrorRecord -- and with this script's $ErrorActionPreference of 'Stop',
# hitting even one of those throws a terminating exception for what is not
# actually an error. Every git call in this test file goes through this
# helper so none of them can be tripped up by that.
function Invoke-GitSilent {
    param([string[]]$GitArgs)
    $savedEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & git @GitArgs 2>&1 | Out-Null
    } finally {
        $ErrorActionPreference = $savedEap
    }
}

# Fresh slate for reproducible runs.
if (Test-Path -LiteralPath $TestFixturesDir) {
    Remove-Item -LiteralPath $TestFixturesDir -Recurse -Force
}
New-Item -ItemType Directory -Path $TestFixturesDir -Force | Out-Null

function New-FakeGitRepo {
    param([string]$Name)
    $path = Join-Path $TestFixturesDir $Name
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    Push-Location -LiteralPath $path
    try {
        Invoke-GitSilent -GitArgs @('init', '-q')
        Invoke-GitSilent -GitArgs @('config', 'user.email', 'test@quality-kit.local')
        Invoke-GitSilent -GitArgs @('config', 'user.name', 'quality-kit-tests')
    } finally {
        Pop-Location
    }
    return $path
}

function Invoke-ScriptCapture {
    param([string]$ScriptPath, [string[]]$ScriptArgs = @())
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + $ScriptArgs
    # Build the argument string manually (PS 5.1's ProcessStartInfo has no
    # ArgumentList property -- confirmed unavailable on this machine), with
    # simple double-quote wrapping per argument; none of these arguments
    # contain embedded double quotes.
    $quotedParts = @()
    foreach ($a in $argList) { $quotedParts += ('"' + $a + '"') }
    $psi.Arguments = ($quotedParts -join ' ')
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $proc.Start() | Out-Null
    # Lecturas ASYNC antes de esperar: en serie (stdout hasta EOF y despues
    # stderr) se traba si el hijo llena el buffer del pipe de stderr (~4KB)
    # mientras el padre sigue bloqueado leyendo stdout. Invoke-CliHeadless, en
    # cross-review.ps1, ya usa esta forma correcta.
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    $proc.StandardInput.Close()
    $proc.WaitForExit()
    return [PSCustomObject]@{ Stdout = $stdoutTask.Result; Stderr = $stderrTask.Result; ExitCode = $proc.ExitCode }
}

# Same as Invoke-ScriptCapture, but strips bash.exe's own directories from
# the CHILD process's PATH before starting it -- while leaving git.exe's
# directory alone -- to deterministically reproduce the exact real machine
# where "Get-Command bash" finds nothing from PowerShell (confirmed live:
# this is a real, reported condition on at least one machine, even though
# bash works fine there for actual git hooks, which run under Git Bash's
# own environment instead). ProcessStartInfo.EnvironmentVariables is
# lazily populated from the CURRENT process's real environment the first
# time it is touched, so reading it here before assigning gives the real
# PATH to filter, not an empty one.
function Invoke-ScriptCaptureWithoutBashOnPath {
    param([string]$ScriptPath, [string[]]$ScriptArgs = @())
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + $ScriptArgs
    $quotedParts = @()
    foreach ($a in $argList) { $quotedParts += ('"' + $a + '"') }
    $psi.Arguments = ($quotedParts -join ' ')
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $currentPath = $psi.EnvironmentVariables['Path']
    $filteredParts = @($currentPath -split ';' | Where-Object {
        ($_ -notlike '*usr\bin*') -and ($_ -notlike '*mingw64\bin*') -and ($_ -notlike '*usr\local\bin*')
    })
    $psi.EnvironmentVariables['Path'] = ($filteredParts -join ';')
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $proc.Start() | Out-Null
    # Lecturas ASYNC antes de esperar: en serie (stdout hasta EOF y despues
    # stderr) se traba si el hijo llena el buffer del pipe de stderr (~4KB)
    # mientras el padre sigue bloqueado leyendo stdout. Invoke-CliHeadless, en
    # cross-review.ps1, ya usa esta forma correcta.
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    $proc.StandardInput.Close()
    $proc.WaitForExit()
    return [PSCustomObject]@{ Stdout = $stdoutTask.Result; Stderr = $stderrTask.Result; ExitCode = $proc.ExitCode }
}

function Invoke-InitRepo {
    param([string]$RepoPath)
    return Invoke-ScriptCapture -ScriptPath $InitRepoScript -ScriptArgs @('-RepoPath', $RepoPath)
}

function Invoke-InitRepoWithoutBashOnPath {
    param([string]$RepoPath)
    return Invoke-ScriptCaptureWithoutBashOnPath -ScriptPath $InitRepoScript -ScriptArgs @('-RepoPath', $RepoPath)
}

function Invoke-HealRepo {
    param([string]$RepoPath, [switch]$AutoInit, [string]$OwnersFile = '')
    $scriptArgs = @('-RepoPath', $RepoPath)
    if ($AutoInit) { $scriptArgs += '-AutoInit' }
    if ($OwnersFile -ne '') { $scriptArgs += @('-OwnersFile', $OwnersFile) }
    return Invoke-ScriptCapture -ScriptPath $HealRepoScript -ScriptArgs $scriptArgs
}

function Invoke-CrossReviewDryRun {
    param([string]$RepoPath, [string]$Con, [string]$Alcance = '', [string]$Excluir = '', [string]$Archivos = '')
    $scriptArgs = @('-Con', $Con, '-RepoPath', $RepoPath, '-DryRun')
    if ($Alcance -ne '') { $scriptArgs += @('-Alcance', $Alcance) }
    if ($Excluir -ne '') { $scriptArgs += @('-Excluir', $Excluir) }
    # Un solo string (posiblemente con comas), igual que como llega desde
    # 'powershell -File' en el mundo real -- el split lo hace el script.
    if ($Archivos -ne '') { $scriptArgs += @('-Archivos', $Archivos) }
    return Invoke-ScriptCapture -ScriptPath $CrossReviewScript -ScriptArgs $scriptArgs
}

# Runs cross-review.ps1 -Con auto with every AI CLI's directory stripped
# from the CHILD's PATH (git and everything else stay), to exercise the
# "no external reviewer available" contract (exit 3) deterministically.
# Safe without -DryRun: with no CLI findable, the chain never invokes
# anything, so no quota is ever spent.
function Invoke-CrossReviewAutoWithoutAiClisOnPath {
    param([string]$RepoPath)
    $aiDirs = @()
    foreach ($cli in @('claude', 'kimi', 'codex')) {
        foreach ($cmd in @(Get-Command -Name $cli -All -ErrorAction SilentlyContinue)) {
            $aiDirs += (Split-Path -Parent $cmd.Source).TrimEnd('\')
        }
    }
    $aiDirs = @($aiDirs | Sort-Object -Unique)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $CrossReviewScript, '-Con', 'auto', '-RepoPath', $RepoPath)
    $quotedParts = @()
    foreach ($a in $argList) { $quotedParts += ('"' + $a + '"') }
    $psi.Arguments = ($quotedParts -join ' ')
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $currentPath = $psi.EnvironmentVariables['Path']
    $filteredParts = @($currentPath -split ';' | Where-Object {
        $aiDirs -notcontains $_.TrimEnd('\')
    })
    $psi.EnvironmentVariables['Path'] = ($filteredParts -join ';')
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $proc.Start() | Out-Null
    # Lecturas ASYNC antes de esperar: en serie (stdout hasta EOF y despues
    # stderr) se traba si el hijo llena el buffer del pipe de stderr (~4KB)
    # mientras el padre sigue bloqueado leyendo stdout. Invoke-CliHeadless, en
    # cross-review.ps1, ya usa esta forma correcta.
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    $proc.StandardInput.Close()
    $proc.WaitForExit()
    return [PSCustomObject]@{ Stdout = $stdoutTask.Result; Stderr = $stderrTask.Result; ExitCode = $proc.ExitCode }
}

# ------------------------------------------------------------------
# TEST GROUP 1: init-repo.ps1 against a fake Python repo
# ------------------------------------------------------------------
Write-Host '=== TEST GROUP 1: init-repo.ps1 -- Python repo ==='
$pyRepo = New-FakeGitRepo -Name 'fake-py-repo'
Write-Utf8NoBomFile -Path (Join-Path $pyRepo 'pyproject.toml') -Content "[project]`nname = ""fake-py-repo""`nversion = ""0.1.0""`n"
New-Item -ItemType Directory -Path (Join-Path $pyRepo 'tests') -Force | Out-Null
Write-Utf8NoBomFile -Path (Join-Path $pyRepo 'tests\test_sample.py') -Content "def test_ok():`n    assert 1 + 1 == 2`n"
Write-Utf8NoBomFile -Path (Join-Path $pyRepo 'app.py') -Content "def add(a, b):`n    return a + b`n"
Push-Location -LiteralPath $pyRepo
try { Invoke-GitSilent -GitArgs @('add', '-A'); Invoke-GitSilent -GitArgs @('commit', '-q', '-m', 'initial') } finally { Pop-Location }

$r1 = Invoke-InitRepo -RepoPath $pyRepo
Assert-True ($r1.ExitCode -eq 0) 'init-repo.ps1 exits 0 on a fake Python repo' "exit=$($r1.ExitCode) stderr=$($r1.Stderr)"

$pyConfigPath = Join-Path $pyRepo '.pre-commit-config.yaml'
$pyConfig = Read-TextFile -Path $pyConfigPath
Assert-True ($null -ne $pyConfig) '.pre-commit-config.yaml was written'
Assert-True ($pyConfig -match 'QUALITY-KIT MANAGED') '.pre-commit-config.yaml carries the quality-kit marker'
Assert-True ($pyConfig -match 'trailing-whitespace') '.pre-commit-config.yaml includes the base pre-commit-hooks block'
Assert-True ($pyConfig -match 'ruff-check') '.pre-commit-config.yaml includes ruff-check (Python detected)'
Assert-True ($pyConfig -match 'ruff-format') '.pre-commit-config.yaml includes ruff-format (Python detected)'
Assert-True ($pyConfig -match 'pytest-pre-push') '.pre-commit-config.yaml includes the pytest pre-push hook (tests/ detected)'
Assert-True ($pyConfig -match 'stages: \[pre-push\]') 'the pytest hook is staged for pre-push, not pre-commit'
Assert-True (-not ($pyConfig -match 'eslint-local|prettier-local|npm-test-pre-push')) 'no Node-specific hooks leaked into a pure-Python repo'

Assert-True (Test-Path -LiteralPath (Join-Path $pyRepo '.git\hooks\pre-commit')) 'the real git pre-commit hook was installed'
Assert-True (Test-Path -LiteralPath (Join-Path $pyRepo '.git\hooks\pre-push')) 'the real git pre-push hook was installed (tests detected)'

$pyClaudeMd = Read-TextFile -Path (Join-Path $pyRepo 'CLAUDE.md')
$pyAgentsMd = Read-TextFile -Path (Join-Path $pyRepo 'AGENTS.md')
Assert-True ($null -ne $pyClaudeMd -and $pyClaudeMd -match 'QUALITY-KIT CALIDAD SECTION START') 'CLAUDE.md was created with the Calidad section'
Assert-True ($null -ne $pyAgentsMd -and $pyAgentsMd -match 'QUALITY-KIT CALIDAD SECTION START') 'AGENTS.md was created with the Calidad section'
Assert-True ($pyClaudeMd -match 'JAMAS') 'the Calidad section states the never-bypass-hooks rule'
Assert-True ($pyClaudeMd -match 'pytest -x -q') 'the Calidad section documents the exact pytest pre-push command'

Write-Host ''
Write-Host '=== TEST GROUP 1b: idempotency -- running init-repo.ps1 again changes nothing extra ==='
$r1b = Invoke-InitRepo -RepoPath $pyRepo
Assert-True ($r1b.ExitCode -eq 0) 'second init-repo.ps1 run also exits 0' "exit=$($r1b.ExitCode)"
$pyClaudeMdAfter2 = Read-TextFile -Path (Join-Path $pyRepo 'CLAUDE.md')
$markerCount = ([regex]::Matches($pyClaudeMdAfter2, [regex]::Escape('QUALITY-KIT CALIDAD SECTION START'))).Count
Assert-True ($markerCount -eq 1) 'CLAUDE.md Calidad marker still appears exactly once after a second run (not duplicated)' "count=$markerCount"
$pyConfigAfter2 = Read-TextFile -Path $pyConfigPath
$configMarkerCount = ([regex]::Matches($pyConfigAfter2, [regex]::Escape('QUALITY-KIT MANAGED'))).Count
Assert-True ($configMarkerCount -eq 1) '.pre-commit-config.yaml marker still appears exactly once after a second run' "count=$configMarkerCount"

# ------------------------------------------------------------------
# TEST GROUP 2: init-repo.ps1 against a fake Node repo
# ------------------------------------------------------------------
Write-Host ''
Write-Host '=== TEST GROUP 2: init-repo.ps1 -- Node repo (with its own ESLint config + a real test script) ==='
$nodeRepo = New-FakeGitRepo -Name 'fake-node-repo'
$packageJson = '{"name":"fake-node-repo","version":"1.0.0","scripts":{"test":"node --test","lint":"eslint ."},"devDependencies":{"eslint":"^9.0.0"}}'
Write-Utf8NoBomFile -Path (Join-Path $nodeRepo 'package.json') -Content $packageJson
Write-Utf8NoBomFile -Path (Join-Path $nodeRepo 'eslint.config.js') -Content 'module.exports = [];'
New-Item -ItemType Directory -Path (Join-Path $nodeRepo 'test') -Force | Out-Null
Write-Utf8NoBomFile -Path (Join-Path $nodeRepo 'test\sample.test.js') -Content "const test = require('node:test');`nconst assert = require('node:assert');`ntest('adds', () => { assert.strictEqual(1 + 1, 2); });`n"
Push-Location -LiteralPath $nodeRepo
try { Invoke-GitSilent -GitArgs @('add', '-A'); Invoke-GitSilent -GitArgs @('commit', '-q', '-m', 'initial') } finally { Pop-Location }

$r2 = Invoke-InitRepo -RepoPath $nodeRepo
Assert-True ($r2.ExitCode -eq 0) 'init-repo.ps1 exits 0 on a fake Node repo' "exit=$($r2.ExitCode) stderr=$($r2.Stderr)"

$nodeConfig = Read-TextFile -Path (Join-Path $nodeRepo '.pre-commit-config.yaml')
Assert-True ($nodeConfig -match 'eslint-local') '.pre-commit-config.yaml includes the local eslint hook (repo already has an ESLint config)' "config=$nodeConfig"
Assert-True ($nodeConfig -match 'npm-test-pre-push') '.pre-commit-config.yaml includes the npm test pre-push hook (real test script detected)'
Assert-True (-not ($nodeConfig -match 'prettier-local')) 'no prettier hook added (repo has no Prettier config)'
Assert-True (-not ($nodeConfig -match 'ruff')) 'no Python-specific hooks leaked into a pure-Node repo'
Assert-True (Test-Path -LiteralPath (Join-Path $nodeRepo '.git\hooks\pre-push')) 'the real git pre-push hook was installed (npm test detected)'

Write-Host ''
Write-Host '=== TEST GROUP 2b: init-repo.ps1 -- generic fallback (neither Python nor Node) ==='
$genericRepo = New-FakeGitRepo -Name 'fake-generic-repo'
Write-Utf8NoBomFile -Path (Join-Path $genericRepo 'README.md') -Content "# hello`n"
Push-Location -LiteralPath $genericRepo
try { Invoke-GitSilent -GitArgs @('add', '-A'); Invoke-GitSilent -GitArgs @('commit', '-q', '-m', 'initial') } finally { Pop-Location }
$r2b = Invoke-InitRepo -RepoPath $genericRepo
Assert-True ($r2b.ExitCode -eq 0) 'init-repo.ps1 exits 0 on a repo with neither stack' "exit=$($r2b.ExitCode)"
$genericConfig = Read-TextFile -Path (Join-Path $genericRepo '.pre-commit-config.yaml')
Assert-True ($genericConfig -match 'trailing-whitespace') 'generic fallback still writes the base hooks'
Assert-True (-not ($genericConfig -match 'ruff-check|eslint-local|prettier-local|pytest-pre-push|npm-test-pre-push')) 'generic fallback adds NO stack-specific or test hooks'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $genericRepo '.git\hooks\pre-push'))) 'no pre-push hook installed when there is nothing to test'

Write-Host ''
Write-Host '=== TEST GROUP 2c: init-repo.ps1 never overwrites a pre-existing NON-quality-kit .pre-commit-config.yaml ==='
$existingRepo = New-FakeGitRepo -Name 'fake-existing-config-repo'
Write-Utf8NoBomFile -Path (Join-Path $existingRepo 'pyproject.toml') -Content "[project]`nname = ""x""`n"
$handWrittenConfig = "repos:`n  - repo: https://example.com/my-own-thing`n    rev: v1.0.0`n    hooks:`n      - id: my-hook`n"
Write-Utf8NoBomFile -Path (Join-Path $existingRepo '.pre-commit-config.yaml') -Content $handWrittenConfig
Push-Location -LiteralPath $existingRepo
try { Invoke-GitSilent -GitArgs @('add', '-A'); Invoke-GitSilent -GitArgs @('commit', '-q', '-m', 'initial') } finally { Pop-Location }
$r2c = Invoke-InitRepo -RepoPath $existingRepo
Assert-True ($r2c.ExitCode -eq 0) 'init-repo.ps1 still exits 0 when it skips an existing config' "exit=$($r2c.ExitCode)"
$existingConfigAfter = Read-TextFile -Path (Join-Path $existingRepo '.pre-commit-config.yaml')
Assert-True ($existingConfigAfter -eq $handWrittenConfig) 'the pre-existing, non-quality-kit .pre-commit-config.yaml is left byte-for-byte UNCHANGED'
$existingClaudeMd = Read-TextFile -Path (Join-Path $existingRepo 'CLAUDE.md')
Assert-True ($existingClaudeMd -match 'ya tenia su propia configuracion') 'CLAUDE.md correctly says the repo already had its own config, instead of falsely listing quality-kit hooks as active'

Write-Host ''
Write-Host '=== TEST GROUP 2d (real-world bug fix): Python detection is RECURSIVE -- nested *.py with no root marker still counts ==='
# This mirrors the actual bug found piloting init-repo.ps1 on the trading
# repo: all its real code lives under user_data\strategies\*.py, with no
# pyproject.toml or requirements.txt anywhere near the root, and the
# original root-only *.py check reported "generico" instead of "Python".
$nestedPyRepo = New-FakeGitRepo -Name 'fake-nested-py-repo'
New-Item -ItemType Directory -Path (Join-Path $nestedPyRepo 'src\deep') -Force | Out-Null
Write-Utf8NoBomFile -Path (Join-Path $nestedPyRepo 'src\deep\thing.py') -Content "def thing():`n    return 42`n"
Write-Utf8NoBomFile -Path (Join-Path $nestedPyRepo 'README.md') -Content "# nested python, no root marker`n"
Push-Location -LiteralPath $nestedPyRepo
try { Invoke-GitSilent -GitArgs @('add', '-A'); Invoke-GitSilent -GitArgs @('commit', '-q', '-m', 'initial') } finally { Pop-Location }
$r2d = Invoke-InitRepo -RepoPath $nestedPyRepo
Assert-True ($r2d.ExitCode -eq 0) 'init-repo.ps1 exits 0 on a repo whose only Python file is nested' "exit=$($r2d.ExitCode) stderr=$($r2d.Stderr)"
$nestedPyConfig = Read-TextFile -Path (Join-Path $nestedPyRepo '.pre-commit-config.yaml')
Assert-True ($nestedPyConfig -match 'ruff-check') 'a nested *.py file with NO root pyproject.toml/requirements.txt is still detected as Python (the actual reported bug)' "config=$nestedPyConfig"

Write-Host ''
Write-Host '=== TEST GROUP 2e (real-world bug fix): the recursive Python search still EXCLUDES .venv -- a repo with *.py only inside .venv is NOT Python ==='
$venvOnlyRepo = New-FakeGitRepo -Name 'fake-venv-only-repo'
New-Item -ItemType Directory -Path (Join-Path $venvOnlyRepo '.venv\Lib\site-packages') -Force | Out-Null
Write-Utf8NoBomFile -Path (Join-Path $venvOnlyRepo '.venv\Lib\site-packages\somelib.py') -Content "# third-party library file, not this repo's own code`n"
Write-Utf8NoBomFile -Path (Join-Path $venvOnlyRepo 'README.md') -Content "# a repo with only a venv, no real python code of its own`n"
Push-Location -LiteralPath $venvOnlyRepo
try { Invoke-GitSilent -GitArgs @('add', '-A'); Invoke-GitSilent -GitArgs @('commit', '-q', '-m', 'initial') } finally { Pop-Location }
$r2e = Invoke-InitRepo -RepoPath $venvOnlyRepo
Assert-True ($r2e.ExitCode -eq 0) 'init-repo.ps1 exits 0 on a repo with only a .venv' "exit=$($r2e.ExitCode)"
$venvOnlyConfig = Read-TextFile -Path (Join-Path $venvOnlyRepo '.pre-commit-config.yaml')
Assert-True (-not ($venvOnlyConfig -match 'ruff-check')) '*.py files found ONLY inside .venv do NOT count as this repo being Python (the search must skip .venv entirely)' "config=$venvOnlyConfig"

Write-Host ''
Write-Host '=== TEST GROUP 2f (superseded by lesson 4 -- see below): re-running after the detected stack CHANGES now PRESERVES the existing file, it does not silently regenerate ==='
# First run: no Python markers anywhere yet -> generic.
$evolvingRepo = New-FakeGitRepo -Name 'fake-evolving-repo'
Write-Utf8NoBomFile -Path (Join-Path $evolvingRepo 'README.md') -Content "# starts generic, becomes python`n"
Push-Location -LiteralPath $evolvingRepo
try { Invoke-GitSilent -GitArgs @('add', '-A'); Invoke-GitSilent -GitArgs @('commit', '-q', '-m', 'initial') } finally { Pop-Location }
$rEvolve1 = Invoke-InitRepo -RepoPath $evolvingRepo
Assert-True ($rEvolve1.ExitCode -eq 0) 'first run (generic) exits 0' "exit=$($rEvolve1.ExitCode)"
$evolvingConfig1 = Read-TextFile -Path (Join-Path $evolvingRepo '.pre-commit-config.yaml')
Assert-True (-not ($evolvingConfig1 -match 'ruff-check')) 'sanity: first run correctly detected generic (no Python yet)'

# Now add a nested Python file (no root marker) and re-run. Lesson 4
# CHANGED this on purpose: the kit can no longer tell "the stack evolved"
# apart from "someone customized this file by hand" (both look the same:
# the existing file differs from what would be generated today), and two
# real incidents proved silent full-file regeneration is dangerous. So the
# safer, intentional behavior now is to leave the existing file untouched
# and say so -- NOT to silently upgrade it. If you want the new stack's
# hooks, delete the file (or merge by hand) and re-run.
New-Item -ItemType Directory -Path (Join-Path $evolvingRepo 'strategies') -Force | Out-Null
Write-Utf8NoBomFile -Path (Join-Path $evolvingRepo 'strategies\my_strategy.py') -Content "def run():`n    pass`n"
Push-Location -LiteralPath $evolvingRepo
try { Invoke-GitSilent -GitArgs @('add', '-A'); Invoke-GitSilent -GitArgs @('commit', '-q', '-m', 'add python code') } finally { Pop-Location }
$rEvolve2 = Invoke-InitRepo -RepoPath $evolvingRepo
Assert-True ($rEvolve2.ExitCode -eq 0) 'second run (now python) exits 0' "exit=$($rEvolve2.ExitCode)"
$evolvingConfig2 = Read-TextFile -Path (Join-Path $evolvingRepo '.pre-commit-config.yaml')
Assert-True ($evolvingConfig2 -eq $evolvingConfig1) 'lesson 4: the existing config is left BYTE-IDENTICAL even though the stack changed -- the kit cannot tell that apart from a hand customization, so it never silently upgrades' "before=$evolvingConfig1 after=$evolvingConfig2"
Assert-True ($rEvolve2.Stdout -match 'Config personalizado detectado') 'init-repo.ps1 reports the safety net triggered (treats "stack changed" the same as "possibly customized", on purpose)' "stdout=$($rEvolve2.Stdout)"

Write-Host ''
Write-Host '=== TEST GROUP 2g (MCP-2 lesson, item 1a): an explicit pytest config wins even when unittest signal is ALSO present ==='
$pytestConfigRepo = New-FakeGitRepo -Name 'fake-pytest-config-repo'
Write-Utf8NoBomFile -Path (Join-Path $pytestConfigRepo 'pytest.ini') -Content "[pytest]`n"
New-Item -ItemType Directory -Path (Join-Path $pytestConfigRepo 'tests') -Force | Out-Null
Write-Utf8NoBomFile -Path (Join-Path $pytestConfigRepo 'tests\__init__.py') -Content ''
Write-Utf8NoBomFile -Path (Join-Path $pytestConfigRepo 'tests\test_mixed.py') -Content "import unittest`n`nclass TestMixed(unittest.TestCase):`n    def test_ok(self):`n        self.assertEqual(1 + 1, 2)`n"
Push-Location -LiteralPath $pytestConfigRepo
try { Invoke-GitSilent -GitArgs @('add', '-A'); Invoke-GitSilent -GitArgs @('commit', '-q', '-m', 'initial') } finally { Pop-Location }
$rPytestConfig = Invoke-InitRepo -RepoPath $pytestConfigRepo
Assert-True ($rPytestConfig.ExitCode -eq 0) 'init-repo.ps1 exits 0 on a repo with an explicit pytest.ini' "exit=$($rPytestConfig.ExitCode) stderr=$($rPytestConfig.Stderr)"
$pytestConfigYaml = Read-TextFile -Path (Join-Path $pytestConfigRepo '.pre-commit-config.yaml')
Assert-True ($pytestConfigYaml -match 'pytest-pre-push') 'pytest.ini being present selects the pytest runner even though the same test file also imports unittest' "config=$pytestConfigYaml"
Assert-True (-not ($pytestConfigYaml -match 'unittest-pre-push')) 'the unittest hook is NOT also added when pytest.ini wins'

Write-Host ''
Write-Host '=== TEST GROUP 2h (MCP-2 lesson, item 1b): a ROOT tests/ dir using unittest, with NO pytest config, gets the unittest runner ==='
$rootUnittestRepo = New-FakeGitRepo -Name 'fake-root-unittest-repo'
New-Item -ItemType Directory -Path (Join-Path $rootUnittestRepo 'tests') -Force | Out-Null
Write-Utf8NoBomFile -Path (Join-Path $rootUnittestRepo 'tests\__init__.py') -Content ''
Write-Utf8NoBomFile -Path (Join-Path $rootUnittestRepo 'tests\test_thing.py') -Content "import unittest`n`nclass TestThing(unittest.TestCase):`n    def test_ok(self):`n        self.assertEqual(2 + 2, 4)`n"
Push-Location -LiteralPath $rootUnittestRepo
try { Invoke-GitSilent -GitArgs @('add', '-A'); Invoke-GitSilent -GitArgs @('commit', '-q', '-m', 'initial') } finally { Pop-Location }
$rRootUnittest = Invoke-InitRepo -RepoPath $rootUnittestRepo
Assert-True ($rRootUnittest.ExitCode -eq 0) 'init-repo.ps1 exits 0 on a repo with root tests/ using unittest, no pytest config' "exit=$($rRootUnittest.ExitCode) stderr=$($rRootUnittest.Stderr)"
$rootUnittestYaml = Read-TextFile -Path (Join-Path $rootUnittestRepo '.pre-commit-config.yaml')
Assert-True ($rootUnittestYaml -match 'unittest-pre-push') 'root tests/ with a real unittest.TestCase and no pytest config selects the unittest runner' "config=$rootUnittestYaml"
Assert-True ($rootUnittestYaml -match [regex]::Escape('-m unittest discover -s tests -t .')) 'the root-level unittest entry uses "-s tests -t ." with no cd/bash wrapper needed' "config=$rootUnittestYaml"
Assert-True (-not ($rootUnittestYaml -match '(?m)^\s*entry:.*bash -c')) 'the root-level case''s actual entry line does NOT use the bash -c cd-into-parent wrapper (that is only for the nested case; the template''s explanatory comment mentions "bash -c" in prose, which is fine -- only the entry: line itself matters here)' "config=$rootUnittestYaml"

Write-Host ''
Write-Host '=== TEST GROUP 2i (MCP-2 lesson, item 1b, exact MCP-2 shape): a NESTED tests dir (app\tests) gets the cd-into-parent unittest variant ==='
$mcp2ShapeRepo = New-FakeGitRepo -Name 'fake-mcp2-shape-repo'
New-Item -ItemType Directory -Path (Join-Path $mcp2ShapeRepo 'app\tests') -Force | Out-Null
Write-Utf8NoBomFile -Path (Join-Path $mcp2ShapeRepo 'app\main.py') -Content "def add(a, b):`n    return a + b`n"
Write-Utf8NoBomFile -Path (Join-Path $mcp2ShapeRepo 'app\tests\__init__.py') -Content ''
Write-Utf8NoBomFile -Path (Join-Path $mcp2ShapeRepo 'app\tests\test_main.py') -Content "import unittest`nfrom main import add`n`nclass TestMain(unittest.TestCase):`n    def test_add(self):`n        self.assertEqual(add(1, 2), 3)`n"
Push-Location -LiteralPath $mcp2ShapeRepo
try { Invoke-GitSilent -GitArgs @('add', '-A'); Invoke-GitSilent -GitArgs @('commit', '-q', '-m', 'initial') } finally { Pop-Location }
$rMcp2Shape = Invoke-InitRepo -RepoPath $mcp2ShapeRepo
Assert-True ($rMcp2Shape.ExitCode -eq 0) 'init-repo.ps1 exits 0 on the exact MCP-2 shape (app\tests, unittest, no pytest config)' "exit=$($rMcp2Shape.ExitCode) stderr=$($rMcp2Shape.Stderr)"
$mcp2ShapeYaml = Read-TextFile -Path (Join-Path $mcp2ShapeRepo '.pre-commit-config.yaml')
Assert-True ($mcp2ShapeYaml -match 'unittest-pre-push') 'the MCP-2 shape (nested app\tests, unittest) selects the unittest runner' "config=$mcp2ShapeYaml"
Assert-True ($mcp2ShapeYaml -match [regex]::Escape("bash -c 'cd app && ")) 'the nested case cds into the parent subdirectory first, mirroring the real MCP-2 hand-fix' "config=$mcp2ShapeYaml"
Assert-True ($mcp2ShapeYaml -match [regex]::Escape('-m unittest discover -s tests -t .')) 'the nested case still discovers with -s tests -t . once inside the parent dir' "config=$mcp2ShapeYaml"
Assert-True ($rMcp2Shape.Stdout -match 'El runner de pruebas \(unittest\) funciona') 'init-repo.ps1 reports that it validated the unittest runner successfully before installing the hook'
Assert-True (Test-Path -LiteralPath (Join-Path $mcp2ShapeRepo '.git\hooks\pre-push')) 'the real git pre-push hook was installed for the validated MCP-2 shape'

Write-Host ''
Write-Host '=== TEST GROUP 2j (MCP-2 lesson, item 2, THE CORE FIX): a runner that fails validation gets NO pre-push hook, plus a loud warning ==='
# Real, reproducible failure mode (found while building this fix, not a
# contrived one): a nested tests dir MISSING __init__.py makes Python's
# own unittest discovery raise "ImportError: Start directory is not
# importable" -- confirmed live on this machine. This is exactly the kind
# of structural runner failure item 2 exists to catch before it ever
# becomes an installed, push-blocking gate.
$brokenRunnerRepo = New-FakeGitRepo -Name 'fake-broken-runner-repo'
New-Item -ItemType Directory -Path (Join-Path $brokenRunnerRepo 'app\tests') -Force | Out-Null
Write-Utf8NoBomFile -Path (Join-Path $brokenRunnerRepo 'app\main.py') -Content "def add(a, b):`n    return a + b`n"
# Deliberately NO tests\__init__.py here.
Write-Utf8NoBomFile -Path (Join-Path $brokenRunnerRepo 'app\tests\test_main.py') -Content "import unittest`nfrom main import add`n`nclass TestMain(unittest.TestCase):`n    def test_add(self):`n        self.assertEqual(add(1, 2), 3)`n"
Push-Location -LiteralPath $brokenRunnerRepo
try { Invoke-GitSilent -GitArgs @('add', '-A'); Invoke-GitSilent -GitArgs @('commit', '-q', '-m', 'initial') } finally { Pop-Location }
$rBrokenRunner = Invoke-InitRepo -RepoPath $brokenRunnerRepo
Assert-True ($rBrokenRunner.ExitCode -eq 0) 'init-repo.ps1 still exits 0 overall even when the test runner fails validation (a skipped hook is not a script error)' "exit=$($rBrokenRunner.ExitCode) stderr=$($rBrokenRunner.Stderr)"
$brokenRunnerYaml = Read-TextFile -Path (Join-Path $brokenRunnerRepo '.pre-commit-config.yaml')
Assert-True (-not ($brokenRunnerYaml -match 'unittest-pre-push|pytest-pre-push')) 'NO pre-push test hook of any kind was written when the chosen runner failed validation' "config=$brokenRunnerYaml"
Assert-True (-not (Test-Path -LiteralPath (Join-Path $brokenRunnerRepo '.git\hooks\pre-push'))) 'the real git pre-push hook was NOT installed at all (only pre-commit, since there is no pre-push hook to enable)'
Assert-True ($rBrokenRunner.Stdout -match 'ADVERTENCIA.*fallaron al verificarlos') 'init-repo.ps1 prints a loud, explicit warning that the runner(s) failed validation' "stdout=$($rBrokenRunner.Stdout)"
Assert-True ($rBrokenRunner.Stdout -match [regex]::Escape('unittest (')) 'the warning names which runner(s) were actually tried (item 1: the skip warning must mention what was tried)' "stdout=$($rBrokenRunner.Stdout)"
$brokenRunnerClaudeMd = Read-TextFile -Path (Join-Path $brokenRunnerRepo 'CLAUDE.md')
Assert-True ($brokenRunnerClaudeMd -match 'ADVERTENCIA') 'the skipped-hook warning is also recorded in the Calidad section of CLAUDE.md, not just printed to the console'

Write-Host ''
Write-Host '=== TEST GROUP 2k (MCP-2 lesson, item 4): re-running init-repo.ps1 against the MCP-2 shape regenerates the SAME unittest hook, not something worse ==='
# This is the idempotency guarantee the lead specifically needs before
# re-running init-repo.ps1 across the goncloud repos: a repo that already
# has the correct unittest hook (matching the real MCP-2 hand-fix) must
# come out the same way after a re-run, never falling back to no hook or
# to a naive pytest guess.
$rMcp2ShapeAgain = Invoke-InitRepo -RepoPath $mcp2ShapeRepo
Assert-True ($rMcp2ShapeAgain.ExitCode -eq 0) 'second run against the MCP-2 shape also exits 0' "exit=$($rMcp2ShapeAgain.ExitCode)"
$mcp2ShapeYaml2 = Read-TextFile -Path (Join-Path $mcp2ShapeRepo '.pre-commit-config.yaml')
Assert-True ($mcp2ShapeYaml2 -eq $mcp2ShapeYaml) 're-running against the MCP-2 shape regenerates byte-identical content -- the same unittest hook, not a regression to no hook or a broken pytest guess' "before=$mcp2ShapeYaml after=$mcp2ShapeYaml2"
$mcp2MarkerCount = ([regex]::Matches($mcp2ShapeYaml2, [regex]::Escape('QUALITY-KIT MANAGED'))).Count
Assert-True ($mcp2MarkerCount -eq 1) 'the regenerated MCP-2-shape config still carries exactly one quality-kit marker'

Write-Host ''
Write-Host '=== TEST GROUP 2l (lesson 3b, item 1+3a, THE REAL MCP-2 SHAPE): pytest.ini present + broken pytest + unittest tests -> FALLS BACK to unittest, not a skip ==='
# This is the exact shape that defeated the lesson-3 build live: MCP-2 has
# BOTH pytest.ini (pythonpath=app, testpaths=app/tests) AND unittest-style
# tests (its own docs mandate unittest). A conftest.py that raises at
# import time deterministically reproduces "pytest is broken on this
# machine" (confirmed live: python -m pytest --collect-only exits 4 with
# this conftest, standing in for the real Python 3.14 capture-teardown
# crash) without depending on that machine-specific bug actually
# reproducing here.
$mcp2RealRepo = New-FakeGitRepo -Name 'fake-mcp2-real-shape-repo'
New-Item -ItemType Directory -Path (Join-Path $mcp2RealRepo 'app\tests') -Force | Out-Null
Write-Utf8NoBomFile -Path (Join-Path $mcp2RealRepo 'pytest.ini') -Content "[pytest]`npythonpath = app`ntestpaths = app/tests`n"
Write-Utf8NoBomFile -Path (Join-Path $mcp2RealRepo 'conftest.py') -Content "raise RuntimeError(`"simulated broken pytest (Python 3.14 capture bug stand-in)`")`n"
Write-Utf8NoBomFile -Path (Join-Path $mcp2RealRepo 'app\main.py') -Content "def add(a, b):`n    return a + b`n"
Write-Utf8NoBomFile -Path (Join-Path $mcp2RealRepo 'app\tests\__init__.py') -Content ''
Write-Utf8NoBomFile -Path (Join-Path $mcp2RealRepo 'app\tests\test_main.py') -Content "import unittest`nfrom main import add`n`nclass TestMain(unittest.TestCase):`n    def test_add(self):`n        self.assertEqual(add(1, 2), 3)`n"
Push-Location -LiteralPath $mcp2RealRepo
try { Invoke-GitSilent -GitArgs @('add', '-A'); Invoke-GitSilent -GitArgs @('commit', '-q', '-m', 'initial') } finally { Pop-Location }
$rMcp2Real = Invoke-InitRepo -RepoPath $mcp2RealRepo
Assert-True ($rMcp2Real.ExitCode -eq 0) 'init-repo.ps1 exits 0 on the real MCP-2 shape (pytest.ini + broken pytest + unittest tests)' "exit=$($rMcp2Real.ExitCode) stderr=$($rMcp2Real.Stderr)"
$mcp2RealYaml = Read-TextFile -Path (Join-Path $mcp2RealRepo '.pre-commit-config.yaml')
Assert-True ($mcp2RealYaml -match 'unittest-pre-push') 'pytest failing validation falls back to unittest -- the REAL fix for the incident (result is the unittest hook, not a skip)' "config=$mcp2RealYaml"
Assert-True (-not ($mcp2RealYaml -match 'pytest-pre-push')) 'the failed pytest attempt itself never gets written as a hook'
Assert-True ($rMcp2Real.Stdout -match [regex]::Escape('funciono como alternativa, despues de que fallara')) 'init-repo.ps1 reports that unittest worked as a fallback after pytest failed' "stdout=$($rMcp2Real.Stdout)"
Assert-True (Test-Path -LiteralPath (Join-Path $mcp2RealRepo '.git\hooks\pre-push')) 'the real git pre-push hook WAS installed (the fallback succeeded, this is not a skip)'
Assert-True ($rMcp2Real.Stdout -notmatch 'NO se instala el candado de pre-push') 'this is NOT the give-up path -- no "hook not installed" warning should appear when a fallback succeeds'

Write-Host ''
Write-Host '=== TEST GROUP 2m (lesson 3b, item 2+3b, THE INVARIANT THAT GOT VIOLATED): re-running against a working unittest hook (with pytest.ini ALSO present) keeps it unchanged ==='
# This is the exact regression: the live incident re-ran init-repo.ps1
# against MCP-2 (which already had a hand-fixed, working unittest hook),
# fresh detection tried pytest first (per priority), pytest failed
# (machine-wide broken), and the OLD logic gave up and wrote NO hook at
# all -- silently deleting the working one. The fix must skip fresh
# detection entirely here and keep the existing, still-working hook
# byte-for-byte.
$rMcp2RealAgain = Invoke-InitRepo -RepoPath $mcp2RealRepo
Assert-True ($rMcp2RealAgain.ExitCode -eq 0) 'second run against the real MCP-2 shape also exits 0' "exit=$($rMcp2RealAgain.ExitCode)"
$mcp2RealYaml2 = Read-TextFile -Path (Join-Path $mcp2RealRepo '.pre-commit-config.yaml')
Assert-True ($mcp2RealYaml2 -eq $mcp2RealYaml) 're-running keeps the unittest hook byte-for-byte identical -- NOT downgraded to a skip just because pytest.ini is also present and pytest still fails' "before=$mcp2RealYaml after=$mcp2RealYaml2"
Assert-True ($rMcp2RealAgain.Stdout -match [regex]::Escape('todavia funciona -- lo mantengo tal cual')) 'init-repo.ps1 reports explicitly that it kept the existing, still-working hook instead of re-detecting' "stdout=$($rMcp2RealAgain.Stdout)"
Assert-True ($rMcp2RealAgain.Stdout -notmatch 'Verificando el runner de pruebas \(pytest\)') 'the re-run does NOT even attempt to validate pytest again -- fresh detection is skipped entirely once the existing hook is confirmed working'
Assert-True (Test-Path -LiteralPath (Join-Path $mcp2RealRepo '.git\hooks\pre-push')) 'the real git pre-push hook is still installed after the second run'

Write-Host ''
Write-Host '=== TEST GROUP 2n (lesson 3c, item 1+3a, SECOND real incident): bash not visible to Get-Command, but present at Gits install path -> existing bash -c hook still validates and is kept ==='
# The MCP-2 fix from lesson 3b got re-broken by a DIFFERENT real problem:
# validating the existing "bash -c '...'" hook spawned a bare 'bash',
# which threw immediately on a machine where PowerShell's own PATH
# resolution cannot see it -- even though the exact same command works
# fine as a real git hook (Git Bash has its own environment). Reusing the
# real MCP-2-shaped repo from TEST GROUP 2l/2m (it already has a working
# unittest hook with a bash -c entry): running init-repo.ps1 in a CHILD
# process whose PATH has had bash.exe's own directories stripped (but NOT
# git.exe's) must still find bash via the fixed Git install-path fallback
# and keep the hook -- not silently degrade it a second time.
$rMcp2NoBashOnPath = Invoke-InitRepoWithoutBashOnPath -RepoPath $mcp2RealRepo
Assert-True ($rMcp2NoBashOnPath.ExitCode -eq 0) 'init-repo.ps1 exits 0 even when bash is not visible to Get-Command in the child process' "exit=$($rMcp2NoBashOnPath.ExitCode) stderr=$($rMcp2NoBashOnPath.Stderr)"
$mcp2RealYaml3 = Read-TextFile -Path (Join-Path $mcp2RealRepo '.pre-commit-config.yaml')
Assert-True ($mcp2RealYaml3 -eq $mcp2RealYaml) 'the existing unittest hook (with its bash -c entry) is preserved byte-for-byte even though Get-Command cannot see bash in this child process' "before=$mcp2RealYaml after=$mcp2RealYaml3"
Assert-True ($rMcp2NoBashOnPath.Stdout -match [regex]::Escape('todavia funciona -- lo mantengo tal cual')) 'init-repo.ps1 reports the hook still works -- it found bash via the Git install-path fallback, not the "could not verify" path' "stdout=$($rMcp2NoBashOnPath.Stdout)"
Assert-True ($rMcp2NoBashOnPath.Stdout -notmatch 'No se pudo verificar') 'this is the SUCCESS path (bash was found via fallback), not the validator-error path -- that is a separate scenario tested next'

Write-Host ''
Write-Host '=== TEST GROUP 2o (lesson 3c, item 2+3b, THE SHARPENED INVARIANT): a validator SPAWN failure on the existing hook keeps it untouched, with a distinct message ==='
# Different failure shape than 2n: here the validator itself cannot even
# launch the check (confirmed live: "Exception calling Start... The system
# cannot find the file specified" for a bogus path) -- this must be
# treated as OUR infrastructure problem, never as proof the hook is
# broken, so the existing hook must be kept exactly as configured.
#
# Built realistically in two steps, not hand-crafted from scratch: first a
# real run produces a real, generator-authentic pytest-pre-push config
# (same shape Build-PreCommitConfigContent always produces); THEN only the
# entry line is doctored to point at a path that cannot exist, simulating
# "this worked before, something external made the exe unreachable" while
# keeping everything else byte-for-byte generator-authentic -- so a
# "kept verbatim" assertion is actually meaningful, instead of comparing
# against a hand-written file the generator would never itself produce.
$spawnFailRepo = New-FakeGitRepo -Name 'fake-spawnfail-repo'
Write-Utf8NoBomFile -Path (Join-Path $spawnFailRepo 'pyproject.toml') -Content "[project]`nname = ""x""`n"
Write-Utf8NoBomFile -Path (Join-Path $spawnFailRepo 'pytest.ini') -Content "[pytest]`n"
New-Item -ItemType Directory -Path (Join-Path $spawnFailRepo 'tests') -Force | Out-Null
Write-Utf8NoBomFile -Path (Join-Path $spawnFailRepo 'tests\test_x.py') -Content "def test_ok():`n    assert 1 + 1 == 2`n"
Push-Location -LiteralPath $spawnFailRepo
try { Invoke-GitSilent -GitArgs @('add', '-A'); Invoke-GitSilent -GitArgs @('commit', '-q', '-m', 'initial') } finally { Pop-Location }
$rSpawnFailSetup = Invoke-InitRepo -RepoPath $spawnFailRepo
Assert-True ($rSpawnFailSetup.ExitCode -eq 0) 'sanity: the setup run that creates a real pytest-pre-push hook exits 0' "exit=$($rSpawnFailSetup.ExitCode)"
$spawnFailConfigReal = Read-TextFile -Path (Join-Path $spawnFailRepo '.pre-commit-config.yaml')
Assert-True ($spawnFailConfigReal -match 'pytest-pre-push') 'sanity: the setup run produced a real pytest-pre-push hook to doctor'
$spawnFailConfigDoctored = [regex]::Replace($spawnFailConfigReal, '(?m)^(\s*entry:\s*).+$', '${1}C:\this\path\does\not\exist\fake-python.exe -m pytest -x -q')
Write-Utf8NoBomFile -Path (Join-Path $spawnFailRepo '.pre-commit-config.yaml') -Content $spawnFailConfigDoctored
$rSpawnFail = Invoke-InitRepo -RepoPath $spawnFailRepo
Assert-True ($rSpawnFail.ExitCode -eq 0) 'init-repo.ps1 exits 0 even when the existing hook''s validator hits a spawn exception' "exit=$($rSpawnFail.ExitCode) stderr=$($rSpawnFail.Stderr)"
$spawnFailConfigAfter = Read-TextFile -Path (Join-Path $spawnFailRepo '.pre-commit-config.yaml')
Assert-True ($spawnFailConfigAfter -eq $spawnFailConfigDoctored) 'the doctored entry (pointing at an unreachable exe) is kept byte-for-byte -- a validator spawn failure must NEVER be treated as proof the hook is broken' "before=$spawnFailConfigDoctored after=$spawnFailConfigAfter"
Assert-True ($rSpawnFail.Stdout -match 'No se pudo verificar') 'the message explicitly says the hook could NOT be verified (validator error), distinct from "ya NO funciona" (the command itself failing)' "stdout=$($rSpawnFail.Stdout)"
Assert-True ($rSpawnFail.Stdout -notmatch 'ya NO funciona') 'this must NOT be reported as the command itself failing -- it is a validator/infrastructure problem'

Write-Host ''
Write-Host '=== TEST GROUP 2p (lesson 4, item 4a, THE REAL INCIDENT SHAPE): a kit-generated config with a hand-added exclude + comment is preserved byte-identical, and the warning lists it ==='
# Real incident: another AI session added a documented "exclude:" line
# (with its own explanatory comment) directly in a kit-managed config for
# a legitimate reason (pre-existing whitespace errors would otherwise
# block commits until a dedicated cleanup). Built realistically: a real
# run first, THEN the customization is added on top of the generator's
# own real output, exactly like a person editing the file after the fact.
$customizedRepo = New-FakeGitRepo -Name 'fake-customized-repo'
Write-Utf8NoBomFile -Path (Join-Path $customizedRepo 'app.py') -Content "def add(a, b):`n    return a + b`n"
Push-Location -LiteralPath $customizedRepo
try { Invoke-GitSilent -GitArgs @('add', '-A'); Invoke-GitSilent -GitArgs @('commit', '-q', '-m', 'initial') } finally { Pop-Location }
$rCustomizedSetup = Invoke-InitRepo -RepoPath $customizedRepo
Assert-True ($rCustomizedSetup.ExitCode -eq 0) 'sanity: the setup run exits 0' "exit=$($rCustomizedSetup.ExitCode)"
$customizedConfigReal = Read-TextFile -Path (Join-Path $customizedRepo '.pre-commit-config.yaml')
Assert-True ($customizedConfigReal -match 'trailing-whitespace') 'sanity: the setup run produced the base trailing-whitespace hook to customize'
$excludeLine = "        exclude: '^app/main\.py$'"
$customizedConfigDoctored = $customizedConfigReal -replace '(?m)(^\s*-\s*id:\s*trailing-whitespace\s*$)', ("`$1`n# Excluido a mano: errores de espacios preexistentes en app/main.py`n# bloquearian cada commit hasta una limpieza dedicada aparte (ADS-BUG-020).`n" + $excludeLine)
Assert-True ($customizedConfigDoctored -ne $customizedConfigReal) 'sanity: the doctoring actually changed the file (the exclude + comment were really inserted)'
Write-Utf8NoBomFile -Path (Join-Path $customizedRepo '.pre-commit-config.yaml') -Content $customizedConfigDoctored
$rCustomized = Invoke-InitRepo -RepoPath $customizedRepo
Assert-True ($rCustomized.ExitCode -eq 0) 'init-repo.ps1 exits 0 when it finds a customized kit-managed config' "exit=$($rCustomized.ExitCode) stderr=$($rCustomized.Stderr)"
$customizedConfigAfter = Read-TextFile -Path (Join-Path $customizedRepo '.pre-commit-config.yaml')
Assert-True ($customizedConfigAfter -eq $customizedConfigDoctored) 'the customized config (exclude + comment) is preserved BYTE-IDENTICAL -- never silently overwritten' "before=$customizedConfigDoctored after=$customizedConfigAfter"
Assert-True ($rCustomized.Stdout -match 'Config personalizado detectado') 'init-repo.ps1 reports that it detected a customized config'
Assert-True ($rCustomized.Stdout -match [regex]::Escape("exclude: '^app/main")) 'the warning output actually LISTS the detected custom line (the exclude), not just a generic notice' "stdout=$($rCustomized.Stdout)"
Assert-True ($rCustomized.Stdout -match 'ADS-BUG-020') 'the warning output also surfaces the hand-written explanatory comment, not only the exclude line itself'
$customizedClaudeMd = Read-TextFile -Path (Join-Path $customizedRepo 'CLAUDE.md')
Assert-True ($customizedClaudeMd -match 'tiene agregados propios') 'CLAUDE.md uses the distinct "Customized" wording, not the generic "never was ours" foreign-config wording' "claudeMd=$customizedClaudeMd"

Write-Host ''
Write-Host '=== TEST GROUP 2q (lesson 4, item 4b): a PRISTINE kit config (no customization) still regenerates freely on re-run ==='
$pristineRepo = New-FakeGitRepo -Name 'fake-pristine-repo'
Write-Utf8NoBomFile -Path (Join-Path $pristineRepo 'README.md') -Content "# generic repo, no customization ever`n"
Push-Location -LiteralPath $pristineRepo
try { Invoke-GitSilent -GitArgs @('add', '-A'); Invoke-GitSilent -GitArgs @('commit', '-q', '-m', 'initial') } finally { Pop-Location }
$rPristine1 = Invoke-InitRepo -RepoPath $pristineRepo
Assert-True ($rPristine1.ExitCode -eq 0) 'first run on the pristine repo exits 0' "exit=$($rPristine1.ExitCode)"
$rPristine2 = Invoke-InitRepo -RepoPath $pristineRepo
Assert-True ($rPristine2.ExitCode -eq 0) 'second run on the still-pristine repo exits 0' "exit=$($rPristine2.ExitCode)"
Assert-True ($rPristine2.Stdout -match [regex]::Escape('Escribi .pre-commit-config.yaml')) 'a pristine (never hand-edited) config keeps going through the normal write path on re-run, not the preserve path' "stdout=$($rPristine2.Stdout)"
Assert-True ($rPristine2.Stdout -notmatch 'Config personalizado detectado') 'a pristine config never triggers the customization warning -- only a real difference does'

Write-Host ''
Write-Host '=== TEST GROUP 2r (lesson 4, item 4c, THE EXACT MCP-2-ON-MAIN SHAPE): unittest hook + ADS-BUG-020 exclude together are preserved byte-identical ==='
# Combines everything from this whole arc into the one real shape that
# actually exists on MCP-2's main branch: a validated, working unittest
# pre-push hook (nested app\tests, lessons 3/3b/3c) PLUS the hand-added
# ADS-BUG-020 exclude/comment (lesson 4) in the SAME file at the same time.
$mcp2MainRepo = New-FakeGitRepo -Name 'fake-mcp2-main-shape-repo'
New-Item -ItemType Directory -Path (Join-Path $mcp2MainRepo 'app\tests') -Force | Out-Null
Write-Utf8NoBomFile -Path (Join-Path $mcp2MainRepo 'app\main.py') -Content "def add(a, b):`n    return a + b`n"
Write-Utf8NoBomFile -Path (Join-Path $mcp2MainRepo 'app\tests\__init__.py') -Content ''
Write-Utf8NoBomFile -Path (Join-Path $mcp2MainRepo 'app\tests\test_main.py') -Content "import unittest`nfrom main import add`n`nclass TestMain(unittest.TestCase):`n    def test_add(self):`n        self.assertEqual(add(1, 2), 3)`n"
Push-Location -LiteralPath $mcp2MainRepo
try { Invoke-GitSilent -GitArgs @('add', '-A'); Invoke-GitSilent -GitArgs @('commit', '-q', '-m', 'initial') } finally { Pop-Location }
$rMcp2MainSetup = Invoke-InitRepo -RepoPath $mcp2MainRepo
Assert-True ($rMcp2MainSetup.ExitCode -eq 0) 'sanity: the setup run (no pytest.ini here, pure unittest shape) exits 0' "exit=$($rMcp2MainSetup.ExitCode)"
$mcp2MainConfigReal = Read-TextFile -Path (Join-Path $mcp2MainRepo '.pre-commit-config.yaml')
Assert-True ($mcp2MainConfigReal -match 'unittest-pre-push') 'sanity: the setup run produced the real unittest pre-push hook'
$mcp2MainExcludeLine = "        exclude: '^app/main\.py$'"
$mcp2MainConfigDoctored = $mcp2MainConfigReal -replace '(?m)(^\s*-\s*id:\s*trailing-whitespace\s*$)', ("`$1`n# Excluido a mano: errores de espacios preexistentes en app/main.py`n# bloquearian cada commit hasta una limpieza dedicada aparte (ADS-BUG-020).`n" + $mcp2MainExcludeLine)
Assert-True ($mcp2MainConfigDoctored -ne $mcp2MainConfigReal) 'sanity: the doctoring actually inserted the ADS-BUG-020 exclude + comment'
Write-Utf8NoBomFile -Path (Join-Path $mcp2MainRepo '.pre-commit-config.yaml') -Content $mcp2MainConfigDoctored
Push-Location -LiteralPath $mcp2MainRepo
try { Invoke-GitSilent -GitArgs @('add', '-A'); Invoke-GitSilent -GitArgs @('commit', '-q', '-m', 'ads-bug-020 exclude') } finally { Pop-Location }
$rMcp2Main = Invoke-InitRepo -RepoPath $mcp2MainRepo
Assert-True ($rMcp2Main.ExitCode -eq 0) 'init-repo.ps1 exits 0 on the exact MCP-2-on-main shape' "exit=$($rMcp2Main.ExitCode) stderr=$($rMcp2Main.Stderr)"
$mcp2MainConfigAfter = Read-TextFile -Path (Join-Path $mcp2MainRepo '.pre-commit-config.yaml')
Assert-True ($mcp2MainConfigAfter -eq $mcp2MainConfigDoctored) 'the unittest hook AND the ADS-BUG-020 exclude are BOTH preserved byte-identical together -- the exact real incident this whole arc protects against' "before=$mcp2MainConfigDoctored after=$mcp2MainConfigAfter"
Assert-True ($rMcp2Main.Stdout -match [regex]::Escape('todavia funciona -- lo mantengo tal cual')) 'the existing unittest hook is still separately confirmed as still working (lessons 3b/3c), on top of the item-4 customization protection'
Assert-True ($rMcp2Main.Stdout -match 'Config personalizado detectado') 'the customization safety net also reports explicitly'
Assert-True (Test-Path -LiteralPath (Join-Path $mcp2MainRepo '.git\hooks\pre-push')) 'the real git pre-push hook (installed during setup) is still in place'

# ------------------------------------------------------------------
# TEST GROUP 3: cross-review.ps1 -DryRun (never calls a real AI in this suite)
# ------------------------------------------------------------------
Write-Host ''
Write-Host '=== TEST GROUP 3: cross-review.ps1 -DryRun output shape, for all three targets ==='
# A small real change to review, so the diff is non-empty.
Write-Utf8NoBomFile -Path (Join-Path $pyRepo 'app.py') -Content "def add(a, b):`n    return a + b`n`n`ndef sub(a, b):`n    return a - b`n"

foreach ($con in @('kimi', 'codex', 'claude')) {
    $r = Invoke-CrossReviewDryRun -RepoPath $pyRepo -Con $con
    Assert-True ($r.ExitCode -eq 0) "cross-review.ps1 -DryRun exits 0 for -Con $con" "exit=$($r.ExitCode) stderr=$($r.Stderr)"
    Assert-True ($r.Stdout -match 'DRY RUN') "-Con $con -DryRun output announces DRY RUN"
    Assert-True ($r.Stdout -match [regex]::Escape('Comando:')) "-Con $con -DryRun output shows the exact command that would run"
    Assert-True ($r.Stdout -match 'Prompt') "-Con $con -DryRun output shows the prompt that would be sent"
    Assert-True ($r.Stdout -match [regex]::Escape('LGTM')) "-Con $con -DryRun prompt instructs the reviewer to answer LGTM when there is nothing to flag"
    $tempFileMatch = [regex]::Match($r.Stdout, 'quality-kit-review-[0-9a-f]+\.txt')
    Assert-True ($tempFileMatch.Success) "-Con $con -DryRun output references a temp diff file"
    if ($tempFileMatch.Success) {
        $tempFilePath = Join-Path ([System.IO.Path]::GetTempPath()) $tempFileMatch.Value
        Assert-True (Test-Path -LiteralPath $tempFilePath) "-Con $con -DryRun leaves the temp diff file on disk for inspection (by design, only in -DryRun)"
        $tempFileContent = Read-TextFile -Path $tempFilePath
        Assert-True ($tempFileContent -match 'def sub') "-Con $con temp diff file actually contains the real diff content"
        Remove-Item -LiteralPath $tempFilePath -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ''
Write-Host '=== TEST GROUP 3b: cross-review.ps1 -Alcance variations select the right diff ==='
Push-Location -LiteralPath $pyRepo
try { Invoke-GitSilent -GitArgs @('add', '-A') } finally { Pop-Location }
$rStaged = Invoke-CrossReviewDryRun -RepoPath $pyRepo -Con 'kimi' -Alcance 'staged'
Assert-True ($rStaged.Stdout -match 'Alcance: staged') '-Alcance staged is reflected in the output label'
$rWorking = Invoke-CrossReviewDryRun -RepoPath $pyRepo -Con 'kimi' -Alcance 'working'
Assert-True ($rWorking.Stdout -match 'Alcance: working') '-Alcance working is reflected in the output label'
Assert-True ([string]::IsNullOrWhiteSpace(($rWorking.Stdout -split "`n" | Where-Object { $_ -match 'Tamano del diff: 0 ' }))) 'sanity: -Alcance working with nothing unstaged still runs (may be empty, must not crash)' 'informational only'
Push-Location -LiteralPath $pyRepo
try { Invoke-GitSilent -GitArgs @('commit', '-q', '-m', 'add sub function') } finally { Pop-Location }
$rLast = Invoke-CrossReviewDryRun -RepoPath $pyRepo -Con 'kimi' -Alcance 'last-commit'
Assert-True ($rLast.Stdout -match 'Alcance: last-commit') '-Alcance last-commit is reflected in the output label'
Assert-True ($rLast.ExitCode -eq 0) '-Alcance last-commit works even though this reads git show HEAD (no HEAD~1 assumption)' "exit=$($rLast.ExitCode)"

$rDefault = Invoke-CrossReviewDryRun -RepoPath $pyRepo -Con 'kimi'
Assert-True ($rDefault.Stdout -match [regex]::Escape('Alcance: combinado')) 'omitting -Alcance defaults to the combined (staged + working) label'

Write-Host ''
Write-Host '=== TEST GROUP 3c: cross-review.ps1 caps an oversized diff at ~60KB with a truncation notice ==='
$bigDiffRepo = New-FakeGitRepo -Name 'fake-bigdiff-repo'
Write-Utf8NoBomFile -Path (Join-Path $bigDiffRepo 'big.txt') -Content 'placeholder'
Push-Location -LiteralPath $bigDiffRepo
try { Invoke-GitSilent -GitArgs @('add', '-A'); Invoke-GitSilent -GitArgs @('commit', '-q', '-m', 'initial') } finally { Pop-Location }
$bigContent = ('x = 1  # filler line to pad size past the 60KB cap' + "`n") * 2000
Write-Utf8NoBomFile -Path (Join-Path $bigDiffRepo 'big.txt') -Content $bigContent
$rBig = Invoke-CrossReviewDryRun -RepoPath $bigDiffRepo -Con 'kimi' -Alcance 'working'
Assert-True ($rBig.ExitCode -eq 0) 'cross-review.ps1 -DryRun still exits 0 on an oversized diff' "exit=$($rBig.ExitCode)"
$tempFileMatchBig = [regex]::Match($rBig.Stdout, 'quality-kit-review-[0-9a-f]+\.txt')
Assert-True ($tempFileMatchBig.Success) 'oversized-diff run still references a temp diff file'
if ($tempFileMatchBig.Success) {
    $tempFilePathBig = Join-Path ([System.IO.Path]::GetTempPath()) $tempFileMatchBig.Value
    $tempFileContentBig = Read-TextFile -Path $tempFilePathBig
    Assert-True ($tempFileContentBig.Length -le 60200) 'the written diff file is capped near the ~60KB (60000 char) limit, not the full oversized diff' "length=$($tempFileContentBig.Length)"
    Assert-True ($tempFileContentBig -match 'diff truncado') 'the capped diff file carries an explicit truncation notice'
    Remove-Item -LiteralPath $tempFilePathBig -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host '=== TEST GROUP 3d: cross-review.ps1 handles an empty diff gracefully ==='
$emptyDiffRepo = New-FakeGitRepo -Name 'fake-emptydiff-repo'
Write-Utf8NoBomFile -Path (Join-Path $emptyDiffRepo 'README.md') -Content "# nothing changed here`n"
Push-Location -LiteralPath $emptyDiffRepo
try { Invoke-GitSilent -GitArgs @('add', '-A'); Invoke-GitSilent -GitArgs @('commit', '-q', '-m', 'initial') } finally { Pop-Location }
$rEmpty = Invoke-CrossReviewDryRun -RepoPath $emptyDiffRepo -Con 'kimi'
Assert-True ($rEmpty.ExitCode -eq 0) 'cross-review.ps1 exits 0 cleanly when there is nothing to review' "exit=$($rEmpty.ExitCode)"
Assert-True ($rEmpty.Stdout -match 'No hay diferencias') 'cross-review.ps1 says plainly there is nothing to review, instead of calling the AI on an empty diff'

Write-Host ''
Write-Host '=== TEST GROUP 3e: cross-review.ps1 -Con auto (chain, -Excluir, self-review guard) ==='
# Earlier groups may have left $pyRepo fully committed (empty diff), and an
# empty diff makes cross-review exit early without exercising the chain --
# so guarantee a fresh working-tree change first.
Write-Utf8NoBomFile -Path (Join-Path $pyRepo 'app.py') -Content "def add(a, b):`n    return a + b`n`ndef mul(a, b):`n    return a * b`n"
# auto mode, excluding the AI that wrote the change: the chain must show
# only the remaining candidates, pick the first available one, and still
# produce the normal DRY RUN shape (command + prompt + temp diff file).
$rAuto = Invoke-CrossReviewDryRun -RepoPath $pyRepo -Con 'auto' -Excluir 'kimi'
Assert-True ($rAuto.ExitCode -eq 0) '-Con auto -DryRun exits 0' "exit=$($rAuto.ExitCode) stderr=$($rAuto.Stderr)"
Assert-True ($rAuto.Stdout -match [regex]::Escape('Cadena auto: claude -> codex')) '-Con auto -Excluir kimi announces the chain without the excluded AI'
# Only the candidate list BEFORE the '(' matters: the parenthetical
# "(excluido: kimi, ...)" legitimately names the excluded AI.
Assert-True ($rAuto.Stdout -notmatch 'Cadena auto:[^(\r\n]*kimi') '-Con auto -Excluir kimi never lists kimi as a candidate'
Assert-True ($rAuto.Stdout -match 'Candidato elegido') '-Con auto -DryRun names the candidate that would run'
Assert-True ($rAuto.Stdout -match [regex]::Escape('Comando:')) '-Con auto -DryRun still shows the exact command that would run'
Assert-True ($rAuto.Stdout -match 'DRY RUN') '-Con auto -DryRun still announces DRY RUN (no real AI called)'

# auto with no exclusion: full chain, strongest first.
$rAutoFull = Invoke-CrossReviewDryRun -RepoPath $pyRepo -Con 'auto'
Assert-True ($rAutoFull.ExitCode -eq 0) '-Con auto (sin -Excluir) -DryRun exits 0' "exit=$($rAutoFull.ExitCode)"
Assert-True ($rAutoFull.Stdout -match [regex]::Escape('Cadena auto: claude -> kimi -> codex')) '-Con auto announces the full chain, strongest brain first'

# self-review guard: asking an AI to review its own change must be refused.
$rSelf = Invoke-CrossReviewDryRun -RepoPath $pyRepo -Con 'claude' -Excluir 'claude'
Assert-True ($rSelf.ExitCode -ne 0) '-Con claude -Excluir claude is refused (an AI must not review its own change)' "exit=$($rSelf.ExitCode)"
Assert-True (($rSelf.Stdout + $rSelf.Stderr) -match 'no debe revisar su propio cambio') 'the self-review refusal explains itself plainly'

# exit-3 contract: with NO AI CLI findable on the child's PATH, auto mode
# must fall all the way through the chain and exit 3 (the harness reads
# this as "fall back to your internal reviewer") -- without ever invoking
# anything.
$rNone = Invoke-CrossReviewAutoWithoutAiClisOnPath -RepoPath $pyRepo
Assert-True ($rNone.ExitCode -eq 3) '-Con auto exits 3 when no external reviewer CLI is available (harness fallback contract)' "exit=$($rNone.ExitCode) stderr=$($rNone.Stderr)"
Assert-True ($rNone.Stdout -match 'NINGUN revisor externo') 'the exit-3 path says plainly that no external reviewer could review'
Assert-True ($rNone.Stdout -match 'no esta instalado') 'each unavailable candidate is reported as it is skipped'

Write-Host ''
Write-Host '=== TEST GROUP 3f (retro Kimi 2026-07-09): -Archivos limits the diff to the current task''s files ==='
# The real failure: a working tree holding FOUR accumulated bug fixes made
# the external reviewer time out twice reviewing everything at once. The
# fix: -Archivos scopes the diff to the files of THIS task only.
$scopeRepo = New-FakeGitRepo -Name 'fake-scope-repo'
New-Item -ItemType Directory -Path (Join-Path $scopeRepo 'sub') -Force | Out-Null
Write-Utf8NoBomFile -Path (Join-Path $scopeRepo 'bug_a.py') -Content "def a():`n    return 1`n"
Write-Utf8NoBomFile -Path (Join-Path $scopeRepo 'bug_b.py') -Content "def b():`n    return 2`n"
Write-Utf8NoBomFile -Path (Join-Path $scopeRepo 'sub\bug_c.py') -Content "def c():`n    return 3`n"
Push-Location -LiteralPath $scopeRepo
try { Invoke-GitSilent -GitArgs @('add', '-A'); Invoke-GitSilent -GitArgs @('commit', '-q', '-m', 'initial') } finally { Pop-Location }
# Simulate the accumulated tree: THREE files changed, only one belongs to the task under review.
Write-Utf8NoBomFile -Path (Join-Path $scopeRepo 'bug_a.py') -Content "def a():`n    return 100  # marker_bug_a`n"
Write-Utf8NoBomFile -Path (Join-Path $scopeRepo 'bug_b.py') -Content "def b():`n    return 200  # marker_bug_b`n"
Write-Utf8NoBomFile -Path (Join-Path $scopeRepo 'sub\bug_c.py') -Content "def c():`n    return 300  # marker_bug_c`n"

$rScoped = Invoke-CrossReviewDryRun -RepoPath $scopeRepo -Con 'kimi' -Archivos 'bug_a.py'
Assert-True ($rScoped.ExitCode -eq 0) '-Archivos scoped run exits 0' "exit=$($rScoped.ExitCode) stderr=$($rScoped.Stderr)"
Assert-True ($rScoped.Stdout -match [regex]::Escape('Archivos (pathspec de la tarea): bug_a.py')) '-Archivos scope is announced in the output'
$tempScoped = [regex]::Match($rScoped.Stdout, 'quality-kit-review-[0-9a-f]+\.txt')
Assert-True ($tempScoped.Success) '-Archivos scoped run still references a temp diff file'
if ($tempScoped.Success) {
    $tempScopedPath = Join-Path ([System.IO.Path]::GetTempPath()) $tempScoped.Value
    $tempScopedContent = Read-TextFile -Path $tempScopedPath
    Assert-True ($tempScopedContent -match 'marker_bug_a') 'the scoped diff contains the in-scope file''s change'
    Assert-True ($tempScopedContent -notmatch 'marker_bug_b') 'the scoped diff does NOT contain the other accumulated change (the whole point of -Archivos)'
    Remove-Item -LiteralPath $tempScopedPath -Force -ErrorAction SilentlyContinue
}

# Comma-separated list in ONE argument (how it arrives via 'powershell -File')
# plus a backslash Windows path: both files in, third still out.
$rMulti = Invoke-CrossReviewDryRun -RepoPath $scopeRepo -Con 'kimi' -Archivos 'bug_a.py, sub\bug_c.py'
$tempMulti = [regex]::Match($rMulti.Stdout, 'quality-kit-review-[0-9a-f]+\.txt')
Assert-True ($tempMulti.Success) 'comma-separated -Archivos run references a temp diff file'
if ($tempMulti.Success) {
    $tempMultiPath = Join-Path ([System.IO.Path]::GetTempPath()) $tempMulti.Value
    $tempMultiContent = Read-TextFile -Path $tempMultiPath
    Assert-True ($tempMultiContent -match 'marker_bug_a') 'comma-separated scope includes the first file'
    Assert-True ($tempMultiContent -match 'marker_bug_c') 'a backslash Windows path is normalized to a git pathspec and matches'
    Assert-True ($tempMultiContent -notmatch 'marker_bug_b') 'the file outside the comma-separated scope stays out'
    Remove-Item -LiteralPath $tempMultiPath -Force -ErrorAction SilentlyContinue
}

# A mistyped path yields an empty diff: must exit 0 but NAME the scope so
# the typo is visible instead of a silent "nothing to do".
$rTypo = Invoke-CrossReviewDryRun -RepoPath $scopeRepo -Con 'kimi' -Archivos 'no_existe.py'
Assert-True ($rTypo.ExitCode -eq 0) 'a scope matching nothing exits 0 (empty diff, not an error)' "exit=$($rTypo.ExitCode)"
Assert-True ($rTypo.Stdout -match 'dentro de los archivos pedidos') 'the empty-scoped-diff message names the scope so a typo is visible'

Write-Host ''
Write-Host '=== TEST GROUP 3g (audit 2026-08-03): a git failure never travels to the reviewer as a diff ==='
# Get-ReviewDiff merges git's stderr into the diff text ON PURPOSE (keeps the
# diagnostic), but nobody read git's exit code -- so in a repo with NO commits
# "git show HEAD" fails and its "fatal: ambiguous argument 'HEAD'" was handed to
# an external reviewer AS the diff, burning a whole ~100-150k-token round on an
# error message. New-FakeGitRepo deliberately leaves the repo commit-less.
$noCommitRepo = New-FakeGitRepo -Name 'fake-nocommit-repo'
$rGitFail = Invoke-CrossReviewDryRun -RepoPath $noCommitRepo -Con 'kimi' -Alcance 'last-commit'
Assert-True ($rGitFail.ExitCode -ne 0) 'a repo with no commits fails loudly instead of reviewing git''s own error text' "exit=$($rGitFail.ExitCode)"
Assert-True ($rGitFail.Stdout -match 'git fallo al armar el diff') 'the git failure is reported plainly, naming git as the culprit'
Assert-True ($rGitFail.Stdout -notmatch 'DRY RUN') 'no reviewer invocation is even prepared once git failed'

Write-Host ''
Write-Host '=== TEST GROUP 3h (audit 2026-08-03): last-commit + mistyped -Archivos is not a reviewable diff ==='
# "git show" ALWAYS prints the commit header, so a pathspec matching nothing
# still produced NON-empty output: the empty-diff guard never fired and a
# "diff" carrying zero changes went out for review. Only the presence of a
# "diff --git " line proves there is real content.
$showRepo = New-FakeGitRepo -Name 'fake-showscope-repo'
Write-Utf8NoBomFile -Path (Join-Path $showRepo 'real.py') -Content "def real():`n    return 1  # marker_real`n"
Push-Location -LiteralPath $showRepo
try { Invoke-GitSilent -GitArgs @('add', '-A'); Invoke-GitSilent -GitArgs @('commit', '-q', '-m', 'initial') } finally { Pop-Location }
$rShowTypo = Invoke-CrossReviewDryRun -RepoPath $showRepo -Con 'kimi' -Alcance 'last-commit' -Archivos 'no_existe.py'
Assert-True ($rShowTypo.ExitCode -eq 0) 'a last-commit scope matching nothing exits 0 (nothing to review, not an error)' "exit=$($rShowTypo.ExitCode)"
Assert-True ($rShowTypo.Stdout -match 'dentro de los archivos pedidos') 'the message names the scope so the typo is visible'
Assert-True ($rShowTypo.Stdout -notmatch 'DRY RUN') 'a bare commit header with no changes is never sent out as a diff'
# Sanity: the same scope with the RIGHT path still reaches the reviewer.
$rShowOk = Invoke-CrossReviewDryRun -RepoPath $showRepo -Con 'kimi' -Alcance 'last-commit' -Archivos 'real.py'
Assert-True ($rShowOk.Stdout -match 'DRY RUN') 'a last-commit scope with real changes still reaches the reviewer'

Write-Host ''
Write-Host '=== TEST GROUP 3i (audit 2026-08-03): -Con auto without -Excluir warns about self-review ==='
# Single mode refuses -Excluir == -Con outright, but auto had no guard at all:
# the chain starts at claude, usually the very AI that wrote the change, so
# forgetting the flag silently destroyed the independence this script exists for.
$rAutoNoExcl = Invoke-CrossReviewDryRun -RepoPath $pyRepo -Con 'auto'
Assert-True ($rAutoNoExcl.Stdout -match 'no pasaste -Excluir') '-Con auto without -Excluir warns that the first candidate may be reviewing its own change'
$rAutoExcl = Invoke-CrossReviewDryRun -RepoPath $pyRepo -Con 'auto' -Excluir 'claude'
Assert-True ($rAutoExcl.Stdout -notmatch 'no pasaste -Excluir') 'the warning disappears once -Excluir is given'

Write-Host ''
Write-Host '=== TEST GROUP 3j (audit 2026-08-03): env-var redirections are actually stripped before claude runs ==='
# Verified live: CLAUDE_CONFIG_DIR pointed at an empty folder makes the real
# CLI build a whole config tree there (.claude.json, projects, sessions) --
# it redirects configuration AND credentials, and it escaped both existing
# prefixes, so a session launched with it set sent the review to another
# account silently.
# This test runs for real (no -DryRun) against a FAKE claude on PATH that only
# reports which vars reached it: zero AI quota, real end-to-end stripping.
function Invoke-CrossReviewWithFakeClaude {
    param([string]$RepoPath, [string]$FakeCliDir)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $CrossReviewScript, '-Con', 'claude', '-RepoPath', $RepoPath)
    $quotedParts = @()
    foreach ($a in $argList) { $quotedParts += ('"' + $a + '"') }
    $psi.Arguments = ($quotedParts -join ' ')
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    # La CLI falsa va PRIMERO en el PATH para ganarle a la real.
    $psi.EnvironmentVariables['Path'] = $FakeCliDir + ';' + $psi.EnvironmentVariables['Path']
    # Redirecciones de mentira que el script DEBE limpiar...
    $psi.EnvironmentVariables['CLAUDE_CONFIG_DIR'] = 'C:\fake\redirected-config'
    $psi.EnvironmentVariables['ANTHROPIC_BASE_URL'] = 'https://fake.example/redirect'
    # Credencial alternativa que el prefijo viejo CLAUDE_CODE_USE_ no cubria
    # (hallazgo de la revision cruzada de kimi, 2026-08-03).
    $psi.EnvironmentVariables['CLAUDE_CODE_OAUTH_TOKEN'] = 'fake-oauth-token'
    # ...y una que a proposito NO debe limpiar (ver cabecera del script).
    $psi.EnvironmentVariables['HTTPS_PROXY'] = 'http://fake-proxy.example:8080'
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $proc.Start() | Out-Null
    # Lecturas ASYNC antes de esperar (hallazgo de la revision cruzada de kimi,
    # 2026-08-03): leer stdout hasta EOF y despues stderr EN SERIE se traba si
    # el hijo llena el buffer del pipe de stderr (~4KB) mientras el padre sigue
    # bloqueado en stdout. Invoke-CliHeadless, en cross-review.ps1, ya usa esta
    # forma correcta; este helper repetia el patron riesgoso.
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    $proc.StandardInput.Close()
    $proc.WaitForExit()
    return [PSCustomObject]@{ Stdout = $stdoutTask.Result; Stderr = $stderrTask.Result; ExitCode = $proc.ExitCode }
}

$fakeCliDir = Join-Path $TestFixturesDir 'fake-cli-bin'
New-Item -ItemType Directory -Path $fakeCliDir -Force | Out-Null
# CRLF a proposito: cmd.exe puede tropezar con un .cmd de solo LF.
$fakeClaudeCmd = "@echo off`r`nif defined CLAUDE_CONFIG_DIR (echo CFG=SET) else (echo CFG=UNSET)`r`nif defined ANTHROPIC_BASE_URL (echo BASE=SET) else (echo BASE=UNSET)`r`nif defined CLAUDE_CODE_OAUTH_TOKEN (echo OAUTH=SET) else (echo OAUTH=UNSET)`r`nif defined HTTPS_PROXY (echo PROXY=SET) else (echo PROXY=UNSET)`r`n"
Write-Utf8NoBomFile -Path (Join-Path $fakeCliDir 'claude.cmd') -Content $fakeClaudeCmd
# Un cambio sin commitear garantiza un diff real que revisar.
Write-Utf8NoBomFile -Path (Join-Path $pyRepo 'app.py') -Content "def add(a, b):`n    return a + b`n`ndef div(a, b):`n    return a / b  # marker_env_test`n"
$rEnv = Invoke-CrossReviewWithFakeClaude -RepoPath $pyRepo -FakeCliDir $fakeCliDir
Assert-True ($rEnv.Stdout -match 'CFG=UNSET') 'CLAUDE_CONFIG_DIR is stripped before claude runs (a relocated config cannot redirect the review to another account)' "stdout=$($rEnv.Stdout)"
Assert-True ($rEnv.Stdout -match 'BASE=UNSET') 'ANTHROPIC_* is still stripped (regression guard on the behaviour that already worked)'
Assert-True ($rEnv.Stdout -match 'OAUTH=UNSET') 'CLAUDE_CODE_OAUTH_TOKEN is stripped too -- the old CLAUDE_CODE_USE_ prefix left this credential door open (kimi cross-review 2026-08-03)'
Assert-True ($rEnv.Stdout -match 'PROXY=SET') 'HTTPS_PROXY is deliberately NOT stripped -- a proxy is usually mandatory infrastructure, and clearing it would cut off legitimate network access'

Write-Host ''
Write-Host '=== TEST GROUP 3k (kimi cross-review 2026-08-03): saikit-gate-heal refuses a duplicated anchor ==='
# saikit-gate-heal patches the kit hook with String.Replace, which replaces ALL
# occurrences: a duplicated anchor would inject the sentinel block twice, and the
# marker check would then report "ya-parchado" forever, hiding the damage. The
# pristine kit hook has each anchor exactly once TODAY, but that is a property of
# third-party code that any update can break -- so the script checks instead of
# assuming. The fixture is synthetic (the real hook lives outside this repo).
$SaikitGateHealScript = Join-Path $QualityKitDir 'saikit-gate-heal.ps1'
function Invoke-SaikitGateHeal {
    param([string]$FakeHome, [string[]]$ExtraArgs = @())
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $SaikitGateHealScript) + $ExtraArgs
    $quotedParts = @()
    foreach ($a in $argList) { $quotedParts += ('"' + $a + '"') }
    $psi.Arguments = ($quotedParts -join ' ')
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    # Home falso: el script real toca ~/.codex, ~/.cursor y ~/.agents (.claude
    # dejo de ser target en la Task 4.1: lo instala entero summonaikit-claude).
    $psi.EnvironmentVariables['USERPROFILE'] = $FakeHome
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $proc.Start() | Out-Null
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    $proc.StandardInput.Close()
    # WaitForExit(ms) y no WaitForExit(): el segundo espera ADEMAS a que los
    # streams redirigidos lleguen a EOF, asi que un descendiente huerfano que
    # todavia retenga el handle de stdout haria medir la vida del huerfano en
    # vez de la del proceso. ExitSeconds tiene que medir cuanto tardo en
    # terminar el SCRIPT, que es lo unico que su propio timeout puede
    # garantizar (ver TEST GROUP 3p).
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $exited = $proc.WaitForExit(180000)
    $sw.Stop()
    if (-not $exited) { try { $proc.Kill() } catch { } }
    return [PSCustomObject]@{
        Stdout      = $stdoutTask.Result
        Stderr      = $stderrTask.Result
        ExitCode    = $proc.ExitCode
        ExitSeconds = $sw.Elapsed.TotalSeconds
    }
}

# Hook sintetico minimo que contiene las tres anclas que el parche busca.
$anchorBlock = @'
#!/usr/bin/env bash
MAX_CYCLES=2

start_harness() {
  prompt_text="$(json_string_field prompt)"
  if [ -z "$prompt_text" ]; then prompt_text="$INPUT"; fi
  if ! is_engineering_task "$prompt_text"; then
    emit_allow
  fi
  # Skip the gate for trivial, low-risk edits (copy/text, spacing, formatting,
  # renames, comments). A substantive-work signal in the prompt overrides this.
  if is_trivial_task "$prompt_text"; then
    emit_allow
  fi
  echo start
}

record_tool_evidence() {
  event_name="$(json_string_field hook_event_name)"
  echo tool
}
'@

# Caso sano: una sola vez cada ancla -> parcha.
$healHomeOk = Join-Path $TestFixturesDir 'fake-home-heal-ok'
New-Item -ItemType Directory -Path (Join-Path $healHomeOk '.cursor\hooks') -Force | Out-Null
Write-Utf8NoBomFile -Path (Join-Path $healHomeOk '.cursor\hooks\summonaikit-harness.sh') -Content $anchorBlock
$rHealOk = Invoke-SaikitGateHeal -FakeHome $healHomeOk
$patchedOk = Read-TextFile -Path (Join-Path $healHomeOk '.cursor\hooks\summonaikit-harness.sh')
Assert-True ($patchedOk -match 'SAIKIT-SENTINEL-GATE') 'sanity: a hook with each anchor exactly once does get patched'
Assert-True ($rHealOk.ExitCode -eq 0) 'saikit-gate-heal exits 0 on the healthy case (fail-open by design)' "exit=$($rHealOk.ExitCode)"

# Caso roto: el ancla A duplicada -> NO debe parchar, y debe decirlo.
$healHomeDup = Join-Path $TestFixturesDir 'fake-home-heal-dup'
New-Item -ItemType Directory -Path (Join-Path $healHomeDup '.cursor\hooks') -Force | Out-Null
Write-Utf8NoBomFile -Path (Join-Path $healHomeDup '.cursor\hooks\summonaikit-harness.sh') -Content ($anchorBlock -replace 'MAX_CYCLES=2', "MAX_CYCLES=2`nMAX_CYCLES=2")
$rHealDup = Invoke-SaikitGateHeal -FakeHome $healHomeDup
$afterDup = Read-TextFile -Path (Join-Path $healHomeDup '.cursor\hooks\summonaikit-harness.sh')
Assert-True ($afterDup -notmatch 'SAIKIT-SENTINEL-GATE') 'a duplicated anchor is NOT patched -- String.Replace would have injected the block twice'
Assert-True ($rHealDup.Stdout -match 'ANCLAS-CAMBIARON') 'the duplicated anchor is reported loudly instead of failing silently'
Assert-True ($rHealDup.Stdout -match 'A=2') 'the report names which anchor and how many times it appeared'
Assert-True ($rHealDup.ExitCode -eq 0) 'even on a refused patch the script exits 0 -- it must never break a session start' "exit=$($rHealDup.ExitCode)"

Write-Host ''
Write-Host '=== TEST GROUP 3l: the two patches stay independent -- broken anchors in ONE never stop the OTHER from applying ==='
# This is the property saikit-gate-heal.ps1's own header claims explicitly:
# breaking SAIKIT-REVIEW-NOTICE v1's anchors must not disarm SAIKIT-SENTINEL-GATE
# v1, and vice versa. Two synthetic fixtures, each missing/breaking ONE patch's
# anchors while keeping the other's intact.
#
# ALTO 2 of the 2026-08-08 cross-review asked this group to use a versioned
# fixture instead of the real installed hooks, same as TEST GROUP 3m below --
# this group already does: both fixtures here are synthetic, embedded
# here-strings, exactly like every other test in this file, with no
# dependency on $env:USERPROFILE or on any kit variant being installed on the
# machine running the suite. Nothing to change here; the fix for THIS group's
# instance of the problem was already the norm the rest of the file follows.

# Fixture 1: has the sentinel's three anchors (reuses $anchorBlock from TEST
# GROUP 3k above) but NONE of the review-notice anchors (no write_state body,
# no subagent-record block, etc.) -- sentinel should still patch cleanly.
$healHomeNoRn = Join-Path $TestFixturesDir 'fake-home-heal-no-rn'
New-Item -ItemType Directory -Path (Join-Path $healHomeNoRn '.cursor\hooks') -Force | Out-Null
Write-Utf8NoBomFile -Path (Join-Path $healHomeNoRn '.cursor\hooks\summonaikit-harness.sh') -Content $anchorBlock
$rHealNoRn = Invoke-SaikitGateHeal -FakeHome $healHomeNoRn
$afterNoRn = Read-TextFile -Path (Join-Path $healHomeNoRn '.cursor\hooks\summonaikit-harness.sh')
Assert-True ($afterNoRn -match 'SAIKIT-SENTINEL-GATE') 'sentinel still patches a fixture that has its own anchors but none of review-notice''s' "content=$afterNoRn"
Assert-True ($afterNoRn -notmatch 'SAIKIT-REVIEW-NOTICE') 'review-notice correctly did NOT apply to a fixture missing all its anchors (0 occurrences, not a false match)'
Assert-True ($rHealNoRn.Stdout -match 'ANCLAS-CAMBIARON') 'the missing review-notice anchors are still reported (RN-A=0 etc), not silently ignored' "stdout=$($rHealNoRn.Stdout)"
Assert-True ($rHealNoRn.ExitCode -eq 0) 'even with one patch refused, the script still exits 0' "exit=$($rHealNoRn.ExitCode)"

# Fixture 2: the mirror case -- all six review-notice CORE anchors present and
# intact, but the sentinel's own anchor is duplicated (broken). Review-notice
# should still patch cleanly even though sentinel is refused.
$rnOnlyFixture = @'
#!/usr/bin/env bash
MAX_CYCLES=2
MAX_CYCLES=2

write_state() {
  task_hash="$1"
  cycle="$2"
  implemented="$3"
  verified="$4"
  agents_seen="$5"
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  {
    printf 'task_hash=%s\n' "$task_hash"
    printf 'cycle=%s\n' "$cycle"
    printf 'implemented=%s\n' "$implemented"
    printf 'verified=%s\n' "$verified"
    printf 'agents_seen=%s\n' "$agents_seen"
  } > "$STATE_PATH" 2>/dev/null || true
}

start_harness() {
  prompt_text="$(json_string_field prompt)"
  if [ -z "$prompt_text" ]; then prompt_text="$INPUT"; fi
  task_hash="$(printf '%s' "$prompt_text" | cksum | awk '{print $1}')"
  write_state "$task_hash" "0" "0" "0" ""
  context="$(harness_context)"
  escaped="$(json_escape "$context")"
  echo start
}

record_tool_evidence() {
  event_name="$(json_string_field hook_event_name)"
  subagent="$(json_string_field subagent_type)"
  if [ -z "$subagent" ]; then subagent="$(json_string_field subagentType)"; fi
  if [ -n "$subagent" ]; then record_agent "$subagent"; fi
  if printf '%s' "$combined" | grep -Eiq 'afterFileEdit|Edit|Write|apply_patch|file_path|edits'; then
    mark_evidence "implemented" "${file_path:-file edit}"
  fi
  echo tool
}

stop_gate() {
  missing=""
  if [ -z "$missing" ]; then
    rm -f "$STATE_PATH" "$LOG_PATH" 2>/dev/null || true
    emit_allow
  fi
}

harness_context() {
  cat <<'HARNESS_CONTEXT'
SUMMONAIKIT HARNESS RECEIPT
Understand: ...
Implement: ...
Verify: ...
Review: ...
Close: evidence summary and remaining gaps.
Retro: harness/codebase-memory improvement, or "none".
HARNESS_CONTEXT
}
'@
$healHomeRnOnly = Join-Path $TestFixturesDir 'fake-home-heal-rn-only'
New-Item -ItemType Directory -Path (Join-Path $healHomeRnOnly '.cursor\hooks') -Force | Out-Null
Write-Utf8NoBomFile -Path (Join-Path $healHomeRnOnly '.cursor\hooks\summonaikit-harness.sh') -Content $rnOnlyFixture
$rHealRnOnly = Invoke-SaikitGateHeal -FakeHome $healHomeRnOnly
$afterRnOnly = Read-TextFile -Path (Join-Path $healHomeRnOnly '.cursor\hooks\summonaikit-harness.sh')
Assert-True ($afterRnOnly -match 'SAIKIT-REVIEW-NOTICE') 'review-notice still patches a fixture that has its own anchors intact but a broken sentinel anchor' "content=$afterRnOnly"
Assert-True ($afterRnOnly -notmatch 'SAIKIT-SENTINEL-GATE') 'sentinel correctly did NOT apply to a fixture whose own anchor is duplicated'
Assert-True ($rHealRnOnly.Stdout -match 'ANCLAS-CAMBIARON') 'the duplicated sentinel anchor (A=2) is still reported' "stdout=$($rHealRnOnly.Stdout)"
Assert-True ($rHealRnOnly.ExitCode -eq 0) 'even with the other patch refused, the script still exits 0' "exit=$($rHealRnOnly.ExitCode)"

Write-Host ''
Write-Host '=== TEST GROUP 3m: SAIKIT-REVIEW-NOTICE v1 end-to-end -- drives a PATCHED COPY of a real-shaped hook exactly like Claude Code does (JSON on stdin, SUMMONAIKIT_HOOK_TARGET=claude, phase dispatched from hook_event_name) ==='
# TEST GROUP 3l above only proves the ANCHOR TEXT matches -- its fixtures are a
# handful of lines with none of the vendor hook's real functions (write_state,
# record_agent, mark_evidence, stop_gate...), so they cannot exercise the actual
# gate BEHAVIOR this patch adds. These tests instead drive full-shaped hooks
# (.claude/.cursor/.agents structural shape, and the structurally distinct
# .codex shape) for real.
#
# ALTO 2 of the 2026-08-08 cross-review: this group used to require the REAL
# hooks installed at ~/.claude and ~/.codex as its ONLY fixture, and hard-failed
# (Assert-True $false) when either was missing -- a machine with .claude but no
# .codex (normal: nobody installed the Codex variant of the kit there) turned
# the WHOLE group red for a reason unrelated to the code under test, and every
# other test in this file uses a synthetic, versioned fixture instead. FIX:
# two frozen, version-controlled copies of a real vendor hook -- the
# .claude/.cursor/.agents structural shape and the .codex structural shape --
# live under tests\fixtures\vendor-hooks\ and are the PRIMARY fixture this
# group always drives, on ANY machine, with or without either kit variant
# installed. The hooks ACTUALLY installed on this machine (if any) are still
# exercised too, as an OPPORTUNISTIC bonus pass (catches the frozen fixtures
# drifting from a real SummonAI Kit update) -- but missing them now only SKIPS
# that bonus pass with a warning, it never fails the suite. Neither pass ever
# writes to the real ~/.claude, ~/.codex, ~/.cursor, ~/.agents -- both copy
# their hook source into a throwaway fake home first.
$FixturesVendorHooksDir = Join-Path $QualityKitDir 'tests\fixtures\vendor-hooks'
$FrozenClaudeHook = Join-Path $FixturesVendorHooksDir 'summonaikit-harness.claude.sh'
$FrozenCodexHook = Join-Path $FixturesVendorHooksDir 'summonaikit-harness.codex.sh'
Assert-True (Test-Path -LiteralPath $FrozenClaudeHook) 'setup: the frozen .claude-shape vendor hook fixture is present in the repo (tests\fixtures\vendor-hooks)' "path=$FrozenClaudeHook"
Assert-True (Test-Path -LiteralPath $FrozenCodexHook) 'setup: the frozen .codex-shape vendor hook fixture is present in the repo (tests\fixtures\vendor-hooks)' "path=$FrozenCodexHook"

# HARD REQUIREMENT under test (the whole point of this patch being
# advisory-only): NOT ONE scenario below may ever produce exit code 2. Every
# Invoke-HarnessHook Stop call made in this test group is collected into
# $script:RnStopExitCodes so a single assertion at the end can check all of
# them at once, in addition to each scenario's own per-case exit-code check.
$script:RnStopExitCodes = @()

function Get-BashExeForTests {
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
$RnBashExe = Get-BashExeForTests
# La pasada live del hook GENeRICO (claude-shape) apunta al .cursor REAL, no al
# .claude: desde la Task 4.1 .claude no es target del heal (lo instala entero
# summonaikit-claude, con marcador de propiedad y los fixes Task 3.x adentro),
# asi que ya no es un sujeto valido para verificar que el heal PARCHEA un hook
# vendor real. .cursor/.agents comparten la shape y son vendor (sin marcador, sin
# los fixes 3.x), exactamente lo que el fixture congelado representa.
$LiveClaudeHookForRnTests = Join-Path $env:USERPROFILE '.cursor\hooks\summonaikit-harness.sh'
$LiveCodexHookForRnTests = Join-Path $env:USERPROFILE '.codex\hooks\summonaikit-harness.sh'

if ($null -eq $RnBashExe) {
    # This is a genuine missing TOOL prerequisite (same tier as git, which the
    # whole suite already assumes throughout) -- not a "did you install this
    # optional kit variant" machine-variance issue, so it stays a hard failure.
    Assert-True $false 'TEST GROUP 3m setup: found a real bash.exe on this machine (required to drive the hook the same way Claude Code does)' 'no bash.exe on PATH or at the fixed Git-for-Windows install paths'
} else {
    # Runs the hook with a JSON payload on stdin, the same contract Claude Code
    # itself uses (SUMMONAIKIT_HOOK_TARGET selects the sequential-subagent
    # enforcement branch; PHASE is left unset so the hook derives it from
    # hook_event_name itself, exactly like a real invocation).
    function Invoke-HarnessHook {
        param([string]$HookPath, [string]$WorkingDirectory, [string]$Json)
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $RnBashExe
        $psi.Arguments = '"' + $HookPath + '"'
        $psi.WorkingDirectory = $WorkingDirectory
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        # Touch EnvironmentVariables once to lazily populate it from the real
        # current environment (same trick as Invoke-ScriptCaptureWithoutBashOnPath
        # above) before overriding the one var Claude Code itself sets.
        $null = $psi.EnvironmentVariables['PATH']
        $psi.EnvironmentVariables['SUMMONAIKIT_HOOK_TARGET'] = 'claude'
        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        $proc.Start() | Out-Null
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        $proc.StandardInput.Write($Json)
        $proc.StandardInput.Close()
        $proc.WaitForExit()
        return [PSCustomObject]@{ Stdout = $stdoutTask.Result; Stderr = $stderrTask.Result; ExitCode = $proc.ExitCode }
    }

    function Start-HarnessTurn {
        param([string]$HookPath, [string]$Dir)
        return (Invoke-HarnessHook -HookPath $HookPath -WorkingDirectory $Dir -Json '{"hook_event_name":"UserPromptSubmit","prompt":"implement the thing -saikit"}')
    }
    function Add-HarnessSubagent {
        param([string]$HookPath, [string]$Dir, [string]$Role)
        $json = '{"hook_event_name":"PostToolUse","tool_name":"Task","subagent_type":"' + $Role + '"}'
        Invoke-HarnessHook -HookPath $HookPath -WorkingDirectory $Dir -Json $json | Out-Null
    }
    function Add-HarnessEdit {
        param([string]$HookPath, [string]$Dir, [string]$FilePath, [string]$Content = '')
        # Also writes a REAL file on disk, not just the JSON notification -- an
        # actual Edit/Write tool call always changes a real file first and THEN
        # fires the PostToolUse event; this mirrors that (the hook itself never
        # reads the file's content, only the event's tool_name/file_path, but a
        # real project directory with real files is a closer approximation of
        # production than a bare JSON stream).
        $fullPath = Join-Path $Dir $FilePath
        $parent = Split-Path -Path $fullPath -Parent
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        if ($Content -eq '') { $Content = "line-$([guid]::NewGuid().ToString('N'))`n" }
        Write-Utf8NoBomFile -Path $fullPath -Content $Content
        $json = '{"hook_event_name":"PostToolUse","tool_name":"Edit","file_path":"' + $FilePath + '"}'
        Invoke-HarnessHook -HookPath $HookPath -WorkingDirectory $Dir -Json $json | Out-Null
    }
    # Lists the per-project state-key subdirectories that exist right now
    # under a hook copy's own state root, so a scenario can diff before/after
    # Start-HarnessTurn to find ITS key without reimplementing the hook's own
    # cksum-based hashing in PowerShell.
    function Get-HarnessStateKeys {
        param([string]$StateRoot)
        if (-not (Test-Path -LiteralPath $StateRoot)) { return @() }
        return @(Get-ChildItem -LiteralPath $StateRoot -Directory | ForEach-Object { $_.Name })
    }
    function New-HarnessProject {
        param([string]$HookPath, [string]$Name)
        $dir = New-FakeGitRepo -Name $Name
        $stateRoot = Join-Path (Split-Path -Path $HookPath -Parent) 'state'
        $before = Get-HarnessStateKeys -StateRoot $stateRoot
        $startResult = Start-HarnessTurn -HookPath $HookPath -Dir $dir
        $script:RnStopExitCodes += $startResult.ExitCode
        $after = Get-HarnessStateKeys -StateRoot $stateRoot
        $key = @($after | Where-Object { $before -notcontains $_ })[0]
        return [PSCustomObject]@{
            Dir         = $dir
            StatePath   = Join-Path $stateRoot (Join-Path $key 'harness-state.env')
            LogPath     = Join-Path $stateRoot (Join-Path $key 'harness-evidence.log')
            OrderPath   = Join-Path $stateRoot (Join-Path $key 'harness-state-review-notice.env')
            # El pendiente va por PROYECTO (STATE_DIR), no por sesion: asi lo
            # entrega tambien a una sesion distinta de la que lo escribio (el
            # bug real observado en la variante .codex, que llavea el estado
            # por session_id).
            PendingPath = Join-Path $stateRoot (Join-Path $key 'review-notice-pending.log')
            FirstStart  = $startResult
        }
    }
    # Fed as raw stdin, same as the SUMMONAIKIT HARNESS RECEIPT block a real
    # agent turn ends with; "ran npm test" alone satisfies the Verify-evidence
    # check via TEST_RUNNER_RE, so no separate tool call is needed for that gate.
    $RnReceipt = (@'
{"hook_event_name":"Stop","transcript_path":""}
SUMMONAIKIT HARNESS RECEIPT
Understand: build the thing the user asked for
Implement: changed the file
Verify: ran npm test, all green
Review: no findings
Close: done, nothing pending
Retro: none
'@ -replace "`r`n", "`n")

    # Runs the FULL SAIKIT-REVIEW-NOTICE v1 behavior suite against ONE pair of
    # hook sources (either the frozen fixtures or a real installed pair),
    # copied into their own throwaway home keyed by $Label so two passes
    # (frozen + live) never collide on the same project directories or state
    # roots.
    function Invoke-ReviewNoticeScenarios {
        param([string]$ClaudeHookSource, [string]$CodexHookSource, [string]$Label)

        $slug = ($Label -replace '[^A-Za-z0-9]+', '-').Trim('-').ToLower()
        $rnHome = Join-Path $TestFixturesDir "review-notice-home-$slug"
        # El hook GENeRICO (claude-shape, $claudeHook) vive a .cursor y no a .claude
        # desde la Task 4.1: .claude ya no es target del heal. La shape es la misma
        # (.claude/.cursor/.agents comparten estructura); el NOMBRE $claudeHook
        # denota la shape, no el path de instalacion.
        New-Item -ItemType Directory -Path (Join-Path $rnHome '.cursor\hooks') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $rnHome '.codex\hooks') -Force | Out-Null
        $claudeHook = Join-Path $rnHome '.cursor\hooks\summonaikit-harness.sh'
        $codexHook = Join-Path $rnHome '.codex\hooks\summonaikit-harness.sh'
        Copy-Item -LiteralPath $ClaudeHookSource -Destination $claudeHook -Force
        Copy-Item -LiteralPath $CodexHookSource -Destination $codexHook -Force

        $heal1 = Invoke-SaikitGateHeal -FakeHome $rnHome
        Assert-True ($heal1.Stdout -notmatch 'ANCLAS-CAMBIARON') "[$Label] setup: healing the hook copies reports NO ANCLAS-CAMBIARON on either variant -- regression guard: the .codex variant is structurally different (harness_context_lite, resolve_state_paths, ROLE FALLBACK branches) and its anchors could silently stop fitting on a kit update" "stdout=$($heal1.Stdout)"
        $patchedClaudeRn = Read-TextFile -Path $claudeHook
        $patchedCodexRn = Read-TextFile -Path $codexHook
        Assert-True ($patchedClaudeRn -match 'SAIKIT-REVIEW-NOTICE v1') "[$Label] setup: the generic (claude-shape) copy at .cursor carries the SAIKIT-REVIEW-NOTICE v1 marker after healing"
        Assert-True ($patchedCodexRn -match 'SAIKIT-REVIEW-NOTICE v1') "[$Label] setup: the .codex copy ALSO carries the SAIKIT-REVIEW-NOTICE v1 marker after healing"
        & $RnBashExe -n $claudeHook 2>&1 | Out-Null
        Assert-True ($LASTEXITCODE -eq 0) "[$Label] setup: the patched generic (claude-shape) copy is still syntactically valid bash"
        & $RnBashExe -n $codexHook 2>&1 | Out-Null
        Assert-True ($LASTEXITCODE -eq 0) "[$Label] setup: the patched .codex copy is still syntactically valid bash"

        Write-Host ''
        Write-Host "--- [$Label] idempotency: applying saikit-gate-heal.ps1 a second time leaves both hook copies byte-identical ---"
        $claudeAfter1st = Read-TextFile -Path $claudeHook
        $codexAfter1st = Read-TextFile -Path $codexHook
        Invoke-SaikitGateHeal -FakeHome $rnHome | Out-Null
        $claudeAfter2nd = Read-TextFile -Path $claudeHook
        $codexAfter2nd = Read-TextFile -Path $codexHook
        Assert-True ([string]::Equals($claudeAfter1st, $claudeAfter2nd, [System.StringComparison]::Ordinal)) "[$Label] a second saikit-gate-heal.ps1 run leaves the generic (claude-shape) copy byte-identical (idempotent)"
        Assert-True ([string]::Equals($codexAfter1st, $codexAfter2nd, [System.StringComparison]::Ordinal)) "[$Label] a second saikit-gate-heal.ps1 run leaves the .codex hook byte-identical too"

        Write-Host ''
        Write-Host "--- [$Label] the contract this hook injects at turn start requires the Close line to declare whether code was touched after the reviewer ran ---"
        $contractProj = New-FakeGitRepo -Name "review-notice-$slug-contract-proj"
        $contractOut = Start-HarnessTurn -HookPath $claudeHook -Dir $contractProj
        $script:RnStopExitCodes += $contractOut.ExitCode
        Assert-True ($contractOut.ExitCode -eq 0) "[$Label] starting a turn (UserPromptSubmit) never blocks" "exit=$($contractOut.ExitCode)"
        Assert-True (($contractOut.Stdout) -match 'state explicitly whether code was touched after the reviewer subagent last ran') "[$Label] the injected contract's Close line requires declaring whether code was touched after the reviewer ran" "stdout=$($contractOut.Stdout)"
        # Regression guard for the anchor-selection risk called out for .codex: the
        # SAME check on the .codex copy must ALSO be reachable through its OWN
        # contract text (harness_context on the regular path) -- a separate check
        # against harness_context_lite specifically follows further below.
        $contractProjCodex = New-FakeGitRepo -Name "review-notice-$slug-contract-proj-codex"
        $contractOutCodex = Invoke-HarnessHook -HookPath $codexHook -WorkingDirectory $contractProjCodex -Json '{"hook_event_name":"UserPromptSubmit","prompt":"implement the thing -saikit","session_id":"contract-sess"}'
        $script:RnStopExitCodes += $contractOutCodex.ExitCode
        Assert-True ($contractOutCodex.ExitCode -eq 0) "[$Label] codex variant: starting a turn never blocks either" "exit=$($contractOutCodex.ExitCode)"
        Assert-True (($contractOutCodex.Stdout) -match 'state explicitly whether code was touched after the reviewer subagent last ran') "[$Label] codex variant: the regular (non-lite) injected contract also requires the Close declaration" "stdout=$($contractOutCodex.Stdout)"
        $contractOutCodexLite = Invoke-HarnessHook -HookPath $codexHook -WorkingDirectory $contractProjCodex -Json '{"hook_event_name":"UserPromptSubmit","prompt":"implement the thing -saikit -harness-lite","session_id":"contract-sess-lite"}'
        $script:RnStopExitCodes += $contractOutCodexLite.ExitCode
        Assert-True ($contractOutCodexLite.ExitCode -eq 0) "[$Label] codex variant: starting a -harness-lite turn never blocks" "exit=$($contractOutCodexLite.ExitCode)"
        Assert-True (($contractOutCodexLite.Stdout) -match 'state explicitly whether code was touched after the reviewer subagent last ran') "[$Label] codex variant: the LITE contract (harness_context_lite, a separate anchor from the regular one) ALSO requires the Close declaration" "stdout=$($contractOutCodexLite.Stdout)"

        Write-Host ''
        Write-Host "--- [$Label] (a) implementer -> edit -> verifier -> reviewer -> edit AGAIN -> Stop: the notice line lands in the evidence log AND the turn is NOT blocked (exit 0) ---"
        $projA = New-HarnessProject -HookPath $claudeHook -Name "review-notice-$slug-proj-a"
        Add-HarnessSubagent -HookPath $claudeHook -Dir $projA.Dir -Role 'implementer'
        Add-HarnessEdit -HookPath $claudeHook -Dir $projA.Dir -FilePath 'src/app.py' -Content "def add(a, b):`n    return a + b`n"
        Add-HarnessSubagent -HookPath $claudeHook -Dir $projA.Dir -Role 'verifier'
        Add-HarnessSubagent -HookPath $claudeHook -Dir $projA.Dir -Role 'reviewer'
        Add-HarnessEdit -HookPath $claudeHook -Dir $projA.Dir -FilePath 'src/app.py' -Content "def add(a, b):`n    return a + b + 1`n"

        # Probe: an INCOMPLETE Stop call (bare event, no receipt at all) still
        # runs the review-notice check -- it runs on EVERY Stop call, not only
        # a clean close -- while leaving the evidence log in place long enough
        # to inspect it. MEDIO fix (RN-E): the log is now ALWAYS removed on a
        # clean close, same as the original vendor behaviour, so this probe is
        # the only way to observe the timestamped audit line from outside the
        # hook process. Its exit code is intentionally kept OUT of
        # $script:RnStopExitCodes: it fails the PRE-EXISTING ceremony gate for
        # an unrelated reason (no receipt at all), which has nothing to do
        # with review-notice and must not be mistaken for a review-notice block.
        $probeA = Invoke-HarnessHook -HookPath $claudeHook -WorkingDirectory $projA.Dir -Json '{"hook_event_name":"Stop","transcript_path":""}'
        Assert-True ($probeA.ExitCode -ne 0) "[$Label] (a) sanity: the probe Stop call (no receipt at all) correctly fails the PRE-EXISTING ceremony gate -- confirms the log inspected next has not already been cleaned up by a clean close" "exit=$($probeA.ExitCode)"
        Assert-True (Test-Path -LiteralPath $projA.LogPath) "[$Label] (a) the evidence log exists while the gate is still open (before any clean close could remove it)"
        $logContentA = Read-TextFile -Path $projA.LogPath
        Assert-True ($logContentA -match 'review-notice: code was edited after the last reviewer subagent run') "[$Label] (a) the evidence log carries the review-notice line" "log=$logContentA"
        Assert-True ($logContentA -match '(?i)tool-name signal only') "[$Label] (a) the logged line itself declares its own limitation (not just a code comment) -- it is what a human reading the log actually sees" "log=$logContentA"
        Assert-True ($logContentA -match '(?i)sed|heredoc|git apply') "[$Label] (a) the logged limitation names the concrete evasion it cannot see (a shell edit), not just a vague caveat" "log=$logContentA"
        Assert-True ($logContentA -match '\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z review-notice:') "[$Label] ALTO 1 regression guard: the logged line carries an ISO-8601 UTC timestamp, so a stale notice can be told apart from a fresh one" "log=$logContentA"

        # The REAL close: send the full receipt now.
        $outA = Invoke-HarnessHook -HookPath $claudeHook -WorkingDirectory $projA.Dir -Json $RnReceipt
        $script:RnStopExitCodes += $outA.ExitCode
        Assert-True ($outA.ExitCode -eq 0) "[$Label] (a) the turn is NOT blocked even though code was edited again after the reviewer ran -- this patch is advisory-only" "exit=$($outA.ExitCode) stdout=$($outA.Stdout) stderr=$($outA.Stderr)"
        Assert-True (($outA.Stdout) -match '"systemMessage"') "[$Label] (a) IMMEDIATE channel: the clean close emits a systemMessage JSON so the USER sees the notice at the end of the SAME turn, not only when the next -saikit turn arms" "stdout=$($outA.Stdout)"
        Assert-True (($outA.Stdout) -match 'SAIKIT REVIEW NOTICE') "[$Label] (a) the systemMessage carries the actual notice text" "stdout=$($outA.Stdout)"
        Assert-True (($outA.Stdout) -notmatch '"decision"') "[$Label] (a) the systemMessage JSON carries NO decision field -- it can inform but structurally cannot block" "stdout=$($outA.Stdout)"
        Assert-True (-not (Test-Path -LiteralPath $projA.LogPath)) "[$Label] (a) MEDIO regression guard: the evidence log IS removed on the clean close, exactly like before this patch -- the audit trail already landed in the timestamped line above, and the pending notice (checked next) now lives in its own file, so the log no longer needs special preservation"
        Assert-True (-not (Test-Path -LiteralPath $projA.StatePath)) "[$Label] (a) the harness state file is still removed on a clean close, same as before this patch"
        Assert-True (-not (Test-Path -LiteralPath $projA.OrderPath)) "[$Label] (a) the order-counter file is removed on a clean close too -- no orphaned state left behind"
        Assert-True (Test-Path -LiteralPath $projA.PendingPath) "[$Label] ALTO 1 (a) NEW: the pending-notice file DOES survive the clean close -- this is the channel the next turn reads from"
        $pendingContentA = Read-TextFile -Path $projA.PendingPath
        Assert-True ($pendingContentA -match 'SAIKIT REVIEW NOTICE: in your previous turn, code was edited after the reviewer subagent last ran, and those edits were not reviewed') "[$Label] ALTO 1 (a) NEW: the pending-notice file's content is exactly the text the next turn will inject" "pending=$pendingContentA"

        Write-Host ''
        Write-Host "--- [$Label] ALTO 1 (new): the pending notice from the previous turn is INJECTED into the NEXT turn's contract, then clears itself ---"
        # NEW (a): the very next turn built on the SAME project must see the
        # notice prepended to the injected contract text.
        $projANextTurn = Start-HarnessTurn -HookPath $claudeHook -Dir $projA.Dir
        $script:RnStopExitCodes += $projANextTurn.ExitCode
        Assert-True ($projANextTurn.ExitCode -eq 0) "[$Label] NEW (a) starting the following turn on the same project never blocks" "exit=$($projANextTurn.ExitCode)"
        Assert-True (($projANextTurn.Stdout) -match 'SAIKIT REVIEW NOTICE: in your previous turn, code was edited after the reviewer subagent last ran, and those edits were not reviewed') "[$Label] NEW (a) the pending notice from the previous turn appears in the text injected when the following turn is built" "stdout=$($projANextTurn.Stdout)"
        Assert-True (-not (Test-Path -LiteralPath $projA.PendingPath)) "[$Label] NEW (a) the pending-notice file is consumed (deleted) the moment it is injected"

        # NEW (b): a further turn (after the notice already fired once) must
        # NOT see it again -- it was consumed, not just read.
        $projANextTurn2 = Start-HarnessTurn -HookPath $claudeHook -Dir $projA.Dir
        $script:RnStopExitCodes += $projANextTurn2.ExitCode
        Assert-True ($projANextTurn2.ExitCode -eq 0) "[$Label] NEW (b) a further turn after the notice already fired once never blocks" "exit=$($projANextTurn2.ExitCode)"
        Assert-True (($projANextTurn2.Stdout) -notmatch 'SAIKIT REVIEW NOTICE') "[$Label] NEW (b) the pending notice does NOT repeat on a turn after the one that already showed it" "stdout=$($projANextTurn2.Stdout)"

        Write-Host ''
        Write-Host "--- [$Label] (b) real happy path: implementer -> edit -> verifier -> reviewer -> full receipt, nothing edited after review: no notice, not blocked ---"
        $projB = New-HarnessProject -HookPath $claudeHook -Name "review-notice-$slug-proj-b"
        Add-HarnessSubagent -HookPath $claudeHook -Dir $projB.Dir -Role 'implementer'
        Add-HarnessEdit -HookPath $claudeHook -Dir $projB.Dir -FilePath 'src/app.py'
        Add-HarnessSubagent -HookPath $claudeHook -Dir $projB.Dir -Role 'verifier'
        Add-HarnessSubagent -HookPath $claudeHook -Dir $projB.Dir -Role 'reviewer'
        $outB = Invoke-HarnessHook -HookPath $claudeHook -WorkingDirectory $projB.Dir -Json $RnReceipt
        $script:RnStopExitCodes += $outB.ExitCode
        Assert-True ($outB.ExitCode -eq 0) "[$Label] (b) the real happy path (nothing edited after review) is not blocked" "exit=$($outB.ExitCode) stdout=$($outB.Stdout) stderr=$($outB.Stderr)"
        Assert-True (($outB.Stdout) -notmatch 'systemMessage') "[$Label] (b) no notice fired, so the clean close emits NO systemMessage -- zero noise on the happy path, byte-identical to the vendor's silent allow" "stdout=$($outB.Stdout)"
        Assert-True (-not (Test-Path -LiteralPath $projB.LogPath)) "[$Label] (b) no notice fired, so the evidence log is removed on close exactly like before this patch (unchanged default behaviour)"
        Assert-True (-not (Test-Path -LiteralPath $projB.StatePath)) "[$Label] (b) regression guard: the harness state file is still removed on a clean close"
        Assert-True (-not (Test-Path -LiteralPath $projB.PendingPath)) "[$Label] (b) regression guard: no pending-notice file was ever written on the happy path"

        Write-Host ''
        Write-Host "--- [$Label] NEW (c): with no pending notice, the NEXT turn's injected text is EXACTLY what it was before this feature -- no extra prefix, no noise ---"
        $projBNextTurn = Start-HarnessTurn -HookPath $claudeHook -Dir $projB.Dir
        $script:RnStopExitCodes += $projBNextTurn.ExitCode
        Assert-True ($projBNextTurn.ExitCode -eq 0) "[$Label] NEW (c) starting the following turn after a clean happy path never blocks" "exit=$($projBNextTurn.ExitCode)"
        Assert-True (($projBNextTurn.Stdout) -notmatch 'SAIKIT REVIEW NOTICE') "[$Label] NEW (c) no stray notice appears when none was pending" "stdout=$($projBNextTurn.Stdout)"
        $projBNextCtx = ($projBNextTurn.Stdout | ConvertFrom-Json).hookSpecificOutput.additionalContext
        $projAFirstCtx = ($projA.FirstStart.Stdout | ConvertFrom-Json).hookSpecificOutput.additionalContext
        Assert-True ([string]::Equals($projBNextCtx, $projAFirstCtx, [System.StringComparison]::Ordinal)) "[$Label] NEW (c) the injected contract text (no pending notice, on two unrelated projects) is byte-identical -- the pending-notice feature adds ZERO noise when nothing is pending" "a=$projAFirstCtx b=$projBNextCtx"
        Assert-True ($projBNextCtx -match '^SUMMONAIKIT HARNESS REQUIRED') "[$Label] NEW (c) the injected contract starts exactly with the original vendor text, nothing prepended" "ctx=$projBNextCtx"

        Write-Host ''
        Write-Host "--- [$Label] (c) the only edit after the reviewer touches a .md file: no notice, not blocked ---"
        $projC = New-HarnessProject -HookPath $claudeHook -Name "review-notice-$slug-proj-c"
        Add-HarnessSubagent -HookPath $claudeHook -Dir $projC.Dir -Role 'implementer'
        Add-HarnessEdit -HookPath $claudeHook -Dir $projC.Dir -FilePath 'src/app.py'
        Add-HarnessSubagent -HookPath $claudeHook -Dir $projC.Dir -Role 'verifier'
        Add-HarnessSubagent -HookPath $claudeHook -Dir $projC.Dir -Role 'reviewer'
        Add-HarnessEdit -HookPath $claudeHook -Dir $projC.Dir -FilePath 'README.md'
        $outC = Invoke-HarnessHook -HookPath $claudeHook -WorkingDirectory $projC.Dir -Json $RnReceipt
        $script:RnStopExitCodes += $outC.ExitCode
        Assert-True ($outC.ExitCode -eq 0) "[$Label] (c) a doc-only edit after review is not blocked" "exit=$($outC.ExitCode) stdout=$($outC.Stdout) stderr=$($outC.Stderr)"
        Assert-True (($outC.Stdout) -notmatch 'systemMessage') "[$Label] (c) a doc-only edit fires no notice, so no systemMessage either" "stdout=$($outC.Stdout)"
        Assert-True (-not (Test-Path -LiteralPath $projC.LogPath)) "[$Label] (c) MEDIO regression guard: the evidence log is removed on close (always true now on a clean close, notice or not)"
        Assert-True (-not (Test-Path -LiteralPath $projC.PendingPath)) "[$Label] (c) no notice fired for a doc-only edit after review -- no pending-notice file was written either"

        Write-Host ''
        Write-Host "--- [$Label] MEDIO 2 (new): a root tracker file (STATUS.json) edited after review does NOT fire the notice, same as a .md file ---"
        $projT = New-HarnessProject -HookPath $claudeHook -Name "review-notice-$slug-proj-tracker"
        Add-HarnessSubagent -HookPath $claudeHook -Dir $projT.Dir -Role 'implementer'
        Add-HarnessEdit -HookPath $claudeHook -Dir $projT.Dir -FilePath 'src/app.py'
        Add-HarnessSubagent -HookPath $claudeHook -Dir $projT.Dir -Role 'verifier'
        Add-HarnessSubagent -HookPath $claudeHook -Dir $projT.Dir -Role 'reviewer'
        Add-HarnessEdit -HookPath $claudeHook -Dir $projT.Dir -FilePath 'STATUS.json'
        $outT = Invoke-HarnessHook -HookPath $claudeHook -WorkingDirectory $projT.Dir -Json $RnReceipt
        $script:RnStopExitCodes += $outT.ExitCode
        Assert-True ($outT.ExitCode -eq 0) "[$Label] MEDIO 2: a tracker-file-only edit after review is not blocked" "exit=$($outT.ExitCode)"
        Assert-True (-not (Test-Path -LiteralPath $projT.PendingPath)) "[$Label] MEDIO 2: a root STATUS.json (evident tracker file) edited after review does NOT fire the notice"

        Write-Host ''
        Write-Host "--- [$Label] MEDIO 2 (new): a REAL config file (tsconfig.json, not a tracker name) edited after review STILL fires the notice -- the narrow-exclusion risk is covered ---"
        $projJ = New-HarnessProject -HookPath $claudeHook -Name "review-notice-$slug-proj-realjson"
        Add-HarnessSubagent -HookPath $claudeHook -Dir $projJ.Dir -Role 'implementer'
        Add-HarnessEdit -HookPath $claudeHook -Dir $projJ.Dir -FilePath 'src/app.py'
        Add-HarnessSubagent -HookPath $claudeHook -Dir $projJ.Dir -Role 'verifier'
        Add-HarnessSubagent -HookPath $claudeHook -Dir $projJ.Dir -Role 'reviewer'
        Add-HarnessEdit -HookPath $claudeHook -Dir $projJ.Dir -FilePath 'tsconfig.json'
        $outJ = Invoke-HarnessHook -HookPath $claudeHook -WorkingDirectory $projJ.Dir -Json $RnReceipt
        $script:RnStopExitCodes += $outJ.ExitCode
        Assert-True ($outJ.ExitCode -eq 0) "[$Label] MEDIO 2: a real-config-edit-after-review turn is still never blocked (advisory-only)" "exit=$($outJ.ExitCode)"
        Assert-True (Test-Path -LiteralPath $projJ.PendingPath) "[$Label] MEDIO 2: a real config file (tsconfig.json) edited after review STILL fires the notice -- the narrow tracker/metadata exclusion must not swallow real config"

        Write-Host ''
        Write-Host "--- [$Label] fail-open: a missing/corrupt order-counter file never blocks and never logs a notice it cannot actually measure ---"
        $projD1 = New-HarnessProject -HookPath $claudeHook -Name "review-notice-$slug-proj-d1"
        Add-HarnessSubagent -HookPath $claudeHook -Dir $projD1.Dir -Role 'implementer'
        Add-HarnessEdit -HookPath $claudeHook -Dir $projD1.Dir -FilePath 'src/app.py'
        Add-HarnessSubagent -HookPath $claudeHook -Dir $projD1.Dir -Role 'verifier'
        Add-HarnessSubagent -HookPath $claudeHook -Dir $projD1.Dir -Role 'reviewer'
        Add-HarnessEdit -HookPath $claudeHook -Dir $projD1.Dir -FilePath 'src/app.py'
        Assert-True (Test-Path -LiteralPath $projD1.OrderPath) "[$Label] sanity: the order-counter file exists before we remove it"
        Remove-Item -LiteralPath $projD1.OrderPath -Force
        $outD1 = Invoke-HarnessHook -HookPath $claudeHook -WorkingDirectory $projD1.Dir -Json $RnReceipt
        $script:RnStopExitCodes += $outD1.ExitCode
        Assert-True ($outD1.ExitCode -eq 0) "[$Label] fail-open: a MISSING order-counter file does not block a turn that would otherwise have gotten a notice" "exit=$($outD1.ExitCode)"
        Assert-True (-not (Test-Path -LiteralPath $projD1.PendingPath)) "[$Label] fail-open: no notice is written when the order-counter file cannot be found -- `"cannot measure`" means stay silent, not assume the worst"

        $projD2 = New-HarnessProject -HookPath $claudeHook -Name "review-notice-$slug-proj-d2"
        Add-HarnessSubagent -HookPath $claudeHook -Dir $projD2.Dir -Role 'implementer'
        Add-HarnessEdit -HookPath $claudeHook -Dir $projD2.Dir -FilePath 'src/app.py'
        Add-HarnessSubagent -HookPath $claudeHook -Dir $projD2.Dir -Role 'verifier'
        Add-HarnessSubagent -HookPath $claudeHook -Dir $projD2.Dir -Role 'reviewer'
        Add-HarnessEdit -HookPath $claudeHook -Dir $projD2.Dir -FilePath 'src/app.py'
        Write-Utf8NoBomFile -Path $projD2.OrderPath -Content "this is not a key=value order file at all`n"
        $outD2 = Invoke-HarnessHook -HookPath $claudeHook -WorkingDirectory $projD2.Dir -Json $RnReceipt
        $script:RnStopExitCodes += $outD2.ExitCode
        Assert-True ($outD2.ExitCode -eq 0) "[$Label] fail-open: a CORRUPT order-counter file does not block" "exit=$($outD2.ExitCode)"
        Assert-True (-not (Test-Path -LiteralPath $projD2.PendingPath)) "[$Label] fail-open: no notice is written when the order-counter file is corrupt"

        Write-Host ''
        Write-Host "--- [$Label] codex variant: the same (a)/(b) scenarios, INCLUDING the new pending-notice injection, also hold on the .codex hook, not just on .claude ---"
        $projCodexA = New-HarnessProject -HookPath $codexHook -Name "review-notice-$slug-codex-a"
        Add-HarnessSubagent -HookPath $codexHook -Dir $projCodexA.Dir -Role 'implementer'
        Add-HarnessEdit -HookPath $codexHook -Dir $projCodexA.Dir -FilePath 'src/app.py'
        Add-HarnessSubagent -HookPath $codexHook -Dir $projCodexA.Dir -Role 'verifier'
        Add-HarnessSubagent -HookPath $codexHook -Dir $projCodexA.Dir -Role 'reviewer'
        Add-HarnessEdit -HookPath $codexHook -Dir $projCodexA.Dir -FilePath 'src/app.py'
        $outCodexA = Invoke-HarnessHook -HookPath $codexHook -WorkingDirectory $projCodexA.Dir -Json $RnReceipt
        $script:RnStopExitCodes += $outCodexA.ExitCode
        Assert-True ($outCodexA.ExitCode -eq 0) "[$Label] codex variant (a): edit-after-review is NOT blocked on the .codex hook either" "exit=$($outCodexA.ExitCode) stdout=$($outCodexA.Stdout) stderr=$($outCodexA.Stderr)"
        Assert-True (($outCodexA.Stdout) -match '"systemMessage"') "[$Label] codex variant (a): the immediate systemMessage channel works on the .codex hook shape too" "stdout=$($outCodexA.Stdout)"
        # The detailed evidence-log CONTENT (timestamp, caveat wording) is
        # already proven above on .claude via the probe-before-close pattern;
        # on .codex the log is removed the same way on a clean close (shared
        # RN-E code path), so the meaningful cross-check here is the surviving
        # pending-notice file, plus the next-turn injection checked right below.
        Assert-True (-not (Test-Path -LiteralPath $projCodexA.LogPath)) "[$Label] codex variant (a): the evidence log is removed on the clean close too, same as .claude"
        Assert-True (Test-Path -LiteralPath $projCodexA.PendingPath) "[$Label] codex variant (a): the pending-notice file survives the clean close on .codex too"

        $projCodexANextTurn = Invoke-HarnessHook -HookPath $codexHook -WorkingDirectory $projCodexA.Dir -Json '{"hook_event_name":"UserPromptSubmit","prompt":"continue -saikit","session_id":"codex-a-sess"}'
        $script:RnStopExitCodes += $projCodexANextTurn.ExitCode
        Assert-True ($projCodexANextTurn.ExitCode -eq 0) "[$Label] codex variant NEW (a): the following turn never blocks" "exit=$($projCodexANextTurn.ExitCode)"
        Assert-True (($projCodexANextTurn.Stdout) -match 'SAIKIT REVIEW NOTICE: in your previous turn, code was edited after the reviewer subagent last ran, and those edits were not reviewed') "[$Label] codex variant NEW (a): the pending notice is injected into the next turn's contract on .codex too" "stdout=$($projCodexANextTurn.Stdout)"

        $projCodexB = New-HarnessProject -HookPath $codexHook -Name "review-notice-$slug-codex-b"
        Add-HarnessSubagent -HookPath $codexHook -Dir $projCodexB.Dir -Role 'implementer'
        Add-HarnessEdit -HookPath $codexHook -Dir $projCodexB.Dir -FilePath 'src/app.py'
        Add-HarnessSubagent -HookPath $codexHook -Dir $projCodexB.Dir -Role 'verifier'
        Add-HarnessSubagent -HookPath $codexHook -Dir $projCodexB.Dir -Role 'reviewer'
        $outCodexB = Invoke-HarnessHook -HookPath $codexHook -WorkingDirectory $projCodexB.Dir -Json $RnReceipt
        $script:RnStopExitCodes += $outCodexB.ExitCode
        Assert-True ($outCodexB.ExitCode -eq 0) "[$Label] codex variant (b): the happy path still passes on .codex" "exit=$($outCodexB.ExitCode) stdout=$($outCodexB.Stdout) stderr=$($outCodexB.Stderr)"
        Assert-True (-not (Test-Path -LiteralPath $projCodexB.LogPath)) "[$Label] codex variant (b): the evidence log is removed on close, same as .claude"
        Assert-True (-not (Test-Path -LiteralPath $projCodexB.PendingPath)) "[$Label] codex variant (b): no notice fired on the happy path, so no pending-notice file was written either"
    }

    # ---- ALWAYS run against the frozen, version-controlled fixtures: this is
    # the mandatory, PRIMARY pass -- it never depends on what is or is not
    # installed on the machine running the suite.
    Invoke-ReviewNoticeScenarios -ClaudeHookSource $FrozenClaudeHook -CodexHookSource $FrozenCodexHook -Label 'frozen fixture'

    # ---- OPPORTUNISTIC bonus pass against whatever is actually installed on
    # THIS machine (if anything). Returns $true if it actually ran, $false if
    # it skipped -- callers use this to prove the skip never turns into a
    # failure (test (e) below).
    function Invoke-OpportunisticLiveHookPass {
        param([string]$ClaudeHookPath, [string]$CodexHookPath, [string]$Label)
        if (-not (Test-Path -LiteralPath $ClaudeHookPath) -or -not (Test-Path -LiteralPath $CodexHookPath)) {
            Write-Host ''
            Write-Host "[skip] $Label -- the real installed SummonAI Kit hooks were not both found on this machine (claude=$ClaudeHookPath codex=$CodexHookPath). The frozen fixtures above already covered every behavior in this group; this pass is only a bonus drift check, so it is SKIPPED, not failed." -ForegroundColor Yellow
            return $false
        }
        Write-Host ''
        Write-Host "=== [$Label] bonus pass: the same suite, driven against the hooks actually installed on this machine ==="
        Invoke-ReviewNoticeScenarios -ClaudeHookSource $ClaudeHookPath -CodexHookSource $CodexHookPath -Label $Label
        return $true
    }

    Invoke-OpportunisticLiveHookPass -ClaudeHookPath $LiveClaudeHookForRnTests -CodexHookPath $LiveCodexHookForRnTests -Label 'live install' | Out-Null

    # ---- (e): the opportunistic pass correctly SKIPS (never fails) on a
    # simulated machine that has the generic (claude-shape) hook installed at
    # .cursor but NOT .codex -- the exact real-world gap (ALTO 2) that used to
    # turn the whole group red. A synthetic profile is enough here: only its
    # PRESENCE/ABSENCE matters to the skip logic under test, not its content.
    Write-Host ''
    Write-Host '=== TEST GROUP 3m (e): the opportunistic live-hook pass skips cleanly (never fails) on a simulated machine without .codex installed ==='
    $noCodexProfile = Join-Path $TestFixturesDir 'simulated-no-codex-profile'
    New-Item -ItemType Directory -Path (Join-Path $noCodexProfile '.cursor\hooks') -Force | Out-Null
    Copy-Item -LiteralPath $FrozenClaudeHook -Destination (Join-Path $noCodexProfile '.cursor\hooks\summonaikit-harness.sh') -Force
    # Deliberately NO .codex\hooks\summonaikit-harness.sh anywhere under here.
    $failCountBeforeNoCodex = $script:FailCount
    $ranNoCodex = Invoke-OpportunisticLiveHookPass -ClaudeHookPath (Join-Path $noCodexProfile '.cursor\hooks\summonaikit-harness.sh') -CodexHookPath (Join-Path $noCodexProfile '.codex\hooks\summonaikit-harness.sh') -Label 'simulated machine without .codex'
    Assert-True ($ranNoCodex -eq $false) '(e) the opportunistic pass correctly reports it was SKIPPED (not run) when .codex is missing, instead of hard-failing' "ranNoCodex=$ranNoCodex"
    Assert-True ($script:FailCount -eq $failCountBeforeNoCodex) '(e) simulating a machine without .codex adds ZERO new failures to the suite -- this is the exact real-world gap (ALTO 2) that used to turn TEST GROUP 3m red for an unrelated reason' "before=$failCountBeforeNoCodex after=$($script:FailCount)"

    Write-Host ''
    Write-Host '--- (d)/(f) THE MOST IMPORTANT CHECK: not one Stop invocation across every pass above (frozen fixture, live install if present) ever returned exit code 2 ---'
    # This patch is advisory-only by hard requirement: it must never turn a
    # passing turn into a blocked one. Every scenario above -- including the
    # ones that DO trigger the notice -- is asserted individually above to
    # exit 0, but this single aggregate check is the one the spec calls out as
    # non-negotiable: scan every exit code collected across every pass and
    # confirm exit code 2 (the hook's own block-decision code) never appears,
    # not even once.
    $rnBlockedCount = @($script:RnStopExitCodes | Where-Object { $_ -eq 2 }).Count
    Assert-True ($rnBlockedCount -eq 0) '(d)/(f) across every scenario in every pass of this test group, SAIKIT-REVIEW-NOTICE v1 never produced exit code 2 (the block-decision exit code)' "exit codes seen: $($script:RnStopExitCodes -join ',')"
}

# ------------------------------------------------------------------
# TEST GROUP 3n / 3o: convivencia con summonaikit-claude (su Task 2.3).
# ------------------------------------------------------------------
Write-Host ''
Write-Host '=== TEST GROUP 3n: a hook that carries the summonaikit-claude ownership marker is SKIPPED, not patched ==='
# POR QUE: el repo summonaikit-claude adopto el hook de .claude por REEMPLAZO
# (escribe el archivo entero desde su propia fuente) y desde la Task 4.1 .claude
# dejo de ser target del heal. El skip por marcador queda como RED DE SEGURIDAD:
# si un .codex/.cursor/.agents llegara a portar el marcador (por una copia
# manual, p.ej.), se saltea entero para no pisar al otro escritor. En produccion
# ningun target restante lo porta, asi que este grupo es el que mantiene viva la
# cobertura del mecanismo -- sintetico, declarado, pero necesario.
#
# El criterio de deteccion es DELIBERADAMENTE mas ancho que el del instalador
# del otro repo: ese exige el marcador en la linea 2 exacta y trata cualquier
# otra posicion como "desconocido, no tocar"; este saltea ante el marcador en
# CUALQUIER linea. Los dos convergen en no escribir -- y ante una senal de
# propiedad ambigua, abstenerse es la unica opcion segura para el escritor por
# anclas.
$OwnershipMarkerLine = '# SAIKIT-CLAUDE-OWNED summonaikit-claude 1.0.0'

function New-MarkedHookText {
    param([string]$Text, [int]$AtLine = 2)
    $lines = @(($Text -replace "`r`n", "`n") -split "`n")
    $head = $lines[0..($AtLine - 2)]
    $tail = $lines[($AtLine - 1)..($lines.Count - 1)]
    return ((@($head) + @($OwnershipMarkerLine) + @($tail)) -join "`n")
}

# Fixture: el hook .codex congelado MAS el marcador en la linea 2. Es el
# fixture que discrimina: sin el skip, este archivo se parcharia (el .codex
# congelado trae las anclas de SAIKIT-REVIEW-NOTICE intactas y todavia no ese
# parche); con el skip, queda igual byte a byte. El marcador va sobre .codex (un
# target restante) porque .claude ya no se itera desde la Task 4.1 -- el
# mecanismo se ejerce sobre un target que el heal realmente toca.
#
# El parche que discrimina aca es REVIEW-NOTICE y no SENTINEL: el hook
# congelado ya venia con el sentinel aplicado (es una copia de un hook real),
# asi que buscar el marcador del sentinel despues del heal daria verde con o sin
# el skip. El sentinel tiene su propio caso discriminante mas abajo, sobre el
# fixture sintetico que no trae ninguno de los dos.
$healHomeOwned = Join-Path $TestFixturesDir 'fake-home-heal-owned'
New-Item -ItemType Directory -Path (Join-Path $healHomeOwned '.codex\hooks') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $healHomeOwned '.cursor\hooks') -Force | Out-Null
$markedCodexHook = Join-Path $healHomeOwned '.codex\hooks\summonaikit-harness.sh'
$unmarkedCursorHook = Join-Path $healHomeOwned '.cursor\hooks\summonaikit-harness.sh'
Write-Utf8NoBomFile -Path $markedCodexHook -Content (New-MarkedHookText -Text (Read-TextFile -Path $FrozenCodexHook))
# El .cursor del MISMO home queda SIN marcador: el skip tiene que ser por
# archivo, no por corrida.
Copy-Item -LiteralPath $FrozenClaudeHook -Destination $unmarkedCursorHook -Force

$markedHashBefore = (Get-FileHash -LiteralPath $markedCodexHook -Algorithm SHA256).Hash
$cursorHashBefore = (Get-FileHash -LiteralPath $unmarkedCursorHook -Algorithm SHA256).Hash
$rHealOwned = Invoke-SaikitGateHeal -FakeHome $healHomeOwned
$markedHashAfter = (Get-FileHash -LiteralPath $markedCodexHook -Algorithm SHA256).Hash
$cursorHashAfter = (Get-FileHash -LiteralPath $unmarkedCursorHook -Algorithm SHA256).Hash
$markedAfter = Read-TextFile -Path $markedCodexHook
$cursorAfterOwned = Read-TextFile -Path $unmarkedCursorHook

Assert-True ($markedHashAfter -eq $markedHashBefore) 'a hook carrying the ownership marker is left byte-identical -- a marked file is skipped whole, never rewritten by anchors' "before=$markedHashBefore after=$markedHashAfter"
Assert-True ($markedAfter -notmatch 'SAIKIT-REVIEW-NOTICE') 'the skipped hook did NOT get the review-notice patch injected -- it would have (this fixture has the RN anchors intact and none of that patch yet)'
Assert-True ($rHealOwned.Stdout -match 'saltado') 'the skip is REPORTED, not silent -- an operator must be able to see why a marked hook was left untouched' "stdout=$($rHealOwned.Stdout)"
Assert-True ($rHealOwned.Stdout -match 'SAIKIT-CLAUDE-OWNED') 'the report names the marker it found, so the reason is diagnosable without reading this script'
Assert-True ($rHealOwned.Stdout -notmatch 'ANCLAS-CAMBIARON') 'a skipped-by-ownership hook is NOT reported as a broken patch -- it is the expected skip state, not a failure' "stdout=$($rHealOwned.Stdout)"
Assert-True ($rHealOwned.ExitCode -eq 0) 'the skip still exits 0 (fail-open: this script must never break a session start)' "exit=$($rHealOwned.ExitCode)"

# DoD punto 2: los otros perfiles (sin marcador) se siguen parcheando igual.
Assert-True ($cursorHashAfter -ne $cursorHashBefore) 'the UNMARKED .cursor hook in the SAME run WAS rewritten -- the skip is per FILE, not per run' "before=$cursorHashBefore after=$cursorHashAfter"
Assert-True ($cursorAfterOwned -match 'SAIKIT-REVIEW-NOTICE') 'the unmarked .cursor hook still gets the review-notice patch it was missing'

# Idempotencia del skip: una segunda corrida tampoco lo toca.
Invoke-SaikitGateHeal -FakeHome $healHomeOwned | Out-Null
$markedHash2nd = (Get-FileHash -LiteralPath $markedCodexHook -Algorithm SHA256).Hash
Assert-True ($markedHash2nd -eq $markedHashBefore) 'a second heal run still leaves the marked hook byte-identical' "before=$markedHashBefore after2nd=$markedHash2nd"

# Marcador FUERA de la linea 2: sigue siendo una senal de propiedad, y ante una
# senal ambigua el escritor por anclas se abstiene igual (el instalador del otro
# repo hace lo simetrico: lo llama "desconocido" y tampoco escribe). El fixture
# va sobre .cursor (un target restante).
#
# Este fixture es ademas el caso discriminante del OTRO parche: $anchorBlock no
# trae ninguno de los dos marcadores, asi que sin el skip se le inyectaria el
# sentinel. Entre los dos fixtures de este grupo, cada parche tiene un caso que
# lo mata.
$healHomeOwnedLate = Join-Path $TestFixturesDir 'fake-home-heal-owned-late'
New-Item -ItemType Directory -Path (Join-Path $healHomeOwnedLate '.cursor\hooks') -Force | Out-Null
$lateCursorHook = Join-Path $healHomeOwnedLate '.cursor\hooks\summonaikit-harness.sh'
# Linea 3 y no cualquiera: es la linea EN BLANCO entre el ancla A y el ancla B,
# el unico lugar de este fixture que esta fuera de la linea 2 y no parte ninguna
# ancla. Medido: con el marcador en la linea 5 este caso quedaba adentro del
# ancla B, y entonces sobrevivia a una mutacion del criterio "cualquier linea"
# -> "solo la linea 2" por el motivo equivocado (el ancla rota, no el skip).
Write-Utf8NoBomFile -Path $lateCursorHook -Content (New-MarkedHookText -Text $anchorBlock -AtLine 3)
$lateHashBefore = (Get-FileHash -LiteralPath $lateCursorHook -Algorithm SHA256).Hash
$rHealLate = Invoke-SaikitGateHeal -FakeHome $healHomeOwnedLate
$lateHashAfter = (Get-FileHash -LiteralPath $lateCursorHook -Algorithm SHA256).Hash
$lateAfter = Read-TextFile -Path $lateCursorHook
Assert-True ($lateHashAfter -eq $lateHashBefore) 'the marker on a line OTHER than line 2 also skips -- ambiguous ownership is still ownership for a by-anchor writer' "before=$lateHashBefore after=$lateHashAfter"
Assert-True ($lateAfter -notmatch 'SAIKIT-SENTINEL-GATE') 'the SENTINEL patch is skipped too -- this fixture carries neither marker, so it would have been patched without the skip'
Assert-True ($rHealLate.Stdout -notmatch 'ANCLAS-CAMBIARON') 'the skip is evaluated BEFORE the anchor check -- this fixture has none of the review-notice anchors, and checking them first would raise a permanent false alarm about a file that is never going to be patched here' "stdout=$($rHealLate.Stdout)"
Assert-True ($rHealLate.ExitCode -eq 0) 'the out-of-position marker case still exits 0' "exit=$($rHealLate.ExitCode)"

Write-Host ''
Write-Host '=== TEST GROUP 3o: check-hook-registration.sh is wired into the heal (summonaikit-claude Task 0.3 + 2.3) ==='
# POR QUE: todo lo que este script mira es CONTENIDO. El modo de falla mas
# silencioso del sistema es el otro: settings.json deja de nombrar al hook y el
# gate no existe, con el archivo intacto. El verificador de ese registro vive en
# summonaikit-claude (tools/check-hook-registration.sh); aca se lo cablea al
# unico script que ya corre en cada SessionStart.
#
# El fixture PRIMARIO es un verificador falso, por la misma razon que TEST GROUP
# 3m congelo sus vendor hooks (ALTO 2, 2026-08-08): la bateria no puede volverse
# roja porque otro repo no este clonado en esta maquina. Lo que se prueba aca es
# el CABLEADO -- que se lo invoque, con el settings del perfil correcto, y que su
# salida llegue al operador. El verificador real se ejercita como pasada
# oportunista mas abajo.
$fakeCheckDir = Join-Path $TestFixturesDir 'fake-registration-check'
New-Item -ItemType Directory -Path $fakeCheckDir -Force | Out-Null
$fakeCheckLoud = Join-Path $fakeCheckDir 'loud.sh'
Write-Utf8NoBomFile -Path $fakeCheckLoud -Content "#!/usr/bin/env bash`nprintf 'FAKE-REGISTRATION-CHECK saw: %s\n' `"`$*`"`nexit 0`n"
$fakeCheckQuiet = Join-Path $fakeCheckDir 'quiet.sh'
Write-Utf8NoBomFile -Path $fakeCheckQuiet -Content "#!/usr/bin/env bash`nexit 0`n"

function New-HealHomeWithSettings {
    # $SettingsJson vacio = NO se escribe settings.json. Va sin tipar a
    # proposito: un [string] convierte $null en '' y el `if` de abajo escribia
    # igual un settings.json de 0 bytes, que es un perfil CON settings (ilegible)
    # y no el caso "no hay perfil" que este helper tiene que poder construir.
    param([string]$Name, $SettingsJson)
    $home_ = Join-Path $TestFixturesDir $Name
    New-Item -ItemType Directory -Path (Join-Path $home_ '.claude\hooks') -Force | Out-Null
    Write-Utf8NoBomFile -Path (Join-Path $home_ '.claude\hooks\summonaikit-harness.sh') -Content $anchorBlock
    if (-not [string]::IsNullOrEmpty($SettingsJson)) {
        Write-Utf8NoBomFile -Path (Join-Path $home_ '.claude\settings.json') -Content $SettingsJson
    }
    return $home_
}

$settingsWithHook = @'
{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"bash ~/.claude/hooks/summonaikit-harness.sh"}]}],"PostToolUse":[{"hooks":[{"type":"command","command":"bash ~/.claude/hooks/summonaikit-harness.sh"}]}],"Stop":[{"hooks":[{"type":"command","command":"bash ~/.claude/hooks/summonaikit-harness.sh"}]}]}}
'@
$settingsWithoutHook = @'
{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"echo something-else"}]}]}}
'@

# (a) cableado: se lo invoca, y con el settings del perfil .claude de ESTE home.
$regHomeA = New-HealHomeWithSettings -Name 'fake-home-heal-reg-a' -SettingsJson $settingsWithoutHook
$rRegA = Invoke-SaikitGateHeal -FakeHome $regHomeA -ExtraArgs @('-RegistrationCheck', $fakeCheckLoud)
Assert-True ($rRegA.Stdout -match 'FAKE-REGISTRATION-CHECK saw:') 'the heal actually RUNS the registration checker (it is wired, not just documented)' "stdout=$($rRegA.Stdout)"
Assert-True ($rRegA.Stdout -match '--settings') 'the checker is called with --settings, the contract it documents'
Assert-True ($rRegA.Stdout -match 'fake-home-heal-reg-a') 'it is pointed at THIS profile''s settings, not at the real ~/.claude (Core Rule 4 of the other repo: never test against live state)' "stdout=$($rRegA.Stdout)"
Assert-True ($rRegA.ExitCode -eq 0) 'wiring the checker in does not change the heal''s exit code' "exit=$($rRegA.ExitCode)"

# (b) el verificador callado no agrega ruido: su propio diseno ya calla cuando
# el registro esta completo, y el heal no debe inventar una linea encima.
$regHomeB = New-HealHomeWithSettings -Name 'fake-home-heal-reg-b' -SettingsJson $settingsWithHook
$rRegB = Invoke-SaikitGateHeal -FakeHome $regHomeB -ExtraArgs @('-RegistrationCheck', $fakeCheckQuiet)
Assert-True ($rRegB.Stdout -notmatch 'REGISTRO') 'a checker with nothing to say produces NO registration line at all -- a warning on every startup is how an operator learns to ignore warnings' "stdout=$($rRegB.Stdout)"
Assert-True ($rRegB.ExitCode -eq 0) 'the quiet path still exits 0' "exit=$($rRegB.ExitCode)"

# (c) sin settings que mirar, no se invoca nada. Es lo que mantiene a esta
# bateria (y a los fake homes de 3k/3l/3m, que no tienen settings) libre de
# ruido y sin depender de que otro repo exista en la maquina.
$regHomeC = New-HealHomeWithSettings -Name 'fake-home-heal-reg-c' -SettingsJson $null
$rRegC = Invoke-SaikitGateHeal -FakeHome $regHomeC -ExtraArgs @('-RegistrationCheck', $fakeCheckLoud)
Assert-True ($rRegC.Stdout -notmatch 'FAKE-REGISTRATION-CHECK') 'with no settings.json and no settings.local.json in the profile there is no registration to verify, so the checker is not run at all' "stdout=$($rRegC.Stdout)"

# (d) verificador ausente: unknown, NUNCA "el registro falta" (Core Rule 2 del
# otro repo -- no haber podido mirar no es haber visto ausencia).
$regHomeD = New-HealHomeWithSettings -Name 'fake-home-heal-reg-d' -SettingsJson $settingsWithoutHook
$rRegD = Invoke-SaikitGateHeal -FakeHome $regHomeD -ExtraArgs @('-RegistrationCheck', (Join-Path $fakeCheckDir 'no-existe.sh'))
Assert-True ($rRegD.Stdout -match 'unknown') 'a missing checker is reported as unknown' "stdout=$($rRegD.Stdout)"
Assert-True ($rRegD.Stdout -notmatch 'REGISTRO DEL HOOK INCOMPLETO') 'a missing checker NEVER claims the registration is absent -- not observed is not absent'
Assert-True ($rRegD.ExitCode -eq 0) 'a missing checker does not break the session start either' "exit=$($rRegD.ExitCode)"

# (e) pasada OPORTUNISTA con el verificador REAL de summonaikit-claude, si el
# repo esta en esta maquina. Si no esta, se avisa y se sigue: la bateria del kit
# no puede depender de otro repo (misma politica que la pasada live de 3m).
$RealRegistrationCheck = Join-Path (
    $(if ($env:SAIKIT_CLAUDE_REPO) { $env:SAIKIT_CLAUDE_REPO } else { 'C:\dev\summonaikit-claude' })
) 'tools\check-hook-registration.sh'
if (Test-Path -LiteralPath $RealRegistrationCheck) {
    $regHomeE = New-HealHomeWithSettings -Name 'fake-home-heal-reg-e' -SettingsJson $settingsWithoutHook
    $rRegE = Invoke-SaikitGateHeal -FakeHome $regHomeE -ExtraArgs @('-RegistrationCheck', $RealRegistrationCheck)
    Assert-True ($rRegE.Stdout -match 'REGISTRO DEL HOOK INCOMPLETO') '(live) the REAL checker, driven through the heal, reports a settings.json that no longer names the hook' "stdout=$($rRegE.Stdout)"
    Assert-True ($rRegE.Stdout -match 'PostToolUse') '(live) it names which phases the gate stopped running in'
    Assert-True ($rRegE.ExitCode -eq 0) '(live) the real checker never changes the heal''s exit code' "exit=$($rRegE.ExitCode)"

    $regHomeF = New-HealHomeWithSettings -Name 'fake-home-heal-reg-f' -SettingsJson $settingsWithHook
    $rRegF = Invoke-SaikitGateHeal -FakeHome $regHomeF -ExtraArgs @('-RegistrationCheck', $RealRegistrationCheck)
    Assert-True ($rRegF.Stdout -notmatch 'REGISTRO DEL HOOK') '(live) a fully registered profile produces no registration output at all' "stdout=$($rRegF.Stdout)"
} else {
    Write-Host "SKIP: summonaikit-claude no esta en esta maquina ($RealRegistrationCheck) -- pasada oportunista del verificador real omitida (la bateria del kit no depende de otro repo)."
}

Write-Host ''
Write-Host '=== TEST GROUP 3p (cross-review codex 2026-08-10): el cableado del registro no puede fallar en SILENCIO ==='
# Los tres casos de abajo salieron de una revision cruzada, y comparten una
# raiz: el aviso `unknown` estaba condicionado a -Quiet, que es EXACTAMENTE el
# modo con el que corre SessionStart. La politica de "no repetir avisos en cada
# arranque" era correcta para el SKIP por propiedad -- que pasa en cada arranque
# sano -- y equivocada para estos: un `unknown` solo aparece cuando algo YA esta
# roto, asi que silenciarlo vuelve "no se pudo mirar" indistinguible de "todo
# bien", que es justo lo que la Core Rule 2 del otro repo prohibe.

# (g) verificador que muere sin decir nada: un exit code nativo != 0 NO lo
# atrapa un try/catch de PowerShell, asi que sin mirarlo explicitamente el fallo
# se pierde entero.
$fakeCheckDead = Join-Path $fakeCheckDir 'dead.sh'
Write-Utf8NoBomFile -Path $fakeCheckDead -Content "#!/usr/bin/env bash`nexit 3`n"
$regHomeG = New-HealHomeWithSettings -Name 'fake-home-heal-reg-g' -SettingsJson $settingsWithoutHook
$rRegG = Invoke-SaikitGateHeal -FakeHome $regHomeG -ExtraArgs @('-RegistrationCheck', $fakeCheckDead)
Assert-True ($rRegG.Stdout -match 'unknown') 'a checker that exits non-zero with no output is reported as unknown -- a native exit code never raises, so not looking at it loses the failure entirely' "stdout=$($rRegG.Stdout)"
Assert-True ($rRegG.Stdout -notmatch 'REGISTRO DEL HOOK INCOMPLETO') 'the dead checker still never claims the registration is absent'
Assert-True ($rRegG.ExitCode -eq 0) 'a dead checker does not change the heal exit code' "exit=$($rRegG.ExitCode)"

# (h) verificador colgado: este script corre en CADA SessionStart. Antes de
# este cambio no lanzaba ningun proceso externo; ahora si, y un cuelgue ahi se
# come el presupuesto del arranque. Mismo motivo por el que cross-review.ps1
# tiene -TimeoutSec desde un cuelgue real (2026-07-05).
$fakeCheckHang = Join-Path $fakeCheckDir 'hang.sh'
Write-Utf8NoBomFile -Path $fakeCheckHang -Content "#!/usr/bin/env bash`nsleep 20`n"
$regHomeH = New-HealHomeWithSettings -Name 'fake-home-heal-reg-h' -SettingsJson $settingsWithoutHook
$rRegH = Invoke-SaikitGateHeal -FakeHome $regHomeH -ExtraArgs @('-RegistrationCheck', $fakeCheckHang, '-RegistrationTimeoutSec', '3')
# Se mide cuanto tarda en TERMINAR EL SCRIPT, no cuanto tarda en cerrarse su
# stdout. La diferencia no es cosmetica y esta medida: un `sleep` lanzado por el
# bash de Git for Windows queda HUERFANO (su padre ya no existe cuando llega el
# kill, porque MSYS2 interpone su propia capa), ningun barrido por parentesco lo
# alcanza, y sigue reteniendo el handle de stdout que heredo. Ese limite esta
# declarado en el script y acotado por el timeout del propio SessionStart; lo
# que el tope de este script SI garantiza --dejar de esperar, decirlo y salir--
# es lo que este caso mide. Margen ancho (10 s contra un tope de 3) porque lo
# que tiene que distinguir es "corto" de "espero el sleep entero", no medir
# latencia de arranque de procesos en una maquina cargada.
Assert-True ($rRegH.ExitSeconds -lt 10) 'a hung checker does not hold the heal itself hostage -- it stops waiting, says so, and exits, instead of riding out the full hang' "exitSeconds=$([math]::Round($rRegH.ExitSeconds,1))s"
Assert-True ($rRegH.Stdout -match 'unknown') 'the killed checker is reported as unknown, not silently dropped' "stdout=$($rRegH.Stdout)"
Assert-True ($rRegH.ExitCode -eq 0) 'a hung checker does not change the heal exit code either' "exit=$($rRegH.ExitCode)"

# (i) el caso que hace a los otros dos importar: SessionStart corre con -Quiet.
$regHomeI = New-HealHomeWithSettings -Name 'fake-home-heal-reg-i' -SettingsJson $settingsWithoutHook
# Hallazgo 1 de la cross-review del plan (codex): para que el -notmatch de abajo
# no sea vacuo, hace falta un target MARCADO entre los que el heal aun itera
# (.codex/.cursor/.agents). Sin el, la linea 'saltado, lo maneja' jamas se
# generaria y -Quiet no tendria nada que silenciar; .claude ya no es target. El
# skip SIN -Quiet se prueba en TEST GROUP 3n (alla la linea SI aparece).
$markedForQuiet = Join-Path $regHomeI '.codex\hooks\summonaikit-harness.sh'
New-Item -ItemType Directory -Path (Join-Path $regHomeI '.codex\hooks') -Force | Out-Null
Write-Utf8NoBomFile -Path $markedForQuiet -Content (New-MarkedHookText -Text (Read-TextFile -Path $FrozenCodexHook))
$rRegI = Invoke-SaikitGateHeal -FakeHome $regHomeI -ExtraArgs @('-Quiet', '-RegistrationCheck', (Join-Path $fakeCheckDir 'no-existe.sh'))
Assert-True ($rRegI.Stdout -match 'unknown') 'the unknown is reported UNDER -Quiet too -- that is the mode SessionStart actually uses, and hiding it there makes "could not look" indistinguishable from "all good"' "stdout=$($rRegI.Stdout)"
Assert-True ($rRegI.Stdout -notmatch 'saltado, lo maneja') '-Quiet silences the ownership-skip line even when a marked target IS present (here .codex) -- non-vacuous: without -Quiet that line WOULD fire (proven in 3n), so this proves -Quiet suppresses it rather than there simply being nothing to suppress' "stdout=$($rRegI.Stdout)"

Write-Host ''
Write-Host '=== TEST GROUP 3q (Task 4.1): .claude ya no es target del heal -- los otros 3 perfiles SI se siguen parcheando ==='
# DoD #3 de la Task 4.1: .claude deja de ser target (lo instala entero
# summonaikit-claude, con marcador de propiedad y los dos parches adentro). El
# heal ya no lo itera; los 3 perfiles restantes (.codex/.cursor/.agents) siguen
# parcheandose igual. Caso discriminante: hoy (con .claude AUN como target) el
# assert de .claude FALLA -- el heal le inyectaria el sentinel.
$healHome41 = Join-Path $TestFixturesDir 'fake-home-task-4-1'
foreach ($prof in @('.claude', '.codex', '.cursor', '.agents')) {
    New-Item -ItemType Directory -Path (Join-Path $healHome41 (Join-Path $prof 'hooks')) -Force | Out-Null
    Write-Utf8NoBomFile -Path (Join-Path $healHome41 (Join-Path $prof 'hooks\summonaikit-harness.sh')) -Content $anchorBlock
}
$claude41Path = Join-Path $healHome41 '.claude\hooks\summonaikit-harness.sh'
$claude41Before = (Get-FileHash -LiteralPath $claude41Path -Algorithm SHA256).Hash
$rHeal41 = Invoke-SaikitGateHeal -FakeHome $healHome41
$claude41After = Read-TextFile -Path $claude41Path
Assert-True ($rHeal41.ExitCode -eq 0) 'Task 4.1: el heal sigue saliendo 0 con .claude fuera del vector de targets' "exit=$($rHeal41.ExitCode)"
# DoD #3, el assert discriminante: .claude NO se toca (ni contenido ni hash).
Assert-True ($claude41After -notmatch 'SAIKIT-SENTINEL-GATE') 'Task 4.1 DoD #3: .claude ya no es target -- el heal NO le inyecta el sentinel' "content=$claude41After"
Assert-True ((Get-FileHash -LiteralPath $claude41Path -Algorithm SHA256).Hash -eq $claude41Before) 'Task 4.1: el hook .claude queda byte-identical -- no se itera, no se reporta, no se toca' "before=$claude41Before after=$((Get-FileHash -LiteralPath $claude41Path -Algorithm SHA256).Hash)"
# DoD #1: los 3 perfiles restantes SI se parchean igual que hoy.
foreach ($prof in @('.codex', '.cursor', '.agents')) {
    $patched41 = Read-TextFile -Path (Join-Path $healHome41 (Join-Path $prof 'hooks\summonaikit-harness.sh'))
    Assert-True ($patched41 -match 'SAIKIT-SENTINEL-GATE') "Task 4.1 DoD #1: el perfil restante $prof SI recibe el sentinel -- los 3 perfiles siguen parcheandose igual" "profile=$prof content=$patched41"
}

# ------------------------------------------------------------------
# TEST GROUP 4: install-ai-rules.ps1 / uninstall-ai-rules.ps1 against FAKE
# home directories -- NEVER the real ~/.claude, ~/.codex, ~/.kimi-code.
# ------------------------------------------------------------------
Write-Host ''
Write-Host '=== TEST GROUP 4: install-ai-rules.ps1 against fake AI home directories ==='
$fakeHomesDir = Join-Path $TestFixturesDir 'fake-ai-homes'
New-Item -ItemType Directory -Path (Join-Path $fakeHomesDir 'claude') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $fakeHomesDir 'codex') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $fakeHomesDir 'kimi') -Force | Out-Null
$fakeClaudeMd = Join-Path $fakeHomesDir 'claude\CLAUDE.md'
$fakeCodexAgents = Join-Path $fakeHomesDir 'codex\AGENTS.md'
$fakeKimiAgents = Join-Path $fakeHomesDir 'kimi\AGENTS.md'
$preexistingClaudeContent = "# Existing global rules`n`nSome pre-existing content that must survive untouched.`n"
Write-Utf8NoBomFile -Path $fakeClaudeMd -Content $preexistingClaudeContent
# codex\AGENTS.md and kimi\AGENTS.md deliberately left absent, to test
# "create if absent" for both.

function Invoke-InstallAiRules {
    return Invoke-ScriptCapture -ScriptPath $InstallAiRulesScript -ScriptArgs @('-ClaudeMdPath', $fakeClaudeMd, '-CodexAgentsPath', $fakeCodexAgents, '-KimiAgentsPath', $fakeKimiAgents)
}
function Invoke-UninstallAiRules {
    return Invoke-ScriptCapture -ScriptPath $UninstallAiRulesScript -ScriptArgs @('-ClaudeMdPath', $fakeClaudeMd, '-CodexAgentsPath', $fakeCodexAgents, '-KimiAgentsPath', $fakeKimiAgents)
}

$rInstall = Invoke-InstallAiRules
Assert-True ($rInstall.ExitCode -eq 0) 'install-ai-rules.ps1 exits 0 against fake home directories' "exit=$($rInstall.ExitCode) stderr=$($rInstall.Stderr)"

$claudeMdAfterInstall = Read-TextFile -Path $fakeClaudeMd
Assert-True ($claudeMdAfterInstall -match 'Some pre-existing content that must survive untouched') 'install-ai-rules.ps1 preserves pre-existing CLAUDE.md content'
Assert-True ($claudeMdAfterInstall -match 'REGLAS DE CALIDAD') 'install-ai-rules.ps1 adds the REGLAS DE CALIDAD section to CLAUDE.md'
Assert-True ($claudeMdAfterInstall -match 'JAMAS') 'the section states the never-bypass-hooks rule'
Assert-True ($claudeMdAfterInstall -match [regex]::Escape('cross-review.ps1')) 'the section mentions cross-review.ps1 for delicate changes'
Assert-True ($claudeMdAfterInstall -match [regex]::Escape('init-repo.ps1')) 'the section mentions init-repo.ps1 for repos without a quality kit yet'
$claudeMdLineCount = @($claudeMdAfterInstall -split "`n" | Where-Object { $_ -match 'REGLAS DE CALIDAD|^\d\.|QUALITY-KIT REGLAS' }).Count
Assert-True ($claudeMdLineCount -le 8) 'the REGLAS DE CALIDAD section stays compact (about 8 lines), matching the discipline of a global rules file' "counted content lines=$claudeMdLineCount"

Assert-True (Test-Path -LiteralPath $fakeCodexAgents) 'install-ai-rules.ps1 CREATED ~/.codex/AGENTS.md, which did not exist before'
$codexAgentsAfterInstall = Read-TextFile -Path $fakeCodexAgents
Assert-True ($codexAgentsAfterInstall -match 'REGLAS DE CALIDAD') 'the created AGENTS.md (codex) has the REGLAS DE CALIDAD section'

$kimiAgentsAfterInstall = Read-TextFile -Path $fakeKimiAgents
Assert-True ($null -ne $kimiAgentsAfterInstall -and $kimiAgentsAfterInstall -match 'REGLAS DE CALIDAD') 'AGENTS.md (kimi) was created with the REGLAS DE CALIDAD section'

$claudeBackups = @(Get-ChildItem -LiteralPath (Join-Path $fakeHomesDir 'claude') -Filter 'CLAUDE.md.bak-*')
Assert-True ($claudeBackups.Count -gt 0) 'install-ai-rules.ps1 left a timestamped backup of the pre-existing CLAUDE.md before changing it'

Write-Host ''
Write-Host '=== TEST GROUP 4b: install-ai-rules.ps1 is idempotent (second run does not duplicate the section) ==='
$rInstall2 = Invoke-InstallAiRules
Assert-True ($rInstall2.ExitCode -eq 0) 'second install-ai-rules.ps1 run also exits 0' "exit=$($rInstall2.ExitCode)"
$claudeMdAfterInstall2 = Read-TextFile -Path $fakeClaudeMd
$claudeMarkerCount = ([regex]::Matches($claudeMdAfterInstall2, [regex]::Escape('QUALITY-KIT REGLAS DE CALIDAD START'))).Count
Assert-True ($claudeMarkerCount -eq 1) 'CLAUDE.md REGLAS DE CALIDAD marker appears exactly once after a second install run' "count=$claudeMarkerCount"
Assert-True ($claudeMdAfterInstall2 -match 'Some pre-existing content that must survive untouched') 'pre-existing content still survives after a second install run'

Write-Host ''
Write-Host '=== TEST GROUP 4c: uninstall-ai-rules.ps1 strips cleanly and preserves everything else ==='
$rUninstall = Invoke-UninstallAiRules
Assert-True ($rUninstall.ExitCode -eq 0) 'uninstall-ai-rules.ps1 exits 0' "exit=$($rUninstall.ExitCode) stderr=$($rUninstall.Stderr)"
$claudeMdAfterUninstall = Read-TextFile -Path $fakeClaudeMd
Assert-True ($null -ne $claudeMdAfterUninstall -and $claudeMdAfterUninstall -notmatch 'REGLAS DE CALIDAD') 'the REGLAS DE CALIDAD section is gone from CLAUDE.md after uninstall'
Assert-True ($claudeMdAfterUninstall -match 'Some pre-existing content that must survive untouched') 'CLAUDE.md pre-existing content survives uninstall untouched'
Assert-True (-not (Test-Path -LiteralPath $fakeCodexAgents)) 'the AGENTS.md (codex) that install-ai-rules.ps1 created from nothing is fully removed on uninstall (nothing else was in it)'
Assert-True (-not (Test-Path -LiteralPath $fakeKimiAgents)) 'the AGENTS.md (kimi) that install-ai-rules.ps1 created from nothing is fully removed on uninstall'

Write-Host ''
Write-Host '=== TEST GROUP 4d: uninstall-ai-rules.ps1 is a safe no-op when nothing was ever installed ==='
$neverInstalledPath = Join-Path $fakeHomesDir 'claude\CLAUDE.md'
$rUninstallAgain = Invoke-UninstallAiRules
Assert-True ($rUninstallAgain.ExitCode -eq 0) 'uninstall-ai-rules.ps1 exits 0 even when there is nothing left to remove' "exit=$($rUninstallAgain.ExitCode)"
Assert-True ($rUninstallAgain.Stdout -match 'no existe -- nada que quitar|no tiene la seccion') 'uninstall-ai-rules.ps1 reports plainly that there was nothing to remove'

Write-Host ''
Write-Host '=== TEST GROUP 4e: a half-present marker (only START, no END) warns and leaves the file untouched ==='
$brokenHomeDir = Join-Path $TestFixturesDir 'fake-ai-homes-broken'
New-Item -ItemType Directory -Path $brokenHomeDir -Force | Out-Null
$brokenClaudeMd = Join-Path $brokenHomeDir 'CLAUDE.md'
$brokenContent = "# rules`n`n<!-- >>> QUALITY-KIT REGLAS DE CALIDAD START -- managed by quality-kit's install-ai-rules.ps1 / uninstall-ai-rules.ps1. Do not hand-edit between these markers. -->`n## REGLAS DE CALIDAD (quality-kit)`n(contenido truncado a mano, sin marca de cierre)`n"
Write-Utf8NoBomFile -Path $brokenClaudeMd -Content $brokenContent
$rBrokenUninstall = Invoke-ScriptCapture -ScriptPath $UninstallAiRulesScript -ScriptArgs @('-ClaudeMdPath', $brokenClaudeMd, '-CodexAgentsPath', (Join-Path $brokenHomeDir 'nope-codex.md'), '-KimiAgentsPath', (Join-Path $brokenHomeDir 'nope-kimi.md'))
Assert-True ($rBrokenUninstall.Stdout -match 'ADVERTENCIA.*UNA de las dos marcas') 'uninstall-ai-rules.ps1 warns explicitly about a half-present marker' "stdout=$($rBrokenUninstall.Stdout)"
$brokenContentAfter = Read-TextFile -Path $brokenClaudeMd
Assert-True ($brokenContentAfter -eq $brokenContent) 'the half-marked file is left byte-for-byte UNCHANGED (only a backup was taken, nothing auto-fixed)'

Write-Host ''
Write-Host '=== TEST GROUP 5: docs-groom -- canonical instructions carry the 3 mandatory guardrails ==='
$docsGroomInstructions = Read-TextFile -Path (Join-Path $DocsGroomDir 'INSTRUCTIONS.md')
Assert-True ($null -ne $docsGroomInstructions) 'docs-groom\INSTRUCTIONS.md exists and is readable'
Assert-True ($docsGroomInstructions -match 'NUNCA toques un bloque administrado') 'guardrail (a): never touch a marker-guarded block is stated explicitly'
Assert-True ($docsGroomInstructions -match '>>> QUALITY-KIT CALIDAD SECTION START') 'guardrail (a) lists a concrete known marker pattern (quality-kit Calidad section)'
Assert-True ($docsGroomInstructions -match '>>> SUMMONAIKIT KIT') 'guardrail (a) lists a concrete known marker pattern (SummonAI Kit sections)'
Assert-True ($docsGroomInstructions -match 'managed by') 'guardrail (a) also covers the generic "managed by" comment convention, not only exact marker strings'
Assert-True ($docsGroomInstructions -match 'MUDA, no se borra') 'guardrail (b): valuable history moves, it is not deleted, is stated explicitly'
Assert-True ($docsGroomInstructions -match 'STATUS\.md') 'guardrail (b) names the tracker file (STATUS.md) as the destination for valuable history'
Assert-True ($docsGroomInstructions -match 'Verifica antes de borrar') 'guardrail (c): verify against the real codebase before deleting as "obsolete" is stated explicitly'
Assert-True ($docsGroomInstructions -match 'necesita revision manual') 'guardrail (c) requires flagging unverifiable claims in the final report instead of silently deleting them'
Assert-True ($docsGroomInstructions -match 'maximo 200 lineas') 'the root CLAUDE.md <= 200 line policy is stated explicitly'
Assert-True ($docsGroomInstructions -match 'CLAUDE.md.{0,40}anidado') 'the nested-CLAUDE.md-per-component policy is present'
Assert-True ($docsGroomInstructions -match 'una skill, no texto pegado') 'the repeatable-procedure-becomes-a-skill policy is present'
Assert-True ($docsGroomInstructions -match 'CON su') 'the permanent-rule-as-one-distilled-line-WITH-its-reason policy is present'
$docsGroomBytes = [System.IO.File]::ReadAllBytes((Join-Path $DocsGroomDir 'INSTRUCTIONS.md'))
$docsGroomNonAscii = @($docsGroomBytes | Where-Object { $_ -gt 127 })
Assert-True ($docsGroomNonAscii.Count -eq 0) 'INSTRUCTIONS.md is byte-level pure ASCII (same discipline as every other file an AI CLI reads directly)' "non-ascii byte count=$($docsGroomNonAscii.Count)"

Write-Host ''
Write-Host '=== TEST GROUP 5b: docs-groom frontmatter templates are present, per-AI-appropriate, and parse ==='
function Test-SkillFrontmatterParses {
    param([string]$Content)
    $m = [regex]::Match($Content, '(?s)\A---\r?\n(.*?)\r?\n---\r?\n')
    if (-not $m.Success) { return $null }
    $block = $m.Groups[1].Value
    $nameMatch = [regex]::Match($block, '(?m)^name:\s*(\S.*)$')
    $descMatch = [regex]::Match($block, '(?m)^description:')
    if (-not $nameMatch.Success -or -not $descMatch.Success) { return $null }
    return [PSCustomObject]@{ Name = $nameMatch.Groups[1].Value.Trim(); Block = $block }
}
foreach ($fm in @(
    @{ File = 'frontmatter-claude.yaml'; ExpectAllowedTools = $true },
    @{ File = 'frontmatter-codex.yaml'; ExpectAllowedTools = $true },
    @{ File = 'frontmatter-kimi.yaml'; ExpectAllowedTools = $false }
)) {
    $fmPath = Join-Path $DocsGroomDir $fm.File
    $fmContent = Read-TextFile -Path $fmPath
    Assert-True ($null -ne $fmContent) "$($fm.File) exists and is readable"
    $parsed = Test-SkillFrontmatterParses -Content $fmContent
    Assert-True ($null -ne $parsed) "$($fm.File) frontmatter parses (opens/closes with --- and has name: + description:)" "content=$fmContent"
    if ($null -ne $parsed) {
        Assert-True ($parsed.Name -eq 'docs-groom') "$($fm.File) frontmatter name is exactly 'docs-groom'" "name=$($parsed.Name)"
        $hasAllowedTools = ($parsed.Block -match '(?m)^allowed-tools:')
        Assert-True ($hasAllowedTools -eq $fm.ExpectAllowedTools) "$($fm.File) allowed-tools presence matches what this AI is expected to support (Kimi: no, confirmed live it does not act on this field; Claude/Codex: yes)" "hasAllowedTools=$hasAllowedTools expected=$($fm.ExpectAllowedTools)"
    }
    $fmBytes = [System.IO.File]::ReadAllBytes($fmPath)
    $fmNonAscii = @($fmBytes | Where-Object { $_ -gt 127 })
    Assert-True ($fmNonAscii.Count -eq 0) "$($fm.File) is byte-level pure ASCII"
}

Write-Host ''
Write-Host '=== TEST GROUP 5c: install-docs-groom.ps1 against fake home directories, all three AI layouts ==='
$fakeSkillHomesDir = Join-Path $TestFixturesDir 'fake-skill-homes'
$fakeClaudeSkillsDir = Join-Path $fakeSkillHomesDir 'claude\skills'
$fakeCodexSkillsDir = Join-Path $fakeSkillHomesDir 'codex\skills'
$fakeKimiSkillsDir = Join-Path $fakeSkillHomesDir 'kimi\skills'
New-Item -ItemType Directory -Path $fakeClaudeSkillsDir -Force | Out-Null
New-Item -ItemType Directory -Path $fakeCodexSkillsDir -Force | Out-Null
New-Item -ItemType Directory -Path $fakeKimiSkillsDir -Force | Out-Null

function Invoke-InstallDocsGroom {
    return Invoke-ScriptCapture -ScriptPath $InstallDocsGroomScript -ScriptArgs @('-ClaudeSkillsDir', $fakeClaudeSkillsDir, '-CodexSkillsDir', $fakeCodexSkillsDir, '-KimiSkillsDir', $fakeKimiSkillsDir)
}
function Invoke-UninstallDocsGroom {
    return Invoke-ScriptCapture -ScriptPath $UninstallDocsGroomScript -ScriptArgs @('-ClaudeSkillsDir', $fakeClaudeSkillsDir, '-CodexSkillsDir', $fakeCodexSkillsDir, '-KimiSkillsDir', $fakeKimiSkillsDir)
}

$rInstallDocsGroom = Invoke-InstallDocsGroom
Assert-True ($rInstallDocsGroom.ExitCode -eq 0) 'install-docs-groom.ps1 exits 0 against fake home directories' "exit=$($rInstallDocsGroom.ExitCode) stderr=$($rInstallDocsGroom.Stderr)"

$claudeSkillMd = Read-TextFile -Path (Join-Path $fakeClaudeSkillsDir 'docs-groom\SKILL.md')
$codexSkillMd = Read-TextFile -Path (Join-Path $fakeCodexSkillsDir 'docs-groom\SKILL.md')
$kimiSkillMd = Read-TextFile -Path (Join-Path $fakeKimiSkillsDir 'docs-groom\SKILL.md')
Assert-True ($null -ne $claudeSkillMd -and $claudeSkillMd -match 'name: docs-groom') 'Claude SKILL.md was created with the right skill name'
Assert-True ($null -ne $codexSkillMd -and $codexSkillMd -match 'name: docs-groom') 'Codex SKILL.md was created with the right skill name'
Assert-True ($null -ne $kimiSkillMd -and $kimiSkillMd -match 'name: docs-groom') 'Kimi SKILL.md was created with the right skill name'
Assert-True ($claudeSkillMd -match 'allowed-tools:') 'Claude SKILL.md includes allowed-tools'
Assert-True ($codexSkillMd -match 'allowed-tools:') 'Codex SKILL.md includes allowed-tools'
Assert-True (-not ($kimiSkillMd -match 'allowed-tools:')) 'Kimi SKILL.md deliberately omits allowed-tools (confirmed live Kimi does not act on this field)'
Assert-True ($claudeSkillMd -match 'NUNCA toques un bloque administrado') 'the installed Claude skill carries the marker-protection guardrail in its body'
Assert-True ($kimiSkillMd -match 'MUDA, no se borra') 'the installed Kimi skill carries the mover-no-borrar guardrail in its body'
Assert-True ($codexSkillMd -match 'Verifica antes de borrar') 'the installed Codex skill carries the verify-before-delete guardrail in its body'

Write-Host ''
Write-Host '=== TEST GROUP 5d: install-docs-groom.ps1 is idempotent (re-run refreshes cleanly, with a backup) ==='
$rInstallDocsGroom2 = Invoke-InstallDocsGroom
Assert-True ($rInstallDocsGroom2.ExitCode -eq 0) 'second install-docs-groom.ps1 run also exits 0' "exit=$($rInstallDocsGroom2.ExitCode)"
$claudeSkillMd2 = Read-TextFile -Path (Join-Path $fakeClaudeSkillsDir 'docs-groom\SKILL.md')
Assert-True ($claudeSkillMd2 -eq $claudeSkillMd) 'a second install run regenerates byte-identical content for the same source (stable, not silently drifting)'
$claudeSkillBackups = @(Get-ChildItem -LiteralPath (Join-Path $fakeClaudeSkillsDir 'docs-groom') -Filter 'SKILL.md.bak-*')
Assert-True ($claudeSkillBackups.Count -gt 0) 'a timestamped backup of the previous SKILL.md was taken before the second install overwrote it'

Write-Host ''
Write-Host '=== TEST GROUP 5e: uninstall-docs-groom.ps1 removes the skill cleanly and is a safe no-op afterward ==='
$rUninstallDocsGroom = Invoke-UninstallDocsGroom
Assert-True ($rUninstallDocsGroom.ExitCode -eq 0) 'uninstall-docs-groom.ps1 exits 0' "exit=$($rUninstallDocsGroom.ExitCode) stderr=$($rUninstallDocsGroom.Stderr)"
Assert-True (-not (Test-Path -LiteralPath (Join-Path $fakeClaudeSkillsDir 'docs-groom\SKILL.md'))) 'Claude SKILL.md is gone after uninstall'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $fakeKimiSkillsDir 'docs-groom\SKILL.md'))) 'Kimi SKILL.md is gone after uninstall'
$rUninstallDocsGroomAgain = Invoke-UninstallDocsGroom
Assert-True ($rUninstallDocsGroomAgain.ExitCode -eq 0) 'uninstall-docs-groom.ps1 exits 0 even when there is nothing left to remove' "exit=$($rUninstallDocsGroomAgain.ExitCode)"
Assert-True ($rUninstallDocsGroomAgain.Stdout -match 'no existe -- nada que quitar') 'uninstall-docs-groom.ps1 reports plainly that there was nothing to remove on a repeat run'

Write-Host ''
Write-Host '=== TEST GROUP 6: heal-repo.ps1 -- re-arms a config-present-but-hook-absent clone ==='
# Reproduces the real incident: .pre-commit-config.yaml travels with a clone
# (committed) but .git/hooks/pre-commit does NOT, so a fresh clone is born with
# the lock disarmed and failing open in silence. heal-repo.ps1 must detect that
# and re-arm it. This is the test that would have caught the gap the analysis
# found (config sin hook read as "passed the checks").
$healRepo = New-FakeGitRepo -Name 'fake-heal-repo'
$healConfig = @'
repos:
  - repo: local
    hooks:
      - id: no-print
        name: no debug prints
        entry: echo checking
        language: system
      - id: trailing-ws
        name: trailing whitespace
        entry: echo ws
        language: system
'@
Write-Utf8NoBomFile -Path (Join-Path $healRepo '.pre-commit-config.yaml') -Content $healConfig

$healHookPath = Join-Path $healRepo '.git\hooks\pre-commit'
Assert-True (-not (Test-Path -LiteralPath $healHookPath)) 'fresh clone starts with NO pre-commit hook installed (the disarmed-but-silent state)'

$rHeal1 = Invoke-HealRepo -RepoPath $healRepo
Assert-True ($rHeal1.ExitCode -eq 0) 'heal-repo.ps1 exits 0 after re-arming a disarmed clone' "exit=$($rHeal1.ExitCode) stderr=$($rHeal1.Stderr)"
Assert-True ($rHeal1.Stdout -match 'CANDADO DESARMADO') 'heal-repo.ps1 LOUDLY reports the disarmed lock instead of failing open in silence'
Assert-True ($rHeal1.Stdout -match 'RE-ARMADO') 'heal-repo.ps1 reports it re-armed the hook'
$healHookContent = Read-TextFile -Path $healHookPath
Assert-True ($null -ne $healHookContent -and $healHookContent -match 'generated by pre-commit') 'the pre-commit hook is now installed AND carries pre-commit''s own generated-file marker (really armed, not a lookalike)'

Write-Host ''
Write-Host '=== TEST GROUP 6b: heal-repo.ps1 is idempotent -- a second run confirms armed, quietly ==='
$rHeal2 = Invoke-HealRepo -RepoPath $healRepo
Assert-True ($rHeal2.ExitCode -eq 0) 'second heal-repo.ps1 run exits 0' "exit=$($rHeal2.ExitCode)"
Assert-True ($rHeal2.Stdout -match 'candados: 2 checks armados') 'heal-repo.ps1 announces the armed lock with the configured check count (distinguishes silent-present from silent-absent)'
Assert-True (-not ($rHeal2.Stdout -match 'CANDADO DESARMADO')) 'an already-armed repo does NOT trigger the disarmed warning on re-run'

Write-Host ''
Write-Host '=== TEST GROUP 6c: heal-repo.ps1 does not mistake a hand-written hook for the pre-commit lock ==='
$handRepo = New-FakeGitRepo -Name 'fake-heal-handwritten'
Write-Utf8NoBomFile -Path (Join-Path $handRepo '.pre-commit-config.yaml') -Content $healConfig
$handHookPath = Join-Path $handRepo '.git\hooks\pre-commit'
Write-Utf8NoBomFile -Path $handHookPath -Content "#!/bin/sh`necho hand-written`n"
$rHealHand = Invoke-HealRepo -RepoPath $handRepo
Assert-True ($rHealHand.Stdout -match 'CANDADO DESARMADO') 'a same-named but hand-written hook is NOT counted as armed -- heal still reports the lock disarmed'
$handHookContent = Read-TextFile -Path $handHookPath
Assert-True ($null -ne $handHookContent -and $handHookContent -match 'generated by pre-commit') 'heal re-installs the real pre-commit hook over the hand-written one'

Write-Host ''
Write-Host '=== TEST GROUP 6d: heal-repo.ps1 on a repo with no config is a plain, non-error no-op ==='
$noCfgRepo = New-FakeGitRepo -Name 'fake-heal-nocfg'
$rHealNoCfg = Invoke-HealRepo -RepoPath $noCfgRepo
Assert-True ($rHealNoCfg.ExitCode -eq 0) 'heal-repo.ps1 exits 0 when there is no .pre-commit-config.yaml to arm' "exit=$($rHealNoCfg.ExitCode)"
Assert-True ($rHealNoCfg.Stdout -match 'sin .pre-commit-config.yaml') 'heal-repo.ps1 says plainly there are no locks configured, rather than pretending success'

Write-Host ''
Write-Host '=== TEST GROUP 6e: heal-repo.ps1 -AutoInit sets up locks from scratch on a brand-new repo of mine ==='
# The "I will not remember to run init-repo" case: a fresh `git init` with no
# remote and no config. With -AutoInit it must run init-repo itself so the repo
# protects itself without anyone remembering.
$autoNewRepo = New-FakeGitRepo -Name 'fake-heal-autonew'
Write-Utf8NoBomFile -Path (Join-Path $autoNewRepo 'app.py') -Content "print('hi')`n"
$rAutoNew = Invoke-HealRepo -RepoPath $autoNewRepo -AutoInit
Assert-True ($rAutoNew.ExitCode -eq 0) 'heal-repo.ps1 -AutoInit exits 0 on a brand-new repo' "exit=$($rAutoNew.ExitCode) stderr=$($rAutoNew.Stderr)"
Assert-True ($rAutoNew.Stdout -match 'armandolos por primera vez') 'heal-repo.ps1 -AutoInit announces it is setting up the lock for the first time'
Assert-True (Test-Path -LiteralPath (Join-Path $autoNewRepo '.pre-commit-config.yaml')) 'a .pre-commit-config.yaml was created from scratch by the auto-init'
$autoNewHook = Read-TextFile -Path (Join-Path $autoNewRepo '.git\hooks\pre-commit')
Assert-True ($null -ne $autoNewHook -and $autoNewHook -match 'generated by pre-commit') 'the pre-commit hook is armed after auto-init (no manual init-repo needed)'

Write-Host ''
Write-Host '=== TEST GROUP 6f: heal-repo.ps1 -AutoInit NEVER touches a repo whose remote is someone else''s ==='
# Safety boundary: a clone of a foreign repo (origin points elsewhere) must not
# have config/CI/CLAUDE.md injected into it, even with -AutoInit.
$foreignRepo = New-FakeGitRepo -Name 'fake-heal-foreign'
Invoke-GitSilent -GitArgs @('-C', $foreignRepo, 'remote', 'add', 'origin', 'https://github.com/someone-else/their-project')
$emptyOwners = Join-Path $TestFixturesDir 'owners-empty.txt'
Write-Utf8NoBomFile -Path $emptyOwners -Content "# no owners`n"
$rForeign = Invoke-HealRepo -RepoPath $foreignRepo -AutoInit -OwnersFile $emptyOwners
Assert-True ($rForeign.ExitCode -eq 0) 'heal-repo.ps1 -AutoInit exits 0 (no-op) on a foreign-remote repo' "exit=$($rForeign.ExitCode)"
Assert-True ($rForeign.Stdout -match 'no parece tuyo') 'heal-repo.ps1 reports it is leaving a foreign repo alone'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $foreignRepo '.pre-commit-config.yaml'))) 'NO .pre-commit-config.yaml is written into a repo whose remote is someone else''s'

Write-Host ''
Write-Host '=== TEST GROUP 6g: heal-repo.ps1 -AutoInit DOES set up a repo whose remote matches my owners list ==='
$ownedRepo = New-FakeGitRepo -Name 'fake-heal-owned'
Invoke-GitSilent -GitArgs @('-C', $ownedRepo, 'remote', 'add', 'origin', 'https://github.com/myhandle/my-project')
$myOwners = Join-Path $TestFixturesDir 'owners-mine.txt'
Write-Utf8NoBomFile -Path $myOwners -Content "# mine`nmyhandle`n"
$rOwned = Invoke-HealRepo -RepoPath $ownedRepo -AutoInit -OwnersFile $myOwners
Assert-True ($rOwned.ExitCode -eq 0) 'heal-repo.ps1 -AutoInit exits 0 on a repo with a remote I own' "exit=$($rOwned.ExitCode) stderr=$($rOwned.Stderr)"
Assert-True (Test-Path -LiteralPath (Join-Path $ownedRepo '.pre-commit-config.yaml')) 'a repo whose remote matches my owners list gets its lock set up automatically'
$ownedHook = Read-TextFile -Path (Join-Path $ownedRepo '.git\hooks\pre-commit')
Assert-True ($null -ne $ownedHook -and $ownedHook -match 'generated by pre-commit') 'the pre-commit hook is armed on the owned-remote repo after auto-init'

Write-Host ''
Write-Host "=== SUMMARY: $script:PassCount passed, $script:FailCount failed ==="
if ($script:FailCount -gt 0) { exit 1 } else { exit 0 }
