import AppKit
import CoreGraphics
import Foundation

public struct CuaDriverPixelSize: Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public struct CuaDriverCoordinateSpace: Equatable, Sendable {
    public static let defaultMaxScreenshotLongSide: CGFloat = 1568

    public let windowBounds: CuaDriverWindowBounds
    public let backingScale: CGFloat
    public let rawPixelSize: CuaDriverPixelSize
    public let screenshotPixelSize: CuaDriverPixelSize

    public var screenshotWidth: Int {
        screenshotPixelSize.width
    }

    public var screenshotHeight: Int {
        screenshotPixelSize.height
    }

    public func rawPixelToScreenshotPixel(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: point.x * CGFloat(screenshotPixelSize.width) / CGFloat(rawPixelSize.width),
            y: point.y * CGFloat(screenshotPixelSize.height) / CGFloat(rawPixelSize.height)
        )
    }

    public func screenshotPixelToRawPixel(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: point.x * CGFloat(rawPixelSize.width) / CGFloat(screenshotPixelSize.width),
            y: point.y * CGFloat(rawPixelSize.height) / CGFloat(screenshotPixelSize.height)
        )
    }

    public func windowPointToScreenshotPixel(_ point: CGPoint) -> CGPoint {
        rawPixelToScreenshotPixel(
            CGPoint(
                x: point.x * backingScale,
                y: point.y * backingScale
            )
        )
    }

    public func screenshotPixelToWindowPoint(_ point: CGPoint) -> CGPoint {
        let rawPoint = screenshotPixelToRawPixel(point)
        return CGPoint(
            x: rawPoint.x / backingScale,
            y: rawPoint.y / backingScale
        )
    }

    public func screenshotPixelToGlobalPoint(_ point: CGPoint) -> CGPoint {
        let windowPoint = screenshotPixelToWindowPoint(point)
        return CGPoint(
            x: windowBounds.x + Double(windowPoint.x),
            y: windowBounds.y + Double(windowPoint.y)
        )
    }
}

public func cuaDriverCoordinateSpace(
    windowBounds: CuaDriverWindowBounds,
    backingScale: CGFloat,
    maxScreenshotLongSide: CGFloat = CuaDriverCoordinateSpace.defaultMaxScreenshotLongSide
) -> CuaDriverCoordinateSpace {
    let normalizedScale = backingScale.isFinite && backingScale > 0 ? backingScale : 1
    let rawWidth = max(1, Int((CGFloat(windowBounds.width) * normalizedScale).rounded()))
    let rawHeight = max(1, Int((CGFloat(windowBounds.height) * normalizedScale).rounded()))
    let rawSize = CuaDriverPixelSize(width: rawWidth, height: rawHeight)
    let longestRawSide = CGFloat(max(rawWidth, rawHeight))
    let maxLongSide = max(1, maxScreenshotLongSide)

    let screenshotSize: CuaDriverPixelSize
    if longestRawSide <= maxLongSide {
        screenshotSize = rawSize
    } else {
        let downscale = maxLongSide / longestRawSide
        screenshotSize = CuaDriverPixelSize(
            width: max(1, Int((CGFloat(rawWidth) * downscale).rounded())),
            height: max(1, Int((CGFloat(rawHeight) * downscale).rounded()))
        )
    }

    return CuaDriverCoordinateSpace(
        windowBounds: windowBounds,
        backingScale: normalizedScale,
        rawPixelSize: rawSize,
        screenshotPixelSize: screenshotSize
    )
}

public func cuaDriverAppKitRect(
    fromCGGlobalRect rect: CGRect,
    primaryScreenHeight: CGFloat
) -> CGRect {
    CGRect(
        x: rect.minX,
        y: primaryScreenHeight - rect.maxY,
        width: rect.width,
        height: rect.height
    )
}

public func cuaDriverCGGlobalPoint(
    fromAppKitGlobalPoint point: CGPoint,
    primaryScreenHeight: CGFloat
) -> CGPoint {
    CGPoint(
        x: point.x,
        y: primaryScreenHeight - point.y
    )
}

public func cuaDriverAppKitGlobalPoint(
    fromCGGlobalPoint point: CGPoint,
    primaryScreenHeight: CGFloat
) -> CGPoint {
    CGPoint(
        x: point.x,
        y: primaryScreenHeight - point.y
    )
}

public func cuaDriverPrimaryScreenHeight() -> CGFloat {
    let height = CGDisplayBounds(CGMainDisplayID()).height
    if height > 0 {
        return height
    }
    return NSScreen.main?.frame.height ?? NSScreen.screens.first?.frame.height ?? 0
}

public protocol CuaDriverBackingScaleProviding: Sendable {
    func backingScale(for bounds: CuaDriverWindowBounds) -> CGFloat
}

public struct SystemCuaDriverBackingScaleProvider: CuaDriverBackingScaleProviding {
    public init() {}

    public func backingScale(for bounds: CuaDriverWindowBounds) -> CGFloat {
        let appKitRect = cuaDriverAppKitRect(
            fromCGGlobalRect: bounds.cgRect,
            primaryScreenHeight: cuaDriverPrimaryScreenHeight()
        )
        return NSScreen.screens.first(where: { $0.frame.intersects(appKitRect) })?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 1
    }
}
