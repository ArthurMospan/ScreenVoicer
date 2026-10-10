using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;
using NAudio.Wave;

namespace ScreenVoicer.Services
{
    /// <summary>
    /// <c>ScreenVoicer.exe --selftest [--lang uk|en|auto] [--model base|small|turbo] [--cpu] [speech.wav]</c> — loads the
    /// speech model the same way the app does and transcribes a file, printing timings. Useful to verify a build on another PC.
    /// </summary>
    internal static class SelfTest
    {
        [DllImport("kernel32.dll")]
        private static extern bool AttachConsole(int processId);

        [DllImport("user32.dll")]
        private static extern IntPtr GetThreadDpiAwarenessContext();

        [DllImport("user32.dll")]
        private static extern int GetAwarenessFromDpiAwarenessContext(IntPtr context);

        private static string DpiAwareness()
        {
            try
            {
                return GetAwarenessFromDpiAwarenessContext(GetThreadDpiAwarenessContext()) switch
                {
                    0 => "unaware",
                    1 => "system",
                    2 => "per-monitor",
                    int other => other.ToString()
                };
            }
            catch
            {
                return "unknown";
            }
        }

        public static async Task<int> RunAsync(string[] args)
        {
            AttachConsole(-1);
            try { Console.OutputEncoding = Encoding.UTF8; } catch { }

            string language = Option(args, "--lang") ?? "uk";
            string model = Option(args, "--model") ?? new SettingsService().Model ?? WhisperModels.Base.Id;
            bool useGpu = !args.Contains("--cpu");
            string? wavPath = args.FirstOrDefault(a => a.EndsWith(".wav", StringComparison.OrdinalIgnoreCase));

            Print($"ScreenVoicer {App.Version} self-test, language={language}, model={model}, gpu={useGpu}, " +
                  $"cpu threads={Environment.ProcessorCount}, DPI awareness={DpiAwareness()}");

            using var service = new WhisperTranscriptionService(language, model, useGpu);
            var stopwatch = Stopwatch.StartNew();
            bool loaded = await service.EnsureModelLoadedAsync();
            Print($"Model '{service.ActiveModel?.Id}': {service.State} in {stopwatch.ElapsedMilliseconds} ms {service.LastError}");
            if (!loaded)
            {
                return 2;
            }

            if (useGpu)
            {
                // The model starts on the processor and moves to the video card in the background.
                while (!service.IsRunningOnGpu && service.IsGpuRuntimeAvailable && stopwatch.Elapsed < TimeSpan.FromSeconds(90))
                {
                    await Task.Delay(100);
                }
            }
            Print($"Running on: {(service.IsRunningOnGpu ? $"GPU {service.GpuName} via {service.GpuBackend}" : "CPU")} after {stopwatch.ElapsedMilliseconds} ms " +
                  $"(GPU runtime available: {service.IsGpuRuntimeAvailable})");

            float[] samples = wavPath != null ? ReadWav(wavPath) : Array.Empty<float>();
            if (samples.Length == 0)
            {
                Print("No (valid) .wav given — model load check only.");
                return 0;
            }

            stopwatch.Restart();
            string? preview = await service.TryTranscribePreviewAsync(samples);
            Print($"Preview ({stopwatch.ElapsedMilliseconds} ms): {preview}");

            stopwatch.Restart();
            string text = await service.TranscribeAsync(samples);
            Print($"Final ({stopwatch.ElapsedMilliseconds} ms, {samples.Length / 16000.0:F1} s audio): {text}");
            return string.IsNullOrWhiteSpace(text) ? 3 : 0;
        }

        private static string? Option(string[] args, string name)
        {
            int index = Array.IndexOf(args, name);
            return index >= 0 && index + 1 < args.Length ? args[index + 1] : null;
        }

        private static float[] ReadWav(string path)
        {
            try
            {
                using var reader = new WaveFileReader(path);
                if (reader.WaveFormat.SampleRate != 16000 || reader.WaveFormat.Channels != 1 || reader.WaveFormat.BitsPerSample != 16)
                {
                    Print($"Expected 16 kHz mono 16-bit PCM, got {reader.WaveFormat}.");
                    return Array.Empty<float>();
                }

                var bytes = new byte[reader.Length];
                int read = reader.Read(bytes, 0, bytes.Length);
                var samples = new float[read / 2];
                for (int i = 0; i < samples.Length; i++)
                {
                    samples[i] = BitConverter.ToInt16(bytes, i * 2) / 32768f;
                }
                return samples;
            }
            catch (Exception ex)
            {
                Print($"Could not read '{path}': {ex.Message}");
                return Array.Empty<float>();
            }
        }

        private static void Print(string message)
        {
            Console.WriteLine(message);
            Log.Info("[SelfTest] " + message);
        }
    }
}
