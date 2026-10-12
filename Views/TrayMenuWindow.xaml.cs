using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using ScreenVoicer.Native;
using ScreenVoicer.Services;
using Drawing = System.Drawing;
using Forms = System.Windows.Forms;

namespace ScreenVoicer.Views
{
    public enum TrayStatusKind { Ready, Busy, Error }

    /// <summary>State of the optional NVIDIA CUDA pack, as the menu shows it.</summary>
    public enum CudaOffer { Hidden, Offer, Downloading, NeedsRestart, Active }

    /// <summary>What the tray menu reads and does; implemented by the app.</summary>
    public interface ITrayMenuHost
    {
        string CaptureHotkey { get; }
        string AppVersion { get; }
        (string Text, TrayStatusKind Kind) VoiceStatus { get; }
        int ScreenshotCount { get; }
        IReadOnlyList<MicrophoneInfo> GetMicrophones();
        string SelectedMicrophone { get; }
        bool CanPlayLastRecording { get; }
        string VoiceLanguage { get; }
        WhisperModelInfo SelectedModel { get; }
        bool UseGpu { get; }
        bool GpuAvailable { get; }
        string? GpuName { get; }
        CudaOffer Cuda { get; }
        double CudaProgress { get; }
        bool AutostartEnabled { get; }
        string AboutText { get; }

        /// <summary>Newer version available on GitHub, or null.</summary>
        string? UpdateVersion { get; }

        /// <summary>0..1 while the update downloads, otherwise null.</summary>
        double? UpdateProgress { get; }

        /// <summary>Raised (on any thread) when something the menu shows has changed.</summary>
        event EventHandler? MenuStateChanged;

        void Capture();
        void OpenGallery();
        void OpenScreenshotsFolder();
        void SelectMicrophone(MicrophoneInfo microphone);
        void PlayLastRecording();
        void SetVoiceLanguage(string code);
        void SelectModel(WhisperModelInfo model);
        void SetUseGpu(bool useGpu);
        void CudaAction();
        void OpenHotkeySettings();
        void SetAutostart(bool enabled);
        void OpenLog();
        void OpenModelsFolder();
        void Exit();
        void InstallUpdate();
        void CheckForUpdates();
    }

    /// <summary>
    /// The tray menu in the app's glass style (the WinForms context menu could not be made to look like it).
    /// It opens above the tray icon; the glass is a blurred copy of the desktop strip behind it, taken just before
    /// it appears — the same trick as the overlay panels. Lists expand inside the panel instead of side menus.
    /// </summary>
    public partial class TrayMenuWindow : Window
    {
        private static readonly Brush Green = Frozen(0x4A, 0xDE, 0x80);
        private static readonly Brush Amber = Frozen(0xFB, 0xBF, 0x24);
        private static readonly Brush Red = Frozen(0xF8, 0x71, 0x71);
        private static readonly Brush ToggleOff = FrozenArgb(0x29, 0xFF, 0xFF, 0xFF);

        private readonly ITrayMenuHost _host;
        private bool _closing;
        private bool _anchorBottom = true;
        private double _anchorEdgeDip;
        private Drawing.Rectangle _windowPx;
        private double _scale = 1;

        // the blurred desktop strip behind the card
        private ImageBrush? _backdrop;
        private Drawing.Rectangle _stripPx;

        public TrayMenuWindow(ITrayMenuHost host)
        {
            InitializeComponent();
            _host = host;
            _host.MenuStateChanged += OnHostChanged;
            Closed += (_, _) => _host.MenuStateChanged -= OnHostChanged;
            Deactivated += (_, _) => CloseMenu();
            SizeChanged += (_, _) => KeepAnchoredAndUpdateGlass();
            Refresh();
        }

        public bool IsClosing => _closing;

