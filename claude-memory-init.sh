#!/usr/bin/env bash
# claude-memory-init.sh — Give a repo a machine-independent Claude memory store.
#
# Problem: Claude keys per-project memory by the project's ABSOLUTE path
# (~/.claude/projects/-home-you-git-foo/memory/). The same repo checked out at a
# different path — or under a slightly different directory name — on another
# machine gets a SEPARATE memory dir, so memory forks per machine. Path-based
# pairing (see link-memory.sh) can't help when the directory names differ
# (…-git-atb-M590-App vs …-workspace-git-atb-App-M590).
#
# Fix: derive a STABLE name for the repo (its sanitized full git remote URL), keep the real
# memory under  <config>/shared_memory/<name>/memory/  (name-keyed, git-tracked,
# synced), and replace this machine's path-keyed  memory/  dir with a relative
# symlink into it. Every machine that runs this in its checkout ends up pointing
# its own path-key at the same shared store — regardless of where or under what
# name the repo lives locally. New machines: clone config, checkout repo, run
# this once.
#
# Usage (run from inside a repo checkout, or pass --repo):
#   claude-memory-init.sh [--name <name>] [--repo <path>] [--config <name>] [--dry-run]
#
#   --name <name>    Override the derived store name (use to disambiguate two
#                    repos that share a remote basename).
#   --repo <path>    Target repo checkout (default: current directory's repo).
#   --config <name>  Config under ~/git/claude-settings/config/ (default: active).
#   --dry-run        Print actions, change nothing.
#
# Notes:
#   * Only the repo's memory/ dir is touched. Session .jsonl transcripts stay.
#   * If the path-keyed memory/ already has content, it is MERGED into the shared
#     store (never overwrites a divergent same-name file; MEMORY.md is unioned).
#   * Idempotent: re-running when already linked is a no-op.
#   * Does NOT commit or push. Run `claude-sync` afterwards.

set -euo pipefail

SETTINGS_ROOT="${CLAUDE_SETTINGS_ROOT:-$HOME/git/claude-settings}"
CONFIG_DIR="$SETTINGS_ROOT/config"
CURRENT_LINK="$CONFIG_DIR/current"
CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

DRY_RUN=0
NAME_OVERRIDE=""
REPO_ARG=""
CONFIG_NAME=""

log()  { echo "[claude-memory-init] $*"; }
warn() { echo "[claude-memory-init] WARNING: $*" >&2; }
die()  { echo "[claude-memory-init] ERROR: $*" >&2; exit 1; }
run()  { if [ "$DRY_RUN" -eq 1 ]; then echo "[dry-run] $*"; else eval "$*"; fi; }

while [ $# -gt 0 ]; do
    case "$1" in
        --name)    NAME_OVERRIDE="${2:-}"; shift ;;
        --repo)    REPO_ARG="${2:-}"; shift ;;
        --config)  CONFIG_NAME="${2:-}"; shift ;;
        --dry-run) DRY_RUN=1 ;;
        -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
        -*)        die "Unknown option: $1" ;;
        *)         die "Unexpected argument: $1" ;;
    esac
    shift
done

# ── Resolve the repo checkout and its git toplevel ────────────────────────────
REPO_DIR="${REPO_ARG:-$PWD}"
[ -d "$REPO_DIR" ] || die "repo path not found: $REPO_DIR"
TOPLEVEL="$(git -C "$REPO_DIR" rev-parse --show-toplevel 2>/dev/null)" \
    || die "not inside a git repo: $REPO_DIR"

