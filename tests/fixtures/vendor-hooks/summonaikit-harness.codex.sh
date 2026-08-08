#!/usr/bin/env bash
# SummonAI Kit harness hook. Project-agnostic: it enforces the implement ->
# verify -> review -> close -> retro gate against whatever stack the host repo
# uses, discovering the repo's own commands and conventions at runtime.

MAX_CYCLES=2

# >>> SAIKIT-SENTINEL-GATE v1 (parche local, re-aplicado por quality-kit/saikit-gate-heal.ps1) >>>
# El kit busca sus palabras clave como fragmentos, sin frontera de palabra, asi que
# en espanol se arma solo ("cualquier" contiene ui, "codex" contiene code). Con este
# parche el harness SOLO se arma si el prompt trae el sentinel explicito.
# El sentinel es unicamente -saikit: /harness-plan es del plugin claude-code-harness,
# otro sistema, y no debe despertar a este kit.
SAIKIT_SENTINEL_RE='(^|[^A-Za-z0-9_])-saikit([^A-Za-z0-9_-]|$)'
# <<< SAIKIT-SENTINEL-GATE v1 <<<

if [ "$SUMMONAIKIT_INTERNAL_GENERATION" = "1" ] 2>/dev/null; then
  exit 0
fi

INPUT="$(cat)"
TARGET="$SUMMONAIKIT_HOOK_TARGET"
PHASE="$SUMMONAIKIT_HOOK_PHASE"
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# Resolve the project from the WORKING directory, not the script location. This
# hook is installed at user level (~/.claude/hooks) and shared by every project,
# so deriving the project from $0 would always point at the home dir. The cwd is
# the project being worked in; fall back to pwd when git is absent.
PROJECT_ROOT="$(pwd)"
if command -v git >/dev/null 2>&1; then
  GIT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$GIT_ROOT" ]; then PROJECT_ROOT="$GIT_ROOT"; fi
fi

# Keep gate state isolated per project. A single user-level hook must not share
# one state file across repos (that would cross-contaminate the implement ->
# verify -> review cycle between projects), so key the state dir by project path.
STATE_ROOT="$HOOK_DIR/state"
PROJECT_KEY="$(printf '%s' "$PROJECT_ROOT" | cksum | cut -d ' ' -f 1)"
STATE_DIR="$STATE_ROOT/$PROJECT_KEY"
STATE_PATH="$STATE_DIR/harness-state.env"
LOG_PATH="$STATE_DIR/harness-evidence.log"

# Language/framework-agnostic test, type-check, and lint runners. Used both to
# mark verification evidence on a tool event and to credit a verification claim in
# the Stop gate, so detection stays consistent across ecosystems (JS/TS, Python,
# Ruby/Rails, PHP, .NET, JVM, Go, Rust, Elixir, Swift, C/C++, make). Add a host's
# runner here rather than in two places.
TEST_RUNNER_RE='bun[[:space:]]+(test|run[[:space:]]+(test|check-types|typecheck|lint))|npm[[:space:]]+(test|run[[:space:]]+(test|typecheck|lint))|pnpm[[:space:]]+(test|run[[:space:]]+(test|typecheck|lint))|yarn[[:space:]]+(test|typecheck|lint)|deno[[:space:]]+(test|lint|check)|vitest|jest|playwright[[:space:]]+test|cypress[[:space:]]+run|tsc|check-types|typecheck|cargo[[:space:]]+(test|nextest)|go[[:space:]]+test|gotestsum|pytest|unittest|tox|rspec|rake[[:space:]]+(test|spec)|rails[[:space:]]+test|bundle[[:space:]]+exec[[:space:]]+(rspec|rake|cucumber|minitest)|mix[[:space:]]+test|phpunit|pest|artisan[[:space:]]+test|composer[[:space:]]+(test|run[[:space:]]+test)|dotnet[[:space:]]+test|gradle[[:space:]]+(test|check)|gradlew[[:space:]]+(test|check)|mvn[[:space:]]+(test|verify)|swift[[:space:]]+test|ctest|ginkgo|make[[:space:]]+(test|check)'

json_string_field() {
  field="$1"
  printf '%s' "$INPUT" | tr '\n' ' ' | sed -n "s/.*\"$field\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n 1
}

json_number_field() {
  field="$1"
  printf '%s' "$INPUT" | tr '\n' ' ' | sed -n "s/.*\"$field\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" | head -n 1
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk 'BEGIN { first = 1 } { gsub(/\r/, ""); if (!first) printf "\\n"; printf "%s", $0; first = 0 }'
}

# AISLAMIENTO POR SESION: cada sesion de Claude usa su propio state/log. El dir
# .claude/hooks/state lo comparten sesiones concurrentes (p.ej. otra IA en el mismo
# arbol); con path fijo, una sesion arma estado y el Stop gate de OTRA tropieza con
# el. Derivamos el path de session_id (o, en su defecto, del hash de transcript_path).
# Si no hay ninguno, quedan los defaults compartidos. Re-aplicar tras saikit-update.
resolve_state_paths() {
  sid="$(json_string_field session_id)"
  if [ -z "$sid" ]; then
    tp="$(json_string_field transcript_path)"
    if [ -n "$tp" ]; then sid="$(printf '%s' "$tp" | cksum | awk '{print $1}')"; fi
  fi
  if [ -n "$sid" ]; then
    safe_id="$(printf '%s' "$sid" | tr -c 'A-Za-z0-9_-' '_' | cut -c1-64)"
    STATE_PATH="$STATE_DIR/harness-state-$safe_id.env"
    LOG_PATH="$STATE_DIR/harness-evidence-$safe_id.log"
  fi
}
resolve_state_paths

