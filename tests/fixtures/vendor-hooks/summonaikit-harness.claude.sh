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
- The person giving you this task is non-technical (a founder, marketer, product manager, designer, or operator). They cannot read code and did not write any. They own WHAT gets built and WHY; you own HOW.
- Talk to them only in plain language: no code, no file names, no library/tool/jargon words in anything you say to them. If a technical detail matters, first explain what it means in one plain sentence.
- Never ask them to make a technical decision (which library, which data model, fail-open vs fail-closed, which framework). Decide those yourself from the repo and tell them the result in plain words.

Run the work as a gated harness:
1. Understand - FIRST, restate the request back in your own plain words so the user can confirm you got it right. If anything about the desired OUTCOME is unclear, ambiguous, or hard to undo, ask short plain-language questions about what they want (never about how to build it) and WAIT for the answer before building. This step is yours as the lead; do not delegate it.
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

is_engineering_task() {
  text="$1"
  printf '%s' "$text" | grep -Eiq 'implement|fix|debug|build|create|add|change|update|rewrite|refactor|hook|skill|agent|cli|code|test|verify|review|frontend|backend|database|auth|api|schema|migration|component|ui|ux|bug|patch'
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
  write_state "$task_hash" "0" "0" "0" ""
  printf 'prompt task started: %s\n' "$task_hash" > "$LOG_PATH" 2>/dev/null || true

  context="$(harness_context)"
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
  printf '%s' "$text" | grep -Eiq "(^|[^[:alpha:]])($label|$alt)[[:space:]]*:"
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

  # A clarifying pause is a valid way to end the turn: the agent asked the
  # non-technical user a question and is waiting for the answer. Do not demand a
  # receipt or the implement -> verify -> review sequence in that case.
  if printf '%s' "$text" | grep -Eiq 'SUMMONAIKIT HARNESS PAUSED'; then
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
      *) missing="$missing- Missing implementer subagent run (delegate the change via the Task tool).\n" ;;
    esac
    case ",$agents_seen," in
      *",verifier,"*) ;;
      *) missing="$missing- Missing verifier subagent run (delegate verification via the Task tool).\n" ;;
    esac
    case ",$agents_seen," in
      *",reviewer,"*) ;;
      *) missing="$missing- Missing reviewer subagent run (delegate review via the Task tool).\n" ;;
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
