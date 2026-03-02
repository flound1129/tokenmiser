# tokenmiser Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a bash CLI that compresses Claude Code CLAUDE.md/MEMORY.md files using AI-powered cross-layer deduplication via the `claude` CLI.

**Architecture:** Single bash script (`tokenmiser`) with functions for discovery, token counting, prompt assembly, compression via `claude -p`, diff display, and optional file writing. No external dependencies beyond `claude`, `diff`, and standard coreutils.

**Tech Stack:** Bash, `claude` CLI (`-p` flag for non-interactive), `diff`, `wc`

---

### Task 1: Script skeleton with argument parsing

**Files:**
- Create: `tokenmiser`

**Step 1: Create the script with arg parsing and usage**

```bash
#!/usr/bin/env bash
set -euo pipefail

VERSION="0.1.0"
APPLY=false
EXCLUDES=()
PROJECT_ROOT=""

# Default exclusions (build artifacts and duplicates)
DEFAULT_EXCLUDES=(
  "node_modules"
  ".next"
  "dist"
  "build"
  ".worktrees"
  "__pycache__"
  ".venv"
)

usage() {
  cat <<'EOF'
Usage: tokenmiser <project-root> [options]

Compress CLAUDE.md and MEMORY.md files using AI-powered cross-layer deduplication.

Options:
  --apply             Write compressed files (default: dry-run)
  --exclude <glob>    Additional paths to exclude (repeatable)
  --version           Show version
  -h, --help          Show this help

Examples:
  tokenmiser ~/nodeprojects          # dry-run, show diff
  tokenmiser ~/nodeprojects --apply  # write compressed files
  tokenmiser . --exclude '.next/**'  # exclude extra paths
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --apply)
        APPLY=true
        shift
        ;;
      --exclude)
        EXCLUDES+=("$2")
        shift 2
        ;;
      --version)
        echo "tokenmiser $VERSION"
        exit 0
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      -*)
        echo "Error: unknown option '$1'" >&2
        usage >&2
        exit 1
        ;;
      *)
        if [[ -z "$PROJECT_ROOT" ]]; then
          PROJECT_ROOT="$1"
        else
          echo "Error: unexpected argument '$1'" >&2
          usage >&2
          exit 1
        fi
        shift
        ;;
    esac
  done

  if [[ -z "$PROJECT_ROOT" ]]; then
    echo "Error: project root is required" >&2
    usage >&2
    exit 1
  fi

  PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"
}

main() {
  parse_args "$@"
  echo "Project root: $PROJECT_ROOT"
  echo "Apply mode: $APPLY"
}

main "$@"
```

**Step 2: Make it executable and test arg parsing**

Run: `chmod +x tokenmiser && ./tokenmiser --help`
Expected: Usage text prints and exits 0.

Run: `./tokenmiser ~/nodeprojects`
Expected: Prints "Project root: /home/adam/nodeprojects" and "Apply mode: false".

Run: `./tokenmiser ~/nodeprojects --apply`
Expected: Prints "Apply mode: true".

Run: `./tokenmiser`
Expected: Error message about missing project root, exit 1.

**Step 3: Commit**

```bash
git add tokenmiser
git commit -m "feat: script skeleton with argument parsing"
```

---

### Task 2: File discovery

**Files:**
- Modify: `tokenmiser`

**Step 1: Add the discover_files function**

Add after the `DEFAULT_EXCLUDES` array and before `usage()`:

