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
    private let pidProvider: @Sendable () -> Int32
    private let cursorPositionProvider: @Sendable () -> CGPoint?

    public init(
        permissionChecker: any CuaDriverPermissionChecking = SystemCuaDriverPermissionChecker(),
        pidProvider: @escaping @Sendable () -> Int32 = { getpid() },
        cursorPositionProvider: @escaping @Sendable () -> CGPoint? = { CGEvent(source: nil)?.location }
    ) {
        self.permissionChecker = permissionChecker
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
