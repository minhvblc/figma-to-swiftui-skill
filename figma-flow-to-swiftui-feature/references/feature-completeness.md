# Feature Completeness Checklist

Use this checklist when the user asks for a feature or flow, not just a screen.

## Per-Screen Checklist

For each screen, check:
- initial state
- data-filled state
- empty state if the screen can have no content
- loading state for every async action
- error state for every async action
- retry path where failure is recoverable
- disabled CTA state when inputs are invalid or work is in flight
- success handoff if the screen triggers navigation

## Form Screens

For forms, verify:
- field binding
- validation timing: live, on submit, or both
- inline error rendering
- keyboard and focus behavior if the project has a pattern for it
- submit button state before, during, and after submission

## Selection or List Screens

For chooser, list, or picker screens, verify:
- empty content fallback
- selected state persistence
- disabled or unavailable options
- loading while content is fetched
- refresh or retry if the project supports it

## Confirmation and Success Screens

For success or confirmation screens, verify:
- destination after primary CTA
- dismissal/back behavior
- whether the flow can be re-entered safely
- whether state should reset after success

## Flow-Level Checklist

Across the whole feature, verify:
- entry point is wired
- every transition has a real destination
- back navigation is coherent
- error recovery returns the user to a useful state
- shared components stay visually and behaviorally consistent
- copy and button labels match the action outcome

## Default Rule

If there is an async call, the screen is not complete until loading, success, and failure are all represented in code.
