import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

public enum CuaDriverAXWindowBridgeError: Error, LocalizedError {
    case axWindowNotFound(pid: Int, windowID: Int)
    case unsupportedResolvedWindow
    case unsupportedCachedElement
    case axPressFailed(AXError)
    case mouseEventSourceUnavailable
    case mouseEventCreationFailed(CGEventType)

    public var errorDescription: String? {
        switch self {
        case let .axWindowNotFound(pid, windowID):
            return "Unable to resolve AX window \(windowID) for pid \(pid)"
        case .unsupportedResolvedWindow:
            return "Resolved window is not backed by a macOS AX window"
        case .unsupportedCachedElement:
            return "Cached element is not backed by a macOS AX element"
        case let .axPressFailed(error):
            return "AXUIElementPerformAction(kAXPressAction) failed with \(error.rawValue)"
        case .mouseEventSourceUnavailable:
            return "Failed to create targeted mouse event source"
        case let .mouseEventCreationFailed(type):
            return "Failed to create mouse event \(type.rawValue)"
        }
    }
}

public protocol CuaDriverResolvedWindow: AnyObject, Sendable {
    var pid: Int { get }
    var windowID: Int { get }
    var title: String? { get }
    var appName: String? { get }
}

public final class CuaDriverResolvedAXWindow: CuaDriverResolvedWindow, @unchecked Sendable {
    public let pid: Int
    public let windowID: Int
    public let title: String?
    public let appName: String?
    let appElement: AXUIElement
    let windowElement: AXUIElement

    init(
        pid: Int,
        windowID: Int,
        title: String?,
        appName: String?,
        appElement: AXUIElement,
        windowElement: AXUIElement
    ) {
        self.pid = pid
        self.windowID = windowID
        self.title = title
        self.appName = appName
        self.appElement = appElement
        self.windowElement = windowElement
    }
}

public protocol CuaDriverAXWindowResolving: Sendable {
    func resolveWindow(pid: Int, windowID: Int, windowInfo: CuaDriverWindowInfo) throws -> any CuaDriverResolvedWindow
}

public struct SystemCuaDriverAXWindowResolver: CuaDriverAXWindowResolving {
    public init() {}

    public func resolveWindow(pid: Int, windowID: Int, windowInfo: CuaDriverWindowInfo) throws -> any CuaDriverResolvedWindow {
        let appElement = AXUIElementCreateApplication(pid_t(pid))
        enableDaemonAccessibilityModes(appElement)

        let windows = copyAXArray(appElement, attribute: kAXWindowsAttribute)
            .filter { stringValue(of: $0, attribute: kAXRoleAttribute) == kAXWindowRole as String }

        if let matched = windows.first(where: { privateWindowID(for: $0) == windowID }) {
            return CuaDriverResolvedAXWindow(
                pid: pid,
                windowID: windowID,
                title: stringValue(of: matched, attribute: kAXTitleAttribute) ?? windowInfo.title,
                appName: windowInfo.appName,
                appElement: appElement,
                windowElement: matched
            )
        }

        if let matched = fallbackMatchedWindow(in: windows, target: windowInfo) {
            return CuaDriverResolvedAXWindow(
                pid: pid,
                windowID: windowID,
                title: stringValue(of: matched, attribute: kAXTitleAttribute) ?? windowInfo.title,
                appName: windowInfo.appName,
                appElement: appElement,
                windowElement: matched
            )
        }

        throw CuaDriverAXWindowBridgeError.axWindowNotFound(pid: pid, windowID: windowID)
    }

    private func fallbackMatchedWindow(in windows: [AXUIElement], target: CuaDriverWindowInfo) -> AXUIElement? {
        let targetBounds = target.bounds.cgRect
        let candidates = windows.compactMap { element -> FallbackWindowCandidate? in
            guard boolValue(of: element, attribute: kAXMinimizedAttribute) != true,
                  let frame = frame(of: element)
            else {
                return nil
            }

            let title = stringValue(of: element, attribute: kAXTitleAttribute)
            let titleMatches = !target.title.isEmpty && title == target.title
            let distance = rectDistance(frame, targetBounds)
            let sizeDelta = abs(frame.width - targetBounds.width) + abs(frame.height - targetBounds.height)
            let intersects = frame.intersects(targetBounds)

            guard titleMatches || distance <= 48 || (intersects && sizeDelta <= 48) else {
                return nil
            }

            let titleScore = titleMatches ? 1_000.0 : 0.0
            let frameScore = max(0, 500.0 - Double(distance + sizeDelta))
            return FallbackWindowCandidate(element: element, score: titleScore + frameScore)
        }

        return candidates.max(by: { $0.score < $1.score })?.element
    }
}

