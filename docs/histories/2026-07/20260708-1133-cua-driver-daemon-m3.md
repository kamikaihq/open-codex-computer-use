## [2026-07-08 11:33] | Task: Finish cua-driver daemon M3

### Execution Context
- Agent ID: `Codex`
- Base Model: `GPT-5`
- Runtime: `Codex CLI`

### User Query
> Implement final daemon feature milestone M3 on `lumi/daemon-m0`: input verbs, Lumi agent cursor session/style, display-region screenshots, multi-display coordinate fixes, tests, live proof, local commit only.

### Changes Overview
Scope: `OpenComputerUseKit` daemon runtime, cursor renderer integration, daemon tests, and docs.

Key actions:
- Added daemon input verbs for text, key press, AX value setting, scrolling, dragging, and secondary AX actions.
- Added in-memory Lumi agent cursor session verbs with custom glyph and bloom color style support.
- Added an additive cursor artwork override seam consulted by the existing renderer only when a daemon style is active.
- Added shared CG top-left to AppKit bottom-left coordinate conversion and reused it for backing scale selection and cursor introspection.
- Added `screenshot.display_region` capture for overlay-inclusive pixel selftests.
- Added daemon tests for parser/color helpers, cursor session state, input verb validation, drag event sequencing, display-region response shaping, AX action matching, and coordinate conversion.

### Design Intent
M3 keeps the daemon contract independent from the MCP tool surface while reusing stable upstream primitives where possible. Text typing and key pressing call existing `InputSimulation` / `KeyPressParser`; daemon-only drag, cursor session, and display-region screenshot paths are isolated in new daemon files. The visible cursor remains off by default for daemon sessions and is controlled only by explicit session verbs so upstream MCP environment behavior is not changed.

### Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/Daemon/CuaDriverInput.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/Daemon/CuaDriverCursorSession.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/Daemon/CuaDriverCoordinateSpace.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/Daemon/CuaDriverWindows.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/Daemon/CuaDriverProtocol.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/SoftwareCursorArtworkOverride.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/SoftwareCursorGlyphRenderer.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/SoftwareCursorOverlay.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/CuaDriverDaemonTests.swift`
- `docs/ARCHITECTURE.md`
- `docs/exec-plans/completed/20260708-cua-driver-daemon-m3.md`
- `docs/histories/2026-07/20260708-1133-cua-driver-daemon-m3.md`
