using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace ScreenVoicer.Services
{
    /// <summary>
    /// Push-to-talk recorder: 16 kHz / 16-bit / mono via WinMM (the wave mapper resamples from the device format).
    /// Samples are kept as raw PCM in memory and handed to Whisper as floats — no WAV container round-trip.
    /// </summary>
    public sealed class AudioRecorderService : IAudioRecorderService
    {
        private const int SampleRate = 16000;
        private const int WaveMapper = -1;

        private readonly object _lock = new();
        private WaveInEvent? _waveIn;
        private WaveOutEvent? _playback;
        private TaskCompletionSource? _stoppedSignal;
        private short[] _pcm = new short[SampleRate * 30];
        private int _sampleCount;
        private bool _isRecording;
        private bool _disposed;

        public bool IsRecording => _isRecording;
        public string PreferredMicrophone { get; set; } = string.Empty;
        public string? LastError { get; private set; }

        public event EventHandler<float>? AudioLevelChanged;

        public IReadOnlyList<MicrophoneInfo> GetMicrophones()
        {
            var endpointNames = GetEndpointNames(out string? defaultName);
            var list = new List<MicrophoneInfo>
            {
                new(WaveMapper, string.Empty,
                    defaultName != null ? $"Системний за замовчуванням ({defaultName})" : "Системний за замовчуванням")
            };

            int count = SafeDeviceCount();
            for (int i = 0; i < count; i++)
            {
                try
                {
                    string name = WaveInEvent.GetCapabilities(i).ProductName;
                    // WinMM truncates names to 31 characters; show the full endpoint name when it is unambiguous.
                    var matches = endpointNames.Where(n => n.StartsWith(name, StringComparison.OrdinalIgnoreCase)).ToList();
                    list.Add(new MicrophoneInfo(i, name, matches.Count == 1 ? matches[0] : name));
                }
                catch (Exception ex)
                {
                    Log.Warn($"[Audio] Could not read capabilities of input device {i}", ex);
                }
            }

            return list;
        }

        public bool StartRecording()
        {
            StopPlayback(); // don't record our own playback
            lock (_lock)
            {
                if (_disposed)
                {
                    return false;
                }
                if (_waveIn != null)
                {
                    return _isRecording;
                }

                LastError = null;
                if (SafeDeviceCount() == 0)
                {
                    LastError = "Мікрофон не знайдено. Підключіть мікрофон і спробуйте ще раз.";
                    return false;
                }

                _sampleCount = 0;
                int preferred = ResolveDeviceNumber();
                if (TryOpen(preferred) || (preferred != WaveMapper && TryOpen(WaveMapper)))
                {
                    _isRecording = true;
                    return true;
                }

                LastError ??= "Не вдалося відкрити мікрофон.";
                return false;
            }
        }

        private bool TryOpen(int deviceNumber)
        {
            var waveIn = new WaveInEvent
            {
                DeviceNumber = deviceNumber,
                WaveFormat = new WaveFormat(SampleRate, 16, 1),
                BufferMilliseconds = 50,
                NumberOfBuffers = 4 // 200 ms of headroom so a busy CPU (Whisper previews) doesn't drop audio
            };
            waveIn.DataAvailable += OnDataAvailable;
            waveIn.RecordingStopped += OnRecordingStopped;

            try
            {
                _stoppedSignal = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                _waveIn = waveIn;
                waveIn.StartRecording();
                Log.Info($"[Audio] Recording started on device {deviceNumber}.");
                return true;
            }
            catch (Exception ex)
            {
                Log.Warn($"[Audio] Failed to open input device {deviceNumber}", ex);
                LastError = $"Не вдалося відкрити мікрофон: {ex.Message}";
                waveIn.DataAvailable -= OnDataAvailable;
                waveIn.RecordingStopped -= OnRecordingStopped;
                try { waveIn.Dispose(); } catch { }
                _waveIn = null;
                _stoppedSignal = null;
                return false;
            }
        }

        private int ResolveDeviceNumber()
        {
            if (string.IsNullOrWhiteSpace(PreferredMicrophone))
            {
                return WaveMapper;
            }

            // Device numbers shift when USB devices come and go, so the choice is stored by name.
            int count = SafeDeviceCount();
            for (int i = 0; i < count; i++)
            {
                try
                {
                    if (string.Equals(WaveInEvent.GetCapabilities(i).ProductName, PreferredMicrophone, StringComparison.OrdinalIgnoreCase))
                    {
                        return i;
                    }
                }
                catch
                {
                    // Device vanished while enumerating.
                }
            }

            Log.Warn($"[Audio] Preferred microphone '{PreferredMicrophone}' not found, using the default device.");
            return WaveMapper;
        }

        private void OnDataAvailable(object? sender, WaveInEventArgs e)
        {
            float level;
            lock (_lock)
            {
                if (!ReferenceEquals(sender, _waveIn) || e.BytesRecorded <= 0)
                {
                    return;
                }

                int newSamples = e.BytesRecorded / 2;
                if (_sampleCount + newSamples > _pcm.Length)
                {
                    Array.Resize(ref _pcm, Math.Max(_pcm.Length * 2, _sampleCount + newSamples));
                }
                Buffer.BlockCopy(e.Buffer, 0, _pcm, _sampleCount * 2, newSamples * 2);
                _sampleCount += newSamples;

                level = AudioAnalysis.LevelFromPcm16(e.Buffer, e.BytesRecorded);
            }

            AudioLevelChanged?.Invoke(this, level);
        }

        private void OnRecordingStopped(object? sender, StoppedEventArgs e)
        {
            if (e.Exception != null)
            {
                Log.Warn("[Audio] Recording stopped with an error", e.Exception);
            }

            lock (_lock)
            {
                if (ReferenceEquals(sender, _waveIn))
                {
                    _isRecording = false;
                    _stoppedSignal?.TrySetResult();
                }
            }
        }

        public float[] GetSamplesSnapshot()
        {
            lock (_lock)
            {
                return ToFloat(_pcm, _sampleCount);
            }
        }

        public async Task<float[]> StopRecordingAsync()
        {
            WaveInEvent? waveIn;
            Task? stopped;
            lock (_lock)
            {
                waveIn = _waveIn;
                stopped = _stoppedSignal?.Task;
                if (waveIn == null)
                {
                    return Array.Empty<float>();
                }
            }

            try
            {
                waveIn.StopRecording();
            }
            catch (Exception ex)
            {
                Log.Warn("[Audio] StopRecording failed", ex);
            }

            // RecordingStopped is raised after the driver returned the last (partial) buffers, so waiting
            // for it keeps the end of the last word that the old fixed 150 ms delay used to cut off.
            if (stopped != null)
            {
                await Task.WhenAny(stopped, Task.Delay(1000));
            }

            lock (_lock)
            {
                if (!ReferenceEquals(waveIn, _waveIn))
                {
                    return Array.Empty<float>(); // cancelled meanwhile
                }

                float[] result = ToFloat(_pcm, _sampleCount);
                SaveDiagnosticCopy(_pcm, _sampleCount);
                ReleaseDevice();
                Log.Info($"[Audio] Recording stopped: {result.Length / (double)SampleRate:F2} s, {DescribeLevel(result)}.");
                return result;
            }
        }

        public void CancelRecording()
        {
            lock (_lock)
            {
                ReleaseDevice();
            }
        }

        private void ReleaseDevice()
        {
            _isRecording = false;
            _sampleCount = 0;
            _stoppedSignal?.TrySetResult();
            _stoppedSignal = null;

            var waveIn = _waveIn;
            _waveIn = null;
            if (waveIn == null)
            {
                return;
            }

            waveIn.DataAvailable -= OnDataAvailable;
            waveIn.RecordingStopped -= OnRecordingStopped;
            try
            {
                waveIn.Dispose(); // stops the device if it is still running
            }
            catch (Exception ex)
            {
                Log.Warn("[Audio] Disposing the input device failed", ex);
            }

            if (_pcm.Length > SampleRate * 120)
            {
                _pcm = new short[SampleRate * 30]; // don't keep a huge buffer around after a very long take
            }
        }

        /// <summary>Peak and loudness of a take — the first thing to look at when recognition goes wrong.</summary>
        public static string DescribeLevel(float[] samples)
        {
            if (samples.Length == 0)
            {
                return "empty";
            }

            double sum = 0;
            float peak = 0;
            foreach (float s in samples)
            {
                sum += s * s;
                peak = Math.Max(peak, Math.Abs(s));
            }
            double rms = Math.Sqrt(sum / samples.Length);
            static string Db(double v) => v <= 0 ? "-inf" : $"{20 * Math.Log10(v):F1}";
            return $"peak {Db(peak)} dBFS, rms {Db(rms)} dBFS";
        }

        private static string LastRecordingPath => Path.Combine(Log.LogDirectory, "last-recording.wav");

        public bool HasLastRecording => File.Exists(LastRecordingPath);

        public bool PlayLastRecording()
        {
            StopPlayback();
            try
            {
                // From memory, so the next take can overwrite the file while this one is still playing.
                var reader = new WaveFileReader(new MemoryStream(File.ReadAllBytes(LastRecordingPath)));
                var output = new WaveOutEvent();
                output.Init(reader);
                output.PlaybackStopped += (_, _) =>
                {
                    output.Dispose();
                    reader.Dispose();
                };
                lock (_lock)
                {
                    _playback = output;
                }
                output.Play();
                return true;
            }
            catch (Exception ex)
            {
                Log.Warn("[Audio] Could not play the last recording", ex);
                return false;
            }
        }

        private void StopPlayback()
        {
            WaveOutEvent? playback;
            lock (_lock)
            {
                playback = _playback;
                _playback = null;
            }
            try
            {
                playback?.Stop(); // PlaybackStopped disposes it
            }
            catch
            {
                // already finished
            }
        }

        /// <summary>Keeps the last take as a WAV next to the log, so a bad transcription can be diagnosed.</summary>
        private static void SaveDiagnosticCopy(short[] pcm, int count)
        {
            try
            {
                Directory.CreateDirectory(Log.LogDirectory);
                using var writer = new WaveFileWriter(LastRecordingPath, new WaveFormat(SampleRate, 16, 1));
                var bytes = new byte[count * 2];
                Buffer.BlockCopy(pcm, 0, bytes, 0, bytes.Length);
                writer.Write(bytes, 0, bytes.Length);
            }
            catch (Exception ex)
            {
                Log.Warn("[Audio] Could not save the diagnostic copy", ex);
            }
        }

        private static float[] ToFloat(short[] pcm, int count)
        {
            var result = new float[count];
            for (int i = 0; i < count; i++)
            {
                result[i] = pcm[i] / 32768f;
            }
            return result;
        }

        private static int SafeDeviceCount()
        {
            try
            {
                return WaveInEvent.DeviceCount;
            }
            catch
            {
                return 0;
            }
        }

        private static List<string> GetEndpointNames(out string? defaultName)
        {
            defaultName = null;
            var names = new List<string>();
            try
            {
                using var enumerator = new MMDeviceEnumerator();
                foreach (var device in enumerator.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active))
                {
                    using (device)
                    {
                        names.Add(device.FriendlyName);
                    }
                }

                if (enumerator.HasDefaultAudioEndpoint(DataFlow.Capture, Role.Console))
                {
                    using var device = enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Console);
                    defaultName = device.FriendlyName;
                }
            }
            catch (Exception ex)
            {
                Log.Warn("[Audio] Could not enumerate audio endpoints", ex);
            }
            return names;
        }

        public void Dispose()
        {
            lock (_lock)
            {
                if (_disposed)
                {
                    return;
                }
                _disposed = true;
                StopPlayback();
                ReleaseDevice();
            }
        }
    }
}
