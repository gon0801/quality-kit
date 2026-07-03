# quality-kit / cross-review.ps1
#
# On-demand cross-AI review: ask a DIFFERENT AI CLI than the one currently
# working to look over a diff with fresh eyes, independent of whoever wrote
# it. Run from inside the repo you want reviewed:
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\ehven\quality-kit\cross-review.ps1 -Con kimi
#   powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\ehven\quality-kit\cross-review.ps1 -Con codex -Alcance staged
#   powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\ehven\quality-kit\cross-review.ps1 -Con claude -Alcance last-commit
#
# -Alcance defaults to the combined working-tree + staged diff against HEAD
# (everything not yet committed) when not specified.
#
# -DryRun prints the exact command and prompt instead of calling the CLI --
# used by the test suite so it never burns real quota / API usage.
#
# Design note on WHY the diff is written to a temp file instead of passed
# as part of the CLI argument: Windows has a real command-line length limit
# (~32K characters via CreateProcess) that a ~60KB diff can exceed outright.
# Piping via stdin was tested and works for codex/claude but NOT for kimi
# (its -p flag requires its value inline, confirmed live: "option '-p,
# --prompt <prompt>' argument missing" when no value follows). A short
# argument that tells the CLI to go read a temp file works identically and
# reliably for all three (also confirmed live, including reading a file
# completely outside the repo/cwd with no permission hang in any of the
# three) -- so that is the one strategy this script uses for all of them.

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('kimi', 'codex', 'claude')]
    [string]$Con,

    [ValidateSet('staged', 'working', 'last-commit')]
    [string]$Alcance = '',

    [string]$RepoPath = (Get-Location).Path,

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$MaxDiffChars = 60000

function Write-Utf8NoBomFile {
    param([string]$Path, [string]$Content)
    [System.IO.File]::WriteAllText($Path, $Content, $Utf8NoBom)
}

function Test-IsGitRepo {
    param([string]$RepoPath)
    return (Test-Path -LiteralPath (Join-Path $RepoPath '.git'))
}

# ------------------------------------------------------------------
# Diff assembly
# ------------------------------------------------------------------

function Get-ReviewDiff {
    param([string]$RepoPath, [string]$Alcance)
    Push-Location -LiteralPath $RepoPath
    # Git routinely writes harmless warnings (CRLF/LF notices, etc.) to
    # stderr. With "2>&1" merging streams, PowerShell turns each stderr
    # line into an ErrorRecord -- and with the script-wide
    # $ErrorActionPreference of 'Stop', hitting even ONE of those throws a
    # terminating exception for what is not actually an error. Loosen it
    # just for these git calls, then restore it immediately after.
    $savedEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($Alcance -eq 'staged') {
            $lines = @(& git diff --cached 2>&1)
            $label = 'cambios en stage (git diff --cached)'
        } elseif ($Alcance -eq 'working') {
            $lines = @(& git diff 2>&1)
            $label = 'cambios sin stage en el working tree (git diff)'
        } elseif ($Alcance -eq 'last-commit') {
            # "git show HEAD --patch" (not "git diff HEAD~1 HEAD") on
            # purpose: it works even on a repo's very first commit, which
            # has no parent to diff against.
            $lines = @(& git show 'HEAD' '--patch' 2>&1)
            $label = 'el ultimo commit (git show HEAD --patch)'
        } else {
            $lines = @(& git diff 'HEAD' 2>&1)
            $label = 'todo lo que falta commitear: stage + working tree combinados (git diff HEAD)'
        }
        $gitExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedEap
        Pop-Location
    }
    # Stderr lines came through as ErrorRecord objects, not plain strings --
    # stringify everything uniformly before joining into diff text.
    $diffText = (($lines | ForEach-Object { [string]$_ }) -join "`n")
    return [PSCustomObject]@{ Diff = $diffText; Label = $label; ExitCode = $gitExitCode }
}

function Get-CappedDiff {
    param([string]$Diff, [int]$MaxChars)
    if ([string]::IsNullOrEmpty($Diff)) { return $Diff }
    if ($Diff.Length -le $MaxChars) { return $Diff }
    $truncated = $Diff.Substring(0, $MaxChars)
    $notice = "`n`n[... diff truncado aca: se supero el limite de $MaxChars caracteres (~60KB) que usa cross-review.ps1 para no saturar el prompt de revision. Si necesitas el diff completo, revisalo a mano con git. ...]"
    return ($truncated + $notice)
}

# ------------------------------------------------------------------
# Prompt + CLI invocation
# ------------------------------------------------------------------

