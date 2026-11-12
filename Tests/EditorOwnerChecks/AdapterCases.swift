import Foundation
import SoundModel
import SessionStore

actor OwnerReadGate {
    var armed=false,reached=false
    var entry:[CheckedContinuation<Void,Never>]=[]
    var continuation:CheckedContinuation<Void,Never>?
    func arm(){armed=true;reached=false}
    func wait()async{if reached{return};await withCheckedContinuation{entry.append($0)}}
    func read(_ session:SoundLibrarySession,_ handle:LibraryEditHandle)async throws->LibraryEditSnapshot {
        let snapshot=try await session.inspectEdit(handle)
        if armed{armed=false;reached=true;for x in entry{x.resume()};entry=[];await withCheckedContinuation{continuation=$0}}
        return snapshot
    }
    func release(){continuation?.resume();continuation=nil}
}
@MainActor func selected(_ receipt:LibraryEditorReceipt)async throws->LibraryEditSnapshot {
    switch await receipt.completion.value {
    case .model(let value):return value
    case .reported(let value):return value.snapshot
    default:throw Failure(message:"model result expected")
    }
}
@MainActor func queryValue<V>(_ query:LibraryEditorQuery<V>)async throws->(LibraryEditorRequest,V){
    switch await query.completion.value {
    case .value(let stamp,let value):return(stamp,value)
    case .superseded:throw Failure(message:"unexpected superseded read")
    case .refused(_,let reason):throw Failure(message:"read refused \(reason)")
    }
}
@MainActor func ownerAdapterCases(_ root:URL)async throws {
    let f=try await Fixture(root.appendingPathComponent("base"));_=try await f.publish()
    let binding=try await f.attach("test.editor"),other=try await f.attach("test.other")
    let gate=OwnerReadGate()
    var events:[LibraryConsumerEvent]=[],applied:[ListeningRenderSnapshot]=[]
    let coordinator=LibraryListeningCoordinator(publish:{events.append($0)},admit:{_ in},apply:{state,_,_ in applied.append(state)},editRead:{try await gate.read($0,$1)})
    await coordinator.start(persistence:f.port,limits:f.limits)
    let adapter=coordinator.editor
    _=try await selected(adapter.select(.use(binding)))
    await adapter.displaySettled();await coordinator.refresh()
    let token=adapter.token!
    let (_,read)=try await queryValue(adapter.mappings(token))
    try check(read.snapshot.generation==read.mappings.generation && read.snapshot.handle==token.handle,"A real token-bound mapping read matches handle/generation")
    let mutationsBefore=events.filter{if case .editorMutation = $0{return true};return false}.count
    let (request,preview)=try await queryValue(adapter.previewOption(token,address:address,mutation:.add(id:d,title:"New",at:1)))
    let apply=try adapter.applyOption(request,preview:preview)
    let appliedEdit=try await selected(apply)
    try check(adapter.reports[apply.command] != nil && appliedEdit.generation==preview.generation+1,"A option apply returns actual snapshot/report on same acknowledgement")
    try check(adapter.acknowledgeReport(apply.command) && !adapter.acknowledgeReport(apply.command),"A actual option report consumed once by command")
    _=try await coordinator.move(address,expected:binding,to:.scalar(1.0/3))
    let undo=try adapter.barrier(token,.undo)
    let outcome=await undo.completion.value
    guard case .reported(let result)=outcome else{throw Failure(message:"reporting Undo result missing")}
    try check(result.report.changes.contains{$0.before==d && $0.after==a && $0.reason == .explicitReplacement},"A always-reporting Undo preserves exact actual replacement report")
    try check(adapter.reports[undo.command] != nil,"A reporting Undo retains report independently from display refresh")
    let mutationsAfter=events.filter{if case .editorMutation = $0{return true};return false}.count
    try check(mutationsAfter==mutationsBefore+2,"A option Apply and Undo acknowledge/autosave exactly once each")
    try check(adapter.acknowledgeReport(undo.command),"A Undo explicit report acknowledged")
    let options=[LibraryOption(id:c,title:"Open",position:0),LibraryOption(id:a,title:"Shut",position:0.5),LibraryOption(id:b,title:"Ajar",position:1)]
    _=try await selected(adapter.submit(token,command:.mapping(path:[],.choiceOptions(control:choice,options:options,tables:[:]))))
    let renamed=adapter.state.edit!
    guard case .choice(let named)=renamed.controls.first(where:{$0.id==choice})!.face else{throw Failure(message:"choice missing")}
    try check(named.map(\.title)==["Open","Shut","Ajar"] && named.map(\.id)==[c,a,b],"A same-id choice rename/reorder uses real ordinary command")
    let ordinaryUndo=try adapter.barrier(token,.undo)
    guard case .reported(let ordinary)=await ordinaryUndo.completion.value else{throw Failure(message:"ordinary report missing")}
    try check(ordinary.report.changes.isEmpty && ordinary.snapshot.controls.first{$0.id==choice}?.title=="Door","A ordinary Undo travels same reporting route with empty report")
    _=adapter.acknowledgeReport(ordinaryUndo.command)
    let beforeListening=adapter.state.edit!
    _=try await coordinator.move(address,expected:binding,to:.scalar(0.5))
    try check(adapter.state.edit?.generation==beforeListening.generation && adapter.state.edit?.pendingStructural==beforeListening.pendingStructural,"A outside-Edit listening neither authors nor hides existing draft")
    await adapter.displaySettled();await coordinator.refresh()
    await gate.arm()
    let held=try adapter.mappings(token);await gate.wait()
    _=try await coordinator.setEnabled(false,expected:other)
    await gate.release()
    guard case .superseded=await held.completion.value else{throw Failure(message:"stale held mapping read shown")}
    try check(true,"A held actual projection refuses newer-live completion")
    await adapter.displaySettled();await coordinator.refresh()
    await gate.arm()
    let switched=try adapter.mappings(token);await gate.wait()
    let selection=try adapter.select(.use(other))
    await gate.release();_=try await selected(selection)
    guard case .superseded=await switched.completion.value else{throw Failure(message:"stale selection projection shown")}
    try check(true,"A held projection refused after selection changes")
    try await ownerGestureCases(root.appendingPathComponent("gesture"))
    try await publicationCasesForAdapter(root.appendingPathComponent("publication"))
}

