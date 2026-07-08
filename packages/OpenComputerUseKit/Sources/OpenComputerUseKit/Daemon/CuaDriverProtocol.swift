import ApplicationServices
import Foundation

public enum CuaDriverProtocolError: Error, LocalizedError {
    case invalidJSONObject
    case invalidUTF8

    public var errorDescription: String? {
        switch self {
        case .invalidJSONObject:
            return "Expected a JSON object"
        case .invalidUTF8:
            return "Expected UTF-8 JSON"
        }
    }
}

public enum CuaDriverConstants {
    // Must match the release tag: the bridge resolver pins on status.version.
    public static let version = "1.0.0"
}

public struct CuaDriverPermissionStatus: Equatable, Sendable {
    public let accessibility: Bool
    public let screenRecording: Bool

    public init(accessibility: Bool, screenRecording: Bool) {
        self.accessibility = accessibility
        self.screenRecording = screenRecording
    }
}

public protocol CuaDriverPermissionChecking: Sendable {
    func checkPermissions(prompt: Bool) -> CuaDriverPermissionStatus
}

public struct SystemCuaDriverPermissionChecker: CuaDriverPermissionChecking {
    public init() {}

    public func checkPermissions(prompt: Bool) -> CuaDriverPermissionStatus {
        let accessibility: Bool
        if prompt {
            let options: NSDictionary = ["AXTrustedCheckOptionPrompt": true]
            accessibility = AXIsProcessTrustedWithOptions(options)
        } else {
            accessibility = AXIsProcessTrusted()
        }

        let screenRecording: Bool
        if prompt {
            screenRecording = CGRequestScreenCaptureAccess()
        } else {
            screenRecording = CGPreflightScreenCaptureAccess()
        }

        return CuaDriverPermissionStatus(
            accessibility: accessibility,
            screenRecording: screenRecording
        )
    }
}

public struct CuaDriverVerbHandler: Sendable {
    private let permissionChecker: any CuaDriverPermissionChecking
    private let windowProvider: any CuaDriverWindowProviding
    private let windowCapturer: any CuaDriverWindowCapturing
    private let backingScaleProvider: any CuaDriverBackingScaleProviding
    private let axWindowResolver: any CuaDriverAXWindowResolving
    private let windowStateRenderer: any CuaDriverWindowStateRendering
    private let elementCache: CuaDriverElementCache
    private let elementClicker: any CuaDriverElementClicking
    private let coordinateClicker: any CuaDriverCoordinateClicking
    private let inputEventPoster: any CuaDriverInputEventPosting
    private let elementInteractor: any CuaDriverElementInteracting
    private let cursorSession: CuaDriverCursorSession
    private let pidProvider: @Sendable () -> Int32
    private let cursorPositionProvider: @Sendable () -> CGPoint?

    public init(
        permissionChecker: any CuaDriverPermissionChecking = SystemCuaDriverPermissionChecker(),
        windowProvider: any CuaDriverWindowProviding = SystemCuaDriverWindowProvider(),
        windowCapturer: any CuaDriverWindowCapturing = SystemCuaDriverWindowCapturer(),
        backingScaleProvider: any CuaDriverBackingScaleProviding = SystemCuaDriverBackingScaleProvider(),
        axWindowResolver: any CuaDriverAXWindowResolving = SystemCuaDriverAXWindowResolver(),
        windowStateRenderer: any CuaDriverWindowStateRendering = SystemCuaDriverWindowStateRenderer(),
        elementCache: CuaDriverElementCache = CuaDriverElementCache(),
        elementClicker: any CuaDriverElementClicking = SystemCuaDriverElementClicker(),
        coordinateClicker: any CuaDriverCoordinateClicking = SystemCuaDriverCoordinateClicker(),
        inputEventPoster: any CuaDriverInputEventPosting = SystemCuaDriverInputEventPoster(),
        elementInteractor: any CuaDriverElementInteracting = SystemCuaDriverElementInteractor(),
        cursorSession: CuaDriverCursorSession = CuaDriverCursorSession(),
        pidProvider: @escaping @Sendable () -> Int32 = { getpid() },
        cursorPositionProvider: @escaping @Sendable () -> CGPoint? = { CGEvent(source: nil)?.location }
    ) {
        self.permissionChecker = permissionChecker
        self.windowProvider = windowProvider
        self.windowCapturer = windowCapturer
        self.backingScaleProvider = backingScaleProvider
        self.axWindowResolver = axWindowResolver
        self.windowStateRenderer = windowStateRenderer
        self.elementCache = elementCache
        self.elementClicker = elementClicker
        self.coordinateClicker = coordinateClicker
        self.inputEventPoster = inputEventPoster
        self.elementInteractor = elementInteractor
        self.cursorSession = cursorSession
        self.pidProvider = pidProvider
        self.cursorPositionProvider = cursorPositionProvider
    }

