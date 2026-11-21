import AppKit
import CoreAudio
import Foundation

/// What wakes a lane that is waiting for its app (waiting state).
enum PlaybackWakeSchedule {
  /// Changes to the audio-process list inside this window fold into one attempt.
  static let listFold: TimeInterval = 0.25
  /// Seconds after an app launch at which one attempt is made, stopping at the first success.
  static let launchBurst: [TimeInterval] = [0.5, 1, 2, 4, 8]
}

/// Everything a waiting lane needs from outside the controller, as closures so a check can script it.
/// Each `listen...` returns its own removal; adding and removing are always paired by the controller.
@MainActor
struct PlaybackWakeEnvironment {
  /// Listens for changes to the system's audio-process list. Installed only while a lane is waiting. Returns
  /// nil when no listener could be installed, so the controller tries again at its next reconcile.
  var listenForProcessListChanges: (@escaping @MainActor () -> Void) -> (@MainActor () -> Void)?
  /// Listens for application launches; the handler receives the launched app's bundle identifier.
  var listenForLaunches: (@escaping @MainActor (String) -> Void) -> (@MainActor () -> Void)
  /// Runs `work` once after `delay` seconds on the main actor; the result cancels it.
  var schedule: (TimeInterval, @escaping @MainActor () -> Void) -> (@MainActor () -> Void)

  static func system(log: @escaping @MainActor (String) -> Void = { _ in }) -> PlaybackWakeEnvironment {
    PlaybackWakeEnvironment(
      listenForProcessListChanges: { handler in
        let listener = AudioProcessListListener(log: log, handler: handler)
        guard listener.addStatus == noErr else { return nil }
        return { _ = listener.remove() }
      },
      listenForLaunches: { handler in
        let center = NSWorkspace.shared.notificationCenter
        let token = center.addObserver(
          forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { notification in
          guard
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
              as? NSRunningApplication,
            let bundle = app.bundleIdentifier
          else { return }
          Task { @MainActor in handler(bundle) }
        }
        return { center.removeObserver(token) }
      },
      schedule: { delay, work in
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
          MainActor.assumeIsolated { work() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
      })
  }
}

/// A CoreAudio property listener on the system object's process list, added at `init` and removed by `remove()`
/// (idempotent); the controller creates one only while a lane is waiting.
///
/// It uses the function-pointer API, whose registration is identified by a fixed function and a client value,
/// so removal matches what was added (a Swift closure passed to the block API may be bridged to a fresh block
/// at each call). The client value is a token into a lock-guarded table: a callback that arrives after its
/// registration was removed finds no token and does nothing.
final class AudioProcessListListener: @unchecked Sendable {
  /// Live registrations by token. Read from CoreAudio's thread and written on the main actor.
  private final class Table: @unchecked Sendable {
    static let shared = Table()
    private let lock = NSLock()
    private var handlers: [UInt: @MainActor () -> Void] = [:]
    private var next: UInt = 1
    func add(_ handler: @escaping @MainActor () -> Void) -> UInt {
      lock.lock(); defer { lock.unlock() }
      let token = next
      next += 1
      handlers[token] = handler
      return token
    }
    func handler(_ token: UInt) -> (@MainActor () -> Void)? {
      lock.lock(); defer { lock.unlock() }
      return handlers[token]
    }
    func retire(_ token: UInt) {
      lock.lock(); defer { lock.unlock() }
      handlers[token] = nil
    }
  }

  private static let callback: AudioObjectPropertyListenerProc = { _, _, _, clientData in
    let token = UInt(bitPattern: clientData)
    DispatchQueue.main.async {
      if let handler = Table.shared.handler(token) { MainActor.assumeIsolated { handler() } }
    }
    return noErr
  }

  private var address = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyProcessObjectList,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
  private var token: UInt?
  /// The status of the add (check seam; `noErr` when registered).
  private(set) var addStatus: OSStatus = noErr
  private let log: @MainActor (String) -> Void

  @MainActor
  init(log: @escaping @MainActor (String) -> Void = { _ in }, handler: @escaping @MainActor () -> Void) {
    self.log = log
    let token = Table.shared.add(handler)
    let status = AudioObjectAddPropertyListener(
      AudioObjectID(kAudioObjectSystemObject), &address, Self.callback,
      UnsafeMutableRawPointer(bitPattern: token))
    addStatus = status
    if status == noErr {
      self.token = token
    } else {
      // Nothing was registered; the launch burst and menu open still apply.
      Table.shared.retire(token)
      log("audio process list listener not added: \(status)")
    }
  }

  /// Removes the registration. Nil when nothing is registered, otherwise the remove status.
  @MainActor
  @discardableResult
  func remove() -> OSStatus? {
    guard let token else { return nil }
    self.token = nil
    // Retire first: from here on a callback already queued for this registration does nothing.
    Table.shared.retire(token)
    let status = AudioObjectRemovePropertyListener(
      AudioObjectID(kAudioObjectSystemObject), &address, Self.callback,
      UnsafeMutableRawPointer(bitPattern: token))
    if status != noErr { log("audio process list listener not removed: \(status)") }
    return status
  }
}
