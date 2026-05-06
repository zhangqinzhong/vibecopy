# VibeCopy Settings, Theme, Language, and Input Stability Plan

## Summary

- Add a native settings window using `NSWindowController + NSHostingController`, keeping the current AppKit app entrypoint.
- Add shared settings for theme and translation language preferences.
- Add Apple Translation language discovery, status refresh, and language-pack preparation using public Translation framework APIs.
- Stabilize source text input so trailing spaces and pinyin marked text are not rewritten while typing.

## Implementation

- Introduce `AppSettingsModel` as the shared `ObservableObject` owned by `AppDelegate`.
- Add a SwiftUI settings window with `通用`, `外观`, `语言`, and `关于` panes.
- Persist theme preference and source/target language identifiers in `UserDefaults`.
- Wire the island gear button and status bar Settings menu item to open Settings.
- Bind source/target language menus in the island to the supported Translation language list.
- Use `LanguageAvailability.supportedLanguages` and `status(from:to:)` for language status; use `.translationTask` + `prepareTranslation()` for language-pack preparation.
- Avoid private system hooks for language-pack download completion; refresh status after public prepare/download flows and when Settings opens.
- Reserve closed-island left/right side semantics: left for translation, right for future clipboard history. Use lightweight local pixel glyph placeholders for now.
- Preserve original source text in the UI while sending a trimmed copy to Translation framework for requests.
- Avoid syncing SwiftUI text state while `NSTextView.hasMarkedText()` is true.

## Test Plan

- `swift build`
- `git diff --check`
- `./scripts/build-app.sh debug`
- Manual: click gear and status bar Settings item, switch theme, reopen app and confirm persistence.
- Manual: choose source/target languages, swap languages, refresh language status, and trigger language-pack preparation.
- Manual: type `你好 ` and confirm trailing space remains; type with Chinese pinyin IME and confirm composition is not interrupted.
- Manual: type `123` and confirm it returns `123` instead of a translation failure.

## Assumptions

- Theme options are `跟随系统`, `浅色`, and `深色`; default is follow system.
- Supported language list comes from Apple Translation framework rather than a custom static full locale list.
- System language-pack downloads are owned by macOS; VibeCopy uses public API status refresh rather than private notifications.
- Clipboard history on the right closed-island side is intentionally deferred.
