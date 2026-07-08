import Darwin
import Foundation
import XCTest
@testable import OpenComputerUseKit

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

    private struct StubPermissionChecker: CuaDriverPermissionChecking {
        let status: CuaDriverPermissionStatus

        func checkPermissions(prompt: Bool) -> CuaDriverPermissionStatus {
            status
        }
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

        server.terminate()
        XCTAssertTrue(waitForExit(server, timeout: 5), "server did not exit after SIGTERM")
        XCTAssertEqual(server.terminationStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path), "socket was not removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidURL.path), "pid file was not removed")

        let downStatus = try runBinary(binary, arguments: ["status", "--socket", socketURL.path])
        XCTAssertNotEqual(downStatus.exitCode, 0)
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
