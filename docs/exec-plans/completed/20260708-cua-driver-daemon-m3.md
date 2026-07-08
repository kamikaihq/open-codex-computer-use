# Cua Driver Daemon M3

Status: completed on 2026-07-08.

## Goal

Finish the `cua-driver` daemon feature milestone on `lumi/daemon-m0` by adding input verbs, an in-memory Lumi agent cursor session, custom cursor artwork plumbing, display-region screenshots, and the multi-display coordinate fix.

## Scope

- Add daemon verbs: `type_text`, `set_value`, `press_key`, `scroll`, `drag`, `perform_secondary_action`, `set_agent_cursor_enabled`, `set_agent_cursor_style`, `get_agent_cursor`.
- Reuse existing `InputSimulation` and `KeyPressParser` for text and key injection.
- Keep daemon cursor session state in memory only; default off on every daemon start.
- Gate daemon overlay use on session state without changing the MCP path's `OPEN_COMPUTER_USE_VISUAL_CURSOR` behavior.
- Add a minimal glyph override seam so default cursor rendering remains unchanged when no override is active.
- Add shared CG top-left to AppKit bottom-left coordinate conversion for screen scale lookup and cursor introspection.
- Add `screenshot.display_region` capture for the cursor pixel selftest.

## Implementation Notes

- Prefer new daemon files for M3 behavior; touch upstream overlay/glyph files only for small additive hooks.
- Use fakeable protocols for AX element operations and CGEvent input paths so CI can cover behavior without permissions.
- Use `CuaDriverCoordinateSpace` for every daemon screenshot-space coordinate path.
- For daemon overlay movement, convert CG global points to AppKit global points before calling `SoftwareCursorOverlay`.

## Verification

- `swift build --product cua-driver` passed locally.
- Daemon live transcript on a temp socket against a scratch TextEdit document.
- `swift test --filter CuaDriver` was attempted locally but failed before reaching package tests because this Command Line Tools install cannot import `XCTest` for `StandaloneCursorSupportTests`.
