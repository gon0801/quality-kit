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
Write-Host "=== SUMMARY: $script:PassCount passed, $script:FailCount failed ==="
if ($script:FailCount -gt 0) { exit 1 } else { exit 0 }
