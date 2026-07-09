# quality-kit / heal-repo.ps1
#
# Per-session "doctor" that makes the commit lock ACTUALLY BITE. Meant to be
# run cheaply at the start of every session on a repo (the same way
# session-heal.ps1 re-patches Chroma each arranque), NOT once-and-forget like
# init-repo.ps1.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\ehven\quality-kit\heal-repo.ps1 -RepoPath <repo>
#
# The hole this closes (real incident): a repo has .pre-commit-config.yaml
# committed (so it travels with every clone), but the actual git hook lives in
# .git/hooks/pre-commit, which does NOT travel with a clone. So a fresh clone
# is born config-present-but-hook-absent: `git commit` invokes NOTHING, the
# commit sails through, and both the human and the model read that silent
# success as "passed the checks" when there were no checks. A disarmed lock is
# worse than no lock -- it manufactures false confidence. init-repo.ps1 arms
# the hook correctly, but only if someone remembers to run it in that clone;
# nothing re-arms it per clone / per session. This does.
#
# What it does, fast and idempotent:
#   1. If no .pre-commit-config.yaml -> nothing to arm; says so; exit 0.
#   2. If the pre-commit hook is already armed -> "candados: N OK"; exit 0.
#   3. If config present but hook NOT armed -> re-arm via `pre-commit install`
#      (+ pre-push when the config declares that stage) and re-verify.
#         - re-armed OK        -> loud "estaba desarmado, RE-ARMADO"; exit 0.
#         - could not re-arm   -> loud warning; exit 2 (so a SessionStart hook
#           can surface it instead of failing open in silence).
#
# Deliberately lighter than init-repo.ps1: it never regenerates the config,
# never runs the hooks against all files, and never pip-installs anything. If
# pre-commit itself is missing from this machine it tells you to run
# init-repo.ps1 (which does the heavier install) rather than mutating the
# machine from a per-session heal.
#
# PowerShell 5.1 compatible on purpose (same constraints as init-repo.ps1):
# no ternary / null-coalescing, explicit -Encoding on reads, every
# Where-Object result destined for .Count is wrapped in @(...).

param(
    [string]$RepoPath = (Get-Location).Path,
    # When set, a repo that is MINE but has no .pre-commit-config.yaml yet gets
    # its lock set up from scratch automatically (runs init-repo.ps1 once),
    # instead of only nagging about it. The SessionStart hook passes this so a
    # brand-new repo protects itself without anyone remembering to run init.
    # A manual `heal-repo.ps1` run WITHOUT this flag stays conservative and
    # never writes a config into a repo that has none.
    [switch]$AutoInit,
    # Path to the owner allowlist; defaults to my-owners.txt next to this
    # script. Overridable so the test suite can point at a fixture.
    [string]$OwnersFile = ''
)

$ErrorActionPreference = 'Stop'
$QualityKitDir = Split-Path -Parent $MyInvocation.MyCommand.Path
# One owner substring per line (e.g. a GitHub username or org). A repo whose
# origin remote URL contains any of these counts as "mine" for -AutoInit. A
# repo with NO remote at all also counts as mine (a fresh local `git init` is
# almost certainly yours). A repo whose remote matches none of these is
# treated as someone else's clone and is never auto-initialized. Missing/empty
# file -> only the no-remote branch fires (the safe default).
if ($OwnersFile -eq '') { $OwnersFile = Join-Path $QualityKitDir 'my-owners.txt' }

