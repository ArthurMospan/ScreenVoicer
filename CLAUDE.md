# ScreenVoicer: rules for Claude

## Windows ↔ macOS parity (top priority)

ScreenVoicer ships for Windows (repo root, WPF / .NET 8) and macOS (`mac/`). The owner's rule: both apps look the same and do the same things. A change made on one platform is made on the other too.

- Any user-visible change goes into both apps in the same piece of work and ships in the same version. That covers features, behaviour, Ukrainian wording, colours, icons, the logo, hotkey behaviour, the clipboard format and file naming.
- If the other platform can't be done right now (for example, the session runs on Windows and can't build the Mac app), add the item to `PARITY.md` under «Pending» and tell the owner. Never let the apps drift silently.
- The apps may differ only where the OS forces it: shortcut keys, tray vs menu bar, installer vs zip, permission prompts. Record each such difference in `PARITY.md`.
- One version number and one `CHANGELOG.md` for both apps. A release tag publishes the assets of both.
- Talk to the owner in Ukrainian: short, clear, practical. They are not a developer.
