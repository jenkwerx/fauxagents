# Agent Relay System

A multi-agent orchestration system where **Claude**, **Gemini**, and **Codex (OpenAI)** take turns working on the same project, handing off through a shared markdown file. Driven by `cron`, coordinated via lock files, with the human in the loop through a single override file.

## What This Does

Three AI coding agents — different vendors, different strengths, different cost profiles — collaborate on long-running projects without you having to actively orchestrate them. Each agent runs on its own schedule (typically every few hours via cron), reads where the last agent left off, picks up the next small task, and hands off cleanly. The human writes a one-time `PROJECT.md` brief and can interject at any time via a `human.md` file.

The agents are:

- **Agent A — Claude Code** — primary coder, primary decision-maker.
- **Agent B — Gemini 2.5 Pro** — writer, auditor, researcher, graphics. Does NOT write code.
- **Agent C — Codex (OpenAI)** — generalist. Can code, but flags work for QA. Cannot do graphics.

The role assignments above are a *convention*, not something the relay enforces — you define roles per-project in `PROJECT.md`. The roles supplement that ships in this repo gives you exactly this A/B/C split if you want it; otherwise define your own (or treat all three as equal generalists).

When agents disagree, Agent A's call stands (in this convention). When agents have ideas, they go in `passed.md` for the next agent to read.

## Quick Start

### 1. Prerequisites

- Linux (or macOS — works on either)
- The CLIs installed and authenticated:
  - `claude` — Claude Code, native install at `~/.local/bin/claude`
  - `gemini` — Gemini CLI via npm
  - `codex` — Codex CLI via npm, with `codex login` completed once
- `bash`, standard core utils

### 2. Install

```bash
sudo mkdir -p /opt/claude
sudo chown -R $USER /opt/claude
cd /opt/claude
# Drop agent_call.sh and AGENT_RELAY.md into /opt/claude/
chmod +x agent_call.sh
```

### 3. Create your first project

```bash
mkdir -p /opt/claude/myproject
cat > /opt/claude/myproject/PROJECT.md <<'EOF'
# Project Brief: My Project

## Summary
Build a Python CLI tool that converts CSV files to JSON.

## Tech Stack
Python 3.11+, no external dependencies.

## Priority Task List
1. Set up project structure (src/, tests/)
2. Write the CSV reader
3. Write the JSON writer
4. Add the CLI argparse layer
5. Write unit tests
EOF
```

That's enough to start, but if you're running multiple agents (A, B, C) and want them to specialize — primary coder, auditor, generalist, etc. — append the contents of `PROJECT_roles_supplement.md` from this repo to the bottom of your `PROJECT.md`. The supplement defines a tested A/B/C split with documented routing rules. Without it, all agents behave as equal generalists.

For a fresh start instead, copy `PROJECT_template.md` from this repo as a skeleton and fill in the blanks.

The relay creates the rest of the bookkeeping files (`passed.md`, `human.md`, `human_kept.md`, `gitinfo/`, etc.) automatically on the first run.

### 4. Run an agent

```bash
/opt/claude/agent_call.sh "Agent A" myproject
```

The launcher will:
- Verify the project directory and `PROJECT.md` exist (refuses to start if either is missing)
- Acquire a lock so two agents can't run on the same project simultaneously
- Hand the project context to the agent
- Wait for the agent to finish
- Release the lock and trim the log

The agent reads `PROJECT.md`, picks the next task, does it, writes its handoff into `passed.md`, and exits. Run another agent and it picks up where the first one left off.

### 5. Talk to the agents

Edit `/opt/claude/myproject/human.md` and write whatever you want them to do or know. The next agent sees it, treats it as primary directive, archives the message, and appends a summary to `human_kept.md` so the lesson sticks. Empty `human.md` (or zero bytes) means "no override."

To declare a project complete, an agent creates `done.txt` — the relay halts. To restart a completed project, write into `human.md`; the launcher detects this and reopens the project automatically.

## Command Reference

```
agent_call.sh "Agent A|B|C" <project_name> [options]
```

