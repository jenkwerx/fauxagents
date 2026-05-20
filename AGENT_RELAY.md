# Agent Relay System

You are one of likely multiple agents in a relay system. You and your counterparts take turns working on this project, handing off in roughly 30-minute windows (the launcher enforces a 30-minute lock). Read this file completely before doing anything.

## Your Identity

Check the lock file to determine if it's your turn. There are multiple agents:

- **Agent A** — runs via a primary service (local, home directory: `~/`)
- **Agent G** — runs via a secondary service
- **Agent C** — runs via a tertiary service
..etc..

You already know which one you are based on your environment.

## Agent Reliability & Delegation

If your project uses multiple agents and wants delegation when one is unreliable, define it in `PROJECT.md` under a section titled "Agent Reliability". Specify (a) which agents are currently unreliable and (b) which agent covers each unreliable agent's workload. Read that section every run; if you're a covering agent, take on the unreliable agent's work to the extent your own capabilities allow. If `PROJECT.md` doesn't define this, every agent does its own work and there is no fallback.

Coverage absorbs workload, not authority. Whatever role-specific limits apply to you in `PROJECT.md` still apply when you're covering for someone else. Document any coverage you take on with a `COVERAGE:` line in `passed.md`.

---

## Roles and Responsibilities

This relay supports multiple agents (typically named "Agent A", "Agent C", "Agent G", etc.). The relay does not assume any particular role assignment — different projects use the agents differently. **Read your project's `PROJECT.md` to learn what your specific agent is supposed to do, what limits apply, and how disagreements between agents are resolved.** If `PROJECT.md` doesn't define roles, treat all agents as equal generalists.

If `PROJECT.md` declares one agent as the primary decision-maker, respect that. A recommendation in `passed.md` addressed to that agent is theirs to resolve — don't act on it unilaterally if you're someone else.

When you reject prior work or decline a recommendation from another agent, document the decision in both `passed.md` (under "What I Did") and `human_kept.md` (as a standing rule). Silent rejection is not allowed — every recommendation in `passed.md` gets either action, a "deferred" note, or a documented decline.

### Research Directory

When you conduct research for any decision, save it to `~/research/YYYYMMDD_topic_name.md`. Include what was researched, what was found, what was decided, how it was applied, and which agent did the work. Review recent research files at the start of each run to keep decisions consistent across the relay.

## Startup Procedure

Follow these steps in order every time you are invoked.

### Step 0: Project state and lock file (launcher-handled)

The launcher checks `done.txt` and `human.md` before invoking you and acquires the relay lock at `~/agent_relay.lock` on your behalf. By the time you start running, the lock is yours, the four-state check has passed, and any `done.txt`/restart handling is done.

**You only need to know one thing about restarts:** if `passed.md` opens with a `# !!! RELAY RESTARTED — READ THIS FIRST !!!` marker, this is a restart run. The author has reopened a previously-completed project. Treat `human.md` as your primary directive (per Step 2), and remove the restart marker when you rewrite `passed.md` at Step 6b — the next agent should not see it.

You do not need to write, check, or remove the lock file. The launcher releases it after you exit.


### Step 1: Bootstrap Required Files

**The only file the author is required to provide is `PROJECT.md`.** Everything else is your responsibility to create if it doesn't exist. Check for each of the following and create any that are missing. This runs every time and is safe if the files already exist — `touch` won't overwrite, and the `if` guards only create when the file is absent.

You **must** do this before proceeding. Do not skip this step. Do not assume these files exist.

- `~/bkupmd/` directory — create if missing
- `~/research/` directory — create if missing
- `~/scratch/` directory — create if missing
- `~/gitinfo/` directory — create if missing (the GitHub-reader-facing files `git_overview.md`, `git_update_round.md`, and `git_updates_all.md` live here, written every run at Step 6f)
- `~/human.md` — create as an empty file if missing
- `~/passed.md` — create with the seed template below if missing
- `~/human_kept.md` — create with the header template below if missing

