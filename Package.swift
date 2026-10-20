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
        .executable(name: "tap-n-filter-render-evidence", targets: ["tap-n-filter-render-evidence"]),
        .library(name: "Capture", targets: ["Capture"]),
        .library(name: "Graph", targets: ["Graph"]),
        .library(name: "Effects", targets: ["Effects"]),
        .library(name: "Presets", targets: ["Presets"]),
        .library(name: "ViewModel", targets: ["ViewModel"]),
        .library(name: "UI", targets: ["UI"])
    ],
    targets: [
        .executableTarget(
            name: "tap-n-filter",
            dependencies: ["Capture", "Graph", "Effects", "Presets", "ViewModel", "UI"],
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
        .executableTarget(
            name: "tap-n-filter-render-evidence",
            dependencies: ["Capture", "Graph", "Effects", "ViewModel", "UI"],
            path: "Sources/RenderedEvidence"
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
            dependencies: ["Capture"],
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
            dependencies: ["Graph", "Effects"],
            path: "Tests/GraphTests"
        ),
        .testTarget(
            name: "EffectsTests",
            dependencies: ["Effects"],
            path: "Tests/EffectsTests"
        ),
        .testTarget(
            name: "PresetsTests",
            dependencies: ["Presets", "Graph", "Effects"],
            path: "Tests/PresetsTests"
        ),
        .testTarget(
            name: "ViewModelTests",
            dependencies: ["ViewModel", "Capture", "Graph", "Effects", "Presets"],
            path: "Tests/ViewModelTests"
        ),
        .testTarget(
            name: "UISnapshotTests",
            dependencies: ["UI", "ViewModel", "Capture", "Graph", "Effects", "Presets"],
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
