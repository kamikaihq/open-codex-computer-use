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
    public static let version = "1.0.0-dev"
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
    private let pidProvider: @Sendable () -> Int32
    private let cursorPositionProvider: @Sendable () -> CGPoint?

    public init(
        permissionChecker: any CuaDriverPermissionChecking = SystemCuaDriverPermissionChecker(),
        windowProvider: any CuaDriverWindowProviding = SystemCuaDriverWindowProvider(),
        windowCapturer: any CuaDriverWindowCapturing = SystemCuaDriverWindowCapturer(),
        pidProvider: @escaping @Sendable () -> Int32 = { getpid() },
        cursorPositionProvider: @escaping @Sendable () -> CGPoint? = { CGEvent(source: nil)?.location }
    ) {
        self.permissionChecker = permissionChecker
        self.windowProvider = windowProvider
        self.windowCapturer = windowCapturer
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
        guard let windowID = intArgument(args["window_id"] ?? args["id"]) else {
            return errorEnvelope(code: "invalid_request", message: "screenshot requires integer field 'window_id'")
        }

        let pid = intArgument(args["pid"])
        guard let window = windowProvider.window(windowID: windowID, pid: pid) else {
            return errorEnvelope(code: "window_not_found", message: "Window not found: \(windowID)")
        }

        let format: CuaDriverScreenshotFormat
        if let rawFormat = args["format"] as? String {
            guard let parsedFormat = CuaDriverScreenshotFormat(rawValue: rawFormat.lowercased()) else {
                return errorEnvelope(code: "invalid_request", message: "screenshot format must be 'jpeg' or 'png'")
            }
            format = parsedFormat
        } else {
            format = .jpeg
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
