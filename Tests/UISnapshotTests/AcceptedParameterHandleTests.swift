import AVFoundation
import Effects
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

    func test_immediate_setter_reentrant_old_tick_is_invalid_before_native_application_finishes() throws {
        let model = makeModel()
        let node = try fixture.node(in: model)
        let handle = try XCTUnwrap(model.makeParameterEditHandle(node: node, parameterID: "amount"))
        XCTAssertTrue(model.acceptParameterValue(7, for: handle, intentRevision: 1))
        let oldTick = try scheduler.takeNext()
        node.afterAttempt = { [weak node] _ in
            node?.afterAttempt = nil
            oldTick()
        }

        model.updateParameter(nodeID: node.id, paramID: "amount", value: 3)

        XCTAssertEqual(node.attempts, [3])
        XCTAssertEqual(node.value, 3)
        model.savePreset(to: fixture.url("reentrant-immediate.tnf"))
        XCTAssertEqual(try fixture.exportedValue("reentrant-immediate.tnf"), 3)
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

    func test_coalescer_outer_rejected_outcome_after_nested_success_reconciles_captured_session_and_drains() throws {
        // Lower-level apply-outcome harness only. The unchanged factory fake
        // throws BEFORE afterAttempt; this is not factory late-throw coverage.
        let model = makeModel()
        let node = try fixture.node(in: model)
        node.readbackAvailable = false
        var edits: AcceptedParameterEdits!
        edits = AcceptedParameterEdits(
            schedule: scheduler.schedule,
            isCurrent: { ObjectIdentifier($0) == ObjectIdentifier(node) },
            apply: { target, parameter, value in
                do {
                    try target.setParameter(parameter, value: value)
                } catch {
                    XCTFail("Harness fake exact setter unexpectedly threw: \(error)")
                    return ParameterApplication(success: false, actual: target.parameterValue(parameter))
                }
                if value == 4 {
                    edits.applyImmediate(node: target, parameter: parameter, value: 8)
                    // Deliberately control the OUTCOME after nested success;
                    // do not pretend the fixture's setter threw after callback.
                    return ParameterApplication(success: false, actual: nil)
                }
                return ParameterApplication(success: true, actual: target.parameterValue(parameter))
            }
        )
        defer { edits = nil }
        let handle = try XCTUnwrap(edits.makeHandle(node: node, parameterID: "amount"))
        var results: [ParameterApplicationResult] = []
        handle.setApplicationResultHandler { results.append($0) }
        XCTAssertTrue(edits.accept(7, for: handle, intentRevision: 41))
        let oldTick = try scheduler.takeNext()

        edits.applyImmediate(node: node, parameter: "amount", value: 4)

        XCTAssertEqual(results.count, 1, "Captured live session requires reconciliation despite outer rejection")
        XCTAssertEqual(results.first?.sessionID, handle.sessionID)
        XCTAssertEqual(results.first?.intentRevision, 41)
        XCTAssertEqual(results.first?.requestedValue, 4, "Acknowledgement must retain the actual outer request")
        XCTAssertNil(results.first?.actualValue)
        XCTAssertEqual(results.first?.outcome, .rejected, "Nested success cannot repurpose the outer outcome")
        XCTAssertGreaterThan(results.first?.applicationSerial ?? 0, 0)
        XCTAssertNil(edits.pendingValue(for: handle), "Nested success supersedes original unattempted 7")
        XCTAssertNil(node.parameterValue("amount"))
        XCTAssertEqual(node.value, 8, "Fake storage only; no current native readback is claimed")
        XCTAssertEqual(node.attempts, [4, 8])
        XCTAssertTrue(edits.finish(handle), "Older outer rejection cannot reinstate failure after newer success 8")
        XCTAssertTrue(edits.flushAll(), "The coalescer drain used by Save must succeed; not a factory export test")
        oldTick()
        scheduler.runAll()
        oldTick()
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(node.attempts, [4, 8], "Original pending 7 cannot return, and outcomes must not retry")
        XCTAssertEqual(node.value, 8)
        XCTAssertNil(edits.pendingValue(for: handle))
        XCTAssertTrue(edits.flushAll())
    }

    // New-API coverage added AFTER implementation under GREEN-GO. These
    // methods are not part of the pre-fix behavioral-red claim.
    func test_successful_presentation_orders_actual_or_successful_request_but_never_pending_or_rejected_input() throws {
        let model = makeModel()
        let node = try fixture.node(in: model)
        let handle = try XCTUnwrap(model.makeParameterEditHandle(node: node, parameterID: "amount"))
        XCTAssertNil(handle.successfulPresentation)
        XCTAssertTrue(model.acceptParameterValue(7, for: handle, intentRevision: 1))
        XCTAssertNil(handle.successfulPresentation, "Queue admission is not setter success")
        var callbackBasis: ParameterSuccessfulPresentation?
        handle.setApplicationResultHandler { [weak handle] _ in callbackBasis = handle?.successfulPresentation }
        try scheduler.runNext()
        let first = try XCTUnwrap(handle.successfulPresentation)
        XCTAssertEqual(first.value, 7)
        XCTAssertGreaterThan(first.operationOrder, 0)
        XCTAssertEqual(callbackBasis?.operationOrder, first.operationOrder, "Publish success before callback")
        node.behavior = .roundedDown
        XCTAssertTrue(model.commitParameterValue(5.5, for: handle, intentRevision: 2))
        let normalized = try XCTUnwrap(handle.successfulPresentation)
        XCTAssertEqual(normalized.value, 5, "Available actual, not requested 5.5, supplies history")
        XCTAssertGreaterThan(normalized.operationOrder, first.operationOrder)
        node.behavior = .exact
        node.readbackAvailable = false
        XCTAssertTrue(model.commitParameterValue(4, for: handle, intentRevision: 3))
        let requested = try XCTUnwrap(handle.successfulPresentation)
        XCTAssertEqual(requested.value, 4, "Successful nil application supplies presentation, not actual")
        XCTAssertGreaterThan(requested.operationOrder, normalized.operationOrder)
        node.behavior = .rejected
        XCTAssertFalse(model.commitParameterValue(8, for: handle, intentRevision: 4))
        XCTAssertEqual(handle.successfulPresentation?.operationOrder, requested.operationOrder)
        XCTAssertEqual(handle.successfulPresentation?.value, 4)
        XCTAssertEqual(callbackBasis?.operationOrder, requested.operationOrder)
        XCTAssertEqual(node.attempts, [7, 5.5, 4, 8])
        handle.setApplicationResultHandler { _ in }
    }

    func test_successful_presentation_nested_public_success_order_survives_later_outer_callback_serial() throws {
        let model = makeModel()
        let node = try fixture.node(in: model)
        let handle = try XCTUnwrap(model.makeParameterEditHandle(node: node, parameterID: "amount"))
        node.readbackAvailable = false
        XCTAssertTrue(model.acceptParameterValue(7, for: handle, intentRevision: 1))
        let oldTick = try scheduler.takeNext()
        var innerOrder: UInt64?
        node.afterAttempt = { [weak node] _ in
            guard let node else { return XCTFail("Expected live node") }
            node.afterAttempt = nil
            model.updateParameter(nodeID: node.id, paramID: "amount", value: 8)
            innerOrder = handle.successfulPresentation?.operationOrder
            XCTAssertEqual(handle.successfulPresentation?.value, 8)
        }
        var result: ParameterApplicationResult?
        var callbackBasis: ParameterSuccessfulPresentation?
        handle.setApplicationResultHandler { [weak handle] in
            result = $0
            callbackBasis = handle?.successfulPresentation
        }

        model.updateParameter(nodeID: node.id, paramID: "amount", value: 4)

        let order = try XCTUnwrap(innerOrder)
        XCTAssertEqual(handle.successfulPresentation?.operationOrder, order)
        XCTAssertEqual(handle.successfulPresentation?.value, 8)
        XCTAssertEqual(callbackBasis?.operationOrder, order)
        XCTAssertEqual(callbackBasis?.value, 8)
        XCTAssertEqual(result?.requestedValue, 4, "Getter must not repurpose the outer result")
        XCTAssertNil(result?.actualValue)
        XCTAssertEqual(result?.outcome, .applied)
        oldTick()
        XCTAssertEqual(node.attempts, [4, 8])
        handle.setApplicationResultHandler { _ in }
    }

    func test_successful_presentation_older_outer_success_survives_newer_rejection_without_clearing_failure() throws {
        let model = makeModel()
        let node = try fixture.node(in: model)
        let handle = try XCTUnwrap(model.makeParameterEditHandle(node: node, parameterID: "amount"))
        node.readbackAvailable = false
        node.afterAttempt = { [weak node] _ in
            guard let node else { return XCTFail("Expected live node") }
            node.afterAttempt = nil
            node.behavior = .rejected
            model.updateParameter(nodeID: node.id, paramID: "amount", value: 8)
            XCTAssertNil(handle.successfulPresentation, "Outer invocation has not completed yet")
            node.behavior = .exact
        }

        model.updateParameter(nodeID: node.id, paramID: "amount", value: 4)

        let outer = try XCTUnwrap(handle.successfulPresentation)
        XCTAssertEqual(outer.value, 4)
        XCTAssertFalse(model.finishParameterEditing(handle), "History is separate from latest completed failure")
        XCTAssertTrue(model.commitParameterValue(9, for: handle, intentRevision: 1))
        XCTAssertGreaterThan(try XCTUnwrap(handle.successfulPresentation).operationOrder, outer.operationOrder)
        XCTAssertEqual(handle.successfulPresentation?.value, 9)
        XCTAssertTrue(model.finishParameterEditing(handle))
        XCTAssertEqual(node.attempts, [4, 8, 9])
    }

    func test_successful_presentation_checks_owner_retirement_and_generation_while_failed_load_preserves_it() throws {
        let model = makeModel()
        let node = try fixture.node(in: model)
        let handle = try XCTUnwrap(model.makeParameterEditHandle(node: node, parameterID: "amount"))
        XCTAssertTrue(model.commitParameterValue(4, for: handle, intentRevision: 1))
        let order = try XCTUnwrap(handle.successfulPresentation).operationOrder
        let foreignModel = makeModel()
        XCTAssertFalse(foreignModel.commitParameterValue(8, for: handle, intentRevision: 2))
        XCTAssertEqual(handle.successfulPresentation?.operationOrder, order)
        model.loadPreset(from: fixture.url("getter-missing.tnf"))
        XCTAssertEqual(handle.successfulPresentation?.value, 4)
        model.retireParameterEditHandle(handle)
        XCTAssertNil(handle.successfulPresentation)
        let fresh = try XCTUnwrap(model.makeParameterEditHandle(node: node, parameterID: "amount"))
        XCTAssertEqual(fresh.successfulPresentation?.operationOrder, order, "History belongs to live target, not session")
        model.savePreset(to: fixture.url("getter-replacement.tnf"))
        model.loadPreset(from: fixture.url("getter-replacement.tnf"))
        XCTAssertNil(fresh.successfulPresentation, "Retained old object/session is invalid after generation change")
        let replacement = try fixture.node(in: model)
        XCTAssertEqual(replacement.id, node.id)
        XCTAssertFalse(replacement === node)
        let renewed = try XCTUnwrap(model.makeParameterEditHandle(node: replacement, parameterID: "amount"))
        XCTAssertNil(renewed.successfulPresentation, "Restored actual is not an invoked success in this generation")
    }

    func test_successful_presentation_rejects_changed_concrete_identity_and_prunes_removed_targets() throws {
        let node = AcceptedParameterNode()
        var current = true
        let edits = AcceptedParameterEdits(
            schedule: scheduler.schedule, isCurrent: { candidate in current && candidate === node },
            apply: { target, parameter, value in
                do {
                    try target.setParameter(parameter, value: value)
                    return ParameterApplication(success: true, actual: target.parameterValue(parameter))
                } catch {
                    return ParameterApplication(success: false, actual: target.parameterValue(parameter))
                }
            }
        )
        let handle = try XCTUnwrap(edits.makeHandle(node: node, parameterID: "amount"))
        XCTAssertTrue(edits.commit(4, for: handle, intentRevision: 1))
        let id = node.id
        node.id = UUID()
        XCTAssertNil(handle.successfulPresentation)
        node.id = id
        XCTAssertNil(handle.successfulPresentation, "Invalid concrete identity history was pruned")
        XCTAssertTrue(edits.commit(6, for: handle, intentRevision: 2))
        XCTAssertEqual(handle.successfulPresentation?.value, 6)
        current = false
        XCTAssertNil(handle.successfulPresentation)
        XCTAssertTrue(edits.flushAll())
        current = true
        let renewed = try XCTUnwrap(edits.makeHandle(node: node, parameterID: "amount"))
        XCTAssertNil(renewed.successfulPresentation, "Removed history cannot reappear on a later handle")
        XCTAssertEqual(node.attempts, [4, 6])
    }

    func test_successful_presentation_records_and_retained_handle_do_not_retain_node_or_owner() throws {
        var node: AcceptedParameterNode? = AcceptedParameterNode()
        weak var weakNode = node
        var edits: AcceptedParameterEdits? = AcceptedParameterEdits(
            schedule: scheduler.schedule, isCurrent: { [weak node] candidate in candidate === node },
            apply: { target, parameter, value in
                do {
                    try target.setParameter(parameter, value: value)
                    return ParameterApplication(success: true, actual: target.parameterValue(parameter))
                } catch {
                    return ParameterApplication(success: false, actual: target.parameterValue(parameter))
                }
            }
        )
        weak var weakOwner = edits
        let handle = try XCTUnwrap(edits?.makeHandle(node: XCTUnwrap(node), parameterID: "amount"))
        XCTAssertTrue(try XCTUnwrap(edits).commit(4, for: handle, intentRevision: 1))
        XCTAssertEqual(handle.successfulPresentation?.value, 4)
        node = nil
        XCTAssertNil(weakNode, "Completed-success records and handle must own the node weakly")
        XCTAssertNil(handle.successfulPresentation)
        edits = nil
        XCTAssertNil(weakOwner)
        XCTAssertNil(handle.successfulPresentation)
    }

    func test_successful_presentation_getter_never_performs_native_reads() throws {
        let node = R6ReadCountingParameterNode()
        let identity = ObjectIdentifier(node)
        let edits = AcceptedParameterEdits(
            schedule: scheduler.schedule, isCurrent: { ObjectIdentifier($0) == identity },
            apply: { target, parameter, value in
                do {
                    try target.setParameter(parameter, value: value)
                    return ParameterApplication(success: true, actual: target.parameterValue(parameter))
                } catch {
                    return ParameterApplication(success: false, actual: target.parameterValue(parameter))
                }
            }
        )
        let handle = try XCTUnwrap(edits.makeHandle(node: node, parameterID: "amount"))
        XCTAssertNil(handle.successfulPresentation)
        XCTAssertEqual(node.nativeReads, 0)
        XCTAssertTrue(edits.commit(4, for: handle, intentRevision: 1))
        XCTAssertEqual(node.nativeReads, 1, "Only the application harness reads native state")
        let first = try XCTUnwrap(handle.successfulPresentation)
        for _ in 0..<3 {
            XCTAssertEqual(handle.successfulPresentation?.operationOrder, first.operationOrder)
            XCTAssertEqual(handle.successfulPresentation?.value, 4)
        }
        XCTAssertEqual(node.nativeReads, 1)
        XCTAssertTrue(edits.accept(7, for: handle, intentRevision: 2))
        XCTAssertEqual(handle.successfulPresentation?.value, 4)
        XCTAssertEqual(node.nativeReads, 1)
        node.base.readbackAvailable = false
        XCTAssertTrue(edits.commit(8, for: handle, intentRevision: 3))
        XCTAssertEqual(handle.successfulPresentation?.value, 8)
        XCTAssertGreaterThan(try XCTUnwrap(handle.successfulPresentation).operationOrder, first.operationOrder)
        XCTAssertEqual(node.nativeReads, 2)
        node.base.behavior = .rejected
        XCTAssertFalse(edits.commit(9, for: handle, intentRevision: 4))
        XCTAssertEqual(handle.successfulPresentation?.value, 8)
        XCTAssertEqual(node.nativeReads, 3)
        edits.retire(handle)
        XCTAssertNil(handle.successfulPresentation)
        scheduler.runAll()
        XCTAssertEqual(node.nativeReads, 3, "Retired getter and obsolete ticks cannot read native state")
        XCTAssertEqual(node.base.attempts, [4, 8, 9])
    }
}

