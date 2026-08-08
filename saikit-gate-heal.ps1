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

  SEGUNDO PARCHE, INDEPENDIENTE: SAIKIT-REVIEW-NOTICE v1
  El gate de ceremonia de arriba solo comprueba que implementer/verifier/reviewer
  CORRIERON, no que el codigo entregado sea el que se reviso -- el lider podia
  correr los tres subagentes y despues seguir editando, y eso quedaba invisible.
  Este segundo parche es puramente ADVISORY: nunca bloquea, nunca agrega un exit
  code nuevo. Cuando el Stop gate detecta que hubo una edicion de codigo despues
  de la ultima corrida del reviewer (por nombre de herramienta, sin git, sin
  lanzar un proceso por archivo) escribe una linea en harness-evidence.log que
  declara su propia limitacion, y sigue de largo. Tambien agrega una linea al
  contrato que el hook inyecta al armar el turno, para que el recibo final
  (linea Close) tenga que declarar si se toco codigo despues del reviewer.
  Ver el detalle en las anclas RN-* mas abajo.

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

# SAIKIT-REVIEW-NOTICE v1: marcador propio, separado del sentinel de arriba, para
# poder diagnosticar cual de los dos parches fallo. Es su propia pasada, sobre el
# mismo texto en memoria, con su propio chequeo de anclas -- si las anclas de este
# parche cambian (el kit actualizo esa zona del hook), el sentinel se sigue
# aplicando igual, y viceversa. Ver Invoke-SinglePatch mas abajo.
$MARKER2 = 'SAIKIT-REVIEW-NOTICE v1'

function ToLf([string]$s) { return ($s -replace "`r`n", "`n") }

# Cuenta ocurrencias literales (Ordinal, sin regex: las anclas traen $, (, ) y
# corchetes que un -match interpretaria).
function Get-LiteralCount {
    param([string]$Haystack, [string]$Needle)
    if ([string]::IsNullOrEmpty($Needle)) { return 0 }
    $count = 0
    $i = 0
    while (($i = $Haystack.IndexOf($Needle, $i, [System.StringComparison]::Ordinal)) -ge 0) {
        $count++
        $i += $Needle.Length
    }
    return $count
}

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

# ============================================================================
# SAIKIT-REVIEW-NOTICE v1 -- anclas y reemplazos (segundo parche, independiente
# del sentinel de arriba: aplica en una segunda pasada sobre el MISMO texto en
# memoria, con su propio marcador y su propio chequeo de anclas 1/1).
#
# DISENO, en una frase: un contador monotonico de eventos de herramienta del
# turno (su propio archivo, derivado de STATE_PATH para heredar automaticamente
# cualquier sufijo de sesion que una variante del hook ya le aplique -- la
# variante .codex asigna un STATE_PATH distinto por sesion via
# resolve_state_paths, y esto se resuelve solo sin tener que conocer esa
# funcion) mas EN QUE evento paso la ultima edicion de codigo y la ultima
# corrida del reviewer. La deteccion de edicion es por NOMBRE de herramienta
# (tool_name en una lista blanca de edicion, MAS file_path) -- deliberadamente
# NO por git ni lanzando un proceso por archivo, por pedido explicito. La
# limitacion que eso implica (una edicion hecha por shell -- sed, un heredoc,
# git apply -- no se ve) se declara por escrito en la linea que se agrega al
# log de evidencia, no solo en este comentario.
# ============================================================================

# Ancla RN-A: la funcion write_state completa. Punto de insercion para el
# contador y sus helpers -- se ubica antes de start_harness Y de
# record_tool_evidence en el archivo pristino, asi que quedan definidos antes
# de que cualquiera de las dos los use.
$anchorRnA = ToLf @'
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
'@

# Ancla RN-B: la linea que calcula task_hash al arrancar el turno en
# start_harness. Se usa para resetear el contador de orden al inicio del
# turno (STATE_DIR persiste entre turnos). Deliberadamente SOLO esta linea
# (no mas contexto pegado): es identica byte a byte en las 4 variantes
# instaladas (.claude/.codex/.cursor/.agents, confirmado), pese a que .codex
# ramifica justo despues de ella (modo -harness-lite).
$anchorRnB = ToLf @'
  task_hash="$(printf '%s' "$prompt_text" | cksum | awk '{print $1}')"
