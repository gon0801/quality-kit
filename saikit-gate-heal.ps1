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
  lanzar un proceso por archivo) hace tres cosas: (1) escribe una linea CON
  TIMESTAMP en harness-evidence.log, de auditoria; (2) en el cierre limpio
  emite el campo systemMessage del contrato de hooks de Claude Code, que se
  muestra AL USUARIO al final del MISMO turno sin tocar la decision -- el
  canal inmediato; y (3) guarda el aviso en su PROPIO archivo por PROYECTO
  (no en harness-evidence.log, que start_harness reescribe con '>' al armar
  el turno siguiente y lo perderia justo cuando hace falta mostrarlo). El
  PROXIMO turno que se arme lee ese archivo, ANTEPONE el aviso al contrato
  inyectado (el canal hookSpecificOutput/additionalContext que el hook ya usa
  para el contrato -- additional_context en cursor) y lo borra en el momento,
  para que no se repita en el turno de despues. Asi el aviso llega a la
  conversacion real -- al usuario en el momento, y al modelo del proximo
  turno armado -- no solo a un log que nadie lee. Tambien agrega una linea al
  contrato en si, para que el recibo final (linea Close) tenga que declarar
  si se toco codigo despues del reviewer.
  Ver el detalle en las anclas RN-* mas abajo.

  POR QUE SE RE-APLICA EN CADA ARRANQUE
  `summonaikit install` / `/saikit-update` reescriben el hook desde cero y se
  llevan el parche. Este script es idempotente: si el marcador ya esta, no hace
  nada; si el kit se actualizo, vuelve a parchar. Mismo patron que session-heal.ps1
  usa para claude-mem.

  Vive en quality-kit (no en ~/.claude/hooks) justamente para que un install del
  kit no pueda borrarlo.

  CONVIVENCIA CON summonaikit-claude (su Task 2.3 + consolidacion Task 4.1)
  Ese repo adopto el hook de .claude y lo instala por REEMPLAZO: escribe el
  archivo entero desde su propia fuente, que YA trae los dos parches adentro,
  con el marcador de propiedad en la linea 2. Durante la adopcion (Task 2.3)
  este script seguia iterando .claude como target y lo SALTEABA por el marcador
  para no pisar al otro escritor. Dias en verde despues, la Task 4.1 retiro
  .claude del vector $targets de abajo: ya no se itera, y la superficie de doble
  escritor sobre la misma ruta deja de existir. .codex / .cursor / .agents si
  siguen parcheando.

  El skip por marcador (`# SAIKIT-CLAUDE-OWNED ...`) se CONSERVA como red de
  seguridad: si algun .codex/.cursor/.agents llegara a portar el marcador (por
  ejemplo una copia manual), se saltea entero sin evaluar anclas. En produccion
  ningun target restante lo porta, asi que $skippedOwned casi siempre queda
  vacio -- lo que importa es que ante una senal de propiedad, el escritor por
  anclas se abstiene. El criterio sigue siendo mas ancho que el del instalador
  del otro repo (marcador en CUALQUIER linea, no solo la 2): ante una senal
  ambigua, abstenerse es la unica opcion segura.

  REGISTRO DEL HOOK (Task 0.3 del mismo repo, cableada aca)
  Todo lo que este script mira es CONTENIDO. El modo de falla mas silencioso es
  el otro: settings.json deja de nombrar al hook y el gate no existe, con el
  archivo intacto. `check-hook-registration.sh` verifica eso, y este es el unico
  script propio que ya corre en cada SessionStart -- por eso se cablea aca.
  Advisory puro: nunca mueve el exit code.

  USO
    powershell -ExecutionPolicy Bypass -File saikit-gate-heal.ps1
    powershell -ExecutionPolicy Bypass -File saikit-gate-heal.ps1 -Check
    powershell -ExecutionPolicy Bypass -File saikit-gate-heal.ps1 -RegistrationCheck <path>
