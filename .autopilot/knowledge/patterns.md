# Patterns & Lessons

### [2026-07-12] NSCollectionView 必须显式设 collectionViewLayout
<!-- tags: nscollectionview, layout, ui, debugging -->
**Scenario**: NSCollectionView reloadData 后不渲染任何 item（numberOfItemsInSection 不被调用），UI 空白且无报错
**Lesson**: NSCollectionView 必须显式设 `collectionViewLayout`；创建了 `NSCollectionViewFlowLayout` 并配置 itemSize/spacing 后，须赋给 `collectionView.collectionViewLayout = flowLayout`。不设时 layout 可能为 nil，reloadData 不触发数据源查询（numberOfSections=0），表现为"数据对但 UI 空"——极易误判为数据层 bug
**Evidence**: IINA 媒体库视频墙"看不到媒体文件"，marker 链定位 `cvLayout=false` → `cvSections=0` → numberOfItems 未调；设 `collectionView.collectionViewLayout = flowLayout` 后 `n=64` 卡片渲染（核对锚点：2026-07-12 iina/MediaLibrary/MediaLibraryViewController.swift:51）

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
