import Darwin
import Foundation

/// Polls a C3 receiver USB serial port without blocking the AppKit run loop.
final class C3SerialBridge {
    var onPresenceChanged: ((Bool) -> Void)?
    var onConnectionChanged: ((Bool) -> Void)?
    var onPairingStatusChanged: ((String) -> Void)?
    var onPortsChanged: (([String], String) -> Void)?
    var onVoiceControl: ((Data) -> Void)?
    var onVoiceAudio: ((Data) -> Void)?
    var onVoiceFault: ((String) -> Void)?
    var onPairingActiveChanged: ((Bool) -> Void)?

    func sendVoiceCommand(_ data: Data) -> Bool {
        guard present, descriptor >= 0, data.count <= 32 else { return false }
        let line = "tx " + data.map { String(format: "%02x", $0) }.joined() + "\n"
        let result = line.withCString { Darwin.write(descriptor, $0, line.utf8.count) }
        guard result == line.utf8.count else { closePort(); return false }
        return true
    }

    private var descriptor: Int32 = -1
    private var port: String?
    private var timer: Timer?
    private var decoder = C3SerialProtocol()
    private var present = false
    private var nextOpen: TimeInterval = 0
    private var nextStatus: TimeInterval = 0
    private var lastResponse: TimeInterval = 0
    private var enabled = RemoteMappingStore.shared.isEnabled(.chromecastC3)
    private var releaseHeldKey: (() -> Void)?
    private var repeatTimer: Timer?
    private var repeatKey: (() -> Void)?
    private var availablePorts: [String] = []
    private var nextPortRefresh: TimeInterval = 0
    private var pairingDeadline: TimeInterval?

    func selectPort(_ path: String) {
        if path.isEmpty { UserDefaults.standard.removeObject(forKey: "c3ReceiverSerialPort") }
        else { UserDefaults.standard.set(path, forKey: "c3ReceiverSerialPort") }
        closePort()
        nextOpen = 0
        nextPortRefresh = 0
        poll()
    }

