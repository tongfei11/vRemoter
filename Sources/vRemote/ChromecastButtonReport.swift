import Foundation

/// Decode standard keyboard/consumer collections, retaining the legacy compact report.
enum ChromecastButtonReport {
    static func decode(reportID: UInt32, data: Data) -> String? {
        let bytes = Array(data)
        // Only strip a report prefix when the expected wire length proves it is present.
        if reportID == 1 {
            if bytes.count >= 8 {
                let payload = bytes.count >= 9 && bytes.first == 1 ? Array(bytes.dropFirst()) : bytes
                let keys = payload.dropFirst(2).prefix(6).filter { $0 != 0 }
                guard let usage = keys.first else { return "00" }
                return [UInt8(0x28): "07", 0x52: "03", 0x51: "04", 0x50: "05", 0x4F: "06", 0x29: "0B"][usage]
            }
            let payload = bytes.count == 2 && bytes.first == 1 ? Array(bytes.dropFirst()) : bytes
            guard let usage = payload.first, usage <= 0x11 else { return nil }
            return String(format: "%02X", usage)
        }
        if reportID == 2 {
            let payload = bytes.count >= 3 && bytes.first == 2 ? Array(bytes.dropFirst()) : bytes
            guard payload.count >= 2 else { return nil }
            let usage = UInt16(payload[0]) | UInt16(payload[1]) << 8
            return [UInt16(0): "00", 0x41: "07", 0x42: "03", 0x43: "04", 0x44: "05", 0x45: "06", 0x46: "0B", 0x223: "0A", 0x224: "0B", 0xE2: "08", 0xE9: "0C", 0xEA: "0D", 0x30: "01"][usage]
        }
        return nil
    }
}
