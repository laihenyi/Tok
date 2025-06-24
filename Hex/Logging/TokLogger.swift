import Foundation
import AppKit

// A lightweight logger that writes important events to a persistent log file inside
// `~/Library/Logs/Tok/tok.log`. The log file can later be opened from the Developer
// section of the app.
//
// Only the most important, high-level events should be logged through this API to avoid
// excessive file growth. For verbose diagnostic output keep using `print`.

enum TokLogLevel: String {
    case info  = "INFO"
    case warn  = "WARN"
    case error = "ERROR"
}

struct TokLogger {
    private static let queue = DispatchQueue(label: "TokLogger")
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let logsDirectoryURL: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Tok", isDirectory: true)
        // Create directory if needed
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// URL to the main log file.
    static let logFileURL: URL = {
        logsDirectoryURL.appendingPathComponent("tok.log", isDirectory: false)
    }()

    /// Appends a line to the log file. The write is performed off the main thread.
    static func log(_ message: String, level: TokLogLevel = .info) {
        let timestamp = isoFormatter.string(from: Date())
        let line = "[\(timestamp)] [\(level.rawValue)] \(message)\n"

        // Echo to Xcode console during development
        #if DEBUG
        print(line)
        #endif

        queue.async {
            if !FileManager.default.fileExists(atPath: logFileURL.path) {
                FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: logFileURL) else { return }
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                if let data = line.data(using: .utf8) {
                    try handle.write(contentsOf: data)
                }
            } catch {
                // Silently ignore logging failures
                print("Failed to write to log file: \(error)")
            }
        }
    }

    /// Convenience helpers
    static func info(_ message: String) { log(message, level: .info) }
    static func warn(_ message: String) { log(message, level: .warn) }
    static func error(_ message: String) { log(message, level: .error) }

    /// Opens the log file with the default application (usually Console or a text editor).
    static func openLogFile() {
        NSWorkspace.shared.open(logFileURL)
    }
} 