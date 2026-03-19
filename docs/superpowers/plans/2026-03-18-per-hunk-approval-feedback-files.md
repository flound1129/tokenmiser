# Per-Hunk Approval & Feedback File Discovery — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace tokenmiser's per-file apply prompt with per-hunk approval, and include `feedback_*.md` files in the discovery and compression pass.

**Architecture:** All changes are to the single `tokenmiser` bash script. Add a source guard to enable unit testing. Extract two pure functions (`parse_hunks`, `apply_selected_hunks`) that power the hunk loop. The main processing loop replaces the single `read -rp "Apply this file?"` prompt with a loop over parsed hunks. `discover_files` gets a one-block addition to glob feedback files.

**Tech Stack:** Bash, `diff` (standard, GNU), `mapfile`, temp files for tests.

---

## File Map

| File | Change |
|---|---|
| `tokenmiser` | Add source guard; add `parse_hunks`, `apply_selected_hunks` functions; extend `discover_files`; replace per-file prompt loop |
| `tests/test_tokenmiser.sh` | New — unit test harness for the pure functions |

---

### Task 1: Source guard and test harness

**Files:**
- Modify: `tokenmiser` (last line only)
- Create: `tests/test_tokenmiser.sh`

- [ ] **Step 1: Add source guard to tokenmiser**

The last line of `tokenmiser` is currently `main "$@"`. Replace it:

```bash
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
```

This allows `source tokenmiser` in tests without executing `main`.

- [ ] **Step 2: Create the test harness**

Create `tests/test_tokenmiser.sh`:

```bash
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
```

- [ ] **Step 3: Run the harness (expect 0 tests)**

```bash
chmod +x tests/test_tokenmiser.sh
bash tests/test_tokenmiser.sh
```

Expected output:
```
Results: 0 passed, 0 failed
```

- [ ] **Step 4: Commit**

```bash
git add tokenmiser tests/test_tokenmiser.sh
git commit -m "test: add source guard and test harness"
```

---

### Task 2: Feedback file discovery

**Files:**
- Modify: `tokenmiser` (`discover_files` function, memory file block)
- Modify: `tests/test_tokenmiser.sh`

- [ ] **Step 1: Write the failing test**

Add this block to `tests/test_tokenmiser.sh` between the `# ── tests below ──` and `# ── results ──` markers:

```bash
echo "=== discover_files: feedback_*.md ==="
_tmpdir=$(mktemp -d)
trap 'rm -rf "$_tmpdir"' EXIT

# Simulate the memory directory structure
_memdir="$_tmpdir/.claude/projects/-tmp-testproj/memory"
mkdir -p "$_memdir"
touch "$_memdir/MEMORY.md"
touch "$_memdir/feedback_alpha.md"
touch "$_memdir/feedback_beta.md"

# Simulate a project root with a CLAUDE.md
_projdir="$_tmpdir/testproj"
mkdir -p "$_projdir"
touch "$_projdir/CLAUDE.md"

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
```

- [ ] **Step 2: Run to confirm failure**

```bash
bash tests/test_tokenmiser.sh
```

Expected: `Results: 0 passed, 2 failed`

- [ ] **Step 3: Implement in `discover_files`**

In `tokenmiser`, find the existing MEMORY.md block (around line 119):

```bash
  local memory_file="$HOME/.claude/projects/$project_key/memory/MEMORY.md"
  if [[ -f "$memory_file" ]]; then
    files+=("$memory_file")
  fi
```

Replace it with:

```bash
  local memory_dir="$HOME/.claude/projects/$project_key/memory"
  local memory_file="$memory_dir/MEMORY.md"
  if [[ -f "$memory_file" ]]; then
    files+=("$memory_file")
  fi
  while IFS= read -r -d '' f; do
    files+=("$f")
  done < <(find "$memory_dir" -maxdepth 1 -name "feedback_*.md" -print0 2>/dev/null)
```

- [ ] **Step 4: Run to confirm passing**

```bash
bash tests/test_tokenmiser.sh
```

Expected: `Results: 2 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add tokenmiser tests/test_tokenmiser.sh
git commit -m "feat: discover feedback_*.md files alongside MEMORY.md"
```

---

### Task 3: `parse_hunks` — split a diff into indexed hunk array

