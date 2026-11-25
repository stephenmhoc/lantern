import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// Declared in Info.plist (UTImportedTypeDeclarations).
    nonisolated static let gguf = UTType(importedAs: "org.ggml.gguf", conformingTo: .data)
}

/// Copies a model file the user already has (file picker or drag and drop) into Documents, where
/// `ModelStore` finds it by the catalog's file name and size.
nonisolated enum ModelImport {
    enum Failure: LocalizedError {
        case notGGUF(String), unknown(String), wrongSize(String, CatalogModel, Int64), noSpace(Int64)

        var errorDescription: String? {
            switch self {
            case .notGGUF(let name): "“\(name)” isn't a GGUF model file."
            case .unknown(let name): "“\(name)” isn't one of the models Lantern runs. Use one of the files listed in Models."
            case .wrongSize(let name, let model, let size):
                "“\(name)” is \(Self.format(size)), but \(model.name) is \(Self.format(model.bytes)). It may not have finished copying."
            case .noSpace(let needed): "Needs \(Self.format(needed)) free."
            }
        }

        private static func format(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    }

    /// Validates `source` against the catalog and copies it in under the catalog's file name.
    /// Each catalog file has a distinct size, so a renamed file is still recognized. With `move`,
    /// a temporary file (from a drop) is moved instead of copied. Slow for big files: call it off
    /// the main actor.
    static func importFile(at source: URL, move: Bool = false) throws -> CatalogModel {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let name = source.lastPathComponent

        let handle = try FileHandle(forReadingFrom: source)
        let magic = try handle.read(upToCount: 4)
        try? handle.close()
        guard magic == Data("GGUF".utf8) else { throw Failure.notGGUF(name) }

        let size = Int64(try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        guard let model = CatalogModel.files.first(where: { $0.bytes == size }) else {
            if let named = CatalogModel.files.first(where: { $0.filename == name }) { throw Failure.wrongSize(name, named, size) }
            throw Failure.unknown(name)
        }

        let fm = FileManager.default
        let dest = URL.documentsDirectory.appending(path: model.filename)
        if source.standardizedFileURL == dest.standardizedFileURL { return model }
        if let existing = try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize, Int64(existing) == model.bytes {
            return model  // already here
        }
        // Bring it in beside the destination first, so ModelStore never sees a half-copied model
        // as "incomplete" under its real name.
        let temp = fm.temporaryDirectory.appending(path: "import-\(UUID().uuidString).gguf")
        if move, (try? fm.moveItem(at: source, to: temp)) != nil {
            return try finish(model, from: temp, to: dest)
        }
        let free = (try? URL.documentsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage) ?? 0
        guard free >= model.bytes + 500_000_000 else { throw Failure.noSpace(model.bytes + 500_000_000) }
        try fm.copyItem(at: source, to: temp)
        return try finish(model, from: temp, to: dest)
    }

    private static func finish(_ model: CatalogModel, from temp: URL, to dest: URL) throws -> CatalogModel {
        let fm = FileManager.default
        try? fm.removeItem(at: dest)
        do {
            try fm.moveItem(at: temp, to: dest)
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
        return model
    }
}
