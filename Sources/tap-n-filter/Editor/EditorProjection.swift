import AppKit
import Foundation
import SoundModel

enum TNFEditorControlKind: String, Identifiable { case slider, choice, switchControl; var id: String { rawValue } }

@MainActor extension TNFEditorCommands {
    func scalar(_ address: LibraryControlAddress) -> Double {
        let position = projection?.mappings.controls.first { $0.address == address }?.effective ?? edit?.positions[address] ?? use?.positions[address.control]
        if case .scalar(let value) = position { return value }; return 0
    }
    func sourcePosition(_ binding: LibraryMappingSummary) -> Double { scalar(LibraryControlAddress(path: binding.path, control: binding.source.control)) }
    func sourceOptions(_ binding: LibraryMappingSummary) -> [LibraryOption] {
        guard let control = projection?.mappings.descriptors.first(where: { $0.address == LibraryControlAddress(path: binding.path, control: binding.source.control) })?.presentation, case .choice(let options) = control.face else { return [] }; return options
    }
    func selectedOption(_ binding: LibraryMappingSummary) -> UUID? {
        guard let id = binding.selector,
              let control = projection?.mappings.descriptors.first(where: { $0.address == LibraryControlAddress(path: binding.path, control: id) })?.presentation,
              case .choice(let options) = control.face else { return nil }
        let position = scalar(LibraryControlAddress(path: binding.path, control: id))
        return options.min { abs($0.position - position) < abs($1.position - position) }?.id
    }
    func targetValue(_ binding: LibraryMappingSummary) -> Double {
        switch binding.target {
        case .setting(let id, let parameter):
            guard let setting = edit?.parts.first(where: { $0.id == id })?.settings.first(where: { $0.parameter == parameter }) else { return binding.reference }
            return (try? setting.specification.normalized(setting.physicalValue)) ?? setting.base
        case .control(let site, let control, _): return scalar(LibraryControlAddress(path: binding.path + (site.map { [$0] } ?? []), control: control))
        }
    }
    func targetName(_ target: LibraryMappingTarget, path: [UUID] = []) -> String {
        switch target {
        case .setting(let part, let parameter): return [edit?.parts.first(where: { $0.id == part }).map { TNFEditorNames.part($0.type) }, TNFEditorNames.parameter(parameter)].compactMap { $0 }.joined(separator: " · ")
        case .control(let site, let control, _):
            let address = LibraryControlAddress(path: path + (site.map { [$0] } ?? []), control: control)
            return projection?.mappings.descriptors.first { $0.address == address }?.presentation?.title ?? controlNames[control] ?? "Control"
        }
    }
}

@MainActor extension TNFEditorCommands {
    func createControl(_ kind: TNFEditorControlKind, title: String, first: String, last: String) async throws {
        let id = UUID(), creation: LibraryControlCreation
        switch kind {
        case .slider: creation = .slider(id: id, title: title, initial: 0, waypoints: [0, 1])
        case .choice, .switchControl:
            let a = UUID(), b = UUID()
            creation = .choice(id: id, title: title, options: [LibraryOption(id: a, title: first, position: 0), LibraryOption(id: b, title: last, position: 1)], initial: a)
        }
        try await mapping(.create(creation))
    }
    func renameOption(_ token: LibraryEditorToken, path: [UUID], control: UUID, option: UUID, title: String) async throws {
        guard adapter.token == token, let value = projection?.mappings.descriptors.first(where: { $0.address == LibraryControlAddress(path: path, control: control) })?.presentation,
              case .choice(let options) = value.face else { throw TNFEditorError.stale }
        let renamed = options.map { LibraryOption(id: $0.id, title: $0.id == option ? title : $0.title, position: $0.position) }
        _ = try await accept(adapter.submit(token, command: .mapping(path: path, .choiceOptions(control: control, options: renamed, tables: [:])))); try await refresh()
    }
    func options(_ address: LibraryControlAddress) -> [LibraryOption] {
        guard let control = projection?.mappings.descriptors.first(where: { $0.address == address })?.presentation, case .choice(let options) = control.face else { return [] }; return options
    }
    func replaceUpdate(_ removal: LibraryOptionRemovalSummary, with replacement: UUID) async throws {
        guard let preview = updatePlan?.preview else { throw TNFEditorError.noSelection }
        var replacements = preview.removals.map { LibraryOptionReplacement(address: $0.address, removed: $0.removed, replacement: $0.replacement) }
        replacements.removeAll { $0.address == removal.address && $0.removed == removal.removed }
        replacements.append(LibraryOptionReplacement(address: removal.address, removed: removal.removed, replacement: replacement))
        try await previewUpdate(places: preview.places, replacements: replacements)
    }
    func placeName(_ place: LibraryUpdatePlace) -> String {
        guard let use = app.snapshot?.uses.first(where: { $0.id == place.use }) else { return "Block" }
        let names = (1...max(1, place.path.count)).compactMap { count -> String? in
            guard count <= place.path.count,
                  let ref = use.occurrences.first(where: { $0.path == Array(place.path.prefix(count)) })?.reference else { return nil }
            return app.snapshot?.definitions.first { $0.id == ref.definition }?.name
        }
        return ([appName(use.target), use.name] + names).joined(separator: " · ")
    }
    func placeName(_ place: LibraryChoicePlace) -> String {
        switch place {
        case .use(let app, _): return appName(app)
        case .workspace(let id): return self.app.snapshot?.definitions.first { $0.id == id }?.name ?? "Block"
        }
    }
}