| Option | Default | Meaning |
|---|---|---|
| `--max-turns N` | 25 | Tool calls before the agent is forced to wrap up. **Claude only** — ignored for Gemini and Codex (their CLIs don't have a turn cap). |
| `--effort LEVEL` | per-agent: A=high, B=n/a, C=high | Reasoning depth. Claude accepts `low / medium / high / xhigh / max`. Codex accepts `minimal / low / medium / high / xhigh`. Gemini ignores it. |
| `--model NAME` | per-agent default | Override the model for whichever agent is running. Claude defaults to `claude-opus-4-7`, Gemini to `gemini-2.5-pro`, Codex to `gpt-5.4`. |
| `--gemini-preload` | off | **Agent B only.** Pre-load the entire project directory into Gemini's context via `--include-directories`. By default the launcher omits that flag — Gemini reads files lazily on demand, like Claude and Codex do. Use this only for small projects where having the whole tree in context from the start is worth the token cost. |

The launcher refuses to start if:
- The project directory `/opt/claude/<project_name>/` doesn't exist
- `PROJECT.md` doesn't exist in that directory
- A lock file is fresh (< 30 minutes old) — assumes another agent is still running

## Project Files

When you create a project, you write **one** file: `PROJECT.md`. Everything else is created by the relay automatically on the first agent run. Here's what each file does:

| File | Who writes it | What it's for |
|---|---|---|
| `PROJECT.md` | **You** | Static project brief. Read by every agent on every run. |
| `passed.md` | Each agent | Handoff log. Agent reads previous handoff, writes a new one before exiting. |
| `human.md` | **You**, anytime | One-time interject. The next agent treats it as primary directive, archives it, empties the file. (**Inbound**: human → agents.) |
| `human_kept.md` | Each agent | Persistent lessons. Standing rules built up from past `human.md` interjects. |
| `_HOOMAN.md` | Each agent (write-only) | Agent → human signal. Exists only when an agent has flagged something needing your attention. (**Outbound**: agents → human.) |
| `_HOOMAN_CLEAN_YYYYMMDDHHMMSS.md` | Each agent (write-only) | The "all clear" marker. Exists when no agent has anything for you. Timestamped so you can see at a glance how recent the last clean run was. Exactly one of `_HOOMAN.md` or `_HOOMAN_CLEAN_*.md` exists at any time, never both. |
| `done.txt` | Final agent | Marks project complete. Launcher refuses to invoke agents while this exists, unless `human.md` has content (which means "restart"). |
| `agent_relay.lock` | Launcher | Prevents concurrent agents on the same project. |
| `bkupmd/` | Each agent | Archive of every `passed.md`, `human.md`, `git_overview.md`, and `git_update_round.md` ever written. |
| `research/` | Each agent | Dated markdown files documenting research and decisions. |
| `scratch/` | Each agent | Breadcrumbs and working files. |
| `gitinfo/` | Each agent | GitHub-reader-facing files. Contains `git_overview.md` (project pitch, rewritten each run), `git_update_round.md` (this run's snapshot), and `git_updates_all.md` (newest-first log of every round, append-only — only the human prunes it). |
| `logs/agent.log` | Launcher | Every run's start/end markers, prompts sent, exit codes. Auto-trimmed to last 5000 lines. |

## Cron Patterns

The relay system is designed for cron. Three patterns work well:

### Single-agent staggering (one agent per cron line)

This is the simplest. Each agent has its own cron line, with project-specific times spaced out so the same project isn't hit twice within 30 minutes:

```
15 09 * * * /opt/claude/agent_call.sh "Agent A" myproject --max-turns 200
30 13 * * * /opt/claude/agent_call.sh "Agent B" myproject
45 18 * * * /opt/claude/agent_call.sh "Agent C" myproject --effort high
```

### Chained multi-agent runs (one cron line, sequence)

You can chain multiple invocations with `&&` if you want a complete A→B→A→C→A sequence in one go. Each agent only runs if the previous one succeeded (returned 0). This is useful when you want to drive a project hard during a quiet hour:

```
00 03 * * * /opt/claude/agent_call.sh "Agent A" jenkwerx --max-turns 200 --effort xhigh && \
            /opt/claude/agent_call.sh "Agent B" jenkwerx && \
            /opt/claude/agent_call.sh "Agent A" jenkwerx --max-turns 200 --effort xhigh && \
            /opt/claude/agent_call.sh "Agent C" jenkwerx --effort high && \
            /opt/claude/agent_call.sh "Agent A" jenkwerx --max-turns 200 --effort xhigh
```

What this cron line does, in order:

1. **Agent A** picks up the next task from `passed.md`, does it (up to 200 tool calls at xhigh reasoning), writes a handoff.
2. **Agent B** reviews what A just did — audits the code, writes documentation, flags anything wrong. B doesn't change code; it leaves recommendations in `passed.md`.
3. **Agent A** reads B's audit notes, acts on them or declines them with a documented reason, picks up the next task.
4. **Agent C** does another pass — generalist work, possibly QA, possibly a different angle on whatever A's been writing.
5. **Agent A** consolidates, decides what to keep from C's contributions, sets up the next handoff.

This produces a tight A-led iteration loop with two audit/contributor passes per cycle. Run it once a day in a quiet hour and you get five productive runs on the project without any manual orchestration. Watch the `--max-turns 200` and `--effort xhigh` — that's expensive compute (Opus 4.7 at xhigh reasoning for up to 200 tool calls), so it's a deliberate "drive this project hard" pattern, not something you'd run hourly.

### Mixed staggering (recommended for multi-project setups)

If you have several projects, group runs by agent so each agent only contends with its own API rate limits. Example schedule:

```
# Agent B (Gemini) — audits in the early evening
15 20 * * * /opt/claude/agent_call.sh "Agent B" project_one
15 21 * * * /opt/claude/agent_call.sh "Agent B" project_two
00 22 * * * /opt/claude/agent_call.sh "Agent B" project_three

# Agent A (Claude) — primary coder, spread across the day
15 05 * * * /opt/claude/agent_call.sh "Agent A" project_one --max-turns 250
15 09 * * * /opt/claude/agent_call.sh "Agent A" project_two --max-turns 250
45 15 * * * /opt/claude/agent_call.sh "Agent A" project_three --max-turns 250

# Agent C (Codex) — overnight sweeps
45 01 * * * /opt/claude/agent_call.sh "Agent C" project_one --effort high
45 02 * * * /opt/claude/agent_call.sh "Agent C" project_two --effort high
45 03 * * * /opt/claude/agent_call.sh "Agent C" project_three --effort high
```

## Concepts

### The 30-minute rhythm

Each agent has roughly 20 minutes of active work time and shouldn't try to do too much per run — pick one small task, do it well, hand off cleanly. Cron runs are spaced at least 30 minutes apart per project so locks always clear before the next attempt.

### Roles and decision authority are project-defined

The relay itself is role-agnostic. Each project's `PROJECT.md` defines which agent does what — primary coder, auditor, generalist, decision-maker — and whether disagreements between agents have a hierarchy or get resolved by discussion. The relay just enforces the mechanics (locks, handoffs, file lifecycle); strategy is the project's call.

A drop-in supplement (`PROJECT_roles_supplement.md`) ships in this repo with a tested A/B/C split: A as primary coder + decision-maker, B as auditor/writer/researcher with no JS or Python edits, C as generalist with QA-flag rule. Paste it into a project's `PROJECT.md` if you want exactly that — otherwise define your own.

Whatever the roles, the universal rule is: **silently ignoring a recommendation is not allowed.** Every recommendation in `passed.md` from another agent gets either action, a "deferred" note, or a documented decline (in `passed.md` and `human_kept.md`).

### `human.md` is your microphone

Whenever you want the agents to know something, write it into `/opt/claude/<project>/human.md`. The next agent treats it as primary directive, does what it says, archives the file, empties it, and appends a permanent rule to `human_kept.md`. This is the cleanest way to:

- Correct a mistake the agents are making repeatedly
- Push the project in a new direction
- Restart a project that was marked done (just write into `human.md` — the launcher detects this and reopens the relay)

### `_HOOMAN.md` is the agents' way of getting your attention

The other direction of the same channel. Every run, each agent writes one of two files at the project root:

- **`_HOOMAN.md`** — exists when an agent has flagged something that needs your call before further productive work can happen. Examples: an ambiguous spec, two viable architectural paths, a content choice the agents shouldn't make on their own, a third-party service that needs your account.
- **`_HOOMAN_CLEAN_YYYYMMDDHHMMSS.md`** — exists when nothing needs you. Timestamped so you can tell at a glance how recent the last clean run was without opening anything.

Exactly one of the two exists at any time. The leading underscore on both names sorts them to the top of file listings, so a quick `ls` of any project tells you instantly whether you need to dig in. **The agent never reads either file** — it overwrites them fresh each run. Your responses to anything flagged in `_HOOMAN.md` go back through `human.md` (the inbound channel).

If you're running multiple projects, this means a single `ls /opt/claude/*/` lets you eyeball which projects need attention and which are humming along on their own.

### `gitinfo/` is the project's GitHub face

Every run, each agent regenerates three files in `<project>/gitinfo/`:

- **`git_overview.md`** — a project pitch for someone arriving at the GitHub repo who has no prior context. Rewritten every run so it stays accurate to the current state of the project.
- **`git_update_round.md`** — a one-round snapshot. What this run did, what's in flight, any open questions.
- **`git_updates_all.md`** — an accumulating log of every round's update, newest first. Append-only by agents; only you ever prune or clear it (typically when you ship a release and want a fresh slate).

These files exist for outside readers (people, search engines) landing on the GitHub repo. They're outputs, not inputs — agents don't read them to inform their work. When you push to GitHub, just include the `gitinfo/` directory and the repo's docs stay fresh without you ever writing them yourself.

### Locks are per-project, 30 minutes

The relay uses a simple file-based lock at `<project>/agent_relay.lock`. If a fresh lock exists (< 30 min), the agent skips. If the lock is stale (≥ 30 min), the agent assumes the previous one died mid-run and takes over.

### Logs auto-trim

`<project>/logs/agent.log` is kept to its last 5000 lines on every run. No log rotation needed.

### Prompt size is effectively unbounded

The launcher pipes the prompt to each agent via stdin, not as a command-line argument. This sidesteps Linux's `ARG_MAX` limit (typically ~128 KB on argv + envp combined), which used to cause `Argument list too long` failures on projects where `PROJECT.md` and `passed.md` had grown past 100 KB. With the stdin-piped form, prompt size is bounded only by the model's context window, not the kernel.

### What the launcher enforces vs. what it just instructs

The relay's bookkeeping rules — write `passed.md`, write `gitinfo/`, write `_HOOMAN.md` or `_HOOMAN_CLEAN_*.md`, append to `human_kept.md`, etc. — live in `AGENT_RELAY.md`, the system prompt every agent reads on every run. The launcher (`agent_call.sh`) does not run these rules itself; the agent reads them and is *expected* to follow them.

Agents usually do. But when they don't — because they ran out of turn budget, or because they fabricated a wrap-up summary without issuing the actual file-write tool calls (a known Gemini failure mode) — the rules silently break.

To make these failures visible, the launcher captures modification times of every expected file *before* invoking the agent and re-checks them *after*. If a file wasn't touched, a `WARN` line is logged to `<project>/logs/agent.log`:

```
WARN: passed.md mtime did not advance during this run. Agent likely fabricated its closing summary without issuing the file-write tool call.
WARN: gitinfo/git_overview.md was not updated this run (Step 6f skipped or fabricated).
WARN: neither _HOOMAN.md nor _HOOMAN_CLEAN_*.md was written this run (Step 6g skipped or fabricated).
```

The check only fires when the agent exited cleanly (exit code 0). Crashes have their own diagnostic signal (the exit code itself) and aren't double-reported here.

The warnings don't fail the run — the agent did real work that the next agent can build on, and a hard fail would be more disruptive than the missing file. But the next agent will see the warning in the recent log when it picks up, and you'll see it too if you spot-check `agent.log`. **If you see these warnings repeatedly from the same agent, that's a signal worth investigating** — possibly a tighter `--max-turns` cap, a clearer instruction, or a model swap.

The set of files monitored: `passed.md`, `gitinfo/git_overview.md`, `gitinfo/git_update_round.md`, `gitinfo/git_updates_all.md`, and one of `_HOOMAN.md` / `_HOOMAN_CLEAN_*.md`. Adding new monitored files is a 5-line edit in `agent_call.sh` near the existing `snap_mtime` helper.

## Big Thoughts (Architecture Notes)

A few design decisions worth understanding if you're going to live with this system, customize it, or extend it.

### The agents run on a heavily restricted user account

The cron user that invokes `agent_call.sh` should be a dedicated account with **access scoped to `/opt/claude/` and nothing else**. The agents shouldn't be able to read your home directory, browse `/etc/`, write to `/var/`, or wander around `/opt/` outside the relay tree. The point is that even though every agent runs with `--yolo` / `--dangerously-skip-permissions` (i.e. tool-call approvals are off), the blast radius of a misbehaving agent stays inside the relay's playground.

A reasonable setup looks roughly like this:

```bash
# Create the dedicated user
sudo useradd -m -s /bin/bash relay-runner
# Give them ownership of the relay directory
sudo chown -R relay-runner:relay-runner /opt/claude
# Lock down their shell so they can't ssh in casually if you don't want them to
sudo passwd -l relay-runner

# Cron runs as relay-runner — install via:
sudo crontab -u relay-runner -e
```

Then everything you do — `codex login`, installing the CLIs in `relay-runner`'s home, configuring git on that account if needed — happens as that user (`sudo -iu relay-runner` to drop into a login shell). The agents see one directory tree, write files inside it, and have no business outside it.

This is genuinely important when you're letting AI agents run unattended for weeks. The combination of `--yolo` + cron + an unrestricted user is how a typo in a prompt or a hallucinated `rm` becomes a Tuesday-morning incident. Restricting the user is the single biggest mitigation, and it costs nothing to set up.

### How the CLIs work locally

There's no proprietary plumbing here — the relay is just a thin shell wrapper around three vendor CLIs that already exist on the machine.

- **Claude Code (`claude`)** — Anthropic's native CLI binary, typically installed via the one-line installer to `~/.local/bin/claude`. It speaks to Anthropic's API directly. Auth is the standard `claude` login flow, stored in the user's home directory. The CLI accepts `-p "<prompt>"` for non-interactive runs, with flags like `--system-prompt-file`, `--max-turns`, `--effort`, `--model`, and `--dangerously-skip-permissions`. The launcher just composes those flags from the args you passed.

- **Gemini CLI (`gemini`)** — Google's CLI, installed via npm globally. It speaks to Google's API. Auth is via your Google account login — once you've authenticated interactively, credentials live under `~/.gemini/`. System prompts come in via the `GEMINI_SYSTEM_MD` environment variable (pointing at a file path), not a CLI flag. `--yolo` autoapproves tool use. There is no thinking-effort flag — Gemini's reasoning depth is controlled API-side and isn't exposed at the CLI. Gemini also has an `--include-directories` flag that pre-loads the entire project tree into context (different from Claude's `--add-dir` and Codex's `--cd`, which expose a directory to the agent's tools without ingesting it). The launcher does NOT pass that flag by default — Gemini reads files lazily on demand instead, matching how the other two engines behave. Pass `--gemini-preload` at the CLI to opt back into eager pre-loading for small projects where the upfront token cost is negligible.

- **Codex CLI (`codex`)** — OpenAI's CLI, also installed via npm. It can authenticate two ways: with an `OPENAI_API_KEY` environment variable (preferred for automation), or via `codex login` which completes a ChatGPT OAuth flow and stores tokens in `~/.codex/auth.json`. The launcher uses `codex exec` (non-interactive mode) with `--yolo`, `--skip-git-repo-check`, and `-c model_reasoning_effort=<value>` for thinking effort (Codex doesn't have a `--reasoning-effort` flag — the value rides in via the generic `-c` config override). System prompts arrive via an `AGENTS.md` file inside `CODEX_HOME`. The launcher redirects `CODEX_HOME` to a project-local `.codex/` directory and symlinks both `AGENTS.md` (pointing at `AGENT_RELAY.md`) and `auth.json` (pointing at `~/.codex/auth.json`) into it. The symlink for auth matters because Codex refreshes OAuth tokens in place — copies would go stale on every refresh, but symlinks all resolve to the same underlying file.