    func beginPairing() {
        guard present, descriptor >= 0 else {
            onPairingStatusChanged?(L10n.text("请先连接 C3 接收器并选择串口", "Connect the C3 receiver and select its serial port"))
            return
        }
        guard pairingDeadline == nil else { return }
        onPairingActiveChanged?(true)
        let result = "p\n".withCString { Darwin.write(descriptor, $0, 2) }
        guard result == 2 else {
            onPairingActiveChanged?(false)
            onPairingStatusChanged?(L10n.text("配对指令发送失败", "Could not send pairing command"))
            closePort()
            return
        }
        pairingDeadline = ProcessInfo.processInfo.systemUptime + 70
        onPairingStatusChanged?(L10n.text("请按住遥控器返回＋主页", "Hold Back + Home on the remote"))
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer!, forMode: .common)
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        closePort()
    }

    func setRemappingEnabled(_ value: Bool) {
        release()
        enabled = value
    }

    private func poll() {
        let now = ProcessInfo.processInfo.systemUptime
        if now >= nextPortRefresh {
            let ports = ((try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? [])
                .filter { $0.hasPrefix("cu.usbmodem") || $0.hasPrefix("cu.usbserial") || $0.hasPrefix("cu.SLAB_USBtoUART") || $0.hasPrefix("cu.wchusbserial") }
                .sorted().map { "/dev/" + $0 }
            availablePorts = ports
            onPortsChanged?(ports, UserDefaults.standard.string(forKey: "c3ReceiverSerialPort") ?? "")
            nextPortRefresh = now + 2
        }
        if let pairingDeadline, now >= pairingDeadline {
            self.pairingDeadline = nil
            onPairingActiveChanged?(false)
            onPairingStatusChanged?(L10n.text("配对超时，请重试", "Pairing timed out. Try again."))
        }
        if descriptor < 0 {
            guard now >= nextOpen else { return }
            nextOpen = now + 2
            openPort()
            return
        }
        guard let port, FileManager.default.fileExists(atPath: port) else {
            closePort()
            return
        }
        var buffer = [UInt8](repeating: 0, count: 4096)
        for _ in 0..<8 {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 {
                if errno != EAGAIN && errno != EINTR { closePort() }
                break
            }
            if count == 0 { break }
            let responses = decoder.statusResponses
            let events = decoder.append(Data(buffer.prefix(count)))
            if decoder.statusResponses != responses { lastResponse = now }
            if decoder.isReceiver {
                if !present {
                    present = true
                    print("[C3-SERIAL] receiver detected at \(port)")
                    onPresenceChanged?(true)
                }
            }
            events.forEach(handle)
        }
        guard descriptor >= 0 else { return }
        if now - lastResponse > 35 {
            print("[C3-SERIAL] receiver heartbeat timed out")
            closePort()
        } else if now >= nextStatus {
            let result = "s\n".withCString { Darwin.write(descriptor, $0, 2) }
            if result != 2 { closePort() }
            nextStatus = now + 3
        }
    }

    private func openPort() {
        let override = ProcessInfo.processInfo.environment["VREMOTER_C3_PORT"]
            ?? UserDefaults.standard.string(forKey: "c3ReceiverSerialPort")
        let candidates: [String]
        if let override, !override.isEmpty { candidates = [override] }
        else {
            // AlphaPi has a stable USB product name. Other boards are selected explicitly.
            candidates = availablePorts.filter { $0.hasPrefix("/dev/cu.usbmodemAlphaPi") }
        }
        guard let candidate = candidates.first else { return }
        let fd = Darwin.open(candidate, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return }
        var options = termios()
        guard tcgetattr(fd, &options) == 0 else { Darwin.close(fd); return }
        cfmakeraw(&options)
        cfsetspeed(&options, speed_t(B115200))
        options.c_cflag |= tcflag_t(CLOCAL | CREAD)
        options.c_cflag &= ~tcflag_t(HUPCL)
        guard tcsetattr(fd, TCSANOW, &options) == 0,
              ioctl(fd, UInt(TIOCEXCL), 0) == 0
        else { Darwin.close(fd); return }
        var modemBits = Int32(TIOCM_DTR | TIOCM_RTS)
        _ = ioctl(fd, UInt(TIOCMBIC), &modemBits)
        descriptor = fd
        port = candidate
        decoder = C3SerialProtocol()
        lastResponse = ProcessInfo.processInfo.systemUptime
        nextStatus = 0
        print("[C3-SERIAL] opened \(candidate) at 115200")
    }

    private func closePort() {
        onPairingActiveChanged?(false)
        if pairingDeadline != nil {
            pairingDeadline = nil
            onPairingStatusChanged?(L10n.text("接收器已断开，配对中止", "Receiver disconnected. Pairing stopped."))
        }
        decoder.reset().forEach(handle)
        release()
        if descriptor >= 0 {
            _ = ioctl(descriptor, UInt(TIOCNXCL), 0)
            Darwin.close(descriptor)
        }
        descriptor = -1
        port = nil
        if present {
            present = false
            onPresenceChanged?(false)
        }
    }

    private func handle(_ event: C3SerialProtocol.Event) {
        switch event {
        case .voiceFault(let reason):
            release()
            onVoiceFault?(reason)
        case .voiceControl(let data):
            onVoiceControl?(data)
        case .voiceAudio(let data):
            onVoiceAudio?(data)
        case .pairingStarted:
            release()
            if pairingDeadline == nil { pairingDeadline = ProcessInfo.processInfo.systemUptime + 70 }
            onPairingActiveChanged?(true)
            onPairingStatusChanged?(L10n.text("正在配对，请按住返回＋主页", "Pairing. Hold Back + Home."))
        case .pairingFailed(let reason):
            pairingDeadline = nil
            onPairingActiveChanged?(false)
            onPairingStatusChanged?(L10n.text("配对失败", "Pairing failed") + " · " + reason)
        case .pairingSucceeded:
            pairingDeadline = nil
            onPairingActiveChanged?(false)
            onPairingStatusChanged?(L10n.text("配对成功", "Paired successfully"))
        case .connection(let connected):
            print("[C3-SERIAL] remote \(connected ? "ready" : "disconnected")")
            onConnectionChanged?(connected)
            if connected, pairingDeadline != nil {
                pairingDeadline = nil
                onPairingActiveChanged?(false)
                onPairingStatusChanged?(L10n.text("配对成功", "Paired successfully"))
            }
        case .button(let id, let isDown):
            if !isDown { release(); return }
            guard enabled,
                  let button = RemoteProfiles.chromecastButtons.first(where: { $0.id == id })
            else { return }
            release()
            let store = RemoteMappingStore.shared
            let target = store.target(for: button, remote: .chromecastC3)
            let shortcut = store.customShortcut(for: button, remote: .chromecastC3)
            // Capture the action now so changing the mapping while held cannot leave a key down.
            releaseHeldKey = {
                if target == .custom { shortcut?.post(isDown: false) }
                else { target.post(isDown: false) }
            }
            store.post(button: button, remote: .chromecastC3, isDown: true)
            print("[C3-MAP] \(button.title) DOWN -> \(store.targetTitle(for: button, remote: .chromecastC3))")
            let repeating: Set<RemoteMappingTarget> = [.arrowUp, .arrowDown, .arrowLeft, .arrowRight, .volumeUp, .volumeDown, .deleteBackward, .pageUp, .pageDown]
            if repeating.contains(target) {
                repeatKey = { [weak self] in
                    guard store.target(for: button, remote: .chromecastC3) == target else {
                        self?.release()
                        return
                    }
                    store.post(button: button, remote: .chromecastC3, isDown: true)
                }
                repeatTimer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.repeatKey?() }
                repeatTimer?.fireDate = Date(timeIntervalSinceNow: 0.45)
                RunLoop.main.add(repeatTimer!, forMode: .common)
            }
        }
    }

    private func release() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        repeatKey = nil
        releaseHeldKey?()
        releaseHeldKey = nil
    }
}
