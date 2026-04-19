# Source Document — Read Before Figma

When the user attaches or references a source document (`.txt`, `.md`, PM brief, spec, ticket description), read it **before** making any Figma MCP call. Shared by both skills.

## Why First

The document tells you which screens matter, which actions are in scope, and which behaviors exist beyond the static design. Without it, the agent fetches Figma blind — pulls context for frames that are not in scope, misses async behavior, and wastes tokens on mockup extras.

## Accepted Inputs

- `.txt`, `.md` files attached or pasted inline
- PM ticket description, feature brief, handoff note
- Slack/email snippets describing the flow
- A combination: document describes behavior, Figma node(s) provide visuals

If the user provides Figma only and no document, skip this step — go straight to the Figma workflow.

## What to Extract

Read the document once and produce a short contract before touching Figma:

```text
Feature: <one line>
Screens (expected): <list from doc, may not match Figma yet>
Entry point: <where the flow starts>
Actions: <per-screen primary/secondary actions>
Async work: <API calls, persistence, auth>
Required states: <loading, error, empty, retry, success>
Constraints: <libraries, architecture, tokens the project must respect>
Out of scope: <anything the doc explicitly excludes>
Unclear: <items that need user confirmation>
```

Keep it compact — this is working context, not documentation. Do not include sections the doc has nothing to say about.

## Using the Extract to Drive Figma

The contract narrows the Figma work:

- **Expected screen list** → map to Figma frames via `get_metadata`. If the doc says 4 screens and the Figma root has 8 frames, ask which 4 — do not guess.
- **Action list** → use to resolve ambiguous elements on each screen (see `ambiguous-mapping.md` in the flow skill). Skip the "action → candidate element" table if the doc already states the mapping.
- **Async work + required states** → must be implemented even if Figma does not show them. Do not stop at happy-path UI when the doc specifies error/retry/empty.
- **Constraints** → drive project audit in the flow skill's Step 2 (architecture, libraries).
- **Out of scope** → do NOT fetch or implement those, even if they are present in the Figma frame.

## Conflict Rules

When the document and Figma disagree:

- **Doc names a screen that is not in Figma** → ask; do not invent a screen.
- **Figma has a screen the doc does not mention** → ask; do not silently add it to the flow.
- **Doc describes an action no button in Figma matches** → ask; do not attach the action to the wrong element.
- **Doc specifies behavior (validation, timing, limits) not visible in Figma** → trust the doc, implement the behavior.

The document is authoritative for behavior and scope. Figma is authoritative for visuals within that scope.

## Deciding Single Screen vs Flow

Use the extracted contract to route:

| Signal | Route to |
|---|---|
| Doc describes 1 screen, 1 Figma node, no transitions | `figma-to-swiftui` alone |
| Doc describes multiple screens OR transitions OR a journey | `figma-flow-to-swiftui-feature` (which delegates per-screen to `figma-to-swiftui`) |
| Doc describes 1 screen but Figma root has multiple | Run screen discovery first; likely still `figma-to-swiftui` on the matched frame |
| No doc, 1 Figma URL | `figma-to-swiftui` |
| No doc, multiple Figma URLs or a root node | Ask the user: single screen or flow? Then route. |

## Stop Rule

Do not start Figma fetches while any of these remain unresolved:
- Screen count in doc vs Figma
- Entry point
- Whether async behavior is in scope for this task

A 30-second clarification saves minutes of wrong fetches.
