import Foundation
import SoundModel
import SessionStore

@MainActor func mappingCases(_ root:URL) async throws {
    let f=try await Fixture(root.appendingPathComponent("source-selector")),sink=id(20),driver=id(21),sourceLink=id(22),selectorLink=id(23)
    try await f.map(.create(.slider(id:sink,title:"Sink",initial:0.5,waypoints:[0,0.5,1])))
    try await f.map(.create(.slider(id:driver,title:"Driver",initial:0,waypoints:[0,0.5,1])))
    try await f.map(.connect(id:sourceLink,source:LibraryMappingSource(choice),target:.control(site:nil,control:sink,axis:.value)))
    for (option,value) in [(a,0.2),(b,0.8),(c,0.4)] {try await f.map(.sourceValue(binding:sourceLink,selectorOption:nil,sourceOption:option,value:value))}
    try await f.map(.connectOptions(id:selectorLink,source:LibraryMappingSource(driver),target:.control(site:nil,control:sink,axis:.value),selector:choice))
    try await f.map(.lane(binding:selectorLink,option:b,lane:LibraryMappingLane(points:[LibraryLanePoint(0,0.1),LibraryLanePoint(0.5,0.9),LibraryLanePoint(1,0.4)],stretches:[.step,.ease])))
    try await f.map(.stretch(binding:selectorLink,option:b,index:0,shape:.step,jump:0.37))
    let before=try await f.facts();_=try await f.mutate(.add(id:d,title:"New",at:2));let after=try await f.facts()
    try check(after.bindings.first{$0.id==sourceLink}?.sourceValues[d]==0.8,"Add copies choice-source values by neighbor OptionID")
    try check(after.bindings.first{$0.id==selectorLink}?.cases[d]==before.bindings.first{$0.id==selectorLink}?.cases[b],"Add copies whole selector transfer")
    _=try await f.mutate(.remove(id:b,replacement:c));let removed=try await f.facts()
    try check(removed.bindings.first{$0.id==sourceLink}?.sourceValues[b]==nil && removed.bindings.first{$0.id==selectorLink}?.cases[b]==nil,"Remove drops only selected source entries/cases")
    try await f.save();try await f.reopen()
    let fresh=try await f.facts();try check(fresh.bindings==removed.bindings,"real reopen preserves exact copied transfers and binding provenance")

    let g=try await Fixture(root.appendingPathComponent("target-anchors")),slider=id(30),link=id(31)
    try await g.hand(0.5)
    try await g.map(.create(.slider(id:slider,title:"Travel",initial:0,waypoints:[0,0.25,0.5,1])))
    try await g.map(.connect(id:link,source:LibraryMappingSource(slider),target:.control(site:nil,control:choice,axis:.value)))
    try await g.map(.lane(binding:link,option:nil,lane:LibraryMappingLane(points:[LibraryLanePoint(0,0),LibraryLanePoint(0.25,0.499999999999),LibraryLanePoint(0.5,0.5),LibraryLanePoint(1,1)],stretches:[.step,.straight,.ease])))
    try await g.map(.stretch(binding:link,option:nil,index:0,shape:.step,jump:0.37))
    _=try await g.mutate(.add(id:d,title:"First",at:0));let binding=try await g.facts().bindings.first{$0.id==link}!
    try check(binding.reference==1.0/3 && binding.lane?.points.map(\.value)==[1.0/3,0.499999999999,2.0/3,1],"exact incoming anchors AND references follow IDs; adjacent nonanchor stays exact")
    try check(binding.lane?.points.map(\.position)==[0,0.25,0.5,1],"option edits add no hidden source waypoints")
    try await g.save()
    let bytes=try Data(contentsOf:g.file),text=String(decoding:bytes,as:UTF8.self)
    try check(text.contains("0.37"),"Step jump survives target anchor transform")

    let h=try await Fixture(root.appendingPathComponent("raw-sum")),x=id(40),y=id(41)
    for (source,link) in [(x,id(42)),(y,id(43))] {
        try await h.map(.create(.slider(id:source,title:"Driver",initial:0,waypoints:[0,1])))
        try await h.map(.connect(id:link,source:LibraryMappingSource(source),target:.control(site:nil,control:choice,axis:.value)))
        try await h.map(.lane(binding:link,option:nil,lane:LibraryMappingLane(points:[LibraryLanePoint(0,0),LibraryLanePoint(1,1)],stretches:[.straight])))
        try await h.hand(1,source)
    }
    try check(try await h.effective()==1,"two-driver raw sum saturates before hand")
    try await h.hand(0.5);var facts=try await h.facts()
    let handEffective=try await h.effective()
    try check(abs(facts.controls.first{$0.address==address}!.adjustments[.value]! + 1.5)<1e-14 && handEffective==0.5,"hand action solves desired anchor minus RAW sum, not quantized output")
    _=try await h.mutate(.add(id:d,title:"First",at:0));facts=try await h.facts()
    try check((try await h.effective())==2.0/3 && abs(facts.controls.first{$0.address==address}!.adjustments[.value]! + 1)<1e-14,"option change re-solves saturated two-driver hand in dependency order")

    let z=try await Fixture(root.appendingPathComponent("zero-hand")),zdriver=id(50),zlink=id(51)
    try await z.map(.create(.slider(id:zdriver,title:"Drive",initial:0,waypoints:[0,0.5,1])))
    try await z.map(.connect(id:zlink,source:LibraryMappingSource(zdriver),target:.control(site:nil,control:choice,axis:.value)))
    try await z.map(.lane(binding:zlink,option:nil,lane:LibraryMappingLane(points:[LibraryLanePoint(0,0),LibraryLanePoint(0.5,0.6),LibraryLanePoint(1,1)],stretches:[.straight,.straight])))
    let downstream=id(52),downlink=id(53),e=id(54),ff=id(55),gg=id(56)
    try await z.map(.create(.choice(id:downstream,title:"Downstream",options:[LibraryOption(id:e,title:"E",position:0),LibraryOption(id:ff,title:"F",position:0.5),LibraryOption(id:gg,title:"G",position:1)],initial:e)))
    try await z.map(.connect(id:downlink,source:LibraryMappingSource(choice),target:.control(site:nil,control:downstream,axis:.value)))
    for (option,value) in [(a,0.0),(b,0.5),(c,1.0)]{try await z.map(.sourceValue(binding:downlink,selectorOption:nil,sourceOption:option,value:value))}
    try await z.hand(0.5,zdriver)
    let redistributed=try await z.mutate(.add(id:d,title:"New",at:3))
    let absentAdjustments=try await z.facts().controls.first{$0.address==address}!.adjustments
    try check(redistributed.report.changes.contains{$0.address==address && $0.before==b && $0.after==c && $0.reason == .redistribution} && absentAdjustments.isEmpty,"historical absent hand record gets no invented compensation")
    try check(redistributed.report.changes.contains{$0.address.control==downstream && $0.before==ff && $0.after==gg && $0.reason == .redistribution},"report includes downstream effective choice redistribution")
    let undoRedistribution=try await z.session.undoOptionEdit(z.edit.handle,expectedGeneration:z.edit.generation);z.edit=undoRedistribution.snapshot
    try check(undoRedistribution.report.changes.contains{$0.address==address && $0.before==c && $0.after==b && $0.reason == .redistribution},"D2 Undo raw-sum C→B is redistribution, not explicit replacement")
    try check(undoRedistribution.report.changes.contains{$0.address.control==downstream && $0.before==gg && $0.after==ff && $0.reason == .redistribution},"D2 Undo downstream G→F remains redistribution")
    let redoRedistribution=try await z.session.redoOptionEdit(z.edit.handle,expectedGeneration:z.edit.generation);z.edit=redoRedistribution.snapshot
    try check(redoRedistribution.report.changes.contains{$0.address==address && $0.before==b && $0.after==c && $0.reason == .redistribution},"D2 Redo raw-sum B→C remains redistribution")
    try check(redoRedistribution.report.changes.contains{$0.address.control==downstream && $0.before==ff && $0.after==gg && $0.reason == .redistribution},"D2 Redo downstream F→G remains redistribution")
    z.edit=try await z.session.undoOptionEdit(z.edit.handle,expectedGeneration:z.edit.generation).snapshot
    try await z.hand(0,zdriver);try await z.hand(0)
    try check(try await z.facts().controls.first{$0.address==address}?.adjustments[.value]==0,"actual same-value hand retains zero intent")
    _=try await z.mutate(.add(id:d,title:"First",at:0))
    try check(try await z.effective()==1.0/3,"actual zero hand stays same OptionID after anchor redistribution")
    try await z.save();try await z.reopen()
    try check(try await z.facts().controls.first{$0.address==address}?.adjustments[.value] != nil,"zero hand survives real checkpoint/reopen")
    let explicit=try await Fixture(root.appendingPathComponent("explicit-history"))
    try await explicit.hand(0.5)
    let removal=try await explicit.mutate(.remove(id:b,replacement:a))
    try check(removal.report.changes.contains{$0.before==b && $0.after==a && $0.reason == .explicitReplacement},"D2 actual Remove B→A is explicit")
    let undoRemoval=try await explicit.session.undoOptionEdit(explicit.edit.handle,expectedGeneration:explicit.edit.generation);explicit.edit=undoRemoval.snapshot
    try check(undoRemoval.report.changes.contains{$0.before==a && $0.after==b && $0.reason == .explicitReplacement},"D2 actual Undo Remove A→B is explicit inverse")
    let redoRemoval=try await explicit.session.redoOptionEdit(explicit.edit.handle,expectedGeneration:explicit.edit.generation);explicit.edit=redoRemoval.snapshot
    try check(redoRemoval.report.changes.contains{$0.before==b && $0.after==a && $0.reason == .explicitReplacement},"D2 actual Redo Remove B→A remains explicit")
}

