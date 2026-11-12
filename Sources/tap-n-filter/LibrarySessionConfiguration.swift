import Foundation

/// Value selection only: never reads files, guesses a schema or falls back to current settings.
enum LibrarySessionConfiguration {
    static let trialInfoKey = "TNFLibrarySessionFile"
    enum Mode { case libraryTrial, legacyDiagnostic }
    enum Selection: Equatable { case libraryTrial(URL), legacyDiagnostic(URL) }
    enum SelectionError: Error, Equatable { case missing, malformed, conflicting, legacyOnly }
    static func select(mode: Mode, explicitPath: String? = nil,
                       packagedLibraryValue: Any? = nil, packagedLegacyValue: Any? = nil) throws -> Selection {
        switch mode {
        case .libraryTrial:
            if packagedLegacyValue != nil {
                throw packagedLibraryValue == nil && explicitPath == nil ? SelectionError.legacyOnly : .conflicting
            }
            let explicit = try explicitPath.map { try libraryURL($0) }
            let packaged = try packagedLibraryValue.map { value -> URL in
                guard let path = value as? String else { throw SelectionError.malformed }
                return try libraryURL(path)
            }
            if let explicit, let packaged, explicit != packaged { throw SelectionError.conflicting }
            guard let selected = explicit ?? packaged else { throw SelectionError.missing }
            return .libraryTrial(selected)
        case .legacyDiagnostic:
            guard packagedLibraryValue == nil else { throw SelectionError.conflicting }
            guard let explicitPath else { throw SelectionError.missing }
            return .legacyDiagnostic(URL(fileURLWithPath: explicitPath))
        }
    }
    static func normal(arguments: [String], packagedLibraryValue: Any?, packagedLegacyValue: Any?) throws -> URL {
        guard !arguments.contains("--session-file") else { throw SelectionError.legacyOnly }
        func value(_ flag: String) throws -> String? {
            let indices = arguments.indices.filter { arguments[$0] == flag }
            guard indices.count <= 1 else { throw SelectionError.conflicting }
            guard let index = indices.first else { return nil }
            guard arguments.indices.contains(index + 1), !arguments[index + 1].hasPrefix("--") else { throw SelectionError.malformed }
            return arguments[index + 1]
        }
        // Imports are deliberately not selected by normal launch yet; no schema guessing/file read.
        guard !arguments.contains("--library-import-file") else { throw SelectionError.conflicting }
        let selected = try select(mode: .libraryTrial, explicitPath: value("--library-session-file"),
            packagedLibraryValue: packagedLibraryValue, packagedLegacyValue: packagedLegacyValue)
        guard case .libraryTrial(let url) = selected else { throw SelectionError.conflicting }
        return url
    }
    private static func libraryURL(_ path: String) throws -> URL {
        guard path.hasPrefix("/"), !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw SelectionError.malformed
        }
        let url = URL(fileURLWithPath: path)
        guard url.standardizedFileURL.path == path, url.lastPathComponent == "library-v5.json" else {
            throw SelectionError.malformed
        }
        return url
    }
}
