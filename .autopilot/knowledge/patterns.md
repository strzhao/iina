# Patterns & Lessons

### [2026-07-12] NSCollectionView 必须显式设 collectionViewLayout
<!-- tags: nscollectionview, layout, ui, debugging -->
**Scenario**: NSCollectionView reloadData 后不渲染任何 item（numberOfItemsInSection 不被调用），UI 空白且无报错
**Lesson**: NSCollectionView 必须显式设 `collectionViewLayout`；创建了 `NSCollectionViewFlowLayout` 并配置 itemSize/spacing 后，须赋给 `collectionView.collectionViewLayout = flowLayout`。不设时 layout 可能为 nil，reloadData 不触发数据源查询（numberOfSections=0），表现为"数据对但 UI 空"——极易误判为数据层 bug
**Evidence**: IINA 媒体库视频墙"看不到媒体文件"，marker 链定位 `cvLayout=false` → `cvSections=0` → numberOfItems 未调；设 `collectionView.collectionViewLayout = flowLayout` 后 `n=64` 卡片渲染（核对锚点：2026-07-12 iina/MediaLibrary/MediaLibraryViewController.swift:51）。**复发（2026-07-13）**：`ContinueWatchingView` 踩同款坑（flowLayout 创建配置后未赋给 `collectionViewLayout`），但被上游 `played` 过滤 bug 长期掩盖（`cwItems` 恒空、整条不显示）——修了 played 才暴露此 UI 层 layout 缺失。**教训**：「数据对但 UI 空」可能被更上游的数据层 bug 盖住，连环修复时 UI 层 layout 缺失会最后浮出（commit 8ad46797）

### [2026-07-12] swiftc 独立验证纯逻辑 + marker 文件诊断 GUI app
<!-- tags: testing, swiftc, debugging, marker, gui -->
**Scenario**: app 因链接失败无法整体运行，但需验证纯逻辑；GUI app 的 Logger 输出被 buffer 难以定位执行链路断点
**Lesson**: ①只 import Foundation 的纯逻辑文件可用 `swiftc -typecheck` + `main.swift`（允许顶层代码）独立编译运行，绕过 app 链接做真实数据验证，比 `-parse` 强（能跑出结果）；②GUI app 的 `Logger.log` 可能 buffer（stderr 未 flush 到重定向文件），用 marker 文件（`try? "x".write(toFile: "/tmp/x.marker")` 同步写）更可靠定位函数是否执行 / 链路在哪断
**Evidence**: IINA 5 个纯逻辑文件 swiftc 独立编译运行验证 19 谓词 PASS；marker 链（req/init/gen/didgen/vdl/rstart/rdone/refresh/n）定位 collectionViewLayout 根因，而 Logger.log 在 stderr buffer 中无输出

### [2026-07-12] IINA 构建依赖获取与历史遗留 copy phase stub
<!-- tags: build, deps, xcodebuild, iina -->
**Scenario**: IINA `xcodebuild` 链接失败 `ld: library 'XXX.0' not found`
**Lesson**: IINA 的 `deps/lib/` 预构建 dylib 被上游 commit 移除后，需 `other/download_libs.sh --arch <arch>` 重新获取；`libstdc++.6.dylib`/`libgcc_s.1.1.dylib` 是历史遗留 copy phase（无真实 dylib 依赖它们），缺失时用 `clang -dynamiclib -o <path> -xc -` 创建空 stub 即可通过；**链接错误 ≠ 代码问题**，先排查依赖完整性再查代码
**Evidence**: `ld: soxr.0 not found` → download_libs.sh 获取 69 dylib；libstdc++/libgcc_s copy phase 失败 → stub 后 BUILD SUCCEEDED（核对锚点：2026-07-12 仓库 commit b7bcc309 移除 dylib）

### [2026-07-13] IINA GUI 验证：AX 窗口不可见，用 CGWindowList+CGEvent+screencapture+图像分析
<!-- tags: iina, gui, verification, cgwindowlist, cgevent, screencapture, ax, automation, testing -->
**Scenario**: 验证 IINA（GUI app）的视频墙改动需运行 app 驱动交互，但 System Events 看不到 IINA 窗口——`name/bounds of every window` 返回空，`window 1` 报无效索引 -1719，AX 自动化路径完全走不通
**Lesson**: IINA 窗口未暴露给 System Events AX（自身 AX 实现问题，非 sandbox）。GUI 自动化绕过组合：① `CGWindowListCopyWindowInfo`（Quartz，直接读窗口服务器，按 `kCGWindowOwnerName=="IINA"` 过滤）拿窗口 bounds——比 AX 可靠；② `CGEvent` 屏幕坐标点击（不依赖 AX window 索引，但需"辅助功能"权限，自动化环境可能不生效）；③ `screencapture -x` 全屏截图 + 多模态图像分析判布局（顶部空白比例/分类控件/卡片角标）。**额外坑**：`osascript "tell app IINA to quit"` 也走 AX 对 IINA 无效，需 `kill -9 <PID>`；系统 python3 无 Quartz 模块，CGWindowList/CGEvent 须用 swift 脚本（Cocoa 原生 binding）
**Evidence**: verify 阶段 AppleScript AX 点击报 -1719 → swift CGWindowList 定位窗口 + CGEvent 坐标点击；截图经图像分析确认视频墙布局（顶部空白 <5%、电视剧剧集集合卡片「N集」角标）

