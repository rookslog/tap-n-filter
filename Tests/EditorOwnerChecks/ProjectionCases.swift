import Foundation
import SoundModel

@MainActor func ownerProjectionCases(_ root:URL) async throws {
    let f=try await Fixture(root),slider=id(810)
    let binding=try await f.startUse()
    f.edit=try await f.session.edit(f.edit.handle,expectedGeneration:f.edit.generation,command:.addPart(type:"gain",at:0))
    let part=f.edit.parts[0].id
    try await f.map(.create(.slider(id:slider,title:"Level",initial:0,waypoints:[0,0.5,1])))
    try await f.map(.connectLegacy(source:LibraryMappingSource(slider),part:part,parameter:"gainDb"))
    try await f.save()
    let bytes=try Data(contentsOf:f.file),before=try await f.session.inspectEdit(f.edit.handle),state=try await f.session.snapshot()
    let projection=try await f.session.mappings(f.edit.handle)
    let row=projection.bindings[0],lane=row.lane!
    try check(row.storage == .legacy && projection.descriptors.first{$0.address.control==slider}?.presentation?.title=="Level" && row.sourceWaypoints==[0,0.5,1],"P actual legacy row has stable identity/storage/presentation/axis waypoints")
    let coefficients=try lane.stretches()
    try check(coefficients.count==1 && coefficients[0].kind == .straight && coefficients[0].jump==0.5,"P authoritative encoded stretch kind/jump/Bezier coefficients exposed")
    for _ in 0..<4 {
        try check(try await f.session.mappings(f.edit.handle)==projection,"P repeated legacy read is deterministic")
    }
    let after=try await f.session.inspectEdit(f.edit.handle),afterState=try await f.session.snapshot()
    try check(before==after && state==afterState && bytes == (try Data(contentsOf:f.file)),"P projection preserves exact edit/history/generation/snapshot/archive bytes/hash")
    let replacement=try LibraryMappingLane(points:[LibraryLanePoint(0,0.2),LibraryLanePoint(0.5,0.8),LibraryLanePoint(1,0.4)],stretches:[.curve,.step])
    try await f.map(.lane(binding:row.id,option:nil,lane:replacement))
    try await f.map(.stretch(binding:row.id,option:nil,index:1,shape:.step,jump:0.37))
    let promoted=try await f.session.mappings(f.edit.handle).bindings[0],actual=promoted.lane!
    try check(promoted.id==row.id && promoted.storage == .bindings,"P first explicit lane edit promotes with SAME deterministic binding id")
    try check(try actual.stretches()[1].kind == .step && actual.stretches()[1].jump==0.37,"P exact nondefault Step jump survives authoritative projection")
    for value in [0.0,0.1,0.49,0.5,0.6,0.684,0.686,0.9,1.0] {
        _=try await f.session.move(LibraryControlAddress(path:[],control:slider),expected:binding,to:.scalar(value))
        f.edit=try await f.session.inspectEdit(f.edit.handle)
        let setting=f.edit.parts.first{$0.id==part}!.settings.first{$0.parameter=="gainDb"}!
        let physical=try setting.specification.physical(actual.value(at:value))
        try check(abs(setting.physicalValue-physical)<1e-10,"P projection evaluation matches actual compiler setting at \(value)")
    }
    try await f.map(.insertPoint(binding:row.id,option:nil,position:0.25))
    try await f.map(.lane(binding:row.id,option:nil,lane:LibraryMappingLane(points:[LibraryLanePoint(0,0.2),LibraryLanePoint(0.25,0.7),LibraryLanePoint(1,0.4)],stretches:[.ease,.straight])))
    try check(try await f.session.mappings(f.edit.handle).bindings[0].lane?.points.map(\.position)==[0,0.25,1],"P existing full-lane setter moves/deletes knots within admitted source waypoints")
    let prior=try await f.session.inspectEdit(f.edit.handle)
    do {
        try await f.map(.lane(binding:row.id,option:nil,lane:LibraryMappingLane(points:[LibraryLanePoint(0,0),LibraryLanePoint(0.37,0.7),LibraryLanePoint(1,1)],stretches:[.straight,.straight])))
        throw Failure(message:"unadmitted source knot accepted")
    } catch is Failure {throw Failure(message:"unadmitted source knot accepted")} catch {
        try check(try await f.session.inspectEdit(f.edit.handle)==prior,"P free unadmitted point-X remains typed refusal without partial edit")
    }
    let xy=id(811),xx=id(812),yy=id(813)
    try await f.map(.create(.xy(id:xy,title:"Position",initialX:0.2,initialY:0.8,xWaypoints:[0,0.2,1],yWaypoints:[0,0.8,1])))
    try await f.map(.connect(id:xx,source:LibraryMappingSource(xy,axis:.x),target:.setting(part:part,parameter:"gainDb")))
    try await f.map(.connect(id:yy,source:LibraryMappingSource(xy,axis:.y),target:.setting(part:part,parameter:"gainDb")))
    let current=try await f.session.mappings(f.edit.handle),xyControl=current.descriptors.first{$0.address.control==xy}!
    try check(xyControl.waypoints[.x]==[0,0.2,1] && xyControl.waypoints[.y]==[0,0.8,1] && xyControl.presentation?.title=="Position","P XY projection exposes independent authoritative axis waypoints/presentation")
    try check(current.bindings.first{$0.id==xx}?.sourceWaypoints==[0,0.2,1] && current.bindings.first{$0.id==yy}?.sourceWaypoints==[0,0.8,1],"P mapping rows preserve exact source axis identity")
    try await f.map(.connect(id:id(814),source:LibraryMappingSource(choice),target:.setting(part:part,parameter:"gainDb")))
    try await f.map(.differentForOptions(source:slider,selector:choice))
    let final=try await f.session.mappings(f.edit.handle)
    try check(final.bindings.first{$0.id==id(814)}?.sourceValues.keys.sorted{$0.uuidString<$1.uuidString} == [a,b,c],"P choice-source keyed values visible, not a made-up continuous lane")
    try check(final.bindings.first{$0.id==row.id}?.cases.count==3 && final.descriptors.first{$0.address.control==choice}?.presentation?.title=="Door","P selector cases and presentation exposed per stable option id")
    try await f.save()
    let fresh=try await SoundLibrarySession(persistence:RecordedStore(f.file),limits:f.limits)
    let freshEdit=try await fresh.beginEdit(.use(binding),admission:{_ in}),freshMap=try await fresh.mappings(freshEdit.handle)
    try check(freshMap.bindings==final.bindings,"P actual promoted lanes/choice tables/provenance survive fresh file owner")
}
