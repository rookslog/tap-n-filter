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
}

@MainActor
final class LibrarySliderRequest {
    let position: LibraryPosition
    private var result: Result<LibrarySliderResult, Error>?
    private var waiters: [CheckedContinuation<LibrarySliderResult, Error>] = []
    init(_ position: LibraryPosition) { self.position = position }
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
    var pending: LibrarySliderRequest?
    var accepting = true
    var inFlight = false
    init(binding: LibraryBinding, address: LibraryControlAddress, option: LibraryOptionGesture?, identity: LibraryMenuIdentity?, request: LibrarySliderRequest) {
        self.binding = binding; self.address = address; self.option = option; self.identity = identity; pending = request
    }
    func matches(_ binding: LibraryBinding, _ address: LibraryControlAddress, _ option: LibraryOptionGesture?, identity: LibraryMenuIdentity?) -> Bool {
        accepting && self.binding == binding && self.address == address && self.option == option && self.identity == identity
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
    var latest: LibraryPosition?
    init(_ plan: LibraryParameterPlan, epoch: UInt64) { self.plan = plan; self.epoch = epoch }
}
