#!/usr/bin/env bash
# Add claude-sync and claude-memory-init aliases to shell config files.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MARKER="# claude-settings aliases"

# alias name → target script, added together under one marker block.
ALIASES=(
    "claude-sync=${SCRIPT_DIR}/sync.sh"
    "claude-memory-init=${SCRIPT_DIR}/claude-memory-init.sh"
)

add_to_file() {
    local file="$1"
    # Append only aliases not already in the file, so re-running (or upgrading
    # from a prior version that added only claude-sync) adds just what's missing.
    local added=0 block="$MARKER"
    local entry name target line
    for entry in "${ALIASES[@]}"; do
        name="${entry%%=*}"; target="${entry#*=}"
        line="alias ${name}='${target}'"
        if grep -qF "alias ${name}=" "$file" 2>/dev/null; then
            continue
        fi
        block="$block"$'\n'"$line"
        added=1
    done
    if [ "$added" -eq 0 ]; then
        echo "  $file: all aliases already present, skipping."
        return
    fi
    printf '\n%s\n' "$block" >> "$file"
    echo "  $file: alias(es) added."
}

ensure_bash_aliases_sourced() {
    local bashrc="$HOME/.bashrc"
    if [ ! -f "$bashrc" ]; then
        return
    fi
    if grep -qF ".bash_aliases" "$bashrc"; then
        return
    fi
    printf '\nif [ -f ~/.bash_aliases ]; then\n    . ~/.bash_aliases\nfi\n' >> "$bashrc"
    echo "  $bashrc: added .bash_aliases sourcing."
}

echo "Installing claude-sync alias..."

# bash: use .bash_aliases
ensure_bash_aliases_sourced
add_to_file "$HOME/.bash_aliases"

# zsh: use .zshrc directly (no .zsh_aliases convention)
if [ -f "$HOME/.zshrc" ]; then
    add_to_file "$HOME/.zshrc"
else
    echo "  ~/.zshrc not found, skipping zsh."
fi

echo "Done. Restart your shell or:"
echo "  bash: source ~/.bash_aliases"
echo "  zsh:  source ~/.zshrc"
