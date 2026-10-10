using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows.Input;
using ScreenVoicer.Native;

namespace ScreenVoicer.Services
{
    /// <summary>A global shortcut such as "Alt+Shift+S" or "PrintScreen".</summary>
    public readonly record struct HotkeyGesture(User32.KeyModifiers Modifiers, Key Key)
    {
        private static readonly Dictionary<Key, string> Names = new()
        {
            [Key.Snapshot] = "PrintScreen",
            [Key.Pause] = "Pause",
            [Key.Scroll] = "ScrollLock",
            [Key.Space] = "Space",
            [Key.Insert] = "Insert",
            [Key.Delete] = "Delete",
            [Key.Home] = "Home",
            [Key.End] = "End",
            [Key.PageUp] = "PageUp",
            [Key.PageDown] = "PageDown",
            [Key.OemTilde] = "`",
            [Key.OemMinus] = "-",
            [Key.OemPlus] = "=",
            [Key.OemOpenBrackets] = "[",
            [Key.OemCloseBrackets] = "]",
            [Key.OemPipe] = "\\",
            [Key.OemSemicolon] = ";",
            [Key.OemQuotes] = "'",
            [Key.OemComma] = ",",
            [Key.OemPeriod] = ".",
            [Key.OemQuestion] = "/"
        };

        /// <summary>Keys that are fine as a hotkey without any modifier (nobody types them).</summary>
        private static bool IsStandaloneKey(Key key) =>
            key is >= Key.F1 and <= Key.F24 or Key.Snapshot or Key.Pause or Key.Scroll or Key.Insert;

        /// <summary>One key instead of three: Insert is almost never used, so the app offers it.</summary>
        public static HotkeyGesture Insert => new(User32.KeyModifiers.None, Key.Insert);

        public static bool IsModifierKey(Key key) =>
            key is Key.LeftCtrl or Key.RightCtrl or Key.LeftAlt or Key.RightAlt or Key.LeftShift or Key.RightShift
                or Key.LWin or Key.RWin or Key.System;

        public bool IsValid =>
            Key != Key.None && !IsModifierKey(Key) &&
            ((Modifiers & ~User32.KeyModifiers.NoRepeat) != User32.KeyModifiers.None || IsStandaloneKey(Key));

        public static User32.KeyModifiers FromWpf(ModifierKeys modifiers)
        {
            var result = User32.KeyModifiers.None;
            if ((modifiers & ModifierKeys.Control) != 0) result |= User32.KeyModifiers.Control;
            if ((modifiers & ModifierKeys.Alt) != 0) result |= User32.KeyModifiers.Alt;
            if ((modifiers & ModifierKeys.Shift) != 0) result |= User32.KeyModifiers.Shift;
            if ((modifiers & ModifierKeys.Windows) != 0) result |= User32.KeyModifiers.Win;
            return result;
        }

        public static string KeyName(Key key) => key switch
        {
            >= Key.D0 and <= Key.D9 => ((char)('0' + (key - Key.D0))).ToString(),
            >= Key.NumPad0 and <= Key.NumPad9 => "Num" + (key - Key.NumPad0),
            _ when Names.TryGetValue(key, out var name) => name,
            _ => key.ToString()
        };

        /// <summary>Modifier names in the order Windows shows them.</summary>
        public static IEnumerable<string> ModifierNames(User32.KeyModifiers modifiers)
        {
            if ((modifiers & User32.KeyModifiers.Control) != 0) yield return "Ctrl";
            if ((modifiers & User32.KeyModifiers.Alt) != 0) yield return "Alt";
            if ((modifiers & User32.KeyModifiers.Shift) != 0) yield return "Shift";
            if ((modifiers & User32.KeyModifiers.Win) != 0) yield return "Win";
        }

        public override string ToString() => string.Join("+", ModifierNames(Modifiers).Append(KeyName(Key)));

        public static bool TryParse(string? text, out HotkeyGesture gesture)
        {
            gesture = default;
            if (string.IsNullOrWhiteSpace(text))
            {
                return false;
            }

            var modifiers = User32.KeyModifiers.None;
            Key key = Key.None;
            foreach (string raw in text.Split('+', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries))
            {
                switch (raw.ToLowerInvariant())
                {
                    case "ctrl" or "control": modifiers |= User32.KeyModifiers.Control; continue;
                    case "alt": modifiers |= User32.KeyModifiers.Alt; continue;
                    case "shift": modifiers |= User32.KeyModifiers.Shift; continue;
                    case "win" or "windows": modifiers |= User32.KeyModifiers.Win; continue;
                }

                if (key != Key.None)
                {
                    return false; // two non-modifier keys
                }

                var named = Names.FirstOrDefault(pair => string.Equals(pair.Value, raw, StringComparison.OrdinalIgnoreCase));
                if (named.Value != null)
                {
                    key = named.Key;
                }
                else if (raw.Length == 1 && char.IsDigit(raw[0]))
                {
                    key = Key.D0 + (raw[0] - '0');
                }
                else if (!Enum.TryParse(raw, ignoreCase: true, out key))
                {
                    return false;
                }
            }

            gesture = new HotkeyGesture(modifiers, key);
            return gesture.IsValid;
        }
    }
}
