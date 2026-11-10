import AVFoundation

/// 版本：跟随 App 版本（见 Config.swift）
///
/// 导航播报：高德把播报文字交给我们，用 iPhone 自带的语音念出来。
/// 播报时把音乐压低（“压低音乐”开关），念完 0.4 秒后恢复；连着蓝牙耳机/头盔时从耳机里出声。
final class Speech: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = Speech()
    private let synth = AVSpeechSynthesizer()
    private var automaticVoice: AVSpeechSynthesisVoice?
    private var playback = SpeechPlaybackState()
    private var utterances: [ObjectIdentifier: UInt64] = [:]
    private var sessionActive = false
    private var releaseWork: DispatchWorkItem?
    private(set) var isSpeaking = false

    override init() {
        super.init()
        synth.delegate = self
        automaticVoice = Self.preferredChineseVoice()
    }

    /// 只自动选择普通话。用 identifier 稳定排序，避免同级音色随枚举顺序切换。
    private static func preferredChineseVoice() -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == "zh-CN" }
            .sorted { $0.identifier < $1.identifier }
        if #available(iOS 16.0, *) {
            if let premium = voices.first(where: { $0.quality == .premium }) {
                return premium
            }
        }
        return voices.first(where: { $0.quality == .enhanced })
            ?? AVSpeechSynthesisVoice(language: "zh-CN")
    }

    private func selectedVoice() -> AVSpeechSynthesisVoice? {
        let id = UserDefaults.standard.string(forKey: "voice_id") ?? ""
        if !id.isEmpty, let selected = AVSpeechSynthesisVoice(identifier: id) {
            return selected
        }
        // 每次自动播报前刷新，下载／删除系统音色后无需重装或修改设置。
        // 不把自动结果写入 voice_id，以便以后继续自动升级音色。
        automaticVoice = Self.preferredChineseVoice()
        return automaticVoice
    }

    @discardableResult private func configureSession(active: Bool) -> Bool {
        let s = AVAudioSession.sharedInstance()
        do {
            if active {
                let opts: AVAudioSession.CategoryOptions = Settings.shared.duck
                    ? [.duckOthers, .interruptSpokenAudioAndMixWithOthers]
                    : [.mixWithOthers]
                try s.setCategory(.playback, mode: .voicePrompt, options: opts)
                try s.setActive(true)
                sessionActive = true
            } else {
                if sessionActive { try s.setActive(false, options: .notifyOthersOnDeactivation) }
                sessionActive = false
            }
            return true
        } catch {
            print("音频设置失败：\(error)")
            return false
        }
    }

    func speak(_ text: String) {
        if Settings.shared.voiceMuted || playback.blockedByCall { return }
        let volume = SpeechVolumePolicy.load()
        if volume == 0 { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return }
        releaseWork?.cancel()
        if playback.isEmpty && !configureSession(active: true) { return }
        guard let token = playback.begin() else { return }
        isSpeaking = true
        let u = AVSpeechUtterance(string: t)
        utterances[ObjectIdentifier(u)] = token
        u.voice = selectedVoice()
        u.rate = Float(UserDefaults.standard.object(forKey: "voice_rate") as? Double ?? Double(AVSpeechUtteranceDefaultSpeechRate))
        u.pitchMultiplier = Float(UserDefaults.standard.object(forKey: "voice_pitch") as? Double ?? 1.0)
        u.volume = Float(volume)
        synth.speak(u)
    }

    private func finished(_ utterance: AVSpeechUtterance) {
        guard let token = utterances.removeValue(forKey: ObjectIdentifier(utterance)) else { return }
        if playback.finish(token) {
            let w = DispatchWorkItem { [weak self] in
                guard let self = self, self.playback.isEmpty else { return }
                self.isSpeaking = false
                self.configureSession(active: false)
            }
            releaseWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
        }
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { DispatchQueue.main.async { self.finished(u) } }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { DispatchQueue.main.async { self.finished(u) } }

    /// 马上停止正在念的（点了静音）
    func stopNow() {
        releaseWork?.cancel()
        utterances.removeAll()
        playback.clear()
        synth.stopSpeaking(at: .immediate)
        isSpeaking = false
        configureSession(active: false)
    }

    /// Never resume navigation instructions that were queued before a call.
    func updateCallState(_ state: CallState) {
        if playback.updateCallState(state) { stopNow() }
    }

    /// 试听（不管静音开关）
    func test() {
        let m = Settings.shared.voiceMuted
        Settings.shared.voiceMuted = false
        speak("前方三百米右转，进入人民南路。注意，前方有测速，限速六十。")
        Settings.shared.voiceMuted = m
    }
}