        /// <summary>Places the menu next to the tray (whatever edge the taskbar is on) and fades it in.</summary>
        public void ShowNear(Drawing.Point cursorPx)
        {
            var screen = Forms.Screen.FromPoint(cursorPx);
            Drawing.Rectangle work = screen.WorkingArea, bounds = screen.Bounds;
            _scale = User32.GetDpiScaleForPoint(cursorPx);

            int widthPx = (int)Math.Round(Width * _scale);
            int marginPx = (int)Math.Round(Card.Margin.Left * _scale);
            int gapPx = (int)Math.Round(6 * _scale);
            int cardW = widthPx - 2 * marginPx;

            // The height is only known after the first layout: show invisibly far away, then place it.
            Left = -32000;
            Top = -32000;
            Show();
            UpdateLayout();
            int heightPx = (int)Math.Round(ActualHeight * _scale);
            int cardH = heightPx - 2 * marginPx;

            bool bottom = work.Bottom < bounds.Bottom || (work.Height == bounds.Height && cursorPx.Y > bounds.Top + bounds.Height / 2);
            bool top = !bottom && work.Top > bounds.Top;
            bool left = !bottom && !top && work.Left > bounds.Left;
            int x, y;
            if (bottom)
            {
                x = cursorPx.X - cardW / 2;
                y = work.Bottom - cardH - gapPx;
            }
            else if (top)
            {
                x = cursorPx.X - cardW / 2;
                y = work.Top + gapPx;
            }
            else if (left)
            {
                x = work.Left + gapPx;
                y = cursorPx.Y - cardH / 2;
            }
            else
            {
                x = work.Right - cardW - gapPx;
                y = cursorPx.Y - cardH / 2;
            }
            x = Math.Clamp(x, work.Left + gapPx, Math.Max(work.Left + gapPx, work.Right - cardW - gapPx));
            y = Math.Clamp(y, work.Top + gapPx, Math.Max(work.Top + gapPx, work.Bottom - cardH - gapPx));
            _anchorBottom = !top;

            // Glass: blur the whole vertical strip, so the panel can grow (expanded lists) without new captures.
            // The window is still off-screen and transparent here, so it never photographs itself.
            _stripPx = new Drawing.Rectangle(x, work.Top, cardW, work.Height);
            SetupBackdrop(_stripPx);

            _windowPx = new Drawing.Rectangle(x - marginPx, y - marginPx, widthPx, heightPx);
            var hwnd = new WindowInteropHelper(this).Handle;
            User32.SetWindowPos(hwnd, User32.HWND_TOPMOST, _windowPx.X, _windowPx.Y, 0, 0, User32.SWP_NOSIZE | User32.SWP_NOACTIVATE);
            _anchorEdgeDip = _anchorBottom ? Top + ActualHeight : Top;
            Activate();
            User32.ForceForeground(hwnd);
            UpdateGlass();

            var ease = new CubicEase { EasingMode = EasingMode.EaseOut };
            BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(140)));
            Slide.BeginAnimation(TranslateTransform.YProperty,
                new DoubleAnimation(_anchorBottom ? 10 : -10, 0, TimeSpan.FromMilliseconds(200)) { EasingFunction = ease });
        }

        public void CloseMenu()
        {
            if (_closing)
            {
                return;
            }
            CloseDropdowns();
            _closing = true;
            Hide(); // gone from the screen at once (a capture may follow); Close after the current input settles
            Dispatcher.BeginInvoke(Close);
        }

        protected override void OnPreviewKeyDown(KeyEventArgs e)
        {
            base.OnPreviewKeyDown(e);
            if (e.Key == Key.Escape)
            {
                e.Handled = true;
                CloseMenu();
            }
        }

        #region Glass

        private void SetupBackdrop(Drawing.Rectangle stripPx)
        {
            try
            {
                using var bitmap = new Drawing.Bitmap(stripPx.Width, stripPx.Height, Drawing.Imaging.PixelFormat.Format32bppRgb);
                using (var g = Drawing.Graphics.FromImage(bitmap))
                {
                    g.CopyFromScreen(stripPx.Location, Drawing.Point.Empty, stripPx.Size);
                }

                var data = bitmap.LockBits(new Drawing.Rectangle(0, 0, bitmap.Width, bitmap.Height),
                    Drawing.Imaging.ImageLockMode.ReadOnly, Drawing.Imaging.PixelFormat.Format32bppRgb);
                BitmapSource source;
                try
                {
                    source = BitmapSource.Create(bitmap.Width, bitmap.Height, 96, 96, PixelFormats.Bgr32, null,
                        data.Scan0, data.Stride * bitmap.Height, data.Stride);
                }
                finally
                {
                    bitmap.UnlockBits(data);
                }

                // A tiny averaged copy stretched back with linear filtering reads as a strong blur.
                int smallW = Math.Max(4, stripPx.Width / 12), smallH = Math.Max(4, stripPx.Height / 12);
                var visual = new DrawingVisual();
                RenderOptions.SetBitmapScalingMode(visual, BitmapScalingMode.HighQuality);
                using (var dc = visual.RenderOpen())
                {
                    dc.DrawImage(source, new Rect(0, 0, smallW, smallH));
                }
                var small = new RenderTargetBitmap(smallW, smallH, 96, 96, PixelFormats.Pbgra32);
                small.Render(visual);
                small.Freeze();

                _backdrop = new ImageBrush(small) { ViewboxUnits = BrushMappingMode.Absolute, Stretch = Stretch.Fill };
                RenderOptions.SetBitmapScalingMode(_backdrop, BitmapScalingMode.Linear);
                Backdrop.Background = _backdrop;
            }
            catch (Exception ex)
            {
                Log.Warn("[Tray] Could not capture the glass backdrop", ex);
            }
        }

        /// <summary>Shows the part of the blurred strip that is right behind the card now.</summary>
        private void UpdateGlass()
        {
            if (_backdrop?.ImageSource is not BitmapSource small || _stripPx.Height <= 0 || !IsLoaded)
            {
                return;
            }

            var hwnd = new WindowInteropHelper(this).Handle;
            double windowTopPx = hwnd != IntPtr.Zero && User32.GetWindowRect(hwnd, out var rect) ? rect.Top : Top * _scale;
            double cardTopPx = windowTopPx + Card.Margin.Top * _scale;
            double cardHeightPx = Card.ActualHeight * _scale;
            double ky = small.PixelHeight / (double)_stripPx.Height;
            _backdrop.Viewbox = new Rect(0, (cardTopPx - _stripPx.Top) * ky, small.PixelWidth, cardHeightPx * ky);
        }

        /// <summary>Expanding a list grows the panel away from the taskbar, not into it.</summary>
        private void KeepAnchoredAndUpdateGlass()
        {
            if (!IsVisible)
            {
                return;
            }
            if (_anchorBottom)
            {
                double top = _anchorEdgeDip - ActualHeight;
                if (Math.Abs(top - Top) > 0.5)
                {
                    Top = top;
                }
            }
            UpdateGlass();
        }

        #endregion

        #region State

        private void OnHostChanged(object? sender, EventArgs e) => Dispatcher.BeginInvoke(() =>
        {
            if (!_closing)
            {
                Refresh();
            }
        });

        private void Refresh()
        {
            TxtVersion.Text = _host.AppVersion;
            var (statusText, kind) = _host.VoiceStatus;
            TxtStatus.Text = statusText;
            TxtStatus.ToolTip = statusText;
            StatusDot.Fill = kind switch { TrayStatusKind.Error => Red, TrayStatusKind.Busy => Amber, _ => Green };

            TxtCaptureHotkey.Text = _host.CaptureHotkey;
            TxtHotkey.Text = _host.CaptureHotkey;
            int count = _host.ScreenshotCount;
            TxtGalleryCount.Text = count > 0 ? Plural(count, "знімок", "знімки", "знімків") : string.Empty;

            var microphones = _host.GetMicrophones();
            var selected = microphones.FirstOrDefault(m => string.Equals(m.Name, _host.SelectedMicrophone, StringComparison.OrdinalIgnoreCase));
            TxtMicrophone.Text = selected == null || selected.IsSystemDefault ? "Системний" : ShortName(selected.DisplayName);

            TxtLanguage.Text = LanguageName(_host.VoiceLanguage);

            TxtModel.Text = _host.SelectedModel.Title;

            bool autostart = _host.AutostartEnabled;
            ToggleTrack.Background = autostart ? (Brush)FindResource("AccentFill") : ToggleOff;
            ToggleKnob.HorizontalAlignment = autostart ? HorizontalAlignment.Right : HorizontalAlignment.Left;

            TxtAbout.Text = _host.AboutText;

            string? update = _host.UpdateVersion;
            UpdateBanner.Visibility = update != null ? Visibility.Visible : Visibility.Collapsed;
            if (update != null)
            {
                double? progress = _host.UpdateProgress;
                TxtUpdate.Text = progress is double p ? $"Завантажую версію {update}… {p:P0}" : $"Доступна версія {update}";
                TxtUpdateAction.Text = progress != null ? string.Empty : "Оновити";
                BtnUpdate.IsEnabled = progress == null;
            }
            if (MicPopup.IsOpen)
            {
                BuildMicrophoneList(microphones);
            }
            if (ModelPopup.IsOpen)
            {
                BuildModelList();
            }
        }

        private static readonly (string Code, string Name, string? Detail)[] Languages =
        {
            ("uk", "Українська", null),
            ("en", "English", null),
            ("auto", "Автовизначення", "повільніше: спершу вгадує мову")
        };

        private static string LanguageName(string code) => Languages.FirstOrDefault(l => l.Code == code).Name ?? "Українська";

        private void BuildLanguageList()
        {
            LanguageList.Children.Clear();
            foreach (var (code, name, detail) in Languages)
            {
                var row = OptionRow(name, detail, code == _host.VoiceLanguage);
                row.Click += (_, _) =>
                {
                    _host.SetVoiceLanguage(code);
                    LanguagePopup.IsOpen = false;
                    Refresh();
                };
                LanguageList.Children.Add(row);
            }
        }

        private void BuildMicrophoneList(IReadOnlyList<MicrophoneInfo> microphones)
        {
            MicList.Children.Clear();
            foreach (var microphone in microphones)
            {
                bool isSelected = string.Equals(microphone.Name, _host.SelectedMicrophone, StringComparison.OrdinalIgnoreCase);
                var row = OptionRow(microphone.DisplayName, null, isSelected);
                row.Click += (_, _) =>
                {
                    _host.SelectMicrophone(microphone);
                    MicPopup.IsOpen = false;
                    Refresh();
                };
                MicList.Children.Add(row);
            }

            var listen = OptionRow("Прослухати останній запис", null, false, (Geometry)FindResource("Icon.Play"));
            listen.IsEnabled = _host.CanPlayLastRecording;
            listen.ToolTip = "Так звучить ваш голос для розпізнавання. Якщо глухо чи тихо — справа в мікрофоні або його підключенні.";
            listen.Click += (_, _) => _host.PlayLastRecording();
            MicList.Children.Add(listen);
        }

        private void BuildModelList()
        {
            ModelList.Children.Clear();
            foreach (var model in WhisperModels.All)
            {
                string detail = $"{model.SizeMb} МБ" + (model.NeedsGpu && !_host.GpuAvailable ? " · повільно без відеокарти" : string.Empty);
                var row = OptionRow(model.Title, detail, model == _host.SelectedModel);
                row.ToolTip = model.Hint;
                row.Click += (_, _) =>
                {
                    _host.SelectModel(model);
                    ModelPopup.IsOpen = false;
                    Refresh();
                };
                ModelList.Children.Add(row);
            }

            ModelList.Children.Add(new System.Windows.Shapes.Rectangle { Style = (Style)FindResource("Separator"), Margin = new Thickness(6, 4, 6, 4) });

            string gpuTitle = _host.GpuName != null ? $"Відеокарта · {_host.GpuName}" : "Використовувати відеокарту";
            var gpu = OptionRow(gpuTitle, null, _host.UseGpu, (Geometry)FindResource("Icon.Gpu"), showCheck: true);
            gpu.IsEnabled = _host.GpuAvailable || _host.UseGpu;
            gpu.Click += (_, _) =>
            {
                _host.SetUseGpu(!_host.UseGpu);
                Refresh();
            };
            ModelList.Children.Add(gpu);

            if (_host.Cuda != CudaOffer.Hidden)
            {
                (string text, string? detail2, bool enabled) = _host.Cuda switch
                {
                    CudaOffer.Active => ("Прискорення NVIDIA увімкнено", (string?)null, false),
                    CudaOffer.Downloading => ($"Завантажую прискорення… {_host.CudaProgress:P0}", null, false),
                    CudaOffer.NeedsRestart => ("Прискорення готове — перезапустити", "щоб розпізнавання стало швидшим", true),
                    _ => ("Прискорити для NVIDIA", $"≈{CudaPack.DownloadMegabytes} МБ один раз · «{WhisperModels.Large.Title}» удвічі швидше", true)
                };
                var cuda = OptionRow(text, detail2, _host.Cuda == CudaOffer.Active, (Geometry)FindResource("Icon.Spark"), showCheck: _host.Cuda == CudaOffer.Active);
                cuda.IsEnabled = enabled;
                cuda.Click += (_, _) =>
                {
                    _host.CudaAction();
                    Refresh();
                };
                ModelList.Children.Add(cuda);
            }
        }

        /// <summary>A choice inside an expanded list: a check (or an icon), a title and an optional second line.</summary>
        private Button OptionRow(string title, string? detail, bool isChecked, Geometry? icon = null, bool showCheck = false)
        {
            var mark = new GlyphIcon
            {
                Width = 15,
                Height = 15,
                Margin = new Thickness(0, detail == null ? 0 : 2, 9, 0),
                VerticalAlignment = detail == null ? VerticalAlignment.Center : VerticalAlignment.Top,
                StrokeThickness = 2.2
            };
            if (isChecked && (icon == null || showCheck))
            {
                mark.Data = (Geometry)FindResource("Icon.Check");
                mark.Foreground = (Brush)FindResource("AccentBrush");
            }
            else if (icon != null)
            {
                mark.Data = icon;
                mark.Foreground = (Brush)FindResource("MenuMuted");
                mark.StrokeThickness = 1.9;
            }

            var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            text.Children.Add(new TextBlock
            {
                Text = title,
                FontSize = 12.5,
                Foreground = isChecked ? Brushes.White : (Brush)FindResource("InkBrush"),
                FontWeight = isChecked ? FontWeights.SemiBold : FontWeights.Normal,
                TextTrimming = TextTrimming.CharacterEllipsis
            });
            if (detail != null)
            {
                text.Children.Add(new TextBlock
                {
                    Text = detail,
                    FontSize = 11.5,
                    Foreground = (Brush)FindResource("MenuMuted"),
                    TextTrimming = TextTrimming.CharacterEllipsis,
                    Margin = new Thickness(0, 1, 0, 0)
                });
            }

            var content = new DockPanel();
            content.Children.Add(mark);
            content.Children.Add(text);
            return new Button { Style = (Style)FindResource("Row"), Content = content, Padding = new Thickness(0) };
        }

        #endregion

        #region Actions

        private void Do(Action action)
        {
            CloseMenu();
            action();
        }

        private void OnCaptureClick(object sender, RoutedEventArgs e) => Do(_host.Capture);

        private void OnGalleryClick(object sender, RoutedEventArgs e) => Do(_host.OpenGallery);

        private void OnFolderClick(object sender, RoutedEventArgs e) => Do(_host.OpenScreenshotsFolder);

        private void OnMicrophoneToggle(object sender, RoutedEventArgs e) =>
            ToggleDropdown(MicPopup, MicRow, MicChevron, () => BuildMicrophoneList(_host.GetMicrophones()));

        private void OnLanguageToggle(object sender, RoutedEventArgs e) =>
            ToggleDropdown(LanguagePopup, LanguageRow, LanguageChevron, BuildLanguageList);

        private void OnModelToggle(object sender, RoutedEventArgs e) =>
            ToggleDropdown(ModelPopup, ModelRow, ModelChevron, BuildModelList);

        private Popup? _lastClosed;
        private DateTime _lastClosedAt;

        /// <summary>
        /// Opens a dropdown under its row, over the rest of the menu (it flips above the row near the screen edge).
        /// A click on the row of an open list closes it: the popup already closed itself on that mouse-down.
        /// </summary>
        private void ToggleDropdown(Popup popup, Button row, GlyphIcon chevron, Action build)
        {
            bool justClosed = _lastClosed == popup && (DateTime.UtcNow - _lastClosedAt).TotalMilliseconds < 300;
            CloseDropdowns();
            if (justClosed)
            {
                return;
            }
            build();
            popup.Width = row.ActualWidth + 20;
            popup.IsOpen = true;
            chevron.RenderTransformOrigin = new Point(0.5, 0.5);
            chevron.RenderTransform = new RotateTransform(180);
        }

        private void CloseDropdowns()
        {
            MicPopup.IsOpen = false;
            LanguagePopup.IsOpen = false;
            ModelPopup.IsOpen = false;
        }

        private void OnDropdownClosed(object? sender, EventArgs e)
        {
            _lastClosed = sender as Popup;
            _lastClosedAt = DateTime.UtcNow;
            GlyphIcon chevron = sender == MicPopup ? MicChevron : sender == LanguagePopup ? LanguageChevron : ModelChevron;
            chevron.RenderTransform = null;
        }

        private void OnHotkeyClick(object sender, RoutedEventArgs e) => Do(_host.OpenHotkeySettings);

        private void OnAutostartClick(object sender, RoutedEventArgs e)
        {
            _host.SetAutostart(!_host.AutostartEnabled);
            Refresh();
        }

        private void OnAboutClick(object sender, RoutedEventArgs e) =>
            AboutWell.Visibility = AboutWell.Visibility == Visibility.Visible ? Visibility.Collapsed : Visibility.Visible;

        private void OnOpenLogClick(object sender, RoutedEventArgs e) => Do(_host.OpenLog);

        private void OnOpenModelsClick(object sender, RoutedEventArgs e) => Do(_host.OpenModelsFolder);

        private void OnExitClick(object sender, RoutedEventArgs e) => Do(_host.Exit);

        private void OnUpdateClick(object sender, RoutedEventArgs e) => _host.InstallUpdate(); // the menu shows the download

        private void OnCheckUpdatesClick(object sender, RoutedEventArgs e) => _host.CheckForUpdates();

        #endregion

        private static string ShortName(string name)
        {
            // "Microphone (High Definition Audio Device)" → "High Definition Audio Device"
            int open = name.IndexOf('(');
            int close = name.LastIndexOf(')');
            return open >= 0 && close > open + 1 ? name[(open + 1)..close] : name;
        }

        private static string Plural(int n, string one, string few, string many)
        {
            int mod10 = n % 10, mod100 = n % 100;
            string word = mod10 == 1 && mod100 != 11 ? one : mod10 is >= 2 and <= 4 && mod100 is < 12 or > 14 ? few : many;
            return $"{n} {word}";
        }

        private static Brush Frozen(byte r, byte g, byte b)
        {
            var brush = new SolidColorBrush(Color.FromRgb(r, g, b));
            brush.Freeze();
            return brush;
        }

        private static Brush FrozenArgb(byte a, byte r, byte g, byte b)
        {
            var brush = new SolidColorBrush(Color.FromArgb(a, r, g, b));
            brush.Freeze();
            return brush;
        }
    }
}
