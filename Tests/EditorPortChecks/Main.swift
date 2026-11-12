import Foundation
import SoundModel
import SessionStore

@main struct EditorPortChecks {
    @MainActor static func main() async {
        do {
            let directory = URL(fileURLWithPath: CommandLine.arguments[1])
            switch CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "commands" {
            case "ack": try await ackCases(directory)
            case "ack-publication": try await ackPublicationCases(directory)
            case "ack-held": try await ackHeldCases(directory)
            case "listening-durability": try await listeningDurabilityCases(directory)
            case "source-corrections": try await sourceCorrectionCases(directory)
            case "principles": try await principlesCases(directory)
            case "durability-owner": try await durabilityOwnerCases(directory)
            case "slow-gesture-read": try await slowGestureReadCase(directory)
            case "durability": try await durabilityProjectionCases(directory)
            case "terminal": try await terminalReceiptCases(directory)
            case "axes": try axisCases()
            case "commands": try await portCommands(directory)
            case "lifecycle": try await portLifecycle(directory)
            case "late": try await portLateCases(directory)
            case "late-acknowledgement": try await lateAcknowledgementCases(directory)
            case "late-product-caller":
                try await lateProductCallerCases(directory.appendingPathComponent("make-own"))
                try await lateDefinitionCallerCase(directory.appendingPathComponent("new-definition"))
            case "gestures": try await portGestureCases(directory)
            case "lifetime": try await portLifetimeCases(directory)
            case "autosave-timing": try await autosaveTimingCases(directory)
            case "autosave-gesture": try await autosaveGesture(directory)
            case "autosave-issued": try await autosaveIssued(directory)
            case "autosave-cancel": try await autosaveIgnoringCancellation(directory)
            case "autosave-new": try await autosaveNewMutationCases(directory)
            case "timer": try await portLifetimeTimer(directory)
            case "done-boundary": try await portDoneBoundary(directory)
            case "owner-history": try await ownerHistoryCases(directory)
            case "owner-projection": try await ownerProjectionCases(directory)
            case "owner-adapter": try await ownerAdapterCases(directory)
            case "owner-ports": try await ownerPortCases(directory)
            case "owner-publication": try await ownerPublicationCases(directory)
            default: throw Failure(message: "unknown group")
            }
            print("PASS actual editor view-command router complete")
        } catch { print("FAIL \(error)"); exit(1) }
    }
}

@MainActor func setup(_ root: URL) async throws -> (Fixture, LibraryAppSession, TNFEditorCommands, LibraryBinding, LibraryBinding) {
    let fixture = try await Fixture(root)
    _ = try await fixture.publish()
    let safari = try await fixture.attach("com.apple.Safari"), iina = try await fixture.attach("com.colliderli.iina")
    var router: TNFEditorCommands?
    let app = LibraryAppSession(changed: { router?.receiveOwnerChange() }, checkpointDelay: { try await Task.sleep(for: .seconds(30)) })
    await app.start(persistence: fixture.port, limits: fixture.limits)
    let commands = TNFEditorCommands(app: app); router = commands
    try await commands.select(.use(safari)); try commands.startEditing()
    return (fixture, app, commands, safari, iina)
}

