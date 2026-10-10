using System;
using Microsoft.Win32;

namespace ScreenVoicer.Services
{
    /// <summary>Autostart via HKCU\...\Run. The installer writes the same value, so there is a single source of truth.</summary>
    public static class StartupManager
    {
        public const string AutostartArgument = "--autostart";
        private const string RunRegistryKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
        private const string AppName = "ScreenVoicer";

        private static string? ExePath => Environment.ProcessPath;

        private static string Command => $"\"{ExePath}\" {AutostartArgument}";

        public static bool IsRunOnStartupEnabled()
        {
            try
            {
                using var key = Registry.CurrentUser.OpenSubKey(RunRegistryKey, false);
                return key?.GetValue(AppName) is string value && !string.IsNullOrWhiteSpace(value);
            }
            catch
            {
                return false;
            }
        }

        public static bool SetRunOnStartup(bool enable)
        {
            try
            {
                using var key = Registry.CurrentUser.OpenSubKey(RunRegistryKey, true);
                if (key == null)
                {
                    return false;
                }

                if (!enable)
                {
                    key.DeleteValue(AppName, false);
                    return true;
                }

                if (string.IsNullOrEmpty(ExePath))
                {
                    return false;
                }

                key.SetValue(AppName, Command);
                return true;
            }
            catch (Exception ex)
            {
                Log.Warn("[Startup] Could not change the Run registry value", ex);
                return false;
            }
        }

        /// <summary>
        /// Adds the --autostart flag to entries written by older versions, and re-points an entry whose exe
        /// no longer exists (app moved) at this exe. Entries for another existing copy are left alone.
        /// </summary>
        public static void RefreshEntryIfEnabled()
        {
            try
            {
                using var key = Registry.CurrentUser.OpenSubKey(RunRegistryKey, true);
                if (key?.GetValue(AppName) is not string value || string.IsNullOrEmpty(ExePath) ||
                    string.Equals(value, Command, StringComparison.OrdinalIgnoreCase))
                {
                    return;
                }

                string registeredExe = ParseExePath(value);
                bool sameExe = string.Equals(registeredExe, ExePath, StringComparison.OrdinalIgnoreCase);
                if (sameExe || !System.IO.File.Exists(registeredExe))
                {
                    key.SetValue(AppName, Command);
                    Log.Info($"[Startup] Autostart entry updated to {Command}");
                }
            }
            catch (Exception ex)
            {
                Log.Warn("[Startup] Could not refresh the autostart entry", ex);
            }
        }

        private static string ParseExePath(string command)
        {
            command = command.Trim();
            if (command.StartsWith('"'))
            {
                int end = command.IndexOf('"', 1);
                return end > 1 ? command[1..end] : command.Trim('"');
            }
            int space = command.IndexOf(" --", StringComparison.Ordinal);
            return space > 0 ? command[..space] : command;
        }
    }
}
