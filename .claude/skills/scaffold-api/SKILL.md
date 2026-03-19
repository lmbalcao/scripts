---
name: scaffold-api
description: Generate a new route or API handler following the active repository conventions
argument-hint: <route-path> (e.g. companies/[id]/notes)
---

Create a new route or API handler for `$ARGUMENTS` using the repository's existing route, auth, data-access, and documentation patterns.

## Step 1: Discover the local route pattern

Before writing anything, inspect nearby route files and determine:
- The route location and naming convention used by the active framework
- The request / response types used locally
- The auth or guard wrapper used for protected routes
- The documentation format already used for public routes
- The data-access layer used by nearby handlers

## Step 2: Scaffold the file in the correct location

Create the new route in the location that matches the active repository.
Examples:
- `app/api/.../route.ts`
- `server/routes/...`
- `src/controllers/...`

Do not assume a specific framework unless the codebase already uses it.

## Step 3: Match the local structure

Your scaffold should include only the patterns already present in nearby routes:
- Existing route docs format such as Swagger/OpenAPI, if used
- Existing method dispatch or verb handling style
- Existing validation approach
- Existing auth / permission wrapper
- Existing data-access abstraction or client
- Existing success and error response envelope

## Minimal skeleton

```typescript
import { routeTypes, routeGuard, validator, dataClient } from './local-patterns';

export default routeGuard(async function handler(req, res) {
  if (req.method !== 'GET') {
    return res.status(405).json({ error: 'Method not allowed' });
  }

  const input = validator(req);
  if (!input.ok) {
    return res.status(400).json({ error: 'Invalid input' });
  }

  const result = await dataClient.run(input.value, req.authContext);
  return res.status(200).json({ data: result });
});
```

## Rules
- Reuse the repository's real route location and file naming scheme.
- Reuse local auth / permission wrappers instead of inventing new ones.
- Reuse the current data-access layer instead of assuming direct SQL.
- Validate params, query, or body before performing writes.
- Keep the response and error shapes consistent with nearby routes.
- If the repository documents routes, follow that format exactly.
