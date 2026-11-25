import Foundation
import LlamaKit
import Network
import Observation
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
        case ready
        case failed(String)
    }

    private(set) var states: [String: State] = [:]
    /// Asked before a model's file is replaced; the engine unloads it. False means not now.
    @ObservationIgnored var canReplaceFile: (CatalogModel) -> Bool = { _ in true }
    @ObservationIgnored private var resumeData: [String: Data] = [:]
    @ObservationIgnored private var backgroundCompletion: (() -> Void)?
    @ObservationIgnored private var backgroundEventsDone = false
    /// Whether there's a network, so a missing drafter is only fetched when it can be.
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var online = false

    @ObservationIgnored private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    override private init() {
        super.init()
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
        pathMonitor.pathUpdateHandler = { [weak self] path in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.online = path.status == .satisfied
                self.fetchMissingDrafters()
            }
        }
        pathMonitor.start(queue: .main)
    }

    /// Starts downloading the drafter of each downloaded model that lacks one (a Gemma from before
    /// drafters, or copied in by hand), if there's a network. Quiet: nothing shows it, and the
    /// model runs without it until it's here. Free to call often.
    func fetchMissingDrafters() {
        guard online else { return }
        for model in CatalogModel.all where states[model.id] == .ready {
            guard let drafter = model.drafter else { continue }
            switch states[drafter.id] {
            case .ready, .downloading: continue
            default: download(drafter)
            }
        }
    }

    func url(for model: CatalogModel) -> URL { URL.documentsDirectory.appending(path: model.filename) }

    var downloaded: Set<String> { Set(states.filter { $0.value == .ready }.map(\.key)) }

    func refresh() {
        for model in CatalogModel.files {
            if case .downloading = states[model.id] { continue }
            var file = url(for: model)
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? -1
            if size == model.bytes {
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try? file.setResourceValues(values)
                states[model.id] = .ready
            } else if size >= 0 {
                states[model.id] = .incomplete(size)
            } else if case .failed = states[model.id] {
                continue
            } else {
                states[model.id] = .missing
            }
        }
        fetchMissingDrafters()
    }

    // MARK: - Files nothing uses any more

    /// Model files from earlier builds still in Documents (see `CatalogModel.retiredFilenames`),
    /// with their sizes.
    private(set) var retired: [(name: String, bytes: Int64)] = []

    func refreshRetired() {
        retired = CatalogModel.retiredFilenames.compactMap { name in
            let file = URL.documentsDirectory.appending(path: name)
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
            return (name, Int64(size))
        }
    }

    func deleteRetired() {
        for (name, _) in retired { try? FileManager.default.removeItem(at: URL.documentsDirectory.appending(path: name)) }
        refreshRetired()
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
        // A model's drafter comes with it.
        if let drafter = model.drafter {
            switch states[drafter.id] {
            case .ready, .downloading: break
            default: download(drafter)
            }
        }
    }

    func cancel(_ model: CatalogModel) {
        let ids = [model.id] + (model.drafter.map { [$0.id] } ?? [])
        session.getAllTasks { tasks in
            tasks.filter { ids.contains($0.taskDescription ?? "") }.forEach { $0.cancel() }
        }
        for id in ids where id == model.id || states[id] != .ready {  // a finished drafter stays
            resumeData[id] = nil
            states[id] = .missing
        }
    }

    func delete(_ model: CatalogModel) {
        try? FileManager.default.removeItem(at: url(for: model))
        states[model.id] = .missing
        if let drafter = model.drafter {  // nothing else uses it
            cancel(drafter)
            try? FileManager.default.removeItem(at: url(for: drafter))
            states[drafter.id] = .missing
        }
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
        let total = expected > 0 ? expected : CatalogModel.files.first { $0.id == id }?.bytes ?? 1
        MainActor.assumeIsolated { states[id] = .downloading(Double(written) / Double(total)) }
    }

    nonisolated func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
    ) {
        // The temp file is deleted when this returns, so move it here.
        guard let id = downloadTask.taskDescription,
              let model = CatalogModel.files.first(where: { $0.id == id }) else { return }
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
