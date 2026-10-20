import Foundation
@testable import UI
@testable import ViewModel
import XCTest

/// New concrete handle/result seam only; no new production protocols assumed.
@MainActor
final class AcceptedParameterHandleTests: XCTestCase {
    private var fixture: AcceptedParameterFixture!
    private var scheduler: AcceptedParameterScheduler!

    override func setUp() async throws {
        try await super.setUp()
        fixture = try AcceptedParameterFixture()
        scheduler = AcceptedParameterScheduler()
    }
    override func tearDown() async throws {
        try fixture.cleanUp()
        fixture = nil
        scheduler = nil
        try await super.tearDown()
    }
    private func makeModel() -> AppViewModel {
        AppViewModel(capture: fixture.capture, engine: fixture.engine, registry: fixture.registry,
                     defaults: fixture.defaults, scheduleParameterEdit: scheduler.schedule)
    }

    func test_application_results_are_synchronous_scoped_revisioned_serial_and_preserve_optional_actual() throws {
        let model = makeModel()
        let node = try fixture.node(in: model)
        let handle = try XCTUnwrap(model.makeParameterEditHandle(node: node, parameterID: "amount"))
        var results: [ParameterApplicationResult] = []
        handle.setApplicationResultHandler { results.append($0) }
        XCTAssertTrue(model.acceptParameterValue(7, for: handle, intentRevision: 41))
        XCTAssertEqual(model.pendingParameterValue(for: handle), 7)
        XCTAssertTrue(results.isEmpty)
        try scheduler.runNext()
        XCTAssertEqual(results.count, 1)
        let first = try XCTUnwrap(results.first)
        XCTAssertEqual(first.sessionID, handle.sessionID)
        XCTAssertEqual(first.intentRevision, 41)
        XCTAssertEqual(first.requestedValue, 7)
        XCTAssertEqual(first.actualValue, 7)
        XCTAssertEqual(first.outcome, .applied)
        node.readbackAvailable = false
        XCTAssertTrue(model.commitParameterValue(8, for: handle, intentRevision: 42))
        XCTAssertEqual(results.count, 2, "Immediate callback must already have its caller revision")
        let immediate = try XCTUnwrap(results.last)
        XCTAssertEqual(immediate.intentRevision, 42)
        XCTAssertNil(immediate.actualValue)
        XCTAssertGreaterThan(immediate.applicationSerial, first.applicationSerial)
        XCTAssertTrue(model.acceptParameterValue(9, for: handle, intentRevision: 43))
        XCTAssertTrue(model.finishParameterEditing(handle))
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results.last?.intentRevision, 43)
        XCTAssertTrue(model.acceptParameterValue(6, for: handle, intentRevision: 44))
        model.savePreset(to: fixture.url("flush-result.tnf"))
        XCTAssertEqual(results.count, 4, "Save emits before returning, without waiting for a model echo")
        XCTAssertEqual(results.last?.intentRevision, 44)
        let serials = results.map { $0.applicationSerial }
        XCTAssertTrue(zip(serials, serials.dropFirst()).allSatisfy { pair in pair.0 < pair.1 })
        XCTAssertEqual(try fixture.exportedValue("flush-result.tnf"), 6)
    }

    func test_multi_handle_latest_intent_wins_and_retired_session_cannot_overwrite_or_receive_old_tick() throws {
        let model = makeModel()
        let node = try fixture.node(in: model)
        let a = try XCTUnwrap(model.makeParameterEditHandle(node: node, parameterID: "amount"))
        let b = try XCTUnwrap(model.makeParameterEditHandle(node: node, parameterID: "amount"))
        var aResults = 0
        var bResults = 0
        a.setApplicationResultHandler { _ in aResults += 1 }
        b.setApplicationResultHandler { _ in bResults += 1 }
        XCTAssertTrue(model.acceptParameterValue(4, for: a, intentRevision: 1))
        XCTAssertTrue(model.acceptParameterValue(7, for: b, intentRevision: 1))
        model.retireParameterEditHandle(a)
        XCTAssertFalse(model.commitParameterValue(9, for: a, intentRevision: 2))
        model.savePreset(to: fixture.url("multi.tnf"))
        scheduler.runAll()
        XCTAssertEqual(node.attempts, [7])
        XCTAssertEqual(aResults, 0)
        XCTAssertEqual(bResults, 1)
    }

    func test_retirement_flushes_result_before_invalidating_and_already_delivered_tick_cannot_repeat_it() throws {
        let model = makeModel()
        let node = try fixture.node(in: model)
        let handle = try XCTUnwrap(model.makeParameterEditHandle(node: node, parameterID: "amount"))
        var results: [ParameterApplicationResult] = []
        handle.setApplicationResultHandler { results.append($0) }
        XCTAssertTrue(model.acceptParameterValue(7, for: handle, intentRevision: 9))
        let tick = try scheduler.takeNext()

        model.retireParameterEditHandle(handle)

        XCTAssertEqual(node.value, 7)
        XCTAssertEqual(results.count, 1, "The scoped consumer receives actual application before retirement")
        XCTAssertEqual(results.first?.intentRevision, 9)
        tick()
        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(model.acceptParameterValue(8, for: handle, intentRevision: 10))
        XCTAssertEqual(node.attempts, [7])
    }

    func test_successful_immediate_update_supersedes_pending_but_rejected_update_does_not_lose_newer_edit() throws {
        let model = makeModel()
        let node = try fixture.node(in: model)
        let handle = try XCTUnwrap(model.makeParameterEditHandle(node: node, parameterID: "amount"))
        XCTAssertTrue(model.acceptParameterValue(7, for: handle, intentRevision: 1))
        let old = try scheduler.takeNext()
        model.updateParameter(nodeID: node.id, paramID: "amount", value: 3)
        old()
        XCTAssertEqual(node.attempts, [3])
        XCTAssertTrue(model.acceptParameterValue(8, for: handle, intentRevision: 2))
        model.updateParameter(nodeID: node.id, paramID: "amount", value: 11)
        model.savePreset(to: fixture.url("immediate.tnf"))
        old()
        XCTAssertEqual(try fixture.exportedValue("immediate.tnf"), 8)
        XCTAssertEqual(node.attempts, [3, 8])
    }

    func test_invalid_accepts_do_not_replace_pending_and_fake_same_uuid_object_cannot_create_valid_handle() throws {
        let model = makeModel()
        let node = try fixture.node(in: model)
        let handle = try XCTUnwrap(model.makeParameterEditHandle(node: node, parameterID: "amount"))
        XCTAssertTrue(model.acceptParameterValue(7, for: handle, intentRevision: 1))
        for value: Float in [.nan, .infinity, -1, 11] {
            XCTAssertFalse(model.acceptParameterValue(value, for: handle, intentRevision: 2))
        }
        XCTAssertEqual(model.pendingParameterValue(for: handle), 7)
        let impostor = AcceptedParameterNode()
        impostor.id = node.id
        XCTAssertNil(model.makeParameterEditHandle(node: impostor, parameterID: "amount"))
        XCTAssertNil(model.makeParameterEditHandle(node: node, parameterID: "unknown"))
        model.savePreset(to: fixture.url("validated.tnf"))
        XCTAssertEqual(try fixture.exportedValue("validated.tnf"), 7)
    }

    func test_failure_is_per_target_survives_retirement_and_other_parameter_success_cannot_clear_it() throws {
        let model = makeModel()
        let node = try fixture.node(in: model)
        let failed = try XCTUnwrap(model.makeParameterEditHandle(node: node, parameterID: "amount"))
        var results: [ParameterApplicationResult] = []
        failed.setApplicationResultHandler { results.append($0) }
        node.behavior = .rejected
        XCTAssertTrue(model.acceptParameterValue(7, for: failed, intentRevision: 1))
        try scheduler.runNext()
        XCTAssertEqual(results.count, 1)
        let result = try XCTUnwrap(results.first)
        XCTAssertEqual(result.outcome, .rejected)
        XCTAssertEqual(result.actualValue, 2)
        model.retireParameterEditHandle(failed)
        node.behavior = .exact
        let other = try XCTUnwrap(model.makeParameterEditHandle(node: node, parameterID: "other"))
        XCTAssertTrue(model.commitParameterValue(4, for: other, intentRevision: 1))
        model.savePreset(to: fixture.url("still-blocked.tnf"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url("still-blocked.tnf").path))
        let repaired = try XCTUnwrap(model.makeParameterEditHandle(node: node, parameterID: "amount"))
        XCTAssertTrue(model.commitParameterValue(8, for: repaired, intentRevision: 1))
        model.savePreset(to: fixture.url("repaired.tnf"))
        XCTAssertEqual(try fixture.exportedValue("repaired.tnf"), 8)
    }

    func test_obsolete_generation_cannot_emit_results_or_reconcile_another_editor_session() throws {
        let model = makeModel()
        let node = try fixture.node(in: model)
        let old = try XCTUnwrap(model.makeParameterEditHandle(node: node, parameterID: "amount"))
        var results: [ParameterApplicationResult] = []
        old.setApplicationResultHandler { results.append($0) }
        XCTAssertTrue(model.commitParameterValue(4, for: old, intentRevision: 1))
        let oldResult = try XCTUnwrap(results.first)
        model.savePreset(to: fixture.url("replace.tnf"))
        XCTAssertTrue(model.acceptParameterValue(7, for: old, intentRevision: 2))
        let oldTick = try scheduler.takeNext()
        model.loadPreset(from: fixture.url("replace.tnf"))
        oldTick()
        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(model.commitParameterValue(9, for: old, intentRevision: 3))
        let replacement = try fixture.node(in: model)
        let editor = fixture.writer(replacement, model).makeEditor()
        editor.drag(to: 0.8)
        editor.receiveApplicationResult(oldResult)
        XCTAssertEqual(editor.value, 8)
        model.savePreset(to: fixture.url("new-session.tnf"))
        XCTAssertEqual(try fixture.exportedValue("new-session.tnf"), 8)
        XCTAssertEqual(results.count, 1)
    }
}
