import AppKit
import Capture
import CoreAudio
import Darwin

enum OwnedProbeArm: String {
  case webkitBundle = "webkit-bundle", webkitMain = "webkit-main", nativeMain = "native-main"
}

enum OwnedProbeRefusal: String, Error {
  case options, unavailable, sourceIdentity, targetIdentity, alreadyCreated
}

struct OwnedProbeOptions {
  static let webkitBundle = "local.tnf.webkitfixture0"
  static let nativeBundle = "local.tnf.productionfixture0"
  static var fixtureDirectory: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent(".developer-fixtures/owned-probes", isDirectory: true)
  }
  static var nativePath: String {
    fixtureDirectory.appendingPathComponent("TNF Test Source.app/Contents/MacOS/source").path
  }
  static var webkitPath: String {
    fixtureDirectory.appendingPathComponent("TNFWebKitFixture.app/Contents/MacOS/TNFWebKitFixture").path
  }
  static func checkedFixtureExecutable(_ path: String) throws {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    guard url.path == path, url.resolvingSymlinksInPath().path == path,
      FileManager.default.isExecutableFile(atPath: path),
      (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    else { throw OwnedProbeRefusal.options }
  }
  let arm: OwnedProbeArm
  let pid: pid_t?
  let launch: Double?
  let executable: String
  var bundle: String { arm == .nativeMain ? Self.nativeBundle : Self.webkitBundle }

  static func parse(_ args: [String], bundleAvailable: () -> Bool) throws -> Self? {
    let keys = [
      "--probe-owned-arm", "--probe-owned-pid", "--probe-owned-launch", "--probe-owned-executable",
    ]
    guard args.contains(where: { $0.hasPrefix("--probe-owned") }) else { return nil }
    guard !args.contains(where: { $0.hasPrefix("--probe-requested") }) else {
      throw OwnedProbeRefusal.options
    }
    guard !args.contains("--smoke") else { throw OwnedProbeRefusal.options }
    for arg in args where arg.hasPrefix("--probe-owned") {
      guard keys.contains(arg) else { throw OwnedProbeRefusal.options }
    }
    func value(_ key: String, required: Bool = true) throws -> String? {
      let indices = args.indices.filter { args[$0] == key }
      guard indices.count <= 1 else { throw OwnedProbeRefusal.options }
      guard let i = indices.first else {
        if required { throw OwnedProbeRefusal.options }; return nil
      }
      guard i + 1 < args.count, !args[i + 1].hasPrefix("--"), !args[i + 1].isEmpty else {
        throw OwnedProbeRefusal.options
      }
      return args[i + 1]
    }
    guard let armText = try value(keys[0]), let arm = OwnedProbeArm(rawValue: armText) else {
      throw OwnedProbeRefusal.options
    }
    let bundle = arm == .nativeMain ? nativeBundle : webkitBundle
    guard try value("--probe-bundle") == bundle else { throw OwnedProbeRefusal.options }
    for key in ["--session-file", "--probe-report", "--probe-stop-file"] { _ = try value(key) }
    let pidText = try value(keys[1], required: false)
    let launchText = try value(keys[2], required: false)
    let executable = try value(keys[3], required: false)
    let fixture = try value("--fixture-source", required: false)
    let source = try value("--probe-source-url", required: false)
    if arm == .nativeMain {
      guard pidText == nil, launchText == nil, executable == nil, fixture == nativePath,
        source == nil
      else {
        throw OwnedProbeRefusal.options
      }
      try checkedFixtureExecutable(nativePath)
      return Self(arm: arm, pid: nil, launch: nil, executable: nativePath)
    }
    guard fixture == nil, let source, let url = URL(string: source),
      url.scheme == "http", url.host == "127.0.0.1", let port = url.port,
      (1...65535).contains(port),
      url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
      URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath.range(
        of: "^/[a-f0-9]{32}/$", options: .regularExpression) != nil,
      let pidText, let pid = Int32(pidText), pid > 0,
      let launchText, let launch = Double(launchText), launch.isFinite, launch > 0,
      let executable, executable == webkitPath
    else {
      throw OwnedProbeRefusal.options
    }
    try checkedFixtureExecutable(webkitPath)
    if arm == .webkitBundle && !bundleAvailable() { throw OwnedProbeRefusal.unavailable }
    return Self(arm: arm, pid: pid, launch: launch, executable: executable)
  }
}