```bash
discover_files() {
  local root="$1"
  local files=()

  # Layer 1: Global CLAUDE.md
  local global_claude="$HOME/.claude/CLAUDE.md"
  if [[ -f "$global_claude" ]]; then
    files+=("$global_claude")
  fi

  # Layer 2 + 3: Project root and sub-project CLAUDE.md files
  # Build find exclusion args from defaults + user excludes
  local find_excludes=()
  for exc in "${DEFAULT_EXCLUDES[@]}" "${EXCLUDES[@]}"; do
    find_excludes+=(-path "*/$exc/*" -o -path "*/$exc")
  done

  while IFS= read -r -d '' f; do
    files+=("$f")
  done < <(find "$root" \( "${find_excludes[@]}" \) -prune -o -name "CLAUDE.md" -print0 2>/dev/null)

  # Layer: MEMORY.md — derive the project key from root path
  # Claude Code uses the pattern: ~/.claude/projects/-<path-with-dashes>/memory/MEMORY.md
  local project_key
  project_key=$(echo "$root" | sed 's|/|-|g')
  local memory_file="$HOME/.claude/projects/$project_key/memory/MEMORY.md"
  if [[ -f "$memory_file" ]]; then
    files+=("$memory_file")
  fi

  printf '%s\n' "${files[@]}"
}
```

**Step 2: Wire it into main and test**

Replace the `main` function body after `parse_args "$@"`:

```bash
main() {
  parse_args "$@"

  echo "=== Discovering files ==="
  local files
  mapfile -t files < <(discover_files "$PROJECT_ROOT")

  if [[ ${#files[@]} -eq 0 ]]; then
    echo "No CLAUDE.md or MEMORY.md files found."
    exit 0
  fi

  echo "Found ${#files[@]} files:"
  for f in "${files[@]}"; do
    echo "  $f"
  done
}
```

Run: `./tokenmiser ~/nodeprojects`
Expected: Lists global CLAUDE.md, nodeprojects/CLAUDE.md, app-level CLAUDE.md files, and MEMORY.md. Should NOT include `.next/standalone/` or `.worktrees/` copies.

Run: `./tokenmiser ~/pythonprojects`
Expected: Lists global CLAUDE.md, pythonprojects/CLAUDE.md, sub-project CLAUDE.md files, and pythonprojects MEMORY.md.

**Step 3: Commit**

```bash
git add tokenmiser
git commit -m "feat: file discovery across CLAUDE.md hierarchy"
```

---

### Task 3: Token counting

**Files:**
- Modify: `tokenmiser`

**Step 1: Add the count_tokens function**

Add after `discover_files`:

```bash
count_tokens() {
  # Rough estimate: word count × 1.3
  local file="$1"
  local words
  words=$(wc -w < "$file")
  echo $(( (words * 13 + 5) / 10 ))
}

report_tokens() {
  local files=("$@")
  local total=0

  for f in "${files[@]}"; do
    local tokens
    tokens=$(count_tokens "$f")
    total=$((total + tokens))
    printf "  %6d tokens  %s\n" "$tokens" "$f"
  done

  printf "  %6d tokens  TOTAL\n" "$total"
  echo "$total"
}
```

**Step 2: Wire into main**

After the file listing in `main`, add:

```bash
  echo ""
  echo "=== Current token usage ==="
  local before_total
  before_total=$(report_tokens "${files[@]}" | tail -1)
```

Run: `./tokenmiser ~/nodeprojects`
Expected: Shows token count per file and total. Global CLAUDE.md should be ~35 tokens, monorepo ~110 tokens, etc.

**Step 3: Commit**

```bash
git add tokenmiser
git commit -m "feat: token counting with word-based estimation"
```

---

### Task 4: Prompt assembly

**Files:**
- Modify: `tokenmiser`

**Step 1: Add the build_prompt function**

Add after `report_tokens`:

