import AppKit
import CoreGraphics
import Foundation

public enum CuaDriverCursorSessionError: Error, LocalizedError {
    case missingStyleField
    case invalidCursorImage(String)
    case invalidCursorColor(String)

    public var code: String {
        switch self {
        case .missingStyleField:
            return "invalid_request"
        case .invalidCursorImage:
            return "invalid_cursor_image"
        case .invalidCursorColor:
            return "invalid_cursor_color"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .missingStyleField:
            return "set_agent_cursor_style requires 'image_path' or 'bloom_color'"
        case let .invalidCursorImage(path):
            return "Cursor image is missing or invalid: \(path)"
        case let .invalidCursorColor(value):
            return "Cursor bloom_color must be a hex RGB color: \(value)"
        }
    }
}

public struct CuaDriverCursorTipPosition: Equatable, Sendable {
    public let x: Double
    public let y: Double
}

public struct CuaDriverCursorSessionSnapshot: Equatable, Sendable {
    public let enabled: Bool
    public let hasCustomGlyph: Bool
    public let bloomColor: String?
    public let tipPosition: CuaDriverCursorTipPosition?
}

@MainActor
public final class CuaDriverCursorSession: @unchecked Sendable {
    private var enabled = false
    private var glyphImage: NSImage?
    private var bloomColor: NSColor?
    private var bloomColorHex: String?

    public nonisolated init() {}

    public func setEnabled(_ enabled: Bool) -> Bool {
        self.enabled = enabled
        if !enabled {
            resetOpenComputerUseVisualCursor()
        }
        return self.enabled
    }

    public func applyStyle(imagePath: String?, bloomColor rawBloomColor: String?) throws {
        guard imagePath != nil || rawBloomColor != nil else {
            throw CuaDriverCursorSessionError.missingStyleField
        }

        if let imagePath {
            guard let image = NSImage(contentsOfFile: imagePath), image.isValid else {
                throw CuaDriverCursorSessionError.invalidCursorImage(imagePath)
            }
            glyphImage = image
        }

        if let rawBloomColor {
            guard let parsed = cuaDriverParseHexColor(rawBloomColor) else {
                throw CuaDriverCursorSessionError.invalidCursorColor(rawBloomColor)
            }
            bloomColor = parsed.color
            bloomColorHex = parsed.hex
        }

        SoftwareCursorArtworkOverrideStore.apply(glyphImage: glyphImage, bloomColor: bloomColor)
    }

    public func snapshot(primaryScreenHeight: CGFloat = cuaDriverPrimaryScreenHeight()) -> CuaDriverCursorSessionSnapshot {
        let appKitTip = SoftwareCursorOverlay.currentTipPosition()
        let cgTip = appKitTip.map {
            cuaDriverCGGlobalPoint(fromAppKitGlobalPoint: $0, primaryScreenHeight: primaryScreenHeight)
        }

        return CuaDriverCursorSessionSnapshot(
            enabled: enabled,
            hasCustomGlyph: glyphImage != nil,
            bloomColor: bloomColorHex,
            tipPosition: cgTip.map { CuaDriverCursorTipPosition(x: Double($0.x), y: Double($0.y)) }
        )
    }

    public func isEnabled() -> Bool {
        enabled
    }
}

public struct CuaDriverParsedHexColor {
    public let color: NSColor
    public let hex: String
}

public func cuaDriverParseHexColor(_ rawValue: String) -> CuaDriverParsedHexColor? {
    var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.hasPrefix("#") {
        value.removeFirst()
    }

    guard value.count == 6,
          let raw = UInt32(value, radix: 16)
    else {
        return nil
    }

    let red = CGFloat((raw >> 16) & 0xff) / 255
    let green = CGFloat((raw >> 8) & 0xff) / 255
    let blue = CGFloat(raw & 0xff) / 255
    let canonical = String(format: "#%02X%02X%02X", Int((raw >> 16) & 0xff), Int((raw >> 8) & 0xff), Int(raw & 0xff))
    return CuaDriverParsedHexColor(
        color: NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1),
        hex: canonical
    )
}

public func cuaDriverRunOnMain<T: Sendable>(_ body: @escaping @MainActor () throws -> T) throws -> T {
    if Thread.isMainThread {
        return try MainActor.assumeIsolated {
            try body()
        }
    }

    var result: Result<T, Error>?
    DispatchQueue.main.sync {
        MainActor.assumeIsolated {
            result = Result {
                try body()
            }
        }
    }
    return try result!.get()
}

public func cuaDriverDispatchMainAndWait(
    timeout: TimeInterval,
    _ body: @escaping @MainActor () -> Void
) {
    if Thread.isMainThread {
        MainActor.assumeIsolated {
            body()
        }
        return
    }

    let semaphore = DispatchSemaphore(value: 0)
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            body()
        }
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + timeout)
}

public func cuaDriverDispatchMain(_ body: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            body()
        }
    }
}
