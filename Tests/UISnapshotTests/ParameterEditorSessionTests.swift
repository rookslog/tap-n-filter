import Combine
import Foundation
@testable import UI
import ViewModel
import XCTest

/// Exercises the lifecycle boundary used by ParameterSlider, never a custom
/// editor factory or a substitute result channel. No view/render execution.
@MainActor
final class ParameterEditorSessionTests: XCTestCase {
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

    func test_retained_host_renews_editor_and_drag_return_reset_after_disappearance() throws {
        let model = makeModel()
        let node = try fixture.node(in: model)
        let host = ParameterEditorSession(writer: fixture.writer(node, model))
        XCTAssertNil(host.editor)
        host.appear()
        let first = try XCTUnwrap(host.editor)
        host.appear()
        XCTAssertTrue(host.editor === first, "Repeated appearance must not create competing sessions")
        first.drag(to: 0.7)
        let oldTick = try scheduler.takeNext()
        first.beginEditing(locale: fixture.locale)
        first.text = "9"

        host.disappear()
        host.disappear()
        XCTAssertNil(host.editor)
        XCTAssertFalse(first.isEditing)
        XCTAssertEqual(node.attempts, [7], "Retirement flushes accepted intent once, never the draft 9")
        host.appear()
        let renewed = try XCTUnwrap(host.editor)
        XCTAssertFalse(renewed === first)
        XCTAssertEqual(renewed.value, 7)
        renewed.drag(to: 0.4)
        renewed.finishDragging()
        renewed.beginEditing(locale: fixture.locale)
        renewed.text = "6"
        XCTAssertTrue(renewed.commit(locale: fixture.locale))
        XCTAssertEqual(node.value, 6)
        renewed.reset()
        oldTick()
        scheduler.runAll()
        XCTAssertEqual(node.attempts, [7, 4, 6, 2])
        model.savePreset(to: fixture.url("renewed-session.tnf"))
        XCTAssertEqual(try fixture.exportedValue("renewed-session.tnf"), 2)
    }

    func test_retired_editor_and_old_tick_cannot_write_or_drain_renewed_pending_input() throws {
        let model = makeModel()
        let node = try fixture.node(in: model)
        let host = ParameterEditorSession(writer: fixture.writer(node, model))
        host.appear()
        let old = try XCTUnwrap(host.editor)
        old.drag(to: 0.4)
        let oldTick = try scheduler.takeNext()
        host.disappear()
        host.appear()
        let renewed = try XCTUnwrap(host.editor)
        renewed.drag(to: 0.7)

        oldTick()
        old.drag(to: 0.9)
        old.beginEditing(locale: fixture.locale)
        old.text = "9"
        XCTAssertFalse(old.commit(locale: fixture.locale))
        old.reset()
        old.finishDragging()
        old.stop()
        old.receiveModelValue(9)
        XCTAssertEqual(node.attempts, [4])
        XCTAssertEqual(renewed.value, 7)
        XCTAssertEqual(scheduler.count, 1)
        try scheduler.runNext()
        oldTick()
        XCTAssertEqual(node.attempts, [4, 7])
        XCTAssertEqual(node.value, 7)
    }

    func test_hidden_host_cannot_renew_against_same_uuid_replacement() throws {
        let model = makeModel()
        let file = fixture.url("replacement.tnf")
        model.savePreset(to: file)
        let oldNode = try fixture.node(in: model)
        let host = ParameterEditorSession(writer: fixture.writer(oldNode, model))
        host.appear()
        let oldEditor = try XCTUnwrap(host.editor)
        oldEditor.drag(to: 0.7)
        let oldTick = try scheduler.takeNext()
        host.disappear()
        model.loadPreset(from: file)
        XCTAssertNil(model.lastError)
        let replacement = try fixture.node(in: model)
        XCTAssertEqual(oldNode.id, replacement.id)
        XCTAssertFalse(oldNode === replacement)

        host.appear()
        XCTAssertNil(host.editor, "Renewal must not look up a new node merely by UUID")
        oldTick()
        oldEditor.drag(to: 0.9)
        oldEditor.reset()
        oldEditor.finishDragging()
        let currentHost = ParameterEditorSession(writer: fixture.writer(replacement, model))
        currentHost.appear()
        let currentEditor = try XCTUnwrap(currentHost.editor)
        currentEditor.drag(to: 0.4)
        currentEditor.finishDragging()
        scheduler.runAll()
        XCTAssertEqual(oldNode.attempts, [7])
        XCTAssertEqual(replacement.attempts, [4])
    }

