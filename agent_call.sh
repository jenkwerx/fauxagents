#!/bin/bash

# ============================================================
# agent_call.sh
# Multi-engine launcher for the agent relay system
#   Agent A  →  Claude Code (Opus)
#   Agent B  →  Gemini 2.5 Pro
#   Agent C  →  Codex (OpenAI)
#
# Copyright (c) 2026 Jenkwerx
# Released under the MIT No Attribution License (MIT-0) — see LICENSE.
#
# Usage:
#   ./agent_call.sh "Agent A" project_name
#   ./agent_call.sh "Agent A" project_name --max-turns 50
#   ./agent_call.sh "Agent A" project_name --effort high
#   ./agent_call.sh "Agent B" project_name --model gemini-2.5-flash
#   ./agent_call.sh "Agent C" project_name --model gpt-5.4 --effort high
#
# Defaults:
#   --max-turns  25  (Claude only — ignored for Gemini and Codex)
#   --effort     per-agent:  Claude=high, Gemini=n/a, OpenAI=high
#                Claude accepts:  low / medium / high / xhigh / max
#                Codex  accepts:  minimal / low / medium / high / xhigh
#                Gemini: no CLI flag; value is ignored
#   --model      per-agent: claude-opus-4-7 / gemini-2.5-pro / gpt-5.4
#
# Gemini-specific:
#   --gemini-preload   Pre-load entire project directory into Gemini's context
#                      via --include-directories (the original behavior). By
#                      default the launcher OMITS that flag — Gemini reads
#                      files lazily on demand, matching how Claude (--add-dir)
#                      and Codex (--cd) behave. Pass --gemini-preload only for
#                      small projects where having the whole tree in context
#                      from the start is worth the token cost.
# ============================================================

AGENT_NAME="$1"
PROJECT_NAME="$2"

# --- defaults (override with flags) ---
MAX_TURNS=25
EFFORT=""  # empty = use per-agent default (see resolution block below)
MODEL=""   # empty = use per-agent default

# --- per-agent default models ---
DEFAULT_CLAUDE_MODEL="claude-opus-4-7"
DEFAULT_GEMINI_MODEL="gemini-2.5-pro"
DEFAULT_OPENAI_MODEL="gpt-5.4"

# --- per-agent default effort ---
# Mirrors YRGE's yrge_fetcher.py effort constants so the two systems behave
# consistently. Gemini has no CLI effort flag — the value is kept for
# symmetry but is never passed through to the Gemini binary.
DEFAULT_CLAUDE_EFFORT="high"     # low / medium / high / xhigh (Opus 4.7 only) / max
DEFAULT_GEMINI_EFFORT="n/a"      # Gemini CLI has no effort flag — this is a marker only
DEFAULT_OPENAI_EFFORT="high"     # low / medium / high / xhigh (no max — Codex ceiling is xhigh)

if [ -z "$AGENT_NAME" ] || [ -z "$PROJECT_NAME" ]; then
  echo "Usage: $0 \"Agent A|B|C\" project_name [options]"
  echo ""
  echo "Options:"
  echo "  --max-turns N      Max tool calls (default: 25)"
  echo "                     Claude only — ignored for Agent B (Gemini) and Agent C (Codex)"
  echo "  --effort LEVEL     Thinking effort: low, medium, high, xhigh, max"
  echo "                     (per-agent default: Claude=high, Gemini=n/a, OpenAI=high)"
  echo "  --model MODEL      Override the model for whichever agent is running"
  echo "  --gemini-preload   Pre-load whole project dir into Gemini's context"
  echo "                     (Agent B only — opt-in to original --include-directories"
  echo "                     behavior; default is lazy file reads)"
  exit 1
fi

# --- parse optional flags ---
# Track whether --max-turns was user-provided so we can warn when it's passed
# to an agent that ignores it (Gemini, Codex — neither has a CLI turn cap).
MAX_TURNS_USER_PROVIDED=0
# --- Gemini preload state ---
# When 1, the launcher passes --include-directories "$PROJECT_DIR" to Gemini,
# pre-loading the entire tree into context. When 0 (default), the flag is
# omitted and Gemini reads files lazily on demand. Only meaningful for
# Agent B; tracked separately so we can warn if it's passed to A or C.
GEMINI_PRELOAD=0
GEMINI_PRELOAD_USER_PROVIDED=0
shift 2
while [ $# -gt 0 ]; do
  case "$1" in
    --max-turns)
      MAX_TURNS="$2"
      MAX_TURNS_USER_PROVIDED=1
      shift 2
      ;;
    --effort)
      EFFORT="$2"
      shift 2
      ;;
    --model)
      MODEL="$2"
      shift 2
      ;;
    --gemini-preload)
      GEMINI_PRELOAD=1
      GEMINI_PRELOAD_USER_PROVIDED=1
      shift
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# --- resolve effort: CLI override or per-agent default ---
# Track whether the user passed --effort explicitly so we can warn on
# mismatches (e.g. Gemini gets an effort value that will be ignored).
EFFORT_USER_PROVIDED=1
if [ -z "$EFFORT" ]; then
  EFFORT_USER_PROVIDED=0
  case "$AGENT_NAME" in
    "Agent A") EFFORT="$DEFAULT_CLAUDE_EFFORT" ;;
    "Agent B") EFFORT="$DEFAULT_GEMINI_EFFORT" ;;
    "Agent C") EFFORT="$DEFAULT_OPENAI_EFFORT" ;;
  esac
