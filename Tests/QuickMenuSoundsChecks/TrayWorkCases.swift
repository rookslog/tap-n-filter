import Foundation
@testable import SoundModel
@testable import EverydayMenu
import SessionStore

extension QuickMenuSoundsChecks {
    // 11. Dragging a tray slider repeats no layout work. Whether the row's label sits above its
    // slider is decided once per row; after that, delivered values measure no label and look up no
    // symbol. Covers the new sounds' trays and Everyday's, whose rows take the same path.
    static func trayDragWorkGroup(_ c: QMSContext) async throws {
        let r = c.report
        let s = try await QMSSession.fresh(c.scratch.appendingPathComponent("tray/library.json"))
        // The stacked layout each row has in the reviewed renders: "Where you stand" above its
        // slider, the others on one line.
        let rows: [(sound: String, choice: String, option: String, stacked: Bool)] = [
            ("Big space", "Space", "Hall", true), ("Big space", "Space", "Church", true),
            ("Old recording", "Era", "Vinyl", false), ("Old recording", "Era", "Tape", false),
            ("Everyday", "Place", "Corner", false), ("Everyday", "Device", "Radio", false),
        ]
        func tab(_ target: String, _ option: String) async throws -> MenuSoundOptionTab? {
            try card(MenuSoundData(library: try await s.session.snapshot()), target).optionTabs.first { $0.option.title == option }
        }
        let values = (0...20).map { Double($0) / 20 }
        for row in rows {
            let label = "\(row.sound) \(row.option)"
            let target = "tray." + label.replacingOccurrences(of: " ", with: "-").lowercased()
            try await s.select(row.sound, on: target)
            try await s.choose(row.choice, row.option, on: target)
            guard let first = try await tab(target, row.option), let control = first.controls.first else {
                r.fail("\(label) shows a tray with a slider"); continue
            }
            // The first decision for this row may measure.
            let stacked = QMSRowSeam.stacks(first, control)
            let height = QMSRowSeam.stackedHeight(first)
            r.check(stacked == row.stacked, "\(label) \(control.title) label \(row.stacked ? "sits above" : "sits beside") its slider")
            let before = QMSRowSeam.counts()
            r.check(before.measurements > 0, "the layout seam has counted a label measurement once a tray row is decided")

            var decisions: Set<String> = []
            for value in values {
                // A position patch, as the menu receives each value while the slider is dragged.
                let patched = QMSRowSeam.patched(first, to: value)
                decisions.insert("\(QMSRowSeam.stacks(patched, patched.controls[0]))/\(QMSRowSeam.stackedHeight(patched))")
                // A full reprojection of the library, as a state publication during the drag delivers it.
                let result = try await s.moveChild(row.choice, row.option, on: target, to: value)
                if result == .superseded { r.fail("\(label) slider move to \(value) was refused while its option is chosen") }
                guard let fresh = try await tab(target, row.option), let freshControl = fresh.controls.first else {
                    r.fail("\(label) keeps its tray at \(value)"); continue
                }
                decisions.insert("\(QMSRowSeam.stacks(fresh, freshControl))/\(QMSRowSeam.stackedHeight(fresh))")
            }
            let after = QMSRowSeam.counts()
            r.check(decisions == ["\(stacked)/\(height)"], "\(label) layout stays the same at every value, got \(decisions.sorted())")
            r.check(after.measurements == before.measurements,
                    "\(label): \(values.count) delivered values measure no label, got \(after.measurements - before.measurements) measurements")
            r.check(after.symbols == before.symbols,
                    "\(label): \(values.count) delivered values look up no symbol, got \(after.symbols - before.symbols) lookups")
            _ = try await s.moveChild(row.choice, row.option, on: target, to: 0.5)
        }
    }
}
