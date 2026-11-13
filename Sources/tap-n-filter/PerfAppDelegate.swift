import AppKit
import EverydayMenu
import Foundation
import SessionStore
import SoundModel

@MainActor
final class PerfAppDelegate: NSObject, NSApplicationDelegate {
    private let configuration: PerfConfiguration
    private let persistence: PerfPersistence
    private var owner: LibraryAppSession?
    private var menu: EverydayMenu?
    private var poll: Timer?
    private var work: Timer?
    private var menuPreparation: Task<Void, Never>?
    private var readyUptime = ProcessInfo.processInfo.systemUptime
    private var activeAt: Date?
    private var activeUptime: Double?
    private var releasedAt: Date?
    private var releasedUptime: Double?
    private var sentAt: [Double] = []
    private var applied = 0
    private var coalesced = 0
    private var failedRequests = 0
    private var ownerMoveSeconds: [Double] = []
    private var liveEvaluationSeconds: [Double] = []
    private var liveFinalValueAppliedUptime: Double?
    private var executionOutcomes: [String: Int] = [:]
    private var finalValueAppliedUptime: Double?
    private var maximumInFlight = 0
    private var maximumPending = 0
    private var outcomes: [String: Int] = [:]
    private var requested: Double?
    private var observed: Double?
    private var reopened: Double?
    private var menuOpened = false
    private var stopping = false
    private var settled = false
    private var settledUptime: Double?
    private var fullReadsAtStart: UInt64 = 0
    private var fullReadsAtRelease: UInt64 = 0
    private var terminating = false
    private var drainedMutations = false
    private var saveReadbackChecked = false
    private var finalDrainSaved = false
    private var failures: [String] = []
    private var beforeCommits: [PerfPersistence.Commit] = []
    private var afterCommits: [PerfPersistence.Commit] = []
    private let schedule: PerfSchedule
    private let target = "com.apple.Safari"
    private var sent: Int { sentAt.count }

