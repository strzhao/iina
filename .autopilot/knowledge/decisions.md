# Decision Log

### [2026-07-12] 视频缩略图复用 FFmpegController 而非 AVFoundation
<!-- tags: thumbnail, ffmpeg, avfoundation, mkv, iina -->
**Background**: 视频墙需为大量本地视频文件生成缩略图，NAS 资源 mkv 占多数（58%）
**Choice**: 复用 IINA 内置 `FFmpegController`（链接 libavcodec/libavformat，支持 mkv/ts/flv/avi 全格式，不依赖 mpv/PlayerCore 实例，可为任意文件路径抽帧）
**Alternatives rejected**: `AVAssetImageGenerator`（不支持 mkv 容器，NAS 58% 文件无法生成）；直接用 `ThumbnailCache`（实为纯缓存类，抽帧靠 FFmpegController，非独立抽帧器）
**Trade-offs**: FFmpegController 单实例串行（`_queue.maxConcurrentOperationCount=1` + `generateThumbnailForFile:` 开头 `cancelAllOperations` 取消未完成旧请求），需实例池实现并发；`thumbnailCount=N` 实际生成 N+1 帧（循环 `i<=N` 含等号，0%/20%/.../100%），取索引 1（~20% 位置）避黑屏片头
**Evidence**: NAS 实测 mkv 680/1168（58%），AVAssetImageGenerator 不支持；FFmpegController.h:56 `generateThumbnailForFile:thumbWidth:` + delegate `didGenerateThumbnails:forFile:succeeded:`（核对锚点：2026-07-12 iina/FFmpegController.h）
