import AVFoundation
import CoreAudio
import Foundation

/// A microphone as the menus show it. `uid` is stored in settings; empty = the system default device.
struct MicrophoneInfo: Equatable, Identifiable {
    let uid: String
    let displayName: String
    var id: String { uid }
    var isSystemDefault: Bool { uid.isEmpty }
}

/// Push-to-talk recorder: the input device through AVAudioEngine, converted to 16 kHz mono floats for Whisper.
/// The twin of AudioRecorderService.cs (WinMM there).
final class AudioRecorder {
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private var player: AVAudioPlayer?

    private(set) var isRecording = false
    /// CoreAudio UID of the preferred microphone. Empty = system default.
    var preferredMicrophone = ""
    /// Why the last start() failed (Ukrainian).
    private(set) var lastError: String?
    /// Normalized 0..1 input level, called on the audio thread.
    var onLevel: ((Float) -> Void)?

    private static let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                     sampleRate: Double(AudioAnalysis.sampleRate),
                                                     channels: 1, interleaved: false)!

    // MARK: - Devices

    func microphones() -> [MicrophoneInfo] {
        let devices = Self.inputDevices()
        let defaultName = Self.defaultInputDevice().flatMap { id in devices.first { $0.id == id }?.name }
        var list = [MicrophoneInfo(uid: "", displayName: defaultName.map { "Системний за замовчуванням (\($0))" } ?? "Системний за замовчуванням")]
        list += devices.map { MicrophoneInfo(uid: $0.uid, displayName: $0.name) }
        return list
    }

    // MARK: - Recording

    func start() -> Bool {
        stopPlayback() // don't record our own playback
        lock.lock()
        defer { lock.unlock() }
        if engine != nil { return isRecording }
        lastError = nil

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted:
            lastError = "Немає доступу до мікрофона. Увімкніть ScreenVoicer у Системних параметрах → Приватність і безпека → Мікрофон."
            return false
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Log.info("[Audio] Microphone access \(granted ? "granted" : "denied").")
            }
            lastError = "Дозвольте ScreenVoicer доступ до мікрофона у вікні macOS і спробуйте ще раз."
            return false
        default:
            break
        }

        if Self.inputDevices().isEmpty {
            lastError = "Мікрофон не знайдено. Підключіть мікрофон і спробуйте ще раз."
            return false
        }

        samples.removeAll(keepingCapacity: true)
        let preferred = preferredMicrophone
        if open(deviceUID: preferred) || (!preferred.isEmpty && open(deviceUID: "")) {
            isRecording = true
            return true
        }
        if lastError == nil { lastError = "Не вдалося відкрити мікрофон." }
        return false
    }

    /// Called with the lock held.
    private func open(deviceUID: String) -> Bool {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if !deviceUID.isEmpty {
            guard var deviceID = Self.deviceID(forUID: deviceUID), let unit = input.audioUnit else {
                Log.warn("[Audio] Microphone '\(deviceUID)' is not connected.")
                return false
            }
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr {
                Log.warn("[Audio] Could not select microphone '\(deviceUID)' (\(status)).")
                return false
            }
        }

        // the hardware format of the (possibly just switched) device; the tap uses the node's own format (nil),
        // and the converter is built from the first buffer, so a format change can never crash the tap
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            lastError = "Мікрофон не передає звук. Оберіть інший мікрофон."
            return false
        }

        input.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            Log.warn("[Audio] Failed to open input device '\(deviceUID.isEmpty ? "default" : deviceUID)'", error)
            lastError = "Не вдалося відкрити мікрофон: \(error.localizedDescription)"
            return false
        }
        self.engine = engine
        self.converter = nil
        Log.info("[Audio] Recording started on \(deviceUID.isEmpty ? "the default device" : deviceUID) (\(Int(format.sampleRate)) Hz, \(format.channelCount) ch).")
        return true
    }

    /// Audio thread: resample to 16 kHz mono and append.
    private func consume(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard engine != nil else {
            lock.unlock()
            return
        }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: Self.targetFormat)
            converter?.downmix = true
        }
        guard let converter else {
            lock.unlock()
            return
        }
        lock.unlock()

        let ratio = Self.targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        if error != nil || output.frameLength == 0 { return }

        let chunk = UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength))
        let level = AudioAnalysis.level(chunk)
        lock.lock()
        samples.append(contentsOf: chunk)
        lock.unlock()
        onLevel?(level)
    }

    /// Copy of everything recorded so far as 16 kHz mono samples.
    func snapshot() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    /// Stops the device and returns the whole recording.
    func stop() async -> [Float] {
        let recorded: [Float] = {
            lock.lock()
            defer { lock.unlock() }
            closeEngine()
            return samples
        }()
        if !recorded.isEmpty {
            saveLastRecording(recorded)
        }
        Log.info("[Audio] Recording stopped: \(String(format: "%.1f", Double(recorded.count) / 16000)) s.")
        return recorded
    }

    func cancel() {
        lock.lock()
        closeEngine()
        samples.removeAll()
        lock.unlock()
    }

    /// Called with the lock held.
    private func closeEngine() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        converter = nil
        isRecording = false
    }

    // MARK: - Last take

    var hasLastRecording: Bool { FileManager.default.fileExists(atPath: Paths.lastRecording.path) }

    /// Plays the last finished take, so the user hears what the recognizer heard.
    @discardableResult
    func playLast() -> Bool {
        do {
            let player = try AVAudioPlayer(contentsOf: Paths.lastRecording)
            self.player = player
            return player.play()
        } catch {
            Log.warn("[Audio] Could not play the last recording", error)
            return false
        }
    }

    private func stopPlayback() {
        player?.stop()
        player = nil
    }

    private func saveLastRecording(_ samples: [Float]) {
        var data = Data()
        let rate = UInt32(AudioAnalysis.sampleRate)
        func put32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func put16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let payload = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); put32(36 + payload)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); put32(16); put16(1); put16(1); put32(rate); put32(rate * 2); put16(2); put16(16)
        data.append(contentsOf: Array("data".utf8)); put32(payload)
        for s in samples {
            put16(UInt16(bitPattern: Int16(max(-1, min(1, s)) * 32767)))
        }
        Paths.ensure(Paths.logs)
        try? data.write(to: Paths.lastRecording, options: .atomic)
    }

    // MARK: - CoreAudio

    private struct InputDevice {
        let id: AudioDeviceID
        let uid: String
        let name: String
    }

    private static func inputDevices() -> [InputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            guard inputChannels(id) > 0,
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
            return InputDevice(id: id, uid: uid, name: name)
        }
    }

    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func defaultInputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    private static func deviceID(forUID uid: String) -> AudioDeviceID? {
        inputDevices().first { $0.uid == uid }?.id
    }
}