In all three cases, the launcher's job is small: assemble the right flags, set the right env vars, hand off the prompt, capture the output to the agent log. The CLIs do everything else. There is no fork of any vendor's tooling in this repo — just a wrapper.

### Swapping models, adding agents, customizing engines

The `agent_call.sh` script is small enough to read end-to-end, and the per-agent setup is intentionally easy to modify. There are three layers where you'd make changes:

#### Layer 1 — Swap a default model

Change one of the default-model constants near the top of `agent_call.sh`:

```bash
DEFAULT_CLAUDE_MODEL="claude-opus-4-7"
DEFAULT_GEMINI_MODEL="gemini-2.5-pro"
DEFAULT_OPENAI_MODEL="gpt-5.4"
```

Edit the value in place — for example, `DEFAULT_CLAUDE_MODEL="claude-sonnet-4-6"` if you want Sonnet by default for Agent A. Or pass `--model claude-sonnet-4-6` at invocation time to override per-run without touching the script.

The same applies to default effort levels (`DEFAULT_CLAUDE_EFFORT`, `DEFAULT_OPENAI_EFFORT`, `DEFAULT_GEMINI_EFFORT`). Edit the constant or pass `--effort xhigh` at the CLI.

#### Layer 2 — Reshuffle which agent uses which engine

