import Foundation

/// ATVV voice transport over the C3 serial link, using the app's existing decoder and audio route.
final class C3VoiceBridge {
    var sendCommand: ((Data) -> Bool)?
    var onAvailableChanged: ((Bool) -> Void)?
    var onAudioStarted: ((UInt8) -> Void)?
    var onAudioStopped: ((UInt8) -> Void)?
    var onMicrophoneOpenFailed: ((UInt16) -> Void)?
    var onLevel: ((Double) -> Void)?

    private var handler = ATVVProtocol()
    private var connected = false
    private var streaming = false
    private var streamID: UInt8 = 0
    private var timer: Timer?
    private var closeTimer: Timer?
    private var frameCount = 0
    private var sampleCount = 0
    private var peak = 0
    private var sumSquares: Double = 0
    private var meterAt = Date.distantPast
    private var recorder: WavRecorder?
    private var capabilityTimer: Timer?
    private var capabilityAttempts = 0
    private var pendingStart: Data?

    func setConnected(_ value: Bool) {
        capabilityTimer?.invalidate()
        capabilityTimer = nil
        pendingStart = nil
        connected = false
        finish(reason: 0xFC)
        connected = value
        handler = ATVVProtocol()
        onAvailableChanged?(false)
        if value {
            capabilityAttempts = 0
            requestCapabilities()
            capabilityTimer = Timer(timeInterval: 1.5, repeats: true) { [weak self] timer in
                guard let self, self.connected, self.handler.capabilities == nil, self.capabilityAttempts < 3 else {
                    timer.invalidate()
                    return
                }
                self.requestCapabilities()
            }
            RunLoop.main.add(capabilityTimer!, forMode: .common)
        }
    }

    private func requestCapabilities() {
        capabilityAttempts += 1
        _ = sendCommand?(handler.getCapabilitiesCommand)
        print("[C3-VOICE] TX getCapabilities attempt=\(capabilityAttempts)")
    }

    func receiveControl(_ data: Data) {
        guard connected else { return }
        if data.first == 0x04, handler.capabilities == nil {
            pendingStart = data
            requestCapabilities()
            return
        }
        switch handler.parseControl(data) {
        case .capabilities(let capabilities):
            do {
                try handler.acceptCapabilities(capabilities)
                capabilityTimer?.invalidate()
                capabilityTimer = nil
                onAvailableChanged?(true)
                print("[C3-VOICE] capabilities v\(capabilities.version) codec=\(handler.codec!) frame=\(capabilities.frameSize)")
                if let pendingStart {
                    self.pendingStart = nil
                    receiveControl(pendingStart)
                }
            } catch { print("[C3-VOICE] capabilities failed: \(error)") }
        case .startSearch:
            _ = openMicrophone()
        case .audioStart(let reason, let codec, let id):
            guard handler.capabilities != nil else {
                _ = sendCommand?(handler.getCapabilitiesCommand)
                return
            }
            closeTimer?.invalidate()
            closeTimer = nil
            // Repeated AUDIO_START resets the decoder without releasing a held voice trigger.
            recorder?.close()
            recorder = nil
            handler.beginAudioStream(codec: codec)
            streamID = id
            streaming = true
            frameCount = 0
            sampleCount = 0
            peak = 0
            sumSquares = 0
            let recording = AppStorage.recordingEnabled || CommandLine.arguments.contains("--c3-record-test")
            recorder = recording ? WavRecorder.createNext(prefix: "c3-voice", sampleRate: UInt32(codec.sampleRate)) : nil
            timer?.invalidate()
            timer = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
                guard let self, let command = try? self.handler.keepAliveCommand(streamID: self.streamID) else { return }
                _ = self.sendCommand?(command)
            }
            RunLoop.main.add(timer!, forMode: .common)
            print("[C3-VOICE] AUDIO_START reason=\(reason) stream=\(id)")
            onAudioStarted?(reason)
            if !AudioPipe.shared.isRemoteInputEnabled { closeMicrophone() }
        case .audioStop(let reason):
            finish(reason: reason)
        case .audioSync(let codec, let sequence, let predictor, let step):
            handler.applyAudioSync(codec: codec, sequence: sequence, predictor: predictor, stepIndex: step)
        case .micOpenError(let code):
            print("[C3-VOICE] MIC_OPEN_ERROR \(code)")
            onMicrophoneOpenFailed?(code)
        case .unknown:
            print("[C3-VOICE] unknown control \(data.map { String(format: "%02x", $0) }.joined())")
        }
    }

    func receiveAudio(_ data: Data) {
        guard streaming, let frame = handler.decodeAudio(data), !frame.samples.isEmpty else { return }
        frameCount += 1
        sampleCount += frame.samples.count
        let framePeak = frame.samples.reduce(0) { max($0, abs(Int($1))) }
        let energy = frame.samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        peak = max(peak, framePeak)
        sumSquares += energy
        recorder?.appendRawBytes(data)
        recorder?.appendSamples(frame.samples)
        AudioPipe.shared.feed(samples: frame.samples, inputSampleRate: Double(handler.codec?.sampleRate ?? 16_000))
        if frameCount == 1 { print("[C3-VOICE] first decoded audio frame samples=\(frame.samples.count) peak=\(framePeak)") }
        if Date().timeIntervalSince(meterAt) >= 0.1 {
            meterAt = Date()
            let rms = sqrt(energy / Double(frame.samples.count))
            onLevel?(rms > 0 ? 20 * log10(rms / 32768) : -120)
        }
    }

    func openMicrophone() -> RemoteMicrophoneOpenResult {
        guard connected, handler.capabilities != nil, AudioPipe.shared.isRemoteInputEnabled else { return .unavailable }
        if streaming { return .alreadyStreaming }
        do {
            handler.prepareForAudioStream()
            guard sendCommand?(try handler.micOpenCommand()) == true else { return .failed("C3 serial command failed") }
            return .sent
        } catch { return .failed(error.localizedDescription) }
    }

    func closeMicrophone() {
        timer?.invalidate()
        timer = nil
        if connected, let command = try? handler.micCloseCommand(streamID: streamID) {
            _ = sendCommand?(command)
        }
        closeTimer?.invalidate()
        // Give the remote's AUDIO_STOP time to preserve its physical-release reason.
        closeTimer = Timer(timeInterval: 0.6, repeats: false) { [weak self] _ in self?.finish(reason: 0xFD) }
        RunLoop.main.add(closeTimer!, forMode: .common)
    }

    func stop() {
        closeMicrophone()
        setConnected(false)
    }

    func transportFailed(_ reason: String) {
        print("[C3-VOICE] transport error \(reason), stopping audio to reset decoder")
        closeMicrophone()
        finish(reason: 0xFD)
    }

    private func finish(reason: UInt8) {
        timer?.invalidate()
        timer = nil
        closeTimer?.invalidate()
        closeTimer = nil
        guard streaming else { return }
        streaming = false
        handler.endAudioStream()
        recorder?.close()
        recorder = nil
        let rms = sampleCount > 0 ? sqrt(sumSquares / Double(sampleCount)) : 0
        print("[C3-VOICE] AUDIO_SUMMARY frames=\(frameCount) samples=\(sampleCount) peak=\(peak) rms=\(Int(rms)) reason=\(reason)")
        onLevel?(-120)
        onAudioStopped?(reason)
    }
}
