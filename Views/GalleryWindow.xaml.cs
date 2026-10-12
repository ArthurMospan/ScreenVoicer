using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using ScreenVoicer.Models;
using ScreenVoicer.Native;
using ScreenVoicer.Services;

namespace ScreenVoicer.Views
{
    public partial class GalleryWindow : Window
    {
        private const int ThumbnailDecodeWidth = 640; // 2x the card width, crisp on high-DPI screens

        private readonly IHistoryService _historyService;
        private readonly IClipboardService _clipboardService;
        private readonly ISettingsService _settingsService;
        private readonly Action _startCapture;
        private readonly Func<IReadOnlyList<ScreenshotHistoryItem>, Task<ShareResult?>>? _share;
        private readonly Func<ScreenshotHistoryItem, Task<bool>>? _unshare;
        private bool _sharing;

        // Decoded thumbnails survive refreshes and filtering; keyed by path + last write time.
        private readonly ConcurrentDictionary<string, BitmapSource> _thumbnailCache = new();
        private readonly SemaphoreSlim _decodeSlots = new(2, 2);
        private readonly DispatcherTimer _searchDebounce;
        private List<GalleryItem> _allItems = new();
        private int _loadVersion;
        private Point? _dragStart;

        public GalleryWindow(
            IHistoryService historyService,
            IClipboardService clipboardService,
            ISettingsService settingsService,
            Action startCapture,
            Func<IReadOnlyList<ScreenshotHistoryItem>, Task<ShareResult?>>? share = null,
            Func<ScreenshotHistoryItem, Task<bool>>? unshare = null)
        {
            InitializeComponent();
            SourceInitialized += (_, _) => User32.UseDarkTitleBar(new WindowInteropHelper(this).Handle, Color.FromRgb(0x0F, 0x0F, 0x13));
            _historyService = historyService;
            _clipboardService = clipboardService;
            _settingsService = settingsService;
            _startCapture = startCapture;
            _share = share;
            _unshare = unshare;

            _searchDebounce = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(150) };
            _searchDebounce.Tick += (_, _) =>
            {
                _searchDebounce.Stop();
                ApplyFilter();
            };

            // New screenshots show up immediately while the gallery is open.
            _historyService.Changed += OnHistoryChanged;
            Closed += (_, _) => _historyService.Changed -= OnHistoryChanged;
            Loaded += async (_, _) => await LoadDataAsync();
        }

        public void BringToFront()
        {
            if (!IsVisible)
            {
                Show();
            }
            if (WindowState == WindowState.Minimized)
            {
                WindowState = WindowState.Normal;
            }
            Activate();
            User32.ForceForeground(new WindowInteropHelper(this).Handle);
        }

        private void OnHistoryChanged(object? sender, EventArgs e) => Dispatcher.BeginInvoke(async () => await LoadDataAsync());

        public async Task LoadDataAsync()
        {
            int version = ++_loadVersion;
            IReadOnlyList<ScreenshotHistoryItem> history;
            try
            {
                history = await _historyService.GetHistoryAsync();
            }
            catch (Exception ex)
            {
                Log.Error("[Gallery] Could not load history", ex);
                ShowSnackbar("Не вдалося прочитати історію");
                return;
            }

            if (version != _loadVersion)
            {
                return; // a newer refresh is already running
            }

            var previous = _allItems.ToDictionary(x => x.Model.Id);
            _allItems = history.Select(item => previous.TryGetValue(item.Id, out var existing) ? existing.Update(item) : new GalleryItem(item)).ToList();
            ApplyFilter();
        }

