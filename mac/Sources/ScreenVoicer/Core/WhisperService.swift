import Foundation
import Metal
import whisper

enum ModelState {
    case notLoaded, downloading, loading, ready, failed
}

/// Local speech recognition with whisper.cpp (Metal on Apple Silicon). The twin of WhisperTranscriptionService.cs:
/// same models, same parameters, same "keep the old model working while the next one downloads" behaviour.
final class WhisperService {
    private static let minValidModelBytes: Int64 = 30 * 1024 * 1024

    /// A loaded whisper.cpp context. Freed on the inference queue, so never in the middle of a run.
    private final class LoadedModel {
        let ctx: OpaquePointer
        let model: WhisperModelInfo
        let onGpu: Bool

        init(ctx: OpaquePointer, model: WhisperModelInfo, onGpu: Bool) {
            self.ctx = ctx
            self.model = model
            self.onGpu = onGpu
        }
    }

    /// Every whisper_full call runs here, one at a time (Windows: the GPU gate + final lock).
    private let inference = DispatchQueue(label: "ScreenVoicer.Whisper.inference", qos: .userInitiated)
    private let loading = DispatchQueue(label: "ScreenVoicer.Whisper.loading", qos: .userInitiated)
    private let loadLock = AsyncMutex()
    private let modelDirectory: URL
    private let threads: Int
    private let previewThreads: Int

    @Atomic private var active: LoadedModel?
    @Atomic private var previewBusy = false
    @Atomic private var gpuBroken = false
    @Atomic private(set) var state: ModelState = .notLoaded
    @Atomic private(set) var downloadProgress: Double = 0
    @Atomic private(set) var downloadingModel: WhisperModelInfo?
    @Atomic private(set) var lastError: String?
    @Atomic private(set) var selectedModel: WhisperModelInfo
    @Atomic private(set) var useGpu: Bool
    @Atomic var language: String

    /// Called on the main thread whenever any of the state above changes.
    var onChange: (() -> Void)?

    init(language: String, modelId: String?, useGpu: Bool, modelDirectory: URL = Paths.models) {
        self.language = language
        self.selectedModel = WhisperModels.find(modelId)
        self.useGpu = useGpu
        self.modelDirectory = modelDirectory
        let cores = WhisperService.performanceCores()
        threads = min(max(cores, 2), 8)
        previewThreads = min(max(cores / 2, 2), 6)
        Self.installLogHandler()
    }

    static var defaultModelDirectory: URL { Paths.models }

    var isModelReady: Bool { active != nil }
    var activeModel: WhisperModelInfo? { active?.model }
    var isRunningOnGpu: Bool { active?.onGpu == true }

    /// A Metal device exists (every Apple Silicon Mac; most Intel Macs too).
    var isGpuRuntimeAvailable: Bool { Self.metalDevice != nil && !gpuBroken }
    var gpuName: String? { Self.metalDevice?.name }
    var gpuBackend: String? { isGpuRuntimeAvailable ? "Metal" : nil }

    private static let metalDevice: MTLDevice? = MTLCreateSystemDefaultDevice()

    static func isModelDownloaded(_ id: String, in directory: URL = Paths.models) -> Bool {
        isValidModelFile(directory.appendingPathComponent(WhisperModels.find(id).fileName))
    }

    // MARK: - Loading & switching

    @discardableResult
    func ensureModelLoaded() async -> Bool {
        if isModelReady { return true }
        return await loadSelected()
    }

    /// Switches to another model; the current one keeps working until the new one is ready.
    func switchModel(_ id: String) async -> Bool {
        selectedModel = WhisperModels.find(id)
        changed()
        return await loadSelected()
    }

    /// Moves inference to the GPU or back to the processor without a restart.
    func setUseGpu(_ on: Bool) async {
        useGpu = on
        if on { gpuBroken = false } // an explicit "turn on" retries a GPU that failed before
        changed()

        await loadLock.acquire()
        defer {
            loadLock.release()
            changed()
        }
        guard let current = active else { return }
        let wantGpu = on && isGpuRuntimeAvailable
        guard wantGpu != current.onGpu else { return }
        if let next = await load(current.model, path: modelPath(current.model), onGpu: wantGpu) {
            activate(next)
        }
    }

