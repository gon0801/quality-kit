# quality-kit / cross-review.ps1
#
# On-demand cross-AI review: ask a DIFFERENT AI CLI than the one currently
# working to look over a diff with fresh eyes, independent of whoever wrote
# it. Run from inside the repo you want reviewed:
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\ehven\quality-kit\cross-review.ps1 -Con kimi
#   powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\ehven\quality-kit\cross-review.ps1 -Con codex -Alcance staged
#   powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\ehven\quality-kit\cross-review.ps1 -Con claude -Alcance last-commit
#   powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\ehven\quality-kit\cross-review.ps1 -Con auto -Excluir kimi
#
# -Con auto: try the strongest available reviewer first and fall back down
# the chain (claude -> kimi -> codex), skipping -Excluir (the AI that wrote
# the change). claude is always invoked with ANTHROPIC_* and
# CLAUDE_CODE_USE_* env vars stripped, so env-var redirections (a
# 'glm'-launched session, Bedrock/Vertex toggles) cannot steer the review
# away from the real Claude account (OAuth + the plan's default model);
# this does not defend against a fake 'claude' binary planted on PATH.
# -TimeoutSec (default 300): hard per-candidate cap -- a hung CLI gets
# killed (exit 124 in single mode) and the auto chain moves on to the next
# candidate. Added after a real hang: without it, this script (and the
# harness that called it) waited forever on a stuck claude. For the same
# reason claude receives the diff INLINE via stdin (no file reads, no
# permission/trust surface to hang on); kimi/codex keep the temp-file path.
#
# Exit 3 -- ONLY in auto mode -- means no external reviewer in the chain
# could deliver a review (caller falls back to its own internal reviewer
# and must say so). In single mode the CLI's own exit code is passed
# through as-is -- with ONE deliberate exception: exit 0 with EMPTY output
# becomes exit 1, because an empty review is not a review (do not read 3
# as a sentinel outside auto). The env stripping applies to EVERY claude
# invocation (single mode included): on a machine where claude
# authenticates ONLY via ANTHROPIC_API_KEY (no OAuth login), claude will
# fail here by design -- in auto mode the chain then falls to the next
# reviewer.
#
# -Alcance defaults to the combined working-tree + staged diff against HEAD
# (everything not yet committed) when not specified.
#
# -Archivos limits the diff to the given paths (git pathspecs, relative to
# the repo root; comma-separated in one argument or repeated). Born from a
# real failure (retro Kimi 2026-07-09): a working tree holding FOUR
# accumulated bug fixes produced a diff so large the external reviewer
# timed out twice (>300 s) and delivered nothing -- scoping the review to
# the current task's files keeps the diff small and the findings relevant.
# Composable with -Alcance. CAREFUL: a mistyped path yields nothing
# reviewable -- and with -Alcance last-commit that is NOT an empty string,
# because "git show" always prints the commit header, so the guard requires
# a real "diff --git " line rather than mere non-emptiness. Either way the
# message names the scope to make the typo visible.
#
# A git failure is never reviewed: git's stderr is merged into the diff text
# on purpose (to keep the diagnostic), so the exit code is checked and a
# failed git aborts with exit 1 instead of shipping "fatal: ..." to a paid
# reviewer.
#
#   ... cross-review.ps1 -Con auto -Excluir kimi -Archivos "engines/bid_motor.py,tests/test_bid_motor.py"
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
    # 'auto' = probar la cadena claude -> kimi -> codex (el cerebro mas fuerte
    # primero) y usar el primero que responda, saltando -Excluir.
    [Parameter(Mandatory = $true)]
    [ValidateSet('kimi', 'codex', 'claude', 'auto')]
    [string]$Con,

    # La IA que ESCRIBIO el cambio, para saltarla en la cadena de 'auto':
    # una IA no debe revisar su propio trabajo.
    [ValidateSet('kimi', 'codex', 'claude', '')]
    [string]$Excluir = '',

    [ValidateSet('staged', 'working', 'last-commit')]
    [string]$Alcance = '',

    # Pathspecs (relativos a la raiz del repo) para limitar el diff a los
    # archivos de la TAREA en curso. Acepta lista separada por comas en un
    # solo argumento (lo que llega desde 'powershell -File') o elementos
    # repetidos. Vacio = diff completo del alcance elegido.
    [string[]]$Archivos = @(),

    [string]$RepoPath = (Get-Location).Path,

    # Tope por candidato. Caso real (2026-07-05): claude se quedo colgado
    # y, sin timeout, este script esperaba PARA SIEMPRE -- desde el harness
    # que lo llamo se veia como cuelgue total y la cadena nunca llegaba al
    # siguiente candidato. 0 = sin tope (no recomendado). Nota honesta: el
    # tope efectivo puede excederse ~35 s (30 s del write de stdin + 5 s de
    # drenado post-kill); es un tope practico, no un deadline exacto.
    [int]$TimeoutSec = 300,

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
    param([string]$RepoPath, [string]$Alcance, [string[]]$FileScope = @())
    # El separador '--' + pathspecs limita cada diff a los archivos pedidos;
    # con $FileScope vacio, $pathspecArgs queda vacio y los comandos son
    # identicos a los de siempre.
    $pathspecArgs = @()
    if ($FileScope.Count -gt 0) { $pathspecArgs = @('--') + $FileScope }
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
            $lines = @(& git diff --cached @pathspecArgs 2>&1)
            $label = 'cambios en stage (git diff --cached)'
        } elseif ($Alcance -eq 'working') {
            $lines = @(& git diff @pathspecArgs 2>&1)
            $label = 'cambios sin stage en el working tree (git diff)'
        } elseif ($Alcance -eq 'last-commit') {
            # "git show HEAD --patch" (not "git diff HEAD~1 HEAD") on
            # purpose: it works even on a repo's very first commit, which
            # has no parent to diff against.
            $lines = @(& git show 'HEAD' '--patch' @pathspecArgs 2>&1)
            $label = 'el ultimo commit (git show HEAD --patch)'
        } else {
            $lines = @(& git diff 'HEAD' @pathspecArgs 2>&1)
            $label = 'todo lo que falta commitear: stage + working tree combinados (git diff HEAD)'
        }
        if ($FileScope.Count -gt 0) {
            $label += ", LIMITADO a los archivos de la tarea en curso: $($FileScope -join ', ')"
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
    # La clausula VERIFICAR nace de falsos positivos reales (retro Kimi
    # 2026-07-09): el revisor dudo de un UNIQUE cuyo DDL existia, de un
    # import que existia y de una funcion definida en otra parte -- todo
    # codigo fuera del diff. Este candidato corre PARADO EN EL REPO (el
    # working directory es el repo real), asi que puede y debe verificar
    # antes de afirmar; solo si no puede, degrada el hallazgo a VERIFICAR:.
    return "Actua como revisor de codigo externo e independiente -- una segunda opinion sobre un cambio que escribio otro asistente de IA, no vos. Lee el archivo '$DiffFilePath' (contiene un diff de git: $Label, del repositorio '$RepoName') y revisalo. Busca bugs, regresiones, riesgos de seguridad y riesgos de calidad. Un diff es parcial por naturaleza: si un posible hallazgo depende de codigo que NO aparece en el diff (un import, un DDL/esquema, una funcion o constante definida en otra parte), NO lo afirmes en ciego -- tu directorio de trabajo ES el repositorio real: verificalo primero leyendo/grepeando el archivo en cuestion. Si no podes verificarlo, reportalo con el prefijo 'VERIFICAR:' en vez de afirmarlo como bug, diciendo exactamente que habria que confirmar. Devuelve los hallazgos como una lista numerada, cada uno con su severidad (alta/media/baja) y una linea de explicacion. Si no encontras nada que objetar, responde exactamente la palabra: LGTM. Responde todo en espanol, en texto plano (sin acentos si podes evitarlos)."
}

