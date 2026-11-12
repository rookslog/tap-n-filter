import AVFoundation
import Capture
import PlaybackRuntime

@MainActor
public final class TapCaptureResource: CaptureResource {
    public let ring: AudioRingBuffer
    public let format: AVAudioFormat
    fileprivate init(reader: TapIOProcReader) {
        ring = reader.ring
        format = reader.format
    }
}

@MainActor
public final class TapCaptureSessionFactory: CaptureSessionFactory {
    private let coreAudio: any CoreAudioInterface
    public init(coreAudio: any CoreAudioInterface) { self.coreAudio = coreAudio }
    public func makeSession() -> any CaptureSession { TapCaptureSession(coreAudio: coreAudio) }
}

@MainActor
private final class TapCaptureSession: CaptureSession {
    private let coreAudio: any CoreAudioInterface
    private var reader: TapIOProcReader?
    private var preparation: CapturePreparation?

    init(coreAudio: any CoreAudioInterface) { self.coreAudio = coreAudio }

    func prepare(source: ResolvedProcess) async throws -> CapturePreparation {
        try Task.checkCancellation()
        if let preparation { return preparation }
        let created = try TapIOProcReader(audioProcessID: source.audioProcessID, coreAudio: coreAudio)
        reader = created
        let format = try StreamFormat(sampleRate: created.format.sampleRate, channels: created.format.channelCount)
        let prepared = CapturePreparation(format: format, resource: TapCaptureResource(reader: created))
        preparation = prepared
        return prepared
    }

    func start() async throws {
        try Task.checkCancellation()
        guard let reader else { throw RuntimeFailure.start("capture was not prepared") }
        try reader.start()
    }

    func stop() async -> TeardownOutcome {
        reader?.stop()
        reader = nil
        preparation = nil
        return .bestEffort("TapIOProcReader.stop suppresses individual HAL teardown errors")
    }
}
