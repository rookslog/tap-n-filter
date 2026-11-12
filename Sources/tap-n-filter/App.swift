import AppKit
import Capture
import Darwin
import EverydayMenu
import PlaybackOutput
import PlaybackRuntime
import PlaybackRuntimeCaptureAdapters
import PlaybackRenderBridge
import SessionStore
import SoundModel

enum LaunchPresentation: Equatable {
  case menuOnly
  case compatibility

  static func select(arguments: [String]) -> Self {
    arguments.contains("--smoke") || arguments.contains("--probe-bundle")
      ? .compatibility : .menuOnly
  }

  var requestedPolicyValue: Int { self == .menuOnly ? 1 : 0 }

  func accepts(setterSucceeded: Bool, effectivePolicyValue: Int) -> Bool {
    self == .compatibility || effectivePolicyValue == requestedPolicyValue
  }
}

@MainActor
final class TNFDelegate: NSObject, NSApplicationDelegate {
  private var releasingLibraryCompare = false
  private var library: LibraryAppSession?
  private var editorWindow: TNFEditorWindowController?
  private var model: ListeningSession?
  private var snapshot: ListeningSnapshot?
  private var visualizationTimer: Timer?
  private var visualizationMode: MenuVisualizationMode?
  private var visualizationRequest: VisualizationRequest?
  private var visualizationEpoch: UInt64 = 0
  private var surface: EverydayMenu?
  private var store: ListeningSessionFile?
  private var playback: PlaybackController?
  private let coreAudio = RealCoreAudioInterface()
  private let ownedProbe: OwnedProbeBinding?
  private let requestedProbe: RequestedSafariOptions?
  private var apps: [SourceAppInfo] = []
  private var original = false
  private var problem: String?
  private var canSave = true
  private var launchTask: Task<Void, Never>?
  private var commands: Task<Void, Never>?
  private var autosave: Task<Void, Never>?
  private enum QuitState { case running, draining, ready }
  private var quitState = QuitState.running
  private let probeStop = ProbeStopCoordinator()
  private var probeSource: OwnedProbeSource?
  private var probeSetupLease: InputGuardLease?
  private var probeLeases: InputGuardLeaseCoordinator?
  private var probeControls: Task<Void, Never>?
  private var probeSignals: [DispatchSourceSignal] = []
  private var probeMetrics: [PlaybackTelemetry] = []
  private var probeProblem = false
  private var probeDrainUnconfirmed = false
  private var probeStopping = false
  private let smoke = CommandLine.arguments.contains("--smoke")

  init(ownedProbe: OwnedProbeOptions? = nil, requestedProbe: RequestedSafariOptions? = nil) {
    self.ownedProbe = ownedProbe.map(OwnedProbeBinding.init)
    self.requestedProbe = requestedProbe
    super.init()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    if argument("--probe-bundle") != nil { installProbeControls() }
    launchTask = Task { @MainActor in
      do { try await boot() } catch is CancellationError {} catch {
        if argument("--probe-bundle") == nil {
          print("FAIL startup: \(error)")
        } else {
          print("PROBE startup-error")
          if requestedProbe != nil {
            print(ProbeTargetFailure(stage: "app-boot", code: "startup-refused").record())
          }
          probeProblem = true
        }
        if smoke { exit(1) }
        if argument("--probe-bundle") != nil {
          requestTermination()
          return
        }
        let alert = NSAlert()
        alert.messageText = "TNF Could Not Start"
        alert.informativeText = String(describing: error)
        NSApplication.shared.activate()
        alert.runModal()
        requestTermination()
      }
    }
  }