# Variante para claude: el diff viaja INLINE por stdin en vez de pedirle leer
# un archivo. Motivo (caso real 2026-07-05): pedir una lectura de archivo abre
# la superficie de permisos/confianza de Claude Code, que en modo headless no
# tiene quien la conteste -- candidato #1 del cuelgue observado. Con el diff
# en stdin la revision no necesita NINGUNA herramienta.
function Build-ReviewPromptInline {
    param([string]$Label, [string]$RepoName)
    # Este candidato NO tiene herramientas por diseno (anti-cuelgue), asi que
    # no puede verificar nada fuera del diff: todo hallazgo que dependa de
    # codigo ausente va SIEMPRE como VERIFICAR:, nunca afirmado (misma retro
    # de falsos positivos que Build-ReviewPrompt).
    return "Actua como revisor de codigo externo e independiente -- una segunda opinion sobre un cambio que escribio otro asistente de IA, no vos. A continuacion de estas instrucciones viene un diff de git ($Label, del repositorio '$RepoName'). Revisalo SIN usar ninguna herramienta: todo lo que necesitas ya esta en este mensaje. Busca bugs, regresiones, riesgos de seguridad y riesgos de calidad. Un diff es parcial por naturaleza y no tenes forma de ver el resto del repo: si un posible hallazgo depende de codigo que NO aparece en el diff (un import, un DDL/esquema, una funcion o constante definida en otra parte), NO lo afirmes como bug -- reportalo con el prefijo 'VERIFICAR:' diciendo exactamente que habria que confirmar, y reserva las afirmaciones directas para lo que el propio diff demuestra. Devuelve los hallazgos como una lista numerada, cada uno con su severidad (alta/media/baja) y una linea de explicacion. Si no encontras nada que objetar, responde exactamente la palabra: LGTM. Responde todo en espanol, en texto plano (sin acentos si podes evitarlos)."
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
function Test-CliAvailable {
    param([string]$Name)
    return (@(Get-Command -Name $Name -All -ErrorAction SilentlyContinue).Count -gt 0)
}

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
    param([string]$Exe, [string]$Arguments, [string]$WorkingDirectory, [string[]]$StripEnvPrefixes = @(), [string]$StdinText = '', [int]$TimeoutSec = 0)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = $Arguments
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    foreach ($prefix in $StripEnvPrefixes) {
        # Quitar del ambiente heredado toda variable con estos prefijos. El
        # caso real: una sesion lanzada con 'glm' redirige el CLI de claude a
        # otro proveedor/modelo via variables ANTHROPIC_*, y las
        # CLAUDE_CODE_USE_* (Bedrock/Vertex) redirigen sin ese prefijo -- la
        # revision cruzada debe ir a la cuenta real de Claude (login OAuth +
        # el modelo default del plan, que sigue solo las mejoras de modelo).
        # Limite honesto: esto neutraliza redirecciones POR VARIABLES DE
        # ENTORNO; no defiende contra un binario 'claude' falso puesto antes
        # en el PATH (eso ya es la maquina comprometida, otro problema).
        $keysToRemove = @($psi.EnvironmentVariables.Keys) | Where-Object { $_ -like "$prefix*" }
        foreach ($k in $keysToRemove) { $psi.EnvironmentVariables.Remove($k) }
    }
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $proc.Start() | Out-Null
    # Escribir el StdinText (si lo hay) y cerrar stdin de inmediato: algunos
    # de estos CLIs (codex confirmado en vivo) tambien leen stdin aunque
    # reciban prompt por argumento; un stdin abierto heredado de un shell
    # interactivo los deja esperando entrada que nunca llega -- cerrarlo
    # senala EOF al instante.
    # Las lecturas async arrancan ANTES de escribir stdin: un write sincrono
    # contra un hijo que no drena stdin llenaria el buffer del pipe (4-64KB,
    # menos que un diff capeado) y bloquearia Write() para siempre ANTES de
    # llegar al WaitForExit con tope -- reintroduciendo exactamente el
    # cuelgue que el timeout elimina. Tambien evita el deadlock clasico de
    # leer stdout/stderr en serie (codex escribe su progreso a stderr).
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    if ($StdinText) {
        # Bytes UTF-8 explicitos via BaseStream: PS 5.1 no tiene
        # ProcessStartInfo.StandardInputEncoding y el StreamWriter default
        # usa la codepage OEM de consola -- un diff con acentos/enie
        # llegaria corrupto y el revisor revisaria codigo distinto del real.
        $stdinBytes = [System.Text.Encoding]::UTF8.GetBytes($StdinText)
        $stdinTask = $null
        try { $stdinTask = $proc.StandardInput.BaseStream.WriteAsync($stdinBytes, 0, $stdinBytes.Length) } catch { }
        $stdinWriteOk = $false
        if ($null -ne $stdinTask) {
            try { $stdinWriteOk = $stdinTask.Wait(30000) } catch { }
        }
        # EOF (Close) si el write termino, o si fallo (pipe roto = el hijo ya
        # murio; su stderr diagnostico se conserva). Si el write sigue
        # ATORADO (hijo no drena), NO cerrar: Close bloquearia en el flush --
        # el timeout + kill de abajo se encarga de ese proceso.
        if ($stdinWriteOk -or ($null -eq $stdinTask) -or $stdinTask.IsFaulted -or $stdinTask.IsCanceled) {
            try { $proc.StandardInput.Close() } catch { }
        }
    } else {
        try { $proc.StandardInput.Close() } catch { }
    }
    if ($TimeoutSec -gt 0) {
        if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
            # Caso real (2026-07-05): claude colgado dejaba a este script (y
            # al harness que lo llamo) esperando para siempre. Matar y
            # reportar TimedOut deja que la cadena siga al siguiente.
            # taskkill /T mata el ARBOL completo: un CLI lanzado via shim
            # .cmd (cmd.exe -> node, el caso codex) quedaria huerfano y
            # consumiendo cuota si solo se matara el proceso directo
            # (Process.Kill() de PS 5.1 no tiene la variante de arbol).
            try { & taskkill /T /F /PID $proc.Id 2>$null | Out-Null } catch { }
            try { if (-not $proc.HasExited) { $proc.Kill() } } catch { }
            # WaitAll lanza AggregateException si una task quedo Faulted (y
            # .Result tambien) -- capturar solo lo que SI termino bien, para
            # conservar el diagnostico parcial sin reventar con error crudo.
            try { [void][System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask), 5000) } catch { }
            $partialOut = ''
            $partialErr = ''
            if ($stdoutTask.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion) { $partialOut = $stdoutTask.Result }
            if ($stderrTask.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion) { $partialErr = $stderrTask.Result }
            return [PSCustomObject]@{ Stdout = $partialOut; Stderr = $partialErr; ExitCode = 124; TimedOut = $true }
        }
        # WaitForExit(ms) puede regresar antes de que el output async
        # termine de vaciarse; el WaitForExit() sin argumento lo garantiza.
        $proc.WaitForExit()
    } else {
        $proc.WaitForExit()
    }
    $stdout = $stdoutTask.Result
    $stderr = $stderrTask.Result
    return [PSCustomObject]@{ Stdout = $stdout; Stderr = $stderr; ExitCode = $proc.ExitCode; TimedOut = $false }
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

