namespace ScreenVoicer.Services
{
    public interface IClipboardService
    {
        string FormatMarkdown(string imagePath, string transcribedText);

        /// <summary>Puts text (and, if given, the image file + bitmap) on the clipboard. Returns false if the clipboard stayed locked.</summary>
        bool CopyToClipboard(string text, string? imagePath = null);

        /// <summary>Only the image (file + bitmap), no text: whatever the user pastes into, the picture arrives.</summary>
        bool CopyImage(string imagePath);
    }
}
