using System;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net.Http;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;

namespace ScreenVoicer.Services
{
    /// <summary>
    /// Optional NVIDIA CUDA backend for Whisper, downloaded on request (~590 MB, ~1 GB on disk).
    /// On a GTX 1650 it runs large-v3 in 3.5 s instead of 7.5–8.5 s through Vulkan, so the most accurate model
    /// becomes usable. Nothing is bundled with the app: the Whisper.net CUDA build comes from NuGet and the CUDA
    /// runtime / cuBLAS (NVIDIA redistributables) from NVIDIA's official PyPI wheels; every file is checked
    /// against a pinned SHA-256.
    /// </summary>
    public static class CudaPack
    {
        /// <summary>Must match the Whisper.net package the app is built with (whisper.dll ABI).</summary>
        private const string Version = "whisper.net-1.7.4+cuda-12.6";

        private sealed record Part(string Name, string Url, string Sha256, long Size, string[] Entries);

        private static readonly Part[] Parts =
        {
            new("whisper.net.runtime.cuda.windows.1.7.4.nupkg",
                "https://api.nuget.org/v3-flatcontainer/whisper.net.runtime.cuda.windows/1.7.4/whisper.net.runtime.cuda.windows.1.7.4.nupkg",
                "c6bff32c9adf4d075e0615da42600b9b4801dd39042370aed785f400a54b6e12", 151054806,
                new[]
                {
                    "build/win-x64/whisper.dll", "build/win-x64/ggml-whisper.dll", "build/win-x64/ggml-base-whisper.dll",
                    "build/win-x64/ggml-cpu-whisper.dll", "build/win-x64/ggml-cuda-whisper.dll"
                }),
            new("nvidia_cublas_cu12-12.6.4.1-py3-none-win_amd64.whl",
                "https://files.pythonhosted.org/packages/84/f7/985e9bdbe3e0ac9298fcc8cfa51a392862a46a0ffaccbbd56939b62a9c83/nvidia_cublas_cu12-12.6.4.1-py3-none-win_amd64.whl",
                "9e4fa264f4d8a4eb0cdbd34beadc029f453b3bafae02401e999cf3d5a5af75f8", 434535301,
                new[] { "nvidia/cublas/bin/cublas64_12.dll", "nvidia/cublas/bin/cublasLt64_12.dll" }),
            new("nvidia_cuda_runtime_cu12-12.6.77-py3-none-win_amd64.whl",
                "https://files.pythonhosted.org/packages/fa/76/4c80fa138333cc975743fd0687a745fccb30d167f906f13c1c7f9a85e5ea/nvidia_cuda_runtime_cu12-12.6.77-py3-none-win_amd64.whl",
                "86c58044c824bf3c173c49a2dbc7a6c8b53cb4e4dca50068be0bf64e9dab3f7f", 891773,
                new[] { "nvidia/cuda_runtime/bin/cudart64_12.dll" })
        };

        private static readonly TimeSpan StallTimeout = TimeSpan.FromSeconds(30);

        public static string BaseDirectory { get; } =
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ScreenVoicer", "cuda");

        /// <summary>Whisper.net looks for the CUDA build in &lt;base&gt;\runtimes\cuda\win-x64.</summary>
        public static string RuntimeDirectory => Path.Combine(BaseDirectory, "runtimes", "cuda", "win-x64");

        private static string MarkerPath => Path.Combine(BaseDirectory, "installed.txt");

        public static long DownloadBytes => Parts.Sum(p => p.Size);

        public static int DownloadMegabytes => (int)(DownloadBytes / 1048576);

        /// <summary>The NVIDIA driver (which provides nvcuda.dll) is installed.</summary>
        public static bool HasNvidiaDriver =>
            File.Exists(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "nvcuda.dll"));

        public static bool IsInstalled
        {
            get
            {
                try
                {
                    return File.Exists(MarkerPath) &&
                           File.ReadAllText(MarkerPath).Trim() == Version &&
                           Parts.SelectMany(p => p.Entries).All(e => File.Exists(Path.Combine(RuntimeDirectory, Path.GetFileName(e))));
                }
                catch
                {
                    return false;
                }
            }
        }

        /// <summary>Downloads, verifies and unpacks the pack. Takes effect after a restart of the app.</summary>
        public static async Task InstallAsync(IProgress<double>? progress, CancellationToken cancellationToken)
        {
            Directory.CreateDirectory(BaseDirectory);
            string downloads = Path.Combine(BaseDirectory, "downloads");
            string staging = Path.Combine(BaseDirectory, "staging");
            Directory.CreateDirectory(downloads);
            if (Directory.Exists(staging))
            {
                Directory.Delete(staging, recursive: true);
            }
            Directory.CreateDirectory(staging);

            using var http = new HttpClient { Timeout = Timeout.InfiniteTimeSpan };
            http.DefaultRequestHeaders.UserAgent.ParseAdd("ScreenVoicer/1.6");

            long total = DownloadBytes, done = 0;
            foreach (var part in Parts)
            {
                string archive = Path.Combine(downloads, part.Name);
                if (!(File.Exists(archive) && new FileInfo(archive).Length == part.Size && HashMatches(archive, part.Sha256)))
                {
                    long before = done;
                    await DownloadAsync(http, part, archive,
                        received => progress?.Report(0.97 * (before + received) / total), cancellationToken).ConfigureAwait(false);
                }
                done += part.Size;
                progress?.Report(0.97 * done / total);

                using (var zip = ZipFile.OpenRead(archive))
                {
                    foreach (string entryName in part.Entries)
                    {
                        var entry = zip.GetEntry(entryName) ?? throw new InvalidDataException($"«{entryName}» немає в {part.Name}.");
                        entry.ExtractToFile(Path.Combine(staging, Path.GetFileName(entryName)), overwrite: true);
                    }
                }
                File.Delete(archive);
                Log.Info($"[CUDA] {part.Name}: verified and unpacked.");
            }

            // Replace the previous copy only now, so a failed or cancelled download never breaks a working pack.
            TryDeleteMarker();
            if (Directory.Exists(RuntimeDirectory))
            {
                Directory.Delete(RuntimeDirectory, recursive: true);
            }
            Directory.CreateDirectory(Path.GetDirectoryName(RuntimeDirectory)!);
            Directory.Move(staging, RuntimeDirectory);
            TryDeleteDirectory(downloads);
            File.WriteAllText(MarkerPath, Version);
            progress?.Report(1);
            Log.Info($"[CUDA] Pack installed to '{RuntimeDirectory}'.");
        }

