import Foundation
import SoundModel
import SessionStore

@MainActor func expectRefusal(_ name:String,_ call:() async throws -> Void) async throws {
    do{try await call();throw Failure(message:"expected refusal: "+name)}catch let error as Failure{throw error}catch{print("PASS \(name) refused: \(error)")}
}
@MainActor func persistenceCases(_ root:URL) async throws {
    let f=try await Fixture(root.appendingPathComponent("compose"));_=try await f.mutate(.add(id:d,title:"Fourth",at:3));_=try await f.publish()
    let target=try await f.attach();try await f.session.move(choice,on:"test.options",to:.scalar(1.0/3))
    _=try await f.mutate(.remove(id:b,replacement:a));_=try await f.mutate(.remove(id:a,replacement:c));try await f.save();try await f.reopen()
    let pre=try await f.session.previewUpdateLibrary(f.edit.handle,expectedGeneration:f.edit.generation,places:[LibraryUpdatePlace(use:target.use)])
    try check(pre.removals.contains{$0.removed==b && $0.replacement==c},"B→A then A→C durably composes B→C")
    let published=try await f.session.confirmUpdateLibrary(pre)
    let composed=try await f.session.snapshot()
    try check(published.commit.outcome.isAccepted && composed.uses.first{$0.id==target.use}?.positions[choice] == .scalar(0),"composed replacement reaches old B use through real A25")

    let u=try await Fixture(root.appendingPathComponent("undo-intent"));_=try await u.publish();_=try await u.mutate(.remove(id:b,replacement:a))
    u.edit=try await u.session.undoOptionEdit(u.edit.handle,expectedGeneration:u.edit.generation).snapshot;try await u.save()
    let undoBytes=try Data(contentsOf:u.file)
    try check(!String(decoding:undoBytes,as:UTF8.self).contains("optionRemovals"),"Undo checkpoint clears intent envelope")
    u.edit=try await u.session.redoOptionEdit(u.edit.handle,expectedGeneration:u.edit.generation).snapshot;try await u.save();try await u.reopen()
    let redoBytes=try Data(contentsOf:u.file)
    try check(String(decoding:redoBytes,as:UTF8.self).contains("optionRemovals"),"Redo checkpoint/fresh reopen restores original intent")
    u.edit=try await u.session.discardEdit(u.edit.handle,expectedGeneration:u.edit.generation);try await u.save()
    try check(u.options()==[a,c] && String(decoding:Data(contentsOf:u.file),as:UTF8.self).contains("optionRemovals"),"Discard retains checkpointed removal and its saved intent")

    let m=try await Fixture(root.appendingPathComponent("missing"));_=try await m.publish();let binding=try await m.attach()
    _=try await m.mutate(.remove(id:b,replacement:a));try await m.save()
    let saved=try Data(contentsOf:m.file)
    // Explicit boundary injection only: readable schema5 draft with its relation missing.
    var json=try JSONSerialization.jsonObject(with:saved) as! [String:Any]
    var workspaces=json["workspaces"] as! [[String:Any]];workspaces[0]["optionRemovals"]=nil;json["workspaces"]=workspaces;json["schema"]=5
    let missing=root.appendingPathComponent("missing-relation.json");try JSONSerialization.data(withJSONObject:json,options:[.sortedKeys]).write(to:missing)
    let reader=try await SoundLibrarySession(persistence:LibrarySessionFile(url:missing,maximumBytes:8_000_000),limits:m.limits)
    let edit=try await reader.beginEdit(.definition(m.definition),admission:{_ in})
    do{_=try await reader.previewUpdateLibrary(edit.handle,expectedGeneration:edit.generation,places:[LibraryUpdatePlace(use:binding.use)]);throw Failure(message:"missing relation guessed")}
    catch LibraryOptionError.replacementRequired(let exact,let removed){try check(exact==address && removed==b,"readable missing relation returns qualified replacementRequired")}
    // Explicit corruption injection: unknown wire field in a semantic intent record.
    var corrupt=try JSONSerialization.jsonObject(with:saved) as! [String:Any];var ws=corrupt["workspaces"] as! [[String:Any]]
    var removals=ws[0]["optionRemovals"] as! [[String:Any]];removals[0]["guess"]=true;ws[0]["optionRemovals"]=removals;corrupt["workspaces"]=ws
    let bad=root.appendingPathComponent("corrupt.json");try JSONSerialization.data(withJSONObject:corrupt).write(to:bad)
    try await expectRefusal("malformed global intent wire") {_ = try await SoundLibrarySession(persistence:LibrarySessionFile(url:bad,maximumBytes:8_000_000),limits:m.limits)}

    var payloads:[Data]=[]
    for (index,replacement) in [a,c].enumerated() {
        let pair=try await Fixture(root.appendingPathComponent("pair-\(index)"));_=try await pair.publish();_=try await pair.mutate(.remove(id:b,replacement:replacement));try await pair.save()
        let obj=try JSONSerialization.jsonObject(with:Data(contentsOf:pair.file)) as! [String:Any],ws=obj["workspaces"] as! [[String:Any]]
        payloads.append(try JSONSerialization.data(withJSONObject:ws[0]["payload"]!,options:[.sortedKeys]))
    }
    try check(payloads[0]==payloads[1],"counterexample pair B→A/B→C has IDENTICAL sound payload bytes, distinct durable intent")
    try await discardSavedCases(root.appendingPathComponent("discard-correction"))
}

