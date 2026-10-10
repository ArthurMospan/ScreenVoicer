using System;
using System.Drawing;
using System.Windows.Forms;

namespace ScreenVoicer.Services
{
    internal static class AppIcons
    {
        private static readonly Uri IconUri = new("pack://application:,,,/ScreenVoicer;component/Resources/AppIcon.ico");

        /// <summary>Tray icon at the size the shell actually uses (the old one was drawn at 32 px and downscaled).</summary>
        public static Icon CreateTrayIcon()
        {
            try
            {
                var resource = System.Windows.Application.GetResourceStream(IconUri);
                if (resource != null)
                {
                    using var stream = resource.Stream;
                    return new Icon(stream, SystemInformation.SmallIconSize);
                }
            }
            catch (Exception ex)
            {
                Log.Warn("[Icons] Could not load the tray icon resource", ex);
            }
            return SystemIcons.Application;
        }
    }
}
