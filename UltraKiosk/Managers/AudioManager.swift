import AVFoundation
import Combine
import Speech
import Porcupine

enum APIError: Error, LocalizedError {
    case invalidURL
    case httpError(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .httpError(let code):
            return "HTTP Error: \(code)"
        case .invalidResponse:
            return "Invalid response format"
        }
    }
}

extension APIError: Equatable {}

/// Closure type used to perform a URL data load.
/// Defaults to URLSession.shared; swap in a mock closure during unit tests.
typealias URLDataLoader = (URLRequest) async throws -> (Data, URLResponse)

class AudioManager: NSObject, ObservableObject {
    
    private let settings = SettingsManager.shared
    
    @Published var isRecording = false
    @Published var homeAssistantConnected = false
    @Published var isSpeaking = false
    
    // Configure preferred recording format
    private var preferredNumChannels: Int = 1 // 1 = mono, 2 = stereo
    
    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var player: AVPlayer?
    private var mixerNode: AVAudioMixerNode?
    private var playbackObserver: NSObjectProtocol?
    private var porcupine: Porcupine?
    private var audioBuffer: [Int16] = []

    private var silenceTimer: Timer?
    private var lastRecognizedText: String = ""
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-AU"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    // SFSpeech-based wake word listener (used when Porcupine access key is empty).
    // Runs a continuous on-device recognition session and scans partial results
    // for the configured wake phrase. iOS limits recognition sessions to ~1 minute
    // so the listener auto-restarts.
    private var wakeRequest: SFSpeechAudioBufferRecognitionRequest?
    private var wakeTask: SFSpeechRecognitionTask?
    private var wakeRestartTimer: Timer?
    private var wakeListenerActive = false
    
    private let synthesizer = AVSpeechSynthesizer()
    private var currentUtterance: AVSpeechUtterance?

    override init() {
        super.init()
        
        // Set synthesizer delegate
        synthesizer.delegate = self

        SFSpeechRecognizer.requestAuthorization { authStatus in
            if authStatus == .authorized {
                AppLogger.speech.info("Speech recognition authorized by user")
            } else {
                AppLogger.speech.warning("Speech recognition permission declined by user")
            }
        }
    }
    
    // Plays a short feedback sound. Preferred: bundled asset (e.g. "bing.caf").
    func playFeedbackSound(assetName: String = "bing", assetExtension: String = "caf") {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setActive(true)
            try session.overrideOutputAudioPort(.speaker)
        } catch {
            AppLogger.audio.error("Audio session activation/override failed for feedback: \(String(describing: error))")
        }
        
        if let url = Bundle.main.url(forResource: assetName, withExtension: assetExtension) {
            let item = AVPlayerItem(url: url)
            player = AVPlayer(playerItem: item)
            
            // Add observer for playback completion
            playbackObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                self?.handlePlaybackCompleted()
            }