### [2026-07-17] XCUITest 在 IINA 可用（纠正"AX 完全不可见"）：4 层突破
<!-- tags: iina, xcuitest, ax, library-validation, launcharguments, testing, gui, nscollectionview, codesign, entitlements -->
**Scenario**: 需 XCUITest 自动化验证 IINA 视频墙。初期基于 [2026-07-13] System Events AX -1719 误判"XCUITest 在 IINA 不可用 / AX 不暴露"，多轮深入修后发现 XCUITest **能**查视频墙所有卡片。
**Lesson**: XCUITest 在 IINA 可用，需打通 4 层（前 3 层是"看不到"的真因，非 AX 本身不暴露）：
① **library validation（非 Team ID）**：iinaUITests-Runner.app 加载 test bundle 报 `different Team IDs` 是 library validation（runner 缺 `disable-library-validation` entitlement），**与 Team ID 无关**——ad-hoc 签名下也复现，配 Team 不解决。IINA.app entitlements 已含但 XCUITest 派生的 runner **不继承**，需 iinaUITests target 显式 `CODE_SIGN_ENTITLEMENTS = iinaUITests/iinaUITests.entitlements`（含 `com.apple.security.cs.disable-library-validation` + `get-task-allow`）。这是 macOS XCUITest 个人项目的标准坑，绕过靠 entitlement 不靠证书。
② **launchArguments seam**：XCUIApplication launch 的 IINA 不读用户已写 defaults（测试隔离），视频墙空（cells=0）。MediaLibraryStore.rootPath 加测试 seam：`CommandLine.arguments` 含 `-mediaLibraryRootPath <path>` 时返回该路径（生产正常启动无此参数，走 UserDefaults），XCUIApplication.launchArguments 注入测试媒体目录。
③ **NSCollectionView 卡片是 Group 不是 .cells**：XCUITest `cv.cells`（iOS UICollectionView 语义）对 macOS NSCollectionView 返回 0；卡片在 AX 树是 `Group → Image + StaticText`，用 `app.images` / `app.staticTexts["m1"]` 查询。视频墙 m1-m20 + "64p" 完全可达。
④ **waitForExistence 抗缩略图生成 flaky**：缩略图生成时序 flaky（缓存命中快/生成中慢），固定 sleep 不稳，用 `app.images.firstMatch.waitForExistence(timeout: 30)` 等生成完。
**Evidence**: iinaUITests target（xcodeproj gem `:ui_test_bundle` 注入 + Configs/iinaUITests.xcconfig + entitlements + scheme TestableReference）+ cell/VC setAccessibilityIdentifier + MediaLibraryStore launchArguments seam → 4 test PASS（test_smoke_app_window / test_smoke_mediawall images=20 / test_humanobs_card_thumbnail m1=true / test_scan_progress_label_seam），`xcodebuild test -only-testing:iinaUITests` → TEST SUCCEEDED。**纠正 [2026-07-13]**：System Events AX 不可见（-1719），但 XCUITest（XCUIElementQuery 用不同 AX API）可见视频墙卡片。GUI 验证三套齐备：XCTest（逻辑）+ CGWindowList（渲染/像素）+ XCUITest（AX 语义）。

### [2026-07-13] 后台扫描失败保留缓存 + 自定义 Error 须暴露 underlying
<!-- tags: iina, medialibrary, rescan, error-handling, robustness, nas, localizederror, cache -->
**Scenario**: NAS 瞬时 I/O 抖动致 `MediaLibraryScanner.scan` 抛 Cocoa error → rescan catch 分支原把 `items/md5Index/tvShowIndex` 全清空，一次抖动让用户失去整个视频墙视图；且 `MediaLibraryError` 是 enum 未实现 LocalizedError，`localizedDescription` 吞掉 underlying，用户只见「错误1」盲盒无法诊断
**Lesson**: ① 后台扫描/同步失败时**保留上次成功缓存**（loadIndex 加载的 items），只上报错误提示不清空——瞬时失败不应丢用户数据视图（直接 swift 扫描 NAS 全成功可证 IINA rescan 失败是瞬时 I/O，非代码 bug）；② 自定义 Error enum 若 wrap 了 underlying（如 `case scanFailed(url:, underlying: Error)`），**必须**在显示层模式匹配取 underlying 暴露（`case .scanFailed(_, let underlying): label = underlying.localizedDescription`），否则 localizedDescription 只剩无用的 enum 默认描述
**Evidence**: 用户真机验收报「扫描目录时出错（错误1）」；swift 直接扫描 NAS 68+68 子目录全成功；修 rescan 不清空 + showError 暴露 underlying 后，视频墙显示缓存数据 + 真实 Cocoa error（核对锚点：2026-07-13 commit ccdfd796 MediaLibraryStore.rescan / MediaLibraryViewController.showError）

### [2026-07-13] 进度类 UI 判据须有自持久化 fallback，不能只依赖单一外部异步数据源（mpv watch-later）
<!-- tags: iina, playbackhistory, watch-later, mpv, progress, medialibrary, fallback, debugging -->
**Scenario**: 进度类 UI 状态（「继续观看」列表/卡片进度条）依赖播放进度，而进度源是 mpv 异步写的 watch-later 文件——mpv 在 stop/quit 才写，且可能因 NAS I/O / pos=NOPTS 写失败。只依赖它会导致 UI 状态丢失（入口消失）。
**Lesson**: 进度类 UI 状态判据**不能只依赖单一外部异步数据源**，必须有应用自持久化的 fallback——否则外部写失败直接导致 UI 状态丢失。`PlaybackHistory.mpvProgress` 的演进印证：①初版只是 watch-later 的派生镜像（解码时读一次、`encode` 不持久化、`add` 不设），watch-later 缺失即空；②升级为 IINA 自持久化独立进度源后（encode 持久化 seconds + `savePlaybackPosition` 运行时回写 + `add` 同 md5 迁移），watch-later 读不到时 fallback 到它，入口不再消失。读取顺序固定：live watch-later 优先（含 mpv 其他保存配置更完整）→ fallback 自持久化值；两者均须过 watchedThreshold / progress>0 判据。回写须独立于 mpv 偏好（置于 `savePositionOnQuit` guard 之前），否则偏好关闭时 fallback 源也写不进。
**Evidence**: (案例1: 2026-07-13) 初版派生镜像致「没进度+不实时更新」，改实时读 watch-later 修复（commit 8ad46797）。(案例2: 2026-07-21) 实时读 watch-later 在 mpv 写失败时仍丢入口（怪奇物语 S03E01：mpv 日志 5 次 Write watch-later 但 watch_later 目录零文件变动，进度文件 ABSENT），升级 mpvProgress 为自持久化独立源 + `MediaLibraryStore.progressSec(for:)` 双路径 fallback 修复（commit 65290dba；核对锚点：2026-07-21 PlaybackHistory.swift KeyMpvProgress / MediaLibraryStore.progressSec(for:) / PlayerCore.savePlaybackPosition guard 前置）

