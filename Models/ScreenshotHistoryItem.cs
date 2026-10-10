using System;
using System.Text.Json.Serialization;

namespace ScreenVoicer.Models
{
    public class ScreenshotHistoryItem
    {
        public string Id { get; set; } = Guid.NewGuid().ToString("N");
        public string ImagePath { get; set; } = string.Empty;
        public string TranscribedText { get; set; } = string.Empty;
        public DateTime CreatedAt { get; set; } = DateTime.Now;
        public int Width { get; set; }
        public int Height { get; set; }
        public long FileSizeBytes { get; set; }

        /// <summary>Public link to this screenshot (shared alone or together with others), if any.</summary>
        public string? ShareId { get; set; }
        public string? ShareUrl { get; set; }
        public string? ShareDeleteToken { get; set; }
        public DateTime? ShareExpiresAt { get; set; }

        [JsonIgnore]
        public bool HasActiveShare => ShareUrl != null && ShareExpiresAt > DateTime.Now;

        [JsonIgnore]
        public string DisplayDate => CreatedAt.ToString("dd.MM.yyyy HH:mm");

        [JsonIgnore]
        public bool HasVoiceComment => !string.IsNullOrWhiteSpace(TranscribedText);

        [JsonIgnore]
        public string HasCommentText => HasVoiceComment ? TranscribedText : "Без коментаря";
    }
}