struct OwnedProbeIdentity: Equatable {
  let pid: pid_t
  let bundle: String
  let executable: String
  let launch: Double
  let parent: pid_t?

  init(pid: pid_t, bundle: String, executable: String, launch: Double, parent: pid_t? = nil) {
    self.pid = pid; self.bundle = bundle; self.executable = executable; self.launch = launch;
    self.parent = parent
  }

  static func parentPID(_ pid: pid_t) -> pid_t? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    return pid_t(info.pbi_ppid)
  }

  static func running(bundle: String) throws -> [Self] {
    try NSRunningApplication.runningApplications(withBundleIdentifier: bundle).map {
      guard !$0.isTerminated, let executable = $0.executableURL?.path, let launch = $0.launchDate
      else {
        throw OwnedProbeRefusal.sourceIdentity
      }
      return Self(
        pid: $0.processIdentifier, bundle: bundle, executable: executable,
        launch: launch.timeIntervalSince1970,
        parent: bundle == OwnedProbeOptions.nativeBundle ? parentPID($0.processIdentifier) : nil)
    }
  }
}

final class OwnedProbeBinding {
  let options: OwnedProbeOptions
  private let started = Date().timeIntervalSince1970
  private var identity: OwnedProbeIdentity?
  init(_ options: OwnedProbeOptions) {
    self.options = options
    if let pid = options.pid, let launch = options.launch {
      identity = OwnedProbeIdentity(
        pid: pid, bundle: options.bundle,
        executable: options.executable, launch: launch)
    }
  }
  func bindNative(_ candidates: [OwnedProbeIdentity]) throws {
    guard options.arm == .nativeMain, candidates.count == 1, let current = candidates.first,
      current.bundle == options.bundle, current.executable == options.executable,
      current.launch >= started, current.pid > 0, current.parent == getpid()
    else { throw OwnedProbeRefusal.sourceIdentity }
    identity = current
  }
  func validate(_ candidates: [OwnedProbeIdentity]) throws -> pid_t {
    guard let identity, candidates == [identity] else { throw OwnedProbeRefusal.sourceIdentity }
    return identity.pid
  }
}

struct ProbeTargetFailure: Error {
  let stage: String
  let code: String
  var status: OSStatus? = nil
  func record() -> String {
    let fields: [String: Any] = [
      "stage": stage, "code": code, "status": status as Any? ?? NSNull(),
    ]
    let data = try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    return "PROBE_TARGET " + String(decoding: data, as: UTF8.self)
  }
}

struct RequestedSafariTarget: Equatable {
  static let bundle = "com.apple.Safari"
  let pid: pid_t
  let launch: Double
  let executable: String

  struct Metadata {
    let pid: pid_t
    let launch: Double?
    let executable: String?
    let bundle: String?
    let terminated: Bool
  }

  static func current() throws -> Self {
    try fromMetadata(
      NSRunningApplication.runningApplications(withBundleIdentifier: bundle).map {
        Metadata(
          pid: $0.processIdentifier, launch: $0.launchDate?.timeIntervalSince1970,
          executable: $0.executableURL?.path, bundle: $0.bundleIdentifier,
          terminated: $0.isTerminated)
      })
  }

  static func fromMetadata(_ apps: [Metadata]) throws -> Self {
    guard apps.count == 1, let app = apps.first else {
      throw ProbeTargetFailure(
        stage: "target-read", code: apps.isEmpty ? "app-absent" : "app-ambiguous")
    }
    guard !app.terminated, app.bundle == bundle, app.pid > 0 else {
      throw ProbeTargetFailure(stage: "target-read", code: "app-not-current-safari")
    }
    guard let launch = app.launch, launch.isFinite, launch > 0 else {
      throw ProbeTargetFailure(stage: "target-read", code: "launch-date-missing")
    }
    guard let executable = app.executable, !executable.isEmpty else {
      throw ProbeTargetFailure(stage: "target-read", code: "executable-missing")
    }
    return Self(
      pid: app.pid, launch: launch, executable: executable)
  }

  func validate(_ current: Self) throws -> pid_t {
    guard current.pid == pid else {
      throw ProbeTargetFailure(stage: "target-identity", code: "pid-changed")
    }
    guard current.launch == launch else {
      throw ProbeTargetFailure(stage: "target-identity", code: "launch-date-changed")
    }
    guard current.executable == executable else {
      throw ProbeTargetFailure(stage: "target-identity", code: "executable-changed")
    }
    return pid
  }
}

