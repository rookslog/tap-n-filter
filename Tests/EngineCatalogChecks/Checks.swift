import Foundation
import EffectCatalog
import PlaybackDSP
import PlaybackRenderBridge
import SessionStore
import EngineCatalogCore
@testable import SoundModel

struct EngineCatalogFailure: Error { let message: String }
func engineExpect(_ condition: Bool, _ message: String) throws {
    if !condition { throw EngineCatalogFailure(message: message) }
    print("PASS \(message)")
}
func engineRefuses(_ message: String, _ body: () throws -> Void) throws {
    do { try body() } catch { print("PASS \(message)"); return }
    throw EngineCatalogFailure(message: "admitted " + message)
}

enum EngineCatalogChecks {
    static let limits = try! LibraryLimits(maximumBytes: 8_000_000, maximumRevisions: 1024,
        expansion: LibraryExpansionLimits(maximumDepth: 24, maximumOccurrences: 256, maximumParts: 1024))

    static func run(_ directory: URL, witness: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try engineExpect(engine_catalog_contract_check() == 0, "Core mask, preset and every native target metadata refusal")
        let refusal = engine_catalog_abi_refusal_check()
        try engineExpect(refusal == 0, "Core refuses bit 0, foreign/inactive/unknown values, presets on presetless effects, absent required knobs, out-of-range values and ABI 1 (line \(refusal))")
        try catalogAgreement()
        try addressableParameters()
        try mapperBounds()
        try await preCatalogWitness(directory, fixture: witness.deletingLastPathComponent().appendingPathComponent("pre-catalog-engine-values.json"))
        try mapper()
        try physicalWitness(witness)
        try features()
        try await persistence(directory)
    }

    static func mapper() throws {
        let id = UUID(), format = try RenderProcessingFormat(sampleRate: 8_000, channels: 2, maximumFrames: 512)
        let token = FRToken(assignment: 1, source_epoch: 1, format_epoch: 1, topology: 1, intent: 1)
        func part(_ type: String, _ values: [(String, Double)]) -> ListeningRenderPart {
            ListeningRenderPart(id: id, path: [], type: type, parameters: values.map { ListeningParameter(key: $0.0, value: $0.1) })
        }
        func assignment(_ part: ListeningRenderPart) -> ListeningRenderAssignment {
            ListeningRenderAssignment(id: id, bundleIdentifier: "engine.synthetic", isEnabled: true, parts: [part])
        }
        var mapper = RenderAssignmentMapper()
        let wet = try mapper.lower(assignment(part("reverb", [("wetPercent", 25), ("roomPreset", 2)])), format: format, token: token)
        let sized = try mapper.lower(assignment(part("reverb", [("wetPercent", 25), ("roomPreset", 2), ("roomSize", 0.5)])), format: format, token: token)
        try engineExpect(wet.signature[0].kind == FR_REVERB.rawValue && wet.signature[0].parameterMask == 1 << FR_WET_PERCENT.rawValue,
            "wet-only reverb declares only wet and reserves no size binding")
        try engineExpect(sized.signature[0].key == wet.signature[0].key && sized.signature != wet.signature,
            "optional size keeps occurrence identity while presence changes topology")
        for preset in 1...5 {
            try RenderAssignmentMapper.admitParts([part("reverb", [("wetPercent", 25), ("roomPreset", Double(preset))])])
        }
        try engineRefuses("render mapper refuses alias outside the admitted model boundary") {
            try RenderAssignmentMapper.admitParts([part("sizedReverb", [("wetPercent", 25), ("roomPreset", 4), ("roomSize", 0.5)])])
        }
        for values: [(String, Double)] in [[("wetPercent", 1)], [("roomPreset", 1)], [("wetPercent", 1), ("roomPreset", 1), ("roomSize", .nan)], [("wetPercent", 1), ("roomPreset", 1), ("unknown", 0)]] {
            try engineRefuses("mapper refuses missing/unknown/nonfinite fields") { try RenderAssignmentMapper.admitParts([part("reverb", values)]) }
        }
        try engineRefuses("alias cannot infer absent size") { try RenderAssignmentMapper.admitParts([part("sizedReverb", [("wetPercent", 1), ("roomPreset", 1)])]) }
        let cutoff = try mapper.lower(assignment(part("deviceEQ", [("highPassHz", 20), ("lowPassHz", 20_000)])), format: format, token: token)
        try engineExpect(cutoff.adaptations.count == 1 && cutoff.adaptations[0].loweredHz == 3920, "generated cutoff policy preserves sample-rate adaptation")
        let profiles = try LibraryProfiles()
        try engineExpect(try profiles.descriptor(LibraryProfiles.quickMenu, type: "reverb").parameters.map(\.key.rawValue) == ["wetPercent", "roomPreset"],
            "optional catalog knob adds no seed or authoring row to wet-only reverb")
        try engineRefuses("legacy alias is not an add-part type") { _ = try profiles.descriptor(LibraryProfiles.everyday, type: "sizedReverb") }
        try engineExpect(LibraryProfiles.authoringKinds == ["deviceEQ", "deviceColour", "placeEQ", "reverb", "dynamics", "gain"], "no second reverb authoring kind")
    }