```bash
# Create directories
mkdir -p ~/bkupmd
mkdir -p ~/research
mkdir -p ~/scratch
mkdir -p ~/gitinfo

# Create human.md if missing (empty = no override)
touch ~/human.md

# Create passed.md if missing (seed with initial state)
if [ ! -f ~/passed.md ]; then
  cat > ~/passed.md <<'EOF'
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
EOF
fi

# Create human_kept.md if missing
if [ ! -f ~/human_kept.md ]; then
  cat > ~/human_kept.md <<'EOF'
# Human Kept — Persistent Lessons and Corrections

> This file is a running log of corrections and instructions from the project author.
> Each entry was originally delivered via `human.md` and appended here for permanence.
> **Treat every entry in this file as an active rule.** These are mistakes you or a prior
> agent have made before. Do not repeat them.

---
EOF
fi
```

### Step 2: Check for Human Override

**Before reading `passed.md`, check `~/human.md`.** This file always exists but may be empty.

- **If `~/human.md` is EMPTY (zero bytes or whitespace only):** The author has no override this run. Proceed normally.
- **If `~/human.md` has CONTENT:** This file contains direct instructions from the project author. **These instructions take immediate priority.** Read `human.md` fully. Its contents may override some or all of what `passed.md` says to do next. Treat it as your primary directive for this run. You should still read `passed.md` for context on what has been accomplished, but `human.md` dictates what you work on.

`human.md` is meant as a **single-use instruction**. You will back it up and empty it at the end of your run (see Step 6). The file stays in place — only its contents are consumed.

### Step 2b: Read the Lessons File

Read `~/human_kept.md` in full. The entries are standing instructions — not history to skim. Follow them alongside `PROJECT.md`. Also re-read your project's "Agent Reliability" section in `PROJECT.md` (if defined) — covering responsibilities can change between runs.

### Step 3: Read the Handoff Log

Read `~/passed.md`. It tells you what the previous agent accomplished, what still needs doing, and any blockers or warnings. The previous agent wrote it for you — don't skip it. If `human.md` was present, use `passed.md` as background but follow `human.md` for priorities.

### Step 4: Read the Project Brief

Read `~/PROJECT.md`. This is your grounding document — what's being built, who does what, and any project-specific rules that override the relay defaults.

### Step 4b: Write a Skeleton Handoff (Crash-Safety Insurance)

Before starting any deep work, write a brief **skeleton** `passed.md` describing what you intend to do this run. This is **insurance against getting cut off** by max-turns or max-price caps mid-task. If the cap hits before you finish your real handoff, the next agent at least sees what you were attempting and can pick up the thread.

The skeleton is **not** your final handoff. It's a stub that will be overwritten at Step 6 with your full, real handoff. The wording in the skeleton itself should say so explicitly — see template below.

Do this in two parts:

**Part 1 — Back up the prior agent's `passed.md` first.** This preserves the prior agent's full handoff in `bkupmd/` before you overwrite `passed.md` with your skeleton. This is the same backup that Step 6a used to do; we're just doing it earlier so the prior agent's work is safe even if you crash before Step 6.

```bash
mkdir -p ~/bkupmd
cp ~/passed.md ~/bkupmd/passed_$(date +%Y%m%d%H%M%S).md
```

**Part 2 — Write a short skeleton `passed.md` describing your intent.** Keep this to 5-10 lines. The point is to be cheap (2-3 tool calls) so this step itself doesn't contribute meaningfully to running out of turns. Use this template:

```markdown
# [SKELETON — this run incomplete] passed.md

**Run started:** YYYY-MM-DD HH:MM (your timestamp)
**Agent:** (your identifier — A, C, D, G, M, OG, OGF, OQ, or OQF)

## Intended work this run
- (One or two sentences on what you're about to do, based on Step 3 + Step 4.)
- (e.g. "Audit incJS_06_stable.js for the duplicate-render bug Agent A flagged last round.")
- (e.g. "Implement the scratch-horse feature scaffolding A handed me; will flag for QA.")

## Status
SKELETON — this passed.md will be overwritten with the full handoff at Step 6.
If you (the next agent) are reading this, the previous agent ran out of turns
or price budget before finishing. Check agent.log for the actual outcome, and
look in bkupmd/ for the prior round's full handoff (the most recent backup
file made before this run started).
```

Don't add findings, code analysis, or recommendations to the skeleton — those go in the real handoff at Step 6. The skeleton is just "here's what I was about to do." Anything more is wasted turns.

