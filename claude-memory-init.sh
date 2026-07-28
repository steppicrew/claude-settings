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
#   --repo <path>    Target directory to key memory for — a repo checkout or any
#                    subdirectory of one (default: current directory).
#   --config <name>  Config under ~/git/claude-settings/config/ (default: active).
#   --dry-run        Print actions, change nothing.
#
# Subdirectory scopes:
#   Claude keys memory by the CWD it was launched in, not by the repo root. So a
#   session started in  <repo>/backend/  gets its own path-key and its own memory.
#   To give such a scope a shared store, run this script from that subdirectory
#   (or pass --repo <repo>/backend). The store name gains a '--<subpath>' suffix:
#     <remote-name>--backend        for  <repo>/backend
#     <remote-name>--services-api   for  <repo>/services/api
#   The subpath is repo-RELATIVE, so it is identical on machines whose checkouts
#   live at different absolute paths. Run once per machine PER SUBDIRECTORY you
#   actually open Claude in; a repo root and its subdirs are separate stores and
#   do not share memory with each other.
#
# Notes:
#   * Only the target dir's memory/ dir is touched. Session .jsonl transcripts stay.
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

# Write a MERGE-REQUEST.md into the shared store and print a paste-ready prompt,
# asking Claude Code to semantically reconcile freshly-merged memory. Placed
# inside memory/ so the next Claude session in this repo loads it automatically.
emit_merge_request() {
    local req="$SHARED_MEM/MERGE-REQUEST.md"
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[dry-run] would write merge-review request: $req"
    else
        {
            echo "# Memory merge review needed"
            echo
            echo "\`claude-memory-init.sh\` merged this machine's memory for **$NAME**"
            echo "(path-key \`$PATHKEY\`) into the shared store on $(date '+%Y-%m-%d %H:%M')."
            echo "The union was mechanical — it never overwrites — so nothing was lost, but it"
            echo "cannot judge meaning. Please reconcile:"
            echo
            echo "- **Contradictions** — two memories that disagree; keep the current one, delete the stale."
            echo "- **Duplicates** — the same fact under different filenames/wordings; merge into one."
            echo "- **Divergent same-name files** (listed below) — the shared copy was kept; the"
            echo "  incoming version is preserved next to it as \`<file>.incoming\`. Diff the two,"
            echo "  keep whichever is correct (or merge them), then remove the \`.incoming\`."
            echo
            if [ "${#CONFLICTS[@]}" -gt 0 ]; then
                echo "## Divergent same-name files (shared kept; incoming saved as .incoming)"
                echo
                local c
                for c in "${CONFLICTS[@]}"; do echo "- \`$c\` vs \`$c.incoming\`"; done
                echo
            fi
            echo "## When done"
            echo
            echo "Prune/merge the fact files, resolve any \`.incoming\` pairs, update \`MEMORY.md\`"
            echo "to match, then **delete this file** (\`MERGE-REQUEST.md\`) and run \`claude-sync\`."
            if [ "$SUBPATH" != "." ]; then
                echo
                echo "> Note: this store is scoped to the subdirectory \`$SUBPATH\` of the repo, not"
                echo "> to the whole repo. Memory here should be about that scope."
            fi
        } >"$req"
        log "wrote merge-review request: shared_memory/$NAME/memory/MERGE-REQUEST.md"
    fi
    echo ""
    echo "  ⚠ Memory merge review needed for '$NAME'."
    echo "    Open this repo in Claude Code and say:"
    echo "      \"resolve the pending memory merge\""
    echo ""
}

# ── Resolve the target dir, its git toplevel, and the repo-relative subpath ───
# TARGET_DIR is what Claude keys memory by (its launch CWD) — it may be the repo
# root or any subdirectory of it. TOPLEVEL is only used to look up the remote and
# to compute SUBPATH; the two are deliberately NOT the same thing.
REPO_DIR="${REPO_ARG:-$PWD}"
[ -d "$REPO_DIR" ] || die "path not found: $REPO_DIR"

# Everything below is PHYSICAL (symlinks resolved). Claude derives its project
# key from the REAL path, not the shell's logical $PWD: on a machine where
# ~/git symlinks to ~/workspace/git, a session launched via ~/git/foo is keyed
# -home-user-workspace-git-foo. Keying off the logical path here would create a
# symlink at a path Claude never reads, leaving the real memory unlinked and
# forking — the exact failure this script exists to prevent.
TARGET_DIR="$(cd -P "$REPO_DIR" 2>/dev/null && pwd -P)" \
    || die "cannot enter path: $REPO_DIR"
TOPLEVEL="$(git -C "$TARGET_DIR" rev-parse --show-toplevel 2>/dev/null)" \
    || die "not inside a git repo: $TARGET_DIR"
TOPLEVEL="$(cd -P "$TOPLEVEL" && pwd -P)"

