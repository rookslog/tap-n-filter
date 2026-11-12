import Foundation
import SoundModel

public enum LibraryFileError: Error { case tooLarge, notLoaded }

/// Explicit URL, one writer, no App startup selection or multiprocess compare-and-swap.
public actor LibrarySessionFile: LibraryPersistence {
    private let url: URL
    private let maximumBytes: Int
    private var loaded = false
    private var baseline: Data?

    public init(url: URL, maximumBytes: Int) {
        self.url = url; self.maximumBytes = maximumBytes
    }
    private func read() throws -> Data? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let size = attributes[.size] as? NSNumber, size.int64Value > Int64(maximumBytes) {
                throw LibraryFileError.tooLarge
            }
            let data = try Data(contentsOf: url)
            guard data.count <= maximumBytes else { throw LibraryFileError.tooLarge }
            return data
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }
    public func load() throws -> Data? {
        let data = try read(); baseline = data; loaded = true; return data
    }
    public func commit(_ data: Data) -> LibraryWriteOutcome {
        guard loaded else { return .refused(.notLoaded) }
        guard maximumBytes > 0, data.count <= maximumBytes else { return .refused(.byteLimit) }
        do {
            let current = try read()
            if current == data { baseline = data; return .identical }
            guard current == baseline else { return .refused(.destinationChanged) }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            // Replacement might have succeeded before the reported failure. Never invent rollback.
            do {
                let observed = try read()
                if observed == data { baseline = data; return .committed }
                if observed == baseline { return .refused(.io("original bytes retained")) }
                return .unresolved("I/O failure; readback differs from both candidate and baseline")
            } catch { return .unresolved("I/O failure; readback unavailable") }
        }
        baseline = data
        return .committed
    }
}
