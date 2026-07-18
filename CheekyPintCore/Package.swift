// swift-tools-version: 6.0
import PackageDescription

// CheekyPintCore holds all Foundation-only domain logic so it can be unit-tested
// on macOS (via `swift test`) without Xcode or an iOS simulator. The iOS app target
// links this package and never re-implements counting, privacy, or validation rules.
let package = Package(
    name: "CheekyPintCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v13)
    ],
    products: [
        .library(name: "CheekyPintCore", targets: ["CheekyPintCore"])
    ],
    targets: [
        .target(
            name: "CheekyPintCore",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        // A dependency-free smoke harness that verifies the domain logic without XCTest,
        // so the core can be checked on a machine that only has the Swift toolchain
        // (`swift run corecheck`). The full XCTest suite in Tests/ runs under Xcode/CI.
        .executableTarget(
            name: "corecheck",
            dependencies: ["CheekyPintCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "CheekyPintCoreTests",
            dependencies: ["CheekyPintCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
