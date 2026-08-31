import Foundation
import Speech
import AVFoundation
import Observation

// MARK: - Voice Dictation
//
// Live speech-to-text for Ask DiPo. Streams microphone audio into
// SFSpeechRecognizer and publishes a partial transcript as the user talks, so
// the input field fills in while they're still speaking rather than after.
//
// Two deliberate choices worth knowing about:
//
//   • On-device recognition is PREFERRED when the installed locale supports it.
//     Ask DiPo ultimately sends the text to our own backend, so this isn't
//     end-to-end privacy — but there's no reason to hand raw audio of someone
//     narrating their finances to a second party when the device can transcribe
//     it locally. Falls back to server recognition when unavailable, since a
//     transcript the user can review beats no transcript at all.
//
//   • Recognition locale follows the in-app language, not the system's. A user
//     reading DiPo in Indonesian is going to say "dua puluh lima ribu", and an
//     en-US recogniser turns that into nonsense.
@Observable
@MainActor
final class VoiceDictation {

    enum State: Equatable {
        case idle
        case listening
        /// Permission refused or restricted. Carries a localized explanation.
        case denied(String)
        /// No recogniser for this locale, or the device can't record.
        case unavailable(String)
    }

    private(set) var state: State = .idle
    /// Live transcript. Updated on every partial result.
    private(set) var transcript: String = ""
    /// Smoothed input level, 0...1. Drives the waveform so the user can see
    /// the mic is actually hearing them — silence that looks identical to
    /// speech is the fastest way to make dictation feel broken.
    private(set) var level: Double = 0

    var isListening: Bool { if case .listening = state { return true }; return false }

    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?

    /// Fires when the transcript has been quiet for a moment, so the user
    /// doesn't have to reach for the stop button after every sentence.
    private var silenceTimer: Timer?
    private static let silenceCutoff: TimeInterval = 1.8

    /// Called once recognition stops with a non-empty transcript.
    var onFinish: ((String) -> Void)?
    /// `stop()` is reachable from three places — the silence timer, the stop
    /// button, and the recogniser's own final result — and they can race. With
    /// auto-submit wired to `onFinish`, firing twice would send the same
    /// sentence twice and spend two credits on it.
    private var didFinish = false

    // MARK: - Locale

    /// The app language mapped to a recogniser locale, falling back to en-US
    /// when Speech has nothing installed for it.
    private static func preferredLocale() -> Locale {
        let appLocale = LanguageManager.shared.currentLocale
        let supported = SFSpeechRecognizer.supportedLocales()
        if supported.contains(where: { $0.identifier == appLocale.identifier }) {
            return appLocale
        }
        // Match on language only — "id" should still find "id-ID".
        if let code = appLocale.language.languageCode?.identifier,
           let match = supported.first(where: { $0.language.languageCode?.identifier == code }) {
            return match
        }
        return Locale(identifier: "en-US")
    }

    // MARK: - Permissions

