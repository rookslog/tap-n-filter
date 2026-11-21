import Foundation
@testable import SoundModel
@testable import EverydayMenu

// The only file that names the menu's tray-row layout seam.
//
// Whether a tray row puts its label above its slider, and the symbol beside the label, depend on
// the row, not on its value. The seam counts the work that decision costs, so group 11 can see
// that delivering slider values adds none:
//
//   MenuRowLayoutCounters.labelMeasurements  text-width measurements made to lay out a tray row
//   MenuRowLayoutCounters.symbolLookups      symbol images looked up or configured for the same
//
// Both are Int, count from process start, are never reset, and are readable from any thread
// without `await`. The decision stays reachable as `MenuSoundOptionTab.stacksLabel(_:)` and
// `MenuSoundOptionTab.stackedHeight`.
enum QMSRowSeam {
    static func counts() -> (measurements: Int, symbols: Int) {
        (MenuRowLayoutCounters.labelMeasurements, MenuRowLayoutCounters.symbolLookups)
    }

    static func stacks(_ tab: MenuSoundOptionTab, _ control: MenuSoundControl) -> Bool { tab.stacksLabel(control) }

    static func stackedHeight(_ tab: MenuSoundOptionTab) -> Double { tab.stackedHeight }

    /// The tab a position patch delivers while a slider is dragged (`MenuSoundData.applying(_:)`):
    /// the same row, rebuilt with a new value. Mirrors that function's construction.
    static func patched(_ tab: MenuSoundOptionTab, to value: Double) -> MenuSoundOptionTab {
        MenuSoundOptionTab(parent: tab.parent, option: tab.option, optionIndex: tab.optionIndex,
            optionCount: tab.optionCount, controls: tab.controls.map {
                MenuSoundControl(address: $0.address, title: $0.title, face: $0.face, placement: $0.placement,
                    readout: $0.readout, position: value, optionGesture: $0.optionGesture, optionChildren: $0.optionChildren)
            })
    }
}
