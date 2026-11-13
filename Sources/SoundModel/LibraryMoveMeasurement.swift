import Foundation

/// Elapsed synchronous owner work, excluding the dispatch/actor queue and UI publication.
public struct LibraryMoveMeasurement: Sendable {
    public let outcome: LibraryLiveMutation
    public let startedUptime: Double
    public let finishedUptime: Double
}
public struct LibraryMenuMoveMeasurement: Sendable {
    public let result: LibraryMenuMoveResult
    public let measurement: LibraryMoveMeasurement
}

extension SoundLibrarySession {
    public func measuredMenuMove(_ address: LibraryControlAddress, expected: LibraryMenuIdentity,
                                optionGesture: LibraryOptionGesture? = nil, to value: LibraryPosition) async throws -> LibraryMenuMoveMeasurement {
        try await document.libraryMeasuredMenuMove(expected: expected, key: address.key, option: optionGesture, value: value)
    }
    public func measuredMove(_ address: LibraryControlAddress, expected: LibraryBinding,
                             optionGesture: LibraryOptionGesture? = nil, to value: LibraryPosition) async throws -> LibraryMoveMeasurement {
        try await document.libraryMeasuredMove(expected: expected, key: address.key, option: optionGesture, value: value)
    }
}

extension SoundDocument {
    func libraryMeasuredMenuMove(expected: LibraryMenuIdentity, key: OccurrenceControlKey,
                                option: LibraryOptionGesture?, value: LibraryPosition) throws -> LibraryMenuMoveMeasurement {
        let start = ProcessInfo.processInfo.systemUptime
        let result = try libraryMenuMove(expected: expected, key: key, option: option, value: value)
        return LibraryMenuMoveMeasurement(result: result, measurement: LibraryMoveMeasurement(outcome: result.outcome,
            startedUptime: start, finishedUptime: ProcessInfo.processInfo.systemUptime))
    }
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
