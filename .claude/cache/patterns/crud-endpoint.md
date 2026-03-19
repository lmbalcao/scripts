# Pattern: CRUD Resource Endpoint

Use this cached pattern only when the task matches a resource-style CRUD surface.
Treat it as a short decision checklist, not as a fixed implementation.

## Applicability
- Endpoints or controllers operating on a single resource type
- Read/update/delete flows with stable identifiers
- Repositories that already expose resource ownership or lifecycle semantics

## Common Decisions
1. **Identifier source**: Reuse the repository's real ID format and validation strategy.
2. **Ownership / scope**: Filter by user, tenant, org, or other ownership boundary when needed.
3. **404 behavior**: Distinguish invalid input from missing records.
4. **Soft delete**: Only use tombstones if the repository already uses them.
5. **Timestamps / partial update**: Match local update semantics instead of inventing new ones.

## Minimal Skeleton

```typescript
async function handler(req: RouteRequest, res: RouteResponse) {
  const id = extractValidatedId(req);
  if (!id) return res.status(400).json({ error: 'Invalid identifier' });

  if (req.method === 'GET') {
    const record = await resourceStore.getOne(id, req.authContext);
    if (!record) return res.status(404).json({ error: 'Not found' });
    return res.status(200).json({ data: record });
  }

  if (req.method === 'PATCH' || req.method === 'PUT') {
    const parsed = updateSchema.safeParse(req.body);
    if (!parsed.success) return res.status(400).json({ error: 'Invalid input' });

    const updated = await resourceStore.update(id, parsed.data, req.authContext);
    if (!updated) return res.status(404).json({ error: 'Not found' });
    return res.status(200).json({ data: updated });
  }

  if (req.method === 'DELETE') {
    const deleted = await resourceStore.remove(id, req.authContext);
    if (!deleted) return res.status(404).json({ error: 'Not found' });
    return res.status(204).end();
  }

  return res.status(405).json({ error: 'Method not allowed' });
}
```

## Checklist
- [ ] ID parsing matches local conventions
- [ ] Missing records return 404, not 500
- [ ] Update semantics match local PATCH/PUT conventions
- [ ] Delete behavior matches hard-delete vs soft-delete policy
- [ ] Ownership or tenant scope is enforced
- [ ] Audit or timestamp updates follow repository conventions
