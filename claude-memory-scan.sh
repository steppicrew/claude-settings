#!/usr/bin/env bash
# claude-memory-scan.sh — Find Claude memory scopes that are not yet shared.
#
# claude-memory-init.sh shares ONE scope, and only if you remember to run it in
# that directory. Scopes therefore accumulate unshared: you work in a repo, Claude
# writes memory under its path-key, and that memory silently stays machine-local
# and forks. This script sweeps ~/.claude/projects/ and reports every scope whose
# memory/ is still a real directory rather than a symlink into the shared store.
#
# It classifies rather than guesses, because most leftovers are NOT shareable
# automatically:
#
#   linkable    memory/ is a real dir, the path exists on THIS machine, and it is
#               inside a git repo → claude-memory-init.sh can share it as-is.
#   non-repo    the path exists but is not in a git repo (e.g. a container dir
#               like ~/git/rtl holding sibling repos). There is no remote to
#               derive a stable name from, and the local path differs per machine,
#               so no name can be derived that reproduces elsewhere. Reported with
#               a ready-to-paste --name command; you choose the name and must use
#               the SAME name on every machine.
#   foreign     the path does not exist here. These are another machine's scopes that
#               arrived through config sync (e.g. ~/workspace/git/* on a ~/git
#               machine). Not actionable here — the owning machine shares them.
#               Skipped quietly and only counted, so sync output stays clean.
#
# Usage:
#   claude-memory-scan.sh [--link] [--config <name>] [--dry-run] [--quiet]
#
#   --link           Actually share the 'linkable' scopes by invoking
#                    claude-memory-init.sh for each. Without it, report only.
#   --ask            Report, then ask whether to link (sync.sh uses this).
#                    Requires a terminal; with no TTY it degrades to report-only
#                    so an unattended sync can never block on a prompt.
#   --config <name>  Config under <settings>/config/ (default: active).
#   --dry-run        Print what --link would do, change nothing.
#   --quiet          Report only what is actionable RIGHT NOW (used by sync):
#                    suppresses the 'non-repo' block and the all-clear line. Those
#                    need a name only you can pick, so on an every-sync run they
#                    are unfixable noise; a bare scan still lists them in full.
#
# Report-only by default ON PURPOSE: linking merges memory and can emit a
# MERGE-REQUEST.md needing human/Claude judgment. sync.sh runs this with --ask,
# so linking during a sync is always a deliberate answer, never a side effect.
#
# Does NOT commit or push. Run `claude-sync` afterwards.

set -euo pipefail

SETTINGS_ROOT="${CLAUDE_SETTINGS_ROOT:-$HOME/git/claude-settings}"
CONFIG_DIR="$SETTINGS_ROOT/config"
CURRENT_LINK="$CONFIG_DIR/current"
CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
INIT_SCRIPT="$SETTINGS_ROOT/claude-memory-init.sh"

DO_LINK=0
ASK=0
DRY_RUN=0
QUIET=0
CONFIG_NAME=""

log()  { echo "[claude-memory-scan] $*"; }
warn() { echo "[claude-memory-scan] WARNING: $*" >&2; }
die()  { echo "[claude-memory-scan] ERROR: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --link)    DO_LINK=1 ;;
        --ask)     ASK=1 ;;
        --config)  CONFIG_NAME="${2:-}"; shift ;;
        --dry-run) DRY_RUN=1 ;;
        --quiet)   QUIET=1 ;;
        -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
        -*)        die "Unknown option: $1" ;;
        *)         die "Unexpected argument: $1" ;;
    esac
    shift
done

PROJECTS_DIR="$CLAUDE_HOME/projects"
[ -d "$PROJECTS_DIR" ] || { [ "$QUIET" -eq 1 ] && exit 0; die "no projects dir: $PROJECTS_DIR"; }

