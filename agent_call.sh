#!/bin/bash

# ============================================================
# agent_call.sh
# Multi-engine launcher for the agent relay system
#   Agent A    →  Claude Code (Opus)
#   Agent C    →  Codex (OpenAI)
#   Agent D    →  Claude Code (DeepSeek backend via Anthropic-compatible endpoint)
#   Agent G    →  Gemini 2.5 Pro
#   Agent M    →  Mistral Vibe CLI (Devstral 2)
#   Agent OG   →  Claude Code (Google Gemma 4 31B via OpenRouter, paid)
#   Agent OGF  →  Claude Code (Google Gemma 4 31B via OpenRouter, free tier)
#   Agent OQ   →  Claude Code (Qwen 3.6 35B A3B via OpenRouter)
#   Agent OQF  →  Claude Code (Qwen free tier via OpenRouter)
#
# Copyright (c) 2026 Jenkwerx
# Released under the MIT No Attribution License (MIT-0) — see LICENSE.
#
# Usage:
#   ./agent_call.sh "Agent A" project_name
#   ./agent_call.sh "Agent A" project_name --max-turns 50
#   ./agent_call.sh "Agent A" project_name --effort high
#   ./agent_call.sh "Agent G" project_name --model gemini-2.5-flash
#   ./agent_call.sh "Agent C" project_name --model gpt-5.4 --effort high
#
# Defaults:
#   --max-turns  25  (Claude only — ignored for Gemini and Codex)
#   --effort     per-agent:  Claude=high, Gemini=n/a, OpenAI=high
#                Claude accepts:  low / medium / high / xhigh / max
#                Codex  accepts:  minimal / low / medium / high / xhigh
#                Gemini: no CLI flag; value is ignored
#   --model      per-agent: claude-opus-4-7 / gemini-3.1-pro-preview / gpt-5.4
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

# ---------------------------------------------------------------------------
# Secrets loading
# ---------------------------------------------------------------------------
# API keys (currently DEEPSEEK_API_KEY for Agent D) live in a separate
# secrets file rather than in this script. The script is portable and may
# be committed; the secrets file is per-host, never committed.
#
# Two supported permission models:
#
#   Strict (single-user setup):
#     Mode 0600, owned by the user who runs the launcher.
#       chmod 600 /opt/claude/.env.secrets
#       chown $USER:$USER /opt/claude/.env.secrets
#
#   Group-read (multi-user setup, e.g. jaccomacacco writes / safeclaude reads):
#     Mode 0640, owned by an admin user, group is a trusted read-only group,
#     and the launcher's user is a member of that group.
#       chown jaccomacacco:safeclaude /opt/claude/.env.secrets
#       chmod 640 /opt/claude/.env.secrets
#     (Then ensure the cron user is in safeclaude: `usermod -a -G safeclaude bubsmeany`)
#
# Add to your .gitignore at the repo root:
#   .env.secrets
#
# Future migration path: this block can be replaced with a call to a local
# key broker (e.g. a service on a Unix socket) without changing any code
# that uses the resulting environment variables. The seam is here.

SECRETS_FILE="/opt/claude/.env.secrets"
SECRETS_GROUP="safeclaude"   # group used in the 640 group-read setup

load_secrets() {
  [ -f "$SECRETS_FILE" ] || return 0   # missing is fine; per-agent code checks for required keys

  local perms owner group expected_owner
  perms=$(stat -c %a "$SECRETS_FILE" 2>/dev/null || echo "?")
  owner=$(stat -c %U "$SECRETS_FILE" 2>/dev/null || echo "?")
  group=$(stat -c %G "$SECRETS_FILE" 2>/dev/null || echo "?")
  expected_owner=$(whoami)

  # Two acceptable configurations:
  #
  #   1. perms=600, owner=$expected_owner (strict single-user setup)
  #   2. perms=640, group=$SECRETS_GROUP, and the launcher user is in $SECRETS_GROUP
  #      (group-read setup — admin owns the file, locked-down cron user reads via group)
  #
  # Anything else is rejected.

  local accept=0

  # Case 1: strict
  if [ "$perms" = "600" ] && [ "$owner" = "$expected_owner" ]; then
    accept=1
  fi

  # Case 2: group-read
  if [ "$perms" = "640" ] && [ "$group" = "$SECRETS_GROUP" ]; then
    # Verify the launcher user is actually a member of the group. Without
    # this check we'd just get a noisy "Permission denied" on the source
    # later; with it, we give a clearer error.
    if id -Gn "$expected_owner" | tr ' ' '\n' | grep -qx "$SECRETS_GROUP"; then
      accept=1
    else
      echo "WARN: $SECRETS_FILE is group=$SECRETS_GROUP but user $expected_owner is NOT in $SECRETS_GROUP. Add them with: usermod -a -G $SECRETS_GROUP $expected_owner (then log out/in)." >&2
      return 1
    fi
  fi

  if [ "$accept" -ne 1 ]; then
    echo "WARN: $SECRETS_FILE has perms=$perms owner=$owner group=$group. Refusing to load. Either (a) chmod 600 and chown $expected_owner, OR (b) chmod 640 and chgrp $SECRETS_GROUP (with $expected_owner in $SECRETS_GROUP)." >&2
    return 1
  fi

  # shellcheck disable=SC1090
  . "$SECRETS_FILE"
  return 0
}
load_secrets

AGENT_NAME="$1"
PROJECT_NAME="$2"

# --- defaults (override with flags) ---
# MAX_TURNS is resolved per-agent later. Empty string here means "use the
# agent's default"; set on CLI with --max-turns N to override. The reason
# we don't just set MAX_TURNS=25 globally is that Vibe (Agent M) typically
# needs ~40-60 tool calls to complete a relay round because its file-edit
# operations are more granular than Claude Code's batched edits.
MAX_TURNS=""
EFFORT=""  # empty = use per-agent default (see resolution block below)
MODEL=""   # empty = use per-agent default

# ─── Load per-agent defaults from external file ─────────────────────────────
# Models, efforts, max-turns, and model maps live in agent_model_defaults.sh,
# expected in the same directory as this launcher. This lets you tune model
# choices without touching dispatch logic.
#
# Same-directory discovery via BASH_SOURCE means the load works regardless
# of cron's working directory or how the launcher was invoked.
#
# If the defaults file is missing we bail loudly — a silent fall-through
# with empty defaults would dispatch agents with empty MODEL strings and
# fail in confusing ways downstream.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULTS_FILE="${SCRIPT_DIR}/agent_model_defaults.sh"

if [ ! -f "$DEFAULTS_FILE" ]; then
  echo "FATAL: agent_model_defaults.sh not found at ${DEFAULTS_FILE}" >&2
  echo "       Copy it into the same directory as agent_call.sh and retry." >&2
  echo "       This file holds per-agent model strings, effort defaults," >&2
  echo "       max-turns, model maps, and the Agent D harness selector." >&2
  exit 1
fi

# shellcheck disable=SC1090
. "$DEFAULTS_FILE"

if [ -z "$AGENT_NAME" ] || [ -z "$PROJECT_NAME" ]; then
  echo "Usage: $0 \"Agent A|C|D|G|M|OG|OGF|OQ|OQF\" project_name [options]"
  echo ""
  echo "Agents:"
  echo "  Agent A    →  Claude Code (Opus)"
  echo "  Agent C    →  Codex (OpenAI GPT-5.x)"
  echo "  Agent D    →  Claude Code (DeepSeek backend)"
  echo "  Agent G    →  Gemini 2.5 Pro"
  echo "  Agent M    →  Mistral Vibe CLI (Devstral 2)"
  echo "  Agent OG   →  Claude Code (Google Gemma 4 31B via OpenRouter, paid)"
  echo "  Agent OGF  →  Claude Code (Google Gemma 4 31B via OpenRouter, FREE — 200/day cap)"
  echo "  Agent OQ   →  Claude Code (Qwen 3.6 35B A3B via OpenRouter, paid)"
  echo "  Agent OQF  →  Claude Code (Qwen free tier via OpenRouter — 200/day cap)"
  echo ""
  echo "Options:"
  echo "  --max-turns N      Max tool calls (default: 25)"
  echo "                     Claude only (A, D, OG, OGF, OQ, OQF) — ignored for G (Gemini) and C (Codex)"
  echo "  --effort LEVEL     Thinking effort: low, medium, high, xhigh, max"
  echo "                     (per-agent default: Claude=high, Gemini=n/a, OpenAI=high, DeepSeek=high,"
  echo "                      OpenRouter=high)"
  echo "  --model MODEL      Override the model for whichever agent is running"
  echo "  --gemini-preload   Pre-load whole project dir into Gemini's context"
  echo "                     (Agent G only — opt-in to original --include-directories"
  echo "                     behavior; default is lazy file reads)"
  echo ""
  echo "Agent D requires DEEPSEEK_API_KEY in /opt/claude/.env.secrets (mode 0600)."
  echo "Agent M requires MISTRAL_API_KEY in /opt/claude/.env.secrets (mode 0600)."
  echo "Agents OG/OGF/OQ/OQF require OPENROUTER_API_KEY in /opt/claude/.env.secrets (mode 0600)."
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
# Agent G; tracked separately so we can warn if it's passed to other agents.
GEMINI_PRELOAD=0
GEMINI_PRELOAD_USER_PROVIDED=0
# --max-price for Agent M. Default applied in the effort-resolution block
# below if the user didn't pass --max-price. Tracked separately so we can
# warn if it's passed for an agent that doesn't honor it.
MAX_PRICE=""
MAX_PRICE_USER_PROVIDED=0
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
    --max-price)
      MAX_PRICE="$2"
      MAX_PRICE_USER_PROVIDED=1
      shift 2
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
    "Agent C") EFFORT="$DEFAULT_OPENAI_EFFORT" ;;
    "Agent D") EFFORT="$DEFAULT_DEEPSEEK_EFFORT" ;;
    "Agent G") EFFORT="$DEFAULT_GEMINI_EFFORT" ;;
    "Agent M") EFFORT="$DEFAULT_MISTRAL_EFFORT" ;;
    "Agent OG"|"Agent OGF"|"Agent OQ"|"Agent OQF") EFFORT="$DEFAULT_OPENROUTER_EFFORT" ;;
  esac