            player?.play()
            return
        }
    }

    private func handlePlaybackCompleted() {
        // Remove the observer
        if let observer = playbackObserver {
            NotificationCenter.default.removeObserver(observer)
            playbackObserver = nil
        }
        
        player = nil
        
        // Restore audio session for recording
        do {
            let session = AVAudioSession.sharedInstance()
            // Remove the speaker override to restore normal routing
            try session.overrideOutputAudioPort(.none)
            // Reconfigure the session for recording
            setupAudioSession()
        } catch {
            AppLogger.audio.error("Failed to restore audio session after playback: \(String(describing: error))")
        }
        
        // Resume recording if it was active before playback
        if isRecording {
            stopRecording()
            
            // Give a small delay to ensure cleanup is complete
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.startRecording()
            }
        }
    }
    
    func setupAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord,
                                         mode: .default,
                                         options: [.defaultToSpeaker, .allowBluetoothA2DP])
            
            // Apply preferred format settings
            try audioSession.setPreferredSampleRate(Double(settings.voiceSampleRate))
            if audioSession.isInputAvailable {
                try? audioSession.setPreferredInputNumberOfChannels(preferredNumChannels)
            }
            
            try audioSession.setActive(true)
        } catch {
            AppLogger.audio.error("Audio session setup failed: \(String(describing: error))")
        }
    }
    
    func startRecording() {
        audioEngine = AVAudioEngine()
        inputNode = audioEngine?.inputNode
        
        guard let audioEngine = audioEngine, let inputNode = inputNode else {
            return
        }
        
        // Desired recording format that downstream consumers expect
        let desiredFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: Double(settings.voiceSampleRate),
                                          channels: AVAudioChannelCount(preferredNumChannels),
                                          interleaved: false)
        
        // Build graph: input -> mixer -> mainMixer
        let mixer = AVAudioMixerNode()
        mixerNode = mixer
        audioEngine.attach(mixer)
        
        let hardwareFormat = inputNode.outputFormat(forBus: 0)
        audioEngine.connect(inputNode, to: mixer, format: hardwareFormat)
        audioEngine.connect(mixer, to: audioEngine.mainMixerNode, format: desiredFormat)

        // Prevent microphone monitoring through speakers while still allowing taps to receive data
        audioEngine.mainMixerNode.outputVolume = 0
        
        // Wake word strategy:
        //   - If Porcupine access key is set, use Porcupine (low CPU, dedicated wake-word DSP).
        //   - Otherwise use SFSpeech continuous mode listening for settings.wakePhrase.
        // Push-to-talk via triggerListening() always works regardless.
        let key = settings.porcupineAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            do {
                porcupine = try Porcupine(
                    accessKey: key,
                    keywords: [Porcupine.BuiltInKeyword.alexa],
                )
                AppLogger.audio.info("Porcupine wake word enabled")
            } catch {
                AppLogger.audio.error("Failed to initialize Porcupine: \(String(describing: error))")
            }
        } else {
            AppLogger.audio.info("Porcupine key empty - using SFSpeech wake-word listener")
        }
        
        // Install tap on mixer so we receive buffers in the desired format (engine converts)
        mixer.installTap(onBus: 0, bufferSize: 512, format: desiredFormat) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer)
        }
        
        do {
            try audioEngine.start()
            DispatchQueue.main.async {
                self.isRecording = true
            }
        } catch {
            AppLogger.audio.error("Failed to start audio engine: \(String(describing: error))")
        }

        // If Porcupine isn't loaded, start the SFSpeech wake-word listener.
        if porcupine == nil {
            startWakeListener()
        }
    }

    func stopRecording() {
        stopWakeListener()
        audioEngine?.stop()

        mixerNode?.removeTap(onBus: 0)
        mixerNode = nil
        inputNode = nil
        audioEngine = nil

        porcupine?.delete()
        porcupine = nil;

        DispatchQueue.main.async {
            self.isRecording = false
        }
    }

    // MARK: - SFSpeech wake-word listener

    /// Starts a long-running SFSpeech recognition session that scans partial
    /// transcripts for `settings.wakePhrase`. iOS limits a single session to
    /// ~1 minute so we restart it on a timer.
    private func startWakeListener() {
        guard speechRecognizer?.isAvailable == true else {
            AppLogger.speech.error("Wake listener: SFSpeechRecognizer unavailable")
            return
        }
        wakeListenerActive = true
        scheduleWakeRestart()
        startWakeSession()
    }

    private func stopWakeListener() {
        wakeListenerActive = false
        wakeRestartTimer?.invalidate()
        wakeRestartTimer = nil
        wakeRequest?.endAudio()
        wakeRequest = nil
        wakeTask?.cancel()
        wakeTask = nil
    }

    private func scheduleWakeRestart() {
        wakeRestartTimer?.invalidate()
        // 50s — comfortably under iOS' ~60s session limit.
        wakeRestartTimer = Timer.scheduledTimer(withTimeInterval: 50.0, repeats: true) { [weak self] _ in
            self?.restartWakeSession()
        }
    }

    private func restartWakeSession() {
        guard wakeListenerActive else { return }
        AppLogger.speech.debug("Wake listener: restarting session (iOS time limit)")
        wakeRequest?.endAudio()
        wakeRequest = nil
        wakeTask?.cancel()
        wakeTask = nil
        startWakeSession()
    }

    private func startWakeSession() {
        guard wakeListenerActive else { return }
        guard recognitionRequest == nil else {
            // A command-capture session is in flight; the wake listener resumes
            // automatically when that finishes.
            return
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        // On-device recognition for streaming audio requires A12+ (iPhone XS+).
        // Older devices (iPhone 6s/A9) silently fail with on-device=true; fall back to cloud.
        if speechRecognizer?.supportsOnDeviceRecognition == true {
            req.requiresOnDeviceRecognition = true
        }
        wakeRequest = req

        wakeTask = speechRecognizer?.recognitionTask(with: req) { [weak self] result, error in
            guard let self = self else { return }

            if let result = result {
                let heard = result.bestTranscription.formattedString
                let phrase = self.settings.wakePhrase.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                if !phrase.isEmpty && heard.lowercased().contains(phrase) {
                    AppLogger.speech.info("Wake phrase detected in stream: \(heard)")
                    // Tear down wake session and switch to command capture.
                    self.wakeRequest?.endAudio()
                    self.wakeRequest = nil
                    self.wakeTask?.cancel()
                    self.wakeTask = nil
                    DispatchQueue.main.async {
                        self.startListening()
                    }
                    return
                }
            }
            if error != nil {
                AppLogger.speech.debug("Wake listener task error: \(String(describing: error))")
                // Don't auto-restart on error; the periodic timer handles that.
            }
        }
    }
    
    func convertFloatToInt16(floatSamples: [Float]) -> [Int16] {
        var int16Samples = [Int16](repeating: 0, count: floatSamples.count)

        for i in 0..<floatSamples.count {
            // Clamp float value to [-1.0, 1.0] range
            let clampedValue = max(-1.0, min(1.0, floatSamples[i]))

            // Convert to Int16 range
            let scaledValue = clampedValue * Float(Int16.max)
            int16Samples[i] = Int16(scaledValue)
        }

        return int16Samples
    }
    
    func getBestVoce(prefix: String, language: String) -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let allVoices = voices.filter { $0.language.hasPrefix(prefix) }
        
        #if DEBUG
        AppLogger.speech.debug("=== Available German voices ===")
        for voice in allVoices {
            AppLogger.speech.debug("Name: \(voice.name), Language: \(voice.language), Quality: \(voice.quality.rawValue), ID: \(voice.identifier)")
        }
        #endif
        
        // Strategie: Beste verfügbare Stimme wählen
        if #available(iOS 16, *) {
            // 1. Versuch: Premium Stimme (beste Qualität)
            if let premium = allVoices.first(where: {
                $0.quality == .premium && $0.language == language
            }) {
                AppLogger.speech.info("Using Premium voice: \(premium.name)")
                return premium
            }
            
            // 2. Versuch: Enhanced Stimme
            if let enhanced = allVoices.first(where: {
                $0.quality == .enhanced && $0.language == language
            }) {
                AppLogger.speech.info("Using Enhanced voice: \(enhanced.name)")
                return enhanced
            }
        }
        
        // 3. Fallback: Beste verfügbare Default-Stimme
        let defaultVoice = AVSpeechSynthesisVoice(language: language)
        AppLogger.speech.info("Using Default voice: \(defaultVoice?.name ?? "unknown")")
        return defaultVoice
    }
    
    private func speak(text: String, language: String) {
        DispatchQueue.main.async { [weak self] in
            self?.isSpeaking = true
        }
        
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = getBestVoce(prefix: "en", language: language)
               
        // Sprechgeschwindigkeit (0.0 - 1.0, default: 0.5)
        utterance.rate = 0.5

        // Tonhöhe (0.5 - 2.0, default: 1.0)
        utterance.pitchMultiplier = 1.0

        // Lautstärke (0.0 - 1.0, default: 1.0)
        utterance.volume = 1.0

        // Pre/Post-Pausen
        utterance.preUtteranceDelay = 0.0
        utterance.postUtteranceDelay = 0.0

        currentUtterance = utterance
        synthesizer.speak(utterance)
    }
    
    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        
        silenceTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(settings.voiceTimeout), repeats: false) { [weak self] _ in
            self?.recognitionRequest?.endAudio()
            self?.recognitionRequest = nil
            self?.recognitionTask?.cancel()
            self?.recognitionTask = nil
            self?.silenceTimer?.invalidate()
            self?.silenceTimer = nil
            
            AppLogger.speech.info("Voice session ended due to inactivity. Last text: \(self?.lastRecognizedText ?? "<none>")")
            
            self?.playFeedbackSound(assetName: "Speech_Off", assetExtension: "wav")
            
            Task {
                do {
                    let response = try await self?.sendHomeAssistantConversation(
                        text: "\(self?.lastRecognizedText ?? "<unknown>")",
                        language: "en"
                    )

                    AppLogger.homeAssistant.info("Received conversation response")

                    self?.speak(text: response ?? "Sorry, something went wrong.", language: "en-AU")

                } catch {
                    AppLogger.homeAssistant.error("Home Assistant conversation error: \(error.localizedDescription)")

                    self?.speak(text: "A technical error occurred. Please try again.", language: "en-AU")
                }

                // Resume wake-word listening once command processing kicked off.
                // The synthesizer's didFinish delegate also restarts recording,
                // but we want the wake listener up immediately on tasks that
                // bypass speech.
                if let self = self, self.porcupine == nil, self.wakeListenerActive {
                    DispatchQueue.main.async {
                        self.startWakeSession()
                    }
                }
            }
        }
    }
    
    func sendHomeAssistantConversation(
        text: String,
        language: String,
        urlLoader: URLDataLoader = { try await URLSession.shared.data(for: $0) }
    ) async throws -> String {
        // Construct the URL
        guard let url = URL(string: "\(settings.homeAssistantBaseURL)/api/conversation/process") else {
            throw APIError.invalidURL
        }
        
        // Create the request
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(settings.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        
        // Create the request body
        let body: [String: Any] = [
            "text": text,
            "language": language,
            "agent_id": settings.homeAssistantConversationAgent,
            "conversation_id": settings.homeAssistantConversationId
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        // Log the request
        AppLogger.homeAssistant.debug("=== HomeAssistant API Request ===")
        AppLogger.homeAssistant.debug("URL: \(url.absoluteString)")
        AppLogger.homeAssistant.debug("Method: \(request.httpMethod ?? "N/A")")
        AppLogger.homeAssistant.debug("Headers: \(String(describing: request.allHTTPHeaderFields))")
        if let bodyData = request.httpBody,
           let bodyString = String(data: bodyData, encoding: .utf8) {
            AppLogger.homeAssistant.debug("Body: \(bodyString)")
        }
        
        // Perform the request
        let (data, response) = try await urlLoader(request)
        
        // Log the response
        AppLogger.homeAssistant.debug("=== HomeAssistant API Response ===")
        if let httpResponse = response as? HTTPURLResponse {
            AppLogger.homeAssistant.debug("Status Code: \(httpResponse.statusCode)")
            AppLogger.homeAssistant.debug("Headers: \(String(describing: httpResponse.allHeaderFields))")
        }
        if let responseString = String(data: data, encoding: .utf8) {
            AppLogger.homeAssistant.debug("Body: \(responseString)")
        }
        
        // Check for HTTP errors
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        
        // Parse the JSON response
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let responseData = json["response"] as? [String: Any],
              let speech = responseData["speech"] as? [String: Any],
              let plainText = speech["plain"] as? [String: Any],
              let speechText = plainText["speech"] as? String else {
            throw APIError.invalidResponse
        }
        
        return speechText
    }
    
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {

        if let request = recognitionRequest {
            request.append(buffer)
            return
        }

        // Feed wake-word recognition session if active.
        if let wake = wakeRequest {
            wake.append(buffer)
            return
        }

        guard let porcupine = porcupine,
          let floatChannelData = buffer.floatChannelData else {
            return
        }

        let frameLength = Int(buffer.frameLength)
        let channelData = floatChannelData[0] // Use first channel (mono)

        // Convert float samples (-1.0 to 1.0) to Int16 (-32768 to 32767)
        let samplesArray = Array(UnsafeBufferPointer(start: channelData, count: frameLength))
        let int16Samples = convertFloatToInt16(floatSamples: samplesArray)

        // Add samples to our buffer
        audioBuffer.append(contentsOf: int16Samples)

        // Process in chunks of Porcupine frame length
        let frameSize = Int(Porcupine.frameLength)

        while audioBuffer.count >= frameSize {
            // Extract one frame worth of samples
            let frame = Array(audioBuffer.prefix(frameSize))
            audioBuffer.removeFirst(frameSize)

            // Process the frame with Porcupine
            do {
                let keywordIndex = try porcupine.process(pcm: frame)
                if keywordIndex >= 0 {
                    AppLogger.speech.info("Wake word detected! Keyword index: \(keywordIndex)")
                    startListening()
                    return
                }
            } catch {
                AppLogger.audio.error("Porcupine processing error: \(error.localizedDescription)")
            }
        }
    }

    /// Public push-to-talk entry point. Begins SFSpeech recognition session as if a wake word fired.
    /// Safe to call from UI button. No-op if a session is already active or recording is off.
    func triggerListening() {
        guard isRecording else {
            AppLogger.speech.warning("triggerListening called but recording is off")
            return
        }
        guard recognitionRequest == nil else {
            AppLogger.speech.debug("triggerListening ignored - session already active")
            return
        }
        AppLogger.speech.info("Push-to-talk triggered")
        startListening()
    }

    private func startListening() {
        playFeedbackSound(assetName: "Speech_On", assetExtension: "wav")

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            AppLogger.speech.error("Unable to create recognition request")
            return
        }

        recognitionRequest.shouldReportPartialResults = true
        // Same compat: only request on-device if device supports streaming on-device STT.
        if speechRecognizer?.supportsOnDeviceRecognition == true {
            recognitionRequest.requiresOnDeviceRecognition = true
        }

        lastRecognizedText = ""
        resetSilenceTimer()

        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            var isFinal = false

            if let result = result {
                let recognizedText = result.bestTranscription.formattedString
                AppLogger.speech.debug("Recognized text: \(recognizedText)")

                self?.lastRecognizedText = recognizedText
                self?.resetSilenceTimer()

                isFinal = result.isFinal
            }

            if error != nil || isFinal {
                self?.recognitionRequest?.endAudio()
                self?.recognitionRequest = nil
                self?.recognitionTask = nil
                self?.silenceTimer?.invalidate()
                self?.silenceTimer = nil

                if let error = error {
                    AppLogger.speech.error("Speech recognition error: \(error.localizedDescription)")
                }
            }
        }

        AppLogger.speech.info("Speech recognition task started")
    }
    
    // Plays an MP3 from a remote or local URL using AVPlayer
    func playMP3(from url: URL) {
        do {
            // Keep current category (.playAndRecord) but ensure session is active and speaker is used
            let session = AVAudioSession.sharedInstance()
            try session.setActive(true)
            try session.overrideOutputAudioPort(.speaker)
        } catch {
            AppLogger.audio.error("Audio session activation/override failed: \(String(describing: error))")
        }
        
        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        
        // Add observer for playback completion
        playbackObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.handlePlaybackCompleted()
        }

        player?.play()
    }
}
// MARK: - AVSpeechSynthesizerDelegate
extension AudioManager: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        AppLogger.speech.info("Speech synthesis started")
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        AppLogger.speech.info("Speech synthesis finished")
        
        DispatchQueue.main.async { [weak self] in
            self?.isSpeaking = false
        }
        
        // Resume recording after speech finishes if voice activation is enabled
        if settings.enableVoiceActivation && !isRecording {
            AppLogger.speech.info("Resuming recording after speech")
            startRecording()
        }
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        AppLogger.speech.warning("Speech synthesis cancelled")
        
        DispatchQueue.main.async { [weak self] in
            self?.isSpeaking = false
        }
        
        // Resume recording if voice activation is enabled
        if settings.enableVoiceActivation && !isRecording {
            startRecording()
        }
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) {
        AppLogger.speech.debug("Speech synthesis paused")
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance) {
        AppLogger.speech.debug("Speech synthesis continued")
    }
}

