using System;
using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace ScreenVoicer.Services
{
    /// <summary>
    /// The screenshot with its comment written under it on a dark band: the link preview (ShareService) and the
    /// «З підписом» copy from the saved-screenshot toast. Same layout as the Mac app's CaptionCard. At 1200 px wide the
    /// band has 40/44 px padding, a 6 px orange bar at x 56 and the text at x 86 (40 px semibold, 52 px lines), plus an
    /// optional muted footer line (28 px); every size scales with the card width.
    /// </summary>
    public static class CaptionCard
    {
        private const double BaseWidth = 1200;
        public const int MinWidth = 640;

        private static readonly SolidColorBrush Background = Frozen(0x0F, 0x0F, 0x13);
        private static readonly SolidColorBrush Ink = Frozen(0xF4, 0xF4, 0xF7);
        private static readonly SolidColorBrush Muted = Frozen(0xAA, 0xAA, 0xB6);
        private static readonly SolidColorBrush Accent = Frozen(0xFF, 0x8A, 0x4C);

        /// <param name="width">Card width in pixels; null keeps the screenshot at its own size (the card is at least MinWidth wide).</param>
        /// <param name="maxPictureHeight">The screenshot is scaled down (never up) to fit width × this.</param>
        /// <remarks>WPF drawing: call on an STA thread.</remarks>
        public static BitmapSource Render(string path, string caption, int? width = null, int maxPictureHeight = int.MaxValue,
            int maxLines = 12, string? footer = null)
        {
            BitmapFrame frame;
            using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            {
                frame = BitmapFrame.Create(stream, BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
            }
            int w = width ?? Math.Max(MinWidth, frame.PixelWidth);
            double scale = Math.Min(1.0, Math.Min(w / (double)frame.PixelWidth, maxPictureHeight / (double)frame.PixelHeight));
            double pw = Math.Round(frame.PixelWidth * scale), ph = Math.Round(frame.PixelHeight * scale);
            double k = Math.Clamp(w / BaseWidth, 0.55, 2.4);

            caption = caption.Trim();
            FormattedText? text = null, more = null;
            double band = 0;
            if (caption.Length > 0)
            {
                var family = new FontFamily("Segoe UI Variable Display, Segoe UI");
                var culture = CultureInfo.GetCultureInfo("uk-UA");
                text = new FormattedText(caption, culture, FlowDirection.LeftToRight,
                    new Typeface(family, FontStyles.Normal, FontWeights.SemiBold, FontStretches.Normal), 40 * k, Ink, 1.0)
                {
                    MaxTextWidth = w - (86 + 56) * k,
                    MaxLineCount = maxLines,
                    LineHeight = 52 * k,
                    Trimming = TextTrimming.WordEllipsis
                };
                band = (40 + 44) * k + text.Height;
                if (!string.IsNullOrEmpty(footer))
                {
                    more = new FormattedText(footer, culture, FlowDirection.LeftToRight,
                        new Typeface(family, FontStyles.Normal, FontWeights.Normal, FontStretches.Normal), 28 * k, Muted, 1.0);
                    band += (14 + 36) * k;
                }
            }

            int height = (int)Math.Ceiling(ph + band);
            var visual = new DrawingVisual();
            RenderOptions.SetBitmapScalingMode(visual, BitmapScalingMode.HighQuality);
            using (var dc = visual.RenderOpen())
            {
                dc.DrawRectangle(Background, null, new Rect(0, 0, w, height));
                dc.DrawImage(frame, new Rect((w - pw) / 2, 0, pw, ph));
                if (text != null)
                {
                    double top = ph + 40 * k;
                    dc.DrawRectangle(Accent, null, new Rect(56 * k, top + 6 * k, 6 * k, Math.Max(20 * k, text.Height - 12 * k)));
                    dc.DrawText(text, new Point(86 * k, top));
                    if (more != null)
                    {
                        dc.DrawText(more, new Point(86 * k, top + text.Height + 14 * k));
                    }
                }
            }
            var target = new RenderTargetBitmap(w, height, 96, 96, PixelFormats.Pbgra32);
            target.Render(visual);
            var opaque = new FormatConvertedBitmap(target, PixelFormats.Bgr24, null, 0); // no alpha: JPEG needs it, PNG gets smaller
            opaque.Freeze();
            return opaque;
        }

        /// <summary>
        /// «З підписом»: the card at the screenshot's own size as a PNG in the temp folder, for the clipboard.
        /// The screenshot itself stays clean. Returns null if it could not be made.
        /// </summary>
        public static string? SaveForClipboard(string path, string caption)
        {
            try
            {
                var card = Render(path, caption);
                string folder = Path.Combine(Path.GetTempPath(), "ScreenVoicer");
                Directory.CreateDirectory(folder);
                string file = Path.Combine(folder, Path.GetFileNameWithoutExtension(path) + "-caption.png");
                var encoder = new PngBitmapEncoder();
                encoder.Frames.Add(BitmapFrame.Create(card));
                using (var output = File.Create(file))
                {
                    encoder.Save(output);
                }
                return file;
            }
            catch (Exception ex)
            {
                Log.Warn("[Caption] Could not make the captioned copy", ex);
                return null;
            }
        }

        private static SolidColorBrush Frozen(byte r, byte g, byte b)
        {
            var brush = new SolidColorBrush(Color.FromRgb(r, g, b));
            brush.Freeze();
            return brush;
        }
    }
}
