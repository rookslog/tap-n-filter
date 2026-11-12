import Foundation
import SoundModel
import SessionStore

@MainActor func sourceCorrectionCases(_ root: URL) async throws {
    let bundle = "test.player"
    func metadata(_ id: String? = "test.player", _ display: String? = nil, _ name: String? = nil, _ file: String? = nil) -> TNFEditorAppMetadata {
        TNFEditorAppMetadata(bundleIdentifier: id, localizedDisplayName: display, bundleName: name, fileDisplayName: file)
    }
    let localized = TNFEditorAppIdentity(bundle: bundle, metadata: metadata(bundle, "  Café Player  ", "Player", "File"))
    try check(localized.name == "Café Player" && !localized.isMissing && localized.image == nil, "R3 injected localized exact-bundle metadata takes precedence, without native lookup")
    let fallback = TNFEditorAppIdentity(bundle: bundle, metadata: metadata(bundle, " ", nil, "Local Player"))
    try check(fallback.name == "Local Player" && !fallback.isMissing, "R3 injected FileManager metadata fallback")
    for facts in [nil, metadata(bundle, " ", "", nil), metadata("test.other", "Wrong app"), metadata(bundle, bundle, nil, bundle)] {
        let absent = TNFEditorAppIdentity(bundle: bundle, metadata: facts)
        try check(absent.name == "Missing App" && absent.isMissing && absent.image == nil, "R3 absent/empty/wrong-identity/raw-ID metadata never invents a display name")
    }
    let (_, app, commands, safari, _) = try await setup(root)
    var calls: [String] = [], installed = false
    commands.appIdentityResolver = { bundle in
        calls.append(bundle)
        return TNFEditorAppIdentity(bundle: bundle, metadata: installed ? metadata(bundle, "Installed Player") : nil)
    }
    commands.refreshAppIdentities()
    try check(Set(calls) == Set(app.snapshot!.assignments.map(\.target)) && commands.appName(safari.target) == "Missing App", "R3 one resolver projection covers exact assigned bundles")
    let bindingBefore = app.snapshot!.assignments
    installed = true; calls = []; commands.windowPresented = true; commands.receiveOwnerChange()
    try check(commands.appName(safari.target) == "Installed Player" && Set(calls) == Set(bindingBefore.map(\.target)), "R3 owner snapshot boundary rechecks previously missing app without a timer")
    try check(app.snapshot!.assignments == bindingBefore, "R3 name resolution never replaces assignment/use")
    commands.focusedControl = address
    try check(commands.settingIsReached(sourceControls: [choice], path: []), "R1 current root control reaches its root setting")
    commands.focusedControl = LibraryControlAddress(path: [id(4801)], control: choice)
    try check(!commands.settingIsReached(sourceControls: [choice], path: []), "R1 repeated occurrence with same ControlID cannot reach another occurrence's setting")
    try check(commands.settingIsReached(sourceControls: [choice], path: [id(4801)]), "R1 exact occurrence path and ControlID match")
    commands.focusedControl = nil
    try check(!commands.settingIsReached(sourceControls: [choice], path: []), "R1 no focused control has no reached treatment")
    // Finish the actual router session; no NSApplication, icon or window is constructed.
    commands.appIdentityResolver = nil
    commands.prepareQuit(); app.beginDrain(); _ = await app.finishDrain(.save); app.close()
}
