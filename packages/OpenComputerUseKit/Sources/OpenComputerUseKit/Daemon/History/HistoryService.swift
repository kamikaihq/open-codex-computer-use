import AppKit
import Foundation

// Daemon-facing Computer History facade.
//
// Serializes all store access on one queue, keeps capture strictly
// non-blocking for the originating computer action (bounded pending appends,
// drops counted and reported through health), and exposes the verb surface:
// status/query reads plus the user-consent lifecycle operations.

public final class HistoryService: @unchecked Sendable {
    static let maxPendingAppends = 256
    static let maxQueryLimit = 200
    static let defaultQueryLimit = 50

    private let queue = DispatchQueue(label: "cua-driver.history")
    private let store: HistoryStore
    private var state: HistoryStoreState
    private let sessionLabel: String
    private var cachedSessionID: String?
    private let pendingLock = NSLock()
    private var pendingAppends = 0
    private var droppedOverflow = 0
    private var droppedEvents = 0
    private var writerFault: HistoryStoreError?
    private var quotaReported = false

    public convenience init() {
        let root: URL
        if let override = ProcessInfo.processInfo.environment["CUA_DRIVER_HISTORY_ROOT"],
           !override.isEmpty {
            root = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            root = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/cua-driver/computer-history", isDirectory: true)
        }
        self.init(rootURL: root, keyStore: KeychainHistoryKeyStore())
    }

    init(rootURL: URL, keyStore: any HistoryKeyStoring, now: @escaping () -> Date = Date.init) {
        self.store = HistoryStore(rootURL: rootURL, keyStore: keyStore, now: now)
        self.state = store.loadState()
        self.sessionLabel = "cua-driver/\(ProcessInfo.processInfo.globallyUniqueString)"
    }

    // MARK: Health

    private var totalDroppedEvents: Int {
        pendingLock.lock()
        let overflow = droppedOverflow
        pendingLock.unlock()
        return droppedEvents + overflow
    }

    private func healthCategory() -> String {
        if let writerFault {
            switch writerFault {
            case .quotaReached: return "quota_reached"
            case .keyUnavailable: return "key_unavailable"
            case .keyDestroyFailed: return "key_destroy_failed"
            case .storageCorrupt: return "storage_corrupt"
            case .storageUnavailable: return "storage_unavailable"
            default: return "writer_stopped"
            }
        }
        if !state.enabled {
            return "disabled"
        }
        if state.paused {
            return "paused"
        }
        if totalDroppedEvents > 0 {
            return "events_dropped"
        }
        return "ready"
    }

    // MARK: Verb surface

    public func statusResponse() -> [String: Any] {
        queue.sync {
            [
                "supported": true,
                "admitted": true,
                "enabled": state.enabled,
                "paused": state.paused,
                "encrypted": true,
                "profile": HistoryStore.profileIdentifier,
                "retention_days": HistoryStore.retentionDays,
                "quota_bytes": HistoryStore.quotaBytes,
                "bytes_used": store.bytesUsed(),
                "dropped_events": totalDroppedEvents,
                "health": healthCategory(),
            ]
        }
    }

    public func queryResponse(args: [String: Any]) -> [String: Any] {
        let allowedKeys: Set<String> = ["limit", "session_id", "since_sequence", "until_sequence"]
        for key in args.keys where !allowedKeys.contains(key) {
            return failure(.invalidQuery("history_query does not accept field '\(key)'"))
        }

        var filters = HistoryQueryFilters(limit: Self.defaultQueryLimit)
        if let rawLimit = args["limit"] {
            guard let limit = (rawLimit as? NSNumber)?.intValue, (1...Self.maxQueryLimit).contains(limit) else {
                return failure(.invalidQuery("limit must be an integer between 1 and \(Self.maxQueryLimit)"))
            }
            filters.limit = limit
        }
        if let rawSession = args["session_id"] {
            guard let sessionID = rawSession as? String, (1...128).contains(sessionID.count) else {
                return failure(.invalidQuery("session_id must be a string of 1..128 characters"))
            }
            filters.sessionID = sessionID
        }
        for (field, keyPath) in [("since_sequence", \HistoryQueryFilters.sinceSequence),
                                 ("until_sequence", \HistoryQueryFilters.untilSequence)] {
            if let raw = args[field] {
                guard let value = (raw as? NSNumber)?.int64Value, value >= 1 else {
                    return failure(.invalidQuery("\(field) must be an integer >= 1"))
                }
                filters[keyPath: keyPath] = UInt64(value)
            }
        }
        if let since = filters.sinceSequence, let until = filters.untilSequence, since > until {
            return failure(.invalidQuery("since_sequence must not exceed until_sequence"))
        }

        return queue.sync {
            do {
                let events = try store.query(filters)
                if !events.isEmpty {
                    appendLocked(
                        actionID: nil,
                        capability: nil,
                        application: HistoryApplicationIdentity(),
                        payload: .access(operation: "history_query", returnedCount: events.count)
                    )
                }
                return [
                    "events": events.map { $0.jsonObject() },
                    "metadata_only": true,
                    "model_context_disclosure": true,
                ]
            } catch let error as HistoryStoreError {
                return Self.errorEnvelope(error)
            } catch {
                return Self.errorEnvelope(.storageUnavailable(error.localizedDescription))
            }
        }
    }