fi

# --- validate effort level ---
# Claude Code: low, medium, high, xhigh (Opus 4.7 only), max
# Codex:       low, medium, high, xhigh, minimal   ('max' maps to xhigh below)
# Gemini:      n/a marker only (no CLI flag exists)
#
# 'minimal' is Codex-only and 'n/a' is Gemini-only. Other values are
# cross-agent and pass validation here; see the Codex mapping block below
# for the 'max' -> 'xhigh' translation.
case "$EFFORT" in
  low|medium|high|xhigh|max) ;;
  minimal)
    if [ "$AGENT_NAME" != "Agent C" ]; then
      echo "ERROR: --effort 'minimal' is only valid for Agent C (Codex). For $AGENT_NAME use low/medium/high/xhigh/max."
      exit 1
    fi
    ;;
  n/a)
    if [ "$AGENT_NAME" != "Agent B" ]; then
      echo "ERROR: --effort 'n/a' is only valid for Agent B (Gemini). For $AGENT_NAME use low/medium/high/xhigh/max."
      exit 1
    fi
    ;;
  *)
    echo "ERROR: Invalid effort level '${EFFORT}'. Must be: low, medium, high, xhigh, max, minimal, n/a"
    exit 1
    ;;
esac

# --- resolve model: CLI override or per-agent default ---
if [ -z "$MODEL" ]; then
  case "$AGENT_NAME" in
    "Agent A") MODEL="$DEFAULT_CLAUDE_MODEL" ;;
    "Agent B") MODEL="$DEFAULT_GEMINI_MODEL" ;;
    "Agent C") MODEL="$DEFAULT_OPENAI_MODEL" ;;
  esac
fi

BASE_DIR="/opt/claude"
PROJECT_DIR="${BASE_DIR}/${PROJECT_NAME}"

# --- project directory must exist ---
# This check runs BEFORE any logging or lock work — if the directory doesn't
# exist, neither does the log path, so we just print to stderr and exit.
# Common cause: typo in the project name passed on the command line, or the
# project hasn't been created yet.
if [ ! -d "$PROJECT_DIR" ]; then
  echo "ERROR: project directory doesn't exist: ${PROJECT_DIR}" >&2
  echo "  (Pass a project name whose directory exists under ${BASE_DIR}/.)" >&2
  exit 1
fi

# --- PROJECT.md must exist ---
# The relay system requires a PROJECT.md as the static project brief —
# every agent reads it on every run. Refuse to start without one.
# The directory exists at this point, so we can also write to the log.
PROJECT_MD="${PROJECT_DIR}/PROJECT.md"
LOG_FILE="${PROJECT_DIR}/logs/agent.log"
if [ ! -f "$PROJECT_MD" ]; then
  # Surface to the user (stderr, will appear on the cron line in mail or terminal)
  echo "ERROR: PROJECT.md does not exist at ${PROJECT_MD}" >&2
  echo "  Create one before invoking the relay. PROJECT.md is the static" >&2
  echo "  project brief that every agent reads on every run." >&2
  # Also drop a line into the agent log so the absence is visible in run history
  mkdir -p "${PROJECT_DIR}/logs"
  echo "$(date -Iseconds) | ${AGENT_NAME} | ABORT: PROJECT.md missing at ${PROJECT_MD}" >> "$LOG_FILE"
  exit 1
fi

if [ -f "${PROJECT_DIR}/AGENT_RELAY.md" ]; then
  AGENT_RELAY="${PROJECT_DIR}/AGENT_RELAY.md"
elif [ -f "${BASE_DIR}/AGENT_RELAY.md" ]; then
  AGENT_RELAY="${BASE_DIR}/AGENT_RELAY.md"
else
  echo "ERROR: AGENT_RELAY.md not found in ${PROJECT_DIR} or ${BASE_DIR}" >&2
  echo "$(date -Iseconds) | ${AGENT_NAME} | ABORT: AGENT_RELAY.md not found" >> "$LOG_FILE"
  exit 1
fi

# --- environment ---
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

# --- paths ---
LOCK_FILE="${PROJECT_DIR}/agent_relay.lock"
# LOG_FILE was set above for the PROJECT.md check; leave it as is.

