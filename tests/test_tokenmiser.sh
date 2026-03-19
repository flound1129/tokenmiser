#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../tokenmiser
source "$SCRIPT_DIR/../tokenmiser"

PASS=0; FAIL=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "  PASS: $desc"
    ((PASS++)) || true
  else
    echo "  FAIL: $desc"
    echo "    expected: |$(echo "$expected" | head -3)|"
    echo "    actual:   |$(echo "$actual"   | head -3)|"
    ((FAIL++)) || true
  fi
}

# ── tests below ──────────────────────────────────────────────────────────────

# ── results ──────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