public protocol CuaDriverCachedElement: AnyObject, Sendable {}

public final class CuaDriverAXCachedElement: CuaDriverCachedElement, @unchecked Sendable {
    let element: AXUIElement

    init(_ element: AXUIElement) {
        self.element = element
    }
}

public struct CuaDriverWindowStateSnapshot: Sendable {
    public let tree: String
    public let elements: [Int: any CuaDriverCachedElement]

    public init(tree: String, elements: [Int: any CuaDriverCachedElement]) {
        self.tree = tree
        self.elements = elements
    }
}

public protocol CuaDriverWindowStateRendering: Sendable {
    func render(window: any CuaDriverResolvedWindow, windowInfo: CuaDriverWindowInfo) throws -> CuaDriverWindowStateSnapshot
}

public struct SystemCuaDriverWindowStateRenderer: CuaDriverWindowStateRendering {
    public init() {}

    public func render(window: any CuaDriverResolvedWindow, windowInfo: CuaDriverWindowInfo) throws -> CuaDriverWindowStateSnapshot {
        guard let window = window as? CuaDriverResolvedAXWindow else {
            throw CuaDriverAXWindowBridgeError.unsupportedResolvedWindow
        }

        var renderer = CuaDriverAXTreeRenderer(windowBounds: windowInfo.bounds.cgRect)
        renderer.render(window.windowElement)
        return CuaDriverWindowStateSnapshot(
            tree: renderer.lines.joined(separator: "\n"),
            elements: renderer.elements
        )
    }
}

public final class CuaDriverElementCache: @unchecked Sendable {
    private struct Key: Hashable {
        let pid: Int
        let windowID: Int
    }

    private let lock = NSLock()
    private var elementsByWindow: [Key: [Int: any CuaDriverCachedElement]] = [:]

    public init() {}

    public func replace(pid: Int, windowID: Int, elements: [Int: any CuaDriverCachedElement]) {
        lock.withLock {
            elementsByWindow[Key(pid: pid, windowID: windowID)] = elements
        }
    }

    public func element(pid: Int, windowID: Int, index: Int) -> (any CuaDriverCachedElement)? {
        lock.withLock {
            elementsByWindow[Key(pid: pid, windowID: windowID)]?[index]
        }
    }
}

public protocol CuaDriverElementClicking: Sendable {
    func press(_ element: any CuaDriverCachedElement) throws
}

public struct SystemCuaDriverElementClicker: CuaDriverElementClicking {
    public init() {}

    public func press(_ element: any CuaDriverCachedElement) throws {
        guard let element = element as? CuaDriverAXCachedElement else {
            throw CuaDriverAXWindowBridgeError.unsupportedCachedElement
        }

        let error = AXUIElementPerformAction(element.element, kAXPressAction as CFString)
        guard error == .success else {
            throw CuaDriverAXWindowBridgeError.axPressFailed(error)
        }
    }
}

public enum CuaDriverMouseButton: String, Sendable {
    case left
    case right

    var cgButton: CGMouseButton {
        switch self {
        case .left:
            return .left
        case .right:
            return .right
        }
    }

    var downEvent: CGEventType {
        switch self {
        case .left:
            return .leftMouseDown
        case .right:
            return .rightMouseDown
        }
    }

    var upEvent: CGEventType {
        switch self {
        case .left:
            return .leftMouseUp
        case .right:
            return .rightMouseUp
        }
    }
}

public protocol CuaDriverCoordinateClicking: Sendable {
    func click(pid: Int, point: CGPoint, button: CuaDriverMouseButton, clickCount: Int) throws
}

