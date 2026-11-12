import Foundation

/// Elapsed synchronous owner work, excluding the dispatch/actor queue and UI publication.
public struct LibraryMoveMeasurement: Sendable {
    public let outcome: LibraryLiveMutation
    public let startedUptime: Double
    public let finishedUptime: Double
}

extension SoundLibrarySession {
    public func measuredMove(_ address: LibraryControlAddress, expected: LibraryBinding,
                             optionGesture: LibraryOptionGesture? = nil, to value: LibraryPosition) async throws -> LibraryMoveMeasurement {
        try await document.libraryMeasuredMove(expected: expected, key: address.key, option: optionGesture, value: value)
    }
}

extension SoundDocument {
    func libraryMeasuredMove(expected: LibraryBinding, key: OccurrenceControlKey,
                             option: LibraryOptionGesture?, value: LibraryPosition) throws -> LibraryMoveMeasurement {
        let start = ProcessInfo.processInfo.systemUptime
        let outcome: LibraryLiveMutation
        if let option { outcome = try libraryMoveOptionChild(expected: expected, key: key, gesture: option, value: value) }
        else { outcome = try libraryMove(expected: expected, key: key, value: value) }
        return LibraryMoveMeasurement(outcome: outcome, startedUptime: start,
                                      finishedUptime: ProcessInfo.processInfo.systemUptime)
    }
}
