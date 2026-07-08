import Darwin
import Foundation
import ApplicationServices
import ImageIO
import XCTest
@testable import OpenComputerUseKit

final class CuaDriverCoordinateSpaceTests: XCTestCase {
    func testRoundTripsRawPixelsAtOneAndTwoXBackingScale() {
        let cases: [(CuaDriverWindowBounds, CGFloat)] = [
            (CuaDriverWindowBounds(x: 0, y: 0, width: 1400, height: 721), 1.0),
            (CuaDriverWindowBounds(x: 10, y: 20, width: 1600.5, height: 917.25), 2.0),
        ]

        for (bounds, backingScale) in cases {
            let space = cuaDriverCoordinateSpace(windowBounds: bounds, backingScale: backingScale)
            let rawPoint = CGPoint(
                x: CGFloat(space.rawPixelSize.width) * 0.37,
                y: CGFloat(space.rawPixelSize.height) * 0.61
            )

            let pngPoint = space.rawPixelToScreenshotPixel(rawPoint)
            let roundTripped = space.screenshotPixelToRawPixel(pngPoint)

            XCTAssertLessThanOrEqual(abs(roundTripped.x - rawPoint.x), 1)
            XCTAssertLessThanOrEqual(abs(roundTripped.y - rawPoint.y), 1)
        }
    }

    func testTinyWindowUsesRawPixelIdentitySize() {
        let space = cuaDriverCoordinateSpace(
            windowBounds: CuaDriverWindowBounds(x: 0, y: 0, width: 100, height: 80),
            backingScale: 2.0
        )

        XCTAssertEqual(space.rawPixelSize, CuaDriverPixelSize(width: 200, height: 160))
        XCTAssertEqual(space.screenshotPixelSize, CuaDriverPixelSize(width: 200, height: 160))
        XCTAssertEqual(space.rawPixelToScreenshotPixel(CGPoint(x: 17, y: 29)), CGPoint(x: 17, y: 29))
    }

    func testDownscalesLongestSideToLimitAndMapsBackToGlobalPoints() {
        let space = cuaDriverCoordinateSpace(
            windowBounds: CuaDriverWindowBounds(x: 10, y: 20, width: 2000, height: 1000),
            backingScale: 1.0
        )

        XCTAssertEqual(space.screenshotPixelSize, CuaDriverPixelSize(width: 1568, height: 784))
        XCTAssertEqual(space.screenshotPixelToWindowPoint(CGPoint(x: 784, y: 392)), CGPoint(x: 1000, y: 500))
        XCTAssertEqual(space.screenshotPixelToGlobalPoint(CGPoint(x: 784, y: 392)), CGPoint(x: 1010, y: 520))
    }
}

