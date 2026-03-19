# Cache Warm

Prepare the cache for a new repository without baking in framework assumptions.

## Process

1. Initialize the cache directory.
2. Detect the active framework only if the repository already exposes one.
3. Warm generic pattern summaries that are broadly useful.
4. Add framework-specific QA rules only when the repository conventions clearly justify them.

```bash
bash "$CLAUDE_PROJECT_DIR/.claude/hooks/cache.sh" init
```

## Template Defaults

This template ships a small generic pattern set:

| Pattern | Purpose |
|---------|---------|
| `rest-api` | route or resource-style handler decisions |
| `auth-jwt` | token or session auth reminders |
| `crud-endpoint` | CRUD surface checklist |

The `qa-rules/` directory starts empty on purpose. Populate it only after the real project establishes stack-specific conventions worth caching.

## Usage

Run once after cloning a new repository from the template:

```text
/cache-warm
```

Then use `/cache-stats` to confirm the cache initialized correctly.

## Related Commands

- `/cache-stats` — inspect cache usage
- `/cache-clear` — clear stale cache state
