import Foundation
@testable import tap_n_filter

// DELIVER-01 S1 and S2 acceptance checks (test writer, 2026-11-13). Selection and policy checks are pure
// values. The round-1 folder and lock checks (D1-1, D1-2) work only inside a fresh temporary directory.
// No running-application query, no App launch. Paths never name a user home.

private struct LaunchCheckFailure: Error, CustomStringConvertible {
    let description: String
}
private func launchDemand(_ condition: Bool, _ message: String) throws {
    guard condition else { throw LaunchCheckFailure(description: message) }
    print("PASS \(message)")
}
private typealias SelectionError = LibrarySessionConfiguration.SelectionError

enum LaunchChecks {
    static let support = URL(fileURLWithPath: "/Volumes/Example/Library/Application Support", isDirectory: true)
    static let defaultPath = "/Volumes/Example/Library/Application Support/tap-n-filter/library-v5.json"
    static let explicitPath = "/Volumes/Example/Explicit/library-v5.json"
    static let packagedPath = "/Volumes/Example/Packaged/library-v5.json"
    static let bundleFolder = "com.loganrooks.tap-n-filter"

    static func run() throws {
        try defaultDataPath()
        try precedenceUnchanged()
        try refusalsUnchanged()
        try instancePolicy()
        try defaultFolderGuard()
        try instanceLock()
        try hardLinkedLibraryRefused()
        try nonRegularLibraryRefused()
        try hardLinkedLockRefused()
        try nonRegularLockRefused()
        try launchClaimForEverySelection()
        try bootClaimsBeforeLibraryWork()
        print("PASS launch data path, protected-folder guard, one-copy policy and lock; no App/workspace path")
    }

    // MARK: S1

    private static func select(_ arguments: [String], library: Any? = nil, legacy: Any? = nil,
                               support: URL? = LaunchChecks.support) throws -> URL {
        try LibrarySessionConfiguration.normal(arguments: arguments, packagedLibraryValue: library,
                                               packagedLegacyValue: legacy, defaultSupportDirectory: support)
    }

    private static func refusal(_ arguments: [String], library: Any? = nil, legacy: Any? = nil,
                                support: URL? = LaunchChecks.support) -> SelectionError? {
        do {
            let url = try select(arguments, library: library, legacy: legacy, support: support)
            print("selected unexpectedly: \(url.path)")
            return nil
        } catch let error as SelectionError {
            return error
        } catch {
            print("unexpected error type: \(error)")
            return nil
        }
    }

    private static func avoidsBundleFolder(_ url: URL) -> Bool {
        !url.pathComponents.contains { $0 == bundleFolder || $0.hasPrefix(bundleFolder + ".") }
    }

    static func defaultDataPath() throws {
        let existedBefore = FileManager.default.fileExists(atPath: "/Volumes/Example")
        let plain = try select(["tap-n-filter"])
        try launchDemand(plain.isFileURL && plain.path == defaultPath,
                         "S1 no flag and no packaged key selects <Application Support>/tap-n-filter/library-v5.json")
        try launchDemand(plain.standardizedFileURL.path == defaultPath && plain.lastPathComponent == "library-v5.json"
                         && plain.deletingLastPathComponent().lastPathComponent == "tap-n-filter",
                         "S1 default is the same library-v5.json name in a tap-n-filter folder")
        try launchDemand(avoidsBundleFolder(plain), "S1 default never uses the com.loganrooks.tap-n-filter folder")

        // A Finder/LaunchServices launch can carry process-serial and AppKit defaults arguments.
        let finder = try select(["/Applications/tap-n-filter.app/Contents/MacOS/tap-n-filter", "-psn_0_12345",
                                 "-NSDocumentRevisionsDebugMode", "YES"])
        try launchDemand(finder.path == defaultPath && avoidsBundleFolder(finder),
                         "S1 Finder-style launch arguments still select the default path")

        let other = URL(fileURLWithPath: "/Volumes/Second Disk/Library/Application Support", isDirectory: true)
        let moved = try select(["tap-n-filter"], support: other)
        try launchDemand(moved.path == "/Volumes/Second Disk/Library/Application Support/tap-n-filter/library-v5.json"
                         && avoidsBundleFolder(moved),
                         "S1 default follows the supplied Application Support directory")

        try launchDemand(refusal(["tap-n-filter"], support: nil) == .missing,
                         "S1 nil default directory keeps today's .missing refusal")

        if !existedBefore {
            try launchDemand(!FileManager.default.fileExists(atPath: "/Volumes/Example"),
                             "S1 selection creates nothing on disk")
        }
    }

