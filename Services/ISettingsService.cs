using ScreenVoicer.Models;

namespace ScreenVoicer.Services
{
    public interface ISettingsService
    {
        /// <summary>WinMM name of the preferred microphone; empty means the system default device.</summary>
        string SelectedMicrophoneName { get; set; }

        string OutputDirectory { get; set; }

        /// <summary>Mode the overlay opens in; remembers the last mode the user picked.</summary>
        CaptureMode DefaultCaptureMode { get; set; }

        /// <summary>Whisper language code ("uk", "en") or "auto".</summary>
        string Language { get; set; }

        /// <summary>Speech model id (see <see cref="WhisperModels"/>); null = not chosen yet (pick by hardware).</summary>
        string? Model { get; set; }

        /// <summary>Run speech recognition on the video card when one is available.</summary>
        bool UseGpu { get; set; }

        /// <summary>Global capture shortcut, e.g. "Alt+Shift+S".</summary>
        string Hotkey { get; set; }

        /// <summary>The one-time "you have a GPU, try the accurate model" hint was already shown.</summary>
        bool ModelHintShown { get; set; }

        /// <summary>Last version the "update available" toast was shown for (it shows once per version).</summary>
        string? UpdateNotifiedVersion { get; set; }

        void Save();
    }
}
