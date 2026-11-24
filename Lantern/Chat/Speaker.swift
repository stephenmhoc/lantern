import AVFoundation
import NaturalLanguage

/// Reads an answer aloud with the system's on-device voices, which work offline.
@MainActor final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = Speaker()

    private let synthesizer = AVSpeechSynthesizer()
    /// The message being read, if any.
    private(set) var speaking: UUID?
    private var utterance: ObjectIdentifier?
    /// Called when reading starts or stops, to update the Stop button.
    var onChange: (() -> Void)?

    override private init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, id: UUID) {
        stop()
        let plain = Markdown.plainText(text)
        guard !plain.isEmpty else { return }
        // Spoken audio plays even with the ring switch off, like a podcast, and ducks other audio.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let utterance = AVSpeechUtterance(string: plain)
        utterance.voice = Self.voice(for: plain)
        speaking = id
        self.utterance = ObjectIdentifier(utterance)
        synthesizer.speak(utterance)
        onChange?()
    }

    func stop() {
        guard speaking != nil else { return }
        speaking = nil
        utterance = nil
        synthesizer.stopSpeaking(at: .immediate)
        onChange?()
    }

    /// A voice in the answer's language when that's clear (short or mixed text guesses badly),
    /// else the system's default.
    private static func voice(for text: String) -> AVSpeechSynthesisVoice? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(1000)))
        guard text.count > 40, let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              confidence > 0.8 else { return nil }
        return AVSpeechSynthesisVoice(language: language.rawValue)
    }

    /// A stopped utterance reports in after the next one has started: only the current one counts.
    private func finished(_ id: ObjectIdentifier) {
        if id == utterance {
            speaking = nil
            utterance = nil
            onChange?()
        }
        // Also after Stop, whose utterance is no longer current: until the session is let go,
        // other apps' audio stays ducked. Not if dictation has taken the session over since
        // (Stop comes just before it starts): that would cut off its microphone.
        let session = AVAudioSession.sharedInstance()
        if speaking == nil, !synthesizer.isSpeaking, session.category == .playback {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.finished(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.finished(id) }
    }
}