Today, "Agent A" is Claude, "Agent B" is Gemini, "Agent C" is Codex — but that's just a convention. The code that actually decides what to run lives in three branches near the bottom of `agent_call.sh`:

```bash
if [ "$AGENT_NAME" = "Agent A" ]; then
  # ---- CLAUDE CODE ----
  "$CLAUDE_BIN" --add-dir "$PROJECT_DIR" ...

elif [ "$AGENT_NAME" = "Agent B" ]; then
  # ---- GEMINI ----
  "$GEMINI_BIN" --include-directories "$PROJECT_DIR" ...

elif [ "$AGENT_NAME" = "Agent C" ]; then
  # ---- CODEX (OpenAI) ----
  CODEX_HOME="$CODEX_HOME_DIR" "$OPENAI_BIN" exec ...
```

If you want "Agent A" to be Gemini and "Agent B" to be Claude, swap the two blocks (and update the role labels in `AGENT_RELAY.md` so the agents know what their personality is supposed to be). If you want all three agents running Claude with three different models or effort levels, replace the contents of the B and C branches with copies of the A branch and tune the model/effort constants. This is genuinely just a five-minute edit.

#### Layer 3 — Add a fourth agent

Adding a new agent is mostly mechanical. Walk through these steps:

1. **Pick an identity.** "Agent D" is the obvious next slot.
2. **Add an effort and model default constant** near the top:
   ```bash
   DEFAULT_DEEPSEEK_MODEL="deepseek-coder-v3"
   DEFAULT_DEEPSEEK_EFFORT="high"
   ```
