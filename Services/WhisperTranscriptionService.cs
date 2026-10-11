using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Whisper.net;
using Whisper.net.LibraryLoader;
using Whisper.net.Logger;

namespace ScreenVoicer.Services
{
    public sealed class WhisperTranscriptionService : ITranscriptionService
    {
        private const long MinValidModelBytes = 30L * 1024 * 1024; // the smallest model we offer is 56+ MB
        private static readonly TimeSpan DownloadStallTimeout = TimeSpan.FromSeconds(30);
        private static readonly Regex VulkanDevice = new(@"ggml_vulkan:\s*0\s*=\s*(.+?)\s*\(", RegexOptions.Compiled);
        private static readonly Regex CudaDevice = new(@"Device 0:\s*(.+?),\s*compute capability", RegexOptions.Compiled);

        private static string? _gpuName;
        private static IDisposable? _nativeLog;

        /// <summary>
        /// ggml-vulkan is not safe for concurrent use of one device: a preview and a final run on the GPU at the
        /// same time crashed the process with an access violation (reproduced). All GPU work goes through here;
        /// CPU runs stay parallel.
        /// </summary>
        private static readonly SemaphoreSlim GpuGate = new(1, 1);

        /// <summary>A loaded model. A replaced (retired) one is disposed when its last run finishes.</summary>
        private sealed class LoadedModel
        {
            public LoadedModel(WhisperFactory factory, WhisperModelInfo model, bool onGpu)
            {
                Factory = factory;
                Model = model;
                OnGpu = onGpu;
            }

            public WhisperFactory Factory { get; }
            public WhisperModelInfo Model { get; }
            public bool OnGpu { get; }
            public int ActiveRuns;
            public bool Retired;
        }

        private readonly string _modelDirectory;
        private readonly string _gpuInitMarker;
        private readonly SemaphoreSlim _initLock = new(1, 1);
        private readonly SemaphoreSlim _finalLock = new(1, 1);
        private readonly object _sync = new();
        private readonly int _threads;
        private readonly int _previewThreads;

        private WhisperModelInfo _selected;
        private bool _useGpu;
        private bool _gpuBroken;
        private LoadedModel? _active;
        private volatile ModelState _state = ModelState.NotLoaded;
        private double _downloadProgress;
        private WhisperModelInfo? _downloading;
        private int _generation; // bumped by every switch, so a late GPU upgrade of an old model is discarded
        private int _previewBusy;
        private bool _disposed;

        public WhisperTranscriptionService(string language = "uk", string modelId = "base", bool useGpu = true, string? modelDirectory = null)
        {
            Language = language;
            _selected = WhisperModels.Find(modelId);
            _useGpu = useGpu;
            _modelDirectory = modelDirectory ?? DefaultModelDirectory;
            _gpuInitMarker = Path.Combine(_modelDirectory, "gpu-init.marker");
            _threads = Math.Clamp(Environment.ProcessorCount, 2, 8);
            _previewThreads = Math.Clamp(Environment.ProcessorCount / 2, 2, 6);

            // The previous run died while initializing the video card (driver crash): don't try again automatically.
            if (File.Exists(_gpuInitMarker))
            {
                GpuCrashDetected = true;
                _gpuBroken = true;
                TryDelete(_gpuInitMarker);
                Log.Warn("[Whisper] The previous GPU initialization did not finish; using the processor.");
            }
        }

        public static string DefaultModelDirectory { get; } =
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "ScreenVoicer", "models");

        public event EventHandler? StateChanged;

        public ModelState State => _state;
        public bool IsModelReady => _active != null;
        public double DownloadProgress => Volatile.Read(ref _downloadProgress);
        public string? LastError { get; private set; }
        public string Language { get; set; }
        public WhisperModelInfo SelectedModel => _selected;
        public WhisperModelInfo? ActiveModel => _active?.Model;
        public WhisperModelInfo? DownloadingModel => _downloading;
        public bool UseGpu => _useGpu;
        public bool IsGpuRuntimeAvailable =>
            (RuntimeOptions.LoadedLibrary is RuntimeLibrary.Vulkan or RuntimeLibrary.Cuda) && !_gpuBroken;
        public bool IsRunningOnGpu => _active?.OnGpu == true;
        public string? GpuName => _gpuName;

