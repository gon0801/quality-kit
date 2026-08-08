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

# SAIKIT-REVIEW-ORDER v1 (separate marker, own set of anchors, applied as a
# second independent pass below): the ceremony gate above only checks that
# implementer/verifier/reviewer subagents ran at some point (agents_seen is a
# deduped SET, no real order). That let the lead run the three subagents and
# then keep editing code on its own afterward -- the turn still closed, and
# the last thing touched was the least reviewed. This patch adds a monotonic
# per-turn event counter (its own file, not a field on harness-state.env,
# which has a fixed 5-field format other pieces parse) so the Stop gate can
# tell whether code was edited AFTER the last reviewer run, not just whether a
# reviewer ran ever. Kept as its own marker so a failed patch reports for
# exactly this piece and not the sentinel gate.
$MARKER2 = 'SAIKIT-REVIEW-ORDER v1'

# ADENDA (revision cruzada independiente, hueco ALTO reproducido en vivo): la
# senal original de arriba miraba el NOMBRE de la herramienta (tool_name en
# la lista blanca edit/write/multiedit/... mas file_path) -- evadible por
# CUALQUIER edicion hecha via Bash (sed -i, heredoc, cat >, git apply, patch,
# mv, cp, un script), que no trae ninguno de los dos campos. El chequeo
# PRIMARIO en el Stop gate ahora es una huella real del arbol de trabajo,
# tomada cuando el reviewer corre y recalculada en el Stop gate
# (compute_code_fingerprint, mas abajo): mide el estado del repo, no la
# ceremonia de que herramienta lo toco. La senal vieja por nombre de
# herramienta queda como respaldo, para cuando no hay git disponible.

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
# SAIKIT-REVIEW-ORDER v1 -- anclas y reemplazos (segundo parche, independiente
# del sentinel de arriba: se aplica en una segunda pasada mas abajo, sobre el
# mismo archivo, con su propio marcador y su propio chequeo de anclas 1/1/1).
# ============================================================================

# Ancla RO-B: la funcion write_state completa. Punto de insercion para el
# archivo/funciones del contador de orden -- se ubica antes de start_harness Y
# de record_tool_evidence en el archivo pristino, asi que ORDER_PATH y sus
# helpers quedan definidos antes de que cualquiera de las dos los use.
$anchorRoB = ToLf @'
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

# Ancla RO-C: la linea que calcula task_hash al arrancar el turno en
# start_harness. Se usa para resetear el contador de orden al inicio del
# turno, porque STATE_DIR persiste entre turnos (solo se borra al cerrar
# limpio). Deliberadamente SOLO esta linea (no task_hash+write_state pegados
# como antes): la variante .codex del hook mete una rama -harness-lite entre
# ambas (dos write_state distintos, uno por rama) que partia ese par en dos y
# dejaba esta ancla en 0 ocurrencias solo ahi. Esta linea sola SI es identica
# byte a byte en las 4 variantes instaladas (.claude/.codex/.cursor/.agents,
# confirmado), asi que el reset ahora encaja en las 4 sin variante especial.
$anchorRoC = ToLf @'
  task_hash="$(printf '%s' "$prompt_text" | cksum | awk '{print $1}')"
'@

# Ancla RO-D: el bloque que registra el subagente en record_tool_evidence.
# Se usa para (1) avanzar el contador en cada evento de herramienta y (2)
# marcar last_review cuando el subagente que corrio es el reviewer.
$anchorRoD = ToLf @'
  subagent="$(json_string_field subagent_type)"
  if [ -z "$subagent" ]; then subagent="$(json_string_field subagentType)"; fi
  if [ -n "$subagent" ]; then record_agent "$subagent"; fi
'@

# Ancla RO-E: el bloque existente que marca "implemented" con la senal laxa
# (grep sobre $combined, que incluye el $INPUT crudo). Deliberadamente NO se
# reusa esa senal para el orden -- ver comentario en el insert. Se ancla aqui
# solo para insertar la deteccion PRECISA justo despues.
$anchorRoE = ToLf @'
  if printf '%s' "$combined" | grep -Eiq 'afterFileEdit|Edit|Write|apply_patch|file_path|edits'; then
    mark_evidence "implemented" "${file_path:-file edit}"
  fi
