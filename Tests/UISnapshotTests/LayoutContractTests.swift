import AVFoundation
import Capture
import Combine
import Effects
import Graph
import SwiftUI
@testable import UI
@testable import ViewModel
import NativeTestSupport
import XCTest

/// Layout-contract guard for the macOS-27 panel-collapse regression.
///
/// WHY THIS EXISTS
///
/// On macOS 27, the `MenuBarExtra(.window)` panel collapsed and the effect
/// list vanished. Root cause: `ChainEditorView`'s `ScrollView` had only a
/// `.frame(maxHeight:)` constraint with no floor. A `ScrollView` reports no
/// intrinsic height; when the window's fitting-size pass ran it resolved the
/// scroll region to zero, collapsing the whole panel. The fix added
/// `.frame(minHeight: 200, maxHeight: 440)` to the scroll region and
/// `.frame(minHeight: 420, maxHeight: 700)` to `ControlPanelView`'s root.
///
/// These tests guard the contract by hosting the view in an
/// `NSHostingController`, pinning its width to 380 pt, and asserting the
/// fitting height stays within the specified floor/cap. They exercise the
/// real SwiftUI layout pass — not a snapshot at a fixed caller-dictated
/// size — so a reintroduced collapse (fitting height -> 0) will fail them.
///
/// IMPORTANT CAVEAT
///
/// This guard catches the collapse on whatever macOS version the test runs
/// on. The macOS-27-specific manifestation requires running on macOS 27
/// (local developer machine or a self-hosted CI runner), because GitHub
/// Actions does not offer a macOS 27 image as of 2026-06. On macOS 26 and
/// earlier the panel does not collapse — the regression is OS-version-
/// specific. Running these tests on any available macOS version still
/// provides a meaningful regression guard: a refactor that removes the
/// `minHeight` floor would fail them everywhere.
@MainActor
final class LayoutContractTests: XCTestCase {

    override func setUp() async throws {
        try requireNativeTests()
        try await super.setUp()
    }

    // MARK: - Empty chain

    /// With no effects in the chain, `ControlPanelView` must still meet the
    /// 420 pt height floor declared in `docs/specs/ui.md`. This is the
    /// exact scenario that collapsed on macOS 27.
    func test_emptyChain_fittingHeight_meetsFloor() async throws {
        let model = try await makeModel()
        let view = ControlPanelView().environmentObject(model)

        let size = SnapshotHelper.intrinsicSize(of: view, width: 380)

        XCTAssertGreaterThanOrEqual(
            size.height,
            420,
            "ControlPanelView fitting height \(size.height) pt is below the 420 pt floor " +
            "(docs/specs/ui.md). This is the macOS-27 collapse contract."
        )
    }

    // MARK: - Populated chain

    /// With several effects added, the panel must remain inside its declared
    /// height contract: at or above the 420 pt floor and at or below the
    /// 700 pt cap. The chain editor's ScrollView should absorb the extra
    /// rows rather than letting the panel grow unbounded.
    func test_populatedChain_fittingHeight_withinContract() async throws {
        let model = try await makeModel()

        // Seed three effects — one of each built-in type — to exercise the
        // chain editor's scroll region with real content.
        model.addEffect(of: "tnf.eq")
        model.addEffect(of: "tnf.gain")
        model.addEffect(of: "tnf.reverb")

        let view = ControlPanelView().environmentObject(model)
        let size = SnapshotHelper.intrinsicSize(of: view, width: 380)

        XCTAssertGreaterThanOrEqual(
            size.height,
            420,
            "ControlPanelView fitting height \(size.height) pt is below the 420 pt floor " +
            "with a three-effect chain (docs/specs/ui.md)."
        )
        XCTAssertLessThanOrEqual(
            size.height,
            700,
            "ControlPanelView fitting height \(size.height) pt exceeds the 700 pt cap " +
            "with a three-effect chain — the chain editor ScrollView should be absorbing " +
            "the extra rows rather than growing the window (docs/specs/ui.md)."
        )
    }

