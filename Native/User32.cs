using System;
using System.Runtime.InteropServices;

namespace ScreenVoicer.Native
{
    public static class User32
    {
        public const int WM_HOTKEY = 0x0312;
        public const int WM_DPICHANGED = 0x02E0;

        /// <summary>Parent handle for message-only windows (never visible, never enumerated).</summary>
        public static readonly IntPtr HWND_MESSAGE = new(-3);

        [Flags]
        public enum KeyModifiers : uint
        {
            None = 0x0000,
            Alt = 0x0001,
            Control = 0x0002,
            Shift = 0x0004,
            Win = 0x0008,
            NoRepeat = 0x4000
        }

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool UnregisterHotKey(IntPtr hWnd, int id);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool SetForegroundWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool BringWindowToTop(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern uint GetWindowThreadProcessId(IntPtr hWnd, IntPtr processId);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, [MarshalAs(UnmanagedType.Bool)] bool fAttach);

        [DllImport("kernel32.dll")]
        public static extern uint GetCurrentThreadId();

        public static readonly IntPtr HWND_TOPMOST = new(-1);
        public const uint SWP_NOSIZE = 0x0001;
        public const uint SWP_NOZORDER = 0x0004;
        public const uint SWP_NOACTIVATE = 0x0010;
        public const uint SWP_SHOWWINDOW = 0x0040;

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

        [StructLayout(LayoutKind.Sequential)]
        public struct RECT
        {
            public int Left, Top, Right, Bottom;
        }

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

        [DllImport("user32.dll")]
        private static extern uint GetDpiForSystem();

        [StructLayout(LayoutKind.Sequential)]
        private struct POINT
        {
            public int X, Y;
        }

        [DllImport("user32.dll")]
        private static extern IntPtr MonitorFromPoint(POINT pt, uint flags);

        [DllImport("shcore.dll")]
        private static extern int GetDpiForMonitor(IntPtr monitor, int dpiType, out uint dpiX, out uint dpiY);

        /// <summary>DPI scale of the monitor under a physical-pixel point (the tray's monitor for the tray menu).</summary>
        public static double GetDpiScaleForPoint(System.Drawing.Point point)
        {
            try
            {
                IntPtr monitor = MonitorFromPoint(new POINT { X = point.X, Y = point.Y }, 2 /* MONITOR_DEFAULTTONEAREST */);
                if (GetDpiForMonitor(monitor, 0 /* MDT_EFFECTIVE_DPI */, out uint dpi, out _) == 0 && dpi > 0)
                {
                    return dpi / 96.0;
                }
            }
            catch (Exception)
            {
                // shcore.dll is missing before Windows 8.1
            }
            return SystemDpiScale;
        }

        /// <summary>System DPI scale (1.0 = 96 DPI); WPF uses it for the initial placement of new windows.</summary>
        public static double SystemDpiScale
        {
            get
            {
                try
                {
                    uint dpi = GetDpiForSystem();
                    return dpi > 0 ? dpi / 96.0 : 1.0;
                }
                catch (EntryPointNotFoundException)
                {
                    return 1.0; // Windows older than 10 1607
                }
            }
        }

        // DWM: cloaking hides a window from the screen while it finishes its first render (no flash),
        // corner preference opts a full-screen borderless window out of Windows 11 rounded corners.
        public const int DWMWA_WINDOW_CORNER_PREFERENCE = 33;
        public const int DWMWA_CLOAK = 13;
        public const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
        public const int DWMWA_CAPTION_COLOR = 35;
        public const int DWMWCP_DONOTROUND = 1;
        public const int DWMWCP_ROUNDSMALL = 3;

        /// <summary>Dark title bar (Windows 10 20H1+) whose colour (Windows 11) blends into the window's own background.</summary>
        public static void UseDarkTitleBar(IntPtr hwnd, System.Windows.Media.Color caption)
        {
            SetDwmAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, 1);
            SetDwmAttribute(hwnd, DWMWA_CAPTION_COLOR, caption.R | caption.G << 8 | caption.B << 16); // COLORREF is 0x00BBGGRR
        }

        [DllImport("dwmapi.dll")]
        public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

        public static void SetDwmAttribute(IntPtr hwnd, int attribute, int value)
        {
            try
            {
                DwmSetWindowAttribute(hwnd, attribute, ref value, sizeof(int));
            }
            catch
            {
                // Older Windows builds simply don't support some attributes.
            }
        }

        /// <summary>
        /// Brings a window to the foreground even when our process is not the active one
        /// (e.g. after a delayed capture), by briefly attaching to the foreground thread's input queue.
        /// </summary>
        public static void ForceForeground(IntPtr hwnd)
        {
            IntPtr foreground = GetForegroundWindow();
            if (foreground == hwnd)
            {
                return;
            }

            uint currentThread = GetCurrentThreadId();
            uint foregroundThread = foreground != IntPtr.Zero ? GetWindowThreadProcessId(foreground, IntPtr.Zero) : 0;
            bool attached = foregroundThread != 0 && foregroundThread != currentThread &&
                            AttachThreadInput(currentThread, foregroundThread, true);
            try
            {
                BringWindowToTop(hwnd);
                SetForegroundWindow(hwnd);
            }
            finally
            {
                if (attached)
                {
                    AttachThreadInput(currentThread, foregroundThread, false);
                }
            }
        }
    }
}
