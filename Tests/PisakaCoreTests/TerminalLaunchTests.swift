import XCTest
@testable import PisakaCore

final class TerminalLaunchTests: XCTestCase {
    func testShellReturnsEnvironmentShellWhenSet() {
        XCTAssertEqual(TerminalLaunch.shell(environment: ["SHELL": "/bin/bash"]), "/bin/bash")
        XCTAssertEqual(TerminalLaunch.shell(environment: ["SHELL": "/usr/local/bin/fish"]), "/usr/local/bin/fish")
    }

    func testShellFallsBackWhenShellAbsent() {
        XCTAssertEqual(TerminalLaunch.shell(environment: [:]), "/bin/zsh")
        XCTAssertEqual(TerminalLaunch.shell(environment: ["PATH": "/usr/bin"]), "/bin/zsh")
    }

    func testShellFallsBackWhenShellEmpty() {
        XCTAssertEqual(TerminalLaunch.shell(environment: ["SHELL": ""]), "/bin/zsh")
    }

    func testShellFallsBackWhenShellWhitespaceOnly() {
        XCTAssertEqual(TerminalLaunch.shell(environment: ["SHELL": "   "]), "/bin/zsh")
        XCTAssertEqual(TerminalLaunch.shell(environment: ["SHELL": "\t\n"]), "/bin/zsh")
    }

    func testWorkingDirectoryReturnsProjectRootWhenPresent() {
        let root = URL(fileURLWithPath: "/Users/me/project")
        let home = URL(fileURLWithPath: "/Users/me")
        XCTAssertEqual(TerminalLaunch.workingDirectory(projectRoot: root, home: home), root)
    }

    func testWorkingDirectoryFallsBackToHomeWhenProjectRootNil() {
        let home = URL(fileURLWithPath: "/Users/me")
        XCTAssertEqual(TerminalLaunch.workingDirectory(projectRoot: nil, home: home), home)
    }
}
