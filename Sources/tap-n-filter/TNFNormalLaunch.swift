import Foundation

/// The normal launch decision: select the library path, prepare the default folder and claim the one-copy
/// lock there, whichever library the flag, the packaged key or the default selected. Pure of audio and of
/// any library file: it creates only the default folder and its lock file.
enum TNFNormalLaunch {
    enum Decision {
        case start(library: URL, lock: TNFInstanceLock)
        case yield
    }

    static func claim(arguments: [String], packagedLibraryValue: Any?, packagedLegacyValue: Any?,
                      supportDirectory: URL) throws -> Decision {
        let library = try LibrarySessionConfiguration.normal(arguments: arguments,
            packagedLibraryValue: packagedLibraryValue, packagedLegacyValue: packagedLegacyValue,
            defaultSupportDirectory: supportDirectory)
        _ = try LibrarySessionConfiguration.prepareDefaultFolder(supportDirectory: supportDirectory)
        guard let lock = TNFInstanceLock.acquire(at: TNFInstanceLock.lockURL(supportDirectory: supportDirectory)) else {
            return .yield
        }
        return .start(library: library, lock: lock)
    }
}
