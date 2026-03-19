# Database / Persistence Rules

Load this guidance only when the task touches database, ORM, query-builder, or persistence code.
Confirm the active repository's real data-access stack before following any pattern.

## Connection and Query Safety
- Reuse the repository's established database client, ORM, or query-builder import path.
- Prefer parameterized queries, prepared statements, or equivalent safe bindings.
- Avoid string interpolation for SQL or query construction.
- Enforce ownership, tenancy, or record scoping when the data model requires it.

## Aliases and Naming
- Avoid reserved keywords as SQL aliases.
- Prefer short, explicit aliases that match nearby code.
- Keep naming consistent with the existing schema and query style.

## Schema Assumptions
- Verify table names, columns, indexes, and relations from the live schema, ORM schema, or current migrations.
- Do not rely on stale docs or prompt memory for schema details.
- Call out uncertainty explicitly when the schema cannot be verified.

## Migrations
- Inspect the current migration location, numbering scheme, and runner before adding new migrations.
- Prefer additive and reversible changes unless the task explicitly requires otherwise.
- Use safety guards such as `IF EXISTS` or `IF NOT EXISTS` when the repository's migration format supports them.
- Register or wire migrations wherever the repository's real workflow requires it.