function Get-RepoName {
    param([string]$RepoPath)
    return (Split-Path -Leaf $RepoPath)
}

function Build-ReviewPrompt {
    param([string]$DiffFilePath, [string]$Label, [string]$RepoName)
    return "Actua como revisor de codigo externo e independiente -- una segunda opinion sobre un cambio que escribio otro asistente de IA, no vos. Lee el archivo '$DiffFilePath' (contiene un diff de git: $Label, del repositorio '$RepoName') y revisalo. Busca bugs, regresiones, riesgos de seguridad y riesgos de calidad. Devuelve los hallazgos como una lista numerada, cada uno con su severidad (alta/media/baja) y una linea de explicacion. Si no encontras nada que objetar, responde exactamente la palabra: LGTM. Responde todo en espanol, en texto plano (sin acentos si podes evitarlos)."
}

function ConvertTo-WindowsCliArg {
    param([string]$Value)
    # Simple, sufficient quoting for this script's own prompts (they never
    # end in a bare backslash before the closing quote, so the full
    # CommandLineToArgvW edge cases don't apply here): wrap in double
    # quotes, escape embedded double quotes for the argv parser.
    $escaped = $Value.Replace('"', '\"')
    return '"' + $escaped + '"'
}

# .NET's Process.Start (with UseShellExecute=$false, needed so we can
# redirect stdin/stdout/stderr) can only launch a real executable directly
# -- it cannot run an extension-less shell script or a .ps1 the way a shell
# would. codex on this machine resolves to THREE things on PATH (a bare
# extension-less launcher, a .cmd shim, and a .ps1 wrapper); only the .cmd
# one is directly launchable this way. kimi and claude happen to resolve
# straight to a .exe, so this matters mainly for codex, but resolving all
# three the same way keeps this robust if that ever changes.
function Resolve-CliExePath {
    param([string]$Name)
    $allCmds = @(Get-Command -Name $Name -All -ErrorAction SilentlyContinue)
    if ($allCmds.Count -eq 0) {
        throw "No encontre '$Name' en el PATH de esta maquina. Confirma que la CLI esta instalada y accesible."
    }
    $preferred = $allCmds | Where-Object { $_.Source -match '\.(exe|cmd|bat)$' } | Select-Object -First 1
    if ($null -ne $preferred) { return $preferred.Source }
    return $allCmds[0].Source
}

# IMPORTANT (confirmed live): launching a resolved .cmd shim DIRECTLY as
# ProcessStartInfo.FileName (with redirected stdin/stdout/stderr) starts a
# real child process, but it hangs forever instead of ever finishing --
# closing the redirected stdin handle on that immediate child does not
# reliably propagate an EOF down to the real program the .cmd shim launches
# in turn. Explicitly wrapping through "cmd.exe /c" instead is the
# well-established reliable way to run a batch file with redirected I/O
# from .NET, and was confirmed live to complete normally (exit 0) where the
# direct approach hung indefinitely. A real .exe (kimi, claude here) has no
# such indirection and launches fine directly.
function Get-CliInvocation {
    param([string]$Con, [string]$Prompt)
    $escapedPrompt = ConvertTo-WindowsCliArg -Value $Prompt
    if ($Con -eq 'kimi') {
        $cliArgsText = "-p $escapedPrompt"
        $resolved = Resolve-CliExePath -Name 'kimi'
    } elseif ($Con -eq 'codex') {
        $cliArgsText = "exec $escapedPrompt"
        $resolved = Resolve-CliExePath -Name 'codex'
    } elseif ($Con -eq 'claude') {
        $cliArgsText = "-p $escapedPrompt"
        $resolved = Resolve-CliExePath -Name 'claude'
    } else {
        throw "CLI desconocido: $Con"
    }
    if ($resolved -match '\.(cmd|bat)$') {
        # cmd.exe's own "/c" parsing needs an EXTRA outer pair of quotes
        # around the whole remainder when the first token (the program
        # path) is itself quoted -- confirmed live: without this extra
        # wrap, cmd.exe mis-tokenizes the line and reports the quoted path
        # itself, glued to the next argument, as "not recognized as an
        # internal or external command". This is cmd.exe's own well-known
        # quirk, not something specific to any of these three CLIs.
        $quotedResolved = ConvertTo-WindowsCliArg -Value $resolved
        return [PSCustomObject]@{ Exe = 'cmd.exe'; Arguments = "/c ""$quotedResolved $cliArgsText""" }
    }
    return [PSCustomObject]@{ Exe = $resolved; Arguments = $cliArgsText }
}

