Security audit - check for injection, auth/access-control gaps, and secret exposure.

---

## Purpose

Audit code changes for security vulnerabilities:
- Injection attacks (SQL, XSS, command, template)
- Authentication and authorization gaps
- Access control and ownership issues
- Secrets exposure
- Security misconfiguration

---

## Execution

Use the **security-auditor** agent.

**Input:** Read `build-report.md` to identify changed files.

**Process:**

1. Scan changed files for injection patterns and unsafe execution paths.
2. Audit auth and access control:
   - Sensitive routes, handlers, or controllers follow the repository's established auth or guard pattern.
   - Identity comes from trusted auth context, not request payloads.
3. Verify ownership, tenancy, or record-scoping checks where applicable.
4. Check for secrets, credentials, or dangerous configuration leaks.
5. Append results to `qa-report.md`.

---

## Vulnerability Patterns

| Pattern | Risk | Detection |
|---------|------|-----------|
| Interpolated query / unsafe DB call | SQL Injection | HIGH |
| Unsafe HTML injection | XSS | MEDIUM |
| Shell execution with user input | Command Injection | CRITICAL |
| Missing auth / guard on sensitive route | Auth Bypass | HIGH |
| Missing ownership / tenant filter | Data Leak | HIGH |
| Hardcoded secret or token | Secret Exposure | CRITICAL |

---

## Output

After audit, report:

```
## Security Audit Complete

**Verdict:** [PASS | FAIL | CRITICAL]

### Vulnerability Scan
- Injection: [CLEAR | FOUND]
- XSS / HTML injection: [CLEAR | FOUND]
- Command execution risk: [CLEAR | FOUND]

### Authentication & Access Control
- Sensitive surfaces checked: [N]
- Properly protected: [N]
- Needs review: [List]

### Secrets & Configuration
- Hardcoded secrets: [NONE | FOUND]
- Dangerous config: [NONE | FOUND]

### Required Fixes
[If FAIL/CRITICAL, specific fixes with code examples]

### Summary
This concludes the QA pipeline.
```

---

## Verdict Levels

- **PASS:** No vulnerabilities found.
- **FAIL:** Vulnerabilities found and must be fixed.
- **CRITICAL:** Severe vulnerabilities found. Stop immediately.

---

## Gate

This command is the final step of the QA pipeline.
Order: `/denoise` -> `/qf` -> `/qb` -> `/qd` -> `/security-review`

After this passes, the implementation is ready for user review.
