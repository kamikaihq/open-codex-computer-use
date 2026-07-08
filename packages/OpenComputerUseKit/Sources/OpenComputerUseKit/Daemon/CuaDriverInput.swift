import ApplicationServices
import CoreGraphics
import Foundation

public enum CuaDriverInputError: Error, LocalizedError {
    case unsupportedCachedElement
    case unsupportedValue
    case setValueFailed(AXError)
    case actionFailed(action: String, error: AXError)
    case eventSourceUnavailable
    case eventCreationFailed(CGEventType)

    public var errorDescription: String? {
        switch self {
        case .unsupportedCachedElement:
            return "Cached element is not backed by a macOS AX element"
        case .unsupportedValue:
            return "value must be a string or number"
        case let .setValueFailed(error):
            return "AXUIElementSetAttributeValue(kAXValueAttribute) failed with \(error.rawValue)"
        case let .actionFailed(action, error):
            return "AXUIElementPerformAction(\(action)) failed with \(error.rawValue)"
        case .eventSourceUnavailable:
            return "Failed to create targeted event source"
        case let .eventCreationFailed(type):
            return "Failed to create event \(type.rawValue)"
        }
    }
}

public protocol CuaDriverInputEventPosting: Sendable {
    func typeText(_ text: String, pid: Int) throws
    func pressKey(_ specification: String, pid: Int) throws
    func scroll(pid: Int, point: CGPoint, direction: String, pages: Int) throws
    func drag(pid: Int, from start: CGPoint, to end: CGPoint) throws
}

public struct SystemCuaDriverInputEventPoster: CuaDriverInputEventPosting {
    public init() {}

    public func typeText(_ text: String, pid: Int) throws {
        try InputSimulation.typeText(text, pid: pid_t(pid))
    }

    public func pressKey(_ specification: String, pid: Int) throws {
        try InputSimulation.pressKey(specification, pid: pid_t(pid))
    }

    public func scroll(pid: Int, point: CGPoint, direction: String, pages: Int) throws {
        try InputSimulation.scrollTargeted(at: point, direction: direction, pages: Double(pages), pid: pid_t(pid))
    }

    public func drag(pid: Int, from start: CGPoint, to end: CGPoint) throws {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw CuaDriverInputError.eventSourceUnavailable
        }

        for event in cuaDriverDragEventSequence(from: start, to: end) {
            guard let cgEvent = CGEvent(
                mouseEventSource: source,
                mouseType: event.type,
                mouseCursorPosition: event.point,
                mouseButton: .left
            ) else {
                throw CuaDriverInputError.eventCreationFailed(event.type)
            }

            cgEvent.setIntegerValueField(.mouseEventClickState, value: 1)
            cgEvent.postToPid(pid_t(pid))
            if event.delayAfter > 0 {
                Thread.sleep(forTimeInterval: event.delayAfter)
            }
        }
    }
}

public struct CuaDriverDragEvent: Equatable, Sendable {
    public let type: CGEventType
    public let point: CGPoint
    public let delayAfter: TimeInterval
}

public func cuaDriverDragEventSequence(
    from start: CGPoint,
    to end: CGPoint,
    steps: Int = 12,
    stepDelay: TimeInterval = 0.015
) -> [CuaDriverDragEvent] {
    let stepCount = max(1, steps)
    var events: [CuaDriverDragEvent] = [
        CuaDriverDragEvent(type: .leftMouseDown, point: start, delayAfter: stepDelay),
    ]

    for step in 1...stepCount {
        let progress = CGFloat(step) / CGFloat(stepCount)
        let point = CGPoint(
            x: start.x + ((end.x - start.x) * progress),
            y: start.y + ((end.y - start.y) * progress)
        )
        events.append(CuaDriverDragEvent(type: .leftMouseDragged, point: point, delayAfter: stepDelay))
    }

    events.append(CuaDriverDragEvent(type: .leftMouseUp, point: end, delayAfter: 0))
    return events
}