function Test-CommandWorks {
    param([string]$Exe, [string[]]$TestArgs)
    try {
        $null = & $Exe @TestArgs 2>&1
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

# Known-good fallback confirmed on this machine (mirrors init-repo.ps1); used
# only if nothing else on PATH already provides a working Python.
$KnownGoodPython = 'C:\Python314\python.exe'

function Get-PythonExe {
    $candidates = @('python', 'py', $KnownGoodPython)
    foreach ($c in $candidates) {
        if (Test-CommandWorks -Exe $c -TestArgs @('--version')) { return $c }
    }
    return $null
}

# Resolves how to invoke pre-commit WITHOUT installing it (unlike init-repo's
# Get-PreCommitInvoker, which pip-installs on miss). Returns $null when
# pre-commit is nowhere invocable -- heal must not mutate the machine.
function Resolve-PreCommitInvoker {
    if (Test-CommandWorks -Exe 'pre-commit' -TestArgs @('--version')) {
        return [PSCustomObject]@{ Exe = 'pre-commit'; ArgsPrefix = @() }
    }
    $pythonExe = Get-PythonExe
    if ($pythonExe) {
        if (Test-CommandWorks -Exe $pythonExe -TestArgs @('-m', 'pre_commit', '--version')) {
            return [PSCustomObject]@{ Exe = $pythonExe; ArgsPrefix = @('-m', 'pre_commit') }
        }
    }
    return $null
}

function Invoke-PreCommit {
    param($Invoker, [string[]]$CmdArgs, [string]$RepoPath)
    $allArgs = @()
    $allArgs += $Invoker.ArgsPrefix
    $allArgs += $CmdArgs
    Push-Location -LiteralPath $RepoPath
    try {
        # Route the tool's own stdout through Out-Host so it prints without
        # being concatenated into this function's return value (same trap
        # documented in init-repo.ps1's Invoke-PreCommit).
        & $Invoker.Exe @allArgs | Out-Host
        $exitCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    return $exitCode
}

function Invoke-GitCapture {
    param([string]$RepoPath, [string[]]$GitArgs)
    $all = @('-C', $RepoPath) + $GitArgs
    # git routinely writes to stderr for non-fatal conditions ("No such remote
    # 'origin'", CRLF notices, etc). With $ErrorActionPreference='Stop', each
    # stderr line becomes a terminating ErrorRecord -- so a perfectly normal
    # "this repo has no origin remote" would throw. Drop to 'Continue' around
    # the call (same fix the test suite's Invoke-GitSilent uses) and read the
    # exit code instead.
    $savedEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & git @all 2>$null
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedEap
    }
    return [PSCustomObject]@{ Ok = ($code -eq 0); Out = ($out | Out-String).Trim() }
}

# Resolves the directory git actually uses for hooks, honoring core.hooksPath
# and worktrees (where .git is a file, not a dir). Returns $null if this is
# not a git work tree.
function Get-HooksDir {
    param([string]$RepoPath)
    $isRepo = Invoke-GitCapture -RepoPath $RepoPath -GitArgs @('rev-parse', '--is-inside-work-tree')
    if (-not $isRepo.Ok -or $isRepo.Out -ne 'true') { return $null }

    $cfg = Invoke-GitCapture -RepoPath $RepoPath -GitArgs @('config', '--get', 'core.hooksPath')
    if ($cfg.Ok -and $cfg.Out -ne '') {
        if ([System.IO.Path]::IsPathRooted($cfg.Out)) { return $cfg.Out }
        return (Join-Path $RepoPath $cfg.Out)
    }
    # No custom hooksPath -> $GIT_DIR/hooks, resolved so worktrees work too.
    $gp = Invoke-GitCapture -RepoPath $RepoPath -GitArgs @('rev-parse', '--git-path', 'hooks')
    if ($gp.Ok -and $gp.Out -ne '') {
        if ([System.IO.Path]::IsPathRooted($gp.Out)) { return $gp.Out }
        return (Join-Path $RepoPath $gp.Out)
    }
    return $null
}

# A hook file counts as "armed by pre-commit" only if it exists AND carries
# pre-commit's own generated-file marker -- so a hand-written hook of the same
# name is never mistaken for the lock being in place.
function Test-HookArmed {
    param([string]$HooksDir, [string]$HookName)
    $path = Join-Path $HooksDir $HookName
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    $content = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    return ($content -match 'generated by pre-commit')
}

# Counts configured hooks (each `- id:` line) for the "candados: N OK"
# announce the analysis asked for, so silent-present is distinguishable from
# silent-absent.
function Get-ConfiguredHookCount {
    param([string]$ConfigPath)
    $lines = @(Get-Content -LiteralPath $ConfigPath -Encoding UTF8 | Where-Object { $_ -match '^\s*-\s*id\s*:' })
    return $lines.Count
}

# Does the config declare a pre-push stage anywhere? If so, the pre-push hook
# must be armed too, not just pre-commit.
function Test-ConfigWantsPrePush {
    param([string]$ConfigPath)
    $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
    return ($raw -match 'pre-push')
}

# Reads the owner allowlist (one substring per line; blanks and #-comments
# ignored). Returns @() if the file is absent, so the caller falls back to the
# safe no-remote-only branch.
function Get-MyOwners {
    param([string]$OwnersFile)
    if (-not (Test-Path -LiteralPath $OwnersFile)) { return @() }
    $lines = @(Get-Content -LiteralPath $OwnersFile -Encoding UTF8 | ForEach-Object { $_.Trim() } | Where-Object {
        ($_ -ne '') -and (-not $_.StartsWith('#'))
    })
    return $lines
}

# "Mine" = no origin remote at all (fresh local repo), OR origin URL contains
# one of my owner substrings. A remote that matches none of them is someone
# else's clone -> not mine -> never auto-initialized.
function Test-RepoIsMine {
    param([string]$RepoPath, [string[]]$Owners)
    $r = Invoke-GitCapture -RepoPath $RepoPath -GitArgs @('remote', 'get-url', 'origin')
    if (-not $r.Ok -or $r.Out -eq '') { return $true }
    foreach ($o in $Owners) {
        if ($o -ne '' -and ($r.Out -like ('*' + $o + '*'))) { return $true }
    }
    return $false
}

# Runs init-repo.ps1 as an isolated child process (it sets global state and
# resolves its own templates dir via $MyInvocation, so a separate process is
# the clean way to invoke it) against $RepoPath. Returns the exit code.
function Invoke-InitRepo {
    param([string]$RepoPath, [string]$QualityKitDir)
    $initScript = Join-Path $QualityKitDir 'init-repo.ps1'
    & powershell -NoProfile -ExecutionPolicy Bypass -File $initScript -RepoPath $RepoPath | Out-Host
    return $LASTEXITCODE
}

# ------------------------------------------------------------------
# Main
# ------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $RepoPath)) {
    Write-Host "==> heal-repo: la ruta no existe: $RepoPath"
    exit 2
}
$RepoPath = (Resolve-Path -LiteralPath $RepoPath).Path

$hooksDir = Get-HooksDir -RepoPath $RepoPath
if ($null -eq $hooksDir) {
    Write-Host "==> heal-repo: $RepoPath no es un repo git -- nada que armar (no-op)."
    exit 0
}

$configPath = Join-Path $RepoPath '.pre-commit-config.yaml'
if (-not (Test-Path -LiteralPath $configPath)) {
    # No lock configured at all. Two paths: auto-set-it-up (only for repos that
    # are mine, only when -AutoInit is passed), or just nag.
    if ($AutoInit) {
        $owners = Get-MyOwners -OwnersFile $OwnersFile
        if (Test-RepoIsMine -RepoPath $RepoPath -Owners $owners) {
            Write-Host "==> [*] repo tuyo SIN candados -- armandolos por primera vez (init-repo.ps1)..."
            $initExit = Invoke-InitRepo -RepoPath $RepoPath -QualityKitDir $QualityKitDir
            if ($initExit -ne 0) {
                Write-Host "==> [X] init-repo.ps1 fallo (codigo $initExit). Revisa el mensaje de arriba."
                exit 2
            }
            $armedNow = Test-HookArmed -HooksDir $hooksDir -HookName 'pre-commit'
            if ($armedNow) {
                Write-Host "==> [OK] candados creados y armados por primera vez en este repo."
                exit 0
            }
            Write-Host "==> [X] init-repo corrio pero el hook no quedo armado. Revisa a mano."
            exit 2
        }
        Write-Host "==> heal-repo: $RepoPath no parece tuyo (remoto ajeno) y no tiene candados -- no lo toco."
        exit 0
    }
    Write-Host "==> heal-repo: sin .pre-commit-config.yaml -- este repo no tiene candados configurados."
    Write-Host "    Si quieres protegerlo: corre init-repo.ps1 aqui una vez (o corre heal-repo con -AutoInit)."
    exit 0
}

$hookCount = Get-ConfiguredHookCount -ConfigPath $configPath
$wantsPrePush = Test-ConfigWantsPrePush -ConfigPath $configPath

$preCommitArmed = Test-HookArmed -HooksDir $hooksDir -HookName 'pre-commit'
$prePushArmed = $true
if ($wantsPrePush) {
    $prePushArmed = Test-HookArmed -HooksDir $hooksDir -HookName 'pre-push'
}

if ($preCommitArmed -and $prePushArmed) {
    $extra = ''
    if ($wantsPrePush) { $extra = ' + pre-push' }
    Write-Host "==> [OK] candados: $hookCount checks armados (hook pre-commit$extra presente y firmado por pre-commit)."
    exit 0
}

# --- Disarmed: this is the whole point of the script. Loud, then re-arm. ---
Write-Host ''
Write-Host "==> [!] CANDADO DESARMADO: hay .pre-commit-config.yaml ($hookCount checks) pero el hook de git NO esta instalado."
Write-Host "    Un clon nuevo nace asi: el config viaja, el hook (.git/hooks/) no. Sin re-armar, 'git commit' NO corre ningun check y pasa en silencio."

$invoker = Resolve-PreCommitInvoker
if ($null -eq $invoker) {
    Write-Host "==> [X] pre-commit no esta instalado/invocable en esta maquina, no puedo re-armar desde el heal."
    Write-Host "    Corre init-repo.ps1 en este repo (ese si instala pre-commit por pip y arma el hook)."
    exit 2
}

Write-Host "==> Re-armando via: $($invoker.Exe) $($invoker.ArgsPrefix -join ' ')"
$installExit = Invoke-PreCommit -Invoker $invoker -CmdArgs @('install') -RepoPath $RepoPath
if ($installExit -ne 0) {
    Write-Host "==> [X] 'pre-commit install' fallo (codigo $installExit). Revisa el mensaje de arriba."
    exit 2
}

if ($wantsPrePush) {
    $prePushExit = Invoke-PreCommit -Invoker $invoker -CmdArgs @('install', '--hook-type', 'pre-push') -RepoPath $RepoPath
    if ($prePushExit -ne 0) {
        Write-Host "==> [X] 'pre-commit install --hook-type pre-push' fallo (codigo $prePushExit)."
        exit 2
    }
}

# Re-verify from disk -- do not trust the exit code alone; confirm the hook is
# really there and firmado.
$preCommitArmed = Test-HookArmed -HooksDir $hooksDir -HookName 'pre-commit'
$prePushArmed = $true
if ($wantsPrePush) { $prePushArmed = Test-HookArmed -HooksDir $hooksDir -HookName 'pre-push' }

if ($preCommitArmed -and $prePushArmed) {
    $extra = ''
    if ($wantsPrePush) { $extra = ' + pre-push' }
    Write-Host "==> [OK] RE-ARMADO: candados: $hookCount checks ahora armados (pre-commit$extra)."
    exit 0
}

Write-Host "==> [X] Corri 'pre-commit install' pero el hook sigue sin aparecer firmado en $hooksDir. Revisa a mano."
exit 2
