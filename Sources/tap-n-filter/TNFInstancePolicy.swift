import Foundation

/// What the instance check needs to know about one running app.
struct RunningAppFacts: Equatable {
    var pid: Int32
    var bundleID: String?
    var executableName: String?
}

/// One copy at a time: a pure decision, fed from `NSWorkspace.shared.runningApplications` by the App.
enum TNFInstancePolicy {
    static let familyBundleID = "com.loganrooks.tap-n-filter"
    static let familyExecutable = "tap-n-filter"

    static func isFamilyMember(_ app: RunningAppFacts) -> Bool {
        if let id = app.bundleID, id == familyBundleID || id.hasPrefix(familyBundleID + ".") { return true }
        return app.executableName == familyExecutable
    }

    /// True when another family member with a different process ID is running, so this copy quits.
    static func shouldYield(selfPID: Int32, running: [RunningAppFacts]) -> Bool {
        running.contains { $0.pid != selfPID && isFamilyMember($0) }
    }
}