actor OwnerControlledStore: LibraryPersistence {
    let file:LibrarySessionFile
    var held=false,reached=false,mode=0
    var waiters:[CheckedContinuation<Void,Never>]=[]
    var releaseWaiter:CheckedContinuation<Void,Never>?
    var submitted:[Data]=[]
    init(_ url:URL){file=LibrarySessionFile(url:url,maximumBytes:8_000_000)}
    func load()async throws->Data?{try await file.load()}
    func arm(_ m:Int){mode=m;held=true;reached=false}
    func wait()async{if reached{return};await withCheckedContinuation{waiters.append($0)}}
    func release(){held=false;releaseWaiter?.resume();releaseWaiter=nil}
    func commit(_ data:Data)async->LibraryWriteOutcome{
        submitted.append(data)
        let current=mode;mode=0
        if held{reached=true;for waiter in waiters{waiter.resume()};waiters=[];await withCheckedContinuation{releaseWaiter=$0}}
        if current==1{return .refused(.io("injected before replacement"))}
        if current==3{return .unresolved("injected acknowledgement before replacement")}
        let result=await file.commit(data)
        return current==2 ? .unresolved("injected after replacement"):result
    }
}
@MainActor func publicationCasesForAdapter(_ root:URL)async throws {
    for mode in 0...3 {
        let f=try await Fixture(root.appendingPathComponent("mode-\(mode)"));_=try await f.publish()
        let binding=try await f.attach("test.editor"),other=try await f.attach("test.other")
        try await f.session.move(choice,on:"test.other",to:.scalar(0.5));try await f.save()
        let port=OwnerControlledStore(f.file)
        var events:[LibraryConsumerEvent]=[],latest:LibraryMenuState?
        let coordinator=LibraryListeningCoordinator(publish:{event in events.append(event);if case .state(let state)=event{latest=state.presentation}},admit:{_ in},apply:{_,_,_ in})
        await coordinator.start(persistence:port,limits:f.limits)
        let adapter=coordinator.editor
        _=try await selected(adapter.select(.use(binding)))
        await adapter.displaySettled();await coordinator.refresh()
        let token=adapter.token!
        let (optionRequest,option)=try await queryValue(adapter.previewOption(token,address:address,mutation:.remove(id:b,replacement:a)))
        let optionResult=try adapter.applyOption(optionRequest,preview:option);_=try await selected(optionResult);_=adapter.acknowledgeReport(optionResult.command)
        await adapter.displaySettled();await coordinator.refresh()
        let places=[LibraryUpdatePlace(use:binding.use),LibraryUpdatePlace(use:other.use)]
        let (_,cancelled)=try await queryValue(adapter.previewUpdate(token,places:places))
        let bytes=try Data(contentsOf:f.file),generation=adapter.state.edit!.generation
        _=try await queryValue(adapter.cancelUpdate(token,preview:cancelled))
        try check(bytes == (try Data(contentsOf:f.file)) && adapter.state.edit?.generation==generation,"A A25 Cancel leaves real bytes/generation unchanged \(mode)")
        let (request,preview)=try await queryValue(adapter.previewUpdate(token,places:places))
        try check(preview.removals.contains{$0.removed==b && $0.replacement==a},"A A25 preview carries actual named removal \(mode)")
        _=try await coordinator.setEnabled(true)
        // A later live mutation invalidates the preview fingerprint, so recapture before issuing.
        await adapter.displaySettled();await coordinator.refresh()
        _=try await queryValue(adapter.cancelUpdate(token,preview:preview))
        let (currentRequest,currentPreview)=try await queryValue(adapter.previewUpdate(token,places:places))
        await port.arm(mode)
        let confirmation=try adapter.confirmUpdate(currentRequest,preview:currentPreview)
        await port.wait()
        _=try await coordinator.move(address,expected:other,to:.scalar(1))
        _=try await coordinator.setEnabled(false,expected:other)
        _=try await coordinator.setEnabled(false)
        _=try await coordinator.compareOriginal(true);_=try await coordinator.compareOriginal(false)
        try check(coordinator.beginDrain() && coordinator.cancelDrain(),"A cancelable Quit while real publication writer held \(mode)")
        if mode==0 {
            let selection=try adapter.select(.definition(f.definition));_=try await selected(selection)
            _=try await adapter.done(adapter.token!).completion.value
            try check(adapter.token==nil,"A selection switch and close do not block live tail behind disk")
        }
        await port.release()
        guard case .publication(let result,_) = await confirmation.completion.value else{throw Failure(message:"publication outcome missing")}
        try check(result.command==confirmation.command && adapter.publications[result.command]?.initial==result,"A durable result bound once to actual command receipt \(mode)")
        if mode==0 {
            guard case .accepted(let commit)=result.outcome,let report=result.publication?.acceptedReport else{throw Failure(message:"accepted update report missing")}
            try check(report.token==commit.token && report.capturedDigest==commit.digest && report.carriedNewerState,"A accepted report retains exact token/digest and newer live merge")
            try check(adapter.reports[result.command] != nil,"A accepted report survives selection switch and editor close")
        }else if mode==1 {
            guard case .refused=result.outcome else{throw Failure(message:"refusal misclassified")}
            try check(adapter.reports[result.command]==nil,"A refused durable write has no accepted report")
        }else{
            guard case .unresolved(let commit)=result.outcome else{throw Failure(message:"uncertainty misclassified")}
            try check(adapter.reports[result.command]==nil && !adapter.acknowledgeReport(result.command),"A unresolved write cannot be acknowledged as report/accepted \(mode)")
            await adapter.receiveReconciliation(command:result.command,commit:UUID(),result:.superseded,report:nil)
            try check(adapter.publications[result.command]?.reconciliation==nil,"A wrong-token reconciliation cannot settle publication \(mode)")
            if mode==2 {
                _=try await adapter.done(token).completion.value
                _=await coordinator.checkpoint()
                try check(adapter.token==nil,"A late accepted report delivered after editor closes")
            }
            await coordinator.onMenuOpen()
            let settled=adapter.publications[result.command]!
            if mode==2 {
                guard case .accepted(let command,let token)?=settled.reconciliation else{throw Failure(message:"matching accepted reconciliation missing")}
                try check(command==result.command && token==commit.token && adapter.reports[result.command]?.commit==commit.token,"A matching-token reconciliation retrieves real accepted report once")
            }else{
                guard case .refused?=settled.reconciliation else{throw Failure(message:"not-written candidate not refused")}
                try check(adapter.reports[result.command]==nil,"A unknown-before readback refuses without accepted report")
            }
        }
        let reports=adapter.reports.count
        await coordinator.onMenuOpen()
        try check(adapter.reports.count==reports,"A later refresh/readback cannot duplicate report \(mode)")
        try check(adapter.acknowledgeReport(result.command) && !adapter.acknowledgeReport(result.command),"A final publication acknowledgement removes bounded receipt once \(mode)")
        await coordinator.refresh()
        try check(latest?.isEnabled==false && latest?.compareOriginal==false && latest?.assignments.first{$0.id==other.assignment}?.isEnabled==false && latest?.uses.first{$0.id==other.use}?.positions[choice] == .scalar(1),"A other app latest C/OFF/masterOFF/compare release retained \(mode)")
        _=coordinator.beginDrain()
        guard case .saved=await coordinator.finishDrain(.save) else{throw Failure(message:"final drain save not accepted")}
        coordinator.closePublications()
        let fresh=try await SoundLibrarySession(persistence:LibrarySessionFile(url:f.file,maximumBytes:8_000_000),limits:f.limits),state=try await fresh.snapshot()
        try check(!state.isEnabled && state.assignments.first{$0.id==other.assignment}?.isEnabled==false && state.uses.first{$0.id==other.use}?.positions[choice] == .scalar(1),"A real final OFF checkpoint/fresh owner retains independent listening \(mode)")
        _=request
    }
}

