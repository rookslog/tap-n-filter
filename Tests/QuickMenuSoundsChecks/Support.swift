import Foundation
@testable import SoundModel
import SessionStore

// Checks for the three Quick Menu sounds added after Everyday and Filters:
// Big space, Old recording and Underwater. Written from the sound spec, not
// from the implementation. Every group records its own failures and the run
// continues, so one report covers every group.

struct QMSFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

final class QMSReport {
    private(set) var passes: [String: Int] = [:]
    private(set) var failures: [(group: String, message: String)] = []
    private(set) var notes: [String] = []
    private(set) var order: [String] = []
    var group = ""

    func check(_ condition: Bool, _ message: @autoclosure () -> String) {
        if condition { passes[group, default: 0] += 1 }
        else {
            let text = message()
            failures.append((group, text))
            print("FAIL [\(group)] \(text)")
        }
    }

    func fail(_ message: String) { check(false, message) }

    func note(_ message: String) {
        notes.append("[\(group)] " + message)
        print("NOTE [\(group)] \(message)")
    }

    func run(_ name: String, _ body: () async throws -> Void) async {
        group = name
        order.append(name)
        print("GROUP \(name)")
        do { try await body() } catch {
            failures.append((name, "group stopped early: \(error)"))
            print("FAIL [\(name)] group stopped early: \(error)")
        }
        print("GROUP-END \(name) passed=\(passes[name] ?? 0) failed=\(failures.filter { $0.group == name }.count)")
    }

    func printSummary() {
        print("SUMMARY")
        for name in order {
            let failed = failures.filter { $0.group == name }.count
            print("  \(failed == 0 ? "PASS" : "FAIL") \(name): \(passes[name] ?? 0) passed, \(failed) failed")
        }
        print(failures.isEmpty ? "PASS all quick menu sound groups" : "FAIL \(failures.count) checks")
    }
}

struct QMSContext {
    let report: QMSReport
    /// The repository root (holds Config/ and Tests/).
    let root: URL
    /// An owned scratch folder; every library file the checks write lives here.
    let scratch: URL
    let table: QMSTable
}

enum QMS {
    static let limits = try! LibraryLimits(maximumBytes: 8_000_000, maximumRevisions: 1024,
        expansion: LibraryExpansionLimits(maximumDepth: 24, maximumOccurrences: 256, maximumParts: 1024))
    static let newNames = ["Big space", "Old recording", "Underwater"]
    static let chooserOrder = ["Everyday", "Filters", "Big space", "Old recording", "Underwater"]
    /// The only on-screen words the three sounds may show, plus Volume and its reused ends.
    static let allowedWords: Set<String> = [
        "Big space", "Space", "Hall", "Church", "Where you stand", "Front", "Back",
        "Old recording", "Era", "Shellac", "Vinyl", "Tape", "Wear", "New", "Worn",
        "Underwater", "Depth", "Surface", "Deep",
        "Volume", "−24 dB", "+6 dB",
    ]
    /// Unit symbols a numeric readout may carry. Any other letters in a readout are a word.
    static let readoutUnits: Set<String> = ["dB", "Hz", "kHz"]
    static let positions21: [Double] = (0...20).map { Double($0) / 20 }

    static func near(_ value: Double?, _ expected: Double, relative: Double = 1e-4, absolute: Double = 1e-6) -> Bool {
        guard let value, value.isFinite else { return false }
        return abs(value - expected) <= max(absolute, relative * abs(expected))
    }

    static func describe(_ value: Double?) -> String { value.map { String($0) } ?? "absent" }
}

/// The engine parameter table as shipped in Config/EffectCatalog.json.
struct QMSTable {
    struct Effect { let type: String; let presetKey: String?; let presets: [Int: String] }
    let effects: [String: Effect]

