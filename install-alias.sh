#!/usr/bin/env bash
# Add claude-sync alias to shell config files.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ALIAS_LINE="alias claude-sync='${SCRIPT_DIR}/sync.sh'"
MARKER="# claude-sync alias"

add_to_file() {
    local file="$1"
    if grep -qF "claude-sync" "$file" 2>/dev/null; then
        echo "  $file: already present, skipping."
        return
    fi
    printf '\n%s\n%s\n' "$MARKER" "$ALIAS_LINE" >> "$file"
    echo "  $file: alias added."
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
