using System;
using System.Threading;
using System.Threading.Tasks;

namespace ScreenVoicer.Services
{
    public enum ModelState
    {
        NotLoaded,
        Downloading,
        Loading,
        Ready,
        Failed
    }

    public interface ITranscriptionService : IDisposable
    {
        /// <summary>Ready means a model is loaded and transcribing (even while another one is being downloaded).</summary>
        ModelState State { get; }
        bool IsModelReady { get; }

        /// <summary>0..1 while <see cref="DownloadingModel"/> is being downloaded.</summary>
        double DownloadProgress { get; }

        /// <summary>Human readable reason of the last failure (Ukrainian), null when healthy.</summary>
        string? LastError { get; }

        /// <summary>Whisper language code ("uk", "en") or "auto".</summary>
        string Language { get; set; }

        /// <summary>The model the user chose.</summary>
        WhisperModelInfo SelectedModel { get; }

        /// <summary>The model that currently transcribes (can lag behind <see cref="SelectedModel"/> during a switch).</summary>
        WhisperModelInfo? ActiveModel { get; }

        /// <summary>Model being downloaded right now, if any.</summary>
        WhisperModelInfo? DownloadingModel { get; }

        bool UseGpu { get; }

        /// <summary>The GPU (Vulkan) build of whisper.cpp could be loaded on this PC.</summary>
        bool IsGpuRuntimeAvailable { get; }

        bool IsRunningOnGpu { get; }

        /// <summary>Video card name reported by the Vulkan or CUDA backend.</summary>
        string? GpuName { get; }

        /// <summary>"CUDA" or "Vulkan" once the native library is loaded, otherwise null.</summary>
        string? GpuBackend { get; }

        /// <summary>Raised from background threads whenever any of the state above changes.</summary>
        event EventHandler? StateChanged;

        /// <summary>Downloads (if needed) and loads the selected model. Safe to call repeatedly; retries after a failure.</summary>
        Task<bool> EnsureModelLoadedAsync(CancellationToken cancellationToken = default);

        /// <summary>Switches to another model; the current one keeps working until the new one is ready.</summary>
        Task<bool> SwitchModelAsync(string modelId);

        /// <summary>Moves inference to the video card or back to the processor without a restart.</summary>
        Task SetUseGpuAsync(bool useGpu);

        /// <summary>Full-quality transcription of 16 kHz mono samples. Waits for the model if it is still loading.</summary>
        Task<string> TranscribeAsync(float[] samples, CancellationToken cancellationToken = default);

        /// <summary>
        /// Fast, lower-quality pass for live feedback while recording.
        /// Returns null when the model is not ready or another preview is still running.
        /// </summary>
        Task<string?> TryTranscribePreviewAsync(float[] samples);
    }
}