@MainActor func portCommands(_ root: URL) async throws {
    let (fixture, app, commands, safari, iina) = try await setup(root)
    let slider = id(4300)
    try await commands.mapping(.create(.slider(id: slider, title: "Background", initial: 0, waypoints: [0, 0.5, 1])))
    try await commands.command(.addPart(type: "gain", at: 0))
    try await commands.command(.addPart(type: "gain", at: 1))
    let first = commands.edit!.parts[0].id, second = commands.edit!.parts[1].id
    try await commands.quickBypass(first, bypassed: true)
    try check(commands.edit!.parts[0].bypassed, "P real quick OFF targets selected part")
    try await commands.history(redo: false)
    try await commands.command(.reorderParts([second, first]))
    try check(commands.edit!.parts.map(\.id) == [second, first], "P actual part reorder")
    try await commands.history(redo: false)
    try await commands.command(.removePart(second))
    try check(!commands.edit!.parts.contains { $0.id == second }, "P actual part removal")
    try await commands.history(redo: false)
    let source = commands.projection!.mappings.descriptors.first { $0.address.control == slider }!
    try await commands.connect(source: source, target: .setting(part: first, parameter: "gainDb"))
    try await commands.connect(source: source, target: .setting(part: second, parameter: "gainDb"))
    var bindings = commands.projection!.mappings.bindings
    let firstBinding = bindings.first { $0.target == .setting(part: first, parameter: "gainDb") }!
    try await commands.mapping(.lane(binding: firstBinding.id, option: nil, lane: LibraryMappingLane(points: [LibraryLanePoint(0, 0.2), LibraryLanePoint(0.5, 0.8), LibraryLanePoint(1, 0.4)], stretches: [.curve, .step])))
    let original = commands.projection!
    let binding = original.mappings.bindings.first { $0.id == firstBinding.id }!
    let identity = try commands.laneIdentity(binding, option: nil)
    let release = try TNFEditorPointRelease(lane: binding.lane!, sourceWaypoints: binding.sourceWaypoints, from: 0.5, to: 0.37, value: 0.7)
    try check(release.insertsWaypoint && commands.projection!.snapshot == original.snapshot, "P horizontal pointer preview has no owner mutation")
    try await commands.releasePoint(identity, lane: binding.lane!, waypoints: binding.sourceWaypoints, from: 0.5, to: 0.37, value: 0.7)
    let changed = commands.projection!
    try check(changed.mappings.bindings.first { $0.id == binding.id }!.lane!.points.map(\.position) == [0, 0.37, 1], "P real router release inserts waypoint and replaces lane")
    let otherBefore = original.mappings.bindings.first { $0.id != binding.id }!, otherAfter = changed.mappings.bindings.first { $0.id == otherBefore.id }!
    for x in [0.0, 0.1, 0.37, 0.5, 0.8, 1.0] { try check(try otherBefore.lane!.value(at: x) == otherAfter.lane!.value(at: x), "P other lane sounds identical at \(x)") }
    try await commands.history(redo: false)
    try check(commands.projection!.mappings.bindings == original.mappings.bindings && commands.projection!.mappings.descriptors == original.mappings.descriptors && commands.edit!.parts == original.snapshot.parts && commands.edit!.positions == original.snapshot.positions, "P ONE reporting Undo restores complete pre-drag sound/projection")
    try await commands.history(redo: true)
    let savedLanes = commands.projection!.mappings.bindings
    let checkpoint = await app.coordinator.submitCheckpoint().value; try commands.requireAccepted(checkpoint)
    let fresh = try await SoundLibrarySession(persistence: LibrarySessionFile(url: fixture.file, maximumBytes: 8_000_000), limits: fixture.limits)
    let freshEdit = try await fresh.beginEdit(.use(safari), admission: { _ in })
    try check(try await fresh.mappings(freshEdit.handle).bindings == savedLanes, "P actual file/fresh facade retains release lanes")
    for shape in [LibraryStretch.curve, .straight, .ease, .step] {
        try await commands.mapping(.stretch(binding: binding.id, option: nil, index: 0, shape: shape, jump: 0.37))
        let current = commands.projection!.mappings.bindings.first { $0.id == binding.id }!
        try check(try current.lane!.stretches()[0].kind == shape, "P actual router shape \(shape)")
    }
    try await commands.mapping(.differentForOptions(source: slider, selector: choice))
    try check(commands.projection!.mappings.bindings.filter { $0.source.control == slider }.allSatisfy { $0.cases.count == 3 }, "P E3 actual per-option lanes")
    let copied = commands.projection!.mappings.bindings.first { $0.id == binding.id }!.cases[c]
    try await commands.previewOption(address, mutation: .add(id: d, title: "New Option", at: 3))
    try await commands.applyOption()
    try check(commands.projection!.mappings.bindings.first { $0.id == binding.id }!.cases[d] == copied, "P plus adds actual OptionID and copies last option response")
    for report in commands.reports { commands.acknowledgeReport(report.request.command) }
    try await commands.history(redo: false)
    for report in commands.reports { commands.acknowledgeReport(report.request.command) }
    try await commands.renameOption(commands.adapter.token!, path: [], control: choice, option: b, title: "Ajar")
    try check(commands.options(address).first { $0.id == b }?.title == "Ajar", "P option rename preserves OptionID through real empty-table command")
    try await commands.move(address, to: 0.5)
    try await commands.previewOption(address, mutation: .remove(id: b, replacement: a))
    let previewReport = commands.optionPlan!.preview.report
    try await commands.applyOption()
    try check(commands.reports.last.map { if case .choice(let report) = $0.report { return report.operation == previewReport.operation && report.changes == previewReport.changes && report.liveGeneration > previewReport.liveGeneration }; return false } == true, "P semantic Apply forwards actual preview/result report")
    for receipt in commands.reports { commands.acknowledgeReport(receipt.request.command) }
    try await commands.history(redo: false)
    try check(!commands.reports.isEmpty, "P reporting Undo is real option report")
    for receipt in commands.reports { commands.acknowledgeReport(receipt.request.command) }
    try check(commands.adapter.reports.isEmpty, "P reports explicitly consumed once")
    try await commands.previewUpdate(places: [LibraryUpdatePlace(use: safari.use), LibraryUpdatePlace(use: iina.use)])
    let beforeCancel = try Data(contentsOf: fixture.file)
    try await commands.cancelPreview()
    try check(try Data(contentsOf: fixture.file) == beforeCancel, "P A25 Preview Cancel keeps exact file")
    try await commands.previewUpdate(places: [LibraryUpdatePlace(use: safari.use), LibraryUpdatePlace(use: iina.use)])
    try await commands.confirmUpdate()
    try check(commands.reports.contains { if case .update = $0.report { return true }; return false }, "P A25 durable acceptance delivers actual report")
    for receipt in commands.reports { commands.acknowledgeReport(receipt.request.command) }
    let token = commands.adapter.token!
    try await commands.renameControl(token, path: [], control: slider, title: "Background Level")
    try await commands.rename("Safari Room")
    try check(commands.use?.name == "Safari Room" && commands.use?.hasOwnName == true, "P exact use rename")
    try await commands.useLibraryName()
    await app.coordinator.refresh()
    try check(commands.use?.hasOwnName == false, "P Use Library Name clears actual flag")
    let oldIdentity = try commands.laneIdentity(commands.projection!.mappings.bindings.first { $0.id == binding.id }!, option: a)
    try await commands.select(.use(iina)); try commands.startEditing()
    do { try await commands.releasePoint(oldIdentity, lane: binding.lane!, waypoints: binding.sourceWaypoints, from: 0.5, to: 0.2, value: 0.7); throw Failure(message: "stale point accepted") }
    catch TNFEditorError.stale { try check(true, "P old selection point release refused") }
    _ = safari
    bindings = commands.projection!.mappings.bindings
    try check(!bindings.isEmpty, "P real second app projection selected")
    app.beginDrain(); _ = await app.finishDrain(.save); app.close()
}