```bash
build_prompt() {
  local files=("$@")

  cat <<'SYSTEM_PROMPT'
You are a technical editor optimizing Claude Code configuration files for minimum token usage. You will receive a hierarchy of CLAUDE.md and MEMORY.md files that are loaded into Claude's context at session start.

Rules:
1. Preserve every directive's semantic meaning exactly. Do not drop, weaken, or alter any instruction.
2. Remove duplication across layers. If a global rule already covers something, do not repeat it in project or sub-project files.
3. Convert verbose prose to terse imperative directives.
   Before: "You should always make sure to use the wrapper script for testing"
   After:  "Use scripts/test.sh — never call pytest directly"
4. Remove markdown structure that adds no information (empty sections, decorative headers, redundant code fences around short values).
5. Preserve code blocks, paths, and command examples exactly.
6. Do not add new directives or commentary.
7. Do not wrap the output in a markdown code fence.

Output each file in this exact format (one per file, in the same order as input):
--- <filepath>
<compressed content>
---

SYSTEM_PROMPT

  echo "Here are the files in the hierarchy (global → project → sub-project):"
  echo ""

  for f in "${files[@]}"; do
    echo "--- $f"
    cat "$f"
    echo ""
    echo "---"
    echo ""
  done
}
```

**Step 2: Test prompt assembly**

Add a temporary debug line in main: `build_prompt "${files[@]}" > /tmp/tokenmiser-prompt.txt`

Run: `./tokenmiser ~/nodeprojects`
Then: Inspect `/tmp/tokenmiser-prompt.txt` — should contain the system prompt followed by each file's content with `--- <path>` delimiters.

Remove the debug line after verifying.

**Step 3: Commit**

```bash
git add tokenmiser
git commit -m "feat: prompt assembly for cross-layer compression"
```

---

### Task 5: Claude CLI compression and output parsing

**Files:**
- Modify: `tokenmiser`

**Step 1: Add the compress function**

Add after `build_prompt`:

```bash
compress() {
  local files=("$@")
  local prompt
  prompt=$(build_prompt "${files[@]}")

  echo "Compressing via claude CLI..." >&2

  local response
  response=$(echo "$prompt" | claude -p --model haiku --no-session-persistence 2>/dev/null)

  if [[ -z "$response" ]]; then
    echo "Error: claude CLI returned empty response" >&2
    return 1
  fi

  echo "$response"
}

parse_compressed() {
  # Parse the "--- <filepath>\n<content>\n---" blocks from claude's response.
  # Outputs pairs of lines: filepath, then content (base64-encoded to preserve newlines).
  local response="$1"
  local current_file=""
  local content=""
  local in_block=false

  while IFS= read -r line; do
    if [[ "$line" =~ ^---[[:space:]]+(/.+)$ ]]; then
      # Start of a new file block
      if [[ -n "$current_file" && "$in_block" == true ]]; then
        # Emit previous block
        echo "$current_file"
        echo "$content" | base64
      fi
      current_file="${BASH_REMATCH[1]}"
      content=""
      in_block=true
    elif [[ "$line" == "---" && "$in_block" == true ]]; then
      # End of current block
      echo "$current_file"
      echo "$content" | base64
      current_file=""
      content=""
      in_block=false
    elif [[ "$in_block" == true ]]; then
      if [[ -n "$content" ]]; then
        content="$content"$'\n'"$line"
      else
        content="$line"
      fi
    fi
  done <<< "$response"

  # Handle case where last block has no closing ---
  if [[ -n "$current_file" && "$in_block" == true ]]; then
    echo "$current_file"
    echo "$content" | base64
  fi
}
```

**Step 2: Test with a real run**

Wire into main after the token report:

```bash
  echo ""
  local response
  response=$(compress "${files[@]}")

  local -A compressed
  local filepath encoded
  while IFS= read -r filepath && IFS= read -r encoded; do
    compressed["$filepath"]=$(echo "$encoded" | base64 -d)
  done < <(parse_compressed "$response")

  if [[ ${#compressed[@]} -eq 0 ]]; then
    echo "Error: could not parse any compressed files from response."
    echo "Raw response:"
    echo "$response"
    exit 1
  fi

  echo "=== Compressed ${#compressed[@]} files ==="
```

Run: `./tokenmiser ~/nodeprojects`
Expected: "Compressing via claude CLI..." then "Compressed N files" where N matches the discovered file count (or close to it).