  private func boot() async throws {
    let probe = argument("--probe-bundle")
    if !smoke && probe == nil {
      let url = try LibrarySessionConfiguration.normal(arguments: CommandLine.arguments,
        packagedLibraryValue: Bundle.main.object(forInfoDictionaryKey: LibrarySessionConfiguration.trialInfoKey),
        packagedLegacyValue: Bundle.main.object(forInfoDictionaryKey: SessionLocation.trialInfoKey))
      let limits = try LibraryAppSession.normalLimits()
      let owner = LibraryAppSession(changed: { [weak self] in self?.refreshMenu() },
        positionsChanged: { [weak self] delta, context in self?.surface?.applyPositions(delta, context: context) ?? true })
      library = owner
      await owner.start(persistence: LibrarySessionFile(url: url, maximumBytes: limits.maximumBytes), limits: limits)
      guard let accepted = owner.presentation else { throw LibraryConsumerLifecycleError.notReady }
      guard owner.coordinator.lifecycle == .running else { return }
      let glyph = try menuGlyph()
      surface = EverydayMenu(presentation: accepted, glyph: glyph,
        visibilityChanged: { [weak self] in self?.recordMenuVisibility($0) },
        visualizationDemandChanged: { [weak self] in self?.setVisualizationMode($0) }
      ) { [weak self] in self?.send($0) }
    } else {
      let url = try SessionLocation.select(cliPath: argument("--session-file"), requiresExplicitCLI: true,
        packagedValue: Bundle.main.object(forInfoDictionaryKey: SessionLocation.trialInfoKey)) {
          preconditionFailure("diagnostics require an explicit session file")
        }
      let store = ListeningSessionFile(url: url)
      self.store = store
      let input = await AppSessionInput.read { try await store.load() }
      let startup = try await AppSessionStartup.prepare(input, mode: smoke ? .smoke : .probe)
      let model = startup.model
      canSave = startup.canSave
      if let error = startup.error {
        problem = "The saved session could not be read. It has been kept at \(url.path). \(error)"
      }
      self.model = model
      if probe != nil { try await model.setEnabled(false) }
      let snapshot = try await model.snapshot()
      self.snapshot = snapshot
      let glyph = try menuGlyph()
      surface = EverydayMenu(snapshot: snapshot, glyph: glyph,
        visibilityChanged: { [weak self] in self?.recordMenuVisibility($0) },
        visualizationDemandChanged: { [weak self] in self?.setVisualizationMode($0) }
      ) { [weak self] in self?.send($0) }
    }
    let main = NSMenu()
    let application = NSMenuItem(title: "TNF", action: nil, keyEquivalent: "")
    application.submenu = surface?.appMenu
    main.addItem(application)
    NSApplication.shared.mainMenu = main
    if smoke, let model, let store {
      try await smokeCheck(model, store: store)
      requestTermination()
      return
    }
    let guardPort = DefaultInputGuardAdapter(
      control: SystemDefaultInputControl(), defaults: .standard
    ) {
      if probe == nil { print("input-guard \($0)") }
    }
    let recovered = await guardPort.recoverIfStranded()
    print("input-guard recovery \(recovered)")
    try Task.checkCancellation()
    if let library, library.coordinator.lifecycle != .running { return }
    let leases = InputGuardLeaseCoordinator(port: guardPort, settingEnabled: true)
    let capture: any CoreAudioInterface
    if let requestedProbe {
      capture = ProbeBundleCapture(
        base: coreAudio, mode: .requestedSafariBundle,
        validate: {
          try requestedProbe.target.validate(RequestedSafariTarget.current())
        })
    } else if let ownedProbe {
      capture = ProbeBundleCapture(
        base: coreAudio, arm: ownedProbe.options.arm,
        validate: {
          try ownedProbe.validate(OwnedProbeIdentity.running(bundle: ownedProbe.options.bundle))
        })
    } else {
      capture = coreAudio
    }
    let playback = PlaybackController(
      coreAudio: capture, leases: leases, probeOutputEnabled: probe != nil)
    playback.log = { [weak self] value in
      if probe == nil { print(value); return }
      if ProbeDiagnostics.teardownUnconfirmed(value) { self?.probeDrainUnconfirmed = true }
      if let line = ProbeDiagnostics.visible(value) { print(line) }
    }
    playback.changed = { [weak self] in
      self?.library?.coordinator.playbackDidChange()
      self?.refreshMenu()
    }
    self.playback = playback
    refreshSources()
    if let library {
      _ = await library.coordinator.attachPlayback { [playback, weak self] snapshot, comparing, mode in
        switch mode {
        case .activation: playback.apply(snapshot, original: comparing)
        case .positions:
          if playback.updatePositions(snapshot, original: comparing) == .requiresFull {
            self?.library?.coordinator.playbackDidChange()
          }
        }
      }
    } else if let snapshot { playback.apply(snapshot, original: false) }
    refreshMenu()
    if library == nil { scheduleSave() }
    if let probe, let model { try await runProbe(model, playback: playback, leases: leases, bundle: probe) }
  }