# ── Reverse a path-key back to a filesystem path ──────────────────────────────
# Claude's key folds BOTH '/' and '.' to '-' (see claude-memory-init.sh), so the
# mapping is lossy and NOT uniquely invertible: '-home-stephan-git-atb-M590-App'
# could be .../atb/M590-App or .../atb-M590/App or .../atb/M590/App. Worse, a
# single directory name may span several key segments ('claude-settings' is two),
# so a left-to-right greedy walk that commits to one segment at a time cannot
# resolve it — after '/home/stephan/git' the segment 'claude' matches nothing,
# yet 'claude-settings' is correct.
#
# So: recursive search with backtracking. At each level try progressively longer
# runs of segments as ONE directory name, joined by '-' or '.', and recurse on
# whatever exists. The filesystem decides every split, so a wrong guess is
# rejected rather than silently yielding a bogus path.
#
# LONGEST match is preferred (the loop counts down): given both 'atb' and
# 'atb-M590', the longer name is tried first, which resolves the common case of
# a repo whose own name contains dashes.
#
# Returns the resolved path on stdout, or empty if no path on this machine
# matches the key (the 'foreign' case).
_resolve_walk() {
    local base="$1"; shift
    local -a segs=("$@")
    local n="${#segs[@]}"

    # All segments consumed → this is a complete, existing path.
    if [ "$n" -eq 0 ]; then
        echo "$base"
        return 0
    fi

    local take joined rest_start cand
    for ((take = n; take >= 1; take--)); do
        # Join the first `take` segments with '-' …
        joined="$(IFS=-; echo "${segs[*]:0:take}")"
        rest_start="$take"
        for cand in "$base/$joined" "$base/${joined//-/.}"; do
            if [ -d "$cand" ]; then
                if _resolve_walk "$cand" "${segs[@]:rest_start}"; then
                    return 0
                fi
            fi
        done
    done
    return 1
}

resolve_pathkey() {
    local key="$1"
    key="${key#-}"                       # keys start with '-' (leading '/')
    [ -n "$key" ] || return 0

    local IFS='-'
    local -a segs
    read -r -a segs <<<"$key"

    _resolve_walk "" "${segs[@]}" 2>/dev/null || true
}

# ── Resolve the active config, to detect already-shared stores ────────────────
resolve_base() {
    if [ -n "$CONFIG_NAME" ]; then
        echo "$CONFIG_DIR/$CONFIG_NAME"
    elif [ -L "$CURRENT_LINK" ]; then
        readlink -f "$CURRENT_LINK"
    else
        return 1
    fi
}
CONFIG_BASE="$(resolve_base || true)"
if [ -z "$CONFIG_BASE" ] || [ ! -d "$CONFIG_BASE" ]; then
    [ "$QUIET" -eq 1 ] && exit 0
    die "no active config (and no --config given)."
fi

# ── Classify every scope ──────────────────────────────────────────────────────
LINKABLE=()        # "pathkey<TAB>path"
NONREPO=()         # "pathkey<TAB>path"
FOREIGN=0
ALREADY=0