public struct SystemCuaDriverCoordinateClicker: CuaDriverCoordinateClicking {
    public init() {}

    public func click(pid: Int, point: CGPoint, button: CuaDriverMouseButton, clickCount: Int) throws {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw CuaDriverAXWindowBridgeError.mouseEventSourceUnavailable
        }

        for _ in 0..<max(clickCount, 1) {
            try postMouseEvent(type: button.downEvent, source: source, point: point, button: button.cgButton, clickState: clickCount, pid: pid_t(pid))
            try postMouseEvent(type: button.upEvent, source: source, point: point, button: button.cgButton, clickState: clickCount, pid: pid_t(pid))
        }
    }

    private func postMouseEvent(type: CGEventType, source: CGEventSource, point: CGPoint, button: CGMouseButton, clickState: Int, pid: pid_t) throws {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button) else {
            throw CuaDriverAXWindowBridgeError.mouseEventCreationFailed(type)
        }

        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        event.postToPid(pid)
        Thread.sleep(forTimeInterval: 0.03)
    }
}

private struct CuaDriverAXTreeRenderer {
    let windowBounds: CGRect
    var nextElementIndex = 0
    var lines: [String] = []
    var elements: [Int: any CuaDriverCachedElement] = [:]

    mutating func render(_ element: AXUIElement, depth: Int = 0, ancestors: [AXUIElement] = []) {
        guard shouldContinueRendering(nextIndex: lines.count, depth: depth) else {
            return
        }

        guard !ancestors.contains(where: { CFEqual($0, element) }) else {
            return
        }
        let nextAncestors = ancestors + [element]

        let role = stringValue(of: element, attribute: kAXRoleAttribute) ?? kAXUnknownRole as String
        let subrole = stringValue(of: element, attribute: kAXSubroleAttribute)
        let title = displayTitle(of: element, role: role)
        let description = stringValue(of: element, attribute: kAXDescriptionAttribute).map { sanitizeText($0) }
        let value = valueDescription(of: element)
        let identifier = displayIdentifier(stringValue(of: element, attribute: kAXIdentifierAttribute))
        let rawActions = copyAXActions(element)
        let prettyActions = meaningfulActions(rawActions, role: role)
        let traits = traitDescriptions(of: element)
        let children = childElements(of: element, role: role)
        let webAreaDepth = webAreaDepth(role: role, ancestors: ancestors)

        if shouldElideNode(
            role: role,
            title: title,
            label: description,
            value: value,
            identifier: identifier,
            traits: traits,
            actions: prettyActions,
            childCount: children.count,
            webAreaDepth: webAreaDepth
        ) {
            for child in children {
                render(child, depth: depth, ancestors: nextAncestors)
            }
            return
        }

        let roleText = daemonRoleDescription(of: element, role: role, subrole: subrole)
        let traitsSegment = traits.isEmpty ? "" : " (\(traits.joined(separator: ", ")))"
        let titleSegment = title.map { " \($0)" } ?? ""
        let descriptionSegment = formattedDescriptionSegment(description, title: title)
        let valueSegment = formattedValueSegment(value, role: role, title: title, hasPriorText: descriptionSegment.isEmpty == false)
        let identifierSegment = identifier.map { " ID: \($0)" } ?? ""
        let actionsSegment = prettyActions.isEmpty ? "" : " Secondary Actions: \(prettyActions.joined(separator: ", "))"

        let markerSegment: String
        if shouldIndexElement(role: role, rawActions: rawActions, value: value, traits: traits) {
            let index = nextElementIndex
            nextElementIndex += 1
            elements[index] = CuaDriverAXCachedElement(element)
            markerSegment = " [element_index \(index)]"
        } else {
            markerSegment = ""
        }

        let line = "\(roleText)\(markerSegment)\(traitsSegment)\(titleSegment)\(descriptionSegment)\(valueSegment)\(identifierSegment)\(actionsSegment)"
            .trimmingCharacters(in: .whitespaces)
        lines.append("\(String(repeating: "\t", count: depth))\(line.isEmpty ? role : line)")

        for child in children {
            render(child, depth: depth + 1, ancestors: nextAncestors)
        }
    }

