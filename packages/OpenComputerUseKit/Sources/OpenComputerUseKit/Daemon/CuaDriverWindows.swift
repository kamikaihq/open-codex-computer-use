import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit

public struct CuaDriverWindowBounds: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(_ rect: CGRect) {
        self.init(
            x: Double(rect.origin.x),
            y: Double(rect.origin.y),
            width: Double(rect.width),
            height: Double(rect.height)
        )
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    var jsonObject: [String: Any] {
        [
            "x": x,
            "y": y,
            "width": width,
            "height": height,
        ]
    }
}

public struct CuaDriverWindowInfo: Equatable, Sendable {
    public let windowID: Int
    public let pid: Int
    public let appName: String
    public let title: String
    public let bounds: CuaDriverWindowBounds
    public let isOnScreen: Bool

    public init(
        windowID: Int,
        pid: Int,
        appName: String,
        title: String,
        bounds: CuaDriverWindowBounds,
        isOnScreen: Bool
    ) {
        self.windowID = windowID
        self.pid = pid
        self.appName = appName
        self.title = title
        self.bounds = bounds
        self.isOnScreen = isOnScreen
    }

    var jsonObject: [String: Any] {
        [
            "window_id": windowID,
            "pid": pid,
            "app_name": appName,
            "title": title,
            "bounds": bounds.jsonObject,
            "is_on_screen": isOnScreen,
        ]
    }
}

public struct CuaDriverDisplayRegion: Equatable, Sendable {
    public let bounds: CuaDriverWindowBounds

    public init(bounds: CuaDriverWindowBounds) {
        self.bounds = bounds
    }

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.init(bounds: CuaDriverWindowBounds(x: x, y: y, width: width, height: height))
    }
}

public enum CuaDriverScreenshotFormat: String, Sendable {
    case jpeg
    case png

    var imageTypeIdentifier: CFString {
        switch self {
        case .jpeg:
            return "public.jpeg" as CFString
        case .png:
            return "public.png" as CFString
        }
    }

}

public struct CuaDriverCapturedScreenshot: Equatable, Sendable {
    public let imageData: Data
    public let format: CuaDriverScreenshotFormat
    public let width: Int
    public let height: Int
    public let capturePath: String

    public init(
        imageData: Data,
        format: CuaDriverScreenshotFormat,
        width: Int,
        height: Int,
        capturePath: String
    ) {
        self.imageData = imageData
        self.format = format
        self.width = width
        self.height = height
        self.capturePath = capturePath
    }

    var jsonObject: [String: Any] {
        [
            "image": imageData.base64EncodedString(),
            "format": format.rawValue,
            "width": width,
            "height": height,
            "capture_path": capturePath,
        ]
    }
}

public protocol CuaDriverWindowProviding: Sendable {
    func listWindows(pid: Int?) -> [CuaDriverWindowInfo]
    func window(windowID: Int, pid: Int?) -> CuaDriverWindowInfo?
}

public protocol CuaDriverWindowCapturing: Sendable {
    func capture(window: CuaDriverWindowInfo, format: CuaDriverScreenshotFormat) throws -> CuaDriverCapturedScreenshot
    func capture(displayRegion: CuaDriverDisplayRegion, format: CuaDriverScreenshotFormat) throws -> CuaDriverCapturedScreenshot
}

public extension CuaDriverWindowCapturing {
    func capture(displayRegion: CuaDriverDisplayRegion, format: CuaDriverScreenshotFormat) throws -> CuaDriverCapturedScreenshot {
        throw CuaDriverScreenshotError.captureFailed("Display-region capture is not implemented")
    }
}

public struct SystemCuaDriverWindowProvider: CuaDriverWindowProviding {
    public init() {}

    public func listWindows(pid: Int?) -> [CuaDriverWindowInfo] {
        guard let infoList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        return infoList.compactMap { info in
            guard
                let layer = intValue(info[kCGWindowLayer as String]),
                layer == 0,
                let windowID = intValue(info[kCGWindowNumber as String]),
                let ownerPID = intValue(info[kCGWindowOwnerPID as String]),
                pid == nil || ownerPID == pid,
                let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                bounds.width > 0,
                bounds.height > 0
            else {
                return nil
            }

            return CuaDriverWindowInfo(
                windowID: windowID,
                pid: ownerPID,
                appName: info[kCGWindowOwnerName as String] as? String ?? "",
                title: info[kCGWindowName as String] as? String ?? "",
                bounds: CuaDriverWindowBounds(bounds),
                isOnScreen: boolValue(info[kCGWindowIsOnscreen as String]) ?? false
            )
        }
    }