CLAUDE_BIN="$HOME/.local/bin/claude"
GEMINI_BIN="/home/bubsmeany/.nvm/versions/node/v25.8.0/bin/gemini"
OPENAI_BIN="/home/bubsmeany/.nvm/versions/node/v25.8.0/bin/codex"

mkdir -p "${PROJECT_DIR}/logs"

# --- done.txt + human.md state check ---
# Four states:
#   done.txt missing, human.md empty    -> normal run
#   done.txt missing, human.md content  -> normal run, human.md is override
#   done.txt exists,  human.md empty    -> SKIP, project is done
#   done.txt exists,  human.md content  -> RESTART (human.md is override, clear done.txt, mark passed.md)
HUMAN_FILE="${PROJECT_DIR}/human.md"
DONE_FILE="${PROJECT_DIR}/done.txt"
PASSED_FILE="${PROJECT_DIR}/passed.md"

HUMAN_HAS_CONTENT=0
[ -s "$HUMAN_FILE" ] && HUMAN_HAS_CONTENT=1

RESTART=0
if [ -f "$DONE_FILE" ]; then
  if [ "$HUMAN_HAS_CONTENT" -eq 0 ]; then
    echo "$(date -Iseconds) | ${AGENT_NAME} | SKIP: done.txt exists and human.md is empty." >> "$LOG_FILE"
    exit 0
  else
    RESTART=1
    echo "$(date -Iseconds) | ${AGENT_NAME} | RESTART: done.txt present AND human.md has content. Clearing done.txt and prepending restart marker to passed.md." >> "$LOG_FILE"

    # Archive done.txt before removing
    mkdir -p "${PROJECT_DIR}/bkupmd"
    cp "$DONE_FILE" "${PROJECT_DIR}/bkupmd/done_$(date +%Y%m%d%H%M%S).txt" 2>/dev/null
    rm -f "$DONE_FILE"

    # Prepend a RESTART marker to passed.md so the agent knows the last handoff
    # was from a concluded run that the human has now reopened.
    if [ -f "$PASSED_FILE" ]; then
      RESTART_TS="$(date -Iseconds)"
      RESTART_HEADER="# !!! RELAY RESTARTED — READ THIS FIRST !!!

- **Restart timestamp:** ${RESTART_TS}
- **Restarted by:** human.md interject (done.txt was present and has been cleared)
- **Triggering agent:** ${AGENT_NAME}

