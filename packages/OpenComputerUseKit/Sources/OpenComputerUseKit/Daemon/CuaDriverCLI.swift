import Darwin
import Foundation

public enum CuaDriverCLI {
    @MainActor
    public static func run(arguments: [String]) -> Int32 {
        do {
            guard !arguments.isEmpty else {
                throw CLIError("missing command")
            }

            if arguments == ["--version"] {
                print(CuaDriverConstants.version)
                return 0
            }

            switch arguments[0] {
            case "serve":
                let options = try parseServeOptions(Array(arguments.dropFirst()))
                try runCuaDriverServer(socketPath: options.socketPath, pidFilePath: options.pidFilePath)
            case "status":
                let options = try parseStatusOptions(Array(arguments.dropFirst()))
                let response = try CuaDriverClient(socketPath: options.socketPath).send(verb: "status", args: [:])
                try validateStatusResponse(response)
                return 0
            case "history":
                return try runHistoryCommand(Array(arguments.dropFirst()))
            case "call":
                let options = try parseCallOptions(Array(arguments.dropFirst()))
                // Verbs can legitimately take seconds (cursor glide, SCK capture,
                // AppKit init after a fresh spawn); only `status` stays at the
                // snappy default so supervision probes fail fast.
                let response = try CuaDriverClient(socketPath: options.socketPath, timeout: 15).send(
                    verb: options.verb,
                    args: options.args
                )
                try writeScreenshotIfRequested(response: response, path: options.screenshotOutFile)
                print(try CuaDriverJSON.text(from: response))
                if let error = response["error"] as? [String: Any] {
                    if let message = error["message"] as? String {
                        writeStderr(message)
                    }
                    return 1
                }
                return 0
            default:
                throw CLIError("unknown command: \(arguments[0])")
            }
        } catch let error as CuaDriverServerError {
            writeStderr(errorDescription(error))
            switch error {
            case .lockHeld:
                return 11
            default:
                return 1
            }
        } catch {
            writeStderr(errorDescription(error))
            return 1
        }
    }

    private struct ServeOptions {
        let socketPath: String
        let pidFilePath: String?
    }

    private struct StatusOptions {
        let socketPath: String
        let pidFilePath: String?
    }

    private struct CallOptions {
        let verb: String
        let args: [String: Any]
        let socketPath: String
        let screenshotOutFile: String?
    }

    // MARK: Computer History

