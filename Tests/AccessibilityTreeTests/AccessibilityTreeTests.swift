import Foundation
import XCTest

/// Phase 3 accessibility-audit test surface.
///
/// The audit's authoritative evidence is two artifacts that this test
/// validates without re-running an in-process AppKit accessibility walk:
///
///   1. `test-artifacts/phase-3-accessibility-tree.json` — the JSON dump
///      produced by the `AccessibilityDump` executable target (see
///      `Sources/AccessibilityDump/main.swift`). The executable runs as a
///      real `NSApplication` with a key window; that environment is what
///      lets AppKit's accessibility shadow tree materialize. Trying to do
///      the same walk inside an `XCTest` CLI binary fails — there is no
///      `NSApplication`, no key window, and no WindowServer connection.
///      ADR-011 documents the split.
///
///   2. The SwiftUI source under `Sources/UI/`, which is the source of
///      truth for `.accessibilityLabel(_:)` and `.accessibilityValue(_:)`
///      modifier application. Source-level grep catches missing or empty
///      labels in CI without depending on AppKit reflection.
///
/// The manual VoiceOver pass documented in
/// `docs/audits/verification/phase-3-accessibility.md` remains the
/// authoritative interactive check; this XCTest is the cheap CI gate that
/// keeps the artifact honest and the source convention enforced.
final class AccessibilityTreeTests: XCTestCase {

    // MARK: Committed-artifact validation

    func test_dump_artifact_exists_and_parses() throws {
        let data = try Data(contentsOf: artifactURL())
        let _ = try JSONDecoder().decode(AccessibilityDumpDocument.self, from: data)
    }

    func test_dump_environment_metadata_is_present() throws {
        let dump = try loadDump()
        XCTAssertFalse(dump.environment.hostingMode.isEmpty)
        XCTAssertEqual(
            dump.environment.adrReference,
            "docs/decisions/ADR-011-no-xcui-in-spm.md"
        )
        // generatedAt and macOSVersion now live in the gitignored sidecar
        // `phase-3-accessibility-diagnostics.json` so the committed tree
        // artifact stays deterministic across regenerations on different
        // hosts. See the AccessibilityDump executable for the split.
    }

    /// The structural counts in the dump have to be plausible for a control
    /// panel showing one EQ + one Reverb. If the dump has near-zero
    /// children, the executable target ran in an environment that did not
    /// materialize the shadow tree, and the committed artifact is stale.
    func test_dump_has_plausible_structural_counts() throws {
        let dump = try loadDump()
        XCTAssertGreaterThanOrEqual(
            dump.counts.totalNodes, 10,
            "Dump should contain at least 10 nodes (source picker, two effect rows with sliders, two menu buttons). Re-run `swift run tap-n-filter-a11y-dump` from a GUI session and recommit."
        )
        XCTAssertGreaterThanOrEqual(
            dump.counts.interactiveElements, 8,
            "Dump should contain at least 8 interactive elements (source picker + several sliders + two menu buttons). Re-run `swift run tap-n-filter-a11y-dump` from a GUI session."
        )
        XCTAssertGreaterThanOrEqual(
            dump.counts.sliders, 3,
            "Dump should contain at least 3 sliders (wet/dry plus at least one parameter slider per effect row)."
        )
        XCTAssertGreaterThanOrEqual(
            dump.counts.popUpButtons, 1,
            "Dump should contain at least one popup button (the source picker)."
        )
    }

    /// The expected menu-button labels are stable strings the SwiftUI source
    /// attaches via `.accessibilityLabel(_:)`. They are the small set the
    /// KVC API reliably surfaces; their presence proves the dump captured
    /// the menubar UI's two action buttons.
    func test_dump_contains_expected_action_buttons() throws {
        let dump = try loadDump()
        let labels = dump.tree.flattenedLabels()
        XCTAssertTrue(
            labels.contains("Add Effect"),
            "Expected an 'Add Effect' button label in the dump; found: \(labels.sorted())"
        )
        XCTAssertTrue(
            labels.contains("Presets"),
            "Expected a 'Presets' menu button label in the dump; found: \(labels.sorted())"
        )
    }

    /// Runs against newly generated hosted evidence, not the older committed
    /// tree. KVC labels are best-effort; full VoiceOver/focus remain manual.
    func test_fresh_dump_contains_expanded_parameter_fields() throws {
        guard ProcessInfo.processInfo.environment["TNF_REQUIRE_PARAMETER_A11Y"] == "1" else {
            throw XCTSkip("Fresh parameter tree check runs after hosted macos-26 regeneration")
        }
        let nodes = try loadDump().tree.flattenedNodes()
        XCTAssertGreaterThanOrEqual(nodes.filter { $0.role == "AXTextField" }.count, 4)
        // Hosted PNG a8036be/39425113185 visibly contains all four Reset
        // buttons (and Start/Quit), but this KVC reader omits them. Do not
        // mistake reader coverage for the native VoiceOver contract.
    }

    // MARK: Source-level label discipline