@MainActor func legacyAndBrokenCases(_ root:URL) async throws {
    let f=try await Fixture(root)
    f.edit=try await f.session.edit(f.edit.handle,expectedGeneration:f.edit.generation,command:.addPart(type:"gain",at:0))
    let part=f.edit.parts[0].id
    try await f.map(.connectLegacy(source:LibraryMappingSource(choice),part:part,parameter:"gainDb"))
    let original=f.edit.parts[0].settings[0].base
    _=try await f.mutate(.add(id:d,title:"Middle",at:1))
    let values=try await f.facts().bindings[0].sourceValues
    try check(Set(values.keys)==Set([a,b,c,d]) && values.values.allSatisfy{$0==original},"legacy choice source promotes at OLD anchors before option-count change")
    let sink=id(900),link=id(901)
    try await f.map(.create(.slider(id:sink,title:"Retire target",initial:0,waypoints:[0,1])))
    try await f.map(.connect(id:link,source:LibraryMappingSource(choice),target:.control(site:nil,control:sink,axis:.value)))
    try await f.map(.removeControl(sink))
    let before=try await f.facts().bindings.first{$0.id==link}!
    try check(before.broken == .targetRemoved,"real public removal retains broken provenance")
    _=try await f.mutate(.remove(id:b,replacement:c))
    let after=try await f.facts().bindings.first{$0.id==link}!
    try check(after.broken == .targetRemoved && after.sourceValues[b]==nil && after.sourceValues[d]==0,"option edit updates broken coverage/provenance without auto-repair")
    try await f.save();try await f.reopen()
    try check(try await f.facts().bindings.first{$0.id==link}==after,"broken remapped binding survives strict file reopen")
}
