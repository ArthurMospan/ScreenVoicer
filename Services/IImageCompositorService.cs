using System.Drawing;
using System.Threading.Tasks;
using System.Windows.Media;

namespace ScreenVoicer.Services
{
    public sealed record SavedScreenshot(string Path, int Width, int Height, long FileSizeBytes);

    public interface IImageCompositorService
    {
        /// <summary>
        /// Burns the annotation layer (ink, text labels, numbered markers) into the screenshot at native
        /// resolution, crops it and saves a PNG. Call on the UI thread (the layer is rendered there);
        /// encoding and disk I/O run in the background.
        /// </summary>
        /// <param name="background">Full-monitor capture in physical pixels.</param>
        /// <param name="annotations">The overlay's annotation layer, laid out in DIPs from (0,0).</param>
        /// <param name="annotationsSize">Size of that layer in DIPs.</param>
        /// <param name="dipToPixelX">Horizontal DIP → pixel scale of the overlay.</param>
        /// <param name="dipToPixelY">Vertical DIP → pixel scale of the overlay.</param>
        /// <param name="cropPx">Region to keep in physical pixels, null for the whole monitor.</param>
        Task<SavedScreenshot> SaveAnnotatedScreenshotAsync(
            Bitmap background,
            Visual? annotations,
            System.Windows.Size annotationsSize,
            double dipToPixelX,
            double dipToPixelY,
            Rectangle? cropPx);
    }
}
