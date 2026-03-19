Code quality check - verify types, lint, and project conventions.

---

## Purpose

Verify that implemented code fits the active repository quality standards:
- TypeScript types are correct
- ESLint rules pass
- Project conventions followed

---

## Execution

Use the **quality-fit** agent.

**Input:** Read `build-report.md` to identify changed files.

**Process:**

1. Run automated checks:
   - `npx tsc --noEmit` — Type checking
   - `npx eslint [files]` — Lint checking

2. Check active repository conventions:
   - Imports, aliases, and module boundaries match the current codebase
   - Auth and access-control flows follow established local patterns
   - Data-access code is safe and consistent with the repository
   - Route, handler, and UI changes follow current validation, docs, and styling conventions

3. Append results to `qa-report.md`

---

## Convention Checklist

| Convention | Check |
|------------|-------|
| Imports and boundaries | Match existing aliases and module layout |
| Data access safety | No unsafe string interpolation or ad-hoc query patterns |
| Auth / access control | Match local guards, middleware, and identity flow |
| Route / handler pattern | Follow current validation, docs, and error handling |
| UI conventions | Reuse established components, styling, and tokens |


---

## Output

After check, report:

```
## Quality Fit Complete

**Verdict:** [PASS | FAIL]

### Automated Checks
- TypeScript: [PASS | FAIL]
- ESLint: [PASS | FAIL]

### Convention Compliance
[Table of conventions and status]

### Issues Found
[List of specific issues with file:line references]

### Required Fixes
[If FAIL, specific fixes needed]

### Next Step
Run `/qb` for behavior validation.
```

---

## Gate

This command is part of the QA pipeline.
Order: `/denoise` → `/qf` → `/qb` → `/qd` → `/security-review`
