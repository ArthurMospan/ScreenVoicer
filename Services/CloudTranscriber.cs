using System;
using System.IO;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace ScreenVoicer.Services
{
    /// <summary>
    /// Voice comments recognized online through the ScreenVoicer server (share-worker/, POST /api/transcribe): accurate
    /// and fast on any computer, the language detected by itself. Returns null when it can't (no internet, the server's
    /// daily allowance used up, a timeout) and the caller recognizes on the computer instead. Same request as the Mac app.
    /// </summary>
    public static class CloudTranscriber
    {
        private static readonly HttpClient Http = CreateClient();

        public static async Task<string?> TranscribeAsync(float[] samples, CancellationToken cancellationToken = default)
        {
            try
            {
                string audio = Convert.ToBase64String(ToWav(AudioAnalysis.NormalizeLevel(samples)));
                using var content = new StringContent(JsonSerializer.Serialize(new { audio }), Encoding.UTF8, "application/json");
                using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                double seconds = samples.Length / (double)AudioAnalysis.SampleRate;
                timeout.CancelAfter(TimeSpan.FromSeconds(Math.Clamp(8 + seconds / 2, 8, 40)));

                var started = DateTime.UtcNow;
                using var response = await Http.PostAsync($"{ShareService.Endpoint}/api/transcribe", content, timeout.Token).ConfigureAwait(false);
                string body = await response.Content.ReadAsStringAsync(timeout.Token).ConfigureAwait(false);
                if (!response.IsSuccessStatusCode)
                {
                    Log.Warn($"[Cloud] Recognition refused ({(int)response.StatusCode}): {(body.Length > 160 ? body[..160] : body)}");
                    return null;
                }

                using var document = JsonDocument.Parse(body);
                string text = document.RootElement.TryGetProperty("text", out var t) ? t.GetString() ?? string.Empty : string.Empty;
                string language = document.RootElement.TryGetProperty("language", out var l) ? l.GetString() ?? "" : "";
                Log.Info($"[Cloud] {seconds:0.0} s → {(DateTime.UtcNow - started).TotalMilliseconds:0} ms, lang={language}: \"{text}\"");
                return TranscriptCleaner.Clean(text);
            }
            catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or OperationCanceledException or JsonException or IOException)
            {
                Log.Warn($"[Cloud] Recognition unavailable, using the computer: {ex.GetType().Name}: {ex.Message}");
                return null;
            }
        }

        /// <summary>16 kHz mono 16-bit PCM WAV, the format the recognizer expects.</summary>
        private static byte[] ToWav(float[] samples)
        {
            int rate = AudioAnalysis.SampleRate, payload = samples.Length * 2;
            using var stream = new MemoryStream(44 + payload);
            using var writer = new BinaryWriter(stream);
            writer.Write(Encoding.ASCII.GetBytes("RIFF"));
            writer.Write(36 + payload);
            writer.Write(Encoding.ASCII.GetBytes("WAVE"));
            writer.Write(Encoding.ASCII.GetBytes("fmt "));
            writer.Write(16);
            writer.Write((short)1);
            writer.Write((short)1);
            writer.Write(rate);
            writer.Write(rate * 2);
            writer.Write((short)2);
            writer.Write((short)16);
            writer.Write(Encoding.ASCII.GetBytes("data"));
            writer.Write(payload);
            foreach (float sample in samples)
            {
                writer.Write((short)Math.Round(Math.Clamp(sample, -1f, 1f) * 32767));
            }
            writer.Flush();
            return stream.ToArray();
        }

        private static HttpClient CreateClient()
        {
            var http = new HttpClient { Timeout = TimeSpan.FromSeconds(60) };
            http.DefaultRequestHeaders.UserAgent.ParseAdd($"ScreenVoicer/{UpdateService.CurrentVersion}");
            return http;
        }
    }
}