**Step 3: Commit**

```bash
git add tokenmiser
git commit -m "feat: claude CLI compression and output parsing"
```

---

### Task 6: Diff display and token comparison

**Files:**
- Modify: `tokenmiser`

**Step 1: Add diff display logic to main**

After the compressed files are parsed, add:

```bash
  local after_total=0

  for f in "${files[@]}"; do
    if [[ -v "compressed[$f]" ]]; then
      local before_tokens after_tokens saved pct
      before_tokens=$(count_tokens "$f")
      after_tokens=$(echo "${compressed[$f]}" | wc -w)
      after_tokens=$(( (after_tokens * 13 + 5) / 10 ))
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
      diff --color=always -u <(cat "$f") <(echo "${compressed[$f]}") || true
    else
      echo ""
      echo "━━━ $f ━━━"
      echo "(not in compressed output — keeping as-is)"
      local tokens
      tokens=$(count_tokens "$f")
      after_total=$((after_total + tokens))
    fi
  done

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  local total_saved total_pct
  total_saved=$((before_total - after_total))
  if [[ $before_total -gt 0 ]]; then
    total_pct=$(( (total_saved * 100) / before_total ))
  else
    total_pct=0
  fi
  printf "TOTAL: %d → %d tokens (saved %d, %d%%)\n" \
    "$before_total" "$after_total" "$total_saved" "$total_pct"
```

**Step 2: Test diff output**

Run: `./tokenmiser ~/nodeprojects`
Expected: Colored diff output per file, with before/after token counts and a summary line showing total savings.

**Step 3: Commit**

```bash
git add tokenmiser
git commit -m "feat: diff display with per-file token comparison"
```

---

### Task 7: Apply mode

**Files:**
- Modify: `tokenmiser`

**Step 1: Add apply logic at the end of main**

After the total summary:

```bash
  if [[ "$APPLY" == true ]]; then
    echo ""
    echo "=== Applying changes ==="
    for f in "${files[@]}"; do
      if [[ -v "compressed[$f]" ]]; then
        echo "${compressed[$f]}" > "$f"
        echo "  Wrote: $f"
      fi
    done
    echo "Done."
  else
    echo ""
    echo "Dry run — no files changed. Use --apply to write."
  fi
```

**Step 2: Test dry-run vs apply**

Run: `./tokenmiser ~/nodeprojects`
Expected: Shows diffs, ends with "Dry run — no files changed."

To test apply mode safely, copy a CLAUDE.md to /tmp first:
Run: `cp ~/nodeprojects/CLAUDE.md /tmp/test-claude.md`

Then verify the file was NOT modified after a dry run:
Run: `diff ~/nodeprojects/CLAUDE.md /tmp/test-claude.md`
Expected: No diff (file unchanged).

**Step 3: Commit**

```bash
git add tokenmiser
git commit -m "feat: apply mode to write compressed files"
```

---

### Task 8: End-to-end test against real monorepo (dry-run)

**Files:**
- No file changes — validation only

**Step 1: Run against nodeprojects**

Run: `./tokenmiser ~/nodeprojects`
Expected:
- Discovers 5+ files (global, monorepo, app-level CLAUDE.md files, MEMORY.md)
- Excludes `.next/standalone` copies
- Shows meaningful compression (aim for 20%+ total savings)
- Diffs preserve all directive meanings

**Step 2: Run against pythonprojects**

Run: `./tokenmiser ~/pythonprojects`
Expected:
- Discovers 4+ files
- Excludes `.worktrees/` copies
- Shows meaningful compression

**Step 3: Verify no data loss**

Manually review 2-3 diffs to confirm:
- No directives dropped
- Paths and commands preserved exactly
- Cross-layer dedup removes only true duplicates

**Step 4: Commit (if any fixes were needed)**

```bash
git add tokenmiser
git commit -m "fix: adjustments from end-to-end testing"
```