    init(root: URL) throws {
        let url = root.appendingPathComponent("Config/EffectCatalog.json")
        guard let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              let list = json["effects"] as? [[String: Any]] else { throw QMSFailure("engine table unreadable") }
        var effects: [String: Effect] = [:]
        for item in list {
            guard let type = item["type"] as? String else { continue }
            var presets: [Int: String] = [:]
            for preset in item["presets"] as? [[String: Any]] ?? [] {
                if let id = preset["id"] as? Int, let native = preset["native"] as? String { presets[id] = native }
            }
            effects[type] = Effect(type: type, presetKey: item["presetKey"] as? String, presets: presets)
        }
        self.effects = effects
    }

    func presetName(_ type: String, _ value: Double?) -> String? {
        guard let value, value.rounded() == value else { return nil }
        return effects[type]?.presets[Int(value)]
    }
}

/// Native values one compiled sound hands the engine.
struct QMSNative {
    let parts: [ListeningRenderPart]
    func all(_ type: String) -> [ListeningRenderPart] { parts.filter { $0.type == type } }
    func value(_ type: String, _ key: String) -> Double? {
        all(type).first?.parameters.first { $0.key == key }?.value
    }
    var line: String {
        parts.map { part in
            part.type + "{" + part.parameters.map { $0.key + "=" + String($0.value) }.joined(separator: ",") + "}"
        }.joined(separator: " ")
    }

    /// Parts not named by a sound's spec must be absent or neutral.
    func neutralProblems(_ type: String) -> [String] {
        var problems: [String] = []
        for part in all(type) {
            func expect(_ key: String, _ wanted: Double) {
                if let value = part.parameters.first(where: { $0.key == key })?.value, !QMS.near(value, wanted) {
                    problems.append("\(type).\(key)=\(value), neutral is \(wanted)")
                }
            }
            switch type {
            case "deviceEQ": expect("highPassHz", 20); expect("lowPassHz", 20_000)
            case "placeEQ": expect("lowPassHz", 20_000)
            case "deviceColour", "reverb": expect("wetPercent", 0)
            case "gain": expect("gainDb", 0)
            case "dynamics": problems += dynamicsOffProblems(part)
            default: problems.append("unexpected part type \(type)")
            }
        }
        return problems
    }

    /// Dynamics off: the threshold sits at the top of its range, no makeup and no expansion.
    func dynamicsOffProblems(_ part: ListeningRenderPart) -> [String] {
        var problems: [String] = []
        let values = Dictionary(part.parameters.map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
        if let threshold = values["thresholdDb"], threshold < 20 - 1e-6 { problems.append("dynamics threshold \(threshold) dB compresses") }
        if let makeup = values["makeupDb"], !QMS.near(makeup, 0) { problems.append("dynamics makeup \(makeup) dB") }
        if let ratio = values["expansionRatio"], !QMS.near(ratio, 1) { problems.append("dynamics expansion ratio \(ratio)") }
        return problems
    }
}

/// A real Quick Menu library session in an owned scratch file.
struct QMSSession {
    let session: SoundLibrarySession
    let file: URL

    static func fresh(_ file: URL) async throws -> QMSSession {
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let store = LibrarySessionFile(url: file, maximumBytes: QMS.limits.maximumBytes)
        guard case .fresh(let session) = await SoundLibrarySession.open(persistence: store, limits: QMS.limits, builtins: .quickMenu) else {
            throw QMSFailure("a fresh Quick Menu library did not open as fresh")
        }
        return QMSSession(session: session, file: file)
    }

    static func reopen(_ file: URL) async throws -> QMSSession {
        let store = LibrarySessionFile(url: file, maximumBytes: QMS.limits.maximumBytes)
        guard case .existing(let session) = await SoundLibrarySession.open(persistence: store, limits: QMS.limits, builtins: .quickMenu) else {
            throw QMSFailure("a saved Quick Menu library did not reopen as existing")
        }
        return QMSSession(session: session, file: file)
    }

    func definition(_ name: String) async throws -> LibraryDefinitionSummary {
        guard let found = try await session.snapshot().definitions.first(where: { $0.name == name && $0.origin == "builtin" }) else {
            throw QMSFailure("no built-in sound named \(name)")
        }
        return found
    }