/// Test-local forwarder solely for the getter's no-native-read assertion.
/// Shared fixtures and production protocols/setters remain untouched.
private final class R6ReadCountingParameterNode: EffectNode {
    static let typeIdentifier = AcceptedParameterNode.typeIdentifier
    let base = AcceptedParameterNode()
    private(set) var nativeReads = 0
    var id: UUID { base.id }
    var displayName: String {
        get { base.displayName }
        set { base.displayName = newValue }
    }
    var bypass: Bool {
        get { base.bypass }
        set { base.bypass = newValue }
    }
    var wetDryMix: Float {
        get { base.wetDryMix }
        set { base.wetDryMix = newValue }
    }
    var parameters: [EffectParameter] { base.parameters }
    var inputBus: AVAudioMixerNode { base.inputBus }
    var outputBus: AVAudioMixerNode { base.outputBus }
    func setParameter(_ identifier: String, value: Float) throws { try base.setParameter(identifier, value: value) }
    func parameterValue(_ identifier: String) -> Float? {
        nativeReads += 1
        return base.parameterValue(identifier)
    }
    func attach(to engine: AVAudioEngine) throws { try base.attach(to: engine) }
    func detach() { base.detach() }
    func snapshot() -> EffectState { base.snapshot() }
    func restore(from state: EffectState) throws { try base.restore(from: state) }
}