    private func childElements(of element: AXUIElement, role: String) -> [AXUIElement] {
        let rows = copyAXArray(element, attribute: kAXRowsAttribute)
        let visibleChildren = copyAXArray(element, attribute: "AXVisibleChildren")
        let attributes = childTraversalAttributes(
            role: role,
            hasRows: !rows.isEmpty,
            hasVisibleChildren: !visibleChildren.isEmpty
        )

        var children: [AXUIElement] = []
        for attribute in attributes {
            let values: [AXUIElement]
            if attribute == kAXRowsAttribute {
                values = rows
            } else if attribute == "AXVisibleChildren" {
                values = visibleChildren
            } else {
                values = copyAXArray(element, attribute: attribute)
            }

            for child in values where !shouldSkip(child: child, of: element) {
                if !children.contains(where: { CFEqual($0, child) }) {
                    children.append(child)
                }
            }
        }
        return children
    }

    private func shouldSkip(child: AXUIElement, of parent: AXUIElement) -> Bool {
        let parentRole = stringValue(of: parent, attribute: kAXRoleAttribute)
        return parentRole == kAXMenuBarRole as String
            && stringValue(of: child, attribute: kAXTitleAttribute) == "Apple"
    }

    private func webAreaDepth(role: String, ancestors: [AXUIElement]) -> Int? {
        if role == "AXWebArea" {
            return 0
        }

        guard let webAreaIndex = ancestors.firstIndex(where: { ancestor in
            stringValue(of: ancestor, attribute: kAXRoleAttribute) == "AXWebArea"
        }) else {
            return nil
        }

        return ancestors.count - webAreaIndex
    }

    private func displayTitle(of element: AXUIElement, role: String) -> String? {
        if let title = stringValue(of: element, attribute: kAXTitleAttribute) {
            return sanitizeText(title)
        }

        if role == kAXButtonRole as String || role == kAXPopUpButtonRole as String || role == kAXImageRole as String,
           let description = stringValue(of: element, attribute: kAXDescriptionAttribute)
        {
            return sanitizeText(description)
        }

        if role == kAXTextFieldRole as String || role == kAXTextAreaRole as String,
           let value = valueDescription(of: element)
        {
            return value
        }

        return nil
    }

    private func traitDescriptions(of element: AXUIElement) -> [String] {
        var traits: [String] = []
        if boolValue(of: element, attribute: kAXSelectedAttribute) == true {
            traits.append("selected")
        }
        if boolValue(of: element, attribute: kAXExpandedAttribute) == true {
            traits.append("expanded")
        }
        if boolValue(of: element, attribute: kAXEnabledAttribute) == false {
            traits.append("disabled")
        }
        if isSettable(of: element, attribute: kAXValueAttribute) {
            traits.append("settable")
        }
        return traits
    }

    private func shouldIndexElement(role: String, rawActions: [String], value: String?, traits: [String]) -> Bool {
        let clickActions = [
            kAXPressAction as String,
            kAXConfirmAction as String,
            kAXShowMenuAction as String,
            "AXOpen",
        ]
        let hasPrimaryAction = rawActions.contains { action in
            clickActions.contains { $0.caseInsensitiveCompare(action) == .orderedSame }
        }
        let hasValue = value?.isEmpty == false || traits.contains("settable")

        if role == kAXMenuBarRole as String || role == kAXMenuRole as String {
            return false
        }

        return hasPrimaryAction || hasValue
    }

    private func formattedDescriptionSegment(_ description: String?, title: String?) -> String {
        guard let description, !description.isEmpty, description != title else {
            return ""
        }
        return " Description: \(description)"
    }

    private func formattedValueSegment(_ value: String?, role: String, title: String?, hasPriorText: Bool) -> String {
        guard let value, !value.isEmpty, value != title else {
            return ""
        }

        if role == kAXStaticTextRole as String && title == nil {
            return " \(value)"
        }

        return hasPriorText ? ", Value: \(value)" : " Value: \(value)"
    }
}

private typealias AXGetWindowFunction = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

