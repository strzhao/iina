#!/bin/bash
# tests/iina-cli-log.acceptance.sh
#
# Black-box acceptance for the iina-cli diagnostic subcommands (`iina log ...`).
# Hermetic: redirects IINA_LOG_DIR to a temp dir, seeds a known log, asserts behavior.
# Note: `iina log show --json` emits JSON Lines (one object per line), not a JSON array,
# so we use `jq -s` (slurp) to parse.
#
# Prerequisite: xcodebuild -project iina.xcodeproj -target iina-cli -configuration Debug build
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$REPO_ROOT/build/Debug/iina-cli"

if [ ! -x "$CLI" ]; then
  echo "FAIL: iina-cli not built at $CLI"
  echo "  Run: xcodebuild -project iina.xcodeproj -target iina-cli -configuration Debug build"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "FAIL: jq is required (brew install jq)"
  exit 1
fi

export IINA_LOG_DIR="$(mktemp -d -t iina-cli-accept)"
trap 'rm -rf "$IINA_LOG_DIR"' EXIT
LOG_PATH="$IINA_LOG_DIR/iina.jsonl"
TMP="$IINA_LOG_DIR/_out.json"

cat > "$LOG_PATH" <<'EOF'
{"level":"debug","msg":"app started","subsystem":"iina","ts":"2026-07-19T11:04:08.861Z"}
{"level":"warning","msg":"codec fallback","subsystem":"mpv0","ts":"2026-07-19T11:04:09.000Z"}
{"level":"error","msg":"Failed to recognize file format","subsystem":"mpv0","ts":"2026-07-19T11:04:10.000Z","meta":{"file":"cplayer"}}
EOF

pass=0; fail=0
check() {
  local desc="$1"; shift
  if "$@"; then echo "  PASS: $desc"; pass=$((pass+1));
  else echo "  FAIL: $desc"; fail=$((fail+1)); fi
}

echo "=== iina-cli log acceptance ==="

# log path
out=$("$CLI" log path)
check "log path prints jsonl path" test "$out" = "$LOG_PATH"

# log show --json emits valid JSON Lines (jq -s slurps into an array)
"$CLI" log show --json > "$TMP"
check "log show --json is valid JSONL" jq -s -e '.[0].msg' "$TMP" >/dev/null

# log show --level warning returns warning AND error (2 lines)
"$CLI" log show --level warning --json > "$TMP"
count=$(jq -s 'length' "$TMP")
check "log show --level warning returns 2 (warning+error)" test "$count" -eq 2

# log show --subsystem mpv0 (CLI filters; expect 2)
"$CLI" log show --subsystem mpv0 --json > "$TMP"
count=$(jq -s 'length' "$TMP")
check "log show --subsystem mpv0 returns 2" test "$count" -eq 2

# log grep
"$CLI" log grep "recognize" --json > "$TMP"
count=$(jq -s 'length' "$TMP")
check "log grep recognize returns 1" test "$count" -eq 1

# log tail --lines 2
out=$("$CLI" log tail --lines 2)
lines=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
check "log tail --lines 2 returns 2 lines" test "$lines" -eq 2

# version
out=$("$CLI" version)
check "version prints IINA prefix" sh -c "printf '%s' \"\$1\" | grep -q '^IINA '" _ "$out"

echo ""
echo "Result: $pass passed, $fail failed"
if [ "$fail" -eq 0 ]; then
  echo "ACCEPTANCE PASS"
  exit 0
else
  echo "ACCEPTANCE FAIL"
  exit 1
fi
