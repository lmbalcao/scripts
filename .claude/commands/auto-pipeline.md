# Automated Pipeline

Run: `/auto-pipeline [--profile=yolo|standard|paranoid] [--gate=soft|mixed|hard] <task>`

$ARGUMENTS

---

## Config

```bash
PROFILE="${PROFILE:-standard}"
GATE_MODE="${GATE_MODE:-mixed}"
SESSION=".claude/artifacts/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$SESSION"

# Initialize cache
bash "$CLAUDE_PROJECT_DIR/.claude/hooks/cache.sh" init
```

Use `.claude/settings.json` as the default control plane. Consult `lib/config.md`, `lib/validator.md`, or `lib/cache.md` only when a phase needs clarification or troubleshooting.

---

## Execution Loop

For each phase:
1. Respect profile skip rules, except Phase 0 which never skips.
2. Reuse cache only when the cached summary still matches the current repository conventions.
3. Run the phase with its token budget.
4. Validate the artifact.
5. Continue, warn, or pause based on gate severity.

---

## Phase Summary

| Phase | Agent | Budget | Output | Gate | Core checks |
|------:|-------|--------|--------|------|-------------|
| 0 | `pre-check` | 3000 | `pre-check.md` | HARD | codebase matches, recommendation, reasoning |
| 1 | `requirements-slim` | 4000 | `brief.md` | SOFT | problem, success criteria, no `NEEDS_INPUT` |
| 2 | `architect-slim` | 6000 | `design.md` | SOFT | decisions, sources, no `NEEDS_RESEARCH`, valid paths |
| 3 | `adversarial-slim` | 4000 | `critique.md` | HARD | verdict, no HIGH severity, limited MEDIUMs |
| 4 | `planner-slim` | 5000 | `plan.md` | SOFT | steps, BEFORE/AFTER, verified paths, no `NEEDS_DETAIL` |
| 5 | `drift-detector` | 3000 | `drift-report.md` | SOFT | verdict, coverage, no unresolved drift |
| 6 | `builder-slim` | 2000/step | `build-report.md` | HARD on blocked | no `BLOCKED`, build/types pass |
| 7 | `denoiser` | 3000 | `qa-report.md` | NONE | auto-fix noise |
| 8 | `quality-fit` | 3000 | `qa-report.md` | NONE | lint, types, convention fit |
| 9 | `quality-behavior` | 3000 | `qa-report.md` | NONE | build, tests, spec alignment |
| 10 | `quality-docs` | 3000 | `qa-report.md` | NONE | docs coverage and regressions |
| 11 | `security-slim` | 3000 | `qa-report.md` | HARD | no CRITICAL, no SQLi, no secret leaks |

---

## Phase Notes

### Phase 0
- If recommendation is `EXTEND_EXISTING`, carry the matched file into Phase 2 context.
- If recommendation is `USE_LIBRARY`, add the install step in planning.

### Phase 2 Cache
- Derive a pattern key from `brief.md`.
- On cache hit, load only the cached pattern summary.
- Never replay full cached docs unless the phase is blocked.

### Phase 3
- On `REVISE_DESIGN`, auto-retry once with fixes, then pause if still failing.

### Phase 5
- On `DRIFT_DETECTED`, auto-add missing steps once, then pause if drift remains.

### Phase 6
- Retry step-level build fixes at most twice.
- If any step is `BLOCKED`, pause and update the plan instead of improvising.

### Phases 7-11
- Run QA phases in parallel.
- Load cached QA rule summaries only when changed files are large enough to benefit.
- Reuse cached security findings only when dependency or lockfile signatures still match.
- On security cache hit, carry forward the cached summary and scan only changed files.

---

## Final Output

Report:

```text
Pipeline Complete [PROFILE: standard]
Task: {task}
Session: {session}
Tokens used: {count}

Cache:
  Hits: {hits}
  Tokens saved: {estimate}

Phases:
0. Pre-Check     [AUTO|WARN|PAUSE]
1. Requirements  [AUTO|WARN|PAUSE]
2. Design        [AUTO|WARN|PAUSE]
3. Adversarial   [AUTO|WARN|PAUSE]
4. Planning      [AUTO|WARN|PAUSE]
5. Drift         [AUTO|WARN|PAUSE]
6. Build         [AUTO|WARN|PAUSE]
7-10. QA         [AUTO|WARN|PAUSE]
11. Security     [AUTO|WARN|PAUSE]

Validation: {summary}
Files changed: {list}
Warnings: {any}
```

---

## Profiles

Read the exact profile and token settings from `.claude/settings.json`.
In practice:
- `yolo`: only critical issues stop execution
- `standard`: warn on soft failures, pause on critical ones
- `paranoid`: pause on any meaningful issue