### [2026-07-13] PlaybackHistory.played 字段语义坏，不可作「已看完」过滤判据
<!-- tags: iina, playbackhistory, played, continue-watching, debugging -->
**Scenario**: 媒体库「继续观看」列表永远为空（用户播放过多个视频却看不到）
**Lesson**: `PlaybackHistory.played` 在 `HistoryController.add` 经 `init(url:duration:name:title:mpvMd5:)` **硬编码 `played=true`**（PlaybackHistory.swift:87），且全代码库无任何处设 false——上游 IINA 从未真正使用该字段。用它做过滤（`if entry.played { continue }`）会把**全部**历史排除。正确「已看完」判据：进度 ≥ duration × 0.95。诊断关键：实测 history.plist 所有条目 played 全 true 即可定位（`plutil -convert xml1 ... | grep -A1 IINAPHPlayed`）
**Evidence**: `continueWatchingItems` 的 played 过滤致 19 条历史全排除；实测 history.plist played=true 19/19；删过滤改用进度<95% 判据后列表恢复（核对锚点：2026-07-13 commit 8ad46797）

### [2026-07-15] avformat_find_stream_info 无条件调用致 NAS 文件 EXC_BAD_ACCESS 崩溃
<!-- tags: iina, ffmpeg, libavformat, find-stream-info, nas, crash, exc-bad-access, probe -->
**Scenario**: 媒体库扩展 `FFmpegController.probeVideoInfoForFile:` 读视频流 codecpar，为"保证填充"在 open_input 后无条件补调 `avformat_find_stream_info` → IINA 启动后 probe 队列对 NAS 挂载文件 probe 时 EXC_BAD_ACCESS（SIGSEGV @ avformat_find_stream_info+696，FFmpeg 7.0.1 libavformat.61）
**Lesson**: `avformat_open_input` 已为多数容器从 header 填充 codecpar，width/height/codec 可直接读，**不需**强制 `find_stream_info`。`find_stream_info` 会读流数据，对 NAS（smb/nfs）文件 + 某些容器在 FFmpeg 7.0.1 触发内部 EXC_BAD_ACCESS。原 IINA 逻辑（duration<=0 才调）是有意为之的稳定边界，不要为"保证填充"改成无条件调用；codecpar 读不到时让 key absent（契约允许），而非冒险 find_stream_info。诊断：crash report .ips 解析 triggered thread backtrace（`iina.media.library.probe` 队列 → `avformat_find_stream_info`）
**Evidence**: 蓝队初版无条件 find_stream_info 致 IINA 启动 ~5s 崩溃（IINA-2026-07-14-002421.ips，pid 45472）；删无条件调用、保留 duration<=0 才调后 IINA 持续运行无 crash（核对锚点：2026-07-15 commit a62ac9cf FFmpegController.m:373-380）

### [2026-07-15] 懒加载 + 通知 reload 无限循环致列表闪烁（probeMetadata probedKeys）
<!-- tags: iina, medialibrary, probemetadata, notification, reload, flicker, loop, lazy-loading -->
**Scenario**: 卡片 `configure` 触发 `probeMetadata` 懒加载，probe 完发 `metadataProbedNotification` → ViewController reload visible items → cell `configure` 再触发 `probeMetadata`。若 probe 失败（NAS I/O 抖动/无视频流）`item.height` 永远 nil，守卫 `if item.height != nil { return }` 不 return → 反复 probe；且 `changed = item.year != nil`（year 从文件名填了就算 changed）→ 反复发通知 → 列表不停 reload 闪烁
**Lesson**: 懒加载 + 通知刷新模式须防"失败重试循环"——probe 完成不论成败都要标记（`probedKeys` Set），下次跳过；`changed` 只在**真新增字段**时 true（year 已存在不再算 changed）。仅靠 `probingKeys`（正在 probe）去重不够，失败后 key 移除会重试。诊断：用户反馈"列表一直闪" = 通知风暴 + reload 循环
**Evidence**: 加 `probedKeys`（probe 完插入，开头 `probedKeys.contains(key)` 跳过）后闪烁消除（核对锚点：2026-07-15 commit a62ac9cf MediaLibraryStore.probeMetadata）

### [2026-07-15] CALayer 阴影无 shadowPath 致 NSCollectionView 滚动卡顿
<!-- tags: iina, appkit, calayer, shadow, shadowpath, performance, scroll, nscollectionview -->
**Scenario**: NSCollectionView 卡片每张配 CALayer 阴影（shadowOpacity/shadowRadius）但无 shadowPath，滚动 + hover 动画时每张可见卡片每帧实时高斯模糊重算阴影，主线程卡顿
**Lesson**: CALayer 阴影**必须设 shadowPath**（`CGPath(roundedRect:cornerWidth:cornerHeight:transform:)` 匹配 cornerRadius）。无 shadowPath 时 AppKit 每帧重新光栅化阴影模糊（O(卡片数 × 模糊半径)），是 NSCollectionView 滚动卡顿的经典源；shadowPath 缓存阴影形状只绘一次。注意 Swift `CGPath(roundedRect:...)` 构造器 `transform` 参数必填，传 `nil`。在 `viewDidLayout` 设（bounds 变时更新）
**Evidence**: 加 shadowPath 后滚动流畅（用户反馈"滚动很卡"消除）（核对锚点：2026-07-15 commit a62ac9cf MediaItemCollectionViewItem.viewDidLayout）

### [2026-07-15] NSCollectionView cell hover 滚动时 mouseExited 漏触发 + trackingArea rect/inVisibleRect 冲突
<!-- tags: iina, appkit, nstrackingarea, hover, mouseexited, nscollectionview, scroll -->
**Scenario**: 卡片 NSTrackingArea hover 态，鼠标离开后 hover 不恢复（抬起/浮层保持）。根因：① `NSTrackingArea(rect: view.bounds, options: [.inVisibleRect,...])` rect 传 view.bounds 与 .inVisibleRect 冲突（.inVisibleRect 模式 rect 应为 .zero，AppKit 用 visibleRect）→ 事件不可靠；② 滚动时 cell 位移，鼠标屏幕未动但离开 cell bounds，mouseExited 不触发（cell 移动非鼠标移动）
**Lesson**: NSTrackingArea + .inVisibleRect 时 rect 传 .zero（不要传 view.bounds）；滚动场景 mouseExited 会漏触发，需在 `viewDidLayout` 加兜底——若 isHovering 且 `NSEvent.mouseLocation` 转换到 view 坐标不在 bounds 则 reset；cell 复用 `prepareForReuse` 也 reset。三重保险（rect .zero + viewDidLayout 鼠标校验 + prepareForReuse）覆盖静止/滚动/复用场景
**Evidence**: 三重修复后 hover 鼠标离开恢复正常（核对锚点：2026-07-15 commit a62ac9cf MediaItemCollectionViewItem installTrackingArea/viewDidLayout/prepareForReuse）

