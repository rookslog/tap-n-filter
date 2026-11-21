import Foundation
import EverydayMenu

@main
struct SoundCardRender {
    @MainActor static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let path = arguments.first(where: { !$0.hasPrefix("--") }), arguments.count <= 2 else { throw CocoaError(.fileNoSuchFile) }
        try await MenuCardRenderer.render(to: URL(fileURLWithPath: path, isDirectory: true), classic: arguments.contains("--classic"))
    }
}
