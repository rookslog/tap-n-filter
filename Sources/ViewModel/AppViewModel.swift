import AVFoundation
import AppKit
import Capture
import Combine
import CoreAudio
import Effects
import Foundation
import Graph
import OSLog
import Presets
import SwiftUI

/// Domain-level errors surfaced to the UI by `AppViewModel`.
///
/// The view model wraps capture, graph, and persistence failures into a
/// single type so the SwiftUI layer can render error state without
/// switching over disparate error namespaces.
public enum AppError: Error, Equatable {
    case capture(CaptureError)
    case graph(String)
    case parameter(String)
    case preset(String)
    case engine(String)
    case persistence(String)

    public var userMessage: String {
        switch self {
        case .capture(let underlying):
            return AppError.message(for: underlying)
        case .graph(let reason):
            return "Graph error: \(reason)"
        case .parameter(let reason):
            return "Parameter error: \(reason)"
        case .preset(let reason):
            return "Preset error: \(reason)"
        case .engine(let reason):
            return "Engine error: \(reason)"
        case .persistence(let reason):
            return "Persistence error: \(reason)"
        }
    }

    private static func message(for error: CaptureError) -> String {
        switch error {
        case .permissionDenied:
            return "Permission denied. Grant access in System Settings → Privacy & Security."
        case .sourceNotFound(let pid):
            return "Source could not be identified (PID \(pid)). Choose the source again, then press Start."
        case .tapCreationFailed(let status):
            return "Tap creation failed (OSStatus \(status))."
        case .aggregateDeviceCreationFailed(let status):
            return "Aggregate device creation failed (OSStatus \(status))."
        case .engineConfigurationFailed(let reason):
            return "Engine configuration failed: \(reason)"
        case .unsupportedOSVersion:
            return "macOS 14.4 or later is required."
        case .captureInterrupted(let reason):
            return "Capture interrupted: \(reason)"
        case .alreadyRunning(let source):
            return "Already capturing \(source.displayName). Stop the current capture before starting a new one."
        case .transitionInProgress:
            return "Another start/stop is in progress. Please retry in a moment."
        }
    }
}

/// Keys used to persist UI session state to `UserDefaults`.
public enum AppViewModelDefaultsKey {
    public static let graph: String = "lastSession.graph"
    public static let sourceBundleID: String = "lastSession.sourceBundleID"
    /// Additional discriminator for restoring a source; names are not stable identities.
    public static let sourceDisplayName: String = "lastSession.sourceDisplayName"
    public static let debugPanel: String = "debug.enabled"
    /// Whether the "Preserve Bluetooth quality during capture" mitigation is
    /// active. Stored as a Bool; absent means default ON (ADR-019).
    public static let preserveBluetoothQuality: String = "settings.preserveBluetoothQuality"
}

/// The single owner of UI state for the menubar window.
///
/// `AppViewModel` mediates between the SwiftUI views and the audio stack
/// (`Graph`, `CaptureController`, `AVAudioEngine`). It is `@MainActor` so
/// all `@Published` mutations are guaranteed to happen on the main
/// thread, which is the contract SwiftUI bindings expect.
///
/// Under the v2 (direct-IOProc + AVAudioSourceNode) architecture
/// (ADR-018), the power lifecycle is:
///
/// 1. `capture.start(source:into:)` — the controller creates the tap,
///    builds an `AVAudioSourceNode`, and attaches it to the engine. The
///    engine's `inputNode` and `outputNode` are NOT touched.
/// 2. `graph.attach(to:source:destination:)` — the view model wires the
///    effect chain from `capture.captureSourceNode` to
///    `engine.mainMixerNode`.
/// 3. `engine.prepare()` + `engine.start()`.
///
/// Power-off reverses: stop the engine, detach the graph, stop the
/// controller. `outputNode` stays on the system default device
/// throughout, which is the property that ADR-018 turned into a
/// load-bearing invariant.
@MainActor
public final class AppViewModel: ObservableObject {

    // MARK: Published state

    @Published public private(set) var graph: Graph

    @Published public var currentSource: CaptureSource?

    @Published public private(set) var availableSources: [CaptureSource] = []

    @Published public private(set) var captureState: CaptureState = .idle {
        didSet {
            if oldValue != captureState {
                logger.info("captureState: \(String(describing: oldValue)) -> \(String(describing: self.captureState))")
            }
        }
    }

    @Published public var expandedEffectID: UUID?

    @Published public private(set) var lastError: AppError? {
        didSet {
            switch (oldValue, lastError) {
            case (nil, let new?):
                logger.warning("lastError set: \(new.userMessage)")
            case (let old?, nil):
                logger.info("lastError cleared (was: \(old.userMessage))")
            case (let old?, let new?):
                logger.warning("lastError replaced: \(old.userMessage) -> \(new.userMessage)")
            case (nil, nil):
                break
            }
        }
    }

    public var availableEffectTypes: [String] {
        registry.registeredTypeIdentifiers
    }

    public let debugLog: DebugLogStore

    @Published public private(set) var showDebugPanel: Bool

    public func toggleDebugPanel() {
        showDebugPanel.toggle()
        defaults.set(showDebugPanel, forKey: AppViewModelDefaultsKey.debugPanel)
    }