# Repo-relative subpath: '.' at the repo root, else e.g. 'services/api'. Both
# sides are physical, so containment is exact and the subpath matches what
# Claude's own key encodes.
if [ "$TARGET_DIR" = "$TOPLEVEL" ]; then
    SUBPATH="."
else
    SUBPATH="${TARGET_DIR#"$TOPLEVEL"/}"
    # A no-op strip means the dir is not under TOPLEVEL — bail rather than
    # silently building a store name from an absolute path.
    [ "$SUBPATH" != "$TARGET_DIR" ] || die "target dir is not inside its git toplevel: $TARGET_DIR"
fi
[ "$SUBPATH" = "." ] || log "subpath: $SUBPATH"

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

# Append the repo-relative subpath so each subdirectory scope gets its own store.
# IMPORTANT: this runs AFTER derive_name's  tr -s '-'  squeeze, which is what lets
# the '--' separator survive. If these are ever reordered, '--' collapses to '-'
# and a subdir store can collide with a repo whose remote path ends in that same
# segment. --name is a full override and is deliberately left unsuffixed.
if [ -z "$NAME_OVERRIDE" ] && [ "$SUBPATH" != "." ]; then
    NAME="$NAME--$(echo "$SUBPATH" | tr '/' '-')"
fi

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

# ── Compute this machine's path-key for the target dir ────────────────────────
# Claude uses the REAL (symlink-resolved) absolute path of its launch CWD, with
# separator characters replaced by '-'. TARGET_DIR is already physical (above).
#
# The set of folded characters is derived from OBSERVED Claude-authored keys
# (dirs holding .jsonl transcripts — dirs holding only a memory/ symlink were
# created by THIS script and prove nothing):
#   '/' → '-'   universally observed
#   '.' → '-'   observed: ~/…/AdventOfCode/2025.haskell is keyed
#               …-AdventOfCode-2025-haskell , NOT …-2025.haskell
#   '_' → '_'   NOT folded, kept verbatim: on stepmobil the key
#               …-atb-WaterPro_CropDiv is the live one, while the dashed
#               variant …-WaterPro-CropDiv existed only as an empty dir (no
#               transcripts) and was removed. Do not add '_' here.
# Keep the folded set in this ONE variable so it stays a one-character edit.
# This MUST key off TARGET_DIR, not TOPLEVEL: a session started in a subdirectory
# gets that subdirectory's path-key, so keying off the repo root here would link
# the wrong dir and leave the subdir's real memory unlinked and forking.
PATHKEY_FOLD='./'
PATHKEY="$(echo "$TARGET_DIR" | tr "$PATHKEY_FOLD" '--')"
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
# The mechanical merge below is SAFE but DUMB: it unions files and never
# overwrites, but it cannot judge semantic conflicts — stale facts, contradictions,
# or the same fact reworded under a different filename. Whenever the merge is
# non-trivial (a divergent same-name file, or BOTH sides already held memory) we
# still do the safe union, then emit a MERGE-REQUEST.md asking Claude Code to
# reconcile. That file lands inside the shared memory/ dir, so the next Claude
# session in this repo loads it and can act on it. (Hybrid: auto for the clean
# path, human/Claude judgment only where it's actually needed.)
CONFLICTS=()          # same-name files whose content diverged
SHARED_HAD_MEMORY=0   # shared store already held fact files before this run
MERGED_ANY=0          # this run copied at least one file in

if [ -d "$PROJ_MEM" ] && [ ! -L "$PROJ_MEM" ]; then
    # Did the shared store already contain fact files (i.e. another machine
    # populated it earlier)? If so, two independently-grown memory sets are
    # coming together — worth a semantic review even with zero same-name clashes.
    if find "$SHARED_MEM" -maxdepth 1 -type f -name '*.md' ! -name 'MEMORY.md' \
            -print -quit 2>/dev/null | grep -q .; then
        SHARED_HAD_MEMORY=1
    fi

    log "merging existing $PATHKEY/memory → shared_memory/$NAME/memory"
    while IFS= read -r f; do
        base="$(basename "$f")"
        [ "$base" = "MEMORY.md" ] && continue
        dest="$SHARED_MEM/$base"
        if [ -e "$dest" ]; then
            if ! diff -q "$f" "$dest" >/dev/null 2>&1; then
                warn "CONFLICT (kept shared, review): $base"
                CONFLICTS+=("$base")
                # Preserve the dropped incoming copy alongside so the review can
                # actually compare — otherwise it vanishes when the path-keyed
                # dir is replaced by the symlink below.
                run "cp -p '$f' '$dest.incoming'"
            fi
        else
            run "cp -p '$f' '$dest'"
            log "  + $base"
            MERGED_ANY=1
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

    # Decide whether a semantic review is warranted, and emit the request.
    if [ "${#CONFLICTS[@]}" -gt 0 ] || { [ "$SHARED_HAD_MEMORY" -eq 1 ] && [ "$MERGED_ANY" -eq 1 ]; }; then
        emit_merge_request
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
