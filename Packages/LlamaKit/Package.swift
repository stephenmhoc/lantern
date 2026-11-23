// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LlamaKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "LlamaKit", targets: ["LlamaKit"]),
    ],
    targets: [
        // Fetched by scripts/fetch-llama.sh, pinned to a build with the Inkling loop fix (PR #32704).
        .binaryTarget(name: "llama", path: "../../Vendor/build-apple/llama.xcframework"),
        .target(name: "LlamaKit", dependencies: ["llama"]),
        // Mac-only smoke test: loads a GGUF through the same wrapper the app uses.
        .executableTarget(name: "lantern-smoke", dependencies: ["LlamaKit"]),
    ]
)
