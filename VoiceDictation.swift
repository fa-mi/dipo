import SwiftUI
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

    private var isListening: Bool { voice.isListening }

    var body: some View {
        ZStack {
            AppTheme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                Text(statusText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)
                    .frame(height: 18)
                    .id(statusText)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.18), value: statusText)
                    .padding(.top, 6)

                Spacer(minLength: 12)

                VoiceOrb(level: voice.level, active: isListening)
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
                onCaptured(trimmed)
                dismiss()
            }
            appeared = true
            // Start listening immediately. Reaching this screen — by gesture or
            // by tapping Record — has already said what the user wants.
            await voice.start()
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
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .frame(width: 38, height: 38)
                    .background(AppTheme.cardDark, in: Circle())
            }
            Spacer()
            Text(loc("voice.title"))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AppTheme.textPrimary)
            Spacer()
            // Balances the back button so the title sits centred.
            Color.clear.frame(width: 38, height: 38)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
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
            Text(loc("voice.example"))
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(voice.transcript)
                .font(.system(size: 26, weight: .semibold))
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
            circleButton(icon: "text.badge.checkmark",
                         enabled: !voice.transcript.isEmpty) {
                voice.stop()
            }

            VStack(spacing: 9) {
                Button {
                    HapticManager.shared.tap()
                    if isListening {
                        voice.stop()
                    } else {
                        voice.reset()
                        Task { await voice.start() }
                    }
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
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(AppTheme.onVividFill)
                    }
                }
                .buttonStyle(ScaleButtonStyle())

                Text(isListening ? loc("voice.tap_stop") : loc("voice.tap_speak"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary)
            }

            circleButton(icon: "xmark", enabled: true) {
                voice.cancel()
                dismiss()
            }
        }
    }

    private func circleButton(icon: String, enabled: Bool,
                              action: @escaping () -> Void) -> some View {
        Button {
            HapticManager.shared.tap(); action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(enabled ? AppTheme.textPrimary : AppTheme.textSecondary.opacity(0.35))
                .frame(width: 52, height: 52)
                .background(AppTheme.cardDark, in: Circle())
        }
        .buttonStyle(ScaleButtonStyle())
        .disabled(!enabled)
    }
}

/// The listening indicator.
///
/// Two conic gradients turning at different speeds and in opposite directions,
/// heavily blurred and then clipped to a circle. Blur first, clip second: that
/// order is what gives a soft, liquid interior behind a crisp edge — blurring
/// after the clip would fray the silhouette into a smudge.
///
/// The counter-rotation is the whole trick. One turning gradient just spins;
/// two crossing each other at different rates never repeat the same way twice,
/// so the surface reads as moving rather than rotating.
///
/// Voice drives scale, blur and the weight of the second layer together — a
/// single one of those on its own reads as a pulse, which is a heartbeat, not
/// a voice. It keeps breathing while the room is quiet, because an orb frozen
/// at rest reads as a hung screen.
///
/// Hues stay inside DiPo's palette — green through teal to sky — rather than
/// the blue-to-pink of the reference. They are analogous, so they blend into
/// iridescence instead of mud.
private struct VoiceOrb: View {
    let level: Double
    let active: Bool

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
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let amp = active ? min(level * 1.8, 1.0) : 0
            // Never fully still.
            let breathe = 1 + sin(t * 0.9) * 0.012

            ZStack {
                // Bloom escaping the silhouette, so the orb sits IN the screen
                // rather than on top of it.
                Circle()
                    .fill(AppTheme.voiceGlow.opacity(active ? 0.20 + amp * 0.18 : 0.10))
                    .blur(radius: 34)
                    .scaleEffect(1.06 + amp * 0.10)

                ZStack {
                    Circle()
                        .fill(AngularGradient(colors: warm, center: .center,
                                              angle: .degrees(t * 17)))
                    Circle()
                        .fill(AngularGradient(colors: cool, center: .center,
                                              angle: .degrees(-t * 26 + 140)))
                        .blendMode(.screen)
                        .opacity(0.52 + amp * 0.30)

                    // Off-centre highlight. Without it the disc is evenly lit
                    // and reads flat; a light source gives it a near side.
                    RadialGradient(colors: [.white.opacity(0.55), .clear],
                                   center: UnitPoint(x: 0.34, y: 0.28),
                                   startRadius: 2, endRadius: 150)
                        .blendMode(.softLight)
                }
                // Oversized before the blur so the soft edge falls OUTSIDE the
                // clip. Blurring at the exact clip size pulls transparency
                // inward and frays the silhouette into a smudge.
                .scaleEffect(1.34)
                .blur(radius: 26 - amp * 7)     // tightens as the voice rises
                .clipShape(Circle())
                .scaleEffect(breathe * (1 + amp * 0.055))
                .shadow(color: AppTheme.voiceGlow.opacity(0.30), radius: 22)
            }
            .animation(.easeOut(duration: 0.14), value: amp)
        }
    }
}

/// A captured sentence on its way to Ask DiPo. `String` has no identity, and
/// `sheet(item:)` needs one.
struct SpokenEntry: Identifiable {
    let id = UUID()
    let text: String
}
