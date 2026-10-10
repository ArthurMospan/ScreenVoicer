using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Runtime;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Input;
using ScreenVoicer.Models;
using ScreenVoicer.Native;
using ScreenVoicer.Services;
using ScreenVoicer.Views;
using Forms = System.Windows.Forms;

namespace ScreenVoicer
{
    public partial class App : System.Windows.Application, ITrayMenuHost
    {
        /// <summary>Current capture shortcut as text, for hints across the UI.</summary>
        public static string HotkeyText { get; private set; } = SettingsService.DefaultHotkey;

        private const string MutexName = @"Local\ScreenVoicer.SingleInstance";
        private const string ShowGalleryEventName = @"Local\ScreenVoicer.ShowGallery";
        private const string LegacyMutexName = @"Global\ScreenVoicer_Unique_App_Mutex_2026"; // versions ≤ 1.2

        private static readonly (string Code, string Title)[] Languages =
        {
            ("uk", "Українська"),
            ("en", "English"),
            ("auto", "Автовизначення (повільніше)")
        };

        public static string Version { get; } = typeof(App).Assembly.GetName().Version?.ToString(3) ?? "1.3.0";

        private Mutex? _singleInstanceMutex;
        private EventWaitHandle? _showGalleryEvent;
        private RegisteredWaitHandle? _showGalleryWait;

        private Forms.NotifyIcon? _notifyIcon;
        private HotkeyWindow? _hotkeyWindow;

        private ISettingsService? _settings;
        private IClipboardService? _clipboard;
        private INotificationService? _notifications;
        private IHistoryService? _history;
        private IScreenCaptureService? _screenCapture;
        private IAudioRecorderService? _audio;
        private ITranscriptionService? _transcription;
        private IImageCompositorService? _compositor;
        private IHotkeyService? _hotkey;

        private OverlayWindow? _overlay;
        private GalleryWindow? _gallery;
        private bool _captureStarting;
        private bool _modelWasDownloading;
        private ModelState _lastReportedState;
        private bool _cleanedUp;

        private enum CaptureTrigger
        {
            Hotkey,
            TrayClick,
            TrayMenu,
            Delayed,
            Gallery
        }

        protected override async void OnStartup(StartupEventArgs e)
        {
            base.OnStartup(e);

            if (e.Args.Contains("--selftest"))
            {
                int code = await SelfTest.RunAsync(e.Args);
                Shutdown(code);
                return;
            }
            if (e.Args.Contains("--install-cuda"))
            {
                Shutdown(await InstallCudaFromCommandLineAsync());
                return;
            }
            if (e.Args.Contains("--check-update"))
            {
                Shutdown(await CheckUpdateFromCommandLineAsync());
                return;
            }
            if (e.Args.Contains("--update"))
            {
                Shutdown(await UpdateFromCommandLineAsync());
                return;
            }

            RegisterExceptionHandlers();
            if (!AcquireSingleInstance())
            {
                Shutdown();
                return;
            }

            bool autostart = e.Args.Contains(StartupManager.AutostartArgument);
            Log.Info($"ScreenVoicer {Version} starting (autostart={autostart}, {Environment.OSVersion}, {Environment.ProcessorCount} CPUs).");

            InitializeServices();
            _history!.Changed += (_, _) => TrayMenuStateChanged?.Invoke(this, EventArgs.Empty);
            _ = _history.GetHistoryAsync(); // so the tray menu can show the count right away
            RegisterHotkey(); // usable right away
            InitializeTrayIcon();
            OfferInsertHotkeyOnce();
            StartupManager.RefreshEntryIfEnabled();
            StartModelLoading();
            StartUpdateChecks();

            // Launched by the user: show the main window. Launched at login: stay quietly in the tray.
            if (!autostart)
            {
                OpenGallery();
            }

            if (WhisperTranscriptionService.IsModelDownloaded(_transcription!.SelectedModel.Id))
            {
                _notifications!.ShowToast("ScreenVoicer працює у треї",
                    $"{HotkeyText} — знімок екрана, затисніть Пробіл — голосовий коментар.", ToastKind.Info, 4000);
            }

            var startup = Stopwatch.StartNew();
            _ = Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.ApplicationIdle,
                () => Log.Info($"Startup finished, UI idle after {startup.ElapsedMilliseconds} ms."));
        }

        #region Startup

        private void RegisterExceptionHandlers()
        {
            DispatcherUnhandledException += (_, args) =>
            {
                Log.Error("Unhandled UI exception", args.Exception);
                args.Handled = true;
                _notifications?.ShowToast("Щось пішло не так", args.Exception.Message, ToastKind.Error, 7000);
            };

            AppDomain.CurrentDomain.UnhandledException += (_, args) =>
                Log.Error("Fatal unhandled exception", args.ExceptionObject as Exception);

            TaskScheduler.UnobservedTaskException += (_, args) =>
            {
                Log.Error("Unobserved task exception", args.Exception);
                args.SetObserved();
            };

            // Exceptions in tray-menu handlers otherwise pop up the raw WinForms "Unhandled exception" dialog.
            Forms.Application.SetUnhandledExceptionMode(Forms.UnhandledExceptionMode.CatchException);
            Forms.Application.ThreadException += (_, args) =>
            {
                Log.Error("Unhandled tray exception", args.Exception);
                _notifications?.ShowToast("Щось пішло не так", args.Exception.Message, ToastKind.Error, 7000);
            };
        }

