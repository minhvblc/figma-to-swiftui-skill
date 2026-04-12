# Output Schema

Before writing code, always emit a short structured summary. This slows the agent down in the right place and makes bad assumptions visible early.

## Required Sections

Use these sections in order:

1. `Feature Contract`
2. `Node Mapping`
3. `Reuse Plan`
4. `Screen Graph`
5. `Open Questions` or `Assumptions`

## Required Content

### Feature Contract

Include:
- feature goal
- entry point
- screens
- transitions
- async work
- required user-visible states

### Node Mapping

Include:
- `screen -> node`
- confidence for each mapping
- `action -> candidate element` when the document is not explicit

### Reuse Plan

Name the actual project-native pieces that will be reused:
- router or navigation pattern
- state ownership pattern
- services or persistence helpers
- shared components or modifiers
- `IKFont`, `IKCoreApp`, assets, colors, tokens

### Screen Graph

Keep it compact:

```text
Splash -> Intro 1
Intro 1 --Next--> Intro 2
Intro 1 --Skip--> Main
```

### Open Questions or Assumptions

- list only items that materially affect implementation
- if none, state that explicitly

## Stop Rule

Do not start code generation until this schema is present. If the schema exposes a low-confidence or architecture-affecting ambiguity, resolve it first.