'@

# Ancla RO-F: la cola del bloque de enforcement secuencial de subagentes en el
# Stop gate -- el chequeo de orden agents_seen mas los dos "fi" que lo cierran
# (el interno y el que cierra "if $TARGET = claude"). Se usa para agregar el
# motivo de fallo por edicion-despues-de-review justo despues, antes del
# "if [ -z "$missing" ]". Deliberadamente SOLO esta cola (no el bloque
# "if $TARGET = claude" completo como antes): la variante .codex mete texto
# "ROLE FALLBACK" dentro de cada rama case de ese bloque, asi que el bloque
# entero no matcheaba ahi (0 ocurrencias). Esta cola de 5 lineas SI es
# identica byte a byte en las 4 variantes instaladas (confirmado), y el punto
# de insercion (justo despues del "fi" que cierra "if $TARGET = claude") es
# el mismo de antes -- el chequeo de orden sigue corriendo fuera de esa rama,
# sin importar $TARGET, igual que en el diseño original.
$anchorRoF = ToLf @'
    if printf '%s' "$agents_seen" | grep -q implementer && printf '%s' "$agents_seen" | grep -q verifier && printf '%s' "$agents_seen" | grep -q reviewer; then
      if ! printf '%s' "$agents_seen" | grep -Eq 'implementer.*verifier.*reviewer'; then
        missing="$missing- Subagents ran out of order; required sequence is implementer -> verifier -> reviewer.\n"
      fi
    fi
  fi
'@

# Ancla RO-G: la rama de cierre limpio del Stop gate (cuando ya no falta
# nada). Se usa para que el rm -f de cierre tambien borre ORDER_PATH -- sin
# esto, harness-order.env queda huerfano en disco tras un cierre limpio hasta
# el proximo turno, rompiendo el mismo contrato de limpieza que STATE_PATH y
# LOG_PATH ya siguen aqui. Identica byte a byte en las 4 variantes.
$anchorRoG = ToLf @'
  if [ -z "$missing" ]; then
    rm -f "$STATE_PATH" "$LOG_PATH" 2>/dev/null || true
    emit_allow
  fi
'@

$insertRoB = ToLf @'
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

# >>> SAIKIT-REVIEW-ORDER v1 (parche local, re-aplicado por quality-kit/saikit-gate-heal.ps1) >>>
# Contador monotonico de eventos del turno, en SU PROPIO archivo -- nunca un
# campo mas de harness-state.env, que tiene un formato fijo de 5 campos que
# otras piezas del hook parsean por posicion/nombre. Guarda ademas EN QUE
# evento paso la ultima edicion de codigo y la ultima corrida del reviewer,
# para que el Stop gate pueda comparar orden real en vez de solo membresia en
# el set agents_seen (que no tiene orden). Ahora guarda tambien la huella del
# arbol de trabajo tomada al correr el reviewer (review_fingerprint) -- ver
# compute_code_fingerprint mas abajo.
ORDER_PATH="$STATE_DIR/harness-order.env"

read_order_value() {
  key="$1"
  if [ ! -f "$ORDER_PATH" ]; then return 0; fi
  grep "^$key=" "$ORDER_PATH" 2>/dev/null | tail -n 1 | cut -d= -f2-
}

write_order() {
  ro_counter="$1"
  ro_last_code_edit="$2"
  ro_last_review="$3"
  ro_review_fingerprint="$4"
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  {
    printf 'counter=%s\n' "$ro_counter"
    printf 'last_code_edit=%s\n' "$ro_last_code_edit"
    printf 'last_review=%s\n' "$ro_last_review"
    printf 'review_fingerprint=%s\n' "$ro_review_fingerprint"
  } > "$ORDER_PATH" 2>/dev/null || true
}

