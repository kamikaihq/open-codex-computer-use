import CryptoKit
import Foundation

// Encrypted on-disk store implementing the Cua History Profile v1:
// each `<chunk-id>.cborseq` file is an RFC 8742 CBOR Sequence whose first item
// is the plaintext deterministic chunk header and whose remaining items are
// tagged COSE_Encrypt0 records containing CloudEvents JSON. The only other
// plaintext state is `state.json` with the enabled/paused booleans.
//
// The store is not thread-safe; `HistoryService` serializes access.

enum HistoryStoreError: Error {
    case notEnabled
    case confirmationRequired
    case invalidQuery(String)
    case keyUnavailable(String)
    case keyDestroyFailed(String)
    case storageUnavailable(String)
    case storageCorrupt(String)
    case quotaReached

    var code: String {
        switch self {
        case .notEnabled: return "history_not_enabled"
        case .confirmationRequired: return "history_confirmation_required"
        case .invalidQuery: return "invalid_request"
        case .keyUnavailable: return "history_key_unavailable"
        case .keyDestroyFailed: return "history_key_destroy_failed"
        case .storageUnavailable: return "history_storage_unavailable"
        case .storageCorrupt: return "history_storage_corrupt"
        case .quotaReached: return "history_quota_reached"
        }
    }

    var message: String {
        switch self {
        case .notEnabled:
            return "Computer History is not enabled"
        case .confirmationRequired:
            return "history_delete requires {\"confirm\": true}"
        case let .invalidQuery(detail):
            return detail
        case let .keyUnavailable(detail):
            return "history key unavailable: \(detail)"
        case let .keyDestroyFailed(detail):
            return "history key destruction failed: \(detail)"
        case let .storageUnavailable(detail):
            return "history storage unavailable: \(detail)"
        case let .storageCorrupt(detail):
            return "history storage corrupt: \(detail)"
        case .quotaReached:
            return "history encrypted-store quota reached"
        }
    }
}

struct HistoryStoreState: Equatable {
    var enabled: Bool
    var paused: Bool
}

struct HistoryQueryFilters {
    var limit: Int
    var sessionID: String? = nil
    var sinceSequence: UInt64? = nil
    var untilSequence: UInt64? = nil
}

final class HistoryStore {
    static let profileIdentifier =
        "cua-history-profile-v1/cbor-sequence+cose-encrypt0+cloudevents-json"
    static let retentionDays = 7
    static let quotaBytes = 100 * 1024 * 1024
    static let keyEpoch: UInt64 = 1
    /// Writers rotate the live chunk on a sub-hour cadence.
    static let chunkRotationInterval: TimeInterval = 30 * 60
    static let chunkRecordLimit: UInt64 = 100_000

    let rootURL: URL
    private let keyStore: any HistoryKeyStoring
    private let fileManager = FileManager()
    private let now: () -> Date

    private var rootKey: Data?
    private var streamID: String?
    private var nextSequence: UInt64 = 0
    private var scannedForSequence = false

    private struct LiveChunk {
        let chunkID: String
        let url: URL
        let headerBytes: Data
        let key: SymmetricKey
        let noncePrefix: Data
        let createdAt: Date
        var recordPosition: UInt64
    }

    private var liveChunk: LiveChunk?

    init(rootURL: URL, keyStore: any HistoryKeyStoring, now: @escaping () -> Date = Date.init) {
        self.rootURL = rootURL
        self.keyStore = keyStore
        self.now = now
    }

    // MARK: State file

    private var stateURL: URL {
        rootURL.appendingPathComponent("state.json")
    }

    func loadState() -> HistoryStoreState {
        guard let data = try? Data(contentsOf: stateURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return HistoryStoreState(enabled: false, paused: false)
        }
        return HistoryStoreState(
            enabled: object["enabled"] as? Bool ?? false,
            paused: object["paused"] as? Bool ?? false
        )
    }

    func saveState(_ state: HistoryStoreState) throws {
        try ensureRootDirectory()
        let object: [String: Any] = ["enabled": state.enabled, "paused": state.paused]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        do {
            try data.write(to: stateURL, options: [.atomic])
        } catch {
            throw HistoryStoreError.storageUnavailable("cannot persist state: \(error.localizedDescription)")
        }
    }

