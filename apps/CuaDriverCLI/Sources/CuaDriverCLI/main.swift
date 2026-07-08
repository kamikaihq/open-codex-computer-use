import Darwin
import OpenComputerUseKit

@main
enum CuaDriverMain {
    @MainActor
    static func main() {
        let exitCode = CuaDriverCLI.run(arguments: Array(CommandLine.arguments.dropFirst()))
        exit(exitCode)
    }
}
