import Foundation

/// Minimal logger. Writes to stderr (visible when launching the binary from a
/// terminal) and appends to ~/Library/Logs/LANCast.log so issues can be
/// diagnosed even when the app was started normally.
enum Log {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static let logFileHandle: FileHandle? = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        let url = dir.appendingPathComponent("LANCast.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: url)
        try? handle?.seekToEnd()
        return handle
    }()

    static func log(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        if let data = line.data(using: .utf8) {
            FileHandle.standardError.write(data)
            logFileHandle?.write(data)
        }
    }
}
