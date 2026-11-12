import Foundation
import SoundModel
import SessionStore

@MainActor func publicationCases(_ root:URL) async throws {
    for replacement in [a,c] {
        let f=try await Fixture(root.appendingPathComponent(replacement.uuidString))
        _=try await f.publish();let old=try await f.attach()
        try await f.session.move(choice,on:"test.options",to:.scalar(0.5))
        _=try await f.mutate(.remove(id:b,replacement:replacement));try await f.save();print("TRACE reopen");try await f.reopen();print("TRACE preview")
        let pre=try Data(contentsOf:f.file)
        let preview=try await f.session.previewUpdateLibrary(f.edit.handle,expectedGeneration:f.edit.generation,places:[LibraryUpdatePlace(use:old.use)])
        try check(preview.removals.first?.replacement==replacement && preview.choices.changes.contains{$0.before==b && $0.after==replacement && $0.reason == .explicitReplacement},"reopened original named replacement appears in A25 preview")
        await f.session.cancelUpdateLibrary(preview)
        try check(try Data(contentsOf:f.file)==pre,"Cancel leaves durable intent/file exact")
        let actual=try await f.publish([LibraryUpdatePlace(use:old.use)])
        let after=try await f.session.snapshot(),use=after.uses.first{$0.id==old.use}!
        try check(use.positions[choice] == .scalar(replacement==a ? 0:1),"old B use follows original replacement after real reopen/A25")
        try check(actual.old != actual.new,"A25 creates new immutable revision")
        _=try await f.session.checkpoint()
        let data=try Data(contentsOf:f.file),j=try JSONSerialization.jsonObject(with:data) as! [String:Any]
        try check([5,6].contains(j["schema"] as? Int ?? 0) && !String(decoding:data,as:UTF8.self).contains("optionRemovals"),"accepted capture retires intent once; no-intent archive retains normal schema5/6 selection")
    }
    let f=try await Fixture(root.appendingPathComponent("override"));_=try await f.publish();let target=try await f.attach()
    try await f.session.move(choice,on:"test.options",to:.scalar(0.5));try await f.hand(0.5)
    _=try await f.mutate(.remove(id:b,replacement:a))
    _=try await f.publish([LibraryUpdatePlace(use:target.use)],replacements:[LibraryOptionReplacement(address:address,removed:b,replacement:c)])
    let state=try await f.session.snapshot()
    try check(state.uses.first{$0.id==target.use}?.positions[choice] == .scalar(1) && f.edit.positions[address] == .scalar(0),"A25 override migrates old place but never remaps already-edited source twice")
    try await expectRefusal("published retired OptionID cannot be revived") {_=try await f.mutate(.add(id:b,title:"Revive retired",at:1))}
    f.edit=try await f.session.undoOptionEdit(f.edit.handle,expectedGeneration:f.edit.generation).snapshot
    let afterUndo=try await f.session.snapshot()
    try check(f.options()==[a,b,c] && f.edit.pendingStructural && state.definitions==afterUndo.definitions && state.uses==afterUndo.uses,"post-A25 Undo is local/unpublished; no head/place rollback")
    _=try await f.publish([LibraryUpdatePlace(use:target.use)])
}

@MainActor func heldPublicationCases(_ root:URL) async throws {
    for mode in 0...2 {
        let f=try await Fixture(root.appendingPathComponent("held-\(mode)"));_=try await f.publish();let target=try await f.attach()
        try await f.session.move(choice,on:"test.options",to:.scalar(0.5))
        _=try await f.mutate(.remove(id:b,replacement:a))
        let preview=try await f.session.previewUpdateLibrary(f.edit.handle,expectedGeneration:f.edit.generation,places:[LibraryUpdatePlace(use:target.use)])
        await f.port.arm(mode)
        let saving=Task{try await f.session.confirmUpdateLibrary(preview)};await f.port.wait()
        try await f.session.move(choice,on:"test.options",to:.scalar(1))
        _=try await f.session.setEnabled(false,expected:target)
        _=try await f.mutate(.add(id:d,title:"New",at:2))
        _=try await f.mutate(.remove(id:a,replacement:c))
        await f.port.release();let result=try await saving.value
        if mode==0 {
            try check(result.acceptedReport?.choices.changes.contains{$0.before==b} == false && result.acceptedReport?.carriedNewerState==true,"accepted report uses final newer C, not stale preview B")
            try check(try await f.session.takeUpdateReport(token:result.commit.token)==nil,"immediate accepted report is drained exactly once")
        }else if mode==1 {
            try check(result.acceptedReport==nil && !result.commit.outcome.isAccepted,"refusal has no accepted report")
        }else{
            try check(result.acceptedReport==nil,"uncertain write has no premature accepted report")
            try check(try await f.session.reconcile().isAccepted,"uncertain write reconciles actual file without replay")
            let report=try await f.session.takeUpdateReport(token:result.commit.token)
            try check(report != nil && report?.capturedDigest==result.commit.digest,"same-owner reconcile exposes actual report once")
            try check(try await f.session.takeUpdateReport(token:result.commit.token)==nil,"reconciled report is drained once")
        }
        try await f.refresh();try check(f.options()==[c,d],"held newer structural edit survives all outcomes")
        try await f.save();try await f.reopen()
        let data=try Data(contentsOf:f.file)
        try check(String(decoding:data,as:UTF8.self).contains("optionRemovals"),"held newer removal intent remains through actual checkpoint/reopen")
        let snap=try await f.session.snapshot()
        try check(snap.assignments.first{$0.id==target.assignment}?.isEnabled==false,"newer per-app OFF retained")
        _=try await f.publish([LibraryUpdatePlace(use:target.use)])
    }
}

