Run the unified quality-gated development pipeline for the following task:

$ARGUMENTS

Execute phases in sequence. After each artifact-producing phase, pause, present the artifact summary, and wait for the user to reply `continue` or give feedback.

Use slim agents by default. Escalate to the full agent only when a slim result returns `NEEDS_INPUT`, `NEEDS_RESEARCH`, `NEEDS_DETAIL`, or the user explicitly asks for depth.

---

## Phase 0: Session Setup

```bash
RUN_ID="$(date +%Y%m%d-%H%M%S)-$(echo '$ARGUMENTS' | tr ' ' '-' | tr '[:upper:]' '[:lower:]' | cut -c1-40)"
SESSION_DIR=".claude/artifacts/$RUN_ID"
mkdir -p "$SESSION_DIR"
echo "$SESSION_DIR" > .claude/artifacts/current.txt
ln -sfn "$RUN_ID" .claude/artifacts/current
```

---

## Interactive Phases

| Phase | Agent | Output | Standalone |
|------:|-------|--------|------------|
| 1 | `requirements-slim` | `brief.md` | `/arm` |
| 2 | `architect-slim` | `design.md` | `/design` |
| 3 | `adversarial-slim` | `critique.md` | `/ar` |
| 4 | `planner-slim` | `plan.md` | `/plan` |
| 5 | `drift-detector` | `drift-report.md` | `/pmatch` |
| 6 | `builder-slim` | `build-report.md` | `/build` |

For each phase:
- Read the required upstream artifact(s) from the current session.
- Produce the next artifact in the same session directory.
- Present a short summary, the artifact path, and the standalone command.
- Wait for user feedback before continuing.

Use this checkpoint template:

```text
Phase {N} Complete — {title}.
Standalone command: {command}

{short summary}

Artifact: {session-dir}/{artifact}

Reply with feedback to revise, or "continue" to proceed to {next phase}.
```

---

## Phase Logic

### Phase 1: Requirements
- Crystallize the task into `brief.md`.
- Ask targeted questions only when needed.

### Phase 2: Design
- Build `design.md` from `brief.md` plus live docs and existing code patterns.

### Phase 3: Adversarial Review
- Produce `critique.md` with `APPROVED` or `REVISE_DESIGN`.
- If user says `revise`, return to Phase 2. Max 2 revision cycles.
- If user says `override`, continue and record the override.

### Phase 4: Planning
- Produce deterministic `plan.md` with concrete files, steps, and checks.

### Phase 5: Drift Detection
- Compare `plan.md` vs `design.md` and write `drift-report.md`.
- If user says `fix-plan`, return to Phase 4.
- If user says `fix-design`, return to Phase 2.
- If user says `override`, continue and record the override.

### Phase 6: Build
- Execute `plan.md` step by step with no improvisation.
- Verify BEFORE/AFTER matches, acceptance checks, build, and types.
- If build is `PARTIAL` or `FAILED`, still pause and let the user decide whether QA should continue.

---

## QA Pipeline (Phases 7-11)

After Phase 6, run these automatically without additional pauses and combine results into `qa-report.md`:

| Phase | Agent | Purpose |
|------:|-------|---------|
| 7 | `denoiser` | remove debug noise and leftovers |
| 8 | `quality-fit` | check types, lint, and repo conventions |
| 9 | `quality-behavior` | run build/tests and verify spec alignment |
| 10 | `quality-docs` | check route docs, exported docs, and doc regressions |
| 11 | `security-slim` | scan for injection, auth gaps, secrets, and critical issues |

At the end, present:

```text
QA Complete.
Artifact: {session-dir}/qa-report.md

{summary of warnings, failures, or clean pass}
```

---

## Final Report

When all phases finish, summarize:
- current session path
- artifact verdicts by phase
- overrides or revision loops used
- files changed
- recommended next action
