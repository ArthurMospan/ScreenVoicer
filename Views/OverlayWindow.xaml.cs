using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Ink;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using ScreenVoicer.Models;
using ScreenVoicer.Native;
using ScreenVoicer.Services;
using CaptureMode = ScreenVoicer.Models.CaptureMode;
using Point = System.Windows.Point;

namespace ScreenVoicer.Views
{
    public partial class OverlayWindow : Window
    {
        private enum Tool { Pen, Highlighter, Arrow, Rectangle, Text, Marker, Blur, Eraser }

        private enum StatusKind { Idle, Recording, Busy, Success, Warning, Error }

        /// <summary>One undoable step: ink strokes, or a text label / numbered marker on the annotation layer.</summary>
        private abstract record Change;
        private sealed record StrokeChange(StrokeCollection Added, StrokeCollection Removed) : Change;
        private sealed record ElementChange(FrameworkElement Element, bool Added) : Change;
        private sealed record ElementMove(FrameworkElement Element, Point From, Point To) : Change;
        private sealed record LabelEdit(Border Label, string From, string To) : Change;

        /// <summary>Marks InkCanvas children that are annotations (label or numbered marker).</summary>
        private sealed record Annotation(bool IsMarker, int Number = 0, bool IsBlur = false);

        /// <summary>One push-to-talk fragment; consecutive fragments are appended to the comment in order.</summary>
        private sealed class VoiceChunk
        {
            public string Text = string.Empty;
            public bool IsFinal;
        }

        private static readonly double[] PenWidths = { 2.5, 4, 7 };
        private static readonly double[] HighlighterWidths = { 14, 22, 34 };
        private static readonly double[] LabelFontSizes = { 15, 20, 28 };
        private static readonly double[] MarkerSizes = { 24, 30, 40 };
        private static readonly double[] BlurBlocks = { 8, 12, 18 };
        private static readonly double[] ThicknessDotSizes = { 5, 8, 12 };
        private static readonly string[] ThicknessNames = { "тонка", "середня", "товста" };
        private static readonly TimeSpan MaxTake = TimeSpan.FromMinutes(3);

        /// <summary>
        /// Below this share of 1–4 kHz energy the voice is "through a pillow" (normal speech: 8–10 %,
        /// low-passed at 700 Hz: ~0.5 %, the take that came out as gibberish: 0.16 %).
        /// </summary>
        private const double MuffledShare = 0.015;

        // Colors for the dark glass panels
        private static readonly Brush InkBrush = Frozen(0xF4, 0xF4, 0xF5);
        private static readonly Brush PreviewBrush = Frozen(0xA1, 0xA1, 0xAA);
        private static readonly Brush GreenBrush = Frozen(0x4A, 0xDE, 0x80);
        private static readonly Brush AmberBrush = Frozen(0xFB, 0xBF, 0x24);
        private static readonly Brush RedBrush = Frozen(0xF8, 0x71, 0x71);
        private static readonly Brush IdleFill = Brushes.Transparent;

        private readonly ScreenCapture _capture;
        private readonly IAudioRecorderService _audio;
        private readonly ITranscriptionService _transcription;
        private readonly IImageCompositorService _compositor;
        private readonly IClipboardService _clipboard;
        private readonly INotificationService _notifications;
        private readonly IHistoryService _history;
        private readonly ISettingsService _settings;
        private readonly Action _openGallery;
        private readonly Action<int>? _startDelayedCapture;
        private readonly Action<ScreenshotHistoryItem>? _shareItem;

        private IntPtr _hwnd;
        private bool _revealed;
        private bool _closed;
        private bool _isSaving;

        // Region selection (DIPs relative to RootGrid)
        private CaptureMode _mode;
        private Rect? _selection;
        private Rect? _selectionBeforeDrag;
        private bool _isSelecting;
        private Point _dragStart;

        // Drawing
        private Tool _tool = Tool.Pen;
        private Color _color;
        private int _thickness = 1;
        private readonly Stack<Change> _undo = new();
        private readonly Stack<Change> _redo = new();
        private bool _suppressHistory;
        private Point? _shapeStart;
        private Image? _blurElement;
        private Stroke? _shapeStroke;

        // Text labels & numbered markers
        private Border? _editingLabel;
        private bool _editingIsNew;
        private string _editingOriginalText = string.Empty;
        private FrameworkElement? _dragElement;
        private Point _dragElementStart;
        private Point _dragElementOrigin;
        private bool _dragElementMoved;

        // Voice
        private bool _isRecording;
        private bool _recordingHandsFree;          // started by the mic button or a short Space tap
        private bool _spaceStopsRecording;         // the current Space press ended a hands-free take
        private DateTime _spaceHoldStarted;
        private (string Text, int Caret)? _textBeforeSpace;
        private int _recordingGeneration;
        private VoiceChunk? _currentChunk;
        private string _baseText = string.Empty;
        private readonly List<VoiceChunk> _chunks = new();
        private readonly List<Task> _pendingTranscriptions = new();
        private bool _updatingText;
        private float _displayLevel;
        private readonly Storyboard _pulse;

        public OverlayWindow(
            ScreenCapture capture,
            IAudioRecorderService audio,
            ITranscriptionService transcription,
            IImageCompositorService compositor,
            IClipboardService clipboard,
            INotificationService notifications,
            IHistoryService history,
            ISettingsService settings,
            Action openGallery,
            Action<int>? startDelayedCapture = null,
            Action<ScreenshotHistoryItem>? shareItem = null)
        {
            InitializeComponent();

            _capture = capture;
            _audio = audio;
            _transcription = transcription;
            _compositor = compositor;
            _clipboard = clipboard;
            _notifications = notifications;
            _history = history;
            _settings = settings;
            _openGallery = openGallery;
            _startDelayedCapture = startDelayedCapture;
            _shareItem = shareItem;
            BtnTimer.Visibility = startDelayedCapture != null ? Visibility.Visible : Visibility.Collapsed;
            _mode = settings.DefaultCaptureMode;
            _color = ((SolidColorBrush)((Button)SwatchPanel.Children[0]).Background).Color;
            _pulse = (Storyboard)Resources["PulseRecording"];

            // Rough placement in DIPs at the system DPI puts the window on the right monitor;
            // the exact physical bounds are applied in OnSourceInitialized.
            double scale = User32.SystemDpiScale;
            Left = capture.Bounds.Left / scale;
            Top = capture.Bounds.Top / scale;
            Width = capture.Bounds.Width / scale;
            Height = capture.Bounds.Height / scale;

            ImgScreenshot.Source = capture.Source;
            SetupGlass();
            SetupFlyouts();
            CreateHandles();

            InkDrawCanvas.Strokes.StrokesChanged += OnStrokesChanged;
            _audio.AudioLevelChanged += OnAudioLevelChanged;
            _transcription.StateChanged += OnModelStateChanged;

            ApplyTool(Tool.Pen);
            SelectColor(_color);
            UpdateThicknessButton();
            UpdateUndoButtons();
            ApplyMode(_mode);
            UpdateMicrophoneButton();
            UpdateIdleStatus();

            ContentRendered += (_, _) => Reveal();
            Closed += OnClosed;
        }

        #region Window placement & activation

        protected override void OnSourceInitialized(EventArgs e)
        {
            base.OnSourceInitialized(e);
            _hwnd = new WindowInteropHelper(this).Handle;

            // Stay invisible (cloaked) until the first frame is rendered: no black/white flash on open.
            User32.SetDwmAttribute(_hwnd, User32.DWMWA_CLOAK, 1);
            User32.SetDwmAttribute(_hwnd, User32.DWMWA_WINDOW_CORNER_PREFERENCE, User32.DWMWCP_DONOTROUND);
            HwndSource.FromHwnd(_hwnd)?.AddHook(WndProc);
            ApplyPhysicalBounds();

            // Safety net in case ContentRendered never arrives.
            var reveal = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(700) };
            reveal.Tick += (_, _) =>
            {
                reveal.Stop();
                Reveal();
            };
            reveal.Start();
        }

        private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
        {
            if (msg == User32.WM_DPICHANGED)
            {
                // WPF resizes the window to the "suggested" rect for the new DPI; snap back to the exact monitor bounds.
                Dispatcher.BeginInvoke(ApplyPhysicalBounds);
            }
            return IntPtr.Zero;
        }

        /// <summary>Covers the captured monitor exactly, in physical pixels (correct on mixed-DPI setups).</summary>
        private void ApplyPhysicalBounds()
        {
            if (_hwnd == IntPtr.Zero || _closed)
            {
                return;
            }

            var b = _capture.Bounds;
            if (User32.GetWindowRect(_hwnd, out var current) &&
                current.Left == b.Left && current.Top == b.Top && current.Right == b.Right && current.Bottom == b.Bottom)
            {
                return;
            }
            User32.SetWindowPos(_hwnd, User32.HWND_TOPMOST, b.Left, b.Top, b.Width, b.Height, User32.SWP_NOACTIVATE);
        }

        private void Reveal()
        {
            if (_revealed || _closed)
            {
                return;
            }
            _revealed = true;
            ApplyPhysicalBounds();
            User32.SetDwmAttribute(_hwnd, User32.DWMWA_CLOAK, 0);
            BringToFront();
            Log.Info($"[Overlay] Shown, foreground={User32.GetForegroundWindow() == _hwnd}.");
        }

        public void BringToFront()
        {
            if (_closed || _isSaving)
            {
                return;
            }
            Activate();
            User32.ForceForeground(_hwnd);
            if (!TbComment.IsKeyboardFocusWithin)
            {
                Keyboard.Focus(RootGrid);
            }
        }

        /// <summary>DIP → physical pixel scale of the overlay.</summary>
        private double ScaleX => RootGrid.ActualWidth > 0 ? _capture.Bounds.Width / RootGrid.ActualWidth : 1.0;
        private double ScaleY => RootGrid.ActualHeight > 0 ? _capture.Bounds.Height / RootGrid.ActualHeight : 1.0;

