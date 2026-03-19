# Pattern: Token / Session Authentication

This cached pattern is stored under `auth-jwt` for compatibility, but it should only be used when the active repository follows a token-based or session-wrapper auth flow.
Map it to the local auth implementation rather than copying it literally.

## Applicability
- JWT, session token, or signed-cookie authentication
- Middleware, guards, or wrappers that attach identity to request context
- Protected routes or handlers that need user or role context

## Common Decisions
1. **Credential transport**: Cookie, header, or session storage must match the repository.
2. **Verification**: Reuse the existing verifier and failure behavior.
3. **Auth context**: Attach only the identity and permissions actually needed downstream.
4. **Admin / elevated access**: Keep elevated checks separate from baseline auth.
5. **Protected surfaces**: Never derive identity from request body or query when trusted auth context exists.

## Minimal Skeleton

```typescript
export interface AuthRequest extends BaseRequest {
  authContext?: {
    userId: string;
    roles?: string[];
  };
}

export function authorize(handler: Handler): Handler {
  return async (req, res) => {
    const authContext = await verifyAuthFromRequest(req);
    if (!authContext) {
      return res.status(401).json({ error: 'Unauthorized' });
    }

    req.authContext = authContext;
    return handler(req, res);
  };
}

export function requirePermission(permission: string) {
  return (handler: Handler): Handler =>
    authorize(async (req, res) => {
      if (!hasPermission(req.authContext, permission)) {
        return res.status(403).json({ error: 'Forbidden' });
      }
      return handler(req, res);
    });
}
```

## Checklist
- [ ] Secrets or signing keys come from environment or secret storage
- [ ] Expiry / refresh semantics match local auth policy
- [ ] Protected routes use trusted auth context, not request payload identity
- [ ] Elevated permissions are checked separately from baseline auth
- [ ] Failure responses match existing 401 / 403 behavior