    @discardableResult
    func select(_ name: String, on target: String) async throws -> LibraryBinding {
        let found = try await definition(name)
        _ = try await session.select(found.id, on: target)
        return try await binding(target)
    }

    func binding(_ target: String) async throws -> LibraryBinding {
        guard let assignment = try await session.snapshot().assignments.first(where: { $0.target == target }) else {
            throw QMSFailure("no assignment on \(target)")
        }
        return LibraryBinding(assignment: assignment.id, use: assignment.use, target: target)
    }

    /// The app's active use: the one its assignment points at. An app keeps one use per sound it has
    /// had, so after a switch the first use found by app alone can be the previous sound's.
    func use(_ target: String) async throws -> LibraryUseSummary {
        let snapshot = try await session.snapshot()
        guard let assignment = snapshot.assignments.first(where: { $0.target == target }),
              let use = snapshot.uses.first(where: { $0.id == assignment.use }) else {
            throw QMSFailure("no active use on \(target)")
        }
        return use
    }

    /// The use this app keeps for one sound, whether or not that sound is the app's current one.
    func use(_ target: String, sound name: String) async throws -> LibraryUseSummary? {
        let definition = try await definition(name)
        return try await session.snapshot().uses.first { $0.target == target && $0.definition == definition.id }
    }

    func native(_ target: String) async throws -> QMSNative {
        guard let assignment = try await session.snapshot().assignments.first(where: { $0.target == target }) else {
            throw QMSFailure("no assignment on \(target)")
        }
        return QMSNative(parts: assignment.parts)
    }

    /// Top-level rows: controls that are nobody's sub-control.
    func topLevel(_ target: String) async throws -> [LibraryControl] {
        let use = try await use(target)
        let children = Set(use.optionControls.map(\.child.control))
        return use.controls.filter { !children.contains($0.id) }
    }

    func control(_ title: String, on target: String) async throws -> LibraryControl {
        guard let control = try await topLevel(target).first(where: { $0.title == title }) else {
            throw QMSFailure("no row titled \(title) on \(target)")
        }
        return control
    }

    func option(_ choice: String, _ option: String, on target: String) async throws -> (LibraryControl, LibraryOption) {
        let control = try await control(choice, on: target)
        guard case .choice(let options) = control.face, let found = options.first(where: { $0.title == option }) else {
            throw QMSFailure("no option \(option) under \(choice)")
        }
        return (control, found)
    }

    func choose(_ choice: String, _ option: String, on target: String) async throws {
        let (control, found) = try await self.option(choice, option, on: target)
        try await session.move(LibraryControlAddress(path: [], control: control.id), on: target, to: .scalar(found.position))
    }

    func relation(_ choice: String, _ option: String, on target: String) async throws -> LibraryOptionControl? {
        let (control, found) = try await self.option(choice, option, on: target)
        let relations = try await use(target).optionControls.filter { $0.parent.control == control.id && $0.option == found.id }
        if relations.count > 1 { throw QMSFailure("\(option) carries \(relations.count) sub-controls") }
        return relations.first
    }

    func childControl(_ choice: String, _ option: String, on target: String) async throws -> LibraryControl? {
        guard let relation = try await relation(choice, option, on: target) else { return nil }
        return try await use(target).controls.first { $0.id == relation.child.control }
    }

    @discardableResult
    func moveChild(_ choice: String, _ option: String, on target: String, to value: Double) async throws -> LibraryLiveMutation {
        guard let relation = try await relation(choice, option, on: target) else {
            throw QMSFailure("\(option) carries no sub-control")
        }
        return try await session.move(relation.child, expected: try await binding(target),
            optionGesture: LibraryOptionGesture(parent: relation.parent, option: relation.option), to: .scalar(value))
    }

    func moveRow(_ title: String, on target: String, to value: Double) async throws {
        let control = try await control(title, on: target)
        try await session.move(LibraryControlAddress(path: [], control: control.id), on: target, to: .scalar(value))
    }

    func position(_ control: UUID, on target: String) async throws -> Double? {
        if case .scalar(let value) = try await use(target).positions[control] { return value }
        return nil
    }
}