@MainActor func boundsAndHistoryCases(_ root:URL) async throws {
    let f=try await Fixture(root.appendingPathComponent("bounds")),before=try await f.session.snapshot(),edit=f.edit,writes=await f.port.submitted.count
    for mutation in [LibraryOptionMutation.add(id:a,title:"Duplicate",at:1),.add(id:d,title:"",at:1),.add(id:d,title:"New",at:-1),.add(id:d,title:"New",at:4),.remove(id:d,replacement:a),.remove(id:b,replacement:b),.remove(id:b,replacement:d)] {
        try await expectRefusal("invalid semantic mutation atomic") { _=try await f.mutate(mutation) }
    }
    try await expectRefusal("unknown qualified choice") {_=try await f.mutate(.add(id:d,title:"New",at:1),at:LibraryControlAddress(path:[id(999)],control:choice))}
    try await expectRefusal("malformed nonfinite choice input") {try await f.map(.create(.choice(id:id(998),title:"Bad",options:[LibraryOption(id:a,title:"A",position:Double.nan),LibraryOption(id:b,title:"B",position:1)],initial:a)))}
    let after=try await f.session.snapshot(),afterEdit=try await f.session.inspectEdit(edit.handle),afterWrites=await f.port.submitted.count
    try check(before==after && edit==afterEdit && writes==afterWrites,"all refused mutations preserve owner/history/generation/file")
    _=try await f.mutate(.remove(id:b,replacement:a))
    try await expectRefusal("minimum two options") {_=try await f.mutate(.remove(id:a,replacement:c))}
    try await expectRefusal("retired ID cannot be revived") {_=try await f.mutate(.add(id:b,title:"Revive",at:1))}
    let maximum=try await Fixture(root.appendingPathComponent("max"))
    try await maximum.map(.removeControl(choice))
    let options=(0..<64).map{LibraryOption(id:id(100+$0),title:"Option \($0)",position:Double($0)/63)}
    try await maximum.map(.create(.choice(id:choice,title:"Many",options:options,initial:options[0].id)))
    try await expectRefusal("maximum64 options") {_=try await maximum.mutate(.add(id:d,title:"65",at:64))}

    let h=try await Fixture(root.appendingPathComponent("later-listening")),binding=try await h.startUse()
    _=try await h.mutate(.add(id:d,title:"New",at:1));try await h.session.move(choice,on:"test.options",to:.scalar(1.0/3))
    let inverse=try await h.session.undoOptionEdit(h.edit.handle,expectedGeneration:h.edit.generation);h.edit=inverse.snapshot
    try check(inverse.report.changes.contains{$0.address==address && $0.before==d && $0.after==a && $0.reason == .explicitReplacement},"reporting Undo names its exact inverse replacement")
    let laterNew=try await h.session.snapshot()
    try check(h.options()==[a,b,c] && laterNew.uses.first{$0.id==binding.use}?.positions[choice] == .scalar(0),"Undo Add maps later selected New to captured copy neighbor")
    _=try await h.mutate(.remove(id:a,replacement:c));try await h.session.move(choice,on:"test.options",to:.scalar(0))
    h.edit=try await h.session.undoOptionEdit(h.edit.handle,expectedGeneration:h.edit.generation).snapshot
    try check((try await h.session.snapshot()).uses.first{$0.id==binding.use}?.positions[choice] == .scalar(0.5),"Undo Remove translates later retained B from0 to restored0.5 by OptionID")
    let preview=try await h.session.previewOptionEdit(h.edit.handle,expectedGeneration:h.edit.generation,address:address,mutation:.add(id:d,title:"New",at:0))
    let generation=h.edit.generation;try await h.session.move(choice,on:"test.options",to:.scalar(1))
    try check(try await h.session.inspectEdit(h.edit.handle).generation==generation,"ordinary listening does not change structural generation")
    try await expectRefusal("listening-only stale preview") {_=try await h.session.applyOptionEdit(preview)}
    h.edit=try await h.session.beginEditGesture(h.edit.handle,expectedGeneration:h.edit.generation)
    try await expectRefusal("option mutation during active gesture") {_=try await h.mutate(.add(id:d,title:"New",at:1))}
    h.edit=try await h.session.cancelEditGesture(h.edit.handle,expectedGeneration:h.edit.generation)
}

