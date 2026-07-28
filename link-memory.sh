#!/usr/bin/env bash
# link-memory.sh — Deduplicate per-project Claude auto-memory across machines.
#
# Problem: Claude keys its per-project memory dir by the project's ABSOLUTE path,
# e.g.  projects/-home-stephan-git-rtl-jupyter-dashboard/memory/
# The same repo checked out at a different path on another machine
# (…/-home-stephan-workspace-git-rtl-jupyter-dashboard/…) gets a SEPARATE
# path-keyed dir. Synced via git, both dirs survive, but each machine only
# reads the one matching its own layout — so memory silently forks per machine.
#
# Fix: pick the de-workspaced path-key as the canonical real memory dir, merge
# the "-workspace-" twin's memory into it, then replace the twin's memory/ with
# a relative symlink → canonical. Git stores the symlink (mode 120000) and
# recreates it on pull, so BOTH path-keys resolve to ONE memory/ on every
# machine. From then on Claude reads/writes a single shared store.
#
# Usage:
#   ./link-memory.sh [--dry-run] [--config <name>]
#       Auto-discover every "-workspace-" project pair and link it.
#   ./link-memory.sh [--dry-run] <canonical-pathkey> <workspace-pathkey>
#       Link one explicit pair (dir names under projects/, no slashes).
#
# Notes:
#   * Only the memory/ subdir is touched. Session .jsonl transcripts and
#     tool-results stay put — those are per-machine session state, not memory.
#   * Merge never overwrites an existing same-name fact file in canonical.
#     Divergent same-name files are reported and left for manual review.
#   * MEMORY.md is unioned line-wise (dedup identical lines), preserving all
#     pointers from both sides.
#   * Idempotent: a twin whose memory/ is already the correct symlink is skipped.
#   * Does NOT commit or push. Run `claude-sync` afterwards.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="$SCRIPT_DIR/config"
CURRENT_LINK="$CONFIG_DIR/current"

DRY_RUN=0
CONFIG_NAME=""
POSITIONAL=()

log()  { echo "[link-memory] $*"; }
warn() { echo "[link-memory] WARNING: $*" >&2; }
run()  { if [ "$DRY_RUN" -eq 1 ]; then echo "[dry-run] $*"; else eval "$*"; fi; }

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --config)  CONFIG_NAME="${2:-}"; shift ;;
        -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
        -*)        echo "Unknown option: $1" >&2; exit 1 ;;
        *)         POSITIONAL+=("$1") ;;
    esac
    shift
done

# Resolve the projects/ root of the active (or named) config.
resolve_projects_dir() {
    local base
    if [ -n "$CONFIG_NAME" ]; then
        base="$CONFIG_DIR/$CONFIG_NAME"
    elif [ -L "$CURRENT_LINK" ]; then
        base="$(readlink -f "$CURRENT_LINK")"
    else
        echo "No active config and no --config given." >&2
        exit 1
    fi
    if [ ! -d "$base/projects" ]; then
        echo "No projects/ dir under $base" >&2
        exit 1
    fi
    echo "$base/projects"
}

PROJECTS_DIR="$(resolve_projects_dir)"