// Getter-specific coverage added after the R7 API under exact GREEN-GO;
// these methods are not pre-fix behavioral-red witnesses.
extension AcceptedParameterHandleTests {
    func test_started_order_is_zero_until_invocation_then_tracks_rejection_and_is_scoped_per_target() throws {
        let model = makeModel()
        let node = try fixture.node(in: model)
        let handle = try XCTUnwrap(model.makeParameterEditHandle(node: node, parameterID: "amount"))
        let other = try XCTUnwrap(model.makeParameterEditHandle(node: node, parameterID: "other"))
        let secondNode = try fixture.node(in: model, at: 1)
        let second = try XCTUnwrap(model.makeParameterEditHandle(node: secondNode, parameterID: "amount"))
        XCTAssertEqual(handle.latestStartedOperationOrder, 0)
        XCTAssertEqual(other.latestStartedOperationOrder, 0)
        XCTAssertEqual(second.latestStartedOperationOrder, 0)
        XCTAssertTrue(model.acceptParameterValue(7, for: handle, intentRevision: 1))
        let oldTick = try scheduler.takeNext()
        XCTAssertEqual(handle.latestStartedOperationOrder, 0, "Pending admission is not invocation")
        var insideOrder: UInt64?
        node.afterAttempt = { [weak node] _ in
            node?.afterAttempt = nil
            insideOrder = handle.latestStartedOperationOrder
            XCTAssertGreaterThan(insideOrder ?? 0, 0)
            XCTAssertNil(handle.successfulPresentation, "Started order is visible before success publication")
        }

        model.updateParameter(nodeID: node.id, paramID: "amount", value: 4)

        let first = try XCTUnwrap(insideOrder)
        XCTAssertEqual(handle.latestStartedOperationOrder, first)
        XCTAssertEqual(handle.successfulPresentation?.operationOrder, first)
        XCTAssertEqual(other.latestStartedOperationOrder, 0)
        XCTAssertEqual(second.latestStartedOperationOrder, 0)
        node.behavior = .rejected
        XCTAssertFalse(model.commitParameterValue(8, for: handle, intentRevision: 2))
        let rejected = try XCTUnwrap(handle.latestStartedOperationOrder)
        XCTAssertGreaterThan(rejected, first)
        XCTAssertEqual(handle.successfulPresentation?.operationOrder, first, "Rejection advances start, not success")
        node.behavior = .exact
        XCTAssertTrue(model.commitParameterValue(3, for: other, intentRevision: 1))
        XCTAssertGreaterThan(try XCTUnwrap(other.latestStartedOperationOrder), rejected)
        XCTAssertEqual(handle.latestStartedOperationOrder, rejected)
        XCTAssertEqual(second.latestStartedOperationOrder, 0)
        oldTick()
        scheduler.runAll()
        XCTAssertEqual(handle.latestStartedOperationOrder, rejected, "Obsolete tickets cannot start invocations")
        XCTAssertEqual(node.attempts, [4, 8, 3])
        XCTAssertTrue(secondNode.attempts.isEmpty)
    }

