using System;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using ScreenVoicer.Native;
using ScreenVoicer.Services;

namespace ScreenVoicer.Views
{
    /// <summary>"Press the new shortcut" dialog. The caller unregisters the current hotkey while it is open.</summary>
    public partial class HotkeyWindow : Window
    {
        private static readonly Brush Muted = Freeze(Color.FromRgb(0x9D, 0x9D, 0xAA));
        private static readonly Brush Ink = Freeze(Color.FromRgb(0xF3, 0xF3, 0xF6));
        private static readonly Brush Warning = Freeze(Color.FromRgb(0xFB, 0xBF, 0x24));
        private static readonly Brush Error = Freeze(Color.FromRgb(0xF8, 0x71, 0x71));

        // Shortcuts other apps (or Windows itself) need; grabbing them globally would break them everywhere.
        private static readonly string[] Reserved =
        {
            "Ctrl+C", "Ctrl+V", "Ctrl+X", "Ctrl+Z", "Ctrl+Y", "Ctrl+A", "Ctrl+S", "Ctrl+F", "Ctrl+P", "Ctrl+N", "Ctrl+W", "Ctrl+T",
            "Alt+F4", "Alt+Tab", "Alt+Space", "Ctrl+Shift+Escape", "Ctrl+Escape"
        };

        private readonly Func<HotkeyGesture, bool> _apply;
        private HotkeyGesture _candidate;

        /// <param name="apply">Tries to register the shortcut; false when another app owns it.</param>
        public HotkeyWindow(HotkeyGesture current, Func<HotkeyGesture, bool> apply)
        {
            InitializeComponent();
            _apply = apply;
            _candidate = current;
            BtnDefault.Content = $"За замовчуванням ({SettingsService.DefaultHotkey})";
            ShowKeys(current.Modifiers, current.Key);
            ShowStatus($"Зараз: {current}", Muted);
            Loaded += (_, _) => Keyboard.Focus(this);
        }

        protected override void OnPreviewKeyDown(KeyEventArgs e)
        {
            base.OnPreviewKeyDown(e);
            Key key = RealKey(e);
            var modifiers = HotkeyGesture.FromWpf(Keyboard.Modifiers);

            if (modifiers == User32.KeyModifiers.None)
            {
                switch (key)
                {
                    case Key.Escape:
                        e.Handled = true;
                        Close();
                        return;
                    case Key.Enter:
                        e.Handled = true;
                        Save();
                        return;
                    case Key.Tab:
                        return; // keep keyboard navigation between the buttons
                }
            }

            e.Handled = true;
            Capture(modifiers, key);
        }

        protected override void OnPreviewKeyUp(KeyEventArgs e)
        {
            base.OnPreviewKeyUp(e);
            Key key = RealKey(e);

            // Windows sends PrintScreen as a key-up only.
            if (key == Key.Snapshot)
            {
                e.Handled = true;
                Capture(HotkeyGesture.FromWpf(Keyboard.Modifiers), key);
            }
            else if (HotkeyGesture.IsModifierKey(key) && !_candidate.IsValid)
            {
                ShowKeys(HotkeyGesture.FromWpf(Keyboard.Modifiers), Key.None);
            }
        }

        private void Capture(User32.KeyModifiers modifiers, Key key)
        {
            if (HotkeyGesture.IsModifierKey(key))
            {
                ShowKeys(modifiers, Key.None); // "Ctrl + Shift + …" while the user is still pressing
                return;
            }

            var gesture = new HotkeyGesture(modifiers, key);
            ShowKeys(modifiers, key);

            if (!gesture.IsValid)
            {
                _candidate = default;
                ShowStatus("Додайте Ctrl, Alt, Shift або Win — інакше клавіша заважатиме друкувати.", Warning);
                return;
            }
            if (Reserved.Contains(gesture.ToString(), StringComparer.OrdinalIgnoreCase))
            {
                _candidate = default;
                ShowStatus($"{gesture} потрібна іншим програмам і Windows — оберіть іншу комбінацію.", Warning);
                return;
            }

            _candidate = gesture;
            ShowStatus("Натисніть «Зберегти» або Enter.", Muted);
        }

        private void Save()
        {
            if (!_candidate.IsValid)
            {
                ShowStatus("Спершу натисніть комбінацію клавіш.", Warning);
                return;
            }

            if (_apply(_candidate))
            {
                Close();
            }
            else
            {
                ShowStatus($"{_candidate} вже зайнята іншою програмою або Windows — спробуйте іншу.", Error);
            }
        }

        private void ShowKeys(User32.KeyModifiers modifiers, Key key)
        {
            KeysPanel.Children.Clear();
            var names = HotkeyGesture.ModifierNames(modifiers).ToList();
            names.Add(key == Key.None ? "…" : HotkeyGesture.KeyName(key));

            for (int i = 0; i < names.Count; i++)
            {
                if (i > 0)
                {
                    KeysPanel.Children.Add(new TextBlock
                    {
                        Text = "+",
                        FontSize = 16,
                        Foreground = Muted,
                        VerticalAlignment = VerticalAlignment.Center,
                        Margin = new Thickness(2, 0, 2, 0)
                    });
                }

                KeysPanel.Children.Add(new Border
                {
                    Style = (Style)FindResource("KeyCap"),
                    Child = new TextBlock
                    {
                        Text = names[i],
                        FontSize = 16,
                        FontWeight = FontWeights.SemiBold,
                        Foreground = names[i] == "…" ? Muted : Ink,
                        HorizontalAlignment = HorizontalAlignment.Center
                    }
                });
            }
        }

        private void ShowStatus(string text, Brush brush)
        {
            TxtStatus.Text = text;
            TxtStatus.Foreground = brush;
        }

        private static Key RealKey(KeyEventArgs e) => e.Key switch
        {
            Key.System => e.SystemKey,
            Key.ImeProcessed => e.ImeProcessedKey,
            Key.DeadCharProcessed => e.DeadCharProcessedKey,
            _ => e.Key
        };

        private void OnDefaultClick(object sender, RoutedEventArgs e)
        {
            if (HotkeyGesture.TryParse(SettingsService.DefaultHotkey, out var gesture))
            {
                _candidate = gesture;
                ShowKeys(gesture.Modifiers, gesture.Key);
                ShowStatus("Натисніть «Зберегти» або Enter.", Muted);
            }
            Keyboard.Focus(this);
        }

        private void OnSaveClick(object sender, RoutedEventArgs e) => Save();

        private void OnCancelClick(object sender, RoutedEventArgs e) => Close();

        private void OnDragArea(object sender, MouseButtonEventArgs e)
        {
            if (e.ButtonState == MouseButtonState.Pressed && e.OriginalSource is not Button)
            {
                DragMove();
            }
        }

        private static Brush Freeze(Color color)
        {
            var brush = new SolidColorBrush(color);
            brush.Freeze();
            return brush;
        }
    }
}
