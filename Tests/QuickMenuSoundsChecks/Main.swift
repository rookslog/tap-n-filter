import Foundation

// Local entry point (this Mac runs these checks without XCTest). SwiftPM excludes this file.
// Usage: <executable> <scratch folder> [group names...]
@main struct QuickMenuSoundsMain {
    static func main() async {
        let arguments = CommandLine.arguments
        guard arguments.count >= 2 else {
            FileHandle.standardError.write(Data("usage: quick-menu-sounds-checks <scratch folder> [groups...]\n".utf8))
            exit(2)
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let only = arguments.count > 2 ? Set(arguments[2...]) : nil
        let report = await QuickMenuSoundsChecks.run(root: root, scratch: URL(fileURLWithPath: arguments[1], isDirectory: true), only: only)
        exit(report.failures.isEmpty ? 0 : 1)
    }
}