fi

# --- resolve max-turns: CLI override or per-agent default ---
# Different agents have different per-round token budgets because their
# CLI harnesses vary in how granular their tool use is. The MAX_TURNS
# variable is left empty after argparse if the user didn't pass --max-turns,
# so we fall through to the per-agent default here.
if [ -z "$MAX_TURNS" ]; then
  case "$AGENT_NAME" in
    "Agent A") MAX_TURNS="$DEFAULT_CLAUDE_MAX_TURNS" ;;
    "Agent C") MAX_TURNS="$DEFAULT_OPENAI_MAX_TURNS" ;;
    "Agent D") MAX_TURNS="$DEFAULT_DEEPSEEK_MAX_TURNS" ;;
    "Agent G") MAX_TURNS="$DEFAULT_GEMINI_MAX_TURNS" ;;
    "Agent M") MAX_TURNS="$DEFAULT_MISTRAL_MAX_TURNS" ;;
    "Agent OG"|"Agent OGF"|"Agent OQ"|"Agent OQF") MAX_TURNS="$DEFAULT_OPENROUTER_MAX_TURNS" ;;
    *)         MAX_TURNS=25 ;;  # safety fallback for unknown agents
  esac
fi

# --- resolve max-price: CLI override or per-agent default ---
# Only Agent M has a use for max-price; for other agents it's silently
# accepted (so cron lines uniformly pass it) but ignored downstream.
if [ -z "$MAX_PRICE" ]; then
  case "$AGENT_NAME" in
    "Agent M") MAX_PRICE="$DEFAULT_MISTRAL_MAX_PRICE" ;;
    *)         MAX_PRICE="" ;;
  esac
fi

# --- validate effort level ---
# Claude Code: low, medium, high, xhigh (Opus 4.7 only), max
# Codex:       low, medium, high, xhigh, minimal   ('max' maps to xhigh below)
# Gemini:      n/a marker only (no CLI flag exists)
# DeepSeek/D:  same as Claude — Agent D runs the Claude Code CLI with DeepSeek
#              as the backend, and Claude Code's --effort flag works normally.
#
# 'minimal' is Codex-only; 'n/a' is valid only for Agent G (Gemini). Other
# values are cross-agent and pass validation here; see the Codex mapping
# block below for the 'max' -> 'xhigh' translation.
case "$EFFORT" in
  low|medium|high|xhigh|max) ;;
  minimal)
    if [ "$AGENT_NAME" != "Agent C" ]; then
      echo "ERROR: --effort 'minimal' is only valid for Agent C (Codex). For $AGENT_NAME use low/medium/high/xhigh/max."
      exit 1
    fi
    ;;
  n/a)
    if [ "$AGENT_NAME" != "Agent G" ] && [ "$AGENT_NAME" != "Agent M" ]; then
      echo "ERROR: --effort 'n/a' is only valid for Agent G (Gemini) and Agent M (Mistral Vibe) — neither CLI exposes an effort flag. For $AGENT_NAME use low/medium/high/xhigh/max."
      exit 1
    fi
    ;;
  *)
    echo "ERROR: Invalid effort level '${EFFORT}'. Must be: low, medium, high, xhigh, max, minimal, n/a"
    exit 1
    ;;
esac

# --- project directory setup (needed before model resolution to read next_round.txt) ---
BASE_DIR="/opt/claude"
PROJECT_DIR="${BASE_DIR}/${PROJECT_NAME}"

# --- resolve model: CLI override > next_round.txt mapping > RESEARCH fallback ---
#
# Precedence:
#   1. If user passed --model X, use X (no further logic).
#   2. Else, read ~/next_round.txt for the project. If it exists and parses,
#      identify the highest-percentage category and look up the model in the
#      current agent's model map.
#   3. Else, fall through to the RESEARCH entry of the agent's map. This
#      covers first runs on new projects (no file yet), malformed files,
#      and all-zero estimates. RESEARCH is chosen because (a) fresh runs
#      are typically research-flavored anyway and (b) RESEARCH maps to the
#      higher-capability model where the maps differ — safer to err toward
#      capability when we have no signal.
#
# Why these precedence rules:
#   - The CLI override is for emergencies / forced testing. Always wins.
#   - The next_round.txt mapping is for cost-savvy automation: cheaper model
#     when the queued workload is code-heavy and the slower frontier-tier
#     model isn't earning its tokens.
#   - The RESEARCH fallback gives sensible behavior on day-zero of a new
#     project and gracefully handles agents that aren't writing the file
#     yet. Use --model on the CLI if you want to bypass this.

# Helper: read next_round.txt and return the highest-percentage category.
# Echoes one of CODE / AUDIT / RESEARCH / WRITING on success, or empty
# string if the file is missing, malformed, or all percentages are zero.
parse_next_round_category() {
  local f="$1"
  [ -f "$f" ] || { echo ""; return; }

  # Look for the first line matching the strict format. Allow either order.
  # Pull each percentage; default missing ones to 0.
  local line code audit research writing
  line=$(grep -E '^(CODE|AUDIT|RESEARCH|WRITING)=' "$f" | head -5 | tr '\n' ' ')
  [ -z "$line" ] && { echo ""; return; }

  code=$(   echo "$line" | grep -oE 'CODE=[0-9]+'     | grep -oE '[0-9]+' || echo 0)
  audit=$(  echo "$line" | grep -oE 'AUDIT=[0-9]+'    | grep -oE '[0-9]+' || echo 0)
  research=$(echo "$line" | grep -oE 'RESEARCH=[0-9]+' | grep -oE '[0-9]+' || echo 0)
  writing=$(echo "$line" | grep -oE 'WRITING=[0-9]+'  | grep -oE '[0-9]+' || echo 0)
  code=${code:-0}; audit=${audit:-0}; research=${research:-0}; writing=${writing:-0}

  # Find max. Ties: priority order CODE > AUDIT > RESEARCH > WRITING.
  local max=$code; local cat="CODE"
  if [ "$audit"    -gt "$max" ]; then max=$audit;    cat="AUDIT";    fi
  if [ "$research" -gt "$max" ]; then max=$research; cat="RESEARCH"; fi
  if [ "$writing"  -gt "$max" ]; then max=$writing;  cat="WRITING";  fi

  # If all zero, treat as no signal.
  [ "$max" -eq 0 ] && { echo ""; return; }

  echo "$cat"
}

NEXT_ROUND_FILE="${PROJECT_DIR}/next_round.txt"
MODEL_SOURCE="default"   # tracking var for the START log line

if [ -n "$MODEL" ]; then
  MODEL_SOURCE="cli-override"