**Step 6a (the backup) is now redundant** — you've already done it here. Skip Step 6a when you reach Step 6. Step 6b (the real `passed.md` rewrite) still happens at Step 6 as normal.

### Step 5: Do Your Work

You have roughly **20 minutes** and a finite number of tool calls. Work on `human.md` first if it had content this run, then the next priority from `passed.md` guided by `PROJECT.md`.

**Pace yourself:**

1. **Pick ONE small task per run.** Fix one function, add one export, write one section, review one file. Don't try to land an entire feature — break it into sub-tasks in `passed.md` and do only the first.
2. **Write breadcrumbs.** Append `[HH:MM] Did: ... Next: ...` lines to `~/scratch/breadcrumbs.md` every few tool calls so the next agent can pick up if you get cut off. Read this file at the start of your run if it exists.
3. **Check your pace every 8-10 tool calls.** If you don't have enough turns left to do Step 6 cleanly, stop working and go to Step 6 immediately.

**The cardinal sin is getting cut off without updating `passed.md`** and the other handoff files. An empty or stale handoff breaks the relay for the next agent.

### Step 6: Archive and Hand Off

Before you finish, do the following **in this order**:

```bash
# Create the backup directory if it doesn't exist
mkdir -p ~/bkupmd
```

**a) Archive the current `passed.md` (only if not already done at Step 4b):**

You should have already done this at Step 4b. If for any reason you skipped 4b or are unsure, run it now as a fallback. If you DID do 4b, you can either skip this step or run it again — a second backup is harmless (just an extra timestamped file in `bkupmd/` that captures the skeleton).

```bash
# Optional defensive re-backup. Safe to skip if Step 4b ran cleanly.
cp ~/passed.md ~/bkupmd/passed_$(date +%Y%m%d%H%M%S).md
```

**b) Write a fresh `passed.md`:**

Overwrite `~/passed.md` with your handoff. The next agent has no memory of your session — `passed.md` is the only bridge. Be specific. If you acted on `human.md` this run, note what changed and why.

> **⚠️ Issue the actual file-write tool call. Do not type "I will now write `passed.md`" and jump to the closing summary without the write happening.** The launcher checks every expected file's modification time after you exit; missing writes show up as `WARN:` lines in the agent log that the next agent will see. This applies to every file written in Step 6, not just `passed.md`.

> **⚠️ Fill in real values — do not write bash substitutions as literal text.** When you use a file-write tool to create `passed.md`, the tool writes whatever text you give it character-for-character. It does not invoke a shell. Strings like `$(date +%Y-%m-%d)` or `${USER}` will appear in the file verbatim and look broken to the next agent.
>
> If you need the current timestamp, run `date -Iseconds` via the bash tool first, then paste the result as a literal string into your file-write call. The same applies anywhere else you'd reach for a bash substitution. (Backup commands inside `bash` heredocs elsewhere in this document — like `cp ~/passed.md ~/bkupmd/passed_$(date +%Y%m%d%H%M%S).md` — DO get evaluated, because those run in a shell. File-write tools do not.)
>
> Also fill in your own agent identity literally. If you are Agent M, write `**Agent:** M`, not `**Agent:** A` (which is the first example mentioned in this document and is easy to copy by mistake) and not `**Agent:** {agent}` or any other placeholder.
>
> Worked example of a correctly-filled header for an Agent M run that took about 12 minutes:
>
> ```markdown
> ## Last Run
>
> - **Agent:** M
> - **Timestamp:** 2026-05-11T15:54:55-05:00
> - **Run Duration:** ~12 min
> ```
>
> Same rules apply to all other Step 6 files: `gitinfo/git_update_round.md`, `_HOOMAN_CLEAN_<timestamp>.md`, `human_kept.md` entries, and so on. Substitute real values; do not write `$(...)` or `{placeholder}` literally.

**c) Archive and empty `human.md` (if it had content this run):**
```bash
# Only backup if human.md had content (not empty)
if [ -s ~/human.md ]; then
  cp ~/human.md ~/bkupmd/human_$(date +%Y%m%d%H%M%S).md
  > ~/human.md
fi
```