  private func menuGlyph() throws -> NSImage {
    let packaged = Bundle.main.resourceURL.flatMap {
      Bundle(url: $0.appendingPathComponent("tap-n-filter_tap-n-filter.bundle", isDirectory: true))
    }
    let resources = packaged ?? Bundle.module
    guard let url = resources.url(forResource: "neck1", withExtension: "pdf", subdirectory: "Resources"),
          let glyph = NSImage(contentsOf: url) else { throw CocoaError(.fileReadNoSuchFile) }
    glyph.isTemplate = true; glyph.accessibilityDescription = "TNF"
    return glyph
  }

  private func requestTermination() {
    if argument("--probe-bundle") != nil {
      requestProbeStop("termination-request")
      return
    }
    guard quitState == .running else { return }
    quitState = .draining
    if let library {
      editorWindow?.prepareQuit()
      library.beginDrain()
      Task { @MainActor in
        // Canonical startup and issued replacement are joined, never cancelled.
        let result = await library.finishDrain(.save)
        switch result {
        case .saved: break
        default:
          let alert = NSAlert()
          alert.messageText = "The Session Could Not Be Saved"
          alert.informativeText = String(describing: result)
          alert.addButton(withTitle: "Cancel")
          alert.addButton(withTitle: "Quit Without Saving")
          NSApplication.shared.activate()
          guard alert.runModal() == .alertSecondButtonReturn else {
            _ = library.cancelDrain(); quitState = .running; return
          }
          _ = await library.finishDrain(.discard)
        }
        library.close()
        await launchTask?.value
        setVisualizationMode(nil)
        await playback?.shutdown()
        quitState = .ready
        NSApplication.shared.terminate(nil)
      }
      return
    }
    Task { @MainActor in
      launchTask?.cancel()
      await launchTask?.value
      await commands?.value
      autosave?.cancel()
      do { try await save() } catch {
        print("FAIL final save: \(error)")
        let alert = NSAlert()
        alert.messageText = "The Session Could Not Be Saved"
        alert.informativeText = String(describing: error)
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit Without Saving")
        NSApplication.shared.activate()
        guard alert.runModal() == .alertSecondButtonReturn else {
          quitState = .running
          return
        }
      }
      setVisualizationMode(nil)
      await playback?.shutdown()
      quitState = .ready
      if smoke { print("SMOKE saved and drained before termination") }
      NSApplication.shared.terminate(nil)
    }
  }