    func test_started_order_is_visible_inside_nested_apply_and_never_rolls_back_on_outer_completion() throws {
        let model = makeModel()
        let node = try fixture.node(in: model)
        let handle = try XCTUnwrap(model.makeParameterEditHandle(node: node, parameterID: "amount"))
        node.readbackAvailable = false
        XCTAssertTrue(model.acceptParameterValue(7, for: handle, intentRevision: 1))
        let oldTick = try scheduler.takeNext()
        var outerOrder: UInt64?
        var innerOrder: UInt64?
        node.afterAttempt = { [weak node] _ in
            guard let target = node else { XCTFail("Expected live node"); return }
            node?.afterAttempt = nil
            outerOrder = handle.latestStartedOperationOrder
            XCTAssertGreaterThan(outerOrder ?? 0, 0)
            XCTAssertNil(handle.successfulPresentation)
            node?.afterAttempt = { [weak node] _ in
                node?.afterAttempt = nil
                innerOrder = handle.latestStartedOperationOrder
                XCTAssertGreaterThan(innerOrder ?? 0, outerOrder ?? 0)
                XCTAssertNil(handle.successfulPresentation, "Neither invocation has completed inside inner apply")
            }
            model.updateParameter(nodeID: target.id, paramID: "amount", value: 8)
            XCTAssertEqual(handle.latestStartedOperationOrder, innerOrder)
            XCTAssertEqual(handle.successfulPresentation?.operationOrder, innerOrder)
        }

        model.updateParameter(nodeID: node.id, paramID: "amount", value: 4)

        let outer = try XCTUnwrap(outerOrder)
        let inner = try XCTUnwrap(innerOrder)
        XCTAssertGreaterThan(inner, outer)
        XCTAssertEqual(handle.latestStartedOperationOrder, inner)
        XCTAssertEqual(handle.successfulPresentation?.operationOrder, inner)
        XCTAssertEqual(handle.successfulPresentation?.value, 8)
        oldTick()
        scheduler.runAll()
        XCTAssertEqual(handle.latestStartedOperationOrder, inner)
        XCTAssertEqual(node.attempts, [4, 8])
    }

