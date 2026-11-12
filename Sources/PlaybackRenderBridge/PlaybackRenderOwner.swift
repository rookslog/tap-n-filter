import Foundation
import PlaybackDSP
import SoundModel

public struct RenderDesiredReceipt {
    public let token: FRToken
    public let preparationRequired: Bool
    public let adaptations: [CutoffAdaptation]
}

public struct RenderPreparationReceipt {
    public let token: FRToken
    public let result: UInt32
    public let nativeStatus: Int32
    public let published: Bool
}

@MainActor
public final class PlaybackRenderOwner {
    // These C records contain only copied scalar values and fixed scalar arrays.
    private struct Work: @unchecked Sendable {
        var config: FRConfig
        var program: FRProgram
        var frame: FRFrame
    }
    // The opaque unpublished bank transfers exclusively from preparation to control.
    private struct Prepared: @unchecked Sendable {
        var bank: OpaquePointer?
        let result: FRResult
        let nativeStatus: Int32
    }
    private enum State { case open, closing, closed }

    public let assignmentID: UUID
    public let numericAssignmentKey: UInt64
    public let format: RenderProcessingFormat
    public private(set) var desiredToken = FRToken()
    public private(set) var lastDesired: RenderDesiredReceipt?
    public private(set) var lastPreparation: RenderPreparationReceipt?
    public private(set) var preparationsStarted: UInt64 = 0
    public private(set) var pendingCoalesced: UInt64 = 0
    private var entry: OpaquePointer?
    private var mapper = RenderAssignmentMapper()
    private var signature: [NativeRenderPart] = []
    private var bundleIdentifier: String
    private var state = State.open
    private var active: Task<Void, Never>?
    private var activeToken: FRToken?
    private var pending: Work?
    private var publishedTopology: UInt64?

    public convenience init(assignment: ListeningAssignment, numericAssignmentKey: UInt64,
                            sourceEpoch: UInt64, formatEpoch: UInt64, format: RenderProcessingFormat,
                            intent: UInt64) throws {
        try self.init(assignment: ListeningRenderAssignment(legacy: assignment), numericAssignmentKey: numericAssignmentKey,
                      sourceEpoch: sourceEpoch, formatEpoch: formatEpoch, format: format, intent: intent)
    }

    public init(assignment: ListeningRenderAssignment, numericAssignmentKey: UInt64,
                sourceEpoch: UInt64, formatEpoch: UInt64, format: RenderProcessingFormat,
                intent: UInt64) throws {
        guard numericAssignmentKey != 0 else { throw RenderBridgeError.invalidIdentity }
        self.assignmentID = assignment.id
        self.numericAssignmentKey = numericAssignmentKey
        self.format = format
        self.bundleIdentifier = assignment.bundleIdentifier
        var config = format.configuration
        let result = pd_create(&config, &entry)
        guard result == FR_OK else { throw RenderBridgeError.native(result.rawValue, 0) }
        do { _ = try update(assignment, intent: intent, sourceEpoch: sourceEpoch, formatEpoch: formatEpoch) }
        catch { pd_destroy(entry); entry = nil; throw error }
    }

    public var nativeCallback: PDCallback { state == .open ? pd_callback(entry) : PDCallback() }
    public var preparationPending: Bool { active != nil || pending != nil }

    public func update(_ assignment: ListeningAssignment, intent: UInt64,
                       sourceEpoch: UInt64, formatEpoch: UInt64) throws -> RenderDesiredReceipt {
        try update(ListeningRenderAssignment(legacy: assignment), intent: intent,
                   sourceEpoch: sourceEpoch, formatEpoch: formatEpoch)
    }

