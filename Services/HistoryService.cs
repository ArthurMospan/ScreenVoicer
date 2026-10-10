using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using ScreenVoicer.Models;

namespace ScreenVoicer.Services
{
    public sealed class HistoryService : IHistoryService
    {
        private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };

        private readonly string _historyFilePath;
        private readonly ISettingsService _settingsService;
        private readonly SemaphoreSlim _lock = new(1, 1);
        private List<ScreenshotHistoryItem>? _items;

        public int? CachedCount => _items?.Count;

        public HistoryService(ISettingsService settingsService, string? dataDirectory = null)
        {
            _settingsService = settingsService;
            string folder = dataDirectory ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "ScreenVoicer");
            Directory.CreateDirectory(folder);
            _historyFilePath = Path.Combine(folder, "history.json");
        }

        public event EventHandler? Changed;

        public async Task<IReadOnlyList<ScreenshotHistoryItem>> GetHistoryAsync()
        {
            await _lock.WaitAsync().ConfigureAwait(false);
            try
            {
                var items = await EnsureLoadedAsync().ConfigureAwait(false);
                int before = items.Count;
                items.RemoveAll(x => !File.Exists(x.ImagePath));
                if (items.Count != before)
                {
                    await SaveInternalAsync(items).ConfigureAwait(false);
                }

                // Hand out a copy: the gallery binds to it while new screenshots are being added.
                return items.ToList();
            }
            finally
            {
                _lock.Release();
            }
        }

        public async Task AddEntryAsync(ScreenshotHistoryItem item)
        {
            await _lock.WaitAsync().ConfigureAwait(false);
            try
            {
                // Must load first: saving an unloaded (empty) list used to overwrite the whole history file.
                var items = await EnsureLoadedAsync().ConfigureAwait(false);
                items.RemoveAll(x => string.Equals(x.ImagePath, item.ImagePath, StringComparison.OrdinalIgnoreCase));
                int index = items.FindIndex(x => x.CreatedAt <= item.CreatedAt);
                items.Insert(index < 0 ? items.Count : index, item); // keep newest-first order
                await SaveInternalAsync(items).ConfigureAwait(false);
            }
            finally
            {
                _lock.Release();
            }

            Changed?.Invoke(this, EventArgs.Empty);
        }

        public async Task SetShareAsync(IEnumerable<string> ids, ShareResult? share)
        {
            var wanted = ids.ToHashSet();
            await _lock.WaitAsync().ConfigureAwait(false);
            try
            {
                var items = await EnsureLoadedAsync().ConfigureAwait(false);
                foreach (var item in items.Where(x => wanted.Contains(x.Id)))
                {
                    item.ShareId = share?.Id;
                    item.ShareUrl = share?.Url;
                    item.ShareDeleteToken = share?.DeleteToken;
                    item.ShareExpiresAt = share?.ExpiresAt;
                }
                await SaveInternalAsync(items).ConfigureAwait(false);
            }
            finally
            {
                _lock.Release();
            }

            Changed?.Invoke(this, EventArgs.Empty);
        }

        public async Task<bool> DeleteEntryAsync(string id)
        {
            bool removed = false;
            await _lock.WaitAsync().ConfigureAwait(false);
            try
            {
                var items = await EnsureLoadedAsync().ConfigureAwait(false);
                var item = items.FirstOrDefault(x => x.Id == id);
                if (item != null)
                {
                    if (File.Exists(item.ImagePath))
                    {
                        // Throws when the file can't be removed, so the entry stays consistent with the disk
                        // (otherwise it would silently reappear as an "unindexed" file on the next start).
                        File.Delete(item.ImagePath);
                    }

                    items.Remove(item);
                    await SaveInternalAsync(items).ConfigureAwait(false);
                    removed = true;
                }
            }
            finally
            {
                _lock.Release();
            }

            if (removed)
            {
                Changed?.Invoke(this, EventArgs.Empty);
            }
            return removed;
        }

        private async Task<List<ScreenshotHistoryItem>> EnsureLoadedAsync()
        {
            if (_items != null)
            {
                return _items;
            }

            var items = new List<ScreenshotHistoryItem>();
            if (File.Exists(_historyFilePath))
            {
                try
                {
                    string json = await File.ReadAllTextAsync(_historyFilePath).ConfigureAwait(false);
                    items = JsonSerializer.Deserialize<List<ScreenshotHistoryItem>>(json) ?? new List<ScreenshotHistoryItem>();
                }
                catch (Exception ex)
                {
                    // Keep the damaged file for manual recovery instead of overwriting the user's comments.
                    string backup = Path.Combine(Path.GetDirectoryName(_historyFilePath)!, $"history.corrupt-{DateTime.Now:yyyyMMdd_HHmmss}.json");
                    Log.Error($"[History] history.json is unreadable, moved to '{backup}'", ex);
                    try { File.Move(_historyFilePath, backup, overwrite: true); } catch { }
                }
            }

            bool changed = ImportUnindexedScreenshots(items);
            items.RemoveAll(x => string.IsNullOrWhiteSpace(x.ImagePath) || !File.Exists(x.ImagePath));
            items.Sort((a, b) => b.CreatedAt.CompareTo(a.CreatedAt));
            _items = items;

            if (changed)
            {
                await SaveInternalAsync(items).ConfigureAwait(false);
            }
            return items;
        }

        /// <summary>Screenshots that exist in the output folder but are missing from history.json (e.g. older versions).</summary>
        private bool ImportUnindexedScreenshots(List<ScreenshotHistoryItem> items)
        {
            string outputDir = _settingsService.OutputDirectory;
            if (!Directory.Exists(outputDir))
            {
                return false;
            }

            var known = new HashSet<string>(items.Select(x => x.ImagePath), StringComparer.OrdinalIgnoreCase);
            bool changed = false;
            try
            {
                foreach (string file in Directory.EnumerateFiles(outputDir, "screenshot_*.png"))
                {
                    if (known.Contains(file))
                    {
                        continue;
                    }

                    var info = new FileInfo(file);
                    items.Add(new ScreenshotHistoryItem
                    {
                        ImagePath = file,
                        CreatedAt = info.CreationTime,
                        FileSizeBytes = info.Length
                    });
                    changed = true;
                }
            }
            catch (Exception ex)
            {
                Log.Warn("[History] Could not scan the screenshots folder", ex);
            }
            return changed;
        }

        private async Task SaveInternalAsync(List<ScreenshotHistoryItem> items)
        {
            try
            {
                string tempPath = _historyFilePath + ".tmp";
                await File.WriteAllTextAsync(tempPath, JsonSerializer.Serialize(items, JsonOptions)).ConfigureAwait(false);
                File.Move(tempPath, _historyFilePath, overwrite: true);
            }
            catch (Exception ex)
            {
                Log.Error("[History] Could not save history.json", ex);
            }
        }
    }
}
