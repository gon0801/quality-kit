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
    $proc.StandardInput.Close()
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    return [PSCustomObject]@{ Stdout = $stdout; Stderr = $stderr; ExitCode = $proc.ExitCode }
}

function Invoke-InitRepo {
    param([string]$RepoPath)
    return Invoke-ScriptCapture -ScriptPath $InitRepoScript -ScriptArgs @('-RepoPath', $RepoPath)
}

function Invoke-CrossReviewDryRun {
    param([string]$RepoPath, [string]$Con, [string]$Alcance = '')
    $scriptArgs = @('-Con', $Con, '-RepoPath', $RepoPath, '-DryRun')
    if ($Alcance -ne '') { $scriptArgs += @('-Alcance', $Alcance) }
    return Invoke-ScriptCapture -ScriptPath $CrossReviewScript -ScriptArgs $scriptArgs
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
Write-Host '=== TEST GROUP 2f: re-running after the detected stack CHANGES regenerates the quality-kit-managed config ==='
# First run: no Python markers anywhere yet -> generic.
$evolvingRepo = New-FakeGitRepo -Name 'fake-evolving-repo'
Write-Utf8NoBomFile -Path (Join-Path $evolvingRepo 'README.md') -Content "# starts generic, becomes python`n"
Push-Location -LiteralPath $evolvingRepo
try { Invoke-GitSilent -GitArgs @('add', '-A'); Invoke-GitSilent -GitArgs @('commit', '-q', '-m', 'initial') } finally { Pop-Location }
$rEvolve1 = Invoke-InitRepo -RepoPath $evolvingRepo
Assert-True ($rEvolve1.ExitCode -eq 0) 'first run (generic) exits 0' "exit=$($rEvolve1.ExitCode)"
$evolvingConfig1 = Read-TextFile -Path (Join-Path $evolvingRepo '.pre-commit-config.yaml')
Assert-True (-not ($evolvingConfig1 -match 'ruff-check')) 'sanity: first run correctly detected generic (no Python yet)'

# Now add a nested Python file (no root marker) and re-run: the config
# already carries the quality-kit marker, so it must be REGENERATED to
# reflect the new stack, not left stale.
New-Item -ItemType Directory -Path (Join-Path $evolvingRepo 'strategies') -Force | Out-Null
Write-Utf8NoBomFile -Path (Join-Path $evolvingRepo 'strategies\my_strategy.py') -Content "def run():`n    pass`n"
Push-Location -LiteralPath $evolvingRepo
try { Invoke-GitSilent -GitArgs @('add', '-A'); Invoke-GitSilent -GitArgs @('commit', '-q', '-m', 'add python code') } finally { Pop-Location }
$rEvolve2 = Invoke-InitRepo -RepoPath $evolvingRepo
Assert-True ($rEvolve2.ExitCode -eq 0) 'second run (now python) exits 0' "exit=$($rEvolve2.ExitCode)"
$evolvingConfig2 = Read-TextFile -Path (Join-Path $evolvingRepo '.pre-commit-config.yaml')
Assert-True ($evolvingConfig2 -match 'ruff-check') 'the quality-kit-managed config was REGENERATED to include Python hooks once the stack actually changed' "config=$evolvingConfig2"
$evolvingMarkerCount = ([regex]::Matches($evolvingConfig2, [regex]::Escape('QUALITY-KIT MANAGED'))).Count
Assert-True ($evolvingMarkerCount -eq 1) 'the regenerated config still carries exactly one quality-kit marker (clean regeneration, not an appended duplicate)'

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
Write-Host "=== SUMMARY: $script:PassCount passed, $script:FailCount failed ==="
if ($script:FailCount -gt 0) { exit 1 } else { exit 0 }