function Invoke-CliHeadless {
    param([string]$Exe, [string]$Arguments, [string]$WorkingDirectory)
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
    $proc.Start() | Out-Null
    # Close stdin immediately without writing: some of these CLIs (codex
    # confirmed live) also peek at stdin even when a prompt argument is
    # given, appending whatever they find as extra context. An
    # unredirected/open stdin inherited from an interactive parent shell
    # would make them block waiting for input that never arrives; closing
    # it right away signals EOF immediately instead.
    $proc.StandardInput.Close()
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    return [PSCustomObject]@{ Stdout = $stdout; Stderr = $stderr; ExitCode = $proc.ExitCode }
}

# ------------------------------------------------------------------
# Main
# ------------------------------------------------------------------

$RepoPath = (Resolve-Path -LiteralPath $RepoPath).Path
Write-Host "=== quality-kit cross-review.ps1 ==="
Write-Host "Repo: $RepoPath"
Write-Host "CLI: $Con"

if (-not (Test-IsGitRepo -RepoPath $RepoPath)) {
    throw "Esta carpeta no es un repositorio git (no encontre .git)."
}

$alcanceLabelForDisplay = $Alcance
if ([string]::IsNullOrEmpty($alcanceLabelForDisplay)) { $alcanceLabelForDisplay = 'combinado (stage + working)' }
Write-Host "Alcance: $alcanceLabelForDisplay"

$diffResult = Get-ReviewDiff -RepoPath $RepoPath -Alcance $Alcance
if ([string]::IsNullOrWhiteSpace($diffResult.Diff)) {
    Write-Host '==> No hay diferencias para revisar en este alcance (diff vacio). Nada que hacer.'
    exit 0
}

$cappedDiff = Get-CappedDiff -Diff $diffResult.Diff -MaxChars $MaxDiffChars
$wasTruncated = ($cappedDiff.Length -gt $diffResult.Diff.Length -or ($diffResult.Diff.Length -gt $MaxDiffChars))
Write-Host "Tamano del diff: $($diffResult.Diff.Length) caracteres $(if ($diffResult.Diff.Length -gt $MaxDiffChars) { '(truncado a ' + $MaxDiffChars + ')' })"

$repoName = Get-RepoName -RepoPath $RepoPath
$tempDiffPath = Join-Path ([System.IO.Path]::GetTempPath()) ("quality-kit-review-" + [Guid]::NewGuid().ToString('N') + '.txt')
Write-Utf8NoBomFile -Path $tempDiffPath -Content $cappedDiff

$prompt = Build-ReviewPrompt -DiffFilePath $tempDiffPath -Label $diffResult.Label -RepoName $repoName
$invocation = Get-CliInvocation -Con $Con -Prompt $prompt

try {
    if ($DryRun) {
        Write-Host ''
        Write-Host '=== DRY RUN -- no se invoco ninguna IA ==='
        Write-Host "Comando: $($invocation.Exe) $($invocation.Arguments)"
        Write-Host ''
        Write-Host '=== Prompt ==='
        Write-Host $prompt
        Write-Host ''
        Write-Host "=== Archivo de diff (temporal): $tempDiffPath ==="
        exit 0
    }

    Write-Host "==> Invocando $Con de forma no interactiva..."
    $result = Invoke-CliHeadless -Exe $invocation.Exe -Arguments $invocation.Arguments -WorkingDirectory $RepoPath

    Write-Host ''
    Write-Host "=== Respuesta de $Con (codigo de salida: $($result.ExitCode)) ==="
    Write-Host $result.Stdout
    if ($result.Stderr) {
        Write-Host ''
        Write-Host '=== stderr ==='
        Write-Host $result.Stderr
    }

    if ($result.ExitCode -ne 0) {
        Write-Host ''
        Write-Host "==> ADVERTENCIA: $Con salio con codigo $($result.ExitCode) -- revisa el stderr de arriba. Si es codex, el problema mas comun es tener que abrir 'codex' de forma interactiva una vez para aceptar la confianza del directorio (ver README, seccion Troubleshooting)."
    }
    exit $result.ExitCode
} finally {
    if (-not $DryRun) {
        Remove-Item -LiteralPath $tempDiffPath -Force -ErrorAction SilentlyContinue
    } else {
        # Left on purpose in -DryRun so the test suite / a curious user can
        # inspect exactly what would have been sent.
        Write-Host "(archivo de diff temporal dejado para inspeccion: $tempDiffPath)"
    }
}