### [2026-07-15] MediaLibrary 跨维度根因：单例 Store + MediaItem 跨线程共享可变引用，致 bug 修复常引入新副作用
<!-- tags: iina, medialibrary, architecture, concurrency, data-race, side-effect, audit, singleton, cache, cancellation -->
**Scenario**: 对视频墙做架构/体验/性能审计（3 agent 并行读码 + plan-reviewer 抽查证据），发现多个 P0/P1 问题有共同根因，且历史修复普遍存在"修一个 bug 引入一个副作用"
**Lesson**: ① **数据竞争根因**：`MediaLibraryStore` 单例 + `MediaItem`（NSObject 可变引用类型）跨线程共享——probeQueue 后台写 width/height/duration/year/bitrate、主线程读 + `saveIndex` NSKeyedArchiver 编码遍历 items——全无同步（TSan 可检出），是 P0 竞态 + P1 大量同步 I/O 的共同源头；修法：probe 字段写入切 `DispatchQueue.main.async`，或 MediaItem 改值类型/actor 隔离。② **"修副作用"模式**（每条都已在 patterns.md 单列）：实时读 watch-later（修进度刷新→引入每次 refresh 全量同步 I/O）、probedKeys 防循环（→ 防了首次失败后的正当重试，须 rescan 后重置）、缩略图池化修串行（→ 单实例 `cancelAllOperations` 丢在途任务 + backoff 4 次后丢任务永久占位图）、rescan 保留缓存（→ probedKeys 不随 rescan 重置）。**根因是缺整体的状态机 / 缓存失效 / 取消设计**，不是单个 bug。③ **修 P0 的耦合警示**：把 probe 写入切主线程会加剧主线程 reload 体感（P1-3/P2-9），须 Phase 0 同时做 `metadataProbed` 通知节流（合并 100ms 内多次 probe 完成）。
**Evidence**: 审计报告 `documents/视频墙审计报告.md`（31 问题 / 13 健康项 / 4 阶段路线图）；关键证据 `MediaLibraryStore.swift:339-352`（后台写）/ `:291,:362`（主线程 saveIndex 编码）/ `MediaItem.swift:53-65`（无锁 var）/ `MediaThumbnailer.swift:162-169`（backoff 丢任务）

### [2026-07-15] swift CGWindowListCopyWindowInfo 须传 kCGNullWindowID；nil 编译错被 2>/dev/null 吞致"窗口不存在"假阴性
<!-- tags: iina, gui, verification, cgwindowlist, swift, debugging, false-negative -->
**Scenario**: 用 `swift -e` 内联脚本验证 IINA GUI 窗口是否打开，写成 `CGWindowListCopyWindowInfo([...], nil)`——第二参是 `CGWindowID(UInt32)` 不能传 nil，编译报 `'nil' is not compatible with expected argument type 'CGWindowID'`。脚本带了 `2>/dev/null` 抑制 stderr，编译错被吞成**静默空输出**，误判"IINA 0 窗口 / 媒体库没开"，浪费数轮排查（实际窗口一直开着 1000×712 "媒体库"）。
**Lesson**: `CGWindowListCopyWindowInfo(options, kCGNullWindowID)` 的第二参**不能传 nil，须传 `kCGNullWindowID`**（表"所有窗口"）。**诊断脚本裸跑先确认能编译**——绝不在验证脚本上加 `2>/dev/null`（除非已确认无编译错）；编译错被吞 = 空输出 = 假阴性，比报错更危险（看着像"验证通过/无窗口"）。排查"app 窗口没出现"前，先确认探测脚本本身正确。
**Evidence**: P0 修复 QA 时 `swift -e '...CGWindowListCopyWindowInfo([...], nil)...' 2>/dev/null` 输出空 → 误判媒体库未开、怀疑回归；去 `2>/dev/null` 暴露编译错，改 `kCGNullWindowID` 后正确返回 `IINA win 1000x712 "媒体库"`。

### [2026-07-17] 给链预编译 dylib 的原生 xcodeproj app 加 hosted XCTest target 的 6 个坑（IINA 实证）
<!-- tags: testing, xctest, xcodeproj, hosted-test, module-name, bridging-header, testability, iina, tsan -->
**Scenario**: 给 IINA（原生 xcodeproj，链 libmpv/ffmpeg 预编译 dylib）加第一个 XCTest target，host 在 app 上。plan-reviewer 两轮 FAIL 各暴露一个编译期 BLOCKER，均 `xcodebuild -showBuildSettings` 实证后修订。
**Lesson**: ① **模块名 = PRODUCT_NAME（PRODUCT_MODULE_NAME），非 target 名**——IINA 是大写 `IINA`（target 名小写 `iina`），测试源须 `@testable import IINA`（大小写敏感；游离测试文件全写小写 `import iina`，接入时必须改）。② **host 测试 target 不能只设 TEST_HOST/BUNDLE_LOADER**：`@testable import` 需被测模块依赖路径可达。建**独立 test xcconfig**：`#include? "Shared.xcconfig"` 只继承 SWIFT_VERSION/deployment/SDKROOT——**实测 Shared.xcconfig 不含** HEADER/LIBRARY_SEARCH_PATHS（在 app 的 iina.xcconfig 里，但该文件带 `SWIFT_OBJC_BRIDGING_HEADER` **不能 include**）→ test xcconfig 须**直接显式声明** `HEADER_SEARCH_PATHS=$(SRCROOT)/deps/include`、`LIBRARY_SEARCH_PATHS=$(SRCROOT)/deps/lib`。③ **不设 SWIFT_OBJC_BRIDGING_HEADER**：app bridging header 路径是 `$(TARGET_NAME)/$(TARGET_NAME)-Bridging-Header.h`，test target 的 TARGET_NAME 不同会算成不存在的 `iinaTests/iinaTests-Bridging-Header.h` 致 build 失败；测试源纯 Swift 无 #import 不需要 bridging header。④ **仅 Debug 单档**：`@testable` 要求被测模块编译时 `ENABLE_TESTABILITY=YES`，app 通常只在 Debug 开（Release=NO），test target 双档会让 Release 测试回退普通 import 致 internal 符号不可达。⑤ host 模式 libmpv 符号经 BUNDLE_LOADER 从宿主运行时解析，test target Frameworks phase 仅系统框架（Cocoa），**不重链 deps dylib**。⑥ **TSan 全 app 运行对预编译未插桩 libmpv 不可用**（false positive），仅 scheme 声明级；覆盖率可真跑。
**Evidence**: commit b1739864；`xcodebuild -showBuildSettings -target iina` 实证 PRODUCT_MODULE_NAME=IINA；Configs/iinaTests.xcconfig；iinaTests 23/23 通过、覆盖率 11.24%。plan-reviewer B1（模块名大小写）/B2（SEARCH_PATHS 缺失+bridging header 误继承）两轮审查。

