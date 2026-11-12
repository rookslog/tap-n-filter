import Foundation

struct ContractFailure: Error, CustomStringConvertible {
    let description: String
}

func requireEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "") throws {
    if actual != expected {
        throw ContractFailure(description: "\(message) expected \(expected), got \(actual)")
    }
}

func requireEqual(_ actual: Double, _ expected: Double, accuracy: Double, _ message: String = "") throws {
    if !actual.isFinite || !expected.isFinite || abs(actual - expected) > accuracy {
        throw ContractFailure(description: "\(message) expected \(expected) +/- \(accuracy), got \(actual)")
    }
}

func requireDifferent<T: Equatable>(_ actual: T, _ other: T) throws {
    if actual == other { throw ContractFailure(description: "expected distinct values, got \(actual)") }
}

func requireTrue(_ condition: Bool, _ message: String = "") throws {
    if !condition { throw ContractFailure(description: message.isEmpty ? "condition was false" : message) }
}

func requireAtLeast(_ actual: Double, _ lower: Double, _ message: String = "") throws {
    try requireTrue(actual >= lower, "\(message) \(actual) below \(lower)")
}

func requireAtMost(_ actual: Double, _ upper: Double, _ message: String = "") throws {
    try requireTrue(actual <= upper, "\(message) \(actual) above \(upper)")
}

func requireValue<T>(_ optional: T?) throws -> T {
    guard let value = optional else { throw ContractFailure(description: "missing required value") }
    return value
}

func requireThrows<T>(_ body: @autoclosure () throws -> T, _ inspect: ((Error) throws -> Void)? = nil) throws
{
    var caught: Error?
    do { _ = try body() } catch { caught = error }
    guard let error = caught else { throw ContractFailure(description: "expected an error") }
    try inspect?(error)
}

struct ModelContract: Sendable {
    let name: String
    let run: @Sendable () async throws -> Void

