# Roles Supplement for Existing PROJECT.md Files

Paste the section below into the bottom of each existing `PROJECT.md`. It replaces the role conventions that used to live in `AGENT_RELAY.md`. The defaults here mirror the current relay-wide conventions, expanded to cover the current agents (A, C, D, G, M, OG, OGF, OQ, OQF).

If a particular project has different needs (e.g. all agents code equally, or only Agent A runs, or you want different graphics routing for one project), edit the snippet for that project after pasting.

---

**COPY EVERYTHING BELOW THIS LINE INTO YOUR PROJECT.md ↓**

---

## Agent Roles

This project uses [N] agents. Each agent reads this section at the start of every run.

```
UNRELIABLE_AGENTS: none
```

Set the value above to one or more agent identifiers (e.g. `A`, `G`, `G,C`, `M,OQ`) when an agent isn't running reliably and you want others to cover. Valid identifiers are any agent letter(s) you've defined above. Set back to `none` for normal operation.

### Role definitions

| Agent | Primary responsibilities | Limits | Notes |
|---|---|---|---|
| **A** | [Peer coder with C — can work on anything. Project decision-maker.] | [Defer to C for heavy creative writing when load-balancing] | [Final call on disagreements per Decision Authority below] |
| **C** | [Peer coder with A — can work on anything. Strong on graphics and creative writing.] | [No hard limits; coordinate with A on decision-level calls] | [Best choice when the task involves both code AND creative/graphics work] |
| **D** | [Auditor + can implement low-impact changes that align with A's or C's recommendations. Graphics-friendly.] | [No unilateral architectural decisions; surface concerns in passed.md and wait for A/C buy-in before larger edits] | [DeepSeek via Claude Code harness; requires DEEPSEEK_API_KEY] |
| **G** | [Gemini auditor, documentation, research, and graphics] | [No JavaScript or Python edits] | [Recommendations get a real answer from A or C] |
| **M** | [Documentation, audit, and low-impact changes M agrees with that A/C/D have recommended. Considered strong at creative writing until noted otherwise.] | [No unilateral architectural decisions; surface concerns in passed.md and wait for A/C/D buy-in before larger edits] | [Mistral Vibe CLI; requires MISTRAL_API_KEY. New to implementation work — start small, build trust.] |
| **OG** | [Same as M — documentation, audit, and low-impact changes OG agrees with that A/C/D have recommended.] | [Same as M — no unilateral architectural decisions; surface concerns in passed.md and wait for A/C/D buy-in before larger edits] | [Gemma 4 31B via OpenRouter (Claude Code harness); requires OPENROUTER_API_KEY. If both M and OG are active, treat as two independent auditor voices.] |
| **OGF** | [Same as OG, but on the OpenRouter free-tier Gemma model] | [Same as OG; expect tighter rate limits (200 req/day) and partial-run risk] | [Useful as a low-cost independent audit voice; requires OPENROUTER_API_KEY.] |
| **OQ** | [Same as M — documentation, audit, and low-impact changes OQ agrees with that A/C/D have recommended. Considered strong at creative writing until noted otherwise.] | [Same as M — no unilateral architectural decisions; surface concerns in passed.md and wait for A/C/D buy-in before larger edits] | [Qwen 3.6 35B A3B via OpenRouter (Claude Code harness); requires OPENROUTER_API_KEY. New to implementation work — start small, build trust. If both M and OQ are active, treat as two independent auditor voices.] |
| **OQF** | [Same as OQ, but on the OpenRouter free-tier Qwen model] | [Same as OQ; expect tighter rate limits and partial-run risk] | [Useful as a low-cost independent audit voice; requires OPENROUTER_API_KEY.] |

Most projects won't use all the agents listed above. Delete rows for agents you aren't running. The relay doesn't care which subset you use — if an agent isn't in your cron schedule, it simply doesn't appear.

### Delegation matrix

If an agent is marked unreliable in the `UNRELIABLE_AGENTS` line above, their workload is covered as follows:

| Unreliable | Covered by | Notes |
|---|---|---|
| A | C | C is A's peer and absorbs the coding/decision load. Decision-level calls queue in `passed.md` for A's next run if C wants to defer. |
| C | A | A is C's peer and absorbs the work. Heavy creative writing may queue for C's return or route to M or OQ. |
| D | M, then OQ/OQF, then G, then A/C | M and OQ are the closest analogs (auditor + light implementation). |
| G | D/M/OG/OGF/OQ/OQF, then A/C | G is the sole Gemini slot; other audit agents cover if it is unreliable. |
| M | OQ, then OG, then OGF, then OQF, then D, then G, then A/C | OQ is M's closest role twin. OG/OGF are the next closest analogs. |
| OG | OGF, then OQ, then M, then D, then G, then A/C | OGF is OG's free-tier twin. OQ/M are the next closest analogs. |
| OGF | OG, then OQ, then M, then D, then G, then A/C | OG is OGF's paid-tier twin. OQ/M are the next closest analogs. |
| OQ | M, then OQF, then D, then G, then A/C | M is OQ's twin (same role, different model). |
| OQF | OQ, then M, then D, then G, then A/C | OQF is the free-tier Qwen variant and should usually defer to paid OQ when both exist. |

Coverage absorbs workload, not authority. If the role definitions above prohibit something for an agent (e.g. G can't write Python), that prohibition still applies when that agent is covering for someone else.

If you've deleted some agent rows above because you don't use them, you can prune the corresponding rows here too — but it's harmless to leave them; an agent you never run will never be marked unreliable.

### Decision authority

[State who has final call when agents disagree. Example: "Agents A and C are peer primary decision-makers; either can ratify a direction. When A and C disagree, A's call stands. D, M, and OQ flag concerns in `passed.md`; A or C act on, defer, or decline each one with documentation per the override protocol in AGENT_RELAY.md."]

[If your project has no decision hierarchy and treats all agents as equal generalists, just say so — e.g. "All agents are generalists; resolve disagreements by discussion in passed.md."]

### Routing rules

[Optional. If certain types of work should be routed to specific agents, list it. Example: "Code changes go to A or C. Graphics-heavy work prefers C, then D. Creative writing prefers C, then M or OQ. Audit findings go to G, D, M, OQ, or OQF. Research can go to anyone but should be cross-referenced in `~/research/`."]
