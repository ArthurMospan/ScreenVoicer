# Windows ↔ macOS parity

Both apps must look and behave the same (see `CLAUDE.md`). This file lists what still differs.

## Pending

- Nothing. The macOS app (`mac/`, since 1.11.0) does everything the Windows app does up to 1.10.0, share links included.

## Allowed differences (forced by the OS)

- **Default hotkey**: ⌥⇧S on Mac = Alt+Shift+S on Windows, the same keys. macOS writes shortcuts as symbols (⌥⇧S, ⌘Z), so the UI shows them that way. Undo/redo are ⌘Z / ⇧⌘Z instead of Ctrl+Z / Ctrl+Y; search is ⌘F.
- **Menu bar instead of tray**: the same glass menu, opened from the menu-bar icon (a monochrome template of the logo, as macOS requires) instead of the tray. There is no double-click on menu-bar icons, so «double-click = capture» exists only on Windows.
- **Wording that names the OS**: «Запуск з macOS» / «Запуск з Windows», «Показати у Finder» / «Показати в провіднику», «Вставте (⌘V)» / «Вставте (Ctrl+V)», «ScreenVoicer працює в рядку меню» / «…у треї».
- **Permissions**: macOS needs Screen Recording and Microphone consent, so the Mac app has a «Дозволи для ScreenVoicer» window (first run, or when access is missing). Windows needs nothing.
- **Install and Gatekeeper**: Windows has an installer; Mac has a zip with the app, a one-time «Все одно відкрити» in System Settings, and an offer to move itself into «Програми».
- **GPU**: Windows uses Vulkan and the optional NVIDIA CUDA pack; Mac uses Metal, so the CUDA menu row and toasts don't exist there. The «GPU crashed last time» safety switch is Windows-only (driver crashes).
- **Fonts**: the system UI font of each OS (Segoe UI Variable / SF Pro) at the same sizes and weights.
- **Data locations**: `~/AI_Screenshots` (Windows `C:\AI_Screenshots`), `~/Library/Application Support/ScreenVoicer` (Windows `%APPDATA%\ScreenVoicer`), logs in `~/Library/Logs/ScreenVoicer`.

## Where the twins live

| Windows | macOS |
| :--- | :--- |
| `App.xaml` tokens, `Icon.*`, `BrandMark` | `mac/Sources/ScreenVoicer/UI/Theme.swift`, `UI/Icons.swift` (same values, same path data) |
| `App.xaml.cs` | `AppDelegate.swift` |
| `Views/OverlayWindow.xaml(.cs)` | `Overlay/OverlayController.swift`, `OverlayChrome.swift`, `OverlayViews.swift`, `Annotations.swift` |
| `Views/TrayMenuWindow` | `UI/TrayMenu.swift` |
| `Views/GalleryWindow` | `UI/Gallery.swift` |
| `Views/ToastWindow`, `NotificationService` | `UI/Toast.swift` |
| `Views/HotkeyWindow`, `CountdownWindow` | `UI/HotkeyWindow.swift`, `UI/Countdown.swift` |
| `Services/*.cs` | `Core/*.swift` (same names) |
