# Contributing

## Scope

Changes should improve the repository with minimal unnecessary complexity. Prefer clear, conventional solutions over repository-local inventions.

## Workflow

1. Keep changes focused and reviewable.
2. Reuse existing patterns before introducing new ones.
3. Run local validation before opening a pull request:

```bash
bash scripts/validate-repo.sh
```

4. Update docs when commands, behavior, automation, or governance changes.

## Commit Conventions

Use Conventional Commits when practical:

- `feat:` for a backward-compatible capability
- `fix:` for a correction
- `docs:` for documentation-only changes
- `chore:` for maintenance
- `type!:` or `BREAKING CHANGE` for breaking changes

## Pull Requests

A good pull request should:

- explain the problem being solved
- describe the main change in repository behavior
- note compatibility or migration risk
- summarize the validation performed
