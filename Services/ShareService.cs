using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using ScreenVoicer.Models;

namespace ScreenVoicer.Services
{
    public sealed record ShareResult(string Id, string Url, string DeleteToken, DateTime ExpiresAt);

    /// <summary>
    /// Public links to screenshots through the ScreenVoicer Cloudflare Worker (share-worker/): one or several
    /// screenshots with their comments behind one unguessable link that expires by itself after 30 days.
    /// Nothing is uploaded unless the user asks for a link.
    /// </summary>
    public static class ShareService
    {
        /// <summary>Production endpoint; SV_SHARE_ENDPOINT points the app at another one (local wrangler dev).</summary>
        private const string DefaultEndpoint = "https://screenvoicer.masspain.workers.dev";

        public const int MaxImages = 10;
        private const long MaxImageBytes = 8L * 1024 * 1024;

        public static string Endpoint =>
            (Environment.GetEnvironmentVariable("SV_SHARE_ENDPOINT") is { Length: > 0 } custom ? custom : DefaultEndpoint).TrimEnd('/');

        public static async Task<ShareResult> CreateAsync(IReadOnlyList<ScreenshotHistoryItem> items, CancellationToken cancellationToken = default)
        {
            if (items.Count == 0)
            {
                throw new ArgumentException("Nothing to share.", nameof(items));
            }
            if (items.Count > MaxImages)
            {
                throw new InvalidOperationException($"За одним посиланням можна поділитися щонайбільше {MaxImages} знімками.");
            }

            using var form = new MultipartFormDataContent();
            var meta = new
            {
                app = $"ScreenVoicer {UpdateService.CurrentVersion}",
                items = items.Select(i => new
                {
                    comment = i.TranscribedText,
                    width = i.Width,
                    height = i.Height,
                    createdAt = i.CreatedAt.ToString("O")
                })
            };
            // Field names in quotes: .NET writes name=meta, and the Workers form parser rejects unquoted names.
            var metaPart = new StringContent(JsonSerializer.Serialize(meta), Encoding.UTF8, "application/json");
            metaPart.Headers.ContentDisposition = new ContentDispositionHeaderValue("form-data") { Name = "\"meta\"" };
            form.Add(metaPart);

            foreach (var item in items)
            {
                var info = new FileInfo(item.ImagePath);
                if (!info.Exists)
                {
                    throw new FileNotFoundException("Файл знімка не знайдено — можливо, його видалили.", item.ImagePath);
                }
                if (info.Length > MaxImageBytes)
                {
                    throw new InvalidOperationException($"Знімок «{info.Name}» завеликий для посилання ({info.Length / 1048576.0:F1} МБ, максимум 8 МБ).");
                }

                var image = new ByteArrayContent(await File.ReadAllBytesAsync(item.ImagePath, cancellationToken).ConfigureAwait(false));
                image.Headers.ContentType = new MediaTypeHeaderValue("image/png");
                image.Headers.ContentDisposition = new ContentDispositionHeaderValue("form-data") { Name = "\"image\"", FileName = $"\"{info.Name}\"" };
                form.Add(image);
            }

            using var http = CreateClient();
            using var response = await http.PostAsync($"{Endpoint}/api/shares", form, cancellationToken).ConfigureAwait(false);
            string body = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode)
            {
                throw new HttpRequestException($"Сервер посилань відповів {(int)response.StatusCode}: {Describe(body)}");
            }

            using var document = JsonDocument.Parse(body);
            var root = document.RootElement;
            var result = new ShareResult(
                root.GetProperty("id").GetString()!,
                root.GetProperty("url").GetString()!,
                root.GetProperty("deleteToken").GetString()!,
                root.GetProperty("expiresAt").GetDateTime().ToLocalTime());
            Log.Info($"[Share] {items.Count} screenshot(s) → {result.Url} (until {result.ExpiresAt:d}).");
            return result;
        }

        public static async Task DeleteAsync(string id, string deleteToken, CancellationToken cancellationToken = default)
        {
            using var http = CreateClient();
            using var request = new HttpRequestMessage(HttpMethod.Delete, $"{Endpoint}/api/shares/{id}");
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", deleteToken);
            using var response = await http.SendAsync(request, cancellationToken).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode)
            {
                string body = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
                throw new HttpRequestException($"Не вдалося видалити посилання ({(int)response.StatusCode}: {Describe(body)}).");
            }
            Log.Info($"[Share] {id} deleted.");
        }

        private static string Describe(string body) => body.Contains("image_too_large") ? "знімок завеликий"
            : body.Contains("image_count") ? "забагато знімків"
            : body.Contains("not_an_image") ? "файл не схожий на зображення"
            : body.Length > 120 ? body[..120] : body;

        private static HttpClient CreateClient()
        {
            var http = new HttpClient { Timeout = TimeSpan.FromMinutes(3) };
            http.DefaultRequestHeaders.UserAgent.ParseAdd($"ScreenVoicer/{UpdateService.CurrentVersion}");
            return http;
        }
    }
}
