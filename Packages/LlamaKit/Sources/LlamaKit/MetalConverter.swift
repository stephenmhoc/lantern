import Foundation
import llama

/// Rewrites the tensors of a GGUF that llama.cpp's Metal backend can't run into a type it can.
///
/// Unsloth's Inkling quants store some MoE expert tensors (`ffn_down_exps`) as NVFP4. Metal has no
/// NVFP4 matmul, so those layers fall back to the CPU and split the graph dozens of times: prefill
/// drops to CPU speed and generation roughly halves. IQ4_NL is the same size (4.5 bits a weight),
/// runs on Metal, and loses the least of the same-size types (K-quants don't fit the 1152-wide rows).
///
/// The rewrite is lossy (about 7% relative RMS error on the affected tensors, measured on the Mac),
/// which is the price of running them on the GPU until llama.cpp gets an NVFP4 Metal kernel.
public enum MetalConverter {
    /// Written into the converted file's metadata, so a converted file can be told from an original.
    public static let markerKey = "lantern.metal_converted"

    public enum Target: String, Sendable, CaseIterable {
        case iq4NL = "iq4_nl", q4_0

        var type: ggml_type {
            switch self {
            case .iq4NL: GGML_TYPE_IQ4_NL
            case .q4_0: GGML_TYPE_Q4_0
            }
        }
    }

    public struct Report: Sendable {
        /// Tensors rewritten; 0 means the file was already fine and wasn't touched.
        public var converted = 0
        public var seconds = 0.0
        /// Relative RMS error of the rewritten tensors against the originals, from a sample of each.
        public var relativeError = 0.0
        public var bytes: Int64 = 0
    }

    public enum Failure: Error, LocalizedError {
        case unreadable, unsupported(String), noSpace(needed: Int64), writeFailed(String), cancelled

        public var errorDescription: String? {
            switch self {
            case .unreadable: "Couldn't read the model file."
            case .unsupported(let name): "Can't convert the tensor \(name)."
            case .noSpace(let needed):
                "Needs \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) free to make this model faster."
            case .writeFailed(let why): "Couldn't write the converted model: \(why)"
            case .cancelled: "Stopped."
            }
        }
    }

    /// How many tensors Metal can't run, and whether the file carries the converted marker.
    /// Reads only the header (a few MB for a 200k-token vocabulary), not the weights.
    public static func inspect(path: String) -> (unsupported: Int, converted: Bool)? {
        guard let gguf = gguf_init_from_file(path, gguf_init_params(no_alloc: true, ctx: nil)) else { return nil }
        defer { gguf_free(gguf) }
        var count = 0
        for i in 0..<gguf_get_n_tensors(gguf) where gguf_get_tensor_type(gguf, i) == GGML_TYPE_NVFP4 { count += 1 }
        return (count, gguf_find_key(gguf, markerKey) >= 0)
    }