        private void ApplyFilter()
        {
            string query = TbSearch.Text.Trim();
            var filtered = query.Length == 0
                ? _allItems
                : _allItems.Where(x => x.Matches(query)).ToList();

            ItemsGallery.ItemsSource = filtered;
            foreach (var item in filtered)
            {
                _ = EnsureThumbnailAsync(item);
            }

            TxtTotalCount.Text = query.Length == 0
                ? Plural(_allItems.Count, "скриншот", "скриншоти", "скриншотів")
                : $"Знайдено {filtered.Count} з {_allItems.Count}";

            bool empty = filtered.Count == 0;
            PanelEmptyState.Visibility = empty ? Visibility.Visible : Visibility.Collapsed;
            if (empty)
            {
                bool searching = _allItems.Count > 0;
                TxtEmptyTitle.Text = searching ? $"Нічого не знайдено за «{query}»" : "Ще немає скриншотів";
                TxtEmptyHint.Text = searching
                    ? "Спробуйте інше слово з коментаря або дату у форматі 09.10.2026."
                    : $"Натисніть {App.HotkeyText} у будь-якій програмі, виділіть область, затисніть Пробіл і розкажіть, що не так.";
                BtnEmptyCapture.Visibility = searching ? Visibility.Collapsed : Visibility.Visible;
            }
        }

        private async Task EnsureThumbnailAsync(GalleryItem item)
        {
            if (item.Thumbnail != null)
            {
                return;
            }

            string path = item.Model.ImagePath;
            string key;
            try
            {
                key = path + "|" + File.GetLastWriteTimeUtc(path).Ticks;
            }
            catch
            {
                return;
            }

            if (_thumbnailCache.TryGetValue(key, out var cached))
            {
                item.Thumbnail = cached;
                return;
            }

            await _decodeSlots.WaitAsync();
            try
            {
                var thumbnail = await Task.Run(() => DecodeThumbnail(path));
                if (thumbnail != null)
                {
                    _thumbnailCache[key] = thumbnail;
                    item.Thumbnail = thumbnail;
                }
            }
            finally
            {
                _decodeSlots.Release();
            }
        }

        /// <summary>
        /// Decodes a small, frozen copy and closes the file right away. The old XAML binding loaded every
        /// screenshot at full resolution and kept the files locked, so "Delete" could not remove them.
        /// </summary>
        private static BitmapSource? DecodeThumbnail(string path)
        {
            try
            {
                using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                var bitmap = new BitmapImage();
                bitmap.BeginInit();
                bitmap.CacheOption = BitmapCacheOption.OnLoad;
                bitmap.CreateOptions = BitmapCreateOptions.IgnoreColorProfile;
                bitmap.DecodePixelWidth = ThumbnailDecodeWidth;
                bitmap.StreamSource = stream;
                bitmap.EndInit();
                bitmap.Freeze();
                return bitmap;
            }
            catch (Exception ex)
            {
                Log.Warn($"[Gallery] Thumbnail failed for '{path}'", ex);
                return null;
            }
        }

        #region Header actions

        private void OnSearchTextChanged(object sender, TextChangedEventArgs e)
        {
            TxtSearchPlaceholder.Visibility = TbSearch.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
            _searchDebounce.Stop();
            _searchDebounce.Start();
        }

        private void OnNewCaptureClick(object sender, RoutedEventArgs e) => _startCapture();

        private void OnOpenFolderClick(object sender, RoutedEventArgs e)
        {
            string folder = _settingsService.OutputDirectory;
            try
            {
                Directory.CreateDirectory(folder);
                Process.Start(new ProcessStartInfo { FileName = folder, UseShellExecute = true });
            }
            catch (Exception ex)
            {
                Log.Warn($"[Gallery] Could not open '{folder}'", ex);
                ShowSnackbar("Не вдалося відкрити папку");
            }
        }

        protected override void OnPreviewKeyDown(KeyEventArgs e)
        {
            base.OnPreviewKeyDown(e);
            if (e.Key == Key.F && (Keyboard.Modifiers & ModifierKeys.Control) != 0)
            {
                TbSearch.Focus();
                TbSearch.SelectAll();
                e.Handled = true;
            }
            else if (e.Key == Key.Escape)
            {
                if (TbSearch.Text.Length > 0)
                {
                    TbSearch.Clear();
                }
                else
                {
                    Close();
                }
                e.Handled = true;
            }
        }