    static func precedenceUnchanged() throws {
        let explicit = try select(["tap-n-filter", "--library-session-file", explicitPath])
        try launchDemand(explicit.path == explicitPath, "S1 explicit --library-session-file wins over the default")

        let packaged = try select(["tap-n-filter"], library: packagedPath)
        try launchDemand(packaged.path == packagedPath, "S1 packaged TNFLibrarySessionFile wins over the default")

        let both = try select(["tap-n-filter", "--library-session-file", packagedPath], library: packagedPath)
        try launchDemand(both.path == packagedPath, "S1 equal explicit and packaged paths still select that path")

        let withoutDefault = try select(["tap-n-filter", "--library-session-file", explicitPath], support: nil)
        try launchDemand(withoutDefault.path == explicitPath, "S1 explicit selection is unchanged without a default directory")
    }

    static func refusalsUnchanged() throws {
        try launchDemand(refusal(["tap-n-filter", "--library-session-file", explicitPath], library: packagedPath) == .conflicting,
                         "S1 differing explicit and packaged paths still conflict, not the default")
        try launchDemand(refusal(["tap-n-filter", "--session-file", explicitPath]) == .legacyOnly,
                         "S1 legacy --session-file is still refused")
        try launchDemand(refusal(["tap-n-filter", "--session-file"]) == .legacyOnly,
                         "S1 bare legacy --session-file is still refused")
        try launchDemand(refusal(["tap-n-filter"], legacy: "/Volumes/Example/Legacy/session.json") == .legacyOnly,
                         "S1 packaged legacy key alone is still refused, not replaced by the default")
        try launchDemand(refusal(["tap-n-filter", "--library-session-file", explicitPath],
                                 legacy: "/Volumes/Example/Legacy/session.json") == .conflicting,
                         "S1 packaged legacy key beside an explicit path still conflicts")
        try launchDemand(refusal(["tap-n-filter", "--library-import-file", "/Volumes/Example/Import/library-v5.json"]) == .conflicting,
                         "S1 --library-import-file is still refused at normal launch")
        try launchDemand(refusal(["tap-n-filter", "--library-session-file", "relative/library-v5.json"]) == .malformed,
                         "S1 malformed explicit path is refused, never replaced by the default")
        try launchDemand(refusal(["tap-n-filter", "--library-session-file", "/Volumes/Example/Explicit/other.json"]) == .malformed,
                         "S1 explicit path with another file name is refused, never replaced by the default")
        try launchDemand(refusal(["tap-n-filter", "--library-session-file"]) == .malformed,
                         "S1 flag without a value is refused, never replaced by the default")
        try launchDemand(refusal(["tap-n-filter", "--library-session-file", explicitPath,
                                  "--library-session-file", explicitPath]) == .conflicting,
                         "S1 repeated flag still conflicts")
        try launchDemand(refusal(["tap-n-filter"], library: 42) == .malformed,
                         "S1 non-string packaged key is refused, never replaced by the default")
    }

    // MARK: S2

    private static func app(_ pid: Int32, _ bundleID: String?, _ executable: String?) -> RunningAppFacts {
        RunningAppFacts(pid: pid, bundleID: bundleID, executableName: executable)
    }

