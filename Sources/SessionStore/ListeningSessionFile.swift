import Foundation
import SoundModel

public enum SessionFileError: Error {
  case tooLarge
  case conflictingRevision
}

/// One writer per app session file. Revision ordering is local to this process.
public actor ListeningSessionFile {
  private let url: URL
  private let maximumBytes: Int
  private var lastSaved: (revision: UInt64, data: Data)?

  public init(url: URL, maximumBytes: Int = 1_048_576) {
    self.url = url
    self.maximumBytes = maximumBytes
  }

  public func load() throws -> Data? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    if let size = attributes[.size] as? NSNumber, size.int64Value > Int64(maximumBytes) {
      throw SessionFileError.tooLarge
    }
    let data = try Data(contentsOf: url)
    guard data.count <= maximumBytes else { throw SessionFileError.tooLarge }
    return data
  }

  @discardableResult
  public func save(_ checkpoint: ListeningCheckpoint) throws -> Bool {
    let revision = checkpoint.snapshot.revision
    let data = checkpoint.data
    guard data.count <= maximumBytes else { throw SessionFileError.tooLarge }
    if let lastSaved {
      guard revision >= lastSaved.revision else { return false }
      if revision == lastSaved.revision {
        guard data == lastSaved.data else { throw SessionFileError.conflictingRevision }
        return false
      }
    }
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
    lastSaved = (revision, data)
    return true
  }
}
