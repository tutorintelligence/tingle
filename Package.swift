// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "tingle",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.5.0")
    ],
    targets: [
        .target(
            name: "TingleCore",
            dependencies: [.product(name: "TOMLKit", package: "TOMLKit")],
            path: "Sources/TingleCore",
            resources: [
                // Device event-engine payload, shipped to TINGDISK as main.py
                // by Flasher. Must be kept byte-identical with the source of
                // truth at device/tingle_main.py.
                .copy("Resources/tingle_main.py")
            ]
        ),
        .executableTarget(
            name: "tingle",
            dependencies: ["TingleCore"],
            path: "Sources/tingle"
        ),
        // Dependency-free test runner (no XCTest: runs with bare
        // CommandLineTools locally and in CI alike): swift run tingle-tests
        .executableTarget(
            name: "tingle-tests",
            dependencies: ["TingleCore"],
            path: "Tests/tingle-tests"
        )
    ]
)
