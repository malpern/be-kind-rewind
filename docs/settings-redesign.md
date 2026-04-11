# Settings Redesign

## Goal

Turn Settings from a single operational dump into a native macOS preferences window:

- a small number of clear categories
- durable preferences separated from one-off maintenance actions
- important setup tasks promoted
- diagnostics available, but visually secondary

## Design Principles

1. Follow the standard macOS Settings model: top-level categories with short titles and SF Symbols.
2. Put frequent setup and preference tasks first; put telemetry and recovery tools last.
3. Prefer native `Form` sections, status rows, and short explanatory copy over custom card containers.
4. Keep the window visually quiet: system materials, semantic colors, and consistent row spacing.
5. Treat live view controls and durable preferences differently.
6. Do not duplicate controls that already exist in-context unless the settings version adds distinct value.
7. Avoid tiny supporting text. In this settings window, primary copy should live at `body`, with secondary explanation and telemetry no smaller than `callout`.

## Information Architecture

### General

Purpose: browsing defaults and app behavior.

- Keep inspector visible
- Claude theme classification toggle

This stays intentionally narrow: inline display controls such as thumbnail size and compressed layout remain in the sidebar popover, where they can be changed in context without duplicating them in Settings.

### Accounts

Purpose: credentials and connected services.

- Anthropic API key
- YouTube Data API key
- Google OAuth client JSON import
- YouTube account connection status

This pane prioritizes setup completion and clear status messaging.

### Watch

Purpose: discovery behavior and watch curation inputs.

- Search API fallback toggle
- Per-refresh API budget
- Watch history import and count
- Excluded creators management

This groups together everything that changes Watch recommendations.

### Advanced

Purpose: operational status, quota telemetry, and browser/sync recovery.

- YouTube quota snapshot
- Recent API and discovery telemetry
- Browser fallback readiness
- Sync queue summary
- Manual refresh / flush / browser sign-in actions
- Last sync error and artifact access

This pane is intentionally denser and more utilitarian than the others.

## Visual Pattern

- Use a `TabView` inside the `Settings` scene so macOS presents a standard preferences toolbar.
- Each pane uses a compact header above a native grouped form.
- Sections should feel structural, not decorative.
- Status rows handle connected-service state; action rows stay short and scannable.
- Avoid oversized promo cards and heavy container chrome.
- Use semantic status styling:
  - green for ready
  - orange for attention needed
  - secondary/tertiary for optional or informational states

## Functional Changes

1. Persist browsing defaults so Settings acts as a true preference surface.
2. Promote "Accounts" to a first-class destination instead of mixing credentials with quota and sync tools.
3. Move Watch-specific controls out of generic settings sections into a coherent Watch pane.
4. Isolate advanced telemetry and sync controls so they do not dominate the main preferences experience.

## Implementation Notes

- Replace the monolithic `AppSettingsView` with a small root view plus pane subviews.
- Keep shared row components for status, metrics, and action groups.
- Preserve current store actions and controller behavior; change presentation and grouping first.
