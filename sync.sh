#!/usr/bin/env bash
# Sync claude-settings to/from GitHub.
# Usage: ./sync.sh [push|pull|sync] [-v]
#   push  — commit local changes and push
#   pull  — fetch and merge remote, preferring local on conflicts
#   sync  — pull first, then push (default)
#   -v    — verbose output

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO_DIR"

VERBOSE=0

log()     { echo "[claude-sync] $*"; }
verbose() { [ "$VERBOSE" -eq 1 ] && echo "[claude-sync] $*" || true; }
warn()    { echo "[claude-sync] WARNING: $*" >&2; }

commit_local_changes() {
    git add -A
    if git diff --cached --quiet; then
        verbose "No local changes to commit."
    else
        local msg="chore: sync claude settings on $(hostname) at $(date '+%Y-%m-%d %H:%M')"
        git commit -m "$msg"
        log "Committed local changes."
    fi
}

pull_remote() {
    verbose "Fetching remote..."
    git fetch origin

    if git diff --quiet HEAD origin/main; then
        verbose "Already up to date."
        return
    fi

    log "Merging remote changes (local wins on conflict)..."
    if git merge --no-edit origin/main 2>/dev/null; then
        verbose "Merge succeeded cleanly."
        return
    fi

    # Merge had conflicts — resolve by keeping local version of each conflicted file
    local conflicted
    conflicted=$(git diff --name-only --diff-filter=U)
    if [ -n "$conflicted" ]; then
        warn "Conflicts in: $(echo "$conflicted" | tr '\n' ' ')"
        warn "Keeping local versions."
        echo "$conflicted" | xargs git checkout --ours --
        echo "$conflicted" | xargs git add
        git commit --no-edit -m "chore: merge remote settings (kept local on conflicts)"
        log "Conflict resolution committed."
    fi
}

push_remote() {
    verbose "Pushing to origin..."
    git push origin main ${VERBOSE:+-v} 2>&1 | { [ "$VERBOSE" -eq 1 ] && cat || grep -E '^\[|^To |^ ' || true; }
    verbose "Push complete."
}

restore_plugins() {
    if ! command -v jq &>/dev/null; then
        warn "jq not found — skipping plugin restore."
        return
    fi
    if ! command -v claude &>/dev/null; then
        warn "claude CLI not found — skipping plugin restore."
        return
    fi

    local manifests_dir="$REPO_DIR/plugins"

    # Add missing marketplaces
    if [ -f "$manifests_dir/known_marketplaces.json" ]; then
        while IFS= read -r entry; do
            local name source_type repo
            name=$(echo "$entry" | jq -r '.name')
            source_type=$(echo "$entry" | jq -r '.source.source')
            if [ "$source_type" = "github" ]; then
                repo=$(echo "$entry" | jq -r '.source.repo')
                if claude plugins marketplace list 2>/dev/null | grep -q "^$name"; then
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
        while IFS= read -r plugin_key; do
            local is_user
            is_user=$(jq -r --arg k "$plugin_key" '.plugins[$k][] | select(.scope == "user") | .scope' \
                "$manifests_dir/installed_plugins.json" | head -1)
            if [ -n "$is_user" ]; then
                if claude plugins list --json 2>/dev/null | jq -e --arg k "$plugin_key" '.[] | select(.name == $k)' &>/dev/null; then
                    verbose "plugin '$plugin_key' already installed."
                else
                    log "Installing plugin '$plugin_key'..."
                    claude plugins install "$plugin_key" 2>&1 | sed 's/^/  /'
                fi
            fi
        done < <(jq -r '.plugins | keys[]' "$manifests_dir/installed_plugins.json")
    fi
}

MODE="${1:-sync}"

# Parse flags from remaining args
shift || true
for arg in "$@"; do
    case "$arg" in
        -v|--verbose) VERBOSE=1 ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

case "$MODE" in
    push)
        commit_local_changes
        push_remote
        ;;
    pull)
        commit_local_changes   # stash local work as a commit before merging
        pull_remote
        restore_plugins
        ;;
    sync)
        commit_local_changes
        pull_remote
        restore_plugins
        push_remote
        ;;
    *)
        echo "Usage: $0 [push|pull|sync] [-v]" >&2
        exit 1
        ;;
esac

verbose "Done."
