import AppKit
import Foundation

struct SoftwareCursorArtworkOverride {
    let glyphImage: NSImage?
    let bloomColor: NSColor?
}

enum SoftwareCursorArtworkOverrideStore {
    nonisolated(unsafe) private static var currentOverride: SoftwareCursorArtworkOverride?

    static var current: SoftwareCursorArtworkOverride? {
        currentOverride
    }

    static func apply(glyphImage: NSImage?, bloomColor: NSColor?) {
        currentOverride = SoftwareCursorArtworkOverride(
            glyphImage: glyphImage,
            bloomColor: bloomColor
        )
    }

    static func clear() {
        currentOverride = nil
    }
}