public protocol CuaDriverElementInteracting: Sendable {
    func setValue(_ value: Any, on element: any CuaDriverCachedElement) throws
    func availableActions(on element: any CuaDriverCachedElement) throws -> [String]
    func performAction(_ action: String, on element: any CuaDriverCachedElement) throws
    func frameCenter(of element: any CuaDriverCachedElement) -> CGPoint?
}

public struct SystemCuaDriverElementInteractor: CuaDriverElementInteracting {
    public init() {}

    public func setValue(_ value: Any, on element: any CuaDriverCachedElement) throws {
        guard let axElement = (element as? CuaDriverAXCachedElement)?.element else {
            throw CuaDriverInputError.unsupportedCachedElement
        }

        let cfValue: CFTypeRef
        switch value {
        case let string as String:
            cfValue = string as CFString
        case let number as NSNumber:
            cfValue = number
        default:
            throw CuaDriverInputError.unsupportedValue
        }

        let error = AXUIElementSetAttributeValue(axElement, kAXValueAttribute as CFString, cfValue)
        guard error == .success else {
            throw CuaDriverInputError.setValueFailed(error)
        }
    }

    public func availableActions(on element: any CuaDriverCachedElement) throws -> [String] {
        guard let axElement = (element as? CuaDriverAXCachedElement)?.element else {
            throw CuaDriverInputError.unsupportedCachedElement
        }

        var actions: CFArray?
        let error = AXUIElementCopyActionNames(axElement, &actions)
        guard error == .success else {
            return []
        }
        return actions as? [String] ?? []
    }

    public func performAction(_ action: String, on element: any CuaDriverCachedElement) throws {
        guard let axElement = (element as? CuaDriverAXCachedElement)?.element else {
            throw CuaDriverInputError.unsupportedCachedElement
        }

        let error = AXUIElementPerformAction(axElement, action as CFString)
        guard error == .success else {
            throw CuaDriverInputError.actionFailed(action: action, error: error)
        }
    }

    public func frameCenter(of element: any CuaDriverCachedElement) -> CGPoint? {
        guard let axElement = (element as? CuaDriverAXCachedElement)?.element,
              let frame = axFrame(of: axElement)
        else {
            return nil
        }

        return CGPoint(x: frame.midX, y: frame.midY)
    }

    private func axFrame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue,
              let sizeValue
        else {
            return nil
        }

        let positionAXValue = positionValue as! AXValue
        let sizeAXValue = sizeValue as! AXValue
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAXValue, .cgPoint, &position),
              AXValueGetValue(sizeAXValue, .cgSize, &size)
        else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }
}

public func cuaDriverScrollAction(direction: String) -> String? {
    switch direction {
    case "up":
        return "AXScrollUpByPage"
    case "down":
        return "AXScrollDownByPage"
    case "left":
        return "AXScrollLeftByPage"
    case "right":
        return "AXScrollRightByPage"
    default:
        return nil
    }
}

public func cuaDriverMatchingAXAction(requested: String, availableActions: [String]) -> String? {
    if let exact = availableActions.first(where: { $0.caseInsensitiveCompare(requested) == .orderedSame }) {
        return exact
    }

    let normalizedRequested = normalizeAXActionName(requested)
    return availableActions.first { action in
        normalizeAXActionName(cuaDriverPrettyAXActionName(action)) == normalizedRequested
    }
}

public func cuaDriverPrettyAXActionName(_ value: String) -> String {
    let stripped = value.hasPrefix("AX") ? String(value.dropFirst(2)) : value
    let withoutPage = stripped.replacingOccurrences(of: "ByPage", with: "")
    var result = ""
    for character in withoutPage {
        if character.isUppercase, !result.isEmpty {
            result.append(" ")
        }
        result.append(character)
    }
    return result
}

private func normalizeAXActionName(_ value: String) -> String {
    value
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .replacingOccurrences(of: " ", with: "")
        .replacingOccurrences(of: "_", with: "")
        .replacingOccurrences(of: "-", with: "")
}
