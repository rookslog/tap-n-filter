import Foundation

public struct ProcessCandidate: Equatable, Sendable {
    public let binding: AppBinding
    public let pid: Int32
    public let audioProcessID: UInt32
    public let instanceIdentifier: String?
    public let selection: ProcessSelection
    public init(
        binding: AppBinding, pid: Int32, audioProcessID: UInt32, instanceIdentifier: String? = nil,
        selection: ProcessSelection = .sameBundle
    ) {
        self.binding = binding
        self.pid = pid
        self.audioProcessID = audioProcessID
        self.instanceIdentifier = instanceIdentifier
        self.selection = selection
    }
}

@MainActor
public protocol ProcessCatalog {
    func processes(for binding: AppBinding) throws -> [ProcessCandidate]
}

@MainActor
public final class BundleProcessResolver: ProcessResolving {
    private let catalog: any ProcessCatalog
    private let fallbackLimit: Int

    public init(catalog: any ProcessCatalog, fallbackLimit: Int = 8) {
        self.catalog = catalog
        self.fallbackLimit = max(1, fallbackLimit)
    }

    public func resolve(binding: AppBinding, preferredPID: Int32?) async throws -> ResolvedProcess {
        let candidates = try validCandidates(binding)
        let preferredMatches = candidates.filter { $0.pid == preferredPID }
        if let preferred = preferredMatches.first {
            if preferred.selection == .temporarySafariGraphicsAndMedia
                && preferredMatches.count != 1
            {
                throw SourceResolutionError.ambiguousSameBundle(count: preferredMatches.count)
            }
            return resolved(preferred, path: .preferredPID)
        }
        guard candidates.count <= fallbackLimit else {
            throw SourceResolutionError.fallbackLimitExceeded(limit: fallbackLimit)
        }
        guard let only = candidates.first else { throw SourceResolutionError.disappeared }
        guard candidates.count == 1 else {
            throw SourceResolutionError.ambiguousSameBundle(count: candidates.count)
        }
        return resolved(only, path: .sameBundleFallback(previousPID: preferredPID))
    }

    public func revalidate(_ process: ResolvedProcess) async throws {
        let candidates = try validCandidates(process.binding)
        let matches = candidates.filter { $0.pid == process.pid }
        guard let current = matches.first else {
            if candidates.isEmpty { throw SourceResolutionError.disappeared }
            throw SourceResolutionError.replaced
        }
        if process.path == .temporarySafariGraphicsAndMedia && matches.count != 1 {
            throw SourceResolutionError.replaced
        }
        guard current.audioProcessID == process.audioProcessID,
              current.instanceIdentifier == process.instanceIdentifier else {
            throw SourceResolutionError.replaced
        }
    }

    private func validCandidates(_ binding: AppBinding) throws -> [ProcessCandidate] {
        try catalog.processes(for: binding).filter {
            $0.binding == binding && $0.pid > 0 && $0.audioProcessID != 0
        }
    }

    private func resolved(_ candidate: ProcessCandidate, path: ResolutionPath) -> ResolvedProcess {
        ResolvedProcess(binding: candidate.binding, pid: candidate.pid,
            audioProcessID: candidate.audioProcessID,
            path: candidate.selection == .temporarySafariGraphicsAndMedia
                ? .temporarySafariGraphicsAndMedia : path,
                        instanceIdentifier: candidate.instanceIdentifier)
    }
}