'@

# Ancla RN-C: el bloque que registra el subagente en record_tool_evidence.
# Se usa para (1) avanzar el contador en cada evento de herramienta y (2)
# marcar last_review cuando el subagente que corrio es el reviewer.
$anchorRnC = ToLf @'
  subagent="$(json_string_field subagent_type)"
  if [ -z "$subagent" ]; then subagent="$(json_string_field subagentType)"; fi
  if [ -n "$subagent" ]; then record_agent "$subagent"; fi
'@

# Ancla RN-D: el bloque existente que marca "implemented" con la senal laxa
# (grep sobre $combined, que incluye el $INPUT crudo). Se ancla aqui solo para
# insertar la deteccion PRECISA justo despues (deliberadamente NO se reusa esa
# senal laxa para el orden: dispara con casi cualquier payload que mencione
# "edit" o una ruta).
$anchorRnD = ToLf @'
  if printf '%s' "$combined" | grep -Eiq 'afterFileEdit|Edit|Write|apply_patch|file_path|edits'; then
    mark_evidence "implemented" "${file_path:-file edit}"
  fi
'@

# Ancla RN-E: la cola de cierre limpio del Stop gate (cuando ya no falta
# nada). Se usa para (1) calcular el aviso ADVISORY justo antes -- nunca toca
# $missing ni el exit code -- y (2) conservar el log de evidencia cuando el
# aviso se disparo, para que la linea siga siendo legible despues de que el
# proceso termine (por defecto el cierre limpio borra ese log igual que el
# archivo de estado). Identica byte a byte en las 4 variantes instaladas.
$anchorRnE = ToLf @'
  if [ -z "$missing" ]; then
    rm -f "$STATE_PATH" "$LOG_PATH" 2>/dev/null || true
    emit_allow
  fi
'@

# Ancla RN-F: el bloque "Close:/Retro:" del contrato que start_harness inyecta
# (harness_context), tal como el hook lo escribe HOY. Ancla CHICA a proposito
# (dos lineas, no el heredoc entero) y con el Retro exacto de harness_context
# -- lo que la distingue del Retro de harness_context_lite en .codex (RN-G),
# que trae otra redaccion. Aparece exactamente 1 vez en las 4 copias
# instaladas (verificado: incluida .codex, que solo la trae en harness_context,
# no en harness_context_lite).
$anchorRnF = ToLf @'
Close: evidence summary and remaining gaps.
Retro: harness/codebase-memory improvement, or "none".
'@

# Ancla RN-G (SOLO .codex, opcional -- ver Invoke-ReviewNoticePatch): el mismo
# par Close/Retro dentro de harness_context_lite (modo "-harness-lite"), que
# .claude/.cursor/.agents no tienen. 0 ocurrencias ahi es el caso normal y NO
# se reporta como parche roto; en .codex debe ser exactamente 1.
$anchorRnG = ToLf @'
Close: evidence summary and remaining gaps.
Retro: improvement note, or "none".
'@

$insertRnA = ToLf @'
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

# >>> SAIKIT-REVIEW-NOTICE v1 (parche local, re-aplicado por quality-kit/saikit-gate-heal.ps1) >>>
# ADVISORY-ONLY, NUNCA bloquea el turno: el gate de ceremonia de arriba solo
# comprueba que implementer/verifier/reviewer CORRIERON, no que el codigo
# entregado sea el mismo que se reviso -- el lider podia correr los tres
# subagentes y seguir editando despues, y eso quedaba invisible. Este parche
# NO agrega motivos de bloqueo a $missing ni cambia ningun exit code: mas
# abajo, en el Stop gate, solo ESCRIBE una linea en el log de evidencia
# cuando detecta esa secuencia, y sigue de largo igual que si no existiera.
#
# RN_ORDER_PATH se deriva de STATE_PATH (no de STATE_DIR a secas) para
# heredar automaticamente cualquier sufijo de sesion que ya traiga (la
# variante .codex reescribe STATE_PATH por sesion via resolve_state_paths,
# ANTES de llegar aqui) -- sin esto, dos sesiones de Codex concurrentes en el
# mismo proyecto compartirian un solo contador y se contaminarian entre si.
RN_ORDER_PATH="${STATE_PATH%.env}-review-notice.env"

