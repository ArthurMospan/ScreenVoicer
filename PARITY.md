# Windows ↔ macOS parity

Both apps must look and behave the same. This file lists what still differs.

## Pending

- Nothing. Both apps have the same features, «Приховати» (B) and the region's resize handles included (1.12.0).

## Allowed differences (forced by the OS)

- **Default hotkey**: ⌥⇧S on Mac = Alt+Shift+S on Windows, the same keys. macOS writes shortcuts as symbols (⌥⇧S, ⌘Z), so the UI shows them that way. Undo/redo are ⌘Z / ⇧⌘Z instead of Ctrl+Z / Ctrl+Y; search is ⌘F.
- **Menu bar instead of tray**: the same icon behaviour (left click = capture, right click = the glass menu; on Mac ⌃-click works too), but in the menu bar, with a monochrome template of the logo as macOS requires. Only Windows 11 needs the «move the icon out of the ^ overflow» step.
- **Wording that names the OS**: «Запуск з macOS» / «Запуск з Windows», «Показати у Finder» / «Показати в провіднику», «Вставте (⌘V)» / «Вставте (Ctrl+V)», «ScreenVoicer працює в рядку меню» / «…у треї».
- **Permissions**: macOS needs Screen Recording and Microphone consent, so the Mac app has a «Дозволи для ScreenVoicer» window (first run, or when access is missing). Windows needs nothing.
- **Install and Gatekeeper**: Windows has an installer (`ScreenVoicer-Setup.exe`, the dark brand look, «Встановити» → «Готово»). Mac has a DMG with the same brand (drag the app onto «Програми»), a one-time «Все одно відкрити» in System Settings, and an offer to move itself into «Програми». The Mac updater uses `ScreenVoicer-macOS.zip`; the Windows one runs the installer silently. The DMG background is light because Finder always draws dark labels over a picture.
- **Autostart at install**: both apps start with the system after the first install (the Windows installer writes the Run key, the Mac app turns its login item on at first start); updates keep the user's choice.
- **GPU**: Windows uses Vulkan and the optional NVIDIA CUDA pack; Mac uses Metal, so the CUDA menu row and toasts don't exist there. The «GPU crashed last time» safety switch is Windows-only (driver crashes).
- **Resize cursors**: macOS 14 has no public diagonal resize cursor, so the region's corner handles show the crosshair there; macOS 15+ and Windows show diagonal arrows. Edge handles show ↔ / ↕ everywhere.
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
