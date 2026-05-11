# VibeCopy

VibeCopy 是一个 macOS 菜单栏应用原型，把划词翻译、截图 OCR 翻译、剪贴板历史和翻译浮窗组合在一起。

当前版本是原生 Swift/AppKit + SwiftUI 实现，不依赖 WebUI、WKWebView、Node 前端。

## 当前能力

- 菜单栏入口：划词翻译、打开翻译窗口、截图 OCR 翻译、剪贴板历史、设置、退出。
- 翻译岛：notch 顶部浮窗、打开/收起动画、手动输入翻译、语言临时切换、语言交换、复制、朗读、标识符格式复制。
- 设置页：通用、快捷键、外观、语言、关于。
- 默认翻译方向：设置页保存应用默认值；每次新打开翻译岛都会从设置默认值初始化。翻译岛内的语言切换只影响当前会话。
- 全局快捷键：可在设置页开启/关闭并自定义划词翻译快捷键（默认 `⌥D`）和剪贴板历史快捷键（默认 `⌥C`）；如果快捷键被系统或其他 App 占用，设置页会显示冲突提示。
- 主题：跟随系统、浅色、深色；设置窗口和翻译岛共享主题设置。
- 语言包管理：使用 Apple Translation framework 查询系统支持语言和单语言包状态，未下载语言可触发系统下载流程。
- 截图 OCR：区域选择后用 Vision OCR 识别，再交给 Apple Translation framework 翻译。
- 剪贴板历史：支持文本、链接、图片和文件历史，带搜索、筛选、回写、Esc 快速关闭和本地持久化。
- 朗读：使用 `AVSpeechSynthesizer`。

## 本地运行

```bash
swift run VibeCopy
```

或使用一键开发运行脚本，它会先关闭旧进程再启动最新版：

```bash
scripts/run-dev.sh
```

运行后应用出现在 macOS 菜单栏，菜单栏按钮显示为 `VC`。

## 构建 .app

```bash
chmod +x scripts/*.sh
scripts/build-app.sh release
open dist/VibeCopy.app
```

## 打包 .dmg

```bash
scripts/create-dmg.sh
```

生成文件：

```text
dist/VibeCopy.dmg
```

## GitHub Release

推送 `v*` tag 会触发 GitHub Actions 自动构建 DMG 并上传到 GitHub Release：

```bash
git tag v0.1.1
git push origin v0.1.1
```

## Translation 语言包

VibeCopy 使用 Apple Translation framework。系统语言包由 macOS 管理：

- 应用可以查询语言包是否已下载或可下载。
- 应用可以通过 `prepareTranslation()` 触发系统下载确认流程。
- Apple 公共 API 不提供真实下载进度、下载速度或后台任务状态。
- 应用不能绕过系统 UI 静默安装 Translation 语言包。

## 当前限制

- 闭合岛右侧可点击打开剪贴板历史；hover 打开仍保留给左侧翻译入口。
- 截图选择当前以主屏为主，多显示器体验还需要继续打磨。
- 剪贴板历史的富文本内容还未单独建模。
- 首次启动权限引导还未实现，包括屏幕录制、辅助功能和通知权限。

## 工程备注

- SwiftPM target 当前链接 `AppKit`、`Carbon`、`Vision`、`SwiftUI`、`Translation`、`AVFoundation`、`ScreenCaptureKit`。
- `Package.swift` 当前平台配置为 macOS 26.0。
- `changelog/` 记录产品和实现演进；`docs/plans/` 记录阶段性实现计划。
