using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using ScreenVoicer.Views;

namespace ScreenVoicer.Services
{
    /// <summary>Shows toasts in a bottom-right stack (they used to be drawn on top of each other).</summary>
    public sealed class NotificationService : INotificationService
    {
        private const int MaxVisible = 3;
        private const double Gap = 4;

        private readonly IClipboardService _clipboard;
        private readonly List<ToastWindow> _toasts = new();

        public NotificationService(IClipboardService clipboard)
        {
            _clipboard = clipboard;
        }

        public void ShowToast(string title, string message, ToastKind kind = ToastKind.Info, int durationMs = 4500) =>
            Show(new ToastOptions { Title = title, Message = message, Kind = kind, DurationMs = durationMs });

        public void Show(ToastOptions options)
        {
            var dispatcher = Application.Current?.Dispatcher;
            if (dispatcher == null)
            {
                return;
            }

            dispatcher.BeginInvoke(() =>
            {
                foreach (var old in _toasts.Take(Math.Max(0, _toasts.Count - MaxVisible + 1)).ToList())
                {
                    old.Dismiss();
                }

                var toast = new ToastWindow(options, (text, image) => _clipboard.CopyToClipboard(text, image));
                toast.HeightKnown += (_, _) => Arrange(animate: true);
                toast.Closed += (_, _) =>
                {
                    _toasts.Remove(toast);
                    Arrange(animate: true);
                };

                _toasts.Add(toast);
                toast.Show();
            });
        }

        public bool HideAll()
        {
            bool any = _toasts.Count > 0;
            foreach (var toast in _toasts.ToList())
            {
                toast.CloseImmediately();
            }
            _toasts.Clear();
            return any;
        }

        /// <summary>Newest toast at the bottom, older ones pushed up.</summary>
        private void Arrange(bool animate)
        {
            var workArea = SystemParameters.WorkArea;
            double bottom = workArea.Bottom - 8;

            for (int i = _toasts.Count - 1; i >= 0; i--)
            {
                var toast = _toasts[i];
                if (!toast.IsHeightKnown)
                {
                    continue;
                }

                double top = bottom - toast.ActualHeight;
                toast.MoveTo(workArea.Right - toast.Width - 8, top, animate);
                bottom = top - Gap;
            }
        }
    }
}
