using System;
using System.Collections.Generic;
using System.Threading.Tasks;

namespace ScreenVoicer.Services
{
    /// <param name="DeviceNumber">WinMM device number, -1 for the system default device.</param>
    /// <param name="Name">WinMM product name (stored in settings, empty for the default device).</param>
    /// <param name="DisplayName">Full endpoint name for the UI.</param>
    public sealed record MicrophoneInfo(int DeviceNumber, string Name, string DisplayName)
    {
        public bool IsSystemDefault => DeviceNumber < 0;

        public override string ToString() => DisplayName;
    }

    public interface IAudioRecorderService : IDisposable
    {
        bool IsRecording { get; }

        /// <summary>WinMM name of the preferred microphone. Empty = system default device.</summary>
        string PreferredMicrophone { get; set; }

        /// <summary>Reason the last <see cref="StartRecording"/> failed (Ukrainian).</summary>
        string? LastError { get; }

        /// <summary>Normalized 0..1 input level, raised from the audio thread.</summary>
        event EventHandler<float>? AudioLevelChanged;

        IReadOnlyList<MicrophoneInfo> GetMicrophones();

        bool StartRecording();

        /// <summary>Copy of everything recorded so far as 16 kHz mono float samples.</summary>
        float[] GetSamplesSnapshot();

        /// <summary>Stops the device, waits for the last buffers and returns the whole recording.</summary>
        Task<float[]> StopRecordingAsync();

        void CancelRecording();

        /// <summary>True when there is a finished take that <see cref="PlayLastRecording"/> can play.</summary>
        bool HasLastRecording { get; }

        /// <summary>
        /// Plays the last finished take through the default speakers, so the user can hear what the
        /// recognizer heard (a muffled or distant microphone is obvious by ear). Returns false if it can't.
        /// </summary>
        bool PlayLastRecording();
    }
}
