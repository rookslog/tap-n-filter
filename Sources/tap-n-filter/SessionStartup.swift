import Foundation
import SoundModel

enum AppSessionMode { case normal, smoke, probe }

enum AppSessionInput {
  case absent
  case loaded(Data)
  case unreadable(any Error)

  static func read(_ load: () async throws -> Data?) async -> Self {
    do { return try await load().map(Self.loaded) ?? .absent }
    catch { return .unreadable(error) }
  }
}

struct AppSessionStartup {
  let model: ListeningSession
  let input: AppSessionInput

  var error: (any Error)? {
    if case .unreadable(let error) = input { return error }
    return nil
  }
  var canSave: Bool { error == nil }

  static func prepare(_ input: AppSessionInput, mode: AppSessionMode) async throws -> Self {
    let model: ListeningSession
    switch input {
    case .absent:
      model = try await ListeningSession()
    case .loaded(let data):
      do { model = try await ListeningSession(savedData: data) }
      catch { return try await fallback(error, mode: mode) }
    case .unreadable(let error):
      return try await fallback(error, mode: mode)
    }
    if case .absent = input, mode == .normal {
      try await model.putEveryday(on: "com.apple.Safari")
      try await model.setEnabled(false)
    }
    return Self(model: model, input: input)
  }

  private static func fallback(_ error: any Error, mode: AppSessionMode) async throws -> Self {
    if mode == .smoke { throw error }
    return Self(model: try await ListeningSession(), input: .unreadable(error))
  }
}