rn_read_order() {
  rn_key="$1"
  if [ ! -f "$RN_ORDER_PATH" ]; then return 0; fi
  grep "^$rn_key=" "$RN_ORDER_PATH" 2>/dev/null | tail -n 1 | cut -d= -f2-
}

rn_write_order() {
  rn_counter="$1"
  rn_last_code_edit="$2"
  rn_last_review="$3"
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  {
    printf 'counter=%s\n' "$rn_counter"
    printf 'last_code_edit=%s\n' "$rn_last_code_edit"
    printf 'last_review=%s\n' "$rn_last_review"
  } > "$RN_ORDER_PATH" 2>/dev/null || true
}

# Avanza el contador en uno y lo devuelve por stdout. Corre en CADA
# PostToolUse -- mismo costo que el resto de record_tool_evidence, que ya
# hace varias subshells por evento -- nunca itera archivos ni el repo.
rn_bump_counter() {
  rn_counter="$(rn_read_order counter)"
  rn_last_code_edit="$(rn_read_order last_code_edit)"
  rn_last_review="$(rn_read_order last_review)"
  case "$rn_counter" in ''|*[!0-9]*) rn_counter=0 ;; esac
  rn_counter=$((rn_counter + 1))
  rn_write_order "$rn_counter" "$rn_last_code_edit" "$rn_last_review"
  printf '%s' "$rn_counter"
}

rn_mark_code_edit() {
  rn_counter="$(rn_read_order counter)"
  rn_last_review="$(rn_read_order last_review)"
  rn_write_order "$rn_counter" "$1" "$rn_last_review"
}

rn_mark_review() {
  rn_counter="$(rn_read_order counter)"
  rn_last_code_edit="$(rn_read_order last_code_edit)"
  rn_write_order "$rn_counter" "$rn_last_code_edit" "$1"
}