    public func responseEnvelope(for requestData: Data) -> [String: Any] {
        do {
            let request = try CuaDriverJSON.object(from: requestData)
            guard let verb = request["verb"] as? String else {
                return errorEnvelope(code: "invalid_request", message: "Request is missing string field 'verb'")
            }

            let args: [String: Any]
            if let requestArgs = request["args"] {
                guard let objectArgs = requestArgs as? [String: Any] else {
                    return errorEnvelope(code: "invalid_request", message: "Request field 'args' must be an object")
                }
                args = objectArgs
            } else {
                args = [:]
            }
            return responseEnvelope(verb: verb, args: args)
        } catch {
            return errorEnvelope(code: "invalid_json", message: error.localizedDescription)
        }
    }

    public func responseEnvelope(verb: String, args: [String: Any]) -> [String: Any] {
        switch verb {
        case "status":
            return [
                "status": "running",
                "version": CuaDriverConstants.version,
                "pid": Int(pidProvider()),
            ]
        case "check_permissions":
            let prompt = args["prompt"] as? Bool ?? false
            let status = permissionChecker.checkPermissions(prompt: prompt)
            return [
                "accessibility": status.accessibility,
                "screen_recording": status.screenRecording,
            ]
        case "get_cursor_position":
            guard let location = cursorPositionProvider() else {
                return errorEnvelope(code: "cursor_unavailable", message: "Unable to read cursor position")
            }
            return [
                "x": Double(location.x),
                "y": Double(location.y),
            ]
        case "list_windows":
            let pid = intArgument(args["pid"])
            return [
                "windows": windowProvider.listWindows(pid: pid).map(\.jsonObject),
            ]
        case "screenshot":
            return screenshotResponse(args: args)
        case "get_window_state":
            return windowStateResponse(args: args)
        case "click":
            return clickResponse(args: args)
        case "type_text":
            return typeTextResponse(args: args)
        case "set_value":
            return setValueResponse(args: args)
        case "press_key":
            return pressKeyResponse(args: args)
        case "scroll":
            return scrollResponse(args: args)
        case "drag":
            return dragResponse(args: args)
        case "perform_secondary_action":
            return performSecondaryActionResponse(args: args)
        case "set_agent_cursor_enabled":
            return setAgentCursorEnabledResponse(args: args)
        case "set_agent_cursor_style":
            return setAgentCursorStyleResponse(args: args)
        case "get_agent_cursor":
            return getAgentCursorResponse()
        default:
            return errorEnvelope(code: "unknown_verb", message: "Unknown verb: \(verb)")
        }
    }

    public static func errorEnvelope(code: String, message: String) -> [String: Any] {
        [
            "error": [
                "code": code,
                "message": message,
            ],
        ]
    }

    private func errorEnvelope(code: String, message: String) -> [String: Any] {
        Self.errorEnvelope(code: code, message: message)
    }