    static func instancePolicy() throws {
        let me: Int32 = 4100
        let selfFacts = app(me, "com.loganrooks.tap-n-filter", "tap-n-filter")
        let safari = app(310, "com.apple.Safari", "Safari")
        func yields(_ running: [RunningAppFacts]) -> Bool { TNFInstancePolicy.shouldYield(selfPID: me, running: running) }

        try launchDemand(!yields([selfFacts]), "S2 only this copy running: stay")
        try launchDemand(!yields([]), "S2 empty running list: stay")
        try launchDemand(yields([selfFacts, app(4200, "com.loganrooks.tap-n-filter", "tap-n-filter")]),
                         "S2 same bundle ID with another pid: yield")
        try launchDemand(yields([selfFacts, app(4200, "com.loganrooks.tap-n-filter", "unusual")]),
                         "S2 exact family bundle ID alone is enough: yield")
        try launchDemand(yields([selfFacts, app(4201, "com.loganrooks.tap-n-filter.operator-try", "unusual")]),
                         "S2 com.loganrooks.tap-n-filter. prefix: yield")
        try launchDemand(yields([selfFacts, app(4202, "com.loganrooks.tap-n-filter.silent-perf.r1", "tap-n-filter")]),
                         "S2 perf-only silent-perf bundle is a family member: yield")
        try launchDemand(yields([selfFacts, app(4203, "local.private.pin", "tap-n-filter")]),
                         "S2 executable named tap-n-filter under another bundle ID: yield")
        try launchDemand(yields([selfFacts, app(4204, nil, "tap-n-filter")]),
                         "S2 executable named tap-n-filter without a bundle ID: yield")
        try launchDemand(!yields([selfFacts, safari, app(311, "com.apple.finder", "Finder")]),
                         "S2 unrelated apps: stay")
        try launchDemand(!yields([selfFacts, app(312, "com.loganrooks.tap-n-filterx", "other")]),
                         "S2 bundle ID sharing letters but not the dot prefix: stay")
        try launchDemand(!yields([selfFacts, app(313, nil, nil)]), "S2 app with no bundle ID or executable: stay")
        try launchDemand(!yields([app(me, "com.loganrooks.tap-n-filter.silent-perf.r1", "tap-n-filter"), safari]),
                         "S2 a family entry with this copy's own pid: stay")

        let perf: Int32 = 5100
        try launchDemand(TNFInstancePolicy.shouldYield(selfPID: perf,
                                                       running: [app(perf, "com.loganrooks.tap-n-filter.silent-perf.r1", "tap-n-filter"), selfFacts]),
                         "S2 perf-only copy yields to a running app copy")
    }

    // MARK: D1-1 default folder never reaches the protected bundle-ID folder

    private static let fm = FileManager.default