    static func physicalWitness(_ fixture: URL) throws {
        let expected = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: fixture))
        let profiles = try LibraryProfiles(), quick = try QuickMenuEveryday()
        let payload = LibraryPayload(profile: LibraryProfiles.quickMenu, block: quick.definition.content,
            presentation: try profiles.presentation(for: quick.definition), canonicalVersion: 5)
        try engineExpect(try payload.canonicalData.base64EncodedString() == expected["canonical5"] && payload.contentHash == expected["contentHash5"],
            "frozen pre-change Quick Menu canonical5 bytes and hash remain exact")
        let context = LibraryCompileContext(profiles: profiles, revisions: [:], limits: nil)
        let controls = quick.definition.content.controls
        var physical = ""
        for p in try controls[0].waypoints.positions(on: .value) {
            for d in try controls[1].waypoints.positions(on: .value) {
                let base = [OccurrenceControlKey(path: [], control: controls[0].id): ControlValue.scalar(p),
                            OccurrenceControlKey(path: [], control: controls[1].id): ControlValue.scalar(d)]
                var frames = [base]
                for relation in quick.definition.content.optionControls {
                    for endpoint in [0.0, 0.25, 0.5, 0.75, 1.0] {
                        var values = base; values[OccurrenceControlKey(path: [], control: relation.child)] = .scalar(try Position(endpoint))
                        frames.append(values)
                    }
                }
                for frame in frames {
                    let sound = try CompiledSound(payload: payload, root: quick.root, reference: nil, context: context, listening: UseListeningState(values: frame))
                    guard sound.parts.allSatisfy({ $0.type != "sizedReverb" }) else { throw EngineCatalogFailure(message: "compiled alias escaped") }
                    for part in try profiles.native(sound) {
                        physical += part.id.uuidString + ":" + part.path.map(\.uuidString).joined(separator: "/") + ":" + part.parameters.map { $0.key + "=" + String($0.value) }.joined(separator: ",") + "|"
                    }
                    physical += "\n"
                }
            }
        }
        try engineExpect(libraryDigest(Data(physical.utf8)) == expected["physicalDigest"], "416 frozen old Quick Menu target projections preserve every physical value and ID")
    }

    static func features() throws {
        let profiles = try LibraryProfiles(), quick = try QuickMenuEveryday()
        let old = LibraryPayload(profile: LibraryProfiles.quickMenu, block: quick.definition.content,
            presentation: try profiles.presentation(for: quick.definition), canonicalVersion: 5)
        let unified = try old.authoredReverb()
        try unified.validateCanonical()
        try engineExpect(unified.canonicalVersion == 6 && unified.requiresSchema9 && !unified.block.hasLegacySizedReverb,
            "new authored unified-size payload explicitly gates canonical6/schema9")
        try engineExpect(try unified.authoredReverb() == unified && unified.replacing() == unified, "authored alias normalization is idempotent")
        try engineExpect(unified.block.controls == old.block.controls && unified.block.optionControls == old.block.optionControls && unified.descendantDefaults == old.descendantDefaults && unified.authored == old.authored,
            "normalization preserves control/option identities, positions, descendants and adjustments")
        for (a,b) in zip(old.block.bindings!, unified.block.bindings!) {
            try engineExpect(a.id == b.id && a.source == b.source && a.target == b.target && a.reference == b.reference && a.response == b.response && a.status == b.status,
                "normalization preserves binding identity, target, response and state")
        }
        try engineRefuses("unified size cannot be written under canonical5") {
            try LibraryPayload(profile: old.profile, block: unified.block, presentation: old.presentation, canonicalVersion: 5).validateCanonical()
        }
        try engineRefuses("new canonical6 cannot spell legacy alias") {
            try LibraryPayload(profile: old.profile, block: old.block, presentation: old.presentation, canonicalVersion: 6).validateCanonical()
        }
        let plain = try LibraryArchive.initial(profiles: profiles)
        try engineExpect(plain.schema == 5 && plain.revisions.allSatisfy { $0.canonicalVersion == 1 }, "unrelated builtins retain old schema and canonical versions")
        let reverb = SoundPart(id: PartID(), type: "reverb", settings: try [
            ("wetPercent", Position(0.25)), ("roomPreset", Position(0.75))].map { ParameterSetting(key: try ParameterKey($0.0), position: $0.1) })
        let expanded = LibraryPayload(profile: LibraryProfiles.expandedReverb,
            block: try SoundBlock(pieces: [.part(reverb)], controls: [], mappings: []).promoted(), presentation: [], canonicalVersion: 6)
        let compiled = try CompiledSound(payload: expanded, root: RootUseID(), reference: nil,
            context: LibraryCompileContext(profiles: profiles, revisions: [:], limits: nil), listening: UseListeningState(positions: [:]))
        let native = try profiles.native(compiled)
        try engineExpect(native[0].parameters.first { $0.key == "roomPreset" }?.value == 4, "named expanded preset domain selects explicit Hall4 without widening historical domains")
        try RenderAssignmentMapper.admitParts(native)
        for (profile, child) in [(LibraryProfiles.quickMenu, unified.block), (LibraryProfiles.expandedReverb, expanded.block)] {
            let site = UseSiteID()
            let nested = LibraryPayload(profile: profile, block: try SoundBlock(pieces: [.block(BlockUse(site: site, content: child))], controls: [], mappings: []).promoted(), presentation: [], canonicalVersion: 6)
            let sound = try CompiledSound(payload: nested, root: RootUseID(), reference: nil,
                context: LibraryCompileContext(profiles: profiles, revisions: [:], limits: nil), listening: UseListeningState(positions: [:]))
            let parts = try profiles.native(sound)
            try engineExpect(parts.allSatisfy { $0.path == [site.rawValue] && $0.type != "sizedReverb" }, "bare inline blocks retain occurrence identity under unified catalog profiles")
            try engineExpect(parts.first { $0.type == "reverb" }?.parameters.first { $0.key == (profile == LibraryProfiles.quickMenu ? "roomSize" : "roomPreset") }?.value == (profile == LibraryProfiles.quickMenu ? 0.5 : 4), "bare inline blocks inherit optional-size and expanded-preset domains")
            try RenderAssignmentMapper.admitParts(parts)
        }
    }

    static func persistence(_ directory: URL) async throws {
        let profiles = try LibraryProfiles(), quick = try QuickMenuEveryday()
        // An old Quick Menu library holds only the two sounds it shipped with, at schema 8.
        let fresh = try LibraryArchive.initial(profiles: profiles, builtins: .quickMenu)
        let shipped = try fresh.revisions.filter { [quick.definition.id, try Filters().definition.id].contains($0.definition.id) }
        var source = LibraryArchive(format: fresh.format, schema: 8, commit: fresh.commit, provenance: fresh.provenance,
            revisions: shipped, heads: shipped.map { LibraryDefinitionRecord($0) }, uses: [], assignments: [], enabled: false)
        let old = source.revisions[0]
        let custom = BlockDefinition(id: DefinitionID(), version: DefinitionVersionID(), name: "Old custom", content: old.payload.block)
        let customRecord = LibraryRevision(definition: custom, origin: "custom", payload: old.payload, contentHash: old.contentHash)
        source.revisions.append(customRecord); source.heads.append(LibraryDefinitionRecord(customRecord))
        let workspaceBlock = SoundBlock(pieces: old.payload.block.pieces, controls: old.payload.block.controls,
            storage: old.payload.block.mappingStorage)
        let workspacePayload = LibraryPayload(profile: old.profile, block: workspaceBlock, presentation: old.payload.presentation, canonicalVersion: 5)
        let workspaceDefinition = BlockDefinition(id: DefinitionID(), version: DefinitionVersionID(), name: "Old editable choice", content: workspaceBlock)
        let workspaceRecord = try LibraryRevision(definition: workspaceDefinition, origin: "custom", payload: workspacePayload, contentHash: workspacePayload.contentHash)
        source.revisions.append(workspaceRecord); source.heads.append(LibraryDefinitionRecord(workspaceRecord))
        let site = UseSiteID(), parent = BlockDefinition(id: DefinitionID(), version: DefinitionVersionID(), name: "Nested old",
            content: try SoundBlock(pieces: [.block(BlockUse(site: site, payload: old.payload, original: custom.reference))], controls: [], mappings: []).promoted())
        let parentPayload = LibraryPayload(profile: LibraryProfiles.everyday, block: parent.content, presentation: [], canonicalVersion: 5)
        let parentRecord = try LibraryRevision(definition: parent, origin: "custom", payload: parentPayload, contentHash: parentPayload.contentHash)
        source.revisions.append(parentRecord); source.heads.append(LibraryDefinitionRecord(parentRecord))
        let url = directory.appendingPathComponent("owned-library.json")
        let store = LibrarySessionFile(url: url, maximumBytes: limits.maximumBytes)
        _ = try await store.load()
        try engineExpect(await store.commit(try source.encoded()).isAccepted, "old mixed history seeded through owned atomic store")
        try Data(contentsOf: url).write(to: directory.appendingPathComponent("original-library.json"))
        let admittedSource = try SoundLibrarySession.storedArchive(Data(contentsOf: url), limits: limits)
        let session = try await SoundLibrarySession(persistence: store, limits: limits)
        for target in ["engine.one", "engine.two"] { _ = try await session.select(custom.id.rawValue, on: target) }
        let child = quick.definition.content.optionControls[0]
        let parentControl = quick.definition.content.controls.first { $0.id == child.parentChoice }!
        if case .choice(let choice) = parentControl.face {
            try await session.move(child.parentChoice.rawValue, on: "engine.one", to: .scalar(try choice.position(of: child.option).value))
        }
        try await session.move(child.child.rawValue, on: "engine.one", to: .scalar(0.73))
        _ = try await session.checkpoint()
        let listened = try SoundLibrarySession.storedArchive(Data(contentsOf: url), limits: limits)
        try engineExpect(listened.schema == 8 && listened.revisions == admittedSource.revisions, "ordinary listening save neither publishes nor rewrites old history")
        let snapshot = try await session.snapshot(), selected = snapshot.assignments.first { $0.target == "engine.one" }!
        try engineExpect(selected.parts.allSatisfy { $0.type != "sizedReverb" }, "admitted legacy archive renders only unified reverb")
        let binding = LibraryBinding(assignment: selected.id, use: selected.use, target: selected.target)
        var edit = try await session.beginEdit(.use(binding), admission: { try RenderAssignmentMapper.admitParts($0) })
        var aliasRefused = false
        do { _ = try await session.edit(edit.handle, expectedGeneration: edit.generation, command: .addPart(type: "sizedReverb", at: 0)) }
        catch LibraryError.unsupportedEdit { aliasRefused = true }
        let afterAliasRefusal = try await session.inspectEdit(edit.handle)
        try engineExpect(aliasRefused && afterAliasRefusal.generation == edit.generation && afterAliasRefusal.parts == edit.parts, "public authoring cannot create the read-only legacy alias")
        let gain = edit.parts.first { $0.type == "gain" }!
        edit = try await session.edit(edit.handle, expectedGeneration: edit.generation, command: .setPhysical(part: gain.id, parameter: "gainDb", value: -11))
        _ = try await session.checkpointEdit(edit.handle, expectedGeneration: edit.generation)
        var workspace = try await session.beginEdit(.definition(workspaceDefinition.id.rawValue), admission: { try RenderAssignmentMapper.admitParts($0) })
        let removed = quick.definition.content.controls[1]
        if case .choice(let choice) = removed.face {
            let preview = try await session.previewOptionEdit(workspace.handle, expectedGeneration: workspace.generation,
                address: LibraryControlAddress(path: [], control: removed.id.rawValue), mutation: .remove(id: choice.options[1].rawValue, replacement: choice.options[0].rawValue))
            workspace = try await session.applyOptionEdit(preview).snapshot
        }
        let workspaceGain = workspace.parts.first { $0.type == "gain" }!
        workspace = try await session.edit(workspace.handle, expectedGeneration: workspace.generation, command: .bypassPart(workspaceGain.id, true))
        _ = try await session.checkpointEdit(workspace.handle, expectedGeneration: workspace.generation)
        _ = try await session.select(workspaceDefinition.id.rawValue, on: "engine.capture")
        let captureAssignment = try await session.snapshot().assignments.first { $0.target == "engine.capture" }!
        let captured = try await session.createFromUse(expected: LibraryBinding(assignment: captureAssignment.id, use: captureAssignment.use, target: captureAssignment.target), name: "Captured legacy alias")
        try engineExpect(captured.commit.outcome.isAccepted, "public create-from-use writes a new unified authored revision")
        let duplicated = try await session.duplicate(LibraryReference(definition: parent.id.rawValue, revision: parent.version.rawValue), name: "New nested")
        try engineExpect(duplicated.commit.outcome.isAccepted, "public duplication appends a normalized nested revision")
        let saved = try SoundLibrarySession.storedArchive(Data(contentsOf: url), limits: limits)
        try engineExpect(saved.schema == 9 && saved.revisions.prefix(admittedSource.revisions.count).elementsEqual(admittedSource.revisions), "schema9 keeps exact old revision records beside new content")
        try engineExpect(saved.uses.first { $0.target.bundleIdentifier == "engine.one" }?.draft?.canonicalVersion == 6 && saved.workspaces.first?.payload.canonicalVersion == 6,
            "use-local draft and offline workspace use canonical6 only after authored changes")
        let intent = saved.workspaces.first?.optionRemovals
        try engineExpect(intent?.isEmpty == false, "option-removal replacement intent survives engine normalization")
        let copied = saved.revisions.last!.payload
        guard case .block(let nested) = copied.block.pieces[0] else { throw EngineCatalogFailure(message: "nested payload missing") }
        try engineExpect(nested.site == site && nested.original == custom.reference && nested.payload?.canonicalVersion == 6,
            "nested payload normalization preserves use site and exact old reference")
        let reopened = try await SoundLibrarySession(persistence: LibrarySessionFile(url: url, maximumBytes: limits.maximumBytes), limits: limits)
        let beforeBytes = try Data(contentsOf: url)
        _ = try await reopened.snapshot()
        _ = try await reopened.checkpoint()
        let again = try SoundLibrarySession.storedArchive(Data(contentsOf: url), limits: limits)
        try engineExpect(again.revisions == saved.revisions && again.uses == saved.uses && again.workspaces == saved.workspaces,
            "actual reopen/checkpoint preserves history, both app states, drafts, workspace and removal intent")
        try engineExpect(beforeBytes == Data(contentsOf: url), "reopen and unchanged save are byte-idempotent")
        for mode in 0...2 {
            var json = try JSONSerialization.jsonObject(with: beforeBytes) as! [String: Any]
            if mode == 0 { json["schema"] = 8 }
            else {
                var revisions = json["revisions"] as! [[String: Any]]
                if mode == 1 { revisions[0]["contentHash"] = String(repeating: "0", count: 64) }
                else { revisions[revisions.count - 1]["canonicalVersion"] = 5 }
                json["revisions"] = revisions
            }
            let bytes = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            let malformed = directory.appendingPathComponent("malformed-\(mode).json")
            try bytes.write(to: malformed)
            guard case .refused = await SoundLibrarySession.open(persistence: LibrarySessionFile(url: malformed, maximumBytes: limits.maximumBytes), limits: limits) else {
                throw EngineCatalogFailure(message: "malformed feature gate/hash admitted")
            }
            try engineExpect(try Data(contentsOf: malformed) == bytes, "malformed schema/hash/version refuses atomically without rewriting \(mode)")
        }
        let restoredWorkspace = try await reopened.beginEdit(.definition(workspaceDefinition.id.rawValue), admission: { try RenderAssignmentMapper.admitParts($0) })
        let publication = try await reopened.previewUpdateLibrary(restoredWorkspace.handle, expectedGeneration: restoredWorkspace.generation, places: [])
        let published = try await reopened.confirmUpdateLibrary(publication)
        try engineExpect(published.commit.outcome.isAccepted, "explicit public publication appends a new version")
        let afterPublication = try SoundLibrarySession.storedArchive(Data(contentsOf: url), limits: limits)
        try engineExpect(afterPublication.revisions.count == saved.revisions.count + 1 && afterPublication.revisions.prefix(saved.revisions.count).elementsEqual(saved.revisions) && afterPublication.revisions.last?.canonicalVersion == 6,
            "publication preserves every old revision and appends only unified canonical6 content")
        try engineExpect(afterPublication.workspaces.first?.optionRemovals == nil && afterPublication.uses == saved.uses,
            "accepted publication retires only source removal intent and preserves app-local drafts and state")
    }
}

