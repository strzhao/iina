#!/bin/bash
# tests/ReusePlaylistC3OldCodeRemoved.acceptance.sh
#
# 红队验收 — 契约 C3 / 谓词 P1 / 谓词 P5
# 「旧 episodes 面板代码彻底清除」黑盒验收（det-machine / grep 断言）
#
# 信息隔离：本脚本只跑 grep，不读任何实现源码语义。基于 state.md 契约 C3 + 谓词
# P1/P5 的字面量符号集做硬断言。
#
# 覆盖：
#   C3：grep -rn "<symbol-set>" iina/ iinaUITests/ 必须输出为空
#   P1：上述 grep 输出为空 → PASS（与 C3 同源）
#   P5：SidebarController.ViewType 与 Preference.ToolBarButton 枚举内
#       `case episodes` 必须为空
#
# 失败行为：任一断言命中即 exit 1（不宽容、不跳过）。

set -u

# 仓库根 = 含 iina.xcodeproj 的目录。从脚本所在路径向上回溯到 iina.xcodeproj 所在。
# 不能用 "$(dirname "$0")/.."（那是任务目录 .autopilot/runtime/requirements/<task>，
#  无 iina/ 子目录，grep 永远 0 命中 → 假 PASS）。
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
  if [ "$hit" = "0" ]; then echo "  PASS: $desc"; pass=$((pass+1));
  else echo "  FAIL: $desc ($hit 命中)"; fail=$((fail+1)); fi
}

echo "=== C3 / P1 — 旧 episodes 面板代码彻底清除 ==="
echo "契约 C3：以下符号在 iina/ 与 iinaUITests/ 中必须全部消失"

# C3 字面量符号集（与 state.md ## 契约规约 C3 逐字一致）
# 注意：MediaLibrary/EpisodeListViewController.swift 是视频墙内的单集列表（非被删对象），
# 不在 C3 删除清单，故不查询 "EpisodeListViewController"。
C3_SYMBOLS=(
  "episodesPanelSuppressed"
  "EpisodeListSidebarViewController"
  "SidebarEpisodeListPane"
  "episodeListView"
  "handleEpisodeSidebarForLoadedFile"
  "updateEpisodeSidebarSuppression"
  "sidebarEpisodesDisplayAtLeading"
  "lastSeenTrailingStatus"
  "episodeSidebarToggleButton"
)

for sym in "${C3_SYMBOLS[@]}"; do
  # -l 仅打印命中文件，wc -l 计文件数；0 = 干净
  hits=$(grep -rln --include='*.swift' -- "$sym" iina/ iinaUITests/ 2>/dev/null | wc -l | tr -d ' ')
  report "C3 symbol '$sym' 已清除" "$hits"
done

echo ""
echo "=== P5 — 枚举内 case episodes 必须为空 ==="

# P5：SidebarController.ViewType 枚举内 `case episodes` 必须消失
# 用 grep -E '^\s*case episodes\b' 锚到枚举 case 行（避免注释/字符串误命中）
viewtype_hits=$(grep -rE '^[[:space:]]*case[[:space:]]+episodes\b' \
  iina/SidebarController.swift 2>/dev/null | wc -l | tr -d ' ')
report "P5 SidebarController.ViewType 无 'case episodes'" "$viewtype_hits"

# P5：Preference.ToolBarButton 枚举内 `case episodes` 必须消失
toolbar_hits=$(grep -rE '^[[:space:]]*case[[:space:]]+episodes\b' \
  iina/Preference.swift 2>/dev/null | wc -l | tr -d ' ')
report "P5 Preference.ToolBarButton 无 'case episodes'" "$toolbar_hits"

# P5：全仓 .episodes 枚举 case（防御性，iina/ 内任何 'case episodes' 都应消失，
# 因为本轮彻底废弃 ViewType.episodes 与 ToolBarButton.episodes 两个唯一来源）
any_case_episodes=$(grep -rE '^[[:space:]]*case[[:space:]]+episodes\b' \
  --include='*.swift' iina/ 2>/dev/null | wc -l | tr -d ' ')
report "P5 iina/ 全仓无任何 'case episodes' 枚举成员" "$any_case_episodes"

echo ""
echo "=== C3 文件级删除验收 ==="

# C3：被废弃的 3 个整文件必须物理消失
# 设计文档「架构决策 3」+ C3 字面量符号集 → 这 3 文件是旧 episodes 面板的载体
DELETED_FILES=(
  "iina/EpisodeListSidebarViewController.swift"
  "iina/SidebarEpisodeListPane.swift"
  "iinaUITests/EpisodeSidebarUITests.swift"
)

for f in "${DELETED_FILES[@]}"; do
  if [ ! -e "$f" ]; then echo "  PASS: $f 已删除"; pass=$((pass+1));
  else echo "  FAIL: $f 仍存在"; fail=$((fail+1)); fi
done

echo ""
echo "=== 结果 ==="
echo "PASS=$pass  FAIL=$fail"
[ "$fail" = "0" ] || exit 1
exit 0
