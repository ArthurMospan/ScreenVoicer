# Installer artwork

`installer.iss` (repo root) builds `ScreenVoicer-Setup.exe` with Inno Setup 6.7+ in the dark, branded wizard. `mac/scripts/dmg.sh` builds `ScreenVoicer-macOS.dmg`. Both use pictures drawn from `art.html`, so the logo is the same vector everywhere.

| File | What | How it was rendered from `art.html` |
| :--- | :--- | :--- |
| `wizard-100/150/200/250.png` | Left picture of the Windows welcome and finish screens | `?kind=big`, viewport 164×314, device scale 1 / 1.5 / 2 / 2.5 |
| `small-100/150/200/250.png` | Top-right logo while installing | `?kind=small`, viewport 55×55, device scale 1 / 1.5 / 2 / 2.5 |
| `../mac/Resources/dmg-background.png`, `@2x` | The Mac DMG window | `?kind=dmg`, viewport 660×420, device scale 1 / 2 |

Chrome DevTools: emulate the viewport with the device scale, open the page, take a screenshot of the viewport.

The DMG background is light on purpose: over a background picture Finder always draws dark icon labels, whatever the system appearance. The icon positions in `mac/scripts/dmg-settings.py` (170, 206 and 490, 206) match the arrow in the picture.
