@_exported import Foundation

public let AVSpeechUtteranceDefaultSpeechRate: Float = 0.5

public enum AVSpeechBoundary {
    case immediate
}

public protocol AVSpeechSynthesizerDelegate: AnyObject {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance)
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance)
}

public final class AVSpeechSynthesisVoice {
    public enum Quality {
        case `default`, enhanced, premium
    }

    public let language: String
    public let identifier: String
    public let quality: Quality = .default

    public init?(language: String) {
        self.language = language
        identifier = "test." + language
    }

    public init?(identifier: String) {
        language = "zh-CN"
        self.identifier = identifier
    }

    public static func speechVoices() -> [AVSpeechSynthesisVoice] { [] }
}

public final class AVSpeechUtterance {
    public let speechString: String
    public var voice: AVSpeechSynthesisVoice?
    public var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    public var pitchMultiplier: Float = 1
    public var volume: Float = 1
    public init(string: String) { speechString = string }
}

public final class AVSpeechSynthesizer {
    public private(set) static var latest: AVSpeechSynthesizer?
    public weak var delegate: AVSpeechSynthesizerDelegate?
    public private(set) var submitted: [AVSpeechUtterance] = []
    public private(set) var stops = 0

    public init() { Self.latest = self }
    public func speak(_ utterance: AVSpeechUtterance) { submitted.append(utterance) }
    @discardableResult public func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool {
        stops += 1
        return true
    }

    public func emitFinish(_ utterance: AVSpeechUtterance) {
        delegate?.speechSynthesizer(self, didFinish: utterance)
    }

    public func emitCancel(_ utterance: AVSpeechUtterance) {
        delegate?.speechSynthesizer(self, didCancel: utterance)
    }
}

public final class AVAudioSession {
    public enum Category {
        case playback
    }
    public enum Mode {
        case voicePrompt
    }
    public struct CategoryOptions: OptionSet {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let duckOthers = CategoryOptions(rawValue: 1 << 0)
        public static let interruptSpokenAudioAndMixWithOthers = CategoryOptions(rawValue: 1 << 1)
        public static let mixWithOthers = CategoryOptions(rawValue: 1 << 2)
    }
    public struct SetActiveOptions: OptionSet {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let notifyOthersOnDeactivation = SetActiveOptions(rawValue: 1 << 0)
    }

    private static let shared = AVAudioSession()
    public private(set) var activeChanges: [Bool] = []
    public private(set) var isActive = false
    public private(set) var categoryCalls = 0
    public var failActivation = false
    public static func sharedInstance() -> AVAudioSession { shared }

    public func setCategory(_ category: Category, mode: Mode, options: CategoryOptions) throws {
        categoryCalls += 1
    }

    public func setActive(_ active: Bool, options: SetActiveOptions = []) throws {
        if active && failActivation {
            throw NSError(domain: "SpeechAdapterTest", code: 1)
        }
        activeChanges.append(active)
        isActive = active
    }
}
