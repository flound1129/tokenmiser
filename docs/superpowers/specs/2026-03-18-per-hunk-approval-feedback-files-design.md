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

Extend `discover_files` to also collect `feedback_*.md` files from the project memory directory alongside `MEMORY.md`. These files are included in the same AI compression prompt, diff/review loop, and apply step — no special handling.

## Design

### Discovery changes

In `discover_files`, after finding the MEMORY.md file for the project key, glob all `feedback_*.md` files in the same directory and append them to the files array.

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

### Per-hunk approval flow

For each file with compressed output:

1. Compute unified diff between original file and compressed string
2. Parse diff into numbered hunks (split on `@@` lines)
3. For each hunk:
   - Display: `Hunk N/Total ━━━━━━━━━━━━━━━━━━━━━━━`
   - Display the hunk content with color (red `-`, green `+`)
   - Prompt: `Apply? [y/N]`
   - Collect approved hunk indices
4. Reconstruct output using approved hunks (see below)
5. Show per-file token savings for the approved combination
6. Queue for writing if at least one hunk was approved

### File reconstruction

Walk the unified diff line by line, tracking the current hunk number:

- `@@` line → increment hunk counter
- `---`/`+++` header lines → skip
- ` ` (context) lines → always output
- `-` lines → output only if current hunk is **denied** (keep original)
- `+` lines → output only if current hunk is **approved** (use compressed)

This produces the correct reconstructed content without requiring `patch` or external tools.

### Edge cases

| Scenario | Behavior |
|---|---|
| All hunks denied | File unchanged, no write |
| All hunks approved | Equivalent to full-file apply |
| Partial approval | Reconstructed file with mixed content written |
| `--apply` flag | All hunks auto-approved, no prompts (unchanged) |
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

Color: red for removed lines, green for added lines (using existing `--color=always` diff output).

## Scope

**In scope:**
- Per-hunk approval replacing per-file approval
- `feedback_*.md` discovery and inclusion in compression pass
- File reconstruction from selectively applied hunks

**Out of scope:**
- Changes to `--apply` behavior
- Changes to the compression prompt
- Per-line (sub-hunk) granularity

## Success Criteria

- User can approve some hunks and deny others within a single file
- Resulting file is valid (no garbled content from partial application)
- `feedback_*.md` files appear in discovery and are included in the AI prompt
- `--apply` continues to work without prompts
