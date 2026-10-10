using System.Drawing;
using System.Drawing.Imaging;
using System.Windows.Forms;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using PixelFormat = System.Drawing.Imaging.PixelFormat;

namespace ScreenVoicer.Services
{
    public sealed class ScreenCaptureService : IScreenCaptureService
    {
        public ScreenCapture CaptureActiveScreen()
        {
            // The process is per-monitor DPI aware (app.manifest), so cursor and screen bounds are physical pixels.
            var screen = Screen.FromPoint(Cursor.Position);
            var bounds = screen.Bounds;

            // 32bpp RGB: screenshots have no alpha, which also makes the saved PNGs smaller and faster to encode.
            var bitmap = new Bitmap(bounds.Width, bounds.Height, PixelFormat.Format32bppRgb);
            try
            {
                using (var graphics = Graphics.FromImage(bitmap))
                {
                    graphics.CopyFromScreen(bounds.Left, bounds.Top, 0, 0, bounds.Size, CopyPixelOperation.SourceCopy);
                }

                // Wrap the pixels directly instead of GetHbitmap + CreateBitmapSourceFromHBitmap,
                // which made two extra full-screen copies and a GDI handle per capture.
                var data = bitmap.LockBits(new Rectangle(0, 0, bounds.Width, bounds.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppRgb);
                BitmapSource source;
                try
                {
                    source = BitmapSource.Create(
                        bounds.Width, bounds.Height, 96, 96, PixelFormats.Bgr32, null,
                        data.Scan0, data.Stride * bounds.Height, data.Stride);
                    source.Freeze();
                }
                finally
                {
                    bitmap.UnlockBits(data);
                }

                return new ScreenCapture(bitmap, source, bounds);
            }
            catch
            {
                bitmap.Dispose();
                throw;
            }
        }
    }
}
