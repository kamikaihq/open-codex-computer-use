import Foundation

// Minimal deterministic CBOR encoder/decoder for the Cua History Profile v1.
//
// The profile (docs/references/cua-history/computer-history-profile-v1.cddl)
// needs exactly: unsigned integers, byte strings, text strings, definite
// arrays, one one-entry map ({5: bstr}), and tag 16 (COSE_Encrypt0).
// Encoding is deterministic: shortest-form lengths, definite lengths only.
// Decoding fails closed: any construct outside the profile subset is an error.

enum HistoryCBORError: Error, Equatable {
    case truncated
    case malformed(String)
}

enum HistoryCBORValue: Equatable {
    case unsigned(UInt64)
    case byteString(Data)
    case textString(String)
    case array([HistoryCBORValue])
    case map([(UInt64, HistoryCBORValue)])
    case tagged(UInt64, [HistoryCBORValue])

    static func == (lhs: HistoryCBORValue, rhs: HistoryCBORValue) -> Bool {
        switch (lhs, rhs) {
        case let (.unsigned(a), .unsigned(b)):
            return a == b
        case let (.byteString(a), .byteString(b)):
            return a == b
        case let (.textString(a), .textString(b)):
            return a == b
        case let (.array(a), .array(b)):
            return a == b
        case let (.map(a), .map(b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case let (.tagged(ta, a), .tagged(tb, b)):
            return ta == tb && a == b
        default:
            return false
        }
    }
}

enum HistoryCBOR {
    // MARK: Encoding

    static func encode(_ value: HistoryCBORValue) -> Data {
        var out = Data()
        append(value, to: &out)
        return out
    }

    private static func append(_ value: HistoryCBORValue, to out: inout Data) {
        switch value {
        case let .unsigned(number):
            appendHead(major: 0, value: number, to: &out)
        case let .byteString(data):
            appendHead(major: 2, value: UInt64(data.count), to: &out)
            out.append(data)
        case let .textString(text):
            let utf8 = Data(text.utf8)
            appendHead(major: 3, value: UInt64(utf8.count), to: &out)
            out.append(utf8)
        case let .array(items):
            appendHead(major: 4, value: UInt64(items.count), to: &out)
            for item in items {
                append(item, to: &out)
            }
        case let .map(entries):
            appendHead(major: 5, value: UInt64(entries.count), to: &out)
            for (key, entryValue) in entries {
                appendHead(major: 0, value: key, to: &out)
                append(entryValue, to: &out)
            }
        case let .tagged(tag, items):
            appendHead(major: 6, value: tag, to: &out)
            appendHead(major: 4, value: UInt64(items.count), to: &out)
            for item in items {
                append(item, to: &out)
            }
        }
    }

    private static func appendHead(major: UInt8, value: UInt64, to out: inout Data) {
        let majorBits = major << 5
        switch value {
        case 0..<24:
            out.append(majorBits | UInt8(value))
        case 24...UInt64(UInt8.max):
            out.append(majorBits | 24)
            out.append(UInt8(value))
        case (UInt64(UInt8.max) + 1)...UInt64(UInt16.max):
            out.append(majorBits | 25)
            withUnsafeBytes(of: UInt16(value).bigEndian) { out.append(contentsOf: $0) }
        case (UInt64(UInt16.max) + 1)...UInt64(UInt32.max):
            out.append(majorBits | 26)
            withUnsafeBytes(of: UInt32(value).bigEndian) { out.append(contentsOf: $0) }
        default:
            out.append(majorBits | 27)
            withUnsafeBytes(of: value.bigEndian) { out.append(contentsOf: $0) }
        }
    }

    // MARK: Decoding

    struct Decoder {
        private let data: Data
        private(set) var offset: Int

        init(_ data: Data) {
            self.data = data
            self.offset = data.startIndex
        }

        var isAtEnd: Bool {
            offset >= data.endIndex
        }

        mutating func decodeItem(maxDepth: Int = 8) throws -> HistoryCBORValue {
            guard maxDepth > 0 else {
                throw HistoryCBORError.malformed("nesting too deep for history profile")
            }
            let (major, length) = try readHead()
            switch major {
            case 0:
                return .unsigned(length)
            case 2:
                return .byteString(try readBytes(count: length))
            case 3:
                let raw = try readBytes(count: length)
                guard let text = String(data: raw, encoding: .utf8) else {
                    throw HistoryCBORError.malformed("text string is not valid UTF-8")
                }
                return .textString(text)
            case 4:
                guard length <= 32 else {
                    throw HistoryCBORError.malformed("array too long for history profile")
                }
                var items: [HistoryCBORValue] = []
                items.reserveCapacity(Int(length))
                for _ in 0..<length {
                    items.append(try decodeItem(maxDepth: maxDepth - 1))
                }
                return .array(items)
            case 5:
                guard length <= 8 else {
                    throw HistoryCBORError.malformed("map too long for history profile")
                }
                var entries: [(UInt64, HistoryCBORValue)] = []
                for _ in 0..<length {
                    let (keyMajor, key) = try readHead()
                    guard keyMajor == 0 else {
                        throw HistoryCBORError.malformed("history profile map keys must be unsigned integers")
                    }
                    entries.append((key, try decodeItem(maxDepth: maxDepth - 1)))
                }
                return .map(entries)
            case 6:
                let inner = try decodeItem(maxDepth: maxDepth - 1)
                guard case let .array(items) = inner else {
                    throw HistoryCBORError.malformed("tagged history item must contain an array")
                }
                return .tagged(length, items)
            default:
                throw HistoryCBORError.malformed("major type \(major) is outside the history profile subset")
            }
        }

        private mutating func readHead() throws -> (UInt8, UInt64) {
            guard offset < data.endIndex else {
                throw HistoryCBORError.truncated
            }
            let initial = data[offset]
            offset += 1
            let major = initial >> 5
            let additional = initial & 0x1F
            switch additional {
            case 0..<24:
                return (major, UInt64(additional))
            case 24:
                let value = UInt64(try readByte())
                guard value >= 24 else {
                    throw HistoryCBORError.malformed("non-shortest-form length")
                }
                return (major, value)
            case 25:
                let value = try readFixed(2)
                guard value > UInt64(UInt8.max) else {
                    throw HistoryCBORError.malformed("non-shortest-form length")
                }
                return (major, value)
            case 26:
                let value = try readFixed(4)
                guard value > UInt64(UInt16.max) else {
                    throw HistoryCBORError.malformed("non-shortest-form length")
                }
                return (major, value)
            case 27:
                let value = try readFixed(8)
                guard value > UInt64(UInt32.max) else {
                    throw HistoryCBORError.malformed("non-shortest-form length")
                }
                return (major, value)
            default:
                throw HistoryCBORError.malformed("indefinite lengths are not part of the history profile")
            }
        }

        private mutating func readByte() throws -> UInt8 {
            guard offset < data.endIndex else {
                throw HistoryCBORError.truncated
            }
            let byte = data[offset]
            offset += 1
            return byte
        }

        private mutating func readFixed(_ count: Int) throws -> UInt64 {
            var value: UInt64 = 0
            for _ in 0..<count {
                value = (value << 8) | UInt64(try readByte())
            }
            return value
        }

        private mutating func readBytes(count: UInt64) throws -> Data {
            guard count <= 16 * 1024 * 1024 else {
                throw HistoryCBORError.malformed("byte string too long for history profile")
            }
            let length = Int(count)
            guard data.endIndex - offset >= length else {
                throw HistoryCBORError.truncated
            }
            let slice = data.subdata(in: offset..<(offset + length))
            offset += length
            return slice
        }
    }
}