        private static async Task DownloadAsync(HttpClient http, Part part, string path, Action<long> onProgress, CancellationToken cancellationToken)
        {
            Log.Info($"[CUDA] Downloading {part.Name} ({part.Size / 1048576} MB).");
            string partial = path + ".part";
            using var stall = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            stall.CancelAfter(StallTimeout);

            using var response = await http.GetAsync(part.Url, HttpCompletionOption.ResponseHeadersRead, stall.Token).ConfigureAwait(false);
            response.EnsureSuccessStatusCode();

            using var sha = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            long received = 0;
            await using (var source = await response.Content.ReadAsStreamAsync(stall.Token).ConfigureAwait(false))
            await using (var target = new FileStream(partial, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 16, useAsync: true))
            {
                var buffer = new byte[1 << 16];
                while (true)
                {
                    stall.CancelAfter(StallTimeout);
                    int read;
                    try
                    {
                        read = await source.ReadAsync(buffer, stall.Token).ConfigureAwait(false);
                    }
                    catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
                    {
                        throw new IOException("З'єднання зависло під час завантаження.");
                    }
                    if (read == 0)
                    {
                        break;
                    }

                    sha.AppendData(buffer, 0, read);
                    await target.WriteAsync(buffer.AsMemory(0, read), cancellationToken).ConfigureAwait(false);
                    received += read;
                    onProgress(received);
                }
            }

            string hash = Convert.ToHexString(sha.GetHashAndReset()).ToLowerInvariant();
            if (received != part.Size || hash != part.Sha256)
            {
                File.Delete(partial);
                throw new IOException($"Файл {part.Name} пошкоджений (завантажено {received / 1048576} МБ, контрольна сума не збігається).");
            }
            File.Move(partial, path, overwrite: true);
        }

        private static bool HashMatches(string path, string sha256)
        {
            using var stream = File.OpenRead(path);
            return Convert.ToHexString(SHA256.HashData(stream)).Equals(sha256, StringComparison.OrdinalIgnoreCase);
        }

        /// <summary>
        /// Whisper.net takes a single base folder and tries the runtimes in order, so the CPU and Vulkan builds
        /// that ship inside the app are mirrored next to the CUDA one; if CUDA can't start, those still work.
        /// Also puts the CUDA folder on PATH so cudart/cuBLAS resolve. Returns false if anything is missing.
        /// </summary>
        internal static bool PrepareRuntimeFolder(string appRuntimesBase)
        {
            if (!IsInstalled || !HasNvidiaDriver)
            {
                return false;
            }

            try
            {
                foreach (string runtime in new[] { @"vulkan\win-x64", "win-x64", @"noavx\win-x64" })
                {
                    string from = Path.Combine(appRuntimesBase, "runtimes", runtime);
                    if (!Directory.Exists(from))
                    {
                        continue;
                    }
                    string to = Path.Combine(BaseDirectory, "runtimes", runtime);
                    Directory.CreateDirectory(to);
                    foreach (string file in Directory.GetFiles(from))
                    {
                        string target = Path.Combine(to, Path.GetFileName(file));
                        var source = new FileInfo(file);
                        var existing = new FileInfo(target);
                        if (!existing.Exists || existing.Length != source.Length || existing.LastWriteTimeUtc != source.LastWriteTimeUtc)
                        {
                            File.Copy(file, target, overwrite: true);
                            File.SetLastWriteTimeUtc(target, source.LastWriteTimeUtc);
                        }
                    }
                }

                string path = Environment.GetEnvironmentVariable("PATH") ?? string.Empty;
                if (!path.Split(';').Contains(RuntimeDirectory, StringComparer.OrdinalIgnoreCase))
                {
                    Environment.SetEnvironmentVariable("PATH", RuntimeDirectory + ";" + path);
                }
                return true;
            }
            catch (Exception ex)
            {
                // E.g. another running copy holds the mirrored DLLs: just use the built-in runtimes this time.
                Log.Warn("[CUDA] Could not prepare the runtime folder, using Vulkan/CPU", ex);
                return false;
            }
        }

        private static void TryDeleteMarker()
        {
            try
            {
                File.Delete(MarkerPath);
            }
            catch
            {
                // not there
            }
        }

        private static void TryDeleteDirectory(string path)
        {
            try
            {
                Directory.Delete(path, recursive: true);
            }
            catch
            {
                // leftovers are harmless
            }
        }
    }
}
