# VibeCopy

VibeCopy 是一个 macOS 菜单栏应用原型，目标是把三类能力组合在一起：

- 截屏区域选择
- OCR 识别与翻译
- 剪贴板历史与回写

翻译浮窗采用 Swift/AppKit 宿主 + SwiftUI 原生界面：窗口、动画、输入、按钮操作、翻译状态都在 Swift 内完成，不再依赖 WebUI、WKWebView 或 Node 前端构建链路。

## 本地运行

```bash
swift run VibeCopy
```

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

## 下一步建议

1. 增加设置页，允许切换快捷指令名称和超时时间。
2. 使用 ScreenCaptureKit 替换当前的基础截图实现，完善多显示器支持。
3. 扩展剪贴板历史类型，支持图片、文件、富文本和搜索。
4. 加入首次启动权限引导：屏幕录制、辅助功能、通知权限。
