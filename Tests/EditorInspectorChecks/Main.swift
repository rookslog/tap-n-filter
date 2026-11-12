import Foundation
import SoundModel

struct CheckError: Error { let message: String }
func expect(_ value: Bool, _ message: String) throws {
    if !value { throw CheckError(message: message) }
    print("PASS " + message)
}
func need<T>(_ value: T?) throws -> T {
    guard let value else { throw CheckError(message: "missing fixture value") }; return value
}
@main struct EditorInspectorChecks {
    @MainActor static func main() async throws {
        var fixture = try await EditorOwnedFixture.make()
        var edit = fixture.edit
        let dynamics = try need(edit.parts.first { $0.type == "dynamics" })
        let gain = try need(edit.parts.first { $0.type == "gain" })
        let threshold = try need(dynamics.settings.first { $0.parameter == "thresholdDb" })
        let attack = try need(dynamics.settings.first { $0.parameter == "attackSeconds" })
        let source = try need(gain.settings.first)
        let expected = edit.controls.filter { ["Place", "Device", "Softer", "Volume"].contains($0.title) }.map(\.id)
        try expect(source.sourceControls == expected && expected.count == 4, "multi-setting sources retained in presentation order at neutral zero contribution")
        try expect(!threshold.isChangedHere && threshold.physicalValue == 20, "neutral baked base has no false changed-here dot")
        try expect(EditorSettingFormat.text(attack) == "1.0 ms", "actual seconds descriptor displayed in milliseconds")
        try expect(abs(try EditorSettingFormat.parse("8.0 ms", setting: attack) - 0.008) < 1e-12, "typed milliseconds return physical seconds")
        try expect(try EditorSettingFormat.parse("−18.0 dB", setting: threshold) == -18, "typed real-unit negative value")
        for invalid in ["NaN", "infinity", "-200 dB", "2 Hz"] {
            do { _ = try EditorSettingFormat.parse(invalid, setting: threshold); throw CheckError(message: "invalid value accepted") }
            catch is CheckError { throw CheckError(message: "invalid value accepted") }
            catch { print("PASS typed domain refusal " + invalid) }
        }
        do { _ = try EditorSettingFormat.parse("0.1 ms", setting: attack); throw CheckError(message: "unsafe attack accepted") }
        catch is CheckError { throw CheckError(message: "unsafe attack accepted") }
        catch { print("PASS actual attack minimum input refusal") }
        let command = try EditorSettingFormat.command(edit, part: dynamics.id, key: "thresholdDb", physical: -18)
        if case .setPhysical(let id, let key, let value) = command {
            try expect(id == dynamics.id && key == "thresholdDb" && value == -18, "typed action retains exact part key and physical value")
        } else { throw CheckError(message: "wrong typed action") }
        try await fixture.apply(command); edit = fixture.edit
        var changed = try need(edit.parts.first { $0.id == dynamics.id }?.settings.first { $0.parameter == "thresholdDb" })
        try expect(changed.isChangedHere && abs(changed.physicalValue + 18) < 1e-9 && changed.adjustment != 0, "actual physical edit shifts offset and marks only local change")
        fixture.edit = try await fixture.session.undoEdit(edit.handle, expectedGeneration: edit.generation); edit = fixture.edit
        changed = try need(edit.parts.first { $0.id == dynamics.id }?.settings.first { $0.parameter == "thresholdDb" })
        try expect(!changed.isChangedHere && changed.physicalValue == threshold.physicalValue, "actual Undo restores authoritative physical value and provenance")
        let id = UUID()
        let phases: [EditorPartAction] = [.begin(id), .sample(id, command), .end(id), .cancel(id)]
        let events = phases.map { EditorPartEvent(edit, $0) }
        try expect(events.allSatisfy { $0.handle == edit.handle && $0.generation == edit.generation }, "begin sample end cancel carry exact caller handle and generation")
        let beforeControls = Set(edit.controls.map(\.id))
        try await fixture.apply(.showAtTop(part: dynamics.id, parameter: "attackSeconds", title: "Attack")); edit = fixture.edit
        let pinned = try need(edit.parts.first { $0.id == dynamics.id }?.settings.first { $0.parameter == "attackSeconds" })
        let newID = try need(edit.controls.first { !beforeControls.contains($0.id) }?.id)
        try expect(pinned.isShownAtTop && pinned.sourceControls == [newID], "actual Show at Top adds the real primary control mapping")
        try expect(EditorPartPresentation.reordered(edit, part: edit.parts[0].id, by: -1) == nil, "first part cannot move earlier")
        if let reorder = EditorPartPresentation.reordered(edit, part: dynamics.id, by: -1) {
            let old = edit.parts.map(\.id)
            try await fixture.apply(reorder); edit = fixture.edit
            let index = try need(old.firstIndex(of: dynamics.id))
            try expect(edit.parts[index - 1].id == dynamics.id && Set(edit.parts.map(\.id)) == Set(old), "actual chain reorder preserves exact part identities")
        } else { throw CheckError(message: "missing valid reorder") }
        try await fixture.apply(.setPhysical(part: dynamics.id, parameter: "thresholdDb", value: -16)); edit = fixture.edit
        let live = try await fixture.session.liveState()
        let binding = try need(live.assignments.first?.binding)
        _ = try await fixture.session.doneEdit(edit.handle, expectedGeneration: edit.generation)
        let created = try await fixture.session.createFromUse(expected: binding, name: "Owned editor fixture")
        try expect(created.acceptedReference != nil, "owned custom creation actually accepted")
        let newLive = try await fixture.session.liveState()
        let newBinding = try need(newLive.assignments.first?.binding)
        edit = try await fixture.session.beginEdit(.use(newBinding), admission: { _ in })
        try expect(edit.parts.allSatisfy { $0.settings.allSatisfy { !$0.isChangedHere } }, "unchanged baked custom base never gets false local-change dots")
        let originalPhysical = try need(edit.parts.first { $0.id == dynamics.id }?.settings.first { $0.parameter == "thresholdDb" }).physicalValue
        edit = try await fixture.session.beginEditGesture(edit.handle, expectedGeneration: edit.generation)
        edit = try await fixture.session.edit(edit.handle, expectedGeneration: edit.generation,
            command: .setPhysical(part: dynamics.id, parameter: "thresholdDb", value: -12))
        edit = try await fixture.session.cancelEditGesture(edit.handle, expectedGeneration: edit.generation)
        let afterCancel = try need(edit.parts.first { $0.id == dynamics.id }?.settings.first { $0.parameter == "thresholdDb" })
        try expect(abs(afterCancel.physicalValue - originalPhysical) < 1e-9 && !afterCancel.isChangedHere, "actual gesture cancel restores authoritative value and base provenance")
        try expect(!newLive.isEnabled, "all checks retain global OFF with no engine constructed")
        try expect(edit.kinds.contains(where: \.canInsert), "chain Add capability comes from actual model admission")
        print("PASS EditorInspectorChecks complete; no view actions, engine, native metadata or user data")
        try await correctionChecks()
    }
}