final class CuaDriverFramingTests: XCTestCase {
    func testFrameRoundTrip() throws {
        let body = Data(#"{"verb":"status","args":{}}"#.utf8)
        let frame = try CuaDriverFraming.encode(body)

        var decoder = CuaDriverFraming.Decoder()
        try decoder.append(frame)

        XCTAssertEqual(try decoder.nextFrame(), body)
        XCTAssertNil(try decoder.nextFrame())
    }

    func testFrameDecoderHandlesPartialChunkedReads() throws {
        let first = Data(#"{"one":1}"#.utf8)
        let second = Data(#"{"two":2}"#.utf8)
        let combined = try CuaDriverFraming.encode(first) + CuaDriverFraming.encode(second)

        // Frame layout: 4-byte header + 9-byte body = 13 bytes per frame.
        var decoder = CuaDriverFraming.Decoder()
        for byte in combined.prefix(3) {
            try decoder.append(Data([byte]))
        }
        XCTAssertNil(try decoder.nextFrame())

        // 3 + 8 = 11 bytes buffered: header complete, body still 2 bytes short.
        try decoder.append(combined.dropFirst(3).prefix(8))
        XCTAssertNil(try decoder.nextFrame())

        // Completes frame one and delivers part of frame two's header.
        try decoder.append(combined.dropFirst(11).prefix(6))
        XCTAssertEqual(try decoder.nextFrame(), first)
        XCTAssertNil(try decoder.nextFrame())

        try decoder.append(combined.dropFirst(17))
        XCTAssertEqual(try decoder.nextFrame(), second)
        XCTAssertNil(try decoder.nextFrame())
    }

    func testFrameDecoderRejectsOversizePrefix() throws {
        let frame = frameWithPrefix(CuaDriverFraming.maximumFrameLength + 1)
        var decoder = CuaDriverFraming.Decoder()

        XCTAssertThrowsError(try decoder.append(frame)) { error in
            XCTAssertEqual(error as? CuaDriverFrameError, .frameTooLarge(CuaDriverFraming.maximumFrameLength + 1))
        }
    }

    func testFrameDecoderRejectsGarbagePrefixAsOversize() throws {
        let frame = Data([0xff, 0xff, 0xff, 0xff])
        var decoder = CuaDriverFraming.Decoder()

        XCTAssertThrowsError(try decoder.append(frame)) { error in
            XCTAssertEqual(error as? CuaDriverFrameError, .frameTooLarge(Int(UInt32.max)))
        }
    }

    private func frameWithPrefix(_ length: Int) -> Data {
        var bigEndian = UInt32(length).bigEndian
        return Data(bytes: &bigEndian, count: MemoryLayout<UInt32>.size)
    }
}

final class CuaDriverVerbTests: XCTestCase {
    func testCheckPermissionsGrantedCaseSerializationAvoidsDeniedRegexTerms() throws {
        let handler = CuaDriverVerbHandler(
            permissionChecker: StubPermissionChecker(status: .init(accessibility: true, screenRecording: true))
        )

        let response = handler.responseEnvelope(verb: "check_permissions", args: ["prompt": false])
        let output = try CuaDriverJSON.text(from: response).lowercased()

        XCTAssertFalse(output.contains("false"))
        XCTAssertFalse(output.contains("denied"))
        XCTAssertEqual(response["accessibility"] as? Bool, true)
        XCTAssertEqual(response["screen_recording"] as? Bool, true)
    }

    func testCheckPermissionsDeniedCaseSerializationContainsFalse() throws {
        let handler = CuaDriverVerbHandler(
            permissionChecker: StubPermissionChecker(status: .init(accessibility: false, screenRecording: true))
        )

        let output = try CuaDriverJSON.text(
            from: handler.responseEnvelope(verb: "check_permissions", args: ["prompt": false])
        ).lowercased()

        XCTAssertTrue(output.contains("false"))
    }

    func testErrorEnvelopeShape() {
        let response = CuaDriverVerbHandler.errorEnvelope(code: "bad", message: "Bad request")
        let error = response["error"] as? [String: Any]

        XCTAssertEqual(error?["code"] as? String, "bad")
        XCTAssertEqual(error?["message"] as? String, "Bad request")
    }

    func testUnknownVerbReturnsErrorEnvelope() {
        let response = CuaDriverVerbHandler().responseEnvelope(verb: "not_real", args: [:])
        let error = response["error"] as? [String: Any]

        XCTAssertEqual(error?["code"] as? String, "unknown_verb")
        XCTAssertEqual(error?["message"] as? String, "Unknown verb: not_real")
    }

    func testListWindowsAppliesPidFilterAndPreservesOnScreenFlag() throws {
        let handler = CuaDriverVerbHandler(
            windowProvider: StubWindowProvider(windows: [
                testWindow(windowID: 1, pid: 10, isOnScreen: false),
                testWindow(windowID: 2, pid: 20, isOnScreen: true),
            ])
        )

        let response = handler.responseEnvelope(verb: "list_windows", args: ["pid": 20])
        let windows = try XCTUnwrap(response["windows"] as? [[String: Any]])
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0]["window_id"] as? Int, 2)
        XCTAssertEqual(windows[0]["pid"] as? Int, 20)
        XCTAssertEqual(windows[0]["is_on_screen"] as? Bool, true)
    }

    func testScreenshotResolvesPidFromWindowIDAndDefaultsToJPEG() throws {
        let capturer = StubWindowCapturer()
        let handler = CuaDriverVerbHandler(
            windowProvider: StubWindowProvider(windows: [testWindow(windowID: 7, pid: 42)]),
            windowCapturer: capturer
        )

        let response = handler.responseEnvelope(verb: "screenshot", args: ["window_id": 7])

        XCTAssertEqual(capturer.capturedWindows.map(\.pid), [42])
        XCTAssertEqual(capturer.capturedFormats, [.jpeg])
        XCTAssertEqual(response["format"] as? String, "jpeg")
        XCTAssertEqual(response["width"] as? Int, 2)
        XCTAssertEqual(response["height"] as? Int, 1)
        XCTAssertEqual(response["capture_path"] as? String, "fake")
        XCTAssertEqual(response["image"] as? String, Data([0xff, 0xd8, 0xff]).base64EncodedString())
    }

    func testScreenshotUnknownWindowReturnsWindowNotFoundEnvelope() throws {
        let handler = CuaDriverVerbHandler(windowProvider: StubWindowProvider(windows: []))

        let response = handler.responseEnvelope(verb: "screenshot", args: ["window_id": 404])
        let error = try XCTUnwrap(response["error"] as? [String: Any])

        XCTAssertEqual(error["code"] as? String, "window_not_found")
    }

    func testScreenshotUsesRequestedPNGAndPlumbsBase64AndDimensions() throws {
        let capturer = StubWindowCapturer(
            screenshot: CuaDriverCapturedScreenshot(
                imageData: Data([0x89, 0x50, 0x4e, 0x47]),
                format: .png,
                width: 11,
                height: 12,
                capturePath: "cgwindowlist"
            )
        )
        let handler = CuaDriverVerbHandler(
            windowProvider: StubWindowProvider(windows: [testWindow(windowID: 8, pid: 50)]),
            windowCapturer: capturer
        )

        let response = handler.responseEnvelope(verb: "screenshot", args: ["window_id": 8, "format": "png"])

        XCTAssertEqual(capturer.capturedFormats, [.png])
        XCTAssertEqual(response["image"] as? String, Data([0x89, 0x50, 0x4e, 0x47]).base64EncodedString())
        XCTAssertEqual(response["format"] as? String, "png")
        XCTAssertEqual(response["width"] as? Int, 11)
        XCTAssertEqual(response["height"] as? Int, 12)
        XCTAssertEqual(response["capture_path"] as? String, "cgwindowlist")
    }

    func testGetWindowStateShapesResponseAndCachesElementsForAXPressClick() throws {
        let element = FakeCachedElement(id: "button")
        let clicker = FakeElementClicker()
        let handler = CuaDriverVerbHandler(
            windowProvider: StubWindowProvider(windows: [
                testWindow(windowID: 7, pid: 42, bounds: CuaDriverWindowBounds(x: 10, y: 20, width: 2000, height: 1000)),
            ]),
            backingScaleProvider: StubScaleProvider(scale: 1.0),
            axWindowResolver: FakeResolver(),
            windowStateRenderer: SequenceWindowStateRenderer(snapshots: [
                CuaDriverWindowStateSnapshot(
                    tree: "button Save [element_index 0]",
                    elements: [0: element]
                ),
            ]),
            elementClicker: clicker
        )

        let state = handler.responseEnvelope(verb: "get_window_state", args: ["pid": 42, "window_id": 7])
        XCTAssertEqual(state["tree"] as? String, "button Save [element_index 0]")
        XCTAssertEqual(state["screenshot_width"] as? Int, 1568)
        XCTAssertEqual(state["screenshot_height"] as? Int, 784)
        XCTAssertEqual(state["window_id"] as? Int, 7)
        XCTAssertEqual(state["pid"] as? Int, 42)
        XCTAssertEqual(state["title"] as? String, "Resolved")
        XCTAssertEqual(state["app_name"] as? String, "Example")

        let click = handler.responseEnvelope(verb: "click", args: ["pid": 42, "window_id": 7, "element_index": 0])
        XCTAssertEqual(click["clicked"] as? Bool, true)
        XCTAssertEqual(click["method"] as? String, "ax_press")
        XCTAssertEqual(clicker.pressedIDs, ["button"])
    }

    func testElementCacheReplacesOnRefreshAndReturnsStaleIndexError() throws {
        let clicker = FakeElementClicker()
        let handler = CuaDriverVerbHandler(
            windowProvider: StubWindowProvider(windows: [testWindow(windowID: 7, pid: 42)]),
            axWindowResolver: FakeResolver(),
            windowStateRenderer: SequenceWindowStateRenderer(snapshots: [
                CuaDriverWindowStateSnapshot(tree: "button Old [element_index 1]", elements: [1: FakeCachedElement(id: "old")]),
                CuaDriverWindowStateSnapshot(tree: "button New [element_index 2]", elements: [2: FakeCachedElement(id: "new")]),
            ]),
            elementClicker: clicker
        )

        _ = handler.responseEnvelope(verb: "get_window_state", args: ["pid": 42, "window_id": 7])
        _ = handler.responseEnvelope(verb: "get_window_state", args: ["pid": 42, "window_id": 7])

        let stale = handler.responseEnvelope(verb: "click", args: ["pid": 42, "window_id": 7, "element_index": 1])
        let staleError = try XCTUnwrap(stale["error"] as? [String: Any])
        XCTAssertEqual(staleError["code"] as? String, "stale_element_index")
        XCTAssertEqual(staleError["message"] as? String, "element_index 1 not found; call get_window_state again")

        let fresh = handler.responseEnvelope(verb: "click", args: ["pid": 42, "window_id": 7, "element_index": 2])
        XCTAssertEqual(fresh["clicked"] as? Bool, true)
        XCTAssertEqual(clicker.pressedIDs, ["new"])
    }

    func testElementCacheIsIsolatedByPidAndWindowID() {
        let cache = CuaDriverElementCache()
        let first = FakeCachedElement(id: "first")
        let second = FakeCachedElement(id: "second")

        cache.replace(pid: 10, windowID: 1, elements: [0: first])
        cache.replace(pid: 10, windowID: 2, elements: [0: second])

        XCTAssertEqual((cache.element(pid: 10, windowID: 1, index: 0) as? FakeCachedElement)?.id, "first")
        XCTAssertEqual((cache.element(pid: 10, windowID: 2, index: 0) as? FakeCachedElement)?.id, "second")
        XCTAssertNil(cache.element(pid: 11, windowID: 1, index: 0))
    }

    func testClickCoordinateMapsPNGSpaceToWindowGlobalPoint() throws {
        let clicker = FakeCoordinateClicker()
        let handler = CuaDriverVerbHandler(
            windowProvider: StubWindowProvider(windows: [
                testWindow(windowID: 7, pid: 42, bounds: CuaDriverWindowBounds(x: 10, y: 20, width: 100, height: 50)),
            ]),
            backingScaleProvider: StubScaleProvider(scale: 2.0),
            coordinateClicker: clicker
        )

        let response = handler.responseEnvelope(
            verb: "click",
            args: ["pid": 42, "window_id": 7, "x": 100, "y": 50, "button": "right", "click_count": 2]
        )

        XCTAssertEqual(response["clicked"] as? Bool, true)
        XCTAssertEqual(response["method"] as? String, "coordinate")
        XCTAssertEqual(clicker.requests.map(\.pid), [42])
        XCTAssertEqual(clicker.requests.map(\.button), [.right])
        XCTAssertEqual(clicker.requests.map(\.clickCount), [2])
        XCTAssertEqual(clicker.requests.first?.point, CGPoint(x: 60, y: 45))
    }

    func testClickValidationMatrixAndElementIndexPrecedence() throws {
        let cache = CuaDriverElementCache()
        let element = FakeCachedElement(id: "wins")
        cache.replace(pid: 42, windowID: 7, elements: [3: element])
        let elementClicker = FakeElementClicker()
        let coordinateClicker = FakeCoordinateClicker()
        let handler = CuaDriverVerbHandler(
            windowProvider: StubWindowProvider(windows: [testWindow(windowID: 7, pid: 42)]),
            elementCache: cache,
            elementClicker: elementClicker,
            coordinateClicker: coordinateClicker
        )

        let missingPid = handler.responseEnvelope(verb: "click", args: ["window_id": 7, "x": 1, "y": 2])
        XCTAssertEqual((missingPid["error"] as? [String: Any])?["code"] as? String, "invalid_request")

        let missingWindow = handler.responseEnvelope(verb: "click", args: ["pid": 42, "x": 1, "y": 2])
        XCTAssertEqual((missingWindow["error"] as? [String: Any])?["code"] as? String, "invalid_request")

        let missingTarget = handler.responseEnvelope(verb: "click", args: ["pid": 42, "window_id": 7, "x": 1])
        XCTAssertEqual((missingTarget["error"] as? [String: Any])?["code"] as? String, "invalid_request")

        let invalidButton = handler.responseEnvelope(verb: "click", args: ["pid": 42, "window_id": 7, "x": 1, "y": 2, "button": "middle"])
        XCTAssertEqual((invalidButton["error"] as? [String: Any])?["code"] as? String, "invalid_request")
        XCTAssertEqual((invalidButton["error"] as? [String: Any])?["message"] as? String, "button must be 'left' or 'right'")

        let elementWins = handler.responseEnvelope(
            verb: "click",
            args: ["pid": 42, "window_id": 7, "element_index": 3, "x": 1, "y": 2, "button": "middle"]
        )
        XCTAssertEqual(elementWins["clicked"] as? Bool, true)
        XCTAssertEqual(elementWins["method"] as? String, "ax_press")
        XCTAssertEqual(elementClicker.pressedIDs, ["wins"])
        XCTAssertTrue(coordinateClicker.requests.isEmpty)
    }

    func testSystemScreenshotCaptureSkipsWithoutScreenRecordingPermission() throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw XCTSkip("Screen Recording permission is not granted")
        }

