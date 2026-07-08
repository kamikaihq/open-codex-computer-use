## [2026-07-08 11:14] | Task: Add cua-driver window state and click M2

### Execution Context
- Agent ID: `Codex`
- Base Model: `GPT-5`
- Runtime: `Codex CLI`

### User Query
> Continue on `lumi/daemon-m0` with M2: add `get_window_state` and `click`, commit locally, and do not push.

### Changes Overview
Scope: `OpenComputerUseKit` daemon runtime, daemon tests, and architecture docs.

Key actions:
- Added a shared daemon coordinate policy that reports screenshot-space dimensions and maps screenshot-space clicks back to window/global points.
- Added AX window resolution for a specific `(pid, window_id)`, using `_AXUIElementGetWindow` when available and frame/title fallback matching otherwise.
- Added daemon window-state rendering with `[element_index N]` markers and a thread-safe per-window element cache.
- Added daemon `click` support for cached AX press and coordinate `CGEvent.postToPid` mouseDown/mouseUp.
- Added tests for coordinate round trips, cache replacement/isolation, click validation, response shape, and a permission-guarded real AX smoke path.

### Design Intent
The daemon contract needs stable window-scoped state without stealing focus or moving the user's pointer. The coordinate-space helper is a single pure function so `get_window_state` and `click` cannot drift. The daemon renderer reuses existing upstream helpers where they are already module-visible (`meaningfulActions`, `sanitizeText`, child traversal policy, elision limits, and wrapper elision), but mirrors the minimal private AX attribute/title/role helpers because `AccessibilitySnapshot.swift` intentionally keeps its renderer internals file-private and the task required leaving upstream snapshot files untouched.

### Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/Daemon/CuaDriverCoordinateSpace.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/Daemon/AXWindowBridge.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/Daemon/CuaDriverProtocol.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/CuaDriverDaemonTests.swift`
- `docs/ARCHITECTURE.md`
- `docs/histories/2026-07/20260708-1114-cua-driver-window-state-click-m2.md`
