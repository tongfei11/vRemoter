import Foundation

// Replace only the audio-device and recording boundaries for this transport test.
enum AppStorage { static var recordingEnabled = false }
final class AudioPipe {
    static let shared = AudioPipe()
    var isRemoteInputEnabled = true
    var samples: [Int16] = []
    func feed(samples: [Int16], inputSampleRate: Double) { self.samples += samples }
}
final class WavRecorder {
    static func createNext(prefix: String, sampleRate: UInt32) -> WavRecorder? { nil }
    func appendRawBytes(_ data: Data) {}
    func appendSamples(_ samples: [Int16]) {}
    func close() {}
}
enum RemoteMicrophoneOpenResult: Equatable {
    case sent, alreadyStreaming, unavailable
    case failed(String)
}
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}
let voice = C3VoiceBridge()
var commands: [Data] = []
var starts: [UInt8] = []
var stops: [UInt8] = []
voice.sendCommand = { commands.append($0); return true }
voice.onAudioStarted = { starts.append($0) }
voice.onAudioStopped = { stops.append($0) }
voice.setConnected(true)
require(commands.last == Data([0x0a,1,0,0,3,3]), "requests ATVV capabilities")
voice.receiveControl(Data([0x0b,1,0,2,3,0,247]))
require(voice.openMicrophone() == .sent, "can open negotiated microphone")
require(commands.last == Data([0x0c,0]), "correct microphone-open command")
voice.receiveControl(Data([4,3,2,1]))
voice.receiveAudio(Data([0x11,0x22]))
require(starts == [3] && AudioPipe.shared.samples.count == 4, "physical start and ADPCM samples reach audio route")
RunLoop.current.run(until: Date().addingTimeInterval(3.8))
voice.closeMicrophone()
let closingCommandCount = commands.count
require(commands.last == Data([0x0d,1]), "close matches stream ID")
RunLoop.current.run(until: Date().addingTimeInterval(0.35))
require(commands.count == closingCommandCount, "keepalive cannot reopen microphone while closing")
voice.receiveControl(Data([0,2]))
require(stops == [2], "physical release reason preserved")
let sampleCount = AudioPipe.shared.samples.count
voice.setConnected(false)
voice.receiveAudio(Data([0x33]))
require(AudioPipe.shared.samples.count == sampleCount, "disconnected transport cannot feed audio")
voice.stop()
print("PASS: C3 capabilities, mic commands, audio decode, stop reason and keepalive cancellation")
