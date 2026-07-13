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
