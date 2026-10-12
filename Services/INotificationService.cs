using System;
using System.Collections.Generic;

namespace ScreenVoicer.Services
{
    /// <summary>A toast button that copies something and keeps the toast open, showing «✓» on itself.</summary>
    public sealed record ToastCopyButton(string Text, Func<bool> Copy);

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

        /// <summary>Copy buttons before the action button (the saved-screenshot toast: «З підписом», «Текст»).</summary>
        public IReadOnlyList<ToastCopyButton> CopyButtons { get; init; } = Array.Empty<ToastCopyButton>();

        /// <summary>«Відкрити» next to the thumbnail; the thumbnail opens the image anyway.</summary>
        public bool ShowOpenButton { get; init; } = true;

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
