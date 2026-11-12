import Foundation
import SoundModel
import SessionStore

@MainActor func localCases(_ root:URL) async throws {
    let f=try await Fixture(root)
    let before=try await f.session.inspectEdit(f.edit.handle),state=try await f.session.snapshot(),writes=await f.port.submitted.count
    let preview=try await f.session.previewOptionEdit(f.edit.handle,expectedGeneration:f.edit.generation,address:address,mutation:.add(id:d,title:"New",at:1))
    let unchanged=try await f.session.inspectEdit(f.edit.handle),next=try await f.session.snapshot()
    let newWrites=await f.port.submitted.count
    try check(before==unchanged && state==next && writes==newWrites,"preview has no generation/state/history/write effect")
    let added=try await f.session.applyOptionEdit(preview);f.edit=added.snapshot
    try check(f.options()==[a,d,b,c] && added.report.operation==preview.id,"actual semantic Add and stamped report")
    do{_=try await f.session.undoEdit(f.edit.handle,expectedGeneration:f.edit.generation);throw Failure(message:"snapshot history consumed option report")}
    catch LibraryOptionError.reportingHistoryRequired{print("PASS snapshot-only history refuses option patch")}
    let undone=try await f.session.undoOptionEdit(f.edit.handle,expectedGeneration:f.edit.generation);f.edit=undone.snapshot
    try check(f.options()==[a,b,c],"one reporting Undo restores ordered IDs")
    let redone=try await f.session.redoOptionEdit(f.edit.handle,expectedGeneration:f.edit.generation);f.edit=redone.snapshot
    try check(f.options()==[a,d,b,c],"one reporting Redo restores ordered IDs")
    let removed=try await f.mutate(.remove(id:b,replacement:a))
    try check(f.options()==[a,d,c] && removed.snapshot.pendingStructural,"actual semantic Remove and report")
    try await f.save();let saved=try Data(contentsOf:f.file)
    try check((try JSONSerialization.jsonObject(with:saved) as? [String:Any])?["schema"] as? Int == 7,"pending replacement intent selects schema7")
    try await f.reopen();try check(f.options()==[a,d,c],"fresh real owner reopens option edit and intent envelope")
    let final=try await f.session.snapshot()
    try check(final.definitions.first{$0.id==f.definition}?.revision==state.definitions.first{$0.id==f.definition}?.revision,"local option history/checkpoint never publishes head")
}

@MainActor func qualifiedCases(_ root:URL) async throws {
    let f=try await Fixture(root.appendingPathComponent("qualified"));let original=try await f.publish()
    _=try await f.session.createLinkedBlock(name:"Two occurrences",children:[original.new,original.new],on:"test.parent")
    let snap=try await f.session.snapshot(),binding=snap.assignments.first{$0.target=="test.parent"}!
    let parentBinding=LibraryBinding(assignment:binding.id,use:binding.use,target:binding.target)
    let sourceEdit=f.edit
    f.edit=try await f.session.beginEdit(.use(parentBinding),admission:{_ in})
    let sites=f.edit.pieces.compactMap{piece -> UUID? in if case .reference(let site,_,_)=piece{return site};return nil}
    guard sites.count==2 else{throw Failure(message:"two exact public references missing")}
    try await f.map(.create(.choice(id:choice,title:"Unrelated same UUID",options:[LibraryOption(id:a,title:"A",position:0),LibraryOption(id:b,title:"B",position:0.5),LibraryOption(id:c,title:"C",position:1)],initial:b)))
    for site in sites{try await f.session.move(LibraryControlAddress(path:[site],control:choice),on:"test.parent",to:.scalar(0.5))}
    let heads=try await f.session.snapshot().definitions
    _=try await f.mutate(.add(id:d,title:"First",at:0),at:LibraryControlAddress(path:[sites[0]],control:choice))
    let facts=try await f.facts()
    try check(facts.controls.first{$0.address==LibraryControlAddress(path:[sites[0]],control:choice)}?.effective == .scalar(2.0/3),"qualified child manual B follows its new anchor")
    try check(facts.controls.first{$0.address==LibraryControlAddress(path:[sites[1]],control:choice)}?.effective == .scalar(0.5) && facts.controls.first{$0.address==address}?.effective == .scalar(0.5),"equal raw control/Option UUIDs at other sites and root remain exact")
    try check(try await f.session.snapshot().definitions==heads,"localization/option edit never mutates any immutable revision/hash")
    try check(f.edit.pieces.contains{if case .reference(let site,let ref,_ )=$0{return site==sites[1] && ref==original.new};return false},"unnamed second exact reference remains immutable")
    try await f.save()
    let fresh=try await SoundLibrarySession(persistence:LibrarySessionFile(url:f.file,maximumBytes:8_000_000),limits:f.limits)
    let freshParent=try await fresh.beginEdit(.use(parentBinding),admission:{_ in}),fm=try await fresh.mappings(freshParent.handle)
    try check(fm.controls==facts.controls,"qualified occurrence memory survives real owner reopen")
    f.edit=sourceEdit

    let g=try await Fixture(root.appendingPathComponent("inactive"));_=try await g.publish()
    let active=try await g.attach("test.active"),inactive=try await g.attach("test.inactive")
    for target in ["test.active","test.inactive"]{try await g.session.move(choice,on:target,to:.scalar(0.5))}
    _=try await g.session.select(nil,on:"test.inactive")
    _=try await g.mutate(.remove(id:b,replacement:c))
    _=try await g.publish([LibraryUpdatePlace(use:active.use),LibraryUpdatePlace(use:inactive.use)])
    let after=try await g.session.snapshot()
    try check(after.uses.filter{$0.id==active.use || $0.id==inactive.use}.allSatisfy{$0.positions[choice] == .scalar(1)} && after.assignments.allSatisfy{$0.target != "test.inactive"},"A25 migrates inactive saved memory without activating it")
    try await g.save();try await g.reopen()
}