        private bool AcquireSingleInstance()
        {
            if (Mutex.TryOpenExisting(LegacyMutexName, out var legacy))
            {
                legacy.Dispose();
                System.Windows.MessageBox.Show(
                    "Зараз запущена стара версія ScreenVoicer.\n\nЗакрийте її (іконка в треї → «Вийти») і запустіть програму ще раз.",
                    "ScreenVoicer", MessageBoxButton.OK, MessageBoxImage.Information);
                return false;
            }

            _singleInstanceMutex = new Mutex(true, MutexName, out bool createdNew);
            if (!createdNew)
            {
                // Already running: ask that instance to show its gallery instead of nagging with a message box.
                try
                {
                    using var showGallery = EventWaitHandle.OpenExisting(ShowGalleryEventName);
                    showGallery.Set();
                }
                catch (Exception ex)
                {
                    Log.Warn("Could not signal the running instance", ex);
                }

                _singleInstanceMutex.Dispose();
                _singleInstanceMutex = null;
                return false;
            }

            _showGalleryEvent = new EventWaitHandle(false, EventResetMode.AutoReset, ShowGalleryEventName);
            _showGalleryWait = ThreadPool.RegisterWaitForSingleObject(
                _showGalleryEvent, (_, _) => Dispatcher.BeginInvoke(OpenGallery), null, Timeout.Infinite, executeOnlyOnce: false);
            return true;
        }

        private void InitializeServices()
        {
            _settings = new SettingsService();
            _clipboard = new ClipboardService();
            _notifications = new NotificationService(_clipboard);
            _history = new HistoryService(_settings);
            _screenCapture = new ScreenCaptureService();
            _audio = new AudioRecorderService { PreferredMicrophone = _settings.SelectedMicrophoneName };
            _settings.Model ??= WhisperModels.Base.Id; // fresh install: small download first, a better model is offered once a GPU shows up
            _transcription = new WhisperTranscriptionService(_settings.Language, _settings.Model, _settings.UseGpu);
            _compositor = new ImageCompositorService(_settings);
            _hotkey = new HotkeyService();

            if (_transcription is WhisperTranscriptionService { GpuCrashDetected: true })
            {
                // The video card driver took the app down last time: stay on the processor until the user re-enables it.
                _settings.UseGpu = false;
                _settings.Save();
                _notifications.Show(new ToastOptions
                {
                    Title = "Відеокарту вимкнено для розпізнавання",
                    Message = "Минулого разу драйвер відеокарти не запустився. Розпізнавання працює на процесорі.",
                    Kind = ToastKind.Warning,
                    DurationMs = 9000,
                    ActionText = "Спробувати знову",
                    OnAction = () => SetUseGpu(true)
                });
            }
        }

        private void RegisterHotkey()
        {
            _hotkey!.HotkeyPressed += (_, _) => TriggerCapture(CaptureTrigger.Hotkey);
            if (!HotkeyGesture.TryParse(_settings!.Hotkey, out var gesture))
            {
                HotkeyGesture.TryParse(SettingsService.DefaultHotkey, out gesture);
            }

            HotkeyText = gesture.ToString();
            if (!_hotkey.Register(gesture.Modifiers, gesture.Key))
            {
                _notifications!.Show(new ToastOptions
                {
                    Title = "Гаряча клавіша зайнята",
                    Message = $"{HotkeyText} вже використовує інша програма. Оберіть іншу комбінацію.",
                    Kind = ToastKind.Warning,
                    DurationMs = 9000,
                    ActionText = "Змінити",
                    OnAction = OpenHotkeyWindow
                });
            }
        }