    public func window(windowID: Int, pid: Int?) -> CuaDriverWindowInfo? {
        listWindows(pid: pid).first { $0.windowID == windowID }
    }
}

public struct SystemCuaDriverWindowCapturer: CuaDriverWindowCapturing {
    private let timeout: TimeInterval
    private let maxEncodedBytes: Int

    public init(timeout: TimeInterval = 10, maxEncodedBytes: Int = 24 * 1024 * 1024) {
        self.timeout = timeout
        self.maxEncodedBytes = maxEncodedBytes
    }

    public func capture(window: CuaDriverWindowInfo, format: CuaDriverScreenshotFormat) throws -> CuaDriverCapturedScreenshot {
        do {
            let image = try captureWithScreenCaptureKit(window: window)
            return try encode(image: image, format: format, capturePath: "sck")
        } catch {
            let image = try captureWithCGWindowList(windowID: window.windowID)
            return try encode(image: image, format: format, capturePath: "cgwindowlist")
        }
    }

    public func capture(displayRegion: CuaDriverDisplayRegion, format: CuaDriverScreenshotFormat) throws -> CuaDriverCapturedScreenshot {
        // SCK first, matching the window path: CGWindowListCreateImage can block
        // indefinitely on the SkyLight main connection in some spawn contexts.
        do {
            let image = try captureDisplayRegionWithScreenCaptureKit(displayRegion.bounds.cgRect)
            return try encode(image: image, format: format, capturePath: "sck_display_region")
        } catch {
            let image = try captureDisplayRegionWithCGWindowList(displayRegion.bounds.cgRect)
            return try encode(image: image, format: format, capturePath: "cgwindowlist_display_region")
        }
    }

    private func captureDisplayRegionWithScreenCaptureKit(_ region: CGRect) throws -> CGImage {
        try BlockingAsyncBridge.run(timeout: timeout) {
            let shareableContent = try await SCShareableContent.current
            guard let display = shareableContent.displays.first(where: { $0.frame.intersects(region) })
                ?? shareableContent.displays.first
            else {
                throw CuaDriverScreenshotError.captureFailed("ScreenCaptureKit exposed no displays")
            }

            let configuration = SCStreamConfiguration()
            let scaleFactor = bestEffortScaleFactor(for: region)
            // sourceRect is in display-local points (display.frame is CG global).
            let localRegion = CGRect(
                x: region.origin.x - display.frame.origin.x,
                y: region.origin.y - display.frame.origin.y,
                width: region.width,
                height: region.height
            ).intersection(CGRect(origin: .zero, size: display.frame.size))
            guard !localRegion.isEmpty else {
                throw CuaDriverScreenshotError.captureFailed("Display region is outside every display")
            }
            configuration.sourceRect = localRegion
            configuration.width = max(1, Int(ceil(localRegion.width * scaleFactor)))
            configuration.height = max(1, Int(ceil(localRegion.height * scaleFactor)))
            configuration.showsCursor = false

            let filter = SCContentFilter(display: display, excludingWindows: [])
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        }
    }

    private func captureWithScreenCaptureKit(window: CuaDriverWindowInfo) throws -> CGImage {
        try BlockingAsyncBridge.run(timeout: timeout) {
            let shareableContent = try await SCShareableContent.current
            guard let scWindow = shareableContent.windows.first(where: { Int($0.windowID) == window.windowID }) else {
                throw CuaDriverScreenshotError.captureFailed("ScreenCaptureKit did not expose window \(window.windowID)")
            }

            let configuration = SCStreamConfiguration()
            let scaleFactor = bestEffortScaleFactor(for: window.bounds.cgRect)
            let captureSize = scWindow.frame.isEmpty ? window.bounds.cgRect.size : scWindow.frame.size
            configuration.width = max(1, Int(ceil(captureSize.width * scaleFactor)))
            configuration.height = max(1, Int(ceil(captureSize.height * scaleFactor)))
            configuration.showsCursor = false
            configuration.scalesToFit = false
            configuration.ignoreShadowsSingleWindow = true

            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        }
    }

