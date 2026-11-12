import Foundation
import SoundModel
import SessionStore
import PlaybackRuntime

enum CheckError: Error { case failed(String), injectedRead }
func check(_ condition: Bool, _ message: String) throws {
  guard condition else { throw CheckError.failed(message) }
  print("PASS \(message)")
}
@MainActor final class MissingCatalog: ProcessCatalog {
  func processes(for binding: AppBinding) throws -> [ProcessCandidate] { [] }
}
@MainActor final class ForbiddenFactory: CaptureSessionFactory {
  var calls = 0
  func makeSession() -> any CaptureSession { calls += 1; preconditionFailure("missing source must fail before capture") }
}
@MainActor final class ForbiddenGuard: InputGuardPort {
  var calls = 0
  func recoverIfStranded() async -> GuardRestoration { calls += 1; return .noMarker }
  func engage(settingEnabled: Bool) async -> GuardEngagement { calls += 1; return .declined(reason: "fake only") }
  func restore() async -> GuardRestoration { calls += 1; return .noMarker }
}
@main struct StartupCheck {
  @MainActor static func main() async throws {
    let safari = "com.apple.Safari", iina = "com.colliderli.iina", chrome = "com.google.Chrome"
    func meta(_ bundle: String, _ name: String) -> SourceCatalogMetadata { .init(bundleIdentifier: bundle, name: name) }
    let installed = [meta(safari,"Safari"), meta(iina,"IINA"), meta(safari,"Duplicate Safari"),meta(chrome,"Chrome"),meta("unrelated.gpu","Safari"),meta("COM.APPLE.SAFARI","Safari")]
    var rows = SourceCatalog.entries(installed: installed, assigned: [])
    try check(rows.map(\.metadata.bundleIdentifier) == [iina,safari] && rows.allSatisfy(\.isSelectable),"curated installed Safari/IINA offered before audio; unrelated/name-spoof/case-spoof/duplicates excluded")
    try check(rows.first { $0.metadata.bundleIdentifier == safari }?.metadata.name == "Safari","duplicate metadata has stable first winner")
    try check(SourceCatalog.entries(installed: [], assigned: []).isEmpty,"missing unassigned registry apps omitted")
    rows = SourceCatalog.entries(installed: installed, assigned: [chrome,"missing.player"], retained: [meta("missing.player","Remembered Player")])
    try check(rows.first { $0.metadata.bundleIdentifier == chrome }?.isSelectable == false && rows.first { $0.metadata.bundleIdentifier == "missing.player" }?.metadata.name == "Remembered Player","existing unsupported/missing cards retain metadata but cannot be new choices")
    let absentRetained = SourceCatalog.entries(installed: [], assigned: [safari], retained: [meta(safari,"Safari")])
    try check(absentRetained.count == 1 && !absentRetained[0].isSelectable,"retained metadata alone is not installation or capture readiness")
    rows = SourceCatalog.entries(installed: installed, assigned: [], retained: rows.map(\.metadata))
    try check(rows.allSatisfy { $0.metadata.bundleIdentifier != chrome && $0.metadata.bundleIdentifier != "missing.player" },"None/removal never reoffers unsupported retained entries")

    let directory = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString,isDirectory: true)
    try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("state.json")
    let file = ListeningSessionFile(url: url)
    let blank = try await ListeningSession()
    let blankState = try await blank.snapshot()
    try check(blankState.assignments.isEmpty,"generic ListeningSession nil remains empty")
    let fresh = try await AppSessionStartup.prepare(await AppSessionInput.read { try await file.load() },mode: .normal)
    let first = try await fresh.model.snapshot()
    try check(fresh.canSave && first.assignments.count == 1 && first.assignments[0].bundleIdentifier == safari && first.assignments[0].block == .everyday && !first.isEnabled,"absent normal starts Safari/Everyday master OFF without audio")
    try await blank.putEveryday(on: safari)
    let neutral = try await blank.snapshot().assignments[0]
    try check(first.assignments[0].controls == neutral.controls && first.assignments[0].parts == neutral.parts,"fresh defaults use actual neutral built-in recipe")
    _ = try await file.save(fresh.model.checkpoint())
    let reopened = try await AppSessionStartup.prepare(await AppSessionInput.read { try await file.load() },mode: .normal)
    try check(try await reopened.model.snapshot().assignments == first.assignments,"save/reload keeps original assignment ID and no duplicate default")
    let empty = try await ListeningSession(); try await empty.setEnabled(true)
    let emptyData = try await empty.savedData()
    let loadedEmpty = try await AppSessionStartup.prepare(.loaded(emptyData),mode: .normal)
    let emptyState = try await loadedEmpty.model.snapshot()
    try check(emptyState.assignments.isEmpty && emptyState.isEnabled && loadedEmpty.canSave,"loaded valid empty/ON is not seeded or reset")
    let populated = try await ListeningSession()
    for bundle in [chrome,iina,safari] { try await populated.putEveryday(on: bundle) }
    let old = try await populated.snapshot()
    try await populated.setEnabled(false,for: old.assignments[0].id)
    try await populated.move(populated.controls.last!.id,on: old.assignments[1].id,to: 0.64)
    try await populated.setEnabled(true)
    let expected = try await populated.snapshot()
    let loaded = try await AppSessionStartup.prepare(.loaded(populated.savedData()),mode: .normal)
    let actual = try await loaded.model.snapshot()
    try check(actual.assignments == expected.assignments && actual.isEnabled == expected.isEnabled,"loaded populated retains unsupported assignments,IDs,added order,app flags,positions and power")
    try await loaded.model.select(nil,on: chrome)
    let remaining = try await loaded.model.snapshot()
    rows = SourceCatalog.entries(installed: installed,assigned: remaining.assignments.map(\.bundleIdentifier),retained: [meta(chrome,"Chrome")])
    try check(!rows.contains { $0.metadata.bundleIdentifier == chrome } && remaining.assignments.map(\.bundleIdentifier) == [iina,safari],"actual None command removes unsupported choice without changing remaining added order")
    for mode in [AppSessionMode.smoke,.probe] {
      let diagnostic = try await AppSessionStartup.prepare(.absent,mode: mode)
      let state = try await diagnostic.model.snapshot()
      try check(state.assignments.isEmpty && state.isEnabled == blankState.isEnabled,"absent diagnostic retains original empty initialization")
    }
    var unsupported = try JSONSerialization.jsonObject(with: emptyData) as! [String:Any];unsupported["version"] = 999
    var incompatible = try JSONSerialization.jsonObject(with: emptyData) as! [String:Any];incompatible["definitions"] = []
    let invalids = [Data("broken".utf8),try JSONSerialization.data(withJSONObject: unsupported),try JSONSerialization.data(withJSONObject: incompatible)]
    for data in invalids {
      try data.write(to: url)
      let reader = ListeningSessionFile(url: url)
      let outcome = try await AppSessionStartup.prepare(await AppSessionInput.read { try await reader.load() },mode: .normal)
      let state = try await outcome.model.snapshot()
      if outcome.canSave { _ = try await reader.save(outcome.model.checkpoint()) }
      try check(!outcome.canSave && outcome.error != nil && state.assignments.isEmpty && (try Data(contentsOf: url)) == data,"corrupt/unsupported/incompatible is unreadable,no seed/no save,original bytes retained")
    }
    let bytes = Data(repeating: 7,count: 20);try bytes.write(to: url)
    let limited = ListeningSessionFile(url: url,maximumBytes: 8)
    let oversize = try await AppSessionStartup.prepare(await AppSessionInput.read { try await limited.load() },mode: .normal)
    let oversizeState = try await oversize.model.snapshot()
    try check(!oversize.canSave && oversizeState.assignments.isEmpty && (try Data(contentsOf: url)) == bytes,"actual oversize load stays unreadable,empty and byte-preserved")
    let denied = try await AppSessionStartup.prepare(.unreadable(CheckError.injectedRead),mode: .normal)
    let deniedState = try await denied.model.snapshot()
    try check(!denied.canSave && deniedState.assignments.isEmpty,"read-error injection is not an absent file")
    do { _ = try await AppSessionStartup.prepare(.loaded(Data("broken".utf8)),mode: .smoke);throw CheckError.failed("smoke must throw") } catch is DecodingError { }
    let probeError = try await AppSessionStartup.prepare(.loaded(Data("broken".utf8)),mode: .probe)
    let probeState = try await probeError.model.snapshot()
    try check(!probeError.canSave && probeState.assignments.isEmpty,"smoke keeps thrown validation error;probe keeps no-save empty fallback")
    let factory = ForbiddenFactory(), guardPort = ForbiddenGuard()
    let leases = InputGuardLeaseCoordinator(port: guardPort,settingEnabled: true)
    let runtime = PlaybackRuntime(resolver: BundleProcessResolver(catalog: MissingCatalog()),factory: factory,leases: leases)
    let request = StartRequest(assignment: AssignmentID(UUID()),binding: try AppBinding(bundleIdentifier: iina),token: PlanToken(intent: 1,source: 1,format: 1))
    let result = await runtime.start(request)
    guard case .failed(.source(.disappeared),nil,nil) = result.event else { throw CheckError.failed("missing source must produce disappeared failure") }
    try check(factory.calls == 0 && guardPort.calls == 0 && leases.activeLeaseCount == 0,"R1 actual resolver/runtime absent HAL source reports disappeared before fake capture or guard;installed choice is not capture-ready")
    print("PASS actual model/file/catalog/fake-runtime only;owned temporary files,no App/UI/native metadata/engine/audio/device action")
  }
}
