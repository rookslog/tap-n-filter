import Foundation

enum QuickMenuSoundsChecks {
    static let groups: [(String, (QMSContext) async throws -> Void)] = [
        ("1-roster", rosterGroup),
        ("2-words", wordsGroup),
        ("3-ids", identityGroup),
        ("4-values", valuesGroup),
        ("5-laws", lawsGroup),
        ("6-engine-table", engineTableGroup),
        ("7-memory", memoryGroup),
        ("8-nothing-else-moved", QMSBaseline.group),
        ("9-symbols", symbolsGroup),
        ("R-rendered-laws", renderGroup),
        ("10-volume-travel", volumeTravelGroup),
        ("11-tray-drag-work", trayDragWorkGroup),
        ("12-switch-memory", switchMemoryGroup),
    ]

    /// `root` is the repository root; `scratch` an owned folder for library files. `only` limits the groups by name.
    static func run(root: URL, scratch: URL, only: Set<String>? = nil) async -> QMSReport {
        let report = QMSReport()
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let context = QMSContext(report: report, root: root, scratch: scratch, table: try QMSTable(root: root))
            for (name, body) in groups where only == nil || only!.contains(name) {
                await report.run(name) { try await body(context) }
            }
        } catch {
            report.group = "setup"
            report.fail("setup: \(error)")
        }
        report.printSummary()
        return report
    }
}
