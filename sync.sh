#!/usr/bin/env bash
# Sync claude-settings private config to/from GitHub.
# Usage: ./sync.sh [push|pull|sync|add-config|switch-config|list-configs] [-v]
#
#   push                      — commit local changes and push (active config)
#   pull                      — fetch and merge remote, restore plugins
#   sync                      — pull first, then push (default)
#   add-config <name> <url>   — clone a private config repo into config/<name>
#   switch-config <name>      — switch active config to config/<name>
#   list-configs              — list available configs, show active
#   -v                        — verbose output

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="$SCRIPT_DIR/config"
CURRENT_LINK="$CONFIG_DIR/current"

VERBOSE=0
PULLED=0

log()     { echo "[claude-sync] $*"; }
verbose() { [ "$VERBOSE" -eq 1 ] && echo "[claude-sync] $*" || true; }
warn()    { echo "[claude-sync] WARNING: $*" >&2; }

active_config_dir() {
    if [ ! -L "$CURRENT_LINK" ]; then
        echo "No active config. Run: $0 add-config <name> <url>" >&2
        exit 1
    fi
    readlink -f "$CURRENT_LINK"
}

# known_marketplaces.json churns on every plugin refresh: lastUpdated is
# rewritten each time and installLocation is an absolute path under $HOME, so
# it differs per machine. Left alone, both make every sync a diff and turn
# cosmetic bookkeeping into a merge conflict between machines.
#
# Both fields are REQUIRED by Claude Code's schema — deleting them corrupts the
# marketplace config ("Invalid input: expected string, received undefined") and
# breaks `claude plugins marketplace list`. So normalize the values instead of
# removing the keys: pin the timestamp and replace $HOME with a placeholder that
# denormalize_volatile() expands back on the way out.
MARKETPLACE_EPOCH="1970-01-01T00:00:00.000Z"

normalize_volatile() {
    local repo_dir="$1"
    command -v jq &>/dev/null || return 0

    local f="$repo_dir/plugins/known_marketplaces.json"
    [ -f "$f" ] || return 0

    local tmp
    tmp="$(mktemp)" || return 0
    if jq -S --arg home "$HOME" --arg epoch "$MARKETPLACE_EPOCH" '
            walk(
                if type == "object" then
                    (if has("lastUpdated") then .lastUpdated = $epoch else . end)
                    | (if has("installLocation")
                       then .installLocation |= sub("^" + $home; "$HOME")
                       else . end)
                else . end
            )' "$f" >"$tmp" 2>/dev/null \
       && [ -s "$tmp" ]; then
        if ! cmp -s "$f" "$tmp"; then
            cat "$tmp" >"$f"
            verbose "Normalized volatile fields in known_marketplaces.json."
        fi
    fi
    rm -f "$tmp"
}

# Expand the placeholder back to a real path so Claude Code sees a valid file.
denormalize_volatile() {
    local repo_dir="$1"
    command -v jq &>/dev/null || return 0

    local f="$repo_dir/plugins/known_marketplaces.json"
    [ -f "$f" ] || return 0

    local tmp
    tmp="$(mktemp)" || return 0
    if jq -S --arg home "$HOME" '
            walk(
                if type == "object" and has("installLocation")
                then .installLocation |= sub("^\\$HOME"; $home)
                else . end
            )' "$f" >"$tmp" 2>/dev/null \
       && [ -s "$tmp" ]; then
        if ! cmp -s "$f" "$tmp"; then
            cat "$tmp" >"$f"
            verbose "Expanded \$HOME in known_marketplaces.json."
        fi
    fi
    rm -f "$tmp"
}

commit_local_changes() {
    local repo_dir="$1"
    normalize_volatile "$repo_dir"
    git -C "$repo_dir" add -A
    if git -C "$repo_dir" diff --cached --quiet; then
        verbose "No local changes to commit."
    else
        local msg="chore: sync claude settings on $(hostname) at $(date '+%Y-%m-%d %H:%M')"
        git -C "$repo_dir" commit -m "$msg"
        log "Committed local changes."
    fi
}