    public func enableResponse() -> [String: Any] {
        queue.sync {
            do {
                try store.loadOrCreateRootKey()
                try store.prepareWriter()
                writerFault = nil
                quotaReported = false
                state = HistoryStoreState(enabled: true, paused: false)
                try store.saveState(state)
                // Verified encrypted write and read-back before reporting success.
                let event = try store.append(
                    sessionID: try sessionID(),
                    actionID: nil,
                    capability: nil,
                    application: HistoryApplicationIdentity(),
                    payload: .control(operation: "enable")
                )
                let verify = try store.query(HistoryQueryFilters(
                    limit: 1,
                    sinceSequence: event.sequence,
                    untilSequence: event.sequence
                ))
                guard verify.first?.id == event.id else {
                    throw HistoryStoreError.storageCorrupt("enable verification read did not return the written record")
                }
                return statusLocked()
            } catch let error as HistoryStoreError {
                state = HistoryStoreState(enabled: false, paused: false)
                try? store.saveState(state)
                return Self.errorEnvelope(error)
            } catch {
                state = HistoryStoreState(enabled: false, paused: false)
                try? store.saveState(state)
                return Self.errorEnvelope(.storageUnavailable(error.localizedDescription))
            }
        }
    }

    public func lifecycleResponse(operation: String) -> [String: Any] {
        queue.sync {
            let target: HistoryStoreState
            switch operation {
            case "disable":
                target = HistoryStoreState(enabled: false, paused: false)
            case "pause":
                guard state.enabled else {
                    return Self.errorEnvelope(.notEnabled)
                }
                target = HistoryStoreState(enabled: true, paused: true)
            case "resume":
                guard state.enabled else {
                    return Self.errorEnvelope(.notEnabled)
                }
                target = HistoryStoreState(enabled: true, paused: false)
            default:
                return Self.errorEnvelope(.invalidQuery("unknown history lifecycle operation \(operation)"))
            }

            if state.enabled, !state.paused || operation == "disable" {
                appendLocked(
                    actionID: nil,
                    capability: nil,
                    application: HistoryApplicationIdentity(),
                    payload: .control(operation: operation)
                )
            }
            do {
                state = target
                try store.saveState(state)
            } catch let error as HistoryStoreError {
                return Self.errorEnvelope(error)
            } catch {
                return Self.errorEnvelope(.storageUnavailable(error.localizedDescription))
            }
            if operation == "disable" {
                store.sealLiveChunk()
            }
            return statusLocked()
        }
    }

    public func deleteResponse(args: [String: Any]) -> [String: Any] {
        guard args["confirm"] as? Bool == true else {
            return Self.errorEnvelope(.confirmationRequired)
        }
        return queue.sync {
            do {
                try store.deleteAll()
                state = HistoryStoreState(enabled: false, paused: false)
                cachedSessionID = nil
                droppedEvents = 0
                pendingLock.lock()
                droppedOverflow = 0
                pendingLock.unlock()
                writerFault = nil
                quotaReported = false
                return ["deleted": true]
            } catch let error as HistoryStoreError {
                return Self.errorEnvelope(error)
            } catch {
                return Self.errorEnvelope(.storageUnavailable(error.localizedDescription))
            }
        }
    }

