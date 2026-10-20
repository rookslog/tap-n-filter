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

/// Exercise the same UI writer/editor factory used by ParameterSlider, through
/// the real AppViewModel and preset loader. No SwiftUI lifecycle or audio start.
@MainActor
final class ParameterNodeWriterTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var presetURL: URL!
    private var queued: [() -> Void] = []

    override func setUp() async throws {
        try await super.setUp()
        queued = []
        suiteName = "tnf.parameter-writer.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        presetURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(suiteName).tnf")
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        if FileManager.default.fileExists(atPath: presetURL.path) {
            try FileManager.default.removeItem(at: presetURL)
        }
        defaults = nil
        try await super.tearDown()
    }

    func test_editor_writes_and_reset_reach_the_current_node_through_the_view_model() throws {
        let (model, capture, engine) = try makeModel()
        let node = try XCTUnwrap(model.graph.nodes.first as? ParameterWriterTestNode)
        let writer = ParameterNodeWriter(node: node, parameter: node.parameters[0], viewModel: model)
        let editor = writer.makeEditor()
        var publications = 0
        let subscription = model.objectWillChange.sink { _ in publications += 1 }

        editor.drag(to: 0.5)
        let target = editor.value
        queued[0]()
        XCTAssertEqual(node.value, target)
        XCTAssertEqual(node.writes, [target])
        XCTAssertGreaterThan(publications, 0)
        editor.reset()
        XCTAssertEqual(node.value, node.parameters[0].defaultValue)
        XCTAssertEqual(node.writes, [target, node.parameters[0].defaultValue])
        XCTAssertEqual(capture.starts, 0)
        XCTAssertFalse(engine.isRunning)
        withExtendedLifetime(subscription) {}
    }

    func test_same_uuid_preset_replacement_rejects_old_queued_and_final_writes_before_teardown() throws {
        let (model, capture, engine) = try makeModel()
        let oldNode = try XCTUnwrap(model.graph.nodes.first as? ParameterWriterTestNode)
        // Construct the replacement fixture before accepting the old drag:
        // Save now intentionally flushes accepted input (covered separately).
        model.savePreset(to: presetURL)
        let writer = ParameterNodeWriter(node: oldNode, parameter: oldNode.parameters[0], viewModel: model)
        let staleEditor = writer.makeEditor()
        staleEditor.drag(to: 0.8)
        model.loadPreset(from: presetURL)
        XCTAssertNil(model.lastError)
        let replacement = try XCTUnwrap(model.graph.nodes.first as? ParameterWriterTestNode)
        XCTAssertEqual(replacement.id, oldNode.id)
        XCTAssertNotEqual(ObjectIdentifier(replacement), ObjectIdentifier(oldNode))

        // Deliberately do not call stop/onDisappear: the old editor is alive
        // and its scheduled callback really runs after graph replacement.
        queued[0]()
        staleEditor.drag(to: 0.9)
        staleEditor.finishDragging()
        // Stale acceptance is rejected before scheduling another tick. Replay
        // the captured old callback again instead of assuming new queued work.
        queued[0]()
        XCTAssertEqual(replacement.value, 800)
        XCTAssertTrue(replacement.writes.isEmpty)
        XCTAssertTrue(oldNode.writes.isEmpty)

        let currentWriter = ParameterNodeWriter(
            node: replacement, parameter: replacement.parameters[0], viewModel: model
        )
        let currentEditor = currentWriter.makeEditor()
        currentEditor.beginEditing(locale: Locale(identifier: "en_US_POSIX"))
        currentEditor.text = "1234.5"
        XCTAssertTrue(currentEditor.commit(locale: Locale(identifier: "en_US_POSIX")))
        XCTAssertEqual(replacement.value, 1_234.5)
        XCTAssertEqual(replacement.writes, [1_234.5])
        XCTAssertEqual(capture.starts, 0)
        XCTAssertFalse(engine.isRunning)
    }

    func test_no_readback_keeps_accepted_exact_entry_without_substituting_default() throws {
        let (model, capture, engine) = try makeModel()
        let node = try XCTUnwrap(model.graph.nodes.first as? ParameterWriterTestNode)
        node.readbackAvailable = false
        let writer = ParameterNodeWriter(node: node, parameter: node.parameters[0], viewModel: model)
        let editor = writer.makeEditor()
        let locale = Locale(identifier: "en_US_POSIX")
        XCTAssertEqual(editor.value, node.parameters[0].defaultValue)
        XCTAssertNil(node.parameterValue(node.parameters[0].identifier))

        editor.beginEditing(locale: locale)
        editor.text = "1234.5"
        XCTAssertTrue(editor.commit(locale: locale))

        XCTAssertEqual(node.value, 1_234.5)
        XCTAssertEqual(node.writes, [1_234.5])
        XCTAssertEqual(editor.value, 1_234.5)
        XCTAssertEqual(Float(editor.text), 1_234.5)
        editor.beginEditing(locale: locale)
        XCTAssertEqual(Float(editor.text), 1_234.5)
        editor.cancel()
        XCTAssertEqual(editor.value, 1_234.5)
        XCTAssertNil(node.parameterValue(node.parameters[0].identifier))
        XCTAssertEqual(capture.starts, 0)
        XCTAssertFalse(engine.isRunning)
    }

    func test_no_readback_keeps_accepted_drag_tick_and_final_value() throws {
        let (model, capture, engine) = try makeModel()
        let node = try XCTUnwrap(model.graph.nodes.first as? ParameterWriterTestNode)
        node.readbackAvailable = false
        let writer = ParameterNodeWriter(node: node, parameter: node.parameters[0], viewModel: model)
        let editor = writer.makeEditor()

        editor.drag(to: 0.5)
        let tickValue = editor.value
        queued[0]()
        XCTAssertEqual(node.value, tickValue)
        XCTAssertEqual(editor.value, tickValue)
        XCTAssertEqual(editor.presentation.parseInput(editor.text, locale: .current), tickValue)

        editor.drag(to: 0.8)
        let finalValue = editor.value
        editor.finishDragging()
        queued[1]()

        XCTAssertEqual(node.writes, [tickValue, finalValue])
        XCTAssertEqual(node.value, finalValue)
        XCTAssertEqual(editor.value, finalValue)
        XCTAssertEqual(editor.presentation.parseInput(editor.text, locale: .current), finalValue)
        XCTAssertNil(node.parameterValue(node.parameters[0].identifier))
        XCTAssertEqual(capture.starts, 0)
        XCTAssertFalse(engine.isRunning)
    }

    private func makeModel() throws -> (AppViewModel, ParameterWriterCapture, AVAudioEngine) {
        let registry = EffectNodeRegistry()
        registry.register(ParameterWriterTestNode.self)
        let preset = GraphPreset(
            name: "writer-test", outputGain: 1, nodes: [ParameterWriterTestNode().snapshot()]
        )
        defaults.set(try JSONEncoder().encode(preset), forKey: AppViewModelDefaultsKey.graph)
        let capture = ParameterWriterCapture()
        let engine = AVAudioEngine()
        let model = AppViewModel(
            capture: capture, engine: engine, registry: registry, defaults: defaults,
            scheduleParameterEdit: { [weak self] action in self?.queued.append(action) }
        )
        return (model, capture, engine)
    }
}

