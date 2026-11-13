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
    /// Folder name under the user's Application Support directory. Never the bundle-ID folder: the
    /// working app keeps its data there and nothing in this module may read, write or create in it.
    static let defaultFolderName = "tap-n-filter"
    static let libraryFileName = "library-v5.json"
    /// Returns `<support>/tap-n-filter`, creating it (mode 0700) when missing. An existing real directory is
    /// accepted and not chmodded. A symlink, a non-directory, or a `library-v5.json` that is not a regular file with link count 1 is
    /// refused with an existing selection error, never followed and never written through, so the default
    /// folder can never reach the protected bundle-ID folder. `supportDirectory` itself may be a link.
    static func prepareDefaultFolder(supportDirectory: URL) throws -> URL {
        let folder = supportDirectory.appendingPathComponent(defaultFolderName, isDirectory: true)
        func kind(_ url: URL) -> mode_t? {
            var info = stat()
            return lstat(url.path, &info) == 0 ? info.st_mode & S_IFMT : nil
        }
        if let existing = kind(folder) {
            guard existing == S_IFDIR else { throw SelectionError.malformed }
        } else {
            try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700])
            } catch {
                guard kind(folder) == S_IFDIR else { throw SelectionError.malformed }
            }
            guard kind(folder) == S_IFDIR else { throw SelectionError.malformed }
        }
        // An existing default library must be a plain file with no other name: a symlink or a hard link
        // could lead into another app's data.
        var info = stat()
        if lstat(folder.appendingPathComponent(libraryFileName).path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw SelectionError.malformed }
        }
        return folder
    }
    static func defaultLibraryURL(supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent(defaultFolderName, isDirectory: true)
            .appendingPathComponent(libraryFileName, isDirectory: false)
    }
    /// `defaultSupportDirectory` is the user's Application Support directory; `nil` keeps `.missing`
    /// when neither an explicit flag nor a packaged key selects a path.
    static func normal(arguments: [String], packagedLibraryValue: Any?, packagedLegacyValue: Any?,
                       defaultSupportDirectory: URL? = nil) throws -> URL {
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
        let selected: Selection
        do {
            selected = try select(mode: .libraryTrial, explicitPath: value("--library-session-file"),
                packagedLibraryValue: packagedLibraryValue, packagedLegacyValue: packagedLegacyValue)
        } catch SelectionError.missing {
            guard let defaultSupportDirectory else { throw SelectionError.missing }
            return defaultLibraryURL(supportDirectory: defaultSupportDirectory)
        }
        guard case .libraryTrial(let url) = selected else { throw SelectionError.conflicting }
        return url
    }
    private static func libraryURL(_ path: String) throws -> URL {
        guard path.hasPrefix("/"), !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw SelectionError.malformed
        }
        let url = URL(fileURLWithPath: path)
        guard url.standardizedFileURL.path == path, url.lastPathComponent == libraryFileName else {
            throw SelectionError.malformed
        }
        return url
    }
}