# Avanza el contador en uno y devuelve el nuevo valor por stdout. Los llamadores
# usan ese valor para fechar el evento que disparo el avance. Corre en CADA
# PostToolUse, asi que solo toca el archivo del contador -- nunca recalcula la
# huella de git aqui (eso seria caro en cada evento de herramienta); se limita
# a preservar review_fingerprint tal cual estaba.
bump_order_counter() {
  ro_counter="$(read_order_value counter)"
  ro_last_code_edit="$(read_order_value last_code_edit)"
  ro_last_review="$(read_order_value last_review)"
  ro_review_fingerprint="$(read_order_value review_fingerprint)"
  case "$ro_counter" in ''|*[!0-9]*) ro_counter=0 ;; esac
  ro_counter=$((ro_counter + 1))
  write_order "$ro_counter" "$ro_last_code_edit" "$ro_last_review" "$ro_review_fingerprint"
  printf '%s' "$ro_counter"
}

mark_order_code_edit() {
  ro_counter="$(read_order_value counter)"
  ro_last_review="$(read_order_value last_review)"
  ro_review_fingerprint="$(read_order_value review_fingerprint)"
  write_order "$ro_counter" "$1" "$ro_last_review" "$ro_review_fingerprint"
}

mark_order_review() {
  ro_counter="$(read_order_value counter)"
  ro_last_code_edit="$(read_order_value last_code_edit)"
  # SAIKIT-REVIEW-ORDER v1, hueco ALTO (revision cruzada independiente,
  # reproducido en vivo): la senal de mas arriba (mark_order_code_edit) solo
  # se dispara para un tool_name en la lista blanca edit/write/... CON
  # file_path -- un "sed -i", un heredoc, "cat >", git apply/patch, mv, cp o
  # un script corren via Bash SIN ninguno de los dos, y esa senal nunca se
  # entera. Esta huella no depende del NOMBRE de la herramienta: lee el
  # arbol de trabajo real en el momento en que el reviewer corre, para
  # compararla mas tarde contra el arbol real en el Stop gate.
  ro_review_fingerprint="$(compute_code_fingerprint)"
  write_order "$ro_counter" "$ro_last_code_edit" "$1" "$ro_review_fingerprint"
}

