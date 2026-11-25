import Foundation

/// Line protocol emitted by the C3 RemoteReceiver firmware.
struct C3SerialProtocol {
    enum Event: Equatable {
        case connection(Bool)
        case button(String, Bool)
        case pairingStarted
        case pairingFailed(String)
        case pairingSucceeded
        case voiceControl(Data)
        case voiceAudio(Data)
        case voiceFault(String)
    }

    private var line = Data()
    private var binaryFrame = Data()
    private var discardingLine = false
    private var connected = false
    private var pressedButton: String?
    private(set) var isReceiver = false
    private(set) var statusResponses = 0

    mutating func append(_ data: Data) -> [Event] {
        var events: [Event] = []
        for byte in data {
            if !binaryFrame.isEmpty {
                binaryFrame.append(byte)
                if binaryFrame.count == 2, byte != 0x5A {
                    binaryFrame = byte == 0xA5 ? Data([0xA5]) : Data()
                } else if binaryFrame.count >= 5 {
                    let length = Int(binaryFrame[3]) | Int(binaryFrame[4]) << 8
                    guard binaryFrame[2] == 1, (1...512).contains(length) else {
                        binaryFrame.removeAll(keepingCapacity: true)
                        continue
                    }
                    if binaryFrame.count == length + 7 {
                        let crc = UInt16(binaryFrame[length + 5]) | UInt16(binaryFrame[length + 6]) << 8
                        if Self.crc16(Data(binaryFrame[2..<length + 5])) == crc {
                            events.append(.voiceAudio(Data(binaryFrame[5..<length + 5])))
                        } else {
                            events.append(.voiceFault("audio_crc_mismatch"))
                        }
                        binaryFrame.removeAll(keepingCapacity: true)
                    }
                }
                continue
            }
            if byte == 0xA5, line.isEmpty {
                binaryFrame.append(byte)
                discardingLine = false
                continue
            }
            if byte == 10 {
                if !discardingLine, let text = String(data: line, encoding: .utf8) {
                    events += consume(text.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                line.removeAll(keepingCapacity: true)
                discardingLine = false
            } else if !discardingLine {
                if line.count < 2048 { line.append(byte) }
                else {
                    line.removeAll(keepingCapacity: true)
                    discardingLine = true
                }
            }
        }
        return events
    }

    mutating func reset() -> [Event] {
        binaryFrame.removeAll(keepingCapacity: true)
        line.removeAll(keepingCapacity: true)
        discardingLine = false
        isReceiver = false
        return setConnected(false)
    }

    static func crc16(_ data: Data) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in data {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = crc & 0x8000 == 0 ? crc << 1 : (crc << 1) ^ 0x1021
            }
        }
        return crc
    }

    private mutating func setConnected(_ value: Bool) -> [Event] {
        var events: [Event] = []
        if !value, let pressedButton {
            events.append(.button(pressedButton, false))
            self.pressedButton = nil
        }
        if connected != value {
            connected = value
            events.append(.connection(value))
        }
        return events
    }

    private mutating func consume(_ text: String) -> [Event] {
        if text.hasPrefix("PAIRING_STARTED ") {
            isReceiver = true
            return setConnected(false) + [.pairingStarted]
        }
        if text.hasPrefix("PAIRING_FAILED reason=") {
            return [.pairingFailed(String(text.dropFirst("PAIRING_FAILED reason=".count)))]
        }
        if text.hasPrefix("PAIRING_SUCCEEDED ") { return [.pairingSucceeded] }
        if text.hasPrefix("READY build=") || text.hasPrefix("BOOT RemoteReceiver ") {
            isReceiver = true
        }
        if text == "DISCONNECTED" || text.hasPrefix("BOOT RemoteReceiver ") {
            return setConnected(false)
        }
        if text.hasPrefix("READY build=") { return setConnected(true) }
        let fields = text.split(separator: " ").reduce(into: [String: String]()) { result, field in
            let pair = field.split(separator: "=", maxSplits: 1)
            if pair.count == 2 { result[String(pair[0])] = String(pair[1]) }
        }
        if text.hasPrefix("ATVV_DROPPED "),
           let audioText = fields["audio"], let audio = UInt(audioText),
           let priorityText = fields["priority"], let priority = UInt(priorityText),
           audio > 0 || priority > 0 {
            return [.voiceFault("receiver_queue_overflow")]
        }
        if text.hasPrefix("ATVV "), let lengthText = fields["len"],
           let length = Int(lengthText), (1...512).contains(length),
           let hex = fields["hex"], hex.count == length * 2, hex.utf8.count == length * 2 {
            var payload = Data()
            let characters = Array(hex)
            for index in stride(from: 0, to: characters.count, by: 2) {
                guard let byte = UInt8(String(characters[index...index + 1]), radix: 16) else { return [] }
                payload.append(byte)
            }
            if fields["kind"] == "control" { return [.voiceControl(payload)] }
            if fields["kind"] == "audio" { return [.voiceAudio(payload)] }
            return []
        }
        if text.hasPrefix("STATUS build=") {
            guard let build = fields["build"], build.count == 4, UInt16(build) != nil,
                  ["connected", "authenticated", "ready"].allSatisfy({ fields[$0] == "0" || fields[$0] == "1" })
            else { return [] }
            isReceiver = true
            statusResponses &+= 1
            return setConnected(fields["connected"] == "1" && fields["authenticated"] == "1" && fields["ready"] == "1")
        }
        guard connected, text.hasPrefix("REPORT "), fields["handle"] == "002b",
              fields["len"] == "2", let hex = fields["hex"], hex.count == 4,
              let low = UInt8(hex.prefix(2), radix: 16),
              let high = UInt8(hex.suffix(2), radix: 16)
        else { return [] }
        let usage = UInt16(low) | UInt16(high) << 8
        let receiverButtons: [UInt16: String] = [0x77: "0E", 0x78: "0F", 0x19E: "01", 0x189: "11"]
        let decoded = receiverButtons[usage]
            ?? ChromecastButtonReport.decode(reportID: 2, data: Data([low, high]))
        let button = decoded == "00" ? nil : decoded
        guard pressedButton != button else { return [] }
        var events: [Event] = []
        if let pressedButton { events.append(.button(pressedButton, false)) }
        pressedButton = button
        if let button { events.append(.button(button, true)) }
        return events
    }
}