    /// Converts `path` in place: writes `<path>.converting` beside it, then atomically replaces the
    /// original. Needs about the file's size in free space, which is checked first. Synchronous and
    /// CPU-heavy (all cores); call from a background task. `progress` is called from worker threads.
    @discardableResult
    public static func convert(
        path: String, target: Target = .iq4NL,
        progress: (@Sendable (Double) -> Void)? = nil,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) throws -> Report {
        let start = Date()
        var report = Report()
        var ggml: OpaquePointer?
        guard let src = withUnsafeMutablePointer(to: &ggml, {
            gguf_init_from_file(path, gguf_init_params(no_alloc: true, ctx: $0))
        }) else { throw Failure.unreadable }
        defer {
            gguf_free(src)
            ggml_free(ggml)
        }
        let count = gguf_get_n_tensors(src)
        let todo = (0..<count).filter { gguf_get_tensor_type(src, $0) == GGML_TYPE_NVFP4 }
        guard !todo.isEmpty else { return report }

        let url = URL(fileURLWithPath: path)
        let fileSize = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let free = (try? url.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage) ?? 0
        let needed = fileSize + 200_000_000
        guard free >= needed else { throw Failure.noSpace(needed: needed) }

        // The new header: same metadata plus the marker, same tensors with the new types. Changing
        // a type moves every later tensor's offset, which gguf recomputes.
        guard let out = gguf_init_empty() else { throw Failure.unreadable }
        defer { gguf_free(out) }
        gguf_set_kv(out, src)
        gguf_set_val_str(out, markerKey, target.rawValue)
        let traits = ggml_get_type_traits(target.type).pointee
        for i in 0..<count {
            let name = gguf_get_tensor_name(src, i)!
            guard let tensor = ggml_get_tensor(ggml, name) else { throw Failure.unreadable }
            gguf_add_tensor(out, tensor)
            if gguf_get_tensor_type(src, i) == GGML_TYPE_NVFP4 {
                let perRow = gguf_get_tensor_ne(src, i)![0]
                guard perRow % 64 == 0, perRow % traits.blck_size == 0 else {
                    throw Failure.unsupported(String(cString: name))
                }
                gguf_set_tensor_type(out, name, target.type)
            }
        }
        let metaSize = gguf_get_meta_size(out)
        var meta = [UInt8](repeating: 0, count: metaSize)
        gguf_get_meta_data(out, &meta)
        let outSize = metaSize + gguf_get_tensor_offset(out, count - 1) + gguf_get_tensor_size(out, count - 1)

        let input = open(path, O_RDONLY)
        guard input >= 0 else { throw Failure.unreadable }
        defer { close(input) }
        guard let map = mmap(nil, Int(fileSize), PROT_READ, MAP_PRIVATE, input, 0), map != MAP_FAILED else {
            throw Failure.unreadable
        }
        defer { munmap(map, Int(fileSize)) }
        let srcData = UnsafeRawPointer(map) + gguf_get_data_offset(src)

        let tempPath = path + ".converting"
        unlink(tempPath)
        let output = open(tempPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard output >= 0 else { throw Failure.writeFailed(String(cString: strerror(errno))) }
        var finished = false
        defer {
            close(output)
            if !finished { unlink(tempPath) }
        }
        func fail() -> Failure { .writeFailed(String(cString: strerror(errno))) }
        guard ftruncate(output, off_t(outSize)) == 0 else { throw fail() }
        guard pwrite(output, meta, metaSize, 0) == metaSize else { throw fail() }

        ggml_quantize_init(target.type)
        let toFloat = ggml_get_type_traits(GGML_TYPE_NVFP4).pointee.to_float!
        let fromTarget = traits.to_float!
        let written = Counter()
        let errors = Counter()
        var errorNum = 0.0, errorDen = 0.0

        for i in 0..<count {
            if isCancelled?() == true { throw Failure.cancelled }
            nonisolated(unsafe) let from = srcData + gguf_get_tensor_offset(src, i)
            let to = off_t(metaSize + gguf_get_tensor_offset(out, i))
            let srcSize = gguf_get_tensor_size(src, i)
            guard gguf_get_tensor_type(src, i) == GGML_TYPE_NVFP4 else {
                // Unchanged: copied through in pieces so progress moves and a cancel is quick.
                var done = 0
                while done < srcSize {
                    let n = min(64 << 20, srcSize - done)
                    guard pwrite(output, from + done, n, to + off_t(done)) == n else { throw fail() }
                    done += n
                    progress?(Double(written.add(n)) / Double(outSize))
                    if isCancelled?() == true { throw Failure.cancelled }
                }
                continue
            }
            let ne = gguf_get_tensor_ne(src, i)!
            let perRow = Int(ne[0]), rows = Int(ne[1] * ne[2] * ne[3])
            let srcRow = srcSize / rows, dstRow = gguf_get_tensor_size(out, i) / rows
            // About 16 MB of floats per worker at a time, so memory stays flat on a phone.
            let chunkRows = max(1, (4 << 20) / perRow)
            let chunks = (rows + chunkRows - 1) / chunkRows
            let sample = Sample()
            DispatchQueue.concurrentPerform(iterations: chunks) { c in
                if errors.value > 0 || isCancelled?() == true { return }
                let r0 = c * chunkRows, n = min(chunkRows, rows - r0)
                let floats = UnsafeMutablePointer<Float>.allocate(capacity: n * perRow)
                let packed = UnsafeMutableRawPointer.allocate(byteCount: n * dstRow, alignment: 64)
                defer {
                    floats.deallocate()
                    packed.deallocate()
                }
                toFloat(from + r0 * srcRow, floats, Int64(n * perRow))
                _ = ggml_quantize_chunk(target.type, floats, packed, 0, Int64(n), Int64(perRow), nil)
                if pwrite(output, packed, n * dstRow, to + off_t(r0 * dstRow)) != n * dstRow { errors.add(1) }
                if c % 16 == 0 {  // measure the loss on a sixteenth of the tensor
                    let back = UnsafeMutablePointer<Float>.allocate(capacity: n * perRow)
                    defer { back.deallocate() }
                    fromTarget(packed, back, Int64(n * perRow))
                    var num = 0.0, den = 0.0
                    for j in 0..<(n * perRow) {
                        let d = Double(back[j] - floats[j])
                        num += d * d
                        den += Double(floats[j]) * Double(floats[j])
                    }
                    sample.add(num, den)
                }
                progress?(Double(written.add(n * dstRow)) / Double(outSize))
            }
            if isCancelled?() == true { throw Failure.cancelled }
            guard errors.value == 0 else { throw Failure.writeFailed("the disk may be full") }
            errorNum += sample.num
            errorDen += sample.den
        }
        guard fsync(output) == 0 else { throw fail() }
        guard rename(tempPath, path) == 0 else { throw fail() }
        finished = true
        report.converted = todo.count
        report.bytes = Int64(outSize)
        report.relativeError = errorDen > 0 ? (errorNum / errorDen).squareRoot() : 0
        report.seconds = Date().timeIntervalSince(start)
        progress?(1)
        return report
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var total = 0
        var value: Int { lock.withLock { total } }
        @discardableResult
        func add(_ n: Int) -> Int { lock.withLock { total += n; return total } }
    }

    private final class Sample: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var num = 0.0, den = 0.0
        func add(_ n: Double, _ d: Double) { lock.withLock { num += n; den += d } }
    }
}
