import XCTest
@testable import PisakaCore

final class TestCommandTests: XCTestCase {
    // Convenience: build evidence from a root listing and/or manifest contents.
    private func evidence(
        root: Set<String> = [],
        manifests: [String: String] = [:]
    ) -> ProjectTestEvidence {
        ProjectTestEvidence(rootEntryNames: root, manifests: manifests)
    }

    // MARK: - isTestFile per language

    func testIsTestFileJavaScriptTypeScript() {
        XCTAssertTrue(TestCommand.isTestFile(fileName: "foo.test.js"))
        XCTAssertTrue(TestCommand.isTestFile(fileName: "foo.spec.js"))
        XCTAssertTrue(TestCommand.isTestFile(fileName: "Button.test.jsx"))
        XCTAssertTrue(TestCommand.isTestFile(fileName: "foo.test.ts"))
        XCTAssertTrue(TestCommand.isTestFile(fileName: "foo.spec.ts"))
        XCTAssertTrue(TestCommand.isTestFile(fileName: "Button.spec.tsx"))
        XCTAssertTrue(TestCommand.isTestFile(fileName: "foo.test.mjs"))
        XCTAssertTrue(TestCommand.isTestFile(fileName: "foo.test.mts"))
        XCTAssertTrue(TestCommand.isTestFile(fileName: "foo.spec.cts"))
        XCTAssertFalse(TestCommand.isTestFile(fileName: "foo.js"))
        XCTAssertFalse(TestCommand.isTestFile(fileName: "foo.ts"))
        XCTAssertFalse(TestCommand.isTestFile(fileName: "testing.ts"))
    }

    func testIsTestFilePython() {
        XCTAssertTrue(TestCommand.isTestFile(fileName: "test_foo.py"))
        XCTAssertTrue(TestCommand.isTestFile(fileName: "foo_test.py"))
        XCTAssertFalse(TestCommand.isTestFile(fileName: "foo.py"))
        XCTAssertFalse(TestCommand.isTestFile(fileName: "contest.py"))
    }

    func testIsTestFileRuby() {
        XCTAssertTrue(TestCommand.isTestFile(fileName: "foo_spec.rb"))
        XCTAssertTrue(TestCommand.isTestFile(fileName: "foo_test.rb"))
        XCTAssertFalse(TestCommand.isTestFile(fileName: "foo.rb"))
    }

    func testIsTestFilePHP() {
        XCTAssertTrue(TestCommand.isTestFile(fileName: "FooTest.php"))
        XCTAssertFalse(TestCommand.isTestFile(fileName: "Foo.php"))
    }

    func testIsTestFileElixir() {
        XCTAssertTrue(TestCommand.isTestFile(fileName: "foo_test.exs"))
        XCTAssertFalse(TestCommand.isTestFile(fileName: "foo.exs"))
        XCTAssertFalse(TestCommand.isTestFile(fileName: "foo.ex"))
    }

    func testIsTestFileGo() {
        XCTAssertTrue(TestCommand.isTestFile(fileName: "foo_test.go"))
        XCTAssertFalse(TestCommand.isTestFile(fileName: "foo.go"))
    }

    func testIsTestFileSwift() {
        XCTAssertTrue(TestCommand.isTestFile(fileName: "FooTests.swift"))
        XCTAssertTrue(TestCommand.isTestFile(fileName: "FooTest.swift"))
        XCTAssertFalse(TestCommand.isTestFile(fileName: "Foo.swift"))
    }

    func testIsTestFileRust() {
        XCTAssertTrue(TestCommand.isTestFile(fileName: "foo.rs"))
        XCTAssertTrue(TestCommand.isTestFile(fileName: "lib.rs"))
        XCTAssertFalse(TestCommand.isTestFile(fileName: "foo.txt"))
    }

    // MARK: - JS/TS runner selection

