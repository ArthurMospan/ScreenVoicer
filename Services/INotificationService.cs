using System;

namespace ScreenVoicer.Services
{
    public enum ToastKind
    {
        Info,
        Success,
        Warning,
        Error
    }

    public sealed record ToastOptions
    {
        public string Title { get; init; } = "ScreenVoicer";
        public string Message { get; init; } = string.Empty;
        public ToastKind Kind { get; init; } = ToastKind.Info;

        /// <summary>Screenshot to show as a thumbnail; enables the open/copy/gallery buttons.</summary>
        public string? ImagePath { get; init; }

        /// <summary>Text the "copy" button puts on the clipboard again.</summary>
        public string? CopyText { get; init; }

        public Action? OnOpenGallery { get; init; }

        /// <summary>Optional extra button (e.g. "Повторити").</summary>
        public string? ActionText { get; init; }
        public Action? OnAction { get; init; }

        public int DurationMs { get; init; } = 4500;
    }

    public interface INotificationService
    {
        void Show(ToastOptions options);

        void ShowToast(string title, string message, ToastKind kind = ToastKind.Info, int durationMs = 4500);

        /// <summary>
        /// Instantly closes all toasts (used before taking a screenshot so they don't end up in it).
        /// Returns true if anything was on screen.
        /// </summary>
        bool HideAll();
    }
}
