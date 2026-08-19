import CryptoKit
import Foundation
import Security

// Cryptography for the Cua History Profile v1 port.
//
// Follows the published upstream profile exactly:
// - namespace root key: 32 random bytes in the platform credential store;
// - per-chunk key: HKDF-SHA-256(ikm: root, salt: chunk-id bytes,
//   info: "cua-driver/history-profile/v1/chunk-key" || stream-id || epoch_be64);
// - session-id key: HKDF-SHA-256(ikm: root, no salt,
//   info: "cua-driver/history-profile/v1/session-id-key"), session identifiers
//   are the first 128 bits of HMAC-SHA-256 over the effective session label;
// - records: COSE_Encrypt0 with ChaCha20/Poly1305 (RFC 9053 algorithm 24),
//   96-bit nonce = 32-bit random chunk prefix || uint64_be(record position),
//   external AAD = the exact encoded chunk header bytes.

enum HistoryCryptoError: Error, Equatable {
    case keyUnavailable(String)
    case keyDestroyFailed(String)
    case malformedChunkID
    case decryptFailed
}

/// Abstracts the namespace root key location so tests never touch the real
/// credential store. The daemon uses `KeychainHistoryKeyStore`.
protocol HistoryKeyStoring: Sendable {
    /// Returns the existing root key, or nil when none has been provisioned.
    func loadRootKey() throws -> Data?
    /// Creates and persists a new 32-byte root key. Fails if one exists.
    func createRootKey() throws -> Data
    /// Destroys the root key. Idempotent: missing key is success.
    func destroyRootKey() throws
    /// Opaque reference recorded in chunk headers.
    var keyReference: String { get }
}

struct KeychainHistoryKeyStore: HistoryKeyStoring {
    let service: String
    let account: String

    init(namespace: String = "ai.kamik.cua-driver.computer-history") {
        self.service = namespace
        self.account = "namespace-root-key"
    }

    var keyReference: String {
        "keychain:\(service)/\(account)"
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func loadRootKey() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, data.count == 32 else {
                throw HistoryCryptoError.keyUnavailable("stored history key is malformed")
            }
            return data
        case errSecItemNotFound:
            return nil
        case errSecInteractionNotAllowed:
            throw HistoryCryptoError.keyUnavailable("credential store is locked")
        default:
            throw HistoryCryptoError.keyUnavailable("credential store error \(status)")
        }
    }

    func createRootKey() throws -> Data {
        var keyBytes = Data(count: 32)
        let generated = keyBytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, 32, buffer.baseAddress!)
        }
        guard generated == errSecSuccess else {
            throw HistoryCryptoError.keyUnavailable("random key generation failed \(generated)")
        }

        var query = baseQuery
        query[kSecValueData as String] = keyBytes
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw HistoryCryptoError.keyUnavailable("credential store add failed \(status)")
        }
        return keyBytes
    }

    func destroyRootKey() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw HistoryCryptoError.keyDestroyFailed("credential store delete failed \(status)")
        }
    }
}

enum HistoryCrypto {
    static let profileVersion: UInt64 = 1
    static let coseAlgorithmChaCha20Poly1305: UInt64 = 24
    static let chunkKeyInfo = Data("cua-driver/history-profile/v1/chunk-key".utf8)
    static let sessionIDKeyInfo = Data("cua-driver/history-profile/v1/session-id-key".utf8)

    /// COSE protected header bytes: deterministic CBOR of {1: 24}.
    static let protectedHeaderBytes = Data([0xA1, 0x01, 0x18, 0x18])

    static func randomHexID() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func randomNoncePrefix() -> Data {
        var bytes = Data(count: 4)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, 4, buffer.baseAddress!)
        }
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return bytes
    }

    static func decodeHex128(_ hex: String) throws -> Data {
        guard hex.count == 32 else {
            throw HistoryCryptoError.malformedChunkID
        }
        var data = Data(capacity: 16)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                throw HistoryCryptoError.malformedChunkID
            }
            data.append(byte)
            index = next
        }
        return data
    }

    static func chunkKey(rootKey: Data, chunkID: String, streamID: String, keyEpoch: UInt64) throws -> SymmetricKey {
        let salt = try decodeHex128(chunkID)
        var info = Data()
        info.append(chunkKeyInfo)
        info.append(Data(streamID.utf8))
        withUnsafeBytes(of: keyEpoch.bigEndian) { info.append(contentsOf: $0) }
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: rootKey),
            salt: salt,
            info: info,
            outputByteCount: 32
        )
        return derived
    }

    static func sessionIdentifier(rootKey: Data, sessionLabel: String) -> String {
        let sessionKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: rootKey),
            info: sessionIDKeyInfo,
            outputByteCount: 32
        )
        let mac = HMAC<SHA256>.authenticationCode(for: Data(sessionLabel.utf8), using: sessionKey)
        return Data(mac).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static func nonce(prefix: Data, recordPosition: UInt64) -> Data {
        precondition(prefix.count == 4, "nonce prefix must be 4 bytes")
        var nonce = Data(prefix)
        withUnsafeBytes(of: recordPosition.bigEndian) { nonce.append(contentsOf: $0) }
        return nonce
    }

    static func seal(
        plaintext: Data,
        chunkKey: SymmetricKey,
        noncePrefix: Data,
        recordPosition: UInt64,
        headerBytes: Data
    ) throws -> (nonce: Data, ciphertext: Data) {
        let nonceBytes = nonce(prefix: noncePrefix, recordPosition: recordPosition)
        let sealed = try ChaChaPoly.seal(
            plaintext,
            using: chunkKey,
            nonce: ChaChaPoly.Nonce(data: nonceBytes),
            authenticating: coseAADStructure(headerBytes: headerBytes)
        )
        return (nonceBytes, sealed.ciphertext + sealed.tag)
    }

    static func open(
        ciphertext: Data,
        chunkKey: SymmetricKey,
        nonce nonceBytes: Data,
        headerBytes: Data
    ) throws -> Data {
        guard nonceBytes.count == 12, ciphertext.count >= 16 else {
            throw HistoryCryptoError.decryptFailed
        }
        do {
            let box = try ChaChaPoly.SealedBox(
                nonce: ChaChaPoly.Nonce(data: nonceBytes),
                ciphertext: ciphertext.dropLast(16),
                tag: ciphertext.suffix(16)
            )
            return try ChaChaPoly.open(
                box,
                using: chunkKey,
                authenticating: coseAADStructure(headerBytes: headerBytes)
            )
        } catch {
            throw HistoryCryptoError.decryptFailed
        }
    }

    /// COSE Enc_structure for COSE_Encrypt0 (RFC 9052 §5.3):
    /// ["Encrypt0", protected header bytes, external AAD].
    static func coseAADStructure(headerBytes: Data) -> Data {
        HistoryCBOR.encode(.array([
            .textString("Encrypt0"),
            .byteString(protectedHeaderBytes),
            .byteString(headerBytes),
        ]))
    }
}
