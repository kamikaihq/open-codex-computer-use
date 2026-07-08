import Darwin
import Foundation

enum CuaDriverSocketError: Error, LocalizedError {
    case pathTooLong(String)
    case posix(String, Int32)
    case closed

    var errorDescription: String? {
        switch self {
        case let .pathTooLong(path):
            return "Unix socket path is too long: \(path)"
        case let .posix(operation, code):
            return "\(operation) failed: \(String(cString: strerror(code)))"
        case .closed:
            return "Socket closed"
        }
    }
}

enum CuaDriverSocket {
    static func makeStreamSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw CuaDriverSocketError.posix("socket", errno)
        }
        return fd
    }

    static func bind(fd: Int32, path: String) throws {
        var address = try unixAddress(path: path)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            throw CuaDriverSocketError.posix("bind", errno)
        }
    }

    static func connect(fd: Int32, path: String) throws {
        var address = try unixAddress(path: path)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            throw CuaDriverSocketError.posix("connect", errno)
        }
    }

    static func setNonBlocking(_ fd: Int32) throws {
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0 else {
            throw CuaDriverSocketError.posix("fcntl(F_GETFL)", errno)
        }
        guard fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw CuaDriverSocketError.posix("fcntl(F_SETFL)", errno)
        }
    }

    static func setBlocking(_ fd: Int32) throws {
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0 else {
            throw CuaDriverSocketError.posix("fcntl(F_GETFL)", errno)
        }
        guard fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) == 0 else {
            throw CuaDriverSocketError.posix("fcntl(F_SETFL)", errno)
        }
    }

    static func setTimeouts(_ fd: Int32, seconds: TimeInterval) throws {
        var timeout = timeval(
            tv_sec: Int(seconds),
            tv_usec: Int32((seconds - floor(seconds)) * 1_000_000)
        )
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw CuaDriverSocketError.posix("setsockopt(SO_RCVTIMEO)", errno)
        }
        guard setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw CuaDriverSocketError.posix("setsockopt(SO_SNDTIMEO)", errno)
        }
    }

    static func readFrame(from fd: Int32) throws -> Data {
        let header = try readExact(count: MemoryLayout<UInt32>.size, from: fd)
        var length: UInt32 = 0
        for byte in header {
            length = (length << 8) | UInt32(byte)
        }

        let bodyLength = Int(length)
        guard bodyLength <= CuaDriverFraming.maximumFrameLength else {
            throw CuaDriverFrameError.frameTooLarge(bodyLength)
        }
        return try readExact(count: bodyLength, from: fd)
    }

    static func writeFrame(_ body: Data, to fd: Int32) throws {
        let frame = try CuaDriverFraming.encode(body)
        try writeAll(frame, to: fd)
    }

    private static func readExact(count: Int, from fd: Int32) throws -> Data {
        var data = Data()
        data.reserveCapacity(count)

        while data.count < count {
            var buffer = [UInt8](repeating: 0, count: min(16 * 1024, count - data.count))
            let bytesRead = Darwin.read(fd, &buffer, buffer.count)
            if bytesRead > 0 {
                data.append(buffer, count: bytesRead)
            } else if bytesRead == 0 {
                throw CuaDriverSocketError.closed
            } else if errno == EINTR {
                continue
            } else {
                throw CuaDriverSocketError.posix("read", errno)
            }
        }

        return data
    }

    private static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }

            var written = 0
            while written < data.count {
                let result = Darwin.write(fd, baseAddress.advanced(by: written), data.count - written)
                if result > 0 {
                    written += result
                } else if result < 0, errno == EINTR {
                    continue
                } else {
                    throw CuaDriverSocketError.posix("write", errno)
                }
            }
        }
    }

    private static func unixAddress(path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        #if os(macOS)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif

        let pathLength = path.utf8.count
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathLength < capacity else {
            throw CuaDriverSocketError.pathTooLong(path)
        }

        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            path.withCString { cString in
                rawBuffer.copyBytes(from: UnsafeRawBufferPointer(start: cString, count: pathLength + 1))
            }
        }

        return address
    }
}