pull_remote() {
    local repo_dir="$1"
    verbose "Fetching remote..."
    git -C "$repo_dir" fetch origin

    if git -C "$repo_dir" diff --quiet HEAD origin/main; then
        verbose "Already up to date."
        PULLED=0
        return
    fi

    log "Merging remote changes (local wins on conflict)..."
    if git -C "$repo_dir" merge --no-edit origin/main 2>/dev/null; then
        verbose "Merge succeeded cleanly."
        PULLED=1
        return
    fi

    # Merge had conflicts — resolve by keeping local version of each conflicted file
    local conflicted
    conflicted=$(git -C "$repo_dir" diff --name-only --diff-filter=U)
    if [ -n "$conflicted" ]; then
        warn "Conflicts in: $(echo "$conflicted" | tr '\n' ' ')"
        warn "Keeping local versions."
        echo "$conflicted" | xargs git -C "$repo_dir" checkout --ours --
        echo "$conflicted" | xargs git -C "$repo_dir" add
        git -C "$repo_dir" commit --no-edit -m "chore: merge remote settings (kept local on conflicts)"
        log "Conflict resolution committed."
    fi
    PULLED=1
}

push_remote() {
    local repo_dir="$1"
    verbose "Pushing to origin..."
    git -C "$repo_dir" push origin main 2>&1 | grep -E '^To |^ ' || true
    verbose "Push complete."
}

restore_plugins() {
    local repo_dir="$1"
    [ "$PULLED" -eq 0 ] && return

    # The committed file carries a $HOME placeholder; expand it before Claude
    # Code (or the checks below) reads it.
    denormalize_volatile "$repo_dir"

    if ! command -v jq &>/dev/null; then
        warn "jq not found — skipping plugin restore."
        return
    fi
    if ! command -v claude &>/dev/null; then
        warn "claude CLI not found — skipping plugin restore."
        return
    fi

    local manifests_dir="$repo_dir/plugins"

    # Add missing marketplaces
    if [ -f "$manifests_dir/known_marketplaces.json" ]; then
        local registered
        registered=$(claude plugins marketplace list 2>/dev/null | grep -oP '(?<=❯ )\S+' || true)
        while IFS= read -r entry; do
            local name source_type repo
            name=$(echo "$entry" | jq -r '.name')
            source_type=$(echo "$entry" | jq -r '.source.source')
            if [ "$source_type" = "github" ]; then
                repo=$(echo "$entry" | jq -r '.source.repo')
                if echo "$registered" | grep -qxF "$name"; then
                    verbose "marketplace '$name' already registered."
                else
                    log "Adding marketplace '$name' ($repo)..."
                    claude plugins marketplace add "$repo" 2>&1 | sed 's/^/  /'
                fi
            else
                warn "unsupported marketplace source type '$source_type' for '$name' — skipping."
            fi
        done < <(jq -c 'to_entries[] | {name: .key, source: .value.source}' "$manifests_dir/known_marketplaces.json")
    fi

    # Install missing user-scoped plugins
    if [ -f "$manifests_dir/installed_plugins.json" ]; then
        local installed
        installed=$(claude plugins list --json 2>/dev/null | jq -r '.[].id' || true)
        while IFS= read -r plugin_key; do
            local is_user
            is_user=$(jq -r --arg k "$plugin_key" '.plugins[$k][] | select(.scope == "user") | .scope' \
                "$manifests_dir/installed_plugins.json" | head -1)
            if [ -n "$is_user" ]; then
                if echo "$installed" | grep -qxF "$plugin_key"; then
                    verbose "plugin '$plugin_key' already installed."
                else
                    log "Installing plugin '$plugin_key'..."
                    claude plugins install "$plugin_key" 2>&1 | sed 's/^/  /'
                fi
            fi
        done < <(jq -r '.plugins | keys[]' "$manifests_dir/installed_plugins.json")
    fi
}

