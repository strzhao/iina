# Knowledge Index

## Decisions
- [2026-07-12] 视频缩略图复用 FFmpegController 而非 AVFoundation | tags: thumbnail, ffmpeg, avfoundation, mkv, iina | → decisions.md

## Patterns
- [2026-07-12] NSCollectionView 必须显式设 collectionViewLayout | tags: nscollectionview, layout, ui, debugging | → patterns.md
- [2026-07-12] swiftc 独立验证纯逻辑 + marker 文件诊断 GUI app | tags: testing, swiftc, debugging, marker, gui | → patterns.md
- [2026-07-12] IINA 构建依赖获取与历史遗留 copy phase stub | tags: build, deps, xcodebuild, iina | → patterns.md
- [2026-07-13] IINA GUI 验证：AX 窗口不可见，用 CGWindowList+CGEvent+screencapture+图像分析 | tags: iina, gui, verification, cgwindowlist, cgevent, ax, automation | → patterns.md
- [2026-07-13] 后台扫描失败保留缓存 + 自定义 Error 须暴露 underlying | tags: iina, medialibrary, rescan, error-handling, robustness, localizederror | → patterns.md
- [2026-07-13] PlaybackHistory.mpvProgress 是启动快照，运行时进度查询须实时读 watch-later | tags: iina, playbackhistory, watch-later, mpv, progress, medialibrary | → patterns.md
- [2026-07-13] PlaybackHistory.played 字段语义坏（add 硬编码 true），不可作过滤判据 | tags: iina, playbackhistory, played, continue-watching | → patterns.md
- [2026-07-15] avformat_find_stream_info 无条件调用致 NAS 文件 EXC_BAD_ACCESS 崩溃 | tags: iina, ffmpeg, libavformat, find-stream-info, nas, crash, probe | → patterns.md
- [2026-07-15] 懒加载 + 通知 reload 无限循环致列表闪烁（probeMetadata probedKeys） | tags: iina, medialibrary, probemetadata, notification, reload, flicker, loop | → patterns.md
- [2026-07-15] CALayer 阴影无 shadowPath 致 NSCollectionView 滚动卡顿 | tags: iina, appkit, calayer, shadow, shadowpath, performance, scroll | → patterns.md
- [2026-07-15] NSCollectionView cell hover 滚动时 mouseExited 漏触发 + trackingArea rect/inVisibleRect 冲突 | tags: iina, appkit, nstrackingarea, hover, mouseexited, scroll | → patterns.md
- [2026-07-15] MediaLibrary 跨维度根因：单例+跨线程共享可变引用致 bug 修复连环副作用 | tags: iina, medialibrary, architecture, concurrency, data-race, side-effect, audit | → patterns.md
