import AVFoundation
import Capture
import Combine
import Effects
import Foundation
import Graph
import Presets
@testable import UI
import ViewModel
import XCTest

/// Existing-API witnesses, independently publishable with this file's fixture.
/// Synchronous tests save before any queued main-thread callback can run. The
/// separate composition suite injects the new VM scheduler, never the factory.
@MainActor
final class AcceptedParameterSaveBaselineTests: XCTestCase {
    private var fixture: AcceptedParameterFixture!

    override func setUp() async throws {
        try await super.setUp()
        fixture = try AcceptedParameterFixture()
    }

    override func tearDown() async throws {
        try fixture.cleanUp()
        fixture = nil
        try await super.tearDown()
    }

    func test_default_factory_drag_then_immediate_save_exports_final_accepted_value() throws {
        let model = fixture.makeModel()
        let node = try fixture.node(in: model)
        let editor = fixture.writer(node, model).makeEditor()
        editor.drag(to: 0.4)
        editor.drag(to: 0.7)

        model.savePreset(to: fixture.url("accepted.tnf"))

        XCTAssertEqual(try fixture.exportedValue("accepted.tnf"), 7)
        XCTAssertEqual(node.value, 7)
        XCTAssertFalse(model.isPresetModified)
    }

    func test_default_factory_stop_preserves_accepted_drag_but_never_submits_numeric_draft() throws {
        let model = fixture.makeModel()
        let node = try fixture.node(in: model)
        let editor = fixture.writer(node, model).makeEditor()
        editor.drag(to: 0.7)
        editor.beginEditing(locale: fixture.locale)
        editor.text = "9"
        editor.stop()

        model.savePreset(to: fixture.url("after-stop.tnf"))

        XCTAssertEqual(try fixture.exportedValue("after-stop.tnf"), 7)
        XCTAssertEqual(node.attempts, [7])
        XCTAssertFalse(editor.isEditing)
    }

    func test_default_factory_finish_then_another_drag_remains_saveable() throws {
        let model = fixture.makeModel()
        let node = try fixture.node(in: model)
        let editor = fixture.writer(node, model).makeEditor()
        editor.drag(to: 0.4)
        editor.finishDragging()
        editor.drag(to: 0.8)

        model.savePreset(to: fixture.url("second-drag.tnf"))

        XCTAssertEqual(try fixture.exportedValue("second-drag.tnf"), 8)
        XCTAssertEqual(node.attempts, [4, 8])
    }
}

/// No real capture, rendering, panels, sleeps, or production defaults. Shared
/// by the structural-red suites without depending on any new production API.
@MainActor
final class AcceptedParameterFixture {
    let suiteName = "tnf.accepted-parameter.\(UUID().uuidString)"
    let defaults: UserDefaults
    let directory: URL
    let registry = EffectNodeRegistry()
    let capture = AcceptedParameterCapture()
    let engine = AVAudioEngine()
    let locale = Locale(identifier: "en_US_POSIX")

    init() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tnf-accepted-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        registry.register(AcceptedParameterNode.self)
        let preset = GraphPreset(name: "accepted edits", outputGain: 1, nodes: [
            AcceptedParameterNode().snapshot(), AcceptedParameterNode().snapshot(),
        ])
        defaults.set(try JSONEncoder().encode(preset), forKey: AppViewModelDefaultsKey.graph)
    }

    func makeModel() -> AppViewModel {
        AppViewModel(capture: capture, engine: engine, registry: registry, defaults: defaults)
    }

    func cleanUp() throws {
        XCTAssertEqual(capture.starts, 0)
        XCTAssertFalse(engine.isRunning)
        defaults.removePersistentDomain(forName: suiteName)
        try FileManager.default.removeItem(at: directory)
    }

    func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    func node(in model: AppViewModel, at index: Int = 0) throws -> AcceptedParameterNode {
        try XCTUnwrap(model.graph.nodes.dropFirst(index).first as? AcceptedParameterNode)
    }

    func writer(_ node: AcceptedParameterNode, _ model: AppViewModel) -> ParameterNodeWriter {
        ParameterNodeWriter(node: node, parameter: node.parameters[0], viewModel: model)
    }

    func exportedValue(_ name: String, at index: Int = 0) throws -> Float {
        let snapshot = try XCTUnwrap(PresetStore.load(from: url(name)).nodes.dropFirst(index).first)
        return try XCTUnwrap(snapshot.parameters["amount"])
    }

    func rejectedDirectory() throws -> URL {
        let target = url("directory.tnf")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        return target
    }
}

