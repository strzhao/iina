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

## 色彩与交互设计体系（统一规范）

**后续所有 UI（含 `MediaLibrary/` 视频墙及任何新增界面）统一采用** [`documents/refs/colors.md`](documents/refs/colors.md) **的 stringzhao-life 色彩体系**，不再零散用系统色或硬编码颜色。

- **品牌色 苔 Sage `#3A7D68`**：CTA、选中态、hover 强调、进度条、焦点环——点睛用，不大面积铺
- **灰阶三档**：雾 `#EBEBEA`（卡片/次级背景）/ 烟 `#8F8F8D`（描述/辅助文字）/ 炭 `#595957`（placeholder/标签）承接信息层级；墨 `#1A1A18` 正文、纸 `#F7F6F1` 页面背景
- **语义色**：琥 `#D4920A` warning / 朱 `#D94F3D` destructive（error/delete）/ 天 `#3B87CC` info（link/badge）
- **AppKit 适配**：colors.md 以 web 表达（oklch + CSS tokens），AppKit 下用 `NSColor` 从 hex 构造，建议集中到 `iina/Color+Brand.swift`（如 `NSColor(hex: 0x3A7D68)` 或 `NSColor(srgbRed:green:blue:alpha:)`）
- **暗黑模式**：colors.md 当前是浅色导向，固定 hex 不随系统切换；引入后须为品牌色与灰阶提供 dark 变体（或 `NSColor(name:)` 动态色），避免破坏视频墙原有的暗黑支持

## 测试现状（重要）

已新增 **`iinaTests` unit-test target**（host 在 IINA.app），通过 `xcodeproj` Ruby gem 程序化注入 pbxproj。

- **运行方式**：
  ```bash
  xcodebuild test -project iina.xcodeproj -scheme iina -configuration Debug -destination 'platform=macOS'
  # 或显式开覆盖率：-enableCodeCoverage YES
  ```
- **当前结果**：23 个测试通过（FileNameCleaner / MediaItem acceptance + TestHarnessAcceptance canary），代码覆盖率 ~11%
- **模块名是大写 `IINA`**（PRODUCT_MODULE_NAME=IINA），测试须 `@testable import IINA`，不是 `import iina`
- test target host 在 IINA.app（TEST_HOST/BUNDLE_LOADER），libmpv 符号从宿主解析，无需重链 deps
- scheme 已开 `codeCoverage` + `TSan` 声明；TSan 全 app 运行因 libmpv 预编译未插桩为**已知局限**（仅声明级，实际 TSan 不能在 libmpv 内部报错）
- 独立构建配置 `Configs/iinaTests.xcconfig`（显式声明 HEADER/LIBRARY_SEARCH_PATHS，Shared.xcconfig 不含这些；不设 bridging header；仅 Debug 单档）
- **仍有 11 个 `tests/*.acceptance.test.swift` 未接入**（依赖 NAS/ffmpeg IO 或完整 app 启动环境）。未来接入时须把 `@testable import iina` 改为 `@testable import IINA`（模块名大写），并补齐夹具可见性
- 访问 VC/Item 成员需 internal 可见性（关键成员已改 internal），夹具 `MediaLibraryStore.setItemsForTesting` 已补
- **视频墙 P1-P5 性能优化**（`b9dbb91e`）：写盘移出主线程+合并（scheduleSaveIndex）/ 搜索 0.15s 防抖（searchDebounceWorkItem）/ 启动后台 loadIndexAsync / `MediaItem.cleanedNameLowercased` 预计算 / 缩略图 cache-hit 移入 queue.async。新增测试 seam：`MediaLibraryStore.disableRescanForTesting`（禁扫真 NAS）、`reloadIndexForTesting`、`__test_lastIndexLoadThread`/`__test_lastCacheHitThread`（写回主线程避 TSan race）、`MediaLibraryViewController.reloadDataCallCount`；配套 `MediaLibraryPerfP1_P5.unit.test` + 6 红队 acceptance（尚未接入 xcodebuild test，依赖 hosted app 环境）

**纯逻辑验证**（脱离 XCTest 时）仍可用 `swiftc -typecheck` + `main.swift`（允许顶层代码）独立编译，绕过 app 链接。GUI 行为用 marker 文件（`try? "x".write(toFile:)` 同步写）诊断执行链路。

## autopilot 约定

- `.autopilot/knowledge/`（decisions.md / patterns.md / index.md / domains/）**入库共享**
- `.autopilot/runtime/`（requirements/ sessions/ 产物）**本地不入库**（已加 .gitignore）
- commit 中文，遵循 conventional commits（feat/fix/docs/refactor …）
- SwiftLint 配置见 `.swiftlint.yml`（适度规则），运行：`swiftlint lint --path iina/`

## 常见坑

- mpv/player core 的 `ignorePathInWatchLaterConfig` 影响 md5 匹配，测试夹具须与生产一致（`ignorePath=false`）
- `PlaybackHistory.duration` 是 `VideoTime`（非 Double），`MediaItem.duration` 是 `Double?`——跨类型比较须转换
- GUI app 的 `Logger.log` 可能 buffer（stderr 未 flush），用 marker 文件更可靠