# Cadena de candidatos -- se arma ANTES de tocar el diff, para que la
# validacion (p.ej. pedir que una IA revise su propio cambio) falle claro
# incluso cuando el diff este vacio. En 'auto' se intenta el cerebro mas
# fuerte primero (claude = el modelo default del plan de la cuenta, que
# sigue solo las mejoras de modelo), despues kimi (rapido), despues codex
# (capaz pero de tiempos variables en esta maquina) -- saltando -Excluir.
# Fail-open: si un candidato no esta instalado o no entrega revision, se
# pasa al siguiente; si NINGUNO responde, exit 3 para que quien llama
# (p.ej. el harness de SummonAI) caiga a su revisor interno y lo diga en
# su recibo.
if ($Con -eq 'auto') {
    $chain = @('claude', 'kimi', 'codex') | Where-Object { $_ -ne $Excluir }
    Write-Host "Cadena auto: $($chain -join ' -> ')$(if ($Excluir) { " (excluido: $Excluir, escribio el cambio)" })"
    # En modo single hay validacion dura (-Excluir == -Con => error), pero en
    # auto no habia NINGUNA: la cadena arranca por claude, que es casi siempre
    # quien escribio el cambio, asi que olvidar -Excluir hacia que la IA se
    # revisara a si misma en silencio -- perdiendo la independencia que es el
    # proposito entero del script. No se aborta (rompería a quien ya llama sin
    # el flag): se avisa fuerte y se sigue.
    if (-not $Excluir) {
        Write-Host "==> ADVERTENCIA: no pasaste -Excluir, asi que la cadena arranca por 'claude'. Si claude escribio este cambio se estaria revisando a si mismo, que es justo lo que esta revision debe evitar. Volve a correr con -Excluir <la IA que lo escribio>." -ForegroundColor Yellow
    }
} else {
    if ($Excluir -eq $Con) {
        throw "-Excluir '$Excluir' es el mismo CLI que -Con '$Con': una IA no debe revisar su propio cambio."
    }
    $chain = @($Con)
}

