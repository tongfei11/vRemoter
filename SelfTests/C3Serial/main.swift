import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

var decoder = C3SerialProtocol()
require(decoder.append(Data("STATUS build=0002 connected=1 authenti".utf8)).isEmpty, "partial status must wait")
require(decoder.append(Data("cated=1 ready=1\r\n".utf8)) == [.connection(true)], "complete status enables input")
let usages = ["4200", "4300", "4400", "4500", "4100", "2402", "2302", "7700", "7800", "e200", "e900", "ea00", "9e01", "8901"]
let buttons = ["03", "04", "05", "06", "07", "0B", "0A", "0E", "0F", "08", "0C", "0D", "01", "11"]
for (usage, button) in zip(usages, buttons) {
    let press = "REPORT ms=12 handle=002b len=2 hex=\(usage)\r\n"
    require(decoder.append(Data(press.utf8)) == [.button(button, true)], "decode \(usage)")
    require(decoder.append(Data(press.utf8)).isEmpty, "duplicate press must not repeat keydown")
    require(decoder.append(Data("REPORT ms=15 handle=002b len=2 hex=0000\n".utf8)) == [.button(button, false)], "release \(button)")
}
require(decoder.append(Data("REPORT ms=16 handle=0057 len=4 hex=04030201\n".utf8)).isEmpty, "voice must not synthesize a keyboard action")
require(decoder.append(Data("REPORT ms=17 handle=002b len=2 hex=4200\n".utf8)) == [.button("03", true)], "press before disconnect")
require(decoder.append(Data("DISCONNECTED\n".utf8)) == [.button("03", false), .connection(false)], "disconnect releases held key")
require(decoder.append(Data("REPORT ms=18 handle=002b len=2 hex=4300\n".utf8)).isEmpty, "ignore input until authenticated")
_ = decoder.append(Data("READY build=0002\n".utf8))
_ = decoder.append(Data("REPORT ms=19 handle=002b len=2 hex=e900\n".utf8))
require(decoder.append(Data("REPORT ms=20 handle=002b len=2 hex=zzzz\n".utf8)).isEmpty, "malformed report does not alter state")
require(decoder.append(Data("REPORT ms=21 handle=002b len=3 hex=4300\n".utf8)).isEmpty, "length mismatch is invalid")
require(decoder.append(Data("REPORT ms=22 handle=002b len=2 hex=ffff\n".utf8)) == [.button("0C", false)], "unknown usage releases previous key")
_ = decoder.append(Data("REPORT ms=23 handle=002b len=2 hex=4100\n".utf8))
require(decoder.reset() == [.button("07", false), .connection(false)], "USB loss releases held key")
_ = decoder.append(Data(repeating: 65, count: 4096))
require(decoder.append(Data("READY build=0002\n".utf8)).isEmpty, "oversized line discarded through newline")
require(decoder.append(Data("READY build=0002\n".utf8)) == [.connection(true)], "decoder recovers after oversized line")
print("PASS: C3 serial framing, all 14 keys, duplicate input, malformed reports and disconnect release")
let responses = decoder.statusResponses
_ = decoder.append(Data("unrelated diagnostic log\n".utf8))
_ = decoder.append(Data("STATUS build=0002 connected=".utf8))
require(decoder.statusResponses == responses, "logs and partial status must not refresh heartbeat")
_ = decoder.append(Data("1 authenticated=1 ready=1\n".utf8))
require(decoder.statusResponses == responses + 1, "complete status refreshes heartbeat")
_ = decoder.append(Data("STATUS build=0002 connected=1\n".utf8))
require(decoder.statusResponses == responses + 1, "malformed status must not refresh heartbeat")
print("PASS: heartbeat requires complete receiver status")
_ = decoder.append(Data("REPORT ms=30 handle=002b len=2 hex=4200\n".utf8))
require(decoder.append(Data("PAIRING_STARTED target=00:11:22:33:44:55\n".utf8)) == [.button("03", false), .connection(false), .pairingStarted], "pairing releases keys and clears readiness")
require(decoder.append(Data("PAIRING_FAILED reason=timeout\n".utf8)) == [.pairingFailed("timeout")], "pairing failures are reported")
require(decoder.append(Data("PAIRING_SUCCEEDED target=00:11:22:33:44:55\n".utf8)) == [.pairingSucceeded], "pairing success notification")
print("PASS: receiver pairing state transitions")
require(decoder.append(Data("ATVV kind=control len=4 hex=04030201\n".utf8)) == [.voiceControl(Data([4,3,2,1]))], "ATVV control framing")
require(decoder.append(Data("ATVV kind=audio len=2 hex=1234\n".utf8)) == [.voiceAudio(Data([0x12,0x34]))], "ATVV audio framing")
require(decoder.append(Data("ATVV kind=audio len=2 hex=zzzz\n".utf8)).isEmpty, "invalid audio hex rejected")
require(decoder.append(Data("ATVV kind=audio len=3 hex=1234\n".utf8)).isEmpty, "invalid audio size rejected")
print("PASS: ATVV serial control and audio packets")
let binaryAudio = Data([0xA5, 0x5A, 1, 2, 0, 0x12, 0x34, 0xF3, 0x45])
require(decoder.append(binaryAudio.prefix(4)).isEmpty, "partial binary header waits")
require(decoder.append(binaryAudio.dropFirst(4)) == [.voiceAudio(Data([0x12,0x34]))], "binary audio CRC and framing")
var corrupt = binaryAudio
corrupt[6] ^= 1
require(decoder.append(corrupt) == [.voiceFault("audio_crc_mismatch")], "corrupt binary audio stops stateful ADPCM decoding")
require(decoder.append(binaryAudio) == [.voiceAudio(Data([0x12,0x34]))], "binary parser recovers after CRC failure")
require(C3SerialProtocol.crc16(Data("123456789".utf8)) == 0x29B1, "CRC16 standard check vector")
print("PASS: binary audio framing, fragmentation, CRC and recovery")
require(decoder.append(Data("ATVV_DROPPED audio=1 priority=0\n".utf8)) == [.voiceFault("receiver_queue_overflow")], "receiver drops are surfaced")