struct RequestedSafariOptions {
  let target: RequestedSafariTarget
  static func parse(_ args: [String], bundleAvailable: () -> Bool) throws -> Self? {
    let keys = [
      "--probe-requested-mode", "--probe-requested-pid", "--probe-requested-launch",
      "--probe-requested-executable",
    ]
    guard args.contains(where: { $0.hasPrefix("--probe-requested") }) else { return nil }
    func fail(_ code: String) -> ProbeTargetFailure {
      ProbeTargetFailure(stage: "options", code: code)
    }
    guard !args.contains(where: { $0.hasPrefix("--probe-owned") }),
      !args.contains(where: { $0.hasPrefix("--fixture-source") }), !args.contains("--smoke")
    else {
      throw fail("mixed-mode")
    }
    let allowed =
      keys + [
        "--probe-bundle", "--session-file", "--probe-report", "--probe-stop-file",
        "--probe-source-url",
      ]
    for a in args where a.hasPrefix("--") {
      guard allowed.contains(a) else { throw fail("unknown-or-equals-form-option") }
    }
    func value(_ key: String) throws -> String {
      let indices = args.indices.filter { args[$0] == key }
      guard indices.count == 1, let i = indices.first else {
        throw fail((indices.isEmpty ? "missing-" : "duplicate-") + key.dropFirst(2))
      }
      guard i + 1 < args.count, !args[i + 1].hasPrefix("--"), !args[i + 1].isEmpty else {
        throw fail("malformed-" + key.dropFirst(2))
      }
      return args[i + 1]
    }
    guard try value(keys[0]) == "safari-bundle" else { throw fail("unknown-mode") }
    guard try value("--probe-bundle") == RequestedSafariTarget.bundle else {
      throw fail("target-not-safari")
    }
    for k in ["--session-file", "--probe-report", "--probe-stop-file"] { _ = try value(k) }
    guard let pid = Int32(try value(keys[1])), pid > 0 else { throw fail("invalid-pid") }
    guard let launch = Double(try value(keys[2])), launch.isFinite, launch > 0 else {
      throw fail("invalid-launch-date")
    }
    let executable = try value(keys[3])
    guard executable.hasPrefix("/"), executable.hasSuffix("/Safari.app/Contents/MacOS/Safari"),
      !executable.contains("/../")
    else { throw fail("invalid-executable") }
    let source = try value("--probe-source-url")
    guard let url = URL(string: source), url.scheme == "http", url.host == "127.0.0.1",
      let port = url.port, (1...65535).contains(port),
      url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
      URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath.range(
        of: "^/[a-f0-9]{32}/$", options: .regularExpression) != nil
    else { throw fail("invalid-source-url") }
    guard bundleAvailable() else { throw fail("bundle-api-unavailable") }
    return Self(target: RequestedSafariTarget(pid: pid, launch: launch, executable: executable))
  }
}

enum ProbeBundleTarget {
  case ownedWebKit, requestedSafari
  var bundle: String {
    self == .ownedWebKit ? OwnedProbeOptions.webkitBundle : RequestedSafariTarget.bundle
  }
}

enum ProbeCaptureMode {
  case owned(OwnedProbeArm), requestedSafariBundle
  var requested: Bool { if case .requestedSafariBundle = self { return true }; return false }
  var label: String {
    if case .owned(let arm) = self { return arm.rawValue }; return "requested-safari-bundle"
  }
  var bundleTarget: ProbeBundleTarget? {
    switch self {
    case .owned(.webkitBundle): .ownedWebKit
    case .requestedSafariBundle: .requestedSafari
    default: nil
    }
  }
}

final class ProbeBundleCapture: CoreAudioInterface {
  let base: any CoreAudioInterface
  let mode: ProbeCaptureMode
  let validate: () throws -> pid_t
  let create: (CATapDescription) throws -> AudioObjectID
  let log: (String) -> Void
  private var attempted = false

  convenience init(
    base: any CoreAudioInterface, arm: OwnedProbeArm, validate: @escaping () throws -> pid_t,
    create: @escaping (CATapDescription) throws -> AudioObjectID = ProbeBundleCapture.nativeCreate,
    log: @escaping (String) -> Void = { print($0) }
  ) {
    self.init(base: base, mode: .owned(arm), validate: validate, create: create, log: log)
  }