read_state_value() {
  key="$1"
  if [ ! -f "$STATE_PATH" ]; then return 0; fi
  grep "^$key=" "$STATE_PATH" 2>/dev/null | tail -n 1 | cut -d= -f2-
}

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

harness_context() {
  cat <<'HARNESS_CONTEXT'
SUMMONAIKIT HARNESS REQUIRED

Who you are working for:
- Read the user's register from how they write. If they use technical terms (file names, code, flags, stack traces), they are a developer: talk to them as a technical peer — precise names, real paths, no dumbing down — and ignore the plain-language constraints below. Those constraints apply ONLY when the user is demonstrably non-technical (a founder, marketer, product manager, designer, or operator who cannot read code). Either way they own WHAT gets built and WHY; you own HOW.
- Talk to them only in plain language: no code, no file names, no library/tool/jargon words in anything you say to them. If a technical detail matters, first explain what it means in one plain sentence.
- Never ask them to make a technical decision (which library, which data model, fail-open vs fail-closed, which framework). Decide those yourself from the repo and tell them the result in plain words.

Run the work as a gated harness:
1. Understand - FIRST, restate the request back in your own plain words so the user can confirm you got it right. If anything about the desired OUTCOME is unclear, ambiguous, or hard to undo, ask short plain-language questions about what they want (never about how to build it) and WAIT for the answer before building. For a CLEAR, reversible bug fix, one restating line is enough — proceed without waiting for confirmation; wait only when the outcome is ambiguous, irreversible, or underspecified. This step is yours as the lead; do not delegate it.
2. Implement - write code and run focused checks while editing.
3. Verify - use fresh-eyes verification and scenario tests where relevant.
4. Review - inspect principles, code quality, regressions, and skill gotchas.
5. Close - reconcile evidence, changed files, skipped checks, and readiness, and explain what changed for the user in plain words.
6. Retro - capture what should improve in the harness or codebase memory.

Asking is not failing:
- When you need an answer before you can do the work well, ask your plain-language questions and then END THE TURN with a final line that reads exactly:
  SUMMONAIKIT HARNESS PAUSED - awaiting your answer
- That line tells the harness you are correctly waiting for the user, so it will not demand a completed receipt. Run the full cycle once they reply.

Delegation rule (Claude):
- Delegate the implement, verify, and review gates to subagents via the Task tool, in this exact sequence:
  1) the implementer subagent, then 2) the verifier subagent, then 3) the reviewer subagent.
- If your host does not surface those project-level agents in the Task tool, delegate to its
  nearest equivalent instead — an engineer/coding agent to implement, a test/QA agent to verify,
  a code-review agent to review. The gate maps host agent names to these roles by function, so a
  correctly-delegated turn still satisfies it.
- You (the lead) handle the Understand step yourself and act as closer and retro: ask the user up front, then reconcile the subagents' evidence and write the final receipt in plain language.
- The turn cannot end until an implementer-, verifier-, and reviewer-role subagent have each run, in that order.
- Evidence-tag contract: each subagent's reply must BEGIN with its exact role line —
  implementer -> "IMPLEMENTER EVIDENCE:"
  verifier -> "VERIFIER VERDICT: PASS" or "VERIFIER VERDICT: FAIL"
  reviewer -> "REVIEWER FINDINGS: LGTM" or "REVIEWER FINDINGS: <N> gaps"
  When you dispatch each subagent, state its required first line yourself at BOTH the start and the end of your instructions to it — the double repetition is what survives a long prompt. If a reply comes back without its exact first line, re-dispatch that subagent immediately asking ONLY for its evidence in the required format — do not accept prose in place of the tag, and do not accept a claim that it "already delivered the evidence earlier" (you only ever see its final reply; evidence not in it does not exist). Two strikes ends the dispatching: if the SAME role comes back out of role a SECOND time (tag missing again, writing its own receipt, or claiming invisible evidence), do not insist a third time — perform that role yourself and declare "ROLE FALLBACK: <ROLE> (out of role twice)" in the receipt. A VERIFIER FAIL or reviewer gaps mean revise from that gate, not close.