This empties the file but leaves it in place. The author can write new instructions into it at any time without having to recreate it. A blank `human.md` means "no override" — the next agent will see it's empty and move on.

**d) Append to `human_kept.md` (if `human.md` existed this run):**

If you acted on a `human.md` this run, append a summary to `~/human_kept.md` so the lesson persists for all future agents. Use this format:

```markdown
### [YYYY-MM-DD HH:MM] — via human.md
**Original instruction:** (brief summary of what human.md said to do)
**What changed:** (what you actually did in response)
**Standing rule:** (the ongoing takeaway — what all future agents must remember)

---
```

Example entry:
```markdown
### 2026-04-12 14:30 — via human.md
**Original instruction:** Regression scores are being optimized in the wrong direction.
**What changed:** Fixed comparison logic in evaluate.py to minimize instead of maximize.
**Standing rule:** Regression scores — LOWER IS BETTER. Never treat a higher score as an improvement.

---
```

This file is the project's institutional memory. Be concise but specific enough that an agent with no context can follow the standing rule.

**e) Create `done.txt` if all work is complete:**

After writing your handoff, assess whether **all tasks** in `PROJECT.md` are complete, `passed.md` has no remaining work items, and `human_kept.md` has no unresolved issues. If you are confident there is nothing productive a future run could accomplish, create the done file:

```bash
cat > ~/done.txt <<EOF
completed_by: [your agent identity]
timestamp: $(date -Iseconds)
summary: [one-line description of final state]
EOF
```

**Only do this if you are genuinely finished.** If there is any remaining work, any task you're unsure about, or anything that needs verification by another agent — do NOT create `done.txt`. Err on the side of letting the relay continue.

The author can restart the relay at any time by writing into `human.md`, which automatically clears `done.txt` (see Step 0).

**f) Write the gitinfo files (every run):**

The repository on GitHub needs reader-facing files that describe the project. These are NOT consumed by agents — they're for humans (and search engines) arriving at the GitHub repo. Three files live in `~/gitinfo/`, each with different update semantics:

- **`~/gitinfo/git_overview.md`** — a project-wide overview. Pitches the project to a stranger. Explains what it is, why it exists, what it does, the high-level tech stack, the user-visible features. Long-lived but **rewritten every run** so it stays accurate. Backed up to `bkupmd/` before overwriting. **Audience: someone landing on the GitHub repo who has no prior context.**

- **`~/gitinfo/git_update_round.md`** — a single-run snapshot. "What I did this round, what's next." Written fresh every run; the previous round's file is backed up to `bkupmd/` before being overwritten. Similar in spirit to `passed.md` but written for an outside reader rather than for the next agent.

- **`~/gitinfo/git_updates_all.md`** — an accumulating list of every round's update. **Append-only** from the agent's perspective: read the existing file (if any), prepend this run's entry to the top (newest-first), write the result back. **No backup needed** — the agent never destroys content, only adds to it. The **human** is the one who clears or trims this file (typically when they push a release to the repo and want a fresh slate). Agents must NOT trim, summarize, or remove old entries; that decision belongs to the human.

```bash
# Ensure gitinfo/ exists
mkdir -p ~/gitinfo
mkdir -p ~/bkupmd

# --- git_overview.md: rewrite each run, back up first if existed ---
[ -f ~/gitinfo/git_overview.md ] && \
  cp ~/gitinfo/git_overview.md ~/bkupmd/git_overview_$(date +%Y%m%d%H%M%S).md
# (then write fresh git_overview.md — see content guidance below)

# --- git_update_round.md: rewrite each run, back up first if existed ---
[ -f ~/gitinfo/git_update_round.md ] && \
  cp ~/gitinfo/git_update_round.md ~/bkupmd/git_update_round_$(date +%Y%m%d%H%M%S).md
# (then write fresh git_update_round.md — see content guidance below)

# --- git_updates_all.md: prepend this run's entry to the top of the file ---
# No header on this file — it's a stream of entries, newest first. The
# agent writes the new entry to a temp file, then concatenates temp + existing
# (if any) and writes the result back. Safe to re-run; the temp file is
# fully written before the merge.
NEW_ENTRY=$(mktemp)
cat > "$NEW_ENTRY" <<'EOF'
## [YYYY-MM-DD HH:MM] — Agent X — one-line summary

- Bullet 1: something concrete that happened or got decided this round
- Bullet 2
- Bullet 3

---

EOF
if [ -f ~/gitinfo/git_updates_all.md ]; then
  cat "$NEW_ENTRY" ~/gitinfo/git_updates_all.md > ~/gitinfo/git_updates_all.md.tmp
  mv ~/gitinfo/git_updates_all.md.tmp ~/gitinfo/git_updates_all.md
else
  # First-ever run — just promote the new entry to be the file
  mv "$NEW_ENTRY" ~/gitinfo/git_updates_all.md
fi
rm -f "$NEW_ENTRY"  # safe even if mv consumed it; rm -f doesn't error
```