else
  # Try the next_round.txt mapping first
  ROUND_CATEGORY=$(parse_next_round_category "$NEXT_ROUND_FILE")
  if [ -n "$ROUND_CATEGORY" ]; then
    case "$AGENT_NAME" in
      "Agent A") MODEL="${CLAUDE_MODEL_MAP[$ROUND_CATEGORY]}" ;;
      "Agent C") MODEL="${OPENAI_MODEL_MAP[$ROUND_CATEGORY]}" ;;
      "Agent D") MODEL="${DEEPSEEK_MODEL_MAP[$ROUND_CATEGORY]}" ;;
      "Agent G") MODEL="${GEMINI_MODEL_MAP[$ROUND_CATEGORY]}" ;;
      "Agent M") MODEL="${MISTRAL_MODEL_MAP[$ROUND_CATEGORY]}" ;;
      "Agent OG")  MODEL="${OG_MODEL_MAP[$ROUND_CATEGORY]}" ;;
      "Agent OGF") MODEL="${OGF_MODEL_MAP[$ROUND_CATEGORY]}" ;;
      "Agent OQ")  MODEL="${OQ_MODEL_MAP[$ROUND_CATEGORY]}" ;;
      "Agent OQF") MODEL="${OQF_MODEL_MAP[$ROUND_CATEGORY]}" ;;
    esac
    if [ -n "$MODEL" ]; then
      MODEL_SOURCE="next-round:$ROUND_CATEGORY"
    fi
  fi

  # Fall through if nothing has set MODEL yet — happens when next_round.txt
  # is missing (first run on a new project), malformed, or all-zero. In all
  # these cases the launcher has no usable signal from the prior agent. We
  # default to the [RESEARCH] entry of the agent's map rather than a global
  # DEFAULT — the rationale is that fresh runs are usually research-flavored
  # (read the brief, understand existing state, plan), and RESEARCH happens
  # to map to the higher-capability model in the maps where tuning differs.
  # If you want the lower-cost default, pass --model on the CLI to override.
  if [ -z "$MODEL" ]; then
    case "$AGENT_NAME" in
      "Agent A") MODEL="${CLAUDE_MODEL_MAP[RESEARCH]}" ;;
      "Agent C") MODEL="${OPENAI_MODEL_MAP[RESEARCH]}" ;;
      "Agent D") MODEL="${DEEPSEEK_MODEL_MAP[RESEARCH]}" ;;
      "Agent G") MODEL="${GEMINI_MODEL_MAP[RESEARCH]}" ;;
      "Agent M") MODEL="${MISTRAL_MODEL_MAP[RESEARCH]}" ;;
      "Agent OG")  MODEL="${OG_MODEL_MAP[RESEARCH]}" ;;
      "Agent OGF") MODEL="${OGF_MODEL_MAP[RESEARCH]}" ;;
      "Agent OQ")  MODEL="${OQ_MODEL_MAP[RESEARCH]}" ;;
      "Agent OQF") MODEL="${OQF_MODEL_MAP[RESEARCH]}" ;;
    esac
    MODEL_SOURCE="default-research"
  fi
fi

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
AGY_BIN="/home/bubsmeany/.local/bin/agy" # "/usr/local/bin/agy" # Or your specific install path

# Mistral Vibe (Agent M). Vibe is a Python package, typically installed via
# `uv tool install mistral-vibe` or `pipx install mistral-vibe` — landing
# in ~/.local/bin/vibe or a pipx-venv path. Auto-detect across the usual
# spots; if nothing matches, leave empty and the agent block will abort
# cleanly when Agent M is invoked.
if [ -x "$HOME/.local/bin/vibe" ]; then
  MISTRAL_BIN="$HOME/.local/bin/vibe"
elif [ -x "$HOME/.local/pipx/venvs/mistral-vibe/bin/vibe" ]; then
  MISTRAL_BIN="$HOME/.local/pipx/venvs/mistral-vibe/bin/vibe"
elif command -v vibe >/dev/null 2>&1; then
  MISTRAL_BIN=$(command -v vibe)
else
  MISTRAL_BIN=""
fi

# Agent D uses the same Claude Code binary as Agent A when AGENT_D_HARNESS=claude.
# Environment variables in the D-only subshell redirect Claude Code to DeepSeek's
# Anthropic-compatible endpoint.
#
# When AGENT_D_HARNESS=aider, AIDER_BIN is resolved here so the legacy branch
# can find the binary. Auto-detection tries common install locations in order.
if [ "$AGENT_D_HARNESS" = "aider" ]; then
  if [ -x "$HOME/.local/bin/aider" ]; then
    AIDER_BIN="$HOME/.local/bin/aider"
  elif [ -x "$HOME/.local/pipx/venvs/aider-chat/bin/aider" ]; then
    AIDER_BIN="$HOME/.local/pipx/venvs/aider-chat/bin/aider"
  elif command -v aider >/dev/null 2>&1; then
    AIDER_BIN=$(command -v aider)
  else
    AIDER_BIN=""   # later check gives clean error if Agent D is invoked
  fi
fi

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
  # Defensive: if stat fails on both Linux and BSD flags (very rare — e.g.
  # the lock file disappears between the -f test and stat, or a filesystem
  # quirk), fall back to mtime=0 so lock_age becomes "now in seconds / 60"
  # which is huge → treat as stale → take over. Without the fallback, the
  # bare arithmetic `$(( now - )) / 60` errors with "integer expression
  # expected" and the script dies before reaching dispatch.
  lock_mtime=$(stat -c %Y "$LOCK_FILE" 2>/dev/null || stat -f %m "$LOCK_FILE" 2>/dev/null || echo 0)
  lock_age=$(( ( $(date +%s) - ${lock_mtime:-0} ) / 60 ))
  if [ "${lock_age:-0}" -lt 30 ]; then
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

if [ "$AGENT_NAME" = "Agent M" ]; then
  echo "$(date -Iseconds) | ${AGENT_NAME} | START (model: ${MODEL} [${MODEL_SOURCE}], effort: ${EFFORT}, max-turns: ${MAX_TURNS}, max-price: \$${MAX_PRICE})" >> "$LOG_FILE"
else
  echo "$(date -Iseconds) | ${AGENT_NAME} | START (model: ${MODEL} [${MODEL_SOURCE}], effort: ${EFFORT}, max-turns: ${MAX_TURNS})" >> "$LOG_FILE"
fi

# Warn if the user explicitly passed --effort to Agent G (Gemini). The Gemini
# CLI has no effort flag, so the value is silently ignored downstream. We
# surface that in the log so it's not a mystery. The per-agent default for
# Gemini is the sentinel "n/a" and doesn't trigger this warning.
if [ "$AGENT_NAME" = "Agent G" ] && [ "$EFFORT_USER_PROVIDED" -eq 1 ]; then
  echo "$(date -Iseconds) | ${AGENT_NAME} | WARN: --effort '${EFFORT}' ignored (agy CLI has no effort flag)" >> "$LOG_FILE"
fi
if [ "$AGENT_NAME" = "Agent M" ] && [ "$EFFORT_USER_PROVIDED" -eq 1 ]; then
  echo "$(date -Iseconds) | ${AGENT_NAME} | WARN: --effort '${EFFORT}' ignored (Mistral Vibe CLI has no effort flag)" >> "$LOG_FILE"
fi

# Warn if --max-price was passed to an agent that doesn't honor it. Only
# Agent M (Vibe) has --max-price. Silently ignored for others so cron lines
# that uniformly pass the flag still work.
if [ "$MAX_PRICE_USER_PROVIDED" -eq 1 ] && [ "$AGENT_NAME" != "Agent M" ]; then
  echo "$(date -Iseconds) | ${AGENT_NAME} | WARN: --max-price '${MAX_PRICE}' ignored (only Agent M / Mistral Vibe supports a hard price cap)" >> "$LOG_FILE"
fi

# Warn if the user explicitly passed --max-turns to an agent that doesn't
# support a turn/iteration cap. Claude Code has --max-turns; Gemini and Codex
# do not. Codex models run "a single turn" that can internally contain many
# tool calls, with context-window pressure as the natural bound — there's no
# CLI flag to cap the inner loop. Silently ignoring the flag is a footgun, so
# we surface it in the log when the user explicitly set it.
if [ "$MAX_TURNS_USER_PROVIDED" -eq 1 ]; then
  case "$AGENT_NAME" in
    "Agent G")
      echo "$(date -Iseconds) | ${AGENT_NAME} | WARN: --max-turns '${MAX_TURNS}' ignored (agy has no turn cap)" >> "$LOG_FILE"
      ;;
    "Agent C")
      echo "$(date -Iseconds) | ${AGENT_NAME} | WARN: --max-turns '${MAX_TURNS}' ignored (Codex CLI has no turn cap — Claude-only flag)" >> "$LOG_FILE"
      ;;
    "Agent D")
      # Only warn when the Aider harness is active. The Claude harness
      # respects --max-turns normally.
      if [ "$AGENT_D_HARNESS" = "aider" ]; then
        echo "$(date -Iseconds) | ${AGENT_NAME} | WARN: --max-turns '${MAX_TURNS}' ignored (AGENT_D_HARNESS=aider; Aider has no turn cap)" >> "$LOG_FILE"
      fi
      ;;
    # Agent D now runs Claude Code (with DeepSeek backend), so --max-turns
    # is respected. No warning needed.
  esac
