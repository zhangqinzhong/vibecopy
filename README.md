# VibeCopy

[中文](/zhangqinzhong/vibecopy/blob/main/README_ZH.md) | English

---

VibeCopy is a macOS menu bar app that combines text selection translation, screenshot OCR translation, clipboard history, and a Dynamic Island-style floating panel into a seamless multilingual workflow.

Built with native Swift/AppKit + SwiftUI — no WebUI, WKWebView, Node frontend, or third-party translation app dependencies.

## Features

- **Translation Island** — A notch-aware floating panel with open/collapse animation, manual text input, language switching, swap direction, copy, text-to-speech, and identifier-case conversion (camelCase / snake_case).
- **Selection Translation** — Select any text and press the hotkey (default `⌥D`) to translate. Reads selection via Accessibility API with a Cmd+C fallback — no intrusive popups.
- **Screenshot OCR Translation** — Capture a screen region, recognize text with Vision OCR, then translate via Apple's Translation framework.
- **Clipboard History** — Automatically records text, links, images, and files. Search, filter by type, one-click paste-back, Esc to close, local JSON persistence.
- **Global Hotkeys** — Toggle and customize shortcuts for selection translation and clipboard history in Settings. Conflict detection via Carbon API with user-facing alerts.
- **Settings Center** — 5 tabs: General, Shortcuts, Appearance, Language, About. All changes take effect immediately and persist to UserDefaults.
- **Themes** — System, Light, and Dark modes. Settings window and Translation Island share the same theme.
- **Language Pack Management** — Built on Apple's Translation framework. Query system-supported languages, check download status, and trigger system download flows.
- **Text-to-Speech** — Reads source or translated text aloud using `AVSpeechSynthesizer`.

## Quick Start

```bash
# One-command dev run (kills old process, builds, launches)
scripts/run-dev.sh

# Or direct SwiftPM build and run
swift run VibeCopy
```

After launch, the app appears in the macOS menu bar as `VC`.

## Build & Package

```bash
# Build .app bundle
scripts/build-app.sh release
open dist/VibeCopy.app

# Package as .dmg
scripts/create-dmg.sh
# → dist/VibeCopy.dmg
```

## GitHub Release

Push a `v*` tag to trigger GitHub Actions — automatically builds the DMG and publishes it:

```bash
git tag v0.1.1 && git push origin v0.1.1
```

## Architecture

```
AppDelegate (composition root)
├── StatusBarController         ← menu bar VC entry + dropdown
├── AppSettingsModel            ← @Published → UserDefaults sync
├── ClipboardMonitor            ← polls NSPasteboard every 0.7s, JSON persistence
├── TranslationService          ← wraps Apple TranslationSession
├── ScreenshotCoordinator       ← screenshot → OCR → translate pipeline
├── SelectionTranslator         ← Accessibility API / Cmd+C fallback
├── SelectionTranslationWindowController  ← Translation Island (~1700 lines)
├── ClipboardHistoryWindowController      ← SwiftUI clipboard history panel
├── SettingsWindowController    ← 5-tab settings window
└── GlobalHotKeyManager         ← Carbon RegisterEventHotKey
```

## Translation Language Packs

VibeCopy uses Apple's Translation framework. System language packs are managed by macOS:

- The app can check whether a language pack is installed or available for download.
- The app can trigger the system download dialog via `prepareTranslation()`.
- Apple's public API does not expose real download progress, speed, or background task status.
- The app cannot silently install language packs — system UI confirmation is required.

## Known Limitations

- Screenshot region selection on multi-monitor setups needs improvement.
- Clipboard history does not model rich text separately.
- No first-launch permission onboarding flow (Screen Recording, Accessibility, Notifications).

## Roadmap

### Completed

- [x] Selection translation + Translation Island floating panel
- [x] Screenshot OCR translation
- [x] Clipboard history (search, filter, paste-back, persistence)
- [x] Global hotkeys + conflict detection
- [x] Theme switching (System / Light / Dark)
- [x] Language pack management
- [x] Text-to-speech
- [x] GitHub Actions CI/CD for releases

### Near Term

- [ ] Clipboard history embedded in the Island (right-side panel)
- [ ] Multi-monitor screenshot improvements
- [ ] First-launch permission onboarding (Screen Recording, Accessibility)
- [ ] Rich text clipboard support
- [ ] Translation favorites & history

### Mid Term

- [ ] iCloud sync for clipboard history
- [ ] Third-party translation engines (DeepL, Google Translate, etc.)
- [ ] Screenshot annotation & editing tools
- [ ] Popup bubble mode for selection translation
- [ ] On-device ML translation models

### Long Term

- [ ] Plugin system for community extensions
- [ ] AI writing assistant (polish, summarize, continue)
- [ ] iOS companion app
- [ ] Team clipboard sharing

## Technical Notes

- SwiftPM target linking `AppKit`, `Carbon`, `Vision`, `SwiftUI`, `Translation`, `AVFoundation`, `ScreenCaptureKit`.
- `Package.swift` platform set to macOS 15.0.
- `changelog/` tracks product and implementation evolution.
- All UI labels are in Simplified Chinese.

## License

MIT License
