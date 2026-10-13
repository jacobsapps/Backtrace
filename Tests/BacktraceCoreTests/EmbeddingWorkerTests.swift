import XCTest
@testable import BacktraceCore

final class EmbeddingWorkerTests: XCTestCase {
    func worker(_ code: String, timeout: Double = 1) throws -> EmbeddingWorker {
        try EmbeddingWorker(executable: "/usr/bin/python3", arguments: ["-u", "-c", code], timeout: timeout)
    }
    func testHungWorkerTimesOutAndFreshWorkerRecovers() throws {
        let hung = try worker("import time; time.sleep(30)", timeout: 0.1)
        let start = Date()
        XCTAssertThrowsError(try hung.vector("hello world")) { error in
            XCTAssertTrue(error.localizedDescription.contains("timed out"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        let good = try worker("import sys,json; sys.stdin.readline(); print(json.dumps([0.0]*384))")
        XCTAssertEqual(try good.vector("hello world").count, 384)
    }
    func testExitMalformedWrongSizeAndOversizedResponsesFail() throws {
        for code in ["pass", "print('not json')", "print('[0.0]')", "print('x'*110000)"] {
            let instance = try worker(code)
            XCTAssertThrowsError(try instance.vector("hello world"))
        }
    }
    func testChunkedResponseAndCachedQueries() throws {
        let instance = try worker("import sys,time; sys.stdin.readline(); print('[0.0,',end='',flush=True); time.sleep(0.03); print(','.join(['0.0']*383)+']'); sys.stdin.readline()")
        XCTAssertEqual(try instance.vector("Hello world").count, 384)
        // The helper deliberately never responds to a second query. Cache must serve it.
        XCTAssertEqual(try instance.vector("hello world").count, 384)
    }
    func testCancellationInterruptsBlockedRead() async throws {
        let instance = try worker("import time; time.sleep(30)", timeout: 5)
        let task = Task.detached { try instance.vector("hello world") }
        try await Task.sleep(for: .milliseconds(80))
        let start = Date()
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }
}
