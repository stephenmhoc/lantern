import Foundation
import LlamaKit
import Observation
import os
import UIKit

/// Model files live in Documents, so they also show up in Finder (over a cable) and the Files app:
/// that's how to copy one from the Mac without internet. They're excluded from backups.
@Observable
final class ModelStore: NSObject {
    static let shared = ModelStore()
    static let sessionID = "com.merimerimeri.Lantern.downloads"

    enum State: Equatable {
        case missing
        /// On disk but smaller than it should be: a copy or download still going, or cut short.
        case incomplete(Int64)
        case downloading(Double)
        /// Being rewritten so all of it runs on the GPU (`convert`). The file can't be used meanwhile.
        case converting(Double)
        case ready
        case failed(String)
    }

    private(set) var states: [String: State] = [:]
    /// Ready models whose file still has tensors Metal can't run: they work, slowly, until converted.
    private(set) var unconverted: Set<String> = []
    /// Why the last conversion of a model didn't happen (e.g. not enough free space).
    private(set) var conversionErrors: [String: String] = [:]
    /// Asked before a model's file is replaced; the engine unloads it. False means not now.
    @ObservationIgnored var canReplaceFile: (CatalogModel) -> Bool = { _ in true }
    /// Models to convert as soon as the app is in front: set when their download finishes.
    @ObservationIgnored private var convertWhenActive: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "models.convertWhenActive") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "models.convertWhenActive") }
    }
    @ObservationIgnored private var resumeData: [String: Data] = [:]
    @ObservationIgnored private var backgroundCompletion: (() -> Void)?
    @ObservationIgnored private var backgroundEventsDone = false

    @ObservationIgnored private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    override private init() {
        super.init()
        // A conversion the app was killed in the middle of: the original is intact, drop the copy.
        for model in CatalogModel.all { try? FileManager.default.removeItem(atPath: url(for: model).path + ".converting") }
        refresh()
        // Reattach to downloads that kept going while the app was closed.
        session.getAllTasks { tasks in
            Task { @MainActor in
                for task in tasks where task.state == .running {
                    guard let id = task.taskDescription, self.states[id] != .ready else { continue }
                    self.states[id] = .downloading(task.progress.fractionCompleted)
                }
            }
        }
    }

    func url(for model: CatalogModel) -> URL { URL.documentsDirectory.appending(path: model.filename) }

    var downloaded: Set<String> { Set(states.filter { $0.value == .ready }.map(\.key)) }

    func refresh() {
        for model in CatalogModel.all {
            if case .downloading = states[model.id] { continue }
            if case .converting = states[model.id] { continue }
            var file = url(for: model)
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? -1
            let converted = isConverted(model, size: size)
            if size == model.bytes || converted {
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try? file.setResourceValues(values)
                states[model.id] = .ready
                setUnconverted(model.id, model.convertsForMetal && !converted)
            } else if size >= 0 {
                setUnconverted(model.id, false)
                states[model.id] = .incomplete(size)
            } else if case .failed = states[model.id] {
                continue
            } else {
                states[model.id] = .missing
            }
        }
    }

    // MARK: - Converting for Metal

    private func setUnconverted(_ id: String, _ value: Bool) {
        if value != unconverted.contains(id) { unconverted.formSymmetricDifference([id]) }
    }

    /// A converted file isn't the catalog's size any more (its header gained a marker), so it
    /// carries the size it had in an extended attribute. If that's lost (the file was copied off
    /// and back), the marker inside the file is the fallback; it costs reading the header.
    private nonisolated static let convertedAttribute = "com.merimerimeri.lantern.converted-from"

    private func isConverted(_ model: CatalogModel, size: Int64) -> Bool {
        guard model.convertsForMetal, size > model.bytes else { return false }
        let path = url(for: model).path
        var buffer = [UInt8](repeating: 0, count: 32)
        let n = getxattr(path, Self.convertedAttribute, &buffer, buffer.count, 0, 0)
        if n > 0, Int64(String(decoding: buffer[..<n], as: UTF8.self)) == model.bytes { return true }
        guard size - model.bytes < 1_000_000, MetalConverter.inspect(path: path)?.converted == true else { return false }
        Self.markConverted(path, from: model.bytes)
        return true
    }

    private nonisolated static func markConverted(_ path: String, from bytes: Int64) {
        let value = Array(String(bytes).utf8)
        setxattr(path, convertedAttribute, value, value.count, 0, 0)
    }

    /// Rewrites the tensors Metal can't run (see `MetalConverter`), which makes Inkling several
    /// times faster. Takes a minute or two and about the file's size in free space; the original
    /// is replaced only once the new file is complete.
    func convert(_ model: CatalogModel) {
        guard states[model.id] == .ready, unconverted.contains(model.id) else { return }
        guard canReplaceFile(model) else {
            conversionErrors[model.id] = "Wait for the answer to finish, then try again."
            return
        }
        let needed = model.bytes + 200_000_000
        guard Self.freeBytes >= needed else {
            let gb = ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)
            conversionErrors[model.id] = "Needs \(gb) free to make it faster."
            return
        }
        conversionErrors[model.id] = nil
        states[model.id] = .converting(0)
        let path = url(for: model).path
        let id = model.id, bytes = model.bytes
        // Leaving the app pauses the work; iOS allows a little time to get further first.
        var background = UIBackgroundTaskIdentifier.invalid
        background = UIApplication.shared.beginBackgroundTask(withName: "Convert model") {
            UIApplication.shared.endBackgroundTask(background)  // out of time: it carries on when Lantern is back
            background = .invalid
        }
        let lastPercent = OSAllocatedUnfairLock(initialState: -1)
        Task.detached(priority: .utility) {
            var failure: String?
            do {
                try MetalConverter.convert(path: path, progress: { p in
                    let percent = Int(p * 100)
                    guard lastPercent.withLock({ last in
                        defer { last = max(last, percent) }
                        return percent > last
                    }) else { return }
                    Task { @MainActor in
                        if case .converting = self.states[id] { self.states[id] = .converting(p) }
                    }
                })
                Self.markConverted(path, from: bytes)
            } catch {
                failure = error.localizedDescription
            }
            await MainActor.run {
                self.states[id] = nil
                self.conversionErrors[id] = failure
                self.convertWhenActive.remove(id)
                self.refresh()
                if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
            }
        }
    }

    /// Starts the conversions that were waiting for the app to be in front.
    func convertPending() {
        guard UIApplication.shared.applicationState == .active else { return }
        refresh()
        for model in CatalogModel.all where convertWhenActive.contains(model.id) {
            if unconverted.contains(model.id) { convert(model) } else if states[model.id] == .ready { convertWhenActive.remove(model.id) }
        }
    }

    static var freeBytes: Int64 {
        (try? URL.documentsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage) ?? 0
    }

    func download(_ model: CatalogModel) {
        let needed = model.bytes + 1_000_000_000
        guard Self.freeBytes >= needed else {
            let gb = ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)
            states[model.id] = .failed("Needs \(gb) free")
            return
        }
        let task = resumeData.removeValue(forKey: model.id).map { session.downloadTask(withResumeData: $0) }
            ?? session.downloadTask(with: model.url)
        task.taskDescription = model.id
        task.countOfBytesClientExpectsToReceive = model.bytes
        states[model.id] = .downloading(0)
        task.resume()
    }

    func cancel(_ model: CatalogModel) {
        session.getAllTasks { tasks in
            tasks.filter { $0.taskDescription == model.id }.forEach { $0.cancel() }
        }
        resumeData[model.id] = nil
        states[model.id] = .missing
    }

    func delete(_ model: CatalogModel) {
        if case .converting = states[model.id] { return }
        try? FileManager.default.removeItem(at: url(for: model))
        convertWhenActive.remove(model.id)
        unconverted.remove(model.id)
        conversionErrors[model.id] = nil
        states[model.id] = .missing
        refresh()
    }

    /// The system relaunches the app to deliver finished downloads; this runs once they're handled.
    func onBackgroundEventsDone(_ completion: @escaping () -> Void) {
        if backgroundEventsDone {
            completion()
        } else {
            backgroundCompletion = completion
        }
    }
}

