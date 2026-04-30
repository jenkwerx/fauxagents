# Project Brief: [PROJECT NAME]

## Summary

[One paragraph. What is this project? Who is it for? Why does it exist?]

## Tech Stack

[Languages, frameworks, runtimes, hosting/deployment, anything that constrains how work gets done. Keep it short — agents don't need a deep dive, they need to know the shape of the codebase.]

## Priority Task List

The work is ordered. Earlier items are higher priority.

1. [First concrete task]
2. [Second]
3. [Third]
4. [Etc.]

## Constraints

[Anything agents must NOT do, or must always do. Things like "preserve URL structure," "do not introduce dependencies," "match the existing visual style," "keep the site under 100KB," etc. Be specific.]

---

## Agent Roles

This project uses [N] agents. Each agent reads this section at the start of every run.

```
UNRELIABLE_AGENTS: none
```

Set the value above to one or more agent identifiers (e.g. `A`, `B`, `B,C`) when an agent isn't running reliably and you want others to cover. Set back to `none` for normal operation.

### Role definitions

| Agent | Primary responsibilities | Limits | Notes |
|---|---|---|---|
| **A** | [What A does best — e.g. "primary coder, project decision-maker"] | [What A should avoid — e.g. "long creative writing, graphics"] | [Anything else worth knowing — e.g. "final call on disagreements"] |
| **B** | [What B does best — e.g. "audits, documentation, research, graphics"] | [What B can't do — e.g. "no JavaScript or Python edits"] | [Notes — e.g. "recommendations get a real answer from A"] |
| **C** | [What C does best — e.g. "generalist coder, QA reviewer"] | [Limits — e.g. "no graphics; flag own code for review"] | [Notes] |

### Delegation matrix

If an agent is marked unreliable in the `UNRELIABLE_AGENTS` line above, their workload is covered as follows:

| Unreliable | Covered by | Notes |
|---|---|---|
| A | C | C absorbs the coding load. Decisions A would have made queue in `passed.md` for A's next run. |
| B | A or C | Whichever runs next picks up B's audit/docs/research work, within their own limits. |
| C | A | A absorbs C's generalist work. |

Coverage absorbs workload, not authority. If the role definitions above prohibit something for an agent (e.g. B can't write Python), that prohibition still applies when that agent is covering for someone else.

### Decision authority

[State who has final call when agents disagree. Example: "Agent A is the primary decision-maker. When agents disagree about a technical decision or whether prior work was correct, A's call stands. Other agents flag concerns in `passed.md`; A acts on, defers, or declines each one with documentation per the override protocol in AGENT_RELAY.md."]

[If your project has no decision hierarchy and treats all agents as equal generalists, just say so — e.g. "All agents are generalists; resolve disagreements by discussion in passed.md."]

### Routing rules

[Optional. If certain types of work should be routed to specific agents, list it. Example: "Code changes go to A or C. Audit findings go to B. Graphics go only to B. Research can go to anyone but should be cross-referenced in `~/research/`."]
