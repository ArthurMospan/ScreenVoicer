using System;
using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using ScreenVoicer.Services;

namespace ScreenVoicer.Views
{
    public partial class ToastWindow : Window
    {
        private static readonly Duration ShowDuration = new(TimeSpan.FromMilliseconds(220));
        private static readonly IEasingFunction Ease = new CubicEase { EasingMode = EasingMode.EaseOut };

        private readonly ToastOptions _options;
        private readonly Func<string, string?, bool> _copy;
        private readonly Storyboard _lifetime = new();
        private bool _shown;
        private bool _closing;

        /// <param name="copy">Copies (text, optional image path) to the clipboard, returns success.</param>
        public ToastWindow(ToastOptions options, Func<string, string?, bool> copy)
        {
            InitializeComponent();
            _options = options;
            _copy = copy;

            TxtTitle.Text = options.Title;
            TxtMessage.Text = options.Message;
            TxtMessage.Visibility = string.IsNullOrWhiteSpace(options.Message) ? Visibility.Collapsed : Visibility.Visible;
            ApplyKind(options.Kind);

            bool hasImage = !string.IsNullOrEmpty(options.ImagePath) && File.Exists(options.ImagePath);
            if (hasImage)
            {
                LoadThumbnail(options.ImagePath!);
                BtnOpenImage.Visibility = Visibility.Visible;
            }
            if (!string.IsNullOrEmpty(options.CopyText))
            {
                BtnCopy.Visibility = Visibility.Visible;
            }
            if (options.OnOpenGallery != null)
            {
                BtnOpenGallery.Visibility = Visibility.Visible;
            }
            if (options.OnAction != null && !string.IsNullOrEmpty(options.ActionText))
            {
                BtnAction.Content = options.ActionText;
                BtnAction.Visibility = Visibility.Visible;
            }
            if (hasImage || BtnCopy.Visibility == Visibility.Visible ||
                BtnOpenGallery.Visibility == Visibility.Visible || BtnAction.Visibility == Visibility.Visible)
            {
                PanelActions.Visibility = Visibility.Visible;
            }

            var timeBar = new DoubleAnimation(1, 0, TimeSpan.FromMilliseconds(Math.Max(1500, options.DurationMs)));
            Storyboard.SetTarget(timeBar, TimeBar);
            Storyboard.SetTargetProperty(timeBar, new PropertyPath("RenderTransform.ScaleX"));
            _lifetime.Children.Add(timeBar);
            _lifetime.Completed += (_, _) => Dismiss();

            Loaded += (_, _) =>
            {
                IsHeightKnown = true;
                HeightKnown?.Invoke(this, EventArgs.Empty);
            };
        }

        /// <summary>Raised once the window has been laid out, so the stack can position it.</summary>
        public event EventHandler? HeightKnown;

        public bool IsHeightKnown { get; private set; }

        public void MoveTo(double left, double top, bool animate)
        {
            Left = left;
            if (!_shown)
            {
                _shown = true;
                Top = top;
                BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, ShowDuration));
                Slide.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(16, 0, ShowDuration) { EasingFunction = Ease });
                _lifetime.Begin(this, true);
                return;
            }

            if (animate && Math.Abs(Top - top) > 0.5)
            {
                BeginAnimation(TopProperty, new DoubleAnimation(top, TimeSpan.FromMilliseconds(180)) { EasingFunction = Ease });
            }
            else
            {
                BeginAnimation(TopProperty, null);
                Top = top;
            }
        }

        public void Dismiss()
        {
            if (_closing)
            {
                return;
            }
            _closing = true;
            _lifetime.Stop(this);

            var fade = new DoubleAnimation(0, TimeSpan.FromMilliseconds(180));
            fade.Completed += (_, _) => Close();
            BeginAnimation(OpacityProperty, fade);
        }

        public void CloseImmediately()
        {
            _closing = true;
            _lifetime.Stop(this);
            Close();
        }

        private void ApplyKind(ToastKind kind)
        {
            // Status toasts get a tinted glass badge with a line icon; plain info carries the logo.
            (string? icon, Color color) = kind switch
            {
                ToastKind.Success => ("Icon.Check", Color.FromRgb(0x4A, 0xDE, 0x80)),
                ToastKind.Warning => ("Icon.Alert", Color.FromRgb(0xFB, 0xBF, 0x24)),
                ToastKind.Error => ("Icon.Close", Color.FromRgb(0xF8, 0x71, 0x71)),
                _ => (null, Color.FromRgb(0xFF, 0x8A, 0x4C))
            };

            bool logo = icon == null;
            BadgeLogo.Visibility = logo ? Visibility.Visible : Visibility.Collapsed;
            IconBadge.Visibility = logo ? Visibility.Collapsed : Visibility.Visible;
            if (!logo)
            {
                BadgeIcon.Data = (Geometry)FindResource(icon!);
                BadgeIcon.Foreground = new SolidColorBrush(color);
                IconBadge.Background = new SolidColorBrush(Color.FromArgb(0x2E, color.R, color.G, color.B));
            }
        }

        private void LoadThumbnail(string path)
        {
            try
            {
                var bitmap = new BitmapImage();
                using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                {
                    bitmap.BeginInit();
                    bitmap.StreamSource = stream;
                    bitmap.DecodePixelWidth = 120;
                    bitmap.CacheOption = BitmapCacheOption.OnLoad; // don't keep the file locked
                    bitmap.EndInit();
                }
                bitmap.Freeze();

                ThumbBrush.ImageSource = bitmap;
                Thumb.Visibility = Visibility.Visible;
                IconBadge.Visibility = Visibility.Collapsed;
                BadgeLogo.Visibility = Visibility.Collapsed;
            }
            catch (Exception ex)
            {
                Log.Warn("[Toast] Thumbnail failed", ex);
            }
        }

        private void OnCardMouseEnter(object sender, MouseEventArgs e)
        {
            if (!_closing)
            {
                _lifetime.Pause(this);
            }
        }

        private void OnCardMouseLeave(object sender, MouseEventArgs e)
        {
            if (!_closing)
            {
                _lifetime.Resume(this);
            }
        }

        private void OnCloseClick(object sender, RoutedEventArgs e) => Dismiss();

        private void OnThumbClick(object sender, MouseButtonEventArgs e) => OpenImage();

        private void OnOpenImageClick(object sender, RoutedEventArgs e) => OpenImage();

        private void OpenImage()
        {
            if (!string.IsNullOrEmpty(_options.ImagePath) && File.Exists(_options.ImagePath))
            {
                try
                {
                    Process.Start(new ProcessStartInfo { FileName = _options.ImagePath, UseShellExecute = true });
                }
                catch (Exception ex)
                {
                    Log.Warn("[Toast] Could not open the image", ex);
                }
            }
            Dismiss();
        }

        private void OnCopyClick(object sender, RoutedEventArgs e)
        {
            if (!string.IsNullOrEmpty(_options.CopyText))
            {
                bool ok = _copy(_options.CopyText, _options.ImagePath);
                BtnCopy.Content = ok ? "✓ Скопійовано" : "Буфер зайнятий";
            }
        }

        private void OnActionClick(object sender, RoutedEventArgs e)
        {
            _options.OnAction?.Invoke();
            Dismiss();
        }

        private void OnOpenGalleryClick(object sender, RoutedEventArgs e)
        {
            _options.OnOpenGallery?.Invoke();
            Dismiss();
        }
    }
}
