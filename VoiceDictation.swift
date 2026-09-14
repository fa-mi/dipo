import SwiftUI
import Foundation
import Speech
import AVFoundation
import Observation

// MARK: - Voice language

/// The language dictation listens for — chosen apart from the app's text
/// language. Plenty of people keep their phone in English and still say
/// "makan siang 45rb" out loud; tying the recogniser to the text setting made
/// them pick between reading comfortably and being understood.
enum VoiceLanguage: String, CaseIterable, Identifiable {
    /// Follow the app's text language (the old behaviour, and the default).
    case app
    case indonesian = "id"
    case english = "en"

    var id: String { rawValue }

    private static let storageKey = "voice_language"

    static var saved: VoiceLanguage {
        get { VoiceLanguage(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .app }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: storageKey) }
    }

    /// The language actually spoken, with `.app` resolved.
    var spoken: LanguageManager.Language {
        switch self {
        case .app:        return LanguageManager.shared.current
        case .indonesian: return .indonesian
        case .english:    return .english
        }
    }

    var label: String {
        switch self {
        case .app:        return String(format: loc("voice.lang_app"), LanguageManager.shared.current.nativeName)
        case .indonesian: return LanguageManager.Language.indonesian.nativeName
        case .english:    return LanguageManager.Language.english.nativeName
        }
    }

    /// Two letters for the chip on the voice screen.
    var code: String { spoken == .indonesian ? "ID" : "EN" }
}

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
//   • Recognition locale follows the voice language the user picked
//     (`VoiceLanguage`, by default the in-app language), never the system's. A
//     user saying "dua puluh lima ribu" to an en-US recogniser gets nonsense.
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

    /// The chosen voice language mapped to a recogniser locale, falling back to
    /// en-US when Speech has nothing installed for it.
    private static func preferredLocale() -> Locale {
        let appLocale = Locale(identifier: VoiceLanguage.saved.spoken == .indonesian ? "id_ID" : "en_US")
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
                    let text = result.bestTranscription.formattedString
                    // Restart the quiet countdown only when NEW WORDS arrived.
                    // Speech keeps firing this callback while audio flows, and
                    // re-arming on every one of them meant the timer could
                    // never expire: the screen listened forever with a finished
                    // sentence sitting on it. Harmless in the chat, where the
                    // user reads the field and taps send — fatal on a screen
                    // whose whole contract is to submit by itself.
                    if text != self.transcript {
                        self.transcript = text
                        self.armSilenceTimer()
                    }
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

// MARK: - Voice capture screen

/// A screen whose only job is to hear one sentence.
///
/// Ask DiPo's inline mic put dictation inside a chat: a keyboard, a history, a
/// text field and a send button all competing with the one thing the user came
/// to do. Bound to a Back Tap it was worse — the gesture is meant to skip the
/// interface, not open a bigger one.
///
/// So this screen holds nothing but the state of listening: whether the mic is
/// hearing anything, and the words so far. It does not parse or save. The
/// sentence goes to Ask DiPo, which already owns parsing, credits and the
/// confirm-before-adding card — a misheard sentence should still cost a glance,
/// never a wrong transaction.
struct VoiceCaptureView: View {
    /// Receives the final sentence. Empty means the user cancelled.
    var onCaptured: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var voice = VoiceDictation()
    @State private var notice: String? = nil
    @State private var appeared = false
    /// The sentence is in: the orb draws in for a beat before the screen closes.
    @State private var finishing = false
    @State private var lastWordTick: Date = .distantPast
    @State private var voiceLanguage = VoiceLanguage.saved

    private var isListening: Bool { voice.isListening }

    private var orbMode: VoiceOrb.Mode {
        finishing ? .finishing : isListening ? .listening : .idle
    }

    private var wordCount: Int {
        voice.transcript.split(whereSeparator: \.isWhitespace).count
    }

    /// Same as the mic button: stop while listening, otherwise start over.
    private func toggleListening() {
        guard !finishing else { return }
        HapticManager.shared.tap()
        if isListening {
            voice.stop()
        } else {
            voice.reset()
            Task { await voice.start() }
        }
    }

    var body: some View {
        ZStack {
            AppTheme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                Text(statusText)
                    .font(.system(.footnote, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)
                    .frame(height: 18)
                    .id(statusText)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.18), value: statusText)
                    .padding(.top, 6)

                Spacer(minLength: 12)

                VoiceOrb(level: voice.level, mode: orbMode, wordCount: wordCount,
                         onTap: toggleListening)
                    .frame(width: 220, height: 220)
                    .opacity(appeared ? 1 : 0)
                    .scaleEffect(appeared ? 1 : 0.9)
                    .animation(.spring(response: 0.55, dampingFraction: 0.8), value: appeared)

                Spacer(minLength: 12)

                transcriptArea
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 26)

                if let notice {
                    InlineBanner(tone: .warning, message: notice)
                        .padding(.horizontal, 26)
                        .padding(.top, 14)
                }

                Spacer(minLength: 18)

                controls
                    .padding(.bottom, 30)
            }
        }
        .task {
            voice.onFinish = { text in
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                HapticManager.shared.success()
                // Let the orb draw the sentence in before the hand-off, so the
                // screen closing reads as "got it", not as being cut off.
                finishing = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    onCaptured(trimmed)
                    dismiss()
                }
            }
            appeared = true
            // Start listening immediately. Reaching this screen — by gesture or
            // by tapping Record — has already said what the user wants.
            await voice.start()
        }
        // A faint tick as each word is recognised — the orb kicks at the same
        // moment, so hand and eye both feel the app hearing. Throttled, since
        // a fast talker's words would otherwise buzz.
        .onChange(of: wordCount) { old, new in
            guard new > old, isListening, Date().timeIntervalSince(lastWordTick) > 0.18 else { return }
            lastWordTick = Date()
            HapticManager.shared.pulse(0.35)
        }
        .onChange(of: voice.state) { _, s in
            switch s {
            case .denied(let why):      notice = why
            case .unavailable(let why): notice = why
            default:                    notice = nil
            }
        }
        .onDisappear { voice.cancel() }
    }

    // MARK: Pieces

    private var header: some View {
        HStack {
            Button {
                HapticManager.shared.tap()
                voice.cancel()
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .frame(width: 38, height: 38)
                    .background(AppTheme.cardDark, in: Circle())
            }
            .accessibilityLabel(loc("a11y.back"))
            .frame(width: 72, alignment: .leading)
            Spacer()
            Text(loc("voice.title"))
                .font(.system(.callout, weight: .semibold))
                .foregroundStyle(AppTheme.textPrimary)
            Spacer()
            languageMenu
                .frame(width: 72, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    /// The language being listened for, switchable mid-sentence: picking a new
    /// one restarts listening in it, since a recogniser cannot change language
    /// while it runs.
    private var languageMenu: some View {
        Menu {
            Picker(loc("voice.lang_title"), selection: Binding(
                get: { voiceLanguage },
                set: { switchLanguage(to: $0) }
            )) {
                ForEach(VoiceLanguage.allCases) { Text($0.label).tag($0) }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "waveform")
                    .font(.system(.caption, weight: .bold))
                Text(voiceLanguage.code)
                    .font(.system(.footnote, weight: .bold))
            }
            .foregroundStyle(AppTheme.textPrimary)
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(AppTheme.cardDark, in: Capsule())
        }
        .accessibilityLabel(loc("voice.lang_title"))
        .accessibilityValue(voiceLanguage.label)
    }

    private func switchLanguage(to language: VoiceLanguage) {
        guard language != voiceLanguage, !finishing else { return }
        HapticManager.shared.select()
        voiceLanguage = language
        VoiceLanguage.saved = language
        if isListening {
            // Drop what was heard in the old language rather than sending it.
            voice.cancel()
            voice.reset()
            Task { await voice.start() }
        }
    }

    private var statusText: String {
        if notice != nil { return loc("voice.status_problem") }
        if isListening { return voice.level > 0.06 ? loc("voice.status_hearing") : loc("voice.status_listening") }
        return voice.transcript.isEmpty ? loc("voice.status_tap") : loc("voice.status_done")
    }

    @ViewBuilder
    private var transcriptArea: some View {
        if voice.transcript.isEmpty {
            // An example rather than an empty void: the parser understands a
            // whole sentence, and nothing on screen would otherwise say so.
            // In the language being listened for, so the example is something
            // the recogniser will actually understand.
            Text(LanguageManager.shared.withLanguage(voiceLanguage.spoken) { loc("voice.example") })
                .font(.system(.title3, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(voice.transcript)
                .font(.system(.title, weight: .semibold))
                .foregroundStyle(AppTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .animation(.easeOut(duration: 0.15), value: voice.transcript)
        }
    }

    private var controls: some View {
        HStack(spacing: 26) {
            // Secondary: send what has been heard so far, without waiting for
            // the silence timer. Someone who has finished talking should not
            // have to wait to be believed.
            circleButton(icon: "text.badge.checkmark", label: loc("a11y.send_now"),
                         enabled: !voice.transcript.isEmpty) {
                voice.stop()
            }

            VStack(spacing: 9) {
                Button {
                    toggleListening()
                } label: {
                    ZStack {
                        if isListening {
                            Circle()
                                .fill(AppTheme.voiceGlow.opacity(0.16))
                                .frame(width: 108 + voice.level * 46,
                                       height: 108 + voice.level * 46)
                                .blur(radius: 6)
                                .animation(.easeOut(duration: 0.12), value: voice.level)
                        }
                        Circle()
                            .fill(isListening ? AppTheme.redFill : AppTheme.accentFill)
                            .frame(width: 84, height: 84)
                            .shadow(color: (isListening ? AppTheme.redFill : AppTheme.accentFill).opacity(0.35),
                                    radius: 16, y: 6)
                        Image(systemName: isListening ? "stop.fill" : "mic.fill")
                            .font(.system(.title, weight: .semibold))
                            .foregroundStyle(AppTheme.onVividFill)
                    }
                }
.accessibilityLabel(loc(isListening ? "voice.stop" : "voice.start"))
                .buttonStyle(ScaleButtonStyle())

                Text(isListening ? loc("voice.tap_stop") : loc("voice.tap_speak"))
                    .font(.system(.caption2, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary)
            }

            circleButton(icon: "xmark", label: loc("common.cancel"), enabled: true) {
                voice.cancel()
                dismiss()
            }
        }
    }

    private func circleButton(icon: String, label: String, enabled: Bool,
                              action: @escaping () -> Void) -> some View {
        Button {
            HapticManager.shared.tap(); action()
        } label: {
            Image(systemName: icon)
                .font(.system(.callout, weight: .semibold))
                .foregroundStyle(enabled ? AppTheme.textPrimary : AppTheme.textSecondary.opacity(0.35))
                .frame(width: 52, height: 52)
                .background(AppTheme.cardDark, in: Circle())
        }
        .buttonStyle(ScaleButtonStyle())
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

/// The listening indicator — and a control: tap it to start or stop, press it
/// and it gives, drag it and it leans toward your finger.
///
/// Built from the same blurred, counter-rotating conic gradients as before (two
/// layers crossing at different speeds never repeat, so the surface reads as
/// moving rather than spinning), with four things added so it answers the user
/// instead of just looping:
///
///   • The silhouette is a living blob, not a circle. Three sine harmonics push
///     the edge in and out; quiet, it barely stirs, speaking, it ripples.
///   • Every new word lands as a kick: a quick swell of size and wobble that
///     decays over a quarter second, so recognised speech visibly arrives.
///   • Speed follows the voice. Swirl, wobble and the sound rings accumulate
///     phase at a rate set by the level, so talking speeds the orb up and a
///     pause lets it settle — without the jump backwards you get from
///     multiplying the clock by a changing speed.
///   • Rings travel outward while it listens, like sound leaving the orb, and
///     brighten with the voice.
///
/// When the sentence is done it draws in and swirls fast before the screen
/// closes, so the hand-off to Ask DiPo is felt rather than cut. Reduce Motion
/// keeps the colour and the level response and drops the rings, sparks, lean
/// and speed-up.
private struct VoiceOrb: View {
    enum Mode: Equatable { case idle, listening, finishing }

    let level: Double
    let mode: Mode
    /// Words recognised so far. Each increase kicks the orb.
    let wordCount: Int
    var onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var motion = OrbMotion()
    @State private var kickAt: TimeInterval = 0
    @State private var tapAt: TimeInterval = 0
    @State private var lean: CGSize = .zero
    @State private var pressed = false

    /// Gradient stops. First and last match so the conic seam is invisible.
    private var warm: [Color] {
        [AppTheme.voiceGlow, AppTheme.accentFill, AppTheme.teal,
         AppTheme.voiceGlow.opacity(0.85), AppTheme.voiceGlow]
    }
    private var cool: [Color] {
        [AppTheme.blue, AppTheme.voiceGlow.opacity(0.9), AppTheme.teal,
         AppTheme.accentFill.opacity(0.8), AppTheme.blue]
    }

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let target = mode == .listening ? min(level * 1.8, 1) : (mode == .finishing ? 0.85 : 0)
                let m = motion.step(at: t, toward: target,
                                    boost: mode == .finishing ? 5 : 0,
                                    calm: reduceMotion)
                orb(size: size, t: t, m: m)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .scaleEffect(pressed ? 0.93 : 1)
        .scaleEffect(mode == .finishing ? 0.86 : 1)
        .animation(.spring(response: 0.28, dampingFraction: 0.55), value: pressed)
        .animation(.spring(response: 0.42, dampingFraction: 0.6), value: mode)
        .contentShape(Circle())
        .gesture(pressAndLean)
        .onChange(of: wordCount) { old, new in
            if new > old { kickAt = Date().timeIntervalSinceReferenceDate }
        }
        .accessibilityElement()
        .accessibilityLabel(loc(mode == .listening ? "voice.stop" : "voice.start"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onTap() }
    }

    // MARK: Layers

    private func orb(size: CGFloat, t: TimeInterval, m: OrbMotion.Frame) -> some View {
        let live: Bool = mode != .idle
        // A word arriving: a swell that decays in about a quarter second.
        let kick: Double = reduceMotion ? 0 : exp(-max(t - kickAt, 0) * 6)
        // A tap: one damped bounce, so the orb answers the finger.
        let since: Double = max(t - tapAt, 0)
        let bounce: Double = since < 1 ? exp(-since * 7) * sin(since * 26) * 0.045 : 0
        var wobble: Double = reduceMotion ? 0.006 : 0.016
        wobble += m.amp * 0.05 + kick * 0.045
        if mode == .finishing { wobble += 0.03 }
        let breathe: Double = 1 + sin(t * 0.9) * 0.012
        let grow: Double = breathe * (1 + m.amp * 0.06 + kick * 0.04 + bounce)

        return ZStack {
            if live && !reduceMotion { ripples(m: m, wobble: wobble) }
            bloom(size: size, live: live, amp: m.amp, kick: kick)
            if live && !reduceMotion { sparks(size: size, t: t, m: m) }
            core(size: size, m: m, kick: kick, wobble: wobble)
                .saturation(live ? 1 : 0.6)
                .scaleEffect(grow)
                .shadow(color: AppTheme.voiceGlow.opacity(0.28 + m.amp * 0.22), radius: 22)
                .offset(lean)
        }
    }

    /// Sound leaving the orb: blob-shaped echoes travelling outward.
    private func ripples(m: OrbMotion.Frame, wobble: Double) -> some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                let p: Double = (m.ripple + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                let alpha: Double = (1 - p) * (0.10 + m.amp * 0.45)
                let width: CGFloat = CGFloat(1 + (1 - p) * 2.5)
                OrbBlob(phase: m.wobble + Double(i) * 1.7, amount: wobble * 0.7)
                    .stroke(AppTheme.voiceGlow.opacity(alpha), lineWidth: width)
                    .scaleEffect(CGFloat(0.94 + p * 0.46))
            }
        }
    }

    /// Bloom escaping the silhouette, so the orb sits IN the screen.
    private func bloom(size: CGFloat, live: Bool, amp: Double, kick: Double) -> some View {
        let alpha: Double = live ? 0.20 + amp * 0.20 + kick * 0.08 : 0.08
        let scale: CGFloat = CGFloat(1.06 + amp * 0.12 + kick * 0.05)
        return Circle()
            .fill(AppTheme.voiceGlow.opacity(alpha))
            .blur(radius: size * 0.155)
            .scaleEffect(scale)
    }

    /// Sparks orbiting just outside the edge, quickening with the swirl.
    private func sparks(size: CGFloat, t: TimeInterval, m: OrbMotion.Frame) -> some View {
        ZStack {
            ForEach(0..<7, id: \.self) { i in
                let seed: Double = Double(i) * 0.9
                let turn: Double = 0.30 + 0.07 * Double(i % 3)
                let angle: Double = m.spinA * .pi / 180 * turn + seed * 2.3
                let reach: Double = 0.54 + 0.04 * sin(t * 1.3 + seed * 2) + m.amp * 0.07
                let radius: Double = Double(size) * reach
                let twinkle: Double = 0.55 + 0.45 * sin(t * 2.1 + seed * 3)
                let dot: CGFloat = CGFloat(3 + i % 3)
                Circle()
                    .fill(AppTheme.voiceGlow)
                    .frame(width: dot, height: dot)
                    .blur(radius: 0.6)
                    .opacity((0.22 + m.amp * 0.6) * twinkle)
                    .offset(x: CGFloat(cos(angle) * radius), y: CGFloat(sin(angle) * radius))
            }
        }
    }

    /// The liquid interior, clipped to the living blob.
    private func core(size: CGFloat, m: OrbMotion.Frame, kick: Double, wobble: Double) -> some View {
        let lobe: CGFloat = size * 0.44
        let lobeX: CGFloat = CGFloat(cos(m.wobble * 0.73)) * size * 0.19
        let lobeY: CGFloat = CGFloat(sin(m.wobble * 0.91 + 0.6)) * size * 0.17
        let light = UnitPoint(x: 0.34 + lean.width / size * 0.9,
                              y: 0.28 + lean.height / size * 0.9)
        let blur: CGFloat = size * CGFloat(0.118 - m.amp * 0.03)   // tightens as the voice rises
        let shape = OrbBlob(phase: m.wobble, amount: wobble)
        let rim = LinearGradient(colors: [.white.opacity(0.55), .clear, .white.opacity(0.15)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing)

        return ZStack {
            Circle()
                .fill(AngularGradient(colors: warm, center: .center, angle: .degrees(m.spinA)))
            Circle()
                .fill(AngularGradient(colors: cool, center: .center, angle: .degrees(-m.spinB + 140)))
                .blendMode(.screen)
                .opacity(0.50 + m.amp * 0.32)
            // A bright lobe drifting inside, so the interior moves on its own
            // path instead of only turning with the gradients.
            Circle()
                .fill(AppTheme.voiceGlow.opacity(0.45 + m.amp * 0.35))
                .frame(width: lobe, height: lobe)
                .offset(x: lobeX, y: lobeY)
                .blendMode(.screen)
            // Off-centre highlight that follows the lean, so the orb seems to
            // turn its lit side toward the finger.
            RadialGradient(colors: [.white.opacity(0.55 + kick * 0.15), .clear],
                           center: light, startRadius: 2, endRadius: size * 0.68)
                .blendMode(.softLight)
        }
        // Oversized before the blur so the soft edge falls OUTSIDE the clip;
        // blurring at the clip size frays the silhouette into a smudge.
        .scaleEffect(1.34)
        .blur(radius: blur)
        .clipShape(shape)
        // Rim light: gives the blob a surface instead of a cut-out edge.
        .overlay(shape.stroke(rim, lineWidth: 1.2).blendMode(.softLight))
    }

    // MARK: Touch

    /// Press squeezes, drag leans (a little, with resistance), release springs
    /// back. A release that barely moved counts as a tap.
    private var pressAndLean: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !pressed { pressed = true }
                guard !reduceMotion else { return }
                let pull = { (d: CGFloat) in max(min(d * 0.18, 18), -18) }
                lean = CGSize(width: pull(value.translation.width), height: pull(value.translation.height))
            }
            .onEnded { value in
                let moved = hypot(value.translation.width, value.translation.height)
                withAnimation(.spring(response: 0.45, dampingFraction: 0.5)) {
                    pressed = false
                    lean = .zero
                }
                if moved < 12 {
                    tapAt = Date().timeIntervalSinceReferenceDate
                    onTap()
                }
            }
    }
}

/// Phase the orb accumulates frame by frame. A reference type in `@State`:
/// TimelineView redraws every frame, and a speed that follows the voice has to
/// be integrated — the clock times a changing speed would jump backwards
/// whenever the level dropped.
private final class OrbMotion {
    struct Frame {
        let amp: Double
        let spinA: Double
        let spinB: Double
        let wobble: Double
        let ripple: Double
    }

    private var last: TimeInterval = 0
    private var amp: Double = 0
    private var spinA: Double = 0
    private var spinB: Double = 140
    private var wobble: Double = 0
    private var ripple: Double = 0

    func step(at t: TimeInterval, toward target: Double, boost: Double, calm: Bool) -> Frame {
        // Capped so a frame that arrives late (app returning from background)
        // does not fling the swirl half a turn.
        let dt = last == 0 ? 0 : min(max(t - last, 0), 1.0 / 20)
        last = t
        // Fast attack, slow release: syllables land at once, silence eases in.
        let rate = target > amp ? 16.0 : 3.5
        amp += (target - amp) * (1 - exp(-rate * dt))

        let speed = calm ? 1 : 1 + amp * 2.4 + boost
        spinA = (spinA + dt * 17 * speed).truncatingRemainder(dividingBy: 360 * 100)
        spinB = (spinB + dt * 26 * speed).truncatingRemainder(dividingBy: 360 * 100)
        wobble += dt * (calm ? 0.6 : 0.9 + amp * 3.2 + boost * 0.8)
        ripple = (ripple + dt * (0.32 + amp * 0.85 + boost * 0.2)).truncatingRemainder(dividingBy: 1)
        return Frame(amp: amp, spinA: spinA, spinB: spinB, wobble: wobble, ripple: ripple)
    }
}

/// A circle whose radius is nudged by three sine harmonics. The sum of their
/// weights is 1 and the base radius shrinks by `amount`, so the deformed edge
/// never leaves the frame it was given.
private struct OrbBlob: Shape {
    var phase: Double
    var amount: Double

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let base = Double(min(rect.width, rect.height)) / 2 * (1 - amount)
        let steps = 96
        var path = Path()
        for i in 0...steps {
            let a = Double(i) / Double(steps) * 2 * .pi
            let d = sin(2 * a + phase * 1.3) * 0.45
                  + sin(3 * a - phase * 1.7 + 1.1) * 0.35
                  + sin(5 * a + phase * 2.3 + 2.4) * 0.20
            let r = base * (1 + amount * d)
            let point = CGPoint(x: Double(c.x) + cos(a) * r, y: Double(c.y) + sin(a) * r)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

/// A captured sentence on its way to Ask DiPo. `String` has no identity, and
/// `sheet(item:)` needs one.
struct SpokenEntry: Identifiable {
    let id = UUID()
    let text: String
}