  private func argument(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name),
      CommandLine.arguments.indices.contains(index + 1)
    else { return nil }
    return CommandLine.arguments[index + 1]
  }

  private func send(_ action: EverydayMenuAction) {
    if let library {
      switch action {
      case .quit: requestTermination()
      case .refreshSources: refreshSources(); library.menuOpened()
      case .showProblem: showProblem()
      default: library.send(action)
      }
      return
    }
    switch action {
    case .compare(let value):
      original = value
      if let snapshot { playback?.apply(snapshot, original: original) }
      refreshMenu()
      return
    case .quit:
      requestTermination()
      return
    case .refreshSources:
      if !smoke { refreshSources() }
      return
    case .showProblem:
      showProblem()
      return
    default: break
    }
    guard quitState == .running else { return }
    let appRequest = surface?.pendingAppRequest(for: action)
    let previous = commands
    commands = Task { @MainActor [weak self] in
      await previous?.value
      guard let self, let model = self.model else { return }
      do {
        switch action {
        case .setEnabled(let enabled):
          self.original = false
          try await model.setEnabled(enabled)
        case .putOn(let bundle): try await model.putDefault(on: bundle)
        case .selectBlock(let definition, let bundle): try await model.select(definition, on: bundle)
        case .setAppEnabled(let id, let enabled): try await model.setEnabled(enabled, for: id)
        case .move(let id, let control, let position):
          try await model.move(control, on: id, to: position)
        default: return
        }
        let snapshot = try await model.snapshot()
        self.snapshot = snapshot
        self.playback?.apply(snapshot, original: self.original)
        self.refreshMenu(snapshotOrigin: .authoritative)
        self.scheduleSave()
      } catch {
        self.problem = "The change could not be saved. \(error)"
        if let appRequest {
          do {
            self.snapshot = try await model.snapshot()
            self.refreshMenu(snapshotOrigin: .authoritative)
            self.surface?.acknowledgeAppChangeFailure(appRequest.bundle, request: appRequest.request, outcome: .reconciled)
          } catch {
            self.surface?.acknowledgeAppChangeFailure(appRequest.bundle, request: appRequest.request, outcome: .unresolved)
          }
        }
        self.refreshMenu()
      }
    }
  }

  private func refreshSources() {
    let assigned = library?.presentation?.assignments.map(\.target) ?? snapshot?.assignments.map(\.bundleIdentifier) ?? []
    var installed: [SourceCatalogMetadata] = []
    var icons = Dictionary(apps.map { ($0.bundleIdentifier, $0.icon) }, uniquingKeysWith: { first, _ in first })
    for bundle in SourceCatalog.lookupBundles(assigned: assigned) {
      guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { continue }
      let info = Bundle(url: url)
      let name = info?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        ?? info?.object(forInfoDictionaryKey: "CFBundleName") as? String ?? bundle
      installed.append(SourceCatalogMetadata(bundleIdentifier: bundle, name: name))
      icons[bundle] = NSWorkspace.shared.icon(forFile: url.path)
    }
    let retained = apps.map { SourceCatalogMetadata(bundleIdentifier: $0.bundleIdentifier, name: $0.name) }
    apps = SourceCatalog.entries(installed: installed, assigned: assigned, retained: retained).map { entry in
      SourceAppInfo(bundleIdentifier: entry.metadata.bundleIdentifier, name: entry.metadata.name,
        icon: icons[entry.metadata.bundleIdentifier] ?? nil, isSelectable: entry.isSelectable)
    }
    refreshMenu()
  }

  private func openEditor(preferredApp: String?) {
    guard quitState == .running, let library, library.isReady else { return }
    if editorWindow == nil { editorWindow = TNFEditorWindowController(app: library) }
    editorWindow?.ownerDidChange(compareAvailable: playback?.compareAvailable == true)
    editorWindow?.open(preferredApp: preferredApp)
  }

  private func refreshMenu(snapshotOrigin: MenuSnapshotOrigin = .cached) {
    if let library, let snapshot = library.presentation {
      editorWindow?.ownerDidChange(compareAvailable: playback?.compareAvailable == true)
      guard library.coordinator.lifecycle != .closed, let data = library.menuData else { return }
      if playback?.compareAvailable != true && snapshot.compareOriginal && !releasingLibraryCompare {
        releasingLibraryCompare = true
        Task { @MainActor in
          _ = try? await library.coordinator.compareOriginal(false)
          releasingLibraryCompare = false
        }
      }
      surface?.update(data: data, positionContext: library.coordinator.positionContext, pendingApps: Set(library.roster.pending.keys), apps: apps,
        comparing: snapshot.compareOriginal, compareAvailable: playback?.compareAvailable == true,
        problem: library.problem != nil || problem != nil || playback?.problem != nil ? "Audio Needs Attention…" : nil)
      return
    }
    guard let snapshot else { return }
    if playback?.compareAvailable != true { original = false }
    surface?.update(
      snapshot: snapshot, apps: apps, comparing: original,
      compareAvailable: playback?.compareAvailable == true,
      problem: problem != nil || playback?.problem != nil ? "Audio Needs Attention…" : nil,
      snapshotOrigin: snapshotOrigin)
  }

  private func scheduleSave() {
    autosave?.cancel()
    guard canSave else { return }
    autosave = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(200))
        guard let self else { return }
        try await self.save()
      } catch is CancellationError {} catch {
        self?.problem = "The session could not be saved. \(error)"
        self?.refreshMenu()
      }
    }
  }

  private func save() async throws {
    guard canSave, let model, let store else { return }
    let checkpoint = try await model.checkpoint()
    _ = try await store.save(checkpoint)
  }

  private func setVisualizationMode(_ mode: MenuVisualizationMode?) {
    if let mode, visualizationMode != nil {
      visualizationMode = mode
      publishVisualization()
      return
    }
    visualizationTimer?.invalidate()
    visualizationTimer = nil
    visualizationMode = mode
    visualizationRequest = nil
    playback?.setVisualizationDemand(nil)
    guard mode != nil else { surface?.updateVisualization(.unavailable); return }
    publishVisualization()
    let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.publishVisualization() }
    }
    visualizationTimer = timer
    RunLoop.main.add(timer, forMode: .common)
    RunLoop.main.add(timer, forMode: .eventTracking)
  }

  private func publishVisualization() {
    guard let mode = visualizationMode,
      let snapshot = library?.neutral ?? self.snapshot.map(ListeningRenderSnapshot.init(legacy:)) else { return }
    let enabled = snapshot.assignments.filter(\.isEnabled)
    guard snapshot.isEnabled, !enabled.isEmpty else {
      visualizationRequest = nil; playback?.setVisualizationDemand(nil)
      surface?.updateVisualization(snapshot.isEnabled && snapshot.assignments.isEmpty ? .unavailable : .off)
      return
    }
    guard enabled.count == 1, enabled[0].bundleIdentifier == "com.apple.Safari" else {
      visualizationRequest = nil; playback?.setVisualizationDemand(nil)
      surface?.updateVisualization(.unavailable); return
    }
    if visualizationRequest?.assignment != enabled[0].id {
      guard visualizationEpoch < UInt64.max else { surface?.updateVisualization(.unavailable); return }
      visualizationEpoch += 1
      visualizationRequest = VisualizationRequest(epoch: visualizationEpoch, assignment: enabled[0].id,
        mode: VisualizationMode(rawValue: mode.rawValue)!)
      playback?.setVisualizationDemand(visualizationRequest)
    } else if visualizationRequest?.mode.rawValue != mode.rawValue {
      visualizationRequest = VisualizationRequest(epoch: visualizationEpoch, assignment: enabled[0].id,
        mode: VisualizationMode(rawValue: mode.rawValue)!)
      playback?.setVisualizationDemand(visualizationRequest)
    }
    guard let request = visualizationRequest, let playback else { surface?.updateVisualization(.unavailable); return }
    switch playback.visualizationSnapshot(matching: request.epoch) {
    case .unavailable(let reason):
      surface?.updateVisualization(reason == .off ? .off : reason == .warming ? .warming : .unavailable)
    case .live(let frame):
      guard frame.requestEpoch == request.epoch, frame.assignment == request.assignment,
        frame.mode == request.mode else { surface?.updateVisualization(.unavailable); return }
      surface?.updateVisualization(.live(MenuVisualizationFrame(sequence: frame.sequence,
        beforeWave: frame.beforeWave.map { MenuVisualizationExtrema(low: $0.low, high: $0.high) },
        afterWave: frame.afterWave.map { MenuVisualizationExtrema(low: $0.low, high: $0.high) },
        beforeSpectrum: frame.beforeSpectrum, afterSpectrum: frame.afterSpectrum,
        beforeRMSDBFS: frame.beforeRMSDBFS, afterRMSDBFS: frame.afterRMSDBFS,
        held: frame.compareActive, silent: frame.silent)))
    }
  }

  private func recordMenuVisibility(_ visible: Bool) {
    let mode = LaunchPresentation.select(arguments: CommandLine.arguments)
    guard mode == .menuOnly else { return }
    let app = NSApplication.shared
    let windows = app.windows
    print("TNF_MENU visible=\(visible ? 1 : 0) active=\(app.isActive ? 1 : 0) requested=\(mode.requestedPolicyValue) effective=\(app.activationPolicy().rawValue) ownWindows=\(windows.count) ownActiveSpaceWindows=\(windows.filter { $0.isOnActiveSpace }.count) beforeClick=unavailable")
  }

  private func showProblem() {
    let alert = NSAlert()
    alert.messageText = "Audio Needs Attention"
    alert.informativeText = library?.problem ?? problem ?? playback?.problem ?? "Playback is ready."
    if playback?.problem != nil { alert.addButton(withTitle: "Try Again") }
    alert.addButton(withTitle: "OK")
    NSApplication.shared.activate()
    let retry = playback?.problem != nil
    if alert.runModal() == .alertFirstButtonReturn && retry { playback?.retry() }
  }

  func applicationDockMenu(_ sender: NSApplication) -> NSMenu? { surface?.dockMenu }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if quitState == .ready { return .terminateNow }
    // Returning keeps AppKit out of the nested terminate-later loop while
    // asynchronous MainActor teardown still needs the ordinary event loop.
    requestTermination()
    return .terminateCancel
  }

  private func smokeCheck(_ model: ListeningSession, store: ListeningSessionFile) async throws {
    try await model.putEveryday(on: "test.tnf-smoke")
    let assignment = try await model.snapshot().assignments[0]
    try await model.move(model.controls[2].id, on: assignment.id, to: 0.43)
    try await model.setEnabled(true)
    let checkpoint = try await model.checkpoint()
    _ = try await store.save(checkpoint)
    let restored = try await ListeningSession(savedData: store.load())
    let snapshot = try await restored.snapshot()
    precondition(snapshot.isEnabled && snapshot.assignments[0].id == assignment.id)
    precondition(snapshot.assignments[0].controls[2].position == 0.43)
    print(
      "PASS real app boot/menu/model/atomic-file reload; smoke path never constructs playback or enumerates HAL"
    )
  }

  private func installProbeControls() {
    for number in [SIGINT, SIGTERM] {
      signal(number, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
      source.setEventHandler { [weak self] in self?.requestProbeStop("signal") }
      source.resume()
      probeSignals.append(source)
    }
    probeControls = Task { @MainActor [weak self] in
      let deadline = ContinuousClock.now.advanced(by: .seconds(35))
      while !Task.isCancelled {
        guard let self else { return }
        if let path = self.argument("--probe-stop-file"),
          FileManager.default.fileExists(atPath: path)
        {
          self.requestProbeStop("control-request")
          return
        }
        if ContinuousClock.now >= deadline {
          self.requestProbeStop("startup-or-run-timeout")
          return
        }
        try? await Task.sleep(for: .milliseconds(100))
      }
    }
  }

  private func disarmProbeSource() async -> Bool {
    guard let text = argument("--probe-source-url"), let base = URL(string: text),
      base.scheme == "http", base.host == "127.0.0.1"
    else {
      if let probeSource { await probeSource.stop(); return probeSource.hasStopped }
      return false
    }
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 1
    config.timeoutIntervalForResource = 1
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: base.appendingPathComponent("disarm"))
    request.httpMethod = "POST"
    guard let (_, response) = try? await session.data(for: request),
      (response as? HTTPURLResponse)?.statusCode == 204
    else { return false }
    // A server latch is not a browser stop witness. Bound the wait, report a
    // missing witness unconfirmed, and still drain our native playback.
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    repeat {
      if let (data, _) = try? await session.data(from: base.appendingPathComponent("armed")),
        ProbeDiagnostics.sourceStopped(in: data)
      {
        return true
      }
      try? await Task.sleep(for: .milliseconds(100))
    } while ContinuousClock.now < deadline
    return false
  }

  private func requestProbeStop(_ reason: String) {
    guard !probeStopping else { return }
    probeStopping = true
    quitState = .draining
    probeControls?.cancel()
    Task { @MainActor in
      let result = await probeStop.stop(
        reason: reason,
        disarm: { await self.disarmProbeSource() },
        cancelAndJoinStartup: {
          self.launchTask?.cancel()
          await self.launchTask?.value
          await self.commands?.value
          self.autosave?.cancel()
        },
        stopOwnedSource: { await self.probeSource?.stop() },
        drain: {
          if self.probeMetrics.isEmpty { self.probeMetrics = self.playback?.telemetry ?? [] }
          self.probeProblem = self.probeProblem || self.playback?.problem != nil
          await self.playback?.shutdown()
          if let lease = self.probeSetupLease { _ = await self.probeLeases?.release(lease) }
          self.probeSetupLease = nil
          return !self.probeDrainUnconfirmed && (self.playback?.guardLeaseCount ?? 0) == 0
            && UserDefaults.standard.string(forKey: DefaultInputGuard.strandedInputMarkerKey)
              == nil
        })
      struct Receipt: Encodable {
        let version: Int
        let reason: String
        let sourceStopped: Bool
        let leasesAfterStop: Int
        let markerRetained: Bool
        let teardownUnconfirmed: Bool
        let cleanup: String
        let inputSignalObserved: Bool
        let telemetry: [PlaybackTelemetry]
        let problemPresent: Bool
      }
      let marker =
        UserDefaults.standard.string(forKey: DefaultInputGuard.strandedInputMarkerKey) != nil
      let receipt = Receipt(
        version: 2, reason: result.reason, sourceStopped: result.sourceStopped,
        leasesAfterStop: self.playback?.guardLeaseCount ?? 0, markerRetained: marker,
        teardownUnconfirmed: self.probeDrainUnconfirmed,
        cleanup: result.clean ? "graceful-confirmed" : "cleanup-unconfirmed",
        inputSignalObserved: self.probeMetrics.contains {
          $0.state == "running" && $0.capturedFrames > 0 && $0.nonSilentMeasuredFrames > 0
            && $0.errors == 0 && $0.nativeStatus == 0
        }, telemetry: self.probeMetrics, problemPresent: self.probeProblem)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      if let path = self.argument("--probe-report"), let data = try? encoder.encode(receipt) {
        do { try data.write(to: URL(fileURLWithPath: path), options: .atomic) } catch {
          print("PROBE receipt-write-failed")
        }
      }
      print("PROBE_CLEANUP \(receipt.cleanup)")
      self.probeSignals.forEach { $0.cancel() }
      self.quitState = .ready
      NSApplication.shared.terminate(nil)
    }
  }

  private func runProbe(
    _ model: ListeningSession, playback: PlaybackController,
    leases: InputGuardLeaseCoordinator, bundle: String
  ) async throws {
    guard argument("--probe-report") != nil else { throw CocoaError(.fileWriteInvalidFileName) }
    probeLeases = leases
    if let executable = argument("--fixture-source"), let path = argument("--probe-report") {
      probeSetupLease = await leases.acquire().lease
      try Task.checkCancellation()
      probeSource = try OwnedProbeSource(
        executable: URL(fileURLWithPath: executable),
        log: URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent(
          "source.log"))
      try await probeSource?.waitForZeroReady()
      if let ownedProbe {
        try ownedProbe.bindNative(OwnedProbeIdentity.running(bundle: ownedProbe.options.bundle))
      }
    }
    try Task.checkCancellation()
    try await model.putEveryday(on: bundle)
    try await model.setEnabled(true)
    try Task.checkCancellation()
    snapshot = try await model.snapshot()
    playback.apply(snapshot!, original: false)
    refreshMenu()
    if let probeSource {
      for _ in 0..<150 {
        if playback.telemetry.contains(where: { $0.state == "running" }) { break }
        if playback.problem != nil { break }
        try await Task.sleep(for: .milliseconds(20))
      }
      if playback.telemetry.contains(where: { $0.state == "running" }) { try probeSource.arm() }
    }
    // Wrapper arms only after PROBE_RUNNING. Leave a bounded startup interval,
    // then a full ten-second finite source; wrapper's stop is authoritative.
    if argument("--probe-source-url") != nil {
      try await Task.sleep(for: .seconds(30))
    } else {
      try await Task.sleep(for: .seconds(10))
    }
    probeMetrics = playback.telemetry
    requestProbeStop("completed")
  }

}