@MainActor func dormantCases(_ root:URL) async throws {
    let f=try await Fixture(root)
    try await f.hand(0.5)
    try await f.map(.removeControl(choice))
    // Public recreation leaves the historical retired record dormant; no byte-injected success fixture.
    try await f.map(.create(.choice(id:choice,title:"Door",options:[LibraryOption(id:a,title:"A",position:0),LibraryOption(id:b,title:"B",position:0.5),LibraryOption(id:c,title:"C",position:1)],initial:a)))
    _=try await f.mutate(.remove(id:b,replacement:c));try await f.save()
    let json=try JSONSerialization.jsonObject(with:Data(contentsOf:f.file)) as! [String:Any],ws=json["workspaces"] as! [[String:Any]],positions=ws[0]["positions"] as! [[String:Any]]
    let retired=positions.first{$0["dormant"] as? Bool==true}!
    try check((retired["id"] as? [String:Any])?["rawValue"] as? String==choice.uuidString && ((retired["value"] as? [String:Any])?["scalar"] as? [String:Any])?["_0"] as? Double == 1,"publicly retired dormant B follows explicit replacement without activation")
    try await f.reopen();try check(try await f.effective()==0,"fresh owner keeps dormant replacement separate from active A/default")
}

@MainActor func historyCapacityCases(_ root:URL) async throws {
    let f=try await Fixture(root)
    for i in 0..<24 {
        let options=(0..<64).map{LibraryOption(id:id(20_000+i*64+$0),title:"Option \($0)",position:Double($0)/63)}
        try await f.map(.create(.choice(id:id(10_000+i),title:"Dense \(i)",options:options,initial:options[0].id)))
    }
    try await f.save();let bytes=try Data(contentsOf:f.file)
    // Explicit exhaustion boundary: reopen the real public-created file under a smaller valid owner budget.
    let limited=try LibraryLimits(maximumBytes:bytes.count+4096,maximumRevisions:1024,expansion:LibraryExpansionLimits(maximumDepth:24,maximumOccurrences:256,maximumParts:1024))
    let session=try await SoundLibrarySession(persistence:LibrarySessionFile(url:f.file,maximumBytes:limited.maximumBytes),limits:limited)
    let edit=try await session.beginEdit(.definition(f.definition),admission:{_ in})
    do{_=try await session.previewOptionEdit(edit.handle,expectedGeneration:edit.generation,address:address,mutation:.add(id:d,title:"New",at:1));throw Failure(message:"oversized option history admitted")}
    catch LibraryError.limitExceeded{print("PASS one option history group exceeding owner byte limit refuses BEFORE preview/install")}
    let unchanged=try await session.inspectEdit(edit.handle)
    try check(unchanged==edit && (try Data(contentsOf:f.file))==bytes,"history-capacity refusal leaves generation/history/file exact")
}

