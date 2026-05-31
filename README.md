# VibeCopy

[English](/zhangqinzhong/vibecopy/blob/main/README_EN.md) | 中文

---

VibeCopy 是一个 macOS 菜单栏应用，将划词翻译、截图 OCR 翻译、剪贴板历史和灵动岛浮窗组合在一起，提供无缝的多语言工作体验。

当前版本是原生 Swift/AppKit + SwiftUI 实现，无 WebUI、WKWebView、Node 前端或第三方翻译应用依赖。

## 功能

- **翻译岛** — Notch 顶部灵动岛风格浮窗，支持打开/收起动画、手动输入翻译、语言切换、语言交换、复制、朗读、标识符格式转换（驼峰/蛇形）。
- **划词翻译** — 选中任意文本，按快捷键（默认 `⌥D`）即可翻译。通过 Accessibility API 读取选区，无侵入式体验。
- **截图 OCR 翻译** — 区域选择截图后，使用 Vision OCR 识别文字，再交给 Apple Translation framework 翻译。
- **剪贴板历史** — 自动记录文本、链接、图片和文件历史。支持搜索、分类筛选、一键回写粘贴、Esc 快速关闭，本地 JSON 持久化。
- **全局快捷键** — 可在设置中开启/关闭并自定义划词翻译快捷键和剪贴板历史快捷键。冲突检测通过 Carbon API 实现，冲突时显示提示。
- **设置中心** — 5 个标签页：通用、快捷键、外观、语言、关于。所有设置即时生效并持久化到 UserDefaults。
- **主题** — 跟随系统、浅色、深色三种模式，设置窗口和翻译岛共享主题。
- **语言包管理** — 基于 Apple Translation framework，查询系统支持语言及下载状态，可触发系统下载流程。
- **朗读** — 使用 `AVSpeechSynthesizer` 朗读原文或译文。

## 本地运行

```bash
# 一键开发运行（先关闭旧进程再构建启动）
scripts/run-dev.sh

# 或直接 SwiftPM 构建运行
swift run VibeCopy
```

运行后应用出现在 macOS 菜单栏，显示为 `VC`。

## 构建与打包

```bash
# 构建 .app
scripts/build-app.sh release
open dist/VibeCopy.app

# 打包 .dmg
scripts/create-dmg.sh
# → dist/VibeCopy.dmg
```

## GitHub Release

推送 `v*` tag 触发 GitHub Actions 自动构建 DMG 并发布：

```bash
git tag v0.1.1 && git push origin v0.1.1
```

## 架构概览

```
AppDelegate (组合根)
├── StatusBarController         ← 菜单栏 VC 入口
├── AppSettingsModel            ← @Published → UserDefaults 同步
├── ClipboardMonitor            ← 每 0.7s 轮询 NSPasteboard，JSON 持久化
├── TranslationService          ← 封装 Apple TranslationSession
├── ScreenshotCoordinator       ← 截图 → OCR → 翻译 流程编排
├── SelectionTranslator         ← Accessibility API / Cmd+C 回退 读取选区
├── SelectionTranslationWindowController  ← 翻译岛浮窗 (~1700 行)
├── ClipboardHistoryWindowController      ← SwiftUI 剪贴板历史面板
├── SettingsWindowController    ← 5 标签页设置窗口
└── GlobalHotKeyManager         ← Carbon RegisterEventHotKey
```

## Translation 语言包

VibeCopy 使用 Apple Translation framework。系统语言包由 macOS 管理：

- 可查询语言包是否已下载或可下载。
- 可通过 `prepareTranslation()` 触发系统下载确认流程。
- Apple 公共 API 不提供真实下载进度、速度或后台任务状态。
- 应用不能绕过系统 UI 静默安装语言包。

## 当前限制

- 多显示器场景下截图区域选择体验待优化。
- 剪贴板历史不支持富文本单独建模。
- 首次启动缺少权限引导流程（屏幕录制、辅助功能、通知）。

## 演进路线

### 已完成

- [x] 划词翻译 + 翻译岛灵动岛浮窗
- [x] 截图 OCR 翻译
- [x] 剪贴板历史（搜索、筛选、回写、持久化）
- [x] 全局快捷键 + 冲突检测
- [x] 主题切换（系统 / 浅色 / 深色）
- [x] 语言包管理
- [x] 朗读 (TTS)
- [x] GitHub Actions 自动构建发布

### 近期计划

- [ ] 剪贴板历史嵌入灵动岛右侧
- [ ] 多显示器截图优化
- [ ] 首次启动权限引导（屏幕录制、辅助功能）
- [ ] 富文本剪贴板支持
- [ ] 翻译结果收藏与历史记录

### 中期路线

- [ ] iCloud 同步剪贴板历史
- [ ] 接入第三方翻译引擎（DeepL、Google Translate 等）
- [ ] 截图标注与编辑工具
- [ ] 划词翻译弹出气泡模式
- [ ] 离线翻译模型支持

### 长期愿景

- [ ] 插件系统，支持社区扩展
- [ ] AI 写作辅助（润色、摘要、续写）
- [ ] iOS 配套应用
- [ ] 团队剪贴板共享

## 工程备注

- SwiftPM target，链接 `AppKit`、`Carbon`、`Vision`、`SwiftUI`、`Translation`、`AVFoundation`、`ScreenCaptureKit`。
- `Package.swift` 当前平台配置为 macOS 15.0。
- `changelog/` 记录产品和实现演进。
- 所有用户界面文本为简体中文。

## 许可

MIT License
