import Foundation
import SwiftUI
@testable import SoundModel
@testable import EverydayMenu

// The only file that names code the sound spec itself names: the three
// BuiltinBlock cases and the three definition types. Everything else is
// found through the public library session by on-screen title.

enum QMSNames {
    static let blocks: [(name: String, block: BuiltinBlock)] = [
        ("Big space", .bigSpace), ("Old recording", .oldRecording), ("Underwater", .underwater),
    ]

    static func recipes() throws -> [(name: String, sound: any BuiltinSound)] {
        [("Big space", try BigSpace()), ("Old recording", try OldRecording()), ("Underwater", try Underwater())]
    }

    static func kind(_ sound: any BuiltinSound) -> BuiltinBlock { sound.kind }

    static func symbol(_ block: BuiltinBlock) -> String { block.symbol }
    static func tint(_ block: BuiltinBlock) -> Color { block.tint }
}
