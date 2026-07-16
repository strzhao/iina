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

### [2026-07-13] 后台扫描失败保留缓存 + 自定义 Error 须暴露 underlying
<!-- tags: iina, medialibrary, rescan, error-handling, robustness, nas, localizederror, cache -->
**Scenario**: NAS 瞬时 I/O 抖动致 `MediaLibraryScanner.scan` 抛 Cocoa error → rescan catch 分支原把 `items/md5Index/tvShowIndex` 全清空，一次抖动让用户失去整个视频墙视图；且 `MediaLibraryError` 是 enum 未实现 LocalizedError，`localizedDescription` 吞掉 underlying，用户只见「错误1」盲盒无法诊断
**Lesson**: ① 后台扫描/同步失败时**保留上次成功缓存**（loadIndex 加载的 items），只上报错误提示不清空——瞬时失败不应丢用户数据视图（直接 swift 扫描 NAS 全成功可证 IINA rescan 失败是瞬时 I/O，非代码 bug）；② 自定义 Error enum 若 wrap 了 underlying（如 `case scanFailed(url:, underlying: Error)`），**必须**在显示层模式匹配取 underlying 暴露（`case .scanFailed(_, let underlying): label = underlying.localizedDescription`），否则 localizedDescription 只剩无用的 enum 默认描述
**Evidence**: 用户真机验收报「扫描目录时出错（错误1）」；swift 直接扫描 NAS 68+68 子目录全成功；修 rescan 不清空 + showError 暴露 underlying 后，视频墙显示缓存数据 + 真实 Cocoa error（核对锚点：2026-07-13 commit ccdfd796 MediaLibraryStore.rescan / MediaLibraryViewController.showError）

### [2026-07-13] PlaybackHistory.mpvProgress 是启动快照，运行时进度查询须实时读 watch-later
<!-- tags: iina, playbackhistory, watch-later, mpv, progress, medialibrary, debugging -->
**Scenario**: 媒体库「继续观看」卡片无进度条 + 播放新视频后列表不实时更新（需重启 IINA 才刷新）
**Lesson**: `PlaybackHistory.mpvProgress` 仅在 `init(coder:)` 解码 history.plist 时从 watch-later 读一次（启动快照），`encode` 不持久化它；而运行时 `HistoryController.add` 走 `init(url:duration:name:title:mpvMd5:)`，该 init **不设 mpvProgress**（默认 nil）。后果：①新播放条目 mpvProgress=nil；②已存在条目的 mpvProgress 是启动值，不随播放刷新。运行时进度查询（继续观看列表、卡片进度条）**必须实时读** `Utility.playbackProgressFromWatchLater(mpvMd5)`，不能依赖 `entry.mpvProgress`，否则要重启才更新
**Evidence**: 用户真机验收「没进度 + 不实时更新」；`MediaLibraryStore.continueWatchingItems` 与 `progress(for:)` 从 `entry.mpvProgress?.second` 改为 `Utility.playbackProgressFromWatchLater(md5)?.second` 后，播放新视频即时进列表 + 卡片进度条实时显示（核对锚点：2026-07-13 commit 8ad46797 MediaLibraryStore.swift）

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