@MainActor func ownerGestureCases(_ root:URL)async throws {
    let f=try await Fixture(root);_=try await f.publish();let binding=try await f.attach()
    let coordinator=LibraryListeningCoordinator(publish:{_ in},admit:{_ in},apply:{_,_,_ in})
    await coordinator.start(persistence:f.port,limits:f.limits)
    let adapter=coordinator.editor;_=try await selected(adapter.select(.use(binding)));let token=adapter.token!
    let gesture=UUID();_=try await selected(adapter.barrier(token,.begin(gesture)))
    _=try await selected(adapter.submit(token,command:.moveControl(address,.scalar(0.5)),gesture:gesture))
    let blocked=try adapter.previewOption(token,address:address,mutation:.add(id:d,title:"New",at:1))
    if case .refused(_, .model(.unsupportedEdit))=await blocked.completion.value {print("PASS A semantic preview typed refusal during gesture")}
    else{throw Failure(message:"gesture admitted semantic preview")}
    _=try await selected(adapter.barrier(token,.end(gesture)))
    let undo=try adapter.barrier(token,.undo);let undoEdit=try await selected(undo)
    try check(undoEdit.positions[address] != .scalar(0.5),"A one reporting Undo undoes real gesture group")
    _=adapter.acknowledgeReport(undo.command)
    let redo=try adapter.barrier(token,.redo);_=try await selected(redo);_=adapter.acknowledgeReport(redo.command)
    let cancel=UUID();_=try await selected(adapter.barrier(token,.begin(cancel)))
    _=try await selected(adapter.submit(token,command:.moveControl(address,.scalar(1)),gesture:cancel))
    let cancelled=try await selected(adapter.barrier(token,.cancel(cancel)))
    try check(cancelled.positions[address] == .scalar(0.5),"A gesture Cancel restores exact prior position")
    var ids:[UUID]=[]
    for _ in 0..<32 {
        let u=try adapter.barrier(token,.undo);_=try await selected(u);ids.append(u.command)
        let r=try adapter.barrier(token,.redo);_=try await selected(r);ids.append(r.command)
    }
    let full=adapter.state.edit!
    do{_=try adapter.barrier(token,.undo);throw Failure(message:"unbounded report admitted")}
    catch LibraryEditorAdmissionError.capacity{print("PASS A report capacity refuses before model command")}
    try check(adapter.reports.count==64 && adapter.state.edit==full,"A actual report retention bounded with no hidden Undo stack")
    try check(adapter.acknowledgeReport(ids[0]),"A explicit report acknowledgement releases capacity")
    let next=try adapter.barrier(token,.undo);_=try await selected(next);_=adapter.acknowledgeReport(next.command)
    for id in ids{_=adapter.acknowledgeReport(id)}
    let fenced=UUID();_=try await selected(adapter.barrier(token,.begin(fenced)))
    _=try await selected(adapter.submit(token,command:.moveControl(address,.scalar(1)),gesture:fenced))
    try check(coordinator.beginDrain() && coordinator.cancelDrain(),"A drain cancellation returns same owner to running")
    do{_=try adapter.barrier(token,.end(fenced));throw Failure(message:"old drained gesture reattached")}
    catch LibraryEditorAdmissionError.gestureMismatch{print("PASS A drained gesture cannot reattach after canceled Quit")}
    await adapter.displaySettled()
    _=try await adapter.done(token).completion.value
    try check(adapter.token==nil,"A Done closes context, does not add save owner")
    do{_=try adapter.submit(token,command:.moveControl(address,.scalar(0)));throw Failure(message:"retired token accepted")}
    catch LibraryEditorAdmissionError.staleSelection{print("PASS A retired token cannot edit replacement context")}
    _=coordinator.beginDrain()
    guard case .saved=await coordinator.finishDrain(.save) else{throw Failure(message:"gesture drain not saved")}
    coordinator.closePublications()
}
