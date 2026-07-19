#!/bin/bash
# tests/ContinueWatchingRefresh.acceptance.sh
#
# 红队验收 — 契约 C1-C4 / 谓词 P1-P4
# 「继续观看刷新时机修复」黑盒验收（det-machine / grep 断言）
#
# 信息隔离：本脚本只跑 grep 字面量断言，不读实现源码语义。基于 state.md 契约 C1-C4 +
# 谓词 P1-P4 的字面量符号集做硬断言。
#
# 根因回顾：用户播放后回视频墙看不到刚播的剧集——磁盘数据正常（watch-later 已写），
# 但 UI 没刷新（.iinaHistoryUpdated 在 fileLoaded 时发，那时 watch-later 还没写；
# savePlaybackPosition 写 watch-later 后无通知；showWindow 不 refresh）。
#
# 覆盖：
#   C1/P1：MediaLibraryWindowController.showWindow 含 viewController.refresh()
#   C2/P2：NSWindowDelegate 协议 + windowDidBecomeKey + window.delegate = self
#   C3/P3：AppData 含 iinaPlaybackProgressUpdated 通知名
#   C4/P4：PlayerCore.savePlaybackPosition post + MediaLibraryViewController observer
#
# 失败行为：任一断言未命中即 exit 1（不宽容、不跳过）。

set -u

_find_repo_root() {
  local d
  d="$(cd "$(dirname "$0")" && pwd)"
  while [ "$d" != "/" ]; do
    if [ -e "$d/iina.xcodeproj" ]; then printf '%s' "$d"; return 0; fi
    d="$(dirname "$d")"
  done
  echo "FAIL: 无法定位仓库根（未找到 iina.xcodeproj）" >&2
  exit 2
}
REPO_ROOT="$(_find_repo_root)"
cd "$REPO_ROOT"

pass=0; fail=0
report() {
  local desc="$1"; shift
  local hit="$1"; shift
  if [ "$hit" != "0" ]; then echo "  PASS: $desc"; pass=$((pass+1));
  else echo "  FAIL: $desc (0 命中)"; fail=$((fail+1)); fi
}
grep_hit() { grep -qE "$1" "$2" 2>/dev/null && printf '1' || printf '0'; }

WC="iina/MediaLibrary/MediaLibraryWindowController.swift"
VC="iina/MediaLibrary/MediaLibraryViewController.swift"
PC="iina/PlayerCore.swift"
AD="iina/AppData.swift"

echo "=== C1/P1 — showWindow 含 refresh() ==="
# showWindow 方法体内含 viewController.refreshContinueWatching()（轻量，不 reload 网格）
report "C1 showWindow 调 viewController.refreshContinueWatching()" \
  "$(grep -A15 'func showWindow' "$WC" | grep -c 'viewController\.refreshContinueWatching()')"

echo ""
echo "=== C2/P2 — NSWindowDelegate 接入 ==="
report "C2 类声明含 NSWindowDelegate" "$(grep_hit 'class MediaLibraryWindowController.*NSWindowDelegate' "$WC")"
report "C2 实现 windowDidBecomeKey" "$(grep_hit 'func windowDidBecomeKey' "$WC")"
report "C2 windowDidBecomeKey 内 refreshContinueWatching" \
  "$(grep -A4 'func windowDidBecomeKey' "$WC" | grep -c 'viewController\.refreshContinueWatching()')"
report "C2 init 设 window.delegate = self" "$(grep_hit 'window\.delegate = self' "$WC")"

echo ""
echo "=== C3/P3 — AppData 新通知名 ==="
report "C3 AppData 含 iinaPlaybackProgressUpdated 通知名" \
  "$(grep_hit 'iinaPlaybackProgressUpdated = Notification\.Name\("IINAPlaybackProgressUpdated"\)' "$AD")"

echo ""
echo "=== C4/P4 — post 点 + observer ==="
report "C4 PlayerCore post iinaPlaybackProgressUpdated" \
  "$(grep_hit 'postNotification\(\.iinaPlaybackProgressUpdated\)' "$PC")"
report "C4 MediaLibraryViewController observer iinaPlaybackProgressUpdated" \
  "$(grep_hit 'name: \.iinaPlaybackProgressUpdated' "$VC")"
# post 必须在 savePlaybackPosition 内（writeWatchLaterConfig 之后）
report "C4 post 在 savePlaybackPosition writeWatchLaterConfig 之后" \
  "$(grep -A4 'writeWatchLaterConfig' "$PC" | grep -c 'postNotification(\.iinaPlaybackProgressUpdated)')"

echo ""
echo "=== 结果 ==="
echo "PASS=$pass  FAIL=$fail"
[ "$fail" = "0" ] || exit 1
exit 0