for dir in "$PROJECTS_DIR"/*/; do
    [ -d "$dir" ] || continue
    key="$(basename "$dir")"
    mem="$dir/memory"

    # Already a symlink → shared. Nothing to do (dangling links are a separate
    # concern and deliberately not "fixed" here).
    if [ -L "${mem%/}" ]; then
        ALREADY=$((ALREADY + 1))
        continue
    fi
    # No memory dir at all, or an empty one → nothing worth sharing.
    [ -d "$mem" ] || continue
    if ! ls -1 "$mem"/*.md >/dev/null 2>&1; then
        continue
    fi

    path="$(resolve_pathkey "$key")"
    if [ -z "$path" ]; then
        FOREIGN=$((FOREIGN + 1))
        continue
    fi

    if git -C "$path" rev-parse --show-toplevel >/dev/null 2>&1; then
        LINKABLE+=("$key	$path")
    else
        NONREPO+=("$key	$path")
    fi
done

# ── Report ────────────────────────────────────────────────────────────────────
n_link="${#LINKABLE[@]}"
n_nonrepo="${#NONREPO[@]}"

# Under --quiet only the actionable set counts as "something to report". The
# non-repo scopes cannot be fixed without a name from the user, so surfacing them
# on every single sync would train the reader to ignore the whole block.
if [ "$QUIET" -eq 1 ]; then
    [ "$n_link" -eq 0 ] && exit 0
elif [ "$n_link" -eq 0 ] && [ "$n_nonrepo" -eq 0 ]; then
    log "all memory scopes shared ($ALREADY linked, $FOREIGN skipped: path not on this machine)."
    exit 0
fi

echo ""
log "unshared memory scopes found:"

if [ "$n_link" -gt 0 ]; then
    echo ""
    echo "  Shareable now ($n_link):"
    for entry in "${LINKABLE[@]}"; do
        path="${entry#*	}"
        n=$(ls -1 "$PROJECTS_DIR/${entry%%	*}/memory"/*.md 2>/dev/null | wc -l)
        printf '    %-52s (%s memory files)\n' "$path" "$n"
    done
    if [ "$DO_LINK" -eq 0 ] && [ "$ASK" -eq 0 ]; then
        echo ""
        echo "    → share them:  claude-memory-scan.sh --link"
    fi
fi

if [ "$n_nonrepo" -gt 0 ] && [ "$QUIET" -eq 0 ]; then
    echo ""
    echo "  Not a git repo — needs an explicit, machine-independent name ($n_nonrepo):"
    for entry in "${NONREPO[@]}"; do
        path="${entry#*	}"
        n=$(ls -1 "$PROJECTS_DIR/${entry%%	*}/memory"/*.md 2>/dev/null | wc -l)
        printf '    %s (%s memory files)\n' "$path" "$n"
        printf '      claude-memory-init.sh --repo %s --name <name>\n' "$path"
    done
    echo ""
    echo "    Pick a name yourself and use the SAME name on every machine — these"
    echo "    paths differ per machine, so no name can be derived automatically."
fi

echo ""
log "summary: $n_link shareable, $n_nonrepo need --name, $FOREIGN skipped (path not on this machine), $ALREADY already shared."

# ── Ask whether to link (sync.sh path) ────────────────────────────────────────
# Only the 'shareable' set is ever offered — the non-repo ones need a name only
# the user can choose. Requires a real terminal: a sync from cron or a pipe must
# fall through to report-only rather than hang waiting on stdin. Read from
# /dev/tty, not stdin, so this still works when the caller pipes our output.
if [ "$ASK" -eq 1 ] && [ "$DO_LINK" -eq 0 ] && [ "$n_link" -gt 0 ]; then
    if [ -t 0 ] || [ -e /dev/tty ]; then
        echo ""
        reply=""
        if ! read -r -p "  Share the $n_link shareable scope(s) now? [y/N] " reply </dev/tty 2>/dev/null; then
            reply=""
        fi
        case "$reply" in
            [yY]|[yY][eE][sS]) DO_LINK=1 ;;
            *) log "skipped. Share later with: claude-memory-scan.sh --link" ;;
        esac
    else
        echo ""
        echo "    → share them:  claude-memory-scan.sh --link"
    fi
fi

# ── Optionally link the clean cases ───────────────────────────────────────────
if [ "$DO_LINK" -eq 1 ] && [ "$n_link" -gt 0 ]; then
    [ -x "$INIT_SCRIPT" ] || die "cannot run linker, not executable: $INIT_SCRIPT"
    echo ""
    for entry in "${LINKABLE[@]}"; do
        path="${entry#*	}"
        log "linking: $path"
        args=(--repo "$path")
        [ -n "$CONFIG_NAME" ] && args+=(--config "$CONFIG_NAME")
        [ "$DRY_RUN" -eq 1 ] && args+=(--dry-run)
        # Keep sweeping if one scope fails; a single bad repo must not strand
        # the rest, and the failure is reported rather than swallowed.
        "$INIT_SCRIPT" "${args[@]}" 2>&1 | sed 's/^/  /' \
            || warn "failed to link $path (continuing)"
    done
    echo ""
    if [ "$DRY_RUN" -eq 1 ]; then
        log "Done (dry run — nothing changed)."
    else
        log "Done. Review the shared stores, then run: claude-sync"
    fi
fi
