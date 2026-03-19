---
name: new-migration
description: Create a new migration file using the repository's real migration workflow and next identifier
argument-hint: <description> (e.g. add_status_to_contacts)
---

Create a new migration file using the active repository's actual migration system.

## Step 1: Discover the migration workflow

Inspect the repository before creating anything:
- Migration directory location
- Naming or numbering convention
- File extension and format
- Migration runner or registration mechanism
- Whether migrations are SQL, ORM-generated, or code-based

## Step 2: Determine the next identifier

Find the latest migration in the real migration directory and derive the next valid identifier or filename.
Do not assume a fixed directory, fixed ID range, or hardcoded duplicate list.

## Step 3: Create the migration file

Create the new migration file using the repository's actual naming pattern.
Examples:
- `<ID>_$ARGUMENTS.sql`
- `<timestamp>_$ARGUMENTS.ts`
- `<name>.sql`

## Step 4: Write a safe migration

When the repository supports safe/idempotent migrations, prefer:
- Additive changes over destructive ones
- Guards such as `IF EXISTS` / `IF NOT EXISTS`
- Reversible changes where the migration system expects them
- Existing timestamp, UUID, foreign-key, and tenancy conventions already used nearby

## Step 5: Register or wire the migration if required

Only update migration registries, manifests, or runner files when the repository's workflow actually requires it.

## Rules
- Inspect the real migration system before creating the file.
- Avoid destructive migrations unless the user explicitly asks for them.
- Match the repository's existing schema, naming, and rollback style.
- Preserve ownership, tenancy, and integrity constraints when the data model uses them.
- Call out uncertainty instead of inventing migration workflow details.
