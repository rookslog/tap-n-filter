import Foundation

// Library archives refuse unknown semantics before shared Codable records can discard them.
// A future field needs an explicit schema/feature compatibility decision, not silent admission.
enum LibraryWireAdmission {
    /// Foundation keyed decoding would otherwise silently keep one repeated key.
    /// Scan strings/object scopes only; JSONDecoder remains the syntax/value parser.
    static func uniqueKeys(_ data: Data) throws {
        let bytes = Array(data); var index = 0, objects: [Set<String>] = []
        while index < bytes.count {
            switch bytes[index] {
            case 123: objects.append([]); index += 1
            case 125:
                guard !objects.isEmpty else { throw LibraryError.invalidArchive }
                objects.removeLast(); index += 1
            case 34:
                let start = index; index += 1
                while index < bytes.count && bytes[index] != 34 {
                    if bytes[index] == 92 { index += 1 }
                    index += 1
                }
                guard index < bytes.count else { throw LibraryError.invalidArchive }
                index += 1
                let end = index
                while index < bytes.count && [9,10,13,32].contains(bytes[index]) { index += 1 }
                if index < bytes.count && bytes[index] == 58 {
                    guard !objects.isEmpty else { throw LibraryError.invalidArchive }
                    let key = try JSONDecoder().decode(String.self, from: Data(bytes[start..<end]))
                    guard objects[objects.count - 1].insert(key).inserted else { throw LibraryError.invalidArchive }
                }
            default: index += 1
            }
        }
        guard objects.isEmpty else { throw LibraryError.invalidArchive }
    }

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    private indirect enum Shape {
        case value
        case record([String: Shape])
        case list(Shape)
        case variant([String: Shape])
        case block
        case payload

        func check(_ decoder: Decoder, depth: Int = 0, limits: LibraryExpansionLimits? = nil, mappings: Bool = false, optionIntent: Bool = false, optionControls: Bool = false, schema8: Bool = false) throws {
            if try decoder.singleValueContainer().decodeNil() { return }
            switch self {
            case .value: return
            case .payload:
                try LibraryWireAdmission.payload(legacy: false, authoring: true).check(decoder, depth: depth, limits: limits, mappings: mappings, optionIntent: optionIntent, optionControls: optionControls, schema8: schema8)
            case .block:
                if let limits, depth >= limits.maximumDepth { throw LibraryError.expansionExceeded }
                try LibraryWireAdmission.block(mappings: mappings, optionControls: optionControls).check(decoder, depth: depth + 1, limits: limits, mappings: mappings, optionIntent: optionIntent, optionControls: optionControls, schema8: schema8)
            case .list(let element):
                var values = try decoder.unkeyedContainer()
                while !values.isAtEnd { try element.check(values.superDecoder(), depth: depth, limits: limits, mappings: mappings, optionIntent: optionIntent, optionControls: optionControls, schema8: schema8) }
            case .record(var fields), .variant(var fields):
                let values = try decoder.container(keyedBy: Key.self)
                var optionControls = optionControls
                if let key = Key(stringValue: "canonicalVersion"), values.contains(key) {
                    let version = try values.decode(Int.self, forKey: key)
                    optionControls = schema8 && version >= 5
                }
                if mappings, fields["path"] != nil, fields["id"] != nil, fields["value"] != nil {
                    fields["dormant"] = .value; fields["retiredControl"] = LibraryWireAdmission.control
                    fields["adjustments"] = .list(.record(["axis": .value, "value": .value]))
                }
                if optionIntent, (fields["draft"] != nil || fields["info"] != nil), fields["positions"] != nil {
                    fields["optionRemovals"] = .list(.record(["base": LibraryWireAdmission.reference, "path": .list(.value),
                        "control": .value, "schema": .list(.value), "removed": .value, "replacement": .value]))
                }
                guard Set(values.allKeys.map(\.stringValue)).isSubset(of: Set(fields.keys)) else {
                    throw LibraryError.unsupportedFormat
                }
                if case .variant = self, values.allKeys.count != 1 { throw LibraryError.unsupportedFormat }
                for key in values.allKeys {
                    if let shape = fields[key.stringValue] { try shape.check(values.superDecoder(forKey: key), depth: depth, limits: limits, mappings: mappings, optionIntent: optionIntent, optionControls: optionControls, schema8: schema8) }
                }
            }
        }
    }
    private static let id = Shape.record(["rawValue": .value])
    private static let reference = Shape.record(["id": id, "version": id])
    private static let name = Shape.variant(["library": .record([:]), "own": .record(["_0": .value])])
    private static let value = Shape.variant([
        "scalar": .record(["_0": .value]), "xy": .record(["x": .value, "y": .value]),
    ])
    private static let face = Shape.variant([
        "slider": .record([:]), "choice": .record(["_0": .list(id)]), "xy": .record([:]),
    ])
    private static let waypoints = Shape.variant([
        "scalar": .record(["_0": .list(.value)]),
        "xy": .record(["x": .list(.value), "y": .list(.value)]),
    ])
    private static let curve = Shape.record([
        "waypoints": .list(.record(["position": .value, "value": .value])),
        "segments": .list(.record(["shape": .value, "first": .value, "second": .value, "jump": .value])),
    ])
    private static func block(mappings: Bool, optionControls: Bool) -> Shape {
        var fields: [String: Shape] = [
            "pieces": .list(.variant([
                "part": .record(["_0": .record([
                    "id": id, "type": .value,
                    "settings": .list(.record(["key": .value, "position": .value])),
                ])]),
                "block": .record(["_0": .record(mappings ? ["site": id, "content": .block, "payload": .payload, "original": reference] : ["site": id, "content": .block])]),
                "reference": .record(["_0": .record(["site": id, "definition": reference])]),
            ])),
            "controls": .list(.record(["id": id, "face": face, "position": value, "waypoints": waypoints])),
            "mappings": .list(.record([
                "control": id, "axis": .value, "part": id, "parameter": .value, "curve": curve,
            ])),
        ]
        if mappings {
            fields["bindings"] = .list(binding)
            fields["selections"] = .list(.record(["source": id, "selector": id]))
        }
        if optionControls {
            fields["optionControls"] = .list(.variant(["choiceOption": .record(["parentChoice": id, "option": id, "child": id])]))
        }
        return .record(fields)
    }
    private static let control = Shape.record(["id": id, "face": face, "position": value, "waypoints": waypoints])
    private static let transfer = Shape.variant([
        "continuous": .record(["_0": curve]),
        "choices": .record(["_0": .list(.record(["option": .value, "value": .value]))]),
    ])
    private static let binding = Shape.record([
        "id": .value, "source": .variant(["control": .record(["id": .value, "axis": .value])]),
        "target": .variant([
            "setting": .record(["part": .value, "parameter": .value]),
            "control": .record(["site": .value, "control": .value, "axis": .value]),
        ]),
        "reference": .value,
        "response": .variant([
            "lane": .record(["_0": transfer]),
            "options": .record(["selector": id, "cases": .list(.record(["option": id, "lane": transfer]))]),
        ]),
        "status": .variant(["active": .record([:]), "broken": .record(["_0": .value])]),
        "provenance": .record(["source": control, "selector": control, "target": control, "setting": .record(["id": id, "type": .value, "settings": .list(.record(["key": .value, "position": .value]))])]),
    ])
    private static let option = Shape.record(["id": .value, "title": .value, "position": .value])
    private static let presentation = Shape.list(.record([
        "id": .value, "title": .value, "placement": .value,
        "face": .variant([
            "slider": .record(["_0": .value, "_1": .value]),
            "choice": .record(["_0": .list(option)]), "xy": .record([:]),
        ]),
        "readout": .variant([
            "frequency": .record(["_0": .value, "_1": .value]),
            "wetPercent": .record(["_0": .value]),
            "decibels": .record(["_0": .value, "_1": .value]), "positionPercent": .record([:]),
        ]),
    ]))
    private static func savedPosition(legacy: Bool) -> Shape {
        var fields: [String: Shape] = ["id": id, "value": value]
        if !legacy { fields["path"] = .list(id) }
        return .record(fields)
    }
    private static let authored = Shape.record(["bypassed": .list(id), "adjustments": .list(.record(["address": .record(["part": id, "parameter": .value]), "value": .value]))])
    private static let draftInfo = Shape.record(["id": .value, "generation": .value, "structural": .value])
    private static func payload(legacy: Bool, authoring: Bool = false) -> Shape {
        var fields: [String: Shape] = ["profile": .value, "block": .block, "presentation": presentation]
        if !legacy {
            fields["canonicalVersion"] = .value
            fields["descendantDefaults"] = .list(savedPosition(legacy: false))
        }
        if authoring { fields["authored"] = authored }
        return .record(fields)
    }
    private static func revision(legacy: Bool, authoring: Bool) -> Shape {
        var fields: [String: Shape] = [
            "definition": .record(["id": id, "version": id, "name": .value, "content": .block, "inTheMenu": .value]),
            "origin": .value, "profile": .value, "presentation": presentation, "contentHash": .value,
        ]
        if !legacy {
            fields["canonicalVersion"] = .value
            fields["descendantDefaults"] = .list(savedPosition(legacy: false))
        }
        if authoring { fields["authored"] = authored }
        return .record(fields)
    }
    private static func archive(legacy: Bool, metadata: Bool, authoring: Bool) -> Shape {
        var fields: [String: Shape] = [
            "format": .value, "schema": .value, "commit": .value, "provenance": .value,
            "revisions": .list(revision(legacy: legacy, authoring: authoring)),

            "uses": .list(.record(useFields(legacy: legacy, authoring: authoring))),
            "assignments": .list(.record(["id": id, "root": id, "app": .value, "isEnabled": .value])),
            "enabled": .value,
        ]
        if authoring {
            fields["workspaces"] = .list(.record(["definition": id, "base": reference, "payload": payload(legacy: false, authoring: true), "info": draftInfo, "positions": .list(savedPosition(legacy: false))]))
        }
        fields[metadata ? "definitions" : "heads"] = metadata
            ? .list(.record(["definition": id, "revision": id, "name": .value, "inTheMenu": .value, "origin": .value]))
            : .list(.record(["definition": id, "revision": id]))
        return .record(fields)
    }
    private static func useFields(legacy: Bool, authoring: Bool) -> [String: Shape] {
        var fields: [String: Shape] = ["target": .value, "use": .record(["id": id, "definition": reference, "name": name]),
            "draft": payload(legacy: legacy, authoring: authoring), "positions": .list(savedPosition(legacy: legacy))]
        if authoring { fields["authoring"] = draftInfo }
        return fields
    }
    static func checkV1(_ decoder: Decoder) throws {
        let position = Shape.record(["control": id, "value": value])
        let assignment = Shape.record(["id": id, "root": id, "app": .value, "isEnabled": .value])
        try Shape.record([
            "version": .value, "isEnabled": .value,
            "definitions": .list(.record(["id": id, "version": id, "name": .value, "content": .block, "inTheMenu": .value])),
            "uses": .list(.record(["id": id, "definition": reference, "name": name])),
            "listening": .list(.record(["root": id, "positions": .list(position)])),
            "assignments": .list(.record(["assignment": assignment, "positions": .list(position)])),
        ]).check(decoder)
    }
    static func check(_ decoder: Decoder, legacy: Bool, metadata: Bool, authoring: Bool) throws {
        let values = try decoder.container(keyedBy: Key.self)
        let schema = try values.decode(Int.self, forKey: Key(stringValue: "schema")!)
        let mapping = schema >= 6
        try archive(legacy: legacy, metadata: metadata, authoring: authoring).check(decoder, limits: decoder.userInfo[.libraryExpansion] as? LibraryExpansionLimits, mappings: mapping, optionIntent: schema >= 7, schema8: schema == 8)
    }
}