- Keep each subagent dispatch SHORT and self-contained: give it only its task plus the exact first line it must return (from the tag contract above). Do NOT paste this whole harness context, the receipt template, or the Understand/Implement/Verify/Review/Close checklist into a subagent — that framing makes a scout or role subagent believe IT must close the harness. Only YOU, the lead, emit the SUMMONAIKIT HARNESS RECEIPT and end the turn; a search/Explore/scout subagent must NEVER write the receipt, declare gates passed, or try to end the turn — it returns its findings and stops.
- Keep the implementer dispatch tight: concrete scope (which files/areas it may touch) plus a SHORT NUMBERED acceptance checklist it must answer item by item in its evidence — never your full plan pasted verbatim. A real run showed a long implementer prompt causing a spelled-out detail (a lost return statement) to be silently ignored.
- Before dispatching the verifier, sanity-check the implementer's work YOURSELF: run git diff --stat and skim the diff of each function the task named, against your checklist. A dropped line or missing file is caught here for free; in a real run a silently-lost return statement survived into review because the lead skipped this one-minute check.
- Verifier context pack (speed rule, 2026-07-11): the verifier dispatch MUST include a complete context pack — the diff (or its exact file:line ranges), the exact commands to re-run, and the specific claims to reproduce — and the verifier must NOT explore beyond that pack: its job is reproducing claims, not discovery; if something it needs is missing from the pack, it asks instead of roaming the repo. The REVIEWER keeps full exploration freedom — never constrain where it looks (real runs show reviewer-initiated exploration is where interaction bugs and out-of-scope debt get found; a no-explore reviewer would have missed ADS-BUG-110).
- Warm agents (speed rule, 2026-07-11): within a session, REUSE the same verifier and reviewer agents across tasks (resume them with their context intact) instead of spawning fresh ones — warm re-rounds run 3-5x faster. Recycle to a fresh agent after ~4-5 tasks or when replies get noticeably shallower. EXCEPTION: changes touching SEALED zones or money-moving apply paths always get FRESH verifier and reviewer — fresh eyes are worth the minutes there.
- Batch low-risk tasks (speed rule, 2026-07-11): queue small low-risk items (docs, caveats, consistency fixes, test-only changes) and run several through ONE harness cycle as a single package — one cycle amortized over N fixes (real run: 7 fixes at ~13 min each vs ~35 min solo). NEVER batch sealed-zone or money-moving changes; those run solo.
- Subagent replies can come back truncated or summarized: never infer a verdict from fragments. If a reply is missing the key command output, re-run that command yourself (cheaper than a re-dispatch) and treat YOUR observed result as the evidence of record.
- One independent bug/feature = one branch/PR: if the turn covers two independent fixes, keep them on separate branches (or clearly separated commits) so the final human review stays reviewable — do not interleave them in one working tree.
- Out-of-scope debt: if the reviewer flags pre-existing technical debt beyond this change's scope (an "OUT-OF-SCOPE DEBT:" section), record it in the repo's own tracker (STATUS/TODO or docs/) during Close and say where in the receipt — do not fix it silently in this change, and do not leave it only in chat.
- Cross-model review (strongest available reviewer): if the assistant running this harness is NOT Claude (e.g. you are Codex, GLM, or another host), then BEFORE delegating the review gate, run — yourself, via your shell tool —
  powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\ehven\quality-kit\cross-review.ps1" -Con auto -Excluir <your-own-cli-name: codex|kimi|claude> -Archivos <files THIS change touched, comma-separated>
  Always pass -Archivos with the current task's files so the external reviewer sees ONLY the relevant slice of the diff: a real run skipped it on a working tree holding four accumulated fixes and the reviewer timed out twice (>300 s), delivering nothing. Omit -Archivos only when the whole uncommitted tree IS the change.
  It has a DIFFERENT (stronger, when available) AI review the diff and prints which reviewer actually ran ("Revisor efectivo") — name that reviewer in the Review line of the receipt. Paste its numbered findings into the reviewer dispatch so the reviewer validates them, merges its own, and answers in its required format; treat confirmed findings like reviewer gaps (fix, re-verify, re-review). External findings are hypotheses, not verdicts: the external reviewer mostly sees only the diff, so it produces confident false positives about code outside it (an import, a DDL, a helper defined elsewhere — all real cases), and findings it prefixes with "VERIFICAR:" are explicitly unverified. The reviewer must resolve EVERY external finding to CONFIRMED (file:line evidence) or FALSE POSITIVE before you treat it as a gap. If the script exits 3 (no external reviewer available), run the review gate normally and say so in the receipt. Skip this call ONLY when the MODEL powering this session is the Claude account model. CAREFUL: the words "Claude Code" in your system prompt name the CLI, not the model — check the "powered by" line instead; a session redirected to another provider (glm, etc.) is NOT Claude even though the CLI says Claude Code. If a MODEL CHECK block appears below, it was computed by the hook from the environment and overrides your own self-identification.
- Subagent crash fallback: if a role subagent dispatch fails on infrastructure (usage limit / 429 / tool error), retry it ONCE. If it fails again, perform that role YOURSELF following its role definition, and declare it in the receipt with a line reading exactly "ROLE FALLBACK: <ROLE> (reason)" — the gate accepts that declaration in place of the dispatch. Never silently skip a role. A dispatch stuck for many minutes with no output counts as failed — abandon it and apply this same fallback. If the task needs NO code changes (auditing or re-checking an already-applied fix, answering a question about the code), do NOT dispatch an implementer with nothing to implement — that idle dispatch is a real observed way subagents drift into closing the harness. Do the analysis yourself and declare "ROLE FALLBACK: IMPLEMENTER (audit-only, no changes to make)" in the receipt. The verifier and reviewer gates still apply to your conclusion, but dispatch them in AUDIT MODE — never as if there were a change (dispatched against a non-existent diff they drift into "nothing to verify" or into trying to close the gate: real observed failure that burns their two strikes for nothing). Open each dispatch with the exact line "AUDIT MODE: no code was changed in this task; your object is the conclusion below, not a diff." Right after that line, restate the ORIGINAL user request in one or two sentences — the verifier and reviewer must be able to judge whether audit-only was even the right classification, not just whether your claims reproduce. Give the verifier the conclusion as a short numbered list of checkable claims, each with the exact command or file:line behind it — it must re-run/re-read them itself and answer VERIFIER VERDICT: PASS only if every claim reproduces. Ask the reviewer what the audit MISSED (other call sites, stale assumptions, code contradicting the conclusion) — it answers REVIEWER FINDINGS: LGTM or gaps as usual.
- Coordination claims need identity evidence: before asserting that component A's output is consumed by component B (publisher/reader, producer/consumer, event/queue/table), read BOTH sides and verify the concrete identifiers actually match (same key, entity type, topic, schema, casing). An unverified coordination claim is the most expensive design error a lead can make — subagents will implement it faithfully and the review cycles to catch it cost more than the check.