    private func captureWithCGWindowList(windowID: Int) throws -> CGImage {
        guard let image = CGWindowListCreateImage(
            .null,
            [.optionIncludingWindow],
            CGWindowID(windowID),
            [.boundsIgnoreFraming, .bestResolution]
        ), image.width > 0, image.height > 0 else {
            throw CuaDriverScreenshotError.captureFailed("Unable to capture window \(windowID)")
        }

        return image
    }

    private func captureDisplayRegionWithCGWindowList(_ region: CGRect) throws -> CGImage {
        guard region.width > 0, region.height > 0 else {
            throw CuaDriverScreenshotError.captureFailed("Display region must have positive width and height")
        }

        guard let image = CGWindowListCreateImage(
            region,
            [.optionOnScreenOnly],
            kCGNullWindowID,
            [.bestResolution]
        ), image.width > 0, image.height > 0 else {
            throw CuaDriverScreenshotError.captureFailed("Unable to capture display region")
        }

        return image
    }

    private func encode(image: CGImage, format: CuaDriverScreenshotFormat, capturePath: String) throws -> CuaDriverCapturedScreenshot {
        guard image.width > 0, image.height > 0 else {
            throw CuaDriverScreenshotError.captureFailed("Captured image is empty")
        }

        let original = try encodeCandidate(image: image, format: format)
        if original.imageData.count <= maxEncodedBytes {
            return CuaDriverCapturedScreenshot(
                imageData: original.imageData,
                format: format,
                width: original.width,
                height: original.height,
                capturePath: capturePath
            )
        }

        var best = original
        var scale: CGFloat = 0.85
        while scale >= 0.05 {
            guard let resized = resizedCGImage(image, scale: scale) else {
                break
            }
            let encoded = try encodeCandidate(image: resized, format: format)
            best = encoded
            if encoded.imageData.count <= maxEncodedBytes {
                break
            }
            scale *= 0.85
        }

        guard best.imageData.count <= CuaDriverFraming.maximumFrameLength / 2 else {
            throw CuaDriverScreenshotError.captureFailed("Encoded screenshot is too large")
        }

        return CuaDriverCapturedScreenshot(
            imageData: best.imageData,
            format: format,
            width: best.width,
            height: best.height,
            capturePath: capturePath
        )
    }

    private func encodeCandidate(image: CGImage, format: CuaDriverScreenshotFormat) throws -> EncodedImage {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, format.imageTypeIdentifier, 1, nil) else {
            throw CuaDriverScreenshotError.captureFailed("Unable to create image encoder")
        }

        let properties: CFDictionary
        switch format {
        case .jpeg:
            properties = [kCGImageDestinationLossyCompressionQuality as String: 0.85] as CFDictionary
        case .png:
            properties = [:] as CFDictionary
        }

        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else {
            throw CuaDriverScreenshotError.captureFailed("Unable to encode image")
        }

        return EncodedImage(imageData: data as Data, width: image.width, height: image.height)
    }
}

public enum CuaDriverScreenshotError: Error, LocalizedError {
    case captureFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .captureFailed(message):
            return message
        }
    }
}

private struct EncodedImage {
    let imageData: Data
    let width: Int
    let height: Int
}

private func bestEffortScaleFactor(for bounds: CGRect) -> CGFloat {
    let appKitRect = cuaDriverAppKitRect(
        fromCGGlobalRect: bounds,
        primaryScreenHeight: cuaDriverPrimaryScreenHeight()
    )
    return NSScreen.screens.first(where: { $0.frame.intersects(appKitRect) })?.backingScaleFactor
        ?? NSScreen.main?.backingScaleFactor
        ?? 1
}

private func resizedCGImage(_ image: CGImage, scale: CGFloat) -> CGImage? {
    let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
    let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else {
        return nil
    }

    context.interpolationQuality = .medium
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()
}

private func intValue(_ value: Any?) -> Int? {
    switch value {
    case let int as Int:
        return int
    case let number as NSNumber:
        return number.intValue
    default:
        return nil
    }
}

private func boolValue(_ value: Any?) -> Bool? {
    switch value {
    case let bool as Bool:
        return bool
    case let number as NSNumber:
        return number.boolValue
    default:
        return nil
    }
}