**`git_overview.md`**: project name + one-paragraph summary, the "why" (problem solved), the "what" (concrete features), the "how" (tech stack at a glance), short "getting started" if runnable. Tone: welcoming and informative.

**`git_update_round.md`**: this run's date and agent identity, what landed, what's in flight, any open questions. Terse. The full history lives in `git_updates_all.md`.

**`git_updates_all.md` entries**: a header line `## [timestamp] — Agent X — one-line summary` followed by 2-5 bullets of the most important things this round did or decided. End each entry with `---`. Skip "in flight"/"next steps" — that's `git_update_round.md`'s job.

**g) Write `_HOOMAN.md` OR `_HOOMAN_CLEAN_*.md` (every run — exactly one):**

Two possible files at the project root. Exactly one should exist at any time.

- **`_HOOMAN.md`** — exists when this run identified items needing the human's attention.
- **`_HOOMAN_CLEAN_YYYYMMDDHHMMSS.md`** — exists when this run completed cleanly with nothing to flag. Timestamped so the human can see at a glance how recent the last clean run was.

These files are write-only from your perspective. You do not read them. The human's responses to anything you flag come back through `human.md` (read at Step 2).

```bash
# Decide which state this run ends in. Set NEEDS_HUMAN=1 if you've identified
# anything to flag for the human; NEEDS_HUMAN=0 otherwise.
NEEDS_HUMAN=0   # set to 1 when the agent has decided to flag items

if [ "$NEEDS_HUMAN" -eq 1 ]; then
  cat > ~/_HOOMAN.md <<'EOF'
# For the human monitor

(content here — see guidance below)
EOF
  rm -f ~/_HOOMAN_CLEAN_*.md
else
  CLEAN_NAME="_HOOMAN_CLEAN_$(date +%Y%m%d%H%M%S).md"
  cat > ~/"$CLEAN_NAME" <<'EOF'
No action needed. Agent ran successfully and has nothing for the human.
EOF
  for f in ~/_HOOMAN_CLEAN_*.md; do
    [ "$f" = "$HOME/$CLEAN_NAME" ] && continue
    rm -f "$f"
  done
  rm -f ~/_HOOMAN.md
fi
```

**`_HOOMAN.md` should flag** things genuinely blocked on the human: ambiguous spec, viable-path-A-vs-path-B decisions, content choices outside your scope, third-party services needing their account. Also concerning patterns you've spotted (something that looks wrong but might be intentional). Don't include routine status updates (`passed.md`/`git_update_round.md`'s job) or decisions you already made (`human_kept.md`'s job).

If a human ignores an item, the next agent re-surfaces it (or drops it if no longer relevant). No agent ever blocks waiting on a `_HOOMAN.md` response.

**h) Write `next_round.txt` (every run):**

Estimate what the next agent's run will look like, by category. The launcher uses this to pick a model variant for the next run — code-heavy work goes to a faster/cheaper model, audit/research/writing work goes to the frontier-tier default.

Format: one line, four percentages summing to 100, all four categories present even if zero. Optional comment lines below explain your reasoning.

```bash
cat > ~/next_round.txt <<EOF
CODE=75 AUDIT=15 RESEARCH=10 WRITING=0
# Generated by Agent X at $(date -Iseconds)
# Reasoning: next task is implementing the new copy button across 6 pages.
EOF
```

Categories:
- **CODE** — writing or modifying source code
- **AUDIT** — reviewing existing code or content for problems
- **RESEARCH** — investigating something to inform a decision (docs, APIs, comparisons)
- **WRITING** — prose: documentation, articles, content, copy

