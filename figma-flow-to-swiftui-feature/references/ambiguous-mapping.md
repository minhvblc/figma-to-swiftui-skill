# Ambiguous Mapping

Use this reference when the PM or product document describes behavior clearly, but does not map each action to an exact element or node.

## Goal

Resolve ambiguity explicitly instead of letting the agent guess which node, button, or control owns a behavior.

## Typical Triggers

- The document says "this screen has a Next button" but does not point to the exact element
- A Figma screen has multiple buttons or repeated controls with similar labels
- A root or page node contains several plausible frames for the same screen
- A control is icon-only or visually obvious, but unnamed in the document

## Required Output Before Code

Produce both tables when ambiguity exists:

```text
Screen -> candidate node
- Intro 1 -> node 12:8 -> confidence: high
- Intro 2 -> node 12:12 -> confidence: medium

Action -> candidate element
- Intro 1 / Next -> footer button "Next" -> confidence: high
- Intro 1 / Skip -> top-right text button -> confidence: medium
```

## Confidence Rules

- `high`: there is one obvious mapping based on label, placement, or structure
- `medium`: a preferred mapping exists but alternatives are plausible
- `low`: multiple plausible mappings exist and choosing one would materially change code

## Stop Rule

Do not generate code when:
- a required screen is mapped with `low` confidence
- a primary action is mapped with `low` confidence
- the ambiguity changes navigation, state ownership, or business behavior

In those cases, present the candidates and recommend one, but ask before proceeding.

## Default Recommendation

When one element is visually primary and another is secondary, recommend:
- primary CTA -> strongest visual emphasis, usually bottom or footer CTA
- secondary CTA -> top-right text action, tertiary button, or less prominent alternative

Still mark `medium` if the document does not explicitly confirm that role.