    /// A fresh temporary tree: <root>/Application Support with the protected folder holding a sentinel library.
    private struct Tree {
        let root: URL
        let support: URL
        let protected: URL
        let folder: URL
        static let sentinel = Data("SYNTHETIC protected working data, not a real library".utf8)
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("tnf-launch-checks-" + UUID().uuidString, isDirectory: true)
            support = root.appendingPathComponent("Application Support", isDirectory: true)
            protected = support.appendingPathComponent("com.loganrooks.tap-n-filter", isDirectory: true)
            folder = support.appendingPathComponent("tap-n-filter", isDirectory: true)
            try FileManager.default.createDirectory(at: protected, withIntermediateDirectories: true)
            try Tree.sentinel.write(to: protected.appendingPathComponent("library-v5.json"))
        }
        func protectedUntouched() -> Bool {
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: protected.path)) ?? []
            return entries == ["library-v5.json"]
                && FileManager.default.contents(atPath: protected.appendingPathComponent("library-v5.json").path) == Tree.sentinel
        }
        func isSymlink(_ url: URL) -> Bool {
            (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
        }
        func mode(_ url: URL) -> Int {
            ((try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber)?.intValue ?? -1
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private static func folderRefusal(_ tree: Tree) -> SelectionError? {
        do {
            let url = try LibrarySessionConfiguration.prepareDefaultFolder(supportDirectory: tree.support)
            print("prepared unexpectedly: \(url.lastPathComponent)")
            return nil
        } catch let error as SelectionError {
            return error
        } catch {
            print("unexpected error type: \(error)")
            return nil
        }
    }

    /// The refusal reuses an existing startup refusal word; no new on-screen words.
    private static func existingRefusal(_ error: SelectionError?) -> Bool {
        error == .missing || error == .malformed
    }

    static func defaultFolderGuard() throws {
        do {
            let tree = try Tree(); defer { tree.remove() }
            let prepared = try LibrarySessionConfiguration.prepareDefaultFolder(supportDirectory: tree.support)
            try launchDemand(prepared.standardizedFileURL.path == tree.folder.standardizedFileURL.path,
                             "D1-1 prepare returns <support>/tap-n-filter")
            try launchDemand(fm.fileExists(atPath: tree.folder.path) && !tree.isSymlink(tree.folder) && tree.mode(tree.folder) == 0o700,
                             "D1-1 missing default folder is created as a real directory with mode 0700")
            try launchDemand((try fm.contentsOfDirectory(atPath: tree.folder.path)).isEmpty,
                             "D1-1 preparing creates nothing inside the folder")
            try launchDemand(tree.protectedUntouched(), "D1-1 creating the default folder leaves the protected folder untouched")
        }
        do {
            let tree = try Tree(); defer { tree.remove() }
            try fm.createDirectory(at: tree.folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tree.folder.path)
            _ = try LibrarySessionConfiguration.prepareDefaultFolder(supportDirectory: tree.support)
            try launchDemand(tree.mode(tree.folder) == 0o755, "D1-1 an existing real default folder is accepted and not chmodded")
        }
        do {
            let tree = try Tree(); defer { tree.remove() }
            try fm.createSymbolicLink(at: tree.folder, withDestinationURL: tree.protected)
            try launchDemand(existingRefusal(folderRefusal(tree)),
                             "D1-1 default folder that is a symlink to the protected folder is refused")
            try launchDemand(tree.isSymlink(tree.folder) && tree.protectedUntouched(),
                             "D1-1 refusal leaves the link and the protected folder untouched")
        }
        do {
            let tree = try Tree(); defer { tree.remove() }
            try fm.createSymbolicLink(atPath: tree.folder.path, withDestinationPath: "com.loganrooks.tap-n-filter")
            try launchDemand(existingRefusal(folderRefusal(tree)) && tree.protectedUntouched(),
                             "D1-1 relative symlink into the protected folder is refused, protected folder untouched")
        }
        do {
            let tree = try Tree(); defer { tree.remove() }
            let elsewhere = tree.root.appendingPathComponent("elsewhere", isDirectory: true)
            try fm.createDirectory(at: elsewhere, withIntermediateDirectories: false)
            try fm.createSymbolicLink(at: tree.folder, withDestinationURL: elsewhere)
            try launchDemand(existingRefusal(folderRefusal(tree)) && (try fm.contentsOfDirectory(atPath: elsewhere.path)).isEmpty,
                             "D1-1 default folder that is any symlink is refused and its target is not written")
        }
        do {
            let tree = try Tree(); defer { tree.remove() }
            let dangling = tree.root.appendingPathComponent("not-yet", isDirectory: true)
            try fm.createSymbolicLink(at: tree.folder, withDestinationURL: dangling)
            try launchDemand(existingRefusal(folderRefusal(tree)) && !fm.fileExists(atPath: dangling.path),
                             "D1-1 dangling symlink is refused and its target is not created")
        }
        do {
            let tree = try Tree(); defer { tree.remove() }
            try fm.createDirectory(at: tree.folder, withIntermediateDirectories: false)
            try fm.createSymbolicLink(at: tree.folder.appendingPathComponent("library-v5.json"),
                                      withDestinationURL: tree.protected.appendingPathComponent("library-v5.json"))
            try launchDemand(existingRefusal(folderRefusal(tree)) && tree.protectedUntouched(),
                             "D1-1 library-v5.json that is a symlink into the protected folder is refused")
        }
        do {
            let tree = try Tree(); defer { tree.remove() }
            try Data("SYNTHETIC not a folder".utf8).write(to: tree.folder)
            try launchDemand(existingRefusal(folderRefusal(tree)), "D1-1 default folder path that is a regular file is refused")
        }
        do {
            // Over-correction guard: an Application Support folder that is itself a link (relocated home data) still works.
            let tree = try Tree(); defer { tree.remove() }
            let relocated = tree.root.appendingPathComponent("Relocated Support", isDirectory: true)
            try fm.createDirectory(at: relocated, withIntermediateDirectories: false)
            let linkedSupport = tree.root.appendingPathComponent("Linked Support", isDirectory: true)
            try fm.createSymbolicLink(at: linkedSupport, withDestinationURL: relocated)
            _ = try LibrarySessionConfiguration.prepareDefaultFolder(supportDirectory: linkedSupport)
            var isDirectory: ObjCBool = false
            try launchDemand(fm.fileExists(atPath: relocated.appendingPathComponent("tap-n-filter").path, isDirectory: &isDirectory) && isDirectory.boolValue,
                             "D1-1 a linked Application Support folder is still accepted; only the tap-n-filter entries are guarded")
        }
    }

    // MARK: D1-2 atomic one-copy claim

    private static func otherProcessCanLock(_ url: URL) throws -> Bool {
        // lockf(1) takes the same flock(2)-family lock as a separate process; -k keeps the file, -t 0 never waits.
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
        child.arguments = ["-k", "-t", "0", url.path, "/usr/bin/true"]
        child.standardError = FileHandle.nullDevice
        try child.run()
        child.waitUntilExit()
        return child.terminationStatus == 0
    }

    static func instanceLock() throws {
        let tree = try Tree(); defer { tree.remove() }
        try launchDemand(TNFInstanceLock.lockURL(supportDirectory: tree.support).standardizedFileURL.path
                         == tree.folder.appendingPathComponent(".instance.lock").standardizedFileURL.path,
                         "D1-2 every copy claims <support>/tap-n-filter/.instance.lock")
        try fm.createDirectory(at: tree.folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let path = TNFInstanceLock.lockURL(supportDirectory: tree.support)

        let first = TNFInstanceLock.acquire(at: path)
        let second = TNFInstanceLock.acquire(at: path)
        try launchDemand(first != nil && second == nil, "D1-2 two claimants in one process: exactly one wins")
        try launchDemand(tree.mode(path) & 0o077 == 0, "D1-2 lock file is private to the user")
        try launchDemand(!(try otherProcessCanLock(path)), "D1-2 another process cannot take the held lock")
        first?.release()
        try launchDemand(try otherProcessCanLock(path), "D1-2 release frees the lock for another process")
        let third = TNFInstanceLock.acquire(at: path)
        try launchDemand(third != nil, "D1-2 after release a new claimant wins")
        third?.release()

        func holdBriefly() -> Bool { TNFInstanceLock.acquire(at: path) != nil }
        try launchDemand(holdBriefly() && holdBriefly(), "D1-2 a dropped claimant releases its lock")
        try launchDemand(tree.protectedUntouched(), "D1-2 claiming touches nothing in the protected folder")

        let linked = tree.folder.appendingPathComponent(".linked.lock")
        let target = tree.protected.appendingPathComponent("planted.lock")
        try fm.createSymbolicLink(at: linked, withDestinationURL: target)
        let viaLink = TNFInstanceLock.acquire(at: linked)
        try launchDemand(viaLink == nil && !fm.fileExists(atPath: target.path) && tree.protectedUntouched(),
                         "D1-2 a lock path that is a symlink is not followed; claim fails and nothing is created")
        viaLink?.release()
    }

    // MARK: R2-2 hard links and non-regular files

    private static func linkCount(_ url: URL) -> Int {
        var info = stat()
        return lstat(url.path, &info) == 0 ? Int(info.st_nlink) : -1
    }

    static func hardLinkedLibraryRefused() throws {
        do {
            let tree = try Tree(); defer { tree.remove() }
            try fm.createDirectory(at: tree.folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let library = tree.folder.appendingPathComponent("library-v5.json")
            try fm.linkItem(at: tree.protected.appendingPathComponent("library-v5.json"), to: library)
            try launchDemand(linkCount(library) == 2, "R2-2 fixture: default library-v5.json is a hard link (link count 2)")
            try launchDemand(existingRefusal(folderRefusal(tree)) && tree.protectedUntouched(),
                             "R2-2 default library-v5.json with link count 2 is refused")
        }
    }

    static func nonRegularLibraryRefused() throws {
        do {
            let tree = try Tree(); defer { tree.remove() }
            try fm.createDirectory(at: tree.folder.appendingPathComponent("library-v5.json"), withIntermediateDirectories: true)
            try launchDemand(existingRefusal(folderRefusal(tree)), "R2-2 default library-v5.json that is a directory is refused")
        }
        do {
            let tree = try Tree(); defer { tree.remove() }
            try fm.createDirectory(at: tree.folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try Data("SYNTHETIC own library".utf8).write(to: tree.folder.appendingPathComponent("library-v5.json"))
            _ = try LibrarySessionConfiguration.prepareDefaultFolder(supportDirectory: tree.support)
            try launchDemand(true, "R2-2 an ordinary default library-v5.json (link count 1) is still accepted")
        }
    }

    static func hardLinkedLockRefused() throws {
        do {
            let tree = try Tree(); defer { tree.remove() }
            try fm.createDirectory(at: tree.folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let protectedFile = tree.protected.appendingPathComponent("library-v5.json")
            try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: protectedFile.path)
            let lock = TNFInstanceLock.lockURL(supportDirectory: tree.support)
            try fm.linkItem(at: protectedFile, to: lock)
            let claim = TNFInstanceLock.acquire(at: lock)
            try launchDemand(claim == nil, "R2-2 .instance.lock with link count 2 is refused")
            try launchDemand(tree.mode(protectedFile) == 0o644 && tree.protectedUntouched(),
                             "R2-2 refusing a hard-linked lock leaves the linked file's mode and bytes unchanged")
            claim?.release()
        }
    }

    static func nonRegularLockRefused() throws {
        do {
            let tree = try Tree(); defer { tree.remove() }
            try fm.createDirectory(at: tree.folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let lock = TNFInstanceLock.lockURL(supportDirectory: tree.support)
            try launchDemand(mkfifo(lock.path, 0o600) == 0, "R2-2 fixture: .instance.lock is a FIFO")
            let claim = TNFInstanceLock.acquire(at: lock)
            try launchDemand(claim == nil, "R2-2 .instance.lock that is not a regular file is refused")
            claim?.release()
            try fm.removeItem(at: lock)
            try fm.createDirectory(at: lock, withIntermediateDirectories: false)
            let onFolder = TNFInstanceLock.acquire(at: lock)
            try launchDemand(onFolder == nil, "R2-2 .instance.lock that is a directory is refused")
            onFolder?.release()
        }
        do {
            let tree = try Tree(); defer { tree.remove() }
            try fm.createDirectory(at: tree.folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let lock = TNFInstanceLock.lockURL(supportDirectory: tree.support)
            try Data().write(to: lock)
            let claim = TNFInstanceLock.acquire(at: lock)
            try launchDemand(claim != nil, "R2-2 an existing ordinary .instance.lock (link count 1) is still claimed")
            claim?.release()
        }
    }

    // MARK: R2-1 every normal launch claims the lock, whatever library it selects

    private static func claim(_ arguments: [String], library: Any? = nil, support: URL) throws -> TNFNormalLaunch.Decision {
        try TNFNormalLaunch.claim(arguments: arguments, packagedLibraryValue: library, packagedLegacyValue: nil,
                                  supportDirectory: support)
    }

    static func launchClaimForEverySelection() throws {
        let tree = try Tree(); defer { tree.remove() }
        let explicitLibrary = tree.root.appendingPathComponent("Explicit", isDirectory: true).appendingPathComponent("library-v5.json")
        let packagedLibrary = tree.root.appendingPathComponent("Packaged", isDirectory: true).appendingPathComponent("library-v5.json")
        let lockPath = TNFInstanceLock.lockURL(supportDirectory: tree.support)
        let cases: [(String, [String], Any?, URL)] = [
            ("default", ["tap-n-filter"], nil, tree.folder.appendingPathComponent("library-v5.json")),
            ("explicit", ["tap-n-filter", "--library-session-file", explicitLibrary.path], nil, explicitLibrary),
            ("packaged", ["tap-n-filter"], packagedLibrary.path, packagedLibrary),
        ]
        for (name, arguments, packaged, expected) in cases {
            let decision = try claim(arguments, library: packaged, support: tree.support)
            guard case .start(let library, let held) = decision else {
                throw LaunchCheckFailure(description: "R2-1 \(name) selection did not start with a claim")
            }
            try launchDemand(library.standardizedFileURL.path == expected.standardizedFileURL.path,
                             "R2-1 \(name) selection keeps its own library path")
            try launchDemand(!(try otherProcessCanLock(lockPath)),
                             "R2-1 \(name) selection holds <support>/tap-n-filter/.instance.lock")
            try launchDemand(tree.mode(tree.folder) == 0o700, "R2-1 \(name) selection prepares the default folder")
            held.release()
            try launchDemand(try otherProcessCanLock(lockPath), "R2-1 \(name) claim releases with its lock")
        }
        try launchDemand(!fm.fileExists(atPath: explicitLibrary.deletingLastPathComponent().path)
                         && !fm.fileExists(atPath: packagedLibrary.deletingLastPathComponent().path),
                         "R2-1 claiming touches no selected library path")

        let incumbent = TNFInstanceLock.acquire(at: lockPath)
        try launchDemand(incumbent != nil, "R2-1 fixture: another copy holds the lock")
        for (name, arguments, packaged, _) in cases {
            let decision = try claim(arguments, library: packaged, support: tree.support)
            guard case .yield = decision else {
                throw LaunchCheckFailure(description: "R2-1 \(name) selection started while another copy held the lock")
            }
            try launchDemand(true, "R2-1 \(name) selection yields to a held lock")
        }
        incumbent?.release()
        try launchDemand(tree.protectedUntouched(), "R2-1 claims touch nothing in the protected folder")

        let linked = try Tree(); defer { linked.remove() }
        try fm.createSymbolicLink(at: linked.folder, withDestinationURL: linked.protected)
        var refused = false
        do { _ = try claim(["tap-n-filter", "--library-session-file", explicitLibrary.path], support: linked.support) }
        catch is SelectionError { refused = true }
        try launchDemand(refused && linked.protectedUntouched(),
                         "R2-1 an explicit selection still refuses a symlinked default folder; no lock is planted")
    }

    /// Source-order check, not a runtime check: the App's normal branch of boot() goes through the
    /// claim before any library session exists, and has no path around it.
    static func bootClaimsBeforeLibraryWork() throws {
        let root = ProcessInfo.processInfo.environment["TNF_SOURCE_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let appURL = root.appendingPathComponent("Sources/tap-n-filter/App.swift")
        guard let source = try? String(contentsOf: appURL, encoding: .utf8) else {
            throw LaunchCheckFailure(description: "R2-1 App.swift not found for the source-order check")
        }
        guard let start = source.range(of: "func boot()") else {
            throw LaunchCheckFailure(description: "R2-1 boot() not found in App.swift")
        }
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n  private func ")?.lowerBound ?? rest.endIndex
        let boot = String(rest[..<end])
        guard let claimAt = boot.range(of: "TNFNormalLaunch.claim("),
              let sessionAt = boot.range(of: "LibraryAppSession(") else {
            throw LaunchCheckFailure(description: "R2-1 boot() does not call TNFNormalLaunch.claim before creating a LibraryAppSession")
        }
        try launchDemand(claimAt.lowerBound < sessionAt.lowerBound,
                         "R2-1 boot() claims before creating the library session")
        try launchDemand(!boot.contains("LibrarySessionConfiguration.normal(") && !boot.contains("TNFInstanceLock.acquire("),
                         "R2-1 boot() has no selection or lock path around the claim")
    }
}