    init(configuration: PerfConfiguration) {
        self.configuration = configuration
        persistence = PerfPersistence(configuration.library)
        schedule = PerfSchedule(scenario: configuration.scenario)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do {
                let app = LibraryAppSession(changed: { [weak self] in self?.refresh() },
                    contextChanged: { [weak self] in self?.menu?.updatePositionContext($0) }, positionsChanged: { [weak self] delta, context in self?.menu?.applyPositions(delta, context: context) ?? true })
                owner = app
                app.perfMutationCompleted = { [weak self] result in
                    self?.applied += 1
                    self?.outcomes[String(describing: result), default: 0] += 1
                }
                app.perfMutationFailed = { [weak self] in self?.failedRequests += 1 }
                app.coordinator.perfSliderCoalesced = { [weak self] in self?.coalesced += 1 }
                app.coordinator.perfSliderQueueChanged = { [weak self] inFlight, pending in
                    guard let self else { return }
                    maximumInFlight = max(maximumInFlight, inFlight)
                    maximumPending = max(maximumPending, pending)
                }
                app.coordinator.perfParameterEvaluated = { [weak self] elapsed, position in
                    guard let self else { return }
                    liveEvaluationSeconds.append(elapsed)
                    if position == .scalar(schedule.value(schedule.expected - 1)) {
                        liveFinalValueAppliedUptime = ProcessInfo.processInfo.systemUptime
                    }
                }
                app.coordinator.perfMoveExecuted = { [weak self] measurement, position in
                    guard let self else { return }
                    ownerMoveSeconds.append(measurement.finishedUptime - measurement.startedUptime)
                    executionOutcomes[String(describing: measurement.outcome), default: 0] += 1
                    if configuration.scenario == .drag, position == .scalar(schedule.value(schedule.expected - 1)),
                       measurement.outcome != .superseded {
                        finalValueAppliedUptime = measurement.finishedUptime
                    }
                }
                await app.start(persistence: persistence, limits: try LibraryAppSession.normalLimits())
                guard let snapshot = app.presentation, !snapshot.isEnabled, app.isReady else { throw PerfLaunchError.existing }
                let packaged = Bundle.main.resourceURL.flatMap { Bundle(url: $0.appendingPathComponent("tap-n-filter_tap-n-filter.bundle")) }
                guard let glyphURL = packaged?.url(forResource: "neck1", withExtension: "pdf", subdirectory: "Resources"),
                      let glyph = NSImage(contentsOf: glyphURL) else { throw CocoaError(.fileReadNoSuchFile) }
                glyph.isTemplate = true
                menu = EverydayMenu(presentation: snapshot, glyph: glyph,
                    visibilityChanged: { [weak self] in self?.visibility($0) }) { [weak self] in self?.send($0) }
                menu?.updateVisualization(.off)
                refresh()
                beforeCommits = await persistence.history()
                readyUptime = ProcessInfo.processInfo.systemUptime
                emit("ready", extra: ["expectedEvents": schedule.expected, "seconds": PerfSchedule.seconds,
                    "cadenceHz": configuration.scenario == .drag ? 60 : 1,
                    "control": configuration.scenario == .switch ? "Place" : "Softer"])
                installPoll()
            } catch {
                failures.append(String(describing: error))
                emit("startup-failed")
                finish()
            }
        }
    }

    private func refresh() {
        guard let owner, let snapshot = owner.presentation else { return }
        guard !snapshot.isEnabled else { stop("master-on-refused"); return }
        if let menu { owner.perfRefresh(menu, apps: [SourceAppInfo(bundleIdentifier: target, name: "Safari", icon: nil)]) }
    }

    private func send(_ action: EverydayMenuAction) {
        if case .quit = action { stop("quit-before-completion"); return }
        guard PerfActionPolicy.permits(action) else {
            owner?.send(.setEnabled(false))
            stop("power-or-compare-on-refused")
            return
        }
        if case .refreshSources = action { menuPreparation = owner?.menuOpened(); return }
        owner?.send(action)
    }

    private func installPoll() {
        poll?.invalidate()
        let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollControl() }
        }
        poll = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    private func pollControl() {
        let elapsed = ProcessInfo.processInfo.systemUptime - readyUptime
        if activeAt == nil && !stopping {
            if FileManager.default.fileExists(atPath: configuration.directory.appendingPathComponent("go").path) {
                if configuration.scenario == .idle { startWork() }
                else if !menuOpened {
                    menuOpened = true
                    guard let button = menu?.statusButton else { stop("status-button-missing"); return }
                    button.performClick(nil)
                }
            } else if elapsed > 60 { stop("collector-handshake-timeout") }
        }
        if settled && FileManager.default.fileExists(atPath: configuration.directory.appendingPathComponent("collector-done").path) { finish() }
        if elapsed > 120 && !terminating { stop("bounded-run-timeout"); if settled { finish() } }
    }

    private func visibility(_ visible: Bool) {
        if visible, activeAt == nil, !stopping {
            Task { @MainActor [weak self] in
                guard let self else { return }
                await menuPreparation?.value
                guard activeAt == nil, !stopping else { return }
                startWork()
            }
        }
        else if !visible, activeAt != nil, !stopping { stop("menu-closed-during-workload") }
    }

    private func startWork() {
        guard activeAt == nil, !stopping else { return }
        poll?.invalidate(); poll = nil
        fullReadsAtStart = owner?.coordinator.fullReadAttempts ?? 0
        activeAt = Date()
        activeUptime = ProcessInfo.processInfo.systemUptime
        if configuration.scenario == .drag { menu?.perfBeginDrag() }
        emit("active", extra: ["expectedEvents": schedule.expected, "seconds": PerfSchedule.seconds,
            "menuOpen": configuration.scenario != .idle])
        let timedEvents = configuration.scenario == .drag || configuration.scenario == .switch
        let interval = timedEvents ? schedule.interval : PerfSchedule.seconds
        let timer = Timer(timeInterval: interval, repeats: timedEvents) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        work = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
        tick()
    }

    private func tick() {
        guard let activeUptime, !stopping else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - activeUptime
        let due = schedule.due(at: elapsed)
        while sent < due {
            let index = sent
            if configuration.scenario == .drag {
                let value = schedule.value(index)
                guard menu?.perfMove(target: target, title: "Softer", value: value) == true else { stop("slider-missing"); return }
                requested = value
            } else if configuration.scenario == .switch {
                guard let value = menu?.perfSelect(target: target, title: "Place", index: (index + 1) % 4) else {
                    stop("choice-missing"); return
                }
                requested = value
            }
            sentAt.append(ProcessInfo.processInfo.systemUptime - activeUptime)
        }
        if elapsed >= PerfSchedule.seconds { stop(nil) }
    }

    private func stop(_ failure: String?) {
        guard !stopping else { return }
        stopping = true
        if let failure { failures.append(failure) }
        work?.invalidate(); work = nil
        fullReadsAtRelease = owner?.coordinator.fullReadAttempts ?? fullReadsAtStart
        releasedAt = Date()
        releasedUptime = ProcessInfo.processInfo.systemUptime
        emit("release", extra: ["sent": sent, "appliedAtRelease": applied])
        if configuration.scenario == .drag { menu?.perfEndDrag() }
        menu?.menu.cancelTracking()
        Task { @MainActor in
            guard let owner else { settled = true; finish(); return }
            do {
                let save = owner.gestureSave ?? owner.flushSave()
                guard let save else { throw PerfLaunchError.existing }
                _ = await save.value
                await owner.coordinator.waitForIssuedSaves()
                guard let snapshot = owner.presentation, !snapshot.isEnabled else { throw PerfLaunchError.existing }
                drainedMutations = true
                let title = configuration.scenario == .switch ? "Place" : "Softer"
                if let use = snapshot.uses.first(where: { $0.target == target }),
                   let control = use.controls.first(where: { $0.title == title }), case .scalar(let value) = use.positions[control.id] {
                    observed = value
                }
                afterCommits = await persistence.history()
                if sent != schedule.expected || (configuration.scenario == .drag ? liveEvaluationSeconds.count : ownerMoveSeconds.count) + coalesced + failedRequests != schedule.expected {
                    failures.append("request-accounting-mismatch")
                }
                if schedule.expected > 0 && ownerMoveSeconds.isEmpty { failures.append("zero-document-commands") }
                if failedRequests != 0 || executionOutcomes.keys.contains(where: { $0 != "changed" && $0 != "noChange" }) {
                    failures.append("owner-request-refused-or-failed")
                }
                if outcomes.keys.contains(where: { $0 != "changed" && $0 != "noChange" }) { failures.append("mutation-refused") }
                if requested != nil && observed != requested { failures.append("final-value-mismatch") }
                if owner.problem != nil { failures.append("owner-problem") }
                settledUptime = ProcessInfo.processInfo.systemUptime
                settled = true
                emit("settled", extra: summary())
            } catch {
                failures.append(String(describing: error)); settledUptime = ProcessInfo.processInfo.systemUptime; settled = true; emit("settled", extra: summary())
            }
            installPoll()
            if failure != nil { finish() }
        }
    }

    private func summary() -> [String: Any] {
        let start = activeAt?.timeIntervalSince1970 ?? 0
        let release = releasedAt?.timeIntervalSince1970 ?? 0
        let sortedCosts = ownerMoveSeconds.sorted()
        let middle = sortedCosts.count / 2
        let median = sortedCosts.isEmpty ? nil : (sortedCosts.count % 2 == 0
            ? (sortedCosts[middle - 1] + sortedCosts[middle]) / 2 : sortedCosts[middle])
        let p95 = sortedCosts.isEmpty ? nil : sortedCosts[max(0, Int(ceil(Double(sortedCosts.count) * 0.95)) - 1)]
        let finalLatency = finalValueAppliedUptime.flatMap { finished in releasedUptime.map { finished - $0 } }
        return ["fullReadsDuringWorkload": fullReadsAtRelease - fullReadsAtStart,
            "fullReadsAfterRelease": (owner?.coordinator.fullReadAttempts ?? fullReadsAtRelease) - fullReadsAtRelease,
            "accountingVersion": 3, "executed": ownerMoveSeconds.count,
            "liveEvaluations": liveEvaluationSeconds.count, "liveDeliveries": liveEvaluationSeconds.count,
            "liveEvaluationSeconds": liveEvaluationSeconds,
            "liveFinalValueAppliedUptime": liveFinalValueAppliedUptime as Any? ?? NSNull(),
            "documentCommands": ownerMoveSeconds.count, "documentCommandSeconds": ownerMoveSeconds,
            "documentCommandOutcomes": executionOutcomes, "coalesced": coalesced,
            "failedRequests": failedRequests, "accountedRequests": (configuration.scenario == .drag ? liveEvaluationSeconds.count : ownerMoveSeconds.count) + coalesced + failedRequests,
            "executionOutcomes": executionOutcomes, "ownerMoveSeconds": ownerMoveSeconds,
            "ownerMoveMedianSeconds": median as Any? ?? NSNull(), "ownerMoveP95Seconds": p95 as Any? ?? NSNull(),
            "ownerCostBasis": "Actual final/ordered SoundDocument commands, not live evaluations; excludes actor queue. Live evaluation timing separately includes precomputed complete parts, admission and synchronous UI/delivery.",
            "maximumInFlightPerSegment": maximumInFlight, "maximumPendingPerSegment": maximumPending,
            "releaseToSettledSeconds": settledUptime.flatMap { settled in releasedUptime.map { settled - $0 } } as Any? ?? NSNull(),
            "finalValueAppliedUptime": finalValueAppliedUptime as Any? ?? NSNull(),
            "finalValueRelativeToReleaseSeconds": finalLatency as Any? ?? NSNull(),
            "committedAfterRelease": afterCommits.filter { $0.started >= release && $0.outcome == "committed" }.count,
            "identicalAfterRelease": afterCommits.filter { $0.started >= release && $0.outcome == "identical" }.count,
            "expectedEvents": schedule.expected, "sent": sent, "applied": applied,
            "mutationOutcomes": outcomes, "requested": requested as Any? ?? NSNull(), "observed": observed as Any? ?? NSNull(),
            "reopened": reopened as Any? ?? NSNull(),
            "sentElapsedSeconds": sentAt, "beforeCommits": beforeCommits.map(commitValue),
            "commitsDuringWorkload": afterCommits.filter { $0.started >= start && $0.started < release }.map(commitValue),
            "commitsAfterRelease": afterCommits.filter { $0.started >= release }.map(commitValue),
            "allCommits": afterCommits.map(commitValue), "drainedMutations": drainedMutations,
            "finalDrainSaved": finalDrainSaved, "saveReadbackChecked": saveReadbackChecked,
            "soundOff": owner?.presentation?.isEnabled == false, "failures": failures,
            "workloadStartedUnix": start, "workloadReleasedUnix": release,
            "workloadElapsedSeconds": (releasedUptime ?? 0) - (activeUptime ?? 0),
            "menuOpened": menuOpened, "catchupEvents": sentAt.enumerated().filter { $0.element > Double($0.offset) * schedule.interval + schedule.interval }.count]
    }

    private func commitValue(_ value: PerfPersistence.Commit) -> [String: Any] {
        ["started": value.started, "finished": value.finished, "outcome": value.outcome]
    }

    private func finish() {
        guard !terminating else { return }
        terminating = true
        poll?.invalidate(); work?.invalidate()
        menu?.menu.cancelTracking()
        Task { @MainActor in
            if let owner {
                owner.beginDrain()
                let result = await owner.finishDrain(.save)
                if case .saved = result { finalDrainSaved = true } else { failures.append("final-drain-\(result)") }
                afterCommits = await persistence.history()
                owner.close()
                if finalDrainSaved { do {
                    let check = try await SoundLibrarySession(persistence: LibrarySessionFile(url: configuration.library, maximumBytes: 4_000_000),
                                                              limits: LibraryAppSession.normalLimits())
                    let snapshot = try await check.snapshot()
                    saveReadbackChecked = true
                    if snapshot.isEnabled { failures.append("saved-master-on") }
                    let title = configuration.scenario == .switch ? "Place" : "Softer"
                    if let use = snapshot.uses.first(where: { $0.target == target }),
                       let control = use.controls.first(where: { $0.title == title }), case .scalar(let value) = use.positions[control.id] {
                        reopened = value
                    }
                    if requested != nil && reopened != requested { failures.append("persistent-final-value-mismatch") }
                } catch { failures.append("reopen-\(error)") } }
            } else { failures.append("final-owner-unavailable") }
            if !saveReadbackChecked { failures.append("save-readback-not-checked") }
            emit("finished", extra: summary())
            NSApplication.shared.terminate(nil)
        }
    }

    private func emit(_ phase: String, extra: [String: Any] = [:]) {
        var value = extra
        value["phase"] = phase
        value["unixSeconds"] = Date().timeIntervalSince1970
        value["uptimeSeconds"] = ProcessInfo.processInfo.systemUptime
        value["scenario"] = configuration.scenario.rawValue
        value["soundOff"] = owner?.presentation?.isEnabled != true
        value["audioObjectsConstructed"] = false
        value["runID"] = configuration.runID.uuidString.lowercased()
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
            try? data.write(to: configuration.directory.appendingPathComponent("phase.json"), options: .atomic)
        }
    }
}
