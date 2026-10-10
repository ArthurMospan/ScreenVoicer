using System;
using System.Collections.Specialized;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Media.Imaging;
using WpfClipboard = System.Windows.Clipboard;
using WpfDataFormats = System.Windows.DataFormats;
using WpfDataObject = System.Windows.DataObject;

namespace ScreenVoicer.Services
{
    public sealed class ClipboardService : IClipboardService
    {
        public string FormatMarkdown(string imagePath, string transcribedText)
        {
            string cleanText = string.IsNullOrWhiteSpace(transcribedText)
                ? "*(No voice comment recorded)*"
                : transcribedText.Trim();

            return $"[{imagePath}]\n**Comment:** {cleanText}";
        }

        /// <remarks>Must be called on an STA thread (the UI thread).</remarks>
        public bool CopyToClipboard(string text, string? imagePath = null)
        {
            var dataObject = new WpfDataObject();
            dataObject.SetData(WpfDataFormats.UnicodeText, text);
            dataObject.SetData(WpfDataFormats.Text, text);

            if (!string.IsNullOrEmpty(imagePath) && File.Exists(imagePath))
            {
                dataObject.SetFileDropList(new StringCollection { imagePath });

                try
                {
                    byte[] png = File.ReadAllBytes(imagePath);

                    // Browsers, Slack, Discord, Telegram etc. paste the "PNG" format losslessly;
                    // classic apps (Paint, Word) use the bitmap.
                    dataObject.SetData("PNG", new MemoryStream(png), false);

                    var bitmap = new BitmapImage();
                    bitmap.BeginInit();
                    bitmap.StreamSource = new MemoryStream(png);
                    bitmap.CacheOption = BitmapCacheOption.OnLoad;
                    bitmap.EndInit();
                    bitmap.Freeze();
                    dataObject.SetImage(bitmap);
                }
                catch (Exception ex)
                {
                    Log.Warn("[Clipboard] Could not attach the image", ex);
                }
            }

            // Another app (clipboard managers, RDP) can hold the clipboard for a moment.
            for (int attempt = 0; attempt < 6; attempt++)
            {
                try
                {
                    WpfClipboard.SetDataObject(dataObject, true);
                    return true;
                }
                catch (ExternalException) // COMException CLIPBRD_E_CANT_OPEN
                {
                    Thread.Sleep(60);
                }
            }

            Log.Warn("[Clipboard] Clipboard stayed locked, copy failed.");
            return false;
        }
    }
}