    private func statusLocked() -> [String: Any] {
        [
            "supported": true,
            "admitted": true,
            "enabled": state.enabled,
            "paused": state.paused,
            "encrypted": true,
            "profile": HistoryStore.profileIdentifier,
            "retention_days": HistoryStore.retentionDays,
            "quota_bytes": HistoryStore.quotaBytes,
            "bytes_used": store.bytesUsed(),
            "dropped_events": totalDroppedEvents,
            "health": healthCategory(),
        ]
    }

    private func failure(_ error: HistoryStoreError) -> [String: Any] {
        Self.errorEnvelope(error)
    }

    static func errorEnvelope(_ error: HistoryStoreError) -> [String: Any] {
        [
            "error": [
                "code": error.code,
                "message": error.message,
            ],
        ]
    }

    // MARK: Capture

    private func sessionID() throws -> String {
        if let cachedSessionID {
            return cachedSessionID
        }
        let derived = try store.sessionIdentifier(forLabel: sessionLabel)
        cachedSessionID = derived
        return derived
    }

    /// Nonblocking capture: never fails or delays the originating action.
    public func recordSession(phase: String) {
        recordAsync(actionID: nil, capability: nil, pid: nil, payload: .session(phase: phase))
    }

    public func recordActionStarted(actionID: String, capability: String, pid: Int?) {
        recordAsync(actionID: actionID, capability: capability, pid: pid, payload: .actionStarted)
    }

    public func recordActionCompleted(
        actionID: String,
        capability: String,
        pid: Int?,
        effect: String,
        route: String?
    ) {
        recordAsync(
            actionID: actionID,
            capability: capability,
            pid: pid,
            payload: .actionCompleted(effect: effect, route: route, deliveredCount: 1)
        )
    }

    public func makeActionID() -> String {
        HistoryCrypto.randomHexID()
    }

    /// Waits for all pending capture work to settle (shutdown and tests).
    public func flush() {
        queue.sync {}
    }

    public var isCapturing: Bool {
        queue.sync {
            state.enabled && !state.paused && writerFault == nil
        }
    }

    private func recordAsync(actionID: String?, capability: String?, pid: Int?, payload: HistoryEventPayload) {
        let application = Self.applicationIdentity(pid: pid)

        pendingLock.lock()
        if pendingAppends >= Self.maxPendingAppends {
            droppedOverflow += 1
            pendingLock.unlock()
            return
        }
        pendingAppends += 1
        pendingLock.unlock()

        queue.async { [weak self] in
            guard let self else {
                return
            }
            defer {
                self.pendingLock.lock()
                self.pendingAppends -= 1
                self.pendingLock.unlock()
            }
            guard self.state.enabled, !self.state.paused else {
                return
            }
            self.appendLocked(
                actionID: actionID,
                capability: capability,
                application: application,
                payload: payload
            )
        }
    }

    /// Must run on `queue`.
    private func appendLocked(
        actionID: String?,
        capability: String?,
        application: HistoryApplicationIdentity,
        payload: HistoryEventPayload
    ) {
        guard writerFault == nil || payload.kind == "control" else {
            droppedEvents += 1
            return
        }
        do {
            try store.append(
                sessionID: try sessionID(),
                actionID: actionID,
                capability: capability,
                application: application,
                payload: payload
            )
            store.pruneExpiredChunks()
        } catch let error as HistoryStoreError {
            droppedEvents += 1
            if case .quotaReached = error {
                writerFault = error
                if !quotaReported {
                    quotaReported = true
                }
            } else {
                writerFault = error
            }
        } catch {
            droppedEvents += 1
            writerFault = .storageUnavailable(error.localizedDescription)
        }
    }

    static func applicationIdentity(pid: Int?) -> HistoryApplicationIdentity {
        guard let pid else {
            return HistoryApplicationIdentity()
        }
        guard let app = NSRunningApplication(processIdentifier: pid_t(pid)) else {
            return HistoryApplicationIdentity()
        }
        return HistoryApplicationIdentity(
            bundleID: app.bundleIdentifier,
            displayName: app.localizedName
        )
    }
}