final class AcceptedParameterCapture: CaptureControllerProtocol, @unchecked Sendable {
    private let subject = CurrentValueSubject<CaptureState, Never>(.idle)
    private(set) var starts = 0
    var state: CaptureState { subject.value }
    var statePublisher: AnyPublisher<CaptureState, Never> { subject.eraseToAnyPublisher() }
    var captureSourceNode: AVAudioSourceNode? { nil }
    func availableSources() throws -> [CaptureSource] { [] }
    func start(source: CaptureSource, into engine: AVAudioEngine) throws {
        starts += 1
        XCTFail("Accepted-edit tests must never start capture")
        throw AcceptedParameterError.audioLifecycle
    }
    func stop() throws {}
}

enum AcceptedParameterError: Error { case rejected, audioLifecycle }

final class AcceptedParameterNode: DefaultConstructibleEffectNode {
    static let typeIdentifier = "tnf.accepted-parameter-test"
    static let supportsWetDry = false
    enum Behavior: Equatable { case exact, roundedDown, unchanged, rejected }
    var behavior: Behavior = .exact
    var id = UUID()
    var displayName = "Accepted parameter"
    var bypass = false
    var wetDryMix: Float = 1
    let inputBus = AVAudioMixerNode()
    let outputBus = AVAudioMixerNode()
    private(set) var value: Float = 2
    private(set) var otherValue: Float = 2
    private(set) var attempts: [Float] = []
    var readbackAvailable = true
    var readbackOverride: Float?
    var afterAttempt: ((Float) -> Void)?
    let parameters = [
        EffectParameter(identifier: "amount", displayName: "Amount", range: 0...10,
                        defaultValue: 2, unit: .ratio),
        EffectParameter(identifier: "other", displayName: "Other", range: 0...10,
                        defaultValue: 2, unit: .ratio),
    ]

    init() {}

    func setParameter(_ identifier: String, value: Float) throws {
        guard let parameter = parameters.first(where: { $0.identifier == identifier }) else {
            throw EffectParameterError.unknownParameter(identifier: identifier)
        }
        guard value.isFinite, parameter.range.contains(value) else {
            throw EffectParameterError.valueOutOfRange(identifier: identifier, value: value, range: parameter.range)
        }
        attempts.append(value)
        if behavior == .rejected { throw AcceptedParameterError.rejected }
        if behavior != .unchanged {
            let actual = behavior == .roundedDown ? value.rounded(.down) : value
            if identifier == "amount" { self.value = actual } else { otherValue = actual }
        }
        afterAttempt?(value)
    }

    func parameterValue(_ identifier: String) -> Float? {
        guard readbackAvailable else { return nil }
        if let readbackOverride { return readbackOverride }
        switch identifier {
        case "amount": return value
        case "other": return otherValue
        default: return nil
        }
    }

    func attach(to engine: AVAudioEngine) throws { throw AcceptedParameterError.audioLifecycle }
    func detach() {}
    func snapshot() -> EffectState {
        EffectState(typeIdentifier: Self.typeIdentifier, id: id, displayName: displayName,
                    bypass: bypass, wetDryMix: wetDryMix,
                    parameters: ["amount": value, "other": otherValue], extras: [:])
    }
    func restore(from state: EffectState) throws {
        id = state.id
        displayName = state.displayName
        bypass = state.bypass
        wetDryMix = state.wetDryMix
        value = state.parameters["amount"] ?? 2
        otherValue = state.parameters["other"] ?? 2
    }
}