    public func update(_ assignment: ListeningRenderAssignment, intent: UInt64,
                       sourceEpoch: UInt64, formatEpoch: UInt64) throws -> RenderDesiredReceipt {
        guard state == .open, let entry else { throw RenderBridgeError.closed }
        guard assignment.id == assignmentID else { throw RenderBridgeError.invalidIdentity }
        guard intent > desiredToken.intent else { throw RenderBridgeError.nonIncreasingIntent }
        guard sourceEpoch > 0, formatEpoch > 0, sourceEpoch >= desiredToken.source_epoch,
              formatEpoch >= desiredToken.format_epoch else { throw RenderBridgeError.staleEpoch }
        if assignment.bundleIdentifier != bundleIdentifier, sourceEpoch == desiredToken.source_epoch {
            throw RenderBridgeError.staleEpoch
        }
        var token = FRToken(assignment: numericAssignmentKey, source_epoch: sourceEpoch,
                            format_epoch: formatEpoch, topology: max(1, desiredToken.topology), intent: intent)
        var candidate = mapper
        var lowered = try candidate.lower(assignment, format: format, token: token)
        let changed = desiredToken.topology == 0 || lowered.signature != signature
            || sourceEpoch != desiredToken.source_epoch || formatEpoch != desiredToken.format_epoch
        if changed, desiredToken.topology > 0 {
            guard desiredToken.topology < UInt64.max else { throw RenderBridgeError.exhaustedGeneration }
            token.topology = desiredToken.topology + 1
        }
        lowered.frame.token = token
        let result = pd_set_desired(entry, &lowered.program, &lowered.frame)
        guard result == FR_OK else { throw RenderBridgeError.native(result.rawValue, 0) }
        mapper = candidate
        signature = lowered.signature
        desiredToken = token
        bundleIdentifier = assignment.bundleIdentifier
        let work = Work(config: format.configuration, program: lowered.program, frame: lowered.frame)
        if let activeToken {
            if activeToken.topology != token.topology {
                if pending != nil { pendingCoalesced += 1 }
                pending = work
            }
        } else if changed || publishedTopology != token.topology { launch(work) }
        let receipt = RenderDesiredReceipt(token: token, preparationRequired: changed || publishedTopology != token.topology,
                                           adaptations: lowered.adaptations)
        lastDesired = receipt
        return receipt
    }

    public func setOriginalRequested(_ requested: Bool) {
        guard state == .open else { return }
        pd_request_original(entry, requested ? 1 : 0)
    }

    @discardableResult
    public func collect() -> UInt32 { pd_collect(entry) }

    public func telemetry() -> PDStats {
        var stats = PDStats()
        pd_stats(entry, &stats)
        return stats
    }

    public func waitUntilIdle() async {
        while let active { await active.value }
    }

    public func close(consumerQuiesced: Bool) async throws {
        if state == .closed { return }
        guard consumerQuiesced else { throw RenderBridgeError.consumerNotQuiesced }
        state = .closing
        pending = nil
        if let active { await active.value }
        if let entry {
            _ = pd_collect(entry)
            pd_destroy(entry)
            self.entry = nil
        }
        state = .closed
    }

    private func launch(_ work: Work) {
        activeToken = work.frame.token
        preparationsStarted += 1
        active = Task { @MainActor in
            let prepared = await Task.detached(priority: .userInitiated) { Self.prepare(work) }.value
            self.finish(prepared, work: work)
        }
    }

    nonisolated private static func prepare(_ copied: Work) -> Prepared {
        var work = copied, bank: OpaquePointer?, nativeStatus: Int32 = 0
        let result = pd_prepare(&work.config, &work.program, &work.frame, &bank, &nativeStatus)
        return Prepared(bank: bank, result: result, nativeStatus: nativeStatus)
    }

    private func finish(_ prepared: Prepared, work: Work) {
        var bank = prepared.bank, nativeStatus = prepared.nativeStatus, result = prepared.result
        var published = false
        if state == .open, let entry, result == FR_OK, bank != nil {
            _ = pd_collect(entry)
            result = pd_publish(entry, &bank, &nativeStatus)
            published = result == FR_OK
            if published { publishedTopology = work.frame.token.topology }
        }
        if let bank { pd_prepared_dispose(bank) }
        lastPreparation = RenderPreparationReceipt(token: work.frame.token, result: result.rawValue,
                                                   nativeStatus: nativeStatus, published: published)
        active = nil
        activeToken = nil
        if state == .open, let next = pending {
            pending = nil
            launch(next)
        }
    }
}