3. **Add a binary path** with the others:
   ```bash
   DEEPSEEK_BIN="/home/relay-runner/.local/bin/deepseek"
   ```
4. **Extend the `EFFORT` resolution case** so Agent D's default effort gets picked up when no `--effort` is passed:
   ```bash
   case "$AGENT_NAME" in
     "Agent A") EFFORT="$DEFAULT_CLAUDE_EFFORT" ;;
     "Agent B") EFFORT="$DEFAULT_GEMINI_EFFORT" ;;
     "Agent C") EFFORT="$DEFAULT_OPENAI_EFFORT" ;;
     "Agent D") EFFORT="$DEFAULT_DEEPSEEK_EFFORT" ;;  # NEW
   esac
   ```
5. **Same for model resolution.**
6. **Add an `elif` branch** in the run-the-engine block, modeled on whichever existing block matches your new vendor's CLI shape most closely (Claude is the simplest template, Codex is the most complex). Match its flag style — does it want a system prompt via flag, env var, or `AGENTS.md`?
7. **Add Agent D's role definition** to `AGENT_RELAY.md` — strengths, what they can/can't do, where they fit in the override hierarchy. (Probably easiest to start by treating D as a B clone and tuning.)
8. **Add Agent D to your cron schedule** — same pattern as the existing agents.

