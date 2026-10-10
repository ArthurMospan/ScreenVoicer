using System;
using System.Windows.Input;
using ScreenVoicer.Native;

namespace ScreenVoicer.Services
{
    public interface IHotkeyService : IDisposable
    {
        event EventHandler? HotkeyPressed;
        bool Register(User32.KeyModifiers modifiers, Key key);
        void Unregister();
        bool IsRegistered { get; }
    }
}
