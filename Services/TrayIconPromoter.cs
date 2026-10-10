using System;
using Microsoft.Win32;

namespace ScreenVoicer.Services
{
    /// <summary>
    /// Windows 11 hides a new tray icon behind the «^» arrow. Explorer keeps one key per icon under
    /// HKCU\Control Panel\NotifyIconSettings (ExecutablePath, IsPromoted); IsPromoted = 1 puts the icon on the
    /// taskbar. The app does this once per install, so a click on the icon is always one click away; if the user
    /// hides it again later, that choice is kept. Windows 10 has no such key: nothing happens there.
    /// </summary>
    internal static class TrayIconPromoter
    {
        private const string SettingsKey = @"Control Panel\NotifyIconSettings";

        /// <summary>True when Explorer's entry for this exe was found and promoted.</summary>
        public static bool TryPromote(string exePath)
        {
            try
            {
                using var root = Registry.CurrentUser.OpenSubKey(SettingsKey);
                if (root == null)
                {
                    return false;
                }

                bool promoted = false;
                foreach (string name in root.GetSubKeyNames())
                {
                    using var key = root.OpenSubKey(name, writable: true);
                    if (key?.GetValue("ExecutablePath") is string path &&
                        string.Equals(path, exePath, StringComparison.OrdinalIgnoreCase))
                    {
                        key.SetValue("IsPromoted", 1, RegistryValueKind.DWord);
                        promoted = true;
                    }
                }
                return promoted;
            }
            catch (Exception ex)
            {
                Log.Warn("[Tray] Could not move the icon out of the overflow", ex);
                return false;
            }
        }
    }
}