@MainActor func discardSavedCases(_ root:URL) async throws {
    for ownedUse in [false,true] {
        let label=ownedUse ? "owned-use" : "workspace"
        func reopen(_ f:Fixture,_ binding:LibraryBinding) async throws {
            try await f.reopen()
            if ownedUse {f.edit=try await f.session.beginEdit(.use(binding),admission:{_ in})}
        }
        func off(_ f:Fixture,_ binding:LibraryBinding) async throws {
            _=try await f.session.setEnabled(false,expected:binding)
            await f.session.setEnabled(false)
        }
        func fileState(_ f:Fixture,_ intent:Bool) throws {
            let data=try Data(contentsOf:f.file),obj=try JSONSerialization.jsonObject(with:data) as! [String:Any]
            try check(obj["schema"] as? Int == (intent ? 7:5) && obj["enabled"] as? Bool==false,"D1 \(label) actual schema follows retained intent/master OFF")
            let rows=obj[ownedUse ? "uses":"workspaces"] as! [[String:Any]]
            try check(rows.contains{($0["optionRemovals"] as? [[String:Any]])?.isEmpty==false}==intent,"D1 \(label) restored intent bytes match saved state")
        }
        func staysOff(_ f:Fixture,_ binding:LibraryBinding) async throws {
            let snapshot=try await f.session.snapshot()
            try check(!snapshot.isEnabled && snapshot.assignments.first{$0.id==binding.assignment}?.isEnabled==false,"D1 \(label) per-app OFF retained")
        }
        let f=try await Fixture(root.appendingPathComponent(label+"-saved-edit"))
        _=try await f.publish();let binding=try await f.attach()
        if ownedUse {f.edit=try await f.session.beginEdit(.use(binding),admission:{_ in})}
        try await off(f,binding)
        f.edit=try await f.session.edit(f.edit.handle,expectedGeneration:f.edit.generation,command:.addPart(type:"gain",at:0))
        let gain=f.edit.parts[0].id
        f.edit=try await f.session.edit(f.edit.handle,expectedGeneration:f.edit.generation,command:.setPhysical(part:gain,parameter:"gainDb",value:-9))
        try await f.map(.rename(control:choice,title:"Saved Door"));try await f.save()
        let saved=try Data(contentsOf:f.file)
        try await reopen(f,binding);try await f.hand(0.5)
        _=try await f.mutate(.remove(id:b,replacement:c))
        f.edit=try await f.session.discardEdit(f.edit.handle,expectedGeneration:f.edit.generation)
        try check(f.options()==[a,b,c] && f.edit.controls.first{$0.id==choice}?.title=="Saved Door" && f.edit.parts.first{$0.id==gain}?.settings.first{$0.parameter=="gainDb"}?.physicalValue == -9,"D1 \(label) Discard preserves saved gain AND rename")
        try check(try await f.effective()==1,"D1 \(label) retained C stays C by name after restoring ABC")
        try check(try Data(contentsOf:f.file)==saved,"D1 \(label) Discard does not write checkpoint bytes")
        try await staysOff(f,binding);try await f.save();try fileState(f,false)
        try await reopen(f,binding)
        try check(f.edit.parts.first{$0.id==gain}?.settings.first{$0.parameter=="gainDb"}?.physicalValue == -9 && f.options()==[a,b,c],"D1 \(label) saved unrelated edit survives fresh owner")

        let g=try await Fixture(root.appendingPathComponent(label+"-saved-removal"))
        _=try await g.publish();let subject=try await g.attach(),oldTarget=try await g.attach("test.old-B")
        if ownedUse {g.edit=try await g.session.beginEdit(.use(subject),admission:{_ in})}
        try await off(g,subject);try await off(g,oldTarget)
        try await g.session.move(choice,on:"test.old-B",to:.scalar(0.5))
        _=try await g.mutate(.remove(id:b,replacement:c));try await g.save()
        try await reopen(g,subject);try await g.map(.rename(control:choice,title:"Unsaved"))
        g.edit=try await g.session.discardEdit(g.edit.handle,expectedGeneration:g.edit.generation)
        try check(g.options()==[a,c] && g.edit.controls.first{$0.id==choice}?.title=="Door" && g.edit.pendingStructural,"D1 \(label) saved removal survives unsaved rename Discard")
        try await g.save();try fileState(g,true);try await reopen(g,subject)
        let places=[LibraryUpdatePlace(use:oldTarget.use)] + (ownedUse ? [LibraryUpdatePlace(use:subject.use)]:[])
        let preview=try await g.session.previewUpdateLibrary(g.edit.handle,expectedGeneration:g.edit.generation,places:places)
        try check(preview.removals.contains{$0.removed==b && $0.replacement==c},"D1 \(label) reopened A25 uses original B→C intent without another answer")
        let result=try await g.session.confirmUpdateLibrary(preview),snapshot=try await g.session.snapshot()
        try check(result.commit.outcome.isAccepted && snapshot.uses.first{$0.id==oldTarget.use}?.positions[choice] == .scalar(1),"D1 \(label) actual A25 migrates old B to C")
        try await staysOff(g,oldTarget)

        let h=try await Fixture(root.appendingPathComponent(label+"-unsaved-removal"))
        _=try await h.publish();let untouched=try await h.attach()
        if ownedUse {h.edit=try await h.session.beginEdit(.use(untouched),admission:{_ in})}
        try await off(h,untouched);try await h.hand(0.5)
        _=try await h.mutate(.remove(id:b,replacement:a))
        h.edit=try await h.session.discardEdit(h.edit.handle,expectedGeneration:h.edit.generation)
        let hPosition=try await h.effective()
        try check(h.options()==[a,b,c] && !h.edit.pendingStructural && hPosition==0,"D1 \(label) never-checkpointed removal restores base, retained A selection")
        try await h.save();try fileState(h,false);try await reopen(h,untouched);try await staysOff(h,untouched)

        let j=try await Fixture(root.appendingPathComponent(label+"-restored-replacement"))
        _=try await j.publish();let jbinding=try await j.attach()
        if ownedUse {j.edit=try await j.session.beginEdit(.use(jbinding),admission:{_ in})}
        try await off(j,jbinding)
        _=try await j.mutate(.remove(id:b,replacement:c));try await j.save()
        j.edit=try await j.session.undoOptionEdit(j.edit.handle,expectedGeneration:j.edit.generation).snapshot
        try await j.hand(0.5)
        j.edit=try await j.session.discardEdit(j.edit.handle,expectedGeneration:j.edit.generation)
        let jPosition=try await j.effective()
        try check(j.options()==[a,c] && jPosition==1,"D1 \(label) live B absent from saved AC uses restored B→C, not fallback A")
        try await j.save();try fileState(j,true);try await reopen(j,jbinding);try await staysOff(j,jbinding)
        try check(try await j.effective()==1,"D1 \(label) restored replacement selection survives fresh owner")
    }
}
