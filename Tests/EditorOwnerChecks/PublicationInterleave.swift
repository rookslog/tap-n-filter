import Foundation
import SoundModel
import SessionStore

@MainActor func publicationOpeningRegression(_ directory:URL,mode:String)async throws {
            let f=try await Fixture(URL(fileURLWithPath:directory.path));_=try await f.publish()
            let source=try await f.attach("test.source"),other=try await f.attach("test.other")
            f.edit=try await f.session.beginEdit(.use(source),admission:{_ in})
            try await f.session.move(choice,on:"test.other",to:.scalar(0.5))
            _=try await f.mutate(.remove(id:b,replacement:a))
            let preview=try await f.session.previewUpdateLibrary(f.edit.handle,expectedGeneration:f.edit.generation,places:[LibraryUpdatePlace(use:source.use),LibraryUpdatePlace(use:other.use)])
            await f.port.arm(0)
            let write=Task{try await f.session.confirmUpdateLibrary(preview)}
            await f.port.wait()
            _=try await f.session.move(address,expected:other,to:.scalar(1))
            _=try await f.session.setEnabled(false,expected:other)
            if mode=="open" {
                let edit=try await f.session.beginEdit(.use(other),admission:{_ in})
                print("TRACE target opened before completion positions=\(edit.positions)")
                _=try await f.session.doneEdit(edit.handle,expectedGeneration:edit.generation)
            }
            print("TRACE pre-release other positions=\((try await f.session.snapshot()).uses.first{$0.id==other.use}!.positions)")
            await f.port.release();let result=try await write.value,state=try await f.session.snapshot()
            let actual=state.uses.first{$0.id==other.use}!.positions[choice]
            print("TRACE accepted=\(result.commit.outcome.isAccepted) other expected=C/1 actual=\(String(describing:actual)) OFF=\(state.assignments.first{$0.id==other.assignment}!.isEnabled)")
            try check(result.commit.outcome.isAccepted && actual == .scalar(1),"A25-OPEN-01: newer C survives opening/closing target during held A25")
}

@MainActor func ownerPublicationCases(_ root:URL)async throws {
    try await publicationOpeningRegression(root.appendingPathComponent("open"),mode:"open")
    try await publicationOpeningRegression(root.appendingPathComponent("control"),mode:"control")
    try await publicationNestedName(root.appendingPathComponent("late-nested-name"))
    try await publicationLateValue(root.appendingPathComponent("late-value-kept"),removePart:false)
    try await publicationLateValue(root.appendingPathComponent("late-value-removed"),removePart:true)
    for mode in 0...2 {
        for action in ["none","open","done","switch","rename","structure","removal","removed"] {
            try await publicationInterleave(root.appendingPathComponent("m\(mode)-\(action)"),mode:mode,action:action)
        }
    }
}

