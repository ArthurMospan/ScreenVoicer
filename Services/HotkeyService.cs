using System;
using System.Runtime.InteropServices;
using System.Windows.Input;
using System.Windows.Interop;
using ScreenVoicer.Native;

namespace ScreenVoicer.Services
{
    public sealed class HotkeyService : IHotkeyService
    {
        private const int HotkeyId = 9001;
        private HwndSource? _hwndSource;
        private bool _isRegistered;
        private bool _disposed;

        public event EventHandler? HotkeyPressed;

        public bool IsRegistered => _isRegistered;

        public HotkeyService()
        {
            // Message-only window: receives WM_HOTKEY, is never shown and never enumerated as a top-level window.
            var parameters = new HwndSourceParameters("ScreenVoicer_HotkeySink")
            {
                Width = 0,
                Height = 0,
                WindowStyle = 0,
                ParentWindow = User32.HWND_MESSAGE
            };

            _hwndSource = new HwndSource(parameters);
            _hwndSource.AddHook(WndProc);
        }

        public bool Register(User32.KeyModifiers modifiers, Key key)
        {
            if (_hwndSource == null)
            {
                return false;
            }

            Unregister();

            int virtualKey = KeyInterop.VirtualKeyFromKey(key);
            uint mod = (uint)(modifiers | User32.KeyModifiers.NoRepeat);
            _isRegistered = User32.RegisterHotKey(_hwndSource.Handle, HotkeyId, mod, (uint)virtualKey);

            if (_isRegistered)
            {
                Log.Info($"[Hotkey] Registered {new HotkeyGesture(modifiers, key)}.");
            }
            else
            {
                Log.Warn($"[Hotkey] Failed to register {new HotkeyGesture(modifiers, key)}, Win32 error {Marshal.GetLastWin32Error()} (taken by another app or Windows).");
            }
            return _isRegistered;
        }

        public void Unregister()
        {
            if (_isRegistered && _hwndSource != null)
            {
                User32.UnregisterHotKey(_hwndSource.Handle, HotkeyId);
                _isRegistered = false;
            }
        }

        private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
        {
            if (msg == User32.WM_HOTKEY && wParam.ToInt32() == HotkeyId)
            {
                handled = true;
                HotkeyPressed?.Invoke(this, EventArgs.Empty);
            }
            return IntPtr.Zero;
        }

        public void Dispose()
        {
            if (_disposed)
            {
                return;
            }
            _disposed = true;

            Unregister();
            if (_hwndSource != null)
            {
                _hwndSource.RemoveHook(WndProc);
                _hwndSource.Dispose();
                _hwndSource = null;
            }
        }
    }
}
