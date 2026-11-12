import Foundation
import SoundModel
import SessionStore

@MainActor func ownerPortCases(_ root:URL)async throws {
    let f=try await Fixture(root.appendingPathComponent("selector"));_=try await f.publish();let binding=try await f.attach()
    let coordinator=LibraryListeningCoordinator(publish:{_ in},admit:{_ in},apply:{_,_,_ in})
    await coordinator.start(persistence:f.port,limits:f.limits)
    let adapter=coordinator.editor;_=try await selected(adapter.select(.use(binding)));let token=adapter.token!
    let gain=try await selected(adapter.submit(token,command:.addPart(type:"gain",at:0))).parts[0].id,slider=id(830)
    _=try await selected(adapter.submit(token,command:.mapping(path:[],.create(.slider(id:slider,title:"Level",initial:0,waypoints:[0,0.5,1])))))
    _=try await selected(adapter.submit(token,command:.mapping(path:[],.connectLegacy(source:LibraryMappingSource(slider),part:gain,parameter:"gainDb"))))
    _=try await selected(adapter.submit(token,command:.mapping(path:[],.differentForOptions(source:slider,selector:choice))))
    await adapter.displaySettled();await coordinator.refresh()
    let (selectorRequest,preview)=try await queryValue(adapter.previewSelector(token,path:[],source:slider))
    try check(preview.source==slider && preview.selector==choice && preview.option==a,"A actual selector preview captures picked OptionID/fingerprint")
    _=try await coordinator.move(address,expected:binding,to:.scalar(0.5))
    do{_=try adapter.applySelector(selectorRequest,preview:preview);throw Failure(message:"stale selector accepted")}
    catch LibraryEditorAdmissionError.staleSelection{print("PASS A typed selector apply rejects stale sequence before owner mutation")}

    await adapter.displaySettled();await coordinator.refresh()
    let (freshRequest,fresh)=try await queryValue(adapter.previewSelector(token,path:[],source:slider))
    _=try await selected(adapter.applySelector(freshRequest,preview:fresh))
    await adapter.displaySettled();await coordinator.refresh()
    let (_,projection)=try await queryValue(adapter.mappings(token))
    try check(projection.mappings.bindings.allSatisfy{$0.selector==nil && $0.cases.isEmpty},"A actual picked-option Same For All command, not fake projection")
    _=coordinator.beginDrain();_=await coordinator.finishDrain(.save);coordinator.closePublications()

    let saved=try await Fixture(root.appendingPathComponent("autosave"));_=try await saved.publish();let target=try await saved.attach()
    let app=LibraryAppSession(changed:{})
    await app.start(persistence:saved.port,limits:saved.limits)
    _=try await selected(app.editor.select(.use(target)));let selectedToken=app.editor.token!
    let writes=await saved.port.submitted.count
    await saved.port.arm(0)
    _=try await selected(app.editor.submit(selectedToken,command:.mapping(path:[],.rename(control:choice,title:"Autosaved Door"))))
    await saved.port.wait()
    try check(await saved.port.submitted.count==writes+1,"A actual existing 200ms autosave callback writes exactly once")
    app.send(.libraryMove(target,address,.scalar(0.5)))
    app.send(.libraryPower(target,false));app.send(.setEnabled(false))
    app.beginDrain()
    let drain=Task{await app.finishDrain(.save)}
    await saved.port.release()
    guard case .saved=await drain.value else{throw Failure(message:"shared AppSession drain failed")}
    app.close()
    let freshOwner=try await SoundLibrarySession(persistence:LibrarySessionFile(url:saved.file,maximumBytes:8_000_000),limits:saved.limits)
    let state=try await freshOwner.snapshot(),edit=try await freshOwner.beginEdit(.use(target),admission:{_ in})
    try check(!state.isEnabled && state.assignments.first{$0.id==target.assignment}?.isEnabled==false && state.uses.first{$0.id==target.use}?.positions[choice] == .scalar(0.5),"A actual shared autosave/drain fresh owner retains newer listening and OFF")
    try check(edit.controls.first{$0.id==choice}?.title=="Autosaved Door","A same real autosave writes authored edit and live state, no second writer")
}