### [2026-07-17] xcodeproj gem 注入 target 会非语义重排 pbxproj；用 showBuildSettings 核验"既有 target 零语义改动"
<!-- tags: xcodeproj, gem, pbxproj, non-semantic, diff, showbuildsettings, verification, c7 -->
**Scenario**: 用 xcodeproj Ruby gem 给 5074 行 pbxproj 注入新 target，gem save 后 git diff 显示既有 target 区域有 ~44 行"删除"，疑似违反"既有 target 零改动"契约。
**Lesson**: **xcodeproj gem 的 project.save 会非语义重排 pbxproj**（group children 顺序、PBXFileReference 位置、XCRemoteSwiftPackageReference 显示名规范化如 GRMustache→GRMustache.swift），导致既有 target 区域出现"删除+新增"行，但**语义等价**（UUID / repositoryURL / build settings 全不变）。核验"既有 target 零语义改动"的正确方法：**`xcodebuild -showBuildSettings -target <app> -configuration Debug | grep 关键设置`** 对比改动前后逐项一致（PRODUCT_MODULE_NAME / SWIFT_OBJC_BRIDGING_HEADER / HEADER_SEARCH_PATHS / LIBRARY_SEARCH_PATHS 等）——showBuildSettings 反映最终合并后的有效设置，比 raw pbxproj diff 更能证明语义不变；辅以"app 能构建 + hosted 测试通过"作强证据。**优先用 gem 程序化注入而非手编大 pbxproj**（手编 UUID/交叉引用极易破坏工程）。注意：gem 改 GRMustache 显示名为 "GRMustache.swift" 是规范化（与 repositoryURL 末尾一致），非用户可感知语义变化。
**Evidence**: commit b1739864 git diff 既有区域 ~44 删除行（gem 重排）+ showBuildSettings 与改动前基线逐项一致 + app 构建/23 测试通过证明既有 4 target 完好。

### [2026-07-18] 测试 seam（记录线程的 static var）后台写致 TSan data race；主线程写修复
<!-- tags: tsan, test-seam, data-race, concurrency, thread, xctest -->
**Scenario**: 为验收"某操作在后台线程执行"加测试 seam（`internal static var lastThread: Thread?`），在后台异步块内 `lastThread = Thread.current` 记录，测试主线程读 `lastThread.isMainThread` 断言
**Lesson**: 后台异步块写 static var + 主线程读 = TSan data race（即使一写一读无逻辑冲突，TSan 仍报，且会拦下所在 test bundle 的测试——表现为"0 failures 但 TEST FAILED"）。修复模式：后台块捕获局部 `let thread = Thread.current`（Thread 对象不可变，跨线程持有安全），在 `DispatchQueue.main.async` 回块写字段——写入收敛主线程消除竞争，记录的仍是后台线程身份。适用于任何"后台记录、主线程断言"的 seam
**Evidence**: IINA 视频墙 P3/P5 seam `__test_lastIndexLoadThread`/`__test_lastCacheHitThread` 在后台块写致 TSan `data race ... closure #2 in configure`，P3.1 测试被拦（iinaTests 86 tests 0 failures 但整体 TEST FAILED）；改后台捕获 `deserializeThread`/`readThread` + 主线程写字段后 race 消除、86 tests 全绿（核对锚点：2026-07-18 MediaLibraryStore.swift loadIndexAsync / ContinueWatchingCollectionViewItem.swift configure，commit b9dbb91e）

### [2026-07-19] iina-cli（main.swift 可执行）顶层 `private let` 首次访问致 SIGSEGV；改 `private var` 计算属性绕过
<!-- tags: swift, main-swift, private-let, sigsegv, cli, iina, dispatch-once, computed-property -->
**Scenario**: 给 iina-cli（独立可执行 target，`main.swift` 顶层代码入口）加诊断子命令，定义顶层 `private let iinaLogsDir: String = { ... }()`（闭包初始化）和 `private let iinaLogFieldLevel = "level"`（字面量），首次访问（`iina log path` → 读 `iinaCurrentLogPath` → 触发 `iinaLogsDir` 初始化）时进程 **SIGSEGV (exit 139)** 崩溃
**Lesson**: ① **`main.swift` 顶层 `private let`（含字面量字符串）会走 dispatch_once 懒初始化路径，在该可执行里首次访问崩溃**——而同文件的 `internal let`（原 iina-cli 的 `currentDirURL`/`iinaPath`/`task`）和 `private func` 不崩。根因未深究（疑似 dispatch_once + main.swift 顶层代码交互）。② **修复：改 `private var x: String { ... }` 计算属性**（每次访问重新求值，无懒初始化，µs 级开销可忽略）；常量也用计算属性（`private var fieldLevel: String { "level" }`）。③ 兄弟项目 buddy CLI 顶层 `private let` 不崩——差异可能在 entry point 结构（buddy 用 `main()` 函数调用 vs iina-cli 纯顶层代码）。诊断此坑：`iina log path` 输出空 `\n`（print 了空串）或 exit 139
**Evidence**: iina-cli 诊断子命令 `iina log show` 首次跑 exit 139；fputs 调试显示 `home`/`urls` 读到但访问 `iinaLogsDir` 崩；改 5 个 `iinaLogField*` + `iinaLogsDir`/`iinaCurrentLogPath` 全部 `let`→`var` 计算属性后 `log show/grep/tail` 全正常（核对锚点：2026-07-19 iina-cli/main.swift）

