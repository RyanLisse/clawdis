import AVFAudio
import Foundation
import Observation
import OSLog
import Speech
import SwabbleKit

private let audioLogger = Logger(subsystem: "com.clawdis", category: "VoiceWakeAudio")
private nonisolated(unsafe) var bufferCount = 0

private nonisolated func makeAudioTapAppendCallback(
    request: SFSpeechAudioBufferRecognitionRequest)
    -> AVAudioNodeTapBlock
{
    { buffer, _ in
        bufferCount += 1
        let frames = buffer.frameLength
        let rate = buffer.format.sampleRate
        let ch = buffer.format.channelCount

        if bufferCount % 50 == 1 {
            audioLogger.info("buf #\(bufferCount): fr=\(frames), rate=\(rate), ch=\(ch)")
        }

        request.append(buffer)
    }
}

@MainActor
@Observable
final class VoiceWakeManager: NSObject {
    var isEnabled: Bool = false
    var isListening: Bool = false
    var statusText: String = "Off"
    var triggerWords: [String] = VoiceWakePreferences.loadTriggerWords()
    var lastTriggeredCommand: String?

    private let audioEngine = AVAudioEngine()
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    private var lastDispatched: String?
    private var onCommand: (@Sendable (String) async -> Void)?
    private var userDefaultsObserver: NSObjectProtocol?

