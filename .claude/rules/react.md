# React / Frontend Rules

Load this guidance only when the active repository actually uses React or a similar component-driven frontend.
Confirm the real UI stack before applying any framework-specific convention.

## Components and Styling
- Reuse the repository's existing component library and styling system before introducing raw HTML or ad-hoc CSS.
- Match the local spacing, typography, color, and layout patterns.
- Prefer shared theme tokens or design primitives over hardcoded values.

## State and Data Fetching
- Reuse the current state-management and server-state tooling already present in the repository.
- If the codebase already uses a specific data-fetching library, continue with it instead of introducing a competing pattern.
- Keep auth, theme, and app-wide state aligned with existing providers or contexts.

## UI Conventions
- Follow the established component API and layout syntax used by nearby files.
- If the repository already uses MUI Grid v2, keep the `size` prop syntax instead of older `item` props.
- If the repository already uses React Query, continue using it rather than mixing in another server-state library.
- Preserve existing dark-mode, theming, and responsive behavior conventions.

## File Structure
- Place new UI code where the repository already expects it: feature modules, shared UI, route segments, or app pages.
- Do not invent a new frontend structure when a local pattern already exists.