// MARK: - Catalog agreement, addressable parameters and pre-catalog saved sounds
//
// These cases were written separately from the catalog builder. They read
// Config/EffectCatalog.json directly and compare it with what was compiled: the
// Swift table, the public C enums and the C++ native contracts. A stale or
// hand-edited generated file therefore fails `swift test`, not only the
// generator's `--check`.

extension EngineCatalogChecks {
    static var catalogURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Config/EffectCatalog.json")
    }

    static func catalogJSON() throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any] else {
            throw EngineCatalogFailure(message: "catalog JSON is not an object")
        }
        return json
    }

    static func number(_ value: Any?) throws -> Double {
        guard let value = value as? NSNumber else { throw EngineCatalogFailure(message: "catalog value is not a number") }
        return value.doubleValue
    }

    static func fourCC(_ text: String) -> UInt32 { text.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

    // Pinned public C symbols. A new catalog symbol must be added here on purpose.
    static let cParameters: [String: UInt32] = [
        "FR_HP_HZ": FR_HP_HZ.rawValue, "FR_LP_HZ": FR_LP_HZ.rawValue, "FR_WET_PERCENT": FR_WET_PERCENT.rawValue,
        "FR_PREGAIN_DB": FR_PREGAIN_DB.rawValue, "FR_THRESHOLD_DB": FR_THRESHOLD_DB.rawValue,
        "FR_HEADROOM_DB": FR_HEADROOM_DB.rawValue, "FR_EXPANSION_RATIO": FR_EXPANSION_RATIO.rawValue,
        "FR_EXPANSION_THRESHOLD_DB": FR_EXPANSION_THRESHOLD_DB.rawValue, "FR_ATTACK_SECONDS": FR_ATTACK_SECONDS.rawValue,
        "FR_RELEASE_SECONDS": FR_RELEASE_SECONDS.rawValue, "FR_MAKEUP_DB": FR_MAKEUP_DB.rawValue,
        "FR_GAIN_DB": FR_GAIN_DB.rawValue, "FR_ROOM_SIZE": FR_ROOM_SIZE.rawValue,
    ]
    static let cKinds: [String: UInt32] = [
        "FR_DEVICE_EQ": FR_DEVICE_EQ.rawValue, "FR_DEVICE_COLOUR": FR_DEVICE_COLOUR.rawValue, "FR_PLACE_EQ": FR_PLACE_EQ.rawValue,
        "FR_REVERB": FR_REVERB.rawValue, "FR_DYNAMICS": FR_DYNAMICS.rawValue, "FR_GAIN": FR_GAIN.rawValue,
    ]

    static func catalogAgreement() throws {
        let json = try catalogJSON()
        let parameters = json["parameters"] as! [[String: Any]], effects = json["effects"] as! [[String: Any]]
        var byKey: [String: [String: Any]] = [:]
        for parameter in parameters {
            let key = parameter["key"] as! String, symbol = parameter["symbol"] as! String
            try engineExpect(byKey.updateValue(parameter, forKey: key) == nil, "catalog key \(key) has exactly one parameter row")
            try engineExpect(cParameters[symbol] == UInt32(try number(parameter["id"])), "C enum \(symbol) equals catalog id")
        }
        try engineExpect(Set(cParameters.keys) == Set(parameters.map { $0["symbol"] as! String }), "C parameter enum and catalog list the same symbols")
        try engineExpect(EffectCatalog.effects.map(\.type) == effects.map { $0["type"] as! String }, "Swift catalog lists the catalog's effects in order")
        try engineExpect((json["reservedKinds"] as! [NSNumber]).map(\.uint32Value) == [FR_RESERVED_KIND_7.rawValue]
            && !effects.contains { (($0["id"] as! NSNumber).uint32Value) == 7 }, "kind 7 stays reserved in JSON, C and Swift")
        var nativeRows: [EngineCatalogNativeRow] = []
        var row = EngineCatalogNativeRow()
        while engine_catalog_native_row(UInt32(nativeRows.count), &row) == 1 { nativeRows.append(row) }
        var effectRows: [EngineCatalogEffectRow] = []
        var effectRow = EngineCatalogEffectRow()
        while engine_catalog_effect_row(UInt32(effectRows.count), &effectRow) == 1 { effectRows.append(effectRow) }
        try engineExpect(effectRows.count == effects.count, "C++ contracts list the catalog's effect count")
        var nativeIndex = 0
        for (index, effect) in effects.enumerated() {
            let type = effect["type"] as! String, kind = UInt32(try number(effect["id"]))
            guard let swift = EffectCatalog.effect(type) else { throw EngineCatalogFailure(message: "Swift catalog lacks \(type)") }
            try engineExpect(cKinds[effect["symbol"] as! String] == kind && swift.kind == kind && effectRows[index].kind == kind,
                "\(type) kind agrees across JSON, C enum, Swift and C++")
            let presets = (effect["presets"] as! [[String: Any]]).map { UInt32(($0["id"] as! NSNumber).uint32Value) }
            let nativePresets = withUnsafeBytes(of: effectRows[index].presets) { Array($0.bindMemory(to: UInt32.self).prefix(Int(effectRows[index].presetCount))) }
            try engineExpect(swift.presets == Set(presets) && nativePresets == presets && swift.presetKey == effect["presetKey"] as? String,
                "\(type) presets and preset key agree across JSON, Swift and C++")
            let component = effect["component"] as! [String: String]
            try engineExpect(effectRows[index].componentType == fourCC(component["type"]!) && effectRows[index].componentSubtype == fourCC(component["subtype"]!)
                && effectRows[index].manufacturer == fourCC(component["manufacturer"]!), "\(type) native component identity agrees")
            let knobs = effect["knobs"] as! [[String: Any]]
            try engineExpect(swift.parameters.map(\.key) == knobs.map { $0["parameter"] as! String }, "\(type) Swift knob order matches catalog")
            var required: UInt32 = 0, allowed: UInt32 = 0
            for (knob, swiftKnob) in zip(knobs, swift.parameters) {
                let parameter = byKey[knob["parameter"] as! String]!
                let id = UInt32(try number(parameter["id"])), range = parameter["range"] as! [NSNumber]
                let optional = knob["optional"] as! Bool
                allowed |= 1 << id; if !optional { required |= 1 << id }
                try engineExpect(swiftKnob.id == id && swiftKnob.lower == range[0].doubleValue && swiftKnob.upper == range[1].doubleValue
                    && swiftKnob.optional == optional && swiftKnob.unit == parameter["unit"] as! String
                    && swiftKnob.cutoff == ((parameter["conversion"] as! String) == "sampleRateCutoff"),
                    "\(type).\(swiftKnob.key) Swift id, range, unit, presence and conversion match catalog")
                for target in knob["targets"] as! [[String: Any]] {
                    guard nativeIndex < nativeRows.count else { throw EngineCatalogFailure(message: "C++ contracts have fewer native targets than the catalog") }
                    let native = nativeRows[nativeIndex]; nativeIndex += 1
                    let units = (target["units"] as! [NSNumber]).reduce(UInt32(0)) { $0 | 1 << $1.uint32Value }
                    let targetRange = target["range"] as! [NSNumber]
                    try engineExpect(native.kind == kind && native.parameter == id && (native.optional == 1) == optional
                        && native.target == UInt32(try number(target["id"])) && native.scope == UInt32(try number(target["scope"]))
                        && native.element == UInt32(try number(target["element"])) && native.units == units
                        && (native.readable == 1) == (target["readable"] as! Bool) && (native.writable == 1) == (target["writable"] as! Bool)
                        && native.lower == targetRange[0].floatValue && native.upper == targetRange[1].floatValue
                        && native.logicalLower == range[0].floatValue && native.logicalUpper == range[1].floatValue,
                        "\(type).\(swiftKnob.key) native target \(native.target) agrees between JSON and C++")
                }
            }
            try engineExpect(effectRows[index].requiredMask == required && effectRows[index].allowedMask == allowed, "\(type) C++ required/allowed masks follow knob presence")
            for (name, rows) in effect["profiles"] as! [String: [[String: Any]]] {
                guard let swiftRows = swift.profiles[name] else { throw EngineCatalogFailure(message: "Swift catalog lacks \(type) \(name)") }
                try engineExpect(swiftRows.map(\.key) == rows.map { $0["key"] as! String }, "\(type) \(name) profile keys match")
                for (profile, swiftProfile) in zip(rows, swiftRows) {
                    let range = profile["range"] as! [NSNumber]
                    try engineExpect(swiftProfile.lower == range[0].doubleValue && swiftProfile.upper == range[1].doubleValue
                        && swiftProfile.seed == (try number(profile["seed"])) && swiftProfile.discrete == (profile["discrete"] as! Bool)
                        && swiftProfile.logarithmic == ((profile["scale"] as! String) == "logarithmic"),
                        "\(type) \(name).\(swiftProfile.key) Swift range, seed and scale match catalog")
                }
            }
            try engineExpect(Set(swift.profiles.keys) == Set((effect["profiles"] as! [String: Any]).keys), "\(type) Swift and catalog list the same profiles")
        }
        try engineExpect(nativeIndex == nativeRows.count, "C++ contracts carry no native target absent from the catalog")
    }

    /// Every parameter an authoring profile exposes resolves to one catalog row with the catalog's range, seed and unit.
    static func addressableParameters() throws {
        let json = try catalogJSON(), profiles = try LibraryProfiles()
        let parameters = json["parameters"] as! [[String: Any]], effects = json["effects"] as! [[String: Any]]
        for profile in [LibraryProfiles.everyday, LibraryProfiles.filters, LibraryProfiles.quickMenu, LibraryProfiles.expandedReverb] {
            for type in LibraryProfiles.authoringKinds {
                guard let descriptor = try? profiles.descriptor(profile, type: type, includingOptional: true) else { continue }
                let effect = effects.first { $0["type"] as! String == type }!
                let rows = effect["profiles"] as! [String: [[String: Any]]]
                let name = profile == LibraryProfiles.expandedReverb ? "unified.v1" : profile == LibraryProfiles.filters ? "filters.v1" : "everyday.v1"
                let domain = (rows[name] ?? rows["everyday.v1"]!) + (rows["quickMenu.v1"] ?? []).filter { row in
                    !(rows[name] ?? rows["everyday.v1"]!).contains { $0["key"] as! String == row["key"] as! String } }
                for parameter in descriptor.parameters {
                    let key = parameter.key.rawValue
                    let knobs = (effect["knobs"] as! [[String: Any]]).filter { $0["parameter"] as! String == key }
                    let isPreset = effect["presetKey"] as? String == key
                    try engineExpect(isPreset ? knobs.isEmpty : knobs.count == 1 && parameters.filter { $0["key"] as! String == key }.count == 1,
                        "\(profile) \(type).\(key) has exactly one catalog row")
                    guard let row = domain.first(where: { $0["key"] as! String == key }) else {
                        throw EngineCatalogFailure(message: "\(profile) \(type).\(key) has no catalog profile row")
                    }
                    let range = row["range"] as! [NSNumber], seed = try number(row["seed"])
                    let bounds: (Double, Double)
                    switch parameter.domain { case .linear(let a, let b), .logarithmic(let a, let b): bounds = (a, b) }
                    let roundTrip = (try? parameter.domain.value(parameter.domain.position(seed))) ?? .nan
                    let unit = isPreset ? "" : parameters.first { $0["key"] as! String == key }!["unit"] as! String
                    try engineExpect(bounds == (range[0].doubleValue, range[1].doubleValue) && (parameter.seed == seed || parameter.seed == roundTrip) && parameter.unit == unit,
                        "\(profile) \(type).\(key) range, default and unit come from the catalog")
                }
            }
        }
    }

    /// Values outside a knob's catalog range and unknown ids refuse at the mapper; nothing is clamped.
    static func mapperBounds() throws {
        func part(_ type: String, _ values: [(String, Double)]) -> ListeningRenderPart {
            ListeningRenderPart(id: UUID(), path: [], type: type, parameters: values.map { ListeningParameter(key: $0.0, value: $0.1) })
        }
        try RenderAssignmentMapper.admitParts([part("gain", [("gainDb", 6)]), part("gain", [("gainDb", -96)])])
        for (type, values) in [
            ("gain", [("gainDb", 6.5)]), ("gain", [("gainDb", -96.5)]),
            ("reverb", [("wetPercent", 100.5), ("roomPreset", 1)]), ("reverb", [("wetPercent", 10), ("roomPreset", 1), ("roomSize", 1.25)]),
            ("reverb", [("wetPercent", 10), ("roomPreset", 6)]), ("reverb", [("wetPercent", 10), ("roomPreset", 2.5)]),
            ("dynamics", [("thresholdDb", 0), ("headroomDb", 0), ("expansionRatio", 1), ("expansionThresholdDb", -60),
                          ("attackSeconds", 0.01), ("releaseSeconds", 0.1), ("makeupDb", 0)]),
            ("chorus", [("wetPercent", 10)]), ("gain", [("gainDb", 0), ("gainDb", 0)]),
        ] as [(String, [(String, Double)])] {
            try engineRefuses("mapper refuses \(type) \(values.map { "\($0.0)=\($0.1)" }.joined(separator: ","))") {
                try RenderAssignmentMapper.admitParts([part(type, values)])
            }
        }
    }

    /// A Quick Menu library saved by the pre-catalog app (FixedRender ABI 1) reopens and lowers to the same
    /// engine values, bit for bit. The only translation allowed is the old sized-reverb kind 7 becoming kind 4.
    static func preCatalogWitness(_ directory: URL, fixture: URL) async throws {
        let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as! [String: Any]
        func translated(_ line: String) -> String { line.replacingOccurrences(of: " k7 ", with: " k4 ") }
        let format = try RenderProcessingFormat(sampleRate: 48_000, channels: 2, maximumFrames: 512)
        let saved = Data(base64Encoded: expected["savedArchiveBase64"] as! String)!
        let url = directory.appendingPathComponent("pre-catalog-library.json")
        try saved.write(to: url)
        let session = try await SoundLibrarySession(persistence: LibrarySessionFile(url: url, maximumBytes: WitnessRows.limits.maximumBytes), limits: WitnessRows.limits)
        let app = expected["appAssignments"] as! [String: String]
        let assignments = try await session.snapshot().assignments
        try engineExpect(Set(assignments.map(\.target)) == Set(app.keys), "pre-catalog saved app targets reopen")
        for assignment in assignments {
            try engineExpect(try WitnessRows.line(assignment.parts, format: format) == translated(app[assignment.target]!),
                "pre-catalog saved \(assignment.target) lowers to the same engine values")
        }
        _ = try await session.checkpoint()
        try engineExpect(try Data(contentsOf: url) == saved, "reopening a pre-catalog library and saving unchanged leaves its bytes untouched")
        let archive = try SoundLibrarySession.storedArchive(saved, limits: WitnessRows.limits)
        let revision = archive.revisions[0]
        try engineExpect(archive.schema == expected["archiveSchema"] as! Int && revision.contentHash == expected["builtinContentHash"] as! String,
            "pre-catalog archive admits with its original schema and builtin hash")
        let profiles = try LibraryProfiles(), quick = try QuickMenuEveryday()
        let context = LibraryCompileContext(profiles: profiles, revisions: [:], limits: nil)
        let grid = expected["builtinGrid"] as! [String]
        let frames = try WitnessRows.controlGrid(revision.payload.block)
        try engineExpect(frames.count == grid.count, "pre-catalog grid has \(grid.count) frames")
        var mismatches: [Int] = []
        for (index, frame) in frames.enumerated() {
            let sound = try CompiledSound(payload: revision.payload, root: quick.root, reference: nil, context: context, listening: UseListeningState(values: frame))
            if try WitnessRows.line(try profiles.native(sound), format: format) != translated(grid[index]) { mismatches.append(index) }
        }
        try engineExpect(mismatches.isEmpty, "\(grid.count) pre-catalog Quick Menu control positions lower to identical engine values (mismatches \(mismatches.prefix(5)))")
        let everydayURL = directory.appendingPathComponent("pre-catalog-everyday.json")
        let schema2 = try Data(contentsOf: fixture.deletingLastPathComponent().appendingPathComponent("everyday-v5-library.json"))
        let everydaySession = try await SoundLibrarySession(persistence: LibrarySessionFile(url: everydayURL, maximumBytes: WitnessRows.limits.maximumBytes),
            limits: WitnessRows.limits, migratingSchema2: schema2)
        let everyday = expected["everydaySchema2Assignments"] as! [String: String]
        let migrated = try await everydaySession.snapshot().assignments
        try engineExpect(Set(migrated.map(\.target)) == Set(everyday.keys), "pre-catalog schema-2 document migrates the same targets")
        for assignment in migrated {
            try engineExpect(try WitnessRows.line(assignment.parts, format: format) == translated(everyday[assignment.target]!),
                "pre-catalog schema-2 \(assignment.target) lowers to the same engine values")
        }
    }
}