# Sweep for memory scopes that are still machine-local and offer to share them.
# Runs with --ask: it reports, and only links if the user says yes at the prompt
# (falling back to report-only with no TTY), so a scripted sync never mutates
# memory or blocks. --quiet keeps a clean sync silent when there is nothing to do.
#
# Placed BEFORE commit_local_changes in each mode so any newly-created symlinks
# and shared stores land in the same commit as the rest of the sync.
scan_memory() {
    local scan="$SCRIPT_DIR/claude-memory-scan.sh"
    [ -x "$scan" ] || return 0
    "$scan" --ask --quiet || true
}

# Guard against the recurring "it worked here but not on the other machine" bug:
# a file this config actively uses that git is not tracking. The repo .gitignore
# is deny-by-default, so every new root-level script needs its own "!name" line;
# forgetting one is silent, and the breakage only shows up on the other machine
# (a hook pointing at a missing file, a skill that never loads).
#
# Two sources of truth, both mechanical:
#   - scripts named in settings.json hook/statusLine "command" strings
#   - every file under skills/
# Report-only and never fatal: this warns, it does not block a sync.
# Install the pre-commit hook into the active config repo.
#
# Git does NOT clone .git/hooks/, so a hook created on one machine simply does
# not exist on the other — the very failure this hook guards against. The hook
# body therefore lives as a tracked file in THIS repo (hooks/pre-commit.sh) and
# is copied into place on every sync, so both machines converge.
#
# Never clobbers a hook this script did not write: an existing pre-commit that
# lacks our marker line is left alone and reported.
install_pre_commit_hook() {
    local repo_dir="$1"
    local src="$SCRIPT_DIR/hooks/pre-commit.sh"
    local dest="$repo_dir/.git/hooks/pre-commit"
    local marker="CLAUDE_SYNC_SKIP_SCRIPT_CHECK"

    [ -f "$src" ] || return 0
    [ -d "$repo_dir/.git/hooks" ] || return 0

    if [ -f "$dest" ] && ! grep -q "$marker" "$dest" 2>/dev/null; then
        warn "existing pre-commit hook at $dest is not ours; leaving it untouched."
        return 0
    fi

    if ! cmp -s "$src" "$dest" 2>/dev/null; then
        cp "$src" "$dest" && chmod +x "$dest"
        verbose "Installed pre-commit hook into $(basename "$repo_dir")."
    fi
}

