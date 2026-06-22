# claude-settings

Shared Claude Code configuration, synced across machines via git.

## What's tracked

| Path | Purpose |
|------|---------|
| `CLAUDE.md` | Global instructions applied to all projects |
| `settings.json` | Claude Code UI/behaviour settings |
| `projects/*/memory/` | Per-project auto-memory files |
| `plugins/installed_plugins.json` | Which plugins are installed and at what scope |
| `plugins/known_marketplaces.json` | Registered plugin marketplaces |
| `plugins/blocklist.json` | Blocked plugins |

Everything else (marketplace dirs, plugin cache, sessions, history, shell snapshots) is excluded via `.gitignore`.

## Setup on a new machine

```bash
# 1. Clone this repo
git clone git@github.com:steppicrew/claude-settings.git ~/git/claude-settings

# 2. Back up any existing ~/.claude (if present)
mv ~/.claude ~/.claude.bak   # skip if not present

# 3. Symlink ~/.claude to the repo
ln -s ~/git/claude-settings ~/.claude

# 4. Add the claude-sync shell alias
~/git/claude-settings/install-alias.sh
source ~/.bash_aliases   # bash
# source ~/.zshrc        # zsh
```

Claude Code will now pick up `CLAUDE.md`, `settings.json`, and all project memories automatically.

## Keeping in sync

Use `sync.sh` (or the `claude-sync` alias) before starting a Claude session and after finishing:

```bash
claude-sync          # pull + push (default)
claude-sync pull     # fetch remote, merge (local wins on conflicts), restore plugins
claude-sync push     # commit local changes and push
claude-sync -v       # verbose output
```

The script:
1. Commits any uncommitted local changes
2. Fetches and merges remote changes — keeps **local version** on conflicts
3. Restores any missing marketplaces and user-scoped plugins from manifests
4. Pushes the result

## Notes

- `~/.claude/.credentials.json` is intentionally excluded — authenticate on each machine separately via `claude login`.
- Project memory paths are named after the absolute path of the project (e.g. `-home-stephan-git-myproject`). These only load on machines with the same directory layout, but sync harmlessly otherwise.
- Plugin marketplace dirs are not synced — they are re-fetched from source on pull. Reference plugin scripts via `~/.claude/plugins/marketplaces/<plugin>/src/...`, never the cache path.
