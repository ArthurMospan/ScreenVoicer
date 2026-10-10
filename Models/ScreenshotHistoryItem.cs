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

        [JsonIgnore]
        public string DisplayDate => CreatedAt.ToString("dd.MM.yyyy HH:mm");

        [JsonIgnore]
        public bool HasVoiceComment => !string.IsNullOrWhiteSpace(TranscribedText);

        [JsonIgnore]
        public string HasCommentText => HasVoiceComment ? TranscribedText : "Без коментаря";
    }
}
