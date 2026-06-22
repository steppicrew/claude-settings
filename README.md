# claude-settings

Public sync tooling for Claude Code configuration. Personal settings live in a separate private config repo.

## How it works

```
~/git/claude-settings/       ← this repo (public): sync tooling only
  sync.sh
  install-alias.sh
  config/
    personal/                ← private config repo (cloned via add-config)
      CLAUDE.md
      settings.json
      plugins/
      projects/
    current -> personal/     ← symlink to active config
~/.claude -> config/current  ← Claude Code reads config from here
```

## Setup on a new machine

```bash
# 1. Clone this repo
git clone git@github.com:steppicrew/claude-settings.git ~/git/claude-settings

# 2. Add your private config repo
~/git/claude-settings/sync.sh add-config personal git@github.com:you/claude-settings-personal.git

# 3. Switch to it (sets config/current symlink)
~/git/claude-settings/sync.sh switch-config personal

# 4. Point ~/.claude at the active config
ln -sfn ~/git/claude-settings/config/current ~/.claude

# 5. Add the claude-sync shell alias
~/git/claude-settings/install-alias.sh
source ~/.bash_aliases   # bash
# source ~/.zshrc        # zsh
```

## Syncing

```bash
claude-sync           # pull + push active config (default)
claude-sync pull      # fetch remote, merge, restore plugins
claude-sync push      # commit local changes and push
claude-sync -v        # verbose output
```

## Multiple configs

```bash
claude-sync add-config work git@github.com:you/claude-settings-work.git
claude-sync switch-config work    # re-points config/current and ~/.claude
claude-sync list-configs          # show all configs, mark active
```

## What's in a private config repo

| Path | Purpose |
|------|---------|
| `CLAUDE.md` | Global instructions applied to all projects |
| `settings.json` | Claude Code UI/behaviour settings |
| `plugins/installed_plugins.json` | Which plugins are installed |
| `plugins/known_marketplaces.json` | Registered plugin marketplaces |
| `plugins/blocklist.json` | Blocked plugins |
| `projects/*/memory/` | Per-project auto-memory files |

Plugin marketplace dirs and cache are excluded — they are re-fetched on pull.

## Notes

- `~/.claude/.credentials.json` is excluded — authenticate per machine via `claude login`.
- Project memory paths encode the absolute project path (e.g. `-home-you-git-myproject`). They load only on machines with matching directory layout, but sync harmlessly otherwise.
- Reference plugin scripts via `~/.claude/plugins/marketplaces/<plugin>/src/...`, never the cache path (hash varies per machine).