    private func ensureRootDirectory() throws {
        do {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true, attributes: [
                .posixPermissions: 0o700,
            ])
        } catch {
            throw HistoryStoreError.storageUnavailable("cannot create history root: \(error.localizedDescription)")
        }
    }

    // MARK: Key lifecycle

    var keyReference: String {
        keyStore.keyReference
    }

    @discardableResult
    func loadOrCreateRootKey() throws -> Data {
        if let rootKey {
            return rootKey
        }
        do {
            if let existing = try keyStore.loadRootKey() {
                rootKey = existing
                return existing
            }
            let created = try keyStore.createRootKey()
            rootKey = created
            return created
        } catch let error as HistoryCryptoError {
            throw storeError(from: error)
        }
    }

    func loadRootKeyIfPresent() throws -> Data? {
        if let rootKey {
            return rootKey
        }
        do {
            rootKey = try keyStore.loadRootKey()
            return rootKey
        } catch let error as HistoryCryptoError {
            throw storeError(from: error)
        }
    }

    private func storeError(from error: HistoryCryptoError) -> HistoryStoreError {
        switch error {
        case let .keyUnavailable(detail):
            return .keyUnavailable(detail)
        case let .keyDestroyFailed(detail):
            return .keyDestroyFailed(detail)
        case .malformedChunkID:
            return .storageCorrupt("malformed chunk identifier")
        case .decryptFailed:
            return .storageCorrupt("record failed authenticated decryption")
        }
    }

    // MARK: Store facts

    func chunkURLs() throws -> [URL] {
        guard fileManager.fileExists(atPath: rootURL.path) else {
            return []
        }
        do {
            return try fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.fileSizeKey])
                .filter { $0.pathExtension == "cborseq" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            throw HistoryStoreError.storageUnavailable("cannot list history root: \(error.localizedDescription)")
        }
    }

    func bytesUsed() -> Int {
        guard let urls = try? chunkURLs() else {
            return 0
        }
        return urls.reduce(0) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + size
        }
    }

    // MARK: Session identifiers

    func sessionIdentifier(forLabel label: String) throws -> String {
        let key = try loadOrCreateRootKey()
        return HistoryCrypto.sessionIdentifier(rootKey: key, sessionLabel: label)
    }

    // MARK: Writer

    /// Seals any live chunk. Called on writer initialization and shutdown so a
    /// chunk is appendable only by the writer instance that created it.
    func sealLiveChunk() {
        liveChunk = nil
    }

    func prepareWriter() throws {
        let key = try loadOrCreateRootKey()
        try ensureRootDirectory()
        if !scannedForSequence {
            var maxSequence: UInt64 = 0
            var existingStreamID: String?
            for url in try chunkURLs() {
                let chunk = try readChunk(at: url, rootKey: key)
                existingStreamID = chunk.header.streamID
                for event in chunk.events {
                    maxSequence = max(maxSequence, event.sequence)
                }
            }
            nextSequence = maxSequence == 0 && existingStreamID == nil ? 1 : maxSequence + 1
            streamID = existingStreamID ?? HistoryCrypto.randomHexID()
            scannedForSequence = true
        }
    }

    var currentStreamID: String? {
        streamID
    }

    @discardableResult
    func append(
        sessionID: String,
        actionID: String?,
        capability: String?,
        application: HistoryApplicationIdentity,
        payload: HistoryEventPayload
    ) throws -> HistoryEvent {
        try prepareWriter()
        guard let key = rootKey, let streamID else {
            throw HistoryStoreError.keyUnavailable("writer is not initialized")
        }
        guard bytesUsed() < Self.quotaBytes else {
            throw HistoryStoreError.quotaReached
        }

        let event = HistoryEvent(
            id: HistoryCrypto.randomHexID(),
            streamID: streamID,
            sessionID: sessionID,
            actionID: actionID,
            sequence: nextSequence,
            time: now(),
            capability: capability,
            application: application,
            payload: payload
        )

        let chunk = try currentChunk(rootKey: key, streamID: streamID)
        let plaintext = try event.encodedJSON()
        let sealed = try HistoryCrypto.seal(
            plaintext: plaintext,
            chunkKey: chunk.key,
            noncePrefix: chunk.noncePrefix,
            recordPosition: chunk.recordPosition,
            headerBytes: chunk.headerBytes
        )
        let record = HistoryCBOR.encode(.tagged(16, [
            .byteString(HistoryCrypto.protectedHeaderBytes),
            .map([(5, .byteString(sealed.nonce))]),
            .byteString(sealed.ciphertext),
        ]))

        guard let handle = FileHandle(forWritingAtPath: chunk.url.path) else {
            liveChunk = nil
            throw HistoryStoreError.storageUnavailable("cannot open live chunk for append")
        }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: record)
        } catch {
            liveChunk = nil
            throw HistoryStoreError.storageUnavailable("append failed: \(error.localizedDescription)")
        }

        liveChunk?.recordPosition = chunk.recordPosition + 1
        nextSequence = event.sequence + 1
        return event
    }

    private func currentChunk(rootKey: Data, streamID: String) throws -> LiveChunk {
        if let liveChunk {
            let expired = now().timeIntervalSince(liveChunk.createdAt) >= Self.chunkRotationInterval
            if !expired, liveChunk.recordPosition < Self.chunkRecordLimit {
                return liveChunk
            }
            self.liveChunk = nil
        }

        let chunkID = HistoryCrypto.randomHexID()
        let url = rootURL.appendingPathComponent("\(chunkID).cborseq")
        let noncePrefix = HistoryCrypto.randomNoncePrefix()
        let headerBytes = HistoryCBOR.encode(.array([
            .unsigned(HistoryCrypto.profileVersion),
            .unsigned(HistoryCrypto.coseAlgorithmChaCha20Poly1305),
            .unsigned(Self.keyEpoch),
            .textString(keyStore.keyReference),
            .textString(streamID),
            .textString(chunkID),
            .byteString(noncePrefix),
        ]))
        let key = try HistoryCrypto.chunkKey(
            rootKey: rootKey,
            chunkID: chunkID,
            streamID: streamID,
            keyEpoch: Self.keyEpoch
        )

        do {
            try headerBytes.write(to: url, options: [.withoutOverwriting])
        } catch {
            throw HistoryStoreError.storageUnavailable("cannot create chunk: \(error.localizedDescription)")
        }

        let chunk = LiveChunk(
            chunkID: chunkID,
            url: url,
            headerBytes: headerBytes,
            key: key,
            noncePrefix: noncePrefix,
            createdAt: now(),
            recordPosition: 0
        )
        liveChunk = chunk
        return chunk
    }

    /// Removes sealed chunks whose newest append predates the retention
    /// cutoff. The live chunk is never pruned.
    func pruneExpiredChunks() {
        let cutoff = now().addingTimeInterval(-TimeInterval(Self.retentionDays * 24 * 60 * 60))
        guard let urls = try? chunkURLs() else {
            return
        }
        for url in urls {
            if url == liveChunk?.url {
                continue
            }
            guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
                continue
            }
            if modified < cutoff {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    // MARK: Reader

    private struct ChunkHeader {
        let keyEpoch: UInt64
        let keyReference: String
        let streamID: String
        let chunkID: String
        let noncePrefix: Data
    }

    private struct DecodedChunk {
        let header: ChunkHeader
        let events: [HistoryEvent]
    }

    private func readChunk(at url: URL, rootKey: Data) throws -> DecodedChunk {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw HistoryStoreError.storageUnavailable("cannot read chunk: \(error.localizedDescription)")
        }
        guard data.count <= Self.quotaBytes else {
            throw HistoryStoreError.storageCorrupt("chunk exceeds quota bound")
        }

        var decoder = HistoryCBOR.Decoder(data)
        let headerStart = decoder.offset
        let headerValue: HistoryCBORValue
        do {
            headerValue = try decoder.decodeItem()
        } catch {
            throw HistoryStoreError.storageCorrupt("chunk header failed to decode")
        }
        let headerBytes = data.subdata(in: headerStart..<decoder.offset)

        guard case let .array(fields) = headerValue,
              fields.count == 7,
              case .unsigned(HistoryCrypto.profileVersion) = fields[0],
              case .unsigned(HistoryCrypto.coseAlgorithmChaCha20Poly1305) = fields[1],
              case let .unsigned(keyEpoch) = fields[2], keyEpoch > 0,
              case let .textString(keyReference) = fields[3],
              (1...128).contains(keyReference.count),
              case let .textString(streamID) = fields[4],
              (1...128).contains(streamID.count),
              case let .textString(chunkID) = fields[5], chunkID.count == 32,
              case let .byteString(noncePrefix) = fields[6], noncePrefix.count == 4
        else {
            throw HistoryStoreError.storageCorrupt("chunk header failed validation")
        }

        let header = ChunkHeader(
            keyEpoch: keyEpoch,
            keyReference: keyReference,
            streamID: streamID,
            chunkID: chunkID,
            noncePrefix: noncePrefix
        )
        let chunkKey: SymmetricKey
        do {
            chunkKey = try HistoryCrypto.chunkKey(
                rootKey: rootKey,
                chunkID: header.chunkID,
                streamID: header.streamID,
                keyEpoch: header.keyEpoch
            )
        } catch let error as HistoryCryptoError {
            throw storeError(from: error)
        }

        var events: [HistoryEvent] = []
        var position: UInt64 = 0
        while !decoder.isAtEnd {
            let recordValue: HistoryCBORValue
            do {
                recordValue = try decoder.decodeItem()
            } catch {
                throw HistoryStoreError.storageCorrupt("incomplete or malformed record at position \(position)")
            }
            guard case let .tagged(16, parts) = recordValue,
                  parts.count == 3,
                  case let .byteString(protectedBytes) = parts[0],
                  protectedBytes == HistoryCrypto.protectedHeaderBytes,
                  case let .map(unprotected) = parts[1],
                  unprotected.count == 1,
                  unprotected[0].0 == 5,
                  case let .byteString(nonceBytes) = unprotected[0].1,
                  nonceBytes.count == 12,
                  case let .byteString(ciphertext) = parts[2]
            else {
                throw HistoryStoreError.storageCorrupt("record structure failed validation at position \(position)")
            }

            let expectedNonce = HistoryCrypto.nonce(prefix: header.noncePrefix, recordPosition: position)
            guard nonceBytes == expectedNonce else {
                throw HistoryStoreError.storageCorrupt("record nonce does not match its position \(position)")
            }

            let plaintext: Data
            do {
                plaintext = try HistoryCrypto.open(
                    ciphertext: ciphertext,
                    chunkKey: chunkKey,
                    nonce: nonceBytes,
                    headerBytes: headerBytes
                )
            } catch {
                throw HistoryStoreError.storageCorrupt("record failed authenticated decryption at position \(position)")
            }

            events.append(try HistoryEvent.decode(from: plaintext))
            position += 1
        }

        return DecodedChunk(header: header, events: events)
    }

    func query(_ filters: HistoryQueryFilters) throws -> [HistoryEvent] {
        guard let key = try loadRootKeyIfPresent() else {
            throw HistoryStoreError.keyUnavailable("no history key has been provisioned")
        }
        if let since = filters.sinceSequence, let until = filters.untilSequence, since > until {
            throw HistoryStoreError.invalidQuery("since_sequence must not exceed until_sequence")
        }

        let cutoff = now().addingTimeInterval(-TimeInterval(Self.retentionDays * 24 * 60 * 60))
        var matches: [HistoryEvent] = []
        for url in try chunkURLs() {
            let chunk = try readChunk(at: url, rootKey: key)
            for event in chunk.events {
                guard event.time >= cutoff else {
                    continue
                }
                if let sessionID = filters.sessionID, event.sessionID != sessionID {
                    continue
                }
                if let since = filters.sinceSequence, event.sequence < since {
                    continue
                }
                if let until = filters.untilSequence, event.sequence > until {
                    continue
                }
                matches.append(event)
            }
        }
        matches.sort { $0.sequence < $1.sequence }
        if matches.count > filters.limit {
            matches.removeFirst(matches.count - filters.limit)
        }
        return matches
    }

    // MARK: Deletion

    /// Cryptographic delete-all: destroys the namespace key, then removes the
    /// recognized store files. Reports success only after both.
    func deleteAll() throws {
        sealLiveChunk()
        do {
            try keyStore.destroyRootKey()
        } catch let error as HistoryCryptoError {
            throw storeError(from: error)
        }
        rootKey = nil
        streamID = nil
        nextSequence = 0
        scannedForSequence = false

        for url in try chunkURLs() {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                throw HistoryStoreError.storageUnavailable("cannot remove chunk: \(error.localizedDescription)")
            }
        }
        if fileManager.fileExists(atPath: stateURL.path) {
            do {
                try fileManager.removeItem(at: stateURL)
            } catch {
                throw HistoryStoreError.storageUnavailable("cannot remove state: \(error.localizedDescription)")
            }
        }
    }
}
