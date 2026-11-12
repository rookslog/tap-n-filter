import Foundation
@testable import SoundModel
import SessionStore

extension MappingOwnerChecks {
 static func repeatedDormant(_ directory: URL, limits: LibraryLimits) async throws {
    for reverse in [false,true] {
        let file = directory.appendingPathComponent("repeated-\(reverse).json")
        let port = MappingGatedPort(LibrarySessionFile(url: file, maximumBytes: limits.maximumBytes))
        let session = try await SoundLibrarySession(persistence: port, limits: limits)
        let source = try await session.createEmpty(name: "Room for retirement")
        var sourceEdit = try await session.beginEdit(.definition(source.candidate.definition), admission: { _ in })
        let door = UUID(), a = UUID(), b = UUID(), c = UUID()
        sourceEdit = try await session.edit(sourceEdit.handle, expectedGeneration: sourceEdit.generation,
            command: .mapping(path: [], .create(.choice(id: door, title: "Door", options: [LibraryOption(id:a,title:"Open",position:0),LibraryOption(id:b,title:"Ajar",position:0.5),LibraryOption(id:c,title:"Closed",position:1)], initial:b))))
        let seed = try await session.previewUpdateLibrary(sourceEdit.handle, expectedGeneration: sourceEdit.generation, places: [])
        _ = try await session.confirmUpdateLibrary(seed); sourceEdit = try await session.inspectEdit(sourceEdit.handle)
        _ = try await session.createLinkedBlock(name: "Two rooms", children: [seed.new,seed.new], on: "test.retire")
        let state = try await session.snapshot(), use = state.uses[0], assignment = state.assignments[0]
        let binding = LibraryBinding(assignment:assignment.id,use:use.id,target:"test.retire")
        var parent = try await session.beginEdit(.use(binding), admission: { _ in })
        let sites = parent.pieces.compactMap { piece -> UUID? in if case .reference(let site,_,_) = piece { return site }; return nil }
        let macro = UUID(), links = [UUID(),UUID()]
        parent = try await session.edit(parent.handle, expectedGeneration:parent.generation, command:.mapping(path:[],.create(.slider(id:macro,title:"Macro",initial:0.5,waypoints:[0,0.5,1]))))
        for i in 0..<2 {
            parent = try await session.edit(parent.handle, expectedGeneration:parent.generation, command:.mapping(path:[],.connect(id:links[i],source:LibraryMappingSource(macro),target:.control(site:sites[i],control:door,axis:.value))))
            try await session.move(LibraryControlAddress(path:[sites[i]],control:door),on:"test.retire",to:.scalar(Double(i)))
        }
        let pub = try await session.previewUpdateLibrary(parent.handle, expectedGeneration:parent.generation, places:[LibraryUpdatePlace(use:use.id)])
        _ = try await session.confirmUpdateLibrary(pub); parent = try await session.inspectEdit(parent.handle)
        await session.setEnabled(true); _ = try await session.checkpoint()
        sourceEdit = try await session.edit(sourceEdit.handle, expectedGeneration:sourceEdit.generation, command:.mapping(path:[],.removeControl(door)))
        let ordered = reverse ? Array(sites.reversed()) : sites
        print("TRACE D2 preview with distinct saved hand positions and signed adjustments, reverse \(reverse)")
        let preview = try await session.previewUpdateLibrary(sourceEdit.handle, expectedGeneration:sourceEdit.generation,
            places:ordered.map { LibraryUpdatePlace(use:use.id,path:[$0]) })
        try checkMapping(Set(preview.brokenBindings) == Set(links), "D2 both-place preview retains exact broken IDs, order \(reverse)")
        await port.arm(0)
        let saving = Task { try await session.confirmUpdateLibrary(preview) }
        await port.wait(); await session.setEnabled(false); await port.release()
        try checkMapping(try await saving.value.commit.outcome.isAccepted, "D2/D3 actual held confirmation accepted, order \(reverse)")
        _ = try await session.checkpoint()
        let bytes = try Data(contentsOf:file)
        let archive = try SoundLibrarySession.storedArchive(bytes, limits:limits)
        let saved = archive.uses.first { $0.use.id.rawValue == use.id }!.positions.filter(\.dormant)
        try checkMapping(saved.count == 2 && Set(saved.map { $0.path.first!.rawValue }) == Set(sites), "D2 two distinct dormant occurrence records survive newer OFF checkpoint \(reverse)")
        for i in 0..<2 {
            let item = saved.first { $0.path.map(\.rawValue) == [sites[i]] }!
            try checkMapping(item.value == .scalar(try Position(0.5)) && item.retiredControl?.id.rawValue == door,
                "D3 exact retired manual/schema identity preserved \(reverse)/\(i)")
            try nearMapping(item.adjustments.first { $0.axis == .value }!.value, Double(i)-0.5, "D3 exact retired signed adjustment preserved \(reverse)/\(i)")
        }
        let fresh = try await SoundLibrarySession(persistence:LibrarySessionFile(url:file,maximumBytes:limits.maximumBytes),limits:limits)
        let freshEdit = try await fresh.beginEdit(.use(binding),admission:{_ in})
        let facts = try await fresh.mappings(freshEdit.handle)
        let freshState = try await fresh.snapshot()
        try checkMapping(!archive.enabled && !freshState.isEnabled && facts.bindings.filter { $0.broken == .targetRemoved }.count == 2,
            "D2/D3 fresh facade retains latest OFF and both broken links \(reverse)")
    }
 }
}
