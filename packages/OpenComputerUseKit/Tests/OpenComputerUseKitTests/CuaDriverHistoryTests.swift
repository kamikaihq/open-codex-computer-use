import Foundation
import XCTest
@testable import OpenComputerUseKit

/// File-backed key store fake so tests never touch the real credential store.
private final class FileHistoryKeyStore: HistoryKeyStoring, @unchecked Sendable {
    let keyURL: URL
    var loadError: HistoryCryptoError?
    var destroyError: HistoryCryptoError?

    init(directory: URL) {
        self.keyURL = directory.appendingPathComponent("test-root-key.bin")
    }

    var keyReference: String {
        "test:history-root-key"
    }

    func loadRootKey() throws -> Data? {
        if let loadError {
            throw loadError
        }
        guard FileManager.default.fileExists(atPath: keyURL.path) else {
            return nil
        }
        return try Data(contentsOf: keyURL)
    }

    func createRootKey() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0...255)
        }
        let key = Data(bytes)
        try key.write(to: keyURL)
        return key
    }

    func destroyRootKey() throws {
        if let destroyError {
            throw destroyError
        }
        try? FileManager.default.removeItem(at: keyURL)
    }
}

final class CuaDriverHistoryTests: XCTestCase {
    private var root: URL!
    private var keyDirectory: URL!
    private var keyStore: FileHistoryKeyStore!

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cua-history-tests-\(UUID().uuidString)")
        root = base.appendingPathComponent("store")
        keyDirectory = base.appendingPathComponent("keys")
        try FileManager.default.createDirectory(at: keyDirectory, withIntermediateDirectories: true)
        keyStore = FileHistoryKeyStore(directory: keyDirectory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    private func makeService(now: @escaping () -> Date = Date.init) -> HistoryService {
        HistoryService(rootURL: root, keyStore: keyStore, now: now)
    }

    private func enable(_ service: HistoryService) throws {
        let response = service.enableResponse()
        XCTAssertNil(response["error"], "enable failed: \(response)")
        XCTAssertEqual(response["enabled"] as? Bool, true)
    }

    private func queryEvents(_ service: HistoryService, args: [String: Any] = [:]) throws -> [[String: Any]] {
        let response = service.queryResponse(args: args)
        XCTAssertNil(response["error"], "query failed: \(response)")
        XCTAssertEqual(response["metadata_only"] as? Bool, true)
        XCTAssertEqual(response["model_context_disclosure"] as? Bool, true)
        return response["events"] as? [[String: Any]] ?? []
    }

    private func chunkFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "cborseq" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: Lifecycle

    func testHistoryIsOffByDefaultAndRecordsNothing() {
        let service = makeService()
        let status = service.statusResponse()
        XCTAssertEqual(status["enabled"] as? Bool, false)
        XCTAssertEqual(status["health"] as? String, "disabled")
        XCTAssertFalse(service.isCapturing)

        service.recordActionStarted(actionID: service.makeActionID(), capability: "computer.pointer.click", pid: nil)
        service.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testEnableVerifiesRoundTripAndReportsReady() throws {
        let service = makeService()
        let response = service.enableResponse()
        XCTAssertNil(response["error"])
        XCTAssertEqual(response["enabled"] as? Bool, true)
        XCTAssertEqual(response["paused"] as? Bool, false)
        XCTAssertEqual(response["health"] as? String, "ready")
        XCTAssertEqual(
            response["profile"] as? String,
            "cua-history-profile-v1/cbor-sequence+cose-encrypt0+cloudevents-json"
        )
        XCTAssertTrue(service.isCapturing)
    }

    func testCaptureRoundTripReturnsMetadataOnlyEventsInAscendingOrder() throws {
        let service = makeService()
        try enable(service)

        let actionID = service.makeActionID()
        service.recordActionStarted(actionID: actionID, capability: "computer.pointer.click", pid: nil)
        service.recordActionCompleted(
            actionID: actionID,
            capability: "computer.pointer.click",
            pid: nil,
            effect: "confirmed",
            route: "accessibility"
        )
        service.flush()

        let events = try queryEvents(service)
        XCTAssertEqual(events.count, 3) // enable control + started + completed

        let sequences = events.compactMap { ($0["data"] as? [String: Any])?["sequence"] as? Int }
        XCTAssertEqual(sequences, sequences.sorted())

        let completed = events.last!
        XCTAssertEqual(completed["type"] as? String, "cua-driver.history.action_completed.v0")
        XCTAssertEqual(completed["dataschema"] as? String, "urn:cua-driver:schema:history-event:v0")
        let data = completed["data"] as? [String: Any]
        XCTAssertEqual(data?["capability"] as? String, "computer.pointer.click")
        XCTAssertEqual(data?["platform"] as? String, "macos")
        let payload = data?["payload"] as? [String: Any]
        XCTAssertEqual(payload?["kind"] as? String, "action_completed")
        XCTAssertEqual(payload?["effect"] as? String, "confirmed")
        XCTAssertEqual(payload?["route"] as? String, "accessibility")

        // Strictly metadata-only: no free-form or excluded fields.
        for event in events {
            let eventData = event["data"] as? [String: Any]
            XCTAssertNil(eventData?["text"])
            XCTAssertNil(eventData?["coordinates"])
            XCTAssertNil(eventData?["arguments"])
        }
    }

    func testPauseStopsCaptureAndResumeRestartsIt() throws {
        let service = makeService()
        try enable(service)

        XCTAssertNil(service.lifecycleResponse(operation: "pause")["error"])
        XCTAssertFalse(service.isCapturing)
        service.recordActionStarted(actionID: service.makeActionID(), capability: "computer.keyboard.press", pid: nil)
        service.flush()

        XCTAssertNil(service.lifecycleResponse(operation: "resume")["error"])
        XCTAssertTrue(service.isCapturing)

        let events = try queryEvents(service)
        // enable + pause control + resume control; the paused action is absent.
        let kinds = events.compactMap {
            (($0["data"] as? [String: Any])?["payload"] as? [String: Any])?["kind"] as? String
        }
        XCTAssertFalse(kinds.contains("action_started"))
    }

    func testDisabledLifecycleVerbsRequireEnable() {
        let service = makeService()
        let pause = service.lifecycleResponse(operation: "pause")
        XCTAssertEqual((pause["error"] as? [String: Any])?["code"] as? String, "history_not_enabled")
    }

    func testDeleteRequiresConfirmationThenDestroysKeyAndFiles() throws {
        let service = makeService()
        try enable(service)
        service.flush()
        XCTAssertFalse(try chunkFiles().isEmpty)

        let refused = service.deleteResponse(args: [:])
        XCTAssertEqual(
            (refused["error"] as? [String: Any])?["code"] as? String,
            "history_confirmation_required"
        )

        let deleted = service.deleteResponse(args: ["confirm": true])
        XCTAssertEqual(deleted["deleted"] as? Bool, true)
        XCTAssertNil(try keyStore.loadRootKey())
        XCTAssertTrue(try chunkFiles().isEmpty)
        XCTAssertEqual(service.statusResponse()["enabled"] as? Bool, false)
    }

    func testDeleteFailsClosedWhenKeyDestructionFails() throws {
        let service = makeService()
        try enable(service)
        service.flush()

        keyStore.destroyError = .keyDestroyFailed("simulated")
        let response = service.deleteResponse(args: ["confirm": true])
        XCTAssertEqual(
            (response["error"] as? [String: Any])?["code"] as? String,
            "history_key_destroy_failed"
        )
        // Files must remain until key destruction succeeds.
        XCTAssertFalse(try chunkFiles().isEmpty)
    }

    // MARK: Query contract

    func testQueryRejectsUnknownFieldsAndInvalidBounds() throws {
        let service = makeService()
        try enable(service)

        for badArgs: [String: Any] in [
            ["unexpected": true],
            ["limit": 0],
            ["limit": 201],
            ["since_sequence": 0],
            ["since_sequence": 9, "until_sequence": 3],
        ] {
            let response = service.queryResponse(args: badArgs)
            XCTAssertEqual(
                (response["error"] as? [String: Any])?["code"] as? String,
                "invalid_request",
                "expected rejection for \(badArgs)"
            )
        }
    }

    func testQueryReturnsNewestLimitSliceAscendingAndPagesBySequence() throws {
        let service = makeService()
        try enable(service)
        for _ in 0..<10 {
            let actionID = service.makeActionID()
            service.recordActionStarted(actionID: actionID, capability: "computer.pointer.click", pid: nil)
        }
        service.flush()

        let all = try queryEvents(service, args: ["limit": 200])
        let allSequences = all.compactMap { ($0["data"] as? [String: Any])?["sequence"] as? Int }
        XCTAssertEqual(allSequences.count, 11) // enable control + 10 actions

        // Reads themselves append an access record, so every window in this test
        // is pinned with an explicit upper bound rather than "whatever is newest".
        let newest = try queryEvents(service, args: ["limit": 3, "until_sequence": allSequences.last!])
        let newestSequences = newest.compactMap { ($0["data"] as? [String: Any])?["sequence"] as? Int }
        XCTAssertEqual(newestSequences, Array(allSequences.suffix(3)))

        // Page toward older records below the current first sequence.
        let older = try queryEvents(service, args: [
            "limit": 3,
            "until_sequence": newestSequences.first! - 1,
        ])
        let olderSequences = older.compactMap { ($0["data"] as? [String: Any])?["sequence"] as? Int }
        XCTAssertEqual(olderSequences, Array(allSequences.dropLast(3).suffix(3)))
    }

    func testQueryFiltersBySessionIdentifier() throws {
        let service = makeService()
        try enable(service)
        service.recordActionStarted(actionID: service.makeActionID(), capability: "computer.pointer.click", pid: nil)
        service.flush()

        let events = try queryEvents(service)
        let sessionID = (events.first?["data"] as? [String: Any])?["session_id"] as? String
        XCTAssertNotNil(sessionID)
        XCTAssertEqual(sessionID?.count, 32)

        let bound = (events.last?["data"] as? [String: Any])?["sequence"] as? Int ?? 0
        let matched = try queryEvents(service, args: ["session_id": sessionID!, "until_sequence": bound])
        XCTAssertEqual(matched.count, events.count)

        let unmatched = try queryEvents(service, args: ["session_id": String(repeating: "0", count: 32)])
        XCTAssertTrue(unmatched.isEmpty)
    }

    func testNonEmptyQueryAppendsEncryptedAccessRecord() throws {
        let service = makeService()
        try enable(service)
        service.flush()

        _ = try queryEvents(service) // returns the enable control event
        service.flush()

        let afterAccess = try queryEvents(service, args: ["limit": 200])
        let kinds = afterAccess.compactMap {
            (($0["data"] as? [String: Any])?["payload"] as? [String: Any])?["kind"] as? String
        }
        XCTAssertTrue(kinds.contains("access"), "expected an access audit event, got \(kinds)")
    }

    func testRetentionCutoffHidesEventsOlderThanSevenDays() throws {
        var currentDate = Date(timeIntervalSince1970: 1_700_000_000)
        let service = makeService(now: { currentDate })
        try enable(service)
        service.recordActionStarted(actionID: service.makeActionID(), capability: "computer.pointer.drag", pid: nil)
        service.flush()
        XCTAssertEqual(try queryEvents(service, args: ["limit": 200]).count, 2)

        currentDate = currentDate.addingTimeInterval(8 * 24 * 60 * 60)
        XCTAssertTrue(try queryEvents(service, args: ["limit": 200]).isEmpty)
    }

    func testSequenceContinuesAcrossWriterRestart() throws {
        let first = makeService()
        try enable(first)
        first.recordActionStarted(actionID: first.makeActionID(), capability: "computer.pointer.click", pid: nil)
        first.flush()

        // New writer instance: seals prior chunks and continues the stream. The
        // stream is only read at the end, because a read appends its own record.
        let second = makeService()
        XCTAssertEqual(second.statusResponse()["enabled"] as? Bool, true)
        second.recordActionStarted(actionID: second.makeActionID(), capability: "computer.pointer.click", pid: nil)
        second.flush()

        let events = try queryEvents(second, args: ["limit": 200])
        let sequences = events.compactMap { ($0["data"] as? [String: Any])?["sequence"] as? Int }
        XCTAssertEqual(sequences, sequences.sorted())
        // enable control + one action per writer, numbered continuously: the
        // second writer must not restart the sequence at 1.
        XCTAssertEqual(sequences, [1, 2, 3])
        XCTAssertEqual(Set(sequences).count, sequences.count, "stream sequences must not repeat")

        // Restart created a fresh chunk: at least two chunk files exist.
        XCTAssertGreaterThanOrEqual(try chunkFiles().count, 2)

        // Both writers share one stream identity in their chunk headers.
        let streamIDs = Set(try chunkFiles().map { url -> String in
            var decoder = HistoryCBOR.Decoder(try Data(contentsOf: url))
            guard case let .array(fields) = try decoder.decodeItem(),
                  case let .textString(streamID) = fields[4] else {
                XCTFail("malformed header in \(url.lastPathComponent)")
                return ""
            }
            return streamID
        })
        XCTAssertEqual(streamIDs.count, 1)
    }

    // MARK: Fail-closed storage validation

    func testWrongKeyRefusesTheStore() throws {
        let service = makeService()
        try enable(service)
        service.flush()

        try keyStore.destroyRootKey()
        _ = try keyStore.createRootKey() // different key material

        let reader = makeService()
        let response = reader.queryResponse(args: [:])
        XCTAssertEqual(
            (response["error"] as? [String: Any])?["code"] as? String,
            "history_storage_corrupt"
        )
    }

    func testTamperedCiphertextRefusesTheStore() throws {
        let service = makeService()
        try enable(service)
        service.flush()

        let chunk = try chunkFiles()[0]
        var bytes = try Data(contentsOf: chunk)
        bytes[bytes.count - 1] ^= 0xFF
        try bytes.write(to: chunk)

        let response = makeService().queryResponse(args: [:])
        XCTAssertEqual(
            (response["error"] as? [String: Any])?["code"] as? String,
            "history_storage_corrupt"
        )
    }

    func testTamperedHeaderBreaksAuthenticationOfEveryRecord() throws {
        let service = makeService()
        try enable(service)
        service.flush()

        let chunk = try chunkFiles()[0]
        var bytes = try Data(contentsOf: chunk)
        // The 4-byte nonce prefix is the final header field; flip a bit inside
        // the header region (byte 6 sits inside the profile/epoch fields).
        bytes[6] ^= 0x01
        try bytes.write(to: chunk)

        let response = makeService().queryResponse(args: [:])
        XCTAssertEqual(
            (response["error"] as? [String: Any])?["code"] as? String,
            "history_storage_corrupt"
        )
    }

    func testReorderedRecordsAreRefusedByNoncePositionBinding() throws {
        let service = makeService()
        try enable(service)
        service.recordActionStarted(actionID: service.makeActionID(), capability: "computer.pointer.click", pid: nil)
        service.flush()

        let chunk = try chunkFiles()[0]
        let bytes = try Data(contentsOf: chunk)
        var decoder = HistoryCBOR.Decoder(bytes)
        let headerStart = decoder.offset
        _ = try decoder.decodeItem()
        let headerEnd = decoder.offset
        var recordRanges: [Range<Int>] = []
        while !decoder.isAtEnd {
            let start = decoder.offset
            _ = try decoder.decodeItem()
            recordRanges.append(start..<decoder.offset)
        }
        XCTAssertGreaterThanOrEqual(recordRanges.count, 2)

        var swapped = bytes.subdata(in: headerStart..<headerEnd)
        swapped.append(bytes.subdata(in: recordRanges[1]))
        swapped.append(bytes.subdata(in: recordRanges[0]))
        for range in recordRanges.dropFirst(2) {
            swapped.append(bytes.subdata(in: range))
        }
        try swapped.write(to: chunk)

        let response = makeService().queryResponse(args: [:])
        XCTAssertEqual(
            (response["error"] as? [String: Any])?["code"] as? String,
            "history_storage_corrupt"
        )
    }

    func testTruncatedFinalRecordIsRefused() throws {
        let service = makeService()
        try enable(service)
        service.flush()

        let chunk = try chunkFiles()[0]
        let bytes = try Data(contentsOf: chunk)
        try bytes.dropLast(5).write(to: chunk)

        let response = makeService().queryResponse(args: [:])
        XCTAssertEqual(
            (response["error"] as? [String: Any])?["code"] as? String,
            "history_storage_corrupt"
        )
    }

    func testKeyUnavailableFailsClosedWithoutPlaintextFallback() throws {
        let service = makeService()
        try enable(service)
        service.flush()

        keyStore.loadError = .keyUnavailable("credential store is locked")
        let reader = makeService()
        let response = reader.queryResponse(args: [:])
        XCTAssertEqual(
            (response["error"] as? [String: Any])?["code"] as? String,
            "history_key_unavailable"
        )
        // No plaintext exists on disk: every stored byte outside the plaintext
        // header and state file is COSE ciphertext.
        for url in try chunkFiles() {
            let raw = try Data(contentsOf: url)
            XCTAssertNil(String(data: raw, encoding: .utf8)?.range(of: "cua-driver.history"))
        }
    }

    // MARK: Verb handler integration

    func testVerbHandlerServesHistoryVerbsAndRecordsFailedActions() throws {
        let service = makeService()
        let handler = CuaDriverVerbHandler(
            windowProvider: EmptyWindowProvider(),
            historyService: service
        )

        let status = handler.responseEnvelope(verb: "history_status", args: [:])
        XCTAssertEqual(status["enabled"] as? Bool, false)

        try enable(service)

        // A click against a missing window fails; history records the failure
        // without affecting the error envelope.
        let click = handler.responseEnvelope(
            verb: "click",
            args: ["pid": 1, "window_id": 999, "x": 1, "y": 1]
        )
        XCTAssertNotNil(click["error"])
        service.flush()

        let query = handler.responseEnvelope(verb: "history_query", args: ["limit": 200])
        let events = query["events"] as? [[String: Any]] ?? []
        let payloads = events.compactMap {
            ($0["data"] as? [String: Any])?["payload"] as? [String: Any]
        }
        let completed: [String: Any] = payloads.first { payload in
            (payload["kind"] as? String) == "action_completed"
        } ?? [:]
        let effect = completed["effect"] as? String
        XCTAssertEqual(effect, "failed")

        let unknown = handler.responseEnvelope(verb: "history_query", args: ["nope": 1])
        XCTAssertEqual((unknown["error"] as? [String: Any])?["code"] as? String, "invalid_request")
    }

    // MARK: Profile primitives

    func testChunkKeyDerivationMatchesProfileConstruction() throws {
        let rootKey = Data(repeating: 0xAB, count: 32)
        let chunkID = String(repeating: "0f", count: 16)
        let derivedOnce = try HistoryCrypto.chunkKey(
            rootKey: rootKey, chunkID: chunkID, streamID: "stream-a", keyEpoch: 1
        )
        let derivedAgain = try HistoryCrypto.chunkKey(
            rootKey: rootKey, chunkID: chunkID, streamID: "stream-a", keyEpoch: 1
        )
        XCTAssertEqual(
            derivedOnce.withUnsafeBytes { Data($0) },
            derivedAgain.withUnsafeBytes { Data($0) }
        )

        // Distinct across chunk, stream, and epoch.
        for (otherChunk, otherStream, otherEpoch) in [
            (String(repeating: "0e", count: 16), "stream-a", UInt64(1)),
            (chunkID, "stream-b", UInt64(1)),
            (chunkID, "stream-a", UInt64(2)),
        ] {
            let other = try HistoryCrypto.chunkKey(
                rootKey: rootKey, chunkID: otherChunk, streamID: otherStream, keyEpoch: otherEpoch
            )
            XCTAssertNotEqual(
                derivedOnce.withUnsafeBytes { Data($0) },
                other.withUnsafeBytes { Data($0) }
            )
        }
    }

    func testSessionIdentifierIsKeyedAndStable() {
        let rootKey = Data(repeating: 0x11, count: 32)
        let one = HistoryCrypto.sessionIdentifier(rootKey: rootKey, sessionLabel: "label-a")
        let two = HistoryCrypto.sessionIdentifier(rootKey: rootKey, sessionLabel: "label-a")
        let other = HistoryCrypto.sessionIdentifier(rootKey: rootKey, sessionLabel: "label-b")
        let otherKey = HistoryCrypto.sessionIdentifier(rootKey: Data(repeating: 0x22, count: 32), sessionLabel: "label-a")
        XCTAssertEqual(one, two)
        XCTAssertEqual(one.count, 32)
        XCTAssertNotEqual(one, other)
        XCTAssertNotEqual(one, otherKey)
    }

    func testCBORRejectsNonShortestFormAndIndefiniteLengths() {
        // 0x18 0x17 is 23 encoded with an unnecessary one-byte argument.
        var decoder = HistoryCBOR.Decoder(Data([0x18, 0x17]))
        XCTAssertThrowsError(try decoder.decodeItem())

        // 0x5F starts an indefinite-length byte string.
        var indefinite = HistoryCBOR.Decoder(Data([0x5F]))
        XCTAssertThrowsError(try indefinite.decodeItem())
    }
}


/// Shutdown is a signal path: the daemon's SIGTERM handler exits the process
/// directly, so the AppKit run loop never returns. This drives the real binary
/// to prove the session-ended record is actually durable at termination rather
/// than sitting in unreachable code after `NSApplication.run()`.
final class CuaDriverHistoryShutdownIntegrationTests: XCTestCase {
    func testSigtermRecordsSessionEndedAndRestartContinuesTheStream() throws {
        let binary = try binaryURL()
        // Keep this path SHORT: unix sun_path caps at ~104 bytes.
        let temp = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cua-hs-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let socket = temp.appendingPathComponent("s")
        let pidFile = temp.appendingPathComponent("p")
        let storeRoot = temp.appendingPathComponent("store")

        // This suite is the only one that touches the real credential store, so
        // it always removes the namespace key it may have created.
        defer {
            try? KeychainHistoryKeyStore().destroyRootKey()
            try? FileManager.default.removeItem(at: temp)
        }

        let first = try spawnDaemon(binary, socket: socket, pidFile: pidFile, storeRoot: storeRoot)
        defer { if first.isRunning { first.terminate() } }
        guard waitForPath(socket.path, timeout: 10), waitForPath(pidFile.path, timeout: 10) else {
            throw XCTSkip("cua-driver did not come up in this environment")
        }

        let enabled = try run(binary, ["history", "enable", "--socket", socket.path])
        guard enabled.exitCode == 0 else {
            throw XCTSkip("history could not be enabled here: \(enabled.stderr)")
        }

        guard let pid = Int32(
            (try String(contentsOf: pidFile, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines)
        ) else {
            return XCTFail("unreadable pid file")
        }
        kill(pid, SIGTERM)
        XCTAssertTrue(waitForExit(first, timeout: 10), "daemon did not exit on SIGTERM")

        let second = try spawnDaemon(binary, socket: socket, pidFile: pidFile, storeRoot: storeRoot)
        defer {
            _ = try? run(binary, ["history", "delete", "--yes", "--socket", socket.path])
            if second.isRunning { second.terminate() }
        }
        guard waitForPath(socket.path, timeout: 10) else {
            throw XCTSkip("cua-driver did not restart in this environment")
        }

        let listed = try run(binary, ["history", "list", "20", "--socket", socket.path])
        XCTAssertEqual(listed.exitCode, 0, listed.stderr)
        let events = ((try JSONSerialization.jsonObject(
            with: Data(listed.stdout.utf8)
        ) as? [String: Any])?["events"] as? [[String: Any]]) ?? []
        let phases = events.compactMap { event -> String? in
            guard let data = event["data"] as? [String: Any],
                  let payload = data["payload"] as? [String: Any],
                  (payload["kind"] as? String) == "session" else {
                return nil
            }
            return payload["phase"] as? String
        }
        XCTAssertEqual(phases, ["ended", "started"], "expected the SIGTERM session close before the restart")

        let sequences = events.compactMap { ($0["data"] as? [String: Any])?["sequence"] as? Int }
        XCTAssertEqual(sequences, sequences.sorted())
        XCTAssertEqual(Set(sequences).count, sequences.count, "restart must not replay sequence numbers")
    }

    // MARK: helpers

    private func spawnDaemon(_ binary: URL, socket: URL, pidFile: URL, storeRoot: URL) throws -> Process {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["serve", "--no-relaunch", "--socket", socket.path, "--pid-file", pidFile.path]
        var environment = ProcessInfo.processInfo.environment
        environment["CUA_DRIVER_HISTORY_ROOT"] = storeRoot.path
        process.environment = environment
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            throw XCTSkip("Unable to spawn cua-driver here: \(error.localizedDescription)")
        }
        return process
    }

    private func run(_ binary: URL, _ arguments: [String]) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        let out = Pipe()
        let err = Pipe()
        process.executableURL = binary
        process.arguments = arguments
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(data: stdout, encoding: .utf8) ?? "",
            String(data: stderr, encoding: .utf8) ?? ""
        )
    }

    private func binaryURL() throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build")
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw XCTSkip("no .build directory")
        }
        for case let url as URL in enumerator
        where url.lastPathComponent == "cua-driver"
            && FileManager.default.isExecutableFile(atPath: url.path) {
            return url
        }
        throw XCTSkip("cua-driver binary not found; run `swift build --product cua-driver` first")
    }

    private func waitForPath(_ path: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return FileManager.default.fileExists(atPath: path)
    }

    private func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !process.isRunning { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return !process.isRunning
    }
}

private struct EmptyWindowProvider: CuaDriverWindowProviding {
    func listWindows(pid: Int?) -> [CuaDriverWindowInfo] { [] }

    func window(windowID: Int, pid: Int?) -> CuaDriverWindowInfo? { nil }
}