        let provider = SystemCuaDriverWindowProvider()
        guard let window = provider.listWindows(pid: nil).first(where: { $0.isOnScreen }) else {
            throw XCTSkip("No on-screen windows available to capture")
        }

        let screenshot = try SystemCuaDriverWindowCapturer().capture(window: window, format: .jpeg)
        XCTAssertFalse(screenshot.imageData.isEmpty)
        XCTAssertEqual(screenshot.format, .jpeg)
        XCTAssertGreaterThan(screenshot.width, 0)
        XCTAssertGreaterThan(screenshot.height, 0)
        XCTAssertNotNil(CGImageSourceCreateWithData(screenshot.imageData as CFData, nil))
    }

    func testSystemAXWindowStateSmokeSkipsWithoutTrustedAccessibility() throws {
        guard AXIsProcessTrusted() else {
            throw XCTSkip("Accessibility permission is not granted")
        }

        let provider = SystemCuaDriverWindowProvider()
        let resolver = SystemCuaDriverAXWindowResolver()
        let renderer = SystemCuaDriverWindowStateRenderer()
        let windows = provider.listWindows(pid: nil).filter(\.isOnScreen)

        for window in windows.prefix(20) {
            do {
                let resolved = try resolver.resolveWindow(pid: window.pid, windowID: window.windowID, windowInfo: window)
                let snapshot = try renderer.render(window: resolved, windowInfo: window)
                if !snapshot.tree.isEmpty {
                    XCTAssertTrue(snapshot.tree.contains("window") || !snapshot.elements.isEmpty)
                    return
                }
            } catch {
                continue
            }
        }

        throw XCTSkip("No AX-resolvable on-screen window was available")
    }

    private struct StubPermissionChecker: CuaDriverPermissionChecking {
        let status: CuaDriverPermissionStatus

        func checkPermissions(prompt: Bool) -> CuaDriverPermissionStatus {
            status
        }
    }

    private struct StubWindowProvider: CuaDriverWindowProviding {
        let windows: [CuaDriverWindowInfo]

        func listWindows(pid: Int?) -> [CuaDriverWindowInfo] {
            windows.filter { pid == nil || $0.pid == pid }
        }

        func window(windowID: Int, pid: Int?) -> CuaDriverWindowInfo? {
            listWindows(pid: pid).first { $0.windowID == windowID }
        }
    }

    private final class StubWindowCapturer: CuaDriverWindowCapturing, @unchecked Sendable {
        private let screenshot: CuaDriverCapturedScreenshot
        var capturedWindows: [CuaDriverWindowInfo] = []
        var capturedFormats: [CuaDriverScreenshotFormat] = []

        init(
            screenshot: CuaDriverCapturedScreenshot = CuaDriverCapturedScreenshot(
                imageData: Data([0xff, 0xd8, 0xff]),
                format: .jpeg,
                width: 2,
                height: 1,
                capturePath: "fake"
            )
        ) {
            self.screenshot = screenshot
        }

        func capture(window: CuaDriverWindowInfo, format: CuaDriverScreenshotFormat) throws -> CuaDriverCapturedScreenshot {
            capturedWindows.append(window)
            capturedFormats.append(format)
            return screenshot
        }
    }

    private struct StubScaleProvider: CuaDriverBackingScaleProviding {
        let scale: CGFloat

        func backingScale(for bounds: CuaDriverWindowBounds) -> CGFloat {
            scale
        }
    }

    private final class FakeResolvedWindow: CuaDriverResolvedWindow, @unchecked Sendable {
        let pid: Int
        let windowID: Int
        let title: String?
        let appName: String?

        init(pid: Int, windowID: Int, title: String? = "Resolved", appName: String? = "Example") {
            self.pid = pid
            self.windowID = windowID
            self.title = title
            self.appName = appName
        }
    }

    private struct FakeResolver: CuaDriverAXWindowResolving {
        func resolveWindow(pid: Int, windowID: Int, windowInfo: CuaDriverWindowInfo) throws -> any CuaDriverResolvedWindow {
            FakeResolvedWindow(pid: pid, windowID: windowID)
        }
    }

    private final class FakeCachedElement: CuaDriverCachedElement, @unchecked Sendable {
        let id: String

        init(id: String) {
            self.id = id
        }
    }

    private final class SequenceWindowStateRenderer: CuaDriverWindowStateRendering, @unchecked Sendable {
        private var snapshots: [CuaDriverWindowStateSnapshot]

        init(snapshots: [CuaDriverWindowStateSnapshot]) {
            self.snapshots = snapshots
        }

        func render(window: any CuaDriverResolvedWindow, windowInfo: CuaDriverWindowInfo) throws -> CuaDriverWindowStateSnapshot {
            if snapshots.count > 1 {
                return snapshots.removeFirst()
            }
            return snapshots.first ?? CuaDriverWindowStateSnapshot(tree: "", elements: [:])
        }
    }

    private final class FakeElementClicker: CuaDriverElementClicking, @unchecked Sendable {
        private(set) var pressedIDs: [String] = []

        func press(_ element: any CuaDriverCachedElement) throws {
            pressedIDs.append((element as? FakeCachedElement)?.id ?? "unknown")
        }
    }

    private struct CoordinateClickRequest: Equatable {
        let pid: Int
        let point: CGPoint
        let button: CuaDriverMouseButton
        let clickCount: Int
    }

    private final class FakeCoordinateClicker: CuaDriverCoordinateClicking, @unchecked Sendable {
        private(set) var requests: [CoordinateClickRequest] = []

        func click(pid: Int, point: CGPoint, button: CuaDriverMouseButton, clickCount: Int) throws {
            requests.append(CoordinateClickRequest(pid: pid, point: point, button: button, clickCount: clickCount))
        }
    }

    private func testWindow(
        windowID: Int,
        pid: Int,
        isOnScreen: Bool = true,
        bounds: CuaDriverWindowBounds = CuaDriverWindowBounds(x: 1, y: 2, width: 100, height: 80)
    ) -> CuaDriverWindowInfo {
        CuaDriverWindowInfo(
            windowID: windowID,
            pid: pid,
            appName: "Example",
            title: "Window \(windowID)",
            bounds: bounds,
            isOnScreen: isOnScreen
        )
    }
}