enum TNFEditorNames {
    static func part(_ type: String) -> String { ["gain":"Volume", "dynamics":"Evener", "deviceEQ":"Device EQ", "deviceColour":"Distortion", "placeEQ":"Place EQ", "reverb":"Reverb"][type] ?? type }
    static func symbol(_ type: String) -> String { ["gain":"speaker.wave.2", "dynamics":"arrow.down.and.line.horizontal.and.arrow.up", "deviceEQ":"speaker.wave.1", "deviceColour":"waveform.path", "placeEQ":"door.left.hand.closed", "reverb":"dot.radiowaves.up.forward"][type] ?? "square" }
    static func parameter(_ key: String) -> String {
        ["highPassHz":"Low Cut", "lowPassHz":"High Cut", "wetPercent":"Mix", "preGainDb":"Input Gain", "factoryPreset":"Preset", "roomPreset":"Room", "thresholdDb":"Threshold", "headroomDb":"Headroom", "expansionRatio":"Expansion Ratio", "expansionThresholdDb":"Expansion Threshold", "attackSeconds":"Attack", "releaseSeconds":"Release", "makeupDb":"Makeup Gain", "gainDb":"Gain"][key] ?? key
    }
    static func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...3))) }
    static func value(_ value: Double, key: String) -> String {
        let precision = key.hasSuffix("Hz") || key == "factoryPreset" || key == "roomPreset" ? 0 : key.hasSuffix("Seconds") ? 3 : 1
        return value.formatted(.number.precision(.fractionLength(0...precision)))
    }

}

struct TNFEditorRename: Identifiable {
    enum Action {
        case definition(UUID)
        case use(LibraryBinding)
        case control(LibraryEditorToken, [UUID], UUID)
        case option(LibraryEditorToken, [UUID], UUID, UUID)
    }
    let id = UUID()
    let title: String
    let action: Action
}


/// Metadata is injected in headless checks; installed app lookup is deferred to the real window.
struct TNFEditorAppMetadata {
    let bundleIdentifier: String?
    let localizedDisplayName: String?
    let bundleName: String?
    let fileDisplayName: String?
}
struct TNFEditorAppIdentity {
    let name: String
    let isMissing: Bool
    let image: NSImage?
    init(bundle: String, metadata: TNFEditorAppMetadata?, image: NSImage? = nil) {
        let names = metadata?.bundleIdentifier == bundle ? [metadata?.localizedDisplayName, metadata?.bundleName, metadata?.fileDisplayName] : []
        let name = names.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && $0 != bundle }
        self.name = name ?? "Missing App"; isMissing = name == nil; self.image = image
    }
    @MainActor static func resolve(_ bundle: String) -> TNFEditorAppIdentity {
        let workspace = NSWorkspace.shared
        guard let url = workspace.urlForApplication(withBundleIdentifier: bundle) else {
            return TNFEditorAppIdentity(bundle: bundle, metadata: nil, image: workspace.icon(for: .applicationBundle))
        }
        let app = Bundle(url: url)
        let display = FileManager.default.displayName(atPath: url.path)
        let metadata = TNFEditorAppMetadata(bundleIdentifier: app?.bundleIdentifier,
            localizedDisplayName: app?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
            bundleName: app?.object(forInfoDictionaryKey: "CFBundleName") as? String,
            fileDisplayName: display.lowercased().hasSuffix(".app") ? String(display.dropLast(4)) : display)
        let label = TNFEditorAppIdentity(bundle: bundle, metadata: metadata)
        return TNFEditorAppIdentity(bundle: bundle, metadata: metadata,
            image: label.isMissing ? workspace.icon(for: .applicationBundle) : workspace.icon(forFile: url.path))
    }
}
@MainActor extension TNFEditorCommands {
    func appIdentity(_ bundle: String) -> TNFEditorAppIdentity {
        appIdentities[bundle] ?? TNFEditorAppIdentity(bundle: bundle, metadata: nil)
    }
    func appName(_ bundle: String) -> String { appIdentity(bundle).name }
    func refreshAppIdentities() {
        guard let appIdentityResolver else { return }
        let bundles = Set((app.snapshot?.uses.map(\.target) ?? []) + (app.snapshot?.assignments.map(\.target) ?? []))
        appIdentities = Dictionary(uniqueKeysWithValues: bundles.map { ($0, appIdentityResolver($0)) })
    }
    func settingIsReached(sourceControls: [UUID], path: [UUID]) -> Bool {
        editing && focusedControl.map { $0.path == path && sourceControls.contains($0.control) } == true
    }
}
