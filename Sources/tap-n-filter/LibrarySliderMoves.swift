import Foundation
import SoundModel

struct LibrarySliderEligibility: Equatable {
    let binding: LibraryBinding
    let address: LibraryControlAddress
    let option: LibraryOptionGesture?
}

// Replaced requests complete explicitly, without claiming an owner application.
enum LibrarySliderResult: Sendable {
    case executed(LibraryLiveMutation)
    case delivered(LibraryLiveMutation)
    case fenced(LibraryLiveMutation)
    case coalesced
    case live
    /// A-E2: a refused value write. Refused at admission, or admitted before a failed drag commit moved the discard epoch
    /// and found stale where it would act. Nothing was applied or written; the session ignores it entirely.
    case dropped
}

/// A-E2: the discard epoch. Every write of a control's value is stamped with it when it is admitted, and is discarded
/// where it would act if a failed drag commit has moved it since. Its own type, so it is never mixed up with a card's
/// barrier epoch or the session's save epoch.
struct LibraryDiscardEpoch: Equatable, Sendable {
    private let value: UInt64
    static let first = LibraryDiscardEpoch(value: 0)
    var next: LibraryDiscardEpoch { LibraryDiscardEpoch(value: value &+ 1) }
}

/// A-E2: the epoch a write of a control's value carries to the sink. A required argument of every value write.
enum LibraryWriteAdmission: Sendable {
    /// A gesture's ordered commit, already serial on the commit chain.
    case commit(LibraryDiscardEpoch)
    /// Any other value write (a slider sample or step, a choice pick, a move): any pending gesture or commit settles first.
    case value(LibraryDiscardEpoch)
}

@MainActor
final class LibrarySliderRequest {
    let position: LibraryPosition
    /// A-E2: the discard epoch when this sample was admitted.
    let discardEpoch: LibraryDiscardEpoch
    private var result: Result<LibrarySliderResult, Error>?
    private var waiters: [CheckedContinuation<LibrarySliderResult, Error>] = []
    init(_ position: LibraryPosition, discardEpoch: LibraryDiscardEpoch) { self.position = position; self.discardEpoch = discardEpoch }
    func finish(_ value: Result<LibrarySliderResult, Error>) {
        precondition(result == nil)
        result = value
        for waiter in waiters { waiter.resume(with: value) }
        waiters.removeAll()
    }
    var value: LibrarySliderResult {
        get async throws {
            if let result { return try result.get() }
            return try await withCheckedThrowingContinuation { waiters.append($0) }
        }
    }
}

@MainActor
final class LibrarySliderBatch {
    let binding: LibraryBinding
    let address: LibraryControlAddress
    let option: LibraryOptionGesture?
    let identity: LibraryMenuIdentity?
    /// A-E2: the discard epoch of this segment's samples. A sample of another epoch never joins it.
    let discardEpoch: LibraryDiscardEpoch
    var pending: LibrarySliderRequest?
    var accepting = true
    var inFlight = false
    init(binding: LibraryBinding, address: LibraryControlAddress, option: LibraryOptionGesture?, identity: LibraryMenuIdentity?,
         request: LibrarySliderRequest, discardEpoch: LibraryDiscardEpoch) {
        self.binding = binding; self.address = address; self.option = option; self.identity = identity
        self.discardEpoch = discardEpoch; pending = request
    }
    func matches(_ binding: LibraryBinding, _ address: LibraryControlAddress, _ option: LibraryOptionGesture?, identity: LibraryMenuIdentity?,
                 discardEpoch: LibraryDiscardEpoch) -> Bool {
        accepting && self.binding == binding && self.address == address && self.option == option && self.identity == identity
            && self.discardEpoch == discardEpoch
    }
    func replace(_ request: LibrarySliderRequest) {
        pending?.finish(.success(.coalesced))
        pending = request
    }
    func take() -> LibrarySliderRequest? {
        let next = pending; pending = nil; return next
    }
}

@MainActor
final class LibraryParameterGesture {
    let plan: LibraryParameterPlan
    let epoch: UInt64
    /// A-E2: the discard epoch when the gesture was created. Every value in `latest` was admitted in it: a reset drops
    /// `parameterGesture`, so only a commit that already captured this gesture can still hold it afterwards.
    let discardEpoch: LibraryDiscardEpoch
    var latest: LibraryPosition?
    init(_ plan: LibraryParameterPlan, epoch: UInt64, discardEpoch: LibraryDiscardEpoch) {
        self.plan = plan; self.epoch = epoch; self.discardEpoch = discardEpoch
    }
}
