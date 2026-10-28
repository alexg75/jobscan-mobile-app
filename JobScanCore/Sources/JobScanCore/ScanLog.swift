import Foundation

/// Appends lines to jobscan.log:
/// `2026-10-28 09:26:53,864 INFO GET https://…`
public final class ScanLog: @unchecked Sendable {
    public let fileURL: URL
    /// The log is trimmed to its newest half when it grows past this size.
    let maxBytes: Int
    private let lock = NSLock()
    private let formatter: DateFormatter

    public init(fileURL: URL, maxBytes: Int = 1_000_000) {
        self.fileURL = fileURL
        self.maxBytes = maxBytes
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss,SSS"
    }

    public func info(_ message: String) { write("INFO", message) }
    public func error(_ message: String) { write("ERROR", message) }

    private func write(_ level: String, _ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = "\(formatter.string(from: Date())) \(level) \(message)\n"
        let data = Data(line.utf8)
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        handle.seekToEndOfFile()
        handle.write(data)
        let size = handle.offsetInFile
        handle.closeFile()
        if size > UInt64(maxBytes) { trim() }
    }

    private func trim() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        var tail = data.suffix(maxBytes / 2)
        if let newline = tail.firstIndex(of: UInt8(ascii: "\n")) {
            tail = tail[tail.index(after: newline)...]
        }
        try? Data(tail).write(to: fileURL, options: .atomic)
    }

    /// The last `maxLines` lines of the log.
    public func tail(maxLines: Int = 400) -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return "" }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(maxLines + 1).joined(separator: "\n").trimmingCharacters(in: .newlines)
    }
}