# ── Derive the stable store name ──────────────────────────────────────────────
# Priority: --name > sanitized full git remote URL > local dir name (unstable).
# The FULL remote URL (host + path) is used, not just the basename, so two repos
# that share a basename across different hosts/orgs still get distinct names.
#   git@gitlab.netrtl.com:jupyter/jupyter-dashboard.git
#     → gitlab.netrtl.com-jupyter-jupyter-dashboard
#   git@rl3.rl3.de:robe-mandanten
#     → rl3.rl3.de-robe-mandanten
derive_name() {
    if [ -n "$NAME_OVERRIDE" ]; then
        echo "$NAME_OVERRIDE"; return
    fi
    local url
    url="$(git -C "$TOPLEVEL" remote get-url origin 2>/dev/null || true)"
    if [ -n "$url" ]; then
        # Normalize: drop protocol prefix and any user@, turn scp-form host:path
        # into host/path, strip trailing .git, then map separators to '-'.
        url="${url%/}"
        url="${url%.git}"
        url="${url#ssh://}"; url="${url#git+ssh://}"
        url="${url#https://}"; url="${url#http://}"; url="${url#git://}"
        url="${url#*@}"                    # drop user@ (e.g. git@)
        url="$(echo "$url" | tr ':/@' '---' | tr -s '-')"
        url="${url#-}"; url="${url%-}"     # trim leading/trailing '-'
        if [ -n "$url" ]; then echo "$url"; return; fi
    fi
    warn "no usable git remote for $TOPLEVEL — falling back to directory name (not stable across differing checkouts). Consider --name."
    basename "$TOPLEVEL"
}
NAME="$(derive_name)"
# Sanitize: allow only safe filename chars.
case "$NAME" in
    ""|*/*|.|..) die "derived store name is unsafe: '$NAME' — pass --name explicitly." ;;
esac
log "store name: $NAME"

# ── Resolve config projects/ and shared_memory/ roots ─────────────────────────
resolve_base() {
    if [ -n "$CONFIG_NAME" ]; then
        echo "$CONFIG_DIR/$CONFIG_NAME"
    elif [ -L "$CURRENT_LINK" ]; then
        readlink -f "$CURRENT_LINK"
    else
        die "no active config and no --config given."
    fi
}
CONFIG_BASE="$(resolve_base)"
[ -d "$CONFIG_BASE" ] || die "config base not found: $CONFIG_BASE"

SHARED_MEM="$CONFIG_BASE/shared_memory/$NAME/memory"

# ── Compute this machine's path-key for the repo ──────────────────────────────
# Claude uses the absolute project path with every '/' replaced by '-'.
PATHKEY="$(echo "$TOPLEVEL" | sed 's:/:-:g')"
PROJ_DIR="$CLAUDE_HOME/projects/$PATHKEY"
PROJ_MEM="$PROJ_DIR/memory"
log "path-key: $PATHKEY"

# ── Already linked correctly? ─────────────────────────────────────────────────
if [ -L "$PROJ_MEM" ] && [ "$(readlink -f "$PROJ_MEM" 2>/dev/null)" = "$(readlink -f "$SHARED_MEM" 2>/dev/null)" ]; then
    log "already linked: $PATHKEY/memory → shared_memory/$NAME/memory (nothing to do)."
    exit 0
fi

run "mkdir -p '$SHARED_MEM'"
# Git can't track an empty dir; without a placeholder the shared store would not
# survive a clone and the symlink would dangle on other machines. Drop a
# .gitkeep so a freshly-created (still empty) store is committable.
if [ ! -e "$SHARED_MEM/.gitkeep" ]; then
    run "touch '$SHARED_MEM/.gitkeep'"
fi

# ── Merge any existing path-keyed memory into the shared store ─────────────────
if [ -d "$PROJ_MEM" ] && [ ! -L "$PROJ_MEM" ]; then
    log "merging existing $PATHKEY/memory → shared_memory/$NAME/memory"
    while IFS= read -r f; do
        base="$(basename "$f")"
        [ "$base" = "MEMORY.md" ] && continue
        dest="$SHARED_MEM/$base"
        if [ -e "$dest" ]; then
            diff -q "$f" "$dest" >/dev/null 2>&1 || warn "CONFLICT (kept shared, review): $base"
        else
            run "cp -p '$f' '$dest'"
            log "  + $base"
        fi
    done < <(find "$PROJ_MEM" -maxdepth 1 -type f -name '*.md')

    # Union MEMORY.md.
    if [ -f "$PROJ_MEM/MEMORY.md" ]; then
        if [ ! -f "$SHARED_MEM/MEMORY.md" ]; then
            run "cp -p '$PROJ_MEM/MEMORY.md' '$SHARED_MEM/MEMORY.md'"
        elif [ "$DRY_RUN" -eq 1 ]; then
            echo "[dry-run] MEMORY.md: would union missing lines."
        else
            tmp="$(mktemp)"
            cat "$SHARED_MEM/MEMORY.md" >"$tmp"
            grep -vxF -f "$SHARED_MEM/MEMORY.md" "$PROJ_MEM/MEMORY.md" >>"$tmp" || true
            mv "$tmp" "$SHARED_MEM/MEMORY.md"
            log "  MEMORY.md unioned."
        fi
    fi
fi

# ── Replace path-keyed memory/ with a relative symlink into shared store ───────
# Relative target: from  projects/<pathkey>/memory  up to config base, then into
# shared_memory. Both live under the same config repo, so this is portable.
REL="$(realpath --relative-to="$PROJ_DIR" "$SHARED_MEM" 2>/dev/null || echo "")"
if [ -z "$REL" ]; then
    # Fallback for systems without realpath --relative-to: hand-build it.
    # projects/<pathkey>/  → ../../shared_memory/<name>/memory
    REL="../../shared_memory/$NAME/memory"
fi

run "mkdir -p '$PROJ_DIR'"
if [ -e "$PROJ_MEM" ] || [ -L "$PROJ_MEM" ]; then
    run "rm -rf '$PROJ_MEM'"
fi
run "ln -s '$REL' '$PROJ_MEM'"
log "symlinked: $PATHKEY/memory → $REL"

if [ "$DRY_RUN" -eq 1 ]; then
    log "Done (dry run — nothing changed)."
else
    log "Done."
    log "Review the shared store, then run: claude-sync"
fi
