using System;
using System.IO;
using System.Text.Json;
using ScreenVoicer.Models;

namespace ScreenVoicer.Services
{
    public sealed class SettingsService : ISettingsService
    {
        public const string DefaultOutputDirectory = @"C:\AI_Screenshots";
        public const string DefaultHotkey = "Alt+Shift+S";
        private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };

        private readonly string _settingsFilePath;
        private readonly object _saveLock = new();

        public string SelectedMicrophoneName { get; set; } = string.Empty;
        public string OutputDirectory { get; set; } = DefaultOutputDirectory;
        public CaptureMode DefaultCaptureMode { get; set; } = CaptureMode.RectangleRegion;
        public string Language { get; set; } = "uk";
        public string? Model { get; set; }
        public bool UseGpu { get; set; } = true;
        public string Hotkey { get; set; } = DefaultHotkey;
        public bool ModelHintShown { get; set; }
        public string? UpdateNotifiedVersion { get; set; }
        public bool InsertHintShown { get; set; }
        public bool TrayIconPromoted { get; set; }

        public SettingsService(string? dataDirectory = null)
        {
            string folder = dataDirectory ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "ScreenVoicer");
            Directory.CreateDirectory(folder);
            _settingsFilePath = Path.Combine(folder, "settings.json");
            Load();
        }

        private void Load()
        {
            try
            {
                if (!File.Exists(_settingsFilePath))
                {
                    return;
                }

                var data = JsonSerializer.Deserialize<SettingsData>(File.ReadAllText(_settingsFilePath));
                if (data == null)
                {
                    return;
                }

                SelectedMicrophoneName = data.SelectedMicrophoneName ?? string.Empty;
                if (!string.IsNullOrWhiteSpace(data.OutputDirectory))
                {
                    OutputDirectory = data.OutputDirectory;
                }
                if (Enum.IsDefined(data.DefaultCaptureMode))
                {
                    DefaultCaptureMode = data.DefaultCaptureMode;
                }
                if (data.Language is "uk" or "en" or "auto")
                {
                    Language = data.Language;
                }

                // Older settings files have no model: they used "base", which is what's on disk.
                Model = string.IsNullOrWhiteSpace(data.Model) ? "base" : data.Model;
                UseGpu = data.UseGpu ?? true;
                ModelHintShown = data.ModelHintShown;
                UpdateNotifiedVersion = data.UpdateNotifiedVersion;
                InsertHintShown = data.InsertHintShown;
                TrayIconPromoted = data.TrayIconPromoted;
                if (!string.IsNullOrWhiteSpace(data.Hotkey) && HotkeyGesture.TryParse(data.Hotkey, out _))
                {
                    Hotkey = data.Hotkey;
                }
            }
            catch (Exception ex)
            {
                Log.Warn("[Settings] Could not read settings, using defaults", ex);
            }
        }

        public void Save()
        {
            lock (_saveLock)
            {
                try
                {
                    var data = new SettingsData
                    {
                        SelectedMicrophoneName = SelectedMicrophoneName,
                        OutputDirectory = OutputDirectory,
                        DefaultCaptureMode = DefaultCaptureMode,
                        Language = Language,
                        Model = Model,
                        UseGpu = UseGpu,
                        Hotkey = Hotkey,
                        ModelHintShown = ModelHintShown,
                        UpdateNotifiedVersion = UpdateNotifiedVersion,
                        InsertHintShown = InsertHintShown,
                        TrayIconPromoted = TrayIconPromoted
                    };

                    // Write-then-rename so a crash mid-write can never leave a truncated settings file.
                    string tempPath = _settingsFilePath + ".tmp";
                    File.WriteAllText(tempPath, JsonSerializer.Serialize(data, JsonOptions));
                    File.Move(tempPath, _settingsFilePath, overwrite: true);
                }
                catch (Exception ex)
                {
                    Log.Warn("[Settings] Could not save settings", ex);
                }
            }
        }

        private sealed class SettingsData
        {
            public string? SelectedMicrophoneName { get; set; }
            public string? OutputDirectory { get; set; }
            public CaptureMode DefaultCaptureMode { get; set; }
            public string? Language { get; set; }
            public string? Model { get; set; }
            public bool? UseGpu { get; set; }
            public string? Hotkey { get; set; }
            public bool ModelHintShown { get; set; }
            public string? UpdateNotifiedVersion { get; set; }
            public bool InsertHintShown { get; set; }
            public bool TrayIconPromoted { get; set; }
        }
    }
}
