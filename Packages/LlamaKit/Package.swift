// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LlamaKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "LlamaKit", targets: ["LlamaKit"]),
    ],
    targets: [
        // Fetched by scripts/fetch-llama.sh (the pinned release's xcframework).
        .binaryTarget(name: "llama", path: "../../Vendor/build-apple/llama.xcframework"),
        // llama.xcframework has no Mac Catalyst slice, and a Mac never runs a model of its own:
        // there LlamaKit is its plain types and a LlamaModel that can't load (`#if canImport(llama)`).
        .target(name: "LlamaKit", dependencies: [
            .target(name: "llama", condition: .when(platforms: [.iOS, .macOS])),
        ]),
        // Mac-only smoke test: loads a GGUF through the same wrapper the app uses.
        .executableTarget(name: "lantern-smoke", dependencies: ["LlamaKit"]),
    ]
)
