import Foundation
import SoundModel
import SessionStore
import PlaybackRenderBridge

struct CheckFailure: Error { let message: String }
@MainActor final class Log {
    let directory: URL
    var rows: [[String:Any]] = []
    init(_ directory: URL) throws { self.directory=directory; try FileManager.default.createDirectory(at: directory, withIntermediateDirectories:true) }
    func record(_ ok: Bool,_ name: String,_ detail: String = "") {
        rows.append(["ok":ok,"check":name,"detail":detail]); print("\(ok ? "PASS" : "FAIL") \(name) \(detail)"); fflush(nil)
        try! JSONSerialization.data(withJSONObject: rows, options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("checks.json"))
    }
    func require(_ ok: Bool,_ name: String) throws { record(ok,name); if !ok { throw CheckFailure(message:name) } }
    func near(_ x: Double,_ y: Double,_ name: String,_ tolerance: Double=1e-10) { record(abs(x-y)<=tolerance,name,"actual=\(x) expected=\(y)") }
    func flat(_ x: Double,_ y: Double,_ name: String) { record(x==y,name,"strict actual=\(x) [\(x.bitPattern)] baseline=\(y) [\(y.bitPattern)]") }
}
actor RecordedFile: LibraryPersistence {
    let file: LibrarySessionFile, directory: URL
    var writes=0
    init(_ url: URL,_ directory: URL) { file=LibrarySessionFile(url:url,maximumBytes:8_000_000); self.directory=directory }
    func load() async throws -> Data? { try await file.load() }
    func commit(_ data: Data) async -> LibraryWriteOutcome {
        writes += 1
        do {
            let json=try JSONSerialization.jsonObject(with:data) as! [String:Any]
            guard json["enabled"] as? Bool == false else { return .refused(.io("test requires encoded global OFF")) }
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            try data.write(to:directory.appendingPathComponent("submission-\(writes).json"))
        } catch { return .refused(.io("owned evidence write: \(error)")) }
        return await file.commit(data)
    }
}
struct Observed: Equatable {
    let parts:[LibraryEditPart], pieces:[LibraryEditPiece], controls:[LibraryControl]
    let positions:[LibraryControlAddress:LibraryPosition], structural:Bool
    let bindings:[LibraryMappingSummary], mappingControls:[LibraryMappingControl]
}
@MainActor final class Harness {
    var session:SoundLibrarySession
    var edit:LibraryEditSnapshot
    let file:URL, log:Log, limits:LibraryLimits
    var recorder:RecordedFile
    var reopenNumber=0
    let definition:UUID
    var temporary:[UUID]=[]
    init(_ log:Log,_ name:String) async throws {
        self.log=log;file=log.directory.appendingPathComponent("library.json")
        limits=try LibraryLimits(maximumBytes:8_000_000,maximumRevisions:1024,expansion:LibraryExpansionLimits(maximumDepth:24,maximumOccurrences:256,maximumParts:1024))
        recorder=RecordedFile(file,log.directory.appendingPathComponent("submissions"))
        session=try await SoundLibrarySession(persistence:recorder,limits:limits)
        await session.setEnabled(false)
        let c=try await session.createEmpty(name:name)
        guard let accepted=c.acceptedReference else { throw CheckFailure(message:"create not accepted") };definition=accepted.definition
        edit=try await session.beginEdit(.definition(definition),admission:RenderAssignmentMapper.admitParts)
    }
    func observe() async throws -> Observed {
        edit=try await session.inspectEdit(edit.handle);let m=try await session.mappings(edit.handle)
        return Observed(parts:edit.parts,pieces:edit.pieces,controls:edit.controls,positions:edit.positions,structural:edit.pendingStructural,bindings:m.bindings,mappingControls:m.controls)
    }
    func action(_ name:String,_ command:LibraryEditCommand,undo:Bool=true) async throws {
        let before=try await observe()
        print("CALL \(name)");fflush(nil)
        edit=try await session.edit(edit.handle,expectedGeneration:edit.generation,command:command)
        let after=try await observe()
        if undo && before != after {
            edit=try await session.undoEdit(edit.handle,expectedGeneration:edit.generation)
            try log.require(try await observe()==before,"\(name) ONE Undo")
            edit=try await session.redoEdit(edit.handle,expectedGeneration:edit.generation)
            try log.require(try await observe()==after,"\(name) ONE Redo")
        } else { log.record(true,"\(name) admitted; no nested Undo or no observable delta") }
    }
    func map(_ name:String,_ command:LibraryMappingCommand,path:[UUID]=[],undo:Bool=true) async throws { try await action(name,.mapping(path:path,command),undo:undo) }
    func add(_ type:String) async throws -> UUID {
        let before=Set(edit.parts.map(\.id));try await action("add \(type)",.addPart(type:type,at:edit.pieces.count))
        guard let id=Set(edit.parts.map(\.id)).subtracting(before).first else { throw CheckFailure(message:"new part identity missing") };return id
    }
    func base(_ part:UUID,_ key:String,_ n:Double) async throws {try await map("base \(key)=\(n)",.settingBase(part:part,parameter:key,normalized:n))}
    func slider(_ id:UUID,_ title:String,_ points:[Double],initial:Double=0) async throws {try await map("create \(title)",.create(.slider(id:id,title:title,initial:initial,waypoints:points)))}
    func choice(_ id:UUID,_ title:String,_ options:[LibraryOption],_ initial:UUID) async throws {try await map("create \(title)",.create(.choice(id:id,title:title,options:options,initial:initial)))}
    func link(_ id:UUID,_ source:UUID,_ target:LibraryMappingTarget) async throws {try await map("connect \(id)",.connect(id:id,source:LibraryMappingSource(source),target:target))}
    func lane(_ id:UUID,_ points:[(Double,Double)],option:UUID?=nil,shapes:[LibraryStretch]?=nil) async throws {
        let lane=try LibraryMappingLane(points:points.map{LibraryLanePoint($0.0,$0.1)},stretches:shapes ?? Array(repeating:.straight,count:points.count-1))
        try await map("lane \(id) / \(String(describing:option))",.lane(binding:id,option:option,lane:lane))
    }
    func bootstrap(_ id:UUID,_ source:UUID,_ target:LibraryMappingTarget,_ temp:[UUID]) async throws {
        temporary=temp
        try await choice(temp[0],"TEMP neutral selector",[LibraryOption(id:temp[1],title:"A",position:0),LibraryOption(id:temp[2],title:"B",position:1)],temp[1])
        try await map("neutral first link",.connectOptions(id:id,source:LibraryMappingSource(source),target:target,selector:temp[0]))
        let p=try await session.previewSameForAll(edit.handle,expectedGeneration:edit.generation,source:source)
        try await map("same for all temporary cases",.sameForAll(p))
        try await map("remove TEMP selector",.removeControl(temp[0]))
        let m=try await session.mappings(edit.handle)
        try log.require(!edit.controls.contains{$0.id==temp[0]} && m.bindings.allSatisfy{$0.selector==nil},"temporary selector absent from final public graph")
    }
    func publish(_ places:[LibraryUpdatePlace]=[]) async throws -> LibraryReference {
        edit=try await session.inspectEdit(edit.handle)
        let p=try await session.previewUpdateLibrary(edit.handle,expectedGeneration:edit.generation,places:places)
        let c=try await session.confirmUpdateLibrary(p)
        try log.require(c.commit.outcome.isAccepted,"A25 accepted commit boundary")
        edit=try await session.inspectEdit(edit.handle);return p.new
    }
    func binding(_ target:String) async throws -> LibraryBinding {
        let s=try await session.snapshot();guard let a=s.assignments.first(where:{$0.target==target}) else {throw CheckFailure(message:"assignment missing")}
        return LibraryBinding(assignment:a.id,use:a.use,target:a.target)
    }
    func attach(_ ref:LibraryReference) async throws {
        for target in ["com.apple.Safari","com.colliderli.iina"] {let c=try await session.select(ref.definition,on:target);try log.require(c.outcome.isAccepted,"assign \(target)")}
        let s=try await session.snapshot();let a=s.assignments.filter{$0.target=="com.apple.Safari" || $0.target=="com.colliderli.iina"}
        let uses=s.uses.filter{u in a.contains{$0.use==u.id}}
        try log.require(uses.count==2 && Set(uses.map(\.id)).count==2 && uses.allSatisfy{$0.definition==ref.definition && $0.baseRevision==ref.revision},"same exact block ref, two independent app uses")
    }
    func move(_ id:UUID,_ p:Double,_ target:String="com.apple.Safari",path:[UUID]=[]) async throws {
        let before=try await observe(),heads=try await session.snapshot().definitions
        let undoBefore=edit.canUndo,redoBefore=edit.canRedo
        _=try await session.move(LibraryControlAddress(path:path,control:id),expected:binding(target),to:.scalar(p))
        let after=try await observe()
        let nowHeads=try await session.snapshot().definitions
        let partsSame=before.parts.count==after.parts.count && zip(before.parts,after.parts).allSatisfy { a,b in
            a.id==b.id && a.type==b.type && a.bypassed==b.bypassed && a.settings.count==b.settings.count && zip(a.settings,b.settings).allSatisfy { x,y in
                x.parameter==y.parameter && x.base==y.base && x.adjustment==y.adjustment && x.isChangedHere==y.isChangedHere && x.isShownAtTop==y.isShownAtTop
            }
        }
        log.record(partsSame && before.pieces==after.pieces && before.controls==after.controls && before.structural==after.structural && before.bindings==after.bindings && heads==nowHeads && undoBefore==edit.canUndo && redoBefore==edit.canRedo,"ordinary move never authors payload/head/history")
    }
    func value(_ part:UUID,_ key:String,_ target:String="com.apple.Safari") async throws -> Double {
        let s=try await session.snapshot();guard let a=s.assignments.first(where:{$0.target==target}),let p=a.parts.first(where:{$0.id==part}),let v=p.parameters.first(where:{$0.key==key}) else {throw CheckFailure(message:"native parameter missing")};return v.value
    }
    func save() async throws {let c=try await session.checkpoint();try log.require(c.outcome.isAccepted,"owned checkpoint accepted");try wire()}
    func wire() throws {
        let data=try Data(contentsOf:file),j=try JSONSerialization.jsonObject(with:data) as! [String:Any]
        try log.require(j["enabled"] as? Bool == false,"saved global OFF")
        var sources=0,valid=true
        func visit(_ x:Any) {
            if let d=x as? [String:Any] {
                if d["target"] != nil,let s=d["source"] as? [String:Any],d["reference"] != nil {
                    sources += 1
                    guard Set(s.keys)==["control"],let c=s["control"] as? [String:Any],Set(c.keys)==["id","axis"],UUID(uuidString:c["id"] as? String ?? "") != nil,["value","x","y"].contains(c["axis"] as? String ?? "") else {valid=false;return}
                };for v in d.values {visit(v)}
            } else if let a=x as? [Any] {for v in a {visit(v)}}
        }
        visit(j);try log.require(sources>0 && valid,"DIRECT saved source tag shape control/id/axis")
        let wire=String(decoding:data,as:UTF8.self).lowercased()
        log.record(temporary.allSatisfy{!wire.contains($0.uuidString.lowercased())},"no TEMP UUID/option/presentation/selection residue in final saved graph (history excluded)")
    }
    func reopen(_ target:LibraryEditTarget?=nil) async throws {
        let authoredBefore=try await observe()
        let before=try await session.snapshot(),oldRecorder=recorder,writes=await recorder.writes
        reopenNumber += 1
        let nextRecorder=RecordedFile(file,log.directory.appendingPathComponent("submissions-reopen-\(reopenNumber)"))
        let fresh=try await SoundLibrarySession(persistence:nextRecorder,limits:limits)
        let after=try await fresh.snapshot()
        try log.require(before.definitions==after.definitions && before.uses==after.uses && before.assignments==after.assignments && !after.isEnabled,"fresh real file owner exact definitions/uses/positions/native order/OFF")
        session=fresh;recorder=nextRecorder;edit=try await fresh.beginEdit(target ?? .definition(definition),admission:RenderAssignmentMapper.admitParts)
        try log.require(try await observe()==authoredBefore,"fresh owner EXACT public mappings/lanes/references/manual/effective/parts/presentation")
        try log.require(await oldRecorder.writes==writes,"old session issues no writes after fresh reopen")
    }
}
func fid(_ row:Int,_ i:Int)->UUID { UUID(uuidString:String(format:"544e4640-0000-0000-0000-%012llx",UInt64((row<<16)+i)))! }
func ng(_ db:Double)->Double {(db+96)/102}
func nf(_ hz:Double)->Double {log(hz/20)/log(1000)}
let safari="com.apple.Safari",iina="com.colliderli.iina"

