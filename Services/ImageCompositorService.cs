using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using PixelFormat = System.Drawing.Imaging.PixelFormat;
using Rectangle = System.Drawing.Rectangle;

namespace ScreenVoicer.Services
{
    public sealed class ImageCompositorService : IImageCompositorService
    {
        private readonly ISettingsService _settings;

        public ImageCompositorService(ISettingsService settings)
        {
            _settings = settings;
        }

        public async Task<SavedScreenshot> SaveAnnotatedScreenshotAsync(
            Bitmap background,
            Visual? annotations,
            System.Windows.Size annotationsSize,
            double dipToPixelX,
            double dipToPixelY,
            Rectangle? cropPx)
        {
            var bounds = new Rectangle(0, 0, background.Width, background.Height);
            var crop = cropPx.HasValue ? Rectangle.Intersect(cropPx.Value, bounds) : bounds;
            if (crop.Width < 2 || crop.Height < 2)
            {
                crop = bounds;
            }

            // Render only the cropped part of the annotation layer, on the UI thread (it is a live UI element).
            byte[]? inkPixels = annotations != null && annotationsSize.Width > 0
                ? RenderAnnotations(annotations, annotationsSize, dipToPixelX, dipToPixelY, crop)
                : null;

            return await Task.Run(() =>
            {
                string path = Path.Combine(EnsureOutputDirectory(), $"screenshot_{DateTime.Now:yyyyMMdd_HHmmss_fff}.png");

                // Crop first, then composite: the old code composited the whole monitor and cropped afterwards.
                // 24 bpp: GDI+ writes 32 bpp bitmaps as RGBA PNGs, screenshots don't need the alpha channel.
                using var output = background.Clone(crop, PixelFormat.Format24bppRgb);
                if (inkPixels != null)
                {
                    var handle = GCHandle.Alloc(inkPixels, GCHandleType.Pinned);
                    try
                    {
                        using var ink = new Bitmap(crop.Width, crop.Height, crop.Width * 4, PixelFormat.Format32bppPArgb, handle.AddrOfPinnedObject());
                        using var g = Graphics.FromImage(output);
                        g.CompositingMode = CompositingMode.SourceOver;
                        g.CompositingQuality = CompositingQuality.HighQuality;
                        g.DrawImageUnscaled(ink, 0, 0);
                    }
                    finally
                    {
                        handle.Free();
                    }
                }

                using (var file = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None, 1 << 16))
                {
                    output.Save(file, ImageFormat.Png);
                }

                long size = new FileInfo(path).Length;
                Log.Info($"[Compositor] Saved {crop.Width}x{crop.Height} ({size / 1024} KB) to {path}");
                return new SavedScreenshot(path, crop.Width, crop.Height, size);
            }).ConfigureAwait(true);
        }

        /// <summary>
        /// Renders exactly what the user sees on the annotation layer (strokes incl. highlighter blending, text
        /// labels, markers) as vectors at native resolution: a DPI of 96 × scale makes 1 DIP = scale pixels.
        /// </summary>
        private static byte[] RenderAnnotations(Visual layer, System.Windows.Size size, double scaleX, double scaleY, Rectangle crop)
        {
            var area = new System.Windows.Rect(size);
            var visual = new DrawingVisual();
            using (var dc = visual.RenderOpen())
            {
                dc.PushTransform(new TranslateTransform(-crop.X / scaleX, -crop.Y / scaleY));
                // Absolute viewbox = the layer's layout box, not its content bounds (which would shift/scale it).
                dc.DrawRectangle(new VisualBrush(layer)
                {
                    ViewboxUnits = BrushMappingMode.Absolute,
                    Viewbox = area,
                    ViewportUnits = BrushMappingMode.Absolute,
                    Viewport = area
                }, null, area);
                dc.Pop();
            }

            var target = new RenderTargetBitmap(crop.Width, crop.Height, 96 * scaleX, 96 * scaleY, PixelFormats.Pbgra32);
            target.Render(visual);

            int stride = crop.Width * 4;
            var pixels = new byte[stride * crop.Height];
            target.CopyPixels(pixels, stride, 0);
            return pixels;
        }

        private string EnsureOutputDirectory()
        {
            string configured = _settings.OutputDirectory;
            try
            {
                Directory.CreateDirectory(configured);
                return configured;
            }
            catch (Exception ex)
            {
                string fallback = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyPictures), "AI_Screenshots");
                Log.Warn($"[Compositor] Cannot use '{configured}', falling back to '{fallback}'", ex);
                Directory.CreateDirectory(fallback);

                // Keep settings in sync so the gallery and "open folder" look in the same place.
                _settings.OutputDirectory = fallback;
                _settings.Save();
                return fallback;
            }
        }
    }
}