        /// <summary>
        /// Once, a few seconds after start: offer Insert (one key nobody uses) instead of the three-key default.
        /// Mac keyboards have no Insert key, so the Mac app doesn't offer it.
        /// </summary>
        private void OfferInsertHotkeyOnce()
        {
            if (_settings == null || _settings.InsertHintShown || HotkeyText != SettingsService.DefaultHotkey)
            {
                return;
            }

            var timer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(8) };
            timer.Tick += (_, _) =>
            {
                timer.Stop();
                if (_settings.InsertHintShown || HotkeyText != SettingsService.DefaultHotkey)
                {
                    return;
                }
                _settings.InsertHintShown = true;
                _settings.Save();
                _notifications!.Show(new ToastOptions
                {
                    Title = "Знімок однією клавішею?",
                    Message = $"Клавішею Insert майже ніхто не користується. Можна робити знімок нею замість {HotkeyText}.",
                    Kind = ToastKind.Info,
                    DurationMs = 15000,
                    ActionText = "Обрати Insert",
                    OnAction = () => ApplyHotkey(HotkeyGesture.Insert)
                });
            };
            timer.Start();
        }

        /// <summary>Registers a new capture shortcut and remembers it; on failure the old one stays.</summary>
        private bool ApplyHotkey(HotkeyGesture gesture)
        {
            if (_hotkey == null || _settings == null)
            {
                return false;
            }

            HotkeyGesture.TryParse(HotkeyText, out var previous);
            _hotkey.Unregister();
            if (!_hotkey.Register(gesture.Modifiers, gesture.Key))
            {
                if (previous.IsValid)
                {
                    _hotkey.Register(previous.Modifiers, previous.Key);
                }
                _notifications!.ShowToast("Гаряча клавіша зайнята",
                    $"{gesture} вже використовує інша програма. Оберіть іншу комбінацію.", ToastKind.Warning, 7000);
                return false;
            }

            HotkeyText = gesture.ToString();
            _settings.Hotkey = HotkeyText;
            _settings.Save();
            UpdateTrayStatus();
            _notifications!.ShowToast("Гаряча клавіша змінена", $"Тепер знімок — {HotkeyText}.", ToastKind.Success, 3500);
            return true;
        }

        private void StartModelLoading()
        {
            _transcription!.StateChanged += (_, _) => Dispatcher.BeginInvoke(OnModelStateChanged);

            var model = _transcription.SelectedModel;
            if (!WhisperTranscriptionService.IsModelDownloaded(model.Id))
            {
                _notifications!.ShowToast("Готую розпізнавання голосу",
                    $"Одноразово завантажую мовну модель «{model.Id}» ({model.SizeMb} МБ). Скриншоти можна робити вже зараз.", ToastKind.Info, 8000);
            }

            // Loading the native runtime maps up to ~900 MB of DLLs (CUDA) while holding the Windows loader lock,
            // which stalled the UI's own startup by ~3 s. Begin once the UI is idle.
            Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.ApplicationIdle,
                () => _ = _transcription.EnsureModelLoadedAsync());
        }

        private void OnModelStateChanged()
        {
            if (_transcription == null)
            {
                return;
            }

            var state = _transcription.State;
            UpdateTrayStatus();
            OfferAccurateModelOnce();

            if (state == _lastReportedState)
            {
                return;
            }
            _lastReportedState = state;

            switch (state)
            {
                case ModelState.Downloading:
                    _modelWasDownloading = true;
                    break;
                case ModelState.Ready when _modelWasDownloading:
                    _modelWasDownloading = false;
                    _notifications!.ShowToast("Розпізнавання голосу готове",
                        "Затисніть Пробіл у вікні знімка, щоб надиктувати коментар.", ToastKind.Success, 5000);
                    break;
                case ModelState.Failed:
                    _notifications!.Show(new ToastOptions
                    {
                        Title = "Розпізнавання голосу недоступне",
                        Message = _transcription.LastError ?? "Невідома помилка.",
                        Kind = ToastKind.Error,
                        DurationMs = 9000,
                        ActionText = "Повторити",
                        OnAction = RetryModel
                    });
                    break;
            }
        }

        private void RetryModel()
        {
            _lastReportedState = ModelState.NotLoaded;
            _ = _transcription?.EnsureModelLoadedAsync();
        }

        /// <summary>With a video card the accurate model is as fast as the small one on a CPU: suggest it once.</summary>
        private void OfferAccurateModelOnce()
        {
            if (_transcription is not { IsRunningOnGpu: true } || _settings == null || _settings.ModelHintShown ||
                _transcription.ActiveModel != WhisperModels.Base)
            {
                return;
            }

            _settings.ModelHintShown = true;
            _settings.Save();
            _notifications!.Show(new ToastOptions
            {
                Title = $"Знайдено відеокарту {_transcription.GpuName}",
                Message = $"Можна увімкнути точнішу модель «{WhisperModels.Small.Id}» ({WhisperModels.Small.SizeMb} МБ) — з відеокартою вона працює так само швидко.",
                Kind = ToastKind.Info,
                DurationMs = 12000,
                ActionText = "Увімкнути",
                OnAction = () => SwitchModel(WhisperModels.Small)
            });
        }

        private async void SwitchModel(WhisperModelInfo model)
        {
            if (_transcription == null || _settings == null || _transcription.SelectedModel == model)
            {
                return;
            }

            _settings.Model = model.Id;
            _settings.Save();

            bool needsDownload = !WhisperTranscriptionService.IsModelDownloaded(model.Id);
            _notifications!.ShowToast($"Модель «{model.Id}»",
                needsDownload
                    ? $"Завантажую {model.SizeMb} МБ… Поки що працює попередня модель."
                    : "Перемикаю модель розпізнавання…",
                ToastKind.Info, 4000);

            bool ok = await _transcription.SwitchModelAsync(model.Id);
            if (ok)
            {
                string where = _transcription.UseGpu && _transcription.IsGpuRuntimeAvailable ? "на відеокарті" : "на процесорі";
                _notifications.ShowToast($"Модель «{model.Id}» готова", $"{model.Title}: {model.Hint}. Працює {where}.", ToastKind.Success, 5000);

                if (model == WhisperModels.Large && CudaPack.HasNvidiaDriver && _transcription.GpuBackend != "CUDA" && _cudaProgress == null)
                {
                    _notifications.Show(new ToastOptions
                    {
                        Title = "Можна вдвічі швидше",
                        Message = CudaPack.IsInstalled
                            ? "Прискорення NVIDIA CUDA вже завантажене — перезапустіть ScreenVoicer, щоб його увімкнути."
                            : $"З прискоренням NVIDIA CUDA модель «{model.Id}» відповідає за ~3,5 с замість ~8 с. Завантаження {CudaPack.DownloadMegabytes} МБ, один раз.",
                        Kind = ToastKind.Info,
                        DurationMs = 15000,
                        ActionText = CudaPack.IsInstalled ? "Перезапустити" : "Завантажити",
                        OnAction = OnCudaItemClick
                    });
                }
            }
            else
            {
                _settings.Model = _transcription.SelectedModel.Id; // the service kept the previous model
                _settings.Save();
                _notifications.ShowToast("Не вдалося змінити модель", _transcription.LastError ?? "Невідома помилка.", ToastKind.Error, 8000);
            }
            UpdateTrayStatus();
        }

        private void SetUseGpu(bool useGpu)
        {
            if (_transcription == null || _settings == null)
            {
                return;
            }

            _settings.UseGpu = useGpu;
            _settings.Save();
            _ = _transcription.SetUseGpuAsync(useGpu);
            _notifications!.ShowToast("Розпізнавання голосу",
                useGpu ? "Переношу на відеокарту…" : "Тепер працює на процесорі.", ToastKind.Success, 3000);
        }

        private void OpenHotkeyWindow()
        {
            if (_hotkeyWindow != null)
            {
                _hotkeyWindow.Activate();
                return;
            }
            if (_hotkey == null || _settings == null || !HotkeyGesture.TryParse(HotkeyText, out var current))
            {
                return;
            }

            // While the dialog is open the current shortcut must not fire, so it can be pressed and re-assigned.
            _hotkey.Unregister();
            _hotkeyWindow = new HotkeyWindow(current, gesture =>
            {
                if (!_hotkey.Register(gesture.Modifiers, gesture.Key))
                {
                    return false;
                }

                HotkeyText = gesture.ToString();
                _settings.Hotkey = HotkeyText;
                _settings.Save();
                UpdateTrayStatus();
                _notifications!.ShowToast("Гаряча клавіша змінена", $"Тепер знімок — {HotkeyText}.", ToastKind.Success, 3500);
                return true;
            });
            _hotkeyWindow.Closed += (_, _) =>
            {
                _hotkeyWindow = null;
                if (!_hotkey.IsRegistered && HotkeyGesture.TryParse(HotkeyText, out var previous))
                {
                    _hotkey.Register(previous.Modifiers, previous.Key); // cancelled: restore the old shortcut
                }
            };
            _hotkeyWindow.Show();
            _hotkeyWindow.Activate();
            User32.ForceForeground(new System.Windows.Interop.WindowInteropHelper(_hotkeyWindow).Handle);
        }

        #endregion

        #region Tray

        private TrayMenuWindow? _trayMenu;
        private DateTime _trayMenuClosedAt;

        /// <summary>Raised when anything the tray menu shows has changed (model state, download, settings).</summary>
        private event EventHandler? TrayMenuStateChanged;

        private void InitializeTrayIcon()
        {
            _notifyIcon = new Forms.NotifyIcon
            {
                Icon = AppIcons.CreateTrayIcon(),
                Visible = true
            };
            // A click on the icon is the quickest way to a screenshot; the menu lives on the right button.
            _notifyIcon.MouseUp += (_, args) =>
            {
                if (args.Button == Forms.MouseButtons.Right)
                {
                    ToggleTrayMenu();
                }
                else if (args.Button == Forms.MouseButtons.Left)
                {
                    if (_trayMenu != null && !_trayMenu.IsClosing)
                    {
                        _trayMenu.CloseMenu();
                        return;
                    }
                    // the click that closed the menu (by moving focus) is not a capture request
                    if (DateTime.UtcNow - _trayMenuClosedAt < TimeSpan.FromMilliseconds(250))
                    {
                        return;
                    }
                    TriggerCapture(CaptureTrigger.TrayClick);
                }
            };
            UpdateTrayStatus();
            PromoteTrayIconOnce();
        }

        /// <summary>Windows 11 puts a new icon behind «^»: bring ours onto the taskbar once (see TrayIconPromoter).</summary>
        private void PromoteTrayIconOnce()
        {
            if (_settings == null || _settings.TrayIconPromoted || Environment.ProcessPath is not { } exe)
            {
                return;
            }

            Task.Run(async () =>
            {
                // Explorer writes its entry for a new icon a moment after the icon appears.
                for (int attempt = 0; attempt < 10; attempt++)
                {
                    await Task.Delay(1500);
                    if (!TrayIconPromoter.TryPromote(exe))
                    {
                        continue;
                    }

                    _ = Dispatcher.BeginInvoke(() =>
                    {
                        _settings.TrayIconPromoted = true;
                        _settings.Save();
                        if (_notifyIcon != null)
                        {
                            // re-adding the icon makes Explorer apply the setting right away
                            _notifyIcon.Visible = false;
                            _notifyIcon.Visible = true;
                        }
                        Log.Info("[Tray] Icon moved out of the overflow.");
                    });
                    return;
                }
            });
        }

        /// <summary>The glass tray menu (Views/TrayMenuWindow); a second click on the icon closes it.</summary>
        private void ToggleTrayMenu()
        {
            if (_trayMenu != null && !_trayMenu.IsClosing)
            {
                _trayMenu.CloseMenu();
                return;
            }
            // Clicking the icon while the menu is open first deactivates (closes) it: do not reopen on that click.
            if (DateTime.UtcNow - _trayMenuClosedAt < TimeSpan.FromMilliseconds(250))
            {
                return;
            }

            var menu = new TrayMenuWindow(this);
            menu.Closed += (_, _) =>
            {
                _trayMenuClosedAt = DateTime.UtcNow;
                if (_trayMenu == menu)
                {
                    _trayMenu = null;
                }
            };
            _trayMenu = menu;
            var cursor = Forms.Cursor.Position;
            menu.ShowNear(new System.Drawing.Point(cursor.X, cursor.Y));
        }

        private void SelectMicrophone(MicrophoneInfo mic)
        {
            _settings!.SelectedMicrophoneName = mic.Name;
            _settings.Save();
            _audio!.PreferredMicrophone = mic.Name;
            _notifications!.ShowToast("Мікрофон змінено", mic.DisplayName, ToastKind.Success, 2500);
        }

        private void SetLanguage(string code, string title)
        {
            _settings!.Language = code;
            _settings.Save();
            _transcription!.Language = code;
            _notifications!.ShowToast("Мова голосових коментарів", title, ToastKind.Success, 2500);
        }

        private void SetAutostart(bool enable)
        {
            if (StartupManager.SetRunOnStartup(enable))
            {
                _notifications!.ShowToast("ScreenVoicer", enable ? "Автозапуск увімкнено." : "Автозапуск вимкнено.", ToastKind.Success, 2500);
            }
            else
            {
                _notifications!.ShowToast("Автозапуск", "Не вдалося змінити налаштування автозапуску.", ToastKind.Error);
            }
        }

        private (string Text, TrayStatusKind Kind) DescribeVoiceStatus()
        {
            var t = _transcription;
            if (t == null)
            {
                return ("Запускаюсь…", TrayStatusKind.Busy);
            }

            string where = t.IsRunningOnGpu ? $"{ShortGpuName(t.GpuName)} ({t.GpuBackend})" : "процесор";
            return t.State switch
            {
                ModelState.Ready when t.DownloadingModel != null =>
                    ($"Завантажую «{t.DownloadingModel.Id}»: {t.DownloadProgress:P0}", TrayStatusKind.Busy),
                ModelState.Ready => ($"Голос готовий · {t.ActiveModel?.Id} · {where}", TrayStatusKind.Ready),
                ModelState.Downloading => ($"Завантажую модель «{t.DownloadingModel?.Id}»: {t.DownloadProgress:P0}", TrayStatusKind.Busy),
                ModelState.Failed => ("Голос недоступний — відкрийте «Розпізнавання»", TrayStatusKind.Error),
                _ => ("Модель розпізнавання запускається…", TrayStatusKind.Busy)
            };
        }

        /// <summary>"NVIDIA GeForce GTX 1650" → "GTX 1650": fits the one-line status.</summary>
        private static string ShortGpuName(string? name) =>
            string.IsNullOrWhiteSpace(name) ? "відеокарта"
            : name.Replace("NVIDIA GeForce ", "").Replace("NVIDIA ", "").Replace("AMD Radeon(TM) ", "Radeon ").Replace("AMD ", "").Trim();

        private void UpdateTrayStatus()
        {
            if (_notifyIcon == null || _transcription == null)
            {
                return;
            }

            var t = _transcription;
            string tip = t.State switch
            {
                ModelState.Downloading => $"ScreenVoicer — модель {t.DownloadProgress:P0}",
                ModelState.Failed => "ScreenVoicer — голос недоступний",
                _ => $"ScreenVoicer\nКлік або {HotkeyText} — знімок, правий клік — меню"
            };
            _notifyIcon.Text = tip.Length > 120 ? tip[..120] : tip;
            TrayMenuStateChanged?.Invoke(this, EventArgs.Empty);
        }

        #region ITrayMenuHost

        string ITrayMenuHost.CaptureHotkey => HotkeyText;
        string ITrayMenuHost.AppVersion => Version;
        (string Text, TrayStatusKind Kind) ITrayMenuHost.VoiceStatus => DescribeVoiceStatus();
        int ITrayMenuHost.ScreenshotCount => _history?.CachedCount ?? 0;
        IReadOnlyList<MicrophoneInfo> ITrayMenuHost.GetMicrophones() => _audio?.GetMicrophones() ?? Array.Empty<MicrophoneInfo>();
        string ITrayMenuHost.SelectedMicrophone => _settings?.SelectedMicrophoneName ?? string.Empty;
        bool ITrayMenuHost.CanPlayLastRecording => _audio is { HasLastRecording: true, IsRecording: false };
        string ITrayMenuHost.VoiceLanguage => _settings?.Language ?? "uk";
        WhisperModelInfo ITrayMenuHost.SelectedModel => _transcription?.SelectedModel ?? WhisperModels.Base;
        bool ITrayMenuHost.UseGpu => _settings?.UseGpu ?? true;
        bool ITrayMenuHost.GpuAvailable => _transcription?.IsGpuRuntimeAvailable == true;
        string? ITrayMenuHost.GpuName => _transcription?.GpuName;
        double ITrayMenuHost.CudaProgress => _cudaProgress ?? 0;
        bool ITrayMenuHost.AutostartEnabled => StartupManager.IsRunOnStartupEnabled();

        CudaOffer ITrayMenuHost.Cuda =>
            !CudaPack.HasNvidiaDriver ? CudaOffer.Hidden
            : _transcription?.GpuBackend == "CUDA" ? CudaOffer.Active
            : _cudaProgress != null ? CudaOffer.Downloading
            : CudaPack.IsInstalled ? CudaOffer.NeedsRestart
            : CudaOffer.Offer;

        string ITrayMenuHost.AboutText =>
            $"ScreenVoicer {Version} — скриншоти з голосовими коментарями для баг-репортів і AI-асистентів.\n" +
            $"Розпізнавання: «{_transcription?.ActiveModel?.Id ?? "—"}» на " +
            $"{(_transcription?.IsRunningOnGpu == true ? $"{_transcription.GpuName} ({_transcription.GpuBackend})" : "процесорі")}.\n" +
            $"Скриншоти: {_settings?.OutputDirectory}";

        event EventHandler? ITrayMenuHost.MenuStateChanged
        {
            add => TrayMenuStateChanged += value;
            remove => TrayMenuStateChanged -= value;
        }

        void ITrayMenuHost.Capture() => TriggerCapture(CaptureTrigger.TrayMenu);
        void ITrayMenuHost.CaptureDelayed(int seconds) => TriggerDelayedCapture(seconds);
        void ITrayMenuHost.OpenGallery() => OpenGallery();
        void ITrayMenuHost.OpenScreenshotsFolder() => OpenScreenshotsFolder();
        void ITrayMenuHost.SelectMicrophone(MicrophoneInfo microphone) => SelectMicrophone(microphone);
        void ITrayMenuHost.PlayLastRecording() => _audio?.PlayLastRecording();
        void ITrayMenuHost.SelectModel(WhisperModelInfo model) => SwitchModel(model);
        void ITrayMenuHost.SetUseGpu(bool useGpu) => SetUseGpu(useGpu);
        void ITrayMenuHost.CudaAction() => OnCudaItemClick();
        void ITrayMenuHost.OpenHotkeySettings() => OpenHotkeyWindow();
        void ITrayMenuHost.SetAutostart(bool enabled) => SetAutostart(enabled);
        void ITrayMenuHost.OpenLog() => OpenInExplorer(Log.LogDirectory);
        void ITrayMenuHost.OpenModelsFolder() => OpenInExplorer(WhisperTranscriptionService.DefaultModelDirectory);
        void ITrayMenuHost.Exit() => ExitApplication();
        void ITrayMenuHost.InstallUpdate() => _ = InstallUpdateAsync();
        void ITrayMenuHost.CheckForUpdates() => _ = CheckForUpdatesAsync(manual: true);
        string? ITrayMenuHost.UpdateVersion => _update?.Version.ToString();
        double? ITrayMenuHost.UpdateProgress => _updateProgress;

        void ITrayMenuHost.SetVoiceLanguage(string code)
        {
            var language = Languages.FirstOrDefault(l => l.Code == code);
            if (language.Code != null && _settings?.Language != code)
            {
                SetLanguage(language.Code, language.Title);
                TrayMenuStateChanged?.Invoke(this, EventArgs.Empty);
            }
        }

        private void OpenInExplorer(string folder)
        {
            try
            {
                Directory.CreateDirectory(folder);
                Process.Start(new ProcessStartInfo { FileName = folder, UseShellExecute = true });
            }
            catch (Exception ex)
            {
                Log.Warn($"Could not open '{folder}'", ex);
                _notifications?.ShowToast("Не вдалося відкрити папку", ex.Message, ToastKind.Error);
            }
        }

        #endregion

        #endregion

        #region Capture

        private async void TriggerCapture(CaptureTrigger trigger)
        {
            if (_overlay != null)
            {
                _overlay.BringToFront();
                return;
            }
            if (_captureStarting || _screenCapture == null)
            {
                return;
            }
            _captureStarting = true;

            bool hidGallery = false;
            try
            {
                if (trigger == CaptureTrigger.Gallery && _gallery is { IsVisible: true })
                {
                    _gallery.Hide();
                    hidGallery = true;
                }

                // Toasts, the tray menu fade-out and the countdown must be gone from the screen (DWM needs a
                // frame or two), otherwise they end up in the screenshot.
                bool hadToasts = _notifications!.HideAll();
                int settleMs = trigger switch
                {
                    CaptureTrigger.Hotkey => hadToasts ? 120 : 0,
                    CaptureTrigger.TrayClick => hadToasts ? 150 : 120, // the icon's tooltip has to go first
                    CaptureTrigger.Delayed => hadToasts ? 150 : 60,
                    _ => 280
                };
                if (settleMs > 0)
                {
                    await Task.Delay(settleMs);
                }

                var stopwatch = Stopwatch.StartNew();
                var capture = _screenCapture.CaptureActiveScreen();
                long captureMs = stopwatch.ElapsedMilliseconds;
                var overlay = new OverlayWindow(capture, _audio!, _transcription!, _compositor!, _clipboard!,
                    _notifications, _history!, _settings!, OpenGallery, TriggerDelayedCapture, ShareFromToast);
                Log.Info($"[Capture] {trigger}: {capture.Bounds.Width}x{capture.Bounds.Height} captured in {captureMs} ms, overlay built in {stopwatch.ElapsedMilliseconds - captureMs} ms.");

                overlay.Closed += (_, _) =>
                {
                    _overlay = null;
                    if (hidGallery)
                    {
                        _gallery?.Show();
                    }
                    ReleaseCaptureMemorySoon();
                };

                _overlay = overlay;
                overlay.Show();
            }
            catch (Exception ex)
            {
                Log.Error("[App] Screen capture failed", ex);
                _notifications?.ShowToast("Не вдалося зробити знімок", ex.Message, ToastKind.Error);
                if (hidGallery)
                {
                    _gallery?.Show();
                }
            }
            finally
            {
                _captureStarting = false;
            }
        }

        private async void TriggerDelayedCapture(int seconds)
        {
            if (_overlay != null)
            {
                _overlay.BringToFront();
                return;
            }

            var countdown = new CountdownWindow();
            if (await countdown.RunAsync(seconds))
            {
                TriggerCapture(CaptureTrigger.Delayed);
            }
        }

        /// <summary>A capture holds several full-screen buffers; give them back to Windows once the overlay is gone.</summary>
        private static void ReleaseCaptureMemorySoon()
        {
            Task.Run(async () =>
            {
                await Task.Delay(1500);
                GCSettings.LargeObjectHeapCompactionMode = GCLargeObjectHeapCompactionMode.CompactOnce;
                GC.Collect();
                GC.WaitForPendingFinalizers();
                GC.Collect();
            });
        }

        #endregion

        #region Windows & actions

        private void OpenGallery()
        {
            if (_history == null || _clipboard == null || _settings == null)
            {
                return;
            }

            if (_gallery == null)
            {
                _gallery = new GalleryWindow(_history, _clipboard, _settings, () => TriggerCapture(CaptureTrigger.Gallery), TriggerDelayedCapture,
                    CreateShareAsync, DeleteShareAsync);
                _gallery.Closed += (_, _) => _gallery = null;
                _gallery.Show();
            }
            _gallery.BringToFront();
        }

        private void OpenScreenshotsFolder()
        {
            string folder = _settings?.OutputDirectory ?? SettingsService.DefaultOutputDirectory;
            try
            {
                Directory.CreateDirectory(folder);
                Process.Start(new ProcessStartInfo { FileName = folder, UseShellExecute = true });
            }
            catch (Exception ex)
            {
                Log.Warn($"Could not open '{folder}'", ex);
                _notifications?.ShowToast("Не вдалося відкрити папку", ex.Message, ToastKind.Error);
            }
        }

        private void ShowAbout()
        {
            System.Windows.MessageBox.Show(
                $"ScreenVoicer {Version}\n" +
                "Скриншоти з голосовими коментарями для баг-репортів та AI-асистентів.\n\n" +
                $"• {HotkeyText} — знімок екрана під курсором (змінити: меню трея)\n" +
                "• Миша — виділити область, потім малювати поверх\n" +
                "• P H A R T N E — олівець, маркер, стрілка, рамка, текст, мітки 1-2-3, гумка\n" +
                "• Затиснути Пробіл — голосовий коментар (офлайн, Whisper)\n" +
                "• Enter — зберегти PNG і скопіювати Markdown, Esc — скасувати\n" +
                "• Ctrl+Z / Ctrl+Y — скасувати / повторити\n\n" +
                $"Розпізнавання: «{_transcription?.ActiveModel?.Id}» на " +
                $"{(_transcription?.IsRunningOnGpu == true ? _transcription.GpuName : "процесорі")}\n" +
                $"Скриншоти: {_settings?.OutputDirectory}\n" +
                $"Журнал: {Log.LogFilePath}",
                "Про ScreenVoicer", MessageBoxButton.OK, MessageBoxImage.Information);
        }

        private void ExitApplication()
        {
            Cleanup();
            Shutdown();
        }

        /// <summary>The native Whisper runtime is chosen once per process, so switching to CUDA needs a fresh start.</summary>
        private void RestartApplication()
        {
            string? exe = Environment.ProcessPath;
            if (exe == null)
            {
                return;
            }

            Log.Info("Restarting.");
            Cleanup(); // releases the single-instance mutex and the hotkey for the new process
            try
            {
                Process.Start(new ProcessStartInfo(exe, StartupManager.AutostartArgument) { UseShellExecute = false });
            }
            catch (Exception ex)
            {
                Log.Error("Restart failed", ex);
            }
            Shutdown();
        }

        #region Share links

        /// <summary>Uploads the screenshots (oldest first) behind one link, remembers it and copies it.</summary>
        private async Task<ShareResult?> CreateShareAsync(IReadOnlyList<ScreenshotHistoryItem> items)
        {
            if (items.Count == 0 || _history == null || _clipboard == null)
            {
                return null;
            }

            try
            {
                var ordered = items.OrderBy(i => i.CreatedAt).ToList();
                var share = await ShareService.CreateAsync(ordered);
                await _history.SetShareAsync(ordered.Select(i => i.Id), share);
                _clipboard.CopyToClipboard(share.Url);
                return share;
            }
            catch (Exception ex)
            {
                Log.Warn("[Share] Could not create a link", ex);
                _notifications?.ShowToast("Не вдалося створити посилання",
                    ex is System.Net.Http.HttpRequestException or TaskCanceledException
                        ? $"Немає зв'язку із сервером посилань. Перевірте інтернет. ({ex.Message})"
                        : ex.Message,
                    ToastKind.Error, 7000);
                return null;
            }
        }

        /// <summary>Deletes the link (for every screenshot that shares it) from the server and the history.</summary>
        private async Task<bool> DeleteShareAsync(ScreenshotHistoryItem item)
        {
            if (item.ShareId == null || item.ShareDeleteToken == null || _history == null)
            {
                return false;
            }

            try
            {
                await ShareService.DeleteAsync(item.ShareId, item.ShareDeleteToken);
                var all = await _history.GetHistoryAsync();
                await _history.SetShareAsync(all.Where(i => i.ShareId == item.ShareId).Select(i => i.Id), null);
                return true;
            }
            catch (Exception ex)
            {
                Log.Warn("[Share] Could not delete a link", ex);
                _notifications?.ShowToast("Не вдалося видалити посилання", ex.Message, ToastKind.Error, 6000);
                return false;
            }
        }

        /// <summary>«Посилання» on the toast after a screenshot.</summary>
        private async void ShareFromToast(ScreenshotHistoryItem item)
        {
            var share = await CreateShareAsync(new[] { item });
            if (share != null)
            {
                _notifications?.Show(new ToastOptions
                {
                    Title = "Посилання скопійовано",
                    Message = $"{share.Url} · діє до {share.ExpiresAt.ToString("d MMMM", UkrainianCulture)}",
                    Kind = ToastKind.Success,
                    ImagePath = item.ImagePath,
                    CopyText = share.Url,
                    DurationMs = 6000
                });
            }
        }

        private static readonly System.Globalization.CultureInfo UkrainianCulture = new("uk-UA");

        #endregion

        #region Updates

        private UpdateInfo? _update;
        private double? _updateProgress;
        private System.Windows.Threading.DispatcherTimer? _updateTimer;

        /// <summary>First check shortly after start (not competing with the model load), then twice a day.</summary>
        private void StartUpdateChecks()
        {
            var first = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(25) };
            first.Tick += (_, _) =>
            {
                first.Stop();
                _ = CheckForUpdatesAsync(manual: false);
            };
            first.Start();

            _updateTimer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromHours(12) };
            _updateTimer.Tick += (_, _) => _ = CheckForUpdatesAsync(manual: false);
            _updateTimer.Start();
        }

        private async Task CheckForUpdatesAsync(bool manual)
        {
            if (_updateProgress != null || _cleanedUp)
            {
                return;
            }

            try
            {
                _update = await UpdateService.CheckAsync();
                TrayMenuStateChanged?.Invoke(this, EventArgs.Empty);
                if (_update == null)
                {
                    if (manual)
                    {
                        _notifications?.ShowToast("Оновлень немає", $"У вас найновіша версія {Version}.", ToastKind.Success, 3500);
                    }
                    return;
                }

                Log.Info($"[Update] {_update.Version} is available ({_update.PageUrl}).");
                string version = _update.Version.ToString();
                if (manual || _settings?.UpdateNotifiedVersion != version)
                {
                    if (_settings != null)
                    {
                        _settings.UpdateNotifiedVersion = version;
                        _settings.Save();
                    }
                    string summary = UpdateService.Summary(_update.Notes);
                    _notifications?.Show(new ToastOptions
                    {
                        Title = $"Доступна версія {version}",
                        Message = summary.Length > 0 ? summary : "Нова версія ScreenVoicer готова до встановлення.",
                        Kind = ToastKind.Info,
                        DurationMs = 15000,
                        ActionText = "Оновити",
                        OnAction = () => _ = InstallUpdateAsync()
                    });
                }
            }
            catch (Exception ex)
            {
                Log.Warn("[Update] Check failed", ex);
                if (manual)
                {
                    _notifications?.ShowToast("Не вдалося перевірити оновлення", ex.Message, ToastKind.Warning, 6000);
                }
            }
        }

        /// <summary>Downloads the new installer, then quits so it can replace the exe; it starts the app again.</summary>
        private async Task InstallUpdateAsync()
        {
            var update = _update;
            if (update == null || _updateProgress != null)
            {
                return;
            }

            _updateProgress = 0;
            TrayMenuStateChanged?.Invoke(this, EventArgs.Empty);
            _notifications?.ShowToast($"Оновлення до {update.Version}",
                $"Завантажую {update.Size / 1048576.0:F0} МБ… Програма перезапуститься сама.", ToastKind.Info, 5000);

            var progress = new Progress<double>(p =>
            {
                if ((int)(p * 100) != (int)((_updateProgress ?? 0) * 100))
                {
                    _updateProgress = p;
                    TrayMenuStateChanged?.Invoke(this, EventArgs.Empty);
                }
            });

            try
            {
                string installer = await UpdateService.DownloadAsync(update, progress);
                Log.Info($"[Update] Installing {update.Version}, restarting.");
                UpdateService.LaunchInstallerAfterExit(installer);
                Cleanup();
                Shutdown();
            }
            catch (Exception ex)
            {
                Log.Error("[Update] Update failed", ex);
                _updateProgress = null;
                TrayMenuStateChanged?.Invoke(this, EventArgs.Empty);
                _notifications?.ShowToast("Не вдалося оновитися", ex.Message, ToastKind.Error, 8000);
            }
        }

        /// <summary>
        /// <c>ScreenVoicer.exe --update</c>: the same update as the tray button, without the UI. Close the running
        /// copy first — the installer waits for it.
        /// </summary>
        private static async Task<int> UpdateFromCommandLineAsync()
        {
            try
            {
                var update = await UpdateService.CheckAsync();
                if (update == null)
                {
                    Console.WriteLine($"Up to date ({UpdateService.CurrentVersion}).");
                    return 0;
                }
                string installer = await UpdateService.DownloadAsync(update, null);
                UpdateService.LaunchInstallerAfterExit(installer);
                Console.WriteLine($"Installing {update.Version} from {installer}.");
                return 0;
            }
            catch (Exception ex)
            {
                Log.Error("[Update] Command-line update failed", ex);
                Console.WriteLine("Failed: " + ex.Message);
                return 1;
            }
        }

        /// <summary><c>ScreenVoicer.exe --check-update</c>: prints what the updater sees (for testing releases).</summary>
        private static async Task<int> CheckUpdateFromCommandLineAsync()
        {
            try
            {
                var update = await UpdateService.CheckAsync();
                Console.WriteLine(update == null
                    ? $"Up to date ({UpdateService.CurrentVersion})."
                    : $"Update {update.Version} available: {update.InstallerUrl} ({update.Size} bytes, sha256 {update.Sha256 ?? "n/a"})");
                return 0;
            }
            catch (Exception ex)
            {
                Console.WriteLine("Failed: " + ex.Message);
                return 1;
            }
        }

        #endregion

        #region NVIDIA CUDA pack

        private double? _cudaProgress;

        private async void OnCudaItemClick()
        {
            if (CudaPack.IsInstalled)
            {
                RestartApplication();
                return;
            }
            if (_cudaProgress != null)
            {
                return;
            }

            _cudaProgress = 0;
            UpdateTrayStatus();
            _notifications!.ShowToast("Прискорення NVIDIA CUDA",
                $"Завантажую {CudaPack.DownloadMegabytes} МБ (один раз). Тим часом усе працює як звичайно.", ToastKind.Info, 5000);

            var progress = new Progress<double>(p =>
            {
                if (_cudaProgress != null && (int)(p * 100) != (int)(_cudaProgress.Value * 100))
                {
                    _cudaProgress = p;
                    UpdateTrayStatus();
                }
            });

            try
            {
                await Task.Run(() => CudaPack.InstallAsync(progress, CancellationToken.None));
                _cudaProgress = null;
                UpdateTrayStatus();
                _notifications.Show(new ToastOptions
                {
                    Title = "Прискорення CUDA встановлено",
                    Message = "Перезапустіть ScreenVoicer, щоб розпізнавання перейшло на CUDA.",
                    Kind = ToastKind.Success,
                    DurationMs = 20000,
                    ActionText = "Перезапустити",
                    OnAction = RestartApplication
                });
            }
            catch (Exception ex)
            {
                Log.Error("[CUDA] Installation failed", ex);
                _cudaProgress = null;
                UpdateTrayStatus();
                _notifications.ShowToast("Не вдалося встановити CUDA", ex.Message, ToastKind.Error, 8000);
            }
        }

        /// <summary>
        /// <c>ScreenVoicer.exe --install-cuda</c>: the same download without the UI (prints progress if
        /// the output is redirected).
        /// </summary>
        private static async Task<int> InstallCudaFromCommandLineAsync()
        {
            if (!CudaPack.HasNvidiaDriver)
            {
                Console.WriteLine("No NVIDIA driver (nvcuda.dll) found.");
                return 2;
            }
            if (CudaPack.IsInstalled)
            {
                Console.WriteLine($"Already installed in {CudaPack.RuntimeDirectory}.");
                return 0;
            }

            int lastPercent = -1;
            var progress = new SynchronousProgress(p =>
            {
                int percent = (int)(p * 100);
                if (percent / 5 != lastPercent / 5)
                {
                    lastPercent = percent;
                    Console.WriteLine($"{percent}%");
                }
            });
            try
            {
                await CudaPack.InstallAsync(progress, CancellationToken.None);
                Console.WriteLine($"Installed to {CudaPack.RuntimeDirectory}.");
                return 0;
            }
            catch (Exception ex)
            {
                Log.Error("[CUDA] Installation failed", ex);
                Console.WriteLine("Failed: " + ex.Message);
                return 1;
            }
        }

        private sealed class SynchronousProgress : IProgress<double>
        {
            private readonly Action<double> _report;
            public SynchronousProgress(Action<double> report) => _report = report;
            public void Report(double value) => _report(value);
        }

        #endregion

        protected override void OnSessionEnding(SessionEndingCancelEventArgs e)
        {
            Cleanup();
            base.OnSessionEnding(e);
        }

        protected override void OnExit(ExitEventArgs e)
        {
            Cleanup();
            base.OnExit(e);
        }

        private void Cleanup()
        {
            if (_cleanedUp)
            {
                return;
            }
            _cleanedUp = true;
            if (_singleInstanceMutex != null)
            {
                Log.Info("ScreenVoicer exiting."); // only the instance that actually ran, not a second launch
            }

            try { _overlay?.Close(); } catch { }
            _notifications?.HideAll();

            if (_notifyIcon != null)
            {
                _notifyIcon.Visible = false;
                _notifyIcon.Dispose();
                _notifyIcon = null;
            }

            _hotkey?.Dispose();
            _audio?.Dispose();
            _transcription?.Dispose();

            _showGalleryWait?.Unregister(null);
            _showGalleryEvent?.Dispose();

            if (_singleInstanceMutex != null)
            {
                try { _singleInstanceMutex.ReleaseMutex(); } catch { }
                _singleInstanceMutex.Dispose();
                _singleInstanceMutex = null;
            }
        }

        #endregion
    }
}
