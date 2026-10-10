using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using ScreenVoicer.Models;

namespace ScreenVoicer.Services
{
    public interface IHistoryService
    {
        /// <summary>Raised (on any thread) after an entry was added or removed.</summary>
        event EventHandler? Changed;

        /// <summary>Snapshot of the history, newest first. Safe to keep and enumerate.</summary>
        Task<IReadOnlyList<ScreenshotHistoryItem>> GetHistoryAsync();

        Task AddEntryAsync(ScreenshotHistoryItem item);

        /// <summary>Removes the entry and deletes its image file.</summary>
        Task<bool> DeleteEntryAsync(string id);

        /// <summary>Number of entries if the history is already loaded, otherwise null (never blocks).</summary>
        int? CachedCount { get; }
    }
}