#>
[CmdletBinding()]
param(
    [switch]$Check,
    [switch]$Quiet,
    # Ruta a check-hook-registration.sh. Vacio = se busca en los candidatos
    # declarados en Invoke-RegistrationCheck. Existe para que una bateria pueda
    # apuntar a su propio fixture en vez del verificador real.
    [string]$RegistrationCheck = '',

    # Tope para el verificador del registro. Es el unico proceso externo que
    # este script lanza, y corre en cada SessionStart (cuyo propio timeout son
    # 30 s): 15 deja margen de sobra para un chequeo que tarda menos de 1 s, y
    # corta antes de comerse el arranque. 0 = sin tope (no recomendado).
    [int]$RegistrationTimeoutSec = 15
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

# Marcador de propiedad de summonaikit-claude (su Task 2.1). Ver CONVIVENCIA en
# el header: un archivo que lo lleve es de ESE repo y no se toca aca.
$OWNERSHIP_MARKER_PREFIX = '# SAIKIT-CLAUDE-OWNED '

function ToLf([string]$s) { return ($s -replace "`r`n", "`n") }

# Devuelve la linea del marcador de propiedad si el archivo lo lleva, o $null.
# Se compara por PREFIJO DE LINEA y Ordinal, no con -match sobre el texto
# entero: el marcador solo cuenta como declaracion de propiedad cuando ES la
# linea, no cuando aparece citado adentro de un comentario o de un heredoc.
function Get-OwnershipMarker {
    param([string]$Text)
    foreach ($line in ($Text -split "`n")) {
        $l = $line.TrimEnd("`r")
        if ($l.StartsWith($OWNERSHIP_MARKER_PREFIX, [System.StringComparison]::Ordinal)) {
            return $l
        }
    }
    return $null
}

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
#
# EL AVISO LLEGA A LA CONVERSACION, no solo al log (hallazgo ALTO 1 de la
# revision cruzada, 2026-08-08): cuando el Stop gate detecta la secuencia
# mala, guarda el aviso en su propio archivo (RN_PENDING_PATH, ver ancla
# RN-A). El PROXIMO turno que se arme lo lee, lo antepone al contrato que
# start_harness ya inyecta via hookSpecificOutput/additionalContext (o
# additional_context en cursor -- el mismo canal, ancla RN-H) y lo borra en
# el momento para que no se repita en el turno de despues.
# ============================================================================

# Ancla RN-A (achicada -- MEDIO 1 de la revision cruzada, 2026-08-08): antes
# usaba el CUERPO COMPLETO de write_state (13 lineas) solo como punto de
# insercion, asi que un cambio del vendor a CUALQUIER detalle interno de esa
# funcion (por ejemplo un sexto campo de estado) desarmaba el parche entero
# -- las 7 anclas de este segundo parche se evaluan en grupo, asi que una
# sola rota tumba a todas. Ahora es la sola linea de apertura, igual de unica
# en el hook, mismo estilo que las anclas del sentinel (anchorA arriba). El
# insert va ANTES de esa linea, no adentro: write_state en si queda
# exactamente como la trae el vendor, sin depender de su cuerpo para nada.
$anchorRnA = ToLf 'write_state() {'

# Ancla RN-B: la linea que calcula task_hash al arrancar el turno en
# start_harness. Se usa para resetear el contador de orden al inicio del
# turno (STATE_DIR persiste entre turnos), y para leer + borrar el aviso
# pendiente del turno anterior (RN_PENDING_PATH) apenas se puede, antes de
# que nada mas en el turno lo toque. Deliberadamente SOLO esta linea (no mas
# contexto pegado): es identica byte a byte en las 4 variantes instaladas
# (.claude/.codex/.cursor/.agents, confirmado), pese a que .codex ramifica
# justo despues de ella (modo -harness-lite).
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
# $missing ni el exit code -- y (2), dentro del cierre limpio, borrar
# tambien el contador de orden. Con el aviso viviendo en su propio archivo
# (RN_PENDING_PATH) desde el momento en que se detecta, $LOG_PATH ya NO hace
# falta conservarlo aca -- esta rama vuelve a ser la del vendor, sin
# condicionales nuevos (menos divergencia). Identica byte a byte en las 4
# variantes instaladas.
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

# Ancla RN-H (nueva -- ALTO 1 de la revision cruzada, 2026-08-08): la linea
# que escapa el contrato ya armado, justo antes de emitirlo. Aparece
# EXACTAMENTE una vez en las 4 variantes instaladas (verificado), identica
# byte a byte pese a que .codex arma $context por dos caminos distintos
# (harness_context / harness_context_lite) mas un bloque MODEL CHECK
# opcional en el medio -- los tres caminos convergen en esta linea antes de
# escapar, asi que anteponer el aviso pendiente justo aca cubre los tres sin
# tener que anclar cada rama por separado.
$anchorRnH = ToLf '  escaped="$(json_escape "$context")"'

$insertRnA = ToLf @'
# >>> SAIKIT-REVIEW-NOTICE v1 (parche local, re-aplicado por quality-kit/saikit-gate-heal.ps1) >>>
# ADVISORY-ONLY, NUNCA bloquea el turno: el gate de ceremonia de arriba solo
# comprueba que implementer/verifier/reviewer CORRIERON, no que el codigo
# entregado sea el mismo que se reviso -- el lider podia correr los tres
# subagentes y seguir editando despues, y eso quedaba invisible sin este
# parche. NO agrega motivos de bloqueo a $missing ni cambia ningun exit code.
#
# QUE HACE, en una frase: el Stop gate compara la ultima edicion de codigo
# contra la ultima corrida del reviewer (por NOMBRE de herramienta, sin git,
# sin lanzar un proceso por archivo -- limitacion declarada por escrito en la
# propia linea de log). Si detecta la secuencia mala: (1) una linea CON
# TIMESTAMP en harness-evidence.log, de auditoria; (2) el aviso se guarda en
# su PROPIO archivo (RN_PENDING_PATH) porque $LOG_PATH lo reescribe
# start_harness con '>' al armar el turno siguiente, y lo perderia justo
# cuando hace falta mostrarlo. El PROXIMO turno que se arme (ancla RN-B) lee
# ese archivo, lo antepone al contrato inyectado (ancla RN-H) y lo borra en
# el momento, para que no se repita en el turno de despues.
#
# RN_ORDER_PATH se deriva de STATE_PATH (no de STATE_DIR a secas) para
# heredar automaticamente cualquier sufijo de sesion que ya traiga (la
# variante .codex reescribe STATE_PATH por sesion via resolve_state_paths,
# ANTES de llegar aqui) -- sin esto, dos sesiones de Codex concurrentes en el
# mismo proyecto compartirian un solo contador y se contaminarian entre si.
#
# RN_PENDING_PATH, en cambio, va por PROYECTO a proposito (STATE_DIR, sin
# sufijo de sesion). Llavearlo por sesion perdia el aviso en silencio en la
# variante .codex: el Stop lo escribia bajo la clave de SU sesion y el turno
# siguiente (otra session_id -- otra corrida de la CLI, u otro id del host)
# lo buscaba bajo otra clave y no lo encontraba jamas (fallo observado en la
# bateria, codex NEW (a)). Por proyecto es seguro porque el contenido es una
# CADENA CONSTANTE: dos sesiones concurrentes escribiendo a la vez escriben
# bytes identicos, y que una sesion hermana del mismo proyecto vea el aviso
# es informacion verdadera, no contaminacion. Borde aceptado y documentado:
# el Stop de una sesion con secuencia limpia puede borrar el aviso pendiente
# de otra (el elif de mas abajo) -- para una senal advisory, preferible a
# perder la entrega entre sesiones.
RN_ORDER_PATH="${STATE_PATH%.env}-review-notice.env"
RN_PENDING_PATH="$STATE_DIR/review-notice-pending.log"

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
# sesgada hacia "es codigo". Normaliza separadores de Windows y mayusculas
# ANTES de clasificar, para que una ruta real de Windows (docs\imagen.png) o
# una extension en mayusculas (README.Md) no caigan del lado equivocado solo
# por como vino escrita.
#
# MEDIO 2 de la revision cruzada (2026-08-08): se suman extensiones de
# tracker/metadata (json/yaml/yml/toml) y lockfiles de dependencias -- pero
# SOLO cuando el nombre del archivo es evidentemente eso: un tracker
# (changelog/status/todo/tracker/version) o un lockfile real (cualquier
# *.lock, mas los nombres fijos que no terminan en .lock como
# package-lock.json). Deliberadamente NO se excluye json/yaml/toml en
# general: ese es el riesgo concreto de una exclusion mas ancha -- un .json
# de CONFIGURACION real (tsconfig.json, la config propia de una app) editado
# despues de revisar tiene que seguir avisando, y una exclusion por extension
# sola lo habria callado.
rn_is_noncode_path() {
  rn_path="$1"
  rn_norm="$(printf '%s' "$rn_path" | tr 'A-Z\134' 'a-z/')"
  rn_base="${rn_norm##*/}"
  case "$rn_norm" in
    *.md|*.txt|*.rst|*.adoc|*.markdown) return 0 ;;
    */docs/*|docs/*) return 0 ;;
    *.lock) return 0 ;;
  esac
  case "$rn_base" in
    package-lock.json|yarn.lock|pnpm-lock.yaml|composer.lock) return 0 ;;
    changelog.json|changelog.yaml|changelog.yml) return 0 ;;
    status.json|status.yaml|status.yml) return 0 ;;
    todo.json|todo.yaml|todo.yml) return 0 ;;
    *tracker*.json|*tracker*.yaml|*tracker*.yml|*tracker*.toml) return 0 ;;
    version.json|version.yaml|version.yml) return 0 ;;
  esac
  return 1
}

# Lee el aviso pendiente del turno anterior (si lo hay) y lo BORRA en el
# mismo paso, para que no se repita en el turno siguiente -- se llama desde
# la ancla RN-B, lo antes posible dentro del camino armado, antes de que
# nada mas lo toque. Fail-open: sin archivo, silencio.
rn_take_pending() {
  if [ ! -f "$RN_PENDING_PATH" ]; then return 0; fi
  cat "$RN_PENDING_PATH" 2>/dev/null || true
  rm -f "$RN_PENDING_PATH" 2>/dev/null || true
}
# <<< SAIKIT-REVIEW-NOTICE v1 <<<
write_state() {
'@

$insertRnB = ToLf @'
  task_hash="$(printf '%s' "$prompt_text" | cksum | awk '{print $1}')"
  # >>> SAIKIT-REVIEW-NOTICE v1 >>>
  # Reinicia el contador de orden; STATE_DIR (y por lo tanto RN_ORDER_PATH)
  # persiste entre turnos. El aviso pendiente del turno anterior (si lo hay)
  # se lee y se borra ACA, lo antes posible dentro del camino armado -- antes
  # de que write_state, el log o el contrato hagan nada mas (ancla RN-H mas
  # abajo antepone rn_pending_text al contrato ya armado).
  rm -f "$RN_ORDER_PATH" 2>/dev/null || true
  rn_pending_text="$(rn_take_pending)"
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
  # $missing ni cambia el exit code. Corre en CADA llamada al Stop gate (no
  # solo en el cierre limpio), asi que un ciclo de revision (gate fallido, el
  # agente sigue editando, Stop se llama de nuevo) siempre ve el estado MAS
  # RECIENTE: si la secuencia mala ya no esta (por ejemplo corrio el reviewer
  # de nuevo despues), el elif de abajo borra un aviso pendiente que hubiera
  # quedado desactualizado de un intento anterior del mismo turno. Postura de
  # fallo: si el contador no existe, no se puede leer, o trae basura no
  # numerica (los dos campos vacios), NO se toca nada -- ni se escribe ni se
  # borra (nunca ruido, nunca un falso "todo bien").
  rn_check_last_code_edit="$(rn_read_order last_code_edit)"
  rn_check_last_review="$(rn_read_order last_review)"
  case "$rn_check_last_code_edit" in ''|*[!0-9]*) rn_check_last_code_edit="" ;; esac
  case "$rn_check_last_review" in ''|*[!0-9]*) rn_check_last_review="" ;; esac
  rn_notice_fired=""
  if [ -n "$rn_check_last_code_edit" ] && [ -n "$rn_check_last_review" ] && [ "$rn_check_last_code_edit" -gt "$rn_check_last_review" ] 2>/dev/null; then
    rn_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
    printf '%s review-notice: code was edited after the last reviewer subagent run (tool-name signal only -- an edit made via a shell command, e.g. sed/heredoc/git apply, is NOT detected by this check).\n' "$rn_ts" >> "$LOG_PATH" 2>/dev/null || true
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    printf 'SAIKIT REVIEW NOTICE: in your previous turn, code was edited after the reviewer subagent last ran, and those edits were not reviewed.\n' > "$RN_PENDING_PATH" 2>/dev/null || true
    rn_notice_fired="1"
  elif [ -n "$rn_check_last_code_edit" ] || [ -n "$rn_check_last_review" ]; then
    rm -f "$RN_PENDING_PATH" 2>/dev/null || true
  fi
  # <<< SAIKIT-REVIEW-NOTICE v1 <<<
  if [ -z "$missing" ]; then
    # >>> SAIKIT-REVIEW-NOTICE v1 >>>
    rm -f "$RN_ORDER_PATH" 2>/dev/null || true
    # Canal INMEDIATO (ademas del pendiente que lee el turno siguiente): en un
    # cierre limpio donde el aviso disparo, se emite el campo systemMessage
    # del contrato de hooks de Claude Code -- documentado como universal, se
    # muestra AL USUARIO y no toca la decision (sin campo decision + exit 0 =
    # allow igual que siempre). Asi el usuario se entera al final del MISMO
    # turno, no recien cuando vuelva a armar -saikit en este proyecto. Solo
    # target no-cursor, el mismo criterio que ya usa emit_gate_failure (el
    # vendor emite JSON estilo Claude para todo lo que no es cursor). Si el
    # host ignorase este stdout en exit 0, el peor caso es el silencio de hoy
    # (fail-open); el pendiente del turno siguiente sigue existiendo igual.
    if [ "$rn_notice_fired" = "1" ] && [ "$TARGET" != "cursor" ]; then
      printf '{"systemMessage":"SAIKIT REVIEW NOTICE: code was edited after the reviewer subagent last ran in this turn; those edits were not re-reviewed. The next -saikit turn on this project will see this notice too. (Tool-name signal only -- edits made via shell commands are not detected.)"}\n'
    fi
    # <<< SAIKIT-REVIEW-NOTICE v1 <<<
    rm -f "$STATE_PATH" "$LOG_PATH" 2>/dev/null || true
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

$insertRnH = ToLf @'
  # >>> SAIKIT-REVIEW-NOTICE v1 >>>
  # Antepone el aviso pendiente del turno anterior (si lo hubo) al contrato
  # recien armado. rn_pending_text se leyo y se borro mas arriba (ancla
  # RN-B), antes de que nada mas lo tocara.
  if [ -n "$rn_pending_text" ]; then
    context="$rn_pending_text

$context"
  fi
  # <<< SAIKIT-REVIEW-NOTICE v1 <<<
  escaped="$(json_escape "$context")"
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
    @{ k = 'RN-H'; v = $anchorRnH; ins = $insertRnH }
)

# ============================================================================
# REGISTRO DEL HOOK — cableado de check-hook-registration.sh (ver el header).
#
# Advisory puro: nunca mueve el exit code de este script, igual que el resto.
# El verificador ya trae su propia politica de ruido (calla cuando el registro
# esta completo, dice `unknown` cuando no pudo mirar), asi que su salida se
# imprime tal cual y sin filtrar -- tambien con -Quiet: cuando habla es porque
# el gate no esta corriendo en alguna fase, y eso no es ruido de exito.
#
# NINGUN `unknown` de aca se calla bajo -Quiet (cross-review codex, 2026-08-10).
# La politica de "no repetir avisos en cada arranque" vale para el SKIP por
# propiedad, que pasa en cada arranque SANO; estos avisos son lo contrario --
# solo aparecen cuando algo ya se rompio (el verificador desaparecio, no hay
# bash, se colgo, murio). Silenciarlos justo en -Quiet, que es el modo con el
# que corre SessionStart, volveria "no se pudo mirar" indistinguible de "todo
# bien": exactamente lo que la Core Rule 2 del otro repo prohibe.
# ============================================================================
function Invoke-RegistrationCheck {
    param([string]$CheckerPath, [int]$TimeoutSec = 15)

    # Un solo lugar para la forma del aviso: los cuatro caminos que no pudieron
    # mirar dicen lo mismo y con la misma redaccion.
    $decirUnknown = {
        param($porQue)
        Write-Host "[i] SummonAI Kit: registro del hook: unknown - $porQue (no se afirma que el registro falte: no se pudo mirar)." -ForegroundColor DarkGray
    }

    $claudeDir = Join-Path $env:USERPROFILE '.claude'
    $settings = Join-Path $claudeDir 'settings.json'
    $localSettings = Join-Path $claudeDir 'settings.local.json'

    # Sin NINGUNO de los dos settings no hay registro que verificar: no es un
    # perfil con el gate desregistrado, es un perfil que no existe. Callar aca
    # es ademas lo que mantiene a la bateria del kit -- cuyos fake homes no
    # tienen settings — libre de ruido y sin depender de este cableado.
    if (-not (Test-Path -LiteralPath $settings) -and -not (Test-Path -LiteralPath $localSettings)) {
        return
    }

    $checker = $CheckerPath
    if (-not $checker) {
        # 1) junto al hook, si alguna vez se instala ahi; 2) el repo que lo
        # mantiene. La env var existe para no clavar la ruta de una maquina.
        $repo = if ($env:SAIKIT_CLAUDE_REPO) { $env:SAIKIT_CLAUDE_REPO } else { 'C:\dev\summonaikit-claude' }
        foreach ($c in @(
            (Join-Path $claudeDir 'hooks\check-hook-registration.sh'),
            (Join-Path $repo 'tools\check-hook-registration.sh')
        )) {
            if (Test-Path -LiteralPath $c) { $checker = $c; break }
        }
    }

    # Core Rule 2 del repo del verificador: no haber podido mirar NO es haber
    # visto que el registro falta. Se reporta unknown y nunca ausencia.
    if (-not $checker -or -not (Test-Path -LiteralPath $checker)) {
        & $decirUnknown "no se encontro check-hook-registration.sh"
        return
    }

    $bash = $null
    $viaPath = Get-Command bash -ErrorAction SilentlyContinue
    if ($null -ne $viaPath) {
        $bash = $viaPath.Source
    } else {
        foreach ($c in @(
            (Join-Path $env:ProgramFiles 'Git\bin\bash.exe'),
            (Join-Path $env:ProgramFiles 'Git\usr\bin\bash.exe')
        )) {
            if (Test-Path -LiteralPath $c) { $bash = $c; break }
        }
    }
    if ($null -eq $bash) {
        & $decirUnknown "no hay bash para correr el verificador"
        return
    }

    # Con proceso propio y no con `& $bash ...` por dos razones, las dos de la
    # revision cruzada del 2026-08-10:
    #
    #   1. TOPE DE TIEMPO. Este script corre en CADA SessionStart y hasta ahora
    #      no lanzaba ningun proceso externo. Ahora lanza bash, que lanza
    #      python: si cualquiera de los dos se cuelga, se come el presupuesto
    #      del arranque. Mismo motivo por el que cross-review.ps1 tiene
    #      -TimeoutSec desde un cuelgue real (2026-07-05). Los parches ya estan
    #      escritos cuando se llega aca, asi que cortar no pierde trabajo.
    #   2. EXIT CODE. Un exit != 0 de un ejecutable nativo NO lanza excepcion en
    #      PowerShell: con `&` y try/catch, un verificador que muere sin decir
    #      nada se perdia entero y el arranque quedaba en silencio, que es
    #      indistinguible de "el registro esta bien".
    #
    # Barras normales: la ruta viaja como argumento hacia un script de bash.
    $toSlash = { param($p) $p -replace '\\', '/' }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $bash
    $psi.Arguments = '"' + (& $toSlash $checker) + '" --settings "' + (& $toSlash $settings) + '"'
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    try {
        $proc.Start() | Out-Null
    }
    catch {
        & $decirUnknown "no se pudo lanzar el verificador ($($_.Exception.Message))"
        return
    }

    # Los dos streams se drenan en paralelo: leer uno hasta el final mientras el
    # hijo llena el buffer del otro (~4KB) es un deadlock clasico.
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $null = $proc.StandardError.ReadToEndAsync()
    $proc.StandardInput.Close()

    if ($TimeoutSec -gt 0) {
        if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
            # taskkill /T y no Kill(): mata tambien lo que cuelgue del proceso
            # que lanzamos (PS 5.1 no tiene Kill($true)).
            #
            # LIMITE MEDIDO Y DECLARADO (2026-08-10): un nieto lanzado por bash
            # de Git for Windows puede quedar HUERFANO -- medido, su padre ya
            # no existe cuando llega el kill, porque MSYS2 interpone su propia
            # capa de procesos -- y entonces ningun barrido por parentesco lo
            # alcanza. Ese huerfano sigue reteniendo los handles de stdout que
            # heredo, asi que quien LEE nuestra salida puede seguir esperando
            # aunque este script ya haya terminado. Lo que el tope garantiza es
            # lo que esta a nuestro alcance: dejar de esperar, decirlo, y salir.
            # El resto lo acota el timeout del propio SessionStart (30 s).
            # Cerrarlo del todo pedia Job Objects via P/Invoke, y ese costo no
            # se paga en un script que corre en cada arranque para cubrir un
            # cuelgue de un chequeo que tarda menos de un segundo.
            try {
                & taskkill.exe /T /F /PID $proc.Id 2>&1 | Out-Null
            }
            catch { }
            if (-not $proc.HasExited) {
                try { $proc.Kill() } catch { }
            }
            & $decirUnknown "el verificador no respondio en ${TimeoutSec}s y se lo corto"
            return
        }
    }
    else {
        $proc.WaitForExit()
    }

    if ($proc.ExitCode -ne 0) {
        # Su contrato es salir 0 SIEMPRE (fail-open). Que no lo cumpla significa
        # que no fue el verificador el que hablo -- bash no encontro el archivo,
        # el script esta roto, algo lo mato.
        & $decirUnknown "el verificador salio $($proc.ExitCode)"
        return
    }

    $out = $stdoutTask.Result
    if (-not [string]::IsNullOrWhiteSpace($out)) {
        Write-Host $out.TrimEnd()
    }
}

# .claude ya no es target desde la Task 4.1: summonaikit-claude lo adopto por
# REEMPLAZO (instala el archivo entero, con marcador de propiedad y los dos
# parches adentro -- ver CONVIVENCIA arriba). Sacarlo de aca vuelve explicita la
# no-escritura y elimina la superficie de doble escritor en cada SessionStart.
# .codex / .cursor / .agents SI siguen parcheandose por anclas.
$targets = @('.codex', '.cursor', '.agents') |
    ForEach-Object { Join-Path $env:USERPROFILE (Join-Path $_ 'hooks\summonaikit-harness.sh') }

$results = @()
$skippedOwned = @()

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

    # El skip por propiedad va ANTES que cualquier evaluacion de anclas: un
    # archivo de summonaikit-claude no tiene por que traer las anclas del
    # vendor, y reportar "ANCLAS-CAMBIARON" sobre el seria una alarma falsa
    # perpetua sobre un archivo que jamas se va a parchar aca.
    $owner = Get-OwnershipMarker -Text $lf
    if ($null -ne $owner) {
        $results += [pscustomobject]@{ hook = $short; sentinel = 'saltado-propiedad'; reviewnotice = 'saltado-propiedad' }
        $skippedOwned += "$short  ->  $owner"
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
elseif (-not $Quiet -and ($changed -gt 0 -or $skippedOwned.Count -gt 0)) {
    $results | Format-Table -AutoSize | Out-String | Write-Host
    if ($changed -gt 0) {
        Write-Host "[OK] SummonAI Kit: parches re-aplicados en $changed hook(s)." -ForegroundColor Green
    }
}

# El salto por propiedad se DICE, no se deduce de la tabla: Format-Table recorta
# las columnas al ancho de la consola y la linea del marcador -- que es el dato
# diagnostico -- es justo lo que se perderia.
#
# Solo sin -Quiet. Antes de la Task 4.1 el salto era el estado NORMAL de cada
# arranque (.claude, marcado, se saltaba en cada SessionStart sano); desde que
# .claude dejo de ser target, el skip ya no es el estado normal -- ningun target
# restante porta el marcador en produccion, asi que esto casi nunca se dispara.
# Se conserva la politica de callarlo bajo -Quiet de todos modos: si algun dia
# un .codex/.cursor/.agents marcado lo dispara, repetirlo en cada arranque seria
# ruido. A mano o con -Check se ve entero. Lo que NO depende de -Quiet es un
# parche sin aplicar: eso sigue gritando arriba.
if (-not $Quiet) {
    foreach ($s in $skippedOwned) {
        Write-Host "[i] SummonAI Kit: saltado, lo maneja summonaikit-claude (instala el archivo entero, con los dos parches adentro): $s" -ForegroundColor Cyan
    }
}

Invoke-RegistrationCheck -CheckerPath $RegistrationCheck -TimeoutSec $RegistrationTimeoutSec

exit 0