    override init() {
        super.init()
        self.triggerWords = VoiceWakePreferences.loadTriggerWords()
        self.userDefaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main,
            using: { [weak self] _ in
                Task { @MainActor in
                    self?.handleUserDefaultsDidChange()
                }
            })
    }

    @MainActor deinit {
        if let userDefaultsObserver = self.userDefaultsObserver {
            NotificationCenter.default.removeObserver(userDefaultsObserver)
        }
    }

    var activeTriggerWords: [String] {
        VoiceWakePreferences.sanitizeTriggerWords(self.triggerWords)
    }

    private func handleUserDefaultsDidChange() {
        let updated = VoiceWakePreferences.loadTriggerWords()
        if updated != self.triggerWords {
            self.triggerWords = updated
        }
    }

    func configure(onCommand: @escaping @Sendable (String) async -> Void) {
        self.onCommand = onCommand
    }

    func setEnabled(_ enabled: Bool) {
        self.isEnabled = enabled
        self.statusText = enabled ? "Starting..." : "Off"
        if enabled {
            Task { await self.start() }
        } else {
            self.stop()
        }
    }

    func start() async {
        guard self.isEnabled else {
            self.statusText = "Not enabled"
            return
        }
        if self.isListening {
            self.statusText = "Already listening"
            return
        }

        if ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] != nil ||
            ProcessInfo.processInfo.environment["SIMULATOR_UDID"] != nil
        {
            self.isListening = false
            self.statusText = "Not supported on Simulator"
            return
        }

        self.statusText = "Requesting mic..."

        let micOk = await Self.requestMicrophonePermission()
        guard micOk else {
            self.statusText = "Mic denied"
            self.isListening = false
            return
        }

        self.statusText = "Requesting speech..."

        let speechOk = await Self.requestSpeechPermission()
        guard speechOk else {
            self.statusText = "Speech denied"
            self.isListening = false
            return
        }

        self.statusText = "Configuring audio..."

        do {
            try Self.configureAudioSession()
            self.statusText = "Starting recognition..."
            try self.startRecognition()
            self.isListening = true
            self.statusText = "Listening"
        } catch {
            self.isListening = false
            self.statusText = "Start failed: \(error.localizedDescription)"
        }
    }

    func stop() {
        self.isEnabled = false
        self.isListening = false
        self.statusText = "Off"
        self.stopRecognition()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Temporarily releases the microphone so other subsystems (e.g. camera video capture) can record audio.
    /// Returns `true` when listening was active and was suspended.
    func suspendForExternalAudioCapture() -> Bool {
        guard self.isEnabled, self.isListening else { return false }

        self.isListening = false
        self.statusText = "Paused"
        self.stopRecognition()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return true
    }

    func resumeAfterExternalAudioCapture(wasSuspended: Bool) {
        guard wasSuspended else { return }
        Task { await self.start() }
    }

    private func stopRecognition() {
        self.recognitionTask?.cancel()
        self.recognitionTask = nil
        self.recognitionRequest?.endAudio()
        self.recognitionRequest = nil
        self.audioEngine.inputNode.removeTap(onBus: 0)
        self.audioEngine.stop()
        self.speechRecognizer = nil
    }

    private func startRecognition() throws {
        bufferCount = 0
        self.stopRecognition()

        self.speechRecognizer = SFSpeechRecognizer()
        guard let recognizer = self.speechRecognizer else {
            audioLogger.error("SFSpeechRecognizer() returned nil")
            throw NSError(domain: "VoiceWake", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Speech recognizer unavailable",
            ])
        }
        audioLogger.info("Recognizer created, available=\(recognizer.isAvailable)")

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.recognitionRequest = request

        let inputNode = self.audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        let rate = recordingFormat.sampleRate
        let ch = recordingFormat.channelCount
        let bits = recordingFormat.streamDescription.pointee.mBitsPerChannel
        audioLogger.info("Audio format: rate=\(rate), ch=\(ch), bits=\(bits)")

        guard ch > 0, rate > 0 else {
            audioLogger.error("Invalid audio format")
            throw NSError(domain: "VoiceWake", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Audio input not available",
            ])
        }

        let tapBlock = makeAudioTapAppendCallback(request: request)
        inputNode.installTap(
            onBus: 0,
            bufferSize: 2048,
            format: recordingFormat,
            block: tapBlock)

        self.audioEngine.prepare()
        try self.audioEngine.start()
        audioLogger.info("Audio engine started")

        let handler = self.makeRecognitionResultHandler()
        self.recognitionTask = recognizer.recognitionTask(with: request, resultHandler: handler)
        audioLogger.info("Recognition task created")
    }

    private nonisolated func makeRecognitionResultHandler()
        -> @Sendable (SFSpeechRecognitionResult?, Error?) -> Void
    {
        { [weak self] result, error in
            if let error {
                let code = (error as NSError).code
                audioLogger.error("Recog err: \(error.localizedDescription), code=\(code), bufs=\(bufferCount)")
            }
            if let result {
                let text = String(result.bestTranscription.formattedString.prefix(50))
                audioLogger.info("Recog result: final=\(result.isFinal), text=\(text)")
            }

            let transcript = result?.bestTranscription.formattedString
            let segments = result.flatMap { result in
                transcript.map { WakeWordSpeechSegments.from(transcription: result.bestTranscription, transcript: $0) }
            } ?? []
            let errorText = error?.localizedDescription

            Task { @MainActor in
                self?.handleRecognitionCallback(transcript: transcript, segments: segments, errorText: errorText)
            }
        }
    }

    private func handleRecognitionCallback(transcript: String?, segments: [WakeWordSegment], errorText: String?) {
        if let errorText {
            self.statusText = "Recognizer error: \(errorText)"
            self.isListening = false

            let shouldRestart = self.isEnabled
            if shouldRestart {
                Task {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    await self.start()
                }
            }
            return
        }

        guard let transcript else { return }
        guard let cmd = self.extractCommand(from: transcript, segments: segments) else { return }

        if cmd == self.lastDispatched { return }
        self.lastDispatched = cmd
        self.lastTriggeredCommand = cmd
        self.statusText = "Triggered"

        Task { [weak self] in
            guard let self else { return }
            await self.onCommand?(cmd)
            await self.startIfEnabled()
        }
    }

    private func startIfEnabled() async {
        let shouldRestart = self.isEnabled
        if shouldRestart {
            await self.start()
        }
    }

    private func extractCommand(from transcript: String, segments: [WakeWordSegment]) -> String? {
        Self.extractCommand(from: transcript, segments: segments, triggers: self.activeTriggerWords)
    }

    nonisolated static func extractCommand(
        from transcript: String,
        segments: [WakeWordSegment],
        triggers: [String],
        minPostTriggerGap: TimeInterval = 0.45) -> String?
    {
        let config = WakeWordGateConfig(triggers: triggers, minPostTriggerGap: minPostTriggerGap)
        return WakeWordGate.match(transcript: transcript, segments: segments, config: config)?.command
    }

    private static func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [
            .duckOthers,
            .mixWithOthers,
            .allowBluetoothHFP,
            .defaultToSpeaker,
        ])
        try session.setActive(true, options: [])
    }

    private nonisolated static func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation(isolation: nil) { cont in
            AVAudioApplication.requestRecordPermission { ok in
                cont.resume(returning: ok)
            }
        }
    }

    private nonisolated static func requestSpeechPermission() async -> Bool {
        await withCheckedContinuation(isolation: nil) { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }
}

#if DEBUG
extension VoiceWakeManager {
    func _test_handleRecognitionCallback(transcript: String?, segments: [WakeWordSegment], errorText: String?) {
        self.handleRecognitionCallback(transcript: transcript, segments: segments, errorText: errorText)
    }
}
#endif
