// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "tap-n-filter",
    platforms: [
        // 14.4 is the floor declared in ADR-005 and is the OS version that
        // introduced the Core Audio process tap APIs we depend on.
        .macOS("14.4")
    ],
    products: [
        .executable(name: "tap-n-filter", targets: ["tap-n-filter"]),
        .executable(name: "tap-n-filter-eartest", targets: ["tap-n-filter-eartest"]),
        .executable(name: "tap-n-filter-a11y-dump", targets: ["tap-n-filter-a11y-dump"]),
        .executable(name: "tap-n-filter-poweron-probe", targets: ["tap-n-filter-poweron-probe"]),
        .library(name: "Capture", targets: ["Capture"]),
        .library(name: "Graph", targets: ["Graph"]),
        .library(name: "Effects", targets: ["Effects"]),
        .library(name: "Presets", targets: ["Presets"]),
        .library(name: "ViewModel", targets: ["ViewModel"]),
        .library(name: "UI", targets: ["UI"])
    ],
    targets: [
        .target(name: "NativeTestSupport", path: "Tests/NativeTestSupport"),
        .executableTarget(name: "tnf-output-check", dependencies: ["PlaybackOutput", "Capture", "OutputGate", "PlaybackRenderBridge", "SoundModel"], path: "Tests/PlaybackOutputChecks"),
        .target(name: "PlaybackDSP", dependencies: ["FixedRender"], publicHeadersPath: "include", cxxSettings: [.unsafeFlags(["-std=c++20"])]),
        .target(name: "PlaybackRenderBridge", dependencies: ["SoundModel", "PlaybackDSP"], swiftSettings: [.unsafeFlags(["-swift-version", "6"])]),
        .target(name: "PlaybackOutput", dependencies: ["Capture", "OutputGate", "PlaybackDSP", "PlaybackRenderBridge", "PlaybackLifecycle", "PlaybackRuntime", "PlaybackRuntimeCaptureAdapters", "SoundModel"], linkerSettings: [.linkedFramework("Accelerate")]),
        .target(name: "PlaybackLifecycle", dependencies: ["PlaybackRuntime", "SoundModel"]),
        .executableTarget(name: "tnf-playback-lifecycle-check", dependencies: ["PlaybackLifecycle", "PlaybackRuntime", "SoundModel"], path: "Tests/PlaybackLifecycleChecks"),
        .target(name: "OutputGate", path: "Sources/OutputGate", publicHeadersPath: "include", cxxSettings: [.unsafeFlags(["-std=c++20"])]),
        .executableTarget(name: "tnf-output-gate-check", dependencies: ["OutputGate"], path: "Tests/OutputGateChecks", cxxSettings: [.unsafeFlags(["-std=c++20"])]),
        .executableTarget(name: "tnf-menu-check", dependencies: ["SoundModel", "SessionStore", "EverydayMenu"], path: "Sources/MenuFixture", resources: [.copy("Resources")]),
        .target(name: "FixedRender", path: "Sources/FixedRender", publicHeadersPath: "include",
                cxxSettings: [.unsafeFlags(["-std=c++20", "-fno-objc-arc"])],
                linkerSettings: [.linkedFramework("AVFAudio"), .linkedFramework("Foundation"), .linkedFramework("AudioToolbox")]),
        .target(name: "EverydayMenu", dependencies: ["SoundModel"], path: "Sources/EverydayMenu"),
        .target(name: "SessionStore", dependencies: ["SoundModel"], path: "Sources/SessionStore"),
        .target(name: "SessionStoreCheckCore", dependencies: ["SoundModel", "SessionStore"], path: "Tests/SessionStoreChecks"),
        .executableTarget(name: "tnf-session-check", dependencies: ["SessionStoreCheckCore"], path: "Tests/SessionStoreDriver"),
        .testTarget(name: "SessionStoreTests", dependencies: ["SessionStoreCheckCore"], path: "Tests/SessionStoreTests"),
        .testTarget(name: "MappingOwnerTests", dependencies: ["SoundModel", "SessionStore"], path: "Tests/MappingOwnerChecks"),
        .testTarget(name: "ChoiceOptionTests", dependencies: ["SoundModel", "SessionStore"], path: "Tests/ChoiceOptionChecks"),
        .testTarget(name: "MenuPerformanceTests", dependencies: ["tap-n-filter", "SoundModel", "SessionStore"], path: "Tests/MenuPerformanceChecks"),
        .testTarget(name: "CompatibilityWitnessTests", dependencies: ["SoundModel"], path: "Tests/CompatibilityWitnessChecks", resources: [.copy("Fixtures")]),
        .target(name: "PlaybackRuntime", path: "Sources/PlaybackRuntime", swiftSettings: [.unsafeFlags(["-swift-version", "6"])]),
        .target(name: "PlaybackRuntimeCaptureAdapters", dependencies: ["PlaybackRuntime", "Capture"],
                path: "Sources/PlaybackRuntimeCaptureAdapters", swiftSettings: [.unsafeFlags(["-swift-version", "6"])]),
        .target(name: "SoundModel", path: "Sources/SoundModel"),
        .testTarget(name: "OptionControlTests", dependencies: ["SoundModel", "SessionStore", "EverydayMenu", "PlaybackRenderBridge"], path: "Tests/OptionControlChecks"),
        .testTarget(
            name: "SoundModelTests",
            dependencies: ["SoundModel"],
            path: "Tests/SoundModelTests",
            exclude: ["ContractMain.swift"],
            resources: [.copy("Fixtures")]
        ),
        .executableTarget(
            name: "tap-n-filter",
            dependencies: ["Capture", "SoundModel", "SessionStore", "EverydayMenu", "PlaybackOutput", "PlaybackRuntime", "PlaybackRuntimeCaptureAdapters"],
            path: "Sources/tap-n-filter",
            resources: [
                .copy("Resources")
            ]
        ),
        .executableTarget(
            name: "tap-n-filter-eartest",
            dependencies: ["Graph", "Effects", "Presets"],
            path: "Sources/EarTestHarness"
        ),
        .executableTarget(
            name: "tap-n-filter-a11y-dump",
            dependencies: ["Capture", "Graph", "Effects", "Presets", "ViewModel", "UI"],
            path: "Sources/AccessibilityDump"
        ),
        .executableTarget(
            name: "tap-n-filter-poweron-probe",
            dependencies: ["Capture", "Graph", "Effects", "Presets", "ViewModel"],
            path: "Sources/PowerOnProbe"
        ),
        .target(
            name: "Capture",
            path: "Sources/Capture"
        ),
        .target(
            name: "Graph",
            dependencies: ["Effects"],
            path: "Sources/Graph"
        ),
        .target(
            name: "Effects",
            path: "Sources/Effects"
        ),
        .target(
            name: "Presets",
            dependencies: ["Graph", "Effects"],
            path: "Sources/Presets",
            resources: [
                .copy("Resources/Presets")
            ]
        ),
        .target(
            name: "ViewModel",
            dependencies: ["Capture", "Graph", "Effects", "Presets"],
            path: "Sources/ViewModel"
        ),
        .target(
            name: "UI",
            dependencies: ["ViewModel", "Capture", "Graph", "Effects", "Presets"],
            path: "Sources/UI"
        ),
        .testTarget(
            name: "CaptureTests",
            dependencies: ["Capture", "NativeTestSupport"],
            path: "Tests/CaptureTests"
        ),
        .testTarget(
            // Gated behind RUN_INTEGRATION_TESTS=1 at runtime (see
            // RealTapIntegrationTests.swift). Builds in every run so the
            // code path is exercised by the compiler; the tests
            // themselves XCTSkip when the env var is unset.
            name: "CaptureIntegrationTests",
            dependencies: ["Capture"],
            path: "Tests/CaptureIntegrationTests"
        ),
        .testTarget(
            name: "GraphTests",
            dependencies: ["Graph", "Effects", "NativeTestSupport"],
            path: "Tests/GraphTests"
        ),
        .testTarget(
            name: "EffectsTests",
            dependencies: ["Effects", "NativeTestSupport"],
            path: "Tests/EffectsTests"
        ),
        .testTarget(
            name: "PresetsTests",
            dependencies: ["Presets", "Graph", "Effects"],
            path: "Tests/PresetsTests"
        ),
        .testTarget(
            name: "ViewModelTests",
            dependencies: ["ViewModel", "Capture", "Graph", "Effects", "Presets", "NativeTestSupport"],
            path: "Tests/ViewModelTests"
        ),
        .testTarget(
            name: "UISnapshotTests",
            dependencies: ["UI", "ViewModel", "Capture", "Graph", "Effects", "Presets", "NativeTestSupport"],
            path: "Tests/UISnapshotTests",
            resources: [
                .copy("__Snapshots__")
            ]
        ),
        .testTarget(
            // The XCTest validates the committed JSON artifact and source-
            // level `.accessibilityLabel(_:)` discipline. The in-process
            // AppKit walk lives in the AccessibilityDump executable (ADR-
            // 011), so this target has no UI/ViewModel dependencies.
            name: "AccessibilityTreeTests",
            dependencies: [],
            path: "Tests/AccessibilityTreeTests"
        )
    ]
)
