// swift-tools-version: 6.0
import PackageDescription

/// Strict warnings: every warning is an error in release builds (SPEC 12.7).
let strictSettings: [SwiftSetting] = [
    .unsafeFlags(["-warnings-as-errors"], .when(configuration: .release))
]

let package = Package(
    name: "VolumeManager",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "VolumeManager", targets: ["VolumeManager"]),
        .executable(name: "vmctl", targets: ["vmctl"]),
    ],
    // No external dependencies yet. KeyboardShortcuts (exact version) returns with the hotkeys
    // milestone, once Xcode (SwiftUI macro plugins) is available.
    dependencies: [],
    targets: [
        // The only C code allowed in the project: a header, no logic (SPEC 12.9.2).
        .target(name: "CSystemShims"),
        .target(name: "VolumeCore", swiftSettings: strictSettings),
        .target(
            name: "VolumeAudio",
            dependencies: ["VolumeCore"],
            swiftSettings: strictSettings
        ),
        .target(
            name: "VolumeSystem",
            dependencies: [
                "VolumeCore",
                "CSystemShims",
            ],
            swiftSettings: strictSettings
        ),
        .target(
            name: "VolumeUI",
            dependencies: ["VolumeCore"],
            swiftSettings: strictSettings
        ),
        // Composition root: the only place that knows every module.
        .executableTarget(
            name: "VolumeManager",
            dependencies: ["VolumeCore", "VolumeAudio", "VolumeSystem", "VolumeUI"],
            swiftSettings: strictSettings
        ),
        // Development tool; never shipped inside Volume.app (SPEC 12.9.6).
        .executableTarget(
            name: "vmctl",
            dependencies: ["VolumeCore"],
            swiftSettings: strictSettings
        ),
        .testTarget(name: "VolumeCoreTests", dependencies: ["VolumeCore"]),
        .testTarget(name: "VolumeAudioTests", dependencies: ["VolumeAudio", "VolumeCore"]),
        .testTarget(name: "VolumeSystemTests", dependencies: ["VolumeSystem", "VolumeCore"]),
    ],
    swiftLanguageModes: [.v6]
)