    /// `cua-driver history <status|list [n]|show <seq>|enable|disable|pause|resume|delete --yes>`
    /// Thin client over the daemon's history verbs; read verbs are safe, the
    /// lifecycle verbs are user-consent operations.
    private static func runHistoryCommand(_ arguments: [String]) throws -> Int32 {
        var positionals: [String] = []
        var socketPath: String?
        var confirmed = false
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--socket":
                socketPath = try value(after: "--socket", in: arguments, index: &index)
            case "--yes":
                confirmed = true
                index += 1
            case "--json":
                // Output is always structured JSON; accepted for compatibility.
                index += 1
            default:
                if arguments[index].hasPrefix("--") {
                    throw CLIError("unknown history option: \(arguments[index])")
                }
                positionals.append(arguments[index])
                index += 1
            }
        }

        guard let subcommand = positionals.first else {
            throw CLIError("history requires a subcommand: status, list, show, enable, disable, pause, resume, delete")
        }

        let verb: String
        var args: [String: Any] = [:]
        switch subcommand {
        case "status":
            verb = "history_status"
        case "list":
            verb = "history_query"
            if positionals.count > 1 {
                guard let limit = Int(positionals[1]), limit >= 1, limit <= 200 else {
                    throw CLIError("history list count must be an integer between 1 and 200")
                }
                args["limit"] = limit
            }
        case "show":
            guard positionals.count > 1, let sequence = Int(positionals[1]), sequence >= 1 else {
                throw CLIError("history show requires a sequence number >= 1")
            }
            verb = "history_query"
            args = ["limit": 1, "since_sequence": sequence, "until_sequence": sequence]
        case "enable":
            verb = "history_enable"
        case "disable":
            verb = "history_disable"
        case "pause":
            verb = "history_pause"
        case "resume":
            verb = "history_resume"
        case "delete":
            guard confirmed else {
                throw CLIError("history delete is destructive; pass --yes to confirm")
            }
            verb = "history_delete"
            args = ["confirm": true]
        default:
            throw CLIError("unknown history subcommand: \(subcommand)")
        }

        guard let socketPath else {
            throw CLIError("history requires --socket <path>")
        }

        let response = try CuaDriverClient(socketPath: socketPath, timeout: 15).send(verb: verb, args: args)
        print(try CuaDriverJSON.text(from: response))
        if let error = response["error"] as? [String: Any] {
            if let message = error["message"] as? String {
                writeStderr(message)
            }
            return 1
        }
        return 0
    }

    private struct CLIError: Error, LocalizedError {
        let message: String

        init(_ message: String) {
            self.message = message
        }

        var errorDescription: String? {
            message
        }
    }

    private static func parseServeOptions(_ arguments: [String]) throws -> ServeOptions {
        var socketPath: String?
        var pidFilePath: String?
        var index = 0

        while index < arguments.count {
            switch arguments[index] {
            case "--no-relaunch":
                index += 1
            case "--socket":
                socketPath = try value(after: "--socket", in: arguments, index: &index)
            case "--pid-file":
                pidFilePath = try value(after: "--pid-file", in: arguments, index: &index)
            default:
                throw CLIError("unknown serve option: \(arguments[index])")
            }
        }

        guard let socketPath else {
            throw CLIError("serve requires --socket <path>")
        }
        return ServeOptions(socketPath: socketPath, pidFilePath: pidFilePath)
    }

    private static func parseStatusOptions(_ arguments: [String]) throws -> StatusOptions {
        var socketPath: String?
        var pidFilePath: String?
        var index = 0

        while index < arguments.count {
            switch arguments[index] {
            case "--socket":
                socketPath = try value(after: "--socket", in: arguments, index: &index)
            case "--pid-file":
                pidFilePath = try value(after: "--pid-file", in: arguments, index: &index)
            default:
                throw CLIError("unknown status option: \(arguments[index])")
            }
        }

        guard let socketPath else {
            throw CLIError("status requires --socket <path>")
        }
        return StatusOptions(socketPath: socketPath, pidFilePath: pidFilePath)
    }

    private static func parseCallOptions(_ arguments: [String]) throws -> CallOptions {
        guard let verb = arguments.first else {
            throw CLIError("call requires a verb")
        }

        var socketPath: String?
        var screenshotOutFile: String?
        var jsonArgument: String?
        var index = 1

        while index < arguments.count {
            switch arguments[index] {
            case "--socket":
                socketPath = try value(after: "--socket", in: arguments, index: &index)
            case "--screenshot-out-file":
                screenshotOutFile = try value(after: "--screenshot-out-file", in: arguments, index: &index)
            default:
                guard !arguments[index].hasPrefix("--") else {
                    throw CLIError("unknown call option: \(arguments[index])")
                }
                guard jsonArgument == nil else {
                    throw CLIError("call accepts at most one positional JSON argument")
                }
                jsonArgument = arguments[index]
                index += 1
            }
        }

        guard let socketPath else {
            throw CLIError("call requires --socket <path>")
        }

        let args = try readCallArguments(jsonArgument)
        return CallOptions(
            verb: verb,
            args: args,
            socketPath: socketPath,
            screenshotOutFile: screenshotOutFile
        )
    }

    private static func readCallArguments(_ jsonArgument: String?) throws -> [String: Any] {
        if let jsonArgument {
            return try parseArgumentsJSON(jsonArgument)
        }

        if isatty(STDIN_FILENO) == 0 {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            if !data.isEmpty {
                return try CuaDriverJSON.object(from: data)
            }
        }

        return [:]
    }

    private static func parseArgumentsJSON(_ json: String) throws -> [String: Any] {
        guard let data = json.data(using: .utf8) else {
            throw CLIError("call JSON must be valid UTF-8")
        }
        return try CuaDriverJSON.object(from: data)
    }

    private static func writeScreenshotIfRequested(response: [String: Any], path: String?) throws {
        guard let path, let base64Image = response["image"] as? String else {
            return
        }
        guard let data = Data(base64Encoded: base64Image) else {
            throw CLIError("response image field is not valid base64")
        }
        try data.write(to: URL(fileURLWithPath: path), options: [.atomic])
    }

    private static func validateStatusResponse(_ response: [String: Any]) throws {
        // Version deliberately NOT compared to this binary's: after an app update
        // replaces the binary on disk, the old daemon must still probe as alive or
        // the supervisor spirals (serve can't take the flock, status says down).
        guard response["error"] == nil,
              response["status"] as? String == "running",
              (response["version"] as? String).map({ !$0.isEmpty }) == true,
              response["pid"] is NSNumber || response["pid"] is Int
        else {
            throw CLIError("daemon returned an invalid status response")
        }
    }

    private static func value(after flag: String, in arguments: [String], index: inout Int) throws -> String {
        let valueIndex = index + 1
        guard valueIndex < arguments.count else {
            throw CLIError("\(flag) requires a value")
        }
        index += 2
        return arguments[valueIndex]
    }

    private static func writeStderr(_ message: String) {
        guard let data = (message + "\n").data(using: .utf8) else {
            return
        }
        FileHandle.standardError.write(data)
    }

    private static func errorDescription(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