        #endregion

        #region Card actions

        private static GalleryItem? ItemOf(object sender) => (sender as FrameworkElement)?.DataContext as GalleryItem;

        private void OnThumbMouseDown(object sender, MouseButtonEventArgs e) => _dragStart = e.GetPosition(this);

        private void OnThumbMouseMove(object sender, MouseEventArgs e)
        {
            if (_dragStart is not Point start || e.LeftButton != MouseButtonState.Pressed || ItemOf(sender) is not { } item)
            {
                return;
            }

            var delta = e.GetPosition(this) - start;
            if (Math.Abs(delta.X) < SystemParameters.MinimumHorizontalDragDistance &&
                Math.Abs(delta.Y) < SystemParameters.MinimumVerticalDragDistance)
            {
                return;
            }

            _dragStart = null;
            if (File.Exists(item.Model.ImagePath))
            {
                // Drop the PNG straight into Slack/Telegram/Jira/a browser chat.
                var data = new DataObject(DataFormats.FileDrop, new[] { item.Model.ImagePath });
                DragDrop.DoDragDrop((DependencyObject)sender, data, DragDropEffects.Copy);
            }
        }

        private void OnThumbMouseUp(object sender, MouseButtonEventArgs e)
        {
            if (_dragStart != null && ItemOf(sender) is { } item)
            {
                OpenFile(item.Model.ImagePath);
            }
            _dragStart = null;
        }

        private void OnOpenFileClick(object sender, RoutedEventArgs e)
        {
            if (ItemOf(sender) is { } item)
            {
                OpenFile(item.Model.ImagePath);
            }
        }

        private void OpenFile(string path)
        {
            try
            {
                Process.Start(new ProcessStartInfo { FileName = path, UseShellExecute = true });
            }
            catch (Exception ex)
            {
                Log.Warn($"[Gallery] Could not open '{path}'", ex);
                ShowSnackbar("Не вдалося відкрити файл");
            }
        }

        private void OnShowInFolderClick(object sender, RoutedEventArgs e)
        {
            if (ItemOf(sender) is not { } item)
            {
                return;
            }

            try
            {
                Process.Start(new ProcessStartInfo
                {
                    FileName = "explorer.exe",
                    Arguments = $"/select,\"{item.Model.ImagePath}\"",
                    UseShellExecute = true
                });
            }
            catch (Exception ex)
            {
                Log.Warn("[Gallery] Could not open Explorer", ex);
            }
        }

        private void OnCopyMarkdownClick(object sender, RoutedEventArgs e)
        {
            if (ItemOf(sender) is not { } item)
            {
                return;
            }

            string markdown = _clipboardService.FormatMarkdown(item.Model.ImagePath, item.Model.TranscribedText);
            ShowSnackbar(_clipboardService.CopyToClipboard(markdown, item.Model.ImagePath)
                ? "✓ Markdown і картинку скопійовано"
                : "Буфер обміну зайнятий іншою програмою — спробуйте ще раз");
        }

        private void OnCopyTextClick(object sender, RoutedEventArgs e)
        {
            if (ItemOf(sender) is { } item && item.Model.HasVoiceComment)
            {
                ShowSnackbar(_clipboardService.CopyToClipboard(item.Model.TranscribedText)
                    ? "✓ Текст коментаря скопійовано"
                    : "Буфер обміну зайнятий іншою програмою — спробуйте ще раз");
            }
        }

        private async void OnDeleteClick(object sender, RoutedEventArgs e)
        {
            if (ItemOf(sender) is not { } item)
            {
                return;
            }

            var answer = MessageBox.Show(this, "Видалити цей скриншот разом із файлом?", "Видалення",
                MessageBoxButton.YesNo, MessageBoxImage.Question, MessageBoxResult.No);
            if (answer != MessageBoxResult.Yes)
            {
                return;
            }

            try
            {
                await _historyService.DeleteEntryAsync(item.Model.Id);
                ShowSnackbar("Скриншот видалено");
            }
            catch (Exception ex)
            {
                Log.Warn($"[Gallery] Could not delete '{item.Model.ImagePath}'", ex);
                ShowSnackbar("Не вдалося видалити файл — можливо, він відкритий в іншій програмі");
            }
        }

