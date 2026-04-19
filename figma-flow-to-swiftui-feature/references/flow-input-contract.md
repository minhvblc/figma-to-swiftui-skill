# Flow Input Contract

Normalize the user's request into a feature contract before touching code. This prevents the agent from generating pretty screens with incomplete behavior.

## Minimum Contract

Capture these fields:
- `feature_goal`: what the user is trying to let the end user accomplish
- `screens`: each screen name plus its Figma URL or node ID
- `entry_point`: how the flow starts
- `transitions`: how the user moves between screens
- `actions`: primary and secondary actions on each screen
- `async_work`: network or persistence operations
- `result_states`: loading, error, empty, success, blocked, disabled, retry
- `project_constraints`: routing, architecture, libraries, shared modules, tokens

## Acceptable Screen Inputs

The user may provide:
- One Figma file with multiple node IDs
- Multiple Figma URLs, one per screen
- A mixed list of URLs plus screen names in plain text
- A `.txt` / `.md` / spec document plus one or more Figma nodes (read the doc first — see [../../figma-to-swiftui/references/source-document.md](../../figma-to-swiftui/references/source-document.md))
- A behavior-only PM or product document plus a broad Figma root node

When a document is present, extract the contract from it **before** fetching Figma. The document's screen list + actions + required states become the driver; Figma provides visuals inside that scope. See source-document.md for the extraction template and rules for resolving doc-vs-Figma conflicts.

Always normalize the combined input into a stable screen list:

```text
Screen: Login
Node: https://www.figma.com/design/...?...node-id=1-2
Purpose: credentials entry
Next: OTP
```

## What Can Be Inferred

You may infer:
- Screen order when the nodes are clearly labeled and the flow is obvious
- Reuse candidates when multiple nodes share the same component structure
- Standard UI states that every async action needs
- Candidate screen and action mappings, as long as you mark confidence and stop when it is too low

You must not infer:
- API request shapes
- Validation rules that affect business behavior
- Success criteria that change navigation
- Security-sensitive behavior such as auth, payments, or permissions

## Missing Information Handling

Use this rule:
- If the missing detail affects only copy or minor presentation, proceed and state the assumption
- If the missing detail affects data flow, navigation, or architecture, ask or stop short of unsafe code
- If the missing detail affects which node or element owns a primary action, produce a candidate mapping table before proceeding

## Recommended Normalized Output

Before coding, write a short contract like this:

```text
Feature: Sign In
Entry: Login screen opened from Account tab
Screens:
- Login -> node 1:2
- OTP -> node 1:3
- Profile Setup -> node 1:4
Transitions:
- Login submit success -> OTP
- OTP verify success -> Profile Setup
- Profile Setup finish -> Home
Async work:
- submit credentials
- verify code
- save profile
Required states:
- inline validation
- submitting
- retry on failure
- success handoff
Reuse:
- existing auth service
- existing router
- IKFont and project color tokens
```