Gate rule:
- Do not advance past a stage without concrete evidence.
- On failure, revise from the first failed gate with structured feedback.
- Revision budget is 2 cycles max. Do not blindly retry.

Context rule:
- Use Context7 for library/framework/API/CLI/cloud basics.
- Use the installed skill references for repo-specific patterns, gotchas, files, and anti-patterns.

Capability-first contract (language/framework/platform agnostic):
- Before adding a new dependency or hand-rolling a mechanism, check — via Context7 and the repo's own deps/config/SDKs — whether the capability the task needs is ALREADY provided by the deploy platform or by a library/framework already installed, and prefer that. Don't add a package for something an installed library already does (e.g. an interaction an existing UI library already supports), and don't reinvent a primitive the platform manages. Identify what's already present from the repo; never assume a provider.
- Run guards (auth/session, validation, authorization) before side effects (email, payments, analytics, storage, persisted writes).
- For ANY guard or limiter, declare its failure stance explicitly — fail-open (allow on guard-infrastructure failure) vs fail-closed (deny on failure) — choose the stance that matches the task's risk, and implement the branch you chose; never leave the failure behavior unstated.
- Before accepting any hand-rolled, in-process, or generic-store implementation of a capability the task needs, first identify the DETECTED platform and look up its OWN native primitive for that SPECIFIC capability (use Context7 and the platform's own docs/SDK/config in the repo). Prefer that native primitive and wire it through the repo's infra/config and typed runtime boundary. A generic durable store is a LAST-RESORT fallback only when no native primitive and no installed library fits; if you fall back, justify in writing why the native primitive does not apply — do not defer the native option to "later".
- The verifier rejects a new dependency or an improvised/in-process/ad-hoc solution when the detected platform or an already-installed library already covers the capability, unless the user explicitly chose otherwise.

Data-source precondition (language/framework/platform agnostic):
- Before building any surface that reads, lists, displays, or reports existing data, first confirm the backing data source actually exists — inspect the repo's schema/models/storage and the procedures or endpoints that would supply it. Do not assume prior data is already captured.
- If the source does NOT exist yet, treat it as a gap: either ask one clarifying question, OR state the assumption EXPLICITLY before coding (for example: this is newly tracked, collection starts now, and there is no historical data to backfill) — and write that assumption into the code itself (a comment or doc on the new source/record path), not only in chat, because reviewers see the diff, not the conversation.
- When a gap is found, the change is a complete slice: create the source, the write path that records new entries going forward, the read path, and the surface that shows them — wired to the existing auth/identity and reusing the repo's own conventions.
- Never claim or imply data that cannot exist yet; what the surface promises must match what is actually recorded.

Missing-information rule (language/framework/platform agnostic):
- Before coding, separate what the REPO can answer (conventions, schema, existing helpers — go read it) from what only the USER can answer (what they want, who it is for, what "done" looks like to them, naming and tone, anything irreversible).
- If a decision that shapes the outcome depends on user-only information, ASK the user the smallest set of key questions FIRST, in plain language, and wait for the answer. A good plain-language question beats a wrong guess. Ask about the outcome they want, never about how to build it.
- Resolve every technical choice yourself from the repo; never hand a non-technical user a technical decision to make.
- Never block on questions the repo already answers, and never silently guess on questions it cannot answer: if you must proceed without an answer, state the assumption in plain words to the user and record it in the diff.

User-facing surface baseline (language/framework/platform agnostic):
- For ANY user-facing surface you add or change, cover the full state matrix explicitly: loading, EMPTY (no data), error, and success — not only the happy path.
- Meet an accessibility baseline: semantic structure (a labelled region/heading, and a list or table for repeated/tabular data rather than nested generic containers), an accessible name for every control and icon-only action, visible keyboard focus, and a working keyboard path.
- Keep it responsive for long or overflowing content, and match the repo's existing component/section style instead of a generic template. Reuse the installed UI library's already-accessible primitives rather than re-implementing them.

Final receipt required before stopping (write every line in plain language a non-technical user can follow):
SUMMONAIKIT HARNESS RECEIPT
Understand: in one or two plain sentences, what the user asked for, plus any question you asked or assumption you made.
Implement: changed files and implementation summary; for any read/listing/reporting surface, state whether its data source already existed or is newly created and the assumption recorded in code; or why no code change was needed.
Verify: exact commands/checks run and results, or skipped with a concrete reason.
Review: findings, risks, or "no findings" with basis.
Close: evidence summary and remaining gaps.
Retro: harness/codebase-memory improvement, or "none".
HARNESS_CONTEXT
}

harness_context_lite() {
  cat <<'HARNESS_CONTEXT_LITE'
SUMMONAIKIT HARNESS LITE

Light mode for MECHANICAL/mirror changes (the user invoked "-harness-lite"): keep the evidence, cut the bureaucracy.

- YOU (the lead) implement the change directly. No implementer/reviewer subagent dispatch is required in this mode.
- Verification is NOT optional: run this repo's own focused checks (type-check / tests / lint of the touched area) and report real results — or dispatch one verifier-role subagent for fresh-eyes evidence (recommended if the change touches data or money). Any skipped check must be named with a concrete reason.
- If while working you discover the change is NOT mechanical after all (new logic, money paths, sealed rules, schema changes), STOP and tell the user it needs the full "-harness" treatment instead.
- The turn still cannot end without this receipt, in plain language:
SUMMONAIKIT HARNESS RECEIPT
Understand: one line restating the request.
Implement: changed files and what changed.
Verify: exact commands/checks run and their real results, or the concrete reason a check was skipped.
Review: lite mode — no reviewer subagent ran; note anything you would have flagged.
Close: evidence summary and remaining gaps.
Retro: improvement note, or "none".
- Asking is still allowed: if you need the user first, end the turn with the exact line:
  SUMMONAIKIT HARNESS PAUSED - awaiting your answer
HARNESS_CONTEXT_LITE
}

