import Foundation

/// Immediate, unbuffered debug log to /tmp/hermesmini.log.
/// (print() buffers on non-tty stdout and NSLog wasn't visible via `log show`
/// for this process, so a FileHandle write is the reliable channel.)
func hmLog(_ message: String) {
    let line = "[\(Date())] \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    let url = URL(fileURLWithPath: "/tmp/hermesmini.log")
    do {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(data)
    } catch {
        try? data.write(to: url)
    }
}
