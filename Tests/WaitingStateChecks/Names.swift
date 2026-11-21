// The only file in these checks that names the product's waiting-state code. If a name changes in the
// product, change it here and nowhere else.

import CoreAudio
import Foundation
import PlaybackLifecycle
import PlaybackRuntime
import SoundModel

@testable import EverydayMenu
@testable import PlaybackOutput

/// What the checks need to know about one card's lane, independent of the product's enum.
enum Activity: Equatable { case running, waiting, other, absent }

typealias LaneMaker = (ListeningRenderAssignment, @escaping @MainActor (LifecycleObservation) -> Void)
  -> (PlaybackCaptureFactory, PlaybackRuntime)

@MainActor
enum Product {
  // MARK: Controller

  /// The real controller with scripted lanes and scripted wake-ups.
  static func makeController(lane: @escaping LaneMaker, events: WakeEvents, clock: ManualClock)
    -> PlaybackController
  {
    let wake = PlaybackWakeEnvironment(
      listenForProcessListChanges: { handler in events.installListListener(handler) },
      listenForLaunches: { handler in events.installLaunchListener(handler) },
      schedule: { delay, work in clock.schedule(after: delay, work) })
    let controller = PlaybackController(testingLane: lane, wake: wake)
    // A testing lane has no NativePlaybackSink, so output readiness is scripted.
    controller.sinkReadyForTesting = { _ in true }
    return controller
  }

  /// The lane state as the controller prints it. Existing seam; the new state prints as "waiting".
  static func laneState(_ controller: PlaybackController, _ id: UUID) -> String? {
    controller.laneStateForTesting(id)
  }

  static let waitingState = "waiting"

  /// Whether a wake-up is owed to the lane (false when there is no such lane).
  static func owed(_ controller: PlaybackController, _ id: UUID) -> Bool { controller.owedForTesting(id) }

  static func activity(_ controller: PlaybackController, _ id: UUID) -> Activity {
    switch controller.laneActivities[id] {
    case .running?: .running
    case .waiting?: .waiting
    case .other?: .other
    case nil: .absent
    }
  }

  /// The manual retry: what App.swift calls when the menu opens.
  static func menuOpened(_ controller: PlaybackController) { controller.menuOpened() }

  /// Hook (asked for): awaited inside a lane start's task before it enters the runtime, ahead of any
  /// check the controller makes there, so a check can stop or shut down while a start is queued.
  static func beforeStartEntersRuntime(
    _ controller: PlaybackController, _ hold: @escaping (UUID) async -> Void
  ) {
    controller.beforeStartEntersRuntimeForTesting = hold
  }

  /// The real process-list listener on the system audio object: add, remove, remove again.
  /// Hook (asked for): `addStatus` is the add call's status, and `remove()` returns the remove call's
  /// status, or nil when there is nothing registered to remove.
  static func realListenerAddAndRemove() -> (add: OSStatus, remove: OSStatus?, again: OSStatus?) {
    let listener = AudioProcessListListener(handler: {})
    let add = listener.addStatus
    let remove = listener.remove()
    let again = listener.remove()
    return (add, remove, again)
  }

  /// The product's fold window and launch burst, checked against the expected values in cases 7 and 4.
  static var productFoldWindow: TimeInterval { PlaybackWakeSchedule.listFold }
  static var productLaunchBurst: [TimeInterval] { PlaybackWakeSchedule.launchBurst }

  // MARK: Icon rule (EverydayMenu)

  typealias Icon = MenuIconSettle

  /// A card's icon as first shown. `running` nil means the card has no lane information.
  static func makeIcon(on: Bool, running: Bool?) -> Icon { MenuIconSettle(on: on, running: running) }
  static func updateIcon(_ icon: inout Icon, on: Bool, running: Bool?, now: TimeInterval) {
    icon.update(on: on, running: running, now: now)
  }
  static func isColoured(_ icon: Icon) -> Bool { icon.isColoured }
  static var iconDelay: TimeInterval { MenuIconSettle.delay }
  static var iconFade: TimeInterval { MenuIconSettle.fade }

  /// The saturation and opacity the card view applies.
  static func iconTone(_ icon: Icon) -> (saturation: Double, opacity: Double) {
    (icon.saturation, icon.opacity)
  }

  // MARK: Accessibility value (one value, "not playing", for a waiting card)

  /// The value a card's app name is given, through the same mapping the app uses for its cards.
  static func accessibilityValue(_ activity: Activity) -> String? {
    let phase: MenuLaneActivity.Phase =
      activity == .running ? .running : activity == .waiting ? .waiting : .other
    let id = UUID()
    return MenuLaneActivity.cards([id: phase], bundles: [id: "test.card"])[id]?.accessibilityValue
  }
  static var accessibilityValueRunning: String? { MenuLaneActivity.running.accessibilityValue }
  static var accessibilityValueNotRunning: String? { MenuLaneActivity.notRunning.accessibilityValue }
}