    /// Asks for speech + microphone access. Both are required; either one
    /// missing makes dictation impossible, so they're requested together and
    /// reported as a single outcome.
    private func requestAccess() async -> Bool {
        let speechOK = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                c.resume(returning: status == .authorized)
            }
        }
        guard speechOK else {
            state = .denied(loc("voice.denied_speech"))
            return false
        }
        let micOK = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { granted in
                c.resume(returning: granted)
            }
        }
        guard micOK else {
            state = .denied(loc("voice.denied_mic"))
            return false
        }
        return true
    }

    // MARK: - Lifecycle

    func toggle() {
        if isListening { stop() } else { Task { await start() } }
    }

    func start() async {
        guard !isListening else { return }
        transcript = ""
        level = 0
        didFinish = false

        guard await requestAccess() else { return }

        let locale = Self.preferredLocale()
        // Only a nil recogniser means the language genuinely has no support.
        //
        // `isAvailable` used to be part of this guard, and that was wrong:
        // SFSpeechRecognizer settles its availability ASYNCHRONOUSLY, so right
        // after construction it is routinely false and flips true a moment
        // later. Hard-failing on it at t=0 is a race that reports "not
        // available for this language" for a language that works fine. Apple's
        // own guidance is to observe availability via the delegate, not to read
        // it immediately. If it really is unavailable, the recognition task
        // below surfaces a proper error instead.
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            print("[Voice] No recogniser for \(locale.identifier)")
            state = .unavailable(String(format: loc("voice.unsupported_language"),
                                        locale.localizedString(forLanguageCode: locale.identifier)
                                        ?? locale.identifier))
            return
        }
        self.recognizer = recognizer
        if !recognizer.isAvailable {
            print("[Voice] Recogniser for \(locale.identifier) not ready yet — continuing anyway")
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Prefer local transcription; see the note at the top of this file.
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        // Money talk is full of digits. This nudges the recogniser toward
        // numeric output ("25000") instead of spelled-out words.
        request.addsPunctuation = false
        self.request = request

        do {
            let session = AVAudioSession.sharedInstance()
            // `.duckOthers` was in here, and it does not belong on a `.record`
            // category — it is a playback option. On some routes setCategory
            // rejects the combination outright, and the throw landed in this
            // catch, which then blamed the user's language for what was
            // actually a bad session configuration.
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("[Voice] Audio session failed: \(error)")
            state = .unavailable(loc("voice.mic_busy"))
            return
        }

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        // A zero sample rate means the route isn't ready (no mic, or the
        // session lost its input). Installing a tap on that format throws an
        // uncatchable exception, so bail out cleanly instead.
        guard format.sampleRate > 0 else {
            print("[Voice] Input format has zero sample rate — no usable mic route")
            state = .unavailable(loc("voice.no_input"))
            deactivateSession()
            return
        }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            let peak = Self.peakLevel(buffer)
            Task { @MainActor [weak self] in self?.updateLevel(peak) }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            print("[Voice] Audio engine failed to start: \(error)")
            input.removeTap(onBus: 0)
            state = .unavailable(loc("voice.mic_busy"))
            deactivateSession()
            return
        }

        state = .listening
        armSilenceTimer()

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    self.armSilenceTimer()          // reset the quiet countdown
                    if result.isFinal { self.stop() }
                } else if let error {
                    // A recognition error after speech has been captured still
                    // leaves a usable partial, so keep whatever we have rather
                    // than discarding the user's sentence. But when nothing was
                    // captured at all, say so — silently stopping looks
                    // identical to the mic never having worked.
                    print("[Voice] Recognition error: \(error)")
                    let hadSpeech = !self.transcript.trimmingCharacters(in: .whitespaces).isEmpty
                    self.stop()
                    if !hadSpeech { self.state = .unavailable(loc("voice.recognition_failed")) }
                }
            }
        }
    }

    func stop() {
        silenceTimer?.invalidate()
        silenceTimer = nil

        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        deactivateSession()

        level = 0
        if isListening { state = .idle }

        let finished = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !finished.isEmpty, !didFinish {
            didFinish = true
            onFinish?(finished)
        }
    }

    /// Stops without delivering the transcript — for teardown, where
    /// auto-submitting a half-spoken sentence as the screen closes would be
    /// surprising and would cost a credit the user never asked to spend.
    func cancel() {
        didFinish = true
        stop()
    }

    /// Clears any error state so the next tap starts fresh rather than
    /// re-showing a stale "permission denied" from a previous attempt.
    func reset() {
        state = .idle
        transcript = ""
        level = 0
    }

    private func deactivateSession() {
        // Best-effort: the session may already be inactive, which throws.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func armSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: Self.silenceCutoff, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.stop() }
        }
    }

    // MARK: - Level metering

    private func updateLevel(_ peak: Float) {
        // Exponential smoothing — raw peaks jitter far too fast to animate.
        let target = Double(min(max(peak * 6, 0), 1))
        level += (target - level) * 0.25
    }

    private nonisolated static func peakLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count { sum += data[i] * data[i] }
        return (sum / Float(count)).squareRoot()
    }
}