@MainActor func publicationInterleave(_ directory:URL,mode:Int,action:String)async throws {
    let f=try await Fixture(directory);_=try await f.publish()
    let source=try await f.attach("test.source"),other=try await f.attach("test.other"),unrelated=try await f.attach("test.unrelated")
    f.edit=try await f.session.beginEdit(.use(source),admission:{_ in})
    try await f.session.move(choice,on:"test.other",to:.scalar(0.5))
    try await f.session.move(choice,on:"test.unrelated",to:.scalar(0.5))
    _=try await f.mutate(.remove(id:b,replacement:a))
    let places=[LibraryUpdatePlace(use:source.use),LibraryUpdatePlace(use:other.use)]
    let cancelled=try await f.session.previewUpdateLibrary(f.edit.handle,expectedGeneration:f.edit.generation,places:places)
    let beforeCancel=try await f.session.snapshot(),fileBefore=try Data(contentsOf:f.file)
    await f.session.cancelUpdateLibrary(cancelled)
    try check(beforeCancel == (try await f.session.snapshot()) && fileBefore == (try Data(contentsOf:f.file)),"A25 Cancel preserves actual state/file \(mode) \(action)")
    let preview=try await f.session.previewUpdateLibrary(f.edit.handle,expectedGeneration:f.edit.generation,places:places)
    await f.port.arm(mode)
    let write=Task{try await f.session.confirmUpdateLibrary(preview)};await f.port.wait()
    _=try await f.session.move(address,expected:other,to:.scalar(action=="removed" ? 0.5:1))
    _=try await f.session.setEnabled(false,expected:other)
    await f.session.setEnabled(false);await f.session.compareOriginal(true)
    var local:LibraryEditSnapshot?
    if action != "none" {
        var e=try await f.session.beginEdit(.use(other),admission:{_ in})
        if action == "rename" {e=try await f.session.edit(e.handle,expectedGeneration:e.generation,command:.mapping(path:[],.rename(control:choice,title:"Local Door")))}
        if action == "structure" {e=try await f.session.edit(e.handle,expectedGeneration:e.generation,command:.mapping(path:[],.create(.slider(id:id(801),title:"New local",initial:0.3,waypoints:[0,1]))))}
        if action == "removal" {
            let p=try await f.session.previewOptionEdit(e.handle,expectedGeneration:e.generation,address:address,mutation:.remove(id:c,replacement:b))
            e=try await f.session.applyOptionEdit(p).snapshot
        }
        local=e
        if action == "done" {_=try await f.session.doneEdit(e.handle,expectedGeneration:e.generation)}
        if action == "switch" {_=try await f.session.beginEdit(.definition(f.definition),admission:{_ in})}
    }
    let live=try await f.session.snapshot()
    await f.port.release();let result=try await write.value
    if mode==2 {
        try check(!result.commit.outcome.isAccepted && result.acceptedReport==nil,"A25 uncertain is not accepted \(action)")
        try check((try await f.session.takeUpdateReport(token:result.commit.token))==nil,"A25 no premature report \(action)")
        try check((try await f.session.reconcile()).isAccepted,"A25 unknown-after exact-byte readback accepted \(action)")
    }
    let accepted=mode != 1
    let report=mode==2 ? try await f.session.takeUpdateReport(token:result.commit.token):result.acceptedReport
    if accepted {
        try check(report?.token==result.commit.token && report?.capturedDigest==result.commit.digest && report?.carriedNewerState==true,"A25 actual report token/digest/newer state \(mode) \(action)")
        try check((try await f.session.takeUpdateReport(token:result.commit.token))==nil,"A25 report consumed once \(mode) \(action)")
    }else{
        try check(!result.commit.outcome.isAccepted && report==nil,"A25 refusal has no accepted report \(action)")
        let refused=try await f.session.snapshot()
        try check(live.isEnabled==refused.isEnabled && live.compareOriginal==refused.compareOriginal && live.definitions==refused.definitions && live.uses==refused.uses && live.assignments==refused.assignments && !refused.writing && !refused.unresolved && refused.pendingCommit==nil && fileBefore == (try Data(contentsOf:f.file)),"A25 refusal clears only writer status; live content/edits/file untouched \(action)")
    }
    let state=try await f.session.snapshot()
    let value=state.uses.first{$0.id==other.use}!.positions[choice]
    let expected:LibraryPosition = action=="removed" ? .scalar(accepted ? 0:0.5):.scalar(1)
    try check(value == expected && !state.isEnabled && state.compareOriginal && state.assignments.first{$0.id==other.assignment}?.isEnabled==false,"A25 latest C or explicit local B/OFF/master/compare retained \(mode) \(action)")
    try check(state.uses.first{$0.id==unrelated.use}==live.uses.first{$0.id==unrelated.use} && state.assignments.first{$0.id==unrelated.assignment}==live.assignments.first{$0.id==unrelated.assignment},"A25 unrelated exact reference/position unchanged \(mode) \(action)")
    if accepted {
        let captured=try await SoundLibrarySession(persistence:LibrarySessionFile(url:f.file,maximumBytes:8_000_000),limits:f.limits)
        try check((try await captured.snapshot()).uses.first{$0.id==other.use}?.positions[choice] == .scalar(0),"A25 captured file is not falsely claimed newer-live durable \(mode) \(action)")
        if !["structure","removal"].contains(action) {
            let e:LibraryEditSnapshot
            if let held=local, action != "done" && action != "switch" {e=try await f.session.inspectEdit(held.handle)}
            else {e=try await f.session.beginEdit(.use(other),admission:{_ in})}
            guard case .choice(let options)=e.controls.first(where:{$0.id==choice})!.face else{throw Failure(message:"choice missing")}
            try check(options.map(\.id)==[a,c],"A25 unchanged or nonstructural target uses actual accepted AC schema \(mode) \(action)")
            if local != nil { local=e }
        }
    }
    if let local, ["rename","structure","removal"].contains(action) {
        var e=try await f.session.inspectEdit(local.handle)
        if action=="rename" {try check(e.controls.first{$0.id==choice}?.title=="Local Door","A25 newer local name survives")}
        if action=="structure" {try check(e.controls.contains{$0.id==id(801)} && e.pendingStructural,"A25 newer structural slider survives")}
        if action=="removal" {guard case .choice(let options)=e.controls.first(where:{$0.id==choice})!.face else{throw Failure(message:"choice missing")};try check(options.map(\.id)==[a,b] && e.pendingStructural,"A25 newer option removal intent survives")}
        e=try await f.session.undoOptionEdit(e.handle,expectedGeneration:e.generation).snapshot
        if action=="rename" {try check(e.controls.first{$0.id==choice}?.title=="Door","A25 local Undo keeps accepted library content")}
        if action=="structure" {try check(!e.controls.contains{$0.id==id(801)},"A25 structural Undo survives")}
        if action=="removal" {guard case .choice(let options)=e.controls.first(where:{$0.id==choice})!.face else{throw Failure(message:"choice missing")};try check(options.map(\.id)==[a,b,c],"A25 option Undo restores exact old schema")}
        e=try await f.session.redoOptionEdit(e.handle,expectedGeneration:e.generation).snapshot
        if action=="rename" {try check(e.controls.first{$0.id==choice}?.title=="Local Door","A25 local Redo survives")}
        if action=="structure" {try check(e.controls.contains{$0.id==id(801)},"A25 structural Redo survives")}
        if action=="removal" {guard case .choice(let options)=e.controls.first(where:{$0.id==choice})!.face else{throw Failure(message:"choice missing")};try check(options.map(\.id)==[a,b],"A25 removal Redo survives")}
    }
    await f.session.compareOriginal(false)
    let commit=try await f.session.checkpoint();try check(commit.outcome.isAccepted,"A25 later checkpoint accepted \(mode) \(action)")
    let fresh=try await SoundLibrarySession(persistence:LibrarySessionFile(url:f.file,maximumBytes:8_000_000),limits:f.limits),saved=try await fresh.snapshot(),final=try await f.session.snapshot()
    try check(saved==final,"A25 actual checkpoint/fresh facade retains full state \(mode) \(action)")
    if ["rename","structure","removal"].contains(action) {
        let e=try await fresh.beginEdit(.use(other),admission:{_ in})
        if action=="rename" {try check(e.controls.first{$0.id==choice}?.title=="Local Door","A25 reopened newer name")}
        if action=="structure" {try check(e.controls.contains{$0.id==id(801)},"A25 reopened newer structure")}
        if action=="removal" {guard case .choice(let options)=e.controls.first(where:{$0.id==choice})!.face else{throw Failure(message:"choice missing")};try check(options.map(\.id)==[a,b],"A25 reopened newer option removal")}
    }
}

