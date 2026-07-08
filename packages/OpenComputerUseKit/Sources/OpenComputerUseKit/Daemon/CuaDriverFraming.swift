import Foundation

public enum CuaDriverFrameError: Error, Equatable, LocalizedError {
    case frameTooLarge(Int)
    case incompleteFrame

    public var errorDescription: String? {
        switch self {
        case let .frameTooLarge(size):
            return "Frame exceeds maximum size: \(size) bytes"
        case .incompleteFrame:
            return "Incomplete frame"
        }
    }
}

public enum CuaDriverFraming {
    public static let maximumFrameLength = 64 * 1024 * 1024

    public static func encode(_ body: Data) throws -> Data {
        guard body.count <= maximumFrameLength else {
            throw CuaDriverFrameError.frameTooLarge(body.count)
        }

        var length = UInt32(body.count).bigEndian
        var frame = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        frame.append(body)
        return frame
    }

    public struct Decoder {
        private var buffer = Data()

        public init() {}

        public mutating func append(_ data: Data) throws {
            buffer.append(data)
            if let pendingLength = pendingBodyLength, pendingLength > maximumFrameLength {
                throw CuaDriverFrameError.frameTooLarge(pendingLength)
            }
        }

        public mutating func nextFrame() throws -> Data? {
            guard let length = pendingBodyLength else {
                return nil
            }

            guard length <= maximumFrameLength else {
                throw CuaDriverFrameError.frameTooLarge(length)
            }

            let frameEnd = MemoryLayout<UInt32>.size + length
            guard buffer.count >= frameEnd else {
                return nil
            }

            let frame = buffer.subdata(in: MemoryLayout<UInt32>.size..<frameEnd)
            buffer.removeSubrange(0..<frameEnd)
            return frame
        }

        private var pendingBodyLength: Int? {
            guard buffer.count >= MemoryLayout<UInt32>.size else {
                return nil
            }

            var length: UInt32 = 0
            for byte in buffer.prefix(MemoryLayout<UInt32>.size) {
                length = (length << 8) | UInt32(byte)
            }
            return Int(length)
        }
    }
}