# Clasificacion codigo vs no-codigo, DELIBERADAMENTE sesgada hacia "es codigo":
# solo extensiones de texto/documentacion y una carpeta docs/ quedan afuera.
# Cualquier otra cosa (config, sin extension, extension desconocida) cuenta
# como codigo, porque el usuario eligio estricto -- ante la duda, se re-revisa.
# Normaliza separadores de Windows (docs\imagen.png) a forward-slash y todo a
# minusculas ANTES de clasificar: sin esto, una ruta real de Windows con
# backslash, o una extension en mayusculas/mixtas (README.Md), caian del lado
# estricto solo por como vino escrita la ruta -- no por lo que es.
is_noncode_path() {
  ro_path="$1"
  # \134 = backslash en octal POSIX de tr -- un backslash literal sin comillas
  # como ultimo caracter del set dispara "unescaped backslash" en GNU tr (a
  # stderr, ruido en cada llamada); el escape octal evita el warning y es
  # portable (POSIX especifica \ddd para tr en ambos lados del mapeo).
  ro_norm="$(printf '%s' "$ro_path" | tr 'A-Z\134' 'a-z/')"
  case "$ro_norm" in
    *.md|*.txt|*.rst|*.adoc|*.markdown) return 0 ;;
    */docs/*|docs/*) return 0 ;;
  esac
  return 1
}

# Huella del arbol de trabajo real -- ciega a que herramienta toco el
# archivo, el reemplazo del hueco ALTO. Contrato:
# - DETERMINISTA: mismo estado del arbol -> mismo hash siempre. Deliberadamente
#   NO se basa solo en el status por archivo de git (M/A/??): ese flag no
#   cambia si un archivo YA estaba modificado y se lo vuelve a editar (sigue
#   marcado "M" antes y despues), asi que una edicion posterior sobre un
#   archivo ya sucio pasaria desapercibida. En cambio hashea el CONTENIDO real
#   de cada ruta afectada con "git hash-object", que SI cambia cuando el
#   contenido cambia, sin importar el flag de status.
# - INCLUYE NO RASTREADOS: "git status --porcelain -uall" enumera cada archivo
#   sin trackear de forma individual (no los resume por carpeta), asi que un
#   archivo fuente nuevo cuenta como edicion, tal como pide la revision.
# - EXCLUYE DOCS: reusa is_noncode_path (mismo criterio que la senal vieja de
#   mark_order_code_edit), asi que tocar solo documentacion no mueve la huella.
# - BARATA: "git status" hace una sola pasada sobre el estado sucio del arbol
#   (no todo el historial), mas un "git hash-object" por archivo AFECTADO --
#   nunca sobre el repo completo. Se llama solo en los dos momentos que
#   importan (mark_order_review, y el chequeo del Stop gate mas abajo), nunca
#   en cada PostToolUse (ver bump_order_counter arriba).
# - POSTURA DE FALLO: si no hay git, si "git status" falla, o esto no es un
#   repo (GIT_ROOT vacio), la funcion no imprime NADA. Los llamadores tratan
#   un resultado vacio como "no se pudo medir" y caen a la senal vieja por
#   nombre de herramienta -- nunca bloquean por no poder medir.
compute_code_fingerprint() {
  if [ -z "$GIT_ROOT" ]; then return 0; fi
  if ! command -v git >/dev/null 2>&1; then return 0; fi
  ro_fp_status_out="$(git -C "$GIT_ROOT" status --porcelain --no-renames -uall 2>/dev/null)"
  if [ $? -ne 0 ]; then return 0; fi
  printf '%s\n' "$ro_fp_status_out" | while IFS= read -r ro_fp_line; do
    if [ -z "$ro_fp_line" ]; then continue; fi
    ro_fp_path="${ro_fp_line#???}"
    if is_noncode_path "$ro_fp_path"; then continue; fi
    ro_fp_hash="$(git -C "$GIT_ROOT" hash-object -- "$ro_fp_path" 2>/dev/null)"
    if [ -z "$ro_fp_hash" ]; then ro_fp_hash="MISSING"; fi
    printf '%s %s\n' "$ro_fp_path" "$ro_fp_hash"
  done | sort | git -C "$GIT_ROOT" hash-object --stdin 2>/dev/null
}
# <<< SAIKIT-REVIEW-ORDER v1 <<<
'@

$insertRoC = ToLf @'
  task_hash="$(printf '%s' "$prompt_text" | cksum | awk '{print $1}')"
  # >>> SAIKIT-REVIEW-ORDER v1 >>>
  # Reinicia el contador de eventos del turno; STATE_DIR persiste entre turnos.
  # Insertado ANTES de write_state a proposito: en .codex write_state se llama
  # dos veces (rama -harness-lite y rama normal) y este reset debe correr sin
  # importar cual de las dos rama se tome.
  rm -f "$ORDER_PATH" 2>/dev/null || true
  # <<< SAIKIT-REVIEW-ORDER v1 <<<
'@

$insertRoD = ToLf @'
  # >>> SAIKIT-REVIEW-ORDER v1 >>>
  order_now="$(bump_order_counter)"
  # <<< SAIKIT-REVIEW-ORDER v1 <<<
  subagent="$(json_string_field subagent_type)"
  if [ -z "$subagent" ]; then subagent="$(json_string_field subagentType)"; fi
  if [ -n "$subagent" ]; then record_agent "$subagent"; fi
  # >>> SAIKIT-REVIEW-ORDER v1 >>>
  if [ -n "$subagent" ] && [ "$(canonical_agent_role "$subagent")" = "reviewer" ]; then
    mark_order_review "$order_now"
  fi
  # <<< SAIKIT-REVIEW-ORDER v1 <<<
'@

$insertRoE = ToLf @'
  if printf '%s' "$combined" | grep -Eiq 'afterFileEdit|Edit|Write|apply_patch|file_path|edits'; then
    mark_evidence "implemented" "${file_path:-file edit}"
  fi

  # >>> SAIKIT-REVIEW-ORDER v1 >>>
  # Senal PRECISA para el orden, deliberadamente distinta del grep laxo de
  # arriba (ese matchea casi cualquier payload que mencione "edit" o una ruta,
  # incluido el $INPUT crudo entero). Solo cuenta un tool_name que sea
  # realmente una herramienta de edicion MAS un file_path real; sin ambos,
  # fail-open y no se registra nada -- mejor perder una edicion que fechar mal
  # una que no ocurrio.
  if [ -n "$file_path" ] && printf '%s' "$tool_name" | grep -Eiq '^(edit|write|multiedit|notebookedit|apply_patch|str_replace_editor|create_file|edit_file)$'; then
    if ! is_noncode_path "$file_path"; then
      mark_order_code_edit "$order_now"
    fi
  fi
  # <<< SAIKIT-REVIEW-ORDER v1 <<<
'@

$insertRoF = ToLf @'
    if printf '%s' "$agents_seen" | grep -q implementer && printf '%s' "$agents_seen" | grep -q verifier && printf '%s' "$agents_seen" | grep -q reviewer; then
      if ! printf '%s' "$agents_seen" | grep -Eq 'implementer.*verifier.*reviewer'; then
        missing="$missing- Subagents ran out of order; required sequence is implementer -> verifier -> reviewer.\n"
      fi
    fi
  fi

  # >>> SAIKIT-REVIEW-ORDER v1 >>>
  # Chequeo PRIMARIO (hueco ALTO, revision cruzada independiente): huella real
  # del arbol de trabajo, ciega a que herramienta hizo el cambio -- un "sed -i"
  # u otra edicion por shell sin file_path SI se detecta aqui. Solo se evalua
  # cuando AMBAS huellas (la guardada al correr el reviewer y la recien
  # calculada) existen; si cualquiera falta -- sin git, "git status" fallo, no
  # es un repo -- este chequeo se salta entero y cae al contador viejo por
  # nombre de herramienta de abajo, que se conserva como respaldo. Nunca
  # bloquea por no poder medir.
  ro_check_saved_fingerprint="$(read_order_value review_fingerprint)"
  ro_check_current_fingerprint="$(compute_code_fingerprint)"
  if [ -n "$ro_check_saved_fingerprint" ] && [ -n "$ro_check_current_fingerprint" ]; then
    if [ "$ro_check_saved_fingerprint" != "$ro_check_current_fingerprint" ]; then
      missing="$missing- Code was edited after the last reviewer run; re-delegate to the reviewer subagent before closing.\n"
    fi
  else
    # Respaldo (senal vieja, por nombre de herramienta). Fail-open: si el
    # archivo del contador no existe, no se puede leer, o trae basura (algo no
    # numerico), este chequeo se SALTEA por completo en vez de bloquear un
    # turno por un motivo que nadie puede ver ni arreglar. Solo un par de
    # enteros bien formados puede hacer fallar el chequeo. Si el reviewer
    # nunca corrio, ese vacio ya lo cubre el motivo "Missing reviewer subagent
    # run" de arriba -- este chequeo es especificamente para cuando SI corrio y
    # despues se toco codigo.
    ro_check_last_code_edit="$(read_order_value last_code_edit)"
    ro_check_last_review="$(read_order_value last_review)"
    case "$ro_check_last_code_edit" in ''|*[!0-9]*) ro_check_last_code_edit="" ;; esac
    case "$ro_check_last_review" in ''|*[!0-9]*) ro_check_last_review="" ;; esac
    if [ -n "$ro_check_last_code_edit" ] && [ -n "$ro_check_last_review" ] && [ "$ro_check_last_code_edit" -gt "$ro_check_last_review" ] 2>/dev/null; then
      missing="$missing- Code was edited after the last reviewer run; re-delegate to the reviewer subagent before closing.\n"
    fi
  fi
  # <<< SAIKIT-REVIEW-ORDER v1 <<<
'@

$insertRoG = ToLf @'
  if [ -z "$missing" ]; then
    # >>> SAIKIT-REVIEW-ORDER v1 >>>
    # El cierre limpio tambien borra el contador de orden -- mismo contrato
    # de limpieza que STATE_PATH y LOG_PATH, aplicado aqui mismo.
    rm -f "$STATE_PATH" "$LOG_PATH" "$ORDER_PATH" 2>/dev/null || true
    # <<< SAIKIT-REVIEW-ORDER v1 <<<
    emit_allow
  fi
'@

# Aplica UN parche (marcador + set de anclas nombradas + inserts) sobre texto
# ya normalizado a LF. Devuelve @{ estado; texto } sin tocar disco -- el
# llamador decide cuando escribir, para que ambos parches (sentinel y
# review-order) puedan aplicarse en secuencia sobre el MISMO contenido en
# memoria y el archivo se escriba una sola vez por hook.
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

$sentinelAnchors = @(
    @{ k = 'A'; v = $anchorA; ins = $insertA }
    @{ k = 'B'; v = $anchorB; ins = $insertB }
    @{ k = 'C'; v = $anchorC; ins = $insertC }
)
$reviewOrderAnchors = @(
    @{ k = 'RO-B'; v = $anchorRoB; ins = $insertRoB }
    @{ k = 'RO-C'; v = $anchorRoC; ins = $insertRoC }
    @{ k = 'RO-D'; v = $anchorRoD; ins = $insertRoD }
    @{ k = 'RO-E'; v = $anchorRoE; ins = $insertRoE }
    @{ k = 'RO-F'; v = $anchorRoF; ins = $insertRoF }
    @{ k = 'RO-G'; v = $anchorRoG; ins = $insertRoG }
)

$targets = @('.claude', '.codex', '.cursor', '.agents') |
    ForEach-Object { Join-Path $env:USERPROFILE (Join-Path $_ 'hooks\summonaikit-harness.sh') }

$results = @()

foreach ($path in $targets) {
    $short = $path.Replace($env:USERPROFILE, '~')

    if (-not (Test-Path $path)) {
        $results += [pscustomobject]@{ hook = $short; sentinel = 'no-instalado'; revieworder = 'no-instalado' }
        continue
    }

    try {
        $lf = ToLf ([System.IO.File]::ReadAllText($path))
    }
    catch {
        $err = "ilegible: $($_.Exception.Message)"
        $results += [pscustomobject]@{ hook = $short; sentinel = $err; revieworder = $err }
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
    # Invoke-SinglePatch devuelve el texto SIN TOCAR cuando no aplica (ya
    # parchado o anclas rotas), asi que encadenarlos siempre da el resultado
    # correcto de a cual(es) SI se les pudo aplicar el parche.
    $r1 = Invoke-SinglePatch -Text $lf -Marker $MARKER -Anchors $sentinelAnchors -CheckOnly:$Check
    $r2 = Invoke-SinglePatch -Text $r1.texto -Marker $MARKER2 -Anchors $reviewOrderAnchors -CheckOnly:$Check

    $sentinelEstado = $r1.estado
    $reviewOrderEstado = $r2.estado
    $results += [pscustomobject]@{ hook = $short; sentinel = $sentinelEstado; revieworder = $reviewOrderEstado }

    if ($Check) { continue }
    if ($sentinelEstado -ne 'PARCHADO' -and $reviewOrderEstado -ne 'PARCHADO') {
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
        $results[-1] = [pscustomobject]@{ hook = $short; sentinel = $err; revieworder = $err }
    }
}

$changed = @($results | Where-Object { $_.sentinel -eq 'PARCHADO' -or $_.revieworder -eq 'PARCHADO' }).Count
$broken = @($results | Where-Object { $_.sentinel -like 'ANCLAS*' -or $_.sentinel -like 'fallo*' -or $_.revieworder -like 'ANCLAS*' -or $_.revieworder -like 'fallo*' }).Count

# Un fallo se reporta SIEMPRE, aun con -Quiet. Un parche que no aplico significa
# que el gate quedo corriendo sin sentinel y/o sin control de orden de revision;
# enterarse tarde es el peor caso, y -Quiet existe para silenciar el ruido de
# exito, no las fallas.
if ($broken -gt 0) {
    $results | Format-Table -AutoSize | Out-String | Write-Host
    Write-Host "[!] SummonAI Kit: $broken hook(s) con al menos un parche sin aplicar - revisar arriba cual (sentinel / revieworder)." -ForegroundColor Yellow
}
elseif (-not $Quiet -and $changed -gt 0) {
    $results | Format-Table -AutoSize | Out-String | Write-Host
    Write-Host "[OK] SummonAI Kit: parches re-aplicados en $changed hook(s)." -ForegroundColor Green
}

exit 0
