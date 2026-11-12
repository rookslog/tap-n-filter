import Foundation
@testable import SoundModel
import SessionStore
import EverydayMenu
import PlaybackRenderBridge
#if SWIFT_PACKAGE
import XCTest
#endif

enum OptionCheckFailure: Error { case failed(String) }
func check(_ condition: Bool, _ name: String) throws {
    guard condition else { throw OptionCheckFailure.failed(name) }
    print("PASS \(name)")
}
func refuses(_ name: String, _ body: () async throws -> Void) async throws {
    do { try await body() } catch is OptionCheckFailure { throw OptionCheckFailure.failed(name) }
    catch { print("PASS \(name) refuses \(error)"); return }
    throw OptionCheckFailure.failed("admitted \(name)")
}
func uid(_ suffix: Int) -> UUID { UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", suffix))! }

struct OptionFixture {
    let parent = ControlID(uid(1)), hall = OptionID(uid(2)), church = OptionID(uid(3)), none = OptionID(uid(4))
    let a = ControlID(uid(5)), b = ControlID(uid(6)), c = ControlID(uid(7)), driver = ControlID(uid(8))
    let part = PartID(uid(9)), definition = DefinitionID(uid(10)), version = DefinitionVersionID(uid(11))
    let profiles = try! LibraryProfiles()
    let limits = try! LibraryLimits(maximumBytes: 8_000_000, maximumRevisions: 1024,
        expansion: LibraryExpansionLimits(maximumDepth: 24, maximumOccurrences: 256, maximumParts: 1024))
    var reference: LibraryReference { LibraryReference(definition: definition.rawValue, revision: version.rawValue) }
    func payload(driven: Bool = false, cycle: Bool = false) throws -> LibraryPayload {
        let choice = try Choice(options: [hall, church, none])
        let parent = SoundControl(id: parent, face: .choice(choice), position: .scalar(.start), waypoints: .scalar(choice.positions))
        func slider(_ id: ControlID, _ value: Double) throws -> SoundControl {
            SoundControl(id: id, face: .slider, position: .scalar(try Position(value)),
                waypoints: .scalar([.start, try Position(value), .end]))
        }
        let a = try slider(a, 0.5), b = try slider(b, 0.3), c = try slider(c, 0.5), driver = try slider(driver, 0.5)
        let soundPart = SoundPart(id: part, type: "gain", settings: [ParameterSetting(key: try ParameterKey("gainDb"), position: try Position(0.5))])
        func lane(_ control: SoundControl) throws -> MappingTransfer {
            .continuous(try MappingCurve(waypoints: [Waypoint(position: .start, value: try Position(0.2)),
                Waypoint(position: try control.position(on: .value), value: try Position(0.5)),
                Waypoint(position: .end, value: try Position(0.8))], shapes: [.straight, .straight]))
        }
        var bindings = try [a,b,c].enumerated().map { index, control in
            MappingBinding(id: uid(20 + index), source: LibraryMappingSource(control.id.rawValue),
                target: .setting(part: part.rawValue, parameter: "gainDb"), reference: try Position(0.5),
                response: .lane(try lane(control)), status: .active,
                provenance: MappingProvenance(source: control, selector: nil, target: nil, setting: soundPart))
        }
        if driven || cycle {
            let source = cycle ? b : driver
            let transfer = try MappingCurve(waypoints: [.init(position: .start, value: .start),
                .init(position: try source.position(on: .value), value: try Position(0.5)), .init(position: .end, value: .end)], shapes: [.straight,.straight])
            bindings.append(MappingBinding(id: uid(30), source: LibraryMappingSource(source.id.rawValue),
                target: .control(site: nil, control: parent.id.rawValue, axis: .value), reference: try Position(0.5),
                response: .lane(.continuous(transfer)), status: .active,
                provenance: MappingProvenance(source: source, selector: nil, target: parent)))
            if driven {
                bindings.append(MappingBinding(id:uid(31),source:LibraryMappingSource(driver.id.rawValue),
                    target:.control(site:nil,control:a.id.rawValue,axis:.value),reference:try Position(0.5),
                    response:.lane(.continuous(transfer)),status:.active,
                    provenance:MappingProvenance(source:driver,selector:nil,target:a)))
            }
        }
        let relations: [OptionControl] = [.choiceOption(parentChoice: parent.id, option: hall, child: a.id),
            .choiceOption(parentChoice: parent.id, option: church, child: b.id), .choiceOption(parentChoice: parent.id, option: hall, child: c.id)]
        let controls = [parent,b,a,c] + (driven ? [driver] : [])
        let block = SoundBlock(pieces: [.part(soundPart)], controls: controls, storage: .bindings(bindings), optionControls: relations)
        let display = controls.map { control -> LibraryControl in
            let face: LibraryFace = control.id == parent.id ? .choice(zip(choice.options,choice.positions).map {
                LibraryOption(id: $0.0.rawValue, title: $0.0 == hall ? "Hall" : ($0.0 == church ? "Church" : "None"), position: $0.1.value)
            }) : .slider("Small", "Large")
            return LibraryControl(id: control.id.rawValue, title: control.id == parent.id ? "Place" : "Where you stand",
                face: face, placement: .primary, readout: .positionPercent)
        }
        return LibraryPayload(profile: LibraryProfiles.everyday, block: block, presentation: display, canonicalVersion: 5)
    }
    func archive(_ payload: LibraryPayload) throws -> LibraryArchive {
        let initial = try LibraryArchive.initial(profiles: profiles)
        let definition = BlockDefinition(id: definition, version: version, name: "Option fixture", content: payload.block)
        let record = try LibraryRevision(definition: definition, origin: "custom", payload: payload, contentHash: payload.contentHash)
        return LibraryArchive(format: "tnf.library", schema: 8, commit: uid(40), provenance: "owned structural fixture",
            revisions: initial.revisions + [record], heads: initial.heads + [LibraryDefinitionRecord(record)],
            uses: [], assignments: [], enabled: false)
    }
    func seed(_ url: URL, payload: LibraryPayload? = nil) async throws {
        let archive = try archive(payload ?? self.payload())
        _ = try archive.validated(profiles: profiles, limits: limits)
        let store = LibrarySessionFile(url: url, maximumBytes: limits.maximumBytes)
        _ = try await store.load()
        try check(await store.commit(try archive.encoded()).isAccepted, "fixture admitted through actual owned file store")
    }
    func open(_ url: URL) async throws -> SoundLibrarySession {
        try await SoundLibrarySession(persistence: LibrarySessionFile(url: url, maximumBytes: limits.maximumBytes), limits: limits)
    }
    func binding(_ session: SoundLibrarySession, _ app: String) async throws -> LibraryBinding {
        let snapshot = try await session.snapshot()
        let assignment = snapshot.assignments.first { $0.target == app }!
        return LibraryBinding(assignment: assignment.id, use: assignment.use, target: app)
    }
    func value(_ session: SoundLibrarySession, _ app: String, _ id: ControlID) async throws -> LibraryPosition? {
        try await session.snapshot().uses.first { $0.target == app && $0.definition == definition.rawValue }?.positions[id.rawValue]
    }
}

actor HeldOptionStore: LibraryPersistence {
    let file: LibrarySessionFile
    var commitCalls = 0
    var armed: Int?, entered = false
    var enteredWaiters: [CheckedContinuation<Void,Never>] = []
    var releaseWaiter: CheckedContinuation<Void,Never>?
    init(_ url: URL, limit: Int) { file = LibrarySessionFile(url: url, maximumBytes: limit) }
    func load() async throws -> Data? { try await file.load() }
    func arm(_ outcome: Int) { armed = outcome; entered = false }
    func wait() async { if !entered { await withCheckedContinuation { enteredWaiters.append($0) } } }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
    func commit(_ data: Data) async -> LibraryWriteOutcome {
        commitCalls += 1
        let outcome = armed
        if armed != nil {
            armed = nil
            await withCheckedContinuation { continuation in
                releaseWaiter = continuation; entered = true
                for waiter in enteredWaiters { waiter.resume() }; enteredWaiters = []
            }
        }
        if outcome == 1 { return .refused(.previousRetained) }
        let result = await file.commit(data)
        return outcome == 2 ? .unresolved("injected missing acknowledgement") : result
    }
}

#if !SWIFT_PACKAGE
@main
#endif
struct OptionControlChecks {
    static func main() async throws {
        try await run(URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
    }
    static func run(_ directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let f = OptionFixture(), file = directory.appendingPathComponent("owner.json")
        try await f.seed(file)
        let session = try await f.open(file)
        for app in ["test.safari", "test.iina"] { _ = try await session.select(f.definition.rawValue, on: app) }
        let binding = try await f.binding(session, "test.safari")
        let child = LibraryControlAddress(path: [], control: f.a.rawValue)
        let parent = LibraryControlAddress(path: [], control: f.parent.rawValue)
        let gesture = LibraryOptionGesture(parent: parent, option: f.hall.rawValue)
        let defaultA = try await f.value(session,"test.safari",f.a), defaultB = try await f.value(session,"test.iina",f.b)
        try check(defaultA == .scalar(0.5) && defaultB == .scalar(0.3), "each absent child starts at its own neutral default")
        let neutralEdit = try await session.beginEdit(.use(binding),admission:{ _ in })
        let neutralSetting = neutralEdit.parts.first { $0.id == f.part.rawValue }!.settings.first { $0.parameter == "gainDb" }!
        try check(try neutralSetting.specification.normalized(neutralSetting.physicalValue) == 0.5,"fresh children preserve exact authored native setting")
        _ = try await session.move(child, expected: binding, optionGesture: gesture, to: .scalar(0.2))
        try await session.move(f.parent.rawValue,on:"test.safari",to:.scalar(0.5))
        try await session.move(f.b.rawValue,on:"test.safari",to:.scalar(0.8))
        try await session.move(f.parent.rawValue,on:"test.safari",to:.scalar(0))
        try await session.move(f.a.rawValue,on:"test.iina",to:.scalar(0.6))
        let safariA = try await f.value(session,"test.safari",f.a), safariB = try await f.value(session,"test.safari",f.b), iinaA = try await f.value(session,"test.iina",f.a)
        try check(safariA == .scalar(0.2) && safariB == .scalar(0.8) && iinaA == .scalar(0.6), "separate option IDs and app memory restore independently")
        let before = try await session.snapshot().assignments.first { $0.target == "test.safari" }!.parts
        try await session.move(f.b.rawValue,on:"test.safari",to:.scalar(0))
        let endpoint0 = try await session.snapshot().assignments.first { $0.target == "test.safari" }!.parts
        try await session.move(f.b.rawValue,on:"test.safari",to:.scalar(1))
        try check(try await session.snapshot().assignments.first { $0.target == "test.safari" }!.parts == before && endpoint0 == before, "inactive nonzero-reference child endpoints produce identical compiled native settings")
        try await session.move(f.parent.rawValue,on:"test.safari",to:.scalar(0.5))
        let frozen = try await session.saveCoverage()
        try check(try await session.move(child, expected: binding, optionGesture: gesture, to:.scalar(1)) == .superseded, "stale Hall callback refuses after Church selection")
        try check(try await session.saveCoverage().liveGeneration == frozen.liveGeneration, "stale gesture cannot mutate or increment live generation")
        try check(try await session.move(LibraryControlAddress(path:[],control:f.b.rawValue), expected:binding,optionGesture:gesture,to:.scalar(0)) == .superseded, "gesture cannot hit another option child")
        let rows = try await session.optionControls(expected: binding)
        try check(rows.filter(\.isActive).map(\.child.control) == [f.b.rawValue], "read-only occurrence relation exposes only effective active option")
        try await session.move(f.parent.rawValue,on:"test.safari",to:.scalar(0))
        try check(try await session.optionControls(expected: binding).filter(\.isActive).count == 2, "multiple child relations remain one parent option without duplicate visibility state")
        let additiveEdit = try await session.beginEdit(.use(binding),admission:{ _ in })
        for (value,expected) in [(1.0,1.0),(0.0,0.0)] {
            try await session.move(f.a.rawValue,on:"test.safari",to:.scalar(value))
            try await session.move(f.c.rawValue,on:"test.safari",to:.scalar(value))
            let part = try await session.inspectEdit(additiveEdit.handle).parts.first { $0.id == f.part.rawValue }!
            let setting = part.settings.first { $0.parameter == "gainDb" }!
            let actual = try setting.specification.normalized(setting.physicalValue)
            try check(abs(actual - expected) < 1e-12,"active child deltas add before final clamp \(value)")
        }
        try await session.move(f.a.rawValue,on:"test.safari",to:.scalar(0.2))
        try await session.move(f.c.rawValue,on:"test.safari",to:.scalar(0.5))
        await session.setEnabled(false); _ = try await session.setEnabled(false,expected:binding)
        _ = try await session.checkpoint()
        var reopened = try await f.open(file)
        let restoredA = try await f.value(reopened,"test.safari",f.a), restoredIina = try await f.value(reopened,"test.iina",f.a)
        try check(restoredA == .scalar(0.2) && restoredIina == .scalar(0.6), "actual save and fresh owner restore independent values")
        let restoredLive = try await reopened.liveState()
        try check(!restoredLive.isEnabled && !restoredLive.assignments.first { $0.binding.target == "test.safari" }!.isEnabled, "save and reopen preserve master and app OFF")
        let builtin = try await reopened.snapshot().definitions.first { $0.origin == "builtin" }!.id
        _ = try await reopened.select(builtin,on:"test.safari")
        try check(try await reopened.move(child,expected:binding,optionGesture:gesture,to:.scalar(1)) == .superseded,"old assignment gesture cannot hit replacement sound")
        _ = try await reopened.select(f.definition.rawValue,on:"test.safari")
        _ = try await reopened.select(nil,on:"test.safari"); _ = try await reopened.select(f.definition.rawValue,on:"test.safari")
        try check(try await f.value(reopened,"test.safari",f.a) == .scalar(0.2), "block switch and app remove/re-add reuse owned child memory")
        _ = try await reopened.checkpoint(); reopened = try await f.open(file)
        let edit = try await reopened.beginEdit(.use(try await f.binding(reopened,"test.safari")),admission:{ _ in })
        let beforeRefusal = try await reopened.snapshot()
        for mutation in [LibraryOptionMutation.add(id:uid(99),title:"New",at:1), .remove(id:f.hall.rawValue,replacement:f.church.rawValue)] {
            try await refuses("relation option authoring atomic refusal") {
                _ = try await reopened.previewOptionEdit(edit.handle,expectedGeneration:edit.generation,address:parent,mutation:mutation)
            }
        }
        try check(try await reopened.snapshot() == beforeRefusal, "option edit refusal leaves entire owner unchanged")
        let copied = try await reopened.duplicate(f.reference,name:"Exact copy")
        _ = try await reopened.select(copied.candidate.definition,on:"test.copy")
        let copiedBinding = try await f.binding(reopened,"test.copy")
        try check(try await reopened.optionControls(expected:copiedBinding).count == 3, "real duplicate retains structural relations and concrete IDs")
        let captureBefore = try await reopened.snapshot(), coverageBefore = try await reopened.saveCoverage(), bytesBefore = try Data(contentsOf:file)
        try await refuses("relation-bearing capture refusal") { _ = try await reopened.createFromUse(expected:copiedBinding,name:"Refused capture") }
        try check(try await reopened.snapshot() == captureBefore, "refused capture leaves live state unchanged")
        try check(try await reopened.saveCoverage() == coverageBefore && Data(contentsOf:file) == bytesBefore, "refused capture has no generation or file mutation")
        _ = try await reopened.select(builtin,on:"test.plain")
        let plainBinding = try await f.binding(reopened,"test.plain")
        let plainUse = try await reopened.snapshot().uses.first { $0.id == plainBinding.use }!
        let plainSlider = plainUse.controls.first { if case .slider = $0.face { return true }; return false }!
        try await reopened.move(plainSlider.id,on:"test.plain",to:.scalar(0.37))
        let plainParts = try await reopened.snapshot().assignments.first { $0.target == "test.plain" }!.parts
        let plainCapture = try await reopened.createFromUse(expected:plainBinding,name:"Plain capture")
        try check(plainCapture.acceptedReference != nil,"plain capture remains supported inside schema8 archive")
        try check(try await reopened.snapshot().assignments.first { $0.target == "test.plain" }!.parts == plainParts,"plain capture retains the current audible snapshot in schema8 archive")
        let cloneReopened = try await f.open(file)
        let cloneRelations = try await cloneReopened.optionControls(expected:copiedBinding)
        try check(Set(cloneRelations.map(\.child.control)) == Set([f.a.rawValue,f.b.rawValue,f.c.rawValue]),"saved exact clone retains distinct child identities after fresh reopen")
        let cloneSnapshot = try await cloneReopened.snapshot()
        try check(cloneSnapshot.definitions.first { $0.id == copied.candidate.definition }!.contentHash == cloneSnapshot.definitions.first { $0.id == f.definition.rawValue }!.contentHash,"duplicate retains exact canonical payload hash")
        let cloneUse = cloneSnapshot.uses.first { $0.id == copiedBinding.use }!
        try check(cloneUse.positions[f.a.rawValue] == .scalar(0.5) && cloneUse.positions[f.b.rawValue] == .scalar(0.3),"clone reopens with each child's exact neutral authored default")
        try await nested(directory,f)
        try await effective(directory,f)
        try await quickMenu(directory)
        try await folding(directory)
        try await menuPerformance(directory)
        try await held(directory,f)
        try await malformed(directory,f)
        try await intent(directory,f)
        print("PASS QM-01-DATA pure owner/file boundary; native UI/listening not exercised")
    }

    static func nested(_ directory: URL, _ f: OptionFixture) async throws {
        let url = directory.appendingPathComponent("nested.json"); try await f.seed(url)
        let session = try await f.open(url)
        _ = try await session.createLinkedBlock(name:"Repeated",children:[f.reference,f.reference],on:"test.nested")
        let binding = try await f.binding(session,"test.nested")
        let relations = try await session.optionControls(expected:binding)
        let halls = relations.filter { $0.option == f.hall.rawValue && $0.child.control == f.a.rawValue }
        try check(halls.count == 2 && halls[0].child.path != halls[1].child.path, "repeated exact child IDs resolve to separate occurrence paths")
        for (row,value) in zip(halls,[0.2,0.8]) {
            _ = try await session.move(row.child,expected:binding,optionGesture:LibraryOptionGesture(parent:row.parent,option:row.option),to:.scalar(value))
        }
        _ = try await session.checkpoint()
        let port = HeldOptionStore(url,limit:f.limits.maximumBytes)
        let reopened = try await SoundLibrarySession(persistence:port,limits:f.limits)
        var edit = try await reopened.beginEdit(.use(binding),admission:{ _ in })
        let facts = try await reopened.mappings(edit.handle)
        try check(facts.controls.first { $0.address == halls[0].child }!.manual == .scalar(0.2) && facts.controls.first { $0.address == halls[1].child }!.manual == .scalar(0.8), "nested repeated memory survives owned file reopen without aliasing")
        let beforeCapture = try await reopened.snapshot(), bytes = try Data(contentsOf:url)
        let commitCalls = await port.commitCalls
        try await refuses("nested referenced relation capture refusal") { _ = try await reopened.createFromUse(expected:binding,name:"Refused nested") }
        try check(try await reopened.snapshot() == beforeCapture && Data(contentsOf:url) == bytes,"nested capture refusal is atomic")
        try check(await port.commitCalls == commitCalls,"nested capture refusal calls no persistence writer")
        let rootChoice = uid(250), rootOptions = [uid(251),uid(252),uid(253)]
        edit = try await reopened.edit(edit.handle,expectedGeneration:edit.generation,command:.mapping(path:[],.create(.choice(id:rootChoice,title:"Root choice",options:rootOptions.enumerated().map { LibraryOption(id:$0.element,title:"Root \($0.offset)",position:Double($0.offset)/2) },initial:rootOptions[0]))))
        let beforeOption = try await reopened.snapshot()
        try await refuses("option authoring on a sound with referenced relations") {
            _ = try await reopened.previewOptionEdit(edit.handle,expectedGeneration:edit.generation,address:LibraryControlAddress(path:[],control:rootChoice),mutation:.add(id:uid(254),title:"Extra",at:1))
        }
        try check(try await reopened.snapshot() == beforeOption,"referenced relation option-authoring refusal is atomic")
        edit = try await reopened.edit(edit.handle,expectedGeneration:edit.generation,command:.mapping(path:[],.makeLocal(path:halls[0].child.path)))
        _ = try await reopened.checkpointEdit(edit.handle,expectedGeneration:edit.generation)
        let localized = try await f.open(url)
        try check(try await localized.optionControls(expected:binding) == relations,"real make-local and fresh reopen carry nested relation payload exactly")
        let nestedBytes = try Data(contentsOf:url)
        func corruptNested(_ value: Any, mode: Int) -> Any {
            if var object = value as? [String:Any] {
                if var payload = object["payload"] as? [String:Any], payload["canonicalVersion"] as? Int == 5 {
                    if mode == 0 { payload["canonicalVersion"] = 4 }
                    if mode == 1, var block = payload["block"] as? [String:Any] { block["optionControls"] = [["unknown":[String:Any]()]]; payload["block"] = block }
                    object["payload"] = payload
                }
                return object.mapValues { corruptNested($0,mode:mode) }
            }
            if let values = value as? [Any] { return values.map { corruptNested($0,mode:mode) } }
            return value
        }
        for mode in 0...1 {
            let malformed = directory.appendingPathComponent("nested-malformed-\(mode).json")
            let bytes = try JSONSerialization.data(withJSONObject:corruptNested(JSONSerialization.jsonObject(with:nestedBytes),mode:mode),options:[.sortedKeys])
            try bytes.write(to:malformed)
            try await refuses("recursive nested canonical/tag gate \(mode)") { _ = try await f.open(malformed) }
        }
        var definitionEdit = try await reopened.beginEdit(.definition(f.definition.rawValue),admission:{ _ in })
        definitionEdit = try await reopened.edit(definitionEdit.handle,expectedGeneration:definitionEdit.generation,command:.mapping(path:[],.rename(control:f.a.rawValue,title:"New head child")))
        let publication = try await reopened.previewUpdateLibrary(definitionEdit.handle,expectedGeneration:definitionEdit.generation,places:[])
        let accepted = try await reopened.confirmUpdateLibrary(publication)
        try check(accepted.commit.outcome.isAccepted,"real owner publishes changed library head without updating retained uses")
        _ = try await reopened.select(f.definition.rawValue,on:"test.current-head")
        let newHead = try await reopened.snapshot().uses.first { $0.target == "test.current-head" }!
        let retained = try await reopened.snapshot().uses.first { $0.target == "test.nested" }!
        try check(newHead.controls.first { $0.id == f.a.rawValue }!.title == "New head child" && retained.occurrences.filter { !$0.path.isEmpty }.allSatisfy { $0.controls.first { $0.id == f.a.rawValue }?.title == "Where you stand" },"new head and exact old nested use have distinct retained presentation payloads")
        _ = try await reopened.renameDefinition(f.definition.rawValue,name:"Current metadata")
        try check(try await reopened.optionControls(expected:binding) == relations, "retained exact references do not follow current display metadata")
    }

    static func effective(_ directory: URL, _ f: OptionFixture) async throws {
        let url = directory.appendingPathComponent("driven.json"); try await f.seed(url,payload:f.payload(driven:true))
        let session = try await f.open(url); _ = try await session.select(f.definition.rawValue,on:"test.driven")
        let binding = try await f.binding(session,"test.driven")
        let frozen = try await session.snapshot()
        let frozenMenu = MenuSoundData(library: frozen).assignments[0]
        try check(frozenMenu.optionTabs.first?.option.id == f.hall.rawValue, "coherent initial owner snapshot projects Hall tab")
        try check(frozenMenu.optionTabs.first?.netHeight == 56 && frozenMenu.optionTabs.first?.controls.map(\.id) == [f.a.rawValue, f.c.rawValue],
            "multiple children share one tab at30+26 points in presentation order")
        let staleRow = frozenMenu.optionTabs[0].controls[0]
        try await session.move(f.driver.rawValue,on:"test.driven",to:.scalar(1))
        let driven = try await session.snapshot()
        let projected = MenuSoundData(library: driven).assignments[0]
        try check(projected.optionTabs.first?.netHeight == 30, "single active child adds30 points")
        try check(projected.controls.first { $0.id == f.parent.rawValue }?.position == 0.5 && projected.optionTabs.first?.option.id == f.church.rawValue,
            "U1 effective parent and Church tab come from the same compiled owner snapshot")
        try check(MenuSoundData(library: frozen).assignments[0].optionTabs.first?.option.id == f.hall.rawValue,
            "U1 retained snapshot does not join a later live option query")
        let generation = try await session.saveCoverage().liveGeneration
        try check(try await session.move(staleRow.address, expected: binding, optionGesture: staleRow.optionGesture!, to: .scalar(0)) == .superseded,
            "U1 projected stale row carries exact parent and option precondition")
        try check(try await session.saveCoverage().liveGeneration == generation, "U1 stale projected row has no mutation")
        try check(try await session.optionControls(expected:binding).filter(\.isActive).map(\.option) == [f.church.rawValue], "effective driven parent aligns audio and projected activity")
        let edit = try await session.beginEdit(.use(binding),admission:{ _ in })
        let latent = try await session.mappings(edit.handle).controls.first { $0.address.control == f.a.rawValue }!
        try check(latent.manual == .scalar(0.5) && latent.effective == .scalar(1),"inactive child retains manual value while incoming link drives latent effective value")
        try check(try await session.move(LibraryControlAddress(path:[],control:f.a.rawValue),expected:binding,optionGesture:LibraryOptionGesture(parent:LibraryControlAddress(path:[],control:f.parent.rawValue),option:f.hall.rawValue),to:.scalar(0)) == .superseded,"gesture activation checks effective rather than manual parent")
        let sound0 = try await session.snapshot().assignments[0].parts
        try await session.move(f.a.rawValue,on:"test.driven",to:.scalar(1))
        try check(try await session.snapshot().assignments[0].parts == sound0, "inactive child stays silent under effective selector driving")
        try await refuses("inactive child to parent cycle") { _ = try f.archive(f.payload(cycle:true)).validated(profiles:f.profiles,limits:f.limits) }
    }

    static func held(_ directory: URL, _ f: OptionFixture) async throws {
        for outcome in 0...2 {
            let url = directory.appendingPathComponent("held-\(outcome).json");try await f.seed(url)
            let port = HeldOptionStore(url,limit:f.limits.maximumBytes)
            let session = try await SoundLibrarySession(persistence:port,limits:f.limits)
            _ = try await session.select(f.definition.rawValue,on:"test.held")
            let binding = try await f.binding(session,"test.held")
            try await session.move(f.a.rawValue,on:"test.held",to:.scalar(0.2)); await session.setEnabled(true)
            let capturesBefore = await port.commitCalls, coverageBefore = try await session.saveCoverage()
            try await refuses("moved active child capture refusal") { _ = try await session.createFromUse(expected:binding,name:"Refused active capture") }
            try check(await port.commitCalls == capturesBefore,"moved active capture calls no persistence writer")
            try check(try await session.saveCoverage() == coverageBefore,"moved active capture preserves owner generation and dirty state")
            await port.arm(outcome)
            let saving = Task { try await session.checkpoint() }
            await port.wait()
            let address = LibraryControlAddress(path:[],control:f.a.rawValue)
            _ = try await session.move(address,expected:binding,optionGesture:LibraryOptionGesture(parent:LibraryControlAddress(path:[],control:f.parent.rawValue),option:f.hall.rawValue),to:.scalar(0.8))
            await session.setEnabled(false); _ = try await session.setEnabled(false,expected:binding); await session.compareOriginal(true)
            await port.release(); let result = try await saving.value
            if outcome == 2 { try check(try await session.reconcile().isAccepted,"uncertain actual file readback reconciles") }
            if outcome == 1 { try check(!result.outcome.isAccepted,"refused write never reports saved") }
            let state = try await session.liveState()
            try check(try await f.value(session,"test.held",f.a) == .scalar(0.8) && !state.isEnabled && !state.assignments[0].isEnabled && state.compareOriginal, "late save retains newer child and OFF/compare state \(outcome)")
            try check(try await session.saveCoverage().isSaved == false,"late/refused/uncertain write leaves newer listening dirty \(outcome)")
            _ = try await session.checkpoint()
            let reopened = try await f.open(url)
            try check(try await f.value(reopened,"test.held",f.a) == .scalar(0.8), "newer child persists after final checkpoint/reopen \(outcome)")
        }
    }

    static func malformed(_ directory: URL, _ f: OptionFixture) async throws {
        let valid = try f.archive(f.payload()).encoded()
        let root = try JSONSerialization.jsonObject(with:valid) as! [String:Any]
        for mode in 0...9 {
            func mutate(_ value: Any) -> Any {
                if var object = value as? [String:Any] {
                    if mode == 0, object["schema"] != nil { object["schema"] = 6 }
                    if mode == 1, object["canonicalVersion"] as? Int == 5 { object["canonicalVersion"] = 4 }
                    if var relations = object["optionControls"] as? [[String:Any]], !relations.isEmpty {
                        if mode == 2 { relations[0] = ["future":[String:Any]()] }
                        if mode == 3 { relations.append(relations[0]) }
                        if var first = relations[0]["choiceOption"] as? [String:Any] {
                            if mode == 4 { first["child"] = ["rawValue":f.parent.rawValue.uuidString] }
                            if mode == 5 { first["option"] = ["rawValue":uid(999).uuidString] }
                            if mode == 6 { first["child"] = ["rawValue":uid(999).uuidString] }
                            if mode == 7 { first["future"] = true }
                            relations[0]["choiceOption"] = first
                        }
                        if mode == 8 { object["bindings"] = []; object["mappings"] = [] }
                        object["optionControls"] = relations
                    }
                    if mode == 9, object["canonicalVersion"] as? Int == 1, var definition = object["definition"] as? [String:Any], var block = definition["content"] as? [String:Any] {
                        block["optionControls"] = []; definition["content"] = block; object["definition"] = definition
                    }
                    return object.mapValues(mutate)
                }
                if let array = value as? [Any] { return array.map(mutate) }
                return value
            }
            let bytes = try JSONSerialization.data(withJSONObject:mutate(root),options:[.sortedKeys])
            let url = directory.appendingPathComponent("bad-\(mode).json");try bytes.write(to:url)
            try await refuses("unknown/malformed relation wire \(mode)") { _ = try await f.open(url) }
            try check(try Data(contentsOf:url) == bytes,"malformed destination is never reset \(mode)")
        }
        let payload = try f.payload()
        var bindings = payload.block.bindings!; bindings[0].response = .lane(.continuous(try MappingCurve(waypoints:[.init(position:.start,value:.start),.init(position:.end,value:.end)],shapes:[.straight])))
        let badChild = SoundControl(id:f.a,face:.slider,position:.scalar(try Position(0.2)),waypoints:.scalar([.start,try Position(0.5),.end]))
        let nonneutral = LibraryPayload(profile:payload.profile,block:payload.block.replacing(controls:payload.block.controls.map { $0.id == f.a ? badChild : $0 }).replacing(bindings:bindings),presentation:payload.presentation,canonicalVersion:5)
        try await refuses("nonneutral authored child default") { _ = try nonneutral.contentHash }
        let relations = payload.block.optionControls.reversed()
        let reordered = SoundBlock(pieces:payload.block.pieces,controls:payload.block.controls,storage:payload.block.mappingStorage,optionControls:Array(relations))
        try check(try payload.contentHash == LibraryPayload(profile:payload.profile,block:reordered,presentation:payload.presentation,canonicalVersion:5).contentHash,"relation hash order is parent/option/child deterministic")
    }

    static func intent(_ directory: URL, _ f: OptionFixture) async throws {
        let url = directory.appendingPathComponent("intent.json");try await f.seed(url)
        let session = try await f.open(url)
        let made = try await session.createEmpty(name:"Unrelated option intent")
        var edit = try await session.beginEdit(.definition(made.candidate.definition),admission:{ _ in })
        let choice = uid(200), options = [uid(201),uid(202),uid(203)]
        edit = try await session.edit(edit.handle,expectedGeneration:edit.generation,command:.mapping(path:[],.create(.choice(id:choice,title:"Choice",options:options.enumerated().map { LibraryOption(id:$0.element,title:"Option \($0.offset)",position:Double($0.offset)/2) },initial:options[0]))))
        let preview = try await session.previewOptionEdit(edit.handle,expectedGeneration:edit.generation,address:LibraryControlAddress(path:[],control:choice),mutation:.remove(id:options[1],replacement:options[0]))
        edit = try await session.applyOptionEdit(preview).snapshot
        _ = try await session.checkpointEdit(edit.handle,expectedGeneration:edit.generation)
        let archive = try SoundLibrarySession.storedArchive(Data(contentsOf:url),limits:f.limits)
        try check(archive.schema == 8 && archive.workspaces.contains { !($0.optionRemovals ?? []).isEmpty }, "schema8 preserves existing optional removal intent with historical v5 revision")
        let reopened = try await f.open(url)
        _ = try await reopened.beginEdit(.definition(made.candidate.definition),admission:{ _ in })
        try check(try Data(contentsOf:url) == archive.encoded(),"schema8 with intent reopens without rewriting bytes")
    }
}
