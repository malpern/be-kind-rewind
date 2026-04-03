# Agent Engineering Guide

This document defines how humans and coding agents should write and update code in this repo.

The project goal is not enterprise ceremony. The goal is software that is:

- fast to build
- flexible to change
- stable in real use
- easy to understand after a few weeks away

## Default Mindset

- Solve the real problem with the smallest clean change.
- Prefer direct code over clever abstractions.
- Preserve momentum, but do not ship fragile behavior casually.
- Optimize for maintainability by one future person, not a large platform team.
- If a change adds complexity, it should buy real clarity, stability, or speed.
- Use modern Swift 6.2 and modern SwiftUI/Observation patterns by default.
- Prefer platform-native APIs over adding third-party dependencies.

## What to Test

Add tests when the change touches:

- persistence or schema behavior
- parsing or serialization
- filtering, sorting, grouping, or navigation rules
- command behavior and validation
- bug fixes with a clear reproduction
- non-trivial branching logic

Tests are optional when the change is:

- purely visual polish
- copy-only text changes
- simple wiring with no meaningful logic
- code that is hard to unit test and low-risk to verify manually

When skipping tests for a logic change, say why in the final summary or commit message.

## Testing Rules

- Prefer unit tests for pure logic and storage behavior.
- Prefer extracting a helper over building a complicated integration harness.
- Test the public behavior, not private implementation details.
- Add regression tests for bugs that are likely to come back.
- Keep fixtures small and readable.
- Avoid giant helper layers that hide what the test is proving.
- In SwiftUI code, test extracted formatting, filtering, sorting, selection, and navigation logic rather than trying to unit test view rendering directly.

## Assertion Rules

- Assertions should prove the intended behavior, not just that "something happened."
- Prefer exact assertions over vague ones.
- Assert important state after the action:
  persisted rows, returned values, ordering, selected IDs, filtered counts.
- For failures, assert the actual error path.
- Do not rely on "does not crash" as the main proof unless crash avoidance is the real behavior under test.
- If order matters, assert order explicitly.

Good:

```swift
#expect(topics.map(\.name) == ["Big", "Small"])
#expect(plan[0].playlist == "C")
```

Weak:

```swift
#expect(topics.count == 2)
_ = client // proves very little
```

## Coverage Expectations

Do not chase a number mechanically. Use coverage to find blind spots.

Current priority order:

1. `TaggingKit`
2. `VideoTagger`
3. pure logic inside `VideoOrganizer`

When adding new files with non-trivial logic, try not to leave them at 0% coverage unless there is a clear reason.

## Swift and SwiftUI Defaults

- Target modern Swift concurrency and Observation patterns when touching relevant code.
- Prefer Swift-native and modern Foundation APIs over older Foundation-style helpers.
- Avoid force unwraps and `try!` unless failure is truly unrecoverable.
- Prefer `async`/`await` over callback-based async code.
- Do not introduce `DispatchQueue.main.async` or other GCD patterns when Swift concurrency is sufficient.
- Prefer small, explicit types in separate files over multi-type catch-all files.
- Keep secrets out of the repo; use config files, environment variables, or keychain-backed storage.

## SwiftUI Data Flow Rules

- Keep business logic out of `body`.
- Views should mostly express state; models and services should own business behavior.
- For `@Observable` reference types owned by a root view, prefer storing them in `@State`.
- Pass shared data explicitly or via `@Environment`; avoid broad hidden dependencies.
- Do not introduce a view model unless the existing code or problem clearly needs one.
- If a view model already exists, prefer making it non-optional and initialize it in `init`.
- Avoid `Binding(get:set:)` in `body` unless there is no simpler alternative.

## Documentation Rules

Update docs when the change affects:

- setup
- runtime requirements
- data flow
- operator workflow
- architecture or technical direction
- project conventions

Keep docs lean:

- README for product overview and basic usage
- `docs/` for developer and design details
- ADRs/specs only when a decision is likely to matter later

Do not write long docs for small local refactors.

## Code Design Rules

- Prefer straightforward data flow.
- Prefer a small number of obvious types over generic frameworks.
- Extract helpers only when they improve readability, reuse, or testability.
- Avoid premature protocol abstraction.
- Avoid introducing dependency injection everywhere by default.
- Keep side effects close to the boundary of the system.
- Keep formatting and transformation logic separate from IO when practical.
- If identical sort behavior is repeated in several places, centralize it in the type rather than duplicating closures.
- Prefer modern formatting APIs and `FormatStyle` over manual string formatting for user-facing values.

## UI Code Rules

- Do not over-abstract SwiftUI/AppKit view code.
- Extract pure logic from views when it is reused or worth testing.
- Prefer a clear view model or helper over embedding dense logic in `body`.
- Avoid building custom infrastructure if platform primitives are sufficient.
- Prefer `Button` over `onTapGesture()` for tappable UI unless tap location or tap count is required.
- Button actions and non-trivial work should be moved out of `body`.
- If a view grows large or has distinct sections, split it into smaller dedicated view types.
- Keep view initializers simple; move non-trivial work to `task()` or lower layers.
- Avoid expensive filtering/sorting transforms inline inside `body`, `List`, or `ForEach`.
- Prefer concrete view composition over `AnyView`.
- Avoid computed `some View` fragments when a dedicated subview type is clearer and easier to maintain.

## View Structure Rules

When editing SwiftUI views, prefer this order:

1. environment
2. stored `let` properties
3. `@State` and other stored properties
4. non-view computed properties
5. `init`
6. `body`
7. extracted view sections / subviews
8. helpers and async functions

Use this as a default structure, not a reason to churn files unnecessarily.

## Accessibility Rules

- Respect Dynamic Type and avoid hard-coded font sizes unless there is a strong reason.
- Icon-only actions should still have an accessible text label.
- Decorative images should be hidden from accessibility; meaningful images need labels.
- Respect Reduce Motion for large motion-heavy effects.
- If color carries meaning, provide another differentiator for accessibility.
- Prefer semantic controls that VoiceOver understands over gesture-only interaction.

## When to Add an ADR or Spec

Add or update a design doc when:

- choosing between materially different architectures
- replacing a core UI or data-flow approach
- introducing a lasting constraint or convention
- capturing research that should not be rediscovered

Do not write an ADR for every refactor.

## Handling Warnings and Debt

- Fix warnings in touched files when the fix is local and cheap.
- Do not expand the scope just to clean unrelated code.
- If a nearby issue is risky but out of scope, call it out briefly.

## Definition of Done

A change is usually done when:

- it solves the intended problem
- the code is still easy to read
- the important behavior is tested or consciously verified another way
- assertions are specific
- docs are updated if needed
- no unnecessary architecture was added

## Preferred Tradeoff

Choose the option that is:

1. correct
2. simple
3. easy to change later

If you cannot have all three, bias toward correctness and simplicity over theoretical extensibility.