check_untracked_config() {
    local repo_dir="$1"
    local -a missing=()
    local f

    # Scripts referenced by settings.json, with $HOME/~ prefixes stripped so the
    # path is repo-relative. Needs python3 only for robust JSON walking; if it is
    # unavailable the skills check below still runs.
    if [ -f "$repo_dir/settings.json" ] && command -v python3 >/dev/null 2>&1; then
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            [ -e "$repo_dir/$f" ] || continue
            git -C "$repo_dir" ls-files --error-unmatch "$f" >/dev/null 2>&1 \
                || missing+=("$f  (referenced by settings.json)")
        done < <(python3 - "$repo_dir/settings.json" <<'PYEOF'
import json, re, sys
try:
    with open(sys.argv[1]) as fh:
        data = json.load(fh)
except Exception:
    sys.exit(0)

found = []
def walk(node):
    if isinstance(node, dict):
        for key, val in node.items():
            if key == "command" and isinstance(val, str):
                found.append(val)
            else:
                walk(val)
    elif isinstance(node, list):
        for item in node:
            walk(item)

walk(data)
for cmd in found:
    for tok in re.findall(r'[\w$~/.-]+\.(?:sh|mjs|js|py)', cmd):
        tok = tok.strip('"\'')
        tok = re.sub(r'^\$HOME/\.claude/|^~/\.claude/|^\$CLAUDE_[A-Z_]+/', '', tok)
        if not tok.startswith(('/', '$', '~')):
            print(tok)
PYEOF
        )
    fi

    # Every file under skills/ — helper scripts included, since a skill missing
    # its .mjs is as broken as one missing SKILL.md.
    if [ -d "$repo_dir/skills" ]; then
        while IFS= read -r f; do
            git -C "$repo_dir" ls-files --error-unmatch "$f" >/dev/null 2>&1 \
                || missing+=("$f")
        done < <(cd "$repo_dir" && find skills -type f -o -type l | sort)
    fi

    [ ${#missing[@]} -eq 0 ] && return 0

    warn "these files are used by your config but are NOT tracked by git;"
    warn "they will be missing on your other machines:"
    for f in "${missing[@]}"; do
        echo "    $f" >&2
    done
    warn "add a matching '!' rule to $repo_dir/.gitignore, then re-run."
    return 0
}

cmd_add_config() {
    local name="${1:-}" url="${2:-}"
    if [ -z "$name" ] || [ -z "$url" ]; then
        echo "Usage: $0 add-config <name> <url>" >&2
        exit 1
    fi
    local target="$CONFIG_DIR/$name"
    if [ -e "$target" ]; then
        echo "Config '$name' already exists at $target" >&2
        exit 1
    fi
    log "Cloning '$url' into config/$name..."
    git clone "$url" "$target"
    log "Cloned. Run '$0 switch-config $name' to activate."
}

cmd_switch_config() {
    local name="${1:-}"
    if [ -z "$name" ]; then
        echo "Usage: $0 switch-config <name>" >&2
        exit 1
    fi
    local target="$CONFIG_DIR/$name"
    if [ ! -d "$target" ]; then
        echo "Config '$name' not found. Available:" >&2
        cmd_list_configs
        exit 1
    fi
    ln -sfn "$name" "$CURRENT_LINK"
    log "Switched to config '$name'."
    log "~/.claude now points to: $(readlink -f "$CURRENT_LINK")"
}

cmd_list_configs() {
    local active=""
    if [ -L "$CURRENT_LINK" ]; then
        active=$(basename "$(readlink "$CURRENT_LINK")")
    fi
    echo "Available configs:"
    for d in "$CONFIG_DIR"/*/; do
        local name
        name=$(basename "$d")
        [ "$name" = "current" ] && continue
        if [ "$name" = "$active" ]; then
            echo "  * $name (active)"
        else
            echo "    $name"
        fi
    done
}

# Parse mode and flags
MODE="${1:-sync}"
shift || true

# For subcommands that take positional args, capture them before flag parsing
SUBCMD_ARGS=()
REMAINING=()
for arg in "$@"; do
    case "$arg" in
        -v|--verbose) VERBOSE=1 ;;
        -*) echo "Unknown option: $arg" >&2; exit 1 ;;
        *) SUBCMD_ARGS+=("$arg") ;;
    esac
done

case "$MODE" in
    add-config)
        cmd_add_config "${SUBCMD_ARGS[@]:-}"
        ;;
    switch-config)
        cmd_switch_config "${SUBCMD_ARGS[@]:-}"
        ;;
    list-configs)
        cmd_list_configs
        ;;
    push)
        REPO="$(active_config_dir)"
        install_pre_commit_hook "$REPO"
        scan_memory
        check_untracked_config "$REPO"
        commit_local_changes "$REPO"
        push_remote "$REPO"
        ;;
    pull)
        REPO="$(active_config_dir)"
        install_pre_commit_hook "$REPO"
        scan_memory
        check_untracked_config "$REPO"
        commit_local_changes "$REPO"
        pull_remote "$REPO"
        restore_plugins "$REPO"
        ;;
    sync)
        REPO="$(active_config_dir)"
        install_pre_commit_hook "$REPO"
        scan_memory
        check_untracked_config "$REPO"
        commit_local_changes "$REPO"
        pull_remote "$REPO"
        restore_plugins "$REPO"
        push_remote "$REPO"
        ;;
    *)
        echo "Usage: $0 [push|pull|sync|add-config <name> <url>|switch-config <name>|list-configs] [-v]" >&2
        exit 1
        ;;
esac