    func test_started_order_guards_owner_retirement_and_generation_but_failed_load_keeps_live_history() throws {
        let model = makeModel()
        let node = try fixture.node(in: model)
        let handle = try XCTUnwrap(model.makeParameterEditHandle(node: node, parameterID: "amount"))
        XCTAssertTrue(model.commitParameterValue(4, for: handle, intentRevision: 1))
        let order = try XCTUnwrap(handle.latestStartedOperationOrder)
        let foreignModel = makeModel()
        XCTAssertFalse(foreignModel.commitParameterValue(8, for: handle, intentRevision: 2))
        foreignModel.retireParameterEditHandle(handle)
        XCTAssertEqual(handle.latestStartedOperationOrder, order, "Foreign owner cannot invoke or retire this session")
        model.loadPreset(from: fixture.url("r7-started-missing.tnf"))
        XCTAssertNotNil(model.lastError)
        XCTAssertEqual(handle.latestStartedOperationOrder, order)
        model.clearError()
        model.retireParameterEditHandle(handle)
        XCTAssertNil(handle.latestStartedOperationOrder)
        let fresh = try XCTUnwrap(model.makeParameterEditHandle(node: node, parameterID: "amount"))
        XCTAssertEqual(fresh.latestStartedOperationOrder, order, "Order belongs to the concrete target, not a session")
        let url = fixture.url("r7-started-replacement.tnf")
        model.savePreset(to: url)
        model.loadPreset(from: url)
        XCTAssertNil(model.lastError)
        XCTAssertNil(fresh.latestStartedOperationOrder)
        let replacement = try fixture.node(in: model)
        XCTAssertEqual(replacement.id, node.id)
        XCTAssertFalse(replacement === node)
        let renewed = try XCTUnwrap(model.makeParameterEditHandle(node: replacement, parameterID: "amount"))
        XCTAssertEqual(renewed.latestStartedOperationOrder, 0, "A restored generation has no invoked operation")
    }

