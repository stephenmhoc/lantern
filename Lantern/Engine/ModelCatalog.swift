import Foundation
import LlamaKit

/// Where a chat's answers come from. The raw values are stored in chats and used in links and
/// widgets, so they stay as they were: `smart` was Inkling on the device and is now Gemma 4 E4B.
/// The declaration order is the picker's and the ⌘1–5 shortcuts' order, not part of what's stored:
/// `apple` (Apple Intelligence's on-device model, iOS 26+) came last, so ⌘1–4 kept their modes.
nonisolated enum Mode: String, Codable, CaseIterable, Identifiable, Sendable {
    case fast, smart, qwen, mac, apple
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fast: "Gemma 4 E2B"
        case .smart: "Gemma 4 E4B"
        case .qwen: "Qwen 3.5 4B"
        case .mac: "Mac"
        // The feature's own name, as the user turns it on in Settings. Not in Siri's options
        // (`ChatModeChoice`), which may not name Apple trademarks.
        case .apple: "Apple Intelligence"
        }
    }
    /// On this device or on the Mac: the picker shows where it runs, not what the model is like.
    var symbol: String { self == .apple ? "apple.intelligence" : isOnDevice ? "cpu" : "desktopcomputer" }
    var isOnDevice: Bool { self != .mac }
    /// Runs in Lantern through llama.cpp, from a downloaded file: on device, but not Apple's model,
    /// which runs in a system process and has no file, cache or saved state of Lantern's.
    var usesLlama: Bool { self != .mac && self != .apple }
    /// Models whose web search is declared in their system turn and answered while they generate
    /// (`LlamaModel.generate(search:)`). The computer is offered the tool per request instead.
    var searchesOnDevice: Bool { usesLlama }
}