  init(
    base: any CoreAudioInterface, mode: ProbeCaptureMode, validate: @escaping () throws -> pid_t,
    create: @escaping (CATapDescription) throws -> AudioObjectID = ProbeBundleCapture
      .requestedCreate,
    log: @escaping (String) -> Void = { print($0) }
  ) {
    self.base = base; self.mode = mode; self.validate = validate; self.create = create;
    self.log = log
  }

  static func bundleAvailable() -> Bool {
    if #available(macOS 26.0, *) {
      return CATapDescription.instancesRespond(to: NSSelectorFromString("setBundleIDs:"))
        && CATapDescription.instancesRespond(to: NSSelectorFromString("setProcessRestoreEnabled:"))
    }
    return false
  }

  @available(macOS 26.0, *)
  static func description(for object: AudioObjectID, target: ProbeBundleTarget = .ownedWebKit)
    -> CATapDescription
  {
    let d = CATapDescription(stereoMixdownOfProcesses: [])
    d.bundleIDs = [target.bundle]
    d.isProcessRestoreEnabled = false
    d.uuid = UUID(); d.name = "tap-n-filter.tap.\(object)"
    d.isPrivate = true; d.isExclusive = false; d.muteBehavior = .mutedWhenTapped
    return d
  }

  static func nativeCreate(_ description: CATapDescription) throws -> AudioObjectID {
    var id = AudioObjectID(kAudioObjectUnknown)
    let status = AudioHardwareCreateProcessTap(description, &id)
    guard status == noErr else {
      if status == kAudioHardwareNotRunningError || (-66_749 ... -66_731).contains(status) {
        throw CaptureError.permissionDenied
      }
      throw CaptureError.tapCreationFailed(status)
    }
    return id
  }

  static func requestedCreate(_ description: CATapDescription) throws -> AudioObjectID {
    try requestedCreateWithStatus(description) { d, id in AudioHardwareCreateProcessTap(d, &id) }
  }

  static func requestedCreateWithStatus(
    _ description: CATapDescription,
    perform: (CATapDescription, inout AudioObjectID) -> OSStatus
  ) throws -> AudioObjectID {
    var id = AudioObjectID(kAudioObjectUnknown)
    let status = perform(description, &id)
    guard status == noErr, id != kAudioObjectUnknown else {
      throw ProbeTargetFailure(
        stage: "tap-create", code: status == noErr ? "unknown-tap-object" : "native-status",
        status: status)
    }
    return id
  }

  private func requestedFailure(_ error: Error, stage: String) {
    if let e = error as? ProbeTargetFailure { log(e.record()); return }
    if case CaptureError.tapCreationFailed(let status) = error {
      log(ProbeTargetFailure(stage: stage, code: "native-status", status: status).record()); return
    }
    log(ProbeTargetFailure(stage: stage, code: "unclassified-refusal").record())
  }

  func createTap(for object: AudioObjectID) throws -> AudioObjectID {
    guard !attempted else {
      if mode.requested {
        let error = ProbeTargetFailure(stage: "tap-create", code: "duplicate-attempt")
        log(error.record()); throw error
      }
      throw OwnedProbeRefusal.alreadyCreated
    }
    attempted = true
    var stage = "target-identity"
    do {
      let pid = try validate()
      stage = "hal-target"
      let matches = try base.availableAudioProcesses().filter { $0.pid == pid }
      if mode.requested {
        guard object != kAudioObjectUnknown else {
          throw ProbeTargetFailure(stage: stage, code: "selected-object-unknown")
        }
        guard matches.count == 1 else {
          throw ProbeTargetFailure(
            stage: stage, code: matches.isEmpty ? "main-hal-absent" : "main-hal-ambiguous")
        }
        guard matches[0].audioProcessID == object else {
          throw ProbeTargetFailure(stage: stage, code: "selected-object-changed")
        }
        guard try base.audioProcessID(forPID: pid) == object else {
          throw ProbeTargetFailure(stage: stage, code: "pid-hal-mapping-changed")
        }
      } else {
        guard object != kAudioObjectUnknown, matches.count == 1,
          matches[0].audioProcessID == object,
          try base.audioProcessID(forPID: pid) == object
        else {
          throw OwnedProbeRefusal.targetIdentity
        }
      }
      // Re-read instance continuity after the HAL queries, before the sole create.
      guard try validate() == pid else {
        if mode.requested {
          throw ProbeTargetFailure(stage: "target-identity", code: "recheck-pid-changed")
        }
        throw OwnedProbeRefusal.sourceIdentity
      }
      if mode.requested {
        log(ProbeTargetFailure(stage: "target-identity", code: "valid").record())
      } else {
        log("PROBE_OWNED target-validated arm=\(mode.label) pid=\(pid) object=\(object)")
      }
      stage = "tap-create"
      if let target = mode.bundleTarget {
        guard #available(macOS 26.0, *), Self.bundleAvailable() else {
          if mode.requested {
            throw ProbeTargetFailure(stage: stage, code: "bundle-api-unavailable")
          }
          throw OwnedProbeRefusal.unavailable
        }
        return try create(Self.description(for: object, target: target))
      }
      return try base.createTap(for: object)
    } catch {
      if mode.requested {
        requestedFailure(error, stage: stage)
      } else {
        log(
          "PROBE_OWNED creation-refused arm=\(mode.label) type=\(String(describing: type(of: error)))"
        )
      }
      throw error
    }
  }

  func tapStreamFormat(for tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
    let f: AudioStreamBasicDescription
    do { f = try base.tapStreamFormat(for: tapID) } catch {
      if mode.requested { requestedFailure(error, stage: "tap-format-read") }
      throw error
    }
    log(
      "\(mode.requested ? "PROBE_TARGET_ASBD" : "PROBE_OWNED") asbd rate=\(f.mSampleRate) channels=\(f.mChannelsPerFrame) format=\(f.mFormatID) flags=\(f.mFormatFlags) bytesPerFrame=\(f.mBytesPerFrame) bits=\(f.mBitsPerChannel)"
    )
    return f
  }
  func audioProcessID(forPID pid: pid_t) throws -> AudioObjectID {
    try base.audioProcessID(forPID: pid)
  }
  func tapUID(for tapID: AudioObjectID) throws -> CFString { try base.tapUID(for: tapID) }
  func createAggregateDevice(description: CFDictionary) throws -> AudioDeviceID {
    try base.createAggregateDevice(description: description)
  }
  func setAggregateTapList(_ id: AudioDeviceID, tapUIDs: CFArray) throws {
    try base.setAggregateTapList(id, tapUIDs: tapUIDs)
  }
  func destroyAggregateDevice(_ id: AudioDeviceID) throws { try base.destroyAggregateDevice(id) }
  func destroyTap(_ id: AudioObjectID) throws { try base.destroyTap(id) }
  func createIOProcID(
    deviceID: AudioDeviceID, ioProc: AudioDeviceIOProc, clientData: UnsafeMutableRawPointer?
  ) throws -> AudioDeviceIOProcID {
    try base.createIOProcID(deviceID: deviceID, ioProc: ioProc, clientData: clientData)
  }
  func destroyIOProcID(deviceID: AudioDeviceID, ioProcID: AudioDeviceIOProcID) throws {
    try base.destroyIOProcID(deviceID: deviceID, ioProcID: ioProcID)
  }
  func startDevice(deviceID: AudioDeviceID, ioProcID: AudioDeviceIOProcID) throws {
    try base.startDevice(deviceID: deviceID, ioProcID: ioProcID)
  }
  func stopDevice(deviceID: AudioDeviceID, ioProcID: AudioDeviceIOProcID) throws {
    try base.stopDevice(deviceID: deviceID, ioProcID: ioProcID)
  }
  func availableAudioProcesses() throws -> [(pid: pid_t, audioProcessID: AudioObjectID)] {
    try base.availableAudioProcesses()
  }
  func streamCount(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
    base.streamCount(deviceID: deviceID, scope: scope)
  }
  func deviceIsRunning(deviceID: AudioDeviceID) -> Bool { base.deviceIsRunning(deviceID: deviceID) }
  func enumerateProcessTaps() -> [AudioObjectID] { base.enumerateProcessTaps() }
  func enumerateAllAudioDevices() -> [AudioDeviceID] { base.enumerateAllAudioDevices() }
  func audioDeviceUID(_ id: AudioDeviceID) -> String? { base.audioDeviceUID(id) }
  func tapName(_ id: AudioObjectID) -> String? { base.tapName(id) }
}