    func test_started_order_rejects_changed_UUID_and_current_target_then_prunes_invalid_history() throws {
        let node = R6ReadCountingParameterNode()
        var current = true
        let edits = AcceptedParameterEdits(
            schedule: scheduler.schedule, isCurrent: { candidate in current && candidate === node },
            apply: { target, parameter, value in
                do {
                    try target.setParameter(parameter, value: value)
                    return ParameterApplication(success: true, actual: target.parameterValue(parameter))
                } catch {
                    return ParameterApplication(success: false, actual: target.parameterValue(parameter))
                }
            }
        )
        let handle = try XCTUnwrap(edits.makeHandle(node: node, parameterID: "amount"))
        XCTAssertNil(edits.makeHandle(node: node, parameterID: "unknown"))
        XCTAssertTrue(edits.commit(4, for: handle, intentRevision: 1))
        let first = try XCTUnwrap(handle.latestStartedOperationOrder)
        let id = node.id
        node.base.id = UUID()
        XCTAssertNil(handle.latestStartedOperationOrder)
        node.base.id = id
        XCTAssertEqual(handle.latestStartedOperationOrder, 0, "Pruned identity history cannot reappear")
        XCTAssertTrue(edits.commit(6, for: handle, intentRevision: 2))
        XCTAssertGreaterThan(try XCTUnwrap(handle.latestStartedOperationOrder), first)
        current = false
        XCTAssertNil(handle.latestStartedOperationOrder)
        XCTAssertTrue(edits.flushAll())
        current = true
        let renewed = try XCTUnwrap(edits.makeHandle(node: node, parameterID: "amount"))
        XCTAssertEqual(renewed.latestStartedOperationOrder, 0)
        let impostor = R6ReadCountingParameterNode()
        impostor.base.id = id
        XCTAssertNil(edits.makeHandle(node: impostor, parameterID: "amount"))
        XCTAssertEqual(node.nativeReads, 2, "Only the two application harness reads are allowed")
        XCTAssertEqual(node.base.attempts, [4, 6])
    }