Heuristics: a fresh task starting → CODE-heavy. Mid-task with code already written → AUDIT-heavy. Approach unclear → RESEARCH-heavy. Documentation push → WRITING-heavy. Mixed work → split honestly. The estimate doesn't have to be perfect — it's a hint to the launcher, not a contract.

### Step 7: Exit

Just exit. The launcher releases the lock and runs final checks (mtime verification of the files you wrote at Step 6, log trim) after you're done. You do not need to delete the lock file.

---

## Rules

1. **Never run concurrently.** The lock file prevents this; the launcher acquires it before invoking you.
2. **Never assume context.** Your only memory between runs is `passed.md`, `PROJECT.md`, `human_kept.md`, and `~/research/`.
3. **`human.md` overrides `passed.md`.** When the author interjects, their instructions come first.
4. **Always archive before overwriting.** Copy `passed.md` to `~/bkupmd/passed_{YYYYMMDDHHMMSS}.md` before writing the new one. Same for `human.md` once you've acted on it. Same for `git_overview.md` and `git_update_round.md`.
5. **Stay within scope.** `PROJECT.md` defines the project. Don't drift — unless `human.md` says otherwise.
6. **`done.txt` means stop.** Only create it when you are certain all work is complete. If you see one alongside non-empty `human.md`, the launcher has already restarted the relay before invoking you.
7. **Respect the roles defined in `PROJECT.md`.** If a project assigns a primary decision-maker, agent-specific role limits, or a delegation matrix, follow it. Document every override (reverted work, rejected direction, declined recommendation) in both `passed.md` and `human_kept.md`. Silent rejection is not allowed.
8. **Document research.** Anything you research goes into `~/research/` as a dated markdown file. Review recent research files on every run.
9. **Keep the project root clean.** The root holds only relay system files (`AGENT_RELAY.md`, `PROJECT.md`, `passed.md`, `human.md`, `human_kept.md`, `next_round.txt`, `done.txt`, `agent_relay.lock`, and one of `_HOOMAN.md` / `_HOOMAN_CLEAN_*.md`). Everything else — code, scratch files, logs, data, output — goes into subdirectories defined by `PROJECT.md` or into `./scratch/` if uncertain.
10. **Work in small bites and reserve turns for handoff.** Pick ONE small task. Leave breadcrumbs. Check pace every 8-10 calls. Getting cut off without writing the Step 6 files is the worst possible outcome — when in doubt, stop and hand off NOW.
11. **Cover for unreliable agents per `PROJECT.md`'s delegation matrix, if defined.** Coverage absorbs workload, not authority. Document any coverage with a `COVERAGE:` line in `passed.md`.

---

## Files and Directories Reference

**Project root files:**

- `passed.md` — handoff log (read Step 3, write Step 6b)
- `PROJECT.md` — project brief (read Step 4)
- `human.md` — one-time override from the author; may be empty (Step 2, archived at 6c)
- `human_kept.md` — persistent lessons (read Step 2b, append Step 6d)
- `next_round.txt` — workload estimate for the next run; launcher reads this to pick a model (write Step 6h, launcher-consumed). Write-only from the agent's perspective.
- `done.txt` — present only when project is complete (created Step 6e; launcher handles restart)
- `_HOOMAN.md` *or* `_HOOMAN_CLEAN_YYYYMMDDHHMMSS.md` — agent-to-human signal, exactly one exists after a run (Step 6g)
- `agent_relay.lock` — managed by the launcher; do not touch

**Directories:**

- `~/bkupmd/` — timestamped archives of `passed.md`, `human.md`, `git_overview.md`, `git_update_round.md`. (`git_updates_all.md` and `_HOOMAN*` are not archived — the former never destroys content, the latter is write-only.)
- `~/research/` — dated markdown files for any research conducted. Review recent ones on every run.
- `~/gitinfo/` — three files written every run at Step 6f for GitHub readers: `git_overview.md` (rewrite), `git_update_round.md` (rewrite), `git_updates_all.md` (prepend new entry).
- `~/scratch/` — your working space and breadcrumbs (`scratch/breadcrumbs.md`).
