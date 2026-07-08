import Darwin
import Foundation

public struct CuaDriverClient {
    public let socketPath: String
    public let timeout: TimeInterval

    public init(socketPath: String, timeout: TimeInterval = 2.0) {
        self.socketPath = socketPath
        self.timeout = timeout
    }

    public func send(verb: String, args: [String: Any]) throws -> [String: Any] {
        signal(SIGPIPE, SIG_IGN)

        let fd = try CuaDriverSocket.makeStreamSocket()
        defer { close(fd) }

        try CuaDriverSocket.setTimeouts(fd, seconds: timeout)
        try CuaDriverSocket.connect(fd: fd, path: socketPath)

        let request = try CuaDriverJSON.data(from: [
            "verb": verb,
            "args": args,
        ])
        try CuaDriverSocket.writeFrame(request, to: fd)

        let response = try CuaDriverSocket.readFrame(from: fd)
        return try CuaDriverJSON.object(from: response)
    }
}
