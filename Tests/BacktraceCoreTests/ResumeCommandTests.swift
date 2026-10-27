import XCTest
@testable import BacktraceCore

final class ResumeCommandTests: XCTestCase {
    func testDefaultModeAddsNoPermissionOverridesForEitherProvider() {
        for provider in ["codex", "claude"] {
            let session = Session(id: "test", provider: provider, title: "Test", updated: 0)
            let cli = provider == "claude" ? "claude --resume" : "codex resume"
            XCTAssertEqual(session.command, "cd -- '/tmp' && \(cli) '\(session.sessionID)'")
            XCTAssertEqual(session.resumeCommand(yolo: false), session.command)
        }
    }

    func testExplicitYOLOUsesProviderSpecificFlagsAndExactID() {
        for (provider, cli, flag) in [
            ("codex", "codex resume", "--dangerously-bypass-approvals-and-sandbox"),
            ("claude", "claude --resume", "--dangerously-skip-permissions")
        ] {
            let session = Session(id: "cache-id", sessionID: "native-id", provider: provider,
                                  title: "Not the ID", updated: 0)
            XCTAssertEqual(session.resumeCommand(yolo: true), "cd -- '/tmp' && \(cli) 'native-id' \(flag)")
            XCTAssertFalse(session.command.contains("dangerously"))
        }
    }

    func testBothModesPreserveShellQuoting() {
        for provider in ["codex", "claude"] {
            for yolo in [false, true] {
                let session = Session(id: "test", sessionID: "id'$(echo not-executed)", provider: provider,
                                      cwd: "/tmp/it's $(echo not-executed)", title: "Test", updated: 0)
                let command = session.resumeCommand(yolo: yolo)
                XCTAssertTrue(command.hasPrefix("cd -- '/tmp/it'\\''s $(echo not-executed)' && "))
                XCTAssertTrue(command.contains(" 'id'\\''$(echo not-executed)'"))
            }
        }
    }
}