        #endregion

        #region Share links

        private static readonly System.Globalization.CultureInfo Ukrainian = new("uk-UA");

        private void OnSelectClick(object sender, RoutedEventArgs e) => UpdateSelectionBar();

        private void UpdateSelectionBar()
        {
            int count = _allItems.Count(i => i.IsSelected);
            SelectionBar.Visibility = count > 0 ? Visibility.Visible : Visibility.Collapsed;
            TxtSelection.Text = count > ShareService.MaxImages
                ? $"Вибрано {count} — для посилання не більше {ShareService.MaxImages}"
                : $"Вибрано: {Plural(count, "знімок", "знімки", "знімків")}";
            BtnShareSelected.IsEnabled = count is > 0 and <= ShareService.MaxImages && !_sharing;
        }

        private void OnClearSelectionClick(object sender, RoutedEventArgs e)
        {
            foreach (var item in _allItems)
            {
                item.IsSelected = false;
            }
            UpdateSelectionBar();
        }

        private async void OnShareSelectedClick(object sender, RoutedEventArgs e)
        {
            var selected = _allItems.Where(i => i.IsSelected).Select(i => i.Model).ToList();
            if (await CreateLinkAsync(selected))
            {
                OnClearSelectionClick(sender, e);
            }
        }

        /// <summary>The link button on a card: copies the existing link, or creates one for this screenshot.</summary>
        private async void OnShareItemClick(object sender, RoutedEventArgs e)
        {
            if (ItemOf(sender) is not { } item)
            {
                return;
            }
            if (item.Model.HasActiveShare)
            {
                CopyLink(item.Model);
                return;
            }
            await CreateLinkAsync(new[] { item.Model });
        }

        private void OnCopyShareClick(object sender, RoutedEventArgs e)
        {
            if (ItemOf(sender) is { } item && item.Model.HasActiveShare)
            {
                CopyLink(item.Model);
            }
        }

        private async void OnDeleteShareClick(object sender, RoutedEventArgs e)
        {
            if (ItemOf(sender) is not { } item || _unshare == null)
            {
                return;
            }
            if (await _unshare(item.Model))
            {
                ShowSnackbar("Посилання видалено — за ним більше нічого не відкриється");
            }
        }

        private void CopyLink(ScreenshotHistoryItem item)
        {
            ShowSnackbar(_clipboardService.CopyToClipboard(item.ShareUrl!)
                ? $"Посилання скопійовано · діє до {item.ShareExpiresAt!.Value.ToString("d MMMM", Ukrainian)}"
                : "Буфер обміну зайнятий іншою програмою");
        }

        private async Task<bool> CreateLinkAsync(IReadOnlyList<ScreenshotHistoryItem> items)
        {
            if (_share == null || _sharing || items.Count == 0)
            {
                return false;
            }

            _sharing = true;
            UpdateSelectionBar();
            ShowSnackbar(items.Count > 1 ? $"Завантажую {items.Count} знімки…" : "Створюю посилання…");
            try
            {
                var share = await _share(items);
                if (share == null)
                {
                    return false; // the app already explained what went wrong
                }
                ShowSnackbar($"Посилання скопійовано · діє до {share.ExpiresAt.ToString("d MMMM", Ukrainian)}");
                return true;
            }
            finally
            {
                _sharing = false;
                UpdateSelectionBar();
            }
        }

        #endregion

