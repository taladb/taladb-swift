// swift-tools-version:5.9
import PackageDescription

// The TalaDB engine release whose TalaDBFFI.xcframework this package links on
// Apple platforms. .github/workflows/engine-bump.yml rewrites these two lines
// when the engine publishes. While they are empty, Apple builds use
// engine/TalaDBFFI.xcframework, built from an engine checkout by
// scripts/build-engine.sh on a Mac.
let engineURL = "https://github.com/taladb/taladb/releases/download/v0.13.0/TalaDBFFI-0.13.0.xcframework.zip"
let engineChecksum = "6f4bb87208f509bfae94aaccf459dc5c4d3d26864633ed5656000e338ff01b3c"

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