@MainActor func nestedPublicationCases(_ root:URL) async throws {
    let f=try await Fixture(root),source=try await f.publish();let sourceEdit=f.edit
    _=try await f.session.createLinkedBlock(name:"Linked pair",children:[source.new,source.new],on:"test.pair")
    let state=try await f.session.snapshot(),assignment=state.assignments.first{$0.target=="test.pair"}!
    let expected=LibraryBinding(assignment:assignment.id,use:assignment.use,target:assignment.target)
    f.edit=try await f.session.beginEdit(.use(expected),admission:{_ in})
    let sites=f.edit.pieces.compactMap{piece -> UUID? in if case .reference(let site,_,_)=piece{return site};return nil},macro=id(200)
    try await f.map(.create(.slider(id:macro,title:"Parent",initial:0,waypoints:[0,0.5,1])))
    for (i,site) in sites.enumerated(){
        let link=id(201+i)
        try await f.map(.connect(id:link,source:LibraryMappingSource(macro),target:.control(site:site,control:choice,axis:.value)))
        try await f.map(.lane(binding:link,option:nil,lane:LibraryMappingLane(points:[LibraryLanePoint(0,0),LibraryLanePoint(0.5,0.5),LibraryLanePoint(1,1)],stretches:[.straight,.step])))
        try await f.session.move(LibraryControlAddress(path:[site],control:choice),on:"test.pair",to:.scalar(Double(i)/2))
    }
    _=try await f.publish([LibraryUpdatePlace(use:assignment.use)]);let parentEdit=f.edit
    f.edit=sourceEdit;try await f.refresh();_=try await f.mutate(.remove(id:b,replacement:c))
    let preview=try await f.session.previewUpdateLibrary(f.edit.handle,expectedGeneration:f.edit.generation,places:sites.map{LibraryUpdatePlace(use:assignment.use,path:[$0])})
    await f.port.arm(0);let task=Task{try await f.session.confirmUpdateLibrary(preview)};await f.port.wait()
    // A new parent patch must also rebase the old child-target endpoint provenance.
    var parent=try await f.session.edit(parentEdit.handle,expectedGeneration:parentEdit.generation,command:.mapping(path:[],.rename(control:macro,title:"Newer parent")))
    _=try await f.session.setEnabled(false,expected:expected);await f.port.release();let accepted=try await task.value
    try check(accepted.commit.outcome.isAccepted,"repeated-child option publication accepts held newer parent patch")
    parent=try await f.session.inspectEdit(parent.handle)
    let facts=try await f.session.mappings(parent.handle)
    try check(facts.controls.first{$0.address==LibraryControlAddress(path:[sites[0]],control:choice)}?.effective == .scalar(0) && facts.controls.first{$0.address==LibraryControlAddress(path:[sites[1]],control:choice)}?.effective == .scalar(1),"two repeated child hands independently remap/re-solve by occurrence")
    try check(facts.bindings.allSatisfy{$0.lane?.points.map(\.value)==[0,1,1]},"parent incoming lanes remap each old B anchor to C")
    parent=try await f.session.undoEdit(parent.handle,expectedGeneration:parent.generation)
    try check(parent.controls.first{$0.id==macro}?.title=="Parent","parent history remains valid against new child schemas/provenance")
    _=try await f.session.checkpoint()
    let fresh=try await SoundLibrarySession(persistence:LibrarySessionFile(url:f.file,maximumBytes:8_000_000),limits:f.limits)
    let reopened=try await fresh.beginEdit(.use(expected),admission:{_ in})
    try check(try await fresh.mappings(reopened.handle).controls==facts.controls,"repeated qualified hand state survives accepted checkpoint/fresh owner")
}

