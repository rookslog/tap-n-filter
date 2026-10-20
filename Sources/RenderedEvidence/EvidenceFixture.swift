import AVFoundation
import Capture
import Combine
import Effects
import Foundation
import Graph
import ViewModel

/// Only this injected model is ever hosted; no default AppViewModel or HAL API.
@MainActor
final class EvidenceFixture {
    enum State: String, CaseIterable {
        case idle, running
        case multilineError = "multiline-error"
        case expandedEq = "expanded-eq"
        case settingsOpen = "settings-open"
    }

    let model: AppViewModel
    let engine: AVAudioEngine
    let capture: EvidenceFakeCapture
    let defaults: UserDefaults
    let suiteName: String
    let state: State
    private(set) var eq: EQNode?

    private static let bannerError = CaptureError.engineConfigurationFailed(
        "Fake capture cannot start.\nSelect the example source and try again."
    )

    init(state: State, capture: EvidenceFakeCapture = EvidenceFakeCapture()) throws {
        self.state = state
        suiteName = "tnf.rendered-evidence.\(UUID().uuidString)"
        guard let isolated = UserDefaults(suiteName: suiteName) else {
            throw EvidenceError.invalid("Could not create isolated defaults")
        }
        defaults = isolated
        self.capture = capture
        engine = AVAudioEngine()
        model = AppViewModel(
            capture: capture, engine: engine, registry: EffectNodeRegistry(), defaults: isolated
        )
        while !model.graph.nodes.isEmpty { model.removeEffect(at: 0) }
        model.addEffect(of: "tnf.eq")
        model.addEffect(of: "tnf.reverb")
        eq = model.graph.nodes.first as? EQNode
        guard eq != nil, model.graph.nodes.count == 2, model.lastError == nil else {
            throw EvidenceError.invalid("Could not prepare canonical EQ/reverb graph")
        }
        model.currentSource = capture.source
        if state == .expandedEq { model.expandedEffectID = eq?.id }
        if state == .settingsOpen { model.toggleSettings() }
        capture.publish(expectedState)
    }

    var expectedState: CaptureState {
        switch state {
        case .running: return .running(source: capture.source)
        case .multilineError: return .failed(Self.bannerError)
        default: return .idle
        }
    }

    func waitForState() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        // Always yield at least once to drain the initial idle publication.
        repeat {
            try await Task.sleep(for: .milliseconds(10))
            if model.captureState == expectedState,
               model.lastError == (state == .multilineError ? .capture(Self.bannerError) : nil) {
                try validate()
                return
            }
        } while clock.now < deadline
        throw EvidenceError.invalid("Fake state/error did not propagate: \(state.rawValue)")
    }

    func validate() throws {
        guard model.captureState == expectedState,
              model.lastError == (state == .multilineError ? .capture(Self.bannerError) : nil),
              model.showSettings == (state == .settingsOpen), !model.showDebugPanel,
              model.expandedEffectID == (state == .expandedEq ? eq?.id : nil),
              model.currentSource == capture.source, !engine.isRunning, !capture.operationAttempted else {
            throw EvidenceError.invalid("State/identity/no-audio contract changed: \(state.rawValue)")
        }
    }

    func observation() throws -> EvidenceManifest.Observed {
        try validate()
        let expanded = model.graph.nodes.first { $0.id == model.expandedEffectID }
        guard let eq else { throw EvidenceError.invalid("Missing EQ identity") }
        return EvidenceManifest.Observed(
            captureState: state == .running ? "running" : (state == .multilineError ? "failed" : "idle"),
            engineRunning: engine.isRunning,
            showSettings: model.showSettings, showDebugPanel: model.showDebugPanel,
            expandedEffectID: Nullable(model.expandedEffectID?.uuidString),
            expandedEffectType: Nullable(expanded.map { type(of: $0).typeIdentifier }),
            eqNodeID: eq.id.uuidString,
            errorMessage: Nullable(model.lastError?.userMessage),
            sourceDisplayName: Nullable(model.currentSource?.displayName)
        )
    }
}

/// Any accidental start/stop is recorded and throws; neither can reach audio.
final class EvidenceFakeCapture: CaptureControllerProtocol, @unchecked Sendable {
    let source = CaptureSource(
        pid: 1234, audioProcessID: 42,
        bundleIdentifier: "com.example.rendered-evidence", displayName: "Example Audio App"
    )
    private let subject = CurrentValueSubject<CaptureState, Never>(.idle)
    private let lock = NSLock()
    private let enumerationProvider: @Sendable (CaptureSource) throws -> [CaptureSource]
    private var attempted = false
    var operationAttempted: Bool { lock.withLock { attempted } }
    var state: CaptureState { subject.value }
    var statePublisher: AnyPublisher<CaptureState, Never> { subject.eraseToAnyPublisher() }
    var captureSourceNode: AVAudioSourceNode? { nil }

    init(
        availableSources: @escaping @Sendable (CaptureSource) throws -> [CaptureSource] = { [$0] }
    ) {
        enumerationProvider = availableSources
    }

    func publish(_ state: CaptureState) { subject.send(state) }
    func availableSources() throws -> [CaptureSource] { try enumerationProvider(source) }
    func start(source: CaptureSource, into engine: AVAudioEngine) throws { try rejectOperation() }
    func stop() throws { try rejectOperation() }

    private func rejectOperation() throws {
        lock.withLock { attempted = true }
        throw EvidenceError.invalid("Exporter must not invoke capture lifecycle")
    }
}
