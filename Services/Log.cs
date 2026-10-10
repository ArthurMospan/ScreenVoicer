using System;
using System.Diagnostics;
using System.IO;
using System.Text;

namespace ScreenVoicer.Services
{
    /// <summary>
    /// Tiny thread-safe file logger. Release builds have no debugger attached, so without a log file
    /// every Debug.WriteLine is lost and user-reported problems are impossible to diagnose.
    /// Log location: %LOCALAPPDATA%\ScreenVoicer\logs\screenvoicer.log (rotated at 1 MB).
    /// </summary>
    public static class Log
    {
        private const long MaxLogBytes = 1024 * 1024;
        private static readonly object Sync = new();

        public static string LogDirectory { get; } = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ScreenVoicer", "logs");

        public static string LogFilePath { get; } = Path.Combine(LogDirectory, "screenvoicer.log");

        public static void Info(string message) => Write("INFO", message, null);

        public static void Warn(string message, Exception? ex = null) => Write("WARN", message, ex);

        public static void Error(string message, Exception? ex = null) => Write("ERROR", message, ex);

        private static void Write(string level, string message, Exception? ex)
        {
            var line = new StringBuilder()
                .Append(DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff"))
                .Append(" [").Append(level).Append("] ")
                .Append(message);

            if (ex != null)
            {
                line.AppendLine().Append(ex);
            }

            string text = line.ToString();
            Debug.WriteLine(text);

            lock (Sync)
            {
                try
                {
                    Directory.CreateDirectory(LogDirectory);

                    var info = new FileInfo(LogFilePath);
                    if (info.Exists && info.Length > MaxLogBytes)
                    {
                        File.Move(LogFilePath, LogFilePath + ".old", overwrite: true);
                    }

                    File.AppendAllText(LogFilePath, text + Environment.NewLine, Encoding.UTF8);
                }
                catch
                {
                    // Logging must never take the app down.
                }
            }
        }
    }
}