    func test_generation_replacement_before_disappearance_discards_old_pending_input() throws {
        let model = makeModel()
        let file = fixture.url("visible-replacement.tnf")
        model.savePreset(to: file)
        let oldNode = try fixture.node(in: model)
        let host = ParameterEditorSession(writer: fixture.writer(oldNode, model))
        host.appear()
        let oldEditor = try XCTUnwrap(host.editor)
        oldEditor.drag(to: 0.7)
        let oldTick = try scheduler.takeNext()

        model.loadPreset(from: file)
        let replacement = try fixture.node(in: model)
        XCTAssertEqual(replacement.id, oldNode.id)
        XCTAssertFalse(replacement === oldNode)
        oldTick()
        oldEditor.finishDragging()
        host.disappear()
        host.appear()
        XCTAssertNil(host.editor)
        oldEditor.drag(to: 0.9)
        oldEditor.reset()
        scheduler.runAll()
        XCTAssertTrue(oldNode.attempts.isEmpty)
        XCTAssertTrue(replacement.attempts.isEmpty)
        XCTAssertEqual(replacement.value, 2)
    }

    func test_retained_host_editor_and_ticks_do_not_retain_model_or_node() throws {
        var model: AppViewModel? = makeModel()
        var node: AcceptedParameterNode? = try fixture.node(in: XCTUnwrap(model))
        weak var weakModel = model
        weak var weakNode = node
        let host = ParameterEditorSession(writer: fixture.writer(try XCTUnwrap(node), try XCTUnwrap(model)))
        host.appear()
        let editor = try XCTUnwrap(host.editor)
        editor.drag(to: 0.7)
        let tick = try scheduler.takeNext()

        model = nil
        XCTAssertNil(weakModel, "Neither host nor editor may retain the VM")
        node = nil
        XCTAssertNil(weakNode, "Renewal state and editor readback must capture the concrete node weakly")
        tick()
        editor.reset()
        host.disappear()
        host.appear()
        XCTAssertNil(host.editor)
        scheduler.runAll()
    }

    func test_observers_follow_published_editor_replacement_and_renewed_editor_state() throws {
        let model = makeModel()
        let node = try fixture.node(in: model)
        let host = ParameterEditorSession(writer: fixture.writer(node, model))
        var identities: [ObjectIdentifier?] = []
        let hostObservation = host.$editor.sink { identities.append($0.map { ObjectIdentifier($0) }) }
        defer { hostObservation.cancel() }
        host.appear()
        let first = try XCTUnwrap(host.editor)
        host.disappear()
        host.appear()
        let renewed = try XCTUnwrap(host.editor)
        XCTAssertEqual(identities, [nil, ObjectIdentifier(first), nil, ObjectIdentifier(renewed)])

        // ParameterSlider's child observes this current editor directly, not
        // an unobserved nested property of the retained host.
        var values: [Float] = []
        var texts: [String] = []
        var errors: [String?] = []
        let valueObservation = renewed.$value.sink { values.append($0) }
        let textObservation = renewed.$text.sink { texts.append($0) }
        let errorObservation = renewed.$errorMessage.sink { errors.append($0) }
        defer {
            valueObservation.cancel()
            textObservation.cancel()
            errorObservation.cancel()
        }
        renewed.beginEditing(locale: fixture.locale)
        renewed.text = "invalid"
        XCTAssertFalse(renewed.commit(locale: fixture.locale))
        XCTAssertTrue(errors.contains { $0 != nil })
        renewed.text = "4"
        XCTAssertTrue(renewed.commit(locale: fixture.locale))
        renewed.drag(to: 0.7)
        renewed.finishDragging()
        XCTAssertTrue(values.contains(4))
        XCTAssertEqual(values.last, 7)
        XCTAssertTrue(texts.contains("invalid"))
        XCTAssertTrue(texts.contains("4"))
        XCTAssertNil(renewed.errorMessage)
        first.reset()
        XCTAssertEqual(node.attempts, [4, 7])
    }
}
