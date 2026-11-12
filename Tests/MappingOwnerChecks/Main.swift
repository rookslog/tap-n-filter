import Foundation
import SoundModel
import SessionStore

enum MappingCheckError: Error { case failed(String) }
func checkMapping(_ value: Bool, _ message: String) throws {
    guard value else { throw MappingCheckError.failed(message) }; print("PASS \(message)")
}
func nearMapping(_ value: Double, _ expected: Double, _ message: String) throws { try checkMapping(abs(value - expected) < 1e-10, message) }
#if !SWIFT_PACKAGE
@main
#endif
struct MappingOwnerChecks {
 static func main() async throws {
    setbuf(stdout, nil)
    try await run(URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
 }
 static func run(_ directory: URL) async throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("mapping.json")
    let limits = try LibraryLimits(maximumBytes: 8_000_000, maximumRevisions: 1024,
        expansion: LibraryExpansionLimits(maximumDepth: 24, maximumOccurrences: 256, maximumParts: 1024))
    let session = try await SoundLibrarySession(persistence: LibrarySessionFile(url: file, maximumBytes: limits.maximumBytes), limits: limits)
    let created = try await session.createEmpty(name: "Rain equivalence")
    try checkMapping(created.acceptedReference != nil, "real create commits empty custom definition")
    let def = created.candidate.definition
    _ = try await session.select(def, on: "test.rain")
    var state = try await session.snapshot()
    let use = state.uses.first { $0.target == "test.rain" }!
    let assignment = state.assignments.first { $0.target == "test.rain" }!
    let binding = LibraryBinding(assignment: assignment.id, use: use.id, target: "test.rain")
    var edit = try await session.beginEdit(.use(binding), admission: { _ in })
    func editCommand(_ command: LibraryEditCommand) async throws {
        edit = try await session.edit(edit.handle, expectedGeneration: edit.generation, command: command)
    }
    func map(_ command: LibraryMappingCommand, path: [UUID] = []) async throws { try await editCommand(.mapping(path: path, command)) }
    try await editCommand(.addPart(type: "gain", at: 0)); try await editCommand(.addPart(type: "gain", at: 1))
    let gainA = edit.parts[0].id, gainB = edit.parts[1].id
    try await map(.settingBase(part: gainA, parameter: "gainDb", normalized: 0.5))
    try await map(.settingBase(part: gainB, parameter: "gainDb", normalized: 0.5))
    let amount = UUID(), awning = UUID(), off = UUID(), on = UUID()
    try await map(.create(.slider(id: amount, title: "Amount", initial: 0.5, waypoints: [0, 0.5, 1])))
    try await map(.create(.choice(id: awning, title: "Awning", options: [LibraryOption(id: off, title: "Off", position: 0), LibraryOption(id: on, title: "On", position: 1)], initial: off)))
    let a = UUID(), b = UUID()
    try await map(.connectOptions(id: a, source: LibraryMappingSource(amount), target: .setting(part: gainA, parameter: "gainDb"), selector: awning))
    try await map(.connect(id: b, source: LibraryMappingSource(amount), target: .setting(part: gainB, parameter: "gainDb")))
    let before = try await session.mappings(edit.handle)
    try checkMapping(before.bindings.count == 2, "public owner exposes stable binding IDs and neutral connections")
    try await map(.differentForOptions(source: amount, selector: awning))
    func lane(_ x: Double, _ y: Double) throws -> LibraryMappingLane {
        try LibraryMappingLane(points: [LibraryLanePoint(0, x), LibraryLanePoint(1, y)], stretches: [.straight])
    }
    try await map(.lane(binding: a, option: off, lane: lane(0.1, 0.3)))
    try await map(.lane(binding: a, option: on, lane: lane(0.7, 0.9)))
    try await map(.lane(binding: b, option: off, lane: lane(0.9, 0.7)))
    try await map(.lane(binding: b, option: on, lane: lane(0.3, 0.1)))
    func gain(_ id: UUID) async throws -> Double {
        let parts = try await session.snapshot().assignments.first { $0.target == "test.rain" }!.parts
        return parts.first { $0.id == id }!.parameters.first { $0.key == "gainDb" }!.value
    }
    for (option, p, expectedA, expectedB) in [(0.0,0.0,0.1,0.9),(0,1,0.3,0.7),(1,0,0.7,0.3),(1,1,0.9,0.1)] {
        try await session.move(awning, on: "test.rain", to: .scalar(option))
        try await session.move(amount, on: "test.rain", to: .scalar(p))
        let values = try await session.inspectEdit(edit.handle).parts
        for (id, expected) in [(gainA,expectedA),(gainB,expectedB)] {
            let setting = values.first { $0.id == id }!.settings[0]
            try nearMapping(try setting.specification.normalized(setting.physicalValue), expected, "M01 selected transfer exact normalized gain target \(option)/\(p)/\(id)")
        }
    }
    try await session.move(amount, on: "test.rain", to: .scalar(0.5))
    try await session.move(awning, on: "test.rain", to: .scalar(0))
    let refs = try await session.mappings(edit.handle).bindings
    try checkMapping(refs.allSatisfy { $0.cases.count == 2 && $0.selector == awning && $0.reference == 0.5 }, "M01 exhaustive option-ID tables exposed by real commands")
    let offA = try await gain(gainA)
    try await session.move(awning, on: "test.rain", to: .scalar(1))
    let onA = try await gain(gainA)
    try checkMapping(onA > offA, "M01 selected lane changes supported gain target, not both cases added")
    _ = try await session.checkpointEdit(edit.handle, expectedGeneration: edit.generation)
    let bytes = try Data(contentsOf: file)
    let object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
    try checkMapping(object["schema"] as? Int == 6, "feature payload selects schema6")
    let reopened = try await SoundLibrarySession(persistence: LibrarySessionFile(url: file, maximumBytes: limits.maximumBytes), limits: limits)
    let reopenedEdit = try await reopened.beginEdit(.use(binding), admission: { _ in })
    try checkMapping(try await reopened.mappings(reopenedEdit.handle).bindings == (try await session.mappings(edit.handle).bindings), "M01 actual file/fresh facade retains IDs references cases and lanes")
    let curveBefore = try await session.mappings(edit.handle).bindings
    edit = try await session.beginEditGesture(edit.handle, expectedGeneration: edit.generation)
    try await map(.insertPoint(binding: a, option: off, position: 0.25))
    try await map(.point(binding: a, option: off, position: 0.25, value: 0.4))
    try await map(.stretch(binding: a, option: off, index: 0, shape: .step, jump: 0.25))
    edit = try await session.endEditGesture(edit.handle, expectedGeneration: edit.generation)
    edit = try await session.undoEdit(edit.handle, expectedGeneration: edit.generation)
    try checkMapping(try await session.mappings(edit.handle).bindings == curveBefore, "M07 point/stretch/waypoint gesture is one real owner Undo")
    edit = try await session.redoEdit(edit.handle, expectedGeneration: edit.generation)
    edit = try await session.undoEdit(edit.handle, expectedGeneration: edit.generation)
    let choiceSource = UUID(), hsA = UUID(), hsB = UUID(), hsC = UUID(), hBinding = UUID()
    let hOptions = [LibraryOption(id: hsA, title: "Near", position: 0), LibraryOption(id: hsB, title: "Middle", position: 0.5), LibraryOption(id: hsC, title: "Far", position: 1)]
    try await map(.create(.choice(id: choiceSource, title: "Choice source", options: hOptions, initial: hsA)))
    try await map(.connect(id: hBinding, source: LibraryMappingSource(choiceSource), target: .setting(part: gainA, parameter: "gainDb")))
    for (id, value) in [(hsA,0.2),(hsB,0.5),(hsC,0.8)] { try await map(.sourceValue(binding: hBinding, selectorOption: nil, sourceOption: id, value: value)) }
    let hDirect = try await session.mappings(edit.handle).bindings.first { $0.id == hBinding }!
    try checkMapping(hDirect.lane == nil && hDirect.sourceValues == [hsA:0.2,hsB:0.5,hsC:0.8], "H02 choice source exposes exact per-ID values, no positional curve")
    let hBefore = try await session.mappings(edit.handle)
    do { try await map(.point(binding: hBinding, option: nil, position: 0.5, value: 0.2)); throw MappingCheckError.failed("choice point admitted") } catch LibraryError.unsupportedEdit { }
    try checkMapping(try await session.mappings(edit.handle) == hBefore, "H03 choice point edit refuses atomically, no between-option curve")
    try await map(.differentForOptions(source: choiceSource, selector: awning))
    try await map(.sourceValue(binding: hBinding, selectorOption: on, sourceOption: hsA, value: 0.9))
    let hSelected = try await session.mappings(edit.handle).bindings.first { $0.id == hBinding }!
    try checkMapping(hSelected.caseSourceValues[off]?[hsA] == 0.2 && hSelected.caseSourceValues[on]?[hsA] == 0.9, "H02 source choice values are orthogonal to selecting whole transfers")
    let reordered = [LibraryOption(id: hsC, title: "Farther", position: 0),LibraryOption(id: hsB, title: "Middle", position: 0.5),LibraryOption(id: hsA, title: "Near", position: 1)]
    try await map(.choiceOptions(control: choiceSource, options: reordered, tables: [:]))
    let hAfter = try await session.mappings(edit.handle)
    try checkMapping(hAfter.bindings.first { $0.id == hBinding }!.caseSourceValues == hSelected.caseSourceValues, "H03 reordering retains exact per-ID responses")
    try checkMapping(hAfter.controls.first { $0.address.control == choiceSource }!.manual == .scalar(1), "H03 reorder retains un-driven manual selected OptionID, not old anchor")
    let hFrozen = try await session.mappings(edit.handle)
    do { try await map(.sourceValue(binding: hBinding, selectorOption: on, sourceOption: hsA, value: .nan)); throw MappingCheckError.failed("nonfinite value admitted") } catch { if error is MappingCheckError { throw error } }
    do { try await map(.choiceOptions(control: choiceSource, options: [reordered[0],reordered[2]], tables: [:])); throw MappingCheckError.failed("choice removal admitted without coverage") } catch LibraryError.unsupportedEdit { }
    try checkMapping(try await session.mappings(edit.handle) == hFrozen, "H03 nonfinite and incomplete option surgery refuse atomically")
    let samePreview = try await session.previewSameForAll(edit.handle, expectedGeneration: edit.generation, source: choiceSource)
    try await session.move(awning, on: "test.rain", to: .scalar(0))
    do { try await map(.sameForAll(samePreview)); throw MappingCheckError.failed("stale selector preview admitted") } catch LibraryError.staleEdit { }
    let same = try await session.previewSameForAll(edit.handle, expectedGeneration: edit.generation, source: choiceSource)
    try await map(.sameForAll(same))
    try checkMapping(try await session.mappings(edit.handle).bindings.first { $0.id == hBinding }!.sourceValues == hSelected.caseSourceValues[off], "H05 Same retains entire effective option transfer")
    edit = try await session.undoEdit(edit.handle, expectedGeneration: edit.generation)
    try checkMapping(try await session.mappings(edit.handle).bindings.first { $0.id == hBinding }!.selector == awning, "H05 one Undo restores selector and complete source choice table")
    edit = try await session.redoEdit(edit.handle, expectedGeneration: edit.generation)
    _ = try await session.checkpoint()
    let hFile = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
    try checkMapping(hFile["schema"] as? Int == 6, "H01 tagged source saved inside schema6")
    let amountAwning = UUID()
    try await map(.connect(id: amountAwning, source: LibraryMappingSource(amount), target: .control(site: nil, control: awning, axis: .value)))
    try await map(.differentForOptions(source: amount, selector: awning))
    let policy = try await session.mappings(edit.handle).bindings
    try checkMapping(policy.first { $0.id == amountAwning }!.selector == nil && policy.first { $0.id == a }!.selector == awning, "M05 Amount-to-Awning excluded from whole-control selector conversion")
    let secondSelector = UUID(), ssOff = UUID(), ssOn = UUID()
    try await map(.create(.choice(id: secondSelector, title: "Other selector", options: [LibraryOption(id: ssOff, title: "Off", position: 0),LibraryOption(id: ssOn, title: "On", position: 1)], initial: ssOff)))
    let policyBefore = try await session.mappings(edit.handle)
    do { try await map(.differentForOptions(source: amount, selector: secondSelector)); throw MappingCheckError.failed("second selector admitted") } catch LibraryError.unsupportedEdit { }
    try checkMapping(try await session.mappings(edit.handle) == policyBefore, "M05 public second-selector conversion refuses without mutation")
    let source = UUID(), distance = UUID(), door = UUID(), open = UUID(), ajar = UUID(), closed = UUID()
    try await map(.create(.slider(id: source, title: "Background", initial: 0.5, waypoints: [0,0.5,1])))
    try await map(.create(.slider(id: distance, title: "Distance", initial: 0.5, waypoints: [0,0.5,1])))
    try await map(.create(.choice(id: door, title: "Door", options: [LibraryOption(id: open, title: "Open", position: 0), LibraryOption(id: ajar, title: "Ajar", position: 0.5), LibraryOption(id: closed, title: "Closed", position: 1)], initial: ajar)))
    let sd = UUID(), sc = UUID()
    try await map(.connect(id: sd, source: LibraryMappingSource(source), target: .control(site: nil, control: distance, axis: .value)))
    try await map(.connect(id: sc, source: LibraryMappingSource(source), target: .control(site: nil, control: door, axis: .value)))
    try await map(.lane(binding: sd, option: nil, lane: lane(0,1))); try await map(.lane(binding: sc, option: nil, lane: lane(0,1)))
    for p in [0.0, 0.5, 1.0] {
        try await session.move(source, on: "test.rain", to: .scalar(p))
        let values = try await session.mappings(edit.handle).controls
        try checkMapping(values.first { $0.address.control == door }!.effective == .scalar(p), "M03 three-option driven choice anchor \(p)")
    }
    let frozen = try await session.mappings(edit.handle)
    do { try await map(.connect(id: UUID(), source: LibraryMappingSource(distance), target: .control(site: nil, control: source, axis: .value))); throw MappingCheckError.failed("cycle admitted") }
    catch LibraryError.mappingCycle { }
    try checkMapping(try await session.mappings(edit.handle) == frozen, "M04 control cycle refuses atomically")
    try await session.move(distance, on: "test.rain", to: .scalar(0.2))
    let driven = try await session.mappings(edit.handle).controls.first { $0.address.control == distance }!
    try checkMapping(driven.manual == .scalar(0.5) && !driven.adjustments.isEmpty, "M06 driven hand response retains manual with signed adjustment")
    if case .scalar(let value) = driven.effective { try nearMapping(value, 0.2, "M06 driven effective response") } else { throw MappingCheckError.failed("scalar") }
    try await map(.removeBinding(sd))
    let folded = try await session.mappings(edit.handle).controls.first { $0.address.control == distance }!
    try checkMapping(folded.adjustments.isEmpty && folded.manual == folded.effective, "M06 final-edge removal folds effective and clears adjustment")
    if case .scalar(let value) = folded.manual { try nearMapping(value, 0.2, "M06 folded value") }
    try await editCommand(.addPart(type: "gain", at: edit.pieces.count))
    let roomGain = edit.parts.last!.id
    try await map(.settingBase(part: roomGain, parameter: "gainDb", normalized: 0.5))
    let roomTransfer = UUID()
    try await map(.connectOptions(id: roomTransfer, source: LibraryMappingSource(distance), target: .setting(part: roomGain, parameter: "gainDb"), selector: door))
    try await map(.lane(binding: roomTransfer, option: open, lane: lane(0.1,0.9)))
    try await map(.lane(binding: roomTransfer, option: ajar, lane: lane(0.3,0.7)))
    try await map(.lane(binding: roomTransfer, option: closed, lane: lane(0.4,0.4)))
    for (option, a, b) in [(0.0,0.1,0.9),(0.5,0.3,0.7),(1.0,0.4,0.4)] {
        try await session.move(door, on: "test.rain", to: .scalar(option))
        for p in [0.0,0.5,1.0] {
            try await session.move(distance, on: "test.rain", to: .scalar(p))
            let setting = try await session.inspectEdit(edit.handle).parts.first { $0.id == roomGain }!.settings[0]
            try nearMapping(try setting.specification.normalized(setting.physicalValue), a+(b-a)*p, "M02 Room Door/Distance selected transfer \(option)/\(p)")
        }
    }
    _ = try await session.checkpoint()
    state = try await session.snapshot()
    try checkMapping(!state.isEnabled, "master OFF preserved during all data authoring")
    let sourceUpdate = try await session.previewUpdateLibrary(edit.handle, expectedGeneration: edit.generation, places: [LibraryUpdatePlace(use: use.id)])
    let beforeCancel = try await session.snapshot()
    await session.cancelUpdateLibrary(sourceUpdate)
    try checkMapping(try await session.snapshot() == beforeCancel, "M09 Cancel changes no sound, head, draft or listening state")
    let update = try await session.previewUpdateLibrary(edit.handle, expectedGeneration: edit.generation, places: [LibraryUpdatePlace(use: use.id)])
    try checkMapping(try await session.confirmUpdateLibrary(update).commit.outcome.isAccepted, "public Update Library creates immutable revision in actual store")
    edit = try await session.inspectEdit(edit.handle)
    try checkMapping(edit.handle.base == update.new, "publication migrates existing authoring handle without losing owner")
    let parentID = try await session.createLinkedBlock(name: "Radio parent", children: [update.new, update.new], on: "test.radio")
    var parentState = try await session.snapshot()
    let parentUse = parentState.uses.first { $0.target == "test.radio" }!, parentAssignment = parentState.assignments.first { $0.target == "test.radio" }!
    let parentBinding = LibraryBinding(assignment: parentAssignment.id, use: parentUse.id, target: "test.radio")
    var parentEdit = try await session.beginEdit(.use(parentBinding), admission: { _ in })
    func pm(_ command: LibraryMappingCommand) async throws {
        parentEdit = try await session.edit(parentEdit.handle, expectedGeneration: parentEdit.generation, command: .mapping(path: [], command))
    }
    let sites = parentEdit.pieces.compactMap { piece -> UUID? in if case .reference(let site, _, _) = piece { return site }; return nil }
    let macro = UUID(), childDoor = UUID(), secondDoor = UUID(), childDistance = UUID()
    try await pm(.create(.slider(id: macro, title: "How hard to hear", initial: 0.5, waypoints: [0,0.5,1])))
    try await pm(.connect(id: childDoor, source: LibraryMappingSource(macro), target: .control(site: sites[0], control: door, axis: .value)))
    try await pm(.connect(id: secondDoor, source: LibraryMappingSource(macro), target: .control(site: sites[1], control: door, axis: .value)))
    try await pm(.connect(id: childDistance, source: LibraryMappingSource(macro), target: .control(site: sites[0], control: distance, axis: .value)))
    try await pm(.lane(binding: childDistance, option: nil, lane: lane(0,1)))
    try await pm(.lane(binding: childDoor, option: nil, lane: lane(0,1)))
    for p in [0.0,0.5,1.0] {
        try await session.move(macro, on: "test.radio", to: .scalar(p))
        let facts = try await session.mappings(parentEdit.handle).controls
        try checkMapping(facts.first { $0.address == LibraryControlAddress(path: [sites[0]], control: door) }!.effective == .scalar(p), "M03 parent macro reaches child option anchor \(p)")
        if case .scalar(let value) = facts.first(where: { $0.address == LibraryControlAddress(path: [sites[0]], control: distance) })!.effective { try nearMapping(value, p, "M03 parent macro reaches child Distance \(p)") }
        try checkMapping(facts.first { $0.address == LibraryControlAddress(path: [sites[1]], control: door) }!.effective == .scalar(0.5), "M03 repeated child occurrence independent \(p)")
    }
    print("TRACE parent preview")
    let parentUpdate = try await session.previewUpdateLibrary(parentEdit.handle, expectedGeneration: parentEdit.generation, places: [LibraryUpdatePlace(use: parentUse.id)])
    print("TRACE parent confirm")
    _ = try await session.confirmUpdateLibrary(parentUpdate)
    print("TRACE parent confirmed")
    parentEdit = try await session.inspectEdit(parentEdit.handle)
    print("TRACE remove source Door")
    try await map(.removeControl(door))
    print("TRACE removed source Door")
    let replacementDoor = UUID(), rOpen = UUID(), rAjar = UUID(), rClosed = UUID()
    try await map(.create(.choice(id: replacementDoor, title: "Door", options: [LibraryOption(id: rOpen, title: "Open", position: 0),LibraryOption(id: rAjar, title: "Ajar", position: 0.5),LibraryOption(id: rClosed, title: "Closed", position: 1)], initial: rAjar)))
    let brokenPreview = try await session.previewUpdateLibrary(edit.handle, expectedGeneration: edit.generation,
        places: [LibraryUpdatePlace(use: use.id), LibraryUpdatePlace(use: parentUse.id, path: [sites[0]]), LibraryUpdatePlace(use: parentUse.id, path: [sites[1]])])
    try checkMapping(Set(brokenPreview.brokenBindings).isSuperset(of: [childDoor,secondDoor]), "M09 preview names exact affected broken binding IDs")
    _ = try await session.confirmUpdateLibrary(brokenPreview)
    edit = try await session.inspectEdit(edit.handle)
    parentEdit = try await session.inspectEdit(parentEdit.handle)
    let brokenFacts = try await session.mappings(parentEdit.handle).bindings
    try checkMapping(brokenFacts.first { $0.id == childDoor }!.broken == .targetRemoved, "M09 removed Door remains broken despite same-name replacement")
    let beforeBadRepair = try await session.mappings(parentEdit.handle)
    do { try await pm(.repair(binding: childDoor, target: .control(site: nil, control: macro, axis: .value))); throw MappingCheckError.failed("repair self-cycle admitted") } catch LibraryError.mappingCycle { }
    try checkMapping(try await session.mappings(parentEdit.handle) == beforeBadRepair, "M09 repair revalidates complete active graph and refuses self-cycle")
    try await pm(.repair(binding: childDoor, target: .control(site: sites[0], control: replacementDoor, axis: .value)))
    try checkMapping(try await session.mappings(parentEdit.handle).bindings.first { $0.id == childDoor }!.broken == nil, "M09 explicit repair validates and restores active identity")
    _ = try await session.checkpoint()
    let final = try await SoundLibrarySession(persistence: LibrarySessionFile(url: file, maximumBytes: limits.maximumBytes), limits: limits)
    let finalEdit = try await final.beginEdit(.use(parentBinding), admission: { _ in })
    let finalMappings = try await final.mappings(finalEdit.handle).bindings
    try checkMapping(finalMappings.first { $0.id == secondDoor }!.broken == .targetRemoved, "M09 unrepaired broken status survives actual file and fresh facade")
    try checkMapping(finalMappings.first { $0.id == childDoor }!.broken == nil, "M09 repaired binding survives reopen")
    parentState = try await final.snapshot()
    try checkMapping(parentState.definitions.contains { $0.id == parentID }, "confirmed parent definition retained")
    for target in ["test.preview-a","test.preview-b"] { _ = try await session.select(def, on: target) }
    let previewState = try await session.snapshot()
    func editTarget(_ target: String) throws -> LibraryEditTarget {
        let assignment = previewState.assignments.first { $0.target == target }!
        return .use(LibraryBinding(assignment: assignment.id, use: assignment.use, target: target))
    }
    let pa = try await session.beginEdit(editTarget("test.preview-a"), admission: { _ in })
    let pb = try await session.beginEdit(editTarget("test.preview-b"), admission: { _ in })
    let cross = try await session.previewSameForAll(pa.handle, expectedGeneration: pa.generation, source: amount)
    let beforeCross = try await session.mappings(pb.handle)
    do {
        _ = try await session.edit(pb.handle, expectedGeneration: pb.generation, command: .mapping(path: [], .sameForAll(cross)))
        throw MappingCheckError.failed("other-owner preview admitted")
    } catch LibraryError.staleEdit { }
    try checkMapping(try await session.mappings(pb.handle) == beforeCross, "M13 same-content other-use preview cannot authorize this owner")
    let definitions = try await session.snapshot().definitions
    let filters = definitions.first { $0.name == "Filters" }!
    let mixedID = try await session.createLinkedBlock(name: "Mixed local", children: [LibraryReference(definition: filters.id, revision: filters.revision), parentUpdate.new], on: "test.mixed")
    let mixedState = try await session.snapshot(), mixedUse = mixedState.uses.first { $0.target == "test.mixed" }!, mixedAssignment = mixedState.assignments.first { $0.target == "test.mixed" }!
    let mixedBinding = LibraryBinding(assignment: mixedAssignment.id, use: mixedUse.id, target: "test.mixed")
    var mixedEdit = try await session.beginEdit(.use(mixedBinding), admission: { _ in })
    let mixedSites = mixedEdit.pieces.compactMap { piece -> UUID? in if case .reference(let site, _, _) = piece { return site }; return nil }
    let beforeLocalPieces = mixedEdit.pieces
    let beforeLocalParts = mixedState.assignments.first { $0.target == "test.mixed" }!.parts
    mixedEdit = try await session.edit(mixedEdit.handle, expectedGeneration: mixedEdit.generation, command: .mapping(path: [], .makeLocal(path: [mixedSites[0]])))
    try checkMapping(try await session.snapshot().assignments.first { $0.target == "test.mixed" }!.parts == beforeLocalParts, "M14 localized Filters keeps exact native lowering under Everyday parent")
    mixedEdit = try await session.undoEdit(mixedEdit.handle, expectedGeneration: mixedEdit.generation)
    try checkMapping(mixedEdit.pieces == beforeLocalPieces, "M14 localization is one Undo")
    let bridgeSource = UUID()
    mixedEdit = try await session.edit(mixedEdit.handle, expectedGeneration: mixedEdit.generation, command: .mapping(path: [], .create(.slider(id: bridgeSource, title: "Deep macro", initial: 0.5, waypoints: [0,0.5,1]))))
    let deepAddress = LibraryControlAddress(path: [mixedSites[1],sites[0]], control: distance)
    let beforeBadBridge = try await session.mappings(mixedEdit.handle)
    do {
        _ = try await session.edit(mixedEdit.handle, expectedGeneration: mixedEdit.generation,
            command: .mapping(path: [], .makeLocalAndForward(source: LibraryMappingSource(bridgeSource), target: LibraryControlAddress(path: deepAddress.path, control: UUID()), axis: .value)))
        throw MappingCheckError.failed("missing deep target admitted")
    } catch LibraryError.unknownTarget { }
    try checkMapping(try await session.mappings(mixedEdit.handle) == beforeBadBridge, "M08 failed deep bridge localizes nothing and refuses atomically")
    mixedEdit = try await session.edit(mixedEdit.handle, expectedGeneration: mixedEdit.generation,
        command: .mapping(path: [], .makeLocalAndForward(source: LibraryMappingSource(bridgeSource), target: deepAddress, axis: .value)))
    let bridgeFacts = try await session.mappings(mixedEdit.handle)
    try checkMapping(bridgeFacts.bindings.filter { $0.source.control == bridgeSource }.count == 1 && mixedEdit.pendingStructural, "M08 E20 creates immediate-hop bridge under existing A24 owner")
    for p in [0.0,1.0] {
        try await session.move(bridgeSource, on: "test.mixed", to: .scalar(p))
        let facts = try await session.mappings(mixedEdit.handle).controls
        if case .scalar(let value) = facts.first(where: { $0.address == deepAddress })!.effective { try nearMapping(value, p, "M08 two-hop bridge reaches deep control \(p)") }
    }
    _ = try await session.checkpoint()
    let mixedReopen = try await SoundLibrarySession(persistence: LibrarySessionFile(url: file, maximumBytes: limits.maximumBytes), limits: limits)
    let mixedFresh = try await mixedReopen.beginEdit(.use(mixedBinding), admission: { _ in })
    try checkMapping(try await mixedReopen.mappings(mixedFresh.handle).bindings == (try await session.mappings(mixedEdit.handle).bindings), "M08 full local-child payload/bridges survive owned store and fresh facade")
    try checkMapping(mixedID == mixedUse.definition, "mixed definition exact identity retained")
    let legacyMade = try await session.createEmpty(name: "Legacy only")
    var legacyEdit = try await session.beginEdit(.definition(legacyMade.candidate.definition), admission: { _ in })
    legacyEdit = try await session.edit(legacyEdit.handle, expectedGeneration: legacyEdit.generation, command: .addPart(type: "gain", at: 0))
    let legacyControl = UUID()
    legacyEdit = try await session.edit(legacyEdit.handle, expectedGeneration: legacyEdit.generation, command: .mapping(path: [], .create(.slider(id: legacyControl, title: "Legacy slider", initial: 0.5, waypoints: [0,0.5,1]))))
    legacyEdit = try await session.edit(legacyEdit.handle, expectedGeneration: legacyEdit.generation, command: .mapping(path: [], .connectLegacy(source: LibraryMappingSource(legacyControl), part: legacyEdit.parts[0].id, parameter: "gainDb")))
    _ = try await session.checkpointEdit(legacyEdit.handle, expectedGeneration: legacyEdit.generation)
    let legacyData = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
    let workspaces = legacyData["workspaces"] as! [[String: Any]]
    let workspace = workspaces.first { ($0["definition"] as? [String: Any])?["rawValue"] as? String == legacyMade.candidate.definition.uuidString }!
    try checkMapping((workspace["payload"] as! [String: Any])["canonicalVersion"] as? Int == 3, "M10 real legacy-representable mapping edit stays canonical3")
    try await Self.wireRefusals(file, directory: directory, limits: limits)
    try await Self.heldPublication(directory, limits: limits)
    try await Self.repeatedDormant(directory, limits: limits)
    print("PASS public mapping owner/store checks; no native/audio/UI")
 }
}

