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

echo "=== discover_files: feedback_*.md ==="
_tmpdir=$(mktemp -d)
trap 'rm -rf "$_tmpdir"' EXIT

# Simulate a project root with a CLAUDE.md
_projdir="$_tmpdir/testproj"
mkdir -p "$_projdir"
touch "$_projdir/CLAUDE.md"

# Calculate the project key the same way discover_files does
_proj_key=$(echo "$_projdir" | sed 's|/|-|g')

# Simulate the memory directory structure
_memdir="$_tmpdir/.claude/projects/$_proj_key/memory"
mkdir -p "$_memdir"
touch "$_memdir/MEMORY.md"
touch "$_memdir/feedback_alpha.md"
touch "$_memdir/feedback_beta.md"

# Temporarily redirect HOME so discover_files finds our fake memory dir
_orig_home="$HOME"
HOME="$_tmpdir"
EXCLUDES=()
mapfile -t _discovered < <(discover_files "$_projdir")
HOME="$_orig_home"

_found_alpha=false; _found_beta=false
for _f in "${_discovered[@]}"; do
  [[ "$_f" == *"feedback_alpha.md" ]] && _found_alpha=true
  [[ "$_f" == *"feedback_beta.md"  ]] && _found_beta=true
done

assert_eq "feedback_alpha.md discovered" "true" "$_found_alpha"
assert_eq "feedback_beta.md discovered"  "true" "$_found_beta"
unset _tmpdir _memdir _projdir _orig_home _discovered _found_alpha _found_beta _f

# ── results ──────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
