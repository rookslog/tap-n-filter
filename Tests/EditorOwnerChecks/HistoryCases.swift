import Foundation
import SoundModel

@MainActor func ownerHistoryCases(_ root:URL) async throws {
    for undoing in [true,false] {
        let f=try await Fixture(root.appendingPathComponent(undoing ? "undo":"redo")),slider=id(800)
        let binding=try await f.startUse()
        try await f.map(.create(.slider(id:slider,title:"Independent",initial:0,waypoints:[0,0.5,1])))
        if undoing {
            _=try await f.mutate(.add(id:d,title:"New",at:1));try await f.hand(0.3,slider)
        }else{
            try await f.hand(0.3,slider);_=try await f.mutate(.remove(id:b,replacement:a))
            f.edit=try await f.session.undoOptionEdit(f.edit.handle,expectedGeneration:f.edit.generation).snapshot
            let ordinary=try await f.session.undoOptionEdit(f.edit.handle,expectedGeneration:f.edit.generation);f.edit=ordinary.snapshot
            try check(ordinary.report.changes.isEmpty,"H ordinary effective edit returns empty semantic report")
        }
        _=try await f.session.move(LibraryControlAddress(path:[],control:slider),expected:binding,to:.scalar(0.7))
        _=try await f.session.move(address,expected:binding,to:.scalar(undoing ? 1.0/3:0.5))
        let before=try await f.session.inspectEdit(f.edit.handle),snapshot=try await f.session.snapshot()
        do {
            if undoing {_=try await f.session.undoEdit(f.edit.handle,expectedGeneration:f.edit.generation)}
            else {_=try await f.session.redoEdit(f.edit.handle,expectedGeneration:f.edit.generation)}
            throw Failure(message:"plain history consumed option")
        }catch LibraryOptionError.reportingHistoryRequired {
            let after=try await f.session.inspectEdit(f.edit.handle),state=try await f.session.snapshot()
            try check(after==before && state==snapshot,"H plain traversal refuses atomically after spent ordinary entry")
        }
        let result=try await (undoing ? f.session.undoOptionEdit(f.edit.handle,expectedGeneration:f.edit.generation):f.session.redoOptionEdit(f.edit.handle,expectedGeneration:f.edit.generation));f.edit=result.snapshot
        try check(result.snapshot.generation==before.generation+1,"H one effective patch advances generation once")
        try check(result.report.changes.contains{$0.address==address && $0.before == (undoing ? d:b) && $0.after==a && $0.reason == .explicitReplacement},"H actual encountered option emits exact replacement row")
        try check(try await f.effective(slider)==0.7,"H newer independent listening retained")
        _=try await f.session.setEnabled(false,expected:binding)
        try await f.save();try await f.reopen()
        let reopened=try await f.session.snapshot()
        try check(!reopened.isEnabled && reopened.assignments.first{$0.id==binding.assignment}?.isEnabled==false,"H actual file/fresh owner preserves master and exact-app OFF")
    }
}
