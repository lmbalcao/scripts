---
name: claude-compat-pipeline
description: Use this when the user asks for the former .claude process or uses commands like /pre-check, /plan, /build, /security-review, /dev-pipeline, or /auto-pipeline. Keeps the same phased workflow and artifacts path.
---

# Claude-Compatible Pipeline

Mirror the old `.claude` behavior in Codex while staying deterministic and concise.

## Session + Artifacts

1. Create or reuse session:
```bash
bash .codex/scripts/session.sh new "<task>"
# or
bash .codex/scripts/session.sh current
```
2. Store artifacts in `.claude/artifacts/<session>/` with these filenames:
- `pre-check.md`
- `brief.md`
- `design.md`
- `critique.md`
- `plan.md`
- `drift-report.md`
- `build-report.md`
- `qa-report.md`

## Compatibility safeguards

Before edits:
```bash
bash .codex/scripts/protect-files.sh <path>
```

After JS/TS edits:
```bash
bash .codex/scripts/auto-format.sh <path>
```

## Command Mapping

### `/pre-check <task>`
- Search the codebase for existing implementation.
- Prefer directories configured in `.claude/settings.json -> pipeline.preCheck.searchDirs` when present.
- Decide: `EXTEND_EXISTING` vs `USE_LIBRARY` vs `BUILD_NEW`.
- Write result to `pre-check.md` with:
  - `Codebase Matches`
  - `Recommendation`
  - `Reasoning`

### `/plan <task>`
- If `design.md` exists: build a deterministic plan from it.
- Else: build a plan from task + codebase exploration.
- Plan must list concrete steps, file paths, and acceptance checks.
- Write to `plan.md`.

### `/build`
- Execute plan step by step with no improvisation.
- Report status per step and final verdict (`SUCCESS|PARTIAL|FAILED`).
- Write to `build-report.md`.

### `/security-review`
- Scan changed files for:
  - string-built query risks
  - missing auth or guard checks on protected surfaces
  - hardcoded secrets
  - command injection patterns
- Write findings, severity, and remediation to `qa-report.md`.

### `/dev-pipeline <task>`
Run phases in order and pause after each artifact phase:
1. pre-check
2. requirements / brief
3. design
4. critique
5. plan
6. drift check
7. build
8. QA / security

### `/auto-pipeline <task>`
Run the same phases automatically with gates:
- HARD stop on: pre-check, adversarial high-risk findings, security critical findings.
- SOFT warn on: requirements, design, or plan quality gaps.
- Load cached pattern summaries only when they match the current repository conventions.

## Rules references

Load these only when relevant:
- API rules: `.claude/rules/api.md`
- DB rules: `.claude/rules/database.md`
- React rules: `.claude/rules/react.md`