final class CuaDriverLifecycleIntegrationTests: XCTestCase {
    func testSocketLifecycleAgainstBuiltBinary() throws {
        let binary = try cuaDriverBinaryURL()
        // Keep this path SHORT: unix sun_path caps at ~104 bytes and CI's
        // NSTemporaryDirectory() alone can exceed it.
        let tempDirectory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cua-t-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let socketURL = tempDirectory.appendingPathComponent("cua-driver.sock")
        let pidURL = tempDirectory.appendingPathComponent("cua-driver.pid")
        try Data("stale".utf8).write(to: socketURL)

        let server = Process()
        server.executableURL = binary
        server.arguments = ["serve", "--no-relaunch", "--socket", socketURL.path]
        server.standardOutput = Pipe()
        server.standardError = Pipe()

        do {
            try server.run()
        } catch {
            throw XCTSkip("Unable to spawn cua-driver in this environment: \(error.localizedDescription)")
        }
        defer {
            if server.isRunning {
                server.terminate()
                _ = waitForExit(server, timeout: 5)
            }
        }

        XCTAssertTrue(waitForPath(socketURL.path, timeout: 5), "server did not create socket")
        // Pid file is written just after the socket binds — wait, don't poll once.
        XCTAssertTrue(waitForPath(pidURL.path, timeout: 5), "server did not create default pid file")

        let status = try runBinary(binary, arguments: ["status", "--socket", socketURL.path])
        XCTAssertEqual(status.exitCode, 0, status.stderr)

        let duplicate = Process()
        duplicate.executableURL = binary
        duplicate.arguments = ["serve", "--no-relaunch", "--socket", socketURL.path]
        duplicate.standardOutput = Pipe()
        duplicate.standardError = Pipe()
        try duplicate.run()
        XCTAssertTrue(waitForExit(duplicate, timeout: 5), "second server did not exit")
        XCTAssertEqual(duplicate.terminationStatus, 11)

        let callStatus = try runBinary(binary, arguments: ["call", "status", "--socket", socketURL.path])
        XCTAssertEqual(callStatus.exitCode, 0, callStatus.stderr)
        let statusObject = try CuaDriverJSON.object(from: Data(callStatus.stdout.utf8))
        XCTAssertEqual(statusObject["status"] as? String, "running")
        XCTAssertEqual(statusObject["version"] as? String, CuaDriverConstants.version)
        XCTAssertNotNil(statusObject["pid"])

        if CGPreflightScreenCaptureAccess() {
            try runScreenshotSmoke(binary: binary, socketPath: socketURL.path, directory: tempDirectory)
        }

        server.terminate()
        XCTAssertTrue(waitForExit(server, timeout: 5), "server did not exit after SIGTERM")
        XCTAssertEqual(server.terminationStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path), "socket was not removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidURL.path), "pid file was not removed")

        let downStatus = try runBinary(binary, arguments: ["status", "--socket", socketURL.path])
        XCTAssertNotEqual(downStatus.exitCode, 0)
    }

