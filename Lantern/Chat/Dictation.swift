import AVFoundation
import os
import Speech

/// Speech to text for the message box, on this device only: nothing is sent to Apple's servers.
/// iOS 26 and later use `SpeechAnalyzer`; earlier versions (or a language its assets aren't
/// installed for) use `SFSpeechRecognizer` with on-device recognition required.
final class Dictation {
    enum Failure: LocalizedError {
        case microphoneDenied, speechDenied, unavailable, notInstalled(String), audio(String)

        var errorDescription: String? {
            switch self {
            case .microphoneDenied: "Lantern needs the microphone to take dictation. You can allow it in Settings."
            case .speechDenied: "Lantern needs speech recognition to take dictation. You can allow it in Settings."
            case .unavailable: "Dictation on this device isn't available for your language."
            case .notInstalled(let language):
                "Dictation in \(language) needs a one-time download. Connect to the internet and try again."
            case .audio(let message): "The microphone couldn't start: \(message)"
            }
        }

        /// Whether Settings is where to fix it.
        var opensSettings: Bool {
            switch self {
            case .microphoneDenied, .speechDenied: true
            default: false
            }
        }
    }

    /// Everything heard so far in this session, partial words included. Called on the main actor.
    var onTranscript: ((String) -> Void)?
    /// Dictation stopped by itself (an error, or the recognizer finished).
    var onEnd: ((Error?) -> Void)?
    private(set) var isRunning = false

    private let engine = AVAudioEngine()
    private var session: Session?

    /// Whether on-device recognition exists for the language. The mic button is hidden if not.
    static func isAvailable(locale: Locale = .current) async -> Bool {
        if #available(iOS 26, *), SpeechTranscriber.isAvailable,
           await SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil {
            return true
        }
        return SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition == true
    }

    func start(locale: Locale = .current) async throws {
        guard !isRunning else { return }
        guard await AVAudioApplication.requestRecordPermission() else { throw Failure.microphoneDenied }
        if #available(iOS 26, *), let session = try await AnalyzerSession.make(locale: locale) {
            self.session = session
        } else {
            guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition else {
                throw Failure.unavailable
            }
            guard await Self.speechAuthorized() else { throw Failure.speechDenied }
            session = RecognizerSession(recognizer: recognizer)
        }
        guard let session else { return }
        session.onTranscript = { [weak self] text in self?.onTranscript?(text) }
        session.onEnd = { [weak self] error in
            guard let self, isRunning else { return }
            tearDown()
            onEnd?(error)
        }
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audio.setActive(true, options: .notifyOthersOnDeactivation)
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            let feed = try await session.begin(naturalFormat: format)
            input.installTap(onBus: 0, bufferSize: 2048, format: format, block: feed)
            engine.prepare()
            try engine.start()
            isRunning = true
        } catch {
            tearDown()
            throw error is Failure ? error : Failure.audio(error.localizedDescription)
        }
    }

    /// Stops listening; the last words are still delivered through `onTranscript`.
    func stop() {
        guard isRunning else { return }
        let session = session
        tearDown()
        session?.finish()
    }

    private func tearDown() {
        isRunning = false
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        session = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func speechAuthorized() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined: return await requestSpeech()
        default: return false
        }
    }

    // Callbacks from Speech and AVFoundation arrive on their own queues, so their closures are
    // made outside the main actor.
    private nonisolated static func requestSpeech() async -> Bool {
        await withCheckedContinuation { done in
            SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0 == .authorized) }
        }
    }
}

/// One stretch of listening, whichever recognizer does it.
private class Session {
    var onTranscript: ((String) -> Void)?
    var onEnd: ((Error?) -> Void)?

    /// Returns the microphone tap's block. Called once, before audio starts.
    func begin(naturalFormat: AVAudioFormat) async throws -> AVAudioNodeTapBlock { fatalError() }
    /// No more audio: finish the last words, then stop delivering.
    func finish() {}
}

/// iOS 18–25, or iOS 26 without the language's SpeechAnalyzer assets.
private final class RecognizerSession: Session {
    private let recognizer: SFSpeechRecognizer
    private let request = SFSpeechAudioBufferRecognitionRequest()
    private var task: SFSpeechRecognitionTask?

