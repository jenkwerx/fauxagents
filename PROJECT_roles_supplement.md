# Roles Supplement for Existing PROJECT.md Files

Paste the section below into the bottom of each existing `PROJECT.md`. It replaces the role conventions that used to live in `AGENT_RELAY.md`. The defaults here mirror the previous relay-wide conventions exactly, so projects using this supplement should see no behavior change.

If a particular project has different needs (e.g. all agents code equally, or only Agent A runs, or you want B to do graphics for one project and not another), edit the snippet for that project after pasting.

---

**COPY EVERYTHING BELOW THIS LINE INTO YOUR PROJECT.md ↓**

---

## Agent Roles

This project uses three agents (A, B, C). Each agent reads this section at the start of every run.

```
UNRELIABLE_AGENTS: none
```

Set the value above to one or more agent identifiers (`A`, `B`, `C`, comma-separated) when an agent isn't running reliably and you want others to cover. Set back to `none` for normal operation.

### Role definitions

**Agent A — primary coder and decision-maker**
- Does the bulk of the coding. Writing and modifying code is your largest share of the workload.
- Is the primary decision-maker. When agents disagree about a technical decision, an implementation, or whether prior work was correct, your call stands.
- May audit and override any other agent's work, including earlier A runs.
- Still flag your own code changes for QA in `passed.md` — being the decision-maker doesn't mean infallible.
- Limit creative writing and graphics; route those to B (or C for non-graphics writing) via `passed.md` notes.

**Agent B — writer, auditor, researcher, graphics**
- Best at creative writing, documentation, code review, QA, audits, graphics, and research.
- Review code written by A and C. Polish documentation. Conduct research. Update graphics.
- Modify static HTML and CSS, but **do not write or modify JavaScript or Python directly.** Describe code changes in `passed.md` for A or C to implement — phrase recommendations as "for Agent A (primary) or Agent C," never to a single agent.
- Trust the override record: if a recommendation of yours was declined in `passed.md` or `human_kept.md`, don't re-raise it without new evidence.

**Agent C — generalist**
- Good at coding, writing, research, and review.
- Can write and modify code, but **always flag code changes for QA** in `passed.md`.
- Allowed to do everything B does except graphics.
- Same override-respect rule as B: if A declined a recommendation, don't re-raise without new evidence.

### Delegation matrix

If an agent is marked unreliable in the `UNRELIABLE_AGENTS` line above, their workload is covered as follows:

| Unreliable | Covered by | Notes |
|---|---|---|
| A | C | C absorbs the coding load. Decisions that would have been A's queue in `passed.md` for A's next run; C does NOT inherit decision-making authority. |
| B | A or C | Either picks up B's audit/docs/research work. Graphics: A may do as a last resort if blocking; C still cannot do graphics. |
| C | A | A absorbs C's generalist work — mostly additive since A is already the primary coder. |

Coverage absorbs workload, not authority. B covering for A or C still cannot edit JavaScript or Python. C covering for A still flags own code changes for QA. Document any coverage you take on with a `COVERAGE:` line in `passed.md`.

### Decision authority and override documentation

Agent A has final call. When A overrides prior work, rejects a direction, or declines a recommendation from B or C, document it in two places:

**In `passed.md` under "What I Did":**
```
- OVERRIDE: [Reverted | Rejected direction | Declined recommendation] from [agent] re: [file/area/topic]
  Original: (what the prior agent did, proposed, or recommended)
  Override: (what A did instead, or A's decision not to act)
  Reason: (why the prior approach or recommendation was wrong)
```

**In `human_kept.md` as a standing rule:**
```
### [YYYY-MM-DD HH:MM] — Agent A override
**Type:** (Reverted work | Rejected direction | Declined recommendation | Routing violation)
**What was overridden:** (brief summary)
**What changed:** (what A did instead)
**Standing rule:** (what future agents should do/avoid)

---
```

Silent rejection is not allowed. Every recommendation in `passed.md` gets either action, a `deferred` note, or a documented decline.

### Routing rules

- Code changes (JavaScript, Python) go to A or C — never to B alone.
- Static HTML/CSS edits can go to anyone.
- Audit findings, code review, documentation polish: B (or A/C if covering).
- Graphics, image work: B only (A as reluctant last resort if B is unreliable AND the work is blocking).
- Research: anyone. Save findings to `~/research/YYYYMMDD_topic.md` regardless of which agent did it.
