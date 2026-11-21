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
  /// Listens for changes to the system's audio-process list. Installed only while a lane is waiting.
  var listenForProcessListChanges: (@escaping @MainActor () -> Void) -> (@MainActor () -> Void)
  /// Listens for application launches; the handler receives the launched app's bundle identifier.
  var listenForLaunches: (@escaping @MainActor (String) -> Void) -> (@MainActor () -> Void)
  /// Runs `work` once after `delay` seconds on the main actor; the result cancels it.
  var schedule: (TimeInterval, @escaping @MainActor () -> Void) -> (@MainActor () -> Void)

  static func system() -> PlaybackWakeEnvironment {
    PlaybackWakeEnvironment(
      listenForProcessListChanges: { handler in
        let listener = AudioProcessListListener(handler: handler)
        return { listener.remove() }
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

/// A CoreAudio property listener on the system object's process list. Added at `init`, removed by
/// `remove()` (idempotent); the controller creates one only while a lane is waiting.
final class AudioProcessListListener: @unchecked Sendable {
  private var address = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyProcessObjectList,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
  private let queue = DispatchQueue.main
  private var block: AudioObjectPropertyListenerBlock?

  @MainActor
  init(handler: @escaping @MainActor () -> Void) {
    let block: AudioObjectPropertyListenerBlock = { _, _ in
      MainActor.assumeIsolated { handler() }
    }
    let status = AudioObjectAddPropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
    // If the add failed there is nothing to remove; the launch burst and menu open still apply.
    self.block = status == noErr ? block : nil
  }

  @MainActor
  func remove() {
    guard let block else { return }
    self.block = nil
    AudioObjectRemovePropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
  }
}
