import XCTest
@testable import iSmith

/// Links in the agent chat: web pages go to a tab; the agent's scheme-less file paths (with
/// spaces and `:line` suffixes) become file URLs instead of failing in the system with -50.
final class AgentLinkTests: XCTestCase {
    private func link(_ markdown: String, folder: String = "/tmp") -> AgentLink? {
        let text = try! AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        let url = text.runs.compactMap(\.link).first!
        return AgentLink(url, workingFolder: folder)
    }

    func testWebLinks() {
        XCTAssertEqual(link("[a](https://example.com/x?y=1)"), .web(URL(string: "https://example.com/x?y=1")!))
    }

    func testAbsolutePathWithSpaces() {
        XCTAssertEqual(link("[a](</Users/x/Library/Application Support/y/index.md>)"),
                       .file(URL(fileURLWithPath: "/Users/x/Library/Application Support/y/index.md")))
    }

    func testLineSuffixIsStripped() {
        XCTAssertEqual(link("[a](/abs/path/app.py:12)"), .file(URL(fileURLWithPath: "/abs/path/app.py")))
        XCTAssertEqual(link("[a](</abs/My Project/R.md:3:7>)"), .file(URL(fileURLWithPath: "/abs/My Project/R.md")))
    }

    func testRelativePathUsesWorkingFolder() {
        XCTAssertEqual(link("[a](notes/today.md)", folder: "/w/f"), .file(URL(fileURLWithPath: "/w/f/notes/today.md")))
    }

    func testBareFileWithLine() {
        // Parsed by Foundation as scheme `app.py`.
        XCTAssertEqual(link("[a](app.py:12)", folder: "/w"), .file(URL(fileURLWithPath: "/w/app.py")))
        XCTAssertEqual(link("[a](foo.swift:10:2)", folder: "/w"), .file(URL(fileURLWithPath: "/w/foo.swift")))
    }

    func testFileSchemeAndHome() {
        XCTAssertEqual(link("[a](file:///tmp/a.py:12)"), .file(URL(fileURLWithPath: "/tmp/a.py")))
        XCTAssertEqual(link("[a](~/x/y.md)"), .file(URL(fileURLWithPath: NSHomeDirectory() + "/x/y.md")))
    }

    func testOtherSchemesGoToTheSystem() {
        XCTAssertNil(link("[a](mailto:a@example.com)"))
    }
}
