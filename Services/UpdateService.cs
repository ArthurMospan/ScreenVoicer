using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace ScreenVoicer.Services
{
    /// <param name="Notes">Release notes (Markdown) shown in the update toast and the tray menu.</param>
    /// <param name="Sha256">Checksum GitHub publishes for the asset, when present.</param>
    public sealed record UpdateInfo(Version Version, string Notes, string InstallerUrl, long Size, string? Sha256, string PageUrl);

    /// <summary>
    /// Updates from GitHub Releases: the latest release's «ScreenVoicer-Setup.exe» is downloaded, checked and run
    /// silently; the installer (per-user, no admin prompt) replaces the exe and starts the app again.
    /// </summary>
    public static class UpdateService
    {
        public const string Repository = "ArthurMospan/ScreenVoicer";
        public const string InstallerAssetName = "ScreenVoicer-Setup.exe";
        private const string LatestReleaseApi = "https://api.github.com/repos/" + Repository + "/releases/latest";

        public static string ReleasesPage => "https://github.com/" + Repository + "/releases";

        /// <summary>The running version; SV_VERSION_OVERRIDE pretends to be older (for testing the update path).</summary>
        public static Version CurrentVersion
        {
            get
            {
                string? fake = Environment.GetEnvironmentVariable("SV_VERSION_OVERRIDE");
                if (!string.IsNullOrWhiteSpace(fake) && Version.TryParse(fake, out var forced))
                {
                    return forced;
                }
                var version = typeof(UpdateService).Assembly.GetName().Version ?? new Version(0, 0);
                return new Version(version.Major, version.Minor, Math.Max(0, version.Build));
            }
        }

        private static string DownloadDirectory =>
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ScreenVoicer", "updates");

        /// <summary>The newer release, or null when this is the latest (or GitHub can't be reached).</summary>
        public static async Task<UpdateInfo?> CheckAsync(CancellationToken cancellationToken = default)
        {
            using var http = CreateClient();
            http.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
            using var response = await http.GetAsync(LatestReleaseApi, cancellationToken).ConfigureAwait(false);
            if (response.StatusCode == System.Net.HttpStatusCode.NotFound)
            {
                return null; // no release published yet
            }
            response.EnsureSuccessStatusCode();
            string json = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
            return ParseLatestRelease(json, CurrentVersion);
        }

        /// <summary>Reads GitHub's «latest release» JSON; null unless it is newer and has the installer.</summary>
        public static UpdateInfo? ParseLatestRelease(string json, Version current)
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            if (root.TryGetProperty("draft", out var draft) && draft.GetBoolean() ||
                root.TryGetProperty("prerelease", out var pre) && pre.GetBoolean())
            {
                return null;
            }

            string tag = root.GetProperty("tag_name").GetString() ?? string.Empty;
            if (!Version.TryParse(tag.TrimStart('v', 'V'), out var version) || version <= current)
            {
                return null;
            }

            foreach (var asset in root.GetProperty("assets").EnumerateArray())
            {
                if (!string.Equals(asset.GetProperty("name").GetString(), InstallerAssetName, StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                string? sha = asset.TryGetProperty("digest", out var digest) && digest.ValueKind == JsonValueKind.String &&
                              digest.GetString()!.StartsWith("sha256:", StringComparison.OrdinalIgnoreCase)
                    ? digest.GetString()![7..].ToLowerInvariant()
                    : null;
                return new UpdateInfo(
                    version,
                    root.TryGetProperty("body", out var body) ? body.GetString() ?? string.Empty : string.Empty,
                    asset.GetProperty("browser_download_url").GetString()!,
                    asset.GetProperty("size").GetInt64(),
                    sha,
                    root.TryGetProperty("html_url", out var page) ? page.GetString() ?? ReleasesPage : ReleasesPage);
            }
            return null;
        }

        /// <summary>Downloads the installer next to the app data and verifies its size and checksum.</summary>
        public static async Task<string> DownloadAsync(UpdateInfo update, IProgress<double>? progress, CancellationToken cancellationToken = default)
        {
            Directory.CreateDirectory(DownloadDirectory);
            foreach (string old in Directory.GetFiles(DownloadDirectory))
            {
                TryDelete(old);
            }

            string path = Path.Combine(DownloadDirectory, $"ScreenVoicer-Setup-{update.Version}.exe");
            string partial = path + ".part";
            using var http = CreateClient();
            using var response = await http.GetAsync(update.InstallerUrl, HttpCompletionOption.ResponseHeadersRead, cancellationToken).ConfigureAwait(false);
            response.EnsureSuccessStatusCode();

            using var sha = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            long received = 0;
            await using (var source = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false))
            await using (var target = new FileStream(partial, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 16, useAsync: true))
            {
                var buffer = new byte[1 << 16];
                int read;
                while ((read = await source.ReadAsync(buffer, cancellationToken).ConfigureAwait(false)) > 0)
                {
                    sha.AppendData(buffer, 0, read);
                    await target.WriteAsync(buffer.AsMemory(0, read), cancellationToken).ConfigureAwait(false);
                    received += read;
                    if (update.Size > 0)
                    {
                        progress?.Report((double)received / update.Size);
                    }
                }
            }

            string hash = Convert.ToHexString(sha.GetHashAndReset()).ToLowerInvariant();
            if ((update.Size > 0 && received != update.Size) || (update.Sha256 != null && hash != update.Sha256))
            {
                TryDelete(partial);
                throw new IOException("Оновлення завантажилося пошкодженим. Спробуйте ще раз.");
            }

            File.Move(partial, path, overwrite: true);
            Log.Info($"[Update] {update.Version} downloaded ({received / 1048576.0:F1} MB, sha256 {hash[..12]}…).");
            return path;
        }

        /// <summary>
        /// Starts the installer a couple of seconds later, once this process has exited and released the
        /// single-instance mutex the installer waits on. The installer shows only its progress bar and starts the
        /// app again when done.
        /// </summary>
        public static void LaunchInstallerAfterExit(string installerPath)
        {
            string arguments = "/SILENT /SUPPRESSMSGBOXES /NORESTART /SP- /CLOSEAPPLICATIONS";
            var start = new ProcessStartInfo
            {
                FileName = "cmd.exe",
                Arguments = $"/c ping -n 3 127.0.0.1 >nul & start \"\" \"{installerPath}\" {arguments}",
                CreateNoWindow = true,
                UseShellExecute = false,
                WindowStyle = ProcessWindowStyle.Hidden
            };
            // The installer starts the new app with this environment: a test override must not follow it there.
            start.Environment.Remove("SV_VERSION_OVERRIDE");
            Process.Start(start);
            Log.Info($"[Update] Installer scheduled: {installerPath}");
        }

        /// <summary>First lines of the release notes, without Markdown markers, for a toast.</summary>
        public static string Summary(string notes, int maxLength = 160)
        {
            var lines = notes.Split('\n')
                .Select(l => l.Trim().TrimStart('#', '-', '*', ' ').Trim())
                .Where(l => l.Length > 0)
                .Take(3);
            string text = string.Join(" · ", lines);
            return text.Length > maxLength ? text[..(maxLength - 1)] + "…" : text;
        }

        private static HttpClient CreateClient()
        {
            var http = new HttpClient { Timeout = TimeSpan.FromMinutes(10) };
            http.DefaultRequestHeaders.UserAgent.ParseAdd($"ScreenVoicer/{CurrentVersion}");
            return http;
        }

        private static void TryDelete(string path)
        {
            try
            {
                File.Delete(path);
            }
            catch
            {
                // still in use: harmless leftover
            }
        }
    }
}