### [2026-07-19] iina-cli build 产物在项目内 build/Debug/，不在 DerivedData app bundle；增量编译需删产物强制
<!-- tags: xcodebuild, iina-cli, build-products, deriveddata, incremental, copy-phase, iina -->
**Scenario**: `xcodebuild -target iina-cli build` 后跑 `IINA.app/Contents/MacOS/iina-cli log path` 仍走旧逻辑（spawn IINA）。排查：`build iina-cli` target 的 `BUILT_PRODUCTS_DIR = $(SRCROOT)/build/Debug`（项目内），**不在** DerivedData 的 `IINA.app/Contents/MacOS/`。app bundle 内的 iina-cli 由 `build iina scheme` 的 copy phase 更新，单 build iina-cli target 不更新它。且增量编译可能不重链接（改源后产物 mtime 不变）
**Lesson**: ① **iina-cli target 产物在 `build/Debug/iina-cli`（项目内）**，验证用这个；IINA.app bundle 内的 iina-cli 要 `build iina scheme` 整体才更新（copy phase）。② **增量编译可能不重链接**：改 main.swift 后 `build iina-cli` 报 BUILD SUCCEEDED 但产物 mtime 不变（旧二进制）——需 `rm build/Debug/iina-cli` + 删 `Build/Intermediates.noindex/iina.build/Debug/iina-cli.build` 强制全量。③ **核验二进制含新代码**：`strings build/Debug/iina-cli | grep -c <新符号>`，不能只信 BUILD SUCCEEDED
**Evidence**: iina-cli 改诊断分支后 `build iina-cli` SUCCEEDED 但产物 mtime 19:00:37（旧），跑 `log path` spawn IINA；删产物+intermediates 全量 rebuild 后 mtime 19:08 + strings 含诊断代码；`build iina scheme` 后 app bundle 内 iina-cli 更新（核对锚点：2026-07-19 BUILT_PRODUCTS_DIR via `xcodebuild -showBuildSettings -target iina-cli`）

### [2026-07-19] pbxproj 悬空文件引用致 develop 分支 build 失败（commit 引用但漏 commit .swift）
<!-- tags: xcodeproj, pbxproj, dangling-reference, build, git, commit-consistency, iina -->
**Scenario**: autopilot 接手"复用 playlist"任务，发现当前 worktree HEAD（98759b48）`xcodebuild build` 失败。诊断：HEAD pbxproj 引用 `EpisodeListSidebarViewController.swift`/`SidebarEpisodeListPane.swift`（PBXBuildFile + PBXFileReference + Sidebar group + Sources phase 共 4 处×2 文件），但 `git show HEAD:<file>` 报 "does not exist in HEAD"——上一轮 episodes 实现 commit 了 pbxproj 文件引用，但 .swift 物理文件未 commit（在另一 worktree 或被本地清理）→ develop 分支 pbxproj 引用不存在的文件 → 编译期 "Cannot find 'XXX' in scope" / Build input file cannot be found。
**Lesson**: ① **xcodeproj gem（或手改）加新源文件时，pbxproj 引用与 .swift 物理文件必须同 commit**——单独 commit pbxproj 引用而漏 commit 文件 = 悬空引用，下个 build 必坏。② **诊断悬空引用**：`git show HEAD:<path/to/file>.swift` 报 fatal does not exist，但 `git show HEAD:iina.xcodeproj/project.pbxproj | grep <filename>` 有命中 → 悬空。③ **修复**：从 pbxproj 移除悬空引用（xcodeproj gem 或手删 PBXBuildFile/PBXFileReference/group 行/Sources phase 行），或补 commit 缺失的 .swift。④ **与 [2026-07-17] xcodeproj gem 非语义重排不同**：那条讲 gem save 重排（语义等价），本条讲引用-文件 commit 不一致（语义破坏，build 坏）。多 worktree 协作时尤其易漏：A worktree commit pbxproj，B worktree 的 .swift 未同步入库。
**Evidence**: HEAD 98759b48 `git show HEAD:iina/EpisodeListSidebarViewController.swift` → fatal: does not exist；`git show HEAD:iina.xcodeproj/project.pbxproj | grep -c EpisodeListSidebarViewController` → 4（悬空引用）；本轮 9ed8fd9c 从 pbxproj 移除 2 文件引用（-8 行）后 `xcodebuild build` → BUILD SUCCEEDED。

### [2026-07-19] det-machine 验收测试不应锁死"会增长的数字"（测试总数/文件数）；断言核心不变量
<!-- tags: testing, det-machine, acceptance-test, red-team, baseline, xctest, iina -->
**Scenario**: 红队为"复用 playlist"写 C4 验收 `tests/ReusePlaylistC4BuildAndTests.acceptance.sh`，P3 断言 `executed == 23`（基于 CLAUDE.md「测试现状」基线"23 个测试通过"）。但实际 `xcodebuild test -only-testing iinaTests` 已增长到 99 测试（套件随开发自然增长）→ 红队测试必 FAIL，但实现正确（99 通过 0 failures）。
**Lesson**: ① **det-machine 验收测试断言"会随开发自然增长的量"（测试总数、文件数、行数、符号数）时，绝不锁死字面值**——锁死 = 定时炸弹（下次增长即 FAIL，且 FAIL 指向"实现问题"误导调试）。② **正确姿势**：断言核心不变量——测试用 `failures == 0`（或 `executed >= <baseline>` 容忍单向增长），而非 `executed == <exact>`。③ **CLAUDE.md 基线数字会过时**：红队/契约引用 CLAUDE.md 的"23 测试"等基线时，基线本身可能过时（本轮实测 99）；契约 C4 同步写"23/23"也需更新基线或改为不锁死。④ **红队测试质量盲点**：红队基于文档（CLAUDE.md）写期望，文档过时则期望过时；QA 编排器需区分"红队期望过时（修测试期望）vs 实现偏差（修实现）"——看实现是否满足"核心不变量"而非"字面数字"。
**Evidence**: 红队 `tests/ReusePlaylistC4BuildAndTests.acceptance.sh:85` `[ "$executed" = "23" ] && [ "$failures" = "0" ]`；实际 `xcodebuild test -only-testing iinaTests` → 99 tests 0 failures（8 skipped）；P3 应改 `failures == 0`（不锁 executed）；CLAUDE.md「测试现状」基线本轮已 23→99（commit 9ed8fd9c）。

