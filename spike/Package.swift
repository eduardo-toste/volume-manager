// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "spike",
    platforms: [.macOS("14.2")],
    products: [.executable(name: "vmctl", targets: ["vmctl"])],
    targets: [
        .target(name: "CAtomics"),
        .target(name: "SpikeCore"),
        .executableTarget(name: "vmctl", dependencies: ["SpikeCore", "CAtomics"]),
        .testTarget(name: "SpikeCoreTests", dependencies: ["SpikeCore"]),
    ]
)
