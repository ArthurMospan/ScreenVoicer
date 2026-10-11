# ScreenVoicer: rules for Claude

## Windows ↔ macOS parity (top priority)

ScreenVoicer ships for Windows (repo root, WPF / .NET 8) and macOS (`mac/`). The owner's rule: both apps look the same and do the same things. A change made on one platform is made on the other too.

- Any user-visible change goes into both apps in the same piece of work and ships in the same version. That covers features, behaviour, Ukrainian wording, colours, icons, the logo, hotkey behaviour, the clipboard format and file naming.
- If the other platform can't be done right now (for example, the session runs on Windows and can't build the Mac app), add the item to `PARITY.md` under «Pending» and tell the owner. Never let the apps drift silently.
- The apps may differ only where the OS forces it: shortcut keys, tray vs menu bar, installer vs zip, permission prompts. Record each such difference in `PARITY.md`.
- One version number and one `CHANGELOG.md` for both apps. A release tag publishes the assets of both.
- Talk to the owner in Ukrainian: short, clear, practical. They are not a developer.

## Working on both apps

- The map of twin files (App.xaml ↔ Theme.swift/Icons.swift, OverlayWindow ↔ Overlay/*, …) is in `PARITY.md` → «Where the twins live».
- The Mac app is built and tested by `.github/workflows/mac.yml` on every push that touches `mac/`: a headless self-test, `--snapshots` (PNG of every window) and `--ui-test` (real windows, real capture, synthetic mouse and keys). After a UI change, download the `snapshots` artifact and look at it.
- A release tag builds both apps (`.github/workflows/release.yml`); it fails if either one fails.

## The site follows the apps

The site (`landing/`, https://sv.mospan.com.ua) must show what the apps really do.

- Every user-visible app change also updates the site in the same piece of work: a new feature gets its line or scene, a changed one gets its wording or picture fixed, a removed one disappears. The changelog entry and the site change ship together.
- Customer-facing text (the site, app UI, toasts, release notes) never names technical internals: no Whisper, whisper.cpp, GGML, model file names, GitHub. Say what the user gets: «розпізнається на вашому комп'ютері, офлайн». A hardware setting says what it does («Прискорення NVIDIA»), not which library does it. Technical detail belongs in the README files.
- Check the site at phone width too: it must be as good on a phone as on a desktop.