    private func loadSelected() async -> Bool {
        await loadLock.acquire()
        defer {
            downloadingModel = nil
            loadLock.release()
            changed()
        }

        let target = selectedModel
        if active?.model == target { return true }
        lastError = nil
        Paths.ensure(modelDirectory)
        cleanupStalePartialDownloads()
        let path = modelPath(target)

        do {
            for _ in 0..<2 {
                if !Self.isValidModelFile(path) {
                    try await download(target, to: path)
                }
                if active == nil { setState(.loading) }

                let gpu = useGpu && isGpuRuntimeAvailable
                var loaded = await load(target, path: path, onGpu: gpu)
                if loaded == nil && gpu {
                    gpuBroken = true // the card refused it: the processor copy keeps voice working
                    loaded = await load(target, path: path, onGpu: false)
                }
                if let loaded {
                    activate(loaded)
                    warmUp()
                    return true
                }

                // An existing file that doesn't load is a broken or partial download: fetch a fresh copy once.
                Log.warn("[Whisper] Model '\(path.path)' failed to load, deleting it and downloading again.")
                try? FileManager.default.removeItem(at: path)
            }
            reportFailure("Модель розпізнавання пошкоджена і не завантажується навіть після повторного завантаження.")
            return false
        } catch {
            Log.error("[Whisper] Failed to prepare model '\(target.id)'", error)
            reportFailure("Не вдалося завантажити розпізнавання «\(target.title)» (\(error.localizedDescription)). Перевірте інтернет і спробуйте ще раз.")
            return false
        }
    }

    /// A failed switch keeps the previous model working; a failed first start is a real failure.
    private func reportFailure(_ message: String) {
        lastError = message
        if let current = active {
            selectedModel = current.model
            changed()
        } else {
            setState(.failed)
        }
    }

    private func load(_ model: WhisperModelInfo, path: URL, onGpu: Bool) async -> LoadedModel? {
        await withCheckedContinuation { continuation in
            loading.async {
                let started = Date()
                var params = whisper_context_default_params()
                params.use_gpu = onGpu
                guard let ctx = whisper_init_from_file_with_params(path.path, params) else {
                    Log.warn("[Whisper] Loading '\(model.id)' on \(onGpu ? "GPU" : "CPU") failed.")
                    continuation.resume(returning: nil)
                    return
                }
                Log.info("[Whisper] Model '\(model.id)' loaded on \(onGpu ? "GPU (\(Self.metalDevice?.name ?? "Metal"))" : "CPU") in \(Int(Date().timeIntervalSince(started) * 1000)) ms.")
                continuation.resume(returning: LoadedModel(ctx: ctx, model: model, onGpu: onGpu))
            }
        }
    }

    /// Makes `next` the active model; the previous one is freed after any run already queued.
    private func activate(_ next: LoadedModel) {
        inference.async { [self] in
            let old = active
            active = next
            if let old, old !== next {
                whisper_free(old.ctx)
            }
            state = .ready
            changed()
        }
        // reads of isModelReady right after loading must already see the new model
        if active == nil { active = next }
    }

    /// The first inference allocates compute buffers; doing it up front keeps the first real one snappy.
    private func warmUp() {
        let silence = [Float](repeating: 0, count: AudioAnalysis.sampleRate)
        inference.async { [self] in _ = runSync(silence, preview: true) }
    }

    // MARK: - Transcription

    /// Full-quality transcription of 16 kHz mono samples. Waits for the model if it is still loading.
    func transcribe(_ samples: [Float]) async -> String {
        if samples.isEmpty || !AudioAnalysis.hasSpeech(samples) { return "" }
        guard await ensureModelLoaded() else { return "" }
        return await withCheckedContinuation { continuation in
            inference.async { [self] in continuation.resume(returning: runSync(samples, preview: false)) }
        }
    }

    /// Fast pass for live feedback while recording; nil when not ready or another preview is still running.
    func tryTranscribePreview(_ samples: [Float]) async -> String? {
        guard isModelReady, !samples.isEmpty, !previewBusy else { return nil }
        previewBusy = true
        defer { previewBusy = false }
        if !AudioAnalysis.hasSpeech(samples) { return "" }
        return await withCheckedContinuation { continuation in
            inference.async { [self] in continuation.resume(returning: runSync(samples, preview: true)) }
        }
    }

    static func prompt(for language: String) -> String? {
        switch language {
        case "uk": return "Коментар до знімка екрана: що не працює і що треба виправити."
        case "en": return "A comment on a screenshot: what is broken and what needs fixing."
        default: return nil
        }
    }