extension WitnessRows {
    /// ABI 2: the presence mask declares exactly the values the frame carries for this part.
    static func checkPresence(_ part: FRPart, _ values: [FRValue]) throws {
        let mask = values.reduce(UInt32(0)) { $0 | 1 << $1.parameter }
        guard part.parameter_mask == mask, part.reserved == 0 else {
            throw WitnessError(message: "kind \(part.kind) mask \(part.parameter_mask) != frame values \(mask)")
        }
    }
}
// Shared row format for the pre-catalog engine-value witness. Compiled against the
// pre-change tree to export, and copied verbatim into the post-change check.
enum WitnessRows {
    static let limits = try! LibraryLimits(maximumBytes: 8_000_000, maximumRevisions: 1024,
        expansion: LibraryExpansionLimits(maximumDepth: 24, maximumOccurrences: 256, maximumParts: 1024))

    /// One line per lowered state: every program part in order with its sorted frame values as Float bits.
    static func line(_ parts: [ListeningRenderPart], format: RenderProcessingFormat) throws -> String {
        var mapper = RenderAssignmentMapper()
        let token = FRToken(assignment: 1, source_epoch: 1, format_epoch: 1, topology: 1, intent: 1)
        let assignment = ListeningRenderAssignment(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            bundleIdentifier: "witness.target", isEnabled: true, parts: parts)
        let state = try mapper.lower(assignment, format: format, token: token)
        let program: [FRPart] = withUnsafeBytes(of: state.program.parts) { Array($0.bindMemory(to: FRPart.self).prefix(Int(state.program.count))) }
        let values: [FRValue] = withUnsafeBytes(of: state.frame.values) { Array($0.bindMemory(to: FRValue.self).prefix(Int(state.frame.count))) }
        guard program.count == parts.count else { throw WitnessError(message: "program/part count \(program.count) != \(parts.count)") }
        var fields: [String] = []
        for (index, part) in program.enumerated() {
            let source = parts[index]
            let own = values.filter { $0.key == part.key }.sorted { $0.parameter < $1.parameter }
            try checkPresence(part, own)
            fields.append(source.path.map(\.uuidString).joined(separator: "/") + ">" + source.id.uuidString
                + " k" + String(part.kind) + " p" + String(part.preset) + " "
                + own.map { String($0.parameter) + ":" + String($0.value.bitPattern, radix: 16) }.joined(separator: ","))
        }
        return fields.joined(separator: " | ")
    }

    static func controlGrid(_ block: SoundBlock) throws -> [[OccurrenceControlKey: ControlValue]] {
        let controls = block.controls
        var frames: [[OccurrenceControlKey: ControlValue]] = []
        for p in try controls[0].waypoints.positions(on: .value) {
            for d in try controls[1].waypoints.positions(on: .value) {
                let base = [OccurrenceControlKey(path: [], control: controls[0].id): ControlValue.scalar(p),
                            OccurrenceControlKey(path: [], control: controls[1].id): ControlValue.scalar(d)]
                frames.append(base)
                for relation in block.optionControls {
                    for endpoint in [0.0, 0.37, 0.5, 0.73, 1.0] {
                        var values = base
                        values[OccurrenceControlKey(path: [], control: relation.child)] = .scalar(try Position(endpoint))
                        frames.append(values)
                    }
                }
            }
        }
        return frames
    }
}

struct WitnessError: Error { let message: String }
