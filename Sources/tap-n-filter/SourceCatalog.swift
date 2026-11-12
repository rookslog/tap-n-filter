import Foundation

struct SourceCatalogMetadata: Equatable {
  let bundleIdentifier: String
  let name: String
}

struct SourceCatalogEntry: Equatable {
  let metadata: SourceCatalogMetadata
  let isSelectable: Bool
}

enum SourceCatalog {
  static let registry = ["com.apple.Safari", "com.colliderli.iina"]

  static func lookupBundles(assigned: [String]) -> [String] {
    var seen: Set<String> = []
    return (registry + assigned).filter { seen.insert($0).inserted }
  }

  static func entries(installed: [SourceCatalogMetadata], assigned: [String],
                      retained: [SourceCatalogMetadata] = []) -> [SourceCatalogEntry] {
    var installedByID: [String: SourceCatalogMetadata] = [:]
    var retainedByID: [String: SourceCatalogMetadata] = [:]
    for app in installed where installedByID[app.bundleIdentifier] == nil { installedByID[app.bundleIdentifier] = app }
    for app in retained where retainedByID[app.bundleIdentifier] == nil { retainedByID[app.bundleIdentifier] = app }
    let assigned = Set(assigned)
    return lookupBundles(assigned: assigned.sorted()).compactMap { bundle in
      guard installedByID[bundle] != nil || assigned.contains(bundle) else { return nil }
      let metadata = installedByID[bundle] ?? retainedByID[bundle]
        ?? SourceCatalogMetadata(bundleIdentifier: bundle, name: bundle)
      return SourceCatalogEntry(metadata: metadata,
        isSelectable: registry.contains(bundle) && installedByID[bundle] != nil)
    }.sorted { $0.metadata.name.localizedStandardCompare($1.metadata.name) == .orderedAscending }
  }
}