@main
struct TapNFilterApp {
  @MainActor static func main() {
    setbuf(stdout, nil)
    signal(SIGPIPE, SIG_IGN)
    let perf: PerfConfiguration?
    do {
      perf = try PerfConfiguration.parse(CommandLine.arguments,
        required: Bundle.main.object(forInfoDictionaryKey: "TNFPerfOnly") as? Bool == true)
      try perf?.claim()
    } catch {
      print(PerfConfiguration.refusalRecord(error))
      exit(64)
    }
    if let perf {
      let app = NSApplication.shared
      _ = app.setActivationPolicy(.accessory)
      let delegate = PerfAppDelegate(configuration: perf)
      app.delegate = delegate
      app.run()
      withExtendedLifetime(delegate) {}
      return
    }
    let ownedProbe: OwnedProbeOptions?
    let requestedProbe: RequestedSafariOptions?
    do {
      requestedProbe = try RequestedSafariOptions.parse(
        CommandLine.arguments, bundleAvailable: ProbeBundleCapture.bundleAvailable)
      ownedProbe = try OwnedProbeOptions.parse(
        CommandLine.arguments, bundleAvailable: ProbeBundleCapture.bundleAvailable)
    } catch {
      if let failure = error as? ProbeTargetFailure {
        print(failure.record())
      } else {
        print("PROBE_OWNED options-refused type=\(String(describing: error))")
      }
      exit(64)
    }
    let app = NSApplication.shared
    let presentation = LaunchPresentation.select(arguments: CommandLine.arguments)
    let requested: NSApplication.ActivationPolicy = presentation == .menuOnly ? .accessory : .regular
    let policySet = app.setActivationPolicy(requested)
    let effective = app.activationPolicy()
    if presentation == .menuOnly {
      print("TNF_MENU startup setter=\(policySet ? 1 : 0) requested=\(requested.rawValue) effective=\(effective.rawValue) active=\(app.isActive ? 1 : 0)")
    }
    guard presentation.accepts(setterSucceeded: policySet, effectivePolicyValue: effective.rawValue) else {
      print("TNF_MENU startup-refused reason=activation-policy-mismatch")
      exit(78)
    }
    let delegate = TNFDelegate(ownedProbe: ownedProbe, requestedProbe: requestedProbe)
    app.delegate = delegate
    app.run()
    withExtendedLifetime(delegate) {}
  }
}
