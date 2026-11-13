import Foundation
import SoundModel

/// Slots85.OpenToggle: UI-only receipt, typed by the production qualified address.
struct TNFEditorOpenToggle {
    let key: LibraryControlAddress
    let time: TimeInterval
    let editing: Bool
    let opened: Set<LibraryControlAddress>
    let picked: LibraryControlAddress?
}

@MainActor extension TNFEditorCommands {
    func perform(token: LibraryEditorToken? = nil, _ operation: @escaping @MainActor () async throws -> Void) {
        let captured = token ?? adapter.token
        Task { do { try validateCallback(captured); try await operation() } catch { fail(error) } }
    }
    /// Slots85.toggleOpen: one open rule across Use/Edit, second click ignored.
    func toggleOpen(_ key: LibraryControlAddress, at time: TimeInterval = ProcessInfo.processInfo.systemUptime, clicks: Int = 1) {
        guard clicks == 1 else { return }
        let moves = projection?.mappings.bindings.contains { $0.path == key.path && $0.source.control == key.control } == true
        guard editing || moves else { return }
        lastOpenToggle = TNFEditorOpenToggle(key: key, time: time, editing: editing, opened: openControls, picked: focusedControl)
        if openControls.contains(key) { openControls.remove(key); if editing { focusedControl = nil } }
        else { if editing { openControls = [key]; focusedControl = key } else { openControls.insert(key) } }
    }
    func restoreNameToggle(_ key: LibraryControlAddress, at time: TimeInterval = ProcessInfo.processInfo.systemUptime, interval: TimeInterval = 0.5) {
        let last = lastOpenToggle; lastOpenToggle = nil
        guard let last, last.key == key, last.editing == editing, time >= last.time, time - last.time <= interval else { return }
        openControls = last.opened; focusedControl = last.picked
    }
    var changedHere: Bool { edit.map { $0.pendingStructural || $0.parts.contains { $0.settings.contains(where: \.isChangedHere) } } ?? false }
    var durabilityWarning: String? {
        switch edit?.durability { case .refused: return "Not Saved"; case .unresolved: return "Not Yet Confirmed"; default: return nil }
    }
    var linkHelp: String? {
        guard let definition else { return nil }
        let uses = app.presentation?.uses.filter { $0.definition == definition.id }.count ?? 0
        if binding != nil { if changedHere { return "Linked · changed here" }; return uses > 1 ? "Linked · used in \(uses)" : "Linked" }
        return uses > 0 ? "Library · used in \(uses)" : "Library"
    }
    func blockDefinition(_ path: [UUID], binding selected: LibraryBinding? = nil) -> LibraryDefinitionSummary? {
        let selected = selected ?? binding
        let use = selected.flatMap { binding in app.presentation?.uses.first { $0.id == binding.use } }
        if path.isEmpty {
            if let use { return app.presentation?.definitions.first { $0.id == use.definition } }
            return definition
        }
        let occurrence = (selected == binding ? edit?.occurrences : use?.occurrences)?.first { $0.path == path }
        return occurrence?.reference.flatMap { reference in app.presentation?.definitions.first { $0.id == reference.definition } }
    }
    func blockName(_ path: [UUID]) -> String {
        guard !path.isEmpty else { return title }
        if let ref = edit?.occurrences.first(where: { $0.path == path })?.reference,
           let definition = app.presentation?.definitions.first(where: { $0.id == ref.definition }) { return definition.name }
        if let piece = edit?.pieces.first(where: { if case .reference(let site, _, _) = $0 { return site == path.first }; return false }),
           case .reference(_, let ref, _) = piece,
           let definition = app.presentation?.definitions.first(where: { $0.id == ref.definition }) { return definition.name }
        return "Block"
    }
    func laneName(_ binding: LibraryMappingSummary) -> String {
        if case .setting(_, let key) = binding.target { return TNFEditorNames.parameter(key) }
        return targetName(binding.target, path: binding.path)
    }
    func sourceLabelPlaces(_ binding: LibraryMappingSummary) -> [(String, Double)] {
        let address = LibraryControlAddress(path: binding.path, control: binding.source.control)
        guard let source = projection?.mappings.descriptors.first(where: { $0.address == address })?.presentation,
              case .slider(let low, let high) = source.face else { return [] }
        return [(low, 0), (high, 1)]
    }
    func brokenBindingName(_ id: UUID) -> String {
        guard let mapping = projection?.mappings.bindings.first(where: { $0.id == id }) else { return "Control" }
        let applicationName = binding.map { appName($0.target) } ?? title
        return applicationName + " · " + (controlNames[mapping.source.control] ?? "Control") + " → " + targetName(mapping.target, path: mapping.path)
    }
}

/// The reference's zero-inset normalized axis, shared by thumb/playhead/points.
struct TNFEditorAxis: Equatable {
    let origin: Double
    let width: Double
    func x(_ value: Double) -> Double { origin + width * value }
    static func cardTrack(width: Double) -> Self { Self(origin: 144, width: max(120, width - 144 - 8)) }
}

struct TNFEditorTreeKey: Hashable {
    let use: UUID
    let path: [UUID]
}

/// Tune85/Window86 inset budget used by the actual window view, not a fit-to-hide policy.
struct TNFEditorWindowBudget {
    static let margin = 22.0
    static let top = 32.0
    static let gap = 18.0
    static let cardBottom = 84.0
    static let sidebarBottom = 64.0
    static let barIcon = 34.0
    static let barVerticalPadding = 10.0
    static var barTop: Double { gap + barIcon + 2 * barVerticalPadding }
    static var lastCardClearance: Double { margin + cardBottom - barTop }
    static var lastLibraryClearance: Double { margin + sidebarBottom - barTop }
    static func minimumLibraryScrollRoom(height: Double) -> Double {
        height - top - margin - sidebarBottom - height * 0.52 - 28 - gap
    }
}
