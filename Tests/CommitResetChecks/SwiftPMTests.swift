import XCTest

/// With no fault armed: every sequence of length 3 over the count alphabet, per send mode and drag target. Each test
/// prints one COMMIT-RESET line and fails on any superseded or thrown drag commit, epoch move, stale drop or pending
/// activation at rest, or on a run that cannot be believed.
final class CommitResetCountTests: XCTestCase {
    func test_await_top() async throws { try await ResetCount.check(mode: .awaitEach, target: .top) }
    func test_send_top() async throws { try await ResetCount.check(mode: .send, target: .top) }
    func test_await_child() async throws { try await ResetCount.check(mode: .awaitEach, target: .child) }
    func test_send_child() async throws { try await ResetCount.check(mode: .send, target: .child) }
}

/// A fault armed on one drag commit at release: the observers must see it, so a zero in the count can be believed.
final class CommitResetSelfCheckTests: XCTestCase {
    func test_thrown_top() async throws { try await ResetCount.selfCheck(.throwIt, target: .top) }
    func test_superseded_top() async throws { try await ResetCount.selfCheck(.supersede, target: .top) }
    func test_thrown_child() async throws { try await ResetCount.selfCheck(.throwIt, target: .child) }
    func test_superseded_child() async throws { try await ResetCount.selfCheck(.supersede, target: .child) }
}

final class CommitResetRuleTests: XCTestCase {
    func test_thrown_commit_at_a_pick() async throws { try await ResetRules.thrownCommitAtAPick() }
    func test_superseded_commit_at_a_pick() async throws { try await ResetRules.supersededCommitAtAPick() }
    func test_queued_samples_after_a_thrown_commit() async throws { try await ResetRules.queuedSamplesAfterAThrownCommit() }
    func test_ordered_move_after_a_thrown_commit() async throws { try await ResetRules.orderedMoveAfterAThrownCommit() }
    func test_power_compare_and_quit_after_a_thrown_commit() async throws { try await ResetRules.powerCompareAndQuitAfterAThrownCommit() }
    func test_structural_command_after_a_failed_commit() async throws { try await ResetRules.structuralCommandAfterAFailedCommit() }
    func test_refused_write_does_nothing_else() async throws { try await ResetRules.refusedWriteDoesNothingElse() }
    func test_activation_asked_again_when_the_last_barrier_ends() async throws { try await ResetRules.activationAskedAgainWhenTheLastBarrierEnds() }
}
