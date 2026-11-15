// swift-tools-version:5.9
import PackageDescription

// The TalaDB engine release whose TalaDBFFI.xcframework this package links on
// Apple platforms. .github/workflows/engine-bump.yml rewrites these two lines
// when the engine publishes. While they are empty, Apple builds use
// engine/TalaDBFFI.xcframework, built from an engine checkout by
// scripts/build-engine.sh on a Mac.
let engineURL = "https://github.com/taladb/taladb/releases/download/v0.13.1/TalaDBFFI-0.13.1.xcframework.zip"
let engineChecksum = "d3f5b22a8335934b0d5d5df848ec9513b331a75e439ed892a5702c58d8b68589"

#if os(Linux)
    // On Linux the engine is a system library: scripts/build-engine.sh stages the
    // header and libtaladb_ffi.so in engine/, and scripts/test-linux.sh points the
    // linker at it. This is how CI and non-Apple contributors run the test suite.
    let engine: Target = .systemLibrary(name: "TalaDBFFI", path: "Sources/TalaDBFFI")
#else
    let engine: Target =
        engineURL.isEmpty
        ? .binaryTarget(name: "TalaDBFFI", path: "engine/TalaDBFFI.xcframework")
        : .binaryTarget(name: "TalaDBFFI", url: engineURL, checksum: engineChecksum)
#endif

let package = Package(
    name: "TalaDB",
    platforms: [.iOS(.v13), .macOS(.v10_15)],
    products: [
        .library(name: "TalaDB", targets: ["TalaDB"])
    ],
    targets: [
        engine,
        .target(
            name: "TalaDB",
            dependencies: ["TalaDBFFI"],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "TalaDBTests",
            dependencies: ["TalaDB"],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
    ]
)