    private func runScreenshotSmoke(binary: URL, socketPath: String, directory: URL) throws {
        let listWindows = try runBinary(binary, arguments: ["call", "list_windows", "{}", "--socket", socketPath])
        XCTAssertEqual(listWindows.exitCode, 0, listWindows.stderr)

        let listObject = try CuaDriverJSON.object(from: Data(listWindows.stdout.utf8))
        let windows = try XCTUnwrap(listObject["windows"] as? [[String: Any]])
        guard let window = windows.first(where: { $0["is_on_screen"] as? Bool == true }),
              let windowID = window["window_id"] as? Int
        else {
            throw XCTSkip("No on-screen windows available to capture")
        }

        let outputURL = directory.appendingPathComponent("m1.jpg")
        let screenshot = try runBinary(
            binary,
            arguments: [
                "call",
                "screenshot",
                #"{"window_id":\#(windowID),"format":"jpeg"}"#,
                "--socket",
                socketPath,
                "--screenshot-out-file",
                outputURL.path,
            ]
        )
        XCTAssertEqual(screenshot.exitCode, 0, screenshot.stderr)
        let imageData = try Data(contentsOf: outputURL)
        XCTAssertFalse(imageData.isEmpty)
        XCTAssertNotNil(CGImageSourceCreateWithData(imageData as CFData, nil))

        let response = try CuaDriverJSON.object(from: Data(screenshot.stdout.utf8))
        XCTAssertEqual(response["format"] as? String, "jpeg")
        XCTAssertGreaterThan(response["width"] as? Int ?? 0, 0)
        XCTAssertGreaterThan(response["height"] as? Int ?? 0, 0)
    }

    private func cuaDriverBinaryURL() throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let directCandidates = [
            root.appendingPathComponent(".build/debug/cua-driver"),
            root.appendingPathComponent(".build/arm64-apple-macosx/debug/cua-driver"),
            root.appendingPathComponent(".build/x86_64-apple-macosx/debug/cua-driver"),
        ]

        for candidate in directCandidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }

        let buildURL = root.appendingPathComponent(".build")
        if let enumerator = FileManager.default.enumerator(at: buildURL, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator where url.lastPathComponent == "cua-driver" {
                if FileManager.default.isExecutableFile(atPath: url.path) {
                    return url
                }
            }
        }

        throw XCTSkip("cua-driver binary not found; run `swift build --product cua-driver` before lifecycle tests")
    }

    private func runBinary(_ binary: URL, arguments: [String]) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = binary
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        return (
            process.terminationStatus,
            String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }

    private func waitForPath(_ path: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    private func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !process.isRunning {
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return !process.isRunning
    }
}