    /// Every `.accessibilityLabel("...")` with a literal string argument in
    /// `Sources/UI/` must use a non-empty literal. This catches the most
    /// common mistake the runtime audit cannot reliably catch headless: a
    /// developer adds `.accessibilityLabel("")` or copy-pastes a row and
    /// leaves a placeholder.
    ///
    /// Dynamic arguments (e.g. `.accessibilityLabel(node.displayName)`) are
    /// not parsed; the convention is that those values are never empty at
    /// runtime, and the manual VoiceOver pass is the backstop.
    func test_source_accessibility_label_literals_are_non_empty() throws {
        let uiDirectory = sourcesRoot().appendingPathComponent("UI")
        let swiftFiles = try filesUnder(uiDirectory, extension: "swift")
        XCTAssertFalse(
            swiftFiles.isEmpty,
            "Expected SwiftUI source files under \(uiDirectory.path)"
        )

        let pattern = #"\.accessibilityLabel\(\s*"([^"]*)"\s*\)"#
        let regex = try NSRegularExpression(pattern: pattern)

        var emptyMatches: [String] = []
        var matchCount = 0
        for file in swiftFiles {
            let contents = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(contents.startIndex..., in: contents)
            regex.enumerateMatches(in: contents, range: range) { result, _, _ in
                guard let result, result.numberOfRanges >= 2 else { return }
                matchCount += 1
                guard let captureRange = Range(result.range(at: 1), in: contents) else {
                    return
                }
                let captured = String(contents[captureRange])
                if captured.isEmpty {
                    emptyMatches.append(file.lastPathComponent)
                }
            }
        }
        XCTAssertGreaterThan(
            matchCount, 0,
            "Expected at least one literal `.accessibilityLabel(\"...\")` call in Sources/UI/; found none."
        )
        XCTAssertTrue(
            emptyMatches.isEmpty,
            "Files with empty .accessibilityLabel(\"\"): \(emptyMatches.sorted())"
        )
    }

    /// Every literal `.accessibilityValue("...")` argument must also be
    /// non-empty. Sliders and pickers benefit most from this — VoiceOver
    /// reads the value aloud when the user lands on the control.
    func test_source_accessibility_value_literals_are_non_empty() throws {
        let uiDirectory = sourcesRoot().appendingPathComponent("UI")
        let swiftFiles = try filesUnder(uiDirectory, extension: "swift")
        let pattern = #"\.accessibilityValue\(\s*"([^"]*)"\s*\)"#
        let regex = try NSRegularExpression(pattern: pattern)

        var emptyMatches: [String] = []
        for file in swiftFiles {
            let contents = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(contents.startIndex..., in: contents)
            regex.enumerateMatches(in: contents, range: range) { result, _, _ in
                guard let result, result.numberOfRanges >= 2 else { return }
                guard let captureRange = Range(result.range(at: 1), in: contents) else {
                    return
                }
                if contents[captureRange].isEmpty {
                    emptyMatches.append(file.lastPathComponent)
                }
            }
        }
        XCTAssertTrue(
            emptyMatches.isEmpty,
            "Files with empty .accessibilityValue(\"\"): \(emptyMatches.sorted())"
        )
    }

    // MARK: Helpers

    private func loadDump() throws -> AccessibilityDumpDocument {
        let data = try Data(contentsOf: artifactURL())
        return try JSONDecoder().decode(AccessibilityDumpDocument.self, from: data)
    }

    /// Path the verification subagent reads. Resolved relative to the
    /// package root, which is the working directory `swift test` uses.
    private func artifactURL() -> URL {
        return packageRoot()
            .appendingPathComponent("test-artifacts/phase-3-accessibility-tree.json")
    }

    /// Walks up from this test file (`#filePath`) to the package root, so
    /// the test works regardless of the working directory. `swift test`
    /// runs with `cwd == package root`, but resolving from `#filePath`
    /// keeps the test resilient to future invocation patterns.
    private func packageRoot(file: StaticString = #filePath) -> URL {
        // Tests/AccessibilityTreeTests/AccessibilityTreeTests.swift
        //   -> Tests/AccessibilityTreeTests/
        //   -> Tests/
        //   -> <package root>
        let here = URL(fileURLWithPath: "\(file)")
        return here
            .deletingLastPathComponent() // AccessibilityTreeTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // package root
    }

    private func sourcesRoot() -> URL {
        return packageRoot().appendingPathComponent("Sources")
    }

    private func filesUnder(_ directory: URL, extension ext: String) throws -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var out: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == ext {
            out.append(url)
        }
        return out.sorted { $0.path < $1.path }
    }
}

// MARK: - Dump document shape
//
// Mirrors `Sources/AccessibilityDump/main.swift`'s `DumpDocument`. Decoded
// independently so this test target does not need to link the executable.

private struct AccessibilityDumpDocument: Decodable {
    struct Environment: Decodable {
        let hostingMode: String
        let adrReference: String
    }
    struct Counts: Decodable {
        let totalNodes: Int
        let interactiveElements: Int
        let sliders: Int
        let buttons: Int
        let popUpButtons: Int
        let nodesWithLabel: Int
        let nodesWithValue: Int
    }
    let environment: Environment
    let counts: Counts
    let tree: TreeNode
}

private struct TreeNode: Decodable {
    let role: String?
    let label: String?
    let value: String?
    let help: String?
    let identifier: String?
    let children: [TreeNode]

    func flattenedNodes() -> [TreeNode] {
        var nodes: [TreeNode] = []
        var stack = [self]
        while let node = stack.popLast() {
            nodes.append(node)
            stack.append(contentsOf: node.children)
        }
        return nodes
    }

    /// Returns every non-empty label found anywhere in the subtree.
    func flattenedLabels() -> Set<String> {
        var out: Set<String> = []
        var stack: [TreeNode] = [self]
        while let node = stack.popLast() {
            if let label = node.label, !label.isEmpty {
                out.insert(label)
            }
            stack.append(contentsOf: node.children)
        }
        return out
    }
}
