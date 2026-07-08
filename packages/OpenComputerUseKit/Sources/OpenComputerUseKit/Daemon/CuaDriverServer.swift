import AppKit
import Darwin
import Foundation

public enum CuaDriverServerError: Error, LocalizedError {
    case lockHeld(String)
    case missingSocketDirectory(String)

    public var errorDescription: String? {
        switch self {
        case let .lockHeld(path):
            return "cua-driver is already running for this socket directory: \(path)"
        case let .missingSocketDirectory(path):
            return "Socket directory does not exist: \(path)"
        }
    }
}

public final class CuaDriverServer {
    public let socketPath: String
    public let pidFilePath: String

    private let handler: CuaDriverVerbHandler
    private let socketDirectory: String
    private let lockPath: String
    private let queue = DispatchQueue(label: "cua-driver.socket")

    private var lockFD: Int32 = -1
    private var listenFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var signalSources: [DispatchSourceSignal] = []
    private var stopped = false
    private var ownsRuntimeFiles = false

    public init(
        socketPath: String,
        pidFilePath: String? = nil,
        handler: CuaDriverVerbHandler = CuaDriverVerbHandler()
    ) {
        self.socketPath = socketPath
        self.socketDirectory = URL(fileURLWithPath: socketPath).deletingLastPathComponent().path
        self.pidFilePath = pidFilePath ?? URL(fileURLWithPath: socketPath)
            .deletingLastPathComponent()
            .appendingPathComponent("cua-driver.pid")
            .path
        self.lockPath = URL(fileURLWithPath: socketPath)
            .deletingLastPathComponent()
            .appendingPathComponent("cua-driver.lock")
            .path
        self.handler = handler
    }

    deinit {
        stop()
    }

    public func start() throws {
        signal(SIGPIPE, SIG_IGN)

        guard FileManager.default.fileExists(atPath: socketDirectory) else {
            throw CuaDriverServerError.missingSocketDirectory(socketDirectory)
        }

        try acquireLock()
        ownsRuntimeFiles = true
        try? FileManager.default.removeItem(atPath: socketPath)

        let fd = try CuaDriverSocket.makeStreamSocket()
        listenFD = fd
        try CuaDriverSocket.setNonBlocking(fd)
        try CuaDriverSocket.bind(fd: fd, path: socketPath)
        guard chmod(socketPath, S_IRUSR | S_IWUSR) == 0 else {
            throw CuaDriverSocketError.posix("chmod", errno)
        }
        guard listen(fd, SOMAXCONN) == 0 else {
            throw CuaDriverSocketError.posix("listen", errno)
        }

        try "\(getpid())\n".write(toFile: pidFilePath, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pidFilePath)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptAvailableConnections()
        }
        source.setCancelHandler {
            close(fd)
        }
        readSource = source
        source.resume()
    }

    public func installTerminationHandlers(on queue: DispatchQueue = .main) {
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)

        signalSources = [SIGTERM, SIGINT].map { signalNumber in
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
            source.setEventHandler { [weak self] in
                self?.stop()
                exit(0)
            }
            source.resume()
            return source
        }
    }

    public func stop() {
        guard !stopped else {
            return
        }
        stopped = true

        if let readSource {
            readSource.cancel()
            self.readSource = nil
        } else if listenFD >= 0 {
            close(listenFD)
        }
        listenFD = -1

        if ownsRuntimeFiles {
            try? FileManager.default.removeItem(atPath: socketPath)
            try? FileManager.default.removeItem(atPath: pidFilePath)
            ownsRuntimeFiles = false
        }

        if lockFD >= 0 {
            flock(lockFD, LOCK_UN)
            close(lockFD)
            lockFD = -1
        }
    }

    private func acquireLock() throws {
        lockFD = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard lockFD >= 0 else {
            throw CuaDriverSocketError.posix("open lock", errno)
        }

        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(lockFD)
            lockFD = -1
            if code == EWOULDBLOCK {
                throw CuaDriverServerError.lockHeld(lockPath)
            }
            throw CuaDriverSocketError.posix("flock", code)
        }
    }

    private func acceptAvailableConnections() {
        while true {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD >= 0 {
                handleConnection(clientFD)
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else if errno == EINTR {
                continue
            } else {
                return
            }
        }
    }

    private func handleConnection(_ clientFD: Int32) {
        defer { close(clientFD) }

        do {
            try CuaDriverSocket.setBlocking(clientFD)
            try CuaDriverSocket.setTimeouts(clientFD, seconds: 2.0)
            let request = try CuaDriverSocket.readFrame(from: clientFD)
            let response = handler.responseEnvelope(for: request)
            let responseData = try CuaDriverJSON.data(from: response)
            try CuaDriverSocket.writeFrame(responseData, to: clientFD)
        } catch {
            let response = CuaDriverVerbHandler.errorEnvelope(
                code: "protocol_error",
                message: error.localizedDescription
            )
            if let responseData = try? CuaDriverJSON.data(from: response) {
                try? CuaDriverSocket.writeFrame(responseData, to: clientFD)
            }
        }
    }
}

@MainActor
public func runCuaDriverServer(socketPath: String, pidFilePath: String?) throws -> Never {
    _ = NSApplication.shared.setActivationPolicy(.accessory)

    let server = CuaDriverServer(socketPath: socketPath, pidFilePath: pidFilePath)
    try server.start()
    server.installTerminationHandlers()

    NSApplication.shared.run()
    server.stop()
    exit(0)
}
