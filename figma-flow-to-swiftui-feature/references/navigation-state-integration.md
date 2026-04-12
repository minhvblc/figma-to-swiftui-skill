# Navigation and State Integration

This reference helps the agent wire a generated feature into the project's real architecture.

## Reuse Existing Navigation

Check for:
- `NavigationStack` with path-based routing
- enum-based destinations
- coordinator or router objects
- tab-root navigation rules
- sheet or full-screen presentation helpers

Never create a second navigation pattern inside the same feature unless the project already nests one intentionally.

## Reuse Existing State Ownership

Match the surrounding feature style:
- local `@State` for simple local-only screens
- `@Observable` or view model objects for multi-action screens
- reducer/store patterns if the project already uses them
- environment-driven dependencies if the project already injects them

Do not introduce a brand-new state container style for one feature.

## Service and Dependency Wiring

Before stubbing anything, search for:
- auth or account services
- repositories
- request clients
- `IKCoreApp` modules or wrappers
- shared error-mapping helpers

If the project already has the capability, integrate with it. Only scaffold a placeholder when no implementation exists and the user has not asked for full backend integration.

## Routing Decisions

For each transition, define:
- who triggers it
- what condition allows it
- whether it depends on async success
- where failures remain visible
- whether the destination can pop, dismiss, or reset

Write this down before editing route code.

## Recommended Integration Order

1. extend route definitions
2. extend state models or view models
3. connect services and async actions
4. render UI states
5. trigger navigation from the same success boundary used by nearby features

## Project-Aware Rules

- Prefer nearby feature patterns over generic SwiftUI samples
- Reuse `IKFont`, `IKCoreApp`, shared modifiers, assets, and color tokens when available
- Reuse existing analytics, logging, and error presentation hooks if the project has them
- Avoid duplicating helper types that already exist under slightly different names
