# tokenmiser — Per-Hunk Approval & Feedback File Discovery

**Date:** 2026-03-18
**Status:** Approved

## Problem

Two gaps in the current tokenmiser workflow:

1. The apply prompt is per-file — you must accept or reject all changes in a file. A single bad compression forces you to reject the whole file even if most changes are good.
2. `feedback_*.md` files in the project memory directory are not discovered or optimized, leaving them uncompressed and potentially redundant.

## Solution

### Feature 1: Per-hunk approval

Replace the per-file `Apply this file? [y/N]` prompt with a per-hunk loop. Each contiguous block of changes (a diff hunk) is presented individually. The user approves or denies each one. The output file is reconstructed by selectively applying approved hunks while preserving denied hunks from the original.

### Feature 2: Feedback file discovery

Extend `discover_files` to also collect `feedback_*.md` files from the project memory directory. The `find` for feedback files runs unconditionally — the memory directory may contain feedback files even if MEMORY.md is absent. These files join the same AI compression prompt, diff/review loop, and apply step with no special handling.

## Design

### Discovery changes

In `discover_files`, after handling MEMORY.md, unconditionally glob `feedback_*.md` files in the same memory directory and append them to the files array:

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

The `2>/dev/null` on `find` silently handles a missing memory directory.

### Per-hunk approval flow

For each file with compressed output:

1. Compute a **plain** unified diff (`diff -u`, no color) between the original file and the compressed string — used for reconstruction.
2. Compute a **colored** unified diff (`diff --color=always -u`) of the same inputs — used for display only.
3. Pre-scan the plain diff to count `@@` lines, establishing `Total` hunk count.
4. Collect all hunks from the plain diff into an indexed array (one entry per `@@` block, including its context and change lines). Build a parallel indexed array from the colored diff in the same pass, used for display only.
5. For each hunk index `N` (1-based):
   - Display: `Hunk N/Total ━━━━━━━━━━━━━━━━━━━━━━━`
   - Display hunk `N` from the colored diff array
   - Prompt: `Apply? [y/N]`
   - Record approved hunk indices
6. Reconstruct the output file from the plain diff and the approved set (see below). Store result in `reconstructed[$f]`.
7. Compute and display per-file token savings reflecting only the approved hunks. **Note:** this is a behavioral change from the current flow, which shows savings before the prompt. Savings are now shown after all hunks are answered.
8. If at least one hunk was approved, queue `$f` for writing using `reconstructed[$f]`.

### File reconstruction

Walk the **plain** unified diff line by line, tracking the current hunk number (incremented on each `@@` line). Emit lines as follows:

- `@@` line → increment hunk counter; skip (do not emit)
- `---`/`+++` header lines → skip
- ` ` prefix (context line) → emit the content (strip leading space)
- `-` prefix → emit content only if current hunk is **denied** (keep original line)
- `+` prefix → emit content only if current hunk is **approved** (use compressed line)

This produces valid file content without requiring `patch` or any external tools. Store the result in `reconstructed[$f]`.

### Edge cases

| Scenario | Behavior |
|---|---|
| All hunks denied | File unchanged, no write |
| All hunks approved | Equivalent to full-file apply |
| Partial approval | `reconstructed[$f]` written with mixed original/compressed content |
| No diff produced (compressed = original) | Zero iterations of the hunk loop; file unchanged, no write |
| `--apply` flag | All hunks auto-approved, no prompts (unchanged behavior) |
| File missing from compressed output | Kept as-is (unchanged) |

### Hunk display format

```
  Hunk 1/3  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
@@ -12,6 +12,3 @@
   context line
-  verbose old line one
-  verbose old line two
+  terse replacement
   context line

Apply? [y/N]
```

Color output comes from the separate `--color=always` diff invocation. The plain diff is used only for reconstruction logic — never displayed.

## Scope

**In scope:**
- Per-hunk approval replacing per-file approval
- `feedback_*.md` discovery and inclusion in compression pass
- File reconstruction from selectively applied hunks
- Two-pass diff: plain for reconstruction, colored for display

**Out of scope:**
- Changes to `--apply` behavior
- Changes to the compression prompt
- Per-line (sub-hunk) granularity

## Success Criteria

- User can approve some hunks and deny others within a single file
- Resulting file is valid (no garbled content from partial application)
- `feedback_*.md` files appear in discovery regardless of whether MEMORY.md exists
- `--apply` continues to work without prompts