@MainActor func portLifecycle(_ root: URL) async throws {
    let (fixture, app, commands, safari, _) = try await setup(root)
    try await commands.renameControl(commands.adapter.token!, path: [], control: choice, title: "Saved Door")
    try commands.requireAccepted(await app.coordinator.submitCheckpoint().value)
    try await commands.renameControl(commands.adapter.token!, path: [], control: choice, title: "Temporary Door")
    try await commands.discard()
    try check(commands.controls.first { $0.id == choice }?.title == "Saved Door", "L Discard returns to real saved checkpoint")
    try await commands.close()
    try await commands.select(.use(safari))
    try check(commands.controls.first { $0.id == choice }?.title == "Saved Door", "L close/reopen keeps saved authored work")
    app.beginDrain(); _ = await app.finishDrain(.save)
    try check(app.cancelDrain(), "L cancelled Quit resumes shared owner")
    try commands.startEditing()
    try await commands.renameControl(commands.adapter.token!, path: [], control: choice, title: "After Cancel")
    app.beginDrain(); _ = await app.finishDrain(.save); app.close()
    let fresh = try await SoundLibrarySession(persistence: LibrarySessionFile(url: fixture.file, maximumBytes: 8_000_000), limits: fixture.limits)
    let edit = try await fresh.beginEdit(.use(safari), admission: { _ in })
    try check(edit.controls.first { $0.id == choice }?.title == "After Cancel", "L actual fresh facade after canceled Quit edits and final drain")
}

