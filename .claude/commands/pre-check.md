# Pre-Check

Run: `/pre-check <task>`

$ARGUMENTS

---

Use the **pre-check** agent.

## Process

1. **Extract keywords** from the task.
   - Feature name
   - Entity name
   - Action verb

2. **Search the codebase**.
   ```bash
   # Prefer directories configured in .claude/settings.json -> pipeline.preCheck.searchDirs.
   # Otherwise scan common code roots that exist.
   for dir in src app lib server services packages; do
     [ -d "$dir" ] || continue
     grep -r "KEYWORD" "$dir" --include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx" | head -5
   done

   # Find similarly named files
   find . -type f \( -name "*KEYWORD*.ts" -o -name "*KEYWORD*.tsx" -o -name "*KEYWORD*.js" -o -name "*KEYWORD*.jsx" \) | head -10
   ```

3. **Check dependencies**.
   ```bash
   grep -i "KEYWORD" package.json
   ```

4. **Web search** only if local matches are weak or missing.
   - Max 3 searches
   - Query: `[keyword] [framework or runtime] library`

5. **Output a recommendation**.

---

## Output

Write to session `pre-check.md`:

```markdown
# Pre-Check: [Task]

## Confidence: [0-100]

## Codebase Matches

| Path | Match | Relevance |
|------|-------|-----------|
| path/to/existing/file.ts | similar handler or component | HIGH |

## Dependencies

| Package | Relevance |
|---------|-----------|
| package-name | HIGH - likely related |

## External Options

| Option | Fit |
|--------|-----|
| library-name | Good / weak / not needed |

## Recommendation: [EXTEND_EXISTING | USE_LIBRARY | BUILD_NEW]

**Reasoning:** [1 sentence]

**Next step:** [What to pass to Phase 1]
```

---

## Decision Logic

```
IF strong local match exists:
  -> EXTEND_EXISTING
ELSE IF installed or well-fitting library exists:
  -> USE_LIBRARY
ELSE:
  -> BUILD_NEW
```

---

## Tip

Run this before any request that may duplicate an existing implementation.
