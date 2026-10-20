import AppKit
import Foundation

/// Explicitly CI-only: refuse before creating NSApplication, models, or windows.
@main
enum RenderedEvidenceMain {
    @MainActor
    static func main() {
        let env = ProcessInfo.processInfo.environment
        guard env["CI"] == "true", env["GITHUB_ACTIONS"] == "true" else {
            fail("Offscreen rendering is restricted to the dedicated GitHub Actions job")
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        var completed = false
        Task { @MainActor in
            do {
                try await export(environment: env)
                completed = true
            } catch {
                fail(String(describing: error))
            }
        }
        let deadline = Date(timeIntervalSinceNow: 60)
        while !completed {
            guard Date() < deadline else { fail("Offscreen exporter exceeded 60 seconds") }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
    }

    @MainActor
    private static func export(environment env: [String: String]) async throws {
        func required(_ key: String) throws -> String {
            guard let value = env[key], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw EvidenceError.invalid("Missing CI provenance: \(key)")
            }
            return value
        }
        func optional(_ key: String) -> String? { env[key].flatMap { $0.isEmpty ? nil : $0 } }
        let source = try EvidenceManifest.Source(
            checkoutSHA: required("TNF_CHECKOUT_SHA"), eventName: required("GITHUB_EVENT_NAME"),
            ref: required("GITHUB_REF"), prHeadSHA: Nullable(optional("TNF_PR_HEAD_SHA")),
            baseSHA: Nullable(optional("TNF_BASE_SHA")), baseRef: Nullable(optional("TNF_BASE_REF"))
        )
        let versions = try EvidenceManifest.Environment(
            macOS: ProcessInfo.processInfo.operatingSystemVersionString,
            swift: required("TNF_SWIFT_VERSION"), xcode: required("TNF_XCODE_VERSION")
        )
        let directory = URL(
            fileURLWithPath: env["TNF_RENDERED_EVIDENCE_DIR"] ?? "test-artifacts/rendered-evidence"
        )
        // Reject existing output rather than mixing this run with stale images.
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw EvidenceError.invalid("Evidence output directory already exists")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var images: [EvidenceManifest.Image] = []
        for state in EvidenceFixture.State.allCases {
            for theme in NativePanelRenderer.Theme.allCases {
                let fixture = try EvidenceFixture(state: state)
                defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
                images.append(try await NativePanelRenderer.render(
                    fixture: fixture, theme: theme, directory: directory
                ))
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let document = EvidenceManifest(source: source, environment: versions, images: images)
        try encoder.encode(document).write(
            to: directory.appendingPathComponent("manifest.json"), options: .atomic
        )
        print("Wrote \(images.count) fake-backed images to \(directory.path); visual approval pending")
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("Rendered evidence: \(message)\n".utf8))
        exit(1)
    }
}
