using System;
using System.Drawing;
using System.Windows.Media.Imaging;

namespace ScreenVoicer.Services
{
    /// <summary>A frozen screenshot of one monitor: GDI+ bitmap for saving, WPF source for display.</summary>
    public sealed class ScreenCapture : IDisposable
    {
        public ScreenCapture(Bitmap bitmap, BitmapSource source, Rectangle bounds)
        {
            Bitmap = bitmap;
            Source = source;
            Bounds = bounds;
        }

        public Bitmap Bitmap { get; }
        public BitmapSource Source { get; }

        /// <summary>Monitor bounds in physical pixels (virtual-screen coordinates).</summary>
        public Rectangle Bounds { get; }

        public void Dispose() => Bitmap.Dispose();
    }

    public interface IScreenCaptureService
    {
        /// <summary>Captures the monitor under the mouse cursor.</summary>
        ScreenCapture CaptureActiveScreen();
    }
}