Nothing in the relay's bookkeeping (`passed.md`, `human_kept.md`, `done.txt`, locks) cares how many agents there are. The lock file just records which one currently holds the project; with four agents instead of three, only the cron schedule and the role descriptions need to scale.

#### Layer 4 — Replace an agent entirely

Want to use a model that doesn't have a CLI? Or a homegrown one? You can. The branch in `agent_call.sh` doesn't care what the binary is — it just needs something that:
- Accepts a system prompt and a user prompt
- Has tool/file access to the project directory
- Returns when it's done

A Python wrapper around a raw API call (`anthropic`, `openai`, `google-genai` SDKs) works fine if you don't want to depend on a vendor CLI. Replace the `"$VENDOR_BIN" ...` invocation with `python3 /opt/claude/scripts/my_wrapper.py "$PROJECT_DIR" "$AGENT_PROMPT" >> "$LOG_FILE" 2>&1` and you're off. The relay system itself doesn't know or care.

The whole point of the architecture is that **the relay is just files plus a cron-driven wrapper**. The intelligence is in the agents and in `AGENT_RELAY.md`. Swap any of it out without breaking the rest.

## Troubleshooting

**`ERROR: project directory doesn't exist`**
You misspelled the project name, or you haven't created `/opt/claude/<project_name>/` yet. Make the directory and re-run.

