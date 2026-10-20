import Foundation
import Graph

/// Errors raised by `PresetStore`.
public enum PresetStoreError: Error {
    case fileNotFound(URL)
    case invalidJSON(URL, underlying: Error)
    case unsupportedFormatVersion(Int)
    case writeFailed(URL, underlying: Error)
}

/// A field discarded by V1 decoding. Paths contain only schema locations and
/// occurrence indices, never imported key names or values.
public struct PresetDecodeDiagnostic: Equatable {
    /// Sanitized location, such as `$.nodes[0].unknownFields[0]`.
    public let path: String

    /// Construct a diagnostic with a sanitized schema/occurrence path.
    public init(path: String) {
        self.path = path
    }
}

/// A decoded preset and fidelity diagnostics derived from the same input bytes.
public struct PresetLoadResult {
    /// The existing V1 value representation, without unsupported object fields.
    public let preset: GraphPreset
    /// Fields the V1 representation cannot preserve on a later save.
    public let diagnostics: [PresetDecodeDiagnostic]

    /// Construct a result without changing the on-disk preset schema.
    public init(preset: GraphPreset, diagnostics: [PresetDecodeDiagnostic]) {
        self.preset = preset
        self.diagnostics = diagnostics
    }
}

/// File I/O for `.tnf` presets.
///
/// `PresetStore` is intentionally an enum with only static methods — there is
/// no state to hold. JSON encoding uses pretty-printed, sorted-key output so
/// the on-disk form is hand-editable and diffs cleanly under version control,
/// matching the `.tnf` format's "intentionally human-readable" goal.
public enum PresetStore {

    /// Read and decode a `.tnf` file.
    ///
    /// Throws `PresetStoreError.fileNotFound` if the URL does not resolve,
    /// `PresetStoreError.invalidJSON` if the contents fail to decode, and
    /// `PresetStoreError.unsupportedFormatVersion` if the file targets a
    /// format newer than this build understands. The loader does not throw
    /// on per-node mismatches; those are warnings surfaced by
    /// `Graph.restore`.
    public static func load(from url: URL) throws -> GraphPreset {
        try loadResult(from: url).preset
    }

    /// Read once and inspect exactly the bytes used to decode the preset.
    /// Error mapping is identical to `load(from:)`.
    public static func loadResult(from url: URL) throws -> PresetLoadResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PresetStoreError.fileNotFound(url)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw PresetStoreError.fileNotFound(url)
        }
        return try decodeResult(data, source: url)
    }

    /// Decode preset bytes without touching the filesystem. Useful for
    /// bundled assets read out of `Bundle.module`.
    public static func decode(_ data: Data, source: URL) throws -> GraphPreset {
        try decodeResult(data, source: source).preset
    }

    /// Decode and inspect supplied bytes without opening `source`. Unknown V1
    /// root/node fields are reported using sanitized occurrence paths.
    public static func decodeResult(_ data: Data, source: URL) throws -> PresetLoadResult {
        let decoder = JSONDecoder()
        do {
            let result = try decoder.decode(InspectedPreset.self, from: data).result
            guard result.preset.formatVersion <= 1 else {
                throw PresetStoreError.unsupportedFormatVersion(result.preset.formatVersion)
            }
            return result
        } catch let error as PresetStoreError {
            throw error
        } catch {
            throw PresetStoreError.invalidJSON(source, underlying: error)
        }
    }

    private struct FieldKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    private struct InspectedPreset: Decodable {
        let result: PresetLoadResult

        init(from decoder: Decoder) throws {
            // Decode and inspect through the SAME decoder/bytes. Unknown values
            // stay opaque; only field occurrences enter sanitized diagnostics.
            let preset = try GraphPreset(from: decoder)
            let diagnostics = try PresetStore.decodeDiagnostics(from: decoder)
            result = PresetLoadResult(preset: preset, diagnostics: diagnostics)
        }
    }

    private static func decodeDiagnostics(from decoder: Decoder) throws -> [PresetDecodeDiagnostic] {
        let rootKeys: Set<String> = ["formatVersion", "name", "outputGain", "nodes"]
        let nodeKeys: Set<String> = [
            "typeIdentifier", "id", "displayName", "bypass", "wetDryMix", "parameters", "extras",
        ]
        let root = try decoder.container(keyedBy: FieldKey.self)
        func unknownFields(_ keys: [FieldKey], allowed: Set<String>, path: String)
            -> [PresetDecodeDiagnostic] {
            let count = keys.filter { !allowed.contains($0.stringValue) }.count
            return (0..<count).map { PresetDecodeDiagnostic(path: "\(path).unknownFields[\($0)]") }
        }
        var diagnostics = unknownFields(root.allKeys, allowed: rootKeys, path: "$")
        var nodes = try root.nestedUnkeyedContainer(forKey: FieldKey(stringValue: "nodes"))
        while !nodes.isAtEnd {
            let index = nodes.currentIndex
            let node = try nodes.nestedContainer(keyedBy: FieldKey.self)
            diagnostics += unknownFields(node.allKeys, allowed: nodeKeys, path: "$.nodes[\(index)]")
        }
        return diagnostics
    }

    /// Encode `preset` and write it to `url` atomically.
    public static func save(_ preset: GraphPreset, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(preset)
        } catch {
            throw PresetStoreError.writeFailed(url, underlying: error)
        }
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw PresetStoreError.writeFailed(url, underlying: error)
        }
    }
}
