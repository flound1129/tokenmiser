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

_found_memory=false
for _f in "${_discovered[@]}"; do
  [[ "$_f" == *"MEMORY.md" ]] && _found_memory=true
done
assert_eq "MEMORY.md still discovered" "true" "$_found_memory"

unset _memdir _projdir _orig_home _discovered _found_alpha _found_beta _found_memory _proj_key _f

echo "=== parse_hunks ==="
# Build a 15-line file with changes at lines 2 and 10 (far enough apart for 2 hunks)
_orig=$(mktemp); _new=$(mktemp)
for i in $(seq -w 1 15); do printf "line%s\n" "$i"; done > "$_orig"
awk 'NR==2{print "line02-new";next} NR==10{print "line10-new";next} {print}' "$_orig" > "$_new"

_plain_diff=$(diff -u "$_orig" "$_new" || true)
_color_diff=$(diff --color=always -u "$_orig" "$_new" || true)

_plain_hunks=()
parse_hunks _plain_hunks "$_plain_diff"
_color_hunks=()
parse_hunks _color_hunks "$_color_diff"

assert_eq "plain hunk count is 2"  "2" "${#_plain_hunks[@]}"
assert_eq "color hunk count is 2"  "2" "${#_color_hunks[@]}"
assert_eq "hunk 1 contains -line02" "true" \
  "$([[ "${_plain_hunks[0]}" == *"-line02"* ]] && echo true || echo false)"
assert_eq "hunk 2 contains -line10" "true" \
  "$([[ "${_plain_hunks[1]}" == *"-line10"* ]] && echo true || echo false)"

rm -f "$_orig" "$_new"
unset _orig _new _plain_diff _color_diff _plain_hunks _color_hunks

echo "=== apply_selected_hunks ==="
_orig=$(mktemp); _new=$(mktemp)
for i in $(seq -w 1 15); do printf "line%s\n" "$i"; done > "$_orig"
awk 'NR==2{print "line02-new";next} NR==10{print "line10-new";next} {print}' "$_orig" > "$_new"
_plain_diff=$(diff -u "$_orig" "$_new" || true)

# All denied → output matches original
_result=$(apply_selected_hunks "$_orig" "$_plain_diff")
assert_eq "all denied = original" "$(cat "$_orig")" "$_result"

# All approved → output matches new file
_result=$(apply_selected_hunks "$_orig" "$_plain_diff" 1 2)
assert_eq "all approved = new file" "$(cat "$_new")" "$_result"

# Hunk 1 approved only → line02-new, line10 unchanged
_expected=$(awk 'NR==2{print "line02-new";next} {print}' "$_orig")
_result=$(apply_selected_hunks "$_orig" "$_plain_diff" 1)
assert_eq "hunk 1 only approved" "$_expected" "$_result"

# Hunk 2 approved only → line02 unchanged, line10-new
_expected=$(awk 'NR==10{print "line10-new";next} {print}' "$_orig")
_result=$(apply_selected_hunks "$_orig" "$_plain_diff" 2)
assert_eq "hunk 2 only approved" "$_expected" "$_result"

rm -f "$_orig" "$_new"
unset _orig _new _plain_diff _result _expected

# ── results ──────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
