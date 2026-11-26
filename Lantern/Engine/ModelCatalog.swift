import Foundation
import LlamaKit

/// Where a chat's answers come from: this device's model, or the Mac. Only `mac` is special;
/// every other value means "this device" (`isOnDevice`), whichever model that is here.
///
/// The raw values are stored in chats and replies, so all five still decode: `fast`, `smart`,
/// `qwen` and `apple` were separate on-device models before each device had exactly one.
/// New chats use `device`; `Conversation.repairModes` moves old ones to it.
nonisolated enum Mode: String, Codable, Sendable {
    case fast, smart, qwen, mac, apple

    /// This device's model.
    static let device = Mode.fast

    var isOnDevice: Bool { self != .mac }
    /// The same place, as one of the two values in use now.
    var current: Mode { isOnDevice ? .device : .mac }
    var symbol: String { isOnDevice ? CatalogModel.deviceSymbol : "desktopcomputer" }
}

/// One file of a model: its weights, its drafter or its vision projector.
nonisolated struct ModelFile: Hashable, Sendable {
    let filename: String
    let url: URL
    let bytes: Int64
}

/// An on-device model Lantern knows how to run, with the settings it needs. A device only ever
/// downloads one: `CatalogModel.device`, the best its memory can run. An older one already on
/// it answers until that's here (`ModelStore.model`).
nonisolated struct CatalogModel: Identifiable, Hashable, Sendable {
    /// Also names the model's saved states (Caches/kv/<chat>/<id>), so it never changes.
    let id: String
    let name: String
    /// Device RAM it needs, as marketed.
    let minDeviceGB: Int
    let weights: ModelFile
    /// The MTP drafter: a small model that guesses the next few tokens for Gemma to check in one
    /// batch. Faster replies, same output. The model runs without it until it's here.
    let drafter: ModelFile
    /// The vision projector, loaded beside the model only when a chat has an image.
    let projector: ModelFile
    let sampling: Sampling
    /// How llama.cpp loads it: context length, KV cache type, lazy embedding tables, batch size.
    let options: ModelOptions

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    /// Everything downloaded for it, weights first.
    var files: [ModelFile] { [weights, drafter, projector] }
    var bytes: Int64 { files.reduce(0) { $0 + $1.bytes } }

    /// Google's QAT checkpoints, Unsloth's dynamic 4-bit, with the drafter and projector from the
    /// same repo. The projector is `mmproj-F16.gguf` there for every size, so it's saved under
    /// the model's name.
    private static func gemma(
        _ size: String, minGB: Int, weights: Int64, drafter: Int64, projector: Int64, options: ModelOptions
    ) -> CatalogModel {
        let repo = "https://huggingface.co/unsloth/gemma-4-\(size)-it-qat-GGUF/resolve/main/"
        func file(_ remote: String, as local: String? = nil, _ bytes: Int64) -> ModelFile {
            ModelFile(filename: local ?? remote, url: URL(string: repo + remote)!, bytes: bytes)
        }
        return CatalogModel(
            id: "gemma-4-\(size.lowercased())-q4",
            name: "Gemma 4 \(size)",
            minDeviceGB: minGB,
            weights: file("gemma-4-\(size)-it-qat-UD-Q4_K_XL.gguf", weights),
            drafter: file("mtp-gemma-4-\(size)-it.gguf", drafter),
            projector: file("mmproj-F16.gguf", as: "gemma-4-\(size)-it-qat-mmproj-F16.gguf", projector),
            sampling: Sampling(temperature: 1.0, topK: 64, topP: 0.95),  // Google's recommendation
            options: options)
    }

    // E2B and E4B have a per-layer embedding table (most of the file) that is read row by row
    // instead of being prefetched at load, and a small cache, so F16 costs little and is faster.
    static let gemmaE2B = gemma(
        "E2B", minGB: 6, weights: 2_620_370_976, drafter: 59_235_648, projector: 985_654_080,
        options: ModelOptions(lazyEmbeddings: true, f16Cache: true))
    static let gemmaE4B = gemma(
        "E4B", minGB: 8, weights: 4_215_695_776, drafter: 59_678_016, projector: 990_372_672,
        options: ModelOptions(lazyEmbeddings: true, f16Cache: true))
    /// Best first.
    static let all = [gemmaE4B, gemmaE2B]

    /// This device's model: the best its memory can run. Devices report a little less than their
    /// marketed RAM, so there's 10% slack. Never a choice the user makes.
    static let device: CatalogModel = {
        #if DEBUG
        // `-model e2b|e4b`: the simulator reports the Mac's memory and runs on the CPU.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-model"), args.indices.contains(i + 1),
           let asked = all.first(where: { $0.name.lowercased().hasSuffix(args[i + 1].lowercased()) }) {
            return asked
        }
        #endif
        let gb = Double(MemoryStats.deviceBytes) / 1_073_741_824
        return all.first { gb >= Double($0.minDeviceGB) * 0.9 } ?? gemmaE2B
    }()

    /// The on-device model's symbol, in the picker and Settings.
    static let deviceSymbol = "iphone"

    /// Files of models earlier versions ran. `ModelStore` deletes them, with the other sizes'
    /// files, once this device's model is here.
    static let retiredFilenames = [
        "Qwen3.5-4B-UD-Q4_K_XL.gguf", "Inkling-2-Mini-UD-Q2_K_XL.gguf", "Inkling-2-Mini-UD-IQ3_XXS.gguf",
        "gemma-4-12B-it-qat-UD-Q4_K_XL.gguf", "mtp-gemma-4-12B-it.gguf", "gemma-4-12B-it-qat-mmproj-F16.gguf",
    ]
}
