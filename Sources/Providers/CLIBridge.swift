import Foundation
import os

/// Locates and runs CLI tools like `claude-swap` and `codex-auth` safely.
enum CLIBridge {
    /// Candidate locations for `claude-swap`.
    static func claudeSwapExecutable(fileManager: FileManager = .default) -> URL? {
        let home = NSHomeDirectory()
        let candidates = [
            URL(fileURLWithPath: home).appendingPathComponent(".local/bin/claude-swap"),
            URL(fileURLWithPath: home).appendingPathComponent(".local/share/uv/tools/claude-swap/bin/claude-swap"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude-swap"),
            URL(fileURLWithPath: "/usr/local/bin/claude-swap")
        ]

        if let found = candidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) }) {
            return found
        }

        return findInPath("claude-swap")
    }

    /// Candidate locations for `codex-auth`.
    static func codexAuthExecutable(fileManager: FileManager = .default) -> URL? {
        let home = NSHomeDirectory()
        var candidates: [URL] = []

        // NVM node versions
        let nvmDir = URL(fileURLWithPath: home).appendingPathComponent(".nvm/versions/node")
        if let nodeDirs = try? fileManager.contentsOfDirectory(at: nvmDir, includingPropertiesForKeys: nil) {
            for dir in nodeDirs.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
                candidates.append(dir.appendingPathComponent("bin/codex-auth"))
            }
        }

        candidates.append(URL(fileURLWithPath: home).appendingPathComponent(".local/bin/codex-auth"))
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/codex-auth"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/codex-auth"))

        if let found = candidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) }) {
            return found
        }

        return findInPath("codex-auth")
    }

    private static func findInPath(_ binary: String) -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [binary]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !path.isEmpty else { return nil }
            let url = URL(fileURLWithPath: path)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        } catch {
            return nil
        }
    }

    /// Execute a CLI command asynchronously.
    @discardableResult
    static func run(executable: URL, arguments: [String]) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                Log.usage.info("CLIBridge: running \(executable.lastPathComponent) \(arguments.joined(separator: " "))")
                try process.run()
                process.waitUntilExit()
                let success = process.terminationStatus == 0
                Log.usage.info("CLIBridge: \(executable.lastPathComponent) exited with code \(process.terminationStatus)")
                return success
            } catch {
                Log.usage.error("CLIBridge: failed to execute \(executable.path): \(error.localizedDescription)")
                return false
            }
        }.value
    }
}
