import Foundation
import LlamaKit

nonisolated enum Mode: String, Codable, CaseIterable, Identifiable, Sendable {
    case fast, smart, mac
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fast: "Fast"
        case .smart: "Smart"
        case .mac: "Mac"
        }
    }
    var symbol: String {
        switch self {
        case .fast: "hare"
        case .smart: "brain"
        case .mac: "desktopcomputer"
        }
    }
    var isOnDevice: Bool { self != .mac }
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
    /// Stream MoE experts from storage: the file is bigger than the app's memory limit.
    let lazyExperts: Bool

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    private static let hf = "https://huggingface.co"

    static let gemma = CatalogModel(
        id: "gemma-4-e2b-q4",
        name: "Gemma 4 E2B",
        detail: "Google, 4-bit. Quick answers, light on battery.",
        filename: "gemma-4-E2B-it-qat-UD-Q4_K_XL.gguf",
        url: URL(string: "\(hf)/unsloth/gemma-4-E2B-it-qat-GGUF/resolve/main/gemma-4-E2B-it-qat-UD-Q4_K_XL.gguf")!,
        bytes: 2_620_370_976, tier: .fast, minDeviceGB: 6,
        sampling: Sampling(temperature: 1.0, topK: 64, topP: 0.95),  // Google's recommendation
        lazyExperts: false
    )

    // Unsloth's Mainline_Support files: the inkling2_loop layout upstream llama.cpp reads.
    // The repo names them .gguf_file so tools don't mix the layouts; we save them as .gguf.
    private static func inkling(_ quant: String, bytes: Int64, minGB: Int, detail: String) -> CatalogModel {
        CatalogModel(
            id: "inkling-2-mini-\(quant.lowercased())",
            name: "Inkling 2 Mini (\(quant))",
            detail: detail,
            filename: "Inkling-2-Mini-UD-\(quant).gguf",
            url: URL(string: "\(hf)/unsloth/Inkling-2-Mini-GGUF/resolve/main/Mainline_Support/Inkling-2-Mini-UD-\(quant).gguf_file")!,
            bytes: bytes, tier: .smart, minDeviceGB: minGB,
            sampling: Sampling(temperature: 1.0),  // Thinking Machines: no truncation
            lazyExperts: true
        )
    }

    static let inklingQ2 = inkling("Q2_K_XL", bytes: 9_138_716_608, minGB: 12,
                                   detail: "Thinking Machines, 2-bit. Smarter, slower. For 12 GB devices.")
    static let inklingQ3 = inkling("IQ3_XXS", bytes: 11_663_310_784, minGB: 16,
                                   detail: "Thinking Machines, 3-bit. Better answers. For 16 GB devices.")

    static let all = [gemma, inklingQ2, inklingQ3]

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
