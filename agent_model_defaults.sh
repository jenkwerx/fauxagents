#!/bin/bash
# ============================================================
# agent_model_defaults.sh
# Per-agent model / effort / max-turns / model-map defaults.
#
# Sourced by agent_call.sh — does NOT run standalone. The launcher
# expects this file in the same directory as itself; it bails out
# with a clear error if missing.
#
# WHY THIS FILE EXISTS:
# Model names change. Pricing tiers shift. New variants release. Editing
# all of that meant editing the dispatch logic in agent_call.sh, with
# every change carrying the risk of breaking control flow. Pulling the
# values out into here lets you tune models without touching dispatch.
#
# WHAT BELONGS HERE:
#   - Default model strings per agent (DEFAULT_*_MODEL)
#   - Reasoning effort defaults (DEFAULT_*_EFFORT)
#   - Tool-call budgets (DEFAULT_*_MAX_TURNS)
#   - Provider-specific knobs (e.g. DEFAULT_MISTRAL_MAX_PRICE, DEFAULT_MISTRAL_TEMP)
#   - Category-keyed model maps (CLAUDE_MODEL_MAP, GEMINI_MODEL_MAP, etc.)
#   - Provider-mode toggles that don't change frequently (AGENT_D_HARNESS)
#
# WHAT DOESN'T BELONG HERE:
#   - Binary path detection (CLAUDE_BIN, MISTRAL_BIN, etc.) — those have
#     runtime side effects (command -v, [ -x ]) and live in agent_call.sh.
#   - Dispatch logic, env-var manipulation, lock-file handling.
#   - Anything that needs argument parsing or per-invocation context.
# ============================================================


# ─── Per-agent default models ────────────────────────────────────────────────
# Used when no CLI --model was passed AND no per-round MODEL_MAP entry
# applies. The model maps below override these for category-based routing.
DEFAULT_CLAUDE_MODEL="claude-opus-4-7"

DEFAULT_GEMINI_MODEL_THREEONE="gemini-3.1-pro-preview"
DEFAULT_GEMINI_MODEL="gemini-2.5-pro"
# As of May 2026, Gemini 2.5 Pro Preview is current and is what the new 
# Antigravity CLI (agy) defaults to. It's still labeled "preview" —
# there's no stable gemini-3.1-pro alias yet, only the preview. If your
# account doesn't have access, agy will reject this model name and
# you can roll back to "gemini-2.5-pro" until access is granted.
DEFAULT_OPENAI_MODEL="gpt-5.4"


# ─── Per-agent default effort ────────────────────────────────────────────────
# Mirrors YRGE's yrge_fetcher.py effort constants so the two systems behave
# consistently. Gemini and Vibe have no CLI effort flag — the value "n/a"
# is kept for symmetry but is never passed through to those binaries.
DEFAULT_CLAUDE_EFFORT="high"     # low / medium / high / xhigh (Opus 4.7 only) / max
DEFAULT_GEMINI_EFFORT="n/a"      # Gemini CLI has no effort flag — marker only
DEFAULT_OPENAI_EFFORT="high"     # low / medium / high / xhigh (no max — Codex ceiling is xhigh)
DEFAULT_DEEPSEEK_EFFORT="high"   # Used when AGENT_D_HARNESS=claude (Claude Code's effort flag).
                                 # Silently ignored when AGENT_D_HARNESS=aider (Aider has no effort flag).
DEFAULT_MISTRAL_EFFORT="n/a"     # Vibe has no effort flag (like Gemini)
DEFAULT_OPENROUTER_EFFORT="high" # Claude Code's effort flag works with the redirected backend
                                 # the same way it does for Agent A. The model receives the
                                 # "high effort" signal via the system prompt Claude Code injects.