is_engineering_task() {
  text="$1"
  # SENTINEL (-saikit): el harness se activa SOLO si el prompt contiene esta palabra clave.
  # Reemplaza el regex de keywords del default (falsos positivos ingles/espanol). Opt-in.
  printf '%s' "$text" | grep -Fiq -e '-saikit'
}

# Substantive-work signals. When any appear, the task is real implementation and
# the full gate runs even if cosmetic words are also present ("change the auth
# flow" must gate, "change the heading text" must not). Platform/stack-agnostic.
SUBSTANTIVE_RE='implement|feature|endpoint|route|handler|\bapi\b|graphql|schema|migration|database|\bdb\b|\bsql\b|query|model|table|index|transaction|concurren|race condition|\bauth\b|login|signup|sign-?in|session|password|token|oauth|permission|authoriz|payment|billing|checkout|webhook|subscription|invoice|refactor|rewrite|re-?architect|redesign|integrat|algorithm|parser|encrypt|hash|security|vulnerab|injection|rate.?limit|throttle|state machine|workflow|queue|cron|scheduled|background (job|task)|deploy|infrastructure|pipeline|new (page|screen|view|route|component|model|table|service|endpoint|module)|business logic|validation|upload|file handling|cache|caching|websocket|stream'

# Trivial-edit signals. Low-risk, narrow changes that do not need the implement
# -> verify -> review gate (the user can still ask for it explicitly).
TRIVIAL_RE='typo|misspell|spell(ing)?|wording|copywrit|copy edit|rephras|reword|reorder|\btext\b|\blabel\b|caption|placeholder text|heading text|title text|\bstring\b|wording|spacing|whitespace|indent(ation)?|\bformat(ting)?\b|prettier|lint(er)? (fix|warning|error)|^lint$|rename|comment|docstring|\bdocs?\b|documentation|readme|changelog|version bump|bump (the )?version|colou?r|margin|padding|\bfont\b|font.?size|\bpx\b|alignment|capitaliz|punctuation|emoji|trailing (space|whitespace|newline)|semicolon|tweak (the )?(copy|wording|text|spacing|color|colour|margin|padding)'

# A task is trivial when it matches a cosmetic/minor signal AND carries no
# substantive-work signal. Substantive always wins.
is_trivial_task() {
  text="$1"
  if printf '%s' "$text" | grep -Eiq "$SUBSTANTIVE_RE"; then
    return 1
  fi
  printf '%s' "$text" | grep -Eiq "$TRIVIAL_RE"
}

emit_cursor_json() {
  key="$1"
  message="$2"
  escaped="$(json_escape "$message")"
  printf '{"%s":"%s"}\n' "$key" "$escaped"
}

emit_allow() {
  if [ "$TARGET" = "cursor" ]; then
    if [ "$PHASE" = "prompt" ]; then
      printf '{"continue":true}\n'
    else
      printf '{}\n'
    fi
  fi
  exit 0
}

start_harness() {
  # GC 7 dias: purga estados de sesiones muertas (cerradas sin Stop gate limpio).
  find "$STATE_ROOT" -type f -mtime +7 -delete 2>/dev/null || true
  find "$STATE_ROOT" -mindepth 1 -type d -empty -delete 2>/dev/null || true
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

  task_hash="$(printf '%s' "$prompt_text" | cksum | awk '{print $1}')"
  # MODO LITE (-harness-lite): cambios mecanicos/espejo. Se pre-siembra
  # agents_seen con los tres roles para que el Stop gate no exija
  # despachos; el recibo y la evidencia de verificacion siguen gateados.
  if printf '%s' "$prompt_text" | grep -Fiq -e '-harness-lite'; then
    write_state "$task_hash" "0" "0" "0" "implementer,verifier,reviewer"
    printf 'prompt task started: %s (lite)\n' "$task_hash" > "$LOG_PATH" 2>/dev/null || true
    context="$(harness_context_lite)"
  else
    write_state "$task_hash" "0" "0" "0" ""
    printf 'prompt task started: %s\n' "$task_hash" > "$LOG_PATH" 2>/dev/null || true
    context="$(harness_context)"
  fi
  # MODEL CHECK deterministico (fallo real: glm se creyo Claude por el
  # "You are Claude Code" del system prompt y salto el cross-review). La
  # regla se computa AQUI por environment, no por auto-identificacion del
  # modelo: host codex o sesion redirigida por variables => NO es el Claude
  # de la cuenta => cross-review obligatorio.
  if [ "$TARGET" = "codex" ] || [ -n "$ANTHROPIC_BASE_URL" ] || [ -n "$ANTHROPIC_AUTH_TOKEN" ] || [ -n "$ANTHROPIC_API_KEY" ]; then
    context="$context

MODEL CHECK (computed by this hook from the environment — do NOT second-guess it): this session is NOT running on the Claude account model (non-Claude host or env-redirected session detected). The cross-model review step is MANDATORY for you. The words Claude Code in your system prompt name the CLI, not the model."
  fi
  escaped="$(json_escape "$context")"

  if [ "$TARGET" = "cursor" ]; then
    if [ "$PHASE" = "session" ]; then
      printf '{"additional_context":"%s"}\n' "$escaped"
    else
      printf '{"continue":true}\n'
    fi
    exit 0
  fi

  printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"%s"}}\n' "$escaped"
  exit 0
}

