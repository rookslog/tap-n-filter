import Foundation
import AppKit
@testable import SoundModel
@testable import EverydayMenu
import SessionStore

/// Delivers library states to a real menu presentation and evaluates the tray row's own views, the
/// way the menu redraws a row when a slider value arrives. Main actor, as the menu is.
@MainActor final class QMSTrayRowProbe {
    let target: String, option: String
    private var state: MenuPresentation?

    init(target: String, option: String) { self.target = target; self.option = option }

    /// One delivered state: a publication replaces the menu's data; a position patch rebuilds the tab
    /// with a new value (`patchedTo`). Either way the row and its tab are drawn through their own `body`.
    func deliver(_ snapshot: LibrarySnapshot, patchedTo value: Double? = nil) -> (stacked: Bool, height: Double, title: String)? {
        if let state { state.snapshot = MenuSoundData(library: snapshot) }
        else { state = MenuPresentation(snapshot: snapshot, glyph: NSImage(size: NSSize(width: 16, height: 16))) { _ in } }
        guard let state, let card = state.snapshot.assignments.first(where: { $0.bundleIdentifier == target }),
              let published = card.optionTabs.first(where: { $0.option.title == option }) else { return nil }
        let tab = value.map { QMSRowSeam.patched(published, to: $0) } ?? published
        guard let control = tab.controls.first else { return nil }
        _ = MenuOptionTab(state: state, assignment: card, tab: tab).body
        _ = MenuOptionControlRow(state: state, assignment: card, tab: tab, control: control, index: 0).body
        return (tab.stacksLabel(control), tab.stackedHeight, control.title)
    }
}

extension QuickMenuSoundsChecks {
    // 11. Dragging a tray slider repeats no layout work. Whether the row's label sits above its
    // slider, and the symbol beside it, are decided once per row; after that, delivered values
    // measure no label and look up no symbol. The row is drawn through its own view code, so work
    // the row does itself is counted too. Covers the new sounds' trays and Everyday's.
    static func trayDragWorkGroup(_ c: QMSContext) async throws {
        let r = c.report

        // The counters see only work done through the row cache. The row view must take its symbol and
        // its layout from that cache alone, so its source may not look either up by itself.
        let rowSource = c.root.appendingPathComponent("Sources/EverydayMenu/MenuOptionTab.swift")
        if let text = try? String(contentsOf: rowSource, encoding: .utf8) {
            for direct in ["optionSymbol(", "NSImage(", "size(withAttributes", "NSFont", "oneLineTrackWidth("] {
                r.check(!text.contains(direct), "the tray row view takes its symbol and layout from the row cache only (it calls \(direct))")
            }
        } else { r.fail("the tray row view's source is readable at Sources/EverydayMenu/MenuOptionTab.swift") }

        let s = try await QMSSession.fresh(c.scratch.appendingPathComponent("tray/library.json"))
        // The layout each row has in the reviewed renders: "Where you stand" above its slider, the others on one line.
        let rows: [(sound: String, choice: String, option: String, stacked: Bool)] = [
            ("Big space", "Space", "Hall", true), ("Big space", "Space", "Church", true),
            ("Old recording", "Era", "Vinyl", false), ("Old recording", "Era", "Tape", false),
            ("Everyday", "Place", "Corner", false), ("Everyday", "Device", "Radio", false),
        ]
        let values = (0...20).map { Double($0) / 20 }
        for row in rows {
            let label = "\(row.sound) \(row.option)"
            let target = "tray." + label.replacingOccurrences(of: " ", with: "-").lowercased()
            try await s.select(row.sound, on: target)
            try await s.choose(row.choice, row.option, on: target)
            let probe = await QMSTrayRowProbe(target: target, option: row.option)
            // The first draw of this row may measure.
            let opened = try await s.session.snapshot()
            guard let first = await probe.deliver(opened) else {
                r.fail("\(label) shows a tray with a slider"); continue
            }
            r.check(first.stacked == row.stacked, "\(label) \(first.title) label \(row.stacked ? "sits above" : "sits beside") its slider")
            let before = QMSRowSeam.counts()
            r.check(before.measurements > 0 && before.symbols > 0, "the layout seam has counted a measurement and a symbol lookup once a tray row is drawn")

            var layouts: Set<String> = []
            for value in values {
                let result = try await s.moveChild(row.choice, row.option, on: target, to: value)
                if result == .superseded { r.fail("\(label) slider move to \(value) was refused while its option is chosen") }
                let snapshot = try await s.session.snapshot()
                // A position patch, then a publication, each drawn through the row's own views.
                for patch in [Optional(value), nil] {
                    guard let drawn = await probe.deliver(snapshot, patchedTo: patch) else { r.fail("\(label) keeps its tray at \(value)"); continue }
                    layouts.insert("\(drawn.stacked)/\(drawn.height)")
                }
            }
            let after = QMSRowSeam.counts()
            r.check(layouts == ["\(first.stacked)/\(first.height)"], "\(label) layout stays the same at every value, got \(layouts.sorted())")
            r.check(after.measurements == before.measurements,
                    "\(label): \(values.count) delivered values measure no label, got \(after.measurements - before.measurements) measurements")
            r.check(after.symbols == before.symbols,
                    "\(label): \(values.count) delivered values look up no symbol, got \(after.symbols - before.symbols) lookups")
            _ = try await s.moveChild(row.choice, row.option, on: target, to: 0.5)
        }
    }
}