**`ERROR: PROJECT.md does not exist`**
Create `<project_dir>/PROJECT.md` with at least a one-paragraph project brief and a Priority Task List. The relay refuses to run without it.

**`SKIP: Lock is Nm old (under 30)`**
Another agent is currently running on the same project. Wait it out. If you're certain the previous run died (e.g. process is gone but lock persists), you can manually `rm <project>/agent_relay.lock` — but verify nothing's actually running first.

**Codex 401 Unauthorized**
Run `codex login` once as the cron user. The launcher symlinks `~/.codex/auth.json` into the project's local `.codex/` directory, so a single login covers all projects.

**Agent runs but doesn't seem to do anything**
Check `<project>/logs/agent.log` for the prompt and any error output. Most common: the agent picked up a task it had already completed but the previous run forgot to update `passed.md` cleanly. Edit `passed.md` to reflect actual state, or write into `human.md` directing the agent to a specific next task.

**Agent keeps making the same mistake**
Write into `human.md` correcting the mistake. The next agent appends the correction to `human_kept.md` as a standing rule, and all future agents follow it.

**`Argument list too long` (exit 126) on Claude / Gemini / Codex**
This used to happen when `PROJECT.md` + `passed.md` + `human_kept.md` combined got large enough to bust Linux's `ARG_MAX`. The launcher now pipes the prompt via stdin instead of argv, so prompt size is effectively unbounded. If you see this from an old log, it predates the fix. If you see it from a recent run, your version of the launcher is out of date — pull the latest.

**Agent B (Gemini) burns far more tokens than A or C**
Likely cause: the project is large and Gemini's `--include-directories` was loading the whole tree into context every run. The launcher now omits that flag by default — Gemini reads files lazily on demand, like Claude and Codex. If you want the original eager-loading behavior for a small project, pass `--gemini-preload`.

**WARN messages about files "not updated this run"**
The launcher checks that every expected file (`passed.md`, the three `gitinfo/` files, and the `_HOOMAN` signal) was actually written by the agent. If one wasn't, you'll see a `WARN:` line in `agent.log`. The agent did real work either way — the warning just flags that it didn't reach Step 6 cleanly. Common causes: agent ran out of `--max-turns`, agent fabricated a closing summary without issuing the tool calls (a known Gemini pattern), or agent crashed in a way that didn't surface as a non-zero exit code. If you see this repeatedly from the same agent, raise `--max-turns` or sharpen the AGENT_RELAY.md instructions for that agent's role.

## Files in This Repo

- `agent_call.sh` — the launcher (this is what cron invokes)
- `AGENT_RELAY.md` — the system prompt every agent reads on every run. Project-agnostic mechanics: lock semantics, startup procedure, handoff protocol, file lifecycle. Roles and decision authority are NOT defined here — those go in each project's `PROJECT.md`.
- `PROJECT_template.md` — a starting skeleton for new projects, with a compact table-based roles section. Copy this when you create a new project, fill in the blanks.
- `PROJECT_roles_supplement.md` — a drop-in block to paste at the bottom of an existing `PROJECT.md` to add tested A/B/C role conventions (primary coder, auditor, generalist) plus a delegation matrix. Use when you want roles without writing them from scratch.
- `LICENSE` — MIT-0 (MIT No Attribution).
- `README.md` — this file.

## License

MIT No Attribution (MIT-0) — Copyright (c) 2026 Jenkwerx. See [LICENSE](./LICENSE) for the full text.

You can use this code for anything: personal projects, commercial products, fork it, modify it, redistribute it. **No attribution required** — keep the copyright notice if you want, or strip it out, doesn't matter. The authors aren't liable for anything that happens. As bare-bones a permissive license as you can get without dropping the liability disclaimer.
