#if !APPSTORE
import AVFoundation
import Speech

// MARK: - VoiceSettings

/// Persisted voice feature settings and permission helpers.
enum VoiceSettings {
    static let enabledKey      = "voiceEnabled"
    static let speakEnabledKey = "voiceSpeakEnabled"
    static let captionEnabledKey = "voiceCaptionEnabled"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Coucou responds aloud after each command. Default: on.
    static var speakEnabled: Bool {
        get {
            let d = UserDefaults.standard
            if d.object(forKey: speakEnabledKey) == nil { return true }   // default on
            return d.bool(forKey: speakEnabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: speakEnabledKey) }
    }

    /// Show caption capsule below notch during voice. Default: on.
    static var captionEnabled: Bool {
        get {
            let d = UserDefaults.standard
            if d.object(forKey: captionEnabledKey) == nil { return true }  // default on
            return d.bool(forKey: captionEnabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: captionEnabledKey) }
    }

    /// Wake phrase said instead of "OK Coucou" (coucou-custom fork). Empty: the default phrases.
    static let wakePhraseKey = "voiceWakePhrase"
    static var wakePhrase: String {
        (UserDefaults.standard.string(forKey: wakePhraseKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Seconds the mic stays open for a follow-up after an answer that was not a question
    /// (coucou-custom fork), like Siri's conversation mode. 0: only after Coucou asked
    /// something, upstream's behaviour.
    static let followUpSecondsKey = "voiceFollowUpSeconds"
    static var followUpSeconds: Double {
        let d = UserDefaults.standard
        return d.object(forKey: followUpSecondsKey) == nil ? 8 : d.double(forKey: followUpSecondsKey)
    }

    /// Which recognizer gives the final text of a command (fork): "parakeet" (default; Apple's
    /// recognizer still spots the wake word and shows live words) or "apple".
    static let commandRecognizerKey = "voiceCommandRecognizer"
    static var commandRecognizer: String {
        UserDefaults.standard.string(forKey: commandRecognizerKey) ?? "parakeet"
    }
    /// Words the recognizer should get right (fork): brands, names, places; see HearingCorrection.
    static let personalWordsKey = "voicePersonalWords"
    static var personalWords: [String] {
        HearingCorrection.personalWords(from: UserDefaults.standard.string(forKey: personalWordsKey) ?? "")
    }

    /// Language Coucou ANSWERS in: "en" (default) or "fr".
    static var language: String {
        get { UserDefaults.standard.string(forKey: "voiceLanguage") ?? "en" }
        set { UserDefaults.standard.set(newValue, forKey: "voiceLanguage") }
    }
    static var answerLocale: Locale { Locale(identifier: language == "fr" ? "fr-FR" : "en-US") }

    /// Language Coucou LISTENS to: "auto" (the Mac's dictation language, default), "en" or "fr".
    /// Independent from the answer language: speak French, hear English.
    static var listenLanguage: String {
        get { UserDefaults.standard.string(forKey: "voiceListenLanguage") ?? "auto" }
        set { UserDefaults.standard.set(newValue, forKey: "voiceListenLanguage") }
    }

    /// Coucou already offered to answer in the language you speak (asked once).
    static var languageOfferDone: Bool {
        get { UserDefaults.standard.bool(forKey: "voiceLanguageOfferDone") }
        set { UserDefaults.standard.set(newValue, forKey: "voiceLanguageOfferDone") }
    }

    /// Voice used to answer: "system" (macOS voices) or "elevenlabs" (user's API key).
    static var ttsEngine: String {
        get { UserDefaults.standard.string(forKey: "voiceTTSEngine") ?? "system" }
        set { UserDefaults.standard.set(newValue, forKey: "voiceTTSEngine") }
    }
    /// ElevenLabs voice: "female" (default) or "male".
    static var elevenGender: String {
        get { UserDefaults.standard.string(forKey: "voiceElevenGender") ?? "female" }
        set { UserDefaults.standard.set(newValue, forKey: "voiceElevenGender") }
    }

    /// Mac voice pitch per voice type (Settings → Voice). The male default is higher than
    /// the voice's own, so it sounds younger. Range 0.8–1.6 (AVSpeech accepts 0.5–2).
    static let defaultPitchFemale = 1.1
    static let defaultPitchMale   = 1.25
    static func pitchKey(for gender: String) -> String { gender == "male" ? "voicePitchMale" : "voicePitchFemale" }
    static func pitch(for gender: String) -> Double {
        let v = UserDefaults.standard.double(forKey: pitchKey(for: gender))
        let fallback = gender == "male" ? defaultPitchMale : defaultPitchFemale
        return v == 0 ? fallback : min(1.6, max(0.8, v))
    }

    /// Claude is Coucou's brain (the user's Anthropic API key): what I say after
    /// "OK Coucou" goes to Claude, which acts with Coucou's tools and searches the web.
    /// Off by default: my words leave the Mac only once this is turned on.
    static var claudeBrainEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "voiceClaudeBrain") }
        set { UserDefaults.standard.set(newValue, forKey: "voiceClaudeBrain") }
    }
    /// The older web-search-only path follows the same switch.
    static var webSearchEnabled: Bool { claudeBrainEnabled }

    /// Weather by voice (Open-Meteo, no key). Off by default: network only when the user
    /// turned it on and set a city.
    static var weatherEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "voiceWeatherEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "voiceWeatherEnabled") }
    }
    static var weatherCity: String {
        get { UserDefaults.standard.string(forKey: "voiceWeatherCity") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "voiceWeatherCity") }
    }

    /// Where the user is, for weather and "near me" questions. `claude -p` web search gets no
    /// location of its own (the API path sends an approximate one), so the prompt carries it.
    /// (coucou-custom fork)
    static var locationLine: String {
        let city = weatherCity.trimmingCharacters(in: .whitespaces)
        let zone = TimeZone.current.identifier
        let country = Locale.current.region.map { Locale.current.localizedString(forRegionCode: $0.identifier) ?? $0.identifier }
        if !city.isEmpty {
            return "The user is in \(city) (time zone \(zone)). Use it for weather and anything local when they name no place."
        }
        return "The user's time zone is \(zone)\(country.map { ", country \($0)" } ?? ""). "
            + "For weather or anything local with no place named, ask once which city they are in."
    }

    // MARK: - Permissions

    enum PermissionStatus { case granted, denied, undetermined }

    static var micStatus: PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:              return .granted
        case .denied, .restricted:     return .denied
        case .notDetermined:           return .undetermined
        @unknown default:              return .undetermined
        }
    }

    static var speechStatus: PermissionStatus {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:              return .granted
        case .denied, .restricted:     return .denied
        case .notDetermined:           return .undetermined
        @unknown default:              return .undetermined
        }
    }

    /// Request microphone then speech recognition. Returns true if both granted.
    @MainActor
    static func requestPermissions() async -> Bool {
        let mic = await AVAudioApplication.requestRecordPermission()
        guard mic else { return false }
        return await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }
}
#endif