    /// Whether the settings panel is visible. Toggled via the gear button in
    /// `HeaderView`. Mirrors the `showDebugPanel` pattern exactly.
    @Published public private(set) var showSettings: Bool = false

    public func toggleSettings() {
        showSettings.toggle()
    }

    /// "Preserve Bluetooth quality during capture" — Layer A storage only.
    ///
    /// When true, the app will (via a separate, gated Layer B) switch the
    /// system default input away from the Bluetooth device during capture to
    /// keep the output on A2DP instead of HFP. The actual device-switch logic
    /// is out of scope for this PR (ADR-019, EXP-037). This property only
    /// stores and exposes the preference.
    ///
    /// Default: true (absent key is treated as true per ADR-019 §Decision).
    @Published public var preserveBluetoothQuality: Bool {
        didSet {
            defaults.set(preserveBluetoothQuality, forKey: AppViewModelDefaultsKey.preserveBluetoothQuality)
        }
    }

    // MARK: - EXP-029 minimal-reader control (throwaway)
    //
    // Debug-panel-driven test that runs a `TapIOProcReader` for 5 s
    // WITHOUT any `engine.attach(sourceNode)` — i.e., the exact same
    // tap + aggregate + IOProc path as production, but with NO contact
    // with the AVAudioEngine. Compare its log block (tagged
    // `[EXP-029.*]`) to the production Start path's block to identify
    // which observable signal first diverges between the two paths.
    // Remove once H10 / H9 / H11 / H12 / H13 is resolved.

    /// Whether the EXP-029 reader test is currently running.
    @Published public private(set) var isReaderTestRunning: Bool = false

    @MainActor
    public func runReaderTest() {
        guard !isReaderTestRunning else { return }
        guard captureState == .idle else {
            logger.warning(
                "runReaderTest: capture is active; stop capture before running "
                + "the reader test (it would create a second tap on the same "
                + "process and can fire a configuration change on the live engine)"
            )
            return
        }
        guard let source = currentSource else {
            logger.warning("runReaderTest: no source selected; pick one first")
            return
        }
        isReaderTestRunning = true
        Task { @MainActor in
            await self.performReaderTest(source: source)
            self.isReaderTestRunning = false
        }
    }

    @MainActor
    private func performReaderTest(source: CaptureSource) async {
        let testLogger = TnfLogger(source: "ReaderTest", store: debugLog)
        testLogger.info("[EXP-029.path] RDRTEST (TapIOProcReader, NO engine.attach)")
        testLogger.info(
            "[EXP-029.input.source] pid=\(source.pid) "
            + "audioProcessID(stored)=\(source.audioProcessID) "
            + "bundleID=\(source.bundleIdentifier ?? "nil") "
            + "displayName=\(source.displayName)"
        )

        let coreAudio = RealCoreAudioInterface()
        let liveProcessID: AudioObjectID
        do {
            liveProcessID = try coreAudio.audioProcessID(forPID: source.pid)
            testLogger.info(
                "[EXP-029.input.resolve] OK liveProcessID=\(liveProcessID) "
                + "(stored was \(source.audioProcessID); "
                + "match=\(liveProcessID == source.audioProcessID))"
            )
        } catch {
            testLogger.error("[EXP-029.input.resolve] FAIL \(error)")
            return
        }

        let reader: TapIOProcReader
        do {
            reader = try TapIOProcReader(
                audioProcessID: liveProcessID,
                coreAudio: coreAudio,
                log: { message in testLogger.info(message) }
            )
        } catch {
            testLogger.error("[EXP-029.reader.init] FAIL \(error)")
            return
        }

        do {
            try reader.start()
            testLogger.info("[EXP-029.rdrtest] start() returned; running 5s")
        } catch {
            testLogger.error("[EXP-029.reader.start] FAIL \(error)")
            reader.stop()
            return
        }

        // Drain the ring fully each ~100 ms tick. A single frameBatch read
        // (4096) under-drains at 48 kHz (~4800 frames per 100 ms window), so
        // the inner loop reads until the ring is empty to keep totalFrames
        // accurate and avoid a slow ring overflow. (CodeRabbit PR #10 review.)
        let ring = reader.ring
        let channelCount = Int(reader.format.channelCount)
        let frameBatch = 4096
        let totalCapacity = frameBatch * channelCount
        let storage = UnsafeMutablePointer<Float>.allocate(capacity: totalCapacity)
        defer { storage.deallocate() }
        var channelPtrs: [UnsafeMutablePointer<Float>] = []
        channelPtrs.reserveCapacity(channelCount)
        for c in 0..<channelCount {
            channelPtrs.append(storage.advanced(by: c * frameBatch))
        }

        var totalFrames = 0
        var nonZeroFrames = 0
        var maxAbs: Float = 0
        var readCount = 0

        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
            var framesRead = ring.read(into: channelPtrs, frames: frameBatch)
            while framesRead > 0 {
                readCount += 1
                totalFrames += framesRead
                let ch0 = channelPtrs[0]
                for i in 0..<framesRead {
                    let s = ch0[i]
                    if s != 0 { nonZeroFrames += 1 }
                    let a = Swift.abs(s)
                    if a > maxAbs { maxAbs = a }
                }
                framesRead = ring.read(into: channelPtrs, frames: frameBatch)
            }
        }

