Documentation check - verify route docs, public function docs, and API documentation.

---

## Purpose

Verify that new or modified code has appropriate documentation:
- Route or endpoint documentation follows the repository's established format.
- Public functions use JSDoc or TSDoc when the code is not self-explanatory.
- Complex exported types have brief descriptions when needed.

---

## Execution

Use the **quality-docs** agent.

**Input:** Read `build-report.md` to identify changed files.

**Process:**

1. Check route and endpoint docs:
   - If the repository uses Swagger or OpenAPI, new routes must match that format.
   - Otherwise, follow the established route documentation pattern already present in the codebase.
2. Check exported functions for useful JSDoc or TSDoc.
3. Check complex types, interfaces, and enums for brief descriptions where helpful.
4. Append results to `qa-report.md`.

---

## Documentation Requirements

| Item | Requirement |
|------|-------------|
| Route / endpoint docs | REQUIRED when the repository documents routes |
| Public exported functions | RECOMMENDED when behavior is not obvious |
| Utility functions | Optional unless non-obvious |
| Types / interfaces | RECOMMENDED when complex or widely reused |

---

## Output

After check, report:

```
## Quality Docs Complete

**Verdict:** [PASS | FAIL | WARN]

### Route Documentation
- Surfaces checked: [N]
- Fully documented: [N]
- Missing or incomplete docs: [List]

### Function Documentation
- Functions checked: [N]
- Adequately documented: [N]
- Missing docs: [List]

### Required Additions
[If FAIL, specific docs needed]

### Next Step
Run `/security-review` for security audit.
```

---

## Gate

This command is part of the QA pipeline.
Order: `/denoise` -> `/qf` -> `/qb` -> `/qd` -> `/security-review`