fi




# Warn if --gemini-preload was passed for an agent other than G. The flag
# only affects Gemini's invocation (toggling --include-directories on/off),
# so passing it for Agent A or Agent C does nothing useful. We surface it
# in the log rather than failing — letting cron lines that uniformly pass
# the flag continue to run for whichever agent is up.
if [ "$GEMINI_PRELOAD_USER_PROVIDED" -eq 1 ] && [ "$AGENT_NAME" != "Agent G" ]; then
  echo "$(date -Iseconds) | ${AGENT_NAME} | WARN: --gemini-preload ignored (Agent G — Gemini only)" >> "$LOG_FILE"
fi

# Log when Gemini preload is actually engaged for G, so token cost is
# visible in the run history even when the rest of the run looks normal.
if [ "$AGENT_NAME" = "Agent G" ] && [ "$GEMINI_PRELOAD" -eq 1 ]; then
  echo "$(date -Iseconds) | ${AGENT_NAME} | NOTE: Agy --include-directories ENABLED (whole project pre-loaded into context)" >> "$LOG_FILE"
fi

# --- first-run bootstrap ---
# Ensure relay bookkeeping files exist before building the prompt. On a true
# first run (project just created, only PROJECT.md present), the agent prompt
# would otherwise inject "(passed.md not found)" and "(human_kept.md not
# found)" strings, which confuse weaker models. Creating the files here gives
# the agent a clean baseline to work from and matches AGENT_RELAY.md's
# Step 1 bootstrap promise ("files are created automatically").
#
# These are idempotent: touch and the if-guards never overwrite existing files.
mkdir -p "${PROJECT_DIR}/bkupmd"
mkdir -p "${PROJECT_DIR}/research"
mkdir -p "${PROJECT_DIR}/scratch"
mkdir -p "${PROJECT_DIR}/gitinfo"
touch "${PROJECT_DIR}/human.md"
if [ ! -f "${PROJECT_DIR}/passed.md" ]; then
  cat > "${PROJECT_DIR}/passed.md" <<'PASSED_SEED'
# Passed — Agent Handoff Log

## Last Run

- **Agent:** (none — this is the initial state)
- **Timestamp:** (project just started)
- **Run Duration:** N/A

## What I Did

- Nothing yet. This is the first run.

## What's Next

1. Read `PROJECT.md` and begin the first task defined there.

## Blockers / Warnings

- None — this is a fresh start.

## Notes

- First run has not happened yet. Treat this as iteration zero.
PASSED_SEED
fi
if [ ! -f "${PROJECT_DIR}/human_kept.md" ]; then
  cat > "${PROJECT_DIR}/human_kept.md" <<'KEPT_SEED'
# Human Kept — Persistent Lessons and Corrections

> This file is a running log of corrections and instructions from the project author.
> Each entry was originally delivered via `human.md` and appended here for permanence.
> **Treat every entry in this file as an active rule.** These are mistakes you or a prior
> agent have made before. Do not repeat them.

---
KEPT_SEED
fi

# --- preload shared context (token-efficient) ---
# Strategy: inject only as much context as each file type warrants.
#
#   passed.md     — tail the last 120 lines. The handoff format is self-contained
#                   per run; agents never need run history older than the previous
#                   round. Older entries live in bkupmd/ if a human needs them.
#
#   PROJECT.md    — inject in full. It is the authoritative brief; truncating it
#                   risks hiding routing rules or constraints.
#
#   human.md      — inject in full. It is a one-time override, typically tiny.
#
#   human_kept.md — inject the last 60 lines (roughly 4-6 recent entries).
#                   The file grows without bound; older entries are rarely
#                   actionable for the current run, and the most recent ones
#                   are what agents need to avoid repeating fresh mistakes.
#                   The full file is always on disk if an agent needs older entries.
PASSED_CONTENT=$(tail -n 120 "${PROJECT_DIR}/passed.md" 2>/dev/null || echo "(passed.md not found)")
PROJECT_CONTENT=$(cat "${PROJECT_DIR}/PROJECT.md" 2>/dev/null || echo "(PROJECT.md not found)")
HUMAN_CONTENT=$(cat "${PROJECT_DIR}/human.md" 2>/dev/null || echo "")
HUMAN_KEPT_CONTENT=$(tail -n 60 "${PROJECT_DIR}/human_kept.md" 2>/dev/null || echo "(human_kept.md not found)")

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



 
# --- Hard identity block ---
# Prepended to AGENT_PROMPT to anchor the model's self-identity. Without
# this, weaker models (Mistral Vibe in particular) sometimes autocomplete
# their own name as "Agent A" because surrounding context — AGENT_RELAY.md
# examples, the relay log, PROJECT.md role tables — mentions Agent A far
# more often than the agent's actual letter. The fix is to plant a clear,
# imperative identity statement at the very top of the prompt where the
# model can't miss it.
#
# AGENT_LETTER strips "Agent " from AGENT_NAME, leaving just "M", "A", "OQ"
# etc. We use both forms in the block so the model has a strong target
# regardless of whether it's writing "Agent M" or "M".
AGENT_LETTER="${AGENT_NAME#Agent }"
 
IDENTITY_BLOCK="=== AGENT IDENTITY (READ FIRST) ===
 
You are ${AGENT_NAME}. Your agent letter is: ${AGENT_LETTER}
 
