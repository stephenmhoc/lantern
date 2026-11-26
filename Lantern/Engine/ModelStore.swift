import Foundation
import LlamaKit
import Network
import Observation

/// Keeps this device's model on disk and downloads the best one (`CatalogModel.device`): its
/// weights, drafter and vision projector, as one download with one progress. The files live in
/// Documents, excluded from backups. A background session, so the download carries on while
/// Lantern is closed.
///
/// Offline first: a model already here keeps answering. If it isn't the best this device runs
/// (an upgrade from an earlier version, or a new best), the best is offered, never forced, and
/// the old one answers until the new one is completely here and checked. Only then is the old
/// one deleted.
@Observable
final class ModelStore: NSObject {
    static let shared = ModelStore()
    static let sessionID = "com.merimerimeri.Lantern.downloads"

    /// How far along the best model's download is.
    enum State: Equatable {
        case missing
        /// Fraction of all the model's bytes.
        case downloading(Double)
        /// Stopped part-way, by the user or the network. Resuming carries on from there.
        case paused(Double)
        case failed(String)
        case ready
    }

    /// The best model this device runs: what gets downloaded.
    let best = CatalogModel.device
    /// The model that answers: `best` once it's here, until then an older one that is.
    private(set) var model = CatalogModel.device
    /// Whether `model` can answer: its weights are here.
    private(set) var isReady = false
    /// The download of `best`. `.ready` when `model` is `best` and here.
    private(set) var state = State.missing
    /// Whether attached images are seen: `model`'s projector is here.
    private(set) var hasProjector = false
    /// Called just before `model` changes to `best`, so the engine lets go of the old one.
    @ObservationIgnored var modelWillChange: () -> Void = {}

    /// A better model than the one answering can be downloaded (or is on its way).
    var hasUpgrade: Bool { isReady && model != best }

