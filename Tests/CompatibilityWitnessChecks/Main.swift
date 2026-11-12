import Foundation

#if !SWIFT_PACKAGE
@main struct Main {
    static func main() throws {
        try CompatibilityWitnessChecks.run(URL(fileURLWithPath: CommandLine.arguments[1]))
    }
}
#endif