extension ModelStore: URLSessionDownloadDelegate {
    // delegateQueue is .main, so these run on the main actor.

    nonisolated func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
        totalBytesWritten written: Int64, totalBytesExpectedToWrite expected: Int64
    ) {
        guard let id = downloadTask.taskDescription else { return }
        let total = expected > 0 ? expected : CatalogModel.all.first { $0.id == id }?.bytes ?? 1
        MainActor.assumeIsolated { states[id] = .downloading(Double(written) / Double(total)) }
    }

    nonisolated func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
    ) {
        // The temp file is deleted when this returns, so move it here.
        guard let id = downloadTask.taskDescription,
              let model = CatalogModel.all.first(where: { $0.id == id }) else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let dest = URL.documentsDirectory.appending(path: model.filename)
        var error: String?
        if status == 200 {
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: location, to: dest)
            } catch let e { error = e.localizedDescription }
        } else {
            error = "Download failed (HTTP \(status))"
        }
        MainActor.assumeIsolated {
            if let error {
                states[id] = .failed(error)
            } else {
                states[id] = nil
                refresh()
                if model.convertsForMetal {
                    convertWhenActive.insert(id)
                    convertPending()
                }
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription else { return }
        let nsError = error as NSError
        let resume = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        let cancelled = (error as? URLError)?.code == .cancelled
        MainActor.assumeIsolated {
            if let resume { resumeData[id] = resume }
            if cancelled && resume == nil {
                states[id] = .missing
            } else {
                states[id] = .failed(resume == nil ? error.localizedDescription : "Paused. Retry resumes it.")
            }
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated {
            backgroundEventsDone = true
            backgroundCompletion?()
            backgroundCompletion = nil
        }
    }
}
