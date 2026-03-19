# Pattern: Route / Resource API

Use this cached pattern only when the task matches a route or endpoint that exposes resource-style read/write operations.
Treat it as a compact reminder, not as a literal framework template.

## Applicability
- Public or internal routes, handlers, or controllers
- Resource endpoints with list/create/update/delete behavior
- Codebases that already have a route layer and a consistent response shape

## Common Decisions
1. **Auth / guard**: Apply the repository's existing auth or permission wrapper only when the surface is protected.
2. **Validation**: Validate params, query, and body before data access.
3. **Errors**: Reuse the local error envelope and status-code pattern.
4. **Responses**: Match the repository's existing success shape.
5. **Ownership / tenancy**: Enforce record scoping when the data model requires it.

## Minimal Skeleton

```typescript
import { routeGuard, RouteRequest, RouteResponse, dataClient, inputSchema } from './local-patterns';

async function handler(req: RouteRequest, res: RouteResponse) {
  if (req.method === 'GET') {
    const records = await dataClient.list({ scope: req.authContext });
    return res.status(200).json({ data: records });
  }

  if (req.method === 'POST') {
    const parsed = inputSchema.safeParse(req.body);
    if (!parsed.success) {
      return res.status(400).json({ error: 'Invalid input' });
    }

    const created = await dataClient.create(parsed.data, req.authContext);
    return res.status(201).json({ data: created });
  }

  return res.status(405).json({ error: 'Method not allowed' });
}

export default routeGuard(handler);
```

## Checklist
- [ ] Route location matches the active framework
- [ ] Validation happens before writes
- [ ] Success and error envelopes match nearby routes
- [ ] Auth / guard pattern matches the repository
- [ ] Ownership / tenant filtering is enforced when required
- [ ] Data access is parameterized or safely bound