    private func screenshotResponse(args: [String: Any]) -> [String: Any] {
        let format: CuaDriverScreenshotFormat
        if let rawFormat = args["format"] as? String {
            guard let parsedFormat = CuaDriverScreenshotFormat(rawValue: rawFormat.lowercased()) else {
                return errorEnvelope(code: "invalid_request", message: "screenshot format must be 'jpeg' or 'png'")
            }
            format = parsedFormat
        } else {
            format = .jpeg
        }

        if let regionValue = args["display_region"] {
            guard args["window_id"] == nil, args["id"] == nil else {
                return errorEnvelope(code: "invalid_request", message: "screenshot accepts either 'window_id' or 'display_region', not both")
            }
            guard let region = displayRegionArgument(regionValue) else {
                return errorEnvelope(code: "invalid_request", message: "display_region requires numeric x, y, width, and height")
            }
            guard region.bounds.width > 0, region.bounds.height > 0 else {
                return errorEnvelope(code: "invalid_request", message: "display_region width and height must be > 0")
            }

            do {
                return try windowCapturer.capture(displayRegion: region, format: format).jsonObject
            } catch {
                return errorEnvelope(
                    code: "capture_failed",
                    message: (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                )
            }
        }

        guard let windowID = intArgument(args["window_id"] ?? args["id"]) else {
            return errorEnvelope(code: "invalid_request", message: "screenshot requires integer field 'window_id' or object field 'display_region'")
        }

        let pid = intArgument(args["pid"])
        guard let window = windowProvider.window(windowID: windowID, pid: pid) else {
            return errorEnvelope(code: "window_not_found", message: "Window not found: \(windowID)")
        }

        do {
            return try windowCapturer.capture(window: window, format: format).jsonObject
        } catch {
            return errorEnvelope(
                code: "capture_failed",
                message: (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            )
        }
    }

    private func windowStateResponse(args: [String: Any]) -> [String: Any] {
        guard let pid = intArgument(args["pid"]) else {
            return errorEnvelope(code: "invalid_request", message: "get_window_state requires integer field 'pid'")
        }
        guard let windowID = intArgument(args["window_id"]) else {
            return errorEnvelope(code: "invalid_request", message: "get_window_state requires integer field 'window_id'")
        }
        guard let window = windowProvider.window(windowID: windowID, pid: pid) else {
            return errorEnvelope(code: "window_not_found", message: "Window not found: \(windowID)")
        }

        do {
            let resolvedWindow = try axWindowResolver.resolveWindow(pid: pid, windowID: windowID, windowInfo: window)
            let snapshot = try windowStateRenderer.render(window: resolvedWindow, windowInfo: window)
            elementCache.replace(pid: pid, windowID: windowID, elements: snapshot.elements)

            let coordinateSpace = cuaDriverCoordinateSpace(
                windowBounds: window.bounds,
                backingScale: backingScaleProvider.backingScale(for: window.bounds)
            )

            return [
                "tree": snapshot.tree,
                "screenshot_width": coordinateSpace.screenshotWidth,
                "screenshot_height": coordinateSpace.screenshotHeight,
                "window_id": window.windowID,
                "pid": window.pid,
                "title": resolvedWindow.title ?? window.title,
                "app_name": resolvedWindow.appName ?? window.appName,
            ]
        } catch let error as CuaDriverAXWindowBridgeError {
            return errorEnvelope(code: windowStateErrorCode(error), message: error.localizedDescription)
        } catch {
            return errorEnvelope(
                code: "window_state_failed",
                message: (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            )
        }
    }

    private func clickResponse(args: [String: Any]) -> [String: Any] {
        guard let pid = intArgument(args["pid"]) else {
            return errorEnvelope(code: "invalid_request", message: "click requires integer field 'pid'")
        }
        guard let windowID = intArgument(args["window_id"]) else {
            return errorEnvelope(code: "invalid_request", message: "click requires integer field 'window_id'")
        }

        if let elementIndex = intArgument(args["element_index"]) {
            guard let element = elementCache.element(pid: pid, windowID: windowID, index: elementIndex) else {
                return errorEnvelope(
                    code: "stale_element_index",
                    message: "element_index \(elementIndex) not found; call get_window_state again"
                )
            }

            do {
                let targetPoint = elementInteractor.frameCenter(of: element)
                moveAgentCursorIfEnabled(to: targetPoint, windowID: windowID)
                try elementClicker.press(element)
                pulseAgentCursorIfEnabled(at: targetPoint, windowID: windowID, clickCount: 1, button: .left)
                return [
                    "clicked": true,
                    "method": "ax_press",
                ]
            } catch {
                return errorEnvelope(
                    code: "click_failed",
                    message: (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                )
            }
        }

        guard let x = doubleArgument(args["x"]), let y = doubleArgument(args["y"]) else {
            return errorEnvelope(code: "invalid_request", message: "click requires either 'element_index' or numeric fields 'x' and 'y'")
        }
        guard x.isFinite, y.isFinite else {
            return errorEnvelope(code: "invalid_request", message: "click coordinates must be finite numbers")
        }

        let clickCount = intArgument(args["click_count"]) ?? 1
        guard clickCount > 0 else {
            return errorEnvelope(code: "invalid_request", message: "click_count must be > 0")
        }

        let buttonName = (args["button"] as? String ?? "left").lowercased()
        guard let button = CuaDriverMouseButton(rawValue: buttonName) else {
            return errorEnvelope(code: "invalid_request", message: "button must be 'left' or 'right'")
        }
        guard let window = windowProvider.window(windowID: windowID, pid: pid) else {
            return errorEnvelope(code: "window_not_found", message: "Window not found: \(windowID)")
        }

        let coordinateSpace = cuaDriverCoordinateSpace(
            windowBounds: window.bounds,
            backingScale: backingScaleProvider.backingScale(for: window.bounds)
        )
        let globalPoint = coordinateSpace.screenshotPixelToGlobalPoint(CGPoint(x: x, y: y))

        do {
            moveAgentCursorIfEnabled(to: globalPoint, windowID: windowID)
            try coordinateClicker.click(pid: pid, point: globalPoint, button: button, clickCount: clickCount)
            pulseAgentCursorIfEnabled(at: globalPoint, windowID: windowID, clickCount: clickCount, button: button)
            return [
                "clicked": true,
                "method": "coordinate",
            ]
        } catch {
            return errorEnvelope(
                code: "click_failed",
                message: (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            )
        }
    }

    private func windowStateErrorCode(_ error: CuaDriverAXWindowBridgeError) -> String {
        switch error {
        case .axWindowNotFound:
            return "ax_window_not_found"
        default:
            return "window_state_failed"
        }
    }

    private func typeTextResponse(args: [String: Any]) -> [String: Any] {
        guard let pid = intArgument(args["pid"]) else {
            return errorEnvelope(code: "invalid_request", message: "type_text requires integer field 'pid'")
        }
        guard let text = args["text"] as? String else {
            return errorEnvelope(code: "invalid_request", message: "type_text requires string field 'text'")
        }

        do {
            try inputEventPoster.typeText(text, pid: pid)
            return ["typed": true]
        } catch {
            return inputErrorEnvelope(defaultCode: "type_text_failed", error: error)
        }
    }

    private func setValueResponse(args: [String: Any]) -> [String: Any] {
        guard let pid = intArgument(args["pid"]) else {
            return errorEnvelope(code: "invalid_request", message: "set_value requires integer field 'pid'")
        }
        guard let windowID = intArgument(args["window_id"]) else {
            return errorEnvelope(code: "invalid_request", message: "set_value requires integer field 'window_id'")
        }
        guard let elementIndex = intArgument(args["element_index"]) else {
            return errorEnvelope(code: "invalid_request", message: "set_value requires integer field 'element_index'")
        }
        guard let value = args["value"], value is String || value is NSNumber else {
            return errorEnvelope(code: "invalid_request", message: "set_value requires string or number field 'value'")
        }
        guard let element = elementCache.element(pid: pid, windowID: windowID, index: elementIndex) else {
            return staleElementEnvelope(elementIndex)
        }

        do {
            try elementInteractor.setValue(value, on: element)
            return ["set": true]
        } catch {
            return inputErrorEnvelope(defaultCode: "set_value_failed", error: error)
        }
    }

    private func pressKeyResponse(args: [String: Any]) -> [String: Any] {
        guard let pid = intArgument(args["pid"]) else {
            return errorEnvelope(code: "invalid_request", message: "press_key requires integer field 'pid'")
        }
        guard let key = args["key"] as? String else {
            return errorEnvelope(code: "invalid_request", message: "press_key requires string field 'key'")
        }

        do {
            try inputEventPoster.pressKey(key, pid: pid)
            return ["pressed": true]
        } catch {
            return inputErrorEnvelope(defaultCode: "press_key_failed", error: error)
        }
    }

    private func scrollResponse(args: [String: Any]) -> [String: Any] {
        guard let pid = intArgument(args["pid"]) else {
            return errorEnvelope(code: "invalid_request", message: "scroll requires integer field 'pid'")
        }
        guard let windowID = intArgument(args["window_id"]) else {
            return errorEnvelope(code: "invalid_request", message: "scroll requires integer field 'window_id'")
        }
        guard let direction = (args["direction"] as? String)?.lowercased(),
              ["up", "down", "left", "right"].contains(direction)
        else {
            return errorEnvelope(code: "invalid_request", message: "direction must be one of up, down, left, or right")
        }
        let pages = intArgument(args["pages"]) ?? 1
        guard pages > 0 else {
            return errorEnvelope(code: "invalid_request", message: "pages must be > 0")
        }
        guard let window = windowProvider.window(windowID: windowID, pid: pid) else {
            return errorEnvelope(code: "window_not_found", message: "Window not found: \(windowID)")
        }

        if let elementIndex = intArgument(args["element_index"]) {
            guard let element = elementCache.element(pid: pid, windowID: windowID, index: elementIndex) else {
                return staleElementEnvelope(elementIndex)
            }

            do {
                if let action = cuaDriverScrollAction(direction: direction),
                   try elementInteractor.availableActions(on: element).contains(where: { $0.caseInsensitiveCompare(action) == .orderedSame })
                {
                    for _ in 0..<pages {
                        try elementInteractor.performAction(action, on: element)
                    }
                    return ["scrolled": true]
                }
            } catch {
                return inputErrorEnvelope(defaultCode: "scroll_failed", error: error)
            }

            let targetPoint = elementInteractor.frameCenter(of: element) ?? windowCenter(window)
            return scrollAtPoint(pid: pid, windowID: windowID, point: targetPoint, direction: direction, pages: pages)
        }

        return scrollAtPoint(pid: pid, windowID: windowID, point: windowCenter(window), direction: direction, pages: pages)
    }

    private func dragResponse(args: [String: Any]) -> [String: Any] {
        guard let pid = intArgument(args["pid"]) else {
            return errorEnvelope(code: "invalid_request", message: "drag requires integer field 'pid'")
        }
        guard let windowID = intArgument(args["window_id"]) else {
            return errorEnvelope(code: "invalid_request", message: "drag requires integer field 'window_id'")
        }
        guard let fromX = doubleArgument(args["from_x"]),
              let fromY = doubleArgument(args["from_y"]),
              let toX = doubleArgument(args["to_x"]),
              let toY = doubleArgument(args["to_y"])
        else {
            return errorEnvelope(code: "invalid_request", message: "drag requires numeric from_x, from_y, to_x, and to_y")
        }
        guard [fromX, fromY, toX, toY].allSatisfy(\.isFinite) else {
            return errorEnvelope(code: "invalid_request", message: "drag coordinates must be finite numbers")
        }
        guard let window = windowProvider.window(windowID: windowID, pid: pid) else {
            return errorEnvelope(code: "window_not_found", message: "Window not found: \(windowID)")
        }

        let coordinateSpace = cuaDriverCoordinateSpace(
            windowBounds: window.bounds,
            backingScale: backingScaleProvider.backingScale(for: window.bounds)
        )
        let start = coordinateSpace.screenshotPixelToGlobalPoint(CGPoint(x: fromX, y: fromY))
        let end = coordinateSpace.screenshotPixelToGlobalPoint(CGPoint(x: toX, y: toY))

        do {
            moveAgentCursorIfEnabled(to: start, windowID: windowID)
            try inputEventPoster.drag(pid: pid, from: start, to: end)
            settleAgentCursorIfEnabled(at: end, windowID: windowID)
            return ["dragged": true]
        } catch {
            return inputErrorEnvelope(defaultCode: "drag_failed", error: error)
        }
    }

    private func performSecondaryActionResponse(args: [String: Any]) -> [String: Any] {
        guard let pid = intArgument(args["pid"]) else {
            return errorEnvelope(code: "invalid_request", message: "perform_secondary_action requires integer field 'pid'")
        }
        guard let windowID = intArgument(args["window_id"]) else {
            return errorEnvelope(code: "invalid_request", message: "perform_secondary_action requires integer field 'window_id'")
        }
        guard let elementIndex = intArgument(args["element_index"]) else {
            return errorEnvelope(code: "invalid_request", message: "perform_secondary_action requires integer field 'element_index'")
        }
        guard let action = args["action"] as? String else {
            return errorEnvelope(code: "invalid_request", message: "perform_secondary_action requires string field 'action'")
        }
        guard let element = elementCache.element(pid: pid, windowID: windowID, index: elementIndex) else {
            return staleElementEnvelope(elementIndex)
        }

        do {
            let availableActions = try elementInteractor.availableActions(on: element)
            guard let matchedAction = cuaDriverMatchingAXAction(requested: action, availableActions: availableActions) else {
                return errorEnvelope(
                    code: "unknown_action",
                    message: "Unknown action '\(action)'. Available actions: \(availableActionDescription(availableActions))"
                )
            }

            try elementInteractor.performAction(matchedAction, on: element)
            return ["performed": true]
        } catch {
            return inputErrorEnvelope(defaultCode: "perform_secondary_action_failed", error: error)
        }
    }

    private func setAgentCursorEnabledResponse(args: [String: Any]) -> [String: Any] {
        guard let enabled = boolArgument(args["enabled"]) else {
            return errorEnvelope(code: "invalid_request", message: "set_agent_cursor_enabled requires boolean field 'enabled'")
        }

        do {
            let applied = try cuaDriverRunOnMain {
                cursorSession.setEnabled(enabled)
            }
            return ["agent_cursor_enabled": applied]
        } catch {
            return inputErrorEnvelope(defaultCode: "agent_cursor_failed", error: error)
        }
    }

    private func setAgentCursorStyleResponse(args: [String: Any]) -> [String: Any] {
        let imagePath = args["image_path"] as? String
        let bloomColor = args["bloom_color"] as? String
        if args.keys.contains("image_path"), imagePath == nil {
            return errorEnvelope(code: "invalid_request", message: "image_path must be a string")
        }
        if args.keys.contains("bloom_color"), bloomColor == nil {
            return errorEnvelope(code: "invalid_request", message: "bloom_color must be a string")
        }

        do {
            try cuaDriverRunOnMain {
                try cursorSession.applyStyle(imagePath: imagePath, bloomColor: bloomColor)
            }
            return ["agent_cursor_style": "applied"]
        } catch let error as CuaDriverCursorSessionError {
            return errorEnvelope(code: error.code, message: error.localizedDescription)
        } catch {
            return inputErrorEnvelope(defaultCode: "agent_cursor_failed", error: error)
        }
    }

    private func getAgentCursorResponse() -> [String: Any] {
        do {
            let snapshot = try cuaDriverRunOnMain {
                cursorSession.snapshot()
            }
            return [
                "enabled": snapshot.enabled,
                "has_custom_glyph": snapshot.hasCustomGlyph,
                "bloom_color": snapshot.bloomColor ?? NSNull(),
                "tip_position": snapshot.tipPosition.map { ["x": $0.x, "y": $0.y] } ?? NSNull(),
            ]
        } catch {
            return inputErrorEnvelope(defaultCode: "agent_cursor_failed", error: error)
        }
    }

    private func scrollAtPoint(pid: Int, windowID: Int, point: CGPoint, direction: String, pages: Int) -> [String: Any] {
        do {
            moveAgentCursorIfEnabled(to: point, windowID: windowID)
            try inputEventPoster.scroll(pid: pid, point: point, direction: direction, pages: pages)
            settleAgentCursorIfEnabled(at: point, windowID: windowID)
            return ["scrolled": true]
        } catch {
            return inputErrorEnvelope(defaultCode: "scroll_failed", error: error)
        }
    }

    private func staleElementEnvelope(_ elementIndex: Int) -> [String: Any] {
        errorEnvelope(
            code: "stale_element_index",
            message: "element_index \(elementIndex) not found; call get_window_state again"
        )
    }

    private func windowCenter(_ window: CuaDriverWindowInfo) -> CGPoint {
        CGPoint(
            x: window.bounds.x + (window.bounds.width / 2),
            y: window.bounds.y + (window.bounds.height / 2)
        )
    }

    private func inputErrorEnvelope(defaultCode: String, error: Error) -> [String: Any] {
        let code: String
        if case ComputerUseError.invalidArguments(_) = error {
            code = "invalid_request"
        } else {
            code = defaultCode
        }
        return errorEnvelope(
            code: code,
            message: (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        )
    }

    private func availableActionDescription(_ actions: [String]) -> String {
        guard !actions.isEmpty else {
            return "(none)"
        }

        return actions
            .map { "\($0) (\(cuaDriverPrettyAXActionName($0)))" }
            .joined(separator: ", ")
    }

    private func moveAgentCursorIfEnabled(to cgPoint: CGPoint?, windowID: Int) {
        guard let cgPoint, agentCursorEnabled() else {
            return
        }
        let appKitPoint = cuaDriverAppKitGlobalPoint(
            fromCGGlobalPoint: cgPoint,
            primaryScreenHeight: cuaDriverPrimaryScreenHeight()
        )
        let targetWindow = CursorTargetWindow(windowID: CGWindowID(windowID), layer: 0)
        cuaDriverDispatchMainAndWait(timeout: 0.6) {
            SoftwareCursorOverlay.moveCursor(to: appKitPoint, in: targetWindow)
        }
    }

    private func pulseAgentCursorIfEnabled(at cgPoint: CGPoint?, windowID: Int, clickCount: Int, button: CuaDriverMouseButton) {
        guard let cgPoint, agentCursorEnabled() else {
            return
        }
        let appKitPoint = cuaDriverAppKitGlobalPoint(
            fromCGGlobalPoint: cgPoint,
            primaryScreenHeight: cuaDriverPrimaryScreenHeight()
        )
        let targetWindow = CursorTargetWindow(windowID: CGWindowID(windowID), layer: 0)
        let mouseButton: MouseButtonKind = button == .right ? .right : .left
        cuaDriverDispatchMain {
            SoftwareCursorOverlay.pulseClick(at: appKitPoint, clickCount: clickCount, mouseButton: mouseButton, in: targetWindow)
        }
    }

    private func settleAgentCursorIfEnabled(at cgPoint: CGPoint?, windowID: Int) {
        guard let cgPoint, agentCursorEnabled() else {
            return
        }
        let appKitPoint = cuaDriverAppKitGlobalPoint(
            fromCGGlobalPoint: cgPoint,
            primaryScreenHeight: cuaDriverPrimaryScreenHeight()
        )
        let targetWindow = CursorTargetWindow(windowID: CGWindowID(windowID), layer: 0)
        cuaDriverDispatchMain {
            SoftwareCursorOverlay.settle(at: appKitPoint, in: targetWindow)
        }
    }

    private func agentCursorEnabled() -> Bool {
        (try? cuaDriverRunOnMain { cursorSession.isEnabled() }) ?? false
    }
}

private func intArgument(_ value: Any?) -> Int? {
    switch value {
    case let int as Int:
        return int
    case let number as NSNumber:
        return number.intValue
    default:
        return nil
    }
}

private func doubleArgument(_ value: Any?) -> Double? {
    switch value {
    case let double as Double:
        return double
    case let int as Int:
        return Double(int)
    case let number as NSNumber:
        return number.doubleValue
    default:
        return nil
    }
}

private func boolArgument(_ value: Any?) -> Bool? {
    switch value {
    case let bool as Bool:
        return bool
    case let number as NSNumber:
        return number.boolValue
    default:
        return nil
    }
}

private func displayRegionArgument(_ value: Any?) -> CuaDriverDisplayRegion? {
    guard let object = value as? [String: Any],
          let x = doubleArgument(object["x"]),
          let y = doubleArgument(object["y"]),
          let width = doubleArgument(object["width"]),
          let height = doubleArgument(object["height"])
    else {
        return nil
    }

    return CuaDriverDisplayRegion(x: x, y: y, width: width, height: height)
}

public enum CuaDriverJSON {
    public static func data(from object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    public static func object(from data: Data) throws -> [String: Any] {
        let decoded = try JSONSerialization.jsonObject(with: data, options: [])
        guard let object = decoded as? [String: Any] else {
            throw CuaDriverProtocolError.invalidJSONObject
        }
        return object
    }

    public static func text(from object: Any) throws -> String {
        let data = try data(from: object)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CuaDriverProtocolError.invalidUTF8
        }
        return text
    }
}