actor MappingGatedPort: LibraryPersistence {
    let file: LibrarySessionFile
    var held = false
    var outcome = 0
    var entered = false
    var waiters: [CheckedContinuation<Void, Never>] = []
    var releaseWaiter: CheckedContinuation<Void, Never>?
    init(_ file: LibrarySessionFile) { self.file = file }
    func load() async throws -> Data? { try await file.load() }
    func arm(_ outcome: Int) { self.outcome = outcome; held = true; entered = false }
    func wait() async { if entered { return }; await withCheckedContinuation { waiters.append($0) } }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
    func commit(_ data: Data) async -> LibraryWriteOutcome {
        let result = outcome
        if held {
            held = false
            await withCheckedContinuation { continuation in
                releaseWaiter = continuation; entered = true
                for w in waiters { w.resume() }; waiters.removeAll()
            }
        }
        if result == 1 { outcome = 0; return .refused(.io("injected before replacement")) }
        let write = await file.commit(data)
        if result == 2 { outcome = 0; return .unresolved("injected lost acknowledgement") }
        return write
    }
}

extension MappingOwnerChecks {
 static func heldPublication(_ directory: URL, limits: LibraryLimits) async throws {
    for outcome in 0...2 {
        let url = directory.appendingPathComponent("held-\(outcome).json")
        let port = MappingGatedPort(LibrarySessionFile(url: url, maximumBytes: limits.maximumBytes))
        let session = try await SoundLibrarySession(persistence: port, limits: limits)
        let made = try await session.createEmpty(name: "Held")
        _ = try await session.select(made.candidate.definition, on: "test.held")
        let state = try await session.snapshot(), use = state.uses[0], binding = state.assignments[0]
        let target = LibraryBinding(assignment: binding.id, use: use.id, target: "test.held")
        var edit = try await session.beginEdit(.use(target), admission: { _ in })
        let first = UUID(), second = UUID()
        edit = try await session.edit(edit.handle, expectedGeneration: edit.generation, command: .mapping(path: [], .create(.slider(id: first, title: "First", initial: 0.5, waypoints: [0,0.5,1]))))
        await session.setEnabled(true)
        let preview = try await session.previewUpdateLibrary(edit.handle, expectedGeneration: edit.generation, places: [LibraryUpdatePlace(use: use.id)])
        await port.arm(outcome)
        let save = Task { try await session.confirmUpdateLibrary(preview) }
        await port.wait()
        edit = try await session.edit(edit.handle, expectedGeneration: edit.generation, command: .mapping(path: [], .create(.slider(id: second, title: "Newer", initial: 0.5, waypoints: [0,0.5,1]))))
        try await session.move(first, on: "test.held", to: .scalar(0.7))
        await session.setEnabled(false)
        _ = try await session.setEnabled(false, expected: target)
        await port.release()
        let receipt = try await save.value
        if outcome == 2 { try checkMapping(try await session.reconcile().isAccepted, "M15 uncertain publication resolved from actual owned file") }
        if outcome == 1 { try checkMapping(!receipt.commit.outcome.isAccepted, "M15 refused publication remains refused") }
        edit = try await session.inspectEdit(edit.handle)
        let after = try await session.snapshot()
        try checkMapping(edit.controls.contains { $0.id == second } && !after.isEnabled && !after.assignments[0].isEnabled,
            "M15 suspended publication preserves newer edit, OFF and assignment OFF \(outcome)")
        try checkMapping(after.uses[0].positions[first] == .scalar(0.7), "M15 newer ordinary listening survives \(outcome)")
        edit = try await session.undoEdit(edit.handle, expectedGeneration: edit.generation)
        try checkMapping(!edit.controls.contains { $0.id == second }, "M15 scoped Undo retains ownership after publication \(outcome)")
        edit = try await session.redoEdit(edit.handle, expectedGeneration: edit.generation)
        try checkMapping(edit.controls.contains { $0.id == second }, "M15 scoped Redo after publication \(outcome)")
        _ = try await session.checkpoint()
        let reopened = try await SoundLibrarySession(persistence: LibrarySessionFile(url: url, maximumBytes: limits.maximumBytes), limits: limits)
        try checkMapping(try await reopened.snapshot().uses[0].controls.contains { $0.id == second }, "M15 newer draft survives final owned checkpoint/reopen \(outcome)")
    }
 }
}