### [2026-07-20] 依赖异步写盘（watch-later）的 UI 刷新须在写盘后触发；高频路径禁全量 reloadData
<!-- tags: medialibrary, continue-watching, watch-later, refresh-timing, reloaddata, performance, flicker, mpv, nscollectionview, iina -->
**Scenario**: 用户报视频墙"继续观看"看不到刚播的剧集（长安的荔枝第5集，进度已存）。实证（[[python-nskeyedarchiver-diagnosis]]）磁盘数据正常：index.plist/history.plist/watch_later 齐全，模拟 `continueWatchingItems()` 返回 OK。根因：`continueWatchingItems()` 实时读 watch-later（progress guard `progressSec > 0`），但 `.iinaHistoryUpdated` 仅在 `fileLoaded`（HistoryController.add 唯一 post 点，PlayerCore:2206）时发——那一刻 mpv 还没写 watch-later（mpv 只在 stop/quit 经 `savePlaybackPosition` 才写）→ progress guard 失败 → 刚播条目被排除 → UI 卡在 fileLoaded 快照；写盘后无通知，showWindow 也不 refresh → 永远看不到。
**Lesson**: ① **依赖异步写盘数据（mpv watch-later / 外部缓存）的 UI 刷新，必须在"数据写盘后"触发，而非业务事件（fileLoaded）时**——fileLoaded 只证明"开始播"，watch-later 写盘在 stop/quit 才发生，时序错配让 UI 永远停在前者快照。② **修复双保险**：写盘点（savePlaybackPosition 内 writeWatchLaterConfig 后）post 新通知（.iinaPlaybackProgressUpdated）+ 窗口重激活（NSWindowDelegate.windowDidBecomeKey / showWindow）兜底。③ **性能铁律**：高频 UI 事件（play/stop/切窗口/窗口激活）绝不全量 `collectionView.reloadData()`（~1200 项网格）——致播放闪 + 退出卡（reload 阻塞主线程）。提取轻量方法（refreshContinueWatching：只刷变化的 strip ~10 cell），全量 reload 仅留扫描完成/首次加载/启动等"数据真变"场景。④ **实现坑**：NSWindowController `init` 内 `let window = NSWindow(...)` 后 `window?.delegate = self` 编译错（局部 window non-optional，遮蔽 self.window）→ 直接 `window.delegate = self`。
**Evidence**: commit 57ee9df0；模拟脚本证明第5集 OK_PASS（prog=893s/dur=2850s=30%）；首轮修复挂全量 refresh 致播放闪+退出卡（用户验收报告），auto-fix 改轻量 refreshContinueWatching 后性能恢复 ✅；.sh 9/9 + build + iinaTests 99/0。

### [2026-07-20] iinaTests（unit test）污染生产 index.plist；XCUI 有 testDataRoot 隔离但 unit test 无
<!-- tags: testing, iinatests, unit-test, test-isolation, nskeyedarchiver, pollution, testdataroot, iina -->
**Scenario**: 跑 `xcodebuild test -only-testing iinaTests` 后，`~/Library/Application Support/com.colliderli.iina/media_library_index.plist` 从 1228 条（872KB）被覆盖为 947 字节（空），修改时间 = test 完成时刻。原因：某 unit test 调 `MediaLibraryStore.saveIndex()` 写盘，iinaTests target 未设 `-iinaTestDataRoot`（XCUI 的 launchArguments seam 有此重定向到 /tmp，unit test 无）→ saveIndex 写生产 indexURL。
**Lesson**: ① **unit test target 写持久化产物（plist/cache）必须像 XCUI 一样重定向到 /tmp**——iinaTests 调 `MediaLibraryStore.saveIndex()` 覆盖用户真实媒体库索引（1228→0 条）。② **数据可恢复**：IINA 启动 viewDidLoad 调 `rescan()` 扫 NAS 重建；或退出时内存 saveIndex 写回。非永久丢，但每跑 iinaTests 都污染。③ **诊断**：`ls -la media_library_index.plist` 修改时间 = test 完成时刻 + 大小骤降。④ **修复方向**（超本轮）：iinaTests 仿 XCUI 加 testDataRoot 隔离（Utility.testDataRootURL 在 unit test 环境也需能设）。
**Evidence**: iinaTests（23:53 完成）后 index.plist = 947B 时间戳 23:53；重启 IINA rescan 重建为 872KB（1228 条恢复）。