private final class ParameterWriterCapture: CaptureControllerProtocol, @unchecked Sendable {
    private let subject = CurrentValueSubject<CaptureState, Never>(.idle)
    private(set) var starts = 0
    var state: CaptureState { subject.value }
    var statePublisher: AnyPublisher<CaptureState, Never> { subject.eraseToAnyPublisher() }
    var captureSourceNode: AVAudioSourceNode? { nil }
    func availableSources() throws -> [CaptureSource] { [] }
    func start(source: CaptureSource, into engine: AVAudioEngine) throws {
        starts += 1
        XCTFail("Parameter writer tests must never start capture")
        throw ParameterWriterTestError.audioLifecycle
    }
    func stop() throws {}
}

private enum ParameterWriterTestError: Error { case audioLifecycle }

private final class ParameterWriterTestNode: DefaultConstructibleEffectNode {
    static let typeIdentifier = "tnf.parameter-writer-test"
    static let supportsWetDry = false
    var id = UUID()
    var displayName = "Writer test"
    var bypass = false
    var wetDryMix: Float = 1
    let inputBus = AVAudioMixerNode()
    let outputBus = AVAudioMixerNode()
    private(set) var value: Float = 800
    private(set) var writes: [Float] = []
    var readbackAvailable = true
    let parameters = [EffectParameter(
        identifier: "frequency", displayName: "Frequency", range: 200 ... 18_000,
        defaultValue: 800, unit: .hertz
    )]

    init() {}

    func setParameter(_ identifier: String, value: Float) throws {
        guard identifier == parameters[0].identifier else {
            throw EffectParameterError.unknownParameter(identifier: identifier)
        }
        guard value.isFinite, parameters[0].range.contains(value) else {
            throw EffectParameterError.valueOutOfRange(
                identifier: identifier, value: value, range: parameters[0].range
            )
        }
        self.value = value
        writes.append(value)
    }
    func parameterValue(_ identifier: String) -> Float? {
        readbackAvailable && identifier == parameters[0].identifier ? value : nil
    }
    func attach(to engine: AVAudioEngine) throws { throw ParameterWriterTestError.audioLifecycle }
    func detach() {}
    func snapshot() -> EffectState {
        EffectState(
            typeIdentifier: Self.typeIdentifier, id: id, displayName: displayName,
            bypass: bypass, wetDryMix: wetDryMix, parameters: ["frequency": value], extras: [:]
        )
    }
    func restore(from state: EffectState) throws {
        id = state.id
        displayName = state.displayName
        bypass = state.bypass
        wetDryMix = state.wetDryMix
        value = state.parameters["frequency"] ?? 800
    }
}