    func test_started_order_query_never_reads_native_state_including_inside_apply_and_after_retirement() throws {
        let node = R6ReadCountingParameterNode()
        let identity = ObjectIdentifier(node)
        let edits = AcceptedParameterEdits(
            schedule: scheduler.schedule, isCurrent: { ObjectIdentifier($0) == identity },
            apply: { target, parameter, value in
                do {
                    try target.setParameter(parameter, value: value)
                    return ParameterApplication(success: true, actual: target.parameterValue(parameter))
                } catch {
                    return ParameterApplication(success: false, actual: target.parameterValue(parameter))
                }
            }
        )
        let handle = try XCTUnwrap(edits.makeHandle(node: node, parameterID: "amount"))
        XCTAssertEqual(handle.latestStartedOperationOrder, 0)
        XCTAssertEqual(node.nativeReads, 0)
        var insideOrder: UInt64?
        node.base.afterAttempt = { [weak node] _ in
            node?.base.afterAttempt = nil
            insideOrder = handle.latestStartedOperationOrder
            XCTAssertGreaterThan(insideOrder ?? 0, 0)
            XCTAssertNil(handle.successfulPresentation)
            XCTAssertEqual(node?.nativeReads, 0, "Inside-apply query cannot pre-read native state")
        }
        XCTAssertTrue(edits.commit(4, for: handle, intentRevision: 1))
        let first = try XCTUnwrap(insideOrder)
        for _ in 0..<3 { XCTAssertEqual(handle.latestStartedOperationOrder, first) }
        XCTAssertEqual(node.nativeReads, 1)
        XCTAssertTrue(edits.accept(7, for: handle, intentRevision: 2))
        XCTAssertEqual(handle.latestStartedOperationOrder, first)
        XCTAssertEqual(node.nativeReads, 1)
        node.base.readbackAvailable = false
        XCTAssertTrue(edits.commit(8, for: handle, intentRevision: 3))
        let second = try XCTUnwrap(handle.latestStartedOperationOrder)
        XCTAssertGreaterThan(second, first)
        XCTAssertEqual(node.nativeReads, 2)
        node.base.behavior = .rejected
        XCTAssertFalse(edits.commit(9, for: handle, intentRevision: 4))
        XCTAssertGreaterThan(try XCTUnwrap(handle.latestStartedOperationOrder), second)
        XCTAssertEqual(node.nativeReads, 3)
        edits.retire(handle)
        XCTAssertNil(handle.latestStartedOperationOrder)
        scheduler.runAll()
        XCTAssertNil(handle.latestStartedOperationOrder)
        XCTAssertEqual(node.nativeReads, 3, "Retired query and obsolete ticks cannot read native state")
        XCTAssertEqual(node.base.attempts, [4, 8, 9])
    }

