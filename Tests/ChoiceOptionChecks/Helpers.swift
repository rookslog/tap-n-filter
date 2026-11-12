import Foundation
import SoundModel
import SessionStore

struct Failure: Error { let message: String }
func check(_ value: Bool, _ message: String) throws {
    guard value else { throw Failure(message:message) };print("PASS \(message)");fflush(nil)
}
func id(_ n: Int) -> UUID { UUID(uuidString:String(format:"39393939-0000-0000-0000-%012llx",UInt64(n)))! }
let a=id(1), b=id(2), c=id(3), d=id(4), choice=id(10)
let address=LibraryControlAddress(path:[],control:choice)
actor RecordedStore: LibraryPersistence {
    let store: LibrarySessionFile
    var submitted:[Data]=[]
    var held = false, reached = false, mode = 0
    var waiters: [CheckedContinuation<Void,Never>] = []
    var releaseWaiter: CheckedContinuation<Void,Never>?
    func arm(_ mode: Int) { held=true;reached=false;self.mode=mode }
    func wait() async { if reached { return };await withCheckedContinuation { waiters.append($0) } }
    func release() { held=false;releaseWaiter?.resume();releaseWaiter=nil }
    init(_ file: URL) {store=LibrarySessionFile(url:file,maximumBytes:8_000_000)}
    func load() async throws -> Data? {try await store.load()}
    func commit(_ data:Data) async -> LibraryWriteOutcome {
        guard (try? JSONSerialization.jsonObject(with:data) as? [String:Any])?["enabled"] as? Bool == false else {return .refused(.io("expected encoded OFF"))}
        submitted.append(data)
        if held { reached=true;for w in waiters {w.resume()};waiters=[];await withCheckedContinuation {releaseWaiter=$0} }
        let outcome=mode;mode=0
        if outcome==1{return .refused(.io("injected before replacement"))}
        let result=await store.commit(data)
        if outcome==2{return .unresolved("injected lost acknowledgement")};return result
    }
}
@MainActor final class Fixture {
    let file:URL, port:RecordedStore, definition:UUID
    var session:SoundLibrarySession, edit:LibraryEditSnapshot
    let limits:LibraryLimits
    init(_ directory:URL,_ name:String="Options") async throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        file=directory.appendingPathComponent("library.json");port=RecordedStore(file)
        limits=try LibraryLimits(maximumBytes:8_000_000,maximumRevisions:1024,
            expansion:LibraryExpansionLimits(maximumDepth:24,maximumOccurrences:256,maximumParts:1024))
        session=try await SoundLibrarySession(persistence:port,limits:limits)
        let creation=try await session.createEmpty(name:name)
        guard let ref=creation.acceptedReference else{throw Failure(message:"initial creation refused")}
        definition=ref.definition;edit=try await session.beginEdit(.definition(definition),admission:{_ in})
        try await map(.create(.choice(id:choice,title:"Door",options:[LibraryOption(id:a,title:"A",position:0),LibraryOption(id:b,title:"B",position:0.5),LibraryOption(id:c,title:"C",position:1)],initial:a)))
    }
    func refresh() async throws {edit=try await session.inspectEdit(edit.handle)}
    func map(_ command:LibraryMappingCommand,path:[UUID]=[]) async throws {
        edit=try await session.edit(edit.handle,expectedGeneration:edit.generation,command:.mapping(path:path,command))
    }
    func mutate(_ mutation:LibraryOptionMutation,at:LibraryControlAddress=address) async throws -> LibraryOptionEditResult {
        try await refresh();let preview=try await session.previewOptionEdit(edit.handle,expectedGeneration:edit.generation,address:at,mutation:mutation)
        let result=try await session.applyOptionEdit(preview);edit=result.snapshot;return result
    }
    func options(_ control:UUID=choice) -> [UUID] {
        guard let p=edit.controls.first(where:{$0.id==control}),case .choice(let options)=p.face else{return []};return options.map(\.id)
    }
    func save() async throws {
        let commit=try await session.checkpointEdit(edit.handle,expectedGeneration:edit.generation)
        try check(commit.outcome.isAccepted,"real owned file checkpoint accepted")
        try check((try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [String:Any])?["enabled"] as? Bool == false,"encoded master OFF")
    }
    func reopen() async throws {
        session=try await SoundLibrarySession(persistence:RecordedStore(file),limits:limits)
        edit=try await session.beginEdit(.definition(definition),admission:{_ in})
    }
}

@MainActor extension Fixture {
    func publish(_ places:[LibraryUpdatePlace]=[], replacements:[LibraryOptionReplacement]=[]) async throws -> LibraryUpdatePreview {
        try await refresh();let p=try await session.previewUpdateLibrary(edit.handle,expectedGeneration:edit.generation,places:places,replacements:replacements)
        let result=try await session.confirmUpdateLibrary(p)
        try check(result.commit.outcome.isAccepted && result.acceptedReport?.capturedDigest==result.commit.digest,"typed A25 actual accepted report/digest")
        try await refresh();return p
    }
    func attach(_ target:String="test.options") async throws -> LibraryBinding {
        _=try await session.select(definition,on:target)
        let snapshot=try await session.snapshot(),binding=snapshot.assignments.first{$0.target==target}!
        return LibraryBinding(assignment:binding.id,use:binding.use,target:target)
    }
    func startUse(_ target:String="test.options") async throws -> LibraryBinding {
        _=try await publish();let binding=try await attach(target)
        edit=try await session.beginEdit(.use(binding),admission:{_ in});return binding
    }
    func hand(_ value:Double,_ control:UUID=choice,path:[UUID]=[]) async throws {
        edit=try await session.edit(edit.handle,expectedGeneration:edit.generation,command:.moveControl(LibraryControlAddress(path:path,control:control),.scalar(value)))
    }
    func facts() async throws -> LibraryMappingSnapshot {try await session.mappings(edit.handle)}
    func effective(_ control:UUID=choice,path:[UUID]=[]) async throws -> Double {
        guard let c=try await facts().controls.first(where:{$0.address==LibraryControlAddress(path:path,control:control)}),case .scalar(let n)=c.effective else{throw Failure(message:"missing effective value")};return n
    }
}
