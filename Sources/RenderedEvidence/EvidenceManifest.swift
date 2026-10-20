import Foundation

/// Versioned evidence metadata; optional fields are explicit JSON nulls.
struct EvidenceManifest: Encodable {
    let schemaVersion = 1
    let source: Source
    let environment: Environment
    let limits = Limits()
    let images: [Image]

    struct Source: Encodable {
        let checkoutSHA: String
        let eventName: String
        let ref: String
        let prHeadSHA: Nullable<String>
        let baseSHA: Nullable<String>
        let baseRef: Nullable<String>
    }

    struct Environment: Encodable {
        let macOS: String
        let swift: String
        let xcode: String
    }

    struct Limits: Encodable {
        let fakeCapture = true
        let isolatedDefaults = true
        let audioStarted = false
        let actualMenuBarExtra = false
        let manualLayoutGateSatisfied = false
        let renderer = "NSHostingView.cacheDisplay in an offscreen NSWindow"
        let visualApproval = "Required: root inspects downloaded source-backed images"
        let sourceScope = "Only this checkout; not a composition of unmerged feature branches"
    }

    struct Image: Encodable {
        let file: String
        let state: String
        let theme: String
        let widthPoints: Double
        let fittingHeightPoints: Double
        let pixelWidth: Int
        let pixelHeight: Int
        let scale = 1
        let preparedViewIdentity: String
        let renderedViewIdentity: String
        let observed: Observed
        let backgroundRGB: [Double]
        let presentation = "Opaque sRGB, native cache composited over explicit theme background"
    }

    struct Observed: Encodable {
        let captureState: String
        let engineRunning: Bool
        let showSettings: Bool
        let showDebugPanel: Bool
        let expandedEffectID: Nullable<String>
        let expandedEffectType: Nullable<String>
        let eqNodeID: String
        let errorMessage: Nullable<String>
        let sourceDisplayName: Nullable<String>
    }
}

/// A nonoptional wrapper ensures Encodable does not omit unavailable metadata.
struct Nullable<Value: Encodable>: Encodable {
    let value: Value?

    init(_ value: Value?) { self.value = value }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let value {
            try container.encode(value)
        } else {
            try container.encodeNil()
        }
    }
}

enum EvidenceError: Error {
    case invalid(String)
}