        private void ShowSnackbar(string text)
        {
            TxtSnackbar.Text = text;
            Snackbar.Margin = new Thickness(0, 0, 0, SelectionBar.Visibility == Visibility.Visible ? 96 : 22);
            var animation = new DoubleAnimationUsingKeyFrames();
            animation.KeyFrames.Add(new LinearDoubleKeyFrame(1, KeyTime.FromTimeSpan(TimeSpan.FromMilliseconds(150))));
            animation.KeyFrames.Add(new LinearDoubleKeyFrame(1, KeyTime.FromTimeSpan(TimeSpan.FromMilliseconds(1900))));
            animation.KeyFrames.Add(new LinearDoubleKeyFrame(0, KeyTime.FromTimeSpan(TimeSpan.FromMilliseconds(2200))));
            Snackbar.BeginAnimation(OpacityProperty, animation);
        }

        private static string Plural(int n, string one, string few, string many)
        {
            int mod10 = n % 10, mod100 = n % 100;
            string word = mod10 == 1 && mod100 != 11 ? one
                : mod10 is >= 2 and <= 4 && mod100 is < 12 or > 14 ? few
                : many;
            return $"{n} {word}";
        }

        /// <summary>Card view model; the thumbnail arrives asynchronously.</summary>
        private sealed class GalleryItem : INotifyPropertyChanged
        {
            private static readonly Brush CommentInk = Freeze(new SolidColorBrush(Color.FromRgb(0xE6, 0xE6, 0xEC)));
            private static readonly Brush CommentMuted = Freeze(new SolidColorBrush(Color.FromRgb(0x6B, 0x6B, 0x78)));
            private BitmapSource? _thumbnail;

            public GalleryItem(ScreenshotHistoryItem model)
            {
                Model = model;
            }

            public event PropertyChangedEventHandler? PropertyChanged;

            public ScreenshotHistoryItem Model { get; private set; }

            public BitmapSource? Thumbnail
            {
                get => _thumbnail;
                set
                {
                    _thumbnail = value;
                    PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Thumbnail)));
                }
            }

            public string CommentText => Model.HasVoiceComment ? Model.TranscribedText : "Без коментаря";
            public Brush CommentBrush => Model.HasVoiceComment ? CommentInk : CommentMuted;
            public Visibility TextButtonVisibility => Model.HasVoiceComment ? Visibility.Visible : Visibility.Collapsed;

            private bool _isSelected;

            /// <summary>Picked for a link with several screenshots; survives gallery refreshes.</summary>
            public bool IsSelected
            {
                get => _isSelected;
                set
                {
                    if (_isSelected != value)
                    {
                        _isSelected = value;
                        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(IsSelected)));
                    }
                }
            }

            public Visibility ShareVisibility => Model.HasActiveShare ? Visibility.Visible : Visibility.Collapsed;
            public string ShareText => Model.ShareExpiresAt is DateTime until ? $"до {until.ToString("d MMM", new System.Globalization.CultureInfo("uk-UA"))}" : string.Empty;
            public string? ShareUrlTip => Model.ShareUrl != null ? $"Копіювати посилання\n{Model.ShareUrl}" : null;
            public string ShareButtonTip => Model.HasActiveShare ? "Копіювати посилання на цей знімок" : "Створити посилання на цей знімок (діє 30 днів)";
            public string DateText => Model.DisplayDate;
            public string SizeText => Model.Width > 0 && Model.Height > 0 ? $"{Model.Width}×{Model.Height}" : FormatSize(Model.FileSizeBytes);

            public GalleryItem Update(ScreenshotHistoryItem model)
            {
                Model = model;
                return this;
            }

            public bool Matches(string query) =>
                Model.TranscribedText.Contains(query, StringComparison.CurrentCultureIgnoreCase) ||
                Model.DisplayDate.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                Path.GetFileName(Model.ImagePath).Contains(query, StringComparison.OrdinalIgnoreCase);

            private static string FormatSize(long bytes) =>
                bytes <= 0 ? "PNG" : bytes < 1024 * 1024 ? $"{bytes / 1024} КБ" : $"{bytes / 1048576.0:F1} МБ";

            private static Brush Freeze(Brush brush)
            {
                brush.Freeze();
                return brush;
            }
        }
    }
}