@MainActor func publicationCapacityCases(_ root:URL) async throws {
    let f=try await Fixture(root);_=try await f.publish()
    var plans:[LibraryUpdatePreview]=[]
    for _ in 0..<16 {plans.append(try await f.session.previewUpdateLibrary(f.edit.handle,expectedGeneration:f.edit.generation,places:[]))}
    try await expectRefusal("16-plan cache refuses rather than dropping old plans") {_=try await f.session.previewUpdateLibrary(f.edit.handle,expectedGeneration:f.edit.generation,places:[])}
    await f.session.cancelUpdateLibrary(plans.removeLast())
    let accepted=try await f.session.confirmUpdateLibrary(plans[0])
    try check(accepted.commit.outcome.isAccepted,"capacity refusal preserved original plan and fingerprint")
}

@MainActor func newerReplacementCases(_ root:URL) async throws {
    let f=try await Fixture(root);_=try await f.publish()
    let first=try await f.attach("test.first"),later=try await f.attach("test.later")
    for target in ["test.first","test.later"]{try await f.session.move(choice,on:target,to:.scalar(0.5))}
    _=try await f.mutate(.remove(id:b,replacement:a))
    let preview=try await f.session.previewUpdateLibrary(f.edit.handle,expectedGeneration:f.edit.generation,places:[LibraryUpdatePlace(use:first.use)])
    await f.port.arm(0);let task=Task{try await f.session.confirmUpdateLibrary(preview)};await f.port.wait()
    f.edit=try await f.session.undoOptionEdit(f.edit.handle,expectedGeneration:f.edit.generation).snapshot
    _=try await f.mutate(.remove(id:b,replacement:c))
    await f.port.release();_=try await task.value;try await f.refresh();try await f.save();try await f.reopen()
    let next=try await f.session.previewUpdateLibrary(f.edit.handle,expectedGeneration:f.edit.generation,places:[])
    try check(next.removals.contains{$0.removed==b && $0.replacement==c},"accepted capture retires ONLY original B→A, preserving newer same-ID B→C intent")
    await f.session.cancelUpdateLibrary(next)
    _=try await f.publish([LibraryUpdatePlace(use:later.use)])
    let state=try await f.session.snapshot()
    try check(state.uses.first{$0.id==first.use}?.positions[choice] == .scalar(0) && state.uses.first{$0.id==later.use}?.positions[choice] == .scalar(1),"later explicit old-schema migration follows newer relation without inverse of first published place")
}

@MainActor func retainedIntentConflictCases(_ root:URL) async throws {
    let f=try await Fixture(root);_=try await f.publish();let first=try await f.attach("test.conflict.first")
    f.edit=try await f.session.beginEdit(.use(first),admission:{_ in})
    _=try await f.mutate(.remove(id:b,replacement:a))
    let preview=try await f.session.previewUpdateLibrary(f.edit.handle,expectedGeneration:f.edit.generation,places:[LibraryUpdatePlace(use:first.use)])
    await f.port.arm(0);let saving=Task{try await f.session.confirmUpdateLibrary(preview)};await f.port.wait()
    f.edit=try await f.session.undoOptionEdit(f.edit.handle,expectedGeneration:f.edit.generation).snapshot
    _=try await f.mutate(.remove(id:b,replacement:c))
    await f.port.release();_=try await saving.value;try await f.refresh()
    let dirty=f.edit;let own=try await f.session.previewUpdateLibrary(dirty.handle,expectedGeneration:dirty.generation,places:[LibraryUpdatePlace(use:first.use)])
    try check(!dirty.pendingStructural && !own.removals.isEmpty,"other use retains distinct unpublished intent despite matching base sound content")
    await f.session.cancelUpdateLibrary(own)
    let other=try await f.attach("test.conflict.other");f.edit=try await f.session.beginEdit(.use(other),admission:{_ in})
    try await f.map(.create(.slider(id:id(950),title:"Unrelated new control",initial:0,waypoints:[0,1])))
    let before=try await f.session.snapshot(),bytes=try Data(contentsOf:f.file)
    try await expectRefusal("A24 protects other owner's retained removal intent, even with identical sound payload") {
        _=try await f.session.previewUpdateLibrary(f.edit.handle,expectedGeneration:f.edit.generation,places:[LibraryUpdatePlace(use:first.use),LibraryUpdatePlace(use:other.use)])
    }
    try check(try await f.session.snapshot()==before && Data(contentsOf:f.file)==bytes,"A24 refusal preserves other intent/state/file")
}
