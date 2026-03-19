# Route / Handler Rules

Load this guidance only when the task touches route, handler, or controller code.
Confirm the active framework and existing local patterns before applying any example literally.

## Authentication
- Reuse the repository's established auth, guard, or permission wrapper.
- Derive user identity from trusted auth context, not request payloads.
- If the repository has a protected request type, use it instead of a generic request type.
- Match the existing authorization pattern for elevated or admin-only operations.

## Handler Pattern
- Follow the repository's existing request validation, method dispatch, and error-handling style.
- Return consistent status codes and response shapes with nearby handlers.
- Log failures using the local logging pattern, not ad-hoc console noise.

## Route Documentation
- If the repository already uses Swagger or OpenAPI, keep using it.
- Otherwise, match the established route documentation format already in the codebase.
- Do not introduce undocumented public behavior on new routes.

## Response Patterns
- 200-range for successful operations.
- 400-range for validation, auth, and method errors.
- 500-range only for true server failures.
- Preserve the repository's existing error envelope where one exists.