        private void OnRootSizeChanged(object sender, SizeChangedEventArgs e)
        {
            DimOuter.Rect = new Rect(0, 0, RootGrid.ActualWidth, RootGrid.ActualHeight);
            UpdateSelectionVisuals();
            RepositionPanels();
        }

        #endregion

        #region Glass panels & flyouts

        private System.Windows.Media.Imaging.BitmapSource? _glassImage;
        private readonly Dictionary<Border, ImageBrush> _glassBrushes = new();
        private readonly DispatcherTimer _flyoutTimer = new() { Interval = TimeSpan.FromMilliseconds(250) };
        private Button? _flyoutAnchor;
        private Border? _openFlyout;

        /// <summary>
        /// "Frosted glass" without a live blur: the screenshot is static, so a tiny averaged copy of it, stretched
        /// back under each panel (linear filtering), looks like a strong blur and costs nothing per frame.
        /// </summary>
        private void SetupGlass()
        {
            var source = _capture.Source;
            int width = 192, height = Math.Max(1, (int)Math.Round(192.0 * source.PixelHeight / source.PixelWidth));

            var visual = new DrawingVisual();
            RenderOptions.SetBitmapScalingMode(visual, BitmapScalingMode.HighQuality); // averages many pixels per sample
            using (var dc = visual.RenderOpen())
            {
                dc.DrawImage(source, new Rect(0, 0, width, height));
            }
            var small = new System.Windows.Media.Imaging.RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
            small.Render(visual);
            small.Freeze();
            _glassImage = small;

            foreach (var panel in new[] { Toolbar, StatusPill, HintBadge, ToolFlyout, ColorFlyout, TimerFlyout })
            {
                var brush = new ImageBrush(small) { ViewboxUnits = BrushMappingMode.Absolute, Stretch = Stretch.Fill };
                RenderOptions.SetBitmapScalingMode(brush, BitmapScalingMode.Linear);
                panel.Background = brush;
                _glassBrushes[panel] = brush;
            }

            RootGrid.LayoutUpdated += (_, _) => UpdateGlass();
        }

        /// <summary>Points each panel's brush at the part of the blurred screenshot that lies under the panel.</summary>
        private void UpdateGlass()
        {
            if (_glassImage == null || RootGrid.ActualWidth <= 0)
            {
                return;
            }

            double sx = _glassImage.Width / RootGrid.ActualWidth;
            double sy = _glassImage.Height / RootGrid.ActualHeight;
            foreach (var (panel, brush) in _glassBrushes)
            {
                if (!panel.IsVisible || panel.ActualWidth <= 0)
                {
                    continue;
                }

                var origin = panel.TranslatePoint(new Point(0, 0), RootGrid);
                var viewbox = new Rect(origin.X * sx, origin.Y * sy, panel.ActualWidth * sx, panel.ActualHeight * sy);
                if (brush.Viewbox != viewbox)
                {
                    brush.Viewbox = viewbox;
                }
            }
        }

        private void SetupFlyouts()
        {
            foreach (var (anchor, flyout) in new[] { (BtnTool, ToolFlyout), (BtnColor, ColorFlyout), (BtnTimer, TimerFlyout) })
            {
                anchor.MouseEnter += (_, _) => OpenFlyout(anchor, flyout);
                anchor.MouseLeave += (_, _) => RestartFlyoutTimer();
                flyout.MouseLeave += (_, _) => RestartFlyoutTimer();
            }

            _flyoutTimer.Tick += (_, _) =>
            {
                _flyoutTimer.Stop();
                if (_openFlyout != null && _flyoutAnchor != null && !_openFlyout.IsMouseOver && !_flyoutAnchor.IsMouseOver)
                {
                    CloseFlyout();
                }
            };
        }

        private void RestartFlyoutTimer()
        {
            _flyoutTimer.Stop();
            _flyoutTimer.Start();
        }

        private void OnToolAnchorClick(object sender, RoutedEventArgs e) => ToggleFlyout(BtnTool, ToolFlyout);

        private void OnColorAnchorClick(object sender, RoutedEventArgs e) => ToggleFlyout(BtnColor, ColorFlyout);

        private void OnTimerAnchorClick(object sender, RoutedEventArgs e) => ToggleFlyout(BtnTimer, TimerFlyout);

        /// <summary>
        /// Retake with a delay: the overlay goes away, the countdown runs, and a fresh screenshot opens in the same
        /// mode — time to open a menu, hover a tooltip or scroll the page.
        /// </summary>
        private void OnDelayClick(object sender, RoutedEventArgs e)
        {
            if (sender is not Button { Tag: string text } || !int.TryParse(text, out int seconds) || _startDelayedCapture == null || _isSaving)
            {
                return;
            }

            CloseFlyout();
            var start = _startDelayedCapture;
            Close();
            Dispatcher.BeginInvoke(() => start(seconds)); // after the app has seen this overlay close
        }

        private void ToggleFlyout(Button anchor, Border flyout)
        {
            if (_openFlyout == flyout)
            {
                CloseFlyout();
            }
            else
            {
                OpenFlyout(anchor, flyout);
            }
        }