    static let all: [ModelContract] = [
        ModelContract(name: "DescriptorReuse.exact_legacy_facts", run: DescriptorReuseCases().test_exact_legacy_descriptor_facts),
        ModelContract(name: "MappingCurveCases.exact_constant_spans",
            run: MappingCurveCases().test_constant_spans_preserve_exact_endpoint_bits),
        ModelContract(name: "Bootstrap.existing_fresh_refusal", run: { try await LibraryBootstrapCases().test_existing_fresh_and_refusal() }),
        ModelContract(name: "Bootstrap.import_interruption", run: { try await LibraryBootstrapCases().test_import_commit_and_interruption() }),
        ModelContract(name: "Bootstrap.typed_commands", run: { try await LibraryBootstrapCases().test_typed_command_outcomes() }),
        ModelContract(name: "LibraryPower.setter_restart", run: { try await LibraryPowerCases().test_power_setter_and_restart() }),
        ModelContract(name: "LibraryPower.repeated_dirty_commit", run: { try await LibraryPowerCases().test_repeated_dirty_snapshot_commit_coherence() }),
        ModelContract(name: "LibraryPower.durable_matrix", run: { try await LibraryPowerCases().test_suspended_writes_and_reconciliation() }),
        ModelContract(name: "LibraryPower.identity", run: { try await LibraryPowerCases().test_identity_and_power_only_generation() }),
        ModelContract(name: "RangeCompatibilityCases.v5_archives", run: { try await RangeCompatibilityCases().test_v5_library_reopens_without_retune() }),
        ModelContract(name: "RangeCompatibilityCases.v5_high_cut", run: { try await RangeCompatibilityCases().test_v5_high_cut_recognition_preserves_100hz_readout() }),
        ModelContract(name: "OwnerBoundary.untouched", run: { try await OwnerBoundaryCases().test_untouched_gesture_retains_child_and_redo() }),
        ModelContract(name: "OwnerBoundary.returned", run: { try await OwnerBoundaryCases().test_returned_gesture_retains_child_and_redo() }),
        ModelContract(name: "OwnerBoundary.export", run: { try await OwnerBoundaryCases().test_library_export_refuses_and_legacy_stays() }),
        ModelContract(name: "LinkedModel.canonical_legacy", run: { try LinkedModelCases().test_canonical_defaults_and_legacy_refusal() }),
        ModelContract(name: "LinkedModel.nested_capture_history", run: { try await LinkedModelCases().test_nested_capture_copy_and_history() }),
        ModelContract(name: "LinkedModel.exact_heads", run: { try await LinkedModelCases().test_exact_heads_and_revision_only_links() }),
        ModelContract(name: "LinkedModel.graph_refusals", run: { try await LinkedModelCases().test_graph_and_version_refusals() }),
        ModelContract(name: "LibraryCases.canonical", run: { try LibraryCases().test_canonical_stream() }),
        ModelContract(name: "LibraryCases.refusals", run: { try await LibraryCases().test_scopes_and_refusals() }),
        ModelContract(name: "LibraryCases.archived_migration", run: { try await LibraryCases().test_archived_v1_migration() }),
        ModelContract(name: "BuiltinCases.v4_controls_migration", run: BuiltinCases().test_v4_controls_migrate_hz_and_neutral_volume_idempotently),
        ModelContract(name: "EverydayCases.volume_compensation", run: EverydayCases().test_volume_combines_with_compensation_without_saturation),
        ModelContract(
            name: "BuiltinCases.real_legacy_reorder",
            run: BuiltinCases()
                .test_real_legacy_option_reordering_uses_option_identity_not_label_or_position),
        ModelContract(
            name: "BuiltinCases.added_order",
            run: BuiltinCases()
                .test_card_order_is_added_order_across_restart_replacement_off_and_none),
        ModelContract(
            name: "BuiltinCases.identity",
            run: BuiltinCases().test_real_blocks_metadata_labels_and_stable_identity),
        ModelContract(
            name: "BuiltinCases.filters",
            run: BuiltinCases()
                .test_filters_defaults_endpoints_sweeps_and_readouts_match_native_targets),
        ModelContract(
            name: "BuiltinCases.selection",
            run: BuiltinCases().test_selection_replacement_off_none_and_refusals_are_per_app_atomic),
        ModelContract(
            name: "BuiltinCases.restart",
            run: BuiltinCases().test_two_builtin_restart_and_menu_defaults_are_definition_metadata),
        ModelContract(
            name: "BuiltinCases.refusals",
            run: BuiltinCases().test_corrupt_foreign_duplicate_and_future_sessions_never_reset),
        ModelContract(
            name: "MigrationCases.reorder_extension_restart",
            run: MigrationCases().test_reorder_and_extension_preserve_independent_choices_and_restart),
        ModelContract(
            name: "MigrationCases.removed_defaults",
            run: MigrationCases().test_removed_selection_and_control_use_current_defaults),
        ModelContract(
            name: "MigrationCases.invalid_overrides",
            run: MigrationCases().test_invalid_overrides_are_not_hidden_by_removal_or_remapping),
        ModelContract(
            name: "MigrationCases.refusal_boundary",
            run: MigrationCases().test_true_face_changes_and_wrong_builtin_identity_still_refuse),
        ModelContract(
            name: "EverydayCases.frozen_builtin_migration",
            run: EverydayCases().test_frozen_older_builtin_retunes_keep_app_positions_power_and_identity),
        ModelContract(
            name: "EverydayCases.recipes",
            run: EverydayCases().test_choices_and_softer_compile_brief_endpoints_and_monotone_sweeps),
        ModelContract(
            name: "EverydayCases.facade_roundtrip",
            run: EverydayCases().test_facade_assignments_and_real_session_roundtrip_preserve_state),
        ModelContract(
            name: "EverydayCases.power",
            run: EverydayCases().test_power_is_not_history_or_gesture_state_and_legacy_archive_defaults_off),
        ModelContract(
            name: "AssignmentCases.independent_apps",
            run: AssignmentCases()
                .test_two_apps_evaluate_independent_positions_without_touching_authored_state_or_history),
        ModelContract(
            name: "AssignmentCases.atomic_refusals",
            run: AssignmentCases().test_assignment_refusals_are_atomic_and_take_off_removes_only_its_listening
        ),
        ModelContract(
            name: "AssignmentCases.history_lifecycle",
            run: AssignmentCases()
                .test_undo_creation_archives_assignments_but_redo_does_not_steal_a_rebound_app),
        ModelContract(
            name: "AssignmentCases.session_roundtrip",
            run: AssignmentCases().test_session_roundtrip_is_real_document_data_and_invalid_restore_is_atomic),
        ModelContract(
            name: "ListeningUndoCases.test_skipped_controls_do_not_reappear_when_redo_matches_an_old_value",
            run: ListeningUndoCases().test_skipped_controls_do_not_reappear_when_redo_matches_an_old_value),
        ModelContract(
            name:
                "ListeningUndoCases.test_playing_preserves_redo_and_root_lifecycle_restores_latest_listening",
            run: ListeningUndoCases().test_playing_preserves_redo_and_root_lifecycle_restores_latest_listening
        ),
        ModelContract(
            name: "ListeningUndoCases.test_edit_drag_undo_and_redo_touch_only_edited_controls",
            run: ListeningUndoCases().test_edit_drag_undo_and_redo_touch_only_edited_controls),
        ModelContract(
            name: "ListeningUndoCases.test_context_mismatch_is_atomic_and_history_only_undo_keeps_revision",
            run: ListeningUndoCases().test_context_mismatch_is_atomic_and_history_only_undo_keeps_revision),
        ModelContract(
            name: "ListeningUndoCases.test_playing_does_not_evict_edits_and_undo_keeps_current_positions",
            run: ListeningUndoCases().test_playing_does_not_evict_edits_and_undo_keeps_current_positions),
        ModelContract(
            name: "ListeningStateCases.test_listening_moves_leave_authored_blocks_and_uses_unchanged",
            run: ListeningStateCases().test_listening_moves_leave_authored_blocks_and_uses_unchanged),
        ModelContract(
            name: "ListeningStateCases.test_new_uses_undo_redo_and_cancel_keep_listening_state_local",
            run: ListeningStateCases().test_new_uses_undo_redo_and_cancel_keep_listening_state_local),
        ModelContract(
            name: "CommandReviewCases.test_history_limits_keep_only_the_newest_completed_groups",
            run: CommandReviewCases().test_history_limits_keep_only_the_newest_completed_groups),
        ModelContract(
            name: "CommandReviewCases.test_history_limit_counts_a_gesture_once_and_cancel_keeps_redo",
            run: CommandReviewCases().test_history_limit_counts_a_gesture_once_and_cancel_keeps_redo),
        ModelContract(
            name: "CommandReviewCases.test_history_limit_rejects_zero_and_negative_counts",
            run: CommandReviewCases().test_history_limit_rejects_zero_and_negative_counts),
        ModelContract(
            name:
                "CommandReviewCases.test_repeated_choice_moves_within_one_option_preserve_history_and_revision",
            run: CommandReviewCases()
                .test_repeated_choice_moves_within_one_option_preserve_history_and_revision),
        ModelContract(
            name: "SoundDocumentCases.test_uses_reference_one_definition_and_xy_commits_atomically",
            run: SoundDocumentCases().test_uses_reference_one_definition_and_xy_commits_atomically),
        ModelContract(
            name: "SoundDocumentCases.test_gesture_samples_undo_once_and_revisions_never_rewind",
            run: SoundDocumentCases().test_gesture_samples_undo_once_and_revisions_never_rewind),
        ModelContract(
            name: "SoundDocumentCases.test_cancel_preserves_prior_redo_and_empty_gestures_do_not_commit",
            run: SoundDocumentCases().test_cancel_preserves_prior_redo_and_empty_gestures_do_not_commit),
        ModelContract(
            name: "SoundDocumentCases.test_rename_collision_and_library_name_ownership_undo_together",
            run: SoundDocumentCases().test_rename_collision_and_library_name_ownership_undo_together),
        ModelContract(
            name: "SoundDocumentCases.test_equal_values_still_own_state_and_noop_preserves_redo",
            run: SoundDocumentCases().test_equal_values_still_own_state_and_noop_preserves_redo),
        ModelContract(
            name: "SoundDocumentCases.test_refusals_are_atomic_and_gesture_boundaries_are_explicit",
            run: SoundDocumentCases().test_refusals_are_atomic_and_gesture_boundaries_are_explicit),
        ModelContract(
            name: "SoundDocumentCases.test_undo_creation_never_leaves_orphan_references",
            run: SoundDocumentCases().test_undo_creation_never_leaves_orphan_references),
        ModelContract(
            name: "SoundDocumentCases.test_concurrent_commands_receive_unique_consecutive_revisions",
            run: SoundDocumentCases().test_concurrent_commands_receive_unique_consecutive_revisions),
        ModelContract(
            name: "ReviewResponseCases.test_local_curve_edit_keeps_nonincident_split_stretches",
            run: ReviewResponseCases().test_local_curve_edit_keeps_nonincident_split_stretches),
        ModelContract(
            name: "ReviewResponseCases.test_local_edits_keep_mapping_laws_and_step_jump",
            run: ReviewResponseCases().test_local_edits_keep_mapping_laws_and_step_jump),
        ModelContract(
            name: "ReviewResponseCases.test_xy_waypoints_are_independent_and_m6_uses_source_axis",
            run: ReviewResponseCases().test_xy_waypoints_are_independent_and_m6_uses_source_axis),
        ModelContract(
            name: "ReviewResponseCases.test_choice_exact_halfway_ties_take_higher_option",
            run: ReviewResponseCases().test_choice_exact_halfway_ties_take_higher_option),
        ModelContract(
            name: "CompiledSoundCases.test_nested_mixed_order_roundtrips_and_addresses_survive_reorder",
            run: CompiledSoundCases().test_nested_mixed_order_roundtrips_and_addresses_survive_reorder),
        ModelContract(
            name: "CompiledSoundCases.test_two_occurrences_of_one_part_keep_independent_addresses",
            run: CompiledSoundCases().test_two_occurrences_of_one_part_keep_independent_addresses),
        ModelContract(
            name: "CompiledSoundCases.test_multiple_mappings_add_relative_to_baseline_then_clamp",
            run: CompiledSoundCases().test_multiple_mappings_add_relative_to_baseline_then_clamp),
        ModelContract(
            name: "CompiledSoundCases.test_a19_choice_and_both_xy_axes_compile_from_normalized_positions",
            run: CompiledSoundCases().test_a19_choice_and_both_xy_axes_compile_from_normalized_positions),
        ModelContract(
            name: "CompiledSoundCases.test_m6_rejects_curve_points_outside_control_waypoints",
            run: CompiledSoundCases().test_m6_rejects_curve_points_outside_control_waypoints),
        ModelContract(
            name: "CompiledSoundCases.test_missing_unknown_and_duplicate_parameters_never_default",
            run: CompiledSoundCases().test_missing_unknown_and_duplicate_parameters_never_default),
        ModelContract(
            name: "CompiledSoundCases.test_duplicate_parts_sites_controls_and_mappings_are_rejected",
            run: CompiledSoundCases().test_duplicate_parts_sites_controls_and_mappings_are_rejected),
        ModelContract(
            name: "CompiledSoundCases.test_unknown_references_and_mismatched_control_axes_are_rejected",
            run: CompiledSoundCases().test_unknown_references_and_mismatched_control_axes_are_rejected),
        ModelContract(
            name: "MappingCurveCases.test_m1_m2_m3_m5_on_3000_deterministic_random_curves",
            run: MappingCurveCases().test_m1_m2_m3_m5_on_3000_deterministic_random_curves),
        ModelContract(
            name: "MappingCurveCases.test_m4_insertion_preserves_every_shape_and_step_jump",
            run: MappingCurveCases().test_m4_insertion_preserves_every_shape_and_step_jump),
        ModelContract(
            name: "MappingCurveCases.test_step_insertion_at_before_and_after_jump_keeps_the_jump",
            run: MappingCurveCases().test_step_insertion_at_before_and_after_jump_keeps_the_jump),
        ModelContract(
            name: "MappingCurveCases.test_invalid_curves_and_duplicate_insertions_are_rejected",
            run: MappingCurveCases().test_invalid_curves_and_duplicate_insertions_are_rejected),
        ModelContract(
            name: "PositionCases.test_positions_reject_nonfinite_and_out_of_range_input",
            run: PositionCases().test_positions_reject_nonfinite_and_out_of_range_input),
        ModelContract(
            name: "PositionCases.test_decoding_cannot_bypass_position_validation",
            run: PositionCases().test_decoding_cannot_bypass_position_validation),
        ModelContract(
            name: "PositionCases.test_choices_of_any_size_use_positions_and_permanent_option_ids",
            run: PositionCases().test_choices_of_any_size_use_positions_and_permanent_option_ids),
        ModelContract(
            name: "PositionCases.test_invalid_choices_are_rejected_on_construction_and_decode",
            run: PositionCases().test_invalid_choices_are_rejected_on_construction_and_decode),
    ]
}

func requireAsyncThrows<T>(_ body: () async throws -> T) async throws {
    do { _ = try await body() } catch { return }
    throw ContractFailure(description: "expected an async error")
}