Wherever you write your name in any handoff file (passed.md, human.md,
gitinfo/*.md, _HOOMAN.md, etc.), you write:
 
  Agent: ${AGENT_LETTER}
 
You are NOT Agent A unless your letter literally is A. The role
definitions in AGENT_RELAY.md and PROJECT.md describe a multi-agent
system; you fill the role assigned to ${AGENT_NAME} specifically. Examples
in those files that mention 'Agent A' are illustrative — they do NOT mean
that you are Agent A. Look up YOUR letter (${AGENT_LETTER}) in PROJECT.md's
role table to find your actual responsibilities.
 
If you find yourself about to write 'Agent: A' in a handoff file and your
letter is not A, STOP. Re-read this block. Write your actual letter:
${AGENT_LETTER}.
 
=== END AGENT IDENTITY ==="



AGENT_PROMPT="
${IDENTITY_BLOCK}

The lock file has already been written by the shell script. Do the following steps NOW using bash commands:

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

(g) Write ${PROJECT_DIR}/next_round.txt with your best estimate of what kind of work the NEXT agent's run will involve. The launcher reads this to pick a model variant for the next run (cheaper/faster for code-heavy work, frontier-tier for audit/research/writing). Format — one line, percentages summing to 100, all four categories present even if zero:

  CODE=N AUDIT=N RESEARCH=N WRITING=N

  Categories:
    CODE     — writing or modifying source code
    AUDIT    — reviewing existing code or content for problems
    RESEARCH — investigating something to inform a decision (docs, APIs, comparisons)
    WRITING  — prose: documentation, articles, content, copy

  Optionally add comment lines below the percentages explaining your reasoning:

    CODE=75 AUDIT=15 RESEARCH=10 WRITING=0
    # Generated by ${AGENT_NAME} at <timestamp>
    # Reasoning: Next task is implementing the new copy button across 6 pages.

  When in doubt: a fresh task starting → CODE-heavy. Mid-task with code already written → AUDIT-heavy. Approach unclear → RESEARCH-heavy. Documentation push → WRITING-heavy. Mixed work → split honestly.

(h) (Optional) Create done.txt only if all PROJECT.md tasks are truly complete and there is genuinely nothing for the next run to do. Err on the side of NOT creating it.

The launcher writes a WARN line to agent.log if any of passed.md, the three gitinfo files, or the _HOOMAN signal isn't updated. Do not skip steps to save turns — the WARNs will appear in the next agent's prompt context and degrade the relay.

The shell script releases the lock when you exit. Do not touch the lock file.

Begin immediately with STEP 2."

# --- Gemini prompt (no longer used, Agent G uses AGENT_PROMPT) ---
# (removed GEMINI_PROMPT definition)

# --- log the prompt being sent ---
LOG_PROMPT="$AGENT_PROMPT"
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

elif [ "$AGENT_NAME" = "Agent ZG" ]; then
  # ---- GEMINI ----
  # Agent G is the Google/Gemini slot; schedules and documentation have a
  # single Gemini identity.
  #
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
  # --skip-trust — Gemini CLI added a "trusted folders" gate (see
  # https://geminicli.com/docs/cli/trusted-folders/). In a headless launcher
  # context the project dir won't be in ~/.gemini/trustedFolders.json, so
  # without this flag the CLI silently downgrades --yolo to "default" approval
  # mode and refuses to act, logging only the trust-warning line. Equivalent
  # to setting GEMINI_CLI_TRUST_WORKSPACE=true. Safe here because the launcher
  # itself controls which project dir Gemini runs against.
  export GEMINI_SYSTEM_MD="${PROJECT_DIR}/.gemini_system.md"
  {
    echo "$IDENTITY_BLOCK"
    echo ""
    cat "$AGENT_RELAY"
  } > "$GEMINI_SYSTEM_MD"

  if [ "$GEMINI_PRELOAD" -eq 1 ]; then
    printf '%s' "$AGENT_PROMPT" | "$GEMINI_BIN" \
      --include-directories "$PROJECT_DIR" \
      --yolo \
      --skip-trust \
      --model "$MODEL" \
      -p "begin" >> "$LOG_FILE" 2>&1
  else
    printf '%s' "$AGENT_PROMPT" | "$GEMINI_BIN" \
      --yolo \
      --skip-trust \
      --model "$MODEL" \
      -p "begin" >> "$LOG_FILE" 2>&1
  fi

elif [ "$AGENT_NAME" = "Agent G" ]; then
  # ---- ANTIGRAVITY CLI (agy) ----
  # Agent G is the Google slot, now powered by Antigravity CLI.
  
  export AGY_SYSTEM_FILE="${PROJECT_DIR}/.agy_system.md"
  {
    echo "$IDENTITY_BLOCK"
    echo ""
    cat "$AGENT_RELAY"
  } > "$AGY_SYSTEM_FILE"

  # agy bypasses the interactive workspace trust prompt
  export AGY_TRUST_WORKSPACE=true
  
  # agy dropped the --model CLI flag, so we pass it via environment variable
  export AGY_MODEL="$MODEL"

  if [ "$GEMINI_PRELOAD" -eq 1 ]; then
    printf '%s' "$AGENT_PROMPT" | "$AGY_BIN" \
      --add-dir "$PROJECT_DIR" \
      --dangerously-skip-permissions \
      -p "begin" >> "$LOG_FILE" 2>&1
  else
    printf '%s' "$AGENT_PROMPT" | "$AGY_BIN" \
      --dangerously-skip-permissions \
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
  # Write AGENTS.md every run with the identity preamble, picking up edits to AGENT_RELAY.md.
  rm -f "$CODEX_HOME_DIR/AGENTS.md"
  {
    echo "$IDENTITY_BLOCK"
    echo ""
    cat "$AGENT_RELAY"
  } > "$CODEX_HOME_DIR/AGENTS.md"
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

elif [ "$AGENT_NAME" = "Agent D" ]; then
  # ---- AGENT D: harness selected by AGENT_D_HARNESS (top of file) ----
  #
  # Two harness implementations. The active one is selected by the
  # AGENT_D_HARNESS constant near the top:
  #   - "claude"  Claude Code with DeepSeek as the backend model
  #   - "aider"   Aider CLI pointed at DeepSeek (legacy)
  #
  # Both branches share DEEPSEEK_API_KEY check + MODEL resolution from
  # DEEPSEEK_MODEL_MAP. They differ in how the request is made to DeepSeek
  # and in what file-access tooling the model has available.

  if [ -z "$DEEPSEEK_API_KEY" ]; then
    echo "$(date -Iseconds) | ${AGENT_NAME} | ABORT: DEEPSEEK_API_KEY not set." >> "$LOG_FILE"
    echo "$(date -Iseconds) | ${AGENT_NAME} | ABORT:   Either load_secrets() didn't find ${SECRETS_FILE}," >> "$LOG_FILE"
    echo "$(date -Iseconds) | ${AGENT_NAME} | ABORT:   or its permissions failed validation (need 0600+owner or 0640+safeclaude)." >> "$LOG_FILE"
    echo "$(date -Iseconds) | ${AGENT_NAME} | ABORT:   See the earlier WARN lines for details." >> "$LOG_FILE"
    rm -f "$LOCK_FILE"
    exit 1
  fi

  if [ "$AGENT_D_HARNESS" = "claude" ]; then
    # ---- BRANCH: Claude Code + DeepSeek backend (default, recommended) ----
    #
    # Runs the same Claude Code binary as Agent A but with environment
    # variables that redirect it to DeepSeek's Anthropic-compatible endpoint.
    # Claude Code doesn't know it's not talking to Anthropic — tool calls,
    # file edits, sub-agents, /resume, MCP, --max-turns, --effort all work
    # normally because those features live in the harness, not the model.
    #
    # Auth scoping: env vars below are exported INSIDE the subshell, so
    # Agent A's subscription-based auth is never contaminated.
    #
    # Model name format: the Anthropic-compat endpoint expects the BARE
    # DeepSeek model name (e.g. "deepseek-v4-pro"), NOT prefixed with
    # "deepseek/". The prefix was a LiteLLM/Aider convention.
    (
      export ANTHROPIC_BASE_URL="https://api.deepseek.com/anthropic"
      export ANTHROPIC_AUTH_TOKEN="$DEEPSEEK_API_KEY"
      export ANTHROPIC_MODEL="$MODEL"
      export ANTHROPIC_DEFAULT_OPUS_MODEL="$MODEL"
      export ANTHROPIC_DEFAULT_SONNET_MODEL="$MODEL"
      # Haiku alias points to flash — Claude Code uses haiku for cheap/fast
      # quick tasks, and v4-flash is the right fit there.
      export ANTHROPIC_DEFAULT_HAIKU_MODEL="deepseek-v4-flash"
      export CLAUDE_CODE_SUBAGENT_MODEL="deepseek-v4-flash"
      export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1

      printf '%s' "$AGENT_PROMPT" | "$CLAUDE_BIN" \
        --add-dir "$PROJECT_DIR" \
        --dangerously-skip-permissions \
        --model "$MODEL" \
        --effort "$EFFORT" \
        --system-prompt-file "$AGENT_RELAY" \
        --no-session-persistence \
        --max-turns "$MAX_TURNS" \
        -p >> "$LOG_FILE" 2>&1
    )

  elif [ "$AGENT_D_HARNESS" = "aider" ]; then
    # ---- BRANCH: Aider + DeepSeek (legacy, kept for fallback) ----
    #
    # Aider's invocation model differs from Claude/Codex/Gemini in a few ways:
    #   - No effort flag. The model itself is the dial.
    #   - No turn cap. It runs until it decides it's done.
    #   - Expects git by default; we detect and pass --no-git if needed.
    #   - Prompt arrives via --message-file rather than stdin/argv.
    #   - CANNOT autonomously decide which files to read mid-session.
    #
    # Model name format: needs the "deepseek/" provider prefix for LiteLLM.

    if [ -z "$AIDER_BIN" ]; then
      echo "$(date -Iseconds) | ${AGENT_NAME} | ABORT: AGENT_D_HARNESS=aider but aider binary not found. Install with: pipx install aider-chat (or switch AGENT_D_HARNESS back to 'claude')." >> "$LOG_FILE"
      rm -f "$LOCK_FILE"
      exit 1
    fi

    AIDER_PROMPT_FILE="${PROJECT_DIR}/.aider_prompt.tmp"
    {
      echo "=== AGENT_RELAY.md (system context) ==="
      cat "$AGENT_RELAY"
      echo ""
      echo "=== Your task ==="
      printf '%s' "$AGENT_PROMPT"
    } > "$AIDER_PROMPT_FILE"

    trap 'rm -f "$AIDER_PROMPT_FILE"' EXIT INT TERM

    AIDER_GIT_FLAGS=""
    if [ -d "${PROJECT_DIR}/.git" ]; then
      AIDER_GIT_FLAGS="--no-auto-commits --no-dirty-commits"
    else
      AIDER_GIT_FLAGS="--no-git"
    fi

    AIDER_MODEL="$MODEL"
    case "$AIDER_MODEL" in
      deepseek/*)  ;;
      *) AIDER_MODEL="deepseek/${AIDER_MODEL}" ;;
    esac

    (
      cd "$PROJECT_DIR" || exit 1
      export DEEPSEEK_API_KEY
      "$AIDER_BIN" \
        --model "$AIDER_MODEL" \
        --message-file "$AIDER_PROMPT_FILE" \
        --cache-prompts \
        --no-detect-urls \
        --map-tokens 8192 \
        --yes-always \
        $AIDER_GIT_FLAGS \
        --no-stream \
        --no-show-model-warnings >> "$LOG_FILE" 2>&1
    )

  else
    echo "$(date -Iseconds) | ${AGENT_NAME} | ABORT: Unknown AGENT_D_HARNESS value '${AGENT_D_HARNESS}'. Valid: 'claude' or 'aider'." >> "$LOG_FILE"
    rm -f "$LOCK_FILE"
    exit 1
  fi

elif [ "$AGENT_NAME" = "Agent M" ]; then
  # ---- MISTRAL VIBE CLI (Devstral 2) ----
  #
  # Vibe is Mistral's agentic coding CLI, the closest analog to Claude Code
  # in our stack. Same agentic file tooling (read_file, write_file,
  # search_replace, bash, grep), project-aware context, first-class non-
  # interactive mode designed for scripting.
  #
  # Key design choices for this branch:
  #
  # 1. Project-scoped VIBE_HOME. Vibe stores config in ~/.vibe/ by default,
  #    but VIBE_HOME env var overrides. We point it at ${PROJECT_DIR}/.vibe
  #    so each project gets its own Vibe config, trusted-folder list, and
  #    session log — same pattern as Agent C uses with CODEX_HOME.
  #
  # 2. System prompt via custom agent profile. Vibe loads system prompts
  #    from $VIBE_HOME/prompts/<name>.md, referenced by system_prompt_id
  #    in an agent profile TOML at $VIBE_HOME/agents/<agentname>.toml.
  #    We symlink AGENT_RELAY.md into prompts/ and write a one-line agent
  #    profile that references it. --agent relay_m on the CLI activates it.
  #    Both files are regenerated every run so AGENT_RELAY.md edits are
  #    picked up automatically.
  #
  # 3. Temperature 0.2 — Mistral's official Devstral 2 recommendation for
  #    code work. Set in the config.toml model entry; Vibe has no CLI
  #    flag for this.
  #
  # 4. --max-price as a hard cost cap. Unique to Vibe in our stack; default
  #    $2.00 per run, overridable via --max-price CLI flag.
  #
  # 5. Trusted-folder bypass via config. Vibe normally prompts for trust
  #    on first run in a new directory. We pre-write the project dir into
  #    trusted_folders.toml so cron doesn't hang waiting for confirmation.
  #
  # 6. Auto-update disabled. Vibe pulls package updates on launch by
  #    default; for cron stability we pin to whatever version is installed.

  if [ -z "$MISTRAL_BIN" ]; then
    echo "$(date -Iseconds) | ${AGENT_NAME} | ABORT: Mistral Vibe binary not found. Install with: uv tool install mistral-vibe (or pipx install mistral-vibe)." >> "$LOG_FILE"
    rm -f "$LOCK_FILE"
    exit 1
  fi

  if [ -z "$MISTRAL_API_KEY" ]; then
    echo "$(date -Iseconds) | ${AGENT_NAME} | ABORT: MISTRAL_API_KEY not set." >> "$LOG_FILE"
    echo "$(date -Iseconds) | ${AGENT_NAME} | ABORT:   Either load_secrets() didn't find ${SECRETS_FILE}," >> "$LOG_FILE"
    echo "$(date -Iseconds) | ${AGENT_NAME} | ABORT:   or its permissions failed validation (need 0600+owner or 0640+safeclaude)." >> "$LOG_FILE"
    rm -f "$LOCK_FILE"
    exit 1
  fi

  VIBE_HOME_DIR="${PROJECT_DIR}/.vibe"
  mkdir -p "$VIBE_HOME_DIR/prompts" "$VIBE_HOME_DIR/agents"

  # System prompt: AGENT_RELAY.md prefixed with a per-agent identity
  # preamble. We used to symlink AGENT_RELAY.md here, but Mistral Large
  # treats the system prompt as authoritative and AGENT_RELAY.md's
  # "Your Identity" section opens with "**Agent A** — runs via a primary
  # service" as the first example. That made Mistral autocomplete its own
  # name as Agent A in passed.md regardless of the IDENTITY block planted
  # in the user message. Claude Code (Agents A/D/OG/OGF/OQ/OQF) shrugs
  # that off because of stronger instruction-following; Mistral does not.
  #
  # Fix: write a real file (not a symlink) whose FIRST bytes are a
  # short, imperative identity statement. Then concatenate AGENT_RELAY.md
  # after it. The preamble comes first so the model sees its true
  # identity before the multi-agent example list.
  #
  # We rewrite this every run because AGENT_LETTER / AGENT_NAME could
  # differ run-to-run if the same project ever ran a different agent
  # variant (it won't here — this whole branch is Agent M — but the
  # write-every-run pattern matches how config.toml and relay_m.toml
  # below are handled). Also rewrites pick up edits to AGENT_RELAY.md.
  # Remove any old symlink left over from the prior implementation.
  rm -f "$VIBE_HOME_DIR/prompts/relay.md"
  {
    cat <<EOF
=== AGENT IDENTITY (READ FIRST — THIS OVERRIDES ALL EXAMPLES BELOW) ===

You are ${AGENT_NAME}. Your agent letter is: ${AGENT_LETTER}.

Wherever you write your name in any handoff file (passed.md, human.md,
gitinfo/*.md, _HOOMAN.md, etc.), you write:

  Agent: ${AGENT_LETTER}

The "Your Identity" section further down in this system prompt lists
"Agent A", "Agent C", "Agent G" etc. as EXAMPLES of the multi-agent
system. Those are NOT your identity unless your letter literally matches.
Your letter is ${AGENT_LETTER}. Do not autocomplete to "Agent A" just
because that example appears first in the list.

If you find yourself about to write "Agent: A" in a handoff file and
${AGENT_LETTER} is not A, STOP. Re-read this block. Write your actual
letter: ${AGENT_LETTER}.

=== END AGENT IDENTITY ===

EOF
    cat "$AGENT_RELAY"
  } > "$VIBE_HOME_DIR/prompts/relay.md"

  # config.toml: registers the Mistral provider, declares BOTH models we use
  # (devstral-medium-latest for CODE rounds, mistral-large-latest for
  # everything else), sets the active model to whichever one MODEL resolved
  # to this round, and turns off auto-update and welcome-banner animation
  # (cron-friendly).
  #
  # Both models are declared even though only one is active per run, so the
  # config is internally consistent if you ever invoke `vibe /model` to
  # swap mid-session (we don't, but it's defensively correct).
  #
  # Pricing per million tokens (Mistral published rates as of May 2026):
  #   devstral-medium-latest : $0.40 input / $2.00 output  (Devstral 2 family)
  #   mistral-large-latest   : $2.00 input / $6.00 output  (general flagship)
  #
  # Note: Mistral Large is meaningfully more expensive than Devstral. The
  # --max-price cap (default $2.00) is the safety net if a non-code round
  # runs long. Adjust DEFAULT_MISTRAL_MAX_PRICE if you see false aborts.
  #
  # We write this every run so changes to MODEL, the map, or the temperature
  # constants propagate on next invocation.
  cat > "$VIBE_HOME_DIR/config.toml" <<EOF
active_model = "$MODEL"
textual_theme = "textual-dark"
vim_keybindings = false
enable_update_checks = false
disable_welcome_banner_animation = true
enable_telemetry = false

[[providers]]
name = "mistral"
api_base = "https://api.mistral.ai/v1"
api_key_env_var = "MISTRAL_API_KEY"
backend = "mistral"

[[models]]
name = "devstral-medium-latest"
provider = "mistral"
alias = "devstral-medium-latest"
temperature = $DEFAULT_MISTRAL_TEMP
input_price = 0.4
output_price = 2.0

[[models]]
name = "mistral-large-latest"
provider = "mistral"
alias = "mistral-large-latest"
temperature = $DEFAULT_MISTRAL_TEMP
# Mistral Large 3 (Dec 2025), which is what mistral-large-latest resolves to
# as of May 2026. Old Large 2 was \$2.00/\$6.00; Large 3 dropped to \$0.50/\$1.50.
# Vibe uses these numbers to compute --max-price spend internally, so getting
# them right matters: stale Large 2 prices made every run look 4x more
# expensive than it actually was and tripped the cap prematurely.
input_price = 0.5
output_price = 1.5
EOF

  # Agent profile: references the system prompt and sets auto-approve so
  # Vibe doesn't ask for tool-execution approvals in cron.
  #
  # NOTE 1: Top-level invocable agents do NOT have an agent_type field —
  # that field is reserved for subagents (agent_type = "subagent"). Having
  # agent_type = "main" causes pydantic validation to reject the file
  # silently, manifesting as "Agent 'relay_m' not found." Don't add it.
  #
  # NOTE 2: auto_approve = true alone is NOT enough to actually let tools
  # execute. It only controls the user-approval *flow*. Each tool also needs
  # an explicit [tools.<name>] block with permission = "always", or Vibe
  # rejects the tool call with "Tool execution not permitted" in programmatic
  # mode (there's no human to satisfy a default ASK permission). The official
  # docs example confirms this pattern. We grant permission for every tool
  # the relay needs: bash, read_file, write_file, search_replace, grep, todo.
  # safety = "yolo" indicates "no safety guardrails" (purely visual; pairs
  # with the permission grants for explicit intent).
  cat > "$VIBE_HOME_DIR/agents/relay_m.toml" <<EOF
display_name = "Relay Agent M"
description = "Mistral Vibe agent for the multi-engine code relay system."
safety = "yolo"
active_model = "$MODEL"
system_prompt_id = "relay"
auto_approve = true

[tools.bash]
permission = "always"

[tools.read_file]
permission = "always"

[tools.write_file]
permission = "always"

[tools.search_replace]
permission = "always"

[tools.grep]
permission = "always"

[tools.todo]
permission = "always"
EOF

  # Trusted folders: pre-mark the project dir as trusted so Vibe doesn't
  # prompt for confirmation on first run.
  cat > "$VIBE_HOME_DIR/trusted_folders.toml" <<EOF
trusted_folders = ["$PROJECT_DIR"]
EOF

  # Run Vibe. Stdin piping keeps long prompts safe from ARG_MAX. --workdir
  # tells Vibe where to operate (matches Claude's --add-dir / Codex's --cd).
  # Trust the project dir. Vibe's trust-folder safety system checks for an
  # authorized .vibe/ subdir before any tool execution. Pre-writing
  # trusted_folders.toml ourselves doesn't work — the .vibe/ dir itself
  # isn't trusted yet, so Vibe ignores its own config. The documented
  # bypass is --trust on the CLI. Idempotent — Vibe just records the
  # authorization in trusted_folders.toml so it sticks for future runs.
  # We pass it every run so the relay's behavior is independent of any
  # prior state.
  # Run Vibe. We override HOME to the project directory before invoking,
  # so that `~/passed.md`, `~/gitinfo/...`, `~/_HOOMAN.md` and other
  # tilde-relative paths in the system prompt resolve to the project root
  # rather than the calling user's actual home directory.
  #
  # Background: Claude Code (Agent A, D) and Codex (Agent C) interpret
  # `~/` references in their tool calls against the directory passed to
  # --add-dir or --cd. The agent ends up writing to PROJECT_DIR/passed.md
  # transparently. Vibe doesn't — its stateful bash tool inherits the
  # parent shell's HOME, which is the system user's home (e.g.
  # /home/bubsmeany). So `cat > ~/passed.md` from inside Vibe would land
  # at /home/bubsmeany/passed.md, not /opt/claude/<project>/passed.md.
  #
  # The launcher's mtime checks then fail because the project's passed.md
  # was never touched. Symptom: every Step 6 file write logs a WARN about
  # "fabricated" output even though Vibe ran cleanly with exit code 0.
  #
  # The HOME override below is the surgical fix: Vibe's bash sees
  # HOME=PROJECT_DIR, so ~/foo becomes PROJECT_DIR/foo, matching what
  # the launcher expects. VIBE_HOME still points at the .vibe/ config
  # dir (separate variable, controls config location only).
  (
    export HOME="$PROJECT_DIR"
    export VIBE_HOME="$VIBE_HOME_DIR"
    export MISTRAL_API_KEY
    printf '%s' "$AGENT_PROMPT" | "$MISTRAL_BIN" \
      --prompt - \
      --trust \
      --agent relay_m \
      --max-turns "$MAX_TURNS" \
      --max-price "$MAX_PRICE" \
      --workdir "$PROJECT_DIR" \
      --output streaming >> "$LOG_FILE" 2>&1
  )

elif [ "$AGENT_NAME" = "Agent OG" ] || [ "$AGENT_NAME" = "Agent OGF" ] || [ "$AGENT_NAME" = "Agent OQ" ] || [ "$AGENT_NAME" = "Agent OQF" ]; then
  # ─── AGENTS OG / OGF / OQ / OQF — Claude Code via OpenRouter ────────────────
  #
  # All OpenRouter agents share the Claude Code harness (same binary as Agents A
  # and D) with environment variables that redirect to OpenRouter's
  # Anthropic-compatible endpoint. From Claude Code's perspective, nothing
  # changes — tool calls, file edits, --max-turns, --effort, sub-agents all
  # behave the same. OpenRouter handles the protocol translation and routes
  # to the backend model (Gemma 4 31B / Gemma 4 31B free / Qwen 3.6 35B A3B /
  # Qwen free tier).
  #
  # Why grouped instead of separate branches: the env-var pattern is identical
  # across them; only the model string differs. Splitting into separate
  # branches would multiply the maintenance burden. The MODEL variable was
  # already set in the model-resolution block above via OG_MODEL_MAP,
  # OGF_MODEL_MAP, OQ_MODEL_MAP, or OQF_MODEL_MAP.
  #
  # Key requirements verified upstream:
  #   - OPENROUTER_API_KEY is in env (loaded by load_secrets earlier)
  #   - CLAUDE_BIN is set (the binary detection happens in the Agent A/D path)
  #
  # Cost/safety notes:
  #   - OG and OQ are paid models; per-run cost typically well under $1.
  #   - OGF and OQF are free tier: 20 req/min, 200/day. A relay run can easily hit
  #     the daily cap. If either gets a 429 mid-run, Claude Code will retry a
  #     few times and then exit. The handoff files may be incomplete — same
  #     as any other rate-limit failure.

  if [ -z "$OPENROUTER_API_KEY" ]; then
    echo "$(date -Iseconds) | ${AGENT_NAME} | ABORT: OPENROUTER_API_KEY not set." >> "$LOG_FILE"
    echo "$(date -Iseconds) | ${AGENT_NAME} | ABORT:   Either load_secrets() didn't find ${SECRETS_FILE}," >> "$LOG_FILE"
    echo "$(date -Iseconds) | ${AGENT_NAME} | ABORT:   the file's permissions are wrong (need 0600 owned by you, or 0640 with you in ${SECRETS_GROUP})," >> "$LOG_FILE"
    echo "$(date -Iseconds) | ${AGENT_NAME} | ABORT:   or the key line is missing/malformed. Get one at https://openrouter.ai/keys" >> "$LOG_FILE"
    rm -f "$LOCK_FILE"
    exit 1
  fi

  if [ -z "$CLAUDE_BIN" ]; then
    echo "$(date -Iseconds) | ${AGENT_NAME} | ABORT: Claude Code binary not found." >> "$LOG_FILE"
    echo "$(date -Iseconds) | ${AGENT_NAME} | ABORT:   OpenRouter agents use Claude Code as the harness." >> "$LOG_FILE"
    echo "$(date -Iseconds) | ${AGENT_NAME} | ABORT:   Install with: npm install -g @anthropic-ai/claude-code" >> "$LOG_FILE"
    rm -f "$LOCK_FILE"
    exit 1
  fi

  # Free-tier rate-limit warning. Not an error; just a
  # heads-up in the log so the operator knows why a partial run might happen.
  if [ "$AGENT_NAME" = "Agent OGF" ] || [ "$AGENT_NAME" = "Agent OQF" ]; then
    echo "$(date -Iseconds) | ${AGENT_NAME} | NOTE: ${AGENT_NAME#Agent } is on OpenRouter's free tier (20 req/min, 200/day). A typical relay run can consume the daily cap; partial runs are expected." >> "$LOG_FILE"
  fi

  # The env redirect. Same pattern as Agent D's Claude Code branch but
  # pointed at OpenRouter instead of DeepSeek.
  #
  # Critical: ANTHROPIC_API_KEY MUST be empty. Claude Code prefers it over
  # ANTHROPIC_AUTH_TOKEN when both are set, and would try to hit Anthropic
  # directly with a key Anthropic doesn't recognize. OpenRouter's official
  # guide spells this out explicitly.
  #
  # Base URL is "https://openrouter.ai/api" — NOT "/api/v1". Claude Code
  # appends "/v1/messages" itself; "/api/v1" would produce "/v1/v1/messages"
  # and 404 every request. Multiple setup guides on the internet get this
  # wrong; we've verified against OpenRouter's official docs.
  (
    export ANTHROPIC_BASE_URL="https://openrouter.ai/api"
    export ANTHROPIC_AUTH_TOKEN="$OPENROUTER_API_KEY"
    export ANTHROPIC_API_KEY=""
    export ANTHROPIC_MODEL="$MODEL"
    export ANTHROPIC_DEFAULT_OPUS_MODEL="$MODEL"
    export ANTHROPIC_DEFAULT_SONNET_MODEL="$MODEL"
    # For HAIKU / sub-agent fast-model fallback, route to the same backend
    # model. OpenRouter doesn't have a "faster cheaper" relative to these
    # specific models the way DeepSeek has v4-flash — Gemma 4 and Qwen
    # don't ship distinct fast variants through OpenRouter at the time of
    # this writing. Reusing the main model avoids the harness reaching for
    # an undefined cheap-fast alias.
    export ANTHROPIC_DEFAULT_HAIKU_MODEL="$MODEL"
    export CLAUDE_CODE_SUBAGENT_MODEL="$MODEL"
    export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1

    printf '%s' "$AGENT_PROMPT" | "$CLAUDE_BIN" \
      --add-dir "$PROJECT_DIR" \
      --dangerously-skip-permissions \
      --model "$MODEL" \
      --effort "$EFFORT" \
      --system-prompt-file "$AGENT_RELAY" \
      --no-session-persistence \
      --max-turns "$MAX_TURNS" \
      -p >> "$LOG_FILE" 2>&1
  )

else
  echo "$(date -Iseconds) | ${AGENT_NAME} | ERROR: Unknown agent name." >> "$LOG_FILE"
  rm -f "$LOCK_FILE"
  exit 1
fi

EXIT_CODE=${?:-0}

# Defensive: in rare cases (e.g. a dispatch branch's subshell pipeline ends
# without setting $? to an integer, or some shell-state oddity) EXIT_CODE
# could end up empty. The downstream `[ "$EXIT_CODE" -eq 0 ]` test would
# then fail with "integer expression expected" and the post-run validation
# block would be skipped. Force a numeric value.
EXIT_CODE="${EXIT_CODE:-0}"
case "$EXIT_CODE" in
  ''|*[!0-9]*) EXIT_CODE=0 ;;
esac

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

  
# Catches the failure mode where the model writes the wrong agent letter
# in passed.md's "## Last Run" section — typically autocompleting "Agent A"
# from surrounding context. This is NOT a substitute for the IDENTITY block
# at the top of AGENT_PROMPT (which prevents the bug); it's a tripwire so
# we know if/when the bug recurs anyway.
#
# Format expected in passed.md (the relay convention):
#   ## Last Run
#   - **Agent:** M
#   - **Timestamp:** 2026-05-15T16:17:07-05:00
#
# We scan the FIRST occurrence of "## Last Run" only (the most recent run's
# header — older runs are below the Run Notes archive and we don't care
# about them).
if [ -f "${PROJECT_DIR}/passed.md" ]; then
  EXPECTED_LETTER="${AGENT_NAME#Agent }"
  # Pull the first 5 lines after "## Last Run" and find the Agent line.
  # The grep+head pattern keeps us looking at only the most recent header,
  # not any historical entries deeper in the file.
  ACTUAL_LETTER=$(awk '/^## Last Run/{found=1; next} found && /\*\*Agent:\*\*/{
      match($0, /\*\*Agent:\*\*[ \t]*([A-Za-z]+)/, arr); print arr[1]; exit
  }' "${PROJECT_DIR}/passed.md")
 
  if [ -z "$ACTUAL_LETTER" ]; then
    echo "$(date -Iseconds) | ${AGENT_NAME} | WARN: passed.md exists but has no '## Last Run' / '**Agent:**' header. The agent may not have updated passed.md, or wrote a malformed header." >> "$LOG_FILE"
  elif [ "$ACTUAL_LETTER" != "$EXPECTED_LETTER" ]; then
    echo "$(date -Iseconds) | ${AGENT_NAME} | WARN: passed.md Last Run header says 'Agent: ${ACTUAL_LETTER}' but this run is ${AGENT_NAME} (expected letter: ${EXPECTED_LETTER}). The model misidentified itself. Check the prompt's IDENTITY block and verify it was actually prepended." >> "$LOG_FILE"
  else
    # Optional positive log line — useful when debugging, harmless in prod.
    # Comment out if you don't want it cluttering the log on every run.
    echo "$(date -Iseconds) | ${AGENT_NAME} | OK: passed.md Last Run identity matches (Agent: ${ACTUAL_LETTER})" >> "$LOG_FILE"
  fi
else
  # If passed.md doesn't exist at all, the mtime/file-change validator above
  # has already complained. We don't duplicate that warning here.
  :
fi




if [ "${EXIT_CODE:-0}" -eq 0 ]; then
  # passed.md — load-bearing for the next agent. Worst case if missed.
  PASSED_MTIME_AFTER=$(snap_mtime "$PASSED_FILE")
  PASSED_MTIME_AFTER="${PASSED_MTIME_AFTER:-0}"
  PASSED_MTIME_BEFORE="${PASSED_MTIME_BEFORE:-0}"
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
  OVERVIEW_MTIME_AFTER="${OVERVIEW_MTIME_AFTER:-0}"
  OVERVIEW_MTIME_BEFORE="${OVERVIEW_MTIME_BEFORE:-0}"
  if [ "$OVERVIEW_MTIME_AFTER" -le "$OVERVIEW_MTIME_BEFORE" ]; then
    echo "$(date -Iseconds) | ${AGENT_NAME} | WARN: gitinfo/git_overview.md was not updated this run (Step 6f skipped or fabricated). GitHub-facing project pitch is stale." >> "$LOG_FILE"
  fi

  ROUND_MTIME_AFTER=$(snap_mtime "$ROUND_FILE")
  ROUND_MTIME_AFTER="${ROUND_MTIME_AFTER:-0}"
  ROUND_MTIME_BEFORE="${ROUND_MTIME_BEFORE:-0}"
  if [ "$ROUND_MTIME_AFTER" -le "$ROUND_MTIME_BEFORE" ]; then
    echo "$(date -Iseconds) | ${AGENT_NAME} | WARN: gitinfo/git_update_round.md was not updated this run (Step 6f skipped or fabricated). This run's snapshot for outside readers is missing." >> "$LOG_FILE"
  fi

  ALL_MTIME_AFTER=$(snap_mtime "$ALL_FILE")
  ALL_MTIME_AFTER="${ALL_MTIME_AFTER:-0}"
  ALL_MTIME_BEFORE="${ALL_MTIME_BEFORE:-0}"
  if [ "$ALL_MTIME_AFTER" -le "$ALL_MTIME_BEFORE" ]; then
    echo "$(date -Iseconds) | ${AGENT_NAME} | WARN: gitinfo/git_updates_all.md was not appended to this run (Step 6f skipped or fabricated). The cumulative update log is missing this round's entry." >> "$LOG_FILE"
  fi

  # HOOMAN signal — exactly one of _HOOMAN.md OR _HOOMAN_CLEAN_*.md must
  # exist after a run. The agent might have written EITHER one. We pass
  # the check if EITHER mtime advanced past its respective snapshot, OR
  # if a _HOOMAN.md (which had no pre-run snapshot for this state) now
  # exists. Otherwise warn.
  HOOMAN_MTIME_AFTER=$(snap_mtime "$HOOMAN_FILE")
  HOOMAN_MTIME_AFTER="${HOOMAN_MTIME_AFTER:-0}"
  HOOMAN_MTIME_BEFORE="${HOOMAN_MTIME_BEFORE:-0}"
  HOOMAN_CLEAN_MTIME_AFTER=$(snap_hooman_clean_mtime)
  HOOMAN_CLEAN_MTIME_AFTER="${HOOMAN_CLEAN_MTIME_AFTER:-0}"
  HOOMAN_CLEAN_MTIME_BEFORE="${HOOMAN_CLEAN_MTIME_BEFORE:-0}"
  HOOMAN_TOUCHED=0
  [ "$HOOMAN_MTIME_AFTER" -gt "$HOOMAN_MTIME_BEFORE" ] && HOOMAN_TOUCHED=1
  [ "$HOOMAN_CLEAN_MTIME_AFTER" -gt "$HOOMAN_CLEAN_MTIME_BEFORE" ] && HOOMAN_TOUCHED=1
  if [ "${HOOMAN_TOUCHED:-0}" -eq 0 ]; then
    echo "$(date -Iseconds) | ${AGENT_NAME} | WARN: neither _HOOMAN.md nor _HOOMAN_CLEAN_*.md was written this run (Step 6g skipped or fabricated). The agent-to-human signal is stale; check manually whether anything needs your attention." >> "$LOG_FILE"
  fi
fi

# --- release lock ---
rm -f "$LOCK_FILE"

if [ -f "$LOG_FILE" ]; then
  tail -n 5000 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
fi

echo "$(date -Iseconds) | ${AGENT_NAME} | DONE (exit code: ${EXIT_CODE})" >> "$LOG_FILE"
