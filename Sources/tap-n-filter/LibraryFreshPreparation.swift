import Foundation
import SoundModel

enum LibraryFreshStage: Equatable, Sendable { case selection, checkpoint }
enum LibraryFreshPreparationFailure: Equatable, Sendable {
    case refused(LibraryFreshStage, LibraryCommit)
    case unresolved(LibraryFreshStage, LibraryCommit)
    case invalidSeed(LibraryCommit?)
    case failure(String)
}
enum LibraryFreshPreparationResult: Equatable, Sendable {
    case prepared(LibraryCommit)
    case failed(LibraryFreshPreparationFailure)
}
enum LibraryFreshPreparation {
    static func safariEveryday(_ owner: SoundLibrarySession) async -> LibraryFreshPreparationResult {
        do {
            await owner.setEnabled(false)
            guard let everyday = try await owner.snapshot().definitions.first(where: { $0.builtin == .everyday }) else {
                return .failed(.invalidSeed(nil))
            }
            let selection = try await owner.select(everyday.id, on: "com.apple.Safari")
            if let failure = failure(selection, at: .selection) { return .failed(failure) }
            await owner.setEnabled(false)
            let checkpoint = try await owner.checkpoint()
            if let failure = failure(checkpoint, at: .checkpoint) { return .failed(failure) }
            let state = try await owner.snapshot(), coverage = try await owner.saveCoverage()
            guard coverage.isSaved, !state.isEnabled, state.assignments.count == 1,
                  state.assignments[0].target == "com.apple.Safari", state.assignments[0].definition == everyday.id else {
                return .failed(.invalidSeed(checkpoint))
            }
            return .prepared(checkpoint)
        } catch { return .failed(.failure(String(describing: error))) }
    }
    private static func failure(_ commit: LibraryCommit, at stage: LibraryFreshStage) -> LibraryFreshPreparationFailure? {
        switch commit.outcome {
        case .committed, .identical: return nil
        case .refused: return .refused(stage, commit)
        case .unresolved: return .unresolved(stage, commit)
        }
    }
}
