#!/bin/bash
# tests/ReusePlaylistC4BuildAndTests.acceptance.sh
#
# 红队验收 — 契约 C4 / 谓词 P2 / 谓词 P3
# 「编译 + 既有测试通过」黑盒验收（det-machine / 退出码断言）
#
# 信息隔离：本脚本只跑 xcodebuild 并断言退出码/测试计数，不读实现源码。
#
# 覆盖：
#   C4：xcodebuild build 成功 + iinaTests 仍 23/23 通过
#   P2：xcodebuild build 退出码 0
#   P3：xcodebuild test（iinaTests）23/23 通过
#
# 失败行为：build 失败 / 测试数 != 23 / 有失败 → exit 1。

set -u

# 仓库根 = 含 iina.xcodeproj 的目录（同 C3 脚本：不能用 dirname/.. 进任务目录）
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

# 允许跳过实际执行（CI 环境 / 已由外层跑过）— 默认执行
RUN_BUILD="${REUSEPLAYLIST_C4_RUN_BUILD:-1}"

pass=0; fail=0
report() {
  local desc="$1"; shift
  local ok="$1"; shift
  if [ "$ok" = "0" ]; then echo "  PASS: $desc"; pass=$((pass+1));
  else echo "  FAIL: $desc"; fail=$((fail+1)); fi
}

echo "=== P2 — xcodebuild build 退出码 0 ==="

if [ "$RUN_BUILD" = "1" ]; then
  # P2：build 必须退出码 0
  if xcodebuild \
      -project iina.xcodeproj \
      -scheme iina \
      -configuration Debug \
      -destination 'platform=macOS' \
      build >/tmp/reuseplaylist_c4_build.log 2>&1; then
    report "P2 xcodebuild build 退出码 0" 0
  else
    report "P2 xcodebuild build 退出码 0" 1
    echo "  ----- build log tail -----"
    tail -40 /tmp/reuseplaylist_c4_build.log
  fi
else
  echo "  SKIP: REUSEPLAYLIST_C4_RUN_BUILD=0 (外层已跑)"
fi

echo ""
echo "=== P3 — iinaTests 23/23 通过 ==="

if [ "$RUN_BUILD" = "1" ]; then
  # P3：iinaTests 必须 23 测试全通过
  # 解析 .xccovmap / xcresult 较繁，这里用文本统计：xcodebuild test 输出含
  # "Test Suite 'All tests' passed" 与 "Executed N tests"
  TEST_LOG=/tmp/reuseplaylist_c4_test.log
  if xcodebuild test \
      -project iina.xcodeproj \
      -scheme iina \
      -configuration Debug \
      -destination 'platform=macOS' \
      -only-testing iinaTests \
      >"$TEST_LOG" 2>&1; then

    # 从输出抓 "Executed N tests, with M failures"
    # xcodebuild 标准格式（每条 Test Suite 行），抓整批 iinaTests 套件汇总
    executed=$(grep -oE 'Executed [0-9]+ test' "$TEST_LOG" | tail -1 | grep -oE '[0-9]+' || echo "0")
    failures=$(grep -oE 'with [0-9]+ failure' "$TEST_LOG" | tail -1 | grep -oE '[0-9]+' || echo "0")

    # CLAUDE.md「测试现状」：iinaTests 当前 23 测试通过
    if [ "$executed" = "23" ] && [ "$failures" = "0" ]; then
      report "P3 iinaTests 23/23 通过（executed=$executed failures=$failures）" 0
    else
      report "P3 iinaTests 23/23 通过（executed=$executed failures=$failures）" 1
      echo "  ----- test log tail -----"
      tail -40 "$TEST_LOG"
    fi
  else
    report "P3 iinaTests xcodebuild test 退出码 0" 1
    echo "  ----- test log tail -----"
    tail -40 "$TEST_LOG"
  fi
else
  echo "  SKIP: REUSEPLAYLIST_C4_RUN_BUILD=0 (外层已跑)"
fi

echo ""
echo "=== 结果 ==="
echo "PASS=$pass  FAIL=$fail"
[ "$fail" = "0" ] || exit 1
exit 0