        /// <summary>Shows the tool set / palette right under (or above, when the toolbar is at the bottom) its button.</summary>
        private void OpenFlyout(Button anchor, Border flyout)
        {
            if (_isSelecting || _isSaving)
            {
                return;
            }
            if (_openFlyout == flyout)
            {
                _flyoutTimer.Stop();
                return;
            }

            CloseFlyout();
            _flyoutAnchor = anchor;
            _openFlyout = flyout;
            flyout.Visibility = Visibility.Visible;
            flyout.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));

            var center = anchor.TranslatePoint(new Point(anchor.ActualWidth / 2, 0), FlyoutLayer);
            bool below = Toolbar.VerticalAlignment == VerticalAlignment.Top;
            double width = flyout.DesiredSize.Width, height = flyout.DesiredSize.Height;
            double x = Math.Clamp(center.X - width / 2, 8, Math.Max(8, RootGrid.ActualWidth - width - 8));
            double y = below ? center.Y + anchor.ActualHeight + 12 : center.Y - height - 12;
            Canvas.SetLeft(flyout, x);
            Canvas.SetTop(flyout, y);

            flyout.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(120)));
            UpdateGlass();
        }

        private void CloseFlyout()
        {
            _flyoutTimer.Stop();
            if (_openFlyout != null)
            {
                _openFlyout.Visibility = Visibility.Collapsed;
            }
            _openFlyout = null;
            _flyoutAnchor = null;
        }

        #endregion

        #region Capture mode & region selection

        private void OnModeRegionClick(object sender, RoutedEventArgs e) => SwitchMode(CaptureMode.RectangleRegion);

        private void OnModeFullClick(object sender, RoutedEventArgs e) => SwitchMode(CaptureMode.FullScreen);

        private void SwitchMode(CaptureMode mode)
        {
            if (mode == CaptureMode.RectangleRegion && _mode == CaptureMode.RectangleRegion)
            {
                _selection = null; // clicking "Область" again starts over
            }

            ApplyMode(mode);
            if (_settings.DefaultCaptureMode != mode)
            {
                _settings.DefaultCaptureMode = mode;
                _settings.Save();
            }
        }

        private void ApplyMode(CaptureMode mode)
        {
            _mode = mode;
            bool region = mode == CaptureMode.RectangleRegion;
            BtnModeRegion.Style = (Style)FindResource(region ? "ActiveButton" : "PillButton");
            BtnModeFull.Style = (Style)FindResource(region ? "PillButton" : "ActiveButton");
            SelectionCanvas.Visibility = region ? Visibility.Visible : Visibility.Collapsed;
            DimPath.Visibility = region ? Visibility.Visible : Visibility.Collapsed;
            UpdateSelectionVisuals();
            RepositionPanels();
        }

        /// <summary>Clicking the picture leaves the comment box, so Space records again instead of typing spaces.</summary>
        private void LeaveTextBox()
        {
            if (TbComment.IsKeyboardFocusWithin)
            {
                Keyboard.Focus(RootGrid);
            }
        }

        private void OnSelectionMouseDown(object sender, MouseButtonEventArgs e)
        {
            LeaveTextBox();
            if (_isSaving)
            {
                return;
            }

            var point = ClampToRoot(e.GetPosition(RootGrid));
            if (HitHandle(point) is int handle and >= 0)
            {
                BeginResize(handle, point, SelectionCanvas);
                e.Handled = true;
                return;
            }

            _isSelecting = true;
            _selectionBeforeDrag = _selection;
            _dragStart = point;
            _selection = new Rect(_dragStart, _dragStart);
            SelectionCanvas.CaptureMouse();
            SetPanelsFaded(true);
            UpdateSelectionVisuals();
            e.Handled = true;
        }

        private void OnSelectionMouseMove(object sender, MouseEventArgs e)
        {
            if (_resizeHandle >= 0)
            {
                UpdateResize(ClampToRoot(e.GetPosition(RootGrid)));
                return;
            }
            if (!_isSelecting)
            {
                SelectionCanvas.Cursor = HandleCursor(HitHandle(e.GetPosition(RootGrid))) ?? Cursors.Cross;
                return;
            }

            _selection = new Rect(_dragStart, ClampToRoot(e.GetPosition(RootGrid)));
            UpdateSelectionVisuals();
        }

        private void OnSelectionMouseUp(object sender, MouseButtonEventArgs e)
        {
            if (_resizeHandle >= 0)
            {
                EndResize();
            }
            else if (_isSelecting)
            {
                EndSelectionDrag(commit: true);
            }
        }

        private void OnSelectionLostCapture(object sender, MouseEventArgs e)
        {
            if (_resizeHandle >= 0)
            {
                EndResize();
            }
            else if (_isSelecting)
            {
                EndSelectionDrag(commit: true);
            }
        }

        private void EndSelectionDrag(bool commit)
        {
            _isSelecting = false;
            if (SelectionCanvas.IsMouseCaptured)
            {
                SelectionCanvas.ReleaseMouseCapture();
            }

            // A click without a real drag keeps the previous selection.
            if (!commit || _selection is not Rect r || r.Width < 8 || r.Height < 8)
            {
                _selection = _selectionBeforeDrag;
            }

            SetPanelsFaded(false);
            UpdateSelectionVisuals();
            RepositionPanels();
        }

        private Point ClampToRoot(Point p) =>
            new(Math.Clamp(p.X, 0, RootGrid.ActualWidth), Math.Clamp(p.Y, 0, RootGrid.ActualHeight));

        // ── Adjusting the region: eight small squares on the frame, drag one instead of selecting again ──

        private readonly System.Windows.Shapes.Rectangle[] _handles = new System.Windows.Shapes.Rectangle[8];
        private int _resizeHandle = -1;
        private Rect _resizeStartRect;
        private Point _resizeStartPoint;
        private UIElement? _resizeCaptureElement;
        private bool _handleHover;

        private void CreateHandles()
        {
            var layer = (Canvas)FrameLine.Parent;
            for (int i = 0; i < _handles.Length; i++)
            {
                _handles[i] = new System.Windows.Shapes.Rectangle
                {
                    Width = 8,
                    Height = 8,
                    RadiusX = 2,
                    RadiusY = 2,
                    Fill = Brushes.White,
                    Stroke = FrozenArgb(0x8C, 0, 0, 0),
                    StrokeThickness = 1,
                    Visibility = Visibility.Collapsed,
                    IsHitTestVisible = false
                };
                layer.Children.Add(_handles[i]);
            }
        }

        /// <summary>0 top-left, then clockwise: top, top-right, right, bottom-right, bottom, bottom-left, left.</summary>
        private static Point HandlePoint(Rect r, int i) => i switch
        {
            0 => r.TopLeft,
            1 => new Point(r.X + r.Width / 2, r.Y),
            2 => r.TopRight,
            3 => new Point(r.Right, r.Y + r.Height / 2),
            4 => r.BottomRight,
            5 => new Point(r.X + r.Width / 2, r.Bottom),
            6 => r.BottomLeft,
            _ => new Point(r.X, r.Y + r.Height / 2)
        };

        private int HitHandle(Point p)
        {
            if (_mode != CaptureMode.RectangleRegion || _isSelecting || _isSaving || _selection is not Rect r || r.Width < 8 || r.Height < 8)
            {
                return -1;
            }
            for (int i = 0; i < _handles.Length; i++)
            {
                var h = HandlePoint(r, i);
                if (Math.Abs(p.X - h.X) <= 7 && Math.Abs(p.Y - h.Y) <= 7)
                {
                    return i;
                }
            }
            return -1;
        }

        private static Cursor? HandleCursor(int handle) => handle switch
        {
            0 or 4 => Cursors.SizeNWSE,
            2 or 6 => Cursors.SizeNESW,
            1 or 5 => Cursors.SizeNS,
            3 or 7 => Cursors.SizeWE,
            _ => null
        };

        private void PlaceHandles(Rect r)
        {
            bool show = !_isSelecting && r.Width >= 8 && r.Height >= 8;
            for (int i = 0; i < _handles.Length; i++)
            {
                var p = HandlePoint(r, i);
                Canvas.SetLeft(_handles[i], p.X - 4);
                Canvas.SetTop(_handles[i], p.Y - 4);
                _handles[i].Visibility = show ? Visibility.Visible : Visibility.Collapsed;
            }
        }

        private void HideHandles()
        {
            foreach (var handle in _handles)
            {
                if (handle != null)
                {
                    handle.Visibility = Visibility.Collapsed;
                }
            }
        }

        private void BeginResize(int handle, Point point, UIElement captureElement)
        {
            CommitLabelEdit();
            _resizeHandle = handle;
            _resizeStartRect = _selection!.Value;
            _resizeStartPoint = point;
            _resizeCaptureElement = captureElement;
            captureElement.CaptureMouse();
            SetPanelsFaded(true);
        }

        private void UpdateResize(Point point)
        {
            double dx = point.X - _resizeStartPoint.X, dy = point.Y - _resizeStartPoint.Y;
            double left = _resizeStartRect.Left, top = _resizeStartRect.Top, right = _resizeStartRect.Right, bottom = _resizeStartRect.Bottom;
            if (_resizeHandle is 0 or 6 or 7) left += dx;
            if (_resizeHandle is 0 or 1 or 2) top += dy;
            if (_resizeHandle is 2 or 3 or 4) right += dx;
            if (_resizeHandle is 4 or 5 or 6) bottom += dy;
            // Rect(Point, Point) normalizes, so dragging an edge past the opposite one just flips the region
            _selection = new Rect(ClampToRoot(new Point(left, top)), ClampToRoot(new Point(right, bottom)));
            UpdateSelectionVisuals();
        }

        private void EndResize()
        {
            if (_resizeHandle < 0)
            {
                return;
            }
            _resizeHandle = -1;
            var element = _resizeCaptureElement;
            _resizeCaptureElement = null;
            if (element?.IsMouseCaptured == true)
            {
                element.ReleaseMouseCapture();
            }
            if (_selection is not Rect r || r.Width < 8 || r.Height < 8)
            {
                _selection = _resizeStartRect;
            }
            SetPanelsFaded(false);
            UpdateSelectionVisuals();
            RepositionPanels();
        }

        /// <summary>Over a handle the ink layer must not start a stroke: switch it off and show a resize cursor.</summary>
        private void UpdateHandleHover(Point p)
        {
            int handle = HitHandle(p);
            if (handle >= 0)
            {
                _handleHover = true;
                InkDrawCanvas.EditingMode = InkCanvasEditingMode.None;
                InkDrawCanvas.UseCustomCursor = true;
                InkDrawCanvas.Cursor = HandleCursor(handle);
            }
            else if (_handleHover)
            {
                _handleHover = false;
                ApplyEditingMode();
            }
        }

        private void UpdateSelectionVisuals()
        {
            bool region = _mode == CaptureMode.RectangleRegion;
            bool hasSelection = region && _selection is Rect s && s.Width >= 1 && s.Height >= 1;

            if (!region)
            {
                DimHole.Rect = Rect.Empty;
                FrameLine.Visibility = FrameShadow.Visibility = SizeBadge.Visibility = Visibility.Collapsed;
                HintBadge.Visibility = Visibility.Collapsed;
                InkDrawCanvas.Clip = null;
                InkDrawCanvas.Visibility = Visibility.Visible;
                HideHandles();
                return;
            }

            if (!hasSelection)
            {
                DimHole.Rect = Rect.Empty;
                FrameLine.Visibility = FrameShadow.Visibility = SizeBadge.Visibility = Visibility.Collapsed;
                HintBadge.Visibility = _isSelecting ? Visibility.Collapsed : Visibility.Visible;
                InkDrawCanvas.Visibility = Visibility.Collapsed;
                HideHandles();
                return;
            }

            var r = _selection!.Value;
            DimHole.Rect = r;
            HintBadge.Visibility = Visibility.Collapsed;
            PlaceHandles(r);

            foreach (var frame in new[] { FrameShadow, FrameLine })
            {
                double inflate = frame == FrameShadow ? 1 : 0;
                Canvas.SetLeft(frame, r.X - inflate);
                Canvas.SetTop(frame, r.Y - inflate);
                frame.Width = r.Width + inflate * 2;
                frame.Height = r.Height + inflate * 2;
                frame.Visibility = Visibility.Visible;
            }

            TxtSize.Text = $"{Math.Round(r.Width * ScaleX)} × {Math.Round(r.Height * ScaleY)}";
            SizeBadge.Visibility = Visibility.Visible;
            Canvas.SetLeft(SizeBadge, r.X);
            Canvas.SetTop(SizeBadge, r.Y >= 30 ? r.Y - 28 : r.Y + 6);

            // Ink is only accepted inside the selection; drags outside go to the selection canvas (new region).
            InkDrawCanvas.Clip = new RectangleGeometry(r);
            InkDrawCanvas.Visibility = Visibility.Visible;
        }

        private void SetPanelsFaded(bool faded)
        {
            if (faded)
            {
                CloseFlyout();
            }
            foreach (var panel in new FrameworkElement[] { Toolbar, StatusPill })
            {
                panel.IsHitTestVisible = !faded;
                panel.BeginAnimation(OpacityProperty, new DoubleAnimation(faded ? 0.12 : 1, TimeSpan.FromMilliseconds(faded ? 120 : 180)));
            }
        }

        private void OnToolbarSizeChanged(object sender, SizeChangedEventArgs e) => RepositionPanels();

        /// <summary>
        /// The bar sits at the top; it moves to the bottom only when the selected region would end up under it.
        /// The status pill hangs off the bar's inner side.
        /// </summary>
        private void RepositionPanels()
        {
            double width = RootGrid.ActualWidth, height = RootGrid.ActualHeight;
            if (width <= 0 || Toolbar.ActualHeight <= 0)
            {
                return;
            }

            const double edge = 16, gap = 8;
            bool atBottom = false;
            if (_mode == CaptureMode.RectangleRegion && _selection is Rect r && r.Width >= 8)
            {
                var topZone = new Rect((width - Toolbar.ActualWidth) / 2, 0, Toolbar.ActualWidth, edge + Toolbar.ActualHeight + 40);
                var bottomZone = new Rect(topZone.X, height - topZone.Height, topZone.Width, topZone.Height);
                atBottom = r.IntersectsWith(topZone) && !r.IntersectsWith(bottomZone);
            }

            var vertical = atBottom ? VerticalAlignment.Bottom : VerticalAlignment.Top;
            var barMargin = atBottom ? new Thickness(0, 0, 0, edge + 8) : new Thickness(0, edge, 0, 0);
            double pillOffset = (atBottom ? edge + 8 : edge) + Toolbar.ActualHeight + gap;
            var pillMargin = atBottom ? new Thickness(0, 0, 0, pillOffset) : new Thickness(0, pillOffset, 0, 0);

            if (Toolbar.VerticalAlignment != vertical || Toolbar.Margin != barMargin)
            {
                CloseFlyout(); // it was placed for the old position
                Toolbar.VerticalAlignment = vertical;
                Toolbar.Margin = barMargin;
            }
            StatusPill.VerticalAlignment = vertical;
            StatusPill.Margin = pillMargin;
        }

        private System.Drawing.Rectangle? GetCropPixels()
        {
            if (_mode != CaptureMode.RectangleRegion || _selection is not Rect r || r.Width < 8 || r.Height < 8)
            {
                return null; // full monitor
            }

            int x = (int)Math.Round(r.X * ScaleX);
            int y = (int)Math.Round(r.Y * ScaleY);
            int right = (int)Math.Round(r.Right * ScaleX);
            int bottom = (int)Math.Round(r.Bottom * ScaleY);
            return new System.Drawing.Rectangle(x, y, right - x, bottom - y);
        }

        #endregion

        #region Drawing tools

        private void OnToolClick(object sender, RoutedEventArgs e)
        {
            if (sender is Button { Tag: string name } && Enum.TryParse(name, out Tool tool))
            {
                ApplyTool(tool);
                CloseFlyout();
            }
        }

        private void ApplyTool(Tool tool)
        {
            if (tool != Tool.Text)
            {
                CommitLabelEdit();
            }

            _tool = tool;
            var active = (Style)FindResource("ActiveButton");
            var normal = (Style)FindResource("PillButton");
            BtnPen.Style = tool == Tool.Pen ? active : normal;
            BtnHighlighter.Style = tool == Tool.Highlighter ? active : normal;
            BtnArrow.Style = tool == Tool.Arrow ? active : normal;
            BtnRectangle.Style = tool == Tool.Rectangle ? active : normal;
            BtnText.Style = tool == Tool.Text ? active : normal;
            BtnMarker.Style = tool == Tool.Marker ? active : normal;
            BtnBlur.Style = tool == Tool.Blur ? active : normal;
            BtnEraser.Style = tool == Tool.Eraser ? active : normal;

            _handleHover = false;
            ApplyEditingMode();
            InkDrawCanvas.DefaultDrawingAttributes = CreateAttributes(tool);

            // The compact toolbar shows only the current tool; the rest live in the flyout.
            var source = tool switch
            {
                Tool.Pen => BtnPen,
                Tool.Highlighter => BtnHighlighter,
                Tool.Arrow => BtnArrow,
                Tool.Rectangle => BtnRectangle,
                Tool.Text => BtnText,
                Tool.Marker => BtnMarker,
                Tool.Blur => BtnBlur,
                _ => BtnEraser
            };
            ToolIconHost.Content = new GlyphIcon { Data = (source.Content as GlyphIcon)?.Data };
            BtnTool.ToolTip = $"{source.ToolTip} — наведіть, щоб обрати інший інструмент";
        }

        private void ApplyEditingMode()
        {
            InkDrawCanvas.EditingMode = _tool switch
            {
                Tool.Pen or Tool.Highlighter => InkCanvasEditingMode.Ink,
                Tool.Eraser => InkCanvasEditingMode.EraseByStroke,
                _ => InkCanvasEditingMode.None
            };
            InkDrawCanvas.UseCustomCursor = _tool != Tool.Eraser;
            InkDrawCanvas.Cursor = _tool == Tool.Text ? Cursors.IBeam : Cursors.Cross;
        }

        private DrawingAttributes CreateAttributes(Tool tool)
        {
            if (tool == Tool.Highlighter)
            {
                double size = HighlighterWidths[_thickness];
                return new DrawingAttributes
                {
                    Color = _color,
                    Width = size * 0.4, // chisel tip like a real marker
                    Height = size,
                    IsHighlighter = true,
                    StylusTip = StylusTip.Rectangle,
                    FitToCurve = false,
                    IgnorePressure = true
                };
            }

            double width = PenWidths[_thickness];
            return new DrawingAttributes
            {
                Color = _color,
                Width = width,
                Height = width,
                StylusTip = StylusTip.Ellipse,
                FitToCurve = tool == Tool.Pen,
                IgnorePressure = tool != Tool.Pen // keep pen pressure for tablets, shapes stay uniform
            };
        }

        private void OnSwatchClick(object sender, RoutedEventArgs e)
        {
            if (sender is Button { Background: SolidColorBrush brush })
            {
                SelectColor(brush.Color);
                CloseFlyout();
            }
        }

        private void SelectColor(Color color)
        {
            _color = color;
            foreach (Button swatch in SwatchPanel.Children)
            {
                swatch.Tag = ((SolidColorBrush)swatch.Background).Color == color ? "on" : null;
            }

            ColorDot.Fill = new SolidColorBrush(color);
            // On the dark glass a near-black dot would vanish: show the size dot in white then.
            ThicknessDot.Fill = new SolidColorBrush(color.R + color.G + color.B < 150 ? Colors.White : color);
            if (_editingLabel != null)
            {
                StyleLabel(_editingLabel, color, LabelFontSizes[_thickness]); // recolor the label being typed
                return;
            }
            ApplyTool(_tool == Tool.Eraser ? Tool.Pen : _tool);
        }

        private void OnThicknessClick(object sender, RoutedEventArgs e) => ChangeThickness(+1, wrap: true);

        private void ChangeThickness(int delta, bool wrap)
        {
            int next = _thickness + delta;
            _thickness = wrap ? (next + 3) % 3 : Math.Clamp(next, 0, 2);
            UpdateThicknessButton();
            InkDrawCanvas.DefaultDrawingAttributes = CreateAttributes(_tool);
        }

        private void UpdateThicknessButton()
        {
            ThicknessDot.Width = ThicknessDot.Height = ThicknessDotSizes[_thickness];
            BtnThickness.ToolTip = $"Товщина: {ThicknessNames[_thickness]} ([ і ] — змінити)";
        }

        private void OnInkMouseDown(object sender, MouseButtonEventArgs e)
        {
            if (_isSaving)
            {
                return;
            }

            var rootPoint = e.GetPosition(RootGrid);
            if (HitHandle(rootPoint) is int handle and >= 0)
            {
                BeginResize(handle, ClampToRoot(rootPoint), InkDrawCanvas);
                e.Handled = true;
                return;
            }

            var annotation = FindAnnotation(e.OriginalSource as DependencyObject);
            if (_editingLabel != null && annotation != _editingLabel)
            {
                CommitLabelEdit(); // clicking elsewhere finishes the label being typed
            }
            else if (annotation == null || annotation != _editingLabel)
            {
                LeaveTextBox();
            }

            var point = e.GetPosition(InkDrawCanvas);
            switch (_tool)
            {
                case Tool.Eraser when annotation != null:
                    RemoveAnnotation(annotation);
                    e.Handled = true;
                    return;

                case Tool.Text or Tool.Marker when annotation is { Tag: Annotation { IsBlur: false } }:
                    if (annotation == _editingLabel)
                    {
                        return; // let the text box place the caret
                    }
                    if (e.ClickCount == 2 && annotation is Border label)
                    {
                        BeginEditLabel(label, isNew: false);
                    }
                    else
                    {
                        BeginDragAnnotation(annotation, point);
                    }
                    e.Handled = true;
                    return;

                case Tool.Text:
                    AddLabel(point);
                    e.Handled = true;
                    return;

                case Tool.Marker:
                    AddMarker(point);
                    e.Handled = true;
                    return;

                case Tool.Arrow or Tool.Rectangle:
                    _shapeStart = point;
                    _shapeStroke = null;
                    InkDrawCanvas.CaptureMouse();
                    e.Handled = true;
                    return;

                case Tool.Blur:
                    _shapeStart = point;
                    _blurElement = null;
                    InkDrawCanvas.CaptureMouse();
                    e.Handled = true;
                    return;
            }
        }

        private void OnInkMouseMove(object sender, MouseEventArgs e)
        {
            if (_resizeHandle >= 0)
            {
                UpdateResize(ClampToRoot(e.GetPosition(RootGrid)));
                return;
            }
            if (e.LeftButton != MouseButtonState.Pressed)
            {
                UpdateHandleHover(e.GetPosition(RootGrid));
            }

            if (_dragElement != null)
            {
                var delta = e.GetPosition(InkDrawCanvas) - _dragElementStart;
                if (!_dragElementMoved && Math.Abs(delta.X) + Math.Abs(delta.Y) < 3)
                {
                    return;
                }
                _dragElementMoved = true;
                SetPosition(_dragElement, _dragElementOrigin + delta);
                return;
            }

            if (_tool == Tool.Blur)
            {
                if (_shapeStart is Point blurStart && InkDrawCanvas.IsMouseCaptured)
                {
                    UpdateBlur(new Rect(blurStart, e.GetPosition(InkDrawCanvas)));
                }
                return;
            }

            if (_shapeStart is not Point start || !InkDrawCanvas.IsMouseCaptured)
            {
                return;
            }

            var end = e.GetPosition(InkDrawCanvas);
            if ((Keyboard.Modifiers & ModifierKeys.Shift) != 0)
            {
                end = Constrain(start, end);
            }

            var points = _tool == Tool.Arrow ? ArrowPoints(start, end) : RectanglePoints(start, end);
            if (points == null)
            {
                return;
            }

            // The live preview stroke is not an undo step; the finished shape is recorded on mouse up.
            _suppressHistory = true;
            try
            {
                if (_shapeStroke == null)
                {
                    _shapeStroke = new Stroke(points, CreateAttributes(_tool));
                    InkDrawCanvas.Strokes.Add(_shapeStroke);
                }
                else
                {
                    _shapeStroke.StylusPoints = points;
                }
            }
            finally
            {
                _suppressHistory = false;
            }
        }

        private void OnInkMouseUp(object sender, MouseButtonEventArgs e)
        {
            if (_resizeHandle >= 0)
            {
                EndResize();
                e.Handled = true;
                return;
            }

            if (_tool == Tool.Blur && _shapeStart != null)
            {
                _shapeStart = null;
                InkDrawCanvas.ReleaseMouseCapture();
                if (_blurElement != null)
                {
                    PushHistory(new ElementChange(_blurElement, Added: true));
                }
                _blurElement = null;
                e.Handled = true;
                return;
            }

            if (_dragElement != null)
            {
                var element = _dragElement;
                _dragElement = null;
                InkDrawCanvas.ReleaseMouseCapture();
                if (_dragElementMoved)
                {
                    PushHistory(new ElementMove(element, _dragElementOrigin, GetPosition(element)));
                }
                e.Handled = true;
                return;
            }

            if (_shapeStart == null)
            {
                return;
            }

            _shapeStart = null;
            InkDrawCanvas.ReleaseMouseCapture();
            if (_shapeStroke != null)
            {
                PushHistory(new StrokeChange(new StrokeCollection { _shapeStroke }, new StrokeCollection()));
                _shapeStroke = null;
            }
            e.Handled = true;
        }

        /// <summary>
        /// «Приховати»: the area under the rectangle, rebuilt from the screenshot itself as big flat blocks, so a
        /// password, an e-mail or a face can't be read back. Shown with nearest-neighbour scaling (sharp blocks).
        /// </summary>
        private void UpdateBlur(Rect rect)
        {
            rect.Intersect(new Rect(0, 0, RootGrid.ActualWidth, RootGrid.ActualHeight));
            if (rect.IsEmpty || rect.Width < 4 || rect.Height < 4)
            {
                return;
            }

            var source = _capture.Source;
            int x = Math.Clamp((int)Math.Round(rect.X * ScaleX), 0, source.PixelWidth - 1);
            int y = Math.Clamp((int)Math.Round(rect.Y * ScaleY), 0, source.PixelHeight - 1);
            int w = Math.Clamp((int)Math.Round(rect.Width * ScaleX), 1, source.PixelWidth - x);
            int h = Math.Clamp((int)Math.Round(rect.Height * ScaleY), 1, source.PixelHeight - y);
            double block = Math.Max(2, BlurBlocks[_thickness] * ScaleX);
            int tilesX = Math.Max(1, (int)Math.Round(w / block));
            int tilesY = Math.Max(1, (int)Math.Round(h / block));

            var crop = new System.Windows.Media.Imaging.CroppedBitmap(source, new Int32Rect(x, y, w, h));
            var tiles = new System.Windows.Media.Imaging.TransformedBitmap(crop, new ScaleTransform((double)tilesX / w, (double)tilesY / h));
            tiles.Freeze();

            if (_blurElement == null)
            {
                _blurElement = new Image { Stretch = Stretch.Fill, Tag = new Annotation(IsMarker: false, IsBlur: true) };
                RenderOptions.SetBitmapScalingMode(_blurElement, BitmapScalingMode.NearestNeighbor);
                Panel.SetZIndex(_blurElement, -1); // part of the picture: under tags and markers (Mac draws it the same way)
                InkDrawCanvas.Children.Add(_blurElement);
            }
            _blurElement.Source = tiles;
            _blurElement.Width = rect.Width;
            _blurElement.Height = rect.Height;
            SetPosition(_blurElement, rect.TopLeft);
        }

        private Point Constrain(Point start, Point end)
        {
            var v = end - start;
            if (_tool == Tool.Rectangle)
            {
                double side = Math.Max(Math.Abs(v.X), Math.Abs(v.Y));
                return new Point(start.X + Math.Sign(v.X) * side, start.Y + Math.Sign(v.Y) * side);
            }

            // Arrow: snap to multiples of 45°.
            double angle = Math.Round(Math.Atan2(v.Y, v.X) / (Math.PI / 4)) * (Math.PI / 4);
            return start + new Vector(Math.Cos(angle), Math.Sin(angle)) * v.Length;
        }

        private StylusPointCollection? ArrowPoints(Point from, Point to)
        {
            var direction = to - from;
            double length = direction.Length;
            if (length < 6)
            {
                return null;
            }

            direction.Normalize();
            double head = Math.Min(length * 0.5, Math.Max(14, PenWidths[_thickness] * 4.5));
            var left = to - Rotate(direction, 28) * head;
            var right = to - Rotate(direction, -28) * head;
            return new StylusPointCollection(new[] { from, to, left, to, right });

            static Vector Rotate(Vector v, double degrees)
            {
                double rad = degrees * Math.PI / 180, cos = Math.Cos(rad), sin = Math.Sin(rad);
                return new Vector(v.X * cos - v.Y * sin, v.X * sin + v.Y * cos);
            }
        }

        private static StylusPointCollection? RectanglePoints(Point a, Point b)
        {
            if (Math.Abs(b.X - a.X) < 4 && Math.Abs(b.Y - a.Y) < 4)
            {
                return null;
            }

            return new StylusPointCollection(new[]
            {
                a, new Point(b.X, a.Y), b, new Point(a.X, b.Y), a
            });
        }

        #endregion

        #region Text labels & numbered markers

        /// <summary>Walks up from the clicked element to the label/marker it belongs to (if any).</summary>
        private FrameworkElement? FindAnnotation(DependencyObject? source)
        {
            while (source != null && source != InkDrawCanvas)
            {
                if (source is FrameworkElement { Tag: Annotation } element && InkDrawCanvas.Children.Contains(element))
                {
                    return element;
                }
                source = source is Visual or System.Windows.Media.Media3D.Visual3D
                    ? VisualTreeHelper.GetParent(source)
                    : LogicalTreeHelper.GetParent(source);
            }
            return null;
        }

        private static Point GetPosition(FrameworkElement element) =>
            new(InkCanvas.GetLeft(element), InkCanvas.GetTop(element));

        private static void SetPosition(FrameworkElement element, Point position)
        {
            InkCanvas.SetLeft(element, position.X);
            InkCanvas.SetTop(element, position.Y);
        }

        private static Brush ContrastBrush(Color color)
        {
            double luminance = (0.299 * color.R + 0.587 * color.G + 0.114 * color.B) / 255;
            return luminance > 0.6 ? new SolidColorBrush(Color.FromRgb(0x18, 0x18, 0x1B)) : Brushes.White;
        }

        private static Color Darker(Color color) =>
            Color.FromRgb((byte)(color.R * 0.78), (byte)(color.G * 0.78), (byte)(color.B * 0.78));

        /// <summary>A text label is a colored rounded tag with contrasting text: readable on any screenshot.</summary>
        private void StyleLabel(Border label, Color color, double fontSize)
        {
            label.Background = new SolidColorBrush(color);
            label.BorderBrush = new SolidColorBrush(Darker(color));
            label.BorderThickness = new Thickness(1);
            label.CornerRadius = new CornerRadius(fontSize * 0.35);
            label.Padding = new Thickness(fontSize * 0.45, fontSize * 0.15, fontSize * 0.45, fontSize * 0.2);
            label.Tag = new Annotation(IsMarker: false);

            var foreground = ContrastBrush(color);
            switch (label.Child)
            {
                case TextBlock text:
                    text.Foreground = foreground;
                    text.FontSize = fontSize;
                    break;
                case TextBox box:
                    box.Foreground = foreground;
                    box.CaretBrush = foreground;
                    box.FontSize = fontSize;
                    break;
            }
        }

        private TextBlock CreateLabelText(string text, double fontSize) => new()
        {
            Text = text,
            FontSize = fontSize,
            FontWeight = FontWeights.SemiBold,
            FontFamily = (FontFamily)FindResource("UiFont"),
            TextWrapping = TextWrapping.NoWrap
        };

        private void AddLabel(Point point)
        {
            double fontSize = LabelFontSizes[_thickness];
            var label = new Border { Child = CreateLabelText(string.Empty, fontSize), Cursor = Cursors.SizeAll };
            StyleLabel(label, _color, fontSize);
            SetPosition(label, new Point(point.X, point.Y - fontSize * 0.8)); // caret lands where the user clicked
            InkDrawCanvas.Children.Add(label);
            BeginEditLabel(label, isNew: true);
        }

        private void BeginEditLabel(Border label, bool isNew)
        {
            CommitLabelEdit();
            var text = (TextBlock)label.Child;
            _editingLabel = label;
            _editingIsNew = isNew;
            _editingOriginalText = isNew ? string.Empty : text.Text;

            var box = new TextBox
            {
                Text = _editingOriginalText,
                FontSize = text.FontSize,
                FontWeight = text.FontWeight,
                FontFamily = text.FontFamily,
                Foreground = text.Foreground,
                CaretBrush = text.Foreground,
                Background = Brushes.Transparent,
                BorderThickness = new Thickness(0),
                Padding = new Thickness(0),
                MinWidth = text.FontSize * 1.2,
                AcceptsReturn = true,
                SelectionBrush = Brushes.White,
                Cursor = Cursors.IBeam
            };
            box.PreviewKeyDown += OnLabelKeyDown;
            label.Child = box;

            Dispatcher.BeginInvoke(DispatcherPriority.Input, () =>
            {
                box.Focus();
                Keyboard.Focus(box);
                box.CaretIndex = box.Text.Length;
            });
        }

        private void OnLabelKeyDown(object sender, KeyEventArgs e)
        {
            if (e.Key == Key.Enter && (Keyboard.Modifiers & ModifierKeys.Shift) == 0)
            {
                e.Handled = true;
                CommitLabelEdit();
            }
            else if (e.Key == Key.Escape)
            {
                e.Handled = true;
                CommitLabelEdit(cancel: true);
            }
        }

        /// <summary>Turns the label being typed back into text and records it for undo.</summary>
        private void CommitLabelEdit(bool cancel = false)
        {
            var label = _editingLabel;
            if (label == null || label.Child is not TextBox box)
            {
                _editingLabel = null;
                return;
            }
            _editingLabel = null;

            string text = cancel ? _editingOriginalText : box.Text.Trim();
            var foreground = box.Foreground;
            label.Child = CreateLabelText(text, box.FontSize);
            ((TextBlock)label.Child).Foreground = foreground;

            if (_editingIsNew)
            {
                if (text.Length == 0)
                {
                    InkDrawCanvas.Children.Remove(label); // nothing typed: no label, no undo step
                }
                else
                {
                    PushHistory(new ElementChange(label, Added: true));
                }
            }
            else if (text.Length == 0)
            {
                ((TextBlock)label.Child).Text = _editingOriginalText;
                RemoveAnnotation(label); // cleared an existing label = delete it (undoable)
            }
            else if (text != _editingOriginalText)
            {
                PushHistory(new LabelEdit(label, _editingOriginalText, text));
            }

            if (box.IsKeyboardFocusWithin)
            {
                Keyboard.Focus(RootGrid);
            }
        }

        private void AddMarker(Point center)
        {
            int number = InkDrawCanvas.Children.OfType<FrameworkElement>()
                .Select(e => e.Tag is Annotation { IsMarker: true } a ? a.Number : 0)
                .DefaultIfEmpty(0).Max() + 1;

            double size = MarkerSizes[_thickness];
            var marker = new Grid
            {
                Width = size,
                Height = size,
                Tag = new Annotation(IsMarker: true, number),
                Cursor = Cursors.SizeAll,
                Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 6, ShadowDepth = 1, Opacity = 0.35 }
            };
            marker.Children.Add(new System.Windows.Shapes.Ellipse
            {
                Fill = new SolidColorBrush(_color),
                Stroke = Brushes.White,
                StrokeThickness = Math.Max(2, size / 13)
            });
            marker.Children.Add(new TextBlock
            {
                Text = number.ToString(),
                FontSize = size * (number > 9 ? 0.42 : 0.52),
                FontWeight = FontWeights.Bold,
                FontFamily = (FontFamily)FindResource("UiFont"),
                Foreground = ContrastBrush(_color),
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(0, 0, 0, size * 0.04)
            });

            SetPosition(marker, new Point(center.X - size / 2, center.Y - size / 2));
            InkDrawCanvas.Children.Add(marker);
            PushHistory(new ElementChange(marker, Added: true));
        }

        private void RemoveAnnotation(FrameworkElement element)
        {
            if (element == _editingLabel)
            {
                bool wasNew = _editingIsNew;
                CommitLabelEdit(cancel: true);
                if (wasNew)
                {
                    return; // a label that was never committed simply disappears
                }
            }
            InkDrawCanvas.Children.Remove(element);
            PushHistory(new ElementChange(element, Added: false));
        }

        private void BeginDragAnnotation(FrameworkElement element, Point point)
        {
            _dragElement = element;
            _dragElementStart = point;
            _dragElementOrigin = GetPosition(element);
            _dragElementMoved = false;
            InkDrawCanvas.CaptureMouse();
        }

        #endregion

        #region Undo / redo

        private void OnStrokesChanged(object? sender, StrokeCollectionChangedEventArgs e)
        {
            if (!_suppressHistory)
            {
                PushHistory(new StrokeChange(new StrokeCollection(e.Added), new StrokeCollection(e.Removed)));
            }
        }

        private void PushHistory(Change change)
        {
            _undo.Push(change);
            _redo.Clear();
            UpdateUndoButtons();
        }

        private void OnUndoClick(object sender, RoutedEventArgs e) => Undo();

        private void OnRedoClick(object sender, RoutedEventArgs e) => Redo();

        /// <summary>Also restores strokes removed by the eraser (the old undo only knew about added strokes).</summary>
        private void Undo()
        {
            CommitLabelEdit();
            if (_undo.Count == 0)
            {
                return;
            }

            var change = _undo.Pop();
            Revert(change, undo: true);
            _redo.Push(change);
            UpdateUndoButtons();
        }

        private void Redo()
        {
            CommitLabelEdit();
            if (_redo.Count == 0)
            {
                return;
            }

            var change = _redo.Pop();
            Revert(change, undo: false);
            _undo.Push(change);
            UpdateUndoButtons();
        }

        private void Revert(Change change, bool undo)
        {
            switch (change)
            {
                case StrokeChange strokes:
                    Apply(remove: undo ? strokes.Added : strokes.Removed, add: undo ? strokes.Removed : strokes.Added);
                    break;

                case ElementChange element:
                    bool present = element.Added != undo; // undoing an add removes it, undoing a removal brings it back
                    if (present && !InkDrawCanvas.Children.Contains(element.Element))
                    {
                        InkDrawCanvas.Children.Add(element.Element);
                    }
                    else if (!present)
                    {
                        InkDrawCanvas.Children.Remove(element.Element);
                    }
                    break;

                case ElementMove move:
                    SetPosition(move.Element, undo ? move.From : move.To);
                    break;

                case LabelEdit edit when edit.Label.Child is TextBlock text:
                    text.Text = undo ? edit.From : edit.To;
                    break;
            }
        }

        private void Apply(StrokeCollection remove, StrokeCollection add)
        {
            _suppressHistory = true;
            try
            {
                foreach (var stroke in remove.Where(InkDrawCanvas.Strokes.Contains).ToList())
                {
                    InkDrawCanvas.Strokes.Remove(stroke);
                }
                foreach (var stroke in add.Where(s => !InkDrawCanvas.Strokes.Contains(s)).ToList())
                {
                    InkDrawCanvas.Strokes.Add(stroke);
                }
            }
            finally
            {
                _suppressHistory = false;
            }
        }

        private void UpdateUndoButtons()
        {
            BtnUndo.IsEnabled = _undo.Count > 0;
            BtnRedo.IsEnabled = _redo.Count > 0;
        }

        #endregion

        #region Keyboard

        protected override void OnPreviewKeyDown(KeyEventArgs e)
        {
            base.OnPreviewKeyDown(e);
            if (_editingLabel?.IsKeyboardFocusWithin == true)
            {
                return; // typing a text label: Enter/Esc/Space/letters belong to it (see OnLabelKeyDown)
            }

            Key key = e.Key == Key.System ? e.SystemKey : e.Key;
            bool inTextBox = TbComment.IsKeyboardFocusWithin;
            var modifiers = Keyboard.Modifiers;

            if (key == Key.Space && modifiers == ModifierKeys.None)
            {
                HandleSpaceDown(e, inTextBox);
                return;
            }

            switch (key)
            {
                case Key.Escape:
                    e.Handled = true;
                    if (_isSelecting)
                    {
                        EndSelectionDrag(commit: false);
                    }
                    else if (_isRecording)
                    {
                        CancelCurrentRecording(); // Esc while talking drops the take, not the whole screenshot
                    }
                    else if (inTextBox)
                    {
                        Keyboard.Focus(RootGrid); // first Esc just leaves the text box
                    }
                    else if (!_isSaving)
                    {
                        Close();
                    }
                    return;

                case Key.Enter when !(inTextBox && (modifiers & ModifierKeys.Shift) != 0):
                    e.Handled = true; // Shift+Enter inside the comment inserts a new line
                    _ = SaveAsync();
                    return;

            }

            if (inTextBox || _isSaving)
            {
                return; // the text box handles its own Ctrl+Z, letters, etc.
            }

            bool ctrl = (modifiers & ModifierKeys.Control) != 0;
            bool shift = (modifiers & ModifierKeys.Shift) != 0;
            if (ctrl && key == Key.Z)
            {
                if (shift) Redo(); else Undo();
                e.Handled = true;
                return;
            }
            if (ctrl && key == Key.Y)
            {
                Redo();
                e.Handled = true;
                return;
            }
            if (ctrl || (modifiers & ModifierKeys.Alt) != 0)
            {
                return;
            }

            switch (key)
            {
                case Key.P: ApplyTool(Tool.Pen); break;
                case Key.H: ApplyTool(Tool.Highlighter); break;
                case Key.A: ApplyTool(Tool.Arrow); break;
                case Key.R: ApplyTool(Tool.Rectangle); break;
                case Key.T: ApplyTool(Tool.Text); break;
                case Key.N: ApplyTool(Tool.Marker); break;
                case Key.B: ApplyTool(Tool.Blur); break;
                case Key.E: ApplyTool(Tool.Eraser); break;
                case Key.OemOpenBrackets: ChangeThickness(-1, wrap: false); break;
                case Key.OemCloseBrackets: ChangeThickness(+1, wrap: false); break;
                case >= Key.D1 and <= Key.D6:
                    SelectColor(((SolidColorBrush)((Button)SwatchPanel.Children[key - Key.D1]).Background).Color);
                    break;
                default:
                    return;
            }
            e.Handled = true;
        }

        /// <summary>
        /// Space talks: hold it and speak (push-to-talk), or tap it to keep recording hands-free until the next
        /// tap / mic click. In the comment box a tap still types a space; holding it (until the keyboard's
        /// auto-repeat kicks in) takes back that space and starts recording.
        /// </summary>
        private void HandleSpaceDown(KeyEventArgs e, bool inTextBox)
        {
            if (!e.IsRepeat)
            {
                if (_isRecording)
                {
                    // A hands-free take: this press ends it.
                    e.Handled = true;
                    _spaceStopsRecording = true;
                    _ = EndRecordingAsync();
                    return;
                }

                if (!inTextBox)
                {
                    e.Handled = true;
                    StartSpaceRecording(heldAlready: false);
                    return;
                }

                // In the comment box: let this press type its space, but remember the text in case it becomes a hold.
                _textBeforeSpace = (TbComment.Text, TbComment.CaretIndex);
                return;
            }

            // Auto-repeat: Space is being held.
            e.Handled = true; // never type a run of spaces or "press" anything
            if (inTextBox && !_isRecording && !_spaceStopsRecording && _textBeforeSpace is var (text, caret) && !TbComment.IsReadOnly)
            {
                if (TbComment.Text.Length == text.Length + 1)
                {
                    TbComment.Text = text; // take back the space the first press typed
                    TbComment.CaretIndex = Math.Min(caret, text.Length);
                }
                _textBeforeSpace = null;
                StartSpaceRecording(heldAlready: true); // the repeat delay already proves it is a hold
            }
        }

        private void StartSpaceRecording(bool heldAlready)
        {
            if (BeginRecording(handsFree: false))
            {
                _spaceHoldStarted = heldAlready ? DateTime.MinValue : DateTime.UtcNow;
            }
        }

        protected override void OnPreviewKeyUp(KeyEventArgs e)
        {
            base.OnPreviewKeyUp(e);
            if (e.Key != Key.Space || _editingLabel?.IsKeyboardFocusWithin == true)
            {
                return;
            }

            _textBeforeSpace = null;
            if (_spaceStopsRecording)
            {
                _spaceStopsRecording = false; // the release of the press that stopped a hands-free take
                e.Handled = true;
                return;
            }

            if (!_isRecording || _recordingHandsFree)
            {
                return;
            }

            e.Handled = true;
            if (DateTime.UtcNow - _spaceHoldStarted < TimeSpan.FromMilliseconds(350))
            {
                // A quick tap: keep listening until Space or the mic is pressed again.
                _recordingHandsFree = true;
                ShowRecordingStatus();
            }
            else
            {
                _ = EndRecordingAsync();
            }
        }

        #endregion

        #region Voice comment

        private void OnRecordClick(object sender, RoutedEventArgs e)
        {
            if (_isRecording)
            {
                _ = EndRecordingAsync();
            }
            else
            {
                BeginRecording(handsFree: true);
            }
        }

        private bool BeginRecording(bool handsFree)
        {
            if (_isRecording || _isSaving || _closed)
            {
                return false;
            }

            if (_chunks.Count == 0)
            {
                _baseText = TbComment.Text.Trim(); // keep whatever the user typed or edited
            }

            if (!_audio.StartRecording())
            {
                ShowStatus(_audio.LastError ?? "Не вдалося увімкнути мікрофон.", StatusKind.Error);
                return false;
            }

            _isRecording = true;
            _recordingHandsFree = handsFree;
            int generation = ++_recordingGeneration;
            var chunk = new VoiceChunk();
            _currentChunk = chunk;
            _chunks.Add(chunk);
            RefreshCommentText();

            SetRecordingVisuals(true);
            ShowRecordingStatus();

            if (!_transcription.IsModelReady)
            {
                _ = _transcription.EnsureModelLoadedAsync();
            }

            _ = RunLivePreviewAsync(generation, chunk);
            return true;
        }

        private void ShowRecordingStatus()
        {
            string how = _recordingHandsFree
                ? "Говоріть… щоб зупинити — натисніть Пробіл або мікрофон"
                : "Говоріть… відпустіть Пробіл, коли закінчите";
            ShowStatus(_transcription.IsModelReady ? how : how + " (модель ще готується)", StatusKind.Recording);
        }

        /// <summary>Esc while talking: drop this take, keep the rest of the comment.</summary>
        private void CancelCurrentRecording()
        {
            if (!_isRecording)
            {
                return;
            }

            _isRecording = false;
            _recordingGeneration++;
            _audio.CancelRecording();
            if (_currentChunk != null)
            {
                _chunks.Remove(_currentChunk);
                _currentChunk = null;
            }
            SetRecordingVisuals(false);
            RefreshCommentText();
            if (_chunks.Count == 0)
            {
                UpdateIdleStatus();
            }
        }

        /// <summary>Re-transcribes the growing recording with the fast preview settings for live feedback.</summary>
        private async Task RunLivePreviewAsync(int generation, VoiceChunk chunk)
        {
            var started = DateTime.UtcNow;
            while (true)
            {
                await Task.Delay(600);
                if (!_isRecording || generation != _recordingGeneration || _closed)
                {
                    return;
                }
                if (DateTime.UtcNow - started > MaxTake)
                {
                    _ = EndRecordingAsync(); // a forgotten hands-free take
                    return;
                }
                if (!_transcription.IsModelReady)
                {
                    continue;
                }

                float[] samples = _audio.GetSamplesSnapshot();
                if (samples.Length < AudioAnalysis.SampleRate / 2)
                {
                    continue;
                }

                string? text = await _transcription.TryTranscribePreviewAsync(samples);
                if (text != null && !chunk.IsFinal && !_closed && _chunks.Contains(chunk) && text.Length > 0)
                {
                    chunk.Text = text;
                    RefreshCommentText();
                }
            }
        }

        private async Task EndRecordingAsync()
        {
            if (!_isRecording)
            {
                return;
            }

            _isRecording = false;
            _recordingHandsFree = false;
            var chunk = _currentChunk!;
            SetRecordingVisuals(false);

            float[] samples = await _audio.StopRecordingAsync();
            if (_closed)
            {
                return;
            }

            if (samples.Length < AudioAnalysis.SampleRate * 0.3)
            {
                _chunks.Remove(chunk);
                RefreshCommentText();
                ShowStatus("Запис був надто короткий — говоріть трохи довше.", StatusKind.Warning);
                return;
            }

            var task = FinishChunkAsync(chunk, samples);
            _pendingTranscriptions.Add(task);
            _ = task.ContinueWith(t => _pendingTranscriptions.Remove(t), TaskScheduler.FromCurrentSynchronizationContext());
        }

        private async Task FinishChunkAsync(VoiceChunk chunk, float[] samples)
        {
            ShowStatus(_transcription.IsModelReady ? "Розпізнаю…" : "Чекаю на модель розпізнавання…", StatusKind.Busy);

            string text = string.Empty;
            var stopwatch = System.Diagnostics.Stopwatch.StartNew();
            double? highBand = null;
            try
            {
                var analysis = Task.Run(() => AudioAnalysis.HighBandShare(samples));
                text = await _transcription.TranscribeAsync(samples);
                highBand = await analysis;
                Log.Info($"[Overlay] {samples.Length / 16000.0:F1} s → {stopwatch.ElapsedMilliseconds} ms, '{_transcription.ActiveModel?.Id}' {(_transcription.IsRunningOnGpu ? "GPU" : "CPU")}, lang={_transcription.Language}, 1–4 kHz {highBand:P2}: \"{text}\"");
            }
            catch (Exception ex)
            {
                Log.Warn("[Overlay] Transcription failed", ex);
            }

            chunk.Text = text;
            chunk.IsFinal = true;
            CommitFinishedChunks();
            RefreshCommentText();

            if (_closed || _isRecording || _chunks.Any(c => !c.IsFinal))
            {
                return;
            }

            if (highBand < MuffledShare)
            {
                // Recognition can't be good when the consonants never reached the computer: say so plainly.
                ShowStatus("Мікрофон звучить глухо — через це погано розпізнає. Послухайте себе: ▾ біля мікрофона",
                    StatusKind.Warning);
            }
            else if (text.Length > 0)
            {
                ShowStatus("Готово! Enter — зберегти і скопіювати, Пробіл — додати ще.", StatusKind.Success);
            }
            else if (!_transcription.IsModelReady)
            {
                ShowStatus(_transcription.LastError ?? "Модель розпізнавання недоступна.", StatusKind.Error);
            }
            else if (AudioAnalysis.IsDigitalSilence(samples))
            {
                ShowStatus($"«{MicrophoneName}» передає повну тишу — оберіть інший мікрофон (▾ біля мікрофона).", StatusKind.Warning);
            }
            else if (!AudioAnalysis.HasSpeech(samples))
            {
                ShowStatus("Не чути голосу — перевірте мікрофон (▾ біля мікрофона).", StatusKind.Warning);
            }
            else
            {
                ShowStatus("Не вдалося розпізнати мову — спробуйте ще раз чіткіше.", StatusKind.Warning);
            }
        }

        /// <summary>Moves finished fragments (in recording order) into the settled text.</summary>
        private void CommitFinishedChunks()
        {
            while (_chunks.Count > 0 && _chunks[0].IsFinal)
            {
                _baseText = TranscriptCleaner.Append(_baseText, _chunks[0].Text);
                _chunks.RemoveAt(0);
            }
        }

        private string ComposeComment()
        {
            string text = _baseText;
            foreach (var chunk in _chunks)
            {
                text = TranscriptCleaner.Append(text, chunk.Text);
            }
            return text.Trim();
        }

        private void RefreshCommentText()
        {
            _updatingText = true;
            try
            {
                string text = ComposeComment();
                if (TbComment.Text != text)
                {
                    TbComment.Text = text;
                    TbComment.CaretIndex = text.Length;
                    TbComment.ScrollToEnd();
                }
            }
            finally
            {
                _updatingText = false;
            }

            // While fragments are being transcribed the box is read-only (and grey for live previews),
            // so late results can't clobber what the user is typing.
            bool busy = _chunks.Count > 0;
            TbComment.IsReadOnly = busy;
            TbComment.Foreground = _chunks.Any(c => !c.IsFinal) ? PreviewBrush : InkBrush;
            TxtPlaceholder.Visibility = TbComment.Text.Length == 0 && !busy ? Visibility.Visible : Visibility.Collapsed;
        }

        private void OnCommentTextChanged(object sender, TextChangedEventArgs e)
        {
            if (!_updatingText && _chunks.Count == 0)
            {
                _baseText = TbComment.Text;
            }
            TxtPlaceholder.Visibility = TbComment.Text.Length == 0 && _chunks.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        }

        private void SetRecordingVisuals(bool recording)
        {
            if (recording)
            {
                _pulse.Begin(this, true);
                MicCircle.Fill = (Brush)FindResource("RecordFill"); // a solid red disc while listening
                MicGlyph.Foreground = Brushes.White;
            }
            else
            {
                _pulse.Stop(this);
                MicCircle.Fill = IdleFill;
                MicGlyph.Foreground = InkBrush;
                _displayLevel = 0;
                LevelRing.Opacity = 0;
            }
        }

        private void OnAudioLevelChanged(object? sender, float level)
        {
            Dispatcher.BeginInvoke(DispatcherPriority.Render, () =>
            {
                if (!_isRecording)
                {
                    return;
                }
                _displayLevel = Math.Max(level, _displayLevel * 0.75f); // fast attack, smooth release
                LevelRing.Opacity = 0.35 + _displayLevel * 0.65;
                LevelScale.ScaleX = LevelScale.ScaleY = 1.05 + _displayLevel * 0.45;
            });
        }

        private void OnModelStateChanged(object? sender, EventArgs e) => Dispatcher.BeginInvoke(UpdateIdleStatus);

        private void UpdateIdleStatus()
        {
            if (_closed || _isRecording || _isSaving || _chunks.Count > 0 || _pendingTranscriptions.Count > 0)
            {
                return;
            }

            switch (_transcription.State)
            {
                case ModelState.Ready when _transcription.DownloadingModel is { } next:
                    ShowStatus($"Говоріть або пишіть · модель «{next.Id}»: {_transcription.DownloadProgress:P0}", StatusKind.Idle);
                    break;
                case ModelState.Ready:
                    ShowStatus("Утримуйте Пробіл і говоріть, або пишіть", StatusKind.Idle);
                    break;
                case ModelState.Downloading:
                    ShowStatus($"Завантажую модель розпізнавання… {_transcription.DownloadProgress:P0} — записувати вже можна.", StatusKind.Busy);
                    break;
                case ModelState.Failed:
                    ShowStatus($"Голос недоступний: {_transcription.LastError}", StatusKind.Error);
                    break;
                default:
                    ShowStatus("Запускаю модель розпізнавання…", StatusKind.Busy);
                    break;
            }
        }

        /// <summary>Idle hints live in the comment placeholder; anything else gets the small status line.</summary>
        private void ShowStatus(string text, StatusKind kind)
        {
            if (kind == StatusKind.Idle)
            {
                TxtPlaceholder.Text = text;
                StatusPill.Visibility = Visibility.Collapsed;
                BusyRotation.BeginAnimation(RotateTransform.AngleProperty, null);
                return;
            }

            StatusPill.Visibility = Visibility.Visible;
            TxtStatus.Text = text;
            TxtStatus.ToolTip = text;
            TxtStatus.Foreground = kind switch
            {
                StatusKind.Success => GreenBrush,
                StatusKind.Warning => AmberBrush,
                StatusKind.Error or StatusKind.Recording => RedBrush,
                _ => InkBrush
            };

            bool busy = kind == StatusKind.Busy;
            BusyGlyph.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
            BusyRotation.BeginAnimation(RotateTransform.AngleProperty,
                busy ? new DoubleAnimation(0, 360, TimeSpan.FromSeconds(1)) { RepeatBehavior = RepeatBehavior.Forever } : null);
        }

        private string MicrophoneName => string.IsNullOrWhiteSpace(_settings.SelectedMicrophoneName)
            ? "Системний мікрофон"
            : _settings.SelectedMicrophoneName;

        private void UpdateMicrophoneButton() => BtnMicrophone.ToolTip = $"Мікрофон: {MicrophoneName} (клацніть, щоб змінити)";

        private void OnMicrophoneClick(object sender, RoutedEventArgs e)
        {
            var menu = new ContextMenu
            {
                PlacementTarget = BtnMicrophone,
                Placement = Toolbar.VerticalAlignment == VerticalAlignment.Top
                    ? System.Windows.Controls.Primitives.PlacementMode.Bottom
                    : System.Windows.Controls.Primitives.PlacementMode.Top,
                FontFamily = (FontFamily)FindResource("UiFont")
            };

            foreach (var mic in _audio.GetMicrophones())
            {
                var item = new MenuItem
                {
                    Header = mic.DisplayName,
                    IsCheckable = true,
                    IsChecked = string.Equals(mic.Name, _settings.SelectedMicrophoneName, StringComparison.OrdinalIgnoreCase)
                };
                item.Click += (_, _) =>
                {
                    _settings.SelectedMicrophoneName = mic.Name;
                    _settings.Save(); // the old overlay changed the mic only until the next restart
                    _audio.PreferredMicrophone = mic.Name;
                    UpdateMicrophoneButton();
                    Keyboard.Focus(RootGrid);
                };
                menu.Items.Add(item);
            }

            menu.Items.Add(new Separator());
            var listen = new MenuItem
            {
                Header = "▶  Прослухати останній запис",
                IsEnabled = _audio.HasLastRecording && !_isRecording,
                ToolTip = "Так звучить ваш голос для розпізнавання. Якщо глухо чи тихо — справа в мікрофоні або його підключенні."
            };
            listen.Click += (_, _) =>
            {
                if (!_audio.PlayLastRecording())
                {
                    ShowStatus("Не вдалося відтворити запис.", StatusKind.Warning);
                }
            };
            menu.Items.Add(listen);

            menu.Closed += (_, _) => Keyboard.Focus(RootGrid);
            menu.IsOpen = true;
        }

        #endregion

        #region Save

        private void OnSaveClick(object sender, RoutedEventArgs e) => _ = SaveAsync();

        private void OnCancelClick(object sender, RoutedEventArgs e)
        {
            if (!_isSaving)
            {
                Close();
            }
        }

        private async Task SaveAsync()
        {
            if (_isSaving || _closed)
            {
                return;
            }
            if (_isSelecting)
            {
                EndSelectionDrag(commit: true);
            }
            CommitLabelEdit(); // a label still being typed is part of the picture

            _isSaving = true;
            try
            {
                if (_isRecording)
                {
                    await EndRecordingAsync();
                }

                // The annotations are rendered synchronously inside this call, so the window can disappear right
                // after: encoding/writing the PNG and waiting for the voice text happen while the user moves on.
                var crop = GetCropPixels();
                if (crop == null && InkDrawCanvas.Visibility != Visibility.Visible)
                {
                    // Whole monitor saved from region mode without a selection: the (hidden) layer may still
                    // hold annotations drawn earlier in full-screen mode.
                    InkDrawCanvas.Clip = null;
                    InkDrawCanvas.Visibility = Visibility.Visible;
                    InkDrawCanvas.UpdateLayout();
                }

                bool hasAnnotations = InkDrawCanvas.Strokes.Count > 0 || InkDrawCanvas.Children.Count > 0;
                var saveTask = _compositor.SaveAnnotatedScreenshotAsync(
                    _capture.Bitmap,
                    hasAnnotations ? InkDrawCanvas : null,
                    new Size(RootGrid.ActualWidth, RootGrid.ActualHeight),
                    ScaleX, ScaleY, crop);
                Hide();

                var saved = await saveTask;
                (string comment, bool voiceLost) = await CollectCommentAsync();

                // the comment goes into the PNG too, so it stays with the file wherever it is sent or moved
                long fileSize = saved.FileSizeBytes;
                if (comment.Length > 0)
                {
                    try
                    {
                        fileSize = await Task.Run(() => PngMetadata.WriteComment(saved.Path, comment)) ?? fileSize;
                    }
                    catch (Exception ex)
                    {
                        Log.Warn("[Overlay] Could not write the comment into the PNG", ex);
                    }
                }

                var entry = new ScreenshotHistoryItem
                {
                    ImagePath = saved.Path,
                    TranscribedText = comment,
                    Width = saved.Width,
                    Height = saved.Height,
                    FileSizeBytes = fileSize,
                    CreatedAt = DateTime.Now
                };
                try
                {
                    await _history.AddEntryAsync(entry);
                }
                catch (Exception ex)
                {
                    Log.Error("[Overlay] Could not add the history entry", ex);
                }

                string markdown = _clipboard.FormatMarkdown(saved.Path, comment);
                bool copied = _clipboard.CopyToClipboard(markdown, saved.Path);

                string message = comment.Length > 0
                    ? $"«{comment}»"
                    : "Вставте (Ctrl+V) у чат чи задачу — шлях до PNG і коментар уже в буфері.";
                if (voiceLost)
                {
                    message = "Голосовий коментар не встиг розпізнатися (модель ще готується). " + message;
                }

                _notifications.Show(new ToastOptions
                {
                    Title = copied ? "Скопійовано в буфер обміну" : "Збережено, але буфер обміну зайнятий",
                    Message = message,
                    Kind = copied && !voiceLost ? ToastKind.Success : ToastKind.Warning,
                    ImagePath = saved.Path,
                    CopyText = markdown,
                    OnOpenGallery = _openGallery,
                    ActionText = _shareItem != null ? "Посилання" : null,
                    OnAction = _shareItem != null ? () => _shareItem(entry) : null,
                    DurationMs = 5000
                });

                Close();
            }
            catch (Exception ex)
            {
                Log.Error("[Overlay] Saving failed", ex);
                _isSaving = false;
                if (!_closed)
                {
                    Show();
                    BringToFront();
                    ShowStatus($"Не вдалося зберегти: {ex.Message}", StatusKind.Error);
                }
            }
            finally
            {
                if (_closed)
                {
                    _capture.Dispose();
                }
            }
        }

        private async Task<(string Comment, bool VoiceLost)> CollectCommentAsync()
        {
            var pending = _pendingTranscriptions.Where(t => !t.IsCompleted).ToList();
            if (pending.Count > 0 && _transcription.State is ModelState.Ready or ModelState.Loading)
            {
                // Normally ~1 s. Never block the screenshot behind a model download.
                await Task.WhenAny(Task.WhenAll(pending), Task.Delay(TimeSpan.FromSeconds(30)));
            }

            bool voiceLost = _chunks.Any(c => !c.IsFinal && c.Text.Length == 0);
            return (ComposeComment(), voiceLost);
        }

        #endregion

        private void OnClosed(object? sender, EventArgs e)
        {
            _closed = true;
            _audio.AudioLevelChanged -= OnAudioLevelChanged;
            _transcription.StateChanged -= OnModelStateChanged;
            InkDrawCanvas.Strokes.StrokesChanged -= OnStrokesChanged;
            _pulse.Stop(this);

            if (_isRecording)
            {
                _isRecording = false;
                _audio.CancelRecording();
            }

            ImgScreenshot.Source = null;
            if (!_isSaving)
            {
                _capture.Dispose(); // during a save the bitmap is disposed once the PNG is written
            }
        }

        private static Brush FrozenArgb(byte a, byte r, byte g, byte b)
        {
            var brush = new SolidColorBrush(Color.FromArgb(a, r, g, b));
            brush.Freeze();
            return brush;
        }

        private static Brush Frozen(byte r, byte g, byte b)
        {
            var brush = new SolidColorBrush(Color.FromRgb(r, g, b));
            brush.Freeze();
            return brush;
        }
    }
}