    // MARK: - Drawers

    /// Opening the settings drawer must add the section's full height to the
    /// panel rather than have a height cap absorb part of it.
    ///
    /// The cap was gated on `showDebugPanel` alone while both drawers append a
    /// section below the footer. Measurement showed the 700 pt cap is not
    /// currently reachable — the chain editor's own 440 pt cap keeps the total
    /// below it — so including `showSettings` is defensive, not a fix for a
    /// live defect. See the note in the body.
    func test_settingsDrawer_addsItsFullHeight() async throws {
        let model = try await makeModel()

        // Fill the chain until its ScrollView sits at its own 440 pt maximum,
        // which is the tallest the panel can get.
        for _ in 0 ..< 12 {
            model.addEffect(of: "tnf.eq")
        }

        let closed = SnapshotHelper.intrinsicSize(
            of: ControlPanelView().environmentObject(model),
            width: 380
        )

        model.toggleSettings()
        XCTAssertTrue(model.showSettings, "toggleSettings did not open the drawer")

        let open = SnapshotHelper.intrinsicSize(
            of: ControlPanelView().environmentObject(model),
            width: 380
        )

        // WHAT THIS CAN AND CANNOT PROVE
        //
        // Measured on CI with a saturated chain: 606 pt closed, 690 pt open.
        // The chain editor is capped at 440 pt, so the surrounding chrome
        // cannot push the total past 700 pt. The closed-panel cap is therefore
        // not reachable today, and opening the settings drawer does not reach
        // it either. Including `showSettings` in the cap expression is
        // defensive rather than a fix for a reachable defect: it matches what
        // docs/specs/ui.md declares, and it keeps the panel correct if the
        // chain cap or the settings section grows later.
        //
        // An earlier version of this test asserted `open > 700` on the
        // assumption the cap was binding. It was not, and the test failed
        // honestly rather than passing for the wrong reason. What *is*
        // measurable is absorption: every point the settings section occupies
        // must show up in the panel's height. If a cap ever does start
        // binding, the section gets squeezed and this margin collapses.
        let growth = open.height - closed.height
        XCTAssertGreaterThanOrEqual(
            growth,
            60,
            "Opening the settings drawer grew the panel by only \(growth) pt " +
            "(closed \(closed.height), open \(open.height)). The settings section is taller " +
            "than that, so a height cap is absorbing part of it instead of letting the " +
            "window extend."
        )
        XCTAssertLessThanOrEqual(
            open.height,
            900,
            "Panel height \(open.height) pt with the settings drawer open exceeds the 900 pt " +
            "drawer cap."
        )
    }

    // MARK: - Helpers

    /// Build a view model backed by a minimal mock capture controller and a
    /// fresh isolated `UserDefaults` suite.
    private func makeModel() async throws -> AppViewModel {
        let defaults = UserDefaults(suiteName: "tnf.layout-contract.\(UUID().uuidString)")!
        let capture = LayoutMockCapture()
        return AppViewModel(
            capture: capture,
            engine: AVAudioEngine(),
            registry: EffectNodeRegistry(),
            defaults: defaults
        )
    }
}

/// Minimal capture-controller stub for layout tests.
///
/// Declared here rather than in a shared helper because SPM scopes test
/// helpers to the file they are declared in — a `private` type in
/// `ControlPanelViewSnapshotTests.swift` is invisible here. The required
/// surface is small enough that the duplication costs less than an
/// `internal` shared file would.
private final class LayoutMockCapture: CaptureControllerProtocol, @unchecked Sendable {
    private let subject = CurrentValueSubject<CaptureState, Never>(.idle)

    var state: CaptureState { subject.value }
    var statePublisher: AnyPublisher<CaptureState, Never> { subject.eraseToAnyPublisher() }
    var captureSourceNode: AVAudioSourceNode? { nil }

    func availableSources() throws -> [CaptureSource] { [] }
    func start(source: CaptureSource, into engine: AVAudioEngine) throws {}
    func stop() throws {}
}
