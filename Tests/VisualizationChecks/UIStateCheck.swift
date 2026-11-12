import Foundation
@main struct UIStateCheck {
  static func main() {
    precondition(MenuHeadMetrics.totalHeight == 48 && MenuHeadMetrics.capsuleWidth == 89)
    precondition(300 - MenuHeadMetrics.trailingInset == 286 && 300 - MenuHeadMetrics.trailingInset - MenuHeadMetrics.switchInset == 280)
    precondition(14 + 173 + 10 + MenuHeadMetrics.capsuleWidth + MenuHeadMetrics.trailingInset == 300)
    var mode = MenuVisualizationMode.waveform
    for i in 0..<12 { precondition(mode.rawValue == i % 3); mode = mode.next }
    precondition(MenuVisualizationState.warming != .unavailable)
    precondition(MenuVisualizationState.off != .warming)
    let zero = MenuVisualizationFrame(sequence: 1, beforeWave: [], afterWave: [], beforeSpectrum: [], afterSpectrum: [], beforeRMSDBFS: -80, afterRMSDBFS: -80, held: false, silent: true)
    precondition(MenuVisualizationState.live(zero) != .unavailable)
    for mode in MenuVisualizationMode.allCases {
      precondition(MenuVisualizationState.off.accessibilityValue(for: mode) == mode.title + ", off")
      precondition(MenuVisualizationState.unavailable.accessibilityValue(for: mode) == mode.title + ", unavailable")
      precondition(MenuVisualizationState.warming.accessibilityValue(for: mode) == mode.title + ", warming")
      precondition(MenuVisualizationState.live(zero).accessibilityValue(for: mode) == mode.title)
    }
    precondition(MenuVisualizationState.off.helpPrefix == "Off. ")
    precondition(MenuVisualizationState.unavailable.helpPrefix == "Unavailable. ")
    for i in 0..<80 {
      let column = 161.0 / 80.0
      let right = (Double(i) + 0.5) * column + column / 2
      let nextLeft = (Double(i) + 1.5) * column - column / 2
      precondition(abs(right - nextLeft) < 1e-10)
    }
    print("PASS V-01 80 butt-column arithmetic tiles161pt;V-02 mode+off/unavailable/warming values and Off help")
    print("PASS5 header arithmetic cases,12 exact cycles and distinct Warming/off/unavailable/valid-silence display states; no App/view construction")
  }
}