    init(recognizer: SFSpeechRecognizer) {
        self.recognizer = recognizer
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
    }

    override func begin(naturalFormat: AVAudioFormat) async throws -> AVAudioNodeTapBlock {
        task = Self.recognize(recognizer, request) { [weak self] text, done, error in
            Task { @MainActor in
                guard let self else { return }
                if let text { self.onTranscript?(text) }
                if done { self.onEnd?(error) }
            }
        }
        return Self.tap(request)
    }

    private nonisolated static func recognize(
        _ recognizer: SFSpeechRecognizer, _ request: SFSpeechAudioBufferRecognitionRequest,
        update: @escaping @Sendable (String?, Bool, Error?) -> Void
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            // 1110: no speech heard; 1101, 216: recognition ended early (Stop). Not worth reporting.
            let code = (error as NSError?)?.code
            let report = error != nil && code != 1110 && code != 1101 && code != 216
            update(result?.bestTranscription.formattedString, result?.isFinal == true || error != nil, report ? error : nil)
        }
    }

    private nonisolated static func tap(_ request: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        { buffer, _ in request.append(buffer) }
    }

    override func finish() {
        request.endAudio()
    }
}

/// iOS 26+: `SpeechAnalyzer` with a `SpeechTranscriber`, volatile results shown as they come.
@available(iOS 26, *)
private final class AnalyzerSession: Session {
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>
    private let builder: AsyncStream<AnalyzerInput>.Continuation
    private var results: Task<Void, Never>?
    private var finalized = ""

    private init(transcriber: SpeechTranscriber) {
        self.transcriber = transcriber
        analyzer = SpeechAnalyzer(modules: [transcriber])
        (input, builder) = AsyncStream<AnalyzerInput>.makeStream()
    }

    /// Nil when this language isn't supported, or its assets aren't installed and can't be fetched
    /// but the older recognizer can do it on device.
    static func make(locale: Locale) async throws -> AnalyzerSession? {
        guard SpeechTranscriber.isAvailable, let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            return nil
        }
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults], attributeOptions: [])
        let installed = await SpeechTranscriber.installedLocales.contains { $0.identifier(.bcp47) == supported.identifier(.bcp47) }
        if !installed {
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try await request.downloadAndInstall()
                }
            } catch {
                if SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition == true { return nil }
                throw Dictation.Failure.notInstalled(locale.localizedString(forLanguageCode: locale.language.languageCode?.identifier ?? "") ?? "this language")
            }
        }
        return AnalyzerSession(transcriber: transcriber)
    }

    override func begin(naturalFormat: AVAudioFormat) async throws -> AVAudioNodeTapBlock {
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: naturalFormat),
              let converter = AVAudioConverter(from: naturalFormat, to: format) else {
            throw Dictation.Failure.unavailable
        }
        let transcriber = transcriber
        results = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters)
                    if result.isFinal {
                        finalized += text
                        onTranscript?(finalized)
                    } else {
                        onTranscript?(finalized + text)
                    }
                }
                self?.onEnd?(nil)
            } catch {
                self?.onEnd?(error)
            }
        }
        try await analyzer.start(inputSequence: input)
        return AudioFeed(converter: converter, to: format, builder: builder).tap
    }

    override func finish() {
        builder.finish()
        let analyzer = analyzer
        Task { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
    }
}

/// Converts microphone buffers to the analyzer's format, on the audio thread.
@available(iOS 26, *)
private nonisolated final class AudioFeed: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let format: AVAudioFormat
    private let builder: AsyncStream<AnalyzerInput>.Continuation

    init(converter: AVAudioConverter, to format: AVAudioFormat, builder: AsyncStream<AnalyzerInput>.Continuation) {
        self.converter = converter
        self.format = format
        self.builder = builder
    }

    var tap: AVAudioNodeTapBlock {
        { [self] buffer, _ in convert(buffer) }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var given = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if given {
                status.pointee = .noDataNow
                return nil
            }
            given = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil, out.frameLength > 0 { builder.yield(AnalyzerInput(buffer: out)) }
    }
}
