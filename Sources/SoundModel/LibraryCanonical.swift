import Foundation
import CryptoKit

// Versioned authored stream: every collection/string is length-prefixed; ordering is semantic.
struct AuthoredStream {
    var data = Data()
    mutating func integer(_ value: UInt64) {
        var value = value.bigEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
    mutating func count(_ value: Int) { integer(UInt64(value)) }
    mutating func text(_ value: String) {
        let bytes = Data(value.precomposedStringWithCanonicalMapping.utf8)
        count(bytes.count); data.append(bytes)
    }
    mutating func number(_ value: Double) { integer(value == 0 ? 0 : value.bitPattern) }
    mutating func id(_ value: UUID) {
        var bytes = value.uuid
        withUnsafeBytes(of: &bytes) { data.append(contentsOf: $0) }
    }
    mutating func position(_ value: ControlValue) {
        switch value {
        case .scalar(let p): text("scalar"); number(p.value)
        case .xy(let x, let y): text("xy"); number(x.value); number(y.value)
        }
    }
    mutating func block(_ block: SoundBlock, optionControls: Bool = false) throws {
        count(block.pieces.count)
        for piece in block.pieces {
            switch piece {
            case .part(let part):
                text("part"); id(part.id.rawValue); text(part.type); count(part.settings.count)
                for setting in part.settings { text(setting.key.rawValue); number(setting.position.value) }
            case .block(let use):
                text("inline"); id(use.site.rawValue)
                if let payload = use.payload {
                    text("local-payload"); let data = try payload.canonicalData; count(data.count); self.data.append(data)
                    if let original = use.original { id(original.id.rawValue); id(original.version.rawValue) }
                } else { try self.block(use.content, optionControls: optionControls) }
            case .reference(let use):
                text("reference"); id(use.site.rawValue)
                id(use.definition.id.rawValue); id(use.definition.version.rawValue)
            }
        }
        count(block.controls.count)
        for control in block.controls {
            id(control.id.rawValue)
            switch control.face {
            case .slider: text("slider")
            case .xy: text("xy")
            case .choice(let choice):
                text("choice"); count(choice.options.count)
                for option in choice.options { id(option.rawValue) }
            }
            position(control.position)
            switch control.waypoints {
            case .scalar(let points):
                text("scalar"); count(points.count); for p in points { number(p.value) }
            case .xy(let x, let y):
                text("xy"); count(x.count); for p in x { number(p.value) }
                count(y.count); for p in y { number(p.value) }
            }
        }
        if optionControls {
            count(block.optionControls.count)
            for relation in block.optionControls.sorted(by: { $0.order < $1.order }) {
                text("choiceOption"); id(relation.parentChoice.rawValue); id(relation.option.rawValue); id(relation.child.rawValue)
            }
        }
        if let bindings = block.bindings {
            text("bindings"); count(block.selections.count)
            for selection in block.selections.sorted(by: { $0.source.rawValue.uuidString < $1.source.rawValue.uuidString }) { id(selection.source.rawValue); id(selection.selector.rawValue) }
            count(bindings.count)
            for binding in bindings.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                let bytes = try encoder.encode(binding); count(bytes.count); data.append(bytes)
            }
            return
        }
        count(block.mappings.count)
        for mapping in block.mappings {
            id(mapping.control.rawValue); text(mapping.axis.rawValue)
            id(mapping.part.rawValue); text(mapping.parameter.rawValue)
            mapping.curve.appendCanonical(to: &self)
        }
    }
    mutating func presentation(_ controls: [LibraryControl]) {
        count(controls.count)
        for control in controls {
            id(control.id); text(control.title)
            text(control.placement == .primary ? "primary" : "more")
            switch control.face {
            case .slider(let a, let b): text("slider"); text(a); text(b)
            case .xy: text("xy")
            case .choice(let options):
                text("choice"); count(options.count)
                for option in options { id(option.id); text(option.title); number(option.position) }
            }
            switch control.readout {
            case .none: text("none")
            case .frequency(let a, let b): text("frequency"); number(a); number(b)
            case .wetPercent(let maximum): text("wet"); number(maximum)
            case .decibels(let a, let b): text("dB"); number(a); number(b)
            case .positionPercent: text("percent")
            }
        }
    }
}

func libraryDigest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

extension LibraryPayload {
    func validateCanonical() throws {
        guard (1...5).contains(canonicalVersion) else { throw LibraryError.unknownCanonicalVersion(canonicalVersion) }
        guard canonicalVersion >= 5 || !block.needsVersion5 else { throw LibraryError.invalidCanonical }
        try block.validateOptionControls()
        guard canonicalVersion >= 4 || !block.needsVersion4 else { throw LibraryError.invalidCanonical }
        guard canonicalVersion < 4 || block.bindings != nil else { throw LibraryError.invalidCanonical }
        try authored.validate(in: block)
        guard canonicalVersion >= 3 || authored == .empty else { throw LibraryError.invalidCanonical }
        guard canonicalVersion != 1 || descendantDefaults.isEmpty,
              descendantDefaults.allSatisfy({ !$0.path.isEmpty }),
              Set(descendantDefaults.map(\.key)).count == descendantDefaults.count else { throw LibraryError.invalidCanonical }
    }
    var canonicalData: Data {
        get throws {
            try validateCanonical()
            var stream = AuthoredStream()
            stream.text("TNF-authored-content"); stream.integer(UInt64(canonicalVersion))
            stream.text(profile); try stream.block(block, optionControls: canonicalVersion >= 5); stream.presentation(presentation)
            if canonicalVersion >= 2 {
                stream.count(descendantDefaults.count)
                for value in descendantDefaults.sorted(by: { $0.key.orderBytes.lexicographicallyPrecedes($1.key.orderBytes) }) {
                    stream.count(value.path.count); for site in value.path { stream.id(site.rawValue) }
                    stream.id(value.id.rawValue); stream.position(value.value)
                }
            }
            if canonicalVersion >= 3 {
                stream.count(authored.bypassed.count)
                for id in authored.bypassed.sorted(by: { $0.rawValue.uuidString < $1.rawValue.uuidString }) { stream.id(id.rawValue) }
                stream.count(authored.adjustments.count)
                for item in authored.adjustments.sorted(by: { $0.address.order < $1.address.order }) {
                    stream.id(item.address.part.rawValue); stream.text(item.address.parameter.rawValue); stream.number(item.value)
                }
            }
            return stream.data
        }
    }
    var contentHash: String { get throws { libraryDigest(try canonicalData) } }
}