mark_evidence() {
  kind="$1"
  detail="$2"
  task_hash="$(read_state_value task_hash)"
  cycle="$(read_state_value cycle)"
  implemented="$(read_state_value implemented)"
  verified="$(read_state_value verified)"
  agents_seen="$(read_state_value agents_seen)"
  if [ -z "$task_hash" ]; then task_hash="unknown"; fi
  if [ -z "$cycle" ]; then cycle="0"; fi
  if [ -z "$implemented" ]; then implemented="0"; fi
  if [ -z "$verified" ]; then verified="0"; fi

  if [ "$kind" = "implemented" ]; then implemented="1"; fi
  if [ "$kind" = "verified" ]; then verified="1"; fi
  write_state "$task_hash" "$cycle" "$implemented" "$verified" "$agents_seen"
  printf '%s: %s\n' "$kind" "$detail" >> "$LOG_PATH" 2>/dev/null || true
}

# Map a host's agent/subagent name onto a canonical harness role
# (implementer | verifier | reviewer | closer | retro), or empty when the name
# carries no harness role. Hosts surface different agent names: Claude Code's
# global set exposes backend-engineer / test-engineer / code-reviewer rather than
# the project-level implementer / verifier / reviewer files SummonAI Kit installs,
# and Cursor/Aider/others differ again. Matching is by role KEYWORD, not a
# hard-coded per-host list, so it stays host-agnostic — any host whose agent name
# names its function resolves to the right gate. Keyword precedence is
# review > verify/test > implement, so a name like "test-engineer" resolves to
# verifier (not implementer via the generic "engineer" signal). Generic agents
# (general-purpose, plan, explore, docs) carry no role and stay unmapped so they
# never satisfy a gate by accident. The leading (^|[^a-z]) boundary matches the
# role stem at a token start only, so "preview" never reads as "review".
# The implement keywords (engineer/build/debug/...) are deliberately broad: any
# engineering/coding agent counts as the implementer. This gate is structural, not
# semantic — it confirms a subagent ran in the implement slot, not that it wrote
# code — and breadth is required so a host's coding agent (Claude Code's
# backend-engineer / data-engineer) resolves; narrowing it would re-break that.
# It never weakens the gate: an implementer match still does not satisfy the
# separate verifier and reviewer slots, which a turn must also fill, in order.
canonical_agent_role() {
  name="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$name" in
    implementer) printf 'implementer'; return 0 ;;
    verifier) printf 'verifier'; return 0 ;;
    reviewer) printf 'reviewer'; return 0 ;;
    closer) printf 'closer'; return 0 ;;
    retro) printf 'retro'; return 0 ;;
  esac
  if printf '%s' "$name" | grep -Eq '(^|[^a-z])(review|critique|critic|audit)'; then printf 'reviewer'; return 0; fi
  if printf '%s' "$name" | grep -Eq '(^|[^a-z])(verif|test|qa|quality|validat)'; then printf 'verifier'; return 0; fi
  if printf '%s' "$name" | grep -Eq '(^|[^a-z])(implement|engineer|developer|coder|build|debug|backend|frontend|fullstack|refactor)'; then printf 'implementer'; return 0; fi
  return 0
}

# Record a harness subagent invocation (any host agent name that normalizes to a
# canonical role) into persistent state so the Stop gate can verify the sequence
# ran — robust to the transcript tail window dropping the Task call.
record_agent() {
  agent="$(canonical_agent_role "$1")"
  if [ -z "$agent" ]; then return 0; fi
  task_hash="$(read_state_value task_hash)"
  cycle="$(read_state_value cycle)"
  implemented="$(read_state_value implemented)"
  verified="$(read_state_value verified)"
  agents_seen="$(read_state_value agents_seen)"
  if [ -z "$task_hash" ]; then task_hash="unknown"; fi
  if [ -z "$cycle" ]; then cycle="0"; fi
  if [ -z "$implemented" ]; then implemented="0"; fi
  if [ -z "$verified" ]; then verified="0"; fi
  case ",$agents_seen," in
    *",$agent,"*) ;;
    *)
      if [ -z "$agents_seen" ]; then agents_seen="$agent"; else agents_seen="$agents_seen,$agent"; fi
      ;;
  esac
  write_state "$task_hash" "$cycle" "$implemented" "$verified" "$agents_seen"
  printf 'agent: %s\n' "$agent" >> "$LOG_PATH" 2>/dev/null || true
}