    /// Runs on the inference queue only.
    private func runSync(_ samples: [Float], preview: Bool) -> String {
        guard let model = active else { return "" }
        let input = AudioAnalysis.padForWhisper(AudioAnalysis.normalizeLevel(samples))
        // The final text weighs several candidates instead of taking the first word every time: noticeably fewer wrong
        // words, at about twice the time; on the CPU a narrower beam keeps it bearable. Same as the Windows app.
        var params = whisper_full_default_params(preview ? WHISPER_SAMPLING_GREEDY : WHISPER_SAMPLING_BEAM_SEARCH)
        if !preview {
            params.beam_search.beam_size = isRunningOnGpu ? 5 : 3
        }
        params.n_threads = Int32(preview ? previewThreads : threads)
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false

        if preview {
            // Encoder cost is proportional to the audio context: limiting it to the clip makes previews ~3× faster.
            let seconds = Double(input.count) / Double(AudioAnalysis.sampleRate)
            let audioContext = min(max(Int((seconds * 50 / 64.0 + 1).rounded(.up)) * 64, 256), 1500)
            params.no_context = true
            params.single_segment = true
            params.temperature_inc = 0
            params.audio_ctx = Int32(audioContext)
            // a single greedy segment can loop ("the page is a test of the page…"): cap it near the speech length
            params.max_tokens = Int32(seconds * 8 + 16)
        }

        let lang = language.isEmpty ? "auto" : language
        // A short sentence in the spoken language steers spelling and punctuation (and keeps Ukrainian from drifting
        // into Russian words). Same text as the Windows app.
        let prompt = Self.prompt(for: lang)
        let result: Int32 = lang.withCString { cLanguage in
            (prompt ?? "").withCString { cPrompt in
                params.language = cLanguage
                if prompt != nil { params.initial_prompt = cPrompt }
                return input.withUnsafeBufferPointer { buffer in
                    whisper_full(model.ctx, params, buffer.baseAddress, Int32(buffer.count))
                }
            }
        }
        guard result == 0 else {
            Log.warn("[Whisper] whisper_full failed with \(result).")
            return ""
        }

        var text = ""
        let segments = whisper_full_n_segments(model.ctx)
        for i in 0..<segments {
            if let segment = whisper_full_get_segment_text(model.ctx, i) {
                text += String(cString: segment)
            }
        }
        return TranscriptCleaner.clean(text)
    }

    // MARK: - Downloads

    private func download(_ model: WhisperModelInfo, to path: URL) async throws {
        downloadingModel = model
        setProgress(0)
        if active == nil { setState(.downloading) }
        changed()
        Log.info("[Whisper] Downloading '\(model.id)' from \(model.url)")

        let partial = path.appendingPathExtension("part")
        let bytes = try await FileDownloader.download(URL(string: model.url)!, to: partial) { [weak self] fraction, _ in
            self?.setProgress(fraction)
        }
        if bytes < Self.minValidModelBytes {
            try? FileManager.default.removeItem(at: partial)
            throw FileDownloader.DownloadError(message: "модель завантажено не повністю (\(bytes / 1_048_576) МБ)")
        }
        try? FileManager.default.removeItem(at: path)
        try FileManager.default.moveItem(at: partial, to: path)
        setProgress(1)
        Log.info("[Whisper] Model '\(model.id)' downloaded (\(bytes / 1_048_576) MB).")
    }

    private func modelPath(_ model: WhisperModelInfo) -> URL { modelDirectory.appendingPathComponent(model.fileName) }

    private func cleanupStalePartialDownloads() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: modelDirectory.path)) ?? []
        for name in names where name.hasSuffix(".part") {
            try? FileManager.default.removeItem(at: modelDirectory.appendingPathComponent(name))
        }
    }

    private static func isValidModelFile(_ url: URL) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        return size >= minValidModelBytes
    }

    // MARK: - State

    private func setProgress(_ value: Double) {
        let previous = downloadProgress
        downloadProgress = value
        if Int(previous * 100) != Int(value * 100) { changed() }
    }

    private func setState(_ newState: ModelState) {
        state = newState
        changed()
    }

    private func changed() {
        DispatchQueue.main.async { [weak self] in self?.onChange?() }
    }

    private static func performanceCores() -> Int {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &value, &size, nil, 0) == 0, value > 0 {
            return Int(value)
        }
        return ProcessInfo.processInfo.activeProcessorCount
    }

    private static var logHandlerInstalled = false

    /// whisper.cpp / ggml talk a lot; keep the few lines that matter (device, failures).
    private static func installLogHandler() {
        if logHandlerInstalled { return }
        logHandlerInstalled = true
        whisper_log_set({ level, text, _ in
            guard let text else { return }
            let message = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
            if message.isEmpty { return }
            let lower = message.lowercased()
            if lower.contains("core ml") { return } // the optional Core ML encoder is simply not downloaded
            if level == GGML_LOG_LEVEL_ERROR || lower.contains("fail") || lower.contains("error")
                || lower.contains("found device") || lower.contains("using metal") {
                Log.info("[whisper.cpp] " + message)
            }
        }, nil)
    }
}
