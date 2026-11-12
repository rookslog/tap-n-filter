import AppKit
import Capture
import Foundation
import PlaybackRuntime

@MainActor
public final class SystemProcessCatalog: ProcessCatalog {
    static let safariBundle = "com.apple.Safari"
    static let safariHelperName = "Safari Graphics and Media"

    struct ApplicationIdentity {
        let bundleIdentifier: String?
        let localizedName: String?
        let instanceIdentifier: String?
        let isTerminated: Bool
    }

    private let coreAudio: any CoreAudioInterface
    private let application: (Int32) -> ApplicationIdentity?

    public init(coreAudio: any CoreAudioInterface) {
        self.coreAudio = coreAudio
        application = Self.applicationIdentity
    }

    // Metadata seam only: fake checks still execute this catalog and the real resolver.
    init(coreAudio: any CoreAudioInterface, application: @escaping (Int32) -> ApplicationIdentity?)
    {
        self.coreAudio = coreAudio
        self.application = application
    }

    private static func applicationIdentity(_ pid: Int32) -> ApplicationIdentity? {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        return ApplicationIdentity(
            bundleIdentifier: app.bundleIdentifier, localizedName: app.localizedName,
            instanceIdentifier: app.launchDate.map { String($0.timeIntervalSince1970.bitPattern) },
            isTerminated: app.isTerminated)
    }

    public func processes(for binding: AppBinding) throws -> [ProcessCandidate] {
        try coreAudio.availableAudioProcesses().compactMap { process in
            guard let app = application(process.pid), !app.isTerminated else { return nil }
            let selection: ProcessSelection
            if binding.bundleIdentifier == Self.safariBundle {
                // Temporary literal host-specific mapping, not a claim of helper ownership.
                // Never fall back to main Safari or an arbitrary WebKit/GPU process.
                guard app.localizedName == Self.safariHelperName else { return nil }
                selection = .temporarySafariGraphicsAndMedia
            } else {
                guard app.bundleIdentifier == binding.bundleIdentifier else { return nil }
                selection = .sameBundle
            }
            return ProcessCandidate(binding: binding, pid: process.pid, audioProcessID: process.audioProcessID,
                instanceIdentifier: app.instanceIdentifier, selection: selection)
        }
    }
}