    func testVitestBeatsJestWhenBothPresent() {
        let e = evidence(
            root: ["vitest.config.ts", "jest.config.js"],
            manifests: ["package.json": #"{ "devDependencies": { "vitest": "1.0", "jest": "29" } }"#]
        )
        XCTAssertEqual(
            TestCommand.command(forFileName: "a.test.ts", absolutePath: "/p/a.test.ts", evidence: e),
            .command("npx vitest run '/p/a.test.ts'")
        )
    }

    func testVitestViaPackageJSON() {
        let e = evidence(manifests: ["package.json": #"{ "devDependencies": { "vitest": "1.0" } }"#])
        XCTAssertEqual(
            TestCommand.command(forFileName: "a.test.ts", absolutePath: "/p/a.test.ts", evidence: e),
            .command("npx vitest run '/p/a.test.ts'")
        )
    }

    func testJestSelected() {
        let e = evidence(root: ["jest.config.js"])
        XCTAssertEqual(
            TestCommand.command(forFileName: "a.test.js", absolutePath: "/p/a.test.js", evidence: e),
            .command("npx jest '/p/a.test.js'")
        )
    }

    func testJestViaPackageJSON() {
        let e = evidence(manifests: ["package.json": #"{ "devDependencies": { "jest": "29" } }"#])
        XCTAssertEqual(
            TestCommand.command(forFileName: "a.spec.js", absolutePath: "/p/a.spec.js", evidence: e),
            .command("npx jest '/p/a.spec.js'")
        )
    }

    func testJestBeatsMochaWhenBothPresent() {
        let e = evidence(root: ["jest.config.js", ".mocharc.json"])
        XCTAssertEqual(
            TestCommand.command(forFileName: "a.test.js", absolutePath: "/p/a.test.js", evidence: e),
            .command("npx jest '/p/a.test.js'")
        )
    }

    func testRunnerResolvesForMtsCts() {
        let e = evidence(root: ["jest.config.js"])
        XCTAssertEqual(
            TestCommand.command(forFileName: "a.test.mts", absolutePath: "/p/a.test.mts", evidence: e),
            .command("npx jest '/p/a.test.mts'")
        )
        XCTAssertEqual(
            TestCommand.command(forFileName: "a.spec.cts", absolutePath: "/p/a.spec.cts", evidence: e),
            .command("npx jest '/p/a.spec.cts'")
        )
    }

    func testMochaSelected() {
        let e = evidence(root: [".mocharc.json"])
        XCTAssertEqual(
            TestCommand.command(forFileName: "a.test.js", absolutePath: "/p/a.test.js", evidence: e),
            .command("npx mocha '/p/a.test.js'")
        )
    }

    /// Detection is a `.mocharc` *prefix* check over the root listing, so every
    /// config variant counts — not just the `.json` one.
    func testMochaSelectedForYAMLConfigVariant() {
        let e = evidence(root: [".mocharc.yml"])
        XCTAssertEqual(
            TestCommand.command(forFileName: "a.test.js", absolutePath: "/p/a.test.js", evidence: e),
            .command("npx mocha '/p/a.test.js'")
        )
    }

    func testMochaViaPackageJSON() {
        let e = evidence(manifests: ["package.json": #"{ "devDependencies": { "mocha": "10" } }"#])
        XCTAssertEqual(
            TestCommand.command(forFileName: "a.test.js", absolutePath: "/p/a.test.js", evidence: e),
            .command("npx mocha '/p/a.test.js'")
        )
    }

    func testJavaScriptUndetectedOnEmptyEvidence() {
        XCTAssertEqual(
            TestCommand.command(forFileName: "a.test.js", absolutePath: "/p/a.test.js", evidence: evidence()),
            .runnerUndetected
        )
        XCTAssertEqual(
            TestCommand.command(forFileName: "a.test.ts", absolutePath: "/p/a.test.ts", evidence: evidence()),
            .runnerUndetected
        )
    }

    // MARK: - single-runner languages (always resolve, incl. empty evidence)

    func testPythonAlwaysResolves() {
        XCTAssertEqual(
            TestCommand.command(forFileName: "test_a.py", absolutePath: "/p/test_a.py", evidence: evidence()),
            .command("pytest '/p/test_a.py'")
        )
    }

    func testRubySpecNoGemfileUsesRspec() {
        XCTAssertEqual(
            TestCommand.command(forFileName: "a_spec.rb", absolutePath: "/p/a_spec.rb", evidence: evidence()),
            .command("rspec '/p/a_spec.rb'")
        )
    }

    func testRubySpecWithGemfileUsesBundleExecRspec() {
        let e = evidence(root: ["Gemfile"])
        XCTAssertEqual(
            TestCommand.command(forFileName: "a_spec.rb", absolutePath: "/p/a_spec.rb", evidence: e),
            .command("bundle exec rspec '/p/a_spec.rb'")
        )
    }

    func testRubyTestNoGemfileUsesRuby() {
        XCTAssertEqual(
            TestCommand.command(forFileName: "a_test.rb", absolutePath: "/p/a_test.rb", evidence: evidence()),
            .command("ruby '/p/a_test.rb'")
        )
    }

    func testRubyTestWithGemfileUsesBundleExecRuby() {
        let e = evidence(root: ["Gemfile"])
        XCTAssertEqual(
            TestCommand.command(forFileName: "a_test.rb", absolutePath: "/p/a_test.rb", evidence: e),
            .command("bundle exec ruby '/p/a_test.rb'")
        )
    }

    func testRubyDotRspecIsNotAnOverride() {
        // `.rspec` present but the filename is `*_test.rb`: the suffix decides, so
        // it stays `ruby` — `.rspec` is no longer consulted.
        let e = evidence(root: [".rspec"])
        XCTAssertEqual(
            TestCommand.command(forFileName: "a_test.rb", absolutePath: "/p/a_test.rb", evidence: e),
            .command("ruby '/p/a_test.rb'")
        )
    }

    func testRubyPathIsShellQuoted() {
        let path = "/p/my dir/a'b_spec.rb"
        XCTAssertEqual(
            TestCommand.command(forFileName: "a'b_spec.rb", absolutePath: path, evidence: evidence(root: ["Gemfile"])),
            .command("bundle exec rspec " + ShellQuote.quote(path))
        )
    }

    func testPHPAlwaysResolves() {
        XCTAssertEqual(
            TestCommand.command(forFileName: "FooTest.php", absolutePath: "/p/FooTest.php", evidence: evidence()),
            .command("./vendor/bin/phpunit '/p/FooTest.php'")
        )
    }

    func testElixirAlwaysResolves() {
        XCTAssertEqual(
            TestCommand.command(forFileName: "a_test.exs", absolutePath: "/p/a_test.exs", evidence: evidence()),
            .command("mix test '/p/a_test.exs'")
        )
    }

    func testSwiftAlwaysResolves() {
        XCTAssertEqual(
            TestCommand.command(forFileName: "FooTests.swift", absolutePath: "/p/Tests/FooTests.swift", evidence: evidence()),
            .command("swift test")
        )
    }

    // MARK: - Go / Rust directory-target

    func testGoTargetsDirectory() {
        XCTAssertEqual(
            TestCommand.command(forFileName: "a_test.go", absolutePath: "/p/pkg/a_test.go", evidence: evidence()),
            .command("go test '/p/pkg'")
        )
    }

    func testRustAlwaysResolves() {
        XCTAssertEqual(
            TestCommand.command(forFileName: "lib.rs", absolutePath: "/p/src/lib.rs", evidence: evidence()),
            .command("cargo test")
        )
    }

    // MARK: - quoting of <file> / <dir>

    func testFileQuotingWithSpaces() {
        XCTAssertEqual(
            TestCommand.command(forFileName: "a.test.js", absolutePath: "/my dir/a b.test.js",
                                evidence: evidence(root: ["jest.config.js"])),
            .command("npx jest '/my dir/a b.test.js'")
        )
    }

    func testFileQuotingWithSingleQuote() {
        XCTAssertEqual(
            TestCommand.command(forFileName: "test_a.py", absolutePath: "/p/it's.py", evidence: evidence()),
            .command("pytest '/p/it'\\''s.py'")
        )
    }

    func testDirQuotingWithMetacharacters() {
        XCTAssertEqual(
            TestCommand.command(forFileName: "a_test.go", absolutePath: "/p/$x`y;z/a_test.go", evidence: evidence()),
            .command("go test '/p/$x`y;z'")
        )
    }

    // MARK: - working directory (agrees with RunCommand)

    func testWorkingDirectoryPrefersProjectRoot() {
        let root = URL(fileURLWithPath: "/proj", isDirectory: true)
        let file = URL(fileURLWithPath: "/proj/pkg/a_test.go")
        XCTAssertEqual(
            TestCommand.workingDirectory(projectRoot: root, fileURL: file),
            RunCommand.workingDirectory(projectRoot: root, fileURL: file)
        )
        XCTAssertEqual(TestCommand.workingDirectory(projectRoot: root, fileURL: file), root)
    }

    func testWorkingDirectoryFallsBackToFileFolder() {
        let file = URL(fileURLWithPath: "/some/dir/a_test.go")
        XCTAssertEqual(
            TestCommand.workingDirectory(projectRoot: nil, fileURL: file),
            file.deletingLastPathComponent()
        )
    }

    // MARK: - unknown extension → runnerUndetected

    func testUnknownExtensionUndetected() {
        XCTAssertEqual(
            TestCommand.command(forFileName: "readme.md", absolutePath: "/p/readme.md", evidence: evidence()),
            .runnerUndetected
        )
    }
}