# Clasificacion codigo vs no-codigo para la senal de orden, deliberadamente
# sesgada hacia "es codigo" (solo extensiones de texto/documentacion y una
# carpeta docs/ quedan afuera). Normaliza separadores de Windows y mayusculas
# ANTES de clasificar, para que una ruta real de Windows (docs\imagen.png) o
# una extension en mayusculas (README.Md) no caigan del lado equivocado solo
# por como vino escrita.
rn_is_noncode_path() {
  rn_path="$1"
  rn_norm="$(printf '%s' "$rn_path" | tr 'A-Z\134' 'a-z/')"
  case "$rn_norm" in
    *.md|*.txt|*.rst|*.adoc|*.markdown) return 0 ;;
    */docs/*|docs/*) return 0 ;;
  esac
  return 1
}
# <<< SAIKIT-REVIEW-NOTICE v1 <<<
'@

$insertRnB = ToLf @'
  task_hash="$(printf '%s' "$prompt_text" | cksum | awk '{print $1}')"
  # >>> SAIKIT-REVIEW-NOTICE v1 >>>
  # Reinicia el contador de orden; STATE_DIR (y por lo tanto RN_ORDER_PATH)
  # persiste entre turnos.
  rm -f "$RN_ORDER_PATH" 2>/dev/null || true
  # <<< SAIKIT-REVIEW-NOTICE v1 <<<
'@

$insertRnC = ToLf @'
  subagent="$(json_string_field subagent_type)"
  if [ -z "$subagent" ]; then subagent="$(json_string_field subagentType)"; fi
  if [ -n "$subagent" ]; then record_agent "$subagent"; fi
  # >>> SAIKIT-REVIEW-NOTICE v1 >>>
  rn_order_now="$(rn_bump_counter)"
  if [ -n "$subagent" ] && [ "$(canonical_agent_role "$subagent")" = "reviewer" ]; then
    rn_mark_review "$rn_order_now"
  fi
  # <<< SAIKIT-REVIEW-NOTICE v1 <<<
'@

$insertRnD = ToLf @'
  if printf '%s' "$combined" | grep -Eiq 'afterFileEdit|Edit|Write|apply_patch|file_path|edits'; then
    mark_evidence "implemented" "${file_path:-file edit}"
  fi

  # >>> SAIKIT-REVIEW-NOTICE v1 >>>
  # Senal PRECISA para el orden, distinta del grep laxo de arriba (ese matchea
  # casi cualquier payload que mencione "edit" o una ruta). Solo cuenta un
  # tool_name realmente de edicion MAS un file_path real; sin ambos, no se
  # registra nada -- mejor perder una edicion que fecharla mal. Por diseno
  # (pedido explicito) esta senal NUNCA lanza git ni un proceso por archivo:
  # es solo el nombre de la herramienta del evento que el hook ya recibe.
  if [ -n "$file_path" ] && printf '%s' "$tool_name" | grep -Eiq '^(edit|write|multiedit|notebookedit|apply_patch|str_replace_editor|create_file|edit_file)$'; then
    if ! rn_is_noncode_path "$file_path"; then
      rn_mark_code_edit "$rn_order_now"
    fi
  fi
  # <<< SAIKIT-REVIEW-NOTICE v1 <<<
'@

$insertRnE = ToLf @'
  # >>> SAIKIT-REVIEW-NOTICE v1 >>>
  # Chequeo ADVISORY: compara el evento de la ultima edicion de codigo contra
  # el evento de la ultima corrida del reviewer. NUNCA agrega un motivo a
  # $missing ni cambia el exit code -- solo escribe una linea en el log de
  # evidencia cuando la secuencia se ve, y esa misma linea declara su propia
  # limitacion. Postura de fallo: si el contador no existe, no se puede leer,
  # o trae basura no numerica, NO se registra nada (nunca ruido, nunca
  # bloqueo).
  rn_notice_fired=""
  rn_check_last_code_edit="$(rn_read_order last_code_edit)"
  rn_check_last_review="$(rn_read_order last_review)"
  case "$rn_check_last_code_edit" in ''|*[!0-9]*) rn_check_last_code_edit="" ;; esac
  case "$rn_check_last_review" in ''|*[!0-9]*) rn_check_last_review="" ;; esac
  if [ -n "$rn_check_last_code_edit" ] && [ -n "$rn_check_last_review" ] && [ "$rn_check_last_code_edit" -gt "$rn_check_last_review" ] 2>/dev/null; then
    printf 'review-notice: code was edited after the last reviewer subagent run (tool-name signal only -- an edit made via a shell command, e.g. sed/heredoc/git apply, is NOT detected by this check).\n' >> "$LOG_PATH" 2>/dev/null || true
    rn_notice_fired="1"
  fi
  # <<< SAIKIT-REVIEW-NOTICE v1 <<<
  if [ -z "$missing" ]; then
    # >>> SAIKIT-REVIEW-NOTICE v1 >>>
    # El contador de orden se limpia siempre en un cierre limpio. El log de
    # evidencia se conserva SOLO cuando el aviso se disparo, para que la
    # linea de arriba siga siendo legible despues de que el proceso termine
    # -- si no se disparo, el cierre borra ambos archivos igual que siempre.
    rm -f "$RN_ORDER_PATH" 2>/dev/null || true
    if [ "$rn_notice_fired" = "1" ]; then
      rm -f "$STATE_PATH" 2>/dev/null || true
    else
      rm -f "$STATE_PATH" "$LOG_PATH" 2>/dev/null || true
    fi
    # <<< SAIKIT-REVIEW-NOTICE v1 <<<
    emit_allow
  fi
'@

$insertRnF = ToLf @'
Close: evidence summary and remaining gaps; state explicitly whether code was touched after the reviewer subagent last ran (yes/no).
Retro: harness/codebase-memory improvement, or "none".
'@

$insertRnG = ToLf @'
Close: evidence summary and remaining gaps; state explicitly whether code was touched after the reviewer subagent last ran (yes/no).
Retro: improvement note, or "none".
'@

# Aplica UN parche (marcador + set de anclas nombradas + inserts) sobre texto
# ya normalizado a LF. Devuelve @{ estado; texto } sin tocar disco -- el
# llamador decide cuando escribir, para que varios parches puedan aplicarse en
# secuencia sobre el MISMO contenido en memoria y el archivo se escriba una
# sola vez por hook.
function Invoke-SinglePatch {
    param(
        [string]$Text,
        [string]$Marker,
        [hashtable[]]$Anchors,
        [switch]$CheckOnly
    )
    if ($Text.Contains($Marker)) {
        return @{ estado = 'ya-parchado'; texto = $Text }
    }
    $bad = @()
    foreach ($anchor in $Anchors) {
        $n = Get-LiteralCount -Haystack $Text -Needle $anchor.v
        if ($n -ne 1) { $bad += "$($anchor.k)=$n" }
    }
    if ($bad.Count -gt 0) {
        return @{ estado = "ANCLAS-CAMBIARON ($($bad -join ',')) - revisar a mano"; texto = $Text }
    }
    if ($CheckOnly) {
        return @{ estado = 'sin-parchar (falta aplicar)'; texto = $Text }
    }
    $out = $Text
    foreach ($anchor in $Anchors) {
        $out = $out.Replace($anchor.v, $anchor.ins)
    }
    return @{ estado = 'PARCHADO'; texto = $out }
}

# Igual que Invoke-SinglePatch, mas un bonus best-effort: la ancla RN-G (el
# contrato "-harness-lite" que SOLO .codex tiene) se aplica UNICAMENTE cuando
# aparece exactamente 1 vez. 0 veces es el caso normal en .claude/.cursor/
# .agents (no tienen modo lite) y NO se reporta como parche roto -- 2+ veces
# tambien se saltea en silencio en vez de tumbar el parche CORE por una
# refinacion opcional que solo afecta una linea de forma del recibo.
function Invoke-ReviewNoticePatch {
    param(
        [string]$Text,
        [switch]$CheckOnly
    )
    $core = Invoke-SinglePatch -Text $Text -Marker $MARKER2 -Anchors $reviewNoticeCoreAnchors -CheckOnly:$CheckOnly
    if ($core.estado -ne 'PARCHADO') {
        return $core
    }
    $liteCount = Get-LiteralCount -Haystack $core.texto -Needle $anchorRnG
    if ($liteCount -eq 1) {
        $core.texto = $core.texto.Replace($anchorRnG, $insertRnG)
    }
    return $core
}

$sentinelAnchors = @(
    @{ k = 'A'; v = $anchorA; ins = $insertA }
    @{ k = 'B'; v = $anchorB; ins = $insertB }
    @{ k = 'C'; v = $anchorC; ins = $insertC }
)
$reviewNoticeCoreAnchors = @(
    @{ k = 'RN-A'; v = $anchorRnA; ins = $insertRnA }
    @{ k = 'RN-B'; v = $anchorRnB; ins = $insertRnB }
    @{ k = 'RN-C'; v = $anchorRnC; ins = $insertRnC }
    @{ k = 'RN-D'; v = $anchorRnD; ins = $insertRnD }
    @{ k = 'RN-E'; v = $anchorRnE; ins = $insertRnE }
    @{ k = 'RN-F'; v = $anchorRnF; ins = $insertRnF }
)

$targets = @('.claude', '.codex', '.cursor', '.agents') |
    ForEach-Object { Join-Path $env:USERPROFILE (Join-Path $_ 'hooks\summonaikit-harness.sh') }

$results = @()

foreach ($path in $targets) {
    $short = $path.Replace($env:USERPROFILE, '~')

    if (-not (Test-Path $path)) {
        $results += [pscustomobject]@{ hook = $short; sentinel = 'no-instalado'; reviewnotice = 'no-instalado' }
        continue
    }

    try {
        $lf = ToLf ([System.IO.File]::ReadAllText($path))
    }
    catch {
        $err = "ilegible: $($_.Exception.Message)"
        $results += [pscustomobject]@{ hook = $short; sentinel = $err; reviewnotice = $err }
        continue
    }

    # Cada ancla debe aparecer EXACTAMENTE una vez (0 -> el kit cambio su codigo
    # y el parche ya no aplica; 2+ -> String.Replace reemplazaria TODAS y el
    # parche se inyectaria duplicado). Se comprueba en vez de asumirse -- hallazgo
    # de la revision cruzada de kimi, 2026-08-03 -- y se reporta fuerte en vez de
    # fallar en silencio: un parche que no aplico es un gate apagado.
    #
    # Los dos parches se evaluan y aplican de forma INDEPENDIENTE sobre el mismo
    # texto en memoria: que a uno le falle el chequeo de anclas (por ejemplo un
    # fixture sintetico que solo trae media firma del hook, o un update del kit
    # que movio una sola zona) no debe impedir que el otro se aplique. Cada
    # funcion de parche devuelve el texto SIN TOCAR cuando no aplica (ya
    # parchado o anclas rotas), asi que encadenarlas siempre da el resultado
    # correcto de a cual(es) SI se les pudo aplicar el parche.
    $r1 = Invoke-SinglePatch -Text $lf -Marker $MARKER -Anchors $sentinelAnchors -CheckOnly:$Check
    $r2 = Invoke-ReviewNoticePatch -Text $r1.texto -CheckOnly:$Check

    $sentinelEstado = $r1.estado
    $reviewNoticeEstado = $r2.estado
    $results += [pscustomobject]@{ hook = $short; sentinel = $sentinelEstado; reviewnotice = $reviewNoticeEstado }

    if ($Check) { continue }
    if ($sentinelEstado -ne 'PARCHADO' -and $reviewNoticeEstado -ne 'PARCHADO') {
        # Nada que escribir: ya-parchado y/o ANCLAS-CAMBIARON en ambos, el texto
        # final es identico al leido.
        continue
    }

    try {
        # LF + UTF8 sin BOM: bash no tolera BOM en el shebang. Una sola escritura
        # por hook aunque ambos parches hayan cambiado el contenido.
        [System.IO.File]::WriteAllText($path, $r2.texto, (New-Object System.Text.UTF8Encoding($false)))
    }
    catch {
        $err = "fallo al escribir: $($_.Exception.Message)"
        $results[-1] = [pscustomobject]@{ hook = $short; sentinel = $err; reviewnotice = $err }
    }
}

$changed = @($results | Where-Object { $_.sentinel -eq 'PARCHADO' -or $_.reviewnotice -eq 'PARCHADO' }).Count
$broken = @($results | Where-Object { $_.sentinel -like 'ANCLAS*' -or $_.sentinel -like 'fallo*' -or $_.reviewnotice -like 'ANCLAS*' -or $_.reviewnotice -like 'fallo*' }).Count

# Un fallo se reporta SIEMPRE, aun con -Quiet. Un parche que no aplico significa
# que el gate quedo corriendo sin sentinel y/o sin el aviso de revision;
# enterarse tarde es el peor caso, y -Quiet existe para silenciar el ruido de
# exito, no las fallas.
if ($broken -gt 0) {
    $results | Format-Table -AutoSize | Out-String | Write-Host
    Write-Host "[!] SummonAI Kit: $broken hook(s) con al menos un parche sin aplicar - revisar arriba cual (sentinel / reviewnotice)." -ForegroundColor Yellow
}
elseif (-not $Quiet -and $changed -gt 0) {
    $results | Format-Table -AutoSize | Out-String | Write-Host
    Write-Host "[OK] SummonAI Kit: parches re-aplicados en $changed hook(s)." -ForegroundColor Green
}

exit 0