@MainActor func portGestureCases(_ root: URL) async throws {
    let (_, app, commands, _, _) = try await setup(root)
    let control = id(4390), otherControl = id(4391)
    try await commands.mapping(.create(.slider(id: control, title: "Background", initial: 0.5, waypoints: [0,0.5,1])))
    try await commands.mapping(.create(.slider(id: otherControl, title: "Other", initial: 0.5, waypoints: [0,0.5,1])))
    try await commands.command(.addPart(type: "gain", at: 0))
    let part = commands.edit!.parts[0].id
    for id in [control, otherControl] {
        let descriptor = commands.projection!.mappings.descriptors.first { $0.address.control == id }!
        try await commands.connect(source: descriptor, target: .setting(part: part, parameter: "gainDb"))
    }
    let primary = commands.projection!.mappings.bindings.first { $0.source.control == control }!
    try await commands.mapping(.lane(binding: primary.id, option: nil, lane: LibraryMappingLane(points: [LibraryLanePoint(0,0.4),LibraryLanePoint(0.5,0.6),LibraryLanePoint(1,0.8)], stretches: [.curve,.step])))
    try await commands.mapping(.stretch(binding: primary.id, option: nil, index: 1, shape: .step, jump: 0.37))
    let setting = commands.edit!.parts[0].settings.first { $0.parameter == "gainDb" }!
    try await commands.command(.setPhysical(part: part, parameter: setting.parameter, value: setting.specification.physical(0.7)))
    let beforeSet = commands.projection!, current = beforeSet.mappings.bindings.first { $0.id == primary.id }!
    let otherBefore = beforeSet.mappings.bindings.first { $0.source.control == otherControl }!
    try await commands.setByEar(current, option: nil, at: 0.5, value: 0.7)
    let afterSet = commands.projection!, afterSetting = commands.edit!.parts[0].settings.first { $0.parameter == "gainDb" }!
    try check(abs(try afterSetting.specification.normalized(afterSetting.physicalValue) - 0.7) < 1e-10 && abs(afterSetting.adjustment) < 1e-10, "G Set Here folds authored nudge, not the other driver's contribution")
    try check(afterSet.mappings.bindings.first { $0.id == otherBefore.id } == otherBefore, "G Set Here leaves other driver exact")
    try await commands.history(redo: false)
    try check(commands.edit!.parts == beforeSet.snapshot.parts && commands.projection!.mappings.bindings == beforeSet.mappings.bindings, "G one Undo restores the complete Set Here gesture")
    let address = LibraryControlAddress(path: [], control: control), originalPosition = commands.edit!.positions[address]
    try commands.beginPositionGesture(address)
    let a = try commands.admitMove(address, to: 0.2), b = try commands.admitMove(address, to: 0.4), end = try commands.admitEndPositionGesture()
    try await commands.consume(a); try await commands.consume(b); try await commands.consume(end)
    try check(commands.edit!.positions[address] == .scalar(0.4), "G synchronous view admission preserves sample/end order")
    try await commands.history(redo: false)
    try check(commands.edit!.positions[address] == originalPosition, "G control drag has one actual Undo")
    let original = commands.edit!.parts
    try commands.beginPhysicalGesture(part: part, parameter: "gainDb")
    let first = try commands.admitPhysical(part: part, parameter: "gainDb", value: setting.specification.physical(0.6))
    let second = try commands.admitPhysical(part: part, parameter: "gainDb", value: setting.specification.physical(0.65))
    let finish = try commands.admitEndPhysicalGesture()
    try await commands.consume(first); try await commands.consume(second); try await commands.consume(finish)
    try await commands.history(redo: false)
    try check(commands.edit!.parts == original, "G setting drag has one actual Undo")
    let beforeResponse = commands.projection!.mappings.bindings.first { $0.id == primary.id }!
    try commands.beginResponseGesture(beforeResponse)
    let jumpA = try commands.admitResponse(beforeResponse, command: .stretch(binding: primary.id, option: nil, index: 1, shape: .step, jump: 0.2))
    let jumpB = try commands.admitResponse(beforeResponse, command: .stretch(binding: primary.id, option: nil, index: 1, shape: .step, jump: 0.8))
    let jumpEnd = try commands.admitEndResponseGesture(beforeResponse)
    try await commands.consume(jumpA); try await commands.consume(jumpB); try await commands.consume(jumpEnd)
    try await commands.history(redo: false)
    try check(commands.projection!.mappings.bindings.first { $0.id == primary.id } == beforeResponse, "G Step jump drag has one actual Undo")
    let currentRelease = commands.projection!.mappings.bindings.first { $0.id == primary.id }!
    try await commands.releasePoint(commands.laneIdentity(currentRelease, option: nil), lane: currentRelease.lane!, waypoints: currentRelease.sourceWaypoints, from: 0.5, to: 0.37, value: 0.65)
    try check(try commands.projection!.mappings.bindings.first { $0.id == primary.id }!.lane!.stretches()[1].jump == 0.37, "G horizontal release preserves moved point's nondefault Step jump")
    try await commands.history(redo: false)
    let axisBefore = beforeResponse.sourceWaypoints
    try await commands.removePoint(commands.laneIdentity(beforeResponse, option: nil), lane: beforeResponse.lane!, position: 0.5)
    let removed = commands.projection!.mappings.bindings.first { $0.id == primary.id }!
    try check(removed.lane!.points.map(\.position) == [0,1] && removed.sourceWaypoints == axisBefore, "G Remove Point omits only lane knot, not shared control waypoint")
    try await commands.history(redo: false)
    try check(commands.projection!.mappings.bindings.first { $0.id == primary.id } == beforeResponse, "G Remove Point Undo restores shapes and nondefault jump")
    do { try await commands.command(.setPhysical(part: part, parameter: "gainDb", value: .nan)); throw Failure(message: "invalid input admitted") }
    catch is Failure { throw Failure(message: "invalid input admitted") }
    catch { commands.fail(error) }
    let failure = commands.error
    try await commands.refresh()
    try check(failure != nil && commands.error == failure, "G a fresh read cannot erase actual refused-input feedback")
    commands.clearError()
    let old = commands.adapter.token
    try await commands.select(.definition(commands.definition!.id))
    do { try commands.validateCallback(old); throw Failure(message: "stale click callback accepted") }
    catch TNFEditorError.stale { print("PASS G click-time epoch refuses replacement target") }
    commands.prepareQuit(); app.beginDrain(); _ = await app.finishDrain(.save); app.close()
}