record_tool_evidence() {
  # GUARDIA anti-fabricacion: sin estado previo NO se registra evidencia. Un evento
  # de herramienta jamas debe crear estado de la nada (bug task_hash=unknown que
  # exigia recibos en conversaciones donde el harness nunca se activo).
  if [ ! -f "$STATE_PATH" ]; then emit_allow; fi
  # >>> SAIKIT-SENTINEL-GATE v1 >>>
  # Sin tarea armada NO se crea archivo de estado. Si no, mark_evidence lo crearia
  # con task_hash=unknown en cualquier edicion y el Stop gate se activaria solo,
  # anulando el sentinel.
  if [ ! -f "$STATE_PATH" ]; then emit_allow; fi
  # <<< SAIKIT-SENTINEL-GATE v1 <<<
  event_name="$(json_string_field hook_event_name)"
  tool_name="$(json_string_field tool_name)"
  command_text="$(json_string_field command)"
  file_path="$(json_string_field file_path)"
  combined="$event_name $tool_name $command_text $file_path $INPUT"

  # Record harness subagent runs (Task tool carries a subagent_type) so the Stop
  # gate can enforce the implementer -> verifier -> reviewer sequence.
  subagent="$(json_string_field subagent_type)"
  if [ -z "$subagent" ]; then subagent="$(json_string_field subagentType)"; fi
  if [ -n "$subagent" ]; then record_agent "$subagent"; fi

  if printf '%s' "$combined" | grep -Eiq 'afterFileEdit|Edit|Write|apply_patch|file_path|edits'; then
    mark_evidence "implemented" "${file_path:-file edit}"
  fi

  # Credit verification only when a test/type-check RUNNER appears in the COMMAND
  # (tool_name + command), never in a file path or the raw payload — otherwise
  # editing vitest.config.ts or reading a Gemfile.lock that names rspec would
  # falsely mark the work verified. The failure-signal guard still consults the
  # full payload, since exit codes live in the tool result, not the command.
  if printf '%s' "$tool_name $command_text" | grep -Eiq "$TEST_RUNNER_RE"; then
    if ! printf '%s' "$combined" | grep -Eiq 'exitCode[^0-9]*[1-9]|failure_type|permission_denied|command not found'; then
      mark_evidence "verified" "${command_text:-verification command}"
    fi
  fi

  emit_allow
}

has_receipt_label() {
  label="$1"
  alt="$2"
  text="$3"
  # Parche 16: transcript JSONL — los \n escapados dejan la letra n antes del label.
  printf '%s' "$text" | grep -Eiq "(^|[^[:alpha:]]|\\\\n)($label|$alt)[[:space:]]*:"
}

build_gate_feedback() {
  missing="$1"
  next_cycle="$2"
  cat <<EOF
SUMMONAIKIT HARNESS GATE

Failed gates:
$missing

Structured revision required:
1. Return to the first missing gate.
2. Use real evidence, not a marker file or a claim.
3. Preserve the Context7 split: Context7 for library basics, skill references for repo gotchas.
4. End with the required SUMMONAIKIT HARNESS RECEIPT.

Revision loop on failure:
- Current revision cycle: $next_cycle/$MAX_CYCLES.
- Budget: 2 cycles max.
- Do not blindly retry.

Required receipt shape (each gate is one line that BEGINS with its label and a colon, inside the receipt block; write them in plain language):
SUMMONAIKIT HARNESS RECEIPT
Understand: ...
Implement: ...
Verify: ...
Review: ...
Close: ...
Retro: ...
EOF
}

emit_gate_failure() {
  feedback="$1"
  if [ "$TARGET" = "cursor" ]; then
    emit_cursor_json "followup_message" "$feedback"
    exit 0
  fi

  escaped="$(json_escape "$feedback")"
  printf '{"decision":"block","reason":"%s"}\n' "$escaped"
  printf '%s\n' "$feedback" >&2
  exit 2
}

emit_budget_exhausted() {
  missing="$1"
  message="SUMMONAIKIT HARNESS REVISION BUDGET EXHAUSTED

The harness gate failed after 2 structured revision cycles.

Still missing:
$missing

Stop now, report the failed gates, and ask the user before another retry."

  if [ "$TARGET" = "cursor" ]; then
    emit_cursor_json "followup_message" "$message"
    exit 0
  fi

  escaped="$(json_escape "$message")"
  printf '{"continue":false,"stopReason":"%s"}\n' "$escaped"
  printf '%s\n' "$message" >&2
  exit 0
}