    func test_started_order_record_and_retained_handle_do_not_retain_node_or_owner() throws {
        var node: R6ReadCountingParameterNode? = R6ReadCountingParameterNode()
        weak var weakNode = node
        var edits: AcceptedParameterEdits? = AcceptedParameterEdits(
            schedule: scheduler.schedule, isCurrent: { [weak node] candidate in candidate === node },
            apply: { target, parameter, value in
                do {
                    try target.setParameter(parameter, value: value)
                    return ParameterApplication(success: true, actual: target.parameterValue(parameter))
                } catch {
                    return ParameterApplication(success: false, actual: target.parameterValue(parameter))
                }
            }
        )
        weak var weakOwner = edits
        let handle = try XCTUnwrap(edits?.makeHandle(node: XCTUnwrap(node), parameterID: "amount"))
        XCTAssertTrue(try XCTUnwrap(edits).commit(4, for: handle, intentRevision: 1))
        XCTAssertGreaterThan(try XCTUnwrap(handle.latestStartedOperationOrder), 0)
        node = nil
        XCTAssertNil(weakNode)
        XCTAssertNil(handle.latestStartedOperationOrder)
        edits = nil
        XCTAssertNil(weakOwner)
        XCTAssertNil(handle.latestStartedOperationOrder)
    }
}