@MainActor func portDoneBoundary(_ root: URL) async throws {
    let (_, app, commands, _, _) = try await setup(root)
    try await commands.renameControl(commands.adapter.token!, path: [], control: choice, title: "Authored before Done")
    try check(commands.edit!.canUndo, "H01 actual router has authored Undo before Done")
    try await commands.done()
    try check(!commands.editing && commands.controls.first { $0.id == choice }?.title == "Authored before Done", "H01 Done checkpoints and returns actual Use projection")
    await app.coordinator.refresh(); try await commands.refresh()
    let generation = commands.edit!.generation, beforeDraft = commands.use?.hasLocalDraft
    try await commands.move(address, to: 0.5)
    await app.coordinator.refresh(); try await commands.refresh()
    print("OBSERVED Use generation before=\(generation) after=\(commands.edit!.generation), draft before=\(String(describing: beforeDraft)) after=\(String(describing: commands.use?.hasLocalDraft)), title=\(commands.controls.first { $0.id == choice }?.title ?? "missing")")
    try check(commands.edit!.generation == generation && commands.use?.hasLocalDraft == beforeDraft && commands.controls.first { $0.id == choice }?.title == "Authored before Done", "H01 actual Use move authors nothing and preserves unpublished work")
    try await commands.history(redo: false)
    try check(!commands.editing && commands.controls.first { $0.id == choice }?.title == "Door" && commands.edit!.positions[address] == .scalar(0.5), "H01 Done Use Undo restores authored title, not listening")
    try await commands.history(redo: true)
    try check(!commands.editing && commands.controls.first { $0.id == choice }?.title == "Authored before Done", "H01 Done Use Redo restores authored title")
    let hasUndo = commands.edit!.canUndo
    commands.prepareQuit(); app.beginDrain(); _ = await app.finishDrain(.save); app.close()
    try check(hasUndo, "H01 authored Undo survives Done on actual router")
}