# ─── Per-agent default max-turns ─────────────────────────────────────────────
# Different agents need different turn budgets to complete a relay round.
# Claude Code (A, D, OG, OGF, OQ) batches reads + edits more aggressively
# than Vibe. Gemini and Codex ignore --max-turns entirely. Vibe (M) needs
# the highest ceiling because its tool-use is the most granular — each
# file edit is 2-3 calls (read, search_replace, sometimes a verify-read).
#
# IMPORTANT: when an agent hits max-turns, it stops where it is. None of
# our agents resume mid-task — each launcher invocation is a fresh session.
# The relay's continuity comes from passed.md (the agent writes its
# handoff there at end of run), not from session state. So if max-turns
# kills an agent BEFORE it writes passed.md, that run's work is lost.
# Pick budgets that comfortably accommodate the full relay round plus
# some actual audit/code work. 50 is reasonable for most agents; Vibe
# needs more headroom (100) plus its --max-price cap as a $$$ safety net.
DEFAULT_CLAUDE_MAX_TURNS=100       # Claude Code batches; 50 gives comfortable margin
DEFAULT_GEMINI_MAX_TURNS=100       # Marker only — Gemini CLI ignores --max-turns
DEFAULT_OPENAI_MAX_TURNS=100       # Marker only — Codex CLI ignores --max-turns
DEFAULT_DEEPSEEK_MAX_TURNS=100     # Same harness as A (Claude Code), same default
DEFAULT_MISTRAL_MAX_TURNS=200     # Vibe is more granular; needs a bigger budget
DEFAULT_OPENROUTER_MAX_TURNS=50   # Mirrors Claude/DeepSeek defaults. For OGF specifically,
                                  # you may want a lower cap to avoid burning the
                                  # free-tier daily quota in a single run.


# ─── Mistral Vibe specifics ──────────────────────────────────────────────────
# Knobs that exist for Vibe and only Vibe — no equivalent on other agents.
#
#   DEFAULT_MISTRAL_MAX_PRICE  Hard cost cap. Aborts the session if total spend
#                              exceeds this. UNIQUE TO VIBE — no other CLI in
#                              the stack has it. Computed against the model's
#                              declared input/output prices in config.toml,
#                              NOT against actual billed cost (so the cap
#                              fires regardless of whether you're on the free
#                              Experiment plan or the paid Scale plan).
#                              At $20, the cap functions as a runaway-loop
#                              circuit breaker rather than a real cost ceiling
#                              — a normal audit run should consume well under
#                              $1 of list-priced tokens; hitting $20 means
#                              Vibe is genuinely stuck. If you switch to the
#                              Scale plan and pay real money per token, drop
#                              this back to $2.00 or so.
#
#   DEFAULT_MISTRAL_TEMP       NOT a CLI flag — written into the [models]
#                              entry of the generated config.toml. Mistral
#                              officially recommends 0.2 for Devstral 2 code
#                              work. Lower = more deterministic edits.
DEFAULT_MISTRAL_MAX_PRICE="20.00"
DEFAULT_MISTRAL_TEMP="0.2"


# ─── Agent D harness selector ────────────────────────────────────────────────
# Two harness implementations are kept in the launcher:
#
#   "claude"  (current default, recommended)
#     Runs the Claude Code CLI with environment variables that redirect it
#     to DeepSeek's Anthropic-compatible endpoint. Full agentic file access
#     (Read/Glob/Grep/Bash tools, autonomous exploration). Same code paths
#     and capabilities as Agent A, only the model brain differs.
#
#   "aider"   (legacy, kept for fallback)
#     Runs the Aider CLI pointed at DeepSeek via LiteLLM. Limited file
#     access — Aider can't autonomously decide to read project files
#     mid-session, only edits files explicitly handed to it at launch.
#     The role definition in PROJECT_roles_supplement.md assumes the
#     "claude" harness; if you flip back to "aider", be aware D becomes a
#     narrative/meta auditor rather than a code auditor.
#
# Change this single line to swap implementations. No other edits needed.
AGENT_D_HARNESS="claude"


# ─── Category-keyed model maps ───────────────────────────────────────────────
# At the end of every run, the agent writes ~/next_round.txt with its best
# estimate of what's queued for the next agent — a percentage breakdown like:
#
#     CODE=75 AUDIT=15 RESEARCH=10 WRITING=0
#
# Before invoking the next agent, the launcher reads that file, identifies
# the highest-percentage category, and looks up the model the current agent
# should use for that workload. If next_round.txt is missing, malformed, or
# the user passed --model on the CLI, we fall through to today's defaults.
#
# Per-agent model maps. Each map entry [CATEGORY]=model_name. [DEFAULT] is
# the fallback when no category matches or no estimate exists. CLI --model
# always wins over both.
#
# Tune CODE/AUDIT/RESEARCH/WRITING values after observation — Gemini and
# DeepSeek values are placeholders matching the default until we have data.