### [2026-07-20] python plistlib 解 NSKeyedArchiver 诊断 IINA 运行时数据（history.plist/index.plist/watch_later）
<!-- tags: debugging, nskeyedarchiver, plistlib, python, runtime-data, iina, history, medialibrary -->
**Scenario**: 诊断"继续观看看不到剧集"需验证 history.plist（PlaybackHistory）/ index.plist（MediaItem）/ watch_later/（mpv 进度）真实状态。这些是 NSKeyedArchiver 二进制 plist，`plutil -p` 输出 CFKeyedArchiverUID 引用不展开，难读 url/md5/duration 关联。
**Lesson**: ① **python3 + plistlib 解 NSKeyedArchiver**：`plistlib.load()` 返回 `{'$top':..., '$objects':[...]}`，`$objects` 扁平数组；CF$UID 解为 `plistlib.UID`（`.data` = 索引），递归 `deref(x)`：UID → `o[x.data]`；dict 含 `NS.relative`（NSURL）→ 递归解 relative；含 `NS.string` → 递归解 string；否则原值。② **逐条关联**：遍历 `$objects` 找含目标 key（IINAPHUrl/MIUrl）的 dict，deref url/md5/duration 关联成可读记录。③ **比读代码推测可靠**：GUI app 运行时数据用此法实证"数据层正常 vs 逻辑层 bug"，避免在"理论上应匹配"里打转（本轮靠它确认第5集磁盘数据齐全，根因转向刷新时机 [[continue-watching-refresh-timing]]）。④ **md5 复现**：file URL 的 `mpvWatchLaterMd5(ignorePath=false)` = `hashlib.md5(url.path.encode()).hexdigest()`，对比 watch_later/ 文件名（mpv 大写 / python 小写，macOS 大小写不敏感）。
**Evidence**: 解 history.plist 35 entries + index.plist 1228 MediaItem，确认第5集 matched（items.first fallback）+ progress 30%，数据层 OK_PASS；artifact 见 task 20260719-我刚点击了剧集长安的。

### [2026-07-21] mpv watch-later 父目录 redirect 是无害噪音；文件缺失诊断用 mtime 对照 + plistlib 交叉匹配
<!-- tags: iina, mpv, watch-later, redirect, forensic, debugging, mpv038, nskeyedarchiver -->
**Scenario**: 诊断「继续观看入口消失」需判断 mpv 写的 watch-later 文件是否存在 / key 是否匹配 / 格式是否可读。较新 mpv 会在 watch_later 目录产生看似异常的 `# redirect entry` 文件，易误判为 bug。
**Lesson**: ① 较新 mpv 的 `write_redirects_for_parent_dirs` 会为播放文件的**每个父目录**额外写 `# redirect entry` 文件（"按目录 resume"功能，**非进度文件，无 start=**），IINA 按文件 resume 不读它——是无害噪音，不是 bug 原因。② watch_later 目录两类文件须区分：进度文件（`start=<秒>`，文件名=md5(path 或 filename，取决于 ignore-path-in-watch-later-config)）vs 父目录 redirect（`# redirect entry` 一行，文件名=md5(父目录路径)）。③ **IINA 与 mpv 的 md5 key 同源**（CJK 路径在 NFC/NFD 下 md5 相同，排除规范化假设），文件缺失是 mpv 侧写失败（NAS I/O / pos=NOPTS）而非 key 不符。④ **诊断方法**：mtime 对照 mpv `Write watch later config` 日志（日志 UTC，文件 mtime CST，+8 换算）确认文件是否真生成；python plistlib 解 history.plist 拿 (url,mpvMd5) 对，与 watch_later 目录文件名交叉算匹配率，区分"md5 不符"vs"文件未生成"。
**Evidence**: 怪奇物语 S03E01：history.plist mpvMd5=F5EC3F60(=md5 path) 在 watch_later ABSENT，但其 5 个父目录 md5 全命中 `# redirect entry`；mpv 日志 5 次 Write watch-later 但目录零文件变动→mpv 写失败（非 key/格式）；40 文件=22 进度+18 父目录 redirect（核对锚点：2026-07-21 mpv v0.38.0 player/configfiles.c write_redirects_for_parent_dirs）

### [2026-07-22] tests/ 下的 *.acceptance.test.swift 不一定在 iinaTests target；新单测须 grep pbxproj 确认或加到 *Tests.swift
<!-- tags: testing, iinatests, acceptance-test, pbxproj, xcodeproj, test-injection, silent-noop, iina -->
**Scenario**: 给 continueWatching 剧集去重写单测，先把测试方法加到 `tests/MediaLibraryStore.acceptance.test.swift`（红队 acceptance 文件），`xcodebuild test -only-testing iinaTests/MediaLibraryStoreAcceptanceTests` 报 `Executed 0 tests`。`grep -c MediaLibraryStore.acceptance.test.swift iina.xcodeproj/project.pbxproj` = 0——该文件**不在 iinaTests Sources Build Phase**，不编译、不执行。最坑的是**静默无效**：build/test 都不报错，只是 0 tests，容易误以为「测试通过」实则没跑。而 `MediaLibraryStoreProgressFallbackTests.swift`（*Tests.swift）在 pbxproj 有 4 处引用（PBXBuildFile/PBXFileReference/PBXGroup/Sources phase），正常执行。注意：同目录的 `MediaLibraryPerfCacheHitAsync.acceptance.test.swift` / `MediaLibraryPerfSmokeRun.acceptance.test.swift` **在** target（改 cell.configure 签名时它们编译报错，可见）——acceptance 文件「部分在、部分不在」，不能一概而论。
**Lesson**: ① **tests/ 有文件 ≠ 在 iinaTests target**：CLAUDE.md 说 acceptance「由 xcodeproj gem 注入」，但实际部分 acceptance 红队文件从未注入 pbxproj，加测试到它们**不编译不执行**（静默无效，不报错只 0 tests，最易误判为「通过」）。② **诊断**：`grep -c <file>.swift iina.xcodeproj/project.pbxproj` == 0 → 不在 target；`-only-testing iinaTests/<TestClass>` → `Executed 0 tests` → 类未编译进 target。③ **正确姿势**：新单测加到**已在 target 的 `*Tests.swift`**（先 grep pbxproj 确认），或用 `xcodeproj` gem 注入新文件（4 处引用，留意 [2026-07-19] pbxproj 悬空引用条目的「引用与文件同 commit」坑）。④ **acceptance 文件不统一**：部分在 target（Perf*）、部分不在（MediaLibraryStore.acceptance）——别假设「acceptance 都在/都不在」，逐个 grep 确认。
**Evidence**: `grep -c MediaLibraryStore.acceptance.test.swift project.pbxproj` = 0；`-only-testing iinaTests/MediaLibraryStoreAcceptanceTests` → Executed 0 tests；同批去重测试改加到 `MediaLibraryStoreProgressFallbackTests.swift`（pbxproj 4 处引用）→ 9 tests 0 failures（含 4 新去重）；PerfCacheHitAsync/PerfSmokeRun acceptance 在 target（改 cell.configure 签名时编译报错触发修复）。
