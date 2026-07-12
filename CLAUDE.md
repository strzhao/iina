# IINA — 项目协作规范

> 本文件供 AI 协作（autopilot / Claude Code）加载。用户全局规范见 `~/.claude/CLAUDE.md`。

## 项目概述

IINA 是 macOS 原生媒体播放器，基于 **libmpv**（mpv 核心）。纯 **Swift / Cocoa / AppKit**，无 Web 层。

- 主仓库：`iina/`（app 源码）+ `iina.xcodeproj`
- 辅助 target：`iina-cli`（命令行）、`iina-plugin`（插件层）、`OpenInIINA/`（浏览器扩展）
- 依赖：`deps/` 预构建 dylib（libmpv / ffmpeg / etc.），由 `other/download_libs.sh` 获取

## 构建与运行

```bash
# 首次/依赖缺失时获取预构建 dylib（链接失败先跑这个）
./other/download_libs.sh --arch arm64

# 构建（Debug）
xcodebuild -project iina.xcodeproj -scheme iina -configuration Debug -destination 'platform=macOS' build

# 产物
~/Library/Developer/Xcode/DerivedData/iina-*/Build/Products/Debug/IINA.app
```

**链接错误 ≠ 代码问题**：`ld: library 'XXX.0' not found` 先排查 deps 完整性（`other/download_libs.sh`），再查代码。历史遗留 copy phase（libstdc++.6 / libgcc_s.1.1）缺失时用 `clang -dynamiclib -o <path> -xc -` 创建空 stub。

## 模块边界

- `iina/MediaLibrary/` — 媒体库视频墙（启动首页）。核心类：`MediaLibraryViewController`（网格墙）、`MediaLibraryStore`（单例，扫描索引+查询）、`MediaLibraryScanner`（NAS 扫描）、`MediaItem`（数据模型）、`EpisodeListViewController`（单集列表）、`FileNameCleaner`（片名清洗）、`MediaThumbnailer`（FFmpegController 抽帧）
- `iina/FFmpegController.{h,m}` — 缩略图抽帧（链接 libavcodec，支持 mkv/ts/flv，单实例串行）
- 视频墙数据流：Scanner 扫 NAS → Store 持久化 index.plist → ViewController 查询渲染 → 缩略图按需生成

## Cocoa/AppKit 约定

- GUI 全部 code-built（无 xib），`loadView()` 内构造 NSView + Auto Layout 约束
- `NSCollectionView` **必须显式设** `collectionViewLayout`（不设则 reloadData 不触发数据源，UI 空白无报错）
- Auto Layout 下 `isHidden=true` **不改变 frame**，约束仍生效——需动态高度时持有约束引用改 `constant`
- 本地化：`iina/*.lproj/`，用户首选中文

## 测试现状（重要）

`tests/*.acceptance.test.swift`（10 个）是 **XCTest 风格契约测试 + `@testable import iina`**，但当前**不可运行**：
- 未纳入 xcodeproj test target（无 `xcodebuild test` 入口）
- 依赖 `MediaLibraryStore.setItemsForTesting` 夹具（已补）
- 访问 VC/Item 成员需 internal 可见性（关键成员已改 internal）
- swiftc 独立编译缺 XCTest 模块

**纯逻辑验证**用 `swiftc -typecheck` + `main.swift`（允许顶层代码）独立编译，绕过 app 链接。GUI 行为用 marker 文件（`try? "x".write(toFile:)` 同步写）诊断执行链路。

## autopilot 约定

- `.autopilot/knowledge/`（decisions.md / patterns.md / index.md / domains/）**入库共享**
- `.autopilot/runtime/`（requirements/ sessions/ 产物）**本地不入库**（已加 .gitignore）
- commit 中文，遵循 conventional commits（feat/fix/docs/refactor …）
- SwiftLint 配置见 `.swiftlint.yml`（适度规则），运行：`swiftlint lint --path iina/`

## 常见坑

- mpv/player core 的 `ignorePathInWatchLaterConfig` 影响 md5 匹配，测试夹具须与生产一致（`ignorePath=false`）
- `PlaybackHistory.duration` 是 `VideoTime`（非 Double），`MediaItem.duration` 是 `Double?`——跨类型比较须转换
- GUI app 的 `Logger.log` 可能 buffer（stderr 未 flush），用 marker 文件更可靠