declare -A CLAUDE_MODEL_MAP=(
  [CODE]="claude-sonnet-4-6"
  [AUDIT]="claude-opus-4-7"
  [RESEARCH]="claude-opus-4-7"
  [WRITING]="claude-opus-4-7"
  [DEFAULT]="claude-opus-4-7"
)

declare -A OPENAI_MODEL_MAP=(
  [CODE]="gpt-5.5"
  [AUDIT]="gpt-5.5"
  [RESEARCH]="gpt-5.5"
  [WRITING]="gpt-5.5"
  [DEFAULT]="gpt-5.5"
)

# Gemini has no per-category tuning yet — every category resolves to the
# default model. Tune after observation.
#
# Pinned to gemini-3.1-pro-preview (current frontier as of May 2026). If
# your account lacks access, roll back to "gemini-2.5-pro" in all five
# entries below.
declare -A GEMINI_MODEL_MAP=(
  [CODE]="gemini-2.5-pro"
  [AUDIT]="gemini-2.5-pro"
  [RESEARCH]="gemini-2.5-pro"
  [WRITING]="gemini-2.5-pro"
  [DEFAULT]="gemini-2.5-pro"
)

declare -A GEMINI_MODEL_MAP_THREEONE=(
  [CODE]="gemini-3.1-pro-preview"
  [AUDIT]="gemini-3.1-pro-preview"
  [RESEARCH]="gemini-3.1-pro-preview"
  [WRITING]="gemini-3.1-pro-preview"
  [DEFAULT]="gemini-3.1-pro-preview"
)

declare -A GEMINI_MODEL_MAP_FLASH=(
  [CODE]="gemini-3.5-flash"
  [AUDIT]="gemini-3.5-flash"
  [RESEARCH]="gemini-3.5-flash"
  [WRITING]="gemini-3.5-flash"
  [DEFAULT]="ggemini-3.5-flash"
)

# DeepSeek (Agent D).
#
# Agent D runs Claude Code with DeepSeek as the backend model via DeepSeek's
# Anthropic-compatible endpoint (https://api.deepseek.com/anthropic). The
# Claude Code CLI talks to DeepSeek the same way it talks to Anthropic —
# tool calls, file edits, /resume, and sub-agents all work because they
# live in the harness, not in the model. From Claude Code's perspective,
# DeepSeek is "another Anthropic-format provider."
#
# Model strings use the V4 explicit names. The legacy aliases deepseek-chat
# and deepseek-reasoner will be retired on 2026-07-24 — don't use them.
#
#   deepseek-v4-flash — fast, cheap, 284B params (13B active).
#   deepseek-v4-pro   — flagship, 1.6T params (49B active), 1M context.
#                       Currently 75% discounted through 2026-05-31.
#
# Current setting: all four categories pinned to deepseek-v4-pro through
# the May 31 sale. The discount makes pro essentially free at the volumes
# Agent D will see, so there's no reason to use flash. AFTER 2026-05-31:
# revisit — likely want CODE→flash, others→pro for cost reasons.
#
# The launcher exports the model name as ANTHROPIC_MODEL (and the OPUS /
# SONNET / HAIKU defaults) in the Agent D subshell. No "deepseek/" prefix
# needed — that was for Aider/LiteLLM; the Anthropic-compat endpoint just
# wants the bare model name.
declare -A DEEPSEEK_MODEL_MAP=(
  [CODE]="deepseek-v4-pro"
  [AUDIT]="deepseek-v4-pro"
  [RESEARCH]="deepseek-v4-pro"
  [WRITING]="deepseek-v4-pro"
  [DEFAULT]="deepseek-v4-pro"
)