@MainActor func publicationLateValue(_ directory:URL,removePart:Bool)async throws {
    let f=try await Fixture(directory)
    f.edit=try await f.session.edit(f.edit.handle,expectedGeneration:f.edit.generation,command:.addPart(type:"gain",at:0))
    _=try await f.publish()
    let source=try await f.attach("test.source"),other=try await f.attach("test.other")
    f.edit=try await f.session.beginEdit(.use(source),admission:{_ in})
    let part=f.edit.parts[0].id
    if removePart {f.edit=try await f.session.edit(f.edit.handle,expectedGeneration:f.edit.generation,command:.removePart(part))}
    else {_=try await f.mutate(.remove(id:b,replacement:a))}
    let p=try await f.session.previewUpdateLibrary(f.edit.handle,expectedGeneration:f.edit.generation,places:[LibraryUpdatePlace(use:source.use),LibraryUpdatePlace(use:other.use)])
    await f.port.arm(0);let write=Task{try await f.session.confirmUpdateLibrary(p)};await f.port.wait()
    var e=try await f.session.beginEdit(.use(other),admission:{_ in})
    let parameter=e.parts[0].settings[0].parameter
    let value=try e.parts[0].settings[0].specification.physical(0.25)
    e=try await f.session.edit(e.handle,expectedGeneration:e.generation,command:.setPhysical(part:part,parameter:parameter,value:value))
    let local=e.parts.first{$0.id==part}!.settings.first{$0.parameter==parameter}!
    await f.port.release();let result=try await write.value
    try check(result.commit.outcome.isAccepted,"A25 newer physical value does not refuse after file accepted \(removePart)")
    e=try await f.session.inspectEdit(e.handle)
    let after=e.parts.first{$0.id==part}?.settings.first{$0.parameter==parameter}
    try check(after?.physicalValue==local.physicalValue && after?.adjustment==local.adjustment,"A25 newer physical value survives retained/removed published target \(removePart)")
    if removePart {try check(e.pendingStructural,"A25 conflicting late value stays explicit local draft, not silent loss")}
    e=try await f.session.undoOptionEdit(e.handle,expectedGeneration:e.generation).snapshot
    if removePart {try check(!e.parts.contains{$0.id==part},"A25 Undo of late value reaches accepted no-part payload")}
    e=try await f.session.redoOptionEdit(e.handle,expectedGeneration:e.generation).snapshot
    try check(e.parts.first{$0.id==part}?.settings.first{$0.parameter==parameter}?.physicalValue==local.physicalValue,"A25 Redo restores actual late value \(removePart)")
    _=try await f.session.checkpoint()
    let fresh=try await SoundLibrarySession(persistence:LibrarySessionFile(url:f.file,maximumBytes:8_000_000),limits:f.limits)
    e=try await fresh.beginEdit(.use(other),admission:{_ in})
    try check(e.parts.first{$0.id==part}?.settings.first{$0.parameter==parameter}?.physicalValue==local.physicalValue,"A25 late physical value survives actual fresh reopen \(removePart)")
}