    @ObservationIgnored private var done: Set<String> = []       // filenames complete on disk
    @ObservationIgnored private var received: [String: Int64] = [:]  // bytes so far, per file in flight
    @ObservationIgnored private var active: Set<String> = []
    @ObservationIgnored private var resumeData: [String: Data] = [:]
    @ObservationIgnored private var failure: String?
    @ObservationIgnored private var backgroundCompletion: (() -> Void)?
    @ObservationIgnored private var backgroundEventsDone = false
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
        // A Mac has no model of its own: nothing is looked for, downloaded or deleted there (the
        // Mac app before this one kept its models in the same folder).
        guard !Device.isMac else { return }
        refresh()
        // Reattach to downloads that kept going while the app was closed.
        session.getAllTasks { tasks in
            Task { @MainActor in
                for task in tasks where task.state == .running {
                    guard let name = task.taskDescription, self.best.files.contains(where: { $0.filename == name }),
                          !self.done.contains(name) else {
                        task.cancel()  // a file of a model this device doesn't download
                        continue
                    }
                    self.active.insert(name)
                    self.received[name] = task.countOfBytesReceived
                }
                self.update()
            }
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.online = path.status == .satisfied
                self.fetchExtras()
            }
        }
        pathMonitor.start(queue: .main)
    }

    func url(for file: ModelFile) -> URL { Folders.models.appending(path: file.filename) }
    func has(_ file: ModelFile) -> Bool { done.contains(file.filename) }

    static var freeBytes: Int64 {
        (try? Folders.models.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage) ?? 0
    }

    /// A file counts only at its exact size and with a GGUF header: a download cut short, or an
    /// error page saved in its place, is not a model.
    private func verified(_ file: ModelFile) -> Bool {
        var url = url(for: file)
        guard (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) == file.bytes,
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard (try? handle.read(upToCount: 4)) == Data("GGUF".utf8) else { return false }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return true
    }

    /// Looks at what's on disk and settles which model answers.
    func refresh() {
        guard !Device.isMac else { return }
        done = Set(CatalogModel.all.flatMap(\.files).filter(verified).map(\.filename))
        // The best, if it's here and nothing older is still answering; else whichever is here.
        let here = CatalogModel.all.filter { has($0.weights) }
        let complete = best.files.allSatisfy(has)
        let next = has(best.weights) && (complete || here == [best]) ? best : here.first { $0 != best } ?? best
        if next != model {
            if isReady { modelWillChange() }
            model = next
        }
        update()
        fetchExtras()
        if model == best, isReady { removeOthers() }
    }

    private func update() {
        isReady = has(model.weights)
        hasProjector = has(model.projector)
        if model == best, isReady {
            state = .ready
            return
        }
        let have = best.files.reduce(Int64(0)) { $0 + (done.contains($1.filename) ? $1.bytes : received[$1.filename] ?? 0) }
        let fraction = min(1, Double(have) / Double(best.bytes))
        if !active.isEmpty {
            state = .downloading(fraction)
        } else if let failure {
            state = .failed(failure)
        } else if have > 0 || !resumeData.isEmpty {
            state = .paused(fraction)
        } else {
            state = .missing
        }
    }

    /// Starts, or carries on, downloading whatever of the best model isn't here yet.
    func download() {
        guard !Device.isMac else { return }
        failure = nil
        let missing = best.files.filter { !done.contains($0.filename) && !active.contains($0.filename) }
        let needed = missing.reduce(Int64(0)) { $0 + $1.bytes - (received[$1.filename] ?? 0) } + 1_000_000_000
        guard Self.freeBytes >= needed else {
            let short = ByteCountFormatter.string(fromByteCount: needed - Self.freeBytes, countStyle: .file)
            failure = "Not enough space. Free up \(short) and try again."
            return update()
        }
        for file in missing { start(file) }
        update()
    }

    private func start(_ file: ModelFile) {
        let task = resumeData.removeValue(forKey: file.filename).map { session.downloadTask(withResumeData: $0) }
            ?? session.downloadTask(with: file.url)
        task.taskDescription = file.filename
        task.countOfBytesClientExpectsToReceive = file.bytes
        active.insert(file.filename)
        task.resume()
    }

    /// The drafter and projector of the best model when its weights are already here (downloaded
    /// before they came with it), fetched quietly when there's a network. Free to call often.
    private func fetchExtras() {
        guard online, model == best, isReady, failure == nil else { return }
        for file in [best.drafter, best.projector] where !done.contains(file.filename) && !active.contains(file.filename) {
            guard Self.freeBytes >= file.bytes + 1_000_000_000 else { continue }
            start(file)
        }
    }

    /// Stops the download, keeping what has arrived so `download()` carries on from there.
    func pause() {
        session.getAllTasks { tasks in
            for case let task as URLSessionDownloadTask in tasks {
                task.cancel { data in
                    Task { @MainActor in
                        if let data, let name = task.taskDescription { self.resumeData[name] = data }
                        self.update()
                    }
                }
            }
        }
        active = []
        update()
    }

    /// Gives up on the download: stops it and deletes what had arrived of the best model. A model
    /// already answering is left alone.
    func cancelDownload() {
        session.getAllTasks { $0.forEach { $0.cancel() } }
        active = []
        received = [:]
        resumeData = [:]
        failure = nil
        if model != best || !isReady {
            for file in best.files { try? FileManager.default.removeItem(at: url(for: file)) }
        }
        refresh()
    }

    /// Removes every model file from this device. The caller unloads the model first.
    func delete() {
        guard !Device.isMac else { return }
        session.getAllTasks { $0.forEach { $0.cancel() } }
        active = []
        received = [:]
        resumeData = [:]
        failure = nil
        for file in CatalogModel.all.flatMap(\.files) { try? FileManager.default.removeItem(at: url(for: file)) }
        refresh()
    }

    /// Once the best model is here and answering: deletes the files of the others, and of models
    /// earlier versions ran. Never in a debug run that picks its model (`-model`, `-e2e`).
    private func removeOthers() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-model") || arguments.contains("-e2e") { return }
        #endif
        let names = CatalogModel.all.filter { $0 != best }.flatMap(\.files).map(\.filename) + CatalogModel.retiredFilenames
        for name in names { done.remove(name) }
        let folder = Folders.models
        Task.detached(priority: .utility) {
            for name in names { try? FileManager.default.removeItem(at: folder.appending(path: name)) }
        }
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
        totalBytesWritten written: Int64, totalBytesExpectedToWrite _: Int64
    ) {
        guard let name = downloadTask.taskDescription else { return }
        MainActor.assumeIsolated {
            guard active.contains(name) else { return }
            received[name] = written
            update()
        }
    }

    nonisolated func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
    ) {
        // The temp file is deleted when this returns, so move it here.
        guard let name = downloadTask.taskDescription else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let dest = Folders.models.appending(path: name)
        var error: String?
        if status == 200 || status == 206 {
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: location, to: dest)
            } catch let e { error = e.localizedDescription }
        } else {
            error = "The download failed (HTTP \(status))."
        }
        MainActor.assumeIsolated {
            active.remove(name)
            received[name] = nil
            refresh()
            // Arrived, but not the file it should be: say so rather than sit at 100%.
            if error == nil, !done.contains(name) {
                try? FileManager.default.removeItem(at: dest)
                error = "The download didn't arrive intact."
            }
            if let error, !isReady || model != best {
                failure = error
                update()
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let name = task.taskDescription else { return }
        let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        let cancelled = (error as? URLError)?.code == .cancelled
        MainActor.assumeIsolated {
            if let resume { resumeData[name] = resume }
            // A pause already cleared `active`; anything else stopping a file in flight is a failure.
            if active.remove(name) != nil, !cancelled { failure = error.localizedDescription }
            update()
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