# Mistral (Agent M). Two-tier model selection:
#   devstral-medium-latest  — Devstral 2 family, code-tuned. SOTA open
#                             coding model (72.2% SWE-bench). Use this
#                             when the round is doing actual code work.
#   mistral-large-latest    — Mistral's flagship general-purpose model.
#                             Better at prose, planning, audit reasoning,
#                             and non-code writing tasks.
#
# CODE category routes to Devstral; everything else uses Mistral Large.
# This matches our other agents' pattern of "specialty model for the
# specialty task, generalist for everything else."
#
# The values here are the API model names that get written into the
# generated config.toml as the active model. The Vibe alias used in our
# agent profile is the same string (no separate alias layer needed).
declare -A MISTRAL_MODEL_MAP=(
  [CODE]="devstral-medium-latest"
  [AUDIT]="mistral-large-latest"
  [RESEARCH]="mistral-large-latest"
  [WRITING]="mistral-large-latest"
  [DEFAULT]="mistral-large-latest"
)

# OpenRouter agents (OG / OGF / OQ / OQF).
#
# These three agents all run the Claude Code binary — same harness as A and D —
# but with environment variables that redirect the backend through OpenRouter's
# Anthropic-compatible endpoint. OpenRouter then routes to the underlying model
# (Gemma 4 31B paid / Gemma 4 31B free tier / Qwen 3.6 35B A3B /
# Qwen free tier).
#
# OpenRouter's official Claude Code integration guide is at:
#   https://openrouter.ai/docs/guides/coding-agents/claude-code-integration
#
# Key things worth knowing (these are dispatch-layer concerns in agent_call.sh,
# but worth re-stating where the model strings live):
#
#   1. BASE_URL must be "https://openrouter.ai/api" — NOT "/api/v1". Claude Code
#      appends "/v1/messages" itself. Several setup guides on the internet get
#      this wrong.
#
#   2. ANTHROPIC_API_KEY must be EMPTY when using OpenRouter, otherwise Claude
#      Code prefers it over ANTHROPIC_AUTH_TOKEN and tries Anthropic directly.
#
#   3. OpenRouter only "officially supports" Anthropic first-party models via
#      Claude Code. Non-Anthropic models (Gemma, Qwen) work via the Anthropic
#      Skin protocol translation layer. Tool-call fidelity is GENERALLY good
#      but can be quirky. Audit-only role is partly insurance against that.
#
#   4. OGF and OQF are FREE TIER. 20 requests/minute, 200 requests/day.
#      Claude Code makes one API call per tool use. A typical relay run can
#      complete roughly ONE full round per day. Not viable for regular cron;
#      useful for testing.
#
# One map per agent rather than a shared one because the three agents target
# genuinely different backend models — there's no "code vs research" split
# within a single agent like Mistral has, since each agent IS a specific
# backend choice.
declare -A OG_MODEL_MAP=(
  [CODE]="google/gemma-4-31b-it"
  [AUDIT]="google/gemma-4-31b-it"
  [RESEARCH]="google/gemma-4-31b-it"
  [WRITING]="google/gemma-4-31b-it"
  [DEFAULT]="google/gemma-4-31b-it"
)

declare -A OGF_MODEL_MAP=(
  [CODE]="google/gemma-4-31b-it:free"
  [AUDIT]="google/gemma-4-31b-it:free"
  [RESEARCH]="google/gemma-4-31b-it:free"
  [WRITING]="google/gemma-4-31b-it:free"
  [DEFAULT]="google/gemma-4-31b-it:free"
)

declare -A OQF_MODEL_MAP=(
  [CODE]="qwen/qwen3-coder:free"
  [AUDIT]="qwen/qwen3-coder:free"
  [RESEARCH]="qwen/qwen3-coder:free"
  [WRITING]="qwen/qwen3-coder:free"
  [DEFAULT]="qwen/qwen3-coder:free"
)


declare -A OQ_MODEL_MAP=(
  [CODE]="qwen/qwen3.6-35b-a3b"
  [AUDIT]="qwen/qwen3.6-35b-a3b"
  [RESEARCH]="qwen/qwen3.6-35b-a3b"
  [WRITING]="qwen/qwen3.6-35b-a3b"
  [DEFAULT]="qwen/qwen3.6-35b-a3b"
)