@MainActor func publicationNestedName(_ directory:URL)async throws {
    let f=try await Fixture(directory);let child=try await f.publish().new
    _=try await f.session.createLinkedBlock(name:"Parent",children:[child],on:"test.source")
    var state=try await f.session.snapshot();let first=state.assignments.first{$0.target=="test.source"}!
    let source=LibraryBinding(assignment:first.id,use:first.use,target:first.target)
    f.edit=try await f.session.beginEdit(.use(source),admission:{_ in})
    guard case .reference(let site,_,_)=f.edit.pieces[0] else{throw Failure(message:"parent reference missing")}
    try await f.map(.makeLocal(path:[site]))
    _=try await f.publish([LibraryUpdatePlace(use:source.use)])
    state=try await f.session.snapshot();let parent=state.uses.first{$0.id==source.use}!.definition
    _=try await f.session.select(parent,on:"test.other")
    let bound=try await f.session.snapshot().assignments.first{$0.target=="test.other"}!
    let other=LibraryBinding(assignment:bound.id,use:bound.use,target:bound.target)
    f.edit=try await f.session.beginEdit(.use(source),admission:{_ in})
    _=try await f.mutate(.remove(id:b,replacement:a),at:LibraryControlAddress(path:[site],control:choice))
    let p=try await f.session.previewUpdateLibrary(f.edit.handle,expectedGeneration:f.edit.generation,places:[LibraryUpdatePlace(use:source.use),LibraryUpdatePlace(use:other.use)])
    await f.port.arm(0);let write=Task{try await f.session.confirmUpdateLibrary(p)};await f.port.wait()
    var e=try await f.session.beginEdit(.use(other),admission:{_ in})
    e=try await f.session.edit(e.handle,expectedGeneration:e.generation,command:.mapping(path:[site],.rename(control:choice,title:"Nested local")))
    await f.port.release();let result=try await write.value
    try check(result.commit.outcome.isAccepted,"A25 nested late name accepted without extra owner")
    func title(_ session:SoundLibrarySession,_ handle:LibraryEditHandle)async throws->String? {
        try await session.mappings(handle).descriptors.first{$0.address==LibraryControlAddress(path:[site],control:choice)}?.presentation?.title
    }
    try check(try await title(f.session,e.handle)=="Nested local","A25 nested newer presentation is not silently lost")
    e=try await f.session.inspectEdit(e.handle)
    e=try await f.session.undoOptionEdit(e.handle,expectedGeneration:e.generation).snapshot
    try check(try await title(f.session,e.handle)=="Door","A25 nested late name Undo retained")
    e=try await f.session.redoOptionEdit(e.handle,expectedGeneration:e.generation).snapshot
    try check(try await title(f.session,e.handle)=="Nested local","A25 nested late name Redo retained")
    _=try await f.session.checkpoint()
    let fresh=try await SoundLibrarySession(persistence:LibrarySessionFile(url:f.file,maximumBytes:8_000_000),limits:f.limits)
    e=try await fresh.beginEdit(.use(other),admission:{_ in})
    try check(try await title(fresh,e.handle)=="Nested local","A25 nested late presentation fresh file owner")
}
