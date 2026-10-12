using System;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using ScreenVoicer.Services;
using Drawing = System.Drawing;

namespace ScreenVoicer.Views
{
    /// <summary>
    /// Frosted glass for the tray menu and the toasts. WPF can't blur what is behind a window, so a vertical strip of the
    /// screen is captured while the window is still invisible, shrunk 12× and stretched back with linear filtering (reads
    /// as a strong blur); the card then shows the part of the strip that is right behind it, so it can move or grow
    /// without a new capture. Same look as the Mac app's NSVisualEffectView glass.
    /// </summary>
    internal static class GlassBackdrop
    {
        /// <summary>The blurred strip as a brush for the card's backdrop layer, or null if the screen could not be read.</summary>
        public static ImageBrush? Capture(Drawing.Rectangle stripPx)
        {
            try
            {
                using var bitmap = new Drawing.Bitmap(stripPx.Width, stripPx.Height, Drawing.Imaging.PixelFormat.Format32bppRgb);
                using (var g = Drawing.Graphics.FromImage(bitmap))
                {
                    g.CopyFromScreen(stripPx.Location, Drawing.Point.Empty, stripPx.Size);
                }

                var data = bitmap.LockBits(new Drawing.Rectangle(0, 0, bitmap.Width, bitmap.Height),
                    Drawing.Imaging.ImageLockMode.ReadOnly, Drawing.Imaging.PixelFormat.Format32bppRgb);
                BitmapSource source;
                try
                {
                    source = BitmapSource.Create(bitmap.Width, bitmap.Height, 96, 96, PixelFormats.Bgr32, null,
                        data.Scan0, data.Stride * bitmap.Height, data.Stride);
                }
                finally
                {
                    bitmap.UnlockBits(data);
                }

                int smallW = Math.Max(4, stripPx.Width / 12), smallH = Math.Max(4, stripPx.Height / 12);
                var visual = new DrawingVisual();
                RenderOptions.SetBitmapScalingMode(visual, BitmapScalingMode.HighQuality);
                using (var dc = visual.RenderOpen())
                {
                    dc.DrawImage(source, new Rect(0, 0, smallW, smallH));
                }
                var small = new RenderTargetBitmap(smallW, smallH, 96, 96, PixelFormats.Pbgra32);
                small.Render(visual);
                small.Freeze();

                var brush = new ImageBrush(small) { ViewboxUnits = BrushMappingMode.Absolute, Stretch = Stretch.Fill };
                RenderOptions.SetBitmapScalingMode(brush, BitmapScalingMode.Linear);
                return brush;
            }
            catch (Exception ex)
            {
                Log.Warn("[Glass] Could not capture the backdrop", ex);
                return null;
            }
        }

        /// <summary>Points the brush at the part of the strip behind a card at these screen pixels.</summary>
        public static void Align(ImageBrush brush, Drawing.Rectangle stripPx, double cardTopPx, double cardHeightPx)
        {
            if (brush.ImageSource is not BitmapSource small || stripPx.Height <= 0)
            {
                return;
            }
            double ky = small.PixelHeight / (double)stripPx.Height;
            brush.Viewbox = new Rect(0, (cardTopPx - stripPx.Top) * ky, small.PixelWidth, cardHeightPx * ky);
        }
    }
}