extension MappingOwnerChecks {
 static func wireRefusals(_ file: URL, directory: URL, limits: LibraryLimits) async throws {
    let original = try Data(contentsOf: file)
    let object = try JSONSerialization.jsonObject(with: original)
    func mutate(_ value: Any, mode: Int) -> Any {
        if var dictionary = value as? [String: Any] {
            if dictionary["source"] != nil, dictionary["reference"] != nil, dictionary["response"] != nil {
                if mode == 0 { dictionary["source"] = ["generator": ["id": UUID().uuidString]] }
                if mode == 1 { dictionary["response"] = ["unknown": [:]] }
            }
            if let entries = dictionary["choices"] as? [String: Any], let table = entries["_0"] as? [[String: Any]], !table.isEmpty {
                if mode == 2 { dictionary["choices"] = ["_0": Array(table.dropLast())] }
                if mode == 3 { dictionary["choices"] = ["_0": table + [table[0]]] }
                if mode == 4 { var changed = table; changed[0]["value"] = 1.1; dictionary["choices"] = ["_0": changed] }
            }
            if mode == 5, dictionary["profile"] != nil, dictionary["canonicalVersion"] != nil { dictionary["futureField"] = true }
            return dictionary.mapValues { mutate($0, mode: mode) }
        }
        if let array = value as? [Any] { return array.map { mutate($0, mode: mode) } }
        return value
    }
    for mode in 0...5 {
        let changed = try JSONSerialization.data(withJSONObject: mutate(object, mode: mode), options: [.sortedKeys])
        try checkMapping(changed != original, "wire fixture changed \(mode)")
        let url = directory.appendingPathComponent("bad-\(mode).json")
        try changed.write(to: url)
        do {
            _ = try await SoundLibrarySession(persistence: LibrarySessionFile(url: url, maximumBytes: limits.maximumBytes), limits: limits)
            throw MappingCheckError.failed("malformed wire admitted \(mode)")
        } catch is MappingCheckError { throw MappingCheckError.failed("malformed wire admitted \(mode)") }
        catch { }
        try checkMapping(try Data(contentsOf: url) == changed, "H01/H03 unknown or malformed transfer refuses without writes \(mode)")
    }
    try checkMapping(try Data(contentsOf: file) == original, "malformed admission keeps the valid owned source unchanged")
 }
}
