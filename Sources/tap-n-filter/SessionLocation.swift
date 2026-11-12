import Foundation

enum SessionLocation {
  static let trialInfoKey = "TNFTrialSessionFile"

  enum SelectionError: Error { case invalidPackagedSession }

  static func select(
    cliPath: String?, requiresExplicitCLI: Bool, packagedValue: Any?,
    normalDefault: () -> URL
  ) throws -> URL {
    if requiresExplicitCLI && cliPath == nil {
      throw CocoaError(.fileWriteInvalidFileName)
    }
    if let cliPath { return URL(fileURLWithPath: cliPath) }
    guard let packagedValue else { return normalDefault() }
    guard let path = packagedValue as? String, path.hasPrefix("/"),
      !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else { throw SelectionError.invalidPackagedSession }
    let url = URL(fileURLWithPath: path)
    guard url.standardizedFileURL.path == path, url.lastPathComponent == "listening-v1.json" else {
      throw SelectionError.invalidPackagedSession
    }
    return url
  }
}