The project was previously marked complete via \`done.txt\`. The human author has
written new instructions into \`human.md\` to reopen the relay. Everything below
this marker is the final handoff from the run that concluded the project — treat
it as historical context, not as your immediate to-do list.

**Your actual instructions for this run are in \`human.md\`.** Read those first,
do that work, and when you rewrite passed.md at the end of your run, remove this
restart marker and write a fresh handoff that reflects the new direction.

---

"
      # Prepend without using a temp file race: write header + original in one go
      printf '%s' "$RESTART_HEADER" > "${PASSED_FILE}.new"
      cat "$PASSED_FILE" >> "${PASSED_FILE}.new"
      mv "${PASSED_FILE}.new" "$PASSED_FILE"
    fi
  fi
fi

# --- lock check ---
if [ -f "$LOCK_FILE" ]; then
  lock_age=$(( ($(date +%s) - $(stat -c %Y "$LOCK_FILE" 2>/dev/null || stat -f %m "$LOCK_FILE" 2>/dev/null)) / 60 ))
  if [ "$lock_age" -lt 30 ]; then
    echo "$(date -Iseconds) | ${AGENT_NAME} | SKIP: Lock is ${lock_age}m old (under 30). Another agent is active." >> "$LOG_FILE"
    exit 0
  else
    echo "$(date -Iseconds) | ${AGENT_NAME} | STALE: Lock is ${lock_age}m old. Taking over." >> "$LOG_FILE"
  fi
fi

# --- write lock ---
cat > "$LOCK_FILE" <<EOF
agent: ${AGENT_NAME}
started: $(date -Iseconds)
pid: $$
EOF

echo "$(date -Iseconds) | ${AGENT_NAME} | START (model: ${MODEL}, effort: ${EFFORT}, max-turns: ${MAX_TURNS})" >> "$LOG_FILE"

# Warn if the user explicitly passed --effort to Agent B (Gemini). The Gemini
# CLI has no effort flag, so the value is silently ignored downstream. We
# surface that in the log so it's not a mystery. The per-agent default for
# Gemini is the sentinel "n/a" and doesn't trigger this warning.
if [ "$AGENT_NAME" = "Agent B" ] && [ "$EFFORT_USER_PROVIDED" -eq 1 ]; then
  echo "$(date -Iseconds) | ${AGENT_NAME} | WARN: --effort '${EFFORT}' ignored (Gemini CLI has no effort flag)" >> "$LOG_FILE"
fi

# Warn if the user explicitly passed --max-turns to an agent that doesn't
# support a turn/iteration cap. Claude Code has --max-turns; Gemini and Codex
# do not. Codex models run "a single turn" that can internally contain many
# tool calls, with context-window pressure as the natural bound — there's no
# CLI flag to cap the inner loop. Silently ignoring the flag is a footgun, so
# we surface it in the log when the user explicitly set it.
if [ "$MAX_TURNS_USER_PROVIDED" -eq 1 ]; then
  case "$AGENT_NAME" in
    "Agent B")
      echo "$(date -Iseconds) | ${AGENT_NAME} | WARN: --max-turns '${MAX_TURNS}' ignored (Gemini CLI has no turn cap)" >> "$LOG_FILE"
      ;;
    "Agent C")
      echo "$(date -Iseconds) | ${AGENT_NAME} | WARN: --max-turns '${MAX_TURNS}' ignored (Codex CLI has no turn cap — Claude-only flag)" >> "$LOG_FILE"
      ;;
  esac
fi

# Warn if --gemini-preload was passed for an agent other than B. The flag
# only affects Gemini's invocation (toggling --include-directories on/off),
# so passing it for Agent A or Agent C does nothing useful. We surface it
# in the log rather than failing — letting cron lines that uniformly pass
# the flag continue to run for whichever agent is up.
if [ "$GEMINI_PRELOAD_USER_PROVIDED" -eq 1 ] && [ "$AGENT_NAME" != "Agent B" ]; then
  echo "$(date -Iseconds) | ${AGENT_NAME} | WARN: --gemini-preload ignored (Agent B / Gemini only)" >> "$LOG_FILE"
fi

# Log when Gemini preload is actually engaged for B, so token cost is visible
# in the run history even when the rest of the run looks normal.
if [ "$AGENT_NAME" = "Agent B" ] && [ "$GEMINI_PRELOAD" -eq 1 ]; then
  echo "$(date -Iseconds) | ${AGENT_NAME} | NOTE: Gemini --include-directories ENABLED (whole project pre-loaded into context)" >> "$LOG_FILE"
fi

# --- preload shared context ---
PASSED_CONTENT=$(cat "${PROJECT_DIR}/passed.md" 2>/dev/null || echo "(passed.md not found)")
PROJECT_CONTENT=$(cat "${PROJECT_DIR}/PROJECT.md" 2>/dev/null || echo "(PROJECT.md not found)")
HUMAN_CONTENT=$(cat "${PROJECT_DIR}/human.md" 2>/dev/null || echo "")
HUMAN_KEPT_CONTENT=$(cat "${PROJECT_DIR}/human_kept.md" 2>/dev/null || echo "(human_kept.md not found)")

# --- shared prompt for Claude and Codex ---
RESTART_NOTICE=""
if [ "$RESTART" -eq 1 ]; then
  RESTART_NOTICE="!!! RELAY RESTART !!!
This run is a restart. done.txt was present and has been cleared by the launcher.
human.md contains the author's new instructions and is your PRIMARY directive.
passed.md has been prepended with a RESTART marker describing what happened — the
content below that marker is historical context from the previously-concluded run.
When you rewrite passed.md at the end of your run, remove the RESTART marker and
replace it with a fresh handoff reflecting the new direction.

"
fi

AGENT_PROMPT="You are ${AGENT_NAME}. The lock file has already been written by the shell script. Do the following steps NOW using bash commands:

${RESTART_NOTICE}STEP 1 — Context (preloaded, no need to re-read files):

passed.md:
${PASSED_CONTENT}

PROJECT.md:
${PROJECT_CONTENT}

human.md (empty means no override):
${HUMAN_CONTENT}

human_kept.md (standing rules — follow always):
${HUMAN_KEPT_CONTENT}

STEP 2 — Handle human.md:
- If human.md had content above, it is your PRIMARY directive for this run.
- Run: if [ -s ${PROJECT_DIR}/human.md ]; then mkdir -p ${PROJECT_DIR}/bkupmd && cp ${PROJECT_DIR}/human.md ${PROJECT_DIR}/bkupmd/human_\$(date +%Y%m%d%H%M%S).md && > ${PROJECT_DIR}/human.md; fi
- If you acted on human.md, append a summary entry to ${PROJECT_DIR}/human_kept.md in this format:
  ### [YYYY-MM-DD HH:MM] — via human.md
  **Original instruction:** (brief summary)
  **What changed:** (what you did)
  **Standing rule:** (ongoing takeaway for all future agents)
  ---

STEP 3 — Do the work:
- If human.md had content: do what it said.
- Otherwise: do the next priority from passed.md, guided by PROJECT.md.

STEP 4 — Hand off (do ALL of these — the launcher checks each file's modification time and logs a WARN for any that wasn't updated):

(a) Archive passed.md before overwriting:
- Run: mkdir -p ${PROJECT_DIR}/bkupmd && cp ${PROJECT_DIR}/passed.md ${PROJECT_DIR}/bkupmd/passed_\$(date +%Y%m%d%H%M%S).md

(b) Overwrite passed.md with a fresh handoff covering what you did this run, what's next, blockers, and notes.

(c) If human.md had content this run, archive it then empty it (already covered in STEP 2 above; skip if human.md was empty).

(d) If you acted on human.md, append a standing-rule entry to human_kept.md (already covered in STEP 2 above; skip if no human.md).

(e) Write the gitinfo files — these are GitHub-reader-facing (not for the next agent). Mechanics:
- Archive existing git_overview.md and git_update_round.md to bkupmd/ first if they exist:
  [ -f ${PROJECT_DIR}/gitinfo/git_overview.md ] && cp ${PROJECT_DIR}/gitinfo/git_overview.md ${PROJECT_DIR}/bkupmd/git_overview_\$(date +%Y%m%d%H%M%S).md
  [ -f ${PROJECT_DIR}/gitinfo/git_update_round.md ] && cp ${PROJECT_DIR}/gitinfo/git_update_round.md ${PROJECT_DIR}/bkupmd/git_update_round_\$(date +%Y%m%d%H%M%S).md
- mkdir -p ${PROJECT_DIR}/gitinfo
- Overwrite ${PROJECT_DIR}/gitinfo/git_overview.md — project pitch for outside readers (one-paragraph summary, why, what, how, getting started). Welcoming and informative.
- Overwrite ${PROJECT_DIR}/gitinfo/git_update_round.md — this run's snapshot (date+agent+one-line summary, what landed, what's in flight, open questions).
- Prepend a new entry to the top of ${PROJECT_DIR}/gitinfo/git_updates_all.md (newest first). Pattern: write new entry to a temp file, concat temp+existing into the destination. New entry format: '## [timestamp] — ${AGENT_NAME} — one-line summary' followed by 2-5 bullets of the most important things this round, ending with '---'. If the file does not exist yet, just write the new entry as the file.

(f) Write EITHER _HOOMAN.md (if anything needs human attention) OR _HOOMAN_CLEAN_<timestamp>.md (if nothing does). Exactly one should exist after this step. Pattern:
  if [ \"\$NEEDS_HUMAN\" -eq 1 ]; then
    cat > ${PROJECT_DIR}/_HOOMAN.md <<'HEOF'
# For the human monitor
(items needing attention)
HEOF
    rm -f ${PROJECT_DIR}/_HOOMAN_CLEAN_*.md
  else
    CLEAN_NAME=\"_HOOMAN_CLEAN_\$(date +%Y%m%d%H%M%S).md\"
    echo \"No action needed.\" > ${PROJECT_DIR}/\$CLEAN_NAME
    for f in ${PROJECT_DIR}/_HOOMAN_CLEAN_*.md; do
      [ \"\$f\" = \"${PROJECT_DIR}/\$CLEAN_NAME\" ] && continue
      rm -f \"\$f\"
    done
    rm -f ${PROJECT_DIR}/_HOOMAN.md
  fi

(g) (Optional) Create done.txt only if all PROJECT.md tasks are truly complete and there is genuinely nothing for the next run to do. Err on the side of NOT creating it.

The launcher writes a WARN line to agent.log if any of passed.md, the three gitinfo files, or the _HOOMAN signal isn't updated. Do not skip steps to save turns — the WARNs will appear in the next agent's prompt context and degrade the relay.

The shell script releases the lock when you exit. Do not touch the lock file.

Begin immediately with STEP 2."

# --- Gemini prompt (relay doc handled via GEMINI_SYSTEM_MD instead) ---
GEMINI_PROMPT="You are ${AGENT_NAME} in the agent relay system.
The lock has already been acquired. Start at Step 2.
Your agent identity: ${AGENT_NAME}
Timestamp: $(date -Iseconds)
${RESTART_NOTICE}"

# --- log the prompt being sent ---
LOG_PROMPT="$AGENT_PROMPT"
[ "$AGENT_NAME" = "Agent B" ] && LOG_PROMPT="$GEMINI_PROMPT"
echo "$(date -Iseconds) | ${AGENT_NAME} | PROMPT_START" >> "$LOG_FILE"
echo "$LOG_PROMPT" >> "$LOG_FILE"
echo "$(date -Iseconds) | ${AGENT_NAME} | PROMPT_END" >> "$LOG_FILE"

# --- capture file mtimes BEFORE invoking the agent ---
# We compare these against post-run mtimes to detect runs where the agent
# claimed completion but never actually wrote files it was supposed to (a
# Gemini failure mode where it announces "I will now write X" and then
# elides the tool call, but any agent can hit this if it runs out of turn
# budget mid-handoff). 0 means the file doesn't exist yet — that's fine on
# first runs; the post-run check just confirms the agent created it.
#
# Files we monitor:
#   passed.md                          — load-bearing for next agent
#   gitinfo/git_overview.md            — README for outside readers
#   gitinfo/git_update_round.md        — this round's snapshot
#   gitinfo/git_updates_all.md         — appending log
#   _HOOMAN.md OR _HOOMAN_CLEAN_*.md   — exactly one should exist after a run

GITINFO_DIR="${PROJECT_DIR}/gitinfo"
OVERVIEW_FILE="${GITINFO_DIR}/git_overview.md"
ROUND_FILE="${GITINFO_DIR}/git_update_round.md"
ALL_FILE="${GITINFO_DIR}/git_updates_all.md"
HOOMAN_FILE="${PROJECT_DIR}/_HOOMAN.md"

snap_mtime() {
  # Echo the mtime of $1, or 0 if it doesn't exist. Linux uses `stat -c %Y`,
  # BSD/macOS uses `stat -f %m` — try both. Final `|| echo 0` is the catch-all.
  if [ -f "$1" ]; then
    stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

# For _HOOMAN_CLEAN_* we don't know the exact name in advance — capture the
# newest matching file's mtime if any exist. The post-run check will look
# at whatever's newest at that time and verify SOMETHING in the _HOOMAN
# family was created or updated.
snap_hooman_clean_mtime() {
  local newest=0 m
  for f in "${PROJECT_DIR}"/_HOOMAN_CLEAN_*.md; do
    [ -f "$f" ] || continue
    m=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)
    [ "$m" -gt "$newest" ] && newest=$m
  done
  echo "$newest"
}

PASSED_MTIME_BEFORE=$(snap_mtime "$PASSED_FILE")
OVERVIEW_MTIME_BEFORE=$(snap_mtime "$OVERVIEW_FILE")
ROUND_MTIME_BEFORE=$(snap_mtime "$ROUND_FILE")
ALL_MTIME_BEFORE=$(snap_mtime "$ALL_FILE")
HOOMAN_MTIME_BEFORE=$(snap_mtime "$HOOMAN_FILE")
HOOMAN_CLEAN_MTIME_BEFORE=$(snap_hooman_clean_mtime)

# --- map effort for Codex ---
# Codex supports: minimal, low, medium, high, xhigh (via -c model_reasoning_effort).
# Claude supports: low, medium, high, xhigh, max. Only 'max' is Claude-specific
# and needs mapping down to Codex's 'xhigh' ceiling. Other values pass through.
# Log when mapping fires so runs show what actually got sent.
case "$EFFORT" in
  max)
    CODEX_EFFORT="xhigh"
    if [ "$AGENT_NAME" = "Agent C" ]; then
      echo "$(date -Iseconds) | ${AGENT_NAME} | MAP: --effort '${EFFORT}' mapped to Codex '${CODEX_EFFORT}' (Codex max reasoning is xhigh)" >> "$LOG_FILE"
    fi
    ;;
  *) CODEX_EFFORT="$EFFORT" ;;
esac

# --- run the correct engine ---
# All three branches pipe the prompt via stdin rather than passing it as an
# argv string. This avoids the kernel's per-process ARG_MAX limit (typically
# ~128 KB on Linux, counting argv + envp combined). Large PROJECT.md or
# passed.md content used to cause `Argument list too long` failures (E2BIG
# from execve) — stdin makes the prompt size effectively unbounded.
if [ "$AGENT_NAME" = "Agent A" ]; then
  # ---- CLAUDE CODE ----
  # --effort: low, medium, high, xhigh (Opus 4.7 only), max
  # Opus 4.7 defaults to max; we override with our setting
  printf '%s' "$AGENT_PROMPT" | "$CLAUDE_BIN" \
    --add-dir "$PROJECT_DIR" \
    --dangerously-skip-permissions \
    --model "$MODEL" \
    --effort "$EFFORT" \
    --system-prompt-file "$AGENT_RELAY" \
    --no-session-persistence \
    --max-turns "$MAX_TURNS" \
    -p >> "$LOG_FILE" 2>&1

elif [ "$AGENT_NAME" = "Agent B" ]; then
  # ---- GEMINI ----
  # Gemini does not have an effort flag.
  #
  # By default we DO NOT pass --include-directories. Without it, Gemini reads
  # files lazily on demand via its own file tools, matching how Claude
  # (--add-dir) and Codex (--cd) behave. With --include-directories, Gemini
  # would pre-load the entire project tree into its context window before the
  # conversation starts — this scales linearly with project size and can burn
  # 30K+ tokens on a single run for a mature project, even when Gemini only
  # needed to read one file.
  #
  # Pass --gemini-preload at the CLI to opt back into the original behavior.
  # Useful only for small projects where the upfront cost is negligible and
  # having the whole tree in context from the start is genuinely helpful.
  #
  # -p "begin" — Gemini's CLI requires a value with -p (it can't be standalone
  # like Claude's -p). Stdin content is appended after the -p value, so the
  # placeholder "begin" sits at the front of the prompt; the actual multi-KB
  # GEMINI_PROMPT flows through stdin where ARG_MAX doesn't apply.
  export GEMINI_SYSTEM_MD="$AGENT_RELAY"
  if [ "$GEMINI_PRELOAD" -eq 1 ]; then
    printf '%s' "$GEMINI_PROMPT" | "$GEMINI_BIN" \
      --include-directories "$PROJECT_DIR" \
      --yolo \
      --model "$MODEL" \
      -p "begin" >> "$LOG_FILE" 2>&1
  else
    printf '%s' "$GEMINI_PROMPT" | "$GEMINI_BIN" \
      --yolo \
      --model "$MODEL" \
      -p "begin" >> "$LOG_FILE" 2>&1
  fi

elif [ "$AGENT_NAME" = "Agent C" ]; then
  # ---- CODEX (OpenAI) ----
  #
  # Codex's intended system-prompt mechanism is AGENTS.md, not a command-line
  # flag. Codex looks for AGENTS.md in CODEX_HOME (default ~/.codex) and also
  # in the project directory tree. We set CODEX_HOME to a project-local dir
  # and symlink AGENT_RELAY.md into it as AGENTS.md. This is the clean,
  # documented way to give Codex system-prompt-equivalent instructions.
  #
  # Per https://developers.openai.com/codex/guides/agents-md:
  #   "Codex reads AGENTS.md files before doing any work."
  #
  # Other Codex-specific choices:
  #   - `codex exec` is the non-interactive mode (vs. bare `codex` which
  #     launches the TUI). This is the current documented form.
  #   - `--yolo` (alias of --dangerously-bypass-approvals-and-sandbox) bypasses
  #     approvals AND sandbox. Swap for `--sandbox workspace-write` if you
  #     want the sandbox on but approvals off.
  #   - `--skip-git-repo-check` lets projects that aren't git repos run.
  #   - `--output-last-message` captures Codex's final message to a file
  #     so the handoff-y piece is easy to grab for logs/debugging.
  #   - Reasoning effort is NOT a standalone flag on Codex. Use the generic
  #     config override: `-c model_reasoning_effort=<value>`. Valid values
  #     are: minimal, low, medium, high, xhigh.
  CODEX_HOME_DIR="${PROJECT_DIR}/.codex"
  mkdir -p "$CODEX_HOME_DIR"
  # (Re)link AGENT_RELAY.md into AGENTS.md every run so edits to AGENT_RELAY.md
  # are picked up without manual intervention. ln -sf is idempotent.
  ln -sf "$AGENT_RELAY" "$CODEX_HOME_DIR/AGENTS.md"
  # Codex stores ChatGPT OAuth credentials at $CODEX_HOME/auth.json. Because
  # we've redirected CODEX_HOME to a project-local dir, Codex won't find the
  # user's login at ~/.codex/auth.json unless we link it through. Using a
  # symlink (rather than copying) is important: Codex refreshes the token in
  # place, and a copy would become stale on the next refresh — both ends of
  # the symlink see the same underlying file, so refresh just works. Run
  # `codex login` once as this user to create ~/.codex/auth.json.
  if [ -f "$HOME/.codex/auth.json" ]; then
    ln -sf "$HOME/.codex/auth.json" "$CODEX_HOME_DIR/auth.json"
  else
    echo "$(date -Iseconds) | ${AGENT_NAME} | WARN: ~/.codex/auth.json not found. Run 'codex login' as this user, or set OPENAI_API_KEY." >> "$LOG_FILE"
  fi

  CODEX_LAST_MSG="${PROJECT_DIR}/logs/codex_last_message.txt"

  # Pass prompt via stdin to avoid ARG_MAX. `codex exec -` reads the prompt
  # from stdin instead of from a positional argument.
  printf '%s' "$AGENT_PROMPT" | CODEX_HOME="$CODEX_HOME_DIR" "$OPENAI_BIN" exec \
    --cd "$PROJECT_DIR" \
    --skip-git-repo-check \
    --yolo \
    --model "$MODEL" \
    -c "model_reasoning_effort=$CODEX_EFFORT" \
    --output-last-message "$CODEX_LAST_MSG" \
    - >> "$LOG_FILE" 2>&1

else
  echo "$(date -Iseconds) | ${AGENT_NAME} | ERROR: Unknown agent name." >> "$LOG_FILE"
  rm -f "$LOCK_FILE"
  exit 1
fi

EXIT_CODE=$?

# --- check that the agent actually updated the files it was supposed to ---
# Compares post-run mtimes against the snapshots taken before invocation.
# If unchanged (or files still missing), the agent ran without producing
# expected output — usually because it fabricated a closing summary without
# issuing the actual file-write tool calls, or it ran out of turn budget
# before reaching Step 6. We log a WARN per file rather than failing the
# run because (a) the agent may have done real work the next agent can
# still benefit from, and (b) the launcher trims the log every run, so
# the warnings are visible in recent run history.
#
# Only fire warnings when the agent exited cleanly — a non-zero exit code
# usually means the agent crashed before reaching the handoff step, which
# is a different problem with its own diagnostic signal (the exit code
# itself plus whatever the CLI logged).

if [ "$EXIT_CODE" -eq 0 ]; then
  # passed.md — load-bearing for the next agent. Worst case if missed.
  PASSED_MTIME_AFTER=$(snap_mtime "$PASSED_FILE")
  if [ "$PASSED_MTIME_AFTER" -le "$PASSED_MTIME_BEFORE" ]; then
    if [ "$PASSED_MTIME_AFTER" -eq 0 ]; then
      echo "$(date -Iseconds) | ${AGENT_NAME} | WARN: passed.md was NOT created during this run. Agent ran successfully but produced no handoff. The next agent will see stale or missing context — recommend manual intervention via human.md." >> "$LOG_FILE"
    else
      echo "$(date -Iseconds) | ${AGENT_NAME} | WARN: passed.md mtime did not advance during this run. Agent likely fabricated its closing summary without issuing the file-write tool call. The next agent will see the previous handoff, not this run's." >> "$LOG_FILE"
    fi
  fi

  # gitinfo files — informational for outside readers. Lower stakes than
  # passed.md but still expected on every run per AGENT_RELAY.md Step 6f.
  OVERVIEW_MTIME_AFTER=$(snap_mtime "$OVERVIEW_FILE")
  if [ "$OVERVIEW_MTIME_AFTER" -le "$OVERVIEW_MTIME_BEFORE" ]; then
    echo "$(date -Iseconds) | ${AGENT_NAME} | WARN: gitinfo/git_overview.md was not updated this run (Step 6f skipped or fabricated). GitHub-facing project pitch is stale." >> "$LOG_FILE"
  fi

  ROUND_MTIME_AFTER=$(snap_mtime "$ROUND_FILE")
  if [ "$ROUND_MTIME_AFTER" -le "$ROUND_MTIME_BEFORE" ]; then
    echo "$(date -Iseconds) | ${AGENT_NAME} | WARN: gitinfo/git_update_round.md was not updated this run (Step 6f skipped or fabricated). This run's snapshot for outside readers is missing." >> "$LOG_FILE"
  fi

  ALL_MTIME_AFTER=$(snap_mtime "$ALL_FILE")
  if [ "$ALL_MTIME_AFTER" -le "$ALL_MTIME_BEFORE" ]; then
    echo "$(date -Iseconds) | ${AGENT_NAME} | WARN: gitinfo/git_updates_all.md was not appended to this run (Step 6f skipped or fabricated). The cumulative update log is missing this round's entry." >> "$LOG_FILE"
  fi

  # HOOMAN signal — exactly one of _HOOMAN.md OR _HOOMAN_CLEAN_*.md must
  # exist after a run. The agent might have written EITHER one. We pass
  # the check if EITHER mtime advanced past its respective snapshot, OR
  # if a _HOOMAN.md (which had no pre-run snapshot for this state) now
  # exists. Otherwise warn.
  HOOMAN_MTIME_AFTER=$(snap_mtime "$HOOMAN_FILE")
  HOOMAN_CLEAN_MTIME_AFTER=$(snap_hooman_clean_mtime)
  HOOMAN_TOUCHED=0
  [ "$HOOMAN_MTIME_AFTER" -gt "$HOOMAN_MTIME_BEFORE" ] && HOOMAN_TOUCHED=1
  [ "$HOOMAN_CLEAN_MTIME_AFTER" -gt "$HOOMAN_CLEAN_MTIME_BEFORE" ] && HOOMAN_TOUCHED=1
  if [ "$HOOMAN_TOUCHED" -eq 0 ]; then
    echo "$(date -Iseconds) | ${AGENT_NAME} | WARN: neither _HOOMAN.md nor _HOOMAN_CLEAN_*.md was written this run (Step 6g skipped or fabricated). The agent-to-human signal is stale; check manually whether anything needs your attention." >> "$LOG_FILE"
  fi
fi

# --- release lock ---
rm -f "$LOCK_FILE"

if [ -f "$LOG_FILE" ]; then
  tail -n 5000 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
fi

echo "$(date -Iseconds) | ${AGENT_NAME} | DONE (exit code: ${EXIT_CODE})" >> "$LOG_FILE"
