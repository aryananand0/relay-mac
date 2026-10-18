import Foundation

/// Writes timestamped lines to stdout and ~/Library/Logs/Relay/relay.log.
enum Log {
    static let fileURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Relay/relay.log")

    private static let queue = DispatchQueue(label: "relay.log")

    private static let handle: FileHandle? = {
        let fm = FileManager.default
        try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let size = (try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
        if size > 1_000_000 || !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        let h = try? FileHandle(forWritingTo: fileURL)
        h?.seekToEndOfFile()
        return h
    }()

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func info(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            let data = Data(line.utf8)
            FileHandle.standardOutput.write(data)
            handle?.write(data)
        }
    }
}