        testLogger.info(
            "[EXP-029.rdrtest.stats] reads=\(readCount) "
            + "totalFrames=\(totalFrames) nonZeroFrames=\(nonZeroFrames) "
            + "maxAbs=\(maxAbs)"
        )
        if totalFrames == 0 {
            testLogger.warning(
                "[EXP-029.rdrtest.result] FAIL_NO_FRAMES — AudioDeviceStart "
                + "succeeded but IOProc delivered nothing. Cause is downstream "
                + "of the start (e.g., tap not actually pumping)."
            )
        } else if nonZeroFrames == 0 {
            testLogger.warning(
                "[EXP-029.rdrtest.result] FAIL_ZEROS_ONLY — frames arrived but all "
                + "are zero. Suspect macOS 26 zero-buffer bug (forums 825780)."
            )
        } else {
            testLogger.info(
                "[EXP-029.rdrtest.result] PASS — \(totalFrames) frames, "
                + "\(nonZeroFrames) non-zero, peak \(maxAbs). Direct-IOProc path "
                + "works without an engine. If production STILL fails: H10 "
                + "(engine.attach pre-empts) is the leading candidate."
            )
        }

        reader.stop()
    }

    // MARK: Collaborators

    private let capture: CaptureControllerProtocol
    private let engine: AVAudioEngine
    private let registry: EffectNodeRegistry
    private let defaults: UserDefaults
    private let logger: TnfLogger

    private var stateCancellable: AnyCancellable?
    private var sourceRefreshTimer: Timer?
    private var persistenceWorkItem: DispatchWorkItem?
    private var configChangeObserver: NSObjectProtocol?
    private var refreshSourcesTask: Task<Void, Never>?
    private var sourceChangeShutdownTask: Task<Void, Never>?

    private static let persistenceDebounceInterval: TimeInterval = 0.200

    /// Whether the render engine is believed to be running.
    ///
    /// Published because `captureState` alone does not tell the UI whether
    /// audio is actually flowing. The device-configuration-change handler can
    /// leave `captureState == .running` while the engine is stopped and a
    /// restart has failed — the user hears silence with a "running" capture.
    /// The header's status pill reads this to avoid reporting a healthy
    /// green state over a dead pipeline.
    @Published public private(set) var engineIsRunning: Bool = false {
        didSet {
            // A successful (re)start clears any prior stall. Every path that
            // brings the engine up runs through here, so the flag cannot
            // outlive the condition it describes.
            if engineIsRunning { engineStalled = false }
        }
    }

    /// The engine stopped while capture still believes it is running, and the
    /// restart failed.
    ///
    /// Distinct from `!engineIsRunning`, which is briefly true during a normal
    /// start and would make the UI flash a failure. This flag is set only on
    /// the configuration-change restart failure and cleared whenever the
    /// engine comes back up.
    ///
    /// It is also deliberately independent of `lastError`: dismissing the
    /// error banner acknowledges the message, not the silence. The status pill
    /// must keep reporting a failure while audio is not actually flowing.
    @Published public private(set) var engineStalled: Bool = false

    // MARK: Init

    public init(
        capture: CaptureControllerProtocol,
        engine: AVAudioEngine,
        registry: EffectNodeRegistry = .shared,
        defaults: UserDefaults = .standard,
        debugLog: DebugLogStore = DebugLogStore()
    ) {
        self.capture = capture
        self.engine = engine
        self.registry = registry
        self.defaults = defaults
        self.debugLog = debugLog
        self.showDebugPanel = defaults.bool(forKey: AppViewModelDefaultsKey.debugPanel)
        // Absent key → true (default ON per ADR-019).
        let storedPreserve = defaults.object(forKey: AppViewModelDefaultsKey.preserveBluetoothQuality)
        self.preserveBluetoothQuality = (storedPreserve as? Bool) ?? true
        self.logger = TnfLogger(source: "AppViewModel", store: debugLog)
        let bootstrapLogger = Logger(subsystem: "tnf.app", category: "AppViewModel.bootstrap")
        self.graph = AppViewModel.restoreGraph(from: defaults, registry: registry, logger: bootstrapLogger)

        stateCancellable = capture.statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.captureState = state
                if case .failed(let error) = state {
                    self?.lastError = .capture(error)
                }
            }

        // Observe AVAudioEngine configuration changes for diagnostics
        // only. Under the v2 architecture the IOProc-driven capture is
        // decoupled from the engine's render pull, so the H4 detach +
        // reattach branch the original implementation needed is no
        // longer load-bearing — the source node keeps draining the ring
        // buffer through engine reconfigurations. See ADR-018.
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            // The observer block is @Sendable; bounce back to the main
            // actor before touching MainActor-isolated state. `queue:
            // .main` only pins the dispatch thread; it doesn't satisfy
            // the actor-isolation checker.
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let outFmt = self.engine.outputNode.outputFormat(forBus: 0)
                self.logger.info(
                    "[EXP-031.configChange] fired engine.isRunning=\(self.engine.isRunning) "
                    + "engineIsRunning_flag=\(self.engineIsRunning) "
                    + "outputNode=\(outFmt.sampleRate)Hz×\(outFmt.channelCount)ch"
                )
                // If we believed the engine was running but it stopped
                // itself on the configuration change (output device
                // changed, hardware sample rate negotiated, route
                // switch), the IOProc keeps writing into the ring
                // buffer but no one is draining it — the user hears
                // silence with captureState still .running. Attempt to
                // restart the engine on the same graph; if that fails,
                // surface a typed error and let the user power-cycle.
                if self.engineIsRunning && !self.engine.isRunning {
                    self.logger.info(
                        "[EXP-031.engineRestart] attempting engine.start() after configChange"
                    )
                    do {
                        try self.engine.start()
                        // Re-apply node mix gains: the engine just restarted,
                        // and the mixer destinations were nil while it was
                        // stopped, so a route / sample-rate change must not
                        // leave bypass or wet/dry at default until the user
                        // touches a control. Third restart path alongside
                        // powerOn + reattach. (Codex PR #10 re-review.)
                        self.graph.refreshNodeMixState()
                        self.logger.info(
                            "[EXP-031.engineRestart] OK — engine.isRunning=\(self.engine.isRunning)"
                        )
                    } catch {
                        self.engineIsRunning = false
                        self.engineStalled = true
                        self.logger.error(
                            "[EXP-031.engineRestart] FAIL — \(error.localizedDescription)"
                        )
                        self.lastError = .engine(
                            "Audio device configuration changed and the engine could not be restarted: "
                            + "\(error.localizedDescription)"
                        )
                    }
                }
            }
        }

        restoreSourceFromDefaults()
        refreshAvailableSources()
        startSourceRefreshTimer()
    }

    public convenience init() {
        // Construct the debug log store + a Capture-tagged logger BEFORE
        // CaptureController so we can route the controller's diagnostic
        // breadcrumbs (EXP-029 + future) through the same file log as
        // the rest of the app.
        let debugLog = DebugLogStore()
        let captureLogger = TnfLogger(source: "Capture", store: debugLog)
        self.init(
            capture: CaptureController(
                coreAudio: RealCoreAudioInterface(),
                log: { message in captureLogger.info(message) }
            ),
            engine: AVAudioEngine(),
            debugLog: debugLog
        )
    }

    deinit {
        sourceRefreshTimer?.invalidate()
        persistenceWorkItem?.cancel()
        refreshSourcesTask?.cancel()
        sourceChangeShutdownTask?.cancel()
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: Menubar icon

    public var menuBarIconName: String {
        switch captureState {
        case .running:
            return "waveform.path"
        case .failed:
            return "waveform.path.badge.minus"
        case .idle, .starting, .stopping:
            return "waveform"
        }
    }

    // MARK: Source selection

    public func setSource(_ source: CaptureSource?) {
        let previousSource = currentSource
        switch captureState {
        case .running:
            if sourceChangeShutdownTask == nil {
                sourceChangeShutdownTask = Task { [weak self] in
                    await self?.powerOff()
                    await MainActor.run { [weak self] in
                        self?.sourceChangeShutdownTask = nil
                    }
                }
            }
        case .starting, .stopping:
            break
        case .idle, .failed:
            break
        }
        currentSource = source
        if source?.bundleIdentifier != previousSource?.bundleIdentifier
            || source?.displayName != previousSource?.displayName {
            schedulePersistence()
        }
    }

    /// A missing name is allowed only for legacy bundle-only session restoration.
    /// Names narrow the candidates but never make an ambiguous identity safe.
    private static func uniqueSource(
        in candidates: [CaptureSource],
        bundleID: String?,
        displayName: String?
    ) -> CaptureSource? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        let matches = candidates.filter { candidate in
            candidate.bundleIdentifier == bundleID
                && (displayName == nil || candidate.displayName == displayName)
        }
        return matches.count == 1 ? matches.first : nil
    }

    // MARK: Power lifecycle

    /// Begin capture and engine for the current source.
    ///
    /// V2 flow:
    /// 1. Resolve the source from the live HAL list (audioProcessID can
    ///    rotate between selection and start).
    /// 2. `capture.start(source:into:)` — the controller creates the
    ///    tap, builds the `AVAudioSourceNode`, attaches it to the
    ///    engine, and starts the IOProc. Audio is now pumping into the
    ///    ring buffer.
    /// 3. `graph.attach(to:source:destination:)` — wire the effect chain
    ///    from the source node into `engine.mainMixerNode`.
    /// 4. `engine.prepare()` + `engine.start()`.
    public func powerOn() async {
        guard let source = currentSource else {
            lastError = .engine("No source selected.")
            return
        }
        guard captureState == .idle || isFailedState(captureState) else {
            return
        }
        // The debug reader test owns a tap on this same process for ~5 s, and
        // it leaves captureState at .idle, so the guard above does not catch
        // it. Starting production capture concurrently would create a second
        // tap/aggregate on the process (the overlap runReaderTest's own guard
        // prevents in the other direction), risking a HAL configuration change
        // or start failure. Refuse until the test finishes. (Codex PR #10
        // re-review — symmetric with the runReaderTest idle guard.)
        guard !isReaderTestRunning else {
            lastError = .engine(
                "A diagnostic reader test is running. Wait a few seconds for it "
                + "to finish, then press Start again."
            )
            return
        }
        lastError = nil

        // Prefer the exact live PID. After a relaunch, only a unique bundle
        // and display-name match is safe enough to use without another pick.
        let resolvedSource: CaptureSource
        do {
            let candidates = try await Task.detached(priority: .userInitiated) { [capture] in
                try capture.availableSources()
            }.value
            // A newer pick or clear supersedes this suspended Start.
            guard currentSource == source else { return }
            let match = candidates.first(where: { $0.pid == source.pid })
                ?? Self.uniqueSource(
                    in: candidates,
                    bundleID: source.bundleIdentifier,
                    displayName: source.displayName
                )
            guard let match else {
                currentSource = nil
                writeSourcePersistence()
                lastError = .capture(.sourceNotFound(source.pid))
                return
            }
            resolvedSource = match
        } catch {
            guard currentSource == source else { return }
            if let captureError = error as? CaptureError {
                lastError = .capture(captureError)
            } else {
                lastError = .engine("Source enumeration failed: \(error.localizedDescription)")
            }
            return
        }

        do {
            try capture.start(source: resolvedSource, into: engine)
        } catch let error as CaptureError {
            lastError = .capture(error)
            return
        } catch {
            lastError = .engine("Capture start failed: \(error.localizedDescription)")
            return
        }

        guard let sourceNode = capture.captureSourceNode else {
            stopCaptureLoggingRollbackError(primaryStage: "captureSourceNode lookup")
            lastError = .engine("Capture started but no source node was published.")
            return
        }

        do {
            try graph.attach(
                to: engine,
                source: sourceNode,
                destination: engine.mainMixerNode,
                sourceFormat: capture.captureFormat
            )
        } catch {
            stopCaptureLoggingRollbackError(primaryStage: "graph attach")
            logger.error("Graph attach failed: \(error.localizedDescription) — full: \(String(describing: error))")
            lastError = .graph("Graph attach failed: \(error.localizedDescription)")
            return
        }

        engine.prepare()

        do {
            try engine.start()
            engineIsRunning = true
            // Re-apply each node's wet/dry + bypass gains now that the engine
            // is running. The mixer destinations the nodes use are nil while
            // the engine is stopped, so gains set during attach do not land
            // until here — without this a preset-loaded bypass / non-50-50 mix
            // is ignored on power-on until the user touches a control.
            // (Codex PR #10 review.)
            graph.refreshNodeMixState()
            let chainSummary = graph.nodes.isEmpty
                ? "EMPTY (audio passes through unprocessed; add effects to hear filtering)"
                : graph.nodes.map { type(of: $0).typeIdentifier }.joined(separator: " -> ")
            logger.info("powerOn complete: engine started, capture running on \(resolvedSource.displayName), chain: \(chainSummary)")
            Self.logChainFormats(
                stage: "powerOn",
                sourceNode: sourceNode,
                engine: engine,
                logger: logger
            )
        } catch {
            graph.detach()
            stopCaptureLoggingRollbackError(primaryStage: "engine start")
            let nsError = error as NSError
            let outFormat = engine.outputNode.outputFormat(forBus: 0)
            logger.error("Engine start failed: domain=\(nsError.domain) code=\(nsError.code) desc=\(error.localizedDescription)")
            logger.error("outputNode.outputFormat=\(outFormat.sampleRate) Hz × \(outFormat.channelCount) ch")
            if !nsError.userInfo.isEmpty {
                logger.error("userInfo: \(nsError.userInfo)")
            }
            lastError = .engine("Engine start failed: \(error.localizedDescription)")
            return
        }

        currentSource = resolvedSource
        schedulePersistence()
    }

    public func powerOff() async {
        // Stopping the engine and detaching the graph are separate conditions,
        // because they can disagree. A failed configuration-change restart
        // leaves `engineIsRunning` false with the graph still attached; the
        // old single `if engineIsRunning` guard therefore skipped
        // `graph.detach()`, and the next `powerOn()` hit
        // `GraphError.alreadyAttached` — capture could not be restarted at all
        // without relaunching the app. Drive each teardown from the state that
        // actually governs it.
        if engineIsRunning || engine.isRunning {
            engine.stop()
            engineIsRunning = false
        }
        if graph.isAttached {
            graph.detach()
        }
        // Powering off resolves the stall by definition: nothing is running to
        // be stalled. Without this the pill would keep reporting a failure into
        // the next session.
        engineStalled = false
        do {
            try capture.stop()
        } catch let error as CaptureError {
            lastError = .capture(error)
        } catch {
            lastError = .engine("Capture stop failed: \(error.localizedDescription)")
        }
    }

    public func clearError() {
        lastError = nil
    }

    // MARK: Graph mutations

    public func addEffect(of typeIdentifier: String) {
        logger.info("addEffect: \(typeIdentifier) (chain size before: \(self.graph.nodes.count))")
        mutateGraph { graph in
            let node = try registry.makeNode(typeIdentifier: typeIdentifier)
            try graph.add(node)
        }
        logger.info("addEffect: complete (chain size after: \(self.graph.nodes.count))")
    }

    public func removeEffect(at index: Int) {
        logger.info("removeEffect: at index \(index) (chain size before: \(self.graph.nodes.count))")
        mutateGraph { graph in
            try graph.remove(at: index)
        }
        logger.info("removeEffect: complete (chain size after: \(self.graph.nodes.count))")
    }

    public func moveEffect(from: Int, to: Int) {
        logger.info("moveEffect: from \(from) to \(to)")
        mutateGraph { graph in
            try graph.move(from: from, to: to)
        }
    }

    public func updateParameter(nodeID: UUID, paramID: String, value: Float) {
        let shortID = String(nodeID.uuidString.prefix(8))
        guard let node = graph.nodes.first(where: { $0.id == nodeID }) else {
            logger.warning("updateParameter: unknown node \(shortID) (param \(paramID)=\(value))")
            lastError = .parameter("Unknown node \(nodeID).")
            return
        }
        do {
            try node.setParameter(paramID, value: value)
            logger.info("updateParameter: \(type(of: node).typeIdentifier)/\(shortID) \(paramID)=\(value)")
            schedulePersistence()
        } catch {
            logger.error("updateParameter: \(type(of: node).typeIdentifier)/\(shortID) \(paramID)=\(value) failed: \(error.localizedDescription)")
            lastError = .parameter(error.localizedDescription)
        }
    }

    public func updateWetDryMix(nodeID: UUID, value: Float) {
        let shortID = String(nodeID.uuidString.prefix(8))
        guard let node = graph.nodes.first(where: { $0.id == nodeID }) else {
            logger.warning("updateWetDryMix: unknown node \(shortID) (value \(value))")
            lastError = .parameter("Unknown node \(nodeID).")
            return
        }
        let clamped = min(max(value, 0.0), 1.0)
        // EXP-031: shares `applyMixGains()` with setBypass, so we mirror the
        // before/after diagnostic block here. If the bug is in
        // `applyMixGains` itself, wetDryMix changes will produce the same
        // log signature shape as bypass toggles.
        logger.info(
            "[EXP-031.wetDryMix.before] node=\(shortID) "
            + "type=\(type(of: node).typeIdentifier) "
            + "requested=\(clamped) state={\(node.debugStateDescription())}"
        )
        node.wetDryMix = clamped
        logger.info(
            "[EXP-031.wetDryMix.after] node=\(shortID) "
            + "type=\(type(of: node).typeIdentifier) "
            + "state={\(node.debugStateDescription())} "
            + "engine.isRunning=\(engine.isRunning)"
        )
        logger.info("updateWetDryMix: \(type(of: node).typeIdentifier)/\(shortID) wetDryMix=\(clamped)")
        objectWillChange.send()
        schedulePersistence()
    }

    public func setBypass(nodeID: UUID, bypass: Bool) {
        let shortID = String(nodeID.uuidString.prefix(8))
        logger.info(
            "[EXP-031.setBypass.entry] node=\(shortID) requested=\(bypass) "
            + "engineIsRunning=\(engineIsRunning) engine.isRunning=\(engine.isRunning)"
        )
        guard let node = graph.nodes.first(where: { $0.id == nodeID }) else {
            logger.warning("[EXP-031.setBypass.entry] unknown node \(shortID)")
            lastError = .parameter("Unknown node \(nodeID).")
            return
        }
        logger.info(
            "[EXP-031.setBypass.before] node=\(shortID) "
            + "type=\(type(of: node).typeIdentifier) "
            + "state={\(node.debugStateDescription())}"
        )
        node.bypass = bypass
        logger.info(
            "[EXP-031.setBypass.after] node=\(shortID) "
            + "type=\(type(of: node).typeIdentifier) "
            + "state={\(node.debugStateDescription())} "
            + "engine.isRunning=\(engine.isRunning)"
        )
        objectWillChange.send()
        schedulePersistence()
    }

    // MARK: Presets

    public func savePreset(to url: URL) {
        let snapshot = graph.snapshot(name: url.deletingPathExtension().lastPathComponent)
        do {
            try PresetStore.save(snapshot, to: url)
        } catch {
            lastError = .preset("Save failed: \(error.localizedDescription)")
        }
    }

    public func loadPreset(from url: URL) {
        do {
            let preset = try PresetStore.load(from: url)
            try installPreset(PresetMigrator.migrate(preset))
        } catch {
            lastError = .preset("Load failed: \(error.localizedDescription)")
        }
    }

    public func loadFactoryPreset(named name: String) {
        do {
            let preset = try FactoryPresets.load(named: name)
            try installPreset(PresetMigrator.migrate(preset))
        } catch {
            lastError = .preset("Factory preset load failed: \(error.localizedDescription)")
        }
    }

    // MARK: Internals

    /// Apply a mutation closure to the graph. If the engine is running,
    /// detach the graph for the mutation and re-attach via the same path
    /// `powerOn` uses (source node → mainMixerNode).
    private func mutateGraph(_ mutation: (Graph) throws -> Void) {
        let wasRunning = engineIsRunning
        logger.info(
            "[EXP-031.mutateGraph.entry] wasRunning=\(wasRunning) "
            + "engine.isRunning=\(engine.isRunning)"
        )
        if engineIsRunning {
            engine.stop()
            graph.detach()
            engineIsRunning = false
            logger.info(
                "[EXP-031.mutateGraph.detached] engine.stop() + graph.detach() done — "
                + "engine.isRunning=\(engine.isRunning)"
            )
        }
        do {
            try mutation(graph)
        } catch {
            logger.error(
                "[EXP-031.mutateGraph.error] mutation failed: \(error.localizedDescription)"
            )
            lastError = .graph(error.localizedDescription)
            if wasRunning {
                reattachAfterMutation()
            }
            return
        }
        objectWillChange.send()
        schedulePersistence()

        if wasRunning {
            logger.info("[EXP-031.mutateGraph.reattaching] calling reattachAfterMutation")
            reattachAfterMutation()
        }
        logger.info(
            "[EXP-031.mutateGraph.exit] wasRunning=\(wasRunning) "
            + "engineIsRunning_now=\(engineIsRunning) engine.isRunning=\(engine.isRunning)"
        )
    }

    /// Re-attach the graph after a live mutation and restart the engine.
    /// V2 path: the graph head is the captureSourceNode, not
    /// `engine.inputNode`.
    private func reattachAfterMutation() {
        logger.info("[EXP-031.reattach.entry] called")
        guard let sourceNode = capture.captureSourceNode else {
            logger.error(
                "[EXP-031.reattach.fail] captureSourceNode unavailable"
            )
            handleReattachFailure(
                NSError(
                    domain: "tnf.viewmodel",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "captureSourceNode unavailable"]
                ),
                stage: "graph attach",
                graphAttached: false
            )
            return
        }
        do {
            try graph.attach(
                to: engine,
                source: sourceNode,
                destination: engine.mainMixerNode,
                sourceFormat: capture.captureFormat
            )
            logger.info("[EXP-031.reattach.graphAttached] graph.attach OK")
        } catch {
            logger.error(
                "[EXP-031.reattach.fail] graph.attach error=\(error.localizedDescription)"
            )
            handleReattachFailure(error, stage: "graph attach", graphAttached: false)
            return
        }
        do {
            try engine.start()
            engineIsRunning = true
            // See powerOn: re-apply node mix gains once the engine is running.
            graph.refreshNodeMixState()
            logger.info(
                "[EXP-031.reattach.engineStarted] engine.isRunning=\(engine.isRunning)"
            )
            Self.logChainFormats(
                stage: "reattach",
                sourceNode: sourceNode,
                engine: engine,
                logger: logger
            )
        } catch {
            logger.error(
                "[EXP-031.reattach.fail] engine.start error=\(error.localizedDescription)"
            )
            handleReattachFailure(error, stage: "engine start", graphAttached: true)
        }
    }

    private func handleReattachFailure(_ error: Error, stage: String, graphAttached: Bool) {
        if graphAttached {
            graph.detach()
        }
        do {
            try capture.stop()
        } catch let stopError {
            logger.error("capture.stop after reattach \(stage) failure also failed: \(stopError.localizedDescription)")
        }
        logger.error("Re-attach \(stage) failed after graph mutation: \(error.localizedDescription) — full error: \(String(describing: error))")
        lastError = .engine("Re-attach failed after graph mutation: \(error.localizedDescription)")
    }

    /// Stop the capture controller as part of a rollback, logging any
    /// secondary error rather than discarding it.
    private func stopCaptureLoggingRollbackError(primaryStage: String) {
        do {
            try capture.stop()
        } catch {
            logger.error(
                "Rollback after \(primaryStage) failure: capture.stop also failed: \(error.localizedDescription)"
            )
        }
    }

    /// Replace the current graph with one loaded from a preset.
    private func installPreset(_ preset: GraphPreset) throws {
        let wasRunning = engineIsRunning
        if engineIsRunning {
            engine.stop()
            graph.detach()
            engineIsRunning = false
        }
        let newGraph: Graph
        do {
            newGraph = try Graph.restore(from: preset, using: registry)
        } catch {
            if wasRunning {
                reattachAfterMutation()
            }
            throw error
        }
        graph = newGraph
        for warning in newGraph.lastLoadWarnings {
            logger.warning("Preset load warning: \(String(describing: warning))")
        }
        schedulePersistence()
        if wasRunning {
            reattachAfterMutation()
        }
    }

    // MARK: Persistence

    /// [EXP-032] H17 source-grounding. Logs the negotiated audio format
    /// at the engine boundaries the user-audible
    /// "voice-changer / pitched-down / crackling / left-shift" artifact
    /// could originate from: the `AVAudioSourceNode` we declared with the
    /// tap's `reader.format`, the mainMixer node (after the effect chain),
    /// and the engine's output node. If the source-node's reported
    /// outputFormat differs from the tap's 48 kHz × 2 ch — or if
    /// `commonFormat` / `isInterleaved` flips somewhere in the chain — the
    /// engine has silently renegotiated the format and H17 is confirmed.
    /// See `docs/investigations/2026-05-audio-pipeline.md` (H17,
    /// "How to confirm").
    @MainActor
    private static func logChainFormats(
        stage: String,
        sourceNode: AVAudioSourceNode,
        engine: AVAudioEngine,
        logger: TnfLogger
    ) {
        let sourceFmt = sourceNode.outputFormat(forBus: 0)
        let mainMixerIn = engine.mainMixerNode.inputFormat(forBus: 0)
        let mainMixerOut = engine.mainMixerNode.outputFormat(forBus: 0)
        let outputIn = engine.outputNode.inputFormat(forBus: 0)
        let outputOut = engine.outputNode.outputFormat(forBus: 0)
        logger.info("[EXP-032.format.source stage=\(stage)] \(describeFormat(sourceFmt))")
        logger.info("[EXP-032.format.mainMixerIn stage=\(stage)] \(describeFormat(mainMixerIn))")
        logger.info("[EXP-032.format.mainMixerOut stage=\(stage)] \(describeFormat(mainMixerOut))")
        logger.info("[EXP-032.format.outputIn stage=\(stage)] \(describeFormat(outputIn))")
        logger.info("[EXP-032.format.outputOut stage=\(stage)] \(describeFormat(outputOut))")
    }

    private static func describeFormat(_ format: AVAudioFormat) -> String {
        let common: String
        switch format.commonFormat {
        case .pcmFormatFloat32: common = "Float32"
        case .pcmFormatFloat64: common = "Float64"
        case .pcmFormatInt16: common = "Int16"
        case .pcmFormatInt32: common = "Int32"
        case .otherFormat: common = "other"
        @unknown default: common = "unknown"
        }
        return "rate=\(format.sampleRate) ch=\(format.channelCount) common=\(common) interleaved=\(format.isInterleaved)"
    }

    private static func restoreGraph(
        from defaults: UserDefaults,
        registry: EffectNodeRegistry,
        logger: Logger
    ) -> Graph {
        if let data = defaults.data(forKey: AppViewModelDefaultsKey.graph) {
            do {
                let preset = try JSONDecoder().decode(GraphPreset.self, from: data)
                let migrated = PresetMigrator.migrate(preset)
                return try Graph.restore(from: migrated, using: registry)
            } catch {
                logger.warning("Failed to decode lastSession.graph; falling back to distant-engines: \(error.localizedDescription, privacy: .public)")
            }
        } else {
            logger.info("No lastSession.graph in UserDefaults; falling back to distant-engines.")
        }
        return restoreDistantEngines(registry: registry, logger: logger)
    }

    private static func restoreDistantEngines(
        registry: EffectNodeRegistry,
        logger: Logger
    ) -> Graph {
        do {
            let preset = try FactoryPresets.load(named: "distant-engines")
            return try Graph.restore(from: preset, using: registry)
        } catch {
            logger.error("Failed to load distant-engines fallback; returning empty graph: \(error.localizedDescription, privacy: .public)")
            return Graph()
        }
    }

    private func restoreSourceFromDefaults() {
        guard let bundleID = defaults.string(forKey: AppViewModelDefaultsKey.sourceBundleID),
              !bundleID.isEmpty
        else { return }
        let displayName = defaults.string(forKey: AppViewModelDefaultsKey.sourceDisplayName)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let candidates = try await self.fetchAvailableSourcesOffMain()
                guard self.currentSource == nil else {
                    self.logger.info("Skipping restore for \(bundleID): currentSource already set.")
                    return
                }
                // A failed Start can clear the saved identity while this
                // enumeration is in flight. Never reinstate that rejected pick.
                guard self.defaults.string(forKey: AppViewModelDefaultsKey.sourceBundleID) == bundleID,
                      self.defaults.string(forKey: AppViewModelDefaultsKey.sourceDisplayName) == displayName
                else { return }
                guard let match = Self.uniqueSource(
                    in: candidates,
                    bundleID: bundleID,
                    displayName: displayName
                ) else { return }
                self.currentSource = match
                if displayName == nil {
                    self.writeSourcePersistence()
                }
            } catch {
                self.logger.warning("Source restore failed: \(error.localizedDescription)")
            }
        }
    }

    private func fetchAvailableSourcesOffMain() async throws -> [CaptureSource] {
        try await Task.detached(priority: .userInitiated) { [capture] in
            try capture.availableSources()
        }.value
    }

    private func schedulePersistence() {
        persistenceWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.writePersistence()
        }
        persistenceWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.persistenceDebounceInterval,
            execute: item
        )
    }

    private func writePersistence() {
        let snapshot = graph.snapshot(name: "lastSession")
        do {
            let data = try JSONEncoder().encode(snapshot)
            defaults.set(data, forKey: AppViewModelDefaultsKey.graph)
        } catch {
            logger.error("Failed to encode graph for persistence: \(error.localizedDescription)")
        }
        writeSourcePersistence()
    }

    /// Source-only updates must not autosave the graph during legacy restore
    /// or leave a rejected selection eligible for another Start.
    private func writeSourcePersistence() {
        if let source = currentSource, let bundleID = source.bundleIdentifier, !bundleID.isEmpty {
            defaults.set(bundleID, forKey: AppViewModelDefaultsKey.sourceBundleID)
            defaults.set(source.displayName, forKey: AppViewModelDefaultsKey.sourceDisplayName)
        } else {
            defaults.removeObject(forKey: AppViewModelDefaultsKey.sourceBundleID)
            defaults.removeObject(forKey: AppViewModelDefaultsKey.sourceDisplayName)
        }
    }

    // MARK: Source refresh

    public func refreshAvailableSources() {
        guard refreshSourcesTask == nil || refreshSourcesTask?.isCancelled == true else {
            return
        }
        refreshSourcesTask = Task { @MainActor [weak self] in
            defer { self?.refreshSourcesTask = nil }
            do {
                let sources = try await self?.fetchAvailableSourcesOffMain() ?? []
                self?.availableSources = sources
            } catch {
                self?.logger.warning("Source refresh failed: \(error.localizedDescription)")
            }
        }
    }

    private func startSourceRefreshTimer() {
        sourceRefreshTimer?.invalidate()
        sourceRefreshTimer = Timer.scheduledTimer(
            withTimeInterval: 5.0,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAvailableSources()
            }
        }
    }

    private func isFailedState(_ state: CaptureState) -> Bool {
        if case .failed = state { return true }
        return false
    }
}
