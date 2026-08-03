<#
  saikit-gate-heal.ps1

  Re-aplica el "sentinel gate" al hook del SummonAI Kit original.

  POR QUE EXISTE
  El kit original se arma con cualquier prompt que contenga uno de sus fragmentos
  clave, y los busca SIN frontera de palabra. En espanol eso da falsos positivos
  constantes: "ui" matchea dentro de "cualquier"/"quiero"/"aqui"/"seguir", y
  "code" matchea dentro de "codex". Resultado: el gate exige recibo casi siempre.

  QUE HACE
  Inserta tres bloques marcados en summonaikit-harness.sh para que el harness solo
  se arme si el prompt trae el sentinel explicito -saikit.

  OJO: el sentinel es SOLO -saikit. /harness-plan pertenece al plugin
  claude-code-harness, que es otro sistema distinto, y no debe despertar a este.

  POR QUE SE RE-APLICA EN CADA ARRANQUE
  `summonaikit install` / `/saikit-update` reescriben el hook desde cero y se
  llevan el parche. Este script es idempotente: si el marcador ya esta, no hace
  nada; si el kit se actualizo, vuelve a parchar. Mismo patron que session-heal.ps1
  usa para claude-mem.

  Vive en quality-kit (no en ~/.claude/hooks) justamente para que un install del
  kit no pueda borrarlo.

  USO
    powershell -ExecutionPolicy Bypass -File saikit-gate-heal.ps1
    powershell -ExecutionPolicy Bypass -File saikit-gate-heal.ps1 -Check
#>
[CmdletBinding()]
param(
    [switch]$Check,
    [switch]$Quiet
)

# Fail-open: este script jamas debe tumbar el arranque de una sesion.
$ErrorActionPreference = 'Continue'

$MARKER = 'SAIKIT-SENTINEL-GATE v1'

function ToLf([string]$s) { return ($s -replace "`r`n", "`n") }

# --- anclas: texto literal del hook pristino donde se inyecta el parche ---
$anchorA = ToLf "MAX_CYCLES=2"

$anchorB = ToLf @'
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
'@

$anchorC = ToLf @'
record_tool_evidence() {
  event_name="$(json_string_field hook_event_name)"
'@

# --- reemplazos ---
$insertA = ToLf @'
MAX_CYCLES=2

# >>> SAIKIT-SENTINEL-GATE v1 (parche local, re-aplicado por quality-kit/saikit-gate-heal.ps1) >>>
# El kit busca sus palabras clave como fragmentos, sin frontera de palabra, asi que
# en espanol se arma solo ("cualquier" contiene ui, "codex" contiene code). Con este
# parche el harness SOLO se arma si el prompt trae el sentinel explicito.
# El sentinel es unicamente -saikit: /harness-plan es del plugin claude-code-harness,
# otro sistema, y no debe despertar a este kit.
SAIKIT_SENTINEL_RE='(^|[^A-Za-z0-9_])-saikit([^A-Za-z0-9_-]|$)'
# <<< SAIKIT-SENTINEL-GATE v1 <<<
'@

$insertB = ToLf @'
start_harness() {
  prompt_text="$(json_string_field prompt)"
  if [ -z "$prompt_text" ]; then prompt_text="$INPUT"; fi
  # >>> SAIKIT-SENTINEL-GATE v1 >>>
  # El sentinel REEMPLAZA a is_engineering_task / is_trivial_task: es la unica
  # condicion de armado. Dejarlas activas ademas del sentinel hacia que un prompt
  # con -saikit pero sin palabras en ingles siguiera durmiendo. Si lo escribiste,
  # lo quieres. Aplica igual a la fase session, cuyo payload nunca trae sentinel.
  if ! printf '%s' "$prompt_text" | grep -Eq "$SAIKIT_SENTINEL_RE"; then
    emit_allow
  fi
  # <<< SAIKIT-SENTINEL-GATE v1 <<<
'@

$insertC = ToLf @'
record_tool_evidence() {
  # >>> SAIKIT-SENTINEL-GATE v1 >>>
  # Sin tarea armada NO se crea archivo de estado. Si no, mark_evidence lo crearia
  # con task_hash=unknown en cualquier edicion y el Stop gate se activaria solo,
  # anulando el sentinel.
  if [ ! -f "$STATE_PATH" ]; then emit_allow; fi
  # <<< SAIKIT-SENTINEL-GATE v1 <<<
  event_name="$(json_string_field hook_event_name)"
'@

$targets = @('.claude', '.codex', '.cursor', '.agents') |
    ForEach-Object { Join-Path $env:USERPROFILE (Join-Path $_ 'hooks\summonaikit-harness.sh') }

$results = @()

foreach ($path in $targets) {
    $short = $path.Replace($env:USERPROFILE, '~')

    if (-not (Test-Path $path)) {
        $results += [pscustomobject]@{ hook = $short; estado = 'no-instalado' }
        continue
    }

    try {
        $lf = ToLf ([System.IO.File]::ReadAllText($path))
    }
    catch {
        $results += [pscustomobject]@{ hook = $short; estado = "ilegible: $($_.Exception.Message)" }
        continue
    }

    if ($lf.Contains($MARKER)) {
        $results += [pscustomobject]@{ hook = $short; estado = 'ya-parchado' }
        continue
    }

    # Si el kit cambio su codigo, las anclas dejan de existir. Reportarlo fuerte
    # en vez de fallar en silencio: un parche que no aplico es un gate apagado.
    $missing = @()
    if (-not $lf.Contains($anchorA)) { $missing += 'A' }
    if (-not $lf.Contains($anchorB)) { $missing += 'B' }
    if (-not $lf.Contains($anchorC)) { $missing += 'C' }
    if ($missing.Count -gt 0) {
        $results += [pscustomobject]@{ hook = $short; estado = "ANCLAS-CAMBIARON ($($missing -join ',')) - revisar a mano" }
        continue
    }

    if ($Check) {
        $results += [pscustomobject]@{ hook = $short; estado = 'sin-parchar (falta aplicar)' }
        continue
    }

    $out = $lf.Replace($anchorA, $insertA).Replace($anchorB, $insertB).Replace($anchorC, $insertC)

    try {
        # LF + UTF8 sin BOM: bash no tolera BOM en el shebang.
        [System.IO.File]::WriteAllText($path, $out, (New-Object System.Text.UTF8Encoding($false)))
        $results += [pscustomobject]@{ hook = $short; estado = 'PARCHADO' }
    }
    catch {
        $results += [pscustomobject]@{ hook = $short; estado = "fallo al escribir: $($_.Exception.Message)" }
    }
}

$changed = @($results | Where-Object { $_.estado -eq 'PARCHADO' }).Count
$broken = @($results | Where-Object { $_.estado -like 'ANCLAS*' -or $_.estado -like 'fallo*' }).Count

# Un fallo se reporta SIEMPRE, aun con -Quiet. Un parche que no aplico significa
# que el gate quedo corriendo sin sentinel; enterarse tarde es el peor caso, y
# -Quiet existe para silenciar el ruido de exito, no las fallas.
if ($broken -gt 0) {
    $results | Format-Table -AutoSize | Out-String | Write-Host
    Write-Host "[!] SummonAI Kit sentinel: $broken hook(s) sin parchar - el gate corre SIN sentinel." -ForegroundColor Yellow
}
elseif (-not $Quiet -and $changed -gt 0) {
    $results | Format-Table -AutoSize | Out-String | Write-Host
    Write-Host "[OK] SummonAI Kit sentinel re-aplicado en $changed hook(s)." -ForegroundColor Green
}

exit 0