stop_gate() {
  if [ ! -f "$STATE_PATH" ]; then
    emit_allow
  fi

  transcript_path="$(json_string_field transcript_path)"
  tail_text=""
  if [ -n "$transcript_path" ] && [ -r "$transcript_path" ]; then
    tail_text="$(tail -n 160 "$transcript_path" 2>/dev/null || true)"
  fi
  text="$INPUT
$tail_text"
  # Parche 16: carrera de flush — reintento unico si el recibo aun no aterrizo.
  if ! printf '%s' "$text" | grep -Eiq 'SUMMONAIKIT HARNESS RECEIPT'; then
    sleep 1
    if [ -n "$transcript_path" ] && [ -r "$transcript_path" ]; then
      tail_text="$(tail -n 160 "$transcript_path" 2>/dev/null || true)"
    fi
    text="$INPUT
$tail_text"
  fi

  # A clarifying pause is a valid way to end the turn: the agent asked the
  # non-technical user a question and is waiting for the answer. Do not demand a
  # receipt or the implement -> verify -> review sequence in that case.
  if printf '%s' "$text" | grep -Eiq 'SUMMONAIKIT HARNESS PAUSED'; then
    # Parche 17: marcar la pausa en el estado — el proximo prompt sin sentinel
    # es la respuesta del usuario y NO debe desarmar (ver start_harness).
    if [ -f "$STATE_PATH" ] && ! grep -q '^paused=1' "$STATE_PATH" 2>/dev/null; then
      printf 'paused=1\n' >> "$STATE_PATH" 2>/dev/null || true
    fi
    emit_allow
  fi

  implemented="$(read_state_value implemented)"
  verified="$(read_state_value verified)"
  cycle="$(read_state_value cycle)"
  task_hash="$(read_state_value task_hash)"
  agents_seen="$(read_state_value agents_seen)"
  if [ -z "$implemented" ]; then implemented="0"; fi
  if [ -z "$verified" ]; then verified="0"; fi
  if [ -z "$cycle" ]; then cycle="0"; fi
  if [ -z "$task_hash" ]; then task_hash="unknown"; fi

  missing=""
  if ! printf '%s' "$text" | grep -Eiq 'SUMMONAIKIT HARNESS RECEIPT'; then
    missing="$missing- Missing SUMMONAIKIT HARNESS RECEIPT.\n"
  fi
  if ! has_receipt_label "Understand" "Capito" "$text"; then
    missing="$missing- Missing Understand gate summary (add a line beginning 'Understand:' inside the SUMMONAIKIT HARNESS RECEIPT block, restating the request in plain words). If you instead need to ask the user first, end the turn with the line 'SUMMONAIKIT HARNESS PAUSED - awaiting your answer'.\n"
  fi
  if ! has_receipt_label "Implement" "Implementazione" "$text"; then
    missing="$missing- Missing Implement gate summary (add a line beginning 'Implement:' inside the SUMMONAIKIT HARNESS RECEIPT block).\n"
  fi
  if ! has_receipt_label "Verify" "Verifica" "$text"; then
    missing="$missing- Missing Verify gate summary (add a line beginning 'Verify:' inside the SUMMONAIKIT HARNESS RECEIPT block).\n"
  fi
  if ! has_receipt_label "Review" "Revisione" "$text"; then
    missing="$missing- Missing Review gate summary (add a line beginning 'Review:' inside the SUMMONAIKIT HARNESS RECEIPT block).\n"
  fi
  if ! has_receipt_label "Close" "Chiusura" "$text"; then
    missing="$missing- Missing Close gate summary (add a line beginning 'Close:' inside the SUMMONAIKIT HARNESS RECEIPT block).\n"
  fi
  if ! has_receipt_label "Retro" "Retrospettiva" "$text"; then
    missing="$missing- Missing Retro gate summary (add a line beginning 'Retro:' inside the SUMMONAIKIT HARNESS RECEIPT block).\n"
  fi
  if [ "$verified" != "1" ] && ! printf '%s' "$text" | grep -Eiq "$TEST_RUNNER_RE|not run|not executed|skipped|non eseguit|saltat"; then
    missing="$missing- Missing verification evidence or explicit skipped-check reason.\n"
  fi

  # Sequential subagent enforcement (Claude only — Task/subagent_type is a Claude
  # Code primitive). The first three gates must each run as their own subagent,
  # in order. closer/retro stay receipt sections the lead writes.
  if [ "$TARGET" = "claude" ]; then
    case ",$agents_seen," in
      *",implementer,"*) ;;
      *) if ! printf '%s' "$text" | grep -Eiq 'ROLE FALLBACK: *IMPLEMENTER'; then missing="$missing- Missing implementer subagent run (delegate the change via the Task tool, or declare ROLE FALLBACK: IMPLEMENTER (reason) in the receipt if that subagent is down after one retry).\n"; fi ;;
    esac
    case ",$agents_seen," in
      *",verifier,"*) ;;
      *) if ! printf '%s' "$text" | grep -Eiq 'ROLE FALLBACK: *VERIFIER'; then missing="$missing- Missing verifier subagent run (delegate verification via the Task tool, or declare ROLE FALLBACK: VERIFIER (reason) in the receipt if that subagent is down after one retry).\n"; fi ;;
    esac
    case ",$agents_seen," in
      *",reviewer,"*) ;;
      *) if ! printf '%s' "$text" | grep -Eiq 'ROLE FALLBACK: *REVIEWER'; then missing="$missing- Missing reviewer subagent run (delegate review via the Task tool, or declare ROLE FALLBACK: REVIEWER (reason) in the receipt if that subagent is down after one retry).\n"; fi ;;
    esac
    if printf '%s' "$agents_seen" | grep -q implementer && printf '%s' "$agents_seen" | grep -q verifier && printf '%s' "$agents_seen" | grep -q reviewer; then
      if ! printf '%s' "$agents_seen" | grep -Eq 'implementer.*verifier.*reviewer'; then
        missing="$missing- Subagents ran out of order; required sequence is implementer -> verifier -> reviewer.\n"
      fi
    fi
  fi

  if [ -z "$missing" ]; then
    rm -f "$STATE_PATH" "$LOG_PATH" 2>/dev/null || true
    emit_allow
  fi

  if [ "$cycle" -ge "$MAX_CYCLES" ] 2>/dev/null; then
    emit_budget_exhausted "$missing"
  fi

  next_cycle=$((cycle + 1))
  write_state "$task_hash" "$next_cycle" "$implemented" "$verified" "$agents_seen"
  feedback="$(build_gate_feedback "$missing" "$next_cycle")"
  emit_gate_failure "$feedback"
}

if [ -z "$PHASE" ]; then
  event="$(json_string_field hook_event_name)"
  case "$event" in
    UserPromptSubmit|beforeSubmitPrompt) PHASE="prompt" ;;
    SessionStart|sessionStart) PHASE="session" ;;
    Stop|stop) PHASE="stop" ;;
    *) PHASE="tool" ;;
  esac
fi

case "$PHASE" in
  prompt|session) start_harness ;;
  tool) record_tool_evidence ;;
  stop|verify) stop_gate ;;
  *) emit_allow ;;
esac