private func privateWindowID(for element: AXUIElement) -> Int? {
    guard let function = AXWindowIDFunction.shared else {
        return nil
    }

    var windowID = CGWindowID(0)
    guard function(element, &windowID) == .success, windowID != 0 else {
        return nil
    }
    return Int(windowID)
}

private enum AXWindowIDFunction {
    static let shared: AXGetWindowFunction? = {
        guard let handle = dlopen(nil, RTLD_LAZY) else {
            return nil
        }
        guard let symbol = dlsym(handle, "_AXUIElementGetWindow") else {
            return nil
        }
        return unsafeBitCast(symbol, to: AXGetWindowFunction.self)
    }()
}

private struct FallbackWindowCandidate {
    let element: AXUIElement
    let score: Double
}

private func rectDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
    abs(lhs.minX - rhs.minX)
        + abs(lhs.minY - rhs.minY)
        + abs(lhs.width - rhs.width)
        + abs(lhs.height - rhs.height)
}

private func enableDaemonAccessibilityModes(_ appElement: AXUIElement) {
    _ = AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    _ = AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
}

private func copyAXAttribute(_ element: AXUIElement, attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    guard error == .success else {
        return nil
    }
    return value
}

private func copyAXArray(_ element: AXUIElement, attribute: String) -> [AXUIElement] {
    copyAXAttribute(element, attribute: attribute) as? [AXUIElement] ?? []
}

private func copyAXActions(_ element: AXUIElement) -> [String] {
    var actions: CFArray?
    guard AXUIElementCopyActionNames(element, &actions) == .success else {
        return []
    }
    return actions as? [String] ?? []
}

private func stringValue(of element: AXUIElement, attribute: String) -> String? {
    guard let value = copyAXAttribute(element, attribute: attribute) else {
        return nil
    }

    if CFGetTypeID(value) == CFStringGetTypeID(), let string = value as? String {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    return nil
}

private func boolValue(of element: AXUIElement, attribute: String) -> Bool? {
    copyAXAttribute(element, attribute: attribute) as? Bool
}

private func isSettable(of element: AXUIElement, attribute: String) -> Bool {
    var settable = DarwinBoolean(false)
    let error = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
    return error == .success && settable.boolValue
}

private func valueDescription(of element: AXUIElement) -> String? {
    if let string = stringValue(of: element, attribute: kAXValueAttribute) {
        let sanitized = sanitizeText(string)
        return sanitized.isEmpty ? nil : sanitized
    }

    guard let value = copyAXAttribute(element, attribute: kAXValueAttribute) else {
        return nil
    }

    if let number = value as? NSNumber {
        return number.stringValue
    }

    return nil
}

private func frame(of element: AXUIElement) -> CGRect? {
    guard let positionValue = copyAXAttribute(element, attribute: kAXPositionAttribute),
          let sizeValue = copyAXAttribute(element, attribute: kAXSizeAttribute)
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

private func displayIdentifier(_ value: String?) -> String? {
    guard let value, !value.isEmpty, !value.hasPrefix("_NS:") else {
        return nil
    }
    return value
}

private func daemonRoleDescription(of element: AXUIElement, role: String, subrole: String?) -> String {
    if role == kAXRowRole as String {
        return "row"
    }
    if role == kAXGroupRole as String {
        return "container"
    }
    if role == kAXMenuBarItemRole as String {
        return ""
    }
    if role == "AXLink" {
        return "link"
    }
    if role == "AXWebArea" {
        return stringValue(of: element, attribute: kAXRoleDescriptionAttribute) ?? "HTML content"
    }
    if let roleDescription = stringValue(of: element, attribute: kAXRoleDescriptionAttribute), !roleDescription.isEmpty {
        return roleDescription.lowercased()
    }
    if let subrole, subrole == kAXStandardWindowSubrole as String {
        return "standard window"
    }
    return humanizedAXToken(role)
}

private func humanizedAXToken(_ value: String) -> String {
    let stripped = value.hasPrefix("AX") ? String(value.dropFirst(2)) : value
    var result = ""
    for character in stripped {
        if character.isUppercase, !result.isEmpty {
            result.append(" ")
        }
        result.append(character)
    }
    return result.lowercased()
}