**Files:**
- Modify: `tokenmiser` (add function before `main`)
- Modify: `tests/test_tokenmiser.sh`

`parse_hunks` takes a nameref array and a diff string and fills the array with one entry per `@@` block. Works identically for plain and colored diff output (the caller passes whichever it needs).

- [ ] **Step 1: Write the failing test**

Add to `tests/test_tokenmiser.sh`:

```bash
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
```

- [ ] **Step 2: Run to confirm failure**

```bash
bash tests/test_tokenmiser.sh
```

Expected: `Results: 2 passed, 4 failed`

- [ ] **Step 3: Implement `parse_hunks`**

Add this function to `tokenmiser` just before the `main()` function:

```bash
parse_hunks() {
  # Usage: parse_hunks <nameref_array> <diff_output>
  # Fills nameref_array with one entry per @@ block.
  # Works with both plain and colored diff: colored @@ lines are prefixed with
  # ANSI escape codes, so we match on the @@ ... @@ content pattern, not ^@@.
  local -n _ph=$1
  local diff_output="$2"
  local current="" in_hunk=false

  while IFS= read -r line; do
    if [[ "$line" =~ ^"---" || "$line" =~ ^"+++" ]]; then
      continue
    elif [[ "$line" =~ @@\ -[0-9]+.*\ \+[0-9]+ ]]; then
      if [[ "$in_hunk" == true ]]; then
        _ph+=("$current")
      fi
      current="$line"
      in_hunk=true
    elif [[ "$in_hunk" == true ]]; then
      current+=$'\n'"$line"
    fi
  done <<< "$diff_output"

  if [[ "$in_hunk" == true && -n "$current" ]]; then
    _ph+=("$current")
  fi
}
```

- [ ] **Step 4: Run to confirm passing**

```bash
bash tests/test_tokenmiser.sh
```

Expected: `Results: 6 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add tokenmiser tests/test_tokenmiser.sh
git commit -m "feat: add parse_hunks to split diff into per-hunk array"
```

---

### Task 4: `apply_selected_hunks` — reconstruct file from selective hunk approval

**Files:**
- Modify: `tokenmiser` (add function after `parse_hunks`, before `main`)
- Modify: `tests/test_tokenmiser.sh`

