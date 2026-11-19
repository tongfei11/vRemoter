import Foundation

/// One held input key for all active remote streams. No dependency on an IME process.
final class HoldVoiceSession {
    private var streams = Set<String>()
    var isActive: Bool { !streams.isEmpty }
    private let key: (Bool) -> Void
    private let route: (Bool) -> Void
    init(key: @escaping (Bool) -> Void, route: @escaping (Bool) -> Void) {
        self.key = key
        self.route = route
    }
    func start(_ stream: String) {
        let wasEmpty = streams.isEmpty
        streams.insert(stream)
        if wasEmpty { route(true); key(true) }
    }
    func stop(_ stream: String) {
        guard streams.remove(stream) != nil, streams.isEmpty else { return }
        key(false)
        route(false)
    }
    func close() {
        guard !streams.isEmpty else { return }
        streams.removeAll()
        key(false)
        route(false)
    }
}

enum VoiceInputBackend: String, CaseIterable, Identifiable {
    case wechat, doubao
    var id: String { rawValue }
    var title: String { self == .wechat ? "微信输入法" : "豆包输入法" }
    static var selected: VoiceInputBackend {
        get { VoiceInputBackend(rawValue: UserDefaults.standard.string(forKey: "voiceInputBackend") ?? "") ?? .wechat }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "voiceInputBackend") }
    }
}