/// An on-device model Lantern knows how to run, with the settings it needs.
nonisolated struct CatalogModel: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let detail: String
    let filename: String
    let url: URL
    let bytes: Int64
    let tier: Mode
    /// Device RAM this quant is meant for. Below it the model may still run, slowly.
    let minDeviceGB: Int
    let sampling: Sampling
    /// How llama.cpp loads it: context length, KV cache type, lazy embedding tables.
    let options: ModelOptions

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    private static let hf = "https://huggingface.co"

    // Google's QAT checkpoints, Unsloth's dynamic 4-bit. Both have a per-layer embedding table
    // (most of the file) that is read row by row instead of being prefetched at load, and a small
    // cache, so F16 costs little and speeds up generation.
    private static func gemma(_ size: String, bytes: Int64, minGB: Int, detail: String) -> CatalogModel {
        CatalogModel(
            id: "gemma-4-\(size.lowercased())-q4",
            name: "Gemma 4 \(size)",
            detail: detail,
            filename: "gemma-4-\(size)-it-qat-UD-Q4_K_XL.gguf",
            url: URL(string: "\(hf)/unsloth/gemma-4-\(size)-it-qat-GGUF/resolve/main/gemma-4-\(size)-it-qat-UD-Q4_K_XL.gguf")!,
            bytes: bytes, tier: size == "E2B" ? .fast : .smart, minDeviceGB: minGB,
            sampling: Sampling(temperature: 1.0, topK: 64, topP: 0.95),  // Google's recommendation
            options: ModelOptions(lazyEmbeddings: true, f16Cache: true)
        )
    }

    private static func vision(for size: String, bytes: Int64, minGB: Int) -> CatalogModel {
        CatalogModel(
            id: "gemma-4-\(size.lowercased())-mmproj",
            name: "Image reading for Gemma 4 \(size)",
            detail: "Lets Gemma 4 \(size) see photos and screenshots you attach.",
            filename: "gemma-4-\(size)-it-qat-mmproj-F16.gguf",
            url: URL(string: "\(hf)/unsloth/gemma-4-\(size)-it-qat-GGUF/resolve/main/mmproj-F16.gguf")!,
            bytes: bytes, tier: size == "E2B" ? .fast : .smart, minDeviceGB: minGB,
            sampling: Sampling(temperature: 1.0), options: ModelOptions()
        )
    }

    static let gemma = gemma("E2B", bytes: 2_620_370_976, minGB: 6,
                             detail: "Google, 4-bit. Quick answers, light on battery.")
    static let gemmaE4B = gemma("E4B", bytes: 4_215_695_776, minGB: 8,
                                detail: "Google, 4-bit. Better answers, a little slower. For 8 GB devices.")

    // Unsloth's dynamic 4-bit. A hybrid model (Gated DeltaNet layers with one attention layer in
    // four), so its cache can't be rewound, only appended to, restored or cleared; the attention
    // cache is small, so F16 costs little. No per-layer embedding table, so nothing to read lazily.
    // 2.9 GB of weights plus the cache and llama.cpp's buffers is too much beside iOS on a 6 GB
    // phone (E2B, 2.6 GB, is already the limit there), so it's for 8 GB devices like E4B.
    // Sampling is Qwen's card's (`Sampling.qwen35`, presence penalty 1.5): replies pick the set for
    // thinking on or off through `sampling(thinking:)`; `sampling` is the one for off.
    static let qwen = CatalogModel(
        id: "qwen-3.5-4b-q4",
        name: "Qwen 3.5 4B",
        detail: "Alibaba, 4-bit. Strong reasoning, and can think before it answers. For 8 GB devices.",
        filename: "Qwen3.5-4B-UD-Q4_K_XL.gguf",
        url: URL(string: "\(hf)/unsloth/Qwen3.5-4B-GGUF/resolve/main/Qwen3.5-4B-UD-Q4_K_XL.gguf")!,
        bytes: 2_912_109_728, tier: .qwen, minDeviceGB: 8,
        sampling: .qwen35(thinking: false),
        options: ModelOptions(lazyEmbeddings: false, f16Cache: true)
    )

    static let all = [gemma, gemmaE4B, qwen]

    /// Each Gemma's vision projector, from the same QAT repo. An optional extra download, loaded
    /// beside its model only when a chat has an image (it costs about 1 GB of memory).
    static let gemmaVision = vision(for: "E2B", bytes: 985_654_080, minGB: 6)
    static let gemmaE4BVision = vision(for: "E4B", bytes: 990_372_672, minGB: 8)

    /// Each Gemma's MTP drafter (`ModelOptions.draftModel`), from the same QAT repo: a 60 MB model
    /// that guesses the next few tokens for Gemma to check in one batch, which makes answers about
    /// a third faster without changing them. Not an option the user sees: `ModelStore` downloads it
    /// with its Gemma (or quietly later, when online) and deletes it with it, and Gemma runs without
    /// one until it's here. Never a row of its own on the Models page.
    private static func drafter(for size: String, bytes: Int64, minGB: Int) -> CatalogModel {
        CatalogModel(
            id: "gemma-4-\(size.lowercased())-mtp",
            name: "Drafter for Gemma 4 \(size)",
            detail: "Makes Gemma 4 \(size) answer faster.",
            filename: "mtp-gemma-4-\(size)-it.gguf",
            url: URL(string: "\(hf)/unsloth/gemma-4-\(size)-it-qat-GGUF/resolve/main/mtp-gemma-4-\(size)-it.gguf")!,
            bytes: bytes, tier: size == "E2B" ? .fast : .smart, minDeviceGB: minGB,
            sampling: Sampling(temperature: 1.0), options: ModelOptions()
        )
    }

    static let gemmaDrafter = drafter(for: "E2B", bytes: 59_235_648, minGB: 6)
    static let gemmaE4BDrafter = drafter(for: "E4B", bytes: 59_678_016, minGB: 8)
    static let drafters = [gemmaDrafter, gemmaE4BDrafter]

    /// Files that go with a model rather than being one: not offered as a mode's model.
    static let extras = [gemmaVision, gemmaE4BVision]
    /// Everything `ModelStore` downloads and tracks.
    static let files = all + extras + drafters
    var isExtra: Bool { Self.extras.contains(self) || Self.drafters.contains(self) }

    /// The drafter that comes with this model, if there is one.
    var drafter: CatalogModel? {
        switch self {
        case .gemma: .gemmaDrafter
        case .gemmaE4B: .gemmaE4BDrafter
        default: nil
        }
    }

    /// The sampling for a reply: Qwen 3.5 has its own settings for thinking on and off (with its
    /// presence penalty); every other model always uses `sampling`.
    func sampling(thinking: Thinking) -> Sampling {
        tier == .qwen ? .qwen35(thinking: thinking != .off) : sampling
    }

    /// The projector that lets this model see images, if there is one.
    var projector: CatalogModel? {
        switch self {
        case .gemma: .gemmaVision
        case .gemmaE4B: .gemmaE4BVision
        default: nil
        }
    }

    /// Files earlier builds downloaded that nothing uses any more (Inkling 2 Mini, dropped as too
    /// big and slow for a phone). Readiness offers to delete them; nothing does it unasked.
    static let retiredFilenames = ["Inkling-2-Mini-UD-Q2_K_XL.gguf", "Inkling-2-Mini-UD-IQ3_XXS.gguf"]

    /// Devices report a little less than their marketed RAM, so allow 10% slack.
    static func fits(_ model: CatalogModel) -> Bool {
        Double(MemoryStats.deviceBytes) >= Double(model.minDeviceGB) * 0.9 * 1_073_741_824
    }

    /// The best quant of a tier for this device: a downloaded one that fits, else any downloaded
    /// one, else the one to download.
    static func preferred(for tier: Mode, downloaded: Set<String>) -> CatalogModel? {
        let candidates = all.filter { $0.tier == tier }.sorted { $0.minDeviceGB > $1.minDeviceGB }
        let fitting = candidates.filter(fits)
        return fitting.first { downloaded.contains($0.id) }
            ?? candidates.first { downloaded.contains($0.id) }
            ?? fitting.first ?? candidates.last
    }
}
