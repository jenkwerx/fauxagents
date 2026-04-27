# Agent Relay System

A multi-agent orchestration system where **Claude**, **Gemini**, and **Codex (OpenAI)** take turns working on the same project, handing off through a shared markdown file. Driven by `cron`, coordinated via lock files, with the human in the loop through a single override file.

## What This Does

Three AI coding agents — different vendors, different strengths, different cost profiles — collaborate on long-running projects without you having to actively orchestrate them. Each agent runs on its own schedule (typically every few hours via cron), reads where the last agent left off, picks up the next small task, and hands off cleanly. The human writes a one-time `PROJECT.md` brief and can interject at any time via a `human.md` file.

The agents are:

- **Agent A — Claude Code** — primary coder, primary decision-maker.
- **Agent B — Gemini 2.5 Pro** — writer, auditor, researcher, graphics. Does NOT write code.
- **Agent C — Codex (OpenAI)** — generalist. Can code, but flags work for QA. Cannot do graphics.

When agents disagree, Agent A's call stands. When agents have ideas, they go in `passed.md` for the next agent to read.

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

That's it. Agent A creates the rest of the relay's bookkeeping files (`passed.md`, `human.md`, `human_kept.md`, etc.) on its first run.

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
| `human.md` | **You**, anytime | One-time interject. The next agent treats it as primary directive, archives it, empties the file. |
| `human_kept.md` | Each agent | Persistent lessons. Standing rules built up from past `human.md` interjects. |
| `done.txt` | Final agent | Marks project complete. Launcher refuses to invoke agents while this exists, unless `human.md` has content (which means "restart"). |
| `agent_relay.lock` | Launcher | Prevents concurrent agents on the same project. |
| `bkupmd/` | Each agent | Archive of every `passed.md` and `human.md` ever written. |
| `research/` | Each agent | Dated markdown files documenting research and decisions. |
| `scratch/` | Each agent | Breadcrumbs and working files. |
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

### Agent A is the primary decision-maker

When agents disagree, Agent A decides. Agent B and Agent C make recommendations in `passed.md`; Agent A either acts on them, defers them with a note, or declines them with a documented reason. **Silently ignoring a recommendation is not allowed** — every recommendation gets a real answer in `passed.md` or `human_kept.md`.

### `human.md` is your microphone

Whenever you want the agents to know something, write it into `/opt/claude/<project>/human.md`. The next agent treats it as primary directive, does what it says, archives the file, empties it, and appends a permanent rule to `human_kept.md`. This is the cleanest way to:

- Correct a mistake the agents are making repeatedly
- Push the project in a new direction
- Restart a project that was marked done (just write into `human.md` — the launcher detects this and reopens the relay)

### Locks are per-project, 30 minutes

The relay uses a simple file-based lock at `<project>/agent_relay.lock`. If a fresh lock exists (< 30 min), the agent skips. If the lock is stale (≥ 30 min), the agent assumes the previous one died mid-run and takes over.

### Logs auto-trim

`<project>/logs/agent.log` is kept to its last 5000 lines on every run. No log rotation needed.

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

## Files in This Repo

- `agent_call.sh` — the launcher (this is what cron invokes)
- `AGENT_RELAY.md` — the system prompt every agent reads on every run; defines roles, startup procedure, override protocols
- `README.md` — this file

## License

MIT No Attribution (MIT-0) - https://opensource.org/license/mit-0


