import XCTest
@testable import PisakaCore

final class RunCommandTests: XCTestCase {
    // MARK: - command(forFileName:absolutePath:) per extension

    func testCommandForTypeScript() {
        XCTAssertEqual(
            RunCommand.command(forFileName: "app.ts", absolutePath: "/p/app.ts"),
            "npx tsx '/p/app.ts'"
        )
        XCTAssertEqual(
            RunCommand.command(forFileName: "App.tsx", absolutePath: "/p/App.tsx"),
            "npx tsx '/p/App.tsx'"
        )
    }

    func testCommandForJavaScript() {
        XCTAssertEqual(
            RunCommand.command(forFileName: "app.js", absolutePath: "/p/app.js"),
            "node '/p/app.js'"
        )
        XCTAssertEqual(
            RunCommand.command(forFileName: "app.mjs", absolutePath: "/p/app.mjs"),
            "node '/p/app.mjs'"
        )
        XCTAssertEqual(
            RunCommand.command(forFileName: "app.cjs", absolutePath: "/p/app.cjs"),
            "node '/p/app.cjs'"
        )
    }

    func testCommandForPython() {
        XCTAssertEqual(
            RunCommand.command(forFileName: "main.py", absolutePath: "/p/main.py"),
            "python3 '/p/main.py'"
        )
    }

    func testCommandForSwift() {
        XCTAssertEqual(
            RunCommand.command(forFileName: "main.swift", absolutePath: "/p/main.swift"),
            "swift '/p/main.swift'"
        )
    }

    func testCommandForShell() {
        XCTAssertEqual(
            RunCommand.command(forFileName: "run.sh", absolutePath: "/p/run.sh"),
            "bash '/p/run.sh'"
        )
        XCTAssertEqual(
            RunCommand.command(forFileName: "run.bash", absolutePath: "/p/run.bash"),
            "bash '/p/run.bash'"
        )
    }

    func testCommandIsCaseInsensitiveOnExtension() {
        XCTAssertEqual(
            RunCommand.command(forFileName: "Main.PY", absolutePath: "/p/Main.PY"),
            "python3 '/p/Main.PY'"
        )
    }

    // MARK: - unknown / empty extension → nil

    func testCommandNilForUnknownExtension() {
        XCTAssertNil(RunCommand.command(forFileName: "readme.md", absolutePath: "/p/readme.md"))
        XCTAssertNil(RunCommand.command(forFileName: "data.json", absolutePath: "/p/data.json"))
    }

    func testCommandNilForNoExtension() {
        XCTAssertNil(RunCommand.command(forFileName: "Makefile", absolutePath: "/p/Makefile"))
        XCTAssertNil(RunCommand.command(forFileName: "", absolutePath: "/p/"))
    }

    // MARK: - canRun

    func testCanRunTrueForSupported() {
        XCTAssertTrue(RunCommand.canRun(fileName: "app.ts"))
        XCTAssertTrue(RunCommand.canRun(fileName: "app.tsx"))
        XCTAssertTrue(RunCommand.canRun(fileName: "app.js"))
        XCTAssertTrue(RunCommand.canRun(fileName: "app.mjs"))
        XCTAssertTrue(RunCommand.canRun(fileName: "app.cjs"))
        XCTAssertTrue(RunCommand.canRun(fileName: "main.py"))
        XCTAssertTrue(RunCommand.canRun(fileName: "main.swift"))
        XCTAssertTrue(RunCommand.canRun(fileName: "run.sh"))
        XCTAssertTrue(RunCommand.canRun(fileName: "run.bash"))
        XCTAssertTrue(RunCommand.canRun(fileName: "MAIN.PY"))
    }

    func testCanRunFalseForUnsupported() {
        XCTAssertFalse(RunCommand.canRun(fileName: "readme.md"))
        XCTAssertFalse(RunCommand.canRun(fileName: "Makefile"))
        XCTAssertFalse(RunCommand.canRun(fileName: ""))
    }

    // MARK: - shell quoting

    func testQuotingPathWithSpaces() {
        XCTAssertEqual(
            RunCommand.command(forFileName: "a.py", absolutePath: "/my dir/a b.py"),
            "python3 '/my dir/a b.py'"
        )
    }

    func testQuotingPathWithSingleQuote() {
        XCTAssertEqual(
            RunCommand.command(forFileName: "a.py", absolutePath: "/p/it's.py"),
            "python3 '/p/it'\\''s.py'"
        )
    }

    func testQuotingPathWithShellMetacharacters() {
        XCTAssertEqual(
            RunCommand.command(forFileName: "a.py", absolutePath: "/p/$x`y;z.py"),
            "python3 '/p/$x`y;z.py'"
        )
    }

    // MARK: - workingDirectory

    func testWorkingDirectoryUsesProjectRootWhenPresent() {
        let root = URL(fileURLWithPath: "/Users/me/project")
        let file = URL(fileURLWithPath: "/Users/me/project/src/main.py")
        XCTAssertEqual(
            RunCommand.workingDirectory(projectRoot: root, fileURL: file),
            root
        )
    }

    func testWorkingDirectoryFallsBackToFileFolderWhenNoRoot() {
        let file = URL(fileURLWithPath: "/Users/me/project/src/main.py")
        XCTAssertEqual(
            RunCommand.workingDirectory(projectRoot: nil, fileURL: file),
            file.deletingLastPathComponent()
        )
    }
}
