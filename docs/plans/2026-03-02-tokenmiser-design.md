# tokenmiser — Context-Aware CLAUDE.md Compressor

**Date:** 2026-03-02
**Status:** Approved

## Problem

Claude Code loads CLAUDE.md and MEMORY.md files into context at session start. Across two monorepos (~11 unique CLAUDE.md files + 2 MEMORY.md files + 1 global CLAUDE.md), this consumes 15-20% of the context window. Files contain cross-layer duplication and verbose prose that could be compressed without losing meaning.

## Solution

A bash CLI tool that understands Claude Code's 3-layer file hierarchy, uses the `claude` CLI for AI-powered compression, and deduplicates across layers.

## Architecture

### File Hierarchy

```
Layer 1: ~/.claude/CLAUDE.md                          (global — always loaded)
Layer 2: <project-root>/CLAUDE.md                     (project — loaded in project)
Layer 3: <project-root>/**/CLAUDE.md                  (sub-project — loaded in subdir)
         ~/.claude/projects/<key>/memory/MEMORY.md     (auto-memory for project)
```

### CLI Interface

```
tokenmiser <project-root>        # dry-run by default
tokenmiser <project-root> --apply   # write compressed files
tokenmiser . --exclude '.next/**'   # exclude paths
```

**Options:**
- Default: dry-run (show diff + token counts, write nothing)
- `--apply`: write compressed files after showing diff
- `--exclude <glob>`: skip matching paths

### Flow

1. **Discovery** — Given a project root, find all relevant files:
   - `~/.claude/CLAUDE.md` (global)
   - `<root>/CLAUDE.md` (project)
   - All `<root>/**/CLAUDE.md` (sub-projects)
   - Matching `~/.claude/projects/<key>/memory/MEMORY.md`
   - Auto-exclude: `node_modules/`, `.next/`, `dist/`, `build/`, `.worktrees/`

2. **Token counting** — Word count x 1.3 as rough token estimate. Report per-file and total.

3. **Compression** — Send all files to `claude` CLI with a structured prompt (see below). Claude returns compressed versions of each file.

4. **Review** — Show unified diff per file with before/after token counts.

5. **Apply** — With `--apply`, write compressed files. Without it, exit after showing the diff.

### Compression Prompt

```
You are a technical editor optimizing Claude Code configuration files for
minimum token usage. You will receive a hierarchy of CLAUDE.md and MEMORY.md
files that are loaded into Claude's context at session start.

Rules:
1. Preserve every directive's semantic meaning exactly. Do not drop, weaken,
   or alter any instruction.
2. Remove duplication across layers. If a global rule already covers something,
   do not repeat it in project or sub-project files.
3. Convert verbose prose to terse imperative directives.
   Before: "You should always make sure to use the wrapper script for testing"
   After:  "Use scripts/test.sh — never call pytest directly"
4. Remove markdown structure that adds no information (empty sections,
   decorative headers, redundant code fences around short values).
5. Preserve code blocks, paths, and command examples exactly.
6. Do not add new directives or commentary.

Output each file as:
--- <filepath>
<compressed content>
---
```

### Excluded Paths

Automatically skip directories that contain build artifacts or duplicates:
- `node_modules/`, `.next/`, `dist/`, `build/`
- `.worktrees/` (copies of root CLAUDE.md)

### Token Estimation

Word count x 1.3 (avoids tokenizer dependency, close enough for comparison).

## Scope

**In scope:**
- Bash script with `claude` CLI integration
- Discovery of CLAUDE.md hierarchy from a project root
- AI-powered cross-layer deduplication and compression
- Dry-run with diff output and token counts
- `--apply` flag to write changes

**Out of scope (for now):**
- Historical stats/tracking
- Automated scheduling (cron/hooks)
- MEMORY.md topic file optimization (only MEMORY.md itself)
- Plugin packaging

## Success Criteria

- Reduces total token count of discovered files by 20%+ without losing any directive
- Dry-run output is clear enough to verify no meaning was lost
- Runs in under 30 seconds for a typical monorepo