# Merge workspace memory/ into canonical memory/, then symlink workspace → canonical.
# Args: <canonical-pathkey> <workspace-pathkey>
link_pair() {
    local canon="$1" ws="$2"
    local canon_dir="$PROJECTS_DIR/$canon"
    local ws_dir="$PROJECTS_DIR/$ws"
    local canon_mem="$canon_dir/memory"
    local ws_mem="$ws_dir/memory"

    if [ ! -d "$canon_dir" ]; then
        warn "canonical project dir missing: $canon — skipping."
        return
    fi

    # Already linked correctly?
    if [ -L "$ws_mem" ]; then
        local tgt
        tgt="$(readlink -f "$ws_mem" || true)"
        if [ "$tgt" = "$(readlink -f "$canon_mem" 2>/dev/null || true)" ]; then
            log "already linked: $ws/memory → $canon/memory (skip)"
            return
        fi
        warn "$ws/memory is a symlink to an unexpected target ($tgt) — skipping."
        return
    fi

    run "mkdir -p '$canon_mem'"

    # No workspace memory to merge — just create the symlink.
    if [ ! -d "$ws_mem" ]; then
        log "no $ws/memory dir; creating symlink only."
        make_symlink "$canon" "$ws" "$ws_dir" "$ws_mem"
        return
    fi

    log "merging $ws/memory → $canon/memory"

    # Merge fact files (any *.md except MEMORY.md). Never overwrite; report divergent twins.
    local f base
    while IFS= read -r f; do
        base="$(basename "$f")"
        [ "$base" = "MEMORY.md" ] && continue
        local dest="$canon_mem/$base"
        if [ -e "$dest" ]; then
            if ! diff -q "$f" "$dest" >/dev/null 2>&1; then
                warn "CONFLICT (kept canonical, review manually): $base"
            fi
        else
            run "cp -p '$f' '$dest'"
            log "  + $base"
        fi
    done < <(find "$ws_mem" -maxdepth 1 -type f -name '*.md')

    merge_memory_index "$canon_mem/MEMORY.md" "$ws_mem/MEMORY.md"

    make_symlink "$canon" "$ws" "$ws_dir" "$ws_mem"
}

# Union two MEMORY.md pointer lists into the canonical one, dedup identical lines,
# preserve order (canonical first, then workspace-only lines).
merge_memory_index() {
    local canon_idx="$1" ws_idx="$2"
    [ -f "$ws_idx" ] || return 0
    if [ ! -f "$canon_idx" ]; then
        run "cp -p '$ws_idx' '$canon_idx'"
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        local added
        added=$(grep -vxF -f "$canon_idx" "$ws_idx" | grep -c '.' || true)
        echo "[dry-run] MEMORY.md: would append $added workspace-only line(s)."
        return 0
    fi
    local tmp
    tmp="$(mktemp)"
    cat "$canon_idx" >"$tmp"
    # Append workspace lines not already present verbatim in canonical.
    grep -vxF -f "$canon_idx" "$ws_idx" >>"$tmp" || true
    mv "$tmp" "$canon_idx"
    log "  MEMORY.md unioned."
}

# Replace <ws_dir>/memory with a relative symlink to the canonical memory/.
# Relative so it stays valid regardless of where the config repo is cloned.
make_symlink() {
    local canon="$1" ws="$2" ws_dir="$3" ws_mem="$4"
    # Relative path from ws_dir up to projects/, then into canonical.
    local rel="../$canon/memory"
    if [ -e "$ws_mem" ] || [ -L "$ws_mem" ]; then
        run "rm -rf '$ws_mem'"
    fi
    run "ln -s '$rel' '$ws_mem'"
    log "symlinked: $ws/memory → $rel"
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
if [ "${#POSITIONAL[@]}" -eq 2 ]; then
    link_pair "${POSITIONAL[0]}" "${POSITIONAL[1]}"
elif [ "${#POSITIONAL[@]}" -eq 0 ]; then
    # Auto-discover every "-workspace-" twin that has a de-workspaced counterpart.
    found=0
    while IFS= read -r ws; do
        canon="${ws/-workspace-/-}"
        [ "$canon" = "$ws" ] && continue
        if [ -d "$PROJECTS_DIR/$canon" ]; then
            found=1
            link_pair "$canon" "$ws"
        fi
    done < <(cd "$PROJECTS_DIR" && find . -maxdepth 1 -type d -name '*-workspace-*' -printf '%f\n' | sort)
    [ "$found" -eq 0 ] && log "No '-workspace-' project pairs found."
else
    echo "Usage: $0 [--dry-run] [--config <name>] [<canonical-pathkey> <workspace-pathkey>]" >&2
    exit 1
fi

log "Done.${DRY_RUN:+}"
[ "$DRY_RUN" -eq 1 ] && log "(dry run — nothing changed)"
log "Review, then run: claude-sync"