        /// <summary>"CUDA" or "Vulkan" once the native library is loaded, otherwise null.</summary>
        public string? GpuBackend => RuntimeOptions.LoadedLibrary switch
        {
            RuntimeLibrary.Cuda => "CUDA",
            RuntimeLibrary.Vulkan => "Vulkan",
            _ => null
        };

        /// <summary>True when the last session crashed while starting the GPU, so it was turned off for safety.</summary>
        public bool GpuCrashDetected { get; }

        public static bool IsModelDownloaded(string modelId, string? modelDirectory = null) =>
            IsValidModelFile(Path.Combine(modelDirectory ?? DefaultModelDirectory, WhisperModels.Find(modelId).FileName));

        #region Loading & switching

        public Task<bool> EnsureModelLoadedAsync(CancellationToken cancellationToken = default)
        {
            // Loading a model is synchronous native work; never let it run on the caller's (UI) thread.
            return IsModelReady ? Task.FromResult(true) : Task.Run(() => LoadSelectedAsync(cancellationToken));
        }

        public Task<bool> SwitchModelAsync(string modelId)
        {
            _selected = WhisperModels.Find(modelId);
            RaiseChanged();
            return Task.Run(() => LoadSelectedAsync(CancellationToken.None));
        }

        public Task SetUseGpuAsync(bool useGpu) => Task.Run(async () =>
        {
            _useGpu = useGpu;
            if (useGpu)
            {
                _gpuBroken = false; // an explicit "turn on" retries a GPU that failed before
            }
            RaiseChanged();

            await _initLock.WaitAsync().ConfigureAwait(false);
            try
            {
                var current = _active;
                if (current == null || _disposed)
                {
                    return;
                }

                int generation = Interlocked.Increment(ref _generation);
                string path = ModelPath(current.Model);
                if (useGpu && !current.OnGpu && IsGpuRuntimeAvailable)
                {
                    StartGpuUpgrade(current.Model, path, generation);
                }
                else if (!useGpu && current.OnGpu && TryLoad(current.Model, path, onGpu: false) is { } cpu)
                {
                    TryActivate(cpu, generation);
                }
            }
            finally
            {
                _initLock.Release();
                RaiseChanged();
            }
        });

