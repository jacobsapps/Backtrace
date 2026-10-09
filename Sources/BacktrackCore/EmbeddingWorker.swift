import Foundation
import Darwin

/// Bounded, cancellable stdio protocol to one persistent local ONNX process.
/// Internal construction parameters allow real subprocess fault-injection tests.
final class EmbeddingWorker {
    let process = Process(), input = Pipe(), output = Pipe()
    private let timeout: TimeInterval
    private var cached: [String: [Float]] = [:]
    private var order: [String] = []

    init(executable: String = SemanticIndexer.python,
         arguments: [String] = ["-B", SemanticIndexer.script, "--serve"],
         timeout: TimeInterval = 5) throws {
        self.timeout = timeout
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw SearchFailure("Local semantic runtime is not installed.")
        }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Nonblocking pipes keep both reads and writes within the deadline.
        let readFD = output.fileHandleForReading.fileDescriptor
        let writeFD = input.fileHandleForWriting.fileDescriptor
        guard fcntl(readFD, F_SETFL, fcntl(readFD, F_GETFL) | O_NONBLOCK) != -1,
              fcntl(writeFD, F_SETFL, fcntl(writeFD, F_GETFL) | O_NONBLOCK) != -1,
              fcntl(writeFD, F_SETNOSIGPIPE, 1) != -1 else {
            stop()
            throw SearchFailure("Could not configure the semantic worker pipes.")
        }
    }
    deinit { stop() }
    private func stop() {
        try? input.fileHandleForWriting.close()
        // This process is owned exclusively by this worker, never a user terminal.
        // SIGKILL also handles a hung helper that ignores graceful termination.
        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        try? output.fileHandleForReading.close()
    }
    private func waitReady(_ fd: Int32, _ events: Int16, until deadline: UInt64) throws {
        while true {
            try Task.checkCancellation()
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw SearchFailure("Semantic worker timed out; keyword search is still available.") }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let remaining = Int32(min(50, max(1, (deadline - now) / 1_000_000)))
            let result = poll(&descriptor, 1, remaining)
            if result > 0 {
                guard descriptor.revents & Int16(POLLNVAL) == 0 else { throw SearchFailure("Semantic worker pipe closed.") }
                return // read/write handles EOF, POLLHUP and POLLERR explicitly.
            }
            if result < 0 && errno != EINTR { throw SearchFailure("Semantic worker pipe failed.") }
        }
    }
    func vector(_ query: String) throws -> [Float] {
        do { return try request(query) }
        catch { stop(); throw error } // No retry can consume a stale/partial response.
    }
    private func request(_ query: String) throws -> [Float] {
        try Task.checkCancellation()
        let key = SearchEngine.normalize(query).trimmingCharacters(in: .whitespacesAndNewlines)
        if let vector = cached[key] { return vector }
        guard process.isRunning else { throw SearchFailure("Local semantic worker stopped.") }
        var request = try JSONSerialization.data(withJSONObject: ["query": query]); request.append(10)
        guard request.count <= 16_384 else { throw SearchFailure("Query is too long for semantic search.") }
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0.001, timeout) * 1_000_000_000)
        let writeFD = input.fileHandleForWriting.fileDescriptor
        var offset = 0
        while offset < request.count {
            try waitReady(writeFD, Int16(POLLOUT), until: deadline)
            let count = request.withUnsafeBytes { bytes in
                Darwin.write(writeFD, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if count > 0 { offset += count }
            else if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            else { throw SearchFailure("Local semantic worker stopped reading queries.") }
        }
        let readFD = output.fileHandleForReading.fileDescriptor
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while !data.contains(10) {
            try waitReady(readFD, Int16(POLLIN), until: deadline)
            let count = Darwin.read(readFD, &buffer, buffer.count)
            if count > 0 { data.append(contentsOf: buffer.prefix(count)) }
            else if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            else { throw SearchFailure("Local semantic worker stopped responding.") }
            guard data.count < 100_000 else { throw SearchFailure("Invalid semantic worker response.") }
        }
        try Task.checkCancellation()
        let vector = try JSONDecoder().decode([Float].self, from: data)
        guard vector.count == SemanticIndexer.dimension, vector.allSatisfy({ $0.isFinite }) else {
            throw SearchFailure("Invalid embedding dimensions.")
        }
        cached[key] = vector; order.append(key)
        if order.count > 24 { cached.removeValue(forKey: order.removeFirst()) }
        return vector
    }
}