extension Harness {
    func xy(_ id: UUID, _ title: String, _ x: Double, _ y: Double,
        _ xs: [Double], _ ys: [Double]) async throws {
        try await map("create real XY", .create(.xy(id:id,title:title,initialX:x,initialY:y,
            xWaypoints:xs,yWaypoints:ys)))
    }
    func moveXY(_ id: UUID, _ x: Double, _ y: Double, _ target: String = safari) async throws {
        let before = try await observe(), heads = try await session.snapshot().definitions
        let undo = edit.canUndo, redo = edit.canRedo
        _ = try await session.move(LibraryControlAddress(path:[],control:id),expected:binding(target),to:.xy(x,y))
        let after = try await observe(), newHeads = try await session.snapshot().definitions
        let sameParts = zip(before.parts, after.parts).allSatisfy { a,b in
            a.id==b.id && a.type==b.type && a.bypassed==b.bypassed && a.settings.count==b.settings.count && zip(a.settings,b.settings).allSatisfy { x,y in
                x.parameter==y.parameter && x.base==y.base && x.adjustment==y.adjustment && x.isChangedHere==y.isChangedHere && x.isShownAtTop==y.isShownAtTop
            }
        }
        log.record(before.parts.count==after.parts.count && sameParts && before.pieces==after.pieces && before.controls==after.controls && before.structural==after.structural && before.bindings==after.bindings && heads==newHeads && undo==edit.canUndo && redo==edit.canRedo,"ordinary XY move never authors payload/head/hash/history")
    }
    func refuse(_ name: String, _ command: LibraryMappingCommand) async throws {
        try await save()
        let before = try await session.inspectEdit(edit.handle), maps = try await session.mappings(edit.handle)
        let snapshot = try await session.snapshot(), bytes = try Data(contentsOf:file)
        do {
            _ = try await session.edit(edit.handle,expectedGeneration:edit.generation,command:.mapping(path:[],command))
            throw CheckFailure(message:"unexpected admission: \(name)")
        } catch let e as CheckFailure { throw e }
        catch { log.record(true,"typed refusal \(name)",String(describing:error)) }
        let now = try await session.inspectEdit(edit.handle), newMaps = try await session.mappings(edit.handle)
        let newSnapshot = try await session.snapshot()
        try log.require(before==now && maps==newMaps && snapshot==newSnapshot,"refusal \(name) full public edit/mapping/snapshot unchanged")
        try await save()
        try log.require(try Data(contentsOf:file)==bytes,"refusal \(name) checkpoint byte equality")
    }
}