        /// <summary>Makes <see cref="SelectedModel"/> the active one; the old model keeps working until then.</summary>
        private async Task<bool> LoadSelectedAsync(CancellationToken cancellationToken)
        {
            try
            {
                await _initLock.WaitAsync(cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return false;
            }

            var target = _selected;
            try
            {
                if (_disposed)
                {
                    return false;
                }
                if (_active?.Model == target)
                {
                    return true;
                }

                LastError = null;
                if (!EnsureNativeLibrary())
                {
                    return false;
                }

                Directory.CreateDirectory(_modelDirectory);
                CleanupStalePartialDownloads();
                int generation = Interlocked.Increment(ref _generation);
                string path = ModelPath(target);

                for (int attempt = 0; attempt < 2; attempt++)
                {
                    if (!IsValidModelFile(path))
                    {
                        await DownloadModelAsync(target, path, cancellationToken).ConfigureAwait(false);
                    }

                    if (_active == null)
                    {
                        SetState(ModelState.Loading);
                    }

                    // CUDA compiles nothing on first start, so a big model goes straight to the card: loading it on
                    // the processor first cost ~7.5 s and 1 GB of RAM for a copy that is far too slow to use anyway.
                    if (target.NeedsGpu && _useGpu && IsGpuRuntimeAvailable && RuntimeOptions.LoadedLibrary == RuntimeLibrary.Cuda)
                    {
                        if (await LoadOnGpuAsync(target, path).ConfigureAwait(false) is { } direct)
                        {
                            ActivateGpu(direct, generation);
                            return true;
                        }
                        // The card failed (now marked unusable): the processor copy below keeps voice working.
                    }

                    // Start on the processor (fast and always works), then move to the video card in the background:
                    // the very first Vulkan start compiles shaders for ~25 s, later starts take ~0.5 s.
                    if (TryLoad(target, path, onGpu: false) is { } cpu)
                    {
                        TryActivate(cpu, generation);
                        bool gpuNext = _useGpu && IsGpuRuntimeAvailable;
                        if (!(gpuNext && target.NeedsGpu))
                        {
                            // A big model's warm-up on the processor would keep all cores busy for ~20 s
                            // just before the video card takes over anyway.
                            _ = Task.Run(() => WarmUpAsync(cpu));
                        }
                        if (gpuNext)
                        {
                            StartGpuUpgrade(target, path, generation);
                        }
                        return true;
                    }

                    // An existing file that doesn't load is a broken/partial download: fetch a fresh copy once.
                    Log.Warn($"[Whisper] Model '{path}' failed to load, deleting it and downloading again.");
                    TryDelete(path);
                }

                ReportFailure(target, "Модель розпізнавання пошкоджена і не завантажується навіть після повторного завантаження.");
                return false;
            }
            catch (OperationCanceledException)
            {
                if (_active == null)
                {
                    SetState(ModelState.NotLoaded);
                }
                return false;
            }
            catch (Exception ex)
            {
                Log.Error($"[Whisper] Failed to prepare model '{target.Id}'", ex);
                ReportFailure(target, ex is HttpRequestException or IOException
                    ? $"Не вдалося завантажити розпізнавання «{target.Title}» ({ex.Message}). Перевірте інтернет і спробуйте ще раз."
                    : $"Не вдалося підготувати розпізнавання «{target.Title}»: {ex.Message}");
                return false;
            }
            finally
            {
                _downloading = null;
                _initLock.Release();
                RaiseChanged();
            }
        }

        /// <summary>A failed switch keeps the previous model working; a failed first start is a real failure.</summary>
        private void ReportFailure(WhisperModelInfo target, string message)
        {
            LastError = message;
            var active = _active;
            if (active != null)
            {
                _selected = active.Model;
                RaiseChanged();
            }
            else
            {
                SetState(ModelState.Failed);
            }
        }

        private void StartGpuUpgrade(WhisperModelInfo model, string path, int generation)
        {
            _ = Task.Run(async () =>
            {
                if (await LoadOnGpuAsync(model, path).ConfigureAwait(false) is { } gpu)
                {
                    ActivateGpu(gpu, generation);
                }
            });
        }

        private void ActivateGpu(LoadedModel gpu, int generation)
        {
            if (_useGpu && TryActivate(gpu, generation))
            {
                Log.Info($"[Whisper] '{gpu.Model.Id}' now runs on {_gpuName} via {GpuBackend}.");
            }
            else
            {
                DisposeModel(gpu); // the user switched model or turned the GPU off meanwhile
            }
        }

        /// <summary>Loads and warms up a copy on the video card; null (and the GPU marked unusable) if it can't run.</summary>
        private async Task<LoadedModel?> LoadOnGpuAsync(WhisperModelInfo model, string path)
        {
            var stopwatch = Stopwatch.StartNew();
            LoadedModel? gpu;
            try
            {
                File.WriteAllText(_gpuInitMarker, DateTime.Now.ToString("O"));
                gpu = TryLoad(model, path, onGpu: true);
                if (gpu != null && _gpuName == null)
                {
                    // The GPU backend loaded but reported no device: whisper.cpp silently fell back to the processor.
                    DisposeModel(gpu);
                    gpu = null;
                    Log.Warn("[Whisper] No GPU device reported, staying on the processor.");
                }
            }
            finally
            {
                TryDelete(_gpuInitMarker);
            }

            if (gpu == null)
            {
                _gpuBroken = true;
                RaiseChanged();
                return null;
            }

            long loadMs = stopwatch.ElapsedMilliseconds;
            try
            {
                await WarmUpAsync(gpu, rethrow: true).ConfigureAwait(false);
            }
            catch (Exception ex)
            {
                Log.Error("[Whisper] GPU warm-up failed, staying on the processor", ex);
                DisposeModel(gpu);
                _gpuBroken = true;
                RaiseChanged();
                return null;
            }

            Log.Info($"[Whisper] '{model.Id}' loaded on {_gpuName} (load {loadMs} ms, warm-up {stopwatch.ElapsedMilliseconds - loadMs} ms).");
            return gpu;
        }

        private LoadedModel? TryLoad(WhisperModelInfo model, string path, bool onGpu)
        {
            WhisperFactory? factory = null;
            if (onGpu)
            {
                GpuGate.Wait(); // uploading a model must not overlap with a run on the same device
            }
            try
            {
                var stopwatch = Stopwatch.StartNew();
                factory = WhisperFactory.FromPath(path, new WhisperFactoryOptions { UseGpu = onGpu });

                // FromPath does not validate the file; building a processor throws WhisperModelLoadException
                // when whisper.cpp rejected a truncated/corrupted model.
                using (factory.CreateBuilder().Build())
                {
                }

                Log.Info($"[Whisper] Model '{model.Id}' loaded on {(onGpu ? "GPU" : "CPU")} in {stopwatch.ElapsedMilliseconds} ms.");
                return new LoadedModel(factory, model, onGpu);
            }
            catch (Exception ex)
            {
                Log.Warn($"[Whisper] Loading '{model.Id}' on {(onGpu ? "GPU" : "CPU")} failed", ex);
                factory?.Dispose();
                return null;
            }
            finally
            {
                if (onGpu)
                {
                    GpuGate.Release();
                }
            }
        }

        /// <summary>Frees a model; GPU memory is released under the GPU gate.</summary>
        private static void DisposeModel(LoadedModel model)
        {
            if (!model.OnGpu)
            {
                model.Factory.Dispose();
                return;
            }

            GpuGate.Wait();
            try
            {
                model.Factory.Dispose();
            }
            finally
            {
                GpuGate.Release();
            }
        }

        /// <summary>Atomically replaces the active model unless a newer switch happened meanwhile.</summary>
        private bool TryActivate(LoadedModel next, int generation)
        {
            LoadedModel? old;
            bool disposeOld;
            lock (_sync)
            {
                if (generation != _generation || _disposed)
                {
                    return false;
                }
                old = _active;
                _active = next;
                disposeOld = old != null && Retire(old);
            }

            if (disposeOld)
            {
                DisposeModel(old!);
            }

            _state = ModelState.Ready;
            RaiseChanged();
            return true;
        }

        /// <summary>Marks a model as replaced; returns true when nobody uses it anymore (caller disposes).</summary>
        private static bool Retire(LoadedModel model)
        {
            model.Retired = true;
            return model.ActiveRuns == 0;
        }

        /// <summary>Pins a model for one run (the active one, or a specific one that isn't active yet).</summary>
        private LoadedModel? Acquire(LoadedModel? specific = null)
        {
            lock (_sync)
            {
                var model = specific ?? _active;
                if (model == null || (model.Retired && model.ActiveRuns == 0))
                {
                    return null; // retired and idle = already disposed
                }
                model.ActiveRuns++;
                return model;
            }
        }

        private void Release(LoadedModel model)
        {
            bool dispose;
            lock (_sync)
            {
                model.ActiveRuns--;
                dispose = model.Retired && model.ActiveRuns == 0;
            }
            if (dispose)
            {
                DisposeModel(model);
            }
        }

        #endregion

        #region Transcription

        public async Task<string> TranscribeAsync(float[] samples, CancellationToken cancellationToken = default)
        {
            if (samples.Length == 0 || !AudioAnalysis.HasSpeech(samples))
            {
                return string.Empty;
            }

            if (!await EnsureModelLoadedAsync(cancellationToken).ConfigureAwait(false))
            {
                return string.Empty;
            }

            await _finalLock.WaitAsync(cancellationToken).ConfigureAwait(false);
            try
            {
                return await RunAsync(samples, preview: false).ConfigureAwait(false);
            }
            finally
            {
                _finalLock.Release();
            }
        }

        public async Task<string?> TryTranscribePreviewAsync(float[] samples)
        {
            if (!IsModelReady || samples.Length == 0)
            {
                return null;
            }

            if (Interlocked.CompareExchange(ref _previewBusy, 1, 0) != 0)
            {
                return null;
            }

            try
            {
                if (!AudioAnalysis.HasSpeech(samples))
                {
                    return string.Empty;
                }
                return await RunAsync(samples, preview: true).ConfigureAwait(false);
            }
            catch (Exception ex)
            {
                Log.Warn("[Whisper] Preview transcription failed", ex);
                return null;
            }
            finally
            {
                Volatile.Write(ref _previewBusy, 0);
            }
        }

        private async Task<string> RunAsync(float[] samples, bool preview)
        {
            var model = Acquire() ?? throw new InvalidOperationException("Whisper model is not loaded.");
            try
            {
                return await RunCoreAsync(model, samples, preview).ConfigureAwait(false);
            }
            catch (Exception ex) when (model.OnGpu && !_disposed)
            {
                // A video card problem must never cost the user their comment: retry on the processor.
                Log.Error("[Whisper] GPU inference failed, falling back to the processor", ex);
                _gpuBroken = true;
                RaiseChanged();
                var cpu = TryLoad(model.Model, ModelPath(model.Model), onGpu: false);
                if (cpu == null)
                {
                    throw;
                }

                bool activated = TryActivate(cpu, Volatile.Read(ref _generation));
                var fallback = Acquire(cpu)!;
                try
                {
                    return await RunCoreAsync(fallback, samples, preview).ConfigureAwait(false);
                }
                finally
                {
                    Release(fallback);
                    if (!activated)
                    {
                        DisposeModel(cpu); // a switch happened meanwhile; this one-off copy isn't needed
                    }
                }
            }
            finally
            {
                Release(model);
            }
        }

        /// <summary>
        /// Every run gets its own processor and is never cancelled half-way. Whisper.net keeps the abort flag and
        /// the segment handlers per processor, so cancelling a run and immediately starting another one on the
        /// same processor leaked the old run's text into the new result.
        /// </summary>
        private async Task<string> RunCoreAsync(LoadedModel model, float[] samples, bool preview)
        {
            float[] input = AudioAnalysis.PadForWhisper(AudioAnalysis.NormalizeLevel(samples));
            var builder = model.Factory.CreateBuilder()
                .WithThreads(preview ? _previewThreads : _threads)
                .WithLanguage(string.IsNullOrWhiteSpace(Language) ? "auto" : Language);

            if (preview)
            {
                // Encoder cost is proportional to the audio context. Limiting it to the clip length makes
                // previews ~3x faster with the same text; temperature fallback can multiply the time on noisy input.
                double seconds = input.Length / (double)AudioAnalysis.SampleRate;
                int audioContext = Math.Clamp((int)Math.Ceiling(seconds * 50 / 64.0 + 1) * 64, 256, 1500);
                builder = builder
                    .WithNoContext()
                    .WithSingleSegment()
                    .WithTemperatureInc(0f)
                    .WithAudioContextSize(audioContext);
            }

            if (model.OnGpu)
            {
                await GpuGate.WaitAsync().ConfigureAwait(false);
            }
            try
            {
                await using var processor = builder.Build();
                var text = new StringBuilder();
                await foreach (var segment in processor.ProcessAsync(input, CancellationToken.None).ConfigureAwait(false))
                {
                    text.Append(segment.Text);
                }
                return TranscriptCleaner.Clean(text.ToString());
            }
            finally
            {
                if (model.OnGpu)
                {
                    GpuGate.Release();
                }
            }
        }

        /// <summary>The first inference allocates compute buffers; doing it up front keeps the first real one snappy.</summary>
        private async Task WarmUpAsync(LoadedModel model, bool rethrow = false)
        {
            if (Acquire(model) is not { } acquired)
            {
                return;
            }
            try
            {
                await RunCoreAsync(acquired, new float[AudioAnalysis.SampleRate], preview: true).ConfigureAwait(false);
            }
            catch (Exception ex) when (!rethrow)
            {
                Log.Warn("[Whisper] Warm-up failed", ex);
            }
            finally
            {
                Release(acquired);
            }
        }

        #endregion

        #region Native library & downloads

        private bool EnsureNativeLibrary()
        {
            try
            {
                WhisperNativeBootstrap.Configure();
                _nativeLog ??= LogProvider.AddLogger(OnNativeLog);

                // Forces the native library to load (and throws if it can't). GetRuntimeInfo() is avoided on
                // purpose: Whisper.net 1.7 frees whisper.cpp's static system-info string with FreeHGlobal.
                bool any = WhisperFactory.GetSupportedLanguages().GetEnumerator().MoveNext();
                Log.Info($"[Whisper] Native runtime: {RuntimeOptions.LoadedLibrary}, languages={any}, " +
                         $"AVX2={System.Runtime.Intrinsics.X86.Avx2.IsSupported}, threads={_threads}.");
                return true;
            }
            catch (Exception ex)
            {
                Log.Error("[Whisper] Native library failed to load", ex);
                LastError = ex is PlatformNotSupportedException
                    ? "Процесор не підтримує потрібні інструкції для розпізнавання голосу."
                    : $"Не вдалося завантажити рушій розпізнавання: {ex.Message}";
                SetState(ModelState.Failed);
                return false;
            }
        }

        private static void OnNativeLog(WhisperLogLevel level, string? message)
        {
            // Whisper.net's own loader chatter is Debug; whisper.cpp levels arrive shifted (plain INFO shows up as
            // "Error"), so filter by content and keep the log to the few lines that matter.
            if (level == WhisperLogLevel.Debug || string.IsNullOrWhiteSpace(message))
            {
                return;
            }

            var device = VulkanDevice.Match(message);
            if (!device.Success)
            {
                device = CudaDevice.Match(message);
            }
            if (device.Success)
            {
                _gpuName = device.Groups[1].Value.Trim();
            }

            if (device.Success ||
                message.Contains("whisper_backend_init_gpu", StringComparison.Ordinal) ||
                message.Contains("fail", StringComparison.OrdinalIgnoreCase) ||
                message.Contains("error", StringComparison.OrdinalIgnoreCase))
            {
                Log.Info("[whisper.cpp] " + message.Trim());
            }
        }

        private async Task DownloadModelAsync(WhisperModelInfo model, string path, CancellationToken cancellationToken)
        {
            _downloading = model;
            SetProgress(0);
            if (_active == null)
            {
                SetState(ModelState.Downloading);
            }
            RaiseChanged();
            Log.Info($"[Whisper] Downloading '{model.Id}' from {model.Url}");

            string partialPath = path + ".part";
            using var http = new HttpClient { Timeout = Timeout.InfiniteTimeSpan };
            http.DefaultRequestHeaders.UserAgent.ParseAdd("ScreenVoicer/1.6");

            using var stallCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            stallCts.CancelAfter(DownloadStallTimeout);

            using var response = await http.GetAsync(model.Url, HttpCompletionOption.ResponseHeadersRead, stallCts.Token).ConfigureAwait(false);
            response.EnsureSuccessStatusCode();
            long? total = response.Content.Headers.ContentLength;

            long received = 0;
            await using (var source = await response.Content.ReadAsStreamAsync(stallCts.Token).ConfigureAwait(false))
            await using (var target = new FileStream(partialPath, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 16, useAsync: true))
            {
                var buffer = new byte[1 << 16];
                while (true)
                {
                    stallCts.CancelAfter(DownloadStallTimeout); // reset the inactivity timer on every chunk
                    int read;
                    try
                    {
                        read = await source.ReadAsync(buffer, stallCts.Token).ConfigureAwait(false);
                    }
                    catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
                    {
                        throw new IOException("З'єднання зависло під час завантаження моделі.");
                    }

                    if (read == 0)
                    {
                        break;
                    }

                    await target.WriteAsync(buffer.AsMemory(0, read), cancellationToken).ConfigureAwait(false);
                    received += read;
                    if (total > 0)
                    {
                        SetProgress((double)received / total.Value);
                    }
                }
            }

            if ((total.HasValue && received != total.Value) || received < MinValidModelBytes)
            {
                TryDelete(partialPath);
                throw new IOException($"Модель завантажено не повністю ({received / 1048576} МБ).");
            }

            File.Move(partialPath, path, overwrite: true);
            SetProgress(1);
            Log.Info($"[Whisper] Model '{model.Id}' downloaded ({received / 1048576} MB).");
        }

        private string ModelPath(WhisperModelInfo model) => Path.Combine(_modelDirectory, model.FileName);

        private void CleanupStalePartialDownloads()
        {
            foreach (string partial in Directory.GetFiles(_modelDirectory, "*.part"))
            {
                TryDelete(partial);
            }
        }

        private static bool IsValidModelFile(string path)
        {
            try
            {
                var info = new FileInfo(path);
                return info.Exists && info.Length >= MinValidModelBytes;
            }
            catch
            {
                return false;
            }
        }

        private static void TryDelete(string path)
        {
            try
            {
                File.Delete(path);
            }
            catch (Exception ex)
            {
                Log.Warn($"[Whisper] Could not delete '{path}'", ex);
            }
        }

        #endregion

        private void SetProgress(double value)
        {
            double previous = Volatile.Read(ref _downloadProgress);
            Volatile.Write(ref _downloadProgress, value);
            if ((int)(previous * 100) != (int)(value * 100))
            {
                RaiseChanged();
            }
        }

        private void SetState(ModelState state)
        {
            _state = state;
            RaiseChanged();
        }

        private void RaiseChanged() => StateChanged?.Invoke(this, EventArgs.Empty);

        public void Dispose()
        {
            LoadedModel? idle;
            lock (_sync)
            {
                if (_disposed)
                {
                    return;
                }
                _disposed = true;
                var active = _active;
                _active = null;
                // Freeing the native context while whisper.cpp is inside a run crashes the process:
                // an in-flight run disposes the model itself when it finishes (see Release).
                idle = active != null && Retire(active) ? active : null;
            }

            if (idle != null)
            {
                DisposeModel(idle);
            }
            _state = ModelState.NotLoaded;
        }
    }