extension EditorInspectorChecks {
    @MainActor static func correctionChecks() async throws {
        var fixture = try await EditorOwnedFixture.make()
        let first = fixture.edit
        let partA = try need(first.parts.first { $0.type == "dynamics" })
        try await fixture.apply(.addPart(type: "dynamics", at: first.pieces.count))
        let two = fixture.edit
        let partB = try need(two.parts.first { $0.type == "dynamics" && $0.id != partA.id })
        let a = EditorSettingIdentity(handle: two.handle, part: partA.id, parameter: "thresholdDb")
        let b = EditorSettingIdentity(handle: two.handle, part: partB.id, parameter: "thresholdDb")
        var calls: [String] = []
        var life = EditorInteractionLifetime<() -> Void>(a)
        let ticketA = try need(life.begin { calls.append("A-original") })
        try expect(life.begin({ calls.append("duplicate") }) == nil, "F1 duplicate begin cannot replace active capture")
        _ = life.update(a)
        life.sample(ticketA.id)?()
        try expect(calls == ["A-original"], "F1 same-identity acknowledgment retains original captured callback")
        let cancelledA = life.update(b)
        try expect(cancelledA?.id == ticketA.id && life.isRetired, "F1 A to B shared parameter permanently retires old native instance")
        try expect(life.sample(ticketA.id) == nil && life.finish(ticketA.id) == nil, "F1 late A sample and end refuse after target change")
        _ = life.update(a)
        try expect(life.begin({ calls.append("A-rebound") }) == nil, "F1 A to B to A never resurrects retired control")
        var freshB = EditorInteractionLifetime<() -> Void>(b)
        let ticketB = try need(freshB.begin { calls.append("B-fresh") })
        try expect(freshB.finish(ticketA.id) == nil && freshB.active?.id == ticketB.id, "F1 old ticket cannot end replacement target")
        let endedB = freshB.finish(ticketB.id); endedB?.payload()
        try expect(freshB.finish(ticketB.id) == nil && freshB.sample(ticketB.id) == nil, "F1 end is once and later sample cannot turn into a discrete edit")
        let cancelTicket = try need(freshB.begin { calls.append("cancelled") })
        let once = freshB.finish(cancelTicket.id)
        try expect(once != nil && freshB.retire() == nil && freshB.finish(cancelTicket.id) == nil, "F1 cancel then dismantle/end cannot terminate twice")
        let reopened = try await fixture.session.beginEdit(two.handle.target, admission: { _ in })
        let newHandle = EditorSettingIdentity(handle: reopened.handle, part: partA.id, parameter: "thresholdDb")
        var handleLife = EditorInteractionLifetime<String>(a)
        let oldHandleTicket = try need(handleLife.begin("captured old handle"))
        _ = handleLife.update(newHandle)
        try expect(a.part == newHandle.part && a.handle != newHandle.handle && handleLife.sample(oldHandleTicket.id) == nil && handleLife.isRetired, "F1 same part UUID with new edit handle refuses old interaction")
        let attack = try need(reopened.parts.first { $0.id == partA.id }?.settings.first { $0.parameter == "attackSeconds" })
        var physicalLife = EditorInteractionLifetime<LibraryEditSetting>(EditorSettingIdentity(handle: reopened.handle, part: partA.id, parameter: attack.parameter))
        let physicalTicket = try need(physicalLife.begin(attack))
        let captured = try need(physicalLife.sample(physicalTicket.id))
        try expect(abs(try EditorSettingFormat.parse("8 ms", setting: captured) - 0.008) < 1e-12, "F1 captured descriptor preserves typed milliseconds")
        do { _ = try EditorSettingFormat.parse("0.1 ms", setting: captured); throw CheckError(message: "captured descriptor minimum lost") }
        catch is CheckError { throw CheckError(message: "captured descriptor minimum lost") }
        catch { print("PASS F1 captured descriptor preserves actual refusal") }
        try expect(calls == ["A-original", "B-fresh"], "F1 retired or cancelled captures never invoke a replacement callback")

        let useFixture = try await EditorOwnedFixture.make()
        let session = useFixture.session
        let definitions = try await session.snapshot().definitions
        let everyday = try need(definitions.first { $0.name == "Everyday" })
        _ = try await session.select(everyday.id, on: "com.colliderli.iina")
        let roster = try await session.liveState()
        let safari = try need(roster.assignments.first { $0.binding.target == "com.apple.Safari" }?.binding)
        let iina = try need(roster.assignments.first { $0.binding.target == "com.colliderli.iina" }?.binding)
        let useA = try await session.inspectEdit(useFixture.edit.handle)
        let useB = try await session.beginEdit(.use(iina), admission: { _ in })
        let dynamicsA = try need(useA.parts.first { $0.type == "dynamics" })
        let headBefore = try await session.snapshot().definitions
        try expect(EditorInspectorPolicy.allowsBypass(useA.handle.target, editing: false), "F2 use quick-off available outside visible Edit")
        try expect(!EditorInspectorPolicy.allowsBypass(.definition(everyday.id), editing: false) && EditorInspectorPolicy.allowsBypass(.definition(everyday.id), editing: true), "F2 offline workspace omits quick-off unless in Edit")
        let event = EditorPartEvent(useA, .command(.bypassPart(dynamicsA.id, true)))
        guard case .command(let command) = event.action else { throw CheckError(message: "wrong bypass event") }
        let offA = try await session.edit(event.handle, expectedGeneration: event.generation, command: command)
        let afterB = try await session.inspectEdit(useB.handle)
        try expect(event.handle.target == .use(safari) && offA.parts.first { $0.id == dynamicsA.id }?.bypassed == true, "F2 exact-use bypass command updates intended use")
        try expect(afterB.parts.allSatisfy { !$0.bypassed } && !offA.pendingStructural, "F2 other use unchanged and quick bypass not structural")
        let headAfter = try await session.snapshot().definitions
        let afterLive = try await session.liveState()
        try expect(headAfter == headBefore && !afterLive.isEnabled, "F2 library heads preserved and all fixture commands remain OFF")
        print("PASS correction lifetime and quick-off checks complete; no native responder or audio claim")
    }
}