The function reconstructs the output file by reading the original on disk for unchanged regions and substituting compressed lines only for approved hunks.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test_tokenmiser.sh` (reuse the temp files from the `parse_hunks` block — but since that block cleans up, create fresh ones here):

```bash
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
```

- [ ] **Step 2: Run to confirm failure**

```bash
bash tests/test_tokenmiser.sh
```

Expected: `Results: 6 passed, 4 failed`

- [ ] **Step 3: Implement `apply_selected_hunks`**

Add after `parse_hunks` in `tokenmiser`:

```bash
apply_selected_hunks() {
  # Usage: apply_selected_hunks <orig_file> <plain_diff> [hunk_num ...]
  # Reconstructs file content applying only the listed (1-based) hunks.
  # Uses the original file for unchanged regions and between-hunk lines.
  local orig_file="$1"
  local plain_diff="$2"
  shift 2

  local -A _approved
  for h in "$@"; do _approved[$h]=1; done

  # Pre-parse: collect hunk metadata from the diff headers
  # h_start[i] = 0-based start line in original for hunk i+1
  # h_count[i] = number of original lines the hunk spans
  # h_new[i]   = reconstructed new content (context + additions, newline-separated)
  local -a h_start h_count h_new
  local _hn=0 _cur_start=0 _cur_count=0 _cur_new="" _in_hunk=false

  while IFS= read -r line; do
    if [[ "$line" =~ ^"---" || "$line" =~ ^"+++" ]]; then
      continue
    elif [[ "$line" =~ @@\ -([0-9]+)(,([0-9]*))?\ \+ ]]; then
      if [[ "$_in_hunk" == true ]]; then
        h_start+=("$(( _cur_start - 1 ))")
        h_count+=("$_cur_count")
        h_new+=("$_cur_new")
        (( _hn++ )) || true
      fi
      _cur_start="${BASH_REMATCH[1]}"
      _cur_count="${BASH_REMATCH[3]}"
      [[ -z "$_cur_count" ]] && _cur_count=1
      _cur_new=""
      _in_hunk=true
    elif [[ "$_in_hunk" == true ]]; then
      case "${line:0:1}" in
        " "|"+")
          [[ -n "$_cur_new" ]] && _cur_new+=$'\n'"${line:1}" || _cur_new="${line:1}" ;;
      esac
    fi
  done <<< "$plain_diff"

  if [[ "$_in_hunk" == true ]]; then
    h_start+=("$(( _cur_start - 1 ))")
    h_count+=("$_cur_count")
    h_new+=("$_cur_new")
    (( _hn++ )) || true
  fi

  # Reconstruct: walk original file, substituting approved hunks
  mapfile -t _orig < "$orig_file"
  local _pos=0  # 0-based index into _orig

  for (( i=0; i<_hn; i++ )); do
    local _h=$(( i + 1 ))  # 1-based hunk number
    local _hs=${h_start[$i]}
    local _hc=${h_count[$i]}

    # Emit original lines before this hunk
    while [[ $_pos -lt $_hs ]]; do
      printf '%s\n' "${_orig[$_pos]}"
      (( _pos++ )) || true
    done

    if [[ -n "${_approved[$_h]+_}" ]]; then
      # Approved: emit new content (may be empty for pure deletions)
      [[ -n "${h_new[$i]}" ]] && printf '%s\n' "${h_new[$i]}"
    else
      # Denied: emit original lines for this hunk
      local _end=$(( _hs + _hc ))
      for (( j=_hs; j<_end; j++ )); do
        printf '%s\n' "${_orig[$j]}"
      done
    fi
    _pos=$(( _hs + _hc ))
  done

  # Emit remaining original lines after last hunk
  while [[ $_pos -lt ${#_orig[@]} ]]; do
    printf '%s\n' "${_orig[$_pos]}"
    (( _pos++ )) || true
  done
}
```

- [ ] **Step 4: Run to confirm passing**

```bash
bash tests/test_tokenmiser.sh
```

Expected: `Results: 10 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add tokenmiser tests/test_tokenmiser.sh
git commit -m "feat: add apply_selected_hunks for selective hunk reconstruction"
```

---

### Task 5: Replace per-file prompt with per-hunk loop

**Files:**
- Modify: `tokenmiser` (`main` function — the per-file review loop)

This is the only task with no automated test (interactive stdin). Verify by smoke test at the end.

The current per-file block (roughly lines 296–339) looks like:

```bash
  local after_total=0
  local -a approved=()

  for f in "${files[@]}"; do
    if [[ -v "compressed[$f]" ]]; then
      local before_tokens after_tokens saved pct
      before_tokens=$(count_tokens "$f")
      after_tokens=$(count_tokens_string "${compressed[$f]}")
      saved=$((before_tokens - after_tokens))
      if [[ $before_tokens -gt 0 ]]; then
        pct=$(( (saved * 100) / before_tokens ))
      else
        pct=0
      fi
      after_total=$((after_total + after_tokens))

      echo ""
      echo "━━━ $f ━━━"
      printf "Before: %d tokens → After: %d tokens (saved %d, %d%%)\n" \
        "$before_tokens" "$after_tokens" "$saved" "$pct"
      echo ""
      diff --color=always -u --label "original: $f" --label "compressed: $f" \
        <(cat "$f") <(echo "${compressed[$f]}") || true

      if [[ "$APPLY" == true ]]; then
        approved+=("$f")
      else
        echo ""
        read -rp "Apply this file? [y/N] " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
          approved+=("$f")
        fi
      fi
    else
      echo ""
      echo "━━━ $f ━━━"
      echo "(not in compressed output — keeping as-is)"
      local tokens
      tokens=$(count_tokens "$f")
      after_total=$((after_total + tokens))
    fi
  done
```

And the write step (roughly lines 354–362):

```bash
  for f in "${approved[@]}"; do
    echo "${compressed[$f]}" > "$f"
    echo "  Wrote: $f"
  done
```

- [ ] **Step 1: Add `reconstructed` associative array**

Find `declare -A compressed` in `main` and add the parallel array on the next line:

```bash
  declare -A compressed
  declare -A reconstructed
```

- [ ] **Step 2: Replace the per-file review block**

Replace the entire block shown above (from `local after_total=0` through the closing `done`) with:

```bash
  local after_total=0
  local -a approved=()

  for f in "${files[@]}"; do
    if [[ -v "compressed[$f]" ]]; then
      local before_tokens
      before_tokens=$(count_tokens "$f")

      echo ""
      echo "━━━ $f ━━━"

      if [[ "$APPLY" == true ]]; then
        local after_tokens saved pct
        after_tokens=$(count_tokens_string "${compressed[$f]}")
        saved=$(( before_tokens - after_tokens ))
        pct=$(( before_tokens > 0 ? (saved * 100) / before_tokens : 0 ))
        printf "Before: %d tokens → After: %d tokens (saved %d, %d%%)\n" \
          "$before_tokens" "$after_tokens" "$saved" "$pct"
        reconstructed["$f"]="${compressed[$f]}"
        approved+=("$f")
        after_total=$(( after_total + after_tokens ))
      else
        # Compute plain diff for reconstruction; colored diff for display
        local plain_diff color_diff
        plain_diff=$(diff -u <(cat "$f") <(printf '%s' "${compressed[$f]}") || true)

        if [[ -z "$plain_diff" ]]; then
          echo "(no changes — keeping as-is)"
          after_total=$(( after_total + before_tokens ))
          continue
        fi

        color_diff=$(diff --color=always -u \
          --label "original: $f" --label "compressed: $f" \
          <(cat "$f") <(printf '%s' "${compressed[$f]}") || true)

        local -a plain_hunks=() color_hunks=()
        parse_hunks plain_hunks "$plain_diff"
        parse_hunks color_hunks "$color_diff"
        local total_hunks=${#plain_hunks[@]}
        local -a approved_hunks=()

        for (( i=0; i<total_hunks; i++ )); do
          local hunk_num=$(( i + 1 ))
          echo ""
          printf "  Hunk %d/%d  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n" \
            "$hunk_num" "$total_hunks"
          echo "${color_hunks[$i]}"
          echo ""
          read -rp "Apply? [y/N] " confirm
          if [[ "$confirm" =~ ^[Yy]$ ]]; then
            approved_hunks+=("$hunk_num")
          fi
        done

        local after_tokens saved pct
        if [[ ${#approved_hunks[@]} -gt 0 ]]; then
          reconstructed["$f"]=$(apply_selected_hunks "$f" "$plain_diff" "${approved_hunks[@]}")
          approved+=("$f")
          after_tokens=$(count_tokens_string "${reconstructed[$f]}")
        else
          after_tokens=$before_tokens
        fi
        saved=$(( before_tokens - after_tokens ))
        pct=$(( before_tokens > 0 ? (saved * 100) / before_tokens : 0 ))
        printf "After selection: %d → %d tokens (saved %d, %d%%)\n" \
          "$before_tokens" "$after_tokens" "$saved" "$pct"
        after_total=$(( after_total + after_tokens ))
      fi
    else
      echo ""
      echo "━━━ $f ━━━"
      echo "(not in compressed output — keeping as-is)"
      local tokens
      tokens=$(count_tokens "$f")
      after_total=$(( after_total + tokens ))
    fi
  done
```

- [ ] **Step 3: Update the write step**

Replace:

```bash
    echo "${compressed[$f]}" > "$f"
```

with:

```bash
    printf '%s' "${reconstructed[$f]}" > "$f"
```

- [ ] **Step 4: Run the unit tests (must still pass)**

```bash
bash tests/test_tokenmiser.sh
```

Expected: `Results: 10 passed, 0 failed`

- [ ] **Step 5: Smoke test — dry run**

```bash
./tokenmiser . 2>&1 | head -20
```

Expected: shows discovery output and "Compressing N files via claude CLI..." (it will actually call claude; interrupt with Ctrl-C after confirming discovery works, or let it run).

- [ ] **Step 6: Commit**

```bash
git add tokenmiser
git commit -m "feat: replace per-file prompt with per-hunk approval loop"
```

---

### Task 6: Merge and push to main

- [ ] **Step 1: Run all tests one final time**

```bash
bash tests/test_tokenmiser.sh
```

Expected: `Results: 10 passed, 0 failed`

- [ ] **Step 2: Merge to main and push**

```bash
git checkout main
git merge per-file-apply-prompt
git push origin main
```