    /// <summary>
    /// Whisper.net looks for its native DLLs in "&lt;app dir&gt;\runtimes\...". In a single-file build they are
    /// extracted to a temp folder instead, so the published exe never found them ("Native Library not found in
    /// default paths"). Point the loader at the extraction folder, and prefer the Vulkan (GPU) build.
    /// </summary>
    internal static class WhisperNativeBootstrap
    {
        private static bool _configured;

        public static void Configure()
        {
            if (_configured)
            {
                return;
            }
            _configured = true;

            // The Vulkan build also contains the CPU backend, so it serves both modes; if vulkan-1.dll is missing
            // (no GPU driver) Whisper.net falls through to the plain CPU builds.
            RuntimeOptions.RuntimeLibraryOrder = new List<RuntimeLibrary> { RuntimeLibrary.Vulkan, RuntimeLibrary.Cpu, RuntimeLibrary.CpuNoAvx };

            var candidates = new List<string> { AppContext.BaseDirectory };
            if (AppContext.GetData("NATIVE_DLL_SEARCH_DIRECTORIES") is string searchDirectories)
            {
                candidates.AddRange(searchDirectories.Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries));
            }

            foreach (string directory in candidates)
            {
                foreach (string runtime in new[] { "vulkan\\win-x64", "win-x64", "noavx\\win-x64" })
                {
                    if (File.Exists(Path.Combine(directory, "runtimes", runtime, "whisper.dll")))
                    {
                        if (CudaPack.PrepareRuntimeFolder(directory))
                        {
                            // NVIDIA pack installed: CUDA first; Vulkan and CPU (mirrored next to it) stay as fallbacks.
                            RuntimeOptions.RuntimeLibraryOrder = new List<RuntimeLibrary>
                                { RuntimeLibrary.Cuda, RuntimeLibrary.Vulkan, RuntimeLibrary.Cpu, RuntimeLibrary.CpuNoAvx };
                            RuntimeOptions.LibraryPath = Path.Combine(CudaPack.BaseDirectory, "whisper.dll");
                            Log.Info($"[Whisper] Native runtimes: CUDA pack in '{CudaPack.BaseDirectory}'.");
                            return;
                        }

                        // Whisper.net only uses the directory part of LibraryPath.
                        RuntimeOptions.LibraryPath = Path.Combine(directory, "whisper.dll");
                        Log.Info($"[Whisper] Native runtimes found in '{directory}'.");
                        return;
                    }
                }
            }

            Log.Warn("[Whisper] Native runtimes folder not found next to the app or in the extraction folder.");
        }
    }
}