$alcanceLabelForDisplay = $Alcance
if ([string]::IsNullOrEmpty($alcanceLabelForDisplay)) { $alcanceLabelForDisplay = 'combinado (stage + working)' }
Write-Host "Alcance: $alcanceLabelForDisplay"

# Normalizar -Archivos: 'powershell -File' entrega un solo string aunque el
# parametro sea [string[]], asi que se acepta lista separada por comas y se
# parte aqui. Backslashes -> slashes porque el pathspec de git no trata '\'
# como separador de ruta (un path Windows pegado tal cual no matchea nada).
$fileScope = @($Archivos |
    ForEach-Object { $_ -split ',' } |
    ForEach-Object { $_.Trim().Replace('\', '/') } |
    Where-Object { $_ -ne '' })
if ($fileScope.Count -gt 0) {
    Write-Host "Archivos (pathspec de la tarea): $($fileScope -join ', ')"
}

$diffResult = Get-ReviewDiff -RepoPath $RepoPath -Alcance $Alcance -FileScope $fileScope

# git puede FALLAR, y su stderr viene mezclado en el texto del diff (el "2>&1"
# de arriba es a proposito, para conservar el diagnostico). Sin mirar el codigo
# de salida, ese mensaje de error viajaba como si FUERA el diff y se le mandaba
# a un revisor externo: una ronda entera (~100-150k tokens) quemada revisando un
# "fatal: ...". Caso real reproducido: repo sin ningun commit + -Alcance
# last-commit -> "fatal: ambiguous argument 'HEAD'". Fail-closed a proposito:
# ante un git roto no se adivina, se para.
if ($diffResult.ExitCode -ne 0) {
    Write-Host ''
    Write-Host "==> git fallo al armar el diff (codigo $($diffResult.ExitCode)). NO se invoca a ningun revisor. Salida de git:"
    Write-Host $diffResult.Diff
    exit 1
}

# "Vacio" no alcanza como unica senal de que no hay nada que revisar: con
# -Alcance last-commit, "git show" SIEMPRE imprime la cabecera del commit, asi
# que un pathspec mal tipeado devolvia esa cabecera (no vacia), el guardia no
# disparaba y se mandaba a revisar un "diff" sin un solo cambio -- justo el
# escenario que -Archivos existe para evitar. Un diff real SIEMPRE trae al menos
# una linea "diff --git " (tambien los cambios de solo permisos, binarios,
# renombres y submodulos), asi que esa es la senal fiable de contenido.
$hasRealChanges = ($diffResult.Diff -match '(?m)^diff --git ')
if ([string]::IsNullOrWhiteSpace($diffResult.Diff) -or (-not $hasRealChanges)) {
    if ($fileScope.Count -gt 0) {
        # Un pathspec mal tipeado no cambia nada en silencio -- nombrar el
        # scope hace visible el typo en vez de un "nada que hacer" mudo.
        Write-Host "==> No hay diferencias para revisar en este alcance dentro de los archivos pedidos ($($fileScope -join ', ')). Si esperabas cambios, revisa que las rutas sean correctas relativas a la raiz del repo."
    } else {
        Write-Host '==> No hay diferencias para revisar en este alcance (el diff no contiene ningun cambio). Nada que hacer.'
    }
    exit 0
}

$cappedDiff = Get-CappedDiff -Diff $diffResult.Diff -MaxChars $MaxDiffChars
Write-Host "Tamano del diff: $($diffResult.Diff.Length) caracteres $(if ($diffResult.Diff.Length -gt $MaxDiffChars) { '(truncado a ' + $MaxDiffChars + ')' })"

$repoName = Get-RepoName -RepoPath $RepoPath
$tempDiffPath = Join-Path ([System.IO.Path]::GetTempPath()) ("quality-kit-review-" + [Guid]::NewGuid().ToString('N') + '.txt')
Write-Utf8NoBomFile -Path $tempDiffPath -Content $cappedDiff

$prompt = Build-ReviewPrompt -DiffFilePath $tempDiffPath -Label $diffResult.Label -RepoName $repoName

try {
    # OJO: nombre distinto de $LASTEXITCODE a proposito (PowerShell no
    # distingue mayusculas en variables): sombrear la automatica seria una
    # mina si mas adelante alguien corre un comando nativo dentro del loop.
    $chainExitCode = 1
    foreach ($candidate in $chain) {
        if (-not (Test-CliAvailable -Name $candidate)) {
            if ($Con -eq 'auto') {
                Write-Host "==> '$candidate' no esta instalado en esta maquina; sigo con el siguiente de la cadena."
                continue
            }
            throw "No encontre '$candidate' en el PATH de esta maquina. Confirma que la CLI esta instalada y accesible."
        }

        # claude: diff inline por stdin + prompt sin lecturas de archivo (ver
        # Build-ReviewPromptInline); kimi/codex siguen leyendo el temp file.
        $candidatePrompt = $prompt
        $candidateStdin = ''
        if ($candidate -eq 'claude') {
            $candidatePrompt = Build-ReviewPromptInline -Label $diffResult.Label -RepoName $repoName
            $candidateStdin = "=== DIFF ===`n" + $cappedDiff
        }

        # Fail-open POR CANDIDATO en modo auto: si armar o lanzar la
        # invocacion truena (exe corrupto, shim raro, etc.), eso no debe
        # abortar la cadena entera con exit 1 -- se anota y se prueba el
        # siguiente. En modo single se conserva el error claro de siempre.
        $invocation = $null
        try {
            $invocation = Get-CliInvocation -Con $candidate -Prompt $candidatePrompt
        } catch {
            if ($Con -eq 'auto') {
                Write-Host "==> ADVERTENCIA: no pude preparar la invocacion de $candidate ($($_.Exception.Message)). Sigo con el siguiente de la cadena."
                continue
            }
            throw
        }
        $stripPrefixes = @()
        if ($candidate -eq 'claude') { $stripPrefixes = @('ANTHROPIC_', 'CLAUDE_CODE_USE_') }

        if ($DryRun) {
            Write-Host ''
            Write-Host '=== DRY RUN -- no se invoco ninguna IA ==='
            if ($Con -eq 'auto') {
                Write-Host "Candidato elegido (primer disponible de la cadena): $candidate"
            }
            if ($stripPrefixes.Count -gt 0) {
                Write-Host "Nota: se invocaria con las variables de entorno $($stripPrefixes -join '* y ')* limpias (el comando de abajo no puede mostrarlo)."
            }
            if ($candidateStdin) {
                Write-Host "Nota: a $candidate el diff se le entrega inline por stdin (sin lecturas de archivo, sin superficie de permisos que pueda colgarse); el archivo temporal de abajo se genera igual para inspeccion, pero $candidate NO lo lee."
            }
            Write-Host "Comando: $($invocation.Exe) $($invocation.Arguments)"
            Write-Host ''
            Write-Host '=== Prompt ==='
            Write-Host $candidatePrompt
            Write-Host ''
            Write-Host "=== Archivo de diff (temporal): $tempDiffPath ==="
            exit 0
        }

        Write-Host "==> Invocando $candidate de forma no interactiva (tope: $(if ($TimeoutSec -gt 0) { "$TimeoutSec s" } else { 'sin tope' }))..."
        $result = $null
        try {
            $result = Invoke-CliHeadless -Exe $invocation.Exe -Arguments $invocation.Arguments -WorkingDirectory $RepoPath -StripEnvPrefixes $stripPrefixes -StdinText $candidateStdin -TimeoutSec $TimeoutSec
        } catch {
            if ($Con -eq 'auto') {
                Write-Host "==> ADVERTENCIA: fallo al invocar $candidate ($($_.Exception.Message)). Sigo con el siguiente de la cadena."
                continue
            }
            throw
        }

        if ($result.TimedOut) {
            $chainExitCode = 124
            Write-Host ''
            if (-not [string]::IsNullOrWhiteSpace($result.Stderr)) {
                # Unica evidencia diagnostica de POR QUE se colgo -- sin
                # esto, el proximo cuelgue se depura a ciegas.
                $errPreview = $result.Stderr
                if ($errPreview.Length -gt 800) { $errPreview = $errPreview.Substring(0, 800) + '...' }
                Write-Host "--- stderr parcial de $candidate antes del kill ---"
                Write-Host $errPreview
            }
            if (-not [string]::IsNullOrWhiteSpace($result.Stdout)) {
                $outPreview = $result.Stdout
                if ($outPreview.Length -gt 800) { $outPreview = $outPreview.Substring(0, 800) + '...' }
                Write-Host "--- stdout parcial de $candidate antes del kill ---"
                Write-Host $outPreview
            }
            if ($Con -eq 'auto') {
                Write-Host "==> ADVERTENCIA: $candidate se colgo mas de $TimeoutSec segundos; proceso (y su arbol) terminado. Sigo con el siguiente de la cadena."
            } else {
                Write-Host "==> ADVERTENCIA: $candidate se colgo mas de $TimeoutSec segundos; proceso (y su arbol) terminado (exit 124). Sube el tope con -TimeoutSec si la revision es legitimamente larga."
            }
            continue
        }

        Write-Host ''
        Write-Host "=== Respuesta de $candidate (codigo de salida: $($result.ExitCode)) ==="
        Write-Host $result.Stdout
        if ($result.Stderr) {
            Write-Host ''
            Write-Host '=== stderr ==='
            Write-Host $result.Stderr
        }

        # Una revision "utilizable" = salio bien Y dijo algo. Un exit 0 con
        # salida vacia no es una revision (y en 'auto' debe pasar al
        # siguiente candidato, no dar el gate por bueno en silencio).
        if ($result.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($result.Stdout)) {
            Write-Host ''
            Write-Host "=== Revisor efectivo: $candidate ==="
            exit 0
        }

        if ($result.ExitCode -ne 0) { $chainExitCode = $result.ExitCode } else { $chainExitCode = 1 }
        $emptyNote = ''
        if ([string]::IsNullOrWhiteSpace($result.Stdout)) { $emptyNote = ', salida vacia' }
        Write-Host ''
        if ($Con -eq 'auto') {
            Write-Host "==> ADVERTENCIA: $candidate no entrego una revision utilizable (codigo $($result.ExitCode)$emptyNote). Sigo con el siguiente de la cadena."
        } else {
            Write-Host "==> ADVERTENCIA: $candidate no entrego una revision utilizable (codigo $($result.ExitCode)$emptyNote) -- revisa el stderr de arriba. Si es codex, el problema mas comun es tener que abrir 'codex' de forma interactiva una vez para aceptar la confianza del directorio (ver README, seccion Troubleshooting)."
        }
    }

    if ($Con -eq 'auto') {
        # El exit 3 como sentinel de "sin revisor externo" aplica SOLO al
        # modo auto. En modo single el exit code del CLI se propaga tal
        # cual (y un CLI tambien podria salir con 3 por sus propias
        # razones) -- no leerlo como sentinel fuera de auto. Ojo: aunque el
        # ultimo candidato haya muerto por timeout (124), en auto la salida
        # al agotar la cadena SIEMPRE es 3 -- el contrato del caller no se
        # rompe por el tipo de falla del ultimo intento.
        Write-Host ''
        Write-Host '==> NINGUN revisor externo de la cadena pudo revisar (exit 3). Quien pidio esta revision debe caer a su propio revisor interno y decirlo en su reporte.'
        exit 3
    }
    exit $chainExitCode
} finally {
    if (-not $DryRun) {
        Remove-Item -LiteralPath $tempDiffPath -Force -ErrorAction SilentlyContinue
    } else {
        # Left on purpose in -DryRun so the test suite / a curious user can
        # inspect exactly what would have been sent.
        Write-Host "(archivo de diff temporal dejado para inspeccion: $tempDiffPath)"
    }
}
